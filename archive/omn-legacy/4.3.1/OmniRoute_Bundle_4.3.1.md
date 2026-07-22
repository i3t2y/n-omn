# OmniRoute Project Source Archive (4.3.1)
> 归档版本: 4.3.1 | 生成时间: 2026-07-22 11:45:16

## 文件: Dockerfile
``dockerfile
# ── 基础镜像：钉死到验证过健康的 3.8.43，禁止浮动 latest ──────────
# 根因：latest 会漂到 3.8.46（默认 Turbopack 构建 + migration 117 表重建），
#       导致 Next 服务进程静默无法 ready，entrypoint 健康等待空转卡在 starting。
# 拿 digest：docker pull diegosouzapw/omniroute:3.8.43
#           docker inspect --format='{{index .RepoDigests 0}}' diegosouzapw/omniroute:3.8.43
# 用 tag+digest 双写：digest 保证不可变，tag 便于人读。
FROM diegosouzapw/omniroute:3.8.43@sha256:517c160643c56ad72e3e305458d961c9a4c87f711393c13020450f9f088d1570

ENV OMNIROUTE_PORT=20128
ENV EXPOSED_PORT=7860
ENV DATA_DIR=/data
# ── 后台访问开关 (v4.3): GATE_ADMIN_TOKEN 空即关闭后台 (默认不设); 设强随机 token 开启后台并可 Basic Auth ──
# 注意: 设此变量会扩大公网暴露面 (后台白名单), 后台仍受 OmniRoute 自身认证约束. 不设 IP 限制 (HF 代理拓扑未验证).
# ENV GATE_ADMIN_TOKEN=

# ── 跨版本防御 env（3.8.43 无害；若将来误漂到新版可避免静默 hang）──
# Turbopack 逃生阀：强制走 webpack，绕开 3.8.45+ 的 Docker Turbopack 缓存 mmap 失败
ENV OMNIROUTE_USE_TURBOPACK=0
# 迁移安全阀：从旧库补多个 migration（含 117 表重建）时不触发 abort 刷屏中断
ENV OMNIROUTE_MAX_PENDING_MIGRATIONS=0

USER root

RUN apt-get update && apt-get install -y --no-install-recommends \
    curl \
    jq \
    python3 \
    python3-pip \
    sqlite3 \
    ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# ── huggingface_hub（HF Dataset 配置快照上传）──────────────────────
RUN pip3 install --no-cache-dir --break-system-packages huggingface_hub

# ── Litestream v0.5.9（修复 R2 InvalidContentEncoding + auto-recover）──
# asset 命名：litestream-{VER}-linux-{ARCH}.tar.gz（无 v 前缀，x86_64 非 amd64）
ARG LITESTREAM_VERSION=0.5.9
RUN ARCH=$(uname -m | sed 's/aarch64/arm64/') && \
    curl -fsSL \
      "https://github.com/benbjohnson/litestream/releases/download/v${LITESTREAM_VERSION}/litestream-${LITESTREAM_VERSION}-linux-${ARCH}.tar.gz" \
    | tar -xz -C /usr/local/bin litestream && \
    chmod +x /usr/local/bin/litestream && \
    litestream version

RUN mkdir -p /data && chmod 777 /data
RUN rm -rf /app/data && ln -sf /data /app/data

RUN mkdir -p /gate
COPY package.json /gate/package.json
COPY gate.js /gate/gate.js
RUN cd /gate && npm install --omit=dev --silent

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

COPY init-nim-keys.sh /entrypoint-init-nim.sh
RUN chmod +x /entrypoint-init-nim.sh

COPY litestream.yml /litestream.yml

EXPOSE 7860

# ── 容器级健康检查：start-period 与 entrypoint 内部 180s 等待对齐 ──
HEALTHCHECK --interval=30s --timeout=10s --start-period=180s --retries=3 \
    CMD curl -sf http://127.0.0.1:7860/healthz || exit 1

ENTRYPOINT ["/entrypoint.sh"]

``

## 文件: gate.js
``javascript
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

``

## 文件: init-nim-keys.sh
``bash
#!/bin/bash
set -eo pipefail

# ─────────────────────────────────────────────────────────────
# NIM OmniRoute initializer  v4.3.1（基于 v4.3）
#
# 【v4.3.1 修正】jq shape 死点根治 + set -e 猝死面收敛 (2026-07-22):
#   A. upsert_combo: GET /api/combos 响应 shape 归一 (bare array / .combos / .data / .items)
#      + objects 过滤 (数组值永不进 select(.name)) — 根治 `jq: Cannot index array with string "name"`
#      (触发条件: 响应为 {"combos":[]} 或 {"data":[...]} 包裹 shape 时,
#       旧式 `.combos[]? // .[]?` 回退分支把顶层数组值喂给 .name — 生产 restore 库首跑实证死亡点);
#   B. CID 单值输出 [0]//empty, 移除 `| head -n1` — 根治多命中时 jq SIGPIPE 141 (pipefail 猝死);
#   C. upsert GET transport-error → fail-closed return 1 (不盲 POST 防重复建);
#      写操作非 2xx → return 1 (对齐纪律: upsert 失败 fail-closed, 不静默跳过);
#   D. filter_alive 空数组不再输出空行 — 根治 POOL_ALIVE=("" ) 伪成员 → "nvidia/" 幽灵模型;
#   E. hf_snapshot 全段容错: export/解析/上传失败 → WARN 跳过 (快照=观测面, 不杀死尾段 init);
#   F. Compression PUT / CB reset / touch marker / register_model 加 transport 容错 (WARN 继续),
#      防 set -e 无签名猝死;
#   G. login/keys/providers/settings 等全部 VAR=$(curl) 加 `|| echo "000"` 护栏;
#   H. _first_key 改用 read 内建 (免 printf|head 竞争); nim-deprecated.txt 缺失兜底;
#   I. check_nim_model_health id 提取归一 (_nim_models_ids: object.data / bare array 双 shape + objects 过滤);
#   J. hf_snapshot 入口条件显式 if (消除 `[ ] || [ ] &&` 优先级脆弱写法).
#   行为不变: 限流 28/1/2200、pool=p2c/codex=priority、TIER 分档、①-⑨ 特性全部继承.
#
# 相对 v4.2.2 的变更（v4.3 继承）：
#   【v4.3·⑨ 】DEBUG log 上传 Dataset: 默认**关闭** (NIM_DEBUG_LOG_TO_DATASET=1 开启);
#              开启时上传前字段级脱敏 Authorization/NIM_KEY/Cookie/Set-Cookie (红线1 动态);
#              本地仅留最近 NIM_DEBUG_LOG_KEEP(默认5) 个.
# 继承 v4.2.2：⑦ 幂等 upsert_combo ⑧ 增量门放宽（任一 nim-* combo 或 INIT_MARKER）。
# 继承 v4.2.1：① 移除 quota-share/主池 p2c+白名单 ② nim-codex 响应体打印
#              ⑤ 增量只清过期熔断 ⑥ context_recommendations 累积推荐（被动观测）。
# ─────────────────────────────────────────────────────────────

# ══ 单变量调试 + 日志归档（stdout 实时 tee；DEBUG 时另上传 Dataset，见⑨）═══════
NIM_MODE="${NIM_MODE:-NORMAL}"
LOG_DIR="/data/omni-data/log"
if [ "$NIM_MODE" = "DEBUG" ]; then
  mkdir -p "$LOG_DIR" 2>/dev/null || true
  INIT_LOG="$LOG_DIR/init_$(date +%Y%m%d_%H%M%S).log"
  exec > >(tee -a "$INIT_LOG") 2>&1
  echo "[init] 🛠️ NIM_MODE=DEBUG：日志 tee -> $INIT_LOG（仅容器内，随 Space 日志可见，不入 Dataset）"
  export APP_LOG_TO_FILE=true
  export DISABLE_SQLITE_AUTO_BACKUP=true
else
  LOG_DIR="/tmp"
fi
_resp() { echo "$LOG_DIR/$1"; }

# ── 强制关闭代理生态 ──────────────────────────────────────────
export ONEPROXY_ENABLED=false
export ENABLE_SOCKS5_PROXY=false
export NEXT_PUBLIC_ENABLE_SOCKS5_PROXY=false
unset HTTP_PROXY HTTPS_PROXY ALL_PROXY http_proxy https_proxy all_proxy 2>/dev/null || true
unset OMNIROUTE_RELAY_BACKEND BIFROST_BASE_URL 2>/dev/null || true

# ── 端口配置 ──────────────────────────────────────────────────
[ -z "$OMNIROUTE_PORT" ] && OMNIROUTE_PORT=20128
BASE_URL="http://127.0.0.1:$OMNIROUTE_PORT"
INIT_MARKER="/data/.init-done"
OR_API_KEY_FILE="/data/.or-api-key"
COOKIE_FILE="/tmp/omniroute-cookie.txt"

LOGIN_RESP_FILE="$(_resp omniroute-login.json)"
KEY_RESP_FILE="$(_resp omniroute-key-response.json)"
PROVIDERS_FILE="$(_resp omniroute-providers.json)"
RESILIENCE_RESP_FILE="$(_resp omniroute-resilience.json)"
SETTINGS_RESP_FILE="$(_resp omniroute-settings.json)"
COMPRESS_RESP_FILE="$(_resp omniroute-compress.json)"
COMBO_RESP_FILE="$(_resp omniroute-combo.json)"
VERSION_FILE="$(_resp omniroute-version.json)"

REGISTERED=0; SKIPPED=0; FAILED=0

# ══ 模型分档 SSOT（对齐现行 NVIDIA 目录）═══════════════════════
TIER_FAST=(
  "z-ai/glm-5.2"
  "deepseek-ai/deepseek-v4-flash"
  "deepseek-ai/deepseek-v4-pro"
  "meta/llama-3.3-70b-instruct"
)
TIER_STABLE=(
  "nvidia/nemotron-3-super-120b-a12b"
  "openai/gpt-oss-120b"
  "qwen/qwen3.5-397b-a17b"
  "mistralai/mistral-small-4-119b-2603"
  "google/gemma-4-31b-it"
)
TIER_RESTRICTED=(
  "moonshotai/kimi-k2.6"
  "minimaxai/minimax-m2.7"
  "mistralai/mistral-large-3-675b-instruct-2512"
)

_PROFILE="${NIM_PROFILE:-balanced}"
case "$_PROFILE" in
  fast)     NIM_POOL_MODELS=("${TIER_FAST[@]}") ;;
  full)     NIM_POOL_MODELS=("${TIER_FAST[@]}" "${TIER_STABLE[@]}" "${TIER_RESTRICTED[@]}") ;;
  *)        _PROFILE="balanced"; NIM_POOL_MODELS=("${TIER_FAST[@]}" "${TIER_STABLE[@]}") ;;
esac
echo "[init] NIM_PROFILE=$_PROFILE -> pool 意向 ${#NIM_POOL_MODELS[@]} 个模型"

NIM_CODEX_MODELS=(
  "deepseek-ai/deepseek-v4-pro"
  "openai/gpt-oss-120b"
  "z-ai/glm-5.2"
)
NIM_FAST_MODELS=(
  "deepseek-ai/deepseek-v4-flash"
  "meta/llama-3.3-70b-instruct"
  "google/gemma-4-31b-it"
)
NIM_EXTRA_MODELS=( "deepseek-ai/deepseek-v4-flash" )

build_all_models() {
  printf '%s\n' "${NIM_POOL_MODELS[@]}" "${NIM_CODEX_MODELS[@]}" "${NIM_EXTRA_MODELS[@]}" | awk '!seen[$0]++'
}
models_to_json() { printf '%s\n' "$@" | sed 's/^/nvidia\//' | jq -R '{model: .}' | jq -s -c .; }

# ══ combo 策略白名单（3.8.43 实测合法枚举，不含 quota-share）═════
_VALID_STRATS="priority weighted round-robin fill-first p2c random least-used cost-optimized reset-aware reset-window headroom strict-random auto lkgp context-optimized fusion"
# v4.3: 删 context-relay (CF-1/红线: NIM 永不用 context-relay; cf-worker 已删, 无外部 Relay 层); 保留 fusion (Codex 池可用).
_is_valid_strat() { printf '%s' "$_VALID_STRATS" | grep -qw -- "$1"; }

# ══ 【⑦ 】幂等 upsert：存在则 PUT，不存在才 POST ═══════════════
# v4.3.1·A/B/C 重写 GET+CID 提取, 写失败 fail-closed.
upsert_combo() {
  local NAME="$1" STRAT="$2"; shift 2; local MODELS=("$@")
  _is_valid_strat "$STRAT" || { echo "[init] upsert_combo: '$STRAT' 非法 -> round-robin"; STRAT="round-robin"; }
  # v4.3.1·D: 清洗空串成员 (防 filter_alive 历史空行 bug 产生 "nvidia/" 幽灵模型)
  local _CLEAN=() _m
  for _m in "${MODELS[@]}"; do [ -n "$_m" ] && _CLEAN+=("$_m"); done
  if [ "${#_CLEAN[@]}" -gt 0 ]; then MODELS=("${_CLEAN[@]}"); else MODELS=(); fi
  [ "${#MODELS[@]}" -eq 0 ] && { echo "[init] upsert_combo: $NAME 无存活模型，跳过。"; return 0; }
  local BODY CID CODE F LIST
  BODY=$(jq -n --arg name "$NAME" --arg strat "$STRAT" \
               --argjson models "$(models_to_json "${MODELS[@]}")" \
               '{name:$name, strategy:$strat, models:$models}')
  # v4.3.1·C: GET transport-error → fail-closed (不盲 POST 防重复建)
  if ! LIST=$(curl -s --connect-timeout 5 --max-time 20 -b "$COOKIE_FILE" "$BASE_URL/api/combos" 2>/dev/null); then
    echo "[init] ✗ upsert $NAME: GET /api/combos transport-error → fail-closed (不盲 POST). init 失败." >&2
    return 1
  fi
  # v4.3.1·A: shape 归一 (bare array / .combos / .data / .items) + objects 过滤
  #   (数组值永不进 select(.name), 根治 "Cannot index array with string");
  # v4.3.1·B: [0]//empty 单值输出, 无 `| head -n1` (根治多命中 SIGPIPE 141).
  CID=$(printf '%s' "$LIST" | jq -r --arg n "$NAME" '
    (if type=="array" then .
     elif type=="object" then
       if   (.combos|type)=="array" then .combos
       elif (.data|type)=="array"   then .data
       elif (.items|type)=="array"  then .items
       else [] end
     else [] end)
    | [.[] | objects | select((.name // "") == $n) | .id // empty][0] // empty
  ' 2>/dev/null || true)
  F="$(_resp omniroute-combo-$NAME.json)"
  if [ -n "$CID" ]; then
    CODE=$(curl -s -o "$F" -w "%{http_code}" --connect-timeout 5 --max-time 20 -b "$COOKIE_FILE" \
      -X PUT "$BASE_URL/api/combos/$CID" -H "Content-Type: application/json" -d "$BODY" 2>/dev/null || echo "000")
    echo "[init] upsert $NAME: existed -> PUT combos/$CID HTTP $CODE"
  else
    CODE=$(curl -s -o "$F" -w "%{http_code}" --connect-timeout 5 --max-time 20 -b "$COOKIE_FILE" \
      -X POST "$BASE_URL/api/combos" -H "Content-Type: application/json" -d "$BODY" 2>/dev/null || echo "000")
    echo "[init] upsert $NAME: new -> POST HTTP $CODE"
  fi
  # v4.3.1·C: 写非 2xx → fail-closed (响应体落日志, 不静默跳过)
  if [ "$CODE" != "200" ] && [ "$CODE" != "201" ]; then
    echo "[init] ✗ upsert $NAME 失败 HTTP $CODE: $(head -c 500 "$F" 2>/dev/null)" >&2
    echo "[init]   fail-closed: combo 是运行关键路径. init 失败." >&2
    return 1
  fi
  return 0
}

# ══ 按存活 Key 数动态推导 RPM/并发 ═════════════════════════════
_count_alive_keys() { printf '%s\n' "$NIM_KEYS" | sed '/^[[:space:]]*$/d' | wc -l; }
_ALIVE_KEYS=$(_count_alive_keys)
# v4.3: 限流固定值 (G3 解: 限流仅 OmniRoute requestQueue 执行, 非线性扩; M26 REJECT 按 Key 线性).
# 候选固定 28 RPM / 1 并发 / 2200ms, 写 requestQueue; Gate 不重复限流 (gate.js 零限流代码).
_PER_KEY_RPM=${NIM_PER_KEY_RPM:-35}   # 单 Key 上限 (仅诊断用, 不入 requestQueue.RPM 算式)
_RPM=${NIM_FIXED_RPM:-28}              # 固定 28 RPM (G3)
_CONCURRENT=${NIM_FIXED_CONCURRENT:-1} # 固定 1 并发 (G3)
_MIN_INTERVAL_MS=${NIM_FIXED_MIN_INTERVAL_MS:-2200}   # 固定 2200ms (G3)
echo "[init] 固定限流 RPM=$_RPM concurrent=$_CONCURRENT interval=${_MIN_INTERVAL_MS}ms (alive_keys=$_ALIVE_KEYS 仅诊断)"

if [ "$_ALIVE_KEYS" -gt 1 ]; then
  _POOL_STRATEGY="${NIM_POOL_STRATEGY:-p2c}"
else
  _POOL_STRATEGY="round-robin"
fi
_is_valid_strat "$_POOL_STRATEGY" || { echo "[init] WARN: pool strategy '$_POOL_STRATEGY' 非法，回退 round-robin"; _POOL_STRATEGY="round-robin"; }
# FIX #4: codex strategy=priority for code generation scenarios.
# round-robin rotates model each turn — unsuitable for coding (上下文连续性丢失).
# 改默认 :-priority; env NIM_CODEX_STRATEGY 可覆盖 (如需 round-robin 传 NIM_CODEX_STRATEGY=round-robin).
_CODEX_STRATEGY="${NIM_CODEX_STRATEGY:-priority}"
_is_valid_strat "$_CODEX_STRATEGY" || { echo "[init] WARN: codex strategy '$_CODEX_STRATEGY' 非法，回退 priority"; _CODEX_STRATEGY="priority"; }
_FALLBACK_STRATEGY="round-robin"
_STICKY_LIMIT=1
_COMPRESS_THRESHOLD=${NIM_COMPRESS_THRESHOLD:-12000}
_COMPRESS_MODE="stacked"
_NIM_REAL_CONTEXT=${CONTEXT_LENGTH_DEFAULT:-32768}
echo "[init] pool strategy=$_POOL_STRATEGY | codex strategy=$_CODEX_STRATEGY"

# ── body limit 归一 ───────────────────────────────────────────
_RAW_BODY_LIMIT=${NIM_REQUEST_BODY_LIMIT:-1}
if [ "$_RAW_BODY_LIMIT" -gt 500 ] 2>/dev/null; then
  _REQUEST_BODY_LIMIT_MB=$(( _RAW_BODY_LIMIT / 1048576 ))
  [ "$_REQUEST_BODY_LIMIT_MB" -lt 1 ] && _REQUEST_BODY_LIMIT_MB=1
elif [ "$_RAW_BODY_LIMIT" -lt 1 ] 2>/dev/null; then
  _REQUEST_BODY_LIMIT_MB=1
else
  _REQUEST_BODY_LIMIT_MB=$_RAW_BODY_LIMIT
fi
[ "$_REQUEST_BODY_LIMIT_MB" -gt 500 ] 2>/dev/null && _REQUEST_BODY_LIMIT_MB=500
echo "[init] body limit: raw=$_RAW_BODY_LIMIT -> maxBodySizeMb=$_REQUEST_BODY_LIMIT_MB"

_PURGE_PROXY=${NIM_PURGE_PROXY:-1}
_PROXY_RELAY_HOST=${NIM_PROXY_RELAY_HOST:-127.0.0.1}
_PROXY_RELAY_PORT=${NIM_PROXY_RELAY_PORT:-20129}
_DB_PATH="${DATA_DIR:-/data}/storage.sqlite"
sql_escape() { printf '%s' "$1" | sed "s/'/''/g"; }

# int 范围校验器 (供 Resilience PATCH 白名单构造): $1=值 $2=下限(int) $3=上限(int); 返回 0 合格, 1 不合格
_res_validate_int() {
  [ -z "$1" ] && return 1
  case "$1" in
    ''|*[!0-9-]*) return 1 ;;   # 非数字 (允许负号作前缀, 实际范围校验拦截)
  esac
  [ "$1" -ge "$2" ] 2>/dev/null && [ "$1" -le "$3" ] 2>/dev/null || return 1
  return 0
}

purge_proxy_db() {
  [ "$_PURGE_PROXY" != "1" ] && { echo "[init] purge_proxy_db: skipped."; return 0; }
  local LIST_JSON
  LIST_JSON=$(curl -s --connect-timeout 5 --max-time 15 -b "$COOKIE_FILE" "$BASE_URL/api/v1/management/proxies" 2>/dev/null || echo "")
  if [ -n "$LIST_JSON" ] && printf '%s' "$LIST_JSON" | jq -e . >/dev/null 2>&1; then
    local BAD_IDS
    BAD_IDS=$(printf '%s' "$LIST_JSON" | jq -r --arg h "$_PROXY_RELAY_HOST" --argjson p "$_PROXY_RELAY_PORT" \
      '(.proxies // .data // .) | (if type=="array" then . else [] end)
       | .[] | objects | select((.host // "")==$h and ((.port|tonumber?)==$p)) | .id // empty' 2>/dev/null || true)
    if [ -n "$BAD_IDS" ]; then
      local _id _c
      while IFS= read -r _id; do
        [ -z "$_id" ] && continue
        _c=$(curl -s -o /dev/null -w "%{http_code}" --connect-timeout 5 --max-time 15 -b "$COOKIE_FILE" \
          -X DELETE "$BASE_URL/api/v1/management/proxies?id=${_id}&force=1" 2>/dev/null || echo "000")
        echo "[init] purge: API force-delete $_id -> HTTP $_c"
      done <<< "$BAD_IDS"
    else
      echo "[init] purge: 注册表无 ${_PROXY_RELAY_HOST}:${_PROXY_RELAY_PORT}。"
    fi
  else
    echo "[init] purge: 管理 API 暂不可用，走 SQL 兜底。"
  fi
  if [ -f "$_DB_PATH" ]; then
    sqlite3 "$_DB_PATH" "DELETE FROM proxy_assignments WHERE proxy_id IN
      (SELECT id FROM proxy_registry WHERE host='$(sql_escape "$_PROXY_RELAY_HOST")' AND port=$_PROXY_RELAY_PORT);" 2>/dev/null || true
    sqlite3 "$_DB_PATH" "UPDATE provider_connections SET proxy_enabled=0 WHERE provider='nvidia';" 2>/dev/null || true
    sqlite3 "$_DB_PATH" "DELETE FROM proxy_registry WHERE host='$(sql_escape "$_PROXY_RELAY_HOST")' AND port=$_PROXY_RELAY_PORT;" 2>/dev/null || true
    local _reg _asg _proxy_on
    _reg=$(sqlite3 "$_DB_PATH" "SELECT COUNT(*) FROM proxy_registry;" 2>/dev/null || echo "?")
    _asg=$(sqlite3 "$_DB_PATH" "SELECT COUNT(*) FROM proxy_assignments;" 2>/dev/null || echo "?")
    _proxy_on=$(sqlite3 "$_DB_PATH" "SELECT COUNT(*) FROM provider_connections WHERE provider='nvidia' AND proxy_enabled=1;" 2>/dev/null || echo "?")
    echo "[init] purge: registry=$_reg assignments=$_asg proxy_enabled=1剩余=$_proxy_on（期望 0/0/0）。"
  fi
}

# v4.3.1·I: NIM 目录响应 id 提取归一 (object.data / bare array 双 shape + objects 过滤)
_nim_models_ids() {
  jq -r '(if type=="object" and (.data|type)=="array" then .data
          elif type=="array" then .
          else [] end) | .[]? | objects | .id? // empty' 2>/dev/null
}

check_nim_model_health() {
  echo "[init] check_nim_model_health..."
  > /tmp/nim-deprecated.txt
  local _first_key _models_json _model_count
  # v4.3.1·H: read 内建取首行 (免 printf|head 竞争)
  IFS= read -r _first_key <<< "$NIM_KEYS" || true
  _models_json=$(curl -s --max-time 10 -H "Authorization: Bearer ${_first_key}" \
    "https://integrate.api.nvidia.com/v1/models" 2>/dev/null || echo "")
  _model_count=$(printf '%s' "$_models_json" | _nim_models_ids | wc -l || true)
  _model_count=${_model_count:-0}
  [ "$_model_count" -lt 5 ] && { echo "[init] only $_model_count models, skip 过滤"; return 0; }
  local model
  while IFS= read -r model; do
    [ -z "$model" ] && continue
    if ! printf '%s' "$_models_json" | _nim_models_ids | grep -Fxq "$model"; then
      echo "[init]   $model — DEPRECATED（NVIDIA 目录无）"; echo "$model" >> /tmp/nim-deprecated.txt
    else
      [ "$NIM_MODE" = "DEBUG" ] && echo "[init]   $model — available"
    fi
  done < <(build_all_models)
  echo "[init] $(wc -l < /tmp/nim-deprecated.txt 2>/dev/null || echo 0) deprecated / $_model_count available"
}

# v4.3.1·D: 空数组不再输出空行 (根治 POOL_ALIVE=("") 伪成员)
filter_alive() {
  local out=() m
  for m in "$@"; do grep -Fxq "$m" /tmp/nim-deprecated.txt 2>/dev/null || out+=("$m"); done
  [ "${#out[@]}" -gt 0 ] && printf '%s\n' "${out[@]}"
  return 0
}

# ══ 【⑥+ 上下文累积判读】跨 call_logs 淘汰周期保留每模型成功/失败口径 ═══
# 背景：call_logs 表有 ~10 万行上限（trimCallLogsToMaxRows），旧日志被淘汰后
#       历史划定信号丢失。本节把"曾经跑通的最大 input"与"首次报错的最小 input"
#       沉降到 context_recommendations 表，跨淘汰周期保留，供自动标定 real_context。
# 约束：只读不写外部服务；checkpoint 存 key_value(namespace='monitor')；
#       ON CONFLICT DO UPDATE 保证 last_success_tokens 只增不减。
_context_acc_init_table() {
  [ ! -f "$_DB_PATH" ] && return 1
  sqlite3 "$_DB_PATH" "
    CREATE TABLE IF NOT EXISTS context_recommendations (
      model_id TEXT PRIMARY KEY,
      last_success_tokens INTEGER DEFAULT NULL,
      first_failure_tokens INTEGER DEFAULT NULL,
      success_samples INTEGER DEFAULT 0,
      failure_samples INTEGER DEFAULT 0,
      confidence TEXT DEFAULT 'insufficient',
      recommended_real_context INTEGER DEFAULT NULL,
      last_updated TEXT DEFAULT NULL
    );" 2>/dev/null || return 1
  return 0
}

# 探测 call_logs 的 input/output token 列名。3.8.43 实测 tokens_in/tokens_out；
# 兼容 input_tokens/in_tokens/total_input_tokens 等（探测命中即用）。
# 单次 PRAGMA（#4 合一）。输出两行：第1行 input 列名、第2行 output 列名；未命中留空行。
_detect_io_cols() {
  sqlite3 "$_DB_PATH" "PRAGMA table_info(call_logs);" 2>/dev/null \
    | awk -F'|' '
        $2~/^tokens_in$|^input_tokens$|^in_tokens$|^total_input_tokens$/ {if(!ic) ic=$2}
        $2~/^tokens_out$|^output_tokens$|^out_tokens$|^total_output_tokens$/ {if(!oc) oc=$2}
        END{print ic; print oc}'
}

# 增量更新：读 checkpoint -> 查 id>checkpoint 新日志 -> 累积 -> 落表 -> 推 checkpoint
context_accumulator_update() {
  echo "[init] context_accumulator_update: 增量累积每模型成功/失败口径..."
  [ ! -f "$_DB_PATH" ] && { echo "[init]   no DB, skip."; return 0; }
  _context_acc_init_table || { echo "[init]   建表失败，skip。"; return 0; }

  local _has_tbl
  _has_tbl=$(sqlite3 "$_DB_PATH" "SELECT name FROM sqlite_master WHERE type='table' AND name='call_logs';" 2>/dev/null || echo "")
  [ -z "$_has_tbl" ] && { echo "[init]   call_logs 不存在（无流量），预约表就绪。"; return 0; }

  local _input_col _output_col _io
  _io=$(_detect_io_cols)
  _input_col=$(printf '%s' "$_io" | sed -n '1p')
  _output_col=$(printf '%s' "$_io" | sed -n '2p')
  [ -z "$_input_col" ] && { echo "[init]   WARN: call_logs 无已知 input token 列，skip。"; return 0; }
  [ -z "$_output_col" ] && _output_col="tokens_out"
  echo "[init]   列探测 input=$_input_col output=$_output_col"

  # checkpoint：call_logs.id 是 TEXT(UUID) 无数值序，改用 timestamp 串比较
  # ISO-8601 字典序 == 时间序；checkpoint str 存 key_value(monitor/ctx_last_log_ts)
  local _ckpt_key="ctx_last_log_ts" _last_ts _new_max_ts
  _last_ts=$(sqlite3 "$_DB_PATH" "SELECT value FROM key_value WHERE namespace='monitor' AND key='$(sql_escape "$_ckpt_key")';" 2>/dev/null || echo "")
  [ -z "$_last_ts" ] && _last_ts="1970-01-01T00:00:00.000Z"
  echo "[init]   checkpoint last_ts=$_last_ts"

  # 成功：status 2xx 且 output>0；
  # 失败：status>=500、status=413、或 (2xx 且 output=0)。
  # 不纳 401/403/429：鉴权/限频信号会污染 first_failure_tokens。
  local _q
  _q="
    SELECT
      model                                                   AS mid,
      MAX(CASE WHEN status BETWEEN 200 AND 299 AND ${_output_col}>0
               THEN ${_input_col} END)                        AS suc_max,
      MIN(CASE WHEN (status>=500) OR (status=413) OR (status BETWEEN 200 AND 299 AND ${_output_col}=0)
               THEN ${_input_col} END)                        AS fail_min,
      SUM(CASE WHEN status BETWEEN 200 AND 299 AND ${_output_col}>0 THEN 1 ELSE 0 END) AS suc_n,
      SUM(CASE WHEN (status>=500) OR (status=413) OR (status BETWEEN 200 AND 299 AND ${_output_col}=0) THEN 1 ELSE 0 END) AS fail_n,
      MAX(timestamp)                                          AS max_ts
    FROM call_logs
    WHERE provider='nvidia' AND timestamp > '$(sql_escape "$_last_ts")'
      AND model LIKE '%/%' AND model != 'model-sync'
    GROUP BY model;"

  local _rows _cnt=0
  _rows=$(sqlite3 -separator $'\t' "$_DB_PATH" "$_q" 2>/dev/null || echo "")
  if [ -z "$_rows" ]; then echo "[init]   本轮无新日志（timestamp > checkpoint）。"; return 0; fi

  # #1 根因修复：mapfile -t -d $'\t' 数组逐字段拆行，保留空字段不折叠，6 索引严格对齐 SQL 列序。
  local _line _mid _suc_max _fail_min _suc_n _fail_n _max_ts
  while IFS= read -r _line; do
    local _acc=(); mapfile -t -d $'\t' _acc <<<"$_line"
    _mid=${_acc[0]}; _suc_max=${_acc[1]}; _fail_min=${_acc[2]}
    _suc_n=${_acc[3]}; _fail_n=${_acc[4]}; _max_ts=${_acc[5]}
    [ -z "$_mid" ] && continue
    local _rec_real _conf _new_total
    _new_total=$(( (${_suc_n:-0} + ${_fail_n:-0}) ))
    sqlite3 "$_DB_PATH" "
      INSERT INTO context_recommendations (model_id, last_success_tokens, first_failure_tokens,
                                           success_samples, failure_samples, confidence,
                                           recommended_real_context, last_updated)
      VALUES ('$(sql_escape "$_mid")',
              $([ -n "$_suc_max" ] && echo "$_suc_max" || echo 'NULL'),
              $([ -n "$_fail_min" ] && echo "$_fail_min" || echo 'NULL'),
              ${_suc_n:-0}, ${_fail_n:-0},
              'insufficient', NULL, datetime('now'))
      ON CONFLICT(model_id) DO UPDATE SET
        last_success_tokens = MAX(COALESCE(excluded.last_success_tokens, 0),
                                  COALESCE(context_recommendations.last_success_tokens, 0)),
        first_failure_tokens = CASE
          WHEN context_recommendations.first_failure_tokens IS NULL THEN excluded.first_failure_tokens
          WHEN excluded.first_failure_tokens IS NULL THEN context_recommendations.first_failure_tokens
          ELSE MIN(excluded.first_failure_tokens, context_recommendations.first_failure_tokens)
        END,
        success_samples  = context_recommendations.success_samples  + excluded.success_samples,
        failure_samples  = context_recommendations.failure_samples  + excluded.failure_samples,
        last_updated     = datetime('now');" 2>/dev/null || continue

    local _hist_suc_n _hist_fail_n _hist_suc _hist_fail
    _hist_suc_n=$(sqlite3 "$_DB_PATH" "SELECT success_samples FROM context_recommendations WHERE model_id='$(sql_escape "$_mid")';" 2>/dev/null || echo 0)
    _hist_fail_n=$(sqlite3 "$_DB_PATH" "SELECT failure_samples FROM context_recommendations WHERE model_id='$(sql_escape "$_mid")';" 2>/dev/null || echo 0)
    _hist_suc=$(sqlite3 "$_DB_PATH" "SELECT last_success_tokens FROM context_recommendations WHERE model_id='$(sql_escape "$_mid")';" 2>/dev/null || echo "")
    _hist_fail=$(sqlite3 "$_DB_PATH" "SELECT first_failure_tokens FROM context_recommendations WHERE model_id='$(sql_escape "$_mid")';" 2>/dev/null || echo "")

    local _total=$((_hist_suc_n + _hist_fail_n))
    if [ "$_total" -lt 10 ]; then _conf="insufficient"
    elif [ "$_total" -lt 50 ]; then _conf="low"
    elif [ "$_total" -lt 200 ]; then _conf="medium"
    else _conf="high"; fi

    # 推荐口径：有失败边界 → first_failure*0.85；否则 last_success*0.9
    if [ -n "$_hist_fail" ] && [ "$_hist_fail" -gt 0 ] 2>/dev/null; then
      _rec_real=$(( _hist_fail * 85 / 100 ))
    elif [ -n "$_hist_suc" ] && [ "$_hist_suc" -gt 0 ] 2>/dev/null; then
      _rec_real=$(( _hist_suc * 90 / 100 ))
    else
      _rec_real=""
    fi

    # ⚠️ confidence='$_conf' 必须用变量展开（早期 '$(_conf)' 命令替换误用已修）。
    sqlite3 "$_DB_PATH" "
      UPDATE context_recommendations
      SET confidence='$_conf',
          recommended_real_context=$([ -n "$_rec_real" ] && echo "$_rec_real" || echo 'NULL')
      WHERE model_id='$(sql_escape "$_mid")';" 2>/dev/null || true
    _cnt=$((_cnt+1))
  done <<< "$_rows"

  _new_max_ts=$(printf '%s\n' "$_rows" | awk -F'\t' '{print $6}' | sort | tail -n1)
  [ -n "$_new_max_ts" ] && sqlite3 "$_DB_PATH" "
    INSERT INTO key_value (namespace, key, value) VALUES ('monitor', '$(sql_escape "$_ckpt_key")', '$(sql_escape "$_new_max_ts")')
    ON CONFLICT(namespace, key) DO UPDATE SET value = excluded.value;" 2>/dev/null \
    && echo "[init]   checkpoint -> ctx_last_log_ts=$_new_max_ts"
  echo "[init]   累积更新 ${_cnt} 个模型。"

  # v4.3: 自动回写 context_recommendations → model_context_overrides 整段删除 (CF-2 + M30 REJECT).
  # 自动 Context Override 默认关闭 (CF-4); 启用路径见 KNOWN-UNVERIFIED (API PATCH max_input_tokens + 读回).

  # 【⑥+ 】累积推荐表输出（被动观测，不触发任何写入）。
  local _acc_rows
  _acc_rows=$(sqlite3 -separator '|' "$_DB_PATH" "
    SELECT model_id,
           COALESCE(last_success_tokens,'-'),
           COALESCE(first_failure_tokens,'-'),
           (success_samples||'/'||failure_samples),
           confidence,
           COALESCE(recommended_real_context,'-')
    FROM context_recommendations
    ORDER BY CASE confidence WHEN 'high' THEN 0 WHEN 'medium' THEN 1
             WHEN 'low' THEN 2 ELSE 3 END, model_id;" 2>/dev/null || echo "")
  if [ -z "$_acc_rows" ]; then
    echo "[init] （累积推荐表为空：尚无成功/失败样本）"
  else
    echo "[init] ═══累积 real_context 推荐（跨淘汰周期保留）═══"
    echo "[init]   model | last_ok | first_fail | ok/fail_n | conf | rec_ctx"
    while IFS='|' read -r _m _ok _fail _n _c _r; do
      [ -z "$_m" ] && continue
      printf '[init]   %s | %s | %s | %s | %s | %s\n' "$_m" "$_ok" "$_fail" "$_n" "$_c" "$_r"
    done <<< "$_acc_rows"
    echo "[init] ═════════════════════════════════════════"
  fi
}

# ══════════════════════════════════════════════════════════════
echo "[init] Starting NIM OmniRoute initializer v4.3.1 (profile=$_PROFILE, mode=$NIM_MODE)..."
echo "[init] BASE_URL=$BASE_URL"

[ -z "$INITIAL_PASSWORD" ] && { echo "[init] ERROR: INITIAL_PASSWORD required"; exit 1; }
[ -z "$NIM_KEYS" ] && { echo "[init] ERROR: NIM_KEYS required"; exit 1; }

echo "[init] Waiting for OmniRoute..."
HWAIT=0
until curl -sf "$BASE_URL/api/monitoring/health" > /dev/null 2>&1; do
  sleep 3; HWAIT=$((HWAIT + 3))
  [ "$HWAIT" -ge 180 ] && { echo "[init] FATAL: not ready within 180s"; exit 1; }
done
echo "[init] OmniRoute up (after ${HWAIT}s)."

VERSION_HTTP=$(curl -s -o "$VERSION_FILE" -w "%{http_code}" --connect-timeout 5 --max-time 10 "$BASE_URL/api/monitoring/health" 2>/dev/null || echo "000")
[ "$VERSION_HTTP" = "200" ] && echo "[init] version: $(jq -r '.version // "unknown"' "$VERSION_FILE" 2>/dev/null || echo unknown)"

echo "[init] Logging in..."
LOGIN_BODY=$(jq -n --arg password "$INITIAL_PASSWORD" '{password: $password}')
LOGIN_HTTP=$(curl -s -o "$LOGIN_RESP_FILE" -w "%{http_code}" --connect-timeout 5 --max-time 15 -c "$COOKIE_FILE" \
  -X POST "$BASE_URL/api/auth/login" -H "Content-Type: application/json" -d "$LOGIN_BODY" 2>/dev/null || echo "000")
[ "$LOGIN_HTTP" != "200" ] && [ "$LOGIN_HTTP" != "201" ] && { echo "[init] ERROR login HTTP $LOGIN_HTTP"; cat "$LOGIN_RESP_FILE" 2>/dev/null || true; exit 1; }
grep -q "auth_token" "$COOKIE_FILE" 2>/dev/null || { echo "[init] ERROR no auth_token"; exit 1; }
echo "[init] Logged in."

purge_proxy_db

resolve_or_key() {
  printf '%s' "${OMNIROUTE_API_KEY:-$(cat "$OR_API_KEY_FILE" 2>/dev/null)}" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//'
}

if [ -n "$OMNIROUTE_API_KEY" ]; then
  OR_KEY="$(printf '%s' "$OMNIROUTE_API_KEY" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
  [ -z "$OR_KEY" ] && { echo "[init] FATAL: OMNIROUTE_API_KEY blank"; exit 1; }
  echo "$OR_KEY" > "$OR_API_KEY_FILE" 2>/dev/null || echo "[init] WARN write $OR_API_KEY_FILE failed"
  chmod 600 "$OR_API_KEY_FILE" 2>/dev/null || true
  echo "[init] OMNIROUTE_API_KEY env set, skip /api/keys."
elif [ -f "$OR_API_KEY_FILE" ] && [ -s "$OR_API_KEY_FILE" ]; then
  OR_KEY="$(sed 's/^[[:space:]]*//;s/[[:space:]]*$//' "$OR_API_KEY_FILE")"
  echo "[init] OR_API_KEY file exists."
else
  echo "[init] Creating OmniRoute API Key..."
  KEY_BODY=$(jq -n --arg name "gate-internal" '{name: $name, expiresAt: null}')
  KEY_HTTP=$(curl -s -o "$KEY_RESP_FILE" -w "%{http_code}" --connect-timeout 5 --max-time 15 -b "$COOKIE_FILE" \
    -X POST "$BASE_URL/api/keys" -H "Content-Type: application/json" -d "$KEY_BODY" 2>/dev/null || echo "000")
  if [ "$KEY_HTTP" = "200" ] || [ "$KEY_HTTP" = "201" ]; then
    # v4.3.1·G: jq 解析容错 (非法 JSON 不再 set -e 无签名猝死, 走明确 ERROR)
    OR_API_KEY_VALUE=$(jq -r '.key // empty' "$KEY_RESP_FILE" 2>/dev/null || true)
    [ -z "$OR_API_KEY_VALUE" ] && { echo "[init] ERROR parse key"; exit 1; }
    echo "$OR_API_KEY_VALUE" > "$OR_API_KEY_FILE"; chmod 600 "$OR_API_KEY_FILE"; OR_KEY="$OR_API_KEY_VALUE"
    echo "[init] OR_API_KEY written."
  else
    echo "[init] ERROR /api/keys HTTP $KEY_HTTP"; exit 1
  fi
fi

echo "[init] Registering NIM keys..."
INDEX=1
while IFS= read -r RAW_KEY; do
  KEY=$(printf '%s' "$RAW_KEY" | tr -d '\r' | xargs)
  [ -z "$KEY" ] && continue
  NAME=$(printf "nim-%02d" "$INDEX")
  RESP_FILE="$(_resp omniroute-provider-$INDEX.json)"
  BODY=$(jq -n --arg provider "nvidia" --arg apiKey "$KEY" --arg name "$NAME" \
    '{provider:$provider, apiKey:$apiKey, name:$name, priority:1, testStatus:"unknown"}')
  HTTP_CODE=$(curl -s -o "$RESP_FILE" -w "%{http_code}" --connect-timeout 5 --max-time 15 -b "$COOKIE_FILE" \
    -X POST "$BASE_URL/api/providers" -H "Content-Type: application/json" -d "$BODY" 2>/dev/null || echo "000")
  if [ "$HTTP_CODE" = "201" ] || [ "$HTTP_CODE" = "200" ]; then echo "[init] $NAME OK"; REGISTERED=$((REGISTERED+1))
  elif [ "$HTTP_CODE" = "409" ]; then echo "[init] $NAME exists"; SKIPPED=$((SKIPPED+1))
  else echo "[init] $NAME HTTP $HTTP_CODE"; cat "$RESP_FILE" 2>/dev/null || true; FAILED=$((FAILED+1)); fi
  INDEX=$((INDEX+1))
done <<< "$NIM_KEYS"
echo "[init] Keys: $REGISTERED registered, $SKIPPED skipped, $FAILED failed."

echo "[init] Fetching provider IDs..."
PROVIDERS_HTTP=$(curl -s -o "$PROVIDERS_FILE" -w "%{http_code}" --connect-timeout 5 --max-time 15 -b "$COOKIE_FILE" "$BASE_URL/api/providers" 2>/dev/null || echo "000")
if [ "$PROVIDERS_HTTP" = "200" ]; then
  mapfile -t PROVIDER_IDS < <(jq -r '[.. | objects | select((.provider? // "")=="nvidia") | select((.id? // "")!="") | .id] | unique | .[]' "$PROVIDERS_FILE" 2>/dev/null || true)
fi
echo "[init] Provider IDs: ${#PROVIDER_IDS[@]}"

purge_proxy_db

echo "[init] Resilience (RPM=$_RPM, concurrent=$_CONCURRENT, interval=${_MIN_INTERVAL_MS}ms)..."

# ── 3.8.43 PATCH 白名单 (SSOT: src/app/api/resilience/route.ts:153 + schemas/settings.ts:131-180) ──
# updateResilienceSchema z.strict(): 顶层仅 requestQueue/connectionCooldown/providerBreaker/
#   waitForCooldown/comboCooldownWait/quotaShareConcurrencyLimit/providerCooldown/profiles/defaults.
# requestQueueSettingsSchema z.strict(): {requestsPerMinute int>=1, minTimeBetweenRequestsMs int>=0,
#   concurrentRequests int>=1, autoEnableApiKeyProviders boolean, maxWaitMs int>=1}.
# useUpstream429BreakerHints 仅在 connectionCooldown.{oauth,apikey} 下, 顶层该字段 → z.strict() 拒绝 → 400.
# PATCH = 部分更新 (mergeResilienceSettings), 未传字段保留旧值.

# 显式白名单构造 + 输入校验 (非法 init 失败, 不静默 SKIP)
if ! _res_validate_int "$_RPM" 1 60000 || ! _res_validate_int "$_MIN_INTERVAL_MS" 0 600000 || ! _res_validate_int "$_CONCURRENT" 1 1000; then
  echo "[init] ✗ Resilience 输入非法 (_RPM=$_RPM / _MIN_INTERVAL_MS=$_MIN_INTERVAL_MS / _CONCURRENT=$_CONCURRENT). init 失败."
  exit 1
fi
RESILIENCE_BODY=$(jq -nc \
  --argjson rpm "$_RPM" \
  --argjson minMs "$_MIN_INTERVAL_MS" \
  --argjson conc "$_CONCURRENT" \
  '{requestQueue:{requestsPerMinute:$rpm, minTimeBetweenRequestsMs:$minMs, concurrentRequests:$conc}}')
echo "[init] Resilience PATCH body keys=[$(echo "$RESILIENCE_BODY" | jq -rc 'keys|join(",")')] requestQueue.keys=[$(echo "$RESILIENCE_BODY" | jq -rc '.requestQueue|keys|join(",")')] (无顶层 useUpstream429BreakerHints)"

# 错误处理区分 HTTP 4xx/5xx vs transport error
_t0=$(date +%s%N 2>/dev/null || date +%s)
RESILIENCE_CODE=$(curl -s -o "$RESILIENCE_RESP_FILE" -w "%{http_code}" --connect-timeout 5 --max-time 20 \
  -b "$COOKIE_FILE" -X PATCH "$BASE_URL/api/resilience" -H "Content-Type: application/json" \
  -d "$RESILIENCE_BODY" 2>/tmp/res_patch.err)
res_curl_rc=$?
_t1=$(date +%s%N 2>/dev/null || date +%s)
_res_dur_ms=$(( (_t1 - _t0) / 1000000 ))
_res_dur_ms=$(( _res_dur_ms < 0 ? 0 : _res_dur_ms ))
_res_err=$(head -c 300 /tmp/res_patch.err 2>/dev/null)

if [ "$res_curl_rc" -ne 0 ] || [ -z "$RESILIENCE_CODE" ]; then
  echo "[init] ⚠️ Resilience PATCH transport-error: curl_rc=$res_curl_rc dur=${_res_dur_ms}ms"
  echo "[init]   curl_err: ${_res_err:-<empty>}"
  echo "[init]   abort_source: $( [ "$res_curl_rc" = 28 ] && echo 'request_timeout' || ([ "$res_curl_rc" = 7 ] && echo 'proxy_connect_failure' || echo 'curl_unknown') )"
  echo "[init]   不伪装成 HTTP 错误. 保留旧配置 (CF-4). PATCH 失败 → init 仍可继续其他步, 但 readiness 不得报告 resilience 健康."
  RESILIENCE_CODE="transport_err"
else
  echo "[init] Resilience PATCH HTTP $RESILIENCE_CODE (dur=${_res_dur_ms}ms)"
  case "$RESILIENCE_CODE" in
    200|201) : ;;
    *)
      echo "[init] ⚠️ Resilience PATCH HTTP $RESILIENCE_CODE (收到响应): body=[$(head -c 500 "$RESILIENCE_RESP_FILE" 2>/dev/null)] path=/api/resilience"
      echo "[init]   fields_sent: $(echo "$RESILIENCE_BODY" | jq -rc '.requestQueue|keys|join(",")' 2>/dev/null)"
      ;;
  esac
fi

# Read-back: PATCH 成功后立即 GET 验三字段 — 不一致 init 失败 (CF-4: 写必须读回)
if [ "$RESILIENCE_CODE" = "200" ] || [ "$RESILIENCE_CODE" = "201" ]; then
  _RB=$(curl -s --connect-timeout 5 --max-time 20 -b "$COOKIE_FILE" "$BASE_URL/api/resilience" 2>/tmp/res_get.err)
  res_get_rc=$?
  _res_get_err=$(head -c 300 /tmp/res_get.err 2>/dev/null)
  if [ "$res_get_rc" -ne 0 ] || [ -z "$_RB" ]; then
    echo "[init] ✗ Resilience GET 读回 transport-error: curl_rc=$res_get_rc err=${_res_get_err:-<empty>}"
    echo "[init]   CF-4 约束: 写必须读回. 读回失败 → init 失败."
    exit 1
  fi
  _RB_RPM=$(echo "$_RB" | jq -r '.requestQueue.requestsPerMinute // "null"' 2>/dev/null || echo "jq_fail")
  _RB_MINMS=$(echo "$_RB" | jq -r '.requestQueue.minTimeBetweenRequestsMs // "null"' 2>/dev/null || echo "jq_fail")
  _RB_CONC=$(echo "$_RB" | jq -r '.requestQueue.concurrentRequests // "null"' 2>/dev/null || echo "jq_fail")
  echo "[init] Resilience 读回: RPM=$_RB_RPM minMs=$_RB_MINMS concurrent=$_RB_CONC (预期 $_RPM/$_MIN_INTERVAL_MS/$_CONCURRENT)"
  _mismatch=""
  [ "$_RB_RPM" != "$_RPM" ] && _mismatch="$_mismatch RPM($_RB_RPM!=$_RPM)"
  [ "$_RB_MINMS" != "$_MIN_INTERVAL_MS" ] && _mismatch="$_mismatch minTimeMs($_RB_MINMS!=$_MIN_INTERVAL_MS)"
  [ "$_RB_CONC" != "$_CONCURRENT" ] && _mismatch="$_mismatch concurrent($_RB_CONC!=$_CONCURRENT)"
  if [ -n "$_mismatch" ]; then
    echo "[init] ✗ Resilience 读回不一致:$_mismatch → init 失败 (CF-4: 限流配置未落定, 不能报告 ready)"
    exit 1
  fi
  echo "[init] ✓ Resilience 读回全字段一致 (28/1/2200ms 已落定)"
fi

echo "[init] Routing + maxBodySizeMb=$_REQUEST_BODY_LIMIT_MB..."
SETTINGS_CODE=$(curl -s -o "$SETTINGS_RESP_FILE" -w "%{http_code}" --connect-timeout 5 --max-time 15 -b "$COOKIE_FILE" \
  -X PATCH "$BASE_URL/api/settings" -H "Content-Type: application/json" \
  -d "{\"fallbackStrategy\":\"$_FALLBACK_STRATEGY\",\"stickyRoundRobinLimit\":$_STICKY_LIMIT,\"requestRetry\":2,\"maxRetryIntervalSec\":5,\"maxBodySizeMb\":$_REQUEST_BODY_LIMIT_MB}" 2>/dev/null || echo "000")
echo "[init] Settings HTTP $SETTINGS_CODE"
[ "$SETTINGS_CODE" != "200" ] && [ "$SETTINGS_CODE" != "201" ] && { echo "[init] ⚠️ Settings 非 2xx："; cat "$SETTINGS_RESP_FILE" 2>/dev/null || true; }

echo "[init] Compression (threshold=$_COMPRESS_THRESHOLD)..."
# v4.3.1·F: transport 容错 (配置类写入, 失败 WARN 继续, 不杀死 init)
curl -s -o "$COMPRESS_RESP_FILE" -w "%{http_code}\n" --connect-timeout 5 --max-time 15 -b "$COOKIE_FILE" \
  -X PUT "$BASE_URL/api/settings/compression" -H "Content-Type: application/json" \
  -d "{\"enabled\":true,\"defaultMode\":\"$_COMPRESS_MODE\",\"autoTriggerTokens\":$_COMPRESS_THRESHOLD}" 2>/dev/null \
  | sed 's/^/[init] Compression HTTP /' \
  || echo "[init] ⚠️ Compression PUT transport-error (保留旧配置, init 继续)."

echo "[init] Resetting circuit breakers (first-init clean start)..."
# v4.3.1·F: transport 容错
curl -s -o /dev/null -w "[init] CB reset HTTP %{http_code}\n" --connect-timeout 5 --max-time 15 -b "$COOKIE_FILE" \
  -X POST "$BASE_URL/api/resilience/reset" -H "Content-Type: application/json" 2>/dev/null \
  || echo "[init] ⚠️ CB reset transport-error (init 继续)."

# K5 FIX (审查裁定推荐选项 c):
# API PATCH /api/provider-models 在 3.8.43 源码中仅接受 isHidden 字段,
# 不接受 contextLength / max_input_tokens / max_output_tokens (B1 L2 源码实证).
# 修复: 保留 init 内部的 per-model 32K override (apply_context_override, 42ea8e7
# 基线原态), 保留"禁用 monitor 自动回写"改动. API PATCH 路径标注为"3.8.43 不支持".
# 自动回写 (confidence-based monitor → model_context_overrides) 仍保持禁用 (CF-4).

# per-model 32K override (real_context=$_NIM_REAL_CONTEXT) — 42ea8e7 基线原态恢复.
echo "[init] per-model 32K override (real_context=$_NIM_REAL_CONTEXT)..."
OVERRIDE_APPLIED=0; OVERRIDE_SKIPPED=0
apply_context_override() {
  if sqlite3 "$_DB_PATH" \
    "INSERT OR REPLACE INTO model_context_overrides (provider, model_id, real_context, source, refreshed_at)
     VALUES ('nvidia', '$(sql_escape "$1")', $2, 'init', datetime('now'));" 2>/dev/null; then
    OVERRIDE_APPLIED=$((OVERRIDE_APPLIED+1))
  else OVERRIDE_SKIPPED=$((OVERRIDE_SKIPPED+1)); echo "[init]   override FAILED: $1"; fi
}
while IFS= read -r _M; do [ -z "$_M" ] && continue; apply_context_override "$_M" "$_NIM_REAL_CONTEXT"; done < <(build_all_models)
echo "[init] override: $OVERRIDE_APPLIED applied, $OVERRIDE_SKIPPED failed."

echo "[init] ─────────────────────────────────────────────"
echo "[init]   PROFILE=$_PROFILE MODE=$NIM_MODE KEYS=$_ALIVE_KEYS RPM=$_RPM BODY=$_REQUEST_BODY_LIMIT_MB MB"
echo "[init]   POOL_STRATEGY=$_POOL_STRATEGY REAL_CONTEXT=$_NIM_REAL_CONTEXT (per-model 32K override 应用, monitor 自动回写禁用)"
echo "[init] ─────────────────────────────────────────────"

hf_snapshot() {
  # v4.3.1·J: 入口条件显式 if
  if [ -z "$HF_TOKEN" ] || [ -z "$HF_DATASET_REPO" ]; then
    return 0
  fi
  echo "[init] HF Dataset snapshot（配置 + 可选 DEBUG log）..."
  local BACKUP_DIR="/tmp/omni-snapshot"; mkdir -p "$BACKUP_DIR"
  local OR_KEY; OR_KEY="$(resolve_or_key)"
  # v4.3.1·E: export/解析失败 → WARN 跳过 (快照=观测面, 不杀死尾段 init)
  if ! curl -sf --connect-timeout 5 --max-time 30 "$BASE_URL/api/settings/export-json" -H "Authorization: Bearer $OR_KEY" \
    | jq 'del(.usageHistory, .domainCostHistory, .domainBudgets) |
          (if (.apiKeys|type)=="array" then .apiKeys |= map(del(.key)) else . end) |
          (if (.providerConnections|type)=="array" then .providerConnections |= map(del(.credentials)) else . end)' \
    > "$BACKUP_DIR/omni_config.json" 2>/dev/null; then
    echo "[init] snapshot: WARN export-json 获取/解析失败, 跳过本轮快照 (init 继续)."
    return 0
  fi
  [ -s "$BACKUP_DIR/omni_config.json" ] || { echo "[init] snapshot: WARN omni_config.json 为空, 跳过."; return 0; }
  jq '.apiKeys' "$BACKUP_DIR/omni_config.json" > "$BACKUP_DIR/keys.json" 2>/dev/null || true
  jq '.providerConnections' "$BACKUP_DIR/omni_config.json" > "$BACKUP_DIR/providerConnections.json" 2>/dev/null || true
  jq '.settings' "$BACKUP_DIR/omni_config.json" > "$BACKUP_DIR/settings.json" 2>/dev/null || true
  jq '.combos' "$BACKUP_DIR/omni_config.json" > "$BACKUP_DIR/combos.json" 2>/dev/null || true

  # ── 【⑥+ 】init_vars.json：脚本运行时变量随快照上传 ──
  _arr_json() { # bash 数组 -> JSON 字符串数组
    [ "$#" -eq 0 ] && { printf '[]'; return; }
    printf '%s\n' "$@" | jq -R . | jq -s -c .
  }
  { jq -n \
      --arg version "4.3.1" \
      --arg profile "$_PROFILE" \
      --arg mode "$NIM_MODE" \
      --argjson tier_fast "$(_arr_json "${TIER_FAST[@]}")" \
      --argjson tier_stable "$(_arr_json "${TIER_STABLE[@]}")" \
      --argjson tier_restricted "$(_arr_json "${TIER_RESTRICTED[@]}")" \
      --argjson pool_models "$(_arr_json "${NIM_POOL_MODELS[@]}")" \
      --argjson codex_models "$(_arr_json "${NIM_CODEX_MODELS[@]}")" \
      --argjson fast_models "$(_arr_json "${NIM_FAST_MODELS[@]}")" \
      --arg alive_keys "$_ALIVE_KEYS" \
      --arg rpm "$_RPM" \
      --arg concurrent "$_CONCURRENT" \
      --arg min_interval_ms "$_MIN_INTERVAL_MS" \
      --arg pool_strategy "$_POOL_STRATEGY" \
      --arg codex_strategy "$_CODEX_STRATEGY" \
      --arg fallback_strategy "$_FALLBACK_STRATEGY" \
      --arg real_context "$_NIM_REAL_CONTEXT" \
      --arg body_limit_mb "$_REQUEST_BODY_LIMIT_MB" \
      --arg compress_threshold "$_COMPRESS_THRESHOLD" \
      --arg per_key_rpm "${_PER_KEY_RPM}" \
      '{version:$version, profile:$profile, mode:$mode,
        tiers:{fast:$tier_fast, stable:$tier_stable, restricted:$tier_restricted},
        pools:{pool:$pool_models, codex:$codex_models, fast:$fast_models},
        dynamic_rpm:{alive_keys:($alive_keys|tonumber), rpm:($rpm|tonumber),
                     concurrent:($concurrent|tonumber), min_interval_ms:($min_interval_ms|tonumber),
                     per_key_rpm:($per_key_rpm|tonumber)},
        strategies:{pool:$pool_strategy, codex:$codex_strategy, fallback:$fallback_strategy},
        context:{real_context:($real_context|tonumber)},
        limits:{body_mb:($body_mb|tonumber), compress_threshold:($compress_threshold|tonumber)}}' \
      --arg body_mb "$_REQUEST_BODY_LIMIT_MB"; } > "$BACKUP_DIR/init_vars.json" 2>/dev/null \
    && echo "[init] snapshot: init_vars.json written" \
    || echo "[init] snapshot: WARN init_vars.json 写入失败"

  # ── 【v4.3·⑨ 】DEBUG log 上传到 Dataset（默认关闭）──
  if [ "$NIM_MODE" = "DEBUG" ] && [ "${NIM_DEBUG_LOG_TO_DATASET:-0}" = "1" ] && [ -n "$INIT_LOG" ] && [ -f "$INIT_LOG" ]; then
    local _keep=${NIM_DEBUG_LOG_KEEP:-5}
    local _dbg="$BACKUP_DIR/debug_$(basename "$INIT_LOG" | sed 's/^init_//')"
    cp -f "$INIT_LOG" "$_dbg" 2>/dev/null \
      && echo "[init] snapshot: 附带 DEBUG log -> debug_$(basename "$INIT_LOG" | sed 's/^init_//')" \
      || echo "[init] snapshot: WARN 复制 DEBUG log 失败，跳过。"
    # 字段级脱敏 (红线1 动态: 不上传凭据明文)
    if [ -f "$_dbg" ]; then
      sed -i -E \
        -e 's/(Authorization:[[:space:]]*Bearer[[:space:]]+)[A-Za-z0-9._\-]+/\1<REDACTED>/gI' \
        -e 's/(NIM_KEY=|nvapi-)[A-Za-z0-9._\-]+/\1<REDACTED>/gI' \
        -e 's/(Cookie:[[:space:]]+)[^[:space:]]+/\1<REDACTED>/gI' \
        -e 's/(Set-Cookie:[[:space:]]+)[^[:space:]]+/\1<REDACTED>/gI' \
        -e 's/(Bearer )[A-Za-z0-9._\-]+/\1<REDACTED>/g' \
        "$_dbg" 2>/dev/null || true
    fi
    # 本地滚动清理：只保留最近 _keep 个 init_*.log
    if [ -d "$LOG_DIR" ]; then
      ls -1t "$LOG_DIR"/init_*.log 2>/dev/null | tail -n +$(( _keep + 1 )) | xargs -r rm -f 2>/dev/null || true
    fi
  else
    [ "$NIM_MODE" = "DEBUG" ] && echo "[init] snapshot: DEBUG log 上传已禁用（默认关, NIM_DEBUG_LOG_TO_DATASET=1 开启)."
  fi

  # v4.3.1·E: 上传失败 WARN, 不杀死 init
  python3 - <<'PYEOF' || echo "[init] snapshot: WARN HF 上传失败 (init 继续)."
import os
from datetime import datetime, timezone
from huggingface_hub import HfApi
api = HfApi(token=os.environ["HF_TOKEN"])
api.upload_folder(folder_path="/tmp/omni-snapshot", path_in_repo="omni_data",
    repo_id=os.environ["HF_DATASET_REPO"], repo_type="dataset",
    commit_message=f"Sync omni_data - {datetime.now(timezone.utc).isoformat()}")
print("[init] HF Dataset uploaded.")
PYEOF
}

# ── 增量模式（⑧ 增量门放宽：任一 nim-* combo 或 INIT_MARKER 存在）──
if [ -f "$_DB_PATH" ]; then
  COMBO_COUNT=$(sqlite3 "$_DB_PATH" "SELECT COUNT(*) FROM combos WHERE name IN ('nim-pool','nim-codex');" 2>/dev/null || echo 0)
  if [ "${COMBO_COUNT:-0}" -gt 0 ] || [ -f "$INIT_MARKER" ]; then
    echo "[init] Incremental mode."
    purge_proxy_db
    # ⑤ 只清"已过期"熔断，保留仍在冷却窗内的历史信号
    sqlite3 "$_DB_PATH" "DELETE FROM domain_circuit_breakers WHERE cooldown_until < datetime('now');" 2>/dev/null || true
    check_nim_model_health
    # ⑦ 增量也走幂等 upsert（同时修复 deprecated 与撞名）
    mapfile -t POOL_ALIVE  < <(filter_alive "${NIM_POOL_MODELS[@]}")
    mapfile -t CODEX_ALIVE < <(filter_alive "${NIM_CODEX_MODELS[@]}")
    upsert_combo "nim-pool"  "$_POOL_STRATEGY"  ${POOL_ALIVE[@]+"${POOL_ALIVE[@]}"}
    upsert_combo "nim-codex" "$_CODEX_STRATEGY" ${CODEX_ALIVE[@]+"${CODEX_ALIVE[@]}"}
    context_accumulator_update
    hf_snapshot
    echo "[init] Done (incremental). v4.3.1"
    exit 0
  fi
else
  echo "[init] DB not present. First-time init."
fi

check_nim_model_health

echo "[init] Registering models..."
register_model() {
  local MODEL_ID="$1" F="$(_resp omniroute-model-$(echo "$1" | tr '/' '-').json)" C
  # v4.3.1·F: transport 容错 → "000" 走 WARN 分支
  C=$(curl -s -o "$F" -w "%{http_code}" --connect-timeout 5 --max-time 15 -b "$COOKIE_FILE" -X POST "$BASE_URL/api/provider-models" \
    -H "Content-Type: application/json" -d "$(jq -n --arg provider "nvidia" --arg modelId "$MODEL_ID" '{provider:$provider, modelId:$modelId}')" 2>/dev/null || echo "000")
  if [ "$C" = "200" ] || [ "$C" = "201" ]; then echo "[init] model $MODEL_ID OK"
  elif [ "$C" = "409" ]; then echo "[init] model $MODEL_ID exists"
  else echo "[init] model $MODEL_ID WARN $C"; cat "$F" 2>/dev/null || true; fi
}
# v4.3.1·H: deprecated 文件缺失兜底 (防 grep -v 空转吞掉全部模型)
[ -f /tmp/nim-deprecated.txt ] || : > /tmp/nim-deprecated.txt
while IFS= read -r _M; do [ -z "$_M" ] && continue; register_model "$_M"; done < <(build_all_models | { grep -Fxvf /tmp/nim-deprecated.txt || true; })
echo "[init] Model registration done."

mapfile -t POOL_ALIVE  < <(filter_alive "${NIM_POOL_MODELS[@]}")
mapfile -t CODEX_ALIVE < <(filter_alive "${NIM_CODEX_MODELS[@]}")

# ⑦ first-init 也走幂等 upsert（根治 R2 restore 后撞名）
upsert_combo "nim-pool"  "$_POOL_STRATEGY"  ${POOL_ALIVE[@]+"${POOL_ALIVE[@]}"}
upsert_combo "nim-codex" "$_CODEX_STRATEGY" ${CODEX_ALIVE[@]+"${CODEX_ALIVE[@]}"}

context_accumulator_update
hf_snapshot
purge_proxy_db

# v4.3.1·F: marker 写入失败不杀 init (增量门可由 combos 存在兜底)
touch "$INIT_MARKER" 2>/dev/null || echo "[init] WARN: INIT_MARKER 写入失败 (增量门由 combos 兜底)."
echo "[init] Final health check..."
HEALTH_FILE="$(_resp omniroute-final-health.json)"
HEALTH_HTTP=$(curl -s -o "$HEALTH_FILE" -w "%{http_code}" --connect-timeout 5 --max-time 10 "$BASE_URL/api/monitoring/health" 2>/dev/null || echo "000")
[ "$HEALTH_HTTP" = "200" ] && echo "[init]   Status: $(jq -r '.status // "unknown"' "$HEALTH_FILE" 2>/dev/null || echo unknown) / $(jq -r '.version // "unknown"' "$HEALTH_FILE" 2>/dev/null || echo unknown)"
echo "[init] Done (first-init). v4.3.1"

``

## 文件: litestream.yml
``yaml
dbs:
  - path: /data/storage.sqlite
    replica:
      type: s3
      bucket: omniroute-data
      path: db/storage.sqlite
      endpoint: https://${R2_ACCOUNT_ID}.r2.cloudflarestorage.com
      access-key-id: ${R2_ACCESS_KEY_ID}
      secret-access-key: ${R2_SECRET_ACCESS_KEY}
      region: auto
      sync-interval: 10s
      # v4.3 红线3: 改 false. entrypoint.sh 已显式 restore (含本地非空 guard + 临时路径 + quick_check);
      # 若 auto-recover true, litestream replicate 启动时自恢复会绕过 entrypoint 的 guard, 可能覆盖有效 DB.
      auto-recover: false

snapshot:
  interval: 1h
  retention: 24h

``

## 文件: package.json
``json
{
  "name": "omniroute-gate",
  "version": "4.3",
  "private": true,
  "description": "PSK (INTERNAL_PSK for /v1) + admin-token (GATE_ADMIN_TOKEN via Basic Auth for admin UI) gate in front of OmniRoute (HF Space :7860 -> :20128)",
  "main": "gate.js",
  "engines": {
    "node": ">=22.0.0"
  },
  "scripts": {
    "start": "node gate.js"
  },
  "dependencies": {
    "express": "^4.21.2"
  }
}

``

## 文件: README.md
``markdown
---
title: Omn
emoji: 🚀
colorFrom: blue
colorTo: indigo
sdk: docker
pinned: false
license: mit
app_port: 7860
---
``

## 文件: entrypoint.sh
``bash
#!/bin/sh
# entrypoint.sh — v4.3 candidate (Stage D)
# OmniRoute + LiteStream + NIM init + gate.js 编排
#
# 红线 3 (LiteStream): restore 前判本地文件存在且非空则跳过; 临时路径原子; 不可覆盖有效 DB.
# 进程监督: trap SIGTERM/SIGINT 转发, 子进程 PID 保存, wait 回收, 任一关键进程退出停其余, 无孤儿.
# POSIX sh: 无 bash 数组/`mapfile`/`[[`.
# 复制非致命 vs 严格: LITESTREAM_STRICT=1 时 restore 复制失败 safe-fail exit; 0 时 warn 继续.

set -e

[ -z "$OMNIROUTE_PORT" ] && OMNIROUTE_PORT=20128
[ -z "$EXPOSED_PORT" ] && EXPOSED_PORT=7860
[ -z "$DATA_DIR" ] && DATA_DIR=/data
[ -z "$CALL_LOGS_TABLE_MAX_ROWS" ] && CALL_LOGS_TABLE_MAX_ROWS=100000
[ -z "$PROXY_LOGS_TABLE_MAX_ROWS" ] && PROXY_LOGS_TABLE_MAX_ROWS=100000
# 复制失败模式开关: 严格(exit) 或 非致命(warn+continue). 默认严格 (红线3 safe-fail).
[ -z "$LITESTREAM_STRICT" ] && LITESTREAM_STRICT=1

DB="$DATA_DIR/storage.sqlite"
DB_TMP="$DATA_DIR/.storage.sqlite.restore.$$"   # 临时恢复路径 (原子保护)

# 子进程 PID 全局 (POSIX sh 用变量, 不用数组)
OR_PID=""
INIT_PID=""
LS_PID=""      # litestream replicate PID
GATE_PID=""

cleanup_done=0
# trap 转发: 向仍存活子进程发 SIGTERM, 短 grace 后 SIGKILL, wait 回收
_forward_signal() {
  sig="$1"
  for pid in "$OR_PID" "$INIT_PID" "$LS_PID" "$GATE_PID"; do
    [ -z "$pid" ] && continue
    kill -0 "$pid" 2>/dev/null && kill -"$sig" "$pid" 2>/dev/null || true
  done
}
_shutdown() {
  [ "$cleanup_done" = 1 ] && return
  cleanup_done=1
  echo "[entrypoint] shutdown: forwarding SIGTERM to children..."
  _forward_signal TERM
  # grace 短等
  g=0
  while [ "$g" -lt 50 ]; do
    alive=0
    for pid in "$OR_PID" "$INIT_PID" "$LS_PID" "$GATE_PID"; do
      [ -z "$pid" ] && continue
      kill -0 "$pid" 2>/dev/null && alive=1
    done
    [ "$alive" = 0 ] && break
    sleep 0.1 2>/dev/null || sleep 1
    g=$((g + 1))
  done
  # 残留 SIGKILL (无孤儿)
  echo "[entrypoint] shutdown: force-kill残留..."
  _forward_signal KILL
  # wait 回收
  for pid in "$OR_PID" "$INIT_PID" "$LS_PID" "$GATE_PID"; do
    [ -z "$pid" ] && continue
    wait "$pid" 2>/dev/null || true
  done
  echo "[entrypoint] shutdown complete."
  exit 0
}
trap '_shutdown' TERM
trap '_shutdown' INT

echo "[entrypoint] cold-boot (restore→purge→replicate→OmniRoute, 严格时序)..."
echo "[entrypoint] OMNIROUTE_PORT=$OMNIROUTE_PORT EXPOSED_PORT=$EXPOSED_PORT DATA_DIR=$DATA_DIR STRICT=$LITESTREAM_STRICT"

# ── 文件锁: 防多容器同时 restore/purge/替换 $DB ───────────
# P3: LOCK_FILE 可配置 (多容器部署置共享卷路径获跨容器互斥; 默认 $DATA_DIR/.entrypoint.lock 同旧硬编码).
#   获锁前断言 LOCK_FILE 所在目录可写: 不可写 → WARN 降级无锁继续 (不 exit 1), 记原因 + 实际锁路径.
#   flock 获取逻辑/失败行为不改 (flock 不可用仍 WARN 跳过; flock 失败仍 exit 1).
LOCK_FD=9
LOCK_FILE="${LOCK_FILE:-${DATA_DIR}/.entrypoint.lock}"
_lock_dir=$(dirname "$LOCK_FILE")
if [ -w "$_lock_dir" ]; then
  :
else
  echo "[entrypoint] WARN: 锁目录不可写 ..." >&2
fi
echo "[entrypoint] flock path=$LOCK_FILE"
if command -v flock >/dev/null 2>&1; then
  if ! exec 9>"$LOCK_FILE" 2>/dev/null; then
    # 目录不可写: 走上面已声明的 WARN 降级语义, 不 exit
    echo "[entrypoint] WARN: 无法打开锁文件 $LOCK_FILE (dir 不可写或权限不足) → 降级无锁继续." >&2
  elif ! flock -n -x 9; then
    echo "[entrypoint] FATAL: 锁被占用 $LOCK_FILE (另一进程持有). abort." >&2
    exit 1
  else
    echo "[entrypoint] lock acquired (flock $LOCK_FILE, fd 9)."
  fi
else
  echo "[entrypoint] WARN: flock 不可用, 跳过跨容器互斥 (HF Space 优先单实例)."
fi

# ── 1. Litestream restore (启动前; 红线3: 不覆盖有效 DB) ─
# 设计原则 (优雅降级):
#   R2 无副本 → -if-replica-exists 返回 0 但不创建文件 → 空库启动 (init 重建), 不 exit
#   restore 命令失败 (配置/网络/权限错误) → WARN + 空库启动, 不 exit
#   restore 成功+有文件 → quick_check 通过 → 原子 mv → 正式 $DB
#   restore 成功+quick_check 失败 → 丢弃临时+空库启动, 不 exit
# STRICT 仅控制日志级别 (STRICT=1 多打一行 WARN), 不控制 exit. 永远不因 restore 失败而 FATAL exit.
has_r2=0
[ -n "$R2_ACCESS_KEY_ID" ] && [ -n "$R2_SECRET_ACCESS_KEY" ] && [ -n "$R2_ACCOUNT_ID" ] && has_r2=1

if [ "$has_r2" = 0 ]; then
  echo "[entrypoint] R2 creds 缺失 → skip restore. 空库启动 (init 重建)."
elif [ -f "$DB" ] && [ -s "$DB" ]; then
  echo "[entrypoint] 本地 DB 非空 ($DB) → skip restore (红线3: 不覆盖有效 DB)."
else
  # 本地 DB 空或不存在 → restore.
  # litestream 0.5.9 restore 参数 = 数据库标识符 (litestream.yml dbs[].path 匹配 = $DB), 不是输出路径.
  # 优先 -o "$DB_TMP" 输出临时路径 → 原子 mv. 若 -o 不支持 → 回退直接 $DB restore (冷启动 $DB 空, 无有效 DB 被覆盖).
  rm -f "$DB_TMP" "$DB_TMP-wal" "$DB_TMP-shm"
  printf '%s' "" > /tmp/ls_restore.err
  rc=0
  litestream restore -config /litestream.yml -if-replica-exists -o "$DB_TMP" "$DB" 2>/tmp/ls_restore.err || rc=$?
  used_tmp=1
  if echo "$(cat /tmp/ls_restore.err 2>/dev/null)" | grep -qiE 'unknown flag|invalid option|flag provided but not defined.*-o'; then
    echo "[entrypoint] litestream 0.5.9 不支持 -o → 回退直接 restore $DB (冷启动 $DB 空, 安全)."
    rm -f "$DB_TMP" "$DB_TMP-wal" "$DB_TMP-shm"
    printf '%s' "" > /tmp/ls_restore.err
    rc=0
    litestream restore -config /litestream.yml -if-replica-exists "$DB" 2>/tmp/ls_restore.err || rc=$?
    used_tmp=0
  fi

  if [ "$rc" -ne 0 ]; then
    # restore 命令失败 (配置/网络/权限) → 空库启动 WARN, 不 exit
    echo "[entrypoint] WARN: restore rc=$rc (见 /tmp/ls_restore.err; 已脱敏, 不打凭据)."
    [ "$LITESTREAM_STRICT" = 1 ] && echo "[entrypoint]   STRICT=1: 仅告警, 不 exit (空库启动)."
    rm -f "$DB_TMP" "$DB_TMP-wal" "$DB_TMP-shm" 2>/dev/null || true
  elif [ "$used_tmp" = 1 ] && { [ ! -f "$DB_TMP" ] || [ ! -s "$DB_TMP" ]; }; then
    # rc=0 但临时文件不存在或空 → R2 无副本 → 空库启动 (正常, 不 WARN 不 exit)
    echo "[entrypoint] restore rc=0 但无文件 (R2 无副本或首次部署). 空库启动, init 重建配置."
    rm -f "$DB_TMP" "$DB_TMP-wal" "$DB_TMP-shm" 2>/dev/null || true
  elif [ "$used_tmp" = 1 ]; then
    # 临时文件有效 → quick_check → 原子 mv
    qc_ok=0
    if command -v sqlite3 >/dev/null 2>&1; then
      if sqlite3 "$DB_TMP" "PRAGMA quick_check;" 2>/dev/null | grep -q "^ok$"; then
        qc_ok=1
      else
        echo "[entrypoint] WARN: quick_check 失败. 丢弃临时 $DB_TMP, 空库启动."
        [ "$LITESTREAM_STRICT" = 1 ] && echo "[entrypoint]   STRICT=1: 仅告警, 不 exit."
        rm -f "$DB_TMP" "$DB_TMP-wal" "$DB_TMP-shm" 2>/dev/null || true
      fi
    else
      echo "[entrypoint] sqlite3 不可用, 跳过 quick_check (验文件非空)."
      qc_ok=1
    fi
    if [ "$qc_ok" = 1 ]; then
      mv "$DB_TMP" "$DB" && echo "[entrypoint] restore complete (原子 mv $DB_TMP → $DB)."
    fi
  else
    # used_tmp=0 (直接 $DB restore): 验 $DB 非空 (R2 无副本文件) + quick_check
    if [ ! -f "$DB" ] || [ ! -s "$DB" ]; then
      echo "[entrypoint] restore rc=0 但 $DB 无文件 (R2 无副本或首次部署). 空库启动, init 重建."
    elif command -v sqlite3 >/dev/null 2>&1; then
      if sqlite3 "$DB" "PRAGMA quick_check;" 2>/dev/null | grep -q "^ok$"; then
        echo "[entrypoint] restore complete (直接 $DB, quick_check ok)."
      else
        echo "[entrypoint] WARN: quick_check 失败 on $DB. 空库启入替换."
        rm -f "$DB" "$DB-wal" "$DB-shm" 2>/dev/null || true
      fi
    else
      echo "[entrypoint] restore complete (直接 $DB, 文件非空)."
    fi
  fi
fi

# ── 2. FIX #5 pre-purge: OmniRoute 启动 *前*, 事务化, 精确条件, 加 assert ──
# B6 源码实证 (L2): runtime patchedFetch (proxyFetch.ts:637) 用内存 account.proxy (pool load 时
# 一次性从 SQLite proxy_registry 读取, proxies.ts:806), 不查 provider_connections.proxy_enabled,
# 无 reload 钩子 → purge 改 SQLite 但 OmniRoute 进程已加载旧条目 → 旧 20129 幽灵 entry 持续.
# 本段在 OmniRoute 启动 *前* SQL-only 清 20129 条目 → pool load 时 SQLite 已无幽灵 → direct 路径.
# purge 时机: 必在 restore 后 (R2 旧库会带回旧条目) → OmniRoute 前. 永不: purge→restore→OmniRoute.
# 删除依据: 精确 host+port 条件 (非 "总数=20129").
# assert: purge 后目标条目残留必须为 0, 否则整个容器 exit (绝不让幽灵条目进 OmniRoute).
[ "$_PURGE_PROXY" != "0" ] && _PURGE_PROXY=1    # NIM_PURGE_PROXY=0 可关全段
if [ -n "$DB" ] && [ -f "$DB" ] && [ -x "$(command -v sqlite3 2>/dev/null || true)" ] && [ "$_PURGE_PROXY" = "1" ]; then
  sql_e5(){ printf '%s' "$1" | sed "s/'/''/g"; }
  _P5=${NIM_PROXY_RELAY_PORT:-20129}
  _H5=${NIM_PROXY_RELAY_HOST:-127.0.0.1}
  _SQLITE3_BIN=$(command -v sqlite3 2>/dev/null || true)
  _SQLITE_RAN=0   # 标记 wal_checkpoint 行 (P5) 与 deleted=N (P4) 是否真输出
  if [ -n "$_SQLITE3_BIN" ]; then
    _pre=$(sqlite3 "$DB" "SELECT COUNT(*) FROM proxy_registry WHERE host IN ('127.0.0.1','::1','localhost','0.0.0.0') AND port=$_P5;" 2>/dev/null || echo "?")
    echo "[entrypoint] FIX #5 pre-purge: relay ${_H5}:${_P5} purge 前=$_pre 条 (host IN 四本地地址变体 + port 约束)."
    # 事务化 purge (BEGIN...COMMIT 包裹): 三条 DELETE 原子提交, 中断回滚不留半状态.
    # P4: WHERE 扩 host IN ('127.0.0.1','::1','localhost','0.0.0.0') + port=$_P5 (保留 port 约束).
    purge_rc=0
    sqlite3 "$DB" <<SQL 2>/tmp/purge.err || purge_rc=$?
BEGIN;
DELETE FROM proxy_assignments WHERE proxy_id IN
  (SELECT id FROM proxy_registry WHERE host IN ('127.0.0.1','::1','localhost','0.0.0.0') AND port=$_P5);
UPDATE provider_connections SET proxy_enabled=0 WHERE provider='nvidia';
DELETE FROM proxy_registry WHERE host IN ('127.0.0.1','::1','localhost','0.0.0.0') AND port=$_P5;
COMMIT;
SQL
    if [ "$purge_rc" -ne 0 ]; then
      echo "[entrypoint] FATAL: pre-purge 事务失败 rc=$purge_rc (见 /tmp/purge.err). abort 启动 (不能让旧条目进 OmniRoute 内存)." >&2
      exit 1
    fi
    # P4: purge 事务提交后用 changes() 取实际删除行数 (proxy_registry DELETE 行数).
    _purge_del=$(sqlite3 "$DB" "SELECT changes();" 2>/dev/null || echo "?")
    echo "[entrypoint] pre-purge deleted=${_purge_del} rows"
    _SQLITE_RAN=1
    # P5: WAL checkpoint (TRUNCATE) 后读 busy/log/checkpointed 三值; busy>0 WARN 不 exit 1.
    _ckpt=$(sqlite3 "$DB" "PRAGMA wal_checkpoint(TRUNCATE);" 2>/dev/null | tr '|' '\t' || echo "")
    # sqlite3 CLI 默认 pipe 分隔返回 busy\tlog\tcheckpointed 三列
    _ck_busy=$(printf '%s' "$_ckpt" | cut -f1)
    _ck_log=$(printf '%s' "$_ckpt" | cut -f2)
    _ck_ckptd=$(printf '%s' "$_ckpt" | cut -f3)
    echo "[entrypoint] wal_checkpoint busy=${_ck_busy:-?} log=${_ck_log:-?} checkpointed=${_ck_ckptd:-?}"
    if [ -n "$_ck_busy" ] && [ "$_ck_busy" -gt 0 ] 2>/dev/null; then
      echo "[entrypoint] WARN: wal_checkpoint busy=${_ck_busy}, WAL not fully checkpointed (Litestream 占 WAL reader 正常, 不阻断启动)." >&2
    fi
    rm -f "$DB-wal" "$DB-shm" 2>/dev/null || true
    # assert: 目标条目残留必须为 0, 否则整个容器 exit (B6 根因硬约束)
    _post=$(sqlite3 "$DB" "SELECT COUNT(*) FROM proxy_registry WHERE host IN ('127.0.0.1','::1','localhost','0.0.0.0') AND port=$_P5;" 2>/dev/null || echo "?")
    echo "[entrypoint] FIX #5 pre-purge: relay ${_H5}:${_P5} purge 后=$_post 条 (必须=0)."
    if [ "$_post" != "0" ]; then
      echo "[entrypoint] FATAL: pre-purge assert 失败 (残留=$_post !=0). 幽灵条目将污染 OmniRoute 内存. 整个容器 exit." >&2
      exit 1
    fi
    echo "[entrypoint] ✓ pre-purge assert pass (残留=0). SQLite 已无 ${_P5} relay → pool load direct 路径."
  else
    # P4/P5 fallback: sqlite3 CLI 不可用 → 改 node -e + node:sqlite (Node22+ experimental) 做同等 purge+checkpoint+assert.
    echo "[entrypoint] FIX #5 pre-purge: sqlite3 CLI 缺 → fallback node:sqlite 做 purge+checkpoint+assert."
    _P5_N="$_P5" _DB_N="$DB" _H5_N="$_H5" node -e '
      const { DatabaseSync } = require("node:sqlite");
      const dbPath = process.env._DB_N, port = Number(process.env._P5_N), host = process.env._H5_N;
      const hosts = ["127.0.0.1","::1","localhost","0.0.0.0"];
      const placeholders = "(" + hosts.map(()=>"?").join(",") + ")";
      let db;
      try { db = new DatabaseSync(dbPath); } catch (e) { console.error("[entrypoint] FATAL: node:sqlite 打开 $DB 失败: " + e.message); process.exit(1); }
      // WAL mode + checkpoint helper
      const q = (s,p=[]) => { const st = db.prepare(s); return p.length ? st.all(...p) : st.all(); };
      const pre = db.prepare("SELECT COUNT(*) AS c FROM proxy_registry WHERE host IN " + placeholders + " AND port=?").all(...hosts, port)[0].c;
      console.log("[entrypoint] FIX #5 pre-purge: relay " + host + ":" + port + " purge 前=" + pre + " 条 (host IN 四本地地址变体 + port 约束).");
      try {
        db.exec("BEGIN");
        db.prepare("DELETE FROM proxy_assignments WHERE proxy_id IN (SELECT id FROM proxy_registry WHERE host IN " + placeholders + " AND port=?)").run(...hosts, port);
        db.prepare("UPDATE provider_connections SET proxy_enabled=0 WHERE provider=?").run("nvidia");
        const del = db.prepare("DELETE FROM proxy_registry WHERE host IN " + placeholders + " AND port=?").run(...hosts, port);
        db.exec("COMMIT");
        console.log("[entrypoint] pre-purge deleted=" + del.changes + " rows");
        try {
          const ck = db.prepare("PRAGMA wal_checkpoint(TRUNCATE)").get();
          const busy = String(ck && ck.busy != null ? ck.busy : "?");
          const log = String(ck && ck.log != null ? ck.log : "?");
          const ckptd = String(ck && ck.checkpointed != null ? ck.checkpointed : "?");
          console.log("[entrypoint] wal_checkpoint busy=" + busy + " log=" + log + " checkpointed=" + ckptd);
          if (!isNaN(Number(busy)) && Number(busy) > 0) {
            console.error("[entrypoint] WARN: wal_checkpoint busy=" + busy + ", WAL not fully checkpointed (Litestream 占 WAL reader 正常, 不阻断启动).");
          }
        } catch (e) { console.log("[entrypoint] wal_checkpoint busy=? log=? checkpointed=? (pragma 失败: " + e.message + ")"); }
        const post = db.prepare("SELECT COUNT(*) AS c FROM proxy_registry WHERE host IN " + placeholders + " AND port=?").all(...hosts, port)[0].c;
        console.log("[entrypoint] FIX #5 pre-purge: relay " + host + ":" + port + " purge 后=" + post + " 条 (必须=0).");
        if (String(post) !== "0") { console.error("[entrypoint] FATAL: pre-purge assert 失败 (残留=" + post + " !=0). 幽灵条目将污染 OmniRoute 内存. 整个容器 exit."); db.close(); process.exit(1); }
        console.log("[entrypoint] ✓ pre-purge assert pass (残留=0). SQLite 已无 " + port + " relay → pool load direct 路径.");
        db.close();
      } catch (e) {
        console.error("[entrypoint] FATAL: pre-purge 事务失败 (" + e.message + "). abort 启动 (不能让旧条目进 OmniRoute 内存).");
        try { db.exec("ROLLBACK"); } catch (_) {}
        db.close(); process.exit(1);
      }
    ' || { echo "[entrypoint] FATAL: node:sqlite purge fallback 失败. abort." >&2; exit 1; }
    _SQLITE_RAN=1
  fi
else
  echo "[entrypoint] FIX #5 pre-purge: skip (DB 未就绪/sqlite3 缺/NIM_PURGE_PROXY=0)."
fi

# ── 3. LiteStream replicate (后台启动, OmniRoute 启动 *前*) ─
# 顺序: restore→purge→replicate→OmniRoute. litestream 先占 purge 后干净 $DB 作 L0 baseline,
# OmniRoute 后续写入 WAL → litestream 复制新 generation 不被旧 L0 覆盖.
# 验: litestream.yml dbs[].path = /data/storage.sqlite = $DB (匹配, 非 $DB_TMP).
export NODE_OPTIONS="--max-old-space-size=4096"
if [ "$has_r2" = 1 ]; then
  mkdir -p "$DATA_DIR" 2>/dev/null || true
  # 删除可能残留的临时 -wal/-shm (purge 后正式 $DB 可能落 wal; litestream 启前清, replicate 会从 $DB 重建基线)
  echo "[entrypoint] Starting Litestream replication (OmniRoute 启动前, 占 purge 后干净 baseline)..."
  # 验 matches litestream.yml dbs[].path
  printf '%s' "$DB" | grep -q "^${DATA_DIR}/storage.sqlite$" || {
    echo "[entrypoint] FATAL: \$DB=$DB 与 litestream.yml dbs[].path 不一致 → replicate db-path 不匹配." >&2; exit 1; }
  litestream replicate -config /litestream.yml &
  LS_PID=$!
  sleep 1
  if ! kill -0 "$LS_PID" 2>/dev/null; then
    echo "[entrypoint] FATAL: Litestream replicate 退出过早 (config/R2 错误? 见 stderr). abort." >&2
    [ "$LITESTREAM_STRICT" = 1 ] && exit 1 || { LS_PID=""; echo "[entrypoint] STRICT=0: 降级无 replicate 继续."; }
  else
    echo "[entrypoint] Litestream PID=$LS_PID (replicate $DB → R2)."
  fi
else
  echo "[entrypoint] WARN: LiteStream replication disabled (无 R2 creds). STRICT=$LITESTREAM_STRICT."
fi

# ── 4. OmniRoute (启动在 purge + replicate 之后) ──────────
echo "[entrypoint] starting OmniRoute via /app/server.js (PIDs OR=$OR_PID background)..."
PORT="$OMNIROUTE_PORT" \
DATA_DIR="$DATA_DIR" \
REQUIRE_API_KEY=true \
HOSTNAME=127.0.0.1 \
NIM_MODE="$NIM_MODE" \
DISABLE_SQLITE_AUTO_BACKUP=true \
PROVIDER_LIMITS_SYNC_INTERVAL_MINUTES=1440 \
CALL_LOGS_TABLE_MAX_ROWS="$CALL_LOGS_TABLE_MAX_ROWS" \
PROXY_LOGS_TABLE_MAX_ROWS="$PROXY_LOGS_TABLE_MAX_ROWS" \
JWT_SECRET="$JWT_SECRET" \
API_KEY_SECRET="$API_KEY_SECRET" \
OMNIROUTE_API_KEY="$OMNIROUTE_API_KEY" \
INITIAL_PASSWORD="$INITIAL_PASSWORD" \
NODE_OPTIONS="--max-old-space-size=4096" \
node /app/server.js --log &
OR_PID=$!
echo "[entrypoint] OmniRoute PID=$OR_PID"

echo "[entrypoint] waiting for health (max 180s)..."
i=0
while [ "$i" -lt 180 ]; do
  kill -0 "$OR_PID" 2>/dev/null || { echo "[entrypoint] FATAL: OmniRoute exited early"; _shutdown; exit 1; }
  curl -sf --max-time 3 "http://127.0.0.1:$OMNIROUTE_PORT/api/monitoring/health" >/dev/null 2>&1 && { echo "[entrypoint] ready after ${i}s"; break; }
  sleep 2; i=$((i + 2))
done
[ "$i" -ge 180 ] && { echo "[entrypoint] FATAL: not ready within 180s"; _shutdown; exit 1; }

# ── 版本护栏 (只告警不中断) ──────────────────────────────
EXPECTED_OR_VERSION="${EXPECTED_OR_VERSION:-3.8.43}"
_OR_VER=$(curl -sf --max-time 3 "http://127.0.0.1:$OMNIROUTE_PORT/api/monitoring/health" 2>/dev/null | jq -r '.version // "unknown"' 2>/dev/null || echo "unknown")
echo "[entrypoint] base version: $_OR_VER (expected $EXPECTED_OR_VERSION)"
if [ "$_OR_VER" != "$EXPECTED_OR_VERSION" ] && [ "$_OR_VER" != "unknown" ]; then
  echo "[entrypoint] WARN: 版本($_OR_VER)与期望($EXPECTED_OR_VERSION)不一致——疑似 FROM 漂移。"
fi

# ── NIM init (后台) ───────────────────────────────────────
echo "[entrypoint] running NIM init in background..."
bash /entrypoint-init-nim.sh &
INIT_PID=$!
echo "[entrypoint] init PID=$INIT_PID"

# ── OR_API_KEY file 等待 ──────────────────────────────────
if [ -n "$OMNIROUTE_API_KEY" ]; then
  echo "[entrypoint] OMNIROUTE_API_KEY set, env-bypass 模式，跳过等待 .or-api-key。"
else
  echo "[entrypoint] waiting for OR_API_KEY (max 120s)..."
  j=0
  while [ "$j" -lt 120 ]; do
    [ -f "/data/.or-api-key" ] && [ -s "/data/.or-api-key" ] && { echo "[entrypoint] OR_API_KEY ready"; break; }
    kill -0 "$OR_PID" 2>/dev/null || { echo "[entrypoint] FATAL: OmniRoute exited waiting key"; _shutdown; exit 1; }
    sleep 2; j=$((j + 2))
  done
  [ ! -s "/data/.or-api-key" ] && { echo "[entrypoint] FATAL: OR_API_KEY not created"; _shutdown; exit 1; }
fi

# ── 启动前: OmniRoute 健康二次确认 ────────────────────────
# 若 OmniRoute 已退出, 不启 gate (避免孤儿)
if ! kill -0 "$OR_PID" 2>/dev/null; then
  echo "[entrypoint] FATAL: OmniRoute died before gate. abort." >&2
  _shutdown; exit 1
fi

echo "[entrypoint] starting gate on port $EXPOSED_PORT..."
node /gate/gate.js &
GATE_PID=$!
echo "[entrypoint] gate PID=$GATE_PID"

# ── 监督循环: 任一关键进程退出 → 停其余 ──────────────────
# gate 为对外服务; OmniRoute 为必需; init 非致命 (告警). litestream 退出按 STRICT.
while true; do
  # gate 退出 (对外不服务) → 停一切
  if ! kill -0 "$GATE_PID" 2>/dev/null; then
    echo "[entrypoint] gate exited. 停止其余并退出."
    _shutdown; exit 1
  fi
  # OmniRoute 退出 → 停一切
  if ! kill -0 "$OR_PID" 2>/dev/null; then
    echo "[entrypoint] OmniRoute exited. 停止其余并退出."
    _shutdown; exit 1
  fi
  # init 退出 (非致命) → 仅日志
  if [ -n "$INIT_PID" ] && ! kill -0 "$INIT_PID" 2>/dev/null; then
    [ "$_init_logged" = 1 ] || { echo "[entrypoint] NIM init 已退出 (非致命)."; _init_logged=1; }
  fi
  # litestream 退出 → 按 STRICT (严格 exit, 非致命告警并标记 PID 空)
  if [ -n "$LS_PID" ] && ! kill -0 "$LS_PID" 2>/dev/null; then
    if [ "$LITESTREAM_STRICT" = 1 ]; then
      echo "[entrypoint] FATAL: Litestream replicate exited (strict). 停止."
      _shutdown; exit 1
    else
      echo "[entrypoint] WARN: Litestream replicate exited (非致命). DB 不再备份 (LITESTREAM_STRICT=0)."
      LS_PID=""
    fi
  fi
  sleep 1
done

``


