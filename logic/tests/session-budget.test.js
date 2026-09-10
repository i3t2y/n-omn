// #4b 会话预算护栏 口径修正回归 (2026-09-10):
//   旧口径按"上游 response head 到达"计数 → 对普通客户端会把"连续 3 次正常对话"误判成重放风暴,
//   永久 502。修正为"只对失败记账 + 正常完成清零 + 墙钟自首次失败起算"。
// 本文件同时守住: 真失败仍必须在 3 次内收口 (治暴能力不退化)。
'use strict';

const test = require('node:test');
const assert = require('node:assert');
const pg = require('../policy-guard.js');

function ledger(over) { return pg.createSessionLedger({ enabled: true, maxAttempts: 3, totalTimeoutMs: 90000, ...over }); }

test('正常完成不计数: 同会话 10 次正常请求全部放行 (连续对话不被误判成风暴)', () => {
  const l = ledger();
  for (let i = 1; i <= 10; i++) {
    assert.equal(pg.canSessionAttempt(l, 's', 1000 * i).allow, true, `第 ${i} 次被误拦`);
    pg.recordSessionAttempt(l, 's', 1000 * i);          // head 到达 (不是失败)
    pg.clearSessionFailure(l, 's', 1000 * i);           // 正常内容到达 → 清零
  }
});

test('仅 head 到达不累计失败: 3 次 head 无失败 → 第 4 次仍放行', () => {
  const l = ledger();
  for (let i = 1; i <= 3; i++) { pg.recordSessionAttempt(l, 's', i); }
  assert.equal(pg.canSessionAttempt(l, 's', 4).allow, true);
  assert.equal(l.get('s', 4).failures, 0);
});

test('连续失败达上限即拒: 第 3 次失败后第 4 次放行前被拦', () => {
  const l = ledger();
  for (let i = 1; i <= 3; i++) {
    assert.equal(pg.canSessionAttempt(l, 's', i).allow, true, `第 ${i} 次应放行`);
    pg.recordSessionFailure(l, 's', { reason: 'upstream_status_502' }, i);
  }
  const gate = pg.canSessionAttempt(l, 's', 4);
  assert.equal(gate.allow, false);
  assert.equal(gate.reason, 'fallback_attempt_limit');
});

test('失败后正常完成 → 计数清零, 之后仍可正常对话 (会话自愈)', () => {
  const l = ledger();
  pg.recordSessionFailure(l, 's', { reason: 'upstream_status_502' }, 1);
  pg.recordSessionFailure(l, 's', { reason: 'upstream_status_502' }, 2);
  pg.clearSessionFailure(l, 's', 3);                    // 内容到达
  for (let i = 4; i <= 9; i++) {
    assert.equal(pg.canSessionAttempt(l, 's', i).allow, true, `自愈后第 ${i} 次被拦`);
    pg.recordSessionFailure(l, 's', { reason: 'upstream_status_502' }, i);
    pg.clearSessionFailure(l, 's', i);                   // 每次都成功
  }
});

test('墙钟自首次失败起算: 正常期再长也不触发, 失败后超期才拒', () => {
  const l = ledger({ totalTimeoutMs: 90000 });
  // 正常期 10 分钟 (远超 90s), 无失败 → 不触发
  assert.equal(pg.canSessionAttempt(l, 's', 600000).allow, true);
  pg.recordSessionAttempt(l, 's', 600000);
  // 首次失败在 t=700000 起算 → t=700001 未超期放行, t=790001 超期拒
  pg.recordSessionFailure(l, 's', { reason: 'upstream_status_502' }, 700000);
  assert.equal(pg.canSessionAttempt(l, 's', 700001).allow, true);
  const gate = pg.canSessionAttempt(l, 's', 790001);
  assert.equal(gate.allow, false);
  assert.equal(gate.reason, 'fallback_total_timeout');
});

test('退化空响应: 同一会话第 2 次退化即拒 (内容空判据独立于次数上限)', () => {
  const l = ledger({ maxAttempts: 99 });
  const r1 = pg.recordSessionFailure(l, 's', { reason: 'empty_response_retry_exhausted' }, 1);
  assert.equal(r1.newlyDenied, false);
  const r2 = pg.recordSessionFailure(l, 's', { reason: 'empty_response_retry_exhausted' }, 2);
  assert.equal(r2.newlyDenied, true);
  const gate = pg.canSessionAttempt(l, 's', 3);
  assert.equal(gate.allow, false);
  assert.equal(gate.reason, 'empty_response_retry_exhausted');
});

test('denied 粘住: 已判退化的会话不会因一次成功而放行 (防风暴回潮)', () => {
  const l = ledger({ maxAttempts: 99 });
  pg.recordSessionFailure(l, 's', { reason: 'empty_response_retry_exhausted' }, 1);
  pg.recordSessionFailure(l, 's', { reason: 'empty_response_retry_exhausted' }, 2);
  pg.clearSessionFailure(l, 's', 3);
  assert.equal(pg.canSessionAttempt(l, 's', 4).allow, false);
});

test('closeSession(清理) : TTL 过后账本可回收, 不增长', () => {
  const l = ledger();
  for (let i = 0; i < 100; i++) pg.recordSessionFailure(l, 'k' + i, { reason: 'upstream_status_502' }, 1);
  assert.equal(l.size(), 100);
  l.sweep(1 + pg.SESSION_TTL_MS + 1);
  assert.equal(l.size(), 0);
});

test('classifyProbeFailure: 真内容/流内错误 → 不记账; 退化/零内容 → 记账', () => {
  assert.equal(pg.classifyProbeFailure({ sawNonPingContent: true, degenerateEmpty: false }), 'ok');
  assert.equal(pg.classifyProbeFailure({ sawError: true }), 'ok');
  assert.equal(pg.classifyProbeFailure({ degenerateEmpty: true }), 'empty_response_retry_exhausted');
  assert.equal(pg.classifyProbeFailure({ sawNonPingContent: false, degenerateEmpty: false }), 'upstream_empty_response');
  assert.equal(pg.classifyProbeFailure(null), 'ok');
});

test('治暴能力不退化: 坏会话 (每次都失败) 仍在 3 次内收口, 不放到 20+', () => {
  const l = ledger();
  let passed = 0;
  for (let i = 1; i <= 25; i++) {
    const g = pg.canSessionAttempt(l, 'storm', i);
    if (!g.allow) break;
    passed++;
    pg.recordSessionFailure(l, 'storm', { reason: 'upstream_status_504' }, i);
  }
  assert.equal(passed, 3);
});
