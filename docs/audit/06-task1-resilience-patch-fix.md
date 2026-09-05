# Stage E · audit/06 — 任务一 Resilience PATCH 修复报告

> 任务一#21 init Resilience PATCH 修复 (candidate-v4.3-reviewed)
> 生成日期: 2026-07-12
> 三基准: B1 nomn/main @ `42ea8e7` | B2 working tree @ `9a1a7f0` | B3 omniroute-v3.8.43 @ `b729a8f`
> 关联: audit/02-claim-matrix.md (CF-4, M01b, M07a) · audit/05-test-results.md ·
>   audit/07-instance-readback-plan.md (R5.K2.1 实例 readback) ·
>   omniroute-v3.8.43/src/app/api/resilience/route.ts:153 (PATCH handler) ·
>   omniroute-v3.8.43/src/shared/validation/schemas/settings.ts:37-45,116-161 (zod .strict()) ·
>   omniroute-v3.8.43/src/lib/resilience/settings/types.ts:35 (useUpstream 实位 connectionCooldown)

## 1. 根因 (源码实证)

### 1.1 3.8.43 PATCH 字段白名单 (settings.ts, route.ts PATCH handler)

B3 源码实证 (修正前 session 误标 L309 — route.ts 总 257 行无 L309):
- PATCH handler: `src/app/api/resilience/route.ts:153` (`export async function PATCH`)
- zod schema: `src/shared/validation/schemas/settings.ts`
  - `requestQueueSettingsSchema` (L37-45): `requestsPerMinute`/`minTimeBetweenRequestsMs`/
    `concurrentRequests` 三字段, `.strict()` 拒未知键
  - `settingsPatchSchema` (L~116-161): 顶层 `.strict()`, 接受 `requestQueue`/
    `connectionCooldown`/`providerBreaker`/`waitForCooldown`/`comboCooldownWait` 等已知键
- `useUpstream429BreakerHints` 真实存在 — 但位于 `connectionCooldown.{oauth,apikey}`
  子对象内 (`settings.ts:55`; `types.ts:35`; `route.ts:227-230`; `normalize.ts:135-136`)
  — 见 audit/02 M01b ACCEPT 实证. **非顶层字段**.

候选此前 (任务一前 session) 把 `useUpstream429BreakerHints` 发在 PATCH body
**顶层** → 顶层 schema `.strict()` 拒未知键 (`Unrecognized key(s) in object:
"useUpstream429BreakerHints"`), 返回 400. 此 400 ≠ transport 错误, 候选此前误
归类 transport_err 导致诊断错配. 修复: init 仅发 `requestQueue` 三字段 (**该限
流由 OmniRoute requestQueue 执行, 见 audit/02 M07a**), 不发 useUpstream429BreakerHints
(发需嵌于 connectionCooldown 子对象内, init 无此需求).

### 1.2 init 此前诊断缺失 (CF-4 红线)

audit/02 CF-4 + audit/05 实证: 候选此前 init Resilience PATCH 段仅打印
`"Resilience PATCH failed (HTTP $RESILIENCE_CODE)"`, 无 curl_rc 区分、无
abort_source、无字段名/路径记录、无 read-back. 当 PATCH 失败时 (无论因顶层
非法字段被 zod strict 拒, 或上游 transport 错, 或 4xx/5xx) 候选 init 无足够
诊断信息区分来源, 且不读回校验即继续 → CF-4 (修改 OmniRoute 共享状态必须读回)
红线违反.

## 2. 修复内容 (init-nim-keys.sh)

### 2.1 PATCH body 白名单收紧

`RESILIENCE_BODY` jq 构造: 仅发 `requestQueue` 三字段. 不发顶层
`useUpstream429BreakerHints` (该字段属 `connectionCooldown.{oauth,apikey}` 子对象,
init 无此需求; 若发于顶层会被 settingsPatchSchema 顶层 `.strict()` 拒):

```bash
RESILIENCE_BODY=$(jq -nc --argjson rpm "$PAIR_RPM" \
  --argjson minms "$PAIR_MIN_MS" --argjson conc "$PAIR_CONCURRENCIES" \
  '{requestQueue:{requestsPerMinute:$rpm,minTimeBetweenRequestsMs:$minms,concurrentRequests:$conc}}')
```

### 2.2 transport vs HTTP 错误区分

transport error 分支 (curl 底层 rc != 0 或 RESILIENCE_CODE 空):
```bash
if [ "$res_curl_rc" -ne 0 ] || [ -z "$RESILIENCE_CODE" ]; then
  abort_source=$( [ "$res_curl_rc" = 28 ] && echo 'request_timeout' \
    || ([ "$res_curl_rc" = 7 ] && echo 'proxy_connect_failure' \
    || echo 'curl_unknown') )
  echo "[init] Resilience PATCH transport-error: curl_rc=$res_curl_rc ... abort_source: $abort_source"
  RESILIENCE_CODE="transport_err"
fi
```

HTTP 4xx/5xx 非 2xx 分支 (case $RESILIENCE_CODE): 记
`status/body_snippet/path/fields_sent` 结构。

### 2.3 Read-back 严格断言

PATCH 成功后立即 GET /api/resilience 解三字段 (`_RB_RPM`, `_RB_MINMS`,
`_RB_CONC`), 逐字段比对 28/1/2200ms。任一不一致 → `return 1`/`exit 1`
(CF-4: 修改 OmniRoute 共享状态必读回)。read-back 严守三字段边界。

### 2.4 `_res_validate_int` 输入校验器

定义 `_res_validate_int value lo hi`: 拒空/非数字/<lo/>hi。三字段/RPM/MIN_MS/
CONCURRENCIES 边界 [1, 60000], [1, 60000], [1, 60000] 分别校验。

## 3. 验证结果

### 3.1 语法

```
$ bash -n init-nim-keys.sh → OK
```

### 3.2 TEST 11 (新增, test-runner.js) 7/7 PASS

```
TEST 11: init Resilience PATCH 白名单 + read-back + 校验
  ✓ PATCH body 白名单: requestQueue 三字段齐全
  ✓ 无顶层 useUpstream429BreakerHints 在 PATCH body (3.8.43 route.ts:309 拒)
  ✓ transport error 结构化 (curl_rc + abort_source 区分)
  ✓ HTTP 4xx/5xx 非 2xx 分支记 status/body/path
  ✓ read-back 28/1/2200ms 全三字段严格断言 + 不一致 init 失败
  ✓ _res_validate_int 行为 unit: 3 合法通过 + 4 非法拒绝 (0/60001/空/abc)
  ✓ TEST 11 Resilience PATCH 白名单+read-back+校验 全 PASS
```

- 校验器 unit: 3 合法 (28, 1 下界, 60000 上界) 全过;
  4 非法 (0 下界-1, 60001 上界+1, 空串, "abc") 全拒。
- 白名单 grep 确认 jq body 构造行不含顶层 `useUpstream429BreakerHints`。

### 3.3 全套 mock test

```
PASS=72 FAIL=0 SKIP=2
全 PASS. candidate tests 通过.
```

(任务一上线前 65 PASS; 增 TEST 11 7 项, 现 72 PASS / 0 FAIL / 2 SKIP。SKIP
为 NEEDS-INSTANCE 项, 非新失败。)

### 3.4 真实实例测试

- **未执行** (守纪: 只读验证源码身份 + 修改候选文件, 不访问生产实例)。
- instance test (含 init 真跑 + read-back 真验 + transport/HTTP 错误本机复现)
  延期至 audit/07 实例 readback plan (Stage E.2) 执行。

## 4. 回滚 / 风险

- **无回滚动作**: 本次仅改候选 `init-nim-keys.sh` + `tests/test-runner.js`;
  生产实例未访问, 未 install 依赖, 未改其他生产源。
- 风险:
  - `_res_validate_int` 边界 [1, 60000] 比 3.8.43 schema 宽松 (schema 用 min≥1
    无上界硬 cap), init 拒绝边界外的冗余保护, 安全。
  - read-back 严格 exit 1: 若 OmniRoute GET /api/resilience 短暂不稳, init 整体
    可能失败退。守纪上接受 (比静默 429 misconfig 危害小, CF-4 红线优先)。

## 5. 完结

任务一#21 (init Resilience PATCH 白名单 + 错误处理 + read-back) 已完成。代码改
`init-nim-keys.sh`, 测试 TEST 11 新增并全 PASS (72/0), 未触生产实例, 无回滚。
转运任务二#22 (entrypoint 时序) 与 任务三#23 (gate 诊断) — 见各独立修复报告。
