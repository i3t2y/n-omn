'use strict';
// ── OmniRoute Gate.js v5.1（零依赖；SSE 全量 pipe；0.0.0.0 绑定）──
const http = require('http');
const crypto = require('crypto');
const fs = require('fs');

// §1 配置与 fail-closed
const INTERNAL_PSK = process.env.INTERNAL_PSK;
if (!INTERNAL_PSK) { console.error('[gate] FATAL: INTERNAL_PSK 未设置。'); process.exit(1); }
if (INTERNAL_PSK.length < 16) { console.error('[gate] FATAL: INTERNAL_PSK < 16 字符。'); process.exit(1); }

const OR_PORT = parseInt(process.env.OMNIROUTE_PORT || '20128', 10);
const GATE_PORT = parseInt(process.env.EXPOSED_PORT || '7860', 10);

let OR_API_KEY = (process.env.OMNIROUTE_API_KEY || '').trim();
if (!OR_API_KEY) {
  try { OR_API_KEY = fs.readFileSync('/data/.or-api-key', 'utf8').trim(); }
  catch (e) { if (e.code !== 'ENOENT') console.error('[gate] WARN read key:', e.message); }
}
if (!OR_API_KEY) { console.error('[gate] FATAL: 无 OR_API_KEY。'); process.exit(1); }

console.log(`[gate] init: port=${GATE_PORT} → upstream=${OR_PORT}, PSK len=${INTERNAL_PSK.length}`);

// §2 timing-safe PSK
function safeEqual(a, b) {
  const ba = Buffer.from(a || ''); const bb = Buffer.from(b || '');
  if (ba.length !== bb.length) return false;
  return crypto.timingSafeEqual(ba, bb);
}

// §3 路径规整化
function normPathOf(u) {
  try { const p = new URL(u, 'http://x').pathname; return p === '/' ? '/' : p.replace(/\/+$/, ''); }
  catch { return u; }
}

// §4 共享预算限流（默认对齐 init：28 RPM / 6 并发 / 0ms）
const RPM_LIMIT = parseInt(process.env.GATE_RPM_LIMIT || '28', 10);
const CONCURRENT_LIMIT = parseInt(process.env.GATE_CONCURRENT_LIMIT || '6', 10);
const MIN_INTERVAL_MS = parseInt(process.env.GATE_MIN_INTERVAL_MS || '0', 10);
const rpmWindow = []; let active = 0; let lastReq = 0;

function checkRate() {
  const now = Date.now();
  if (active >= CONCURRENT_LIMIT) return { ok: false, retry: 2, why: `concurrent(${active}/${CONCURRENT_LIMIT})` };
  if (MIN_INTERVAL_MS > 0 && now - lastReq < MIN_INTERVAL_MS)
    return { ok: false, retry: Math.ceil((MIN_INTERVAL_MS - (now - lastReq)) / 1000), why: 'interval' };
  const start = now - 60000;
  while (rpmWindow.length && rpmWindow[0] < start) rpmWindow.shift();
  if (rpmWindow.length >= RPM_LIMIT) {
    const retry = Math.ceil((rpmWindow[0] + 60000 - now) / 1000);
    return { ok: false, retry: retry > 0 ? retry : 1, why: `rpm(${rpmWindow.length}/${RPM_LIMIT})` };
  }
  rpmWindow.push(now); active++; lastReq = now; return { ok: true };
}
function release() { if (active > 0) active--; }

// §5 诊断
const diag = { errors: {}, start: Date.now() };

// §6 主服务
const server = http.createServer((req, res) => {
  const t0 = Date.now();
  const np = normPathOf(req.url);

  // A. /healthz（无需认证）
  if (req.method === 'GET' && np === '/healthz') {
    const hc = http.request({ host: '127.0.0.1', port: OR_PORT, path: '/api/monitoring/health', method: 'GET', timeout: 5000 },
      (up) => {
        const ok = up.statusCode >= 200 && up.statusCode < 300;
        res.writeHead(ok ? 200 : 503, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify({ ok })); up.resume();
      });
    hc.on('error', () => { res.writeHead(503, { 'Content-Type': 'application/json' }); res.end('{"ok":false}'); });
    hc.on('timeout', () => hc.destroy());
    hc.end();
    return;
  }

  // B. 白名单：仅 /v1 或 /v1/*，其余 404
  const isV1 = np === '/v1' || np.startsWith('/v1/');
  if (!isV1) { res.writeHead(404, { 'Content-Type': 'application/json' }); res.end('{"error":"not_found"}'); return; }

  // C. 敏感子路径 404（隐藏搜索分析统计）
  if (np === '/v1/search/analytics') { res.writeHead(404, { 'Content-Type': 'application/json' }); res.end('{"error":"not_found"}'); return; }

  // D. PSK 认证
  const bearer = (req.headers['authorization'] || '').replace(/^Bearer\s+/i, '');
  if (!safeEqual(bearer, INTERNAL_PSK)) {
    res.writeHead(401, { 'Content-Type': 'application/json' }); res.end('{"error":"unauthorized"}'); return;
  }

  // E. 限流
  const rl = checkRate();
  if (!rl.ok) {
    res.writeHead(429, { 'Content-Type': 'application/json', 'Retry-After': String(rl.retry) });
    res.end(JSON.stringify({ error: 'rate_limited', reason: rl.why, retryAfter: rl.retry }));
    return;
  }

  // F. PSK → OR_API_KEY 替换 + Host 重写
  req.headers['authorization'] = `Bearer ${OR_API_KEY}`;
  req.headers['host'] = `127.0.0.1:${OR_PORT}`;

  // G. 反代到本地 OmniRoute —— 全量 pipe（不猜 SSE，由上游 Content-Type 驱动）
  let released = false;
  const done = () => { if (!released) { released = true; release(); } };

  const proxyReq = http.request(
    { host: '127.0.0.1', port: OR_PORT, path: req.url, method: req.method, headers: req.headers },
    (up) => {
      const code = up.statusCode || 502;
      if (code >= 500) { diag.errors[code] = (diag.errors[code] || 0) + 1;
        console.error(`[gate] ${req.method} ${np} → ${code} (${Date.now() - t0}ms)`); }
      res.writeHead(code, up.headers);
      up.pipe(res);                    // ← 关键：流式/非流式统一 pipe，尊重背压
      up.on('end', done);
      up.on('error', done);
    }
  );

  proxyReq.on('error', (err) => {
    diag.errors['502'] = (diag.errors['502'] || 0) + 1;
    console.error(`[gate] upstream error: ${err.message}`);
    if (!res.headersSent) { res.writeHead(502, { 'Content-Type': 'application/json' }); }
    res.end(JSON.stringify({ error: 'bad_gateway', detail: err.message }));
    done();
  });

  proxyReq.setTimeout(0);              // ← SSE 长连接全禁超时
  req.on('aborted', () => { proxyReq.destroy(); done(); });  // 客户端断开清理上游
  req.pipe(proxyReq);                  // 请求体流式转发
});

server.setTimeout(0);                  // 全局禁用 socket 超时（大上下文压缩期）
server.listen(GATE_PORT, '0.0.0.0', () => {
  console.log(`[gate] listening on 0.0.0.0:${GATE_PORT} (upstream 127.0.0.1:${OR_PORT})`);
});
