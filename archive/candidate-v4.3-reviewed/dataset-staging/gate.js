// OmniRoute Gate · 零依赖版（仅 http / crypto）
// =====================================================
// 合并版 — K3 v2.0 根因修 + candidate v4.3 保留的真值项 + 后台 fail-safe
//
// K3 v2.0 根因修（撤回 v1/candidate 错设计）:
//   - 清理时机 req.on('close') → res.on('close')
//     Node 的 IncomingMessage 是 autoDestroy 流: 请求体被 pipe 消费完即触发 close,
//     v1/candidate 在此 destroy() 上游 → 所有请求 12-24ms 内被误杀 (request_signal_aborted)。
//     正确时机是 res close (响应结束 或 客户端真断开)。
//   - connection: close 头 规避 keep-alive 复用边界问题。
//
// candidate v4.3 保留真值（K3 漏, 已补回）:
//   - 上游超时 504: timeout: UPSTREAM_TIMEOUT_MS + timeout handler → 504。
//     K3 原设 timeout:0 = 上游挂死 gate 永等。补回 candidate 30s 默认 (env 可调)。
//   - 无 body 显式 end: GET/OPTIONS 无 content-length/transfer-encoding 时,
//     纯 req.pipe(proxyReq) 不会自动调 proxyReq.end() → 上游收不到完整请求。
//     candidate 在此情况显式 upstreamReq.end()。
//   - 后台 fail-safe + GATE_ADMIN_TOKEN (用户选加 — K3 v2.0 裸透传致后台暴露公网):
//     * 默认 (GATE_ADMIN_TOKEN 未设/空/过短<16): 后台关闭, 外网仅 GET /healthz + /v1/*, 其余 404。
//       后台关时即使持 OmniRoute Cookie 也 404 — 不泄露后台是否存在, 堵 /api/auth/login 撞 INITIAL_PASSWORD 面。
//     * 设有效 GATE_ADMIN_TOKEN: 后台白名单路径经 HTTP Basic Auth (admin/<token>) 放行,
//       白名单仅只读 GET 看板 API + 页面 (排除 restart/shutdown/init/webhooks 等高危写执行)。
//       通过后删 Authorization 头不转发上游 (防凭据泄露); OmniRoute 自家 Cookie/Session 照走。

const http = require('http');
const crypto = require('crypto');

const GATE_PORT = parseInt(process.env.EXPOSED_PORT || '7860', 10);
const UPSTREAM_PORT = parseInt(process.env.OMNIROUTE_PORT || '20128', 10);
const UPSTREAM_HOST = '127.0.0.1';
const PSK = process.env.INTERNAL_PSK || '';
const OR_API_KEY = process.env.OMNIROUTE_API_KEY || '';

// candidate 保留: 上游超时 (env 可调, 默认 180s)
// 注意: Node http.request timeout 是 socket 空闲超时 (非总时长), 数据流动时计时器重置, SSE 长流不被腰斩。
// 180s 容纳 thinking 模型长思考期间零 chunk; 对非 thinking 流可经 GATE_UPSTREAM_TIMEOUT_MS env 调低。
const UPSTREAM_TIMEOUT_MS = parseInt(process.env.GATE_UPSTREAM_TIMEOUT_MS || '180000', 10) || 180000;

const RPM_LIMIT = parseInt(process.env.NIM_RPM_LIMIT || '28', 10);
const CONCURRENT_LIMIT = parseInt(process.env.NIM_CONCURRENT_LIMIT || '1', 10);
const MIN_INTERVAL_MS = parseInt(process.env.NIM_MIN_INTERVAL_MS || '100', 10);

// ── 后台开关 (candidate v4.3 移植) ──
const GATE_ADMIN_TOKEN = process.env.GATE_ADMIN_TOKEN || '';
const ADMIN_TOKEN_MIN_LEN = 16;
const ADMIN_REALM = 'OmniRoute Admin';
const ADMIN_ENABLED = GATE_ADMIN_TOKEN.length >= ADMIN_TOKEN_MIN_LEN;
if (process.env.GATE_ADMIN_TOKEN && GATE_ADMIN_TOKEN.length < ADMIN_TOKEN_MIN_LEN) {
  console.error(`[gate] WARN: GATE_ADMIN_TOKEN 长度 <${ADMIN_TOKEN_MIN_LEN}, 后台关闭 (不记录 token 值).`);
}
// 后台页面前缀 (GET 导航免静态资源 token)
const ADMIN_PAGE_PREFIXES = [
  '/login', '/forgot-password', '/auth/callback', '/callback', '/authorize',
  '/connect', '/terms', '/privacy', '/docs', '/status', '/landing',
  '/home', '/dashboard',
];
// 只读看板管理 API (排除 restart/shutdown/init/webhooks 等高危写执行)
const ADMIN_API_ROUTES = [
  { pre: '/api/providers',          methods: ['GET'] },
  { pre: '/api/combos',             methods: ['GET'] },
  { pre: '/api/resilience',         methods: ['GET'] },
  { pre: '/api/keys',               methods: ['GET'] },
  { pre: '/api/provider-models',    methods: ['GET'] },
  { pre: '/api/models',             methods: ['GET'] },
  { pre: '/api/settings',           methods: ['GET'] },
  { pre: '/api/provider-stats',    methods: ['GET'] },
  { pre: '/api/provider-metrics',  methods: ['GET'] },
  { pre: '/api/sessions',          methods: ['GET'] },
  { pre: '/api/session-pools',     methods: ['GET'] },
  { pre: '/api/rate-limit',        methods: ['GET'] },
  { pre: '/api/rate-limits',       methods: ['GET'] },
  { pre: '/api/token-health',      methods: ['GET'] },
  { pre: '/api/synced-available-models', methods: ['GET'] },
  { pre: '/api/free-models',              methods: ['GET'] },
  { pre: '/api/free-provider-rankings',   methods: ['GET'] },
  { pre: '/api/tags',              methods: ['GET'] },
];

let _tokens = RPM_LIMIT, _lastRefill = Date.now(), _lastReq = 0, _active = 0;

function tryAcquire() {
  const now = Date.now();
  _tokens = Math.min(RPM_LIMIT, _tokens + ((now - _lastRefill) / 60000) * RPM_LIMIT);
  _lastRefill = now;
  if (_tokens < 1 || _active >= CONCURRENT_LIMIT || now - _lastReq < MIN_INTERVAL_MS) return false;
  _tokens -= 1; _active += 1; _lastReq = now;
  return true;
}

function safeCompare(a, b) {
  const x = Buffer.from(a), y = Buffer.from(b);
  return x.length === y.length && crypto.timingSafeEqual(x, y);
}

// ── 后台白名单辅助 (candidate v4.3 移植) ──
function normalizePath(p) {
  try {
    const u = new URL(p, 'http://x');
    let n = u.pathname.replace(/\/+/g, '/').replace(/\/$/, '');
    if (n === '') n = '/';
    return n;
  } catch (e) { return p; }
}
function isStaticAssetPath(p) {
  if (p.startsWith('/_next/')) return true;
  return /^\/(favicon\.ico|favicon\.svg|apple-touch-icon\.(png|svg)|icon-192\.svg|icon-512\.png|sw\.js|openapi\.yaml)/.test(p);
}
function isAdminPagePath(p) {
  if (p === '/') return true;
  if (isStaticAssetPath(p)) return true;
  // 仅精确匹配 或 前缀+斜杠; 去掉裸 startsWith(pre) (避 /loginxyz 误命中)
  return ADMIN_PAGE_PREFIXES.some(pre => p === pre || p.startsWith(pre + '/'));
}
function apiRouteMatch(p, method) {
  for (const r of ADMIN_API_ROUTES) {
    if (p === r.pre || p.startsWith(r.pre + '/')) return r.methods.includes(method);
  }
  return false;
}
// HTTP Basic Auth: user 固定 'admin', password = GATE_ADMIN_TOKEN. timing-safe 比密码.
function adminBasicAuthOk(req) {
  const header = req.headers['authorization'] || '';
  if (!header.startsWith('Basic ')) return false;
  let decoded;
  try { decoded = Buffer.from(header.slice('Basic '.length).trim(), 'base64').toString('utf8'); }
  catch { return false; }
  const idx = decoded.indexOf(':');
  if (idx < 0) return false;
  const user = decoded.slice(0, idx), pass = decoded.slice(idx + 1);
  if (user !== 'admin') return false;
  return safeCompare(pass, GATE_ADMIN_TOKEN); // timing-safe, 长度不等不退字符串比较
}

http.createServer((req, res) => {
  const normPath = normalizePath(req.url);
  const qIdx = req.url.indexOf('?');
  const qs = qIdx >= 0 ? req.url.slice(qIdx) : '';

  // ── 1. 健康检查 (不耗令牌, 不计并发, 免认证) ──
  if (normPath === '/healthz') {
    res.writeHead(200, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify({ status: 'ok', active: _active, tokens: Math.floor(_tokens) }));
    return;
  }

  // ── 2. 暴露面白名单 (candidate 移植: 默认仅 /v1/* + /healthz; 后台须 ADMIN_ENABLED 且路径在白名单) ──
  //   非 /v1: 须 ADMIN_ENABLED 且路径在白名单 (页/api/静态), 否则 404。
  //   后台关时即使持 OmniRoute Cookie 也 404 (不泄露后台是否存在)。
  let adminMode = false; // 是否走后台代理 (区别于 /v1 推理)

  if (normPath === '/v1' || normPath.startsWith('/v1/')) {
    adminMode = false; // /v1/* 推理流
  } else {
    // 后台
    if (!ADMIN_ENABLED) { res.writeHead(404); res.end(); return; }
    // 白名单校验
    if (!isStaticAssetPath(normPath)) {
      if (isAdminPagePath(normPath)) {
        if (!['GET'].includes(req.method)) { res.writeHead(405, { 'Content-Type': 'application/json' }); res.end(JSON.stringify({ error: 'method_not_allowed' })); return; }
      } else if (apiRouteMatch(normPath, req.method)) {
        // 只读 API 允许
      } else {
        res.writeHead(404); res.end(); // 非白名单/未知 → 404, 开启用时仍 404
        return;
      }
    }
    adminMode = true;
  }

  // ── 3. 鉴权分两路 ──
  if (adminMode) {
    // 后台 Basic Auth (静态资源免 token, 仅须开关开)
    if (!isStaticAssetPath(normPath)) {
      if (!adminBasicAuthOk(req)) {
        res.setHeader('WWW-Authenticate', `Basic realm="${ADMIN_REALM}", charset="UTF-8"`);
        res.writeHead(401, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify({ error: 'unauthorized' }));
        return;
      }
    }
    // 路径就是 normPath (不含原 strip 问题, 纯 http 无 mount)
  } else {
    // /v1/* PSK 鉴权 (timingSafeEqual)
    // 双通道: Bearer (Authorization 头) 优先, 回退 X-Internal-PSK 头 (方案文档/README/运维手册指客户端用此头接入)
    const xPsk = req.headers['x-internal-psk'] || '';
    const auth = req.headers['authorization'] || '';
    const bearer = auth.startsWith('Bearer ') ? auth.slice('Bearer '.length).trim() : xPsk;
    if (!PSK || !safeCompare(bearer, PSK)) {
      res.writeHead(401, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify({ error: 'unauthorized' }));
      return;
    }
  }

  // ── 4. 限流 (仅 /v1 推理流计; 后台看板不计推理限流) ──
  if (!adminMode) {
    if (!tryAcquire()) {
      res.writeHead(429, { 'Content-Type': 'application/json', 'Retry-After': '3' });
      res.end(JSON.stringify({ error: 'rate_limited', retry_after: 3 }));
      return;
    }
  }

  let released = false;
  const done = () => { if (!released) { released = true; if (!adminMode) _active = Math.max(0, _active - 1); } };

  // ── 5. 透传头 ──
  const headers = { ...req.headers };
  if (adminMode) {
    // 后台: 删 Basic Auth 凭据不转发上游 (防泄露); OmniRoute 自家 Cookie/Session 照走
    delete headers['authorization'];
  } else {
    // /v1: 替换为上游 OR_API_KEY
    if (OR_API_KEY) headers['authorization'] = `Bearer ${OR_API_KEY}`;
    delete headers['x-internal-psk'];
  }
  headers['connection'] = 'close'; // 避 keep-alive 复用边界

  // ── 6. 上游请求 (含 candidate 保留的超时 config) ──
  // path: /v1 用 req.url (含 query); 后台用 normPath + qs
  const upstreamPath = adminMode ? (normPath + qs) : req.url;
  let gateTimeout = false;
  const proxyReq = http.request({
    hostname: UPSTREAM_HOST,
    port: UPSTREAM_PORT,
    path: upstreamPath,
    method: req.method,
    headers,
    timeout: UPSTREAM_TIMEOUT_MS,
  }, (proxyRes) => {
    res.writeHead(proxyRes.statusCode, proxyRes.headers);
    proxyRes.pipe(res); // SSE / 流式透传, 原生 pipe 自带 backpressure
  });

  // candidate 保留: 上游超时 → 504 (K3 timeout:0 会让 gate 永等)
  proxyReq.on('timeout', () => {
    gateTimeout = true;
    proxyReq.destroy(new Error('upstream_timeout'));
    console.error(`[gate] upstream timeout (${UPSTREAM_TIMEOUT_MS}ms): ${req.method} ${normPath}`);
    if (!res.headersSent) {
      res.writeHead(504, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify({ error: 'gateway_timeout', detail: 'upstream_request_timeout' }));
    } else {
      res.destroy();
    }
    done();
  });

  proxyReq.on('error', (e) => {
    if (gateTimeout) return; // 客户端真断开/timeout 反发不当上游错处理 (gateTimeout 由 timeout 单独记)
    console.error(`[gate] upstream error: ${e.message} (${req.method} ${normPath})`);
    if (!res.headersSent) {
      res.writeHead(502, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify({ error: 'bad_gateway', detail: e.message }));
    } else {
      res.destroy();
    }
    done();
  });

  // ── 7. K3 根因修: 清理点迁到 res.on('close') ──
  // 响应真正结束或客户端真断开才释放并发槽 + 销毁上游。
  // v1/candidate 的 req.on('close') 在请求体被 pipe 消费完即触发 → 误杀上游 (12-24ms abort)。
  res.on('close', () => {
    if (!proxyReq.destroyed) proxyReq.destroy();
    done();
  });

  // ── 8. 转发 body (candidate 保留: 无 body 显式 end) ──
  if (req.readable && (req.headers['content-length'] || req.headers['transfer-encoding'])) {
    req.pipe(proxyReq);
  } else {
    req.resume();
    proxyReq.end();
  }
}).listen(GATE_PORT, '0.0.0.0', () => {
  // 不打印 PSK 长度 (避长度泄露缩爆破空间); timingSafeEqual 已防时序侧信道
  console.log(`[gate] :${GATE_PORT} → ${UPSTREAM_HOST}:${UPSTREAM_PORT} | ${RPM_LIMIT}rpm/${CONCURRENT_LIMIT}并发/${MIN_INTERVAL_MS}ms | timeout=${UPSTREAM_TIMEOUT_MS}ms | PSK=${PSK ? 'set' : 'unset'} OR_KEY=${OR_API_KEY ? 'set' : 'unset'} 后台=${ADMIN_ENABLED ? '开(ADMIN_TOKEN set)' : '关(默认404)'}`);
});

// ── 优雅关停 ──
process.on('SIGTERM', () => {
  console.log('[gate] SIGTERM received, exiting');
  process.exit(0);
});
