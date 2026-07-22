// verify_parseRetryAfter.js — P0 本地 mock 验证 (无 ts 依赖版, 与 .ts 同源同逻辑)
// 纪律: 禁真实端点, 全本地注入值. 验两种 Retry-After 格式正确等待.
"use strict";

function parseDeltaSeconds(header) {
  const trimmed = String(header).trim();
  if (trimmed === "" || !/^\d+(\.\d+)?$/.test(trimmed)) return null;
  const seconds = parseFloat(trimmed);
  if (!isFinite(seconds) || seconds < 0) return null;
  return seconds * 1000;
}
function parseHttpDate(header, nowMs) {
  const ts = Date.parse(header);
  if (isNaN(ts)) return null;
  const delta = ts - nowMs;
  return delta < 0 ? 0 : delta;
}
function parseRetryAfter(header, nowMs) {
  if (header == null) return null;
  const h = String(header).trim();
  if (h === "") return null;
  const s = parseDeltaSeconds(h);
  if (s !== null) return s;
  return parseHttpDate(h, nowMs);
}
function computeBackoff(p) {
  const exp = Math.min(p.baseMs * Math.pow(2, p.attempt - 1), p.maxMs);
  const pseudoJitter = (p.attempt * 9301 + 49297) % 233280 / 233280;
  const jitter = pseudoJitter * p.jitterRatio * exp;
  const wait = exp - jitter;
  return wait < 1 ? 1 : wait;
}
function shouldDedup(fp, nowMs, st) {
  const u = st.getUntilMs(fp);
  return u === null ? false : nowMs < u;
}

const now = Date.parse("2026-07-22T03:16:00Z");
const cases = [
  ["delta-seconds 120 → 120000", parseRetryAfter("120", now), 120000],
  ["HTTP-date 未来+60s → 60000", parseRetryAfter("2026-07-22T03:17:00Z", now), 60000],
  ["HTTP-date 已过 → 0", parseRetryAfter("2026-07-22T03:00:00Z", now), 0],
  ["null → null", parseRetryAfter(null, now), null],
  ["空串 → null", parseRetryAfter("", now), null],
  ["上游洞 IMF-fixdate 'Wed,22 ... GMT' 非 NaN",
   parseRetryAfter("Wed, 22 Jul 2026 03:17:00 GMT", now), 60000],
  ["未知格式 'foo' → null(走退避)", parseRetryAfter("foo", now), null],
];
let fails = 0;
for (const [name, got, want] of cases) {
  const ok = got === want;
  if (!ok) fails++;
  console.log(`${ok ? "✅" : "❌"}  ${name.padEnd(48)} 预期 ${want}  实测 ${got}`);
}
let bf = 0;
for (let a = 1; a <= 5; a++) {
  const w = computeBackoff({ attempt: a, nowMs: now, baseMs: 1000, maxMs: 60000, jitterRatio: 1 });
  if (w <= 0) bf++;
}
const boMin = computeBackoff({ attempt: 1, nowMs: now, baseMs: 1000, maxMs: 60000, jitterRatio: 1 });
console.log(`${bf === 0 ? "✅" : "❌"}  computeBackoff 1..5 永远 > 0 (禁立即重试守门)  sample a1=${boMin}`);

const store = new Map();
const st = {
  getUntilMs: k => store.has(k) ? store.get(k) : null,
  setUntilMs: (k, v) => store.set(k, v),
};
st.setUntilMs("fp1", now + 150);
const din = shouldDedup("fp1", now + 100, st);
const dout = shouldDedup("fp1", now + 200, st);
const dmiss = shouldDedup("fp2", now + 100, st);
if (din !== true) { fails++; console.log(`❌  dedup 窗口内应 true 实 ${din}`); } else console.log(`✅  dedup 窗口内 true`);
if (dout !== false) { fails++; console.log(`❌  dedup 窗口外应 false 实 ${dout}`); } else console.log(`✅  dedup 窗口外 false`);
if (dmiss !== false) { fails++; console.log(`❌  dedup 无记录应 false 实 ${dmiss}`); } else console.log(`✅  dedup 无记录 false`);

const total = cases.length + 3;
console.log(`\n${total - fails}/${total} 通过`);
process.exit(fails ? 1 : 0);
