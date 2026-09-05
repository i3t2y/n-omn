/**
 * parseRetryAfter — P0 补丁: Retry-After 头硬遵守解析
 * =====================================================================
 * 来源证据(上游 3.8.43 真源已有半成品, 本补丁补全 HTTP-date 洞):
 *   - open-sse/handlers/chatCore.ts:2359  取头 normalizedHeaders["retry-after"]
 *   - open-sse/handlers/chatCore.ts:2360  解析: Number.parseFloat(header) * 1000
 *                                           ↑ 只处理"秒数"格式, 遇 HTTP-date 返 NaN → 退避失效
 *   - open-sse/services/accountFallback.ts:519  注释明提 "a `Retry-After` header"
 *                                            应被 exactCooldownMs 精确遵守, 但上游解析阶段就漏了 HTTP-date
 *
 * 补丁职责(架构师红线: "遵守"而非"重试策略"):
 *   本函数只解析 + 返回最小等待毫秒数. 是否重试 / 403 进冷却还是熔断的
 *   分类策略, 属 R3 宣判后才定稿部分, 本补丁一律不实现, 只留接口(TBD-POLICY).
 *
 * 适用面(由调用方决定, 本函数仅给值):
 *   429 / 503 / 携带 Retry-After 头的 403
 *
 * RFC 7231 §7.1.3 Retry-After 两合法格式:
 *   1. delta-seconds: 纯数字秒, 如 "120"
 *   2. HTTP-date:    IMF-fixdate, 如 "Wed, 22 Jul 2026 03:16:00 GMT"
 *
 * 边界:
 *   - 秒数负值/NaN → null (协议非法, 不作退避依据)
 *   - HTTP-date 已过 → 0 (等方式不退避, 但返回0以区分"无头")
 *   - 解析失败/未知格式 → null (调用方走指数退避+抖动分支)
 *   - 秒数封顶: RFC 允许巨大值, 本函数不截断(遵守语义), 由调用方 maxCooldownMs 兜底
 */

// HTTP-date 解析: 用 Date.parse 接 IMF-fixdate (RFC 7231 §7.1.1.1)
// 返回 null 表"非日期或解析失败", 返回 0 表"日期已过当下"
function parseHttpDate(header: string, nowMs: number): number | null {
  const ts = Date.parse(header);
  if (Number.isNaN(ts)) return null; // 非 HTTP-date
  const delta = ts - nowMs;
  return delta < 0 ? 0 : delta;
}

// delta-seconds 解析: 仅整数/浮点秒, 严格拒非数字串
// 返回 null 表"非秒数格式"
function parseDeltaSeconds(header: string): number | null {
  // 严格: 允许前后空白, 中段必须是纯数字(可带小数点)
  const trimmed = header.trim();
  if (trimmed === "" || !/^\d+(\.\d+)?$/.test(trimmed)) return null;
  const seconds = Number.parseFloat(trimmed);
  if (!Number.isFinite(seconds) || seconds < 0) return null;
  return seconds * 1000;
}

/**
 * 解析 Retry-After 头为最小等待毫秒数(硬遵守依据).
 * @param header 原始头值(undefined/null → null)
 * @param nowMs  当前时间戳(注入以便测试, 不在函数内 new Date)
 * @returns 毫秒数; null=无头或格式全失败(走退避); 0=日期已过
 */
export function parseRetryAfter(
  header: string | null | undefined,
  nowMs: number
): number | null {
  if (header == null) return null;
  const h = String(header).trim();
  if (h === "") return null;

  // 先试 delta-seconds (纯数字), 不通再试 HTTP-date
  const seconds = parseDeltaSeconds(h);
  if (seconds !== null) return seconds;

  const dateMs = parseHttpDate(h, nowMs);
  return dateMs; // null 或 0 或 正数
}

// ── TBD 参数清单(依赖 R3 宣判, 本补丁不填值) ──────────────────
// TBD-POLICY-1: retryAfterMs 命中后, 403 进 cooldown 还是 circuit-breaker?
//               (上游 accountFallback.ts:704 现 403→quota_exhausted 1h 短冷却, 4.B 第10项判 P0 缺陷,
//                但改策略违本补丁红线, 留 R3 宣判定稿)
// TBD-POLICY-2: Retry-After 头值的硬度上限 (是否 cap 到 maxCooldownMs, 用哪个 TBD 常数)
// TBD-PARAM-3:  无 Retry-After 退避基数/上限/抖动幅度 (现 v2 §待R3: TBD-COOLDOWN-MS 参数谱)
// TBD-DEDUP-4:  请求指纹算法 + 退避窗口去重 store 实现 (本补丁只给接口)
// ──────────────────────────────────────────────────────────
