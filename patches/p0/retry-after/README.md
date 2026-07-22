# p0-retry-after — Retry-After 硬遵守补丁

> Supreme 增补令 #1 · 2026-07-22 · 依附 cg52 v2 §5 P0 批局部提前授权
> **本地合成弹药, 非上膛**。R3 宣判(2026-07-23 03:16 后)前不出仓不上 Space。

## 补丁作用

补上游 3.8.43 Retry-After 头解析的 **HTTP-date 缺陷**:

上游现版只解析"秒数"格式, 遇 HTTP-date 直接 `Number.parseFloat` → **NaN → 退避失效**。
本补丁按 RFC 7231 §7.1.3 两合法格式全解析, 返回最小等待毫秒数供硬遵守。

## 核心职责(架构师红线)

> "遵守"而非"重试策略"。

本补丁 **只解析 + 给等待时长**。是否重试、403 进冷却还是熔断的**分类策略**,
属 R3 宣判后才定稿部分, 本补丁**只留接口不实现** (见 TBD 清单), 避免未宣判假设焊死进代码。

## 依赖证据(上游 3.8.43 file:line)

| 锚点 | 证据 |
|---|---|
| `open-sse/handlers/chatCore.ts:2359` | `const retryAfterHeader = normalizedHeaders["retry-after"] ?? null;` 取头 |
| `open-sse/handlers/chatCore.ts:2360` | `Number.parseFloat(retryAfterHeader) * 1000` ← **只秒数, HTTP-date→NaN 洞** |
| `open-sse/services/accountFallback.ts:519` | 注释明提 "a `Retry-After` header" 应被 exactCooldownMs 精确遵守 |
| `open-sse/services/accountFallback.ts:523` | `parseRetryFromErrorText` 已有 text 解析, 头解析这一支漏 HTTP-date |
| `open-sse/types.d.ts:53` | `retryAfterMs?: number` 类型已就绪, 等解析层补全 |

**4.B 关联**: 第10项发现 `accountFallback.ts:704`(3.8.49) 403→quota_exhausted 1h 短冷却 (P0 缺陷),
但改该分类策略 **违本补丁红线**, 留 R3 宣判定稿。

## 文件清单

- `parseRetryAfter.ts` — 头解析(秒数 + HTTP-date), 返回最小等待 ms
- `backoffAndDedup.ts`  — 无头时指数退避+全幅抖动(禁立即重试守门) + 请求指纹去重接口
- `verify_parseRetryAfter.js` — 本地 mock 验证(禁真实端点), 10/10 通过

## 验证输出(Supreme 第五步验收项之一)

```
✅  delta-seconds 120 → 120000
✅  HTTP-date 未来+60s → 60000
✅  HTTP-date 已过 → 0
✅  null → null / 空串 → null
✅  上游洞 IMF-fixdate 'Wed,22 ... GMT' 非 NaN  (修复点)
✅  未知格式 'foo' → null(走退避)
✅  computeBackoff 1..5 永远 > 0 (禁立即重试守门)
✅  dedup 窗口内 true / 窗口外 false / 无记录 false
10/10 通过
```

跑法: `node verify_parseRetryAfter.js` (无 ts 依赖, JS 版与 .ts 同源同逻辑, tsx 可直接跑 .ts)

## TBD 参数清单(依赖 R3 宣判, 禁止拍脑袋填)

| TBD | 说明 | 依赖 |
|---|---|---|
| **TBD-POLICY-1** | retryAfterMs 命中后, 403 进 cooldown 还是 circuit-breaker? | R3 金丝雀 403 实判 |
| **TBD-POLICY-2** | Retry-After 头值硬度上限 (是否 cap 到 maxCooldownMs, 用哪个常数) | R3 退避谱 |
| **TBD-PARAM-3** | 无 Retry-After 退避基数/倍数/上限/抖动比例 | R3 金丝雀数据定标 |
| **TBD-DEDUP-4** | 请求指纹算法 + 退避窗口去重 store 持久化方式 (内存/SQLite/Redis) | R3 持久通道决策 |

## 适用面

由调用方决定(本补丁仅给值):
- 429 — 携 Retry-After 头即硬遵守
- 503 — 同上
- 403 — **仅当携带 Retry-After 头**时硬遵守该值; 无头 403 走分类策略(TBD-POLICY-1, R3)

## 验收红线(写入以当验收标准)

1. 补丁只解析给值, 不实现重试分类策略 ✅ (TBD-POLICY-1/2 留接口)
2. 两格式 (delta-seconds / HTTP-date) 都被正确等待 ✅ (验证 10/10)
3. 无头时退避永远 > 0, 禁立即重试 ✅ (minFloorMs 守门)
4. 去重挂钩存在但 store 实现留 R3 ✅ (DedupStore 接口 + TBD-DEDUP-4)
5. 无真实端点调用 ✅ (纯本地注入值)

## 接入约束(非本补丁执行)

R3 宣判后, 本补丁**接口接入** `chatCore.ts:2360` 处替换 `Number.parseFloat(header)*1000`,
改调 `parseRetryAfter(header, Date.now())`。接入属"改现役脚本", 在 R3 解禁令前不动。
