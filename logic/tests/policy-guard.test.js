// #4b fallback 治暴护栏 单测 (node:test, 零依赖)
// 跑法: node --test logic/tests/  (或 node logic/tests/policy-guard.test.js)
// 场景覆盖 Issue #4 验收三点:
//   ① 尝试次数上限 (单请求最多 3 次)  ② 总墙钟墙 (默认 90s)  ③ tool_calls 后空响应护栏
'use strict';

const test = require('node:test');
const assert = require('node:assert');
const g = require('../policy-guard.js');

// ── ① 次数上限 ────────────────────────────────────────────
test('maxAttempts: 3 次内放行, 第 3 次后拒 (不再等下一个 key)', () => {
  const b = g.createBudget({ maxAttempts: 3, totalTimeoutMs: 0 }, 0);
  for (let i = 0; i < 3; i++) {
    assert.equal(g.canAttempt(b, i * 1000).allow, true, `attempt ${i + 1} 应放行`);
    g.recordAttempt(b);
  }
  const v = g.canAttempt(b, 3000);
  assert.equal(v.allow, false);
  assert.equal(v.reason, 'fallback_attempt_limit');
  assert.equal(v.detail.attempts, 3);
});

test('maxAttempts: 关闭 (0) 时不限次数', () => {
  const b = g.createBudget({ maxAttempts: 0, totalTimeoutMs: 0 }, 0);
  for (let i = 0; i < 50; i++) g.recordAttempt(b);
  assert.equal(g.canAttempt(b, 0).allow, true);
});

// ── ② 总墙钟墙 ────────────────────────────────────────────
test('totalTimeoutMs: 90s 前放行, 到点即拒 (不再等下一个 key 的 240s)', () => {
  const b = g.createBudget({ maxAttempts: 0, totalTimeoutMs: 90000 }, 0);
  assert.equal(g.canAttempt(b, 89000).allow, true);
  const v = g.canAttempt(b, 90000);
  assert.equal(v.allow, false);
  assert.equal(v.reason, 'fallback_total_timeout');
  assert.equal(v.detail.elapsedMs, 90000);
});

test('totalTimeoutMs: env 可配 (10s 档)', () => {
  const b = g.createBudget({ maxAttempts: 0, totalTimeoutMs: 10000 }, 0);
  assert.equal(g.canAttempt(b, 9999).allow, true);
  assert.equal(g.canAttempt(b, 10000).allow, false);
});

// ── ③ tool_calls 后空响应护栏 ─────────────────────────────
test('emptyResponse: 第 1 次退化允许换 key 重试, 第 2 次即拒', () => {
  const b = g.createBudget({ emptyResponseRetry: true, emptyResponseMaxRetries: 1 }, 0);
  assert.deepEqual(g.recordEmptyResponse(b), { empty: true, allowRetry: true, reason: null });
  const second = g.recordEmptyResponse(b);
  assert.equal(second.allowRetry, false);
  assert.equal(second.reason, 'empty_response_retry_exhausted');
  assert.equal(b.emptyResponses, 2);
});

test('emptyResponse: 退化 2 次 → 终态 502, 不静默放空 200', () => {
  const b = g.createBudget({}, 0);
  g.recordEmptyResponse(b);
  g.recordEmptyResponse(b);
  const v = g.terminalVerdict(b, { emptyResponse: true, now: 5000 });
  assert.equal(v.status, 502);
  assert.equal(v.error, 'upstream_degraded_empty_response');
  assert.match(v.message, /degenerate empty completion/);
});

test('isDegenerateEmptyCompletion: 只有 tool_calls 无 content → 退化', () => {
  assert.equal(g.isDegenerateEmptyCompletion({
    choices: [{ message: { content: null, tool_calls: [{ id: 'a', function: { name: 'f' } }] } }],
  }), true);
  assert.equal(g.isDegenerateEmptyCompletion({
    choices: [{ message: { content: '', tool_calls: [{ id: 'a' }] } }],
  }), true);
});

test('isDegenerateEmptyCompletion: 有真 content / 无 tool_calls / 有 error → 都非退化', () => {
  assert.equal(g.isDegenerateEmptyCompletion({
    choices: [{ message: { content: 'hello', tool_calls: [{ id: 'a' }] } }],
  }), false);
  assert.equal(g.isDegenerateEmptyCompletion({ choices: [{ message: { content: null } }] }), false);
  assert.equal(g.isDegenerateEmptyCompletion({
    error: { message: 'boom' }, choices: [{ message: { content: null, tool_calls: [{ id: 'a' }] } }],
  }), false);
});

// ── 流探针 (SSE) ─────────────────────────────────────────
test('probe: 真内容流 → OK, 不判退化', () => {
  const p = g.createStreamProbe();
  p.feed('data: {"choices":[{"delta":{"content":"你"}}]}\n', 'text/event-stream');
  p.feed('data: {"choices":[{"delta":{"content":"好"}}]}\n', 'text/event-stream');
  const v = p.verdict();
  assert.equal(v.sawContentText, true);
  assert.equal(v.degenerateEmpty, false);
  assert.equal(v.code, 'OK');
});

test('probe: tool_calls 之后 content 全空 → DEGENERATE', () => {
  const p = g.createStreamProbe();
  p.feed('data: {"choices":[{"delta":{"tool_calls":[{"id":"a","function":{"name":"f"}}]}}]}\n', 'text/event-stream');
  p.feed('data: {"choices":[{"delta":{},"finish_reason":"tool_calls"}]}\n', 'text/event-stream');
  p.feed('data: [DONE]\n', 'text/event-stream');
  const v = p.verdict();
  assert.equal(v.sawToolCalls, true);
  assert.equal(v.degenerateEmpty, true);
  assert.equal(v.code, 'DEGENERATE_EMPTY_AFTER_TOOL_CALLS');
});

test('probe: 只有 keepalive ping 后断开 → 全程零内容', () => {
  const p = g.createStreamProbe();
  p.feed('data: {"type":"ping"}\n', 'text/event-stream');
  const v = p.verdict();
  assert.equal(v.sawNonPingContent, false);
  assert.equal(v.degenerateEmpty, false);
  assert.equal(v.code, 'EMPTY_STREAM');
});

test('probe: 上游 error 帧 → sawError (走既有错误路径, 不重复判退化)', () => {
  const p = g.createStreamProbe();
  p.feed('data: {"error":{"message":"upstream exploded","code":"STREAM_READINESS_TIMEOUT"}}\n', 'text/event-stream');
  const v = p.verdict();
  assert.equal(v.sawError, true);
  assert.equal(v.degenerateEmpty, false);
  assert.equal(v.code, 'STREAM_UPSTREAM_ERROR');
});

test('probe: 跨 chunk 断行 (SSE 行被打散) 仍能识别', () => {
  const p = g.createStreamProbe();
  p.feed('data: {"choices":[{"delta":{"tool_ca', 'text/event-stream');
  p.feed('lls":[{"id":"a"}]}}]}\n', 'text/event-stream');
  assert.equal(p.verdict().sawToolCalls, true);
});

// ── 综合: 风暴截断 ────────────────────────────────────────
test('风暴场景: 20+ key 轮换被压到 3 次且在 90s 内收口', () => {
  const b = g.createBudget({ maxAttempts: 3, totalTimeoutMs: 90000 }, 0);
  let allowed = 0;
  for (let i = 0; i < 25; i++) {
    const t = 200000; // 每个 key 等满 200s 的真实场景
    if (g.canAttempt(b, Math.min(i * t, t)).allow === false) break;
    if (g.canAttempt(b, i * 200000).allow) { allowed++; g.recordAttempt(b); } else break;
  }
  assert.ok(allowed <= 3, `放行次数应 ≤3, 实际 ${allowed}`);
});

test('墙钟先于次数触发: 90s 到点即停, 即使次数没用完', () => {
  const b = g.createBudget({ maxAttempts: 30, totalTimeoutMs: 90000 }, 0);
  g.recordAttempt(b);
  const v = g.canAttempt(b, 95000);
  assert.equal(v.allow, false);
  assert.equal(v.reason, 'fallback_total_timeout');
});

test('normalizePolicy: 非法 env 值回落默认, 不炸', () => {
  const p = g.normalizePolicy({ maxAttempts: NaN, totalTimeoutMs: undefined, emptyResponseMaxRetries: -5 });
  assert.equal(p.maxAttempts, g.DEFAULT_POLICY.maxAttempts);
  assert.equal(p.totalTimeoutMs, g.DEFAULT_POLICY.totalTimeoutMs);
  assert.equal(p.emptyResponseMaxRetries, 0);
});
