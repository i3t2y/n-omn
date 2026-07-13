// gate.js — v4.3 candidate (Stage D)
// OmniRoute PSK 出口 Proxy (HF Space :7860 -> 127.0.0.1:20128)
// 唯一出口代理, 经 OmniRoute 直连, 无外部 Relay / cf-worker / context-relay.
//
// 红线 2 (暴露面, 看管性改写——受后台开关约束):
//   默认 (GATE_ADMIN_TOKEN 未设/空/过短): 后台关闭, 外网仅 GET /healthz + /v1 + /v1/*; 其余 404.
//   设置有效 GATE_ADMIN_TOKEN: 后台白名单路径经 HTTP Basic Auth (admin/<token>) 放行;
//     白名单为 B3 v3.8.43 真实路由的最小权限保守子集, 非全量; 未验证路径恒 404, 不 allow-everything.
// 兼容: 保留原变量名 GATE_ADMIN_TOKEN (v8.0 后台鉴权变量, slim 删除前);
//   废弃 v8.0 "空 Token 内网直连不鉴权" 旧语义; 现: 空 Token = 后台关闭 (404).
// 三类入口分离: /healthz(免认证) | /v1,/v1/*(INTERNAL_PSK) | 后台白名单(GATE_ADMIN_TOKEN via Basic Auth).
//   互不回退, PSK 不访问后台, admin token 不访问 /v1.
// 后台认证仅外层入口保护, 不替代/OmniRoute 自身认证; Gate 不注入 Session, 不伪造 Cookie.
//   完成 Basic Auth 校验后, 删除/替换外层 Authorization 头, 不转发给上游 (防凭据泄露).
// 红线 (PSK/admin token): 缺失/格式错/长度不同/内容不同 → 401; crypto.timingSafeEqual 常量时间; 长度不等不退字符串比较.
// SSE: 逐块转发 (不聚合), 不 text/json 读流, 尊重背压, 客户端断开取消上游, 清理监听/定时器/流.
// 进程: SIGTERM/SIGINT 自处理优雅关 (entrypoint.sh trap 亦转发).
// 无第二套限流: 28 RPM/1 并发/2200ms 由 OmniRoute requestQueue 执行, 本文件零限流代码.
// IP/CIDR 限制: 不默认实现 (HF 代理拓扑未验证, 无 L1 证据 trust proxy); 预留能力默认关, KNOWN-UNVERIFIED 记.

const express = require('express');
const http = require('http');
const crypto = require('crypto');
const fs = require('fs');

const INTERNAL_PSK = process.env.INTERNAL_PSK || '';
const GATE_ADMIN_TOKEN = process.env.GATE_ADMIN_TOKEN || '';
const OR_PORT = parseInt(process.env.OMNIROUTE_PORT || '20128', 10);
const GATE_PORT = parseInt(process.env.EXPOSED_PORT || '7860', 10);
const UPSTREAM_TIMEOUT_MS = parseInt(process.env.GATE_UPSTREAM_TIMEOUT_MS || '30000', 10) || 30000;
const SHUTDOWN_GRACE_MS = parseInt(process.env.GATE_SHUTDOWN_GRACE_MS || '5000', 10) || 5000;
const ADMIN_TOKEN_MIN_LEN = 16;
const ADMIN_REALM = 'OmniRoute Admin';

// ── fail-closed: PSK 必须非空且最小长度 ──────────────────────
if (!INTERNAL_PSK || INTERNAL_PSK.length < 16) {
  console.error('[gate] FATAL: INTERNAL_PSK missing or <16 chars. HF Space Secret 必须配置。');
  process.exit(1);
}
let OR_API_KEY = (process.env.OMNIROUTE_API_KEY || '').trim();
if (!OR_API_KEY) {
  try { OR_API_KEY = fs.readFileSync('/data/.or-api-key', 'utf8').trim(); }
  catch (e) { if (e.code !== 'ENOENT') console.error('[gate] WARN read key failed:', e.message); }
}
if (!OR_API_KEY) {
  console.error('[gate] FATAL: No OR_API_KEY (env nor /data/.or-api-key).');
  process.exit(1);
}

// ── 后台开关 (单变量 GATE_ADMIN_TOKEN, 兼任开关 + 入口认证) ──
// 空/过短 → 后台关闭 (路径 404); 有效 → 后台白名单 + Basic Auth.
// 不记录/回显/转发 GATE_ADMIN_TOKEN.
const ADMIN_ENABLED = GATE_ADMIN_TOKEN.length >= ADMIN_TOKEN_MIN_LEN;
if (process.env.GATE_ADMIN_TOKEN && GATE_ADMIN_TOKEN.length < ADMIN_TOKEN_MIN_LEN) {
  console.error(`[gate] WARN: GATE_ADMIN_TOKEN 长度 <${ADMIN_TOKEN_MIN_LEN}, 后台关闭 (不记录 token 值).`);
}
console.log(`[gate] admin UI: ${ADMIN_ENABLED ? 'enabled' : 'disabled'} (开关状态可记, 不记 token).`);

// timing-safe equal: 双方 Buffer, 长度不等先返回不泄露内容, 长度相等路径走 timingSafeEqual.
function safeEqual(a, b) {
  if (!a || !b) return false;
  const ba = Buffer.from(a);
  const bb = Buffer.from(b);
  if (ba.length !== bb.length) return false;
  return crypto.timingSafeEqual(ba, bb);
}
// HTTP Basic Auth: user 固定 'admin', password = GATE_ADMIN_TOKEN. timing-safe 比密码.
function adminBasicAuthOk(req) {
  const header = req.headers.authorization || '';
  if (!header.startsWith('Basic ')) return false;
  let decoded;
  try { decoded = Buffer.from(header.slice('Basic '.length).trim(), 'base64').toString('utf8'); }
  catch (e) { return false; }          // base64 解码失败
  if (typeof decoded !== 'string' || decoded.indexOf(':') < 0) return false;
  const sep = decoded.indexOf(':');
  const user = decoded.slice(0, sep);
  const pass = decoded.slice(sep + 1);
  if (user !== 'admin') return false;
  return safeEqual(pass, GATE_ADMIN_TOKEN);   // timing-safe, 长度不等不退字符串比较
}

// ── 后台白名单 (B3 v3.8.43 真实路由最小权限保守子集, 源码 audit/06 ◆) ──
// 页面导航 (Next App Router 真实存在):
const ADMIN_PAGE_PREFIXES = [
  '/login', '/forgot-password', '/auth/callback', '/callback', '/authorize',
  '/connect', '/terms', '/privacy', '/docs', '/status', '/landing',
  '/home', '/dashboard',
];
// 页面允许方法 (GET 导航):
const ADMIN_PAGE_METHODS = ['GET'];
// 只读看板管理 API (B3 src/app/api 顶层只读子集; 排除 restart/shutdown/init/webhooks 等高风险写执行):
const ADMIN_API_ROUTES = [
  { pre: '/api/providers',          methods: ['GET'] },
  { pre: '/api/combos',             methods: ['GET'] },
  { pre: '/api/resilience',         methods: ['GET'] },
  { pre: '/api/keys',               methods: ['GET'] },
  { pre: '/api/provider-models',     methods: ['GET'] },
  { pre: '/api/models',             methods: ['GET'] },
  { pre: '/api/settings',           methods: ['GET'] },
  { pre: '/api/provider-stats',     methods: ['GET'] },
  { pre: '/api/provider-metrics',   methods: ['GET'] },
  { pre: '/api/sessions',           methods: ['GET'] },
  { pre: '/api/session-pools',      methods: ['GET'] },
  { pre: '/api/rate-limit',         methods: ['GET'] },
  { pre: '/api/rate-limits',        methods: ['GET'] },
  { pre: '/api/token-health',       methods: ['GET'] },
  { pre: '/api/synced-available-models', methods: ['GET'] },
  { pre: '/api/free-models',        methods: ['GET'] },
  { pre: '/api/free-provider-rankings', methods: ['GET'] },
  { pre: '/api/tags',               methods: ['GET'] },
];

function isStaticAssetPath(p) {
  if (p.startsWith('/_next/')) return true;
  return /^\/(favicon\.ico|favicon\.svg|apple-touch-icon\.(png|svg)|icon-192\.svg|icon-512\.png|sw\.js|openapi\.yaml)/.test(p);
}
function isAdminPagePath(p) {
  if (p === '/') return true;
  if (isStaticAssetPath(p)) return true;
  return ADMIN_PAGE_PREFIXES.some(pre => p === pre || p.startsWith(pre + '/') || p.startsWith(pre));
}
function apiRouteMatch(p, method) {
  for (const r of ADMIN_API_ROUTES) {
    if (p === r.pre || p.startsWith(r.pre + '/')) {
      return r.methods.includes(method);
    }
  }
  return false;
}

// ── 结构化诊断日志 (gate 出口 proxy 错误/abort) ──
//   一行 JSON stderr (HF Space 抓取): requestId/path/method/upstream/elapsedMs/httpStatus/errorCode/abortSource/destroyInitiator
//   abortSource 区分: 'upstream_error' (上游真错) / 'client_close' (客户端断开反发) / 'timeout' (gate 30s 超时) / 'shutdown'
//   destroyInitiator: 'gate_timeout' / 'client' / 'upstream' / 'null' (无主动 destroy)
//   不打印 headers/PSK/token/body (脱敏). 仅 path+method+errorCode (无敏感).
function genReqId() {
  try { return crypto.randomBytes(8).toString('hex'); } catch { return 'rid_unknown'; }
}
function logGate(req, fields) {
  try {
    const v = (n) => (typeof n === 'number' || typeof n === 'string') ? n : null;
    const line = JSON.stringify({
      ts: Date.now(),
      level: 'error',
      component: 'gate',
      stage: 'upstream_proxy',
      requestId: req?._gateReqId || null,
      method: req?.method || null,
      path: req?._normPath || null,
      upstream_path: req?._upstreamPath || null,
      upstream_target: `127.0.0.1:${OR_PORT}`,
      elapsedMs: v(fields.elapsedMs),
      httpStatus: v(fields.httpStatus),
      errorCode: fields.errorCode || null,
      abortSource: fields.abortSource || null,
      socketPhase: fields.socketPhase || null,
      destroyInitiator: fields.destroyInitiator || null,
      msg: fields.msg || null,
    });
    process.stderr.write(line + '\n');
  } catch { /* never throw from logger */ }
}

// abort source 区分: 从上游 error 事件 + 标记位判断谁发起 destroy
//   gateTimeout=true → 'timeout'; clientAborted=true → 'client_close'; shuttingDown → 'shutdown';
//   ECONNRESET + elapsedMs<5000 → 'upstream_reset' (短时窗 socket reset, 候选 stale pooled socket);
//   else 'upstream_error'.
//   timeout/client_close/shutdown 三类判断逻辑不变 (task#23 仅增 upstream_reset 兜底前).
function classifyAbortSource(e, { gateTimeout, clientAborted, elapsedMs } = {}) {
  if (gateTimeout) return 'timeout';
  if (clientAborted) return 'client_close';
  if (shuttingDown) return 'shutdown';
  if (e?.code === 'ECONNRESET' && typeof elapsedMs === 'number' && elapsedMs < 5000) {
    return 'upstream_reset';
  }
  return 'upstream_error';
}

// HTTP status 映射: ECONNREFUSED/ECONNRESET=503 (upstream unavailable/rest),
//   timeout/ETIMEDOUT/ESOCKETTIMEDOUT=504 (gateway_timeout), 其余=502 (bad_gateway)
function mapUpstreamStatus(e, { gateTimeout } = {}) {
  if (gateTimeout || e?.code === 'ETIMEDOUT' || e?.code === 'ESOCKETTIMEDOUT') return 504;
  if (e?.code === 'ECONNREFUSED' || e?.code === 'ECONNRESET') return 503;
  return 502;
}
function statusErrorLabel(code) {
  return code === 504 ? 'gateway_timeout'
    : code === 503 ? 'service_unavailable'
    : 'bad_gateway';
}

const app = express();
let shuttingDown = false;

// 注入 requestId + 开始时间 (per-request, 在路径规整化中间件后可用 _normPath)
app.use((req, res, next) => {
  req._gateReqId = genReqId();
  req._gateT0 = Date.now();
  next();
});

// ── /healthz: 免认证探活 ─────────────────────────────────
app.get('/healthz', async (req, res) => {
  if (shuttingDown) return res.status(503).json({ ok: false });
  let r;
  try {
    r = await fetch(`http://127.0.0.1:${OR_PORT}/api/monitoring/health`, {
      signal: AbortSignal.timeout(2000),
    });
  } catch (e) {
    return res.status(503).json({ ok: false });
  }
  r?.ok ? res.json({ ok: true }) : res.status(503).json({ ok: false });
});

// 路径规整化: 解 dot-segment, 重复斜杠, 尾斜杠 (防绕过白名单匹配)
function normalizePath(p) {
  try {
    const u = new URL(p, 'http://x');
    let n = u.pathname.replace(/\/+/g, '/').replace(/\/$/, '');
    if (n === '') n = '/';
    return n;
  } catch (e) {
    return p;
  }
}

// ── 暴露面白名单 (默认仅 /healthz + /v1; 管理白名单仅 token 有效时) ──
//   非 /healthz / 非 /v1: 须 ADMIN_ENABLED 且路径在白名单 (页/api/静态), 否则 404.
//   后台关闭时即使带 OmniRoute Cookie/Session 也 404 (不泄露后台是否存在).
app.use((req, res, next) => {
  req._normPath = normalizePath(req.path);
  if (shuttingDown && req._normPath !== '/healthz') return res.status(503).json({ ok: false });
  if (req._normPath === '/healthz') return next();
  if (req._normPath === '/v1' || req._normPath.startsWith('/v1/')) return next();
  // 后台
  if (!ADMIN_ENABLED) return res.status(404).end();
  const p = req._normPath;
  // 静态资源 (开关开后免 Basic Auth, 仍须白名单)
  if (isAdminPagePath(p)) {
    if (isStaticAssetPath(p)) return next();   // 静态免 token, 仅须开关开
    // 页面导航须 method GET + Basic Auth (后中间件)
    if (ADMIN_PAGE_METHODS.includes(req.method)) return next();
    return res.status(405).json({ error: 'method_not_allowed' });
  }
  if (apiRouteMatch(p, req.method)) return next();
  if (apiRouteMatch(p, 'GET') && req.method !== 'GET') {
    return res.status(405).json({ error: 'method_not_allowed' });
  }
  return res.status(404).end();   // 非白名单 + 未知 → 404, 开启用时仍 404
});

// ── 后台页 + api Basic Auth (静态免) ──
//   通过后删除 Authorization 头 (不转发 Basic 给上游 OmniRoute, 防凭据泄露).
app.use((req, res, next) => {
  if (req._normPath === '/healthz' || req._normPath === '/v1' || req._normPath.startsWith('/v1/')) return next();
  if (!ADMIN_ENABLED) return next();   // 后台关 (已在白名单中间件 404, 此处不到)
  const p = req._normPath;
  if (isStaticAssetPath(p)) return next();   // 静态免 token
  if (!isAdminPagePath(p) && !apiRouteMatch(p, req.method)) return next();   // 非白名单 (已 404, 不到)
  if (!adminBasicAuthOk(req)) {
    res.setHeader('WWW-Authenticate', `Basic realm="${ADMIN_REALM}", charset="UTF-8"`);
    return res.status(401).json({ error: 'unauthorized' });
  }
  delete req.headers.authorization;   // 不转发 Basic 给上游; OmniRoute 自身认证照走 (Cookie/Session)
  next();
});

// ── /v1 PSK 校验: Internal PSK timing-safe ──
app.use('/v1', (req, res, next) => {
  const auth = req.headers.authorization || '';
  if (!auth.startsWith('Bearer ')) {
    return res.status(401).json({ error: 'unauthorized' });
  }
  const bearer = auth.slice('Bearer '.length).trim();
  if (!safeEqual(bearer, INTERNAL_PSK)) {
    return res.status(401).json({ error: 'unauthorized' });
  }
  req.headers.authorization = `Bearer ${OR_API_KEY}`;   // /v1 转发用 OR_API_KEY
  next();
});

// ── SSE 透传代理: 手写 http, 逐块 pipe, 客户端断开 abort 上游 ─
function proxyV1(req, res) {
  // app.use('/v1', ...) mount 下 req.path 被 Express strip '/v1' 前缀; 用 originalUrl 保完整 (含 query).
  const upstreamPath = req.originalUrl;
  const headers = { ...req.headers };
  delete headers.host;
  headers.host = `127.0.0.1:${OR_PORT}`;

  const upstreamReq = http.request({
    host: '127.0.0.1',
    port: OR_PORT,
    method: req.method,
    path: upstreamPath,
    headers,
    timeout: UPSTREAM_TIMEOUT_MS,
  }, (upstreamRes) => {
    req._socketPhase = 'streaming';   // 已收 response head → 进入流相 (含 SSE 逐块)
    res.writeHead(upstreamRes.statusCode, upstreamRes.headers);
    upstreamRes.on('data', (chunk) => {
      if (!res.write(chunk)) {
        upstreamRes.pause();
        res.once('drain', () => upstreamRes.resume());
      }
    });
    upstreamRes.on('end', () => { if (!res.writableEnded) res.end(); });
    upstreamRes.on('error', (e) => {
      // 上游响应流中途错 (已 head, 非 connect 错): fallback 502 + 结构化日志
      // task#23: 复用 classifyAbortSource (非硬码 'upstream_error'); 流相 elapsedMs 多 >5000 → 落 upstream_error
      const elapsedMs = Date.now() - (req._gateT0 || 0);
      const abortSource = classifyAbortSource(e, { gateTimeout, clientAborted, elapsedMs });
      logGate(req, { elapsedMs, httpStatus: 502,
        errorCode: e?.code || e?.message || 'upstream_response_stream_error',
        abortSource, socketPhase: req._socketPhase || 'streaming',
        destroyInitiator: 'upstream', msg: 'upstream_response_stream_error' });
      if (!res.headersSent) res.status(502).json({ error: 'bad_gateway', abort_source: abortSource });
      else if (!res.writableEnded) res.end();
    });
  });

  // socketPhase 跟踪: connecting → headers → streaming (供 upstream_reset/upstream_error 日志区分断在哪相)
  req._socketPhase = 'connecting';
  upstreamReq.on('socket', (socket) => {
    socket.on('connect', () => { if (req._socketPhase === 'connecting') req._socketPhase = 'headers'; });
  });

  // abort source tracking: 区分 client 断开 vs gate 超时 vs upstream 真错
  let aborted = false;
  let gateTimeout = false;   // gate 主动超时 destroy
  let clientAborted = false; // 客户端断开触发 cleanup
  let firstError = null;      // 首个上游 error (后续 destroy 反发不覆盖)
  function cleanup() {
    if (aborted) return;
    aborted = true;
    if (upstreamReq) {
      // 仅在 client 断开机上标记 (timeout handler 自己标记, 避免误判)
      if (!gateTimeout) { clientAborted = true; upstreamReq.destroy(); }
    }
    res.removeAllListeners('drain');
  }
  req.on('error', () => { clientAborted = true; cleanup(); });
  req.on('aborted', () => { clientAborted = true; cleanup(); });
  req.on('close', () => { clientAborted = true; cleanup(); });

  upstreamReq.on('timeout', () => {
    gateTimeout = true;
    upstreamReq.destroy(new Error('upstream_timeout'));
    const code = 504;
    logGate(req, { elapsedMs: Date.now() - (req._gateT0 || 0), httpStatus: code, errorCode: 'ETIMEDOUT',
      abortSource: 'timeout', destroyInitiator: 'gate_timeout', msg: 'upstream_request_timeout' });
    if (!res.headersSent) res.status(code).json({ error: statusErrorLabel(code), abort_source: 'timeout' });
    else if (!res.writableEnded) res.end();
  });
  upstreamReq.on('error', (e) => {
    // 首个 error 仅记一次 (后续 destroy 同事件反发不覆盖诊断)
    if (!firstError) firstError = e;
    // abort source 区分: client 已断开 + 这是 cleanup 反发的 destroy → client_close (不响应, client 已走)
    const elapsedMs = Date.now() - (req._gateT0 || 0);
    const abortSource = classifyAbortSource(e, { gateTimeout, clientAborted, elapsedMs });
    const code = clientAborted ? null : mapUpstreamStatus(e, { gateTimeout });
    // 不打 504 重复日志 (timeout handler 已打)
    if (!gateTimeout) {
      // socketPhase 仅附加于 upstream_reset/upstream_error (timeout/client_close/shutdown 不附, 非其语义)
      const phase = (abortSource === 'upstream_reset' || abortSource === 'upstream_error')
        ? (req._socketPhase || null) : null;
      logGate(req, {
        elapsedMs,
        httpStatus: code,
        errorCode: e?.code || e?.message || 'unknown_error',
        abortSource,
        socketPhase: phase,
        destroyInitiator: clientAborted ? 'client' : (gateTimeout ? 'gate_timeout' : 'upstream'),
        msg: abortSource === 'client_close' ? 'client_disconnected_proxy_aborted'
          : abortSource === 'shutdown' ? 'gate_shutting_down'
          : abortSource === 'upstream_reset' ? 'upstream_socket_reset_short_lived'
          : 'upstream_error',
      });
    }
    // client 断开: client 已不可达, 不再写 res (headersSent与否都直接 end)
    if (clientAborted) {
      if (!res.writableEnded) { try { res.end(); } catch {} }
      return;
    }
    if (!res.headersSent && code) {
      res.status(code).json({ error: statusErrorLabel(code), abort_source: abortSource });
    } else if (!res.writableEnded) {
      res.end();
    }
  });

  // 转发 body: 有 body 用 pipe 自动 end; 无 body (GET/OPTIONS) 须显式 end 发请求 (req 在 Express 已 end
  // 但 pipe 不一定触发 destination end; 显式收尾确保上游收到完整请求).
  if (req.readable && (req.headers['content-length'] || req.headers['transfer-encoding'])) {
    req.pipe(upstreamReq);
  } else {
    upstreamReq.end();
  }
}

app.use('/v1', (req, res) => proxyV1(req, res));

// 后台页 + api 转发 (经 Basic Auth + Authorization 已删); /v1 已各别处理
function proxyAdmin(req, res) {
  const qIdx = req.url.indexOf('?');
  const qs = qIdx >= 0 ? req.url.slice(qIdx) : '';
  const upstreamPath = req.path + qs;
  const headers = { ...req.headers };
  delete headers.host;
  headers.host = `127.0.0.1:${OR_PORT}`;
  // Authorization 已在 Basic Auth 中间件 delete; OmniRoute 自身认证 (Cookie/Session) 原样上行.

  const upstreamReq = http.request({
    host: '127.0.0.1',
    port: OR_PORT,
    method: req.method,
    path: upstreamPath,
    headers,
    timeout: UPSTREAM_TIMEOUT_MS,
  }, (upstreamRes) => {
    res.writeHead(upstreamRes.statusCode, upstreamRes.headers);
    upstreamRes.on('data', (chunk) => {
      if (!res.write(chunk)) {
        upstreamRes.pause();
        res.once('drain', () => upstreamRes.resume());
      }
    });
    upstreamRes.on('end', () => { if (!res.writableEnded) res.end(); });
    upstreamRes.on('error', (e) => {
      // 上游响应流中途错 (非 connect 错): 已 head, fallback 502 + 结构化日志
      logGate(req, { elapsedMs: Date.now() - (req._gateT0 || 0), httpStatus: 502,
        errorCode: e?.code || e?.message || 'upstream_response_stream_error',
        abortSource: 'upstream_error', destroyInitiator: 'upstream', msg: 'upstream_response_stream_error' });
      if (!res.headersSent) res.status(502).json({ error: 'bad_gateway', abort_source: 'upstream_error' });
      else if (!res.writableEnded) res.end();
    });
  });
  // abort source tracking (同 proxyV1): 区分 client 断开 vs gate 超时 vs upstream 真错
  let aborted = false;
  let gateTimeout = false;
  let clientAborted = false;
  let firstError = null;
  function cleanup() {
    if (aborted) return;
    aborted = true;
    if (upstreamReq) {
      if (!gateTimeout) { clientAborted = true; upstreamReq.destroy(); }
    }
    res.removeAllListeners('drain');
  }
  req.on('error', () => { clientAborted = true; cleanup(); });
  req.on('aborted', () => { clientAborted = true; cleanup(); });
  req.on('close', () => { clientAborted = true; cleanup(); });
  upstreamReq.on('timeout', () => {
    gateTimeout = true;
    upstreamReq.destroy(new Error('upstream_timeout'));
    const code = 504;
    logGate(req, { elapsedMs: Date.now() - (req._gateT0 || 0), httpStatus: code, errorCode: 'ETIMEDOUT',
      abortSource: 'timeout', destroyInitiator: 'gate_timeout', msg: 'admin_upstream_request_timeout' });
    if (!res.headersSent) res.status(code).json({ error: statusErrorLabel(code), abort_source: 'timeout' });
    else if (!res.writableEnded) res.end();
  });
  upstreamReq.on('error', (e) => {
    if (!firstError) firstError = e;
    const abortSource = classifyAbortSource(e, { gateTimeout, clientAborted });
    const code = clientAborted ? null : mapUpstreamStatus(e, { gateTimeout });
    if (!gateTimeout) {
      logGate(req, {
        elapsedMs: Date.now() - (req._gateT0 || 0),
        httpStatus: code,
        errorCode: e?.code || e?.message || 'unknown_error',
        abortSource,
        destroyInitiator: clientAborted ? 'client' : (gateTimeout ? 'gate_timeout' : 'upstream'),
        msg: abortSource === 'client_close' ? 'admin_client_disconnected_proxy_aborted'
          : abortSource === 'shutdown' ? 'gate_shutting_down' : 'admin_upstream_error',
      });
    }
    if (clientAborted) {
      if (!res.writableEnded) { try { res.end(); } catch {} }
      return;
    }
    if (!res.headersSent && code) {
      res.status(code).json({ error: statusErrorLabel(code), abort_source: abortSource });
    } else if (!res.writableEnded) {
      res.end();
    }
  });
  // 转发 body: 有 body 用 pipe 自动 end; 无 body (GET/OPTIONS) 须显式 end 发请求 (req 在 Express 已 end
  // 但 pipe 不一定触发 destination end; 显式收尾确保上游收到完整请求).
  if (req.readable && (req.headers['content-length'] || req.headers['transfer-encoding'])) {
    req.pipe(upstreamReq);
  } else {
    upstreamReq.end();
  }
}
// catch-all: 白名单已过中间件的 (后台页/api 非 /v1) → proxyAdmin; /v1 已前处理
app.use((req, res) => {
  if (req._normPath === '/healthz') return res.status(502).json({ error: 'bad_gateway' });  // /healthz 后端挂
  if (req._normPath === '/v1' || req._normPath.startsWith('/v1/')) return proxyV1(req, res);
  // 后台 (白名单已过 + Basic Auth 已过)
  return proxyAdmin(req, res);
});

const server = app.listen(GATE_PORT, '0.0.0.0', () => {
  const actualPort = server.address().port;   // GATE_PORT=0 (test/random) 时取实际监听端口; 生产 7860 同值
  console.log(`[gate] listening on 0.0.0.0:${actualPort} -> 127.0.0.1:${OR_PORT}`);
});

function shutdown(sig) {
  if (shuttingDown) return;
  shuttingDown = true;
  console.log(`[gate] received ${sig}, shutting down (grace ${SHUTDOWN_GRACE_MS}ms)...`);
  server.close(() => { process.exit(0); });
  setTimeout(() => {
    console.error('[gate] forced exit after grace.');
    process.exit(1);
  }, SHUTDOWN_GRACE_MS).unref();
}
process.on('SIGTERM', () => shutdown('SIGTERM'));
process.on('SIGINT', () => shutdown('SIGINT'));
