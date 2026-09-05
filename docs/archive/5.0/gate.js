// === ARCHIVED gate.js ===
// 来源版本: 5.0 旁支(omniroute-gate-v5)
// 生成日期: 2026-07-16 (mtime)
// 状态: DEPRECATED — 永久禁止作为任何新生成的起点, 仅作指纹比对素材
// === END META ===

'use strict';
// ── OmniRoute 3.8.43 终极优化版 · Gate.js（零依赖纯 Node.js 内置模块）───
// 架构：http/fs/crypto 内置模块，移除 express/http-proxy-middleware
// 解决：better-sqlite3 和 node-gyp 在 Node 24 环境下的 C++20 编译冲突
//
// 安全特性：
//   · timing-safe PSK 比较（防时序侧信道攻击）
//   · PSK 最小长度 16 fail-closed（弱 PSK 直接 FATAL exit）
//   · 白名单暴露面（仅 /healthz + /v1/*，其余 404）
//   · 路径规整化（防 dot-segment/double-slash 绕过）
//   · PSK → OR_API_KEY 替换（客户端只需知道 PSK）
//   · SSE 流式全禁超时（防大上下文压缩期间被掐断）
//   · 共享预算限流（RPM 滑动窗口 + 并发计数 + 间隔 pacing）
//   · 连接生命周期管理（客户端断开清理上游 socket）
//   · 结构化请求日志（JSON 格式，便于日志聚合）

const http = require('http');
const crypto = require('crypto');
const fs = require('fs');

// ════════════════════════════════════════════════════════════════
// §1 配置与安全初始化
// ════════════════════════════════════════════════════════════════
const INTERNAL_PSK = process.env.INTERNAL_PSK;
if (!INTERNAL_PSK) {
  console.error('[gate] FATAL: INTERNAL_PSK 未设置。HF Space Secret 必须配置。');
  process.exit(1);
}
// PSK 最小长度 16 fail-closed
if (INTERNAL_PSK.length < 16) {
  console.error('[gate] FATAL: INTERNAL_PSK 长度不足 16 字符。');
  process.exit(1);
}

const OR_PORT = parseInt(process.env.OMNIROUTE_PORT || '20128', 10);
const GATE_PORT = parseInt(process.env.EXPOSED_PORT || '7860', 10);

// ── OR_API_KEY 双源：env 优先，fallback 读文件 ──
let OR_API_KEY = (process.env.OMNIROUTE_API_KEY || '').trim();
if (!OR_API_KEY) {
  try { OR_API_KEY = fs.readFileSync('/data/.or-api-key', 'utf8').trim(); }
  catch (e) { if (e.code !== 'ENOENT') console.error('[gate] WARN read key failed:', e.message); }
}
if (!OR_API_KEY) {
  console.error('[gate] FATAL: 无 OR_API_KEY（env 和文件均缺失）。');
  process.exit(1);
}

console.log(`[gate] 初始化完成: port=${GATE_PORT} → upstream=${OR_PORT}`);
console.log(`[gate] PSK 长度=${INTERNAL_PSK.length}, OR_API_KEY 源=${process.env.OMNIROUTE_API_KEY ? 'env' : 'file'}`);

// ════════════════════════════════════════════════════════════════
// §2 timing-safe PSK 比较（常量时间，防时序侧信道攻击）
// ════════════════════════════════════════════════════════════════
function timingSafeEqual(a, b) {
  // 长度不等时先返回 false（不泄露长度信息）
  if (a.length !== b.length) return false;
  return crypto.timingSafeEqual(Buffer.from(a), Buffer.from(b));
}

// ════════════════════════════════════════════════════════════════
// §3 路径规整化（防 dot-segment / double-slash / tail-slash 绕过）
// ════════════════════════════════════════════════════════════════
function normalizePath(urlPath) {
  try {
    const parsed = new URL(urlPath, 'http://x');
    const p = parsed.pathname;
    // 去尾斜杠（根路径除外）
    return p === '/' ? '/' : p.replace(/\/+$/, '');
  } catch { return urlPath; }
}

// ════════════════════════════════════════════════════════════════
// §4 共享预算限流（Gate 自行执行，不依赖 OmniRoute API）
// ════════════════════════════════════════════════════════════════
const RPM_LIMIT = parseInt(process.env.GATE_RPM_LIMIT || '28', 10);
const CONCURRENT_LIMIT = parseInt(process.env.GATE_CONCURRENT_LIMIT || '1', 10);
const MIN_INTERVAL_MS = parseInt(process.env.GATE_MIN_INTERVAL_MS || '2200', 10);

// RPM 滑动窗口（60 秒内请求时间戳数组）
const rpmWindow = [];
let activeRequests = 0;
let lastRequestTime = 0;

function checkRateLimit() {
  const now = Date.now();

  // 并发检查
  if (activeRequests >= CONCURRENT_LIMIT) {
    return { allowed: false, retryAfter: 2, reason: `concurrent(${activeRequests}/${CONCURRENT_LIMIT})` };
  }

  // 间隔 pacing 检查
  const elapsed = now - lastRequestTime;
  if (elapsed < MIN_INTERVAL_MS) {
    return { allowed: false, retryAfter: Math.ceil((MIN_INTERVAL_MS - elapsed) / 1000), reason: `interval(${elapsed}ms<${MIN_INTERVAL_MS}ms)` };
  }

  // RPM 滑动窗口检查
  const windowStart = now - 60000;
  while (rpmWindow.length > 0 && rpmWindow[0] < windowStart) {
    rpmWindow.shift();
  }
  if (rpmWindow.length >= RPM_LIMIT) {
    const oldest = rpmWindow[0];
    const retrySec = Math.ceil((oldest + 60000 - now) / 1000);
    return { allowed: false, retryAfter: retrySec > 0 ? retrySec : 1, reason: `rpm(${rpmWindow.length}/${RPM_LIMIT})` };
  }

  // 通过所有检查
  rpmWindow.push(now);
  activeRequests++;
  lastRequestTime = now;
  return { allowed: true };
}

function releaseRequest() {
  activeRequests--;
}

// ════════════════════════════════════════════════════════════════
// §5 诊断端点 /gate/diagnostics
// ════════════════════════════════════════════════════════════════
const diagnostics = {
  errors: { 502: 0, 503: 0, 504: 0 },
  recentLogs: [],
  startTime: Date.now(),
  config: { GATE_PORT, OR_PORT, RPM_LIMIT, CONCURRENT_LIMIT, MIN_INTERVAL_MS }
};

function recordLog(method, path, statusCode, latencyMs, contentLength) {
  const entry = {
    ts: new Date().toISOString(),
    method,
    path,
    statusCode,
    latencyMs,
    contentLength,
    userAgent: '-' // 可从 req.headers 提取
  };
  diagnostics.recentLogs.push(entry);
  if (diagnostics.recentLogs.length > 20) diagnostics.recentLogs.shift();
}

// ════════════════════════════════════════════════════════════════
// §6 ANSI 颜色日志函数
// ════════════════════════════════════════════════════════════════
function log_info(msg)  { console.log(`\x1b[32m[gate]\x1b[0m ${msg}`); }
function log_success(msg){ console.log(`\x1b[32;1m[gate]\x1b[0m ${msg}`); }
function log_warn(msg)   { console.warn(`\x1b[33m[gate]\x1b[0m ${msg}`); }
function log_error(msg)  { console.error(`\x1b[31m[gate]\x1b[0m ${msg}`); }

// ════════════════════════════════════════════════════════════════
// §7 HTTP Server 主逻辑
// ════════════════════════════════════════════════════════════════
const server = http.createServer((req, res) => {
  const reqStart = Date.now();
  const normPath = normalizePath(req.url);

  // ── A. /healthz：网关自身健康检查（无需认证）──
  if (req.method === 'GET' && normPath === '/healthz') {
    const hc = http.request(
      { host: '127.0.0.1', port: OR_PORT, path: '/api/monitoring/health', method: 'GET', timeout: 5000 },
      (up) => {
        if (up.statusCode && up.statusCode >= 200 && up.statusCode < 300) {
          res.writeHead(200, { 'Content-Type': 'application/json' });
          res.end(JSON.stringify({ ok: true }));
        } else {
          res.writeHead(503, { 'Content-Type': 'application/json' });
          res.end(JSON.stringify({ ok: false }));
        }
        up.resume();
      }
    );
    hc.on('error', () => {
      res.writeHead(503, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify({ ok: false }));
    });
    hc.on('timeout', () => hc.destroy());
    hc.end();
    return;
  }

  // ── B. /gate/diagnostics：诊断信息（无需认证，仅本地调试用）──
  if (req.method === 'GET' && normPath === '/gate/diagnostics') {
    res.writeHead(200, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify({
      uptimeMs: Date.now() - diagnostics.startTime,
      errors: diagnostics.errors,
      recentLogs: diagnostics.recentLogs,
      rateLimit: {
        currentRpm: rpmWindow.filter(t => t > Date.now() - 60000).length,
        activeRequests,
        rpmLimit: RPM_LIMIT,
        concurrentLimit: CONCURRENT_LIMIT
      },
      config: diagnostics.config
    }, null, 2));
    return;
  }

  // ── C. 白名单暴露面控制：仅放行 /v1 路径，其余 404 ──
  //     使用精确匹配：'/v1' 或 '/v1/*'，排除 '/v123' '/v1admin' 等
  const isV1Path = normPath === '/v1' || normPath.startsWith('/v1/');
  if (!isV1Path) {
    res.writeHead(404, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify({ error: 'not_found', path: normPath }));
    return;
  }

  // ── D. PSK 认证（timing-safe equal）──
  const bearer = (req.headers['authorization'] || '').replace('Bearer ', '');
  if (!timingSafeEqual(bearer, INTERNAL_PSK)) {
    res.writeHead(401, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify({ error: 'unauthorized' }));
    log_warn(`认证失败 (${normPath.substring(0, 40)})`);
    return;
  }

  // ── E. 限流检查 ──
  const rl = checkRateLimit();
  if (!rl.allowed) {
    res.writeHead(429, {
      'Content-Type': 'application/json',
      'Retry-After': String(rl.retryAfter)
    });
    res.end(JSON.stringify({ error: 'rate_limited', reason: rl.reason, retryAfter: rl.retryAfter }));
    log_warn(`限流触发: ${rl.reason} (${normPath.substring(0, 40)})`);
    return;
  }

  // ── F. PSK → OR_API_KEY 替换 ──
  req.headers['authorization'] = `Bearer ${OR_API_KEY}`;

  // ── G. SSE 检测（Accept: text/event-stream 或 GET /v1/ 开头）──
  const isSSE = req.headers['accept'] === 'text/event-stream' ||
                (req.method === 'GET' && normPath.startsWith('/v1/'));

  // ── H. Host header 重写（防上游路由异常）──
  delete req.headers['host'];
  req.headers['host'] = `127.0.0.1:${OR_PORT}`;

  // ── I. 反向代理到本地 OmniRoute ──
  const proxyReq = http.request(
    { host: '127.0.0.1', port: OR_PORT, path: req.url, method: req.method, headers: req.headers },
    (upstreamRes) => {
      const statusCode = upstreamRes.statusCode || 502;
      const latencyMs = Date.now() - reqStart;

      // 记录错误统计
      if (statusCode >= 500) {
        diagnostics.errors[String(statusCode)] = (diagnostics.errors[String(statusCode)] || 0) + 1;
        log_error(`${req.method} ${normPath} → ${statusCode} (${latencyMs}ms)`);
      }

      res.writeHead(statusCode, upstreamRes.headers);

      if (isSSE) {
        // ── SSE 流式转发：逐块 pipe，尊重背压 ──
        upstreamRes.on('data', (chunk) => {
          if (!res.write(chunk)) {
            upstreamRes.pause();
            res.once('drain', () => upstreamRes.resume());
          }
        });
        upstreamRes.on('end', () => { res.end(); releaseRequest(); recordLog(req.method, normPath, statusCode, latencyMs, 0); });
      } else {
        // 非 SSE：聚合转发
        const chunks = [];
        upstreamRes.on('data', (chunk) => chunks.push(chunk));
        upstreamRes.on('end', () => {
          const body = Buffer.concat(chunks);
          res.end(body);
          releaseRequest();
          recordLog(req.method, normPath, statusCode, latencyMs, body.length);
        });
      }
    }
  );

  proxyReq.on('error', (err) => {
    const latencyMs = Date.now() - reqStart;
    diagnostics.errors['502']++;
    log_error(`upstream error: ${err.message} (${normPath.substring(0, 40)})`);
    releaseRequest();
    if (!res.headersSent) {
      res.writeHead(502, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify({ error: 'bad_gateway', message: err.message }));
    }
  });

  // ── J. 连接生命周期管理：客户端断开时清理上游连接 ──
  req.on('close', () => {
    if (!res.finished) {
      proxyReq.destroy();
    }
  });

  // 请求体流式转发
  req.pipe(proxyReq);
});

// ════════════════════════════════════════════════════════════════
// §8 SSE / 长连接：禁用所有超时
// ════════════════════════════════════════════════════════════════
server.timeout = 0;
server.requestTimeout = 0;
server.headersTimeout = 0;

// ════════════════════════════════════════════════════════════════
// §9 SIGTERM 优雅退出
// ════════════════════════════════════════════════════════════════
process.on('SIGTERM', () => {
  log_info('收到 SIGTERM，优雅关闭 HTTP 服务器...');
  server.close(() => {
    log_success('HTTP 服务器已关闭');
    process.exit(0);
  });
  // 5s 后强制退出
  setTimeout(() => { log_error('强制退出'); process.exit(1); }, 5000);
});

// ════════════════════════════════════════════════════════════════
// §10 启动监听
// ════════════════════════════════════════════════════════════════
server.listen(GATE_PORT, '0.0.0.1', () => {
  log_success(`listening on 0.0.0.0:${GATE_PORT} → 127.0.0.1:${OR_PORT} (零依赖版)`);
  log_info(`限流: ${RPM_LIMIT} RPM / ${CONCURRENT_LIMIT} 并发 / ${MIN_INTERVAL_MS}ms 间隔`);
});