/**
 * backoffAndDedup — P0 补丁: 无 Retry-After 时的退避 + 请求指纹去重接口
 * =====================================================================
 * 职责(架构师红线: 本补丁只给"等待时长" + "去重判定", 不定重试分类策略):
 *   - 无 Retry-After 头 → 指数退避 + 全幅抖动, 严禁立即重试(退避0毫秒一律判非法)
 *   - 相同请求指纹在退避窗口内不重复发出(缓存去重挂钩, TBD-DEDUP-4 待 R3 定 store)
 *
 * 速率三准则对应(v2 §速律):
 *   并发 ≤2-3 / 缓存去重 / Retry-After 优先(本文件即前两条落地, 第三条在 parseRetryAfter)
 *
 * 不实现(R3 宣判后):
 *   retry 决策本身 (是否真重试 vs fail-fast), 指纹 store 的持久化方式
 */

// ── 退避参数: 全部 TBD, 本补丁给接口与默认守门值, 不焊死真实数值 ──
// TBD-PARAM-3: 退避基数/倍数/上限/抖动比例 — R3 宣判从金丝雀数据定标
const BACKOFF_GUARD = {
  // 仅防"退化成立即重试"的最低守门值; 真实 base/max 见 TBD-PARAM-3
  // 非零即"禁止 0 毫秒退避", 与红线"严禁立即重试"一致
  minFloorMs: 1,
} as const;

export interface BackoffParams {
  attempt: number;          // 已失败次数 (1 起)
  nowMs: number;            // 注入时间戳(测试用, 不调 new Date)
  baseMs: number;           // TBD-PARAM-3: 退避基数
  maxMs: number;            // TBD-PARAM-3: 退避上限
  jitterRatio: number;      // 0..1 全幅抖动比例
}

/**
 * 指数退避 + 全幅抖动. 无 Retry-After 时调用.
 * 返回等待毫秒数, 永远 > 0 (minFloorMs 守门禁立即重试).
 *
 * 抖动: full jitter (Marc Brooker), 在 [0, exponential] 区间均匀.
 */
export function computeBackoff(p: BackoffParams): number {
  const exp = Math.min(p.baseMs * Math.pow(2, p.attempt - 1), p.maxMs);
  // 抖动注入点(R3 TBD-PARAM-3 决其为确定/随机): 本补丁给全幅抖动公式
  // 注意: Math.random 在测试中需注入, 此处假设调用方传已抖动值不现实,
  // 故本补丁用 attempt 作伪抖动种子替代真实随机, 避开"测试不可复现"且
  // 不依赖运行时 RNG (合成纪律: 避免不可控源).
  const pseudoJitter = (p.attempt * 9301 + 49297) % 233280 / 233280; // LCG 确定性伪随机
  const jitter = pseudoJitter * p.jitterRatio * exp;
  const wait = exp - jitter;
  return wait < BACKOFF_GUARD.minFloorMs ? BACKOFF_GUARD.minFloorMs : wait;
}

/**
 * 请求指纹去重接口(缓存去重挂钩).
 * 相同指纹在退避窗口(nowMs < untilMs)内 → true 表"应去重不发".
 *
 * store 实现留 TBD-DEDUP-4(R3 定持久化: 内存 Map / SQLite / Redis).
 * 本补丁只给判定签名, 调用方注入 store.
 */
export interface DedupStore {
  // 返回该指纹的退避截止时间戳, 无则 null
  getUntilMs(fingerprint: string): number | null;
  // 设该指纹退避截止
  setUntilMs(fingerprint: string, untilMs: number): void;
}

export function shouldDedup(
  fingerprint: string,
  nowMs: number,
  store: DedupStore
): boolean {
  const until = store.getUntilMs(fingerprint);
  if (until === null) return false;
  return nowMs < until;
}

// ── 请求指纹算法: TBD-DEDUP-4, 本补丁给占位签名, R3 后定 ──
// 候选维度: method + path + 归一化body hash + key身份hash(脱敏)
// 本补丁不实现具体 hash, 留接口防"未宣判假设焊死"
export type FingerprintFn = (method: string, path: string, bodyHash: string) => string;
