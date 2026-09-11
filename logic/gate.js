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
const policyGuard = require('./policy-guard.js');
const routeSplit = require('./route-split.js');

const INTERNAL_PSK = process.env.INTERNAL_PSK || '';
const ADMIN_ENABLED = process.env.GATE_ADMIN_ENABLED === '1';   // 纯布尔开关: 仅确置 '1' 开后台; 未设/'0'/任意他值均关 (保守 fail-closed)
const OR_PORT = parseInt(process.env.OMNIROUTE_PORT || '20128', 10);
const GATE_PORT = parseInt(process.env.EXPOSED_PORT || '7860', 10);
const UPSTREAM_TIMEOUT_MS = parseInt(process.env.GATE_UPSTREAM_TIMEOUT_MS || '30000', 10) || 30000;
const SHUTDOWN_GRACE_MS = parseInt(process.env.GATE_SHUTDOWN_GRACE_MS || '5000', 10) || 5000;

// ── FT (FlareTunnel) 桥本地端端口 (路3 路3-b 反代) ──────────────
// entrypoint export FT_PORTS "空格分隔端口串" (多桥). FT_PORTS 空 → FT_BRIDGES 兜 8080 (/v1/ft/metrics 取时 503).
// FT 桥监听 127.0.0.1:$PORT, 同端口 /healthz + /metrics (Host 守卫非 127.0.0.1:PORT 不命中).
// gate 现役惯例 "首桥代整体" (init-nim-keys.sh _ft_register_proxy 多桥 healthz 读 [0].port);
//   /v1/ft/metrics 默认取首桥, ?bridge=index (0-基) 选特定桥, 越界回 400.
const FT_PORTS_LIST = (process.env.FT_PORTS || '').split(/\s+/).map(s => parseInt(s, 10)).filter(n => Number.isInteger(n) && n > 0);
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

// ── #4b fallback 治暴配置 (2026-09-10 裁): 限尝试次数 + 总超时墙 + 空响应护栏 ─────────
// 依据 docs/ops/k3-故障诊断-2026-09-10.md L2: 上游 NIM 对 k3 长请求掐断时, 本侧逐 key 全额重放
//   同一 body, 把"上游慢"放大成 80 分钟级空转风暴 (单次等待 180s × 20+ key)。
//   本层不做"换 key"本身 (换 key 由上游 combo 做), 也无从按"单个 HTTP 请求"计数 ——
//   gate 是透明代理, 上游换 key 发生在上游进程内, 同一客户请求对 gate 只产生**一个** response head。
//   故记账口径 = **同一会话的连续重放** (消费端带同一会话指纹反复进 gate), 由 gate 兜底截断:
//   上游自身预算 (见下) 是第一道, gate 会话级预算 是第二道。
// 上游 3.8.50 实证 (只读对照树, 本侧不改):
//   · open-sse/services/combo/comboConfig.ts:121 maxGlobalAttempts=30 (硬顶 200, comboPredicates.ts:103)
//   · comboConfig.ts:180 comboTimeoutMs=0 (= 不限总墙钟, 仅 COMBO_LOOP_SAFETY_TIMEOUT_MS=10min 兜底)
//   · comboConfig.ts:154 maxSetRetries=0 (同 set 不重跑)
//   · validateQuality.ts:738 "empty content and no tool_calls" 已把空响应判 quality 不合格并换 target
//   → 上游"能配"但生产未配; 本 PR 把 `GATE_FALLBACK_*` 落成 gate 侧默认 + entrypoint 显式导出, 无需改上游 src。
// ── GATE_FALLBACK_MAX_ATTEMPTS: 同一会话连续失败几次后拒放行 ──
//   语义 (2026-09-10 修正): 只对**失败**记账 —— 上游 2xx 却给不出有效内容 (退化空响应 / 零内容)
//   或 4xx/5xx 失败响应, 这才算一次失败。连续失败达上限 → 直接 502, 不再放行下一次重放
//   (等价"不再等下一个 key")。**正常完成即清零**, 所以"连续 3 问正常对话"不会被误伤。
//   为什么不是"按上游 response head 计数": gate 是透明代理, 上游 combo 换 key 在上游进程内完成,
//   gate 每次只看到一个 head → 按 head 计数恒为 1 拦不住风暴, 对普通客户端却会误杀长会话。
//   默认 3 = Issue #4 验收口径 (单请求最多尝试 3 个 key)。≤0 = 关闭本护栏。
// ── GATE_FALLBACK_TOTAL_TIMEOUT_MS: 同一会话 fallback 累计墙钟 ──
//   从该会话**首次失败**起算 (正常请求不计时, 否则长会话满 90s 会被墙钟误杀);
//   超过即放弃并回 502 (而不是再等下一个 key 的 240s)。env 可配, 默认 90000=90s。
// ── GATE_EMPTY_RESPONSE_RETRY: tool_calls 后空响应护栏 ──
//   上游若返回 "HTTP 200 + 只有 tool_calls + content 全空" 的退化应答, 上游 quality gate 不拦
//   (它只把 "无 content 且无 tool_calls" 判空, validateQuality.ts:738)。gate 侧记一次"上游退化",
//   同会话再退化 → 明确 502 报给消费端, 不静默放空 200 (Deferred-head, 见 handleDegenerateHold)。
// 消费端 gate 无 key 可换 (key 池在上游), 故本组仅"数次数 + 掐墙钟 + 判退化", 不实现 key 轮换。
const FALLBACK_GUARD_ENABLED = process.env.GATE_FALLBACK_GUARD_ENABLED !== '0';
const FALLBACK_MAX_ATTEMPTS = parseInt(process.env.GATE_FALLBACK_MAX_ATTEMPTS || '3', 10);
const FALLBACK_TOTAL_TIMEOUT_MS = parseInt(process.env.GATE_FALLBACK_TOTAL_TIMEOUT_MS || '90000', 10) || 90000;
const EMPTY_RESPONSE_RETRY_ENABLED = process.env.GATE_EMPTY_RESPONSE_RETRY !== '0';
const EMPTY_RESPONSE_MAX_RETRIES = parseInt(process.env.GATE_EMPTY_RESPONSE_MAX_RETRIES || '1', 10);
const FALLBACK_SESSION_TTL_MS = parseInt(process.env.GATE_FALLBACK_SESSION_TTL_MS || '600000', 10) || 600000;
const FALLBACK_MAX_SESSIONS = parseInt(process.env.GATE_FALLBACK_MAX_SESSIONS || '5000', 10) || 5000;

// ── #16 调用前缀/路径分流 (2026-09-11 裁): 只择路, 不限流 ──────────────────
// 把「重访问热点」(health / models / bucket 校验探针) 与「推理类 payload」分流:
//   probe 快路径跳过两处重活 —— (a) 不读 body 前缀 (探针无 body, 也就无会话指纹),
//   (b) 不进 fallback 会话账本 (账本只对 POST 语义服务)。
// 唯一限流器仍是上游 requestQueue (gate.js:15 契约), 本开关零限流语义。
// 判据/分流规则全在 route-split.js (纯函数零依赖, 可独立单测)。
// 默认 '1' 开; 设 '0' 一键回退到旧行为 (全量走原路径, 便于灰度/排障)。
const ROUTE_SPLIT_ENABLED = process.env.GATE_ROUTE_SPLIT_ENABLED !== '0';
const ROUTE_SPLIT_STRICT = process.env.GATE_ROUTE_SPLIT_STRICT === '1';  // 诊断用: 打全部 lane 日志, 非仅 probe
// ── 会话级账本 (为什么不是"请求级") ─────────────────────────────
// gate 是透明代理: 上游 combo 的换 key 重放发生在上游进程内, gate 每次只看到**一个**响应头,
//   故"请求内计数"永远停在 1, 拦不住风暴。可观测口径 = 同一会话连续重放 (消费端带同一会话指纹
//   反复进 gate)。护栏据此记账: 连续**失败**超 3 / 首次失败起累计超 90s / 退化空响应 → 直接拒。
//   证伪条件: 若上游卡在某个坏 key 上不返回也不换 key, 消费端不会自动重放 → gate 侧无新增观测,
//   此时 90s / 3 次都不会触发, 兜底仍由 GATE_UPSTREAM_TIMEOUT_MS (单请求上游超时) 承担。
const fallbackLedger = policyGuard.createSessionLedger({
  enabled: FALLBACK_GUARD_ENABLED,
  maxAttempts: FALLBACK_MAX_ATTEMPTS,
  totalTimeoutMs: FALLBACK_TOTAL_TIMEOUT_MS,
  emptyResponseRetry: EMPTY_RESPONSE_RETRY_ENABLED,
  emptyResponseMaxRetries: EMPTY_RESPONSE_MAX_RETRIES,
  maxSessions: FALLBACK_MAX_SESSIONS,
});

// ── 会话指纹: 让"同一对话的连续重放"落同一账本 ──────────────────
// 优先级: 显式 session/conversation 头 → body.conversation_id / session_id
//        → messages 指纹哈希 (同对话同样前缀) → 连接+模型兜底 (最后手段)。
function resolveSessionKey(req, bodyBuf) {
  const h = req.headers || {};
  for (const name of ['x-session-id', 'x-conversation-id', 'x-omniroute-session-id', 'session_id']) {
    const v = h[name];
    if (typeof v === 'string' && v.trim().length > 0) return `h:${v.trim()}`;
  }
  if (bodyBuf && bodyBuf.length > 0) {
    try {
      const j = JSON.parse(bodyBuf.toString('utf8'));
      const cid = j && (j.conversation_id || j.session_id);
      if (typeof cid === 'string' && cid.trim().length > 0) return `b:${cid.trim()}`;
      const msgs = j && j.messages;
      if (Array.isArray(msgs) && msgs.length > 0) {
        const fp = crypto.createHash('sha256').update(JSON.stringify(msgs.slice(0, 2))).digest('hex').slice(0, 16);
        return `m:${fp}:${j.model || ''}`;
      }
    } catch { /* 非 JSON body, 走兜底 */ }
  }
  return `f:${req.headers?.['x-forwarded-for'] || req.socket?.remoteAddress || 'anon'}:${req._normPath || ''}`;
}

// 读 body 前缀 (最多 maxBytes) 并**原样重放给下游**: 用 PassThrough 承接已读字节,
// 之后 req 剩余字节 pipe 进去, 下游 req.pipe 改读该 PassThrough —— body 语义零改动, 不走 unshift
// (unshift 在 pause 中的 IncomingMessage 上不可靠, 会致下游 400)。
const { PassThrough } = require('stream');
function readBodyPrefix(req, maxBytes) {
  return new Promise((resolve, reject) => {
    const want = Math.min(parseInt(req.headers['content-length'] || '0', 10) || maxBytes, maxBytes);
    const chunks = [];
    let got = 0;
    let settled = false;
    const onData = (c) => {
      if (settled) return;
      chunks.push(c); got += c.length;
      if (got >= want) finish();
    };
    const onEnd = () => finish();
    const onErr = (e) => { if (settled) return; settled = true; cleanup(); reject(e); };
    function cleanup() {
      req.off('data', onData); req.off('end', onEnd); req.off('error', onErr);
    }
    function finish() {
      if (settled) return;
      settled = true;
      cleanup();
      const buf = Buffer.concat(chunks);
      // 下游读的"替身 body": 已读字节 + 后续 req 剩余字节
      const replay = new PassThrough();
      if (buf.length > 0) replay.write(buf);
      req.on('data', (c) => replay.write(c));
      req.on('end', () => replay.end());
      req.on('error', (e) => replay.destroy(e));
      req._fgBodyStream = replay;
      req.resume();
      resolve(buf);
    }
    req.on('data', onData);
    req.on('end', onEnd);
    req.on('error', onErr);
  });
}

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
      // #16 路径分流 (纯增量字段: 既有键零改; 未分流时 lane=null)
      lane: req?._gateLane || null,
      route_reason: req?._gateRouteReason || null,
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
//   2026-09-02: 私有化后反代出站 authorization 让位给 HF 门票 (Bearer <HF_TOKEN>),
//   PSK 走 X-Gate-PSK 独立头 (反代透传). 校验顺序: X-Gate-PSK 优先 (新路/经反代),
//   无则回退 authorization (老路/直连/其他客户端). 门票值永不被当 PSK 校验.
app.use('/v1', (req, res, next) => {
  const auth = req.headers.authorization || '';
  const gatePsk = req.headers['x-gate-psk'] || '';
  const bearer = gatePsk.startsWith('Bearer ')
    ? gatePsk.slice('Bearer '.length).trim()
    : auth.startsWith('Bearer ') ? auth.slice('Bearer '.length).trim() : '';
  if (!bearer || !safeEqual(bearer, INTERNAL_PSK)) {
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
// ── #4b: 终态记账 ────────────────────────────────────────────────
// 只判"上游 2xx 但给不出有效内容"这一种退化 —— 非 2xx 的错误响应本身已明确, 不重复记账。
// 判定口径 (保守, 宁放过不误伤):
//   · 非 2xx (statusCode >= 300) → 不是退化, 交既有错误路径 (也不记空响应)。
//   · sawNonPingContent = true   → 有真内容, 绝不判退化。
//   · sawError                   → 流内报错, 交既有错误路径。
//   · 2xx 且零星/空              → 记一次退化; 同会话再来即拒 (不静默放空 200)。
function recordFallbackOutcome(req, verdict, statusCode) {
  if (!verdict || !req._fgSessionKey) return;
  if (typeof statusCode === 'number' && statusCode >= 300) return;
  const key = req._fgSessionKey;
  const reason = policyGuard.classifyProbeFailure(verdict);   // 纯函数: 真内容/流内错误 → 'ok'
  if (reason === 'ok') {
    // 正常内容到达 → 清零该会话失败计数 (会话自愈; 已 denied 的保持粘住, 见 clearSessionFailure)
    policyGuard.clearSessionFailure(fallbackLedger, key);
    return;
  }
  const r = policyGuard.recordSessionFailure(fallbackLedger, key, { reason });
  logGate(req, { elapsedMs: Date.now() - (req._gateT0 || 0),
    httpStatus: verdict.degenerateEmpty ? 200 : 502,
    errorCode: verdict.degenerateEmpty ? 'upstream_degenerate_empty_response' : 'upstream_empty_response',
    abortSource: 'gate_fallback_guard', destroyInitiator: verdict.degenerateEmpty ? null : 'upstream',
    msg: `fallback_guard_${verdict.degenerateEmpty ? 'degenerate_empty_response' : 'empty_response'} session=${key.slice(0, 24)} failures=${r.failures} denied=${Boolean(r.denied)}` });
}

// ── #4b 透传: 上游 → 客户端的原样逐块转发 (原 proxyV1 内联逻辑抽出, 零语义改动) ──
function writeUpstreamChunk(res, upstreamRes, chunk) {
  if (!res.write(chunk)) {
    upstreamRes.pause();
    res.once('drain', () => upstreamRes.resume());
  }
}

function passThroughUpstream(req, res, upstreamRes, fgProbe) {
  req._socketPhase = 'streaming';
  if (!res.headersSent) res.writeHead(upstreamRes.statusCode, upstreamRes.headers);
  const pass = (chunk) => {
    if (fgProbe) fgProbe.feed(chunk, String(upstreamRes.headers['content-type'] || ''));
    writeUpstreamChunk(res, upstreamRes, chunk);
  };
  upstreamRes.on('data', pass);
  upstreamRes.on('end', () => {
    // 若 hold 窗口已吞掉首批 chunk, 这里补发 (避免丢内容)
    const buffered = upstreamRes._fgBuffered;
    if (Array.isArray(buffered)) {
      upstreamRes._fgBuffered = null;
      for (const c of buffered) pass(c);
    }
    if (!res.writableEnded) res.end();
    if (fgProbe) recordFallbackOutcome(req, fgProbe.verdict(), upstreamRes.statusCode);
    if (res.headersSent) {
      logGate(req, { elapsedMs: Date.now() - (req._gateT0 || 0),
        httpStatus: res.statusCode || 200, level: 'info', msg: 'upstream_completed' });
    }
  });
}

// ── #4b Deferred-head: 只在"空响应重试配额已用尽"的请求上启用 ──────────────────
// 目的: 上游第二次仍给"退化空响应"时, 消费端不该静默收一个空 200。
// 做法: 先缓冲首批 chunk (上限 EMPTY_HEAD_HOLD_MS 或 EMPTY_HEAD_MAX_BYTES), 期间:
//   · 探针见到真内容/非退化 → 立即写 head + 补发缓冲, 转入正常逐块透传 (真回复零丢失);
//   · 探针判定退化 或 宽限窗到期仍无内容 → 丢弃上游流, 回明确 502 (带诊断, 不静默)。
// 正常请求 (配额未用尽) 永不走此路 → 零额外延迟、零缓冲。
const EMPTY_HEAD_HOLD_MS = parseInt(process.env.GATE_EMPTY_HEAD_HOLD_MS || '2000', 10) || 2000;
const EMPTY_HEAD_MAX_BYTES = parseInt(process.env.GATE_EMPTY_HEAD_MAX_BYTES || '65536', 10) || 65536;

function handleDegenerateHold(req, res, upstreamRes, fgProbe) {
  req._socketPhase = 'streaming';
  const buffered = [];
  upstreamRes._fgBuffered = buffered;
  let bufferedBytes = 0;
  let settled = false;

  const finishPassThrough = () => {
    if (settled) return;
    settled = true;
    clearTimeout(timer);
    upstreamRes.removeListener('data', onData);
    upstreamRes.removeListener('end', onEnd);
    if (!res.headersSent) res.writeHead(upstreamRes.statusCode, upstreamRes.headers);
    for (const c of buffered) writeUpstreamChunk(res, upstreamRes, c);
    buffered.length = 0;
    upstreamRes._fgBuffered = null;
    passThroughUpstream(req, res, upstreamRes, fgProbe);
  };

  const finishReject = (verdict) => {
    if (settled) return;
    settled = true;
    clearTimeout(timer);
    upstreamRes.removeListener('data', onData);
    upstreamRes.removeListener('end', onEnd);
    try { upstreamRes.destroy(); } catch { /* best effort */ }
    buffered.length = 0;
    upstreamRes._fgBuffered = null;
    logGate(req, { elapsedMs: Date.now() - (req._gateT0 || 0), httpStatus: 502,
      errorCode: 'upstream_degenerate_empty_response', abortSource: 'gate_fallback_guard',
      destroyInitiator: 'gate_fallback_guard',
      msg: `fallback_guard_degenerate_reject code=${verdict ? verdict.code : 'hold_timeout'}` });
    if (!res.headersSent) {
      res.status(502).json({ error: {
        type: 'upstream_degenerate_empty_response',
        message: 'Upstream returned a degenerate empty completion after tool_calls; the same-request retry budget is exhausted, so gate is surfacing an explicit error instead of a silent empty 200.',
        upstream_code: verdict ? verdict.code : 'hold_timeout',
        session: req._fgSessionKey ? req._fgSessionKey.slice(0, 24) : null,
      } });
    } else if (!res.writableEnded) {
      res.end();
    }
  };

  const timer = setTimeout(() => finishReject(null), EMPTY_HEAD_HOLD_MS);

  const onData = (chunk) => {
    fgProbe.feed(chunk, String(upstreamRes.headers['content-type'] || ''));
    buffered.push(chunk);
    bufferedBytes += chunk.length;
    const v = fgProbe.verdict();
    if (v.degenerateEmpty && !v.sawContentText) {
      // 已明确判定"tool_calls 后空 content" → 提前收口, 不等满窗
      finishReject(v);
      return;
    }
    if (v.sawContentText || bufferedBytes >= EMPTY_HEAD_MAX_BYTES) finishPassThrough();
  };
  const onEnd = () => {
    const v = fgProbe.verdict();
    if (!v.sawNonPingContent && !v.sawToolCalls) finishReject(v);
    else finishPassThrough();
  };
  upstreamRes.on('data', onData);
  upstreamRes.on('end', onEnd);
}

async function proxyV1(req, res) {
  // app.use('/v1', ...) mount 下 req.path 被 Express strip '/v1' 前缀; 用 originalUrl 保完整 (含 query).
  const upstreamPath = req.originalUrl;
  // ── #16 路径分流: 先定 lane (纯函数, 零 I/O) ─────────────────────────
  // probe = 无 body 的轻读热点 → 快路径 (不读 body 前缀 + 不进 fallback 账本)。
  // 拿不准一律 inference (fail-safe, 见 route-split.js 头注): probe 快路径会跳过护栏,
  //   误判成 probe = 该护的没护; 反向误判只损失一点性能。
  const split = ROUTE_SPLIT_ENABLED
    ? routeSplit.classifyLane({ method: req.method, path: upstreamPath })
    : { lane: 'inference', reason: 'route_split_disabled', path: upstreamPath, method: req.method };
  req._gateLane = split.lane;
  req._gateRouteReason = split.reason;
  const isProbe = split.lane === 'probe';
  // probe 只择路: 不读 body (探针无 body) → 不走 readBodyPrefix。
  // 审计: probe 命中常规静默 (只记 logGate 的 lane 字段), STRICT 时全 lane 打点便于核对分流。
  if (isProbe || ROUTE_SPLIT_STRICT) {
    logGate(req, { elapsedMs: 0, httpStatus: null, level: 'info',
      abortSource: 'gate_route_split', msg: `lane=${split.lane} route_reason=${split.reason}` });
  }
  // #4b: 会话指纹需读 body 里的 conversation_id / messages 前缀 —— 用 PassThrough 重放
  //   已读字节 (见 readBodyPrefix), 后续 pipe 读它, body 语义零改动。仅 POST 需要。
  // #16: probe 快路径跳过此段 (无 body 可读, 也无须会话指纹)。
  if (req.method === 'POST' && !isProbe) {
    let prefix = Buffer.alloc(0);
    try { prefix = await readBodyPrefix(req, 65536); }
    catch (e) { logGate(req, { elapsedMs: Date.now() - (req._gateT0 || 0), httpStatus: 400,
      errorCode: 'body_read_error', abortSource: 'gate_body_read', msg: `body_prefix_read_failed ${e?.message || e}` });
      if (!res.headersSent) return res.status(400).json({ error: 'bad_request', detail: 'failed to read request body' });
      return; }
    req._fgSessionKey = resolveSessionKey(req, prefix);
  }
  // ── #4b fallback 治暴: 会话级预算账本 (key 见 resolveSessionKey) ──
  // 记账口径 = 同一会话的连续重放 (gate 是透明代理, 上游换 key 发生在上游内, 见 policy-guard.js 头注)。
  // 放行前先问会话账本: 次数超限 / 墙钟已过 / 已判退化 → 直接 502, 不再把请求交给上游
  // (等价"不再等下一个 key 的 240s")。GET/OPTIONS 等无会话语义的请求不拦。
  // #16: probe 快路径不进账本 (账本只对 POST 语义服务, 探针本就不参与 fallback 治暴)。
  const fgGuardApplies = req.method === 'POST' && !isProbe;
  if (fgGuardApplies && req._fgSessionKey) {
    const fgGate = policyGuard.canSessionAttempt(fallbackLedger, req._fgSessionKey);
    if (!fgGate.allow) {
      logGate(req, { elapsedMs: Date.now() - (req._gateT0 || 0), httpStatus: 502,
        errorCode: fgGate.reason, abortSource: 'gate_fallback_guard', destroyInitiator: null,
        msg: `fallback_guard_reject before_upstream attempts=${fgGate.detail.attempts ?? 0}` });
      return res.status(502).json({ error: {
        type: fgGate.reason,
        message: fgGate.reason === 'fallback_total_timeout'
          ? `Fallback wall-clock budget (${fgGate.detail.totalTimeoutMs}ms) exhausted for this conversation; refusing to start another multi-minute key rotation.`
          : fgGate.reason === 'empty_response_retry_exhausted'
            ? 'Upstream keeps returning degenerate empty completions (no content after tool_calls) for this conversation; refusing to pass another silent empty 200.'
            : `Fallback attempt budget (max ${fgGate.detail.maxAttempts}) exhausted for this conversation; refusing further key rotation.`,
        budget: fgGate.detail,
      } });
    }
  }
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
    // #4b: 响应头已到 → 记一次"上游尝试"观测。注意: 这是**证据**不是拦截口径 —— head 到 ≠ 失败,
    //   且透明代理下按 head 计数恒为 1 (换 key 在上游进程内), 真计数在终态 (recordFallbackOutcome):
    //   只对"2xx 却给不出内容"与"4xx/5xx 失败"记失败, 达上限才拒。普通客户端连续对话不受影响。
    if (req._fgSessionKey) {
      const fgState0 = policyGuard.recordSessionAttempt(fallbackLedger, req._fgSessionKey);
      if (upstreamRes.statusCode >= 400) {
        policyGuard.recordSessionFailure(fallbackLedger, req._fgSessionKey,
          { reason: `upstream_status_${upstreamRes.statusCode}` });
      }
    }
    // #4b 空响应护栏: 边转发边探针, 判"非 ping 内容有没有出现" + "是否 tool_calls 后空 content"。
    // 只旁路观测, 不缓冲、不改写 (零内存放大, 仍逐块转发), 只在 end 时给结论。
    // 只对 POST + 2xx 起探针 (非 2xx 的错误体不是"空响应", 交既有错误路径)。
    const fgProbe = (req.method === 'POST' && upstreamRes.statusCode < 300)
      ? policyGuard.createStreamProbe() : null;
    // #4b Deferred-head 窗口: 正常情况下 head 立刻透传 (零改动既有语义); 仅对"有退化风险的会话"
    //   (此前已出现退化空响应, 或本次已是同会话第 ≥2 次尝试) 先缓冲到"确认真有内容"或 2s 宽限窗到期,
    //   期间若探针判定"退化空响应" → 直接改回明确 502 (消费端不静默收空 200); 见到真内容立即透传。
    //   成本: 仅风险会话多留 ≤2s; 正常请求零延迟、零缓冲。判定保守, 只对"确无内容"收口。
    const fgSessionState = req._fgSessionKey ? fallbackLedger.get(req._fgSessionKey) : null;
    // 只在"本会话已出现过失败"时启用 Deferred-head (首轮正常请求零延迟, 见 handleDegenerateHold)。
    const fgHoldHead = Boolean(fgProbe && upstreamRes.statusCode < 300 && fgSessionState &&
      fgSessionState.failures > 0 && !shuttingDown);
    if (fgHoldHead) handleDegenerateHold(req, res, upstreamRes, fgProbe);
    else passThroughUpstream(req, res, upstreamRes, fgProbe);
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
  if (req._fgBodyStream) {
    req._fgBodyStream.pipe(upstreamReq);
  } else if (req.readable && (req.headers['content-length'] || req.headers['transfer-encoding'])) {
    req.pipe(upstreamReq);
  } else {
    upstreamReq.end();
  }
}

// ── /v1/ft/metrics: PSK 鉴权反代 FlareTunnel 桥本地 /metrics (路3-b, 2026-08-12 Zen令) ──
// PSK 校验靠前 /v1 app.use (line 187-198): Bearer INTERNAL_PSK safeEqual, 缺/错 fail-closed 401.
// 反代 FT 桥 127.0.0.1:$PORT/metrics (Prometheus text exposition, text/plain; version=0.0.4).
//   FT 桥本地端无鉴权 (127.0.0.1 Host 守卫), gate 此层做唯一公网鉴权门.
// 现役惯例 "首桥代整体" (init-nim-keys.sh _ft_register_proxy 多桥 healthz 读首桥);
//   ?bridge=index (0-基) 选特定桥, 越界/非数 → 400; 默认 bridge=0 首桥.
// FT 未启 (FT_PIDS 空): /metrics 上游 ECONNREFUSED → 503 (不 404, 区分路由存在 vs 桥死).
// 不反代 /healthz: 公网已有 /healthz (探 OR 链), FT healthz 本地端无额外面价值; metrics 含 per-Worker 计数才是Zen要.
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
      // 正常成功完成 logGate (同 proxyV1 修, Zen 2026-07-29 探针验漏补)
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
