// policy-guard.js — #4b fallback 治暴护栏 (纯逻辑, 无 I/O, 可单测)
// 依据: docs/ops/k3-故障诊断-2026-09-10.md §三 L2 "本侧把上游慢放大成风暴"。
// 本文件只做三件事, 全部按"同一客户端请求"口径记账:
//   1. 尝试次数上限  —— 空响应退化每发生一次记一次, 超限即终止, 不再等下一轮 180s。
//   2. 总墙钟墙      —— 从请求进 gate 起算, 超期即终止 (代替"再等下一个 key 240s")。
//   3. 空响应护栏    —— tool_calls 之后 content 全空 = 上游退化, 允许换 key 重试 N 次, 再空即明确报错。
// 纯函数/纯状态对象: 不引 express/http, 不读时钟以外的外部状态 (now 可注入, 便于单测)。
'use strict';

const DEFAULT_POLICY = Object.freeze({
  enabled: true,
  // 语义: 同一会话"连续失败"多少次后拒放行 (失败 = 2xx 却给不出内容, 或 4xx/5xx)。
  // 正常完成会清零, 所以按 head 计数的老口径 (会把连续 3 次正常对话误判成重放风暴) 已废弃。
  maxAttempts: 3,          // ≤0 视为关闭次数护栏
  totalTimeoutMs: 90000,   // ≤0 视为关闭墙钟护栏 (自"首次失败"起算)
  emptyResponseRetry: true,
  emptyResponseMaxRetries: 1,
});

function normalizePolicy(raw) {
  const p = { ...DEFAULT_POLICY, ...(raw || {}) };
  p.enabled = p.enabled !== false;
  p.maxAttempts = Number.isFinite(p.maxAttempts) ? Math.floor(p.maxAttempts) : DEFAULT_POLICY.maxAttempts;
  p.totalTimeoutMs = Number.isFinite(p.totalTimeoutMs) ? Math.floor(p.totalTimeoutMs) : DEFAULT_POLICY.totalTimeoutMs;
  p.emptyResponseMaxRetries = Number.isFinite(p.emptyResponseMaxRetries)
    ? Math.max(0, Math.floor(p.emptyResponseMaxRetries)) : DEFAULT_POLICY.emptyResponseMaxRetries;
  return p;
}

/** 开一个请求级预算账本。now 可注入 (单测用)。
 *  注: 早期版本 (attempts/emptyResponses 口径, 见下方 createBudget/canAttempt/recordEmptyResponse/
 *  terminalVerdict) 保留为纯函数供单测与推演使用; 生产接线走会话级账本 (canSessionAttempt /
 *  recordSessionFailure / clearSessionFailure), 口径修正见 recordSessionFailure 注释。 */
function createBudget(policy, startedAt) {
  const p = normalizePolicy(policy);
  return {
    policy: p,
    startedAt: Number.isFinite(startedAt) ? startedAt : Date.now(),
    attempts: 0,          // 已观测到的"上游尝试"次数
    emptyResponses: 0,    // 其中 content 全空 (退化) 的次数
    emptyRetriesUsed: 0,  // 已用掉的空响应重试配额
  };
}

/**
 * 是否还能再放行一次上游尝试。
 * @returns {{allow: boolean, reason: string|null, detail: object}}
 */
function canAttempt(budget, now) {
  const t = Number.isFinite(now) ? now : Date.now();
  const p = budget.policy;
  if (!p.enabled) return { allow: true, reason: null, detail: {} };
  if (p.totalTimeoutMs > 0) {
    const elapsed = t - budget.startedAt;
    if (elapsed >= p.totalTimeoutMs) {
      return { allow: false, reason: 'fallback_total_timeout', detail: { elapsedMs: elapsed, totalTimeoutMs: p.totalTimeoutMs } };
    }
  }
  if (p.maxAttempts > 0 && budget.attempts >= p.maxAttempts) {
    return { allow: false, reason: 'fallback_attempt_limit', detail: { attempts: budget.attempts, maxAttempts: p.maxAttempts } };
  }
  return { allow: true, reason: null, detail: { attempts: budget.attempts, elapsedMs: t - budget.startedAt } };
}

/** 记一次上游尝试 (响应头已到, 即视为"上游尝试过一次")。 */
function recordAttempt(budget) { budget.attempts += 1; return budget.attempts; }

/**
 * 流探针终态分类: 把一次上游 2xx 响应的观测结果收敛成"是否失败"。
 * 供 gate 侧会话账本使用 (见 gate.js recordFallbackOutcome), 单测友好 (纯函数)。
 *   真内容 / 流内错误  → 'ok'   (流内错误交既有错误路径, 不重复记账)
 *   退化空响应 (tools) → 'empty_response_retry_exhausted'
 *   2xx 却零内容       → 'upstream_empty_response'
 */
function classifyProbeFailure(verdict) {
  if (!verdict) return 'ok';
  if (verdict.sawError) return 'ok';
  if (verdict.degenerateEmpty) return 'empty_response_retry_exhausted';
  if (!verdict.sawNonPingContent) return 'upstream_empty_response';
  return 'ok';
}

/**
 * 记一次"退化空响应"并判定是否允许换 key 重试。
 * @returns {{empty: boolean, allowRetry: boolean, reason: string|null}}
 */
function recordEmptyResponse(budget) {
  budget.emptyResponses += 1;
  const p = budget.policy;
  if (!p.enabled || !p.emptyResponseRetry) return { empty: true, allowRetry: false, reason: 'empty_response_retry_disabled' };
  if (budget.emptyRetriesUsed < p.emptyResponseMaxRetries) {
    budget.emptyRetriesUsed += 1;
    return { empty: true, allowRetry: true, reason: null };
  }
  return { empty: true, allowRetry: false, reason: 'empty_response_retry_exhausted' };
}

/**
 * 终态决策: 请求结束时该回什么 (null = 正常放过)。
 * 只在"没有任何有效内容"时给出错误, 保证不误伤真回复。
 */
function terminalVerdict(budget, { emptyResponse, statusCode, now } = {}) {
  const t = Number.isFinite(now) ? now : Date.now();
  const p = budget.policy;
  const elapsedMs = t - budget.startedAt;
  if (!p.enabled) return null;
  if (emptyResponse) {
    return {
      status: 502,
      error: 'upstream_degraded_empty_response',
      message: `Upstream returned a degenerate empty completion (no content after tool_calls) ${budget.emptyResponses} time(s) on this request; refusing to pass a silent empty 200 to the client.`,
      detail: { emptyResponses: budget.emptyResponses, attempts: budget.attempts, elapsedMs },
    };
  }
  if (p.maxAttempts > 0 && budget.attempts > p.maxAttempts) {
    return {
      status: 502,
      error: 'fallback_attempt_limit_exceeded',
      message: `Upstream fallback exceeded the per-request attempt budget (${budget.attempts} > ${p.maxAttempts}).`,
      detail: { attempts: budget.attempts, maxAttempts: p.maxAttempts, elapsedMs },
    };
  }
  return null;
}

/** 判断一次上游响应体是否为"退化空响应": 有 tool_calls, 但 content / reasoning 全空, 且无错误。 */
function isDegenerateEmptyCompletion(payload) {
  if (!payload || typeof payload !== 'object') return false;
  if (payload.error) return false;
  const choices = payload.choices;
  if (!Array.isArray(choices) || choices.length === 0) return false;
  const msg = choices[0]?.message || choices[0]?.delta;
  if (!msg || typeof msg !== 'object') return false;
  const hasToolCalls = Array.isArray(msg.tool_calls) && msg.tool_calls.length > 0;
  if (!hasToolCalls) return false;
  const contentEmpty = msg.content === null || msg.content === undefined ||
    (typeof msg.content === 'string' && msg.content.trim().length === 0) ||
    (Array.isArray(msg.content) && msg.content.length === 0);
  const reasoning = msg.reasoning_content ?? msg.reasoning;
  const reasoningEmpty = reasoning === null || reasoning === undefined ||
    (typeof reasoning === 'string' && reasoning.trim().length === 0);
  return contentEmpty && reasoningEmpty;
}

// ── 会话级账本 (2026-09-10 修正) ───────────────────────────────
// 关键事实: gate 是透明代理 —— 上游 combo 的"换 key"发生在**上游进程内部**,
//   gate 只能看到一次 HTTP 响应头, 因此"请求级计数"永远停在 1, 拦不住风暴。
//   真正可观测的口径 = **同一会话 (同一对话) 的连续失败** —— 上游每次换 key 重放
//   都由消费端带着同一会话指纹再进一次 gate。故护栏按 sessionKey 记账,
//   连续失败达上限 / 首次失败起累计超墙钟 → 直接拒, 不再放行下一次重放。
// sessionKey 取值优先级 (由调用方传入, 见 gate.js resolveSessionKey):
//   x-session-id / x-conversation-id → conversation_id 字段 → 消息指纹哈希 → 连接+模型兜底。
const SESSION_TTL_MS = 10 * 60 * 1000;   // 会话账本不用了自动回收 (防内存增长)

function createSessionLedger(opts) {
  const policy = normalizePolicy(opts);
  const maxSessions = Number.isFinite(opts && opts.maxSessions) ? opts.maxSessions : 5000;
  const map = new Map();
  function sweep(now) {
    for (const [k, v] of map) if (now - v.lastSeen > SESSION_TTL_MS) map.delete(k);
  }
  function get(key, now) {
    const t = Number.isFinite(now) ? now : Date.now();
    if (map.size > maxSessions) sweep(t);
    let e = map.get(key);
    // startedAt 只在该会话**首次失败**时冻结 (见 recordSessionFailure)。
    // 正常请求若把它当成"会话起点", 一个长会话满 90s 就会被墙钟永久误杀 —— 那不是退化。
    if (!e) { e = { startedAt: t, clockArmed: false, attempts: 0, failures: 0, emptyResponses: 0, lastFailureAt: null, denied: null, lastSeen: t }; map.set(key, e); }
    e.lastSeen = t;
    return e;
  }
  return { policy, get, sweep, size: () => map.size, _map: map };
}

/** 会话级判决: 是否放行这一次重放。denied 一旦置位则粘住 (同会话不再放行)。 */
function canSessionAttempt(ledger, key, now) {
  const t = Number.isFinite(now) ? now : Date.now();
  const e = ledger.get(key, t);
  if (e.denied) return { allow: false, reason: e.denied.reason, detail: e.denied.detail };
  const p = ledger.policy;
  if (!p.enabled) return { allow: true, reason: null, detail: {} };
  // 墙钟只在"该会话已出现过失败 (退化/空响应)"后计时 (clockArmed) —— 正常请求不因会话长寿被掐。
  if (p.totalTimeoutMs > 0 && e.clockArmed && t - e.startedAt >= p.totalTimeoutMs) {
    e.denied = { reason: 'fallback_total_timeout', detail: { elapsedMs: t - e.startedAt, totalTimeoutMs: p.totalTimeoutMs } };
    return { allow: false, reason: e.denied.reason, detail: e.denied.detail };
  }
  // 拦截口径 = **连续失败计数** (failures), 不是 head 计数 (attempts, 仅作证据)。
  if (p.maxAttempts > 0 && e.failures >= p.maxAttempts) {
    e.denied = { reason: 'fallback_attempt_limit', detail: { failures: e.failures, maxAttempts: p.maxAttempts } };
    return { allow: false, reason: e.denied.reason, detail: e.denied.detail };
  }
  return { allow: true, reason: null, detail: { failures: e.failures, attempts: e.attempts, elapsedMs: t - e.startedAt } };
}

function recordSessionAttempt(ledger, key, now) {
  const e = ledger.get(key, Number.isFinite(now) ? now : Date.now());
  e.attempts += 1;
  return e;
}

/**
 * 记一次"同一会话的失败观测" —— 本 PR 的护栏只对**失败**记账, 正常完成绝不记账。
 * 与 recordSessionAttempt 的分工 (2026-09-10 修正):
 *   · recordSessionAttempt: "上游 response head 到达" (不论成败)。head 到 ≠ 失败, 且 gate 是
 *     透明代理 —— 上游 combo 把单请求放大成 20+ 次同体重放发生在上游进程内, gate 每次只看到
 *     **一个** head → 按 head 计数恒为 1, 拦不住风暴; 对普通客户端反而会把"连续 3 问"误判成
 *     重放风暴并永久 502。故该计数**不参与拦截**, 只作可观测证据。
 *   · recordSessionFailure: 唯一触发拦截的记账口径。上游 2xx 却给不出有效内容 (退化空响应 /
 *     零内容) 或 4xx/5xx 失败响应, 才记一次; 连续失败达上限 / 首次失败起累计超墙钟 → 拒绝,
 *     不再放行下一次重放。正常内容到达 → clearSessionFailure 清零 (天然自愈, 不粘 502)。
 * @returns {{failures:number, emptyResponses:number, newlyDenied:boolean}}
 */
function recordSessionFailure(ledger, key, opts, now) {
  const t = Number.isFinite(now) ? now : Date.now();
  const e = ledger.get(key, t);
  const reason = opts && opts.reason ? opts.reason : 'upstream_failure';
  e.failures += 1;
  if (reason === 'empty_response_retry_exhausted') e.emptyResponses += 1;
  if (!e.clockArmed) { e.clockArmed = true; e.startedAt = t; }   // 墙钟从首次失败起算
  e.lastFailureAt = t;
  const p = ledger.policy;
  let newlyDenied = false;
  if (p.enabled) {
    if (p.emptyResponseRetry && reason === 'empty_response_retry_exhausted' &&
        e.emptyResponses > p.emptyResponseMaxRetries) {
      e.denied = { reason, detail: { emptyResponses: e.emptyResponses, failures: e.failures } };
      newlyDenied = true;
    } else if (p.maxAttempts > 0 && e.failures >= p.maxAttempts) {
      e.denied = { reason: 'fallback_attempt_limit', detail: { failures: e.failures, maxAttempts: p.maxAttempts, lastReason: reason } };
      newlyDenied = true;
    } else if (p.totalTimeoutMs > 0 && t - e.startedAt >= p.totalTimeoutMs) {
      e.denied = { reason: 'fallback_total_timeout', detail: { elapsedMs: t - e.startedAt, totalTimeoutMs: p.totalTimeoutMs } };
      newlyDenied = true;
    }
  }
  return { failures: e.failures, emptyResponses: e.emptyResponses, newlyDenied, denied: e.denied };
}

/** 正常内容到达 → 清掉失败计数 (会话自愈, 不粘 502); 已 denied 的会话保持粘住 (防风暴回潮)。 */
function clearSessionFailure(ledger, key, now) {
  const t = Number.isFinite(now) ? now : Date.now();
  const e = ledger.get(key, t);
  if (e.denied) return e;
  e.failures = 0;
  e.emptyResponses = 0;
  e.clockArmed = false;
  e.startedAt = t;
  e.lastFailureAt = null;
  return e;
}

module.exports = {
  DEFAULT_POLICY,
  createSessionLedger,
  canSessionAttempt,
  recordSessionAttempt,
  recordSessionFailure,
  clearSessionFailure,
  SESSION_TTL_MS,
  normalizePolicy,
  createBudget,
  canAttempt,
  recordAttempt,
  recordEmptyResponse,
  terminalVerdict,
  classifyProbeFailure,
  isDegenerateEmptyCompletion,
  createStreamProbe,
};

// ── 流探针: 旁路观测 SSE 流是否"有过真内容" ───────────────────────────
// 设计取舍: 不缓冲全流 (内存零放大), 只保留滚动的尾部窗口做 SSE 行解析;
//   一旦见到任一非 ping 的 `data:` 帧 → sawNonPingContent=true (此后早退, 不再解析)。
//   OpenAI 形状: 见到 choices[].delta/message 中 content/reasoning/tool_calls 任一非空 → 真内容。
//   退化判定 degenerateEmpty: 全程只见到 tool_calls (且本轮没见过 content/非空), content 始终空。
// 保守性: 无法解析的二进制/压缩流 → 见 "data:" 即视为有内容 (宁放过), 不误判。
function createStreamProbe() {
  let sawNonPingContent = false;
  let sawError = false;
  let sawToolCalls = false;
  let sawContentText = false;
  let tail = '';           // 未完成行尾 (最多保留 8KB, 防畸形流撑内存)
  const MAX_TAIL = 8192;

  function feed(chunk, contentType) {
    if (sawNonPingContent) return;
    if (typeof contentType === 'string' && contentType.includes('event-stream') === false &&
        contentType.includes('json') === false) {
      // 非 SSE/JSON (如二进制) → 视为有内容, 直接放过 (保守, 不误判退化)
      sawNonPingContent = true;
      return;
    }
    let text;
    if (typeof chunk === 'string') text = chunk;
    else text = Buffer.from(chunk).toString('utf8');
    tail += text;
    const lines = tail.split('\n');
    tail = lines.pop() || '';
    if (tail.length > MAX_TAIL) tail = tail.slice(-MAX_TAIL);
    for (const rawLine of lines) {
      const line = rawLine.trim();
      if (!line.startsWith('data:')) continue;
      const payload = line.slice(5).trim();
      if (payload === '' || payload === '[DONE]') continue;
      if (payload === '{"type":"ping"}' || /"type"\s*:\s*"ping"/.test(payload)) continue;  // 上游 keepalive
      let json;
      try { json = JSON.parse(payload); } catch { sawNonPingContent = true; continue; }  // 解析不了但确实是 data 帧 → 宁可放过
      if (json && json.error) { sawError = true; sawNonPingContent = true; continue; }
      const choice = Array.isArray(json?.choices) ? json.choices[0] : null;
      const delta = choice?.delta || choice?.message;
      if (delta && typeof delta === 'object') {
        if (Array.isArray(delta.tool_calls) && delta.tool_calls.length > 0) sawToolCalls = true;
        const c = delta.content;
        const hasText = typeof c === 'string' ? c.length > 0
          : Array.isArray(c) ? c.length > 0 : (c !== null && c !== undefined);
        const r = delta.reasoning_content ?? delta.reasoning;
        const hasReasoning = typeof r === 'string' ? r.length > 0 : (r !== null && r !== undefined);
        if (hasText || hasReasoning) sawContentText = true;
      }
      // 任一"非空、非 ping、非错误框架"的 data 帧都算上游确实吐了东西
      if (choice || json?.usage || json?.model) sawNonPingContent = true;
      else if (!delta) sawNonPingContent = true;
    }
  }

  function verdict() {
    const degenerateEmpty = sawToolCalls && !sawContentText && !sawError;
    return {
      sawNonPingContent: sawNonPingContent || sawContentText,
      sawError,
      sawToolCalls,
      sawContentText,
      degenerateEmpty,
      code: sawError ? 'STREAM_UPSTREAM_ERROR'
        : degenerateEmpty ? 'DEGENERATE_EMPTY_AFTER_TOOL_CALLS'
        : sawNonPingContent ? 'OK' : 'EMPTY_STREAM',
    };
  }

  return { feed, verdict };
}
