// gate.js — v4.3 candidate (Stage D)
// 上游 PSK 出口 Proxy (HF Space :7860 -> 127.0.0.1:20128)
// 唯一出口代理, 经 上游 直连, 无外部 Relay / cf-worker / context-relay.
//
// 暴露面 (单布尔开关后台 GATE_ADMIN_ENABLED === '1'):
//   关 (未设/非 '1'): 后台关闭, 外网仅 GET /healthz + /v1 + /v1/*; 其余全 404 (门藏).
//   开 (=== '1'): 后台全路径**无闸**直透传 上游 (无 Basic Auth 框/无凭据验/无 cookie);
//     后台自身的写执行鉴权全交 上游 自身 INITIAL_PASSWORD(bcrypt) + loginGuard(IP 锁) + JWT session.
// 三类入口分离: /healthz(免认证) | /v1,/v1/*(INTERNAL_PSK) | 其余全路径(GATE_ADMIN_ENABLED 开时直透传, 关时 404).
//   互不回退, PSK 不访问后台, 后台路径不走 PSK.
// gate 层不做入口认证 (砍 Basic Auth: 浏览器原生框反复弹弊大于利); Gate 不注入 Session, 不伪造 Cookie.
// 红线 (PSK): 缺失/格式错/长度不同/内容不同 → 401; crypto.timingSafeEqual 常量时间; 长度不等不退字符串比较.
// SSE: 逐块转发 (不聚合), 不 text/json 读流, 尊重背压, 客户端断开取消上游, 清理监听/定时器/流.
// 进程: SIGTERM/SIGINT 自处理优雅关 (entrypoint.sh trap 亦转发).
// 无第二套限流: 28 RPM/1 并发/2200ms 由 上游 requestQueue 执行, 本文件零限流代码.
// IP/CIDR 限制: 不默认实现 (HF 代理拓扑未验证, 无 L1 证据 trust proxy); 预留能力默认关, KNOWN-UNVERIFIED 记.

const express = require('express');
const http = require('http');
const crypto = require('crypto');
const fs = require('fs');

const INTERNAL_PSK = process.env.INTERNAL_PSK || '';
const ADMIN_ENABLED = process.env.GATE_ADMIN_ENABLED === '1';   // 纯布尔开关: 仅确置 '1' 开后台; 未设/'0'/任意他值均关 (保守 fail-closed)
const OR_PORT = parseInt(process.env.OMNIROUTE_PORT || '20128', 10);
const GATE_PORT = parseInt(process.env.EXPOSED_PORT || '7860', 10);
const UPSTREAM_TIMEOUT_MS = parseInt(process.env.GATE_UPSTREAM_TIMEOUT_MS || '30000', 10) || 30000;
const SHUTDOWN_GRACE_MS = parseInt(process.env.GATE_SHUTDOWN_GRACE_MS || '5000', 10) || 5000;

// ── FT (FlareTunnel) 桥本地端端口 (路3 路3-b 反代) ──────────────
// entrypoint export FT_PORTS "空格分隔端口串" (多桥) / FT_PORT (单桥回退 8080).
// FT 桥监听 127.0.0.1:$PORT, 同端口 /healthz + /metrics (Host 守卫非 127.0.0.1:PORT 不命中).
// gate 现役惯例 "首桥代整体" (init-nim-keys.sh _ft_register_proxy 多桥 healthz 读 [0].port);
//   /v1/ft/metrics 默认取首桥, ?bridge=index (0-基) 选特定桥, 越界回 400.
const FT_PORTS_LIST = (process.env.FT_PORTS || '').split(/\s+/).map(s => parseInt(s, 10)).filter(n => Number.isInteger(n) && n > 0);
const FT_PORT_SINGLE = parseInt(process.env.FT_PORT || process.env.FT_PROXY_PORT || '8080', 10);
if (!Number.isInteger(FT_PORT_SINGLE) || FT_PORT_SINGLE <= 0) { /* 兜 8080 */ }
const FT_HOST = process.env.FT_PROXY_HOST || '127.0.0.1';
const FT_BRIDGES = FT_PORTS_LIST.length > 0 ? FT_PORTS_LIST : [8080];  // FT 未启 (FT_PORTS 空) 时仍 8080 兜, /v1/ft/metrics 取时 503

// ── #4 context guard 配置 (2026-07-25 裁 b): 单阈值字节硬拦 ──────────────────
// 斩病链首环: 400-context-overflow → N×round-robin fallback 同体转发 → heap OOM → Space shutdown.
// 病链根因: omn 计数偏 NVIDIA 实测 ~40% (自认 212813 vs 实测 297040); 200000 软限+压缩(仅省3%)
//   数学上不防 400 → real_context 降级为"压缩 Governor"非"防400盾"; 改上游 src 拓扑上需双部署重建
//   (生产官方镜像+http-proxy-middleware gate, dev 自建GHCR+手写http gate, auth.ts 是 Next.js 打包产物)
//   故改 gate 自有代码(§5零风险, dev Dataset push+Restart 即生效).
// 标定: dev+生产两起真实 400 的 NVIDIA 实测比率上界 = 8 bytes/token (弹H 3900147B→487511tok);
//   est = bytes/8 > 195000 ⟺ bytes > 1.56MB, 灰区估算数学退化(三段式零收益复杂度), 故单阈值.
//   1500000B @8B/tok ≈ 187500 tok, 距 200000 软限留 12500 余量给 tokenizer 波动/39-tools schema 口径差(实测偏差40%).
// KNOWN-LIMITATION: 无 content-length 的 chunked 上传不拦 (现有客户端日志均带 content-length);
//   比率 <8 的假想流量可能漏拦, 由 NODE_OPTIONS 4096 + fallback exhaustion 终态兜底, (a) 落地后闭合.
const CTX_GUARD_ENABLED = process.env.GATE_CTX_GUARD_ENABLED !== '0';
const CTX_MAX_BYTES = parseInt(process.env.GATE_CTX_MAX_BYTES || '1500000', 10) || 1500000;
const CTX_BYTES_PER_TOKEN = parseInt(process.env.GATE_CTX_BYTES_PER_TOKEN || '8', 10) || 8;

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

// ── 后台开关 (纯布尔 GATE_ADMIN_ENABLED === '1', 仅作暴露面开关, 不作入口认证) ──
// '1' → 后台全路径开放**无闸**直透传 OR; 非 '1' (未设/空/'0'/任意他值) → 后台全 404 (门藏).
// 不弹 Basic Auth 框 (浏览器原生框反复弹弊大于利); 后台写执行认证全交 OR 自身
// INITIAL_PASSWORD (bcrypt) + loginGuard (5次/15min IP锁) + JWT session 兜底.
console.log(`[gate] admin UI: ${ADMIN_ENABLED ? 'enabled' : 'disabled'} (GATE_ADMIN_ENABLED 开关状态).`);
console.log(`[gate] FT bridges: ${FT_BRIDGES.join(',')} (FT_PORTS env, 首桥代整体; /v1/ft/metrics 反代 FT 本地端).`);

// timing-safe equal: 双方 Buffer, 长度不等先返回不泄露内容, 长度相等路径走 timingSafeEqual.
function safeEqual(a, b) {
  if (!a || !b) return false;
  const ba = Buffer.from(a);
  const bb = Buffer.from(b);
  if (ba.length !== bb.length) return false;
  return crypto.timingSafeEqual(ba, bb);
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
      level: fields.level || 'error',
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

// ── 暴露面 (单布尔开关: 默认仅 /healthz + /v1; GATE_ADMIN_ENABLED==='1' 时其余全路径走后台) ──
//   非 /healthz / 非 /v1: 须 GATE_ADMIN_ENABLED==='1', 否则 404 (门关即全 404, 不泄露后台是否存在).
app.use((req, res, next) => {
  req._normPath = normalizePath(req.path);
  if (shuttingDown && req._normPath !== '/healthz') return res.status(503).json({ ok: false });
  if (req._normPath === '/healthz') return next();
  if (req._normPath === '/v1' || req._normPath.startsWith('/v1/')) return next();
  // 后台: GATE_ADMIN_ENABLED==='1' 时全路径直放行透传 OR (无闸);
  //   关时 (非 '1') 全 404 (门藏, 不暴露后台存在). 写执行认证交 OR 自身.
  if (!ADMIN_ENABLED) return res.status(404).end();
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

// ── #4 context guard: 超阈 body 在 gate 直拒 413, 不进 上游 堆 ──
// 斩断病链首环: 400-context-overflow → N×round-robin fallback 同体转发 → heap OOM → Space shutdown.
// 仅判 content-length 字节, 不缓冲 body (零内存开销, 不扰 SSE 流式); chunked 无 content-length 放行.
// 插入点在 PSK 校验后 (未认证请求已在 PSK 层 401, 不消耗本检查), proxyV1 前 (不进上游堆).
app.use('/v1', (req, res, next) => {
  if (!CTX_GUARD_ENABLED || req.method !== 'POST') return next();
  const cl = parseInt(req.headers['content-length'] || '0', 10);
  if (!cl || cl <= CTX_MAX_BYTES) return next();
  const estTokens = Math.floor(cl / CTX_BYTES_PER_TOKEN);
  logGate(req, { elapsedMs: Date.now() - (req._gateT0 || 0), httpStatus: 413,
    errorCode: 'CONTEXT_LENGTH_EXCEEDED', abortSource: 'gate_context_guard',
    destroyInitiator: null, msg: `context_guard_reject bytes=${cl} est_tokens=${estTokens}` });
  return res.status(413).json({ error: {
    type: 'context_length_exceeded',
    message: `Request body ${cl} bytes exceeds context guard (${CTX_MAX_BYTES}B, est ~${estTokens} tokens > 200000 budget). Reduce message length.`,
    est_tokens: estTokens, limit_bytes: CTX_MAX_BYTES,
  } });
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
    upstreamRes.on('end', () => {
      if (!res.writableEnded) res.end();
      // 正常成功/非 aborted 完成路径 logGate (此前只记 error/timeout 分支, 正常 200 不出日志
      // 致永续日志健康镜态 staging 零内容 — 圣上 2026-07-29 探针验证暴露此漏). 成功也记一行.
      if (!aborted && res.headersSent) {
        logGate(req, { elapsedMs: Date.now() - (req._gateT0 || 0),
          httpStatus: res.statusCode || 200, level: 'info', msg: 'upstream_completed' });
      }
    });
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
  // 不监 req 'close': body 读完 Node 正常 emit 'close' (非 client 真断), 旧版误判 clientAborted
  //   会 destroy upstreamReq, 掐断 OR 慢响应(如 /api/auth/login bcrypt 比对 100-300ms),
  //   致浏览器收 ECONNRESET 无提示进不去。真 client 中途断由 'aborted'/'error' 兜。
  //   响应已开始后 client 跑路由 res 'close' (见下), 仅响应头未发时才掐 upstream。
  res.on('close', () => { if (!res.headersSent) { clientAborted = true; cleanup(); } });

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

// ── /v1/ft/metrics: PSK 鉴权反代 FlareTunnel 桥本地 /metrics (路3-b, 2026-08-12 圣上令) ──
// PSK 校验靠前 /v1 app.use (line 187-198): Bearer INTERNAL_PSK safeEqual, 缺/错 fail-closed 401.
// 反代 FT 桥 127.0.0.1:$PORT/metrics (Prometheus text exposition, text/plain; version=0.0.4).
//   FT 桥本地端无鉴权 (127.0.0.1 Host 守卫), gate 此层做唯一公网鉴权门.
// 现役惯例 "首桥代整体" (init-nim-keys.sh _ft_register_proxy 多桥 healthz 读首桥);
//   ?bridge=index (0-基) 选特定桥, 越界/非数 → 400; 默认 bridge=0 首桥.
// FT 未启 (FT_PIDS 空): /metrics 上游 ECONNREFUSED → 503 (不 404, 区分路由存在 vs 桥死).
// 不反代 /healthz: 公网已有 /healthz (探 OR 链), FT healthz 本地端无额外面价值; metrics 含 per-Worker 计数才是圣上要.
app.get('/v1/ft/metrics', async (req, res) => {
  if (shuttingDown) return res.status(503).json({ error: 'service_unavailable', abort_source: 'shutdown' });
  // bridge 选址 (?bridge=N, 0-基, 默 0 首桥)
  const bi = (() => {
    if (req.query.bridge === undefined || req.query.bridge === '') return 0;
    const n = parseInt(req.query.bridge, 10);
    if (!Number.isInteger(n) || n < 0 || n >= FT_BRIDGES.length) return -1;
    return n;
  })();
  if (bi < 0) {
    return res.status(400).json({ error: 'bad_bridge_index', bridges: FT_BRIDGES.length, msg: `?bridge=N (0..${FT_BRIDGES.length - 1})` });
  }
  const ftPort = FT_BRIDGES[bi];
  try {
    const r = await fetch(`http://${FT_HOST}:${ftPort}/metrics`, {
      signal: AbortSignal.timeout(3000),
      headers: { Host: `${FT_HOST}:${ftPort}` },   // FT Host 守卫须 = 桥监听地址, 否则不命中落 HandleHTTP 透传
    });
    if (!r.ok) {
      return res.status(502).json({ error: 'bad_gateway', abort_source: 'upstream_error', ft_http: r.status, bridge: bi });
    }
    const text = await r.text();
    res.setHeader('Content-Type', 'text/plain; version=0.0.4; charset=utf-8');
    return res.status(200).send(text);
  } catch (e) {
    // ECONNREFUSED = FT 桥未启/死; timeout = 桥卡; 其余 transport err.
    const code = (e?.cause?.code === 'ECONNREFUSED' || e?.code === 'ECONNREFUSED') ? 503
      : (e?.name === 'TimeoutError' || e?.cause?.code === 'ETIMEDOUT') ? 504 : 502;
    return res.status(code).json({
      error: code === 503 ? 'service_unavailable' : (code === 504 ? 'gateway_timeout' : 'bad_gateway'),
      abort_source: code === 503 ? 'upstream_unavailable' : (code === 504 ? 'timeout' : 'upstream_error'),
      bridge: bi, ft_port: ftPort, err: e?.message || String(e),
    });
  }
});

app.use('/v1', (req, res) => proxyV1(req, res));

// 后台页 + api 转发 (经 Basic Auth + Authorization 已删); /v1 已各别处理
function proxyAdmin(req, res) {
  const qIdx = req.url.indexOf('?');
  const qs = qIdx >= 0 ? req.url.slice(qIdx) : '';
  const upstreamPath = req.path + qs;
  const headers = { ...req.headers };
  delete headers.host;
  headers.host = `127.0.0.1:${OR_PORT}`;
  // Authorization 已在 Basic Auth 中间件 delete; 上游 自身认证 (Cookie/Session) 原样上行.

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
    upstreamRes.on('end', () => {
      if (!res.writableEnded) res.end();
      // 正常成功完成 logGate (同 proxyV1 修, 圣上 2026-07-29 探针验漏补)
      if (!aborted && res.headersSent) {
        logGate(req, { elapsedMs: Date.now() - (req._gateT0 || 0),
          httpStatus: res.statusCode || 200, level: 'info', msg: 'upstream_completed' });
      }
    });
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
  // 不监 req 'close': body 读完 Node 正常 emit 'close' (非 client 真断), 旧版误判 clientAborted
  //   会 destroy upstreamReq, 掐断 OR 慢响应(如 /api/auth/login bcrypt 比对 100-300ms),
  //   致浏览器收 ECONNRESET 无提示进不去后台。真 client 中途断由 'aborted'/'error' 兜。
  //   响应头未发时 client 跑路才掐 upstream, 响应已开始流式则 client 自然关不算 abort。
  res.on('close', () => { if (!res.headersSent) { clientAborted = true; cleanup(); } });
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
