# 模型分档分析方案 (2026-07-20)

> 任务: 搜索查证 omn 项目目录所有"模型分档"脚本/文档 → 提炼 + 修正 + 优化 → 最佳模型分档分析方案。
> 方法: Explore agent 全扫 omn-merge + omn-ops (candidate-v4.3-reviewed / 5.0 / 5.1 / 4.2.3 / audit / docs) 取 7 条引证 + R3+ 序3a 探针真测数据 (4 活 8 死 latency 实测) 交叉修正。
> 关联: [[omn-merge-script-version-topology]] [[omniroute-gateway-goal-and-risks]] [[omn-三层解耦新方案绕hf冻]]

---

## 1. 命中清单 (脚本/文档 + 行号 + 分级机制)

### 1.1 `candidate-v4.3-reviewed/init-nim-keys.sh` — 生产实跑版, **仅 2 combo, 无分档**
- L767: `COMBO_COUNT=$(... WHERE name IN ('nim-pool','nim-codex'))` — 增量门只数这 2 个
- L777-778 / L806-807: `upsert_combo "nim-pool" "$_POOL_STRATEGY" "${POOL_ALIVE[@]}"` + `upsert_combo "nim-codex" "$_CODEX_STRATEGY" "${CODEX_ALIVE[@]}"`
- L144-153 策略默认:
  ```bash
  _POOL_STRATEGY="${NIM_POOL_STRATEGY:-p2c}"        # 多活 key → p2c; 单 → round-robin (L146)
  _CODEX_STRATEGY="${NIM_CODEX_STRATEGY:-priority}" # FIX#4: 原 round-robin → priority (code-gen 不宜每轮换模型)
  ```
- **分级机制**: 无 TIER 概念。POOL = 全活模型 (filter_alive 后 build_all_models 去重), CODEX = 固定 `NIM_CODEX_MODELS` 子集。按"场景"分 2 combo (通用池 vs 代码生成), 非按 latency/speed/context 分档。

### 1.2 `5.0/init-nim-keys.sh` — 旁支, **4 combo + SSOT 三档分档**
- L80 §1 注: `模型分档 SSOT（对齐现行 NVIDIA 目录）`
- L82-101 三档数组 (写死模型名):
  ```bash
  TIER_FAST=( z-ai/glm-5.2 deepseek-ai/deepseek-v4-flash deepseek-ai/deepseek-v4-pro meta/llama-3.3-70b-instruct )
  TIER_STABLE=( nvidia/nemotron-3-super-120b-a12b openai/gpt-oss-120b qwen/qwen3.5-397b-a17b mistralai/mistral-small-4-119b-2603 google/gemma-4-31b-it )
  TIER_RESTRICTED=( moonshotai/kimi-k2.6 minimaxai/minimax-m2.7 mistralai/mistral-large-3-675b-instruct-2512 )
  ```
- L103-108 `NIM_PROFILE` 控制 (env 默认 balanced):
  - `fast` → POOL = TIER_FAST
  - `full` → POOL = 三档全并
  - `balanced` (默认) → POOL = TIER_FAST + TIER_STABLE
- L117-121 `NIM_FAST_MODELS=( deepseek-v4-flash llama-3.3-70b gemma-4-31b )`
- L663-672 4 combo 落地:
  ```bash
  upsert_combo "nim-pool"   "$_POOL_STRATEGY"  $_pool_models   # 主力池
  upsert_combo "nim-codex"  "$_CODEX_STRATEGY" $_codex_models  # 代码生成
  upsert_combo "nim-fast"   "round-robin"      $_fast_models   # 快速响应
  upsert_combo "nim-stable" "priority"         $_pool_models   # 稳定长会话 (复用 pool 全集)
  ```
- L193: `_CODEX_STRATEGY="${NIM_CODEX_STRATEGY:-round-robin}"` (注意: 5.0 codex 默认 round-robin, **未继承 candidate FIX#4 的 priority**)

### 1.3 `5.1/init-nim-keys.sh` — 旁支, **4 combo 同 5.0 结构**
- L489: `_combo_count=(... IN ('nim-pool','nim-stable','nim-fast','nim-codex'))`
- L507-510: 4 combo 落地 (同 5.0 L663-672)
- L140-143: POOL 单 key 自动降 round-robin; codex 默认 round-robin (亦未继承 FIX#4)

### 1.4 `docs/OmniRoute 永续节点方案 v1.0.md` L710 — **规划文档 (非实跑)**
- `Step 18: 创建/更新 Combos（nim-pool / nim-codex / nim-fast / nim-stable）` — 4-combo 设计目标, 反映 5.0 提出的设计, 非 candidate 实跑。

### 1.5 `docs/readme4.2.3.md` L82 — client 侧入口
- `模型填 nim-max 或 auto/coding` — 客户端选模型名即选档 (nim-max=最大 / auto/coding=自动代码)。

### 1.6 `candidate-v4.3-reviewed/gate.v43-merged.js` L36-41 — **唯一 proxy 侧"分档相关"行为**
```js
// 180s 容纳 thinking 模型长思考期间零 chunk; 对非 thinking 流可经 GATE_UPSTREAM_TIMEOUT_MS env 调低。
const UPSTREAM_TIMEOUT_MS = parseInt(process.env.GATE_UPSTREAM_TIMEOUT_MS || '180000', 10) || 180000;
```
- 注意: Node http.request timeout = socket 空闲超时 (非总时长), SSE 长流数据流动时计时器重置不被腰斩。
- gate 不识 model 名, 不按档路由; 仅给 thinking 模型留长 timeout 容差。

### 1.7 `audit/05-test-results.md` L126-130 — **分档落地能力硬约束 (源码侧 L2 实证)**
- `providerModelMutationSchema` (B3 `schemas/provider.ts:129-169+`) 可写字段: `provider` `modelId` `modelName?` `source?` `apiFormat` `supportedEndpoints` `targetFormat?` **`max_input_tokens?`** **`max_output_tokens?`** `normalizeToolCallId?`
- `contextLength` **仅 catalog 读态, 不可写**; API PATCH **仅 `isHidden`**; POST add 接受 max_tokens
- → **按 token 长度分档可写 (`max_input_tokens`/`max_output_tokens` 持久 inputTokenLimit/outputTokenLimit), 按 `contextLength` 字段不可写**

---

## 2. 综合段 (分档散在哪 / 生产有无 / 旁支是否瞎生 / 字段名值)

| 维度 | candidate v4.3 (生产实跑) | 5.0 / 5.1 (旁支) | 永续节点 v1.0 (规划) |
|------|--------------------------|------------------|---------------------|
| combo 数 | **2** (nim-pool, nim-codex) | 4 (+ nim-fast, nim-stable) | 4 (目标设计) |
| 分档机制 | 无 TIER; POOL=全活 / CODEX=固定子集 | **SSOT 三档数组 (TIER_FAST/STABLE/RESTRICTED) + NIM_PROFILE env** | 描述性 Step 18 |
| 按什么分 | 场景 (通用 vs 代码) | 模型名写死 (凭名想当然) | — |
| POOL strategy | p2c (多 key) → round-robin (单) | 同 | — |
| CODEX strategy | **priority (FIX#4)** | round-robin (**未继承 FIX#4**) | — |
| fast/stable 落地 | ❌ 无 | ✅ (round-robin / priority) | 规划目标 |

**核心结论**:
1. **生产实跑 (candidate v4.3) 无模型分档**。只有"通用池 vs 代码池"2 combo 场景切分, 不按 latency/speed/context 分档。
2. **5.0/5.1 旁支瞎生 4-combo 分档**, 且分档依据是**写死模型名凭感觉**, 跟真活死/latency 全不符 (见 §3 交叉验证)。
3. **5.0/5.1 未继承 candidate FIX#4** (codex strategy 仍 round-robin, 应 priority) — 旁支代码漂移, 不可直接采用。
4. **永续节点 v1.0 的 4-combo 是规划, 不是实跑** — 若要做分档, 是设计目标不是现成可用代码。
5. **分档落地能力**: proxy 侧 (gate) 不识 model; DB mutation 可写 `max_input_tokens`/`max_output_tokens` 不可写 `contextLength`; 即"按 token 长度分档"可行, "按 catalog contextLength 强制"只能读不能改。

---

## 3. 3a 探针真测 vs 5.0 SSOT 交叉 (5.0 瞎生的实证)

R3+ 序3a 探针 (12 nvidia chat 模型 ×2 发 --max-time 30, /v1 直发绕 auto/LKGP) 真测结果对照 5.0 TIER_FAST:

| 模型 | 5.0 分档 | 3a 探针实测 | 判 |
|------|---------|------------|-----|
| z-ai/glm-5.2 | TIER_FAST | 活 1/2, 4.84s total (lat 900ms) | 中档非 fast |
| deepseek-ai/deepseek-v4-flash | TIER_FAST | 活 1/2, **20.7s total tail** (lat 14949ms, 思 640 tok) | **最慢, 当 fast 完全错** |
| deepseek-ai/deepseek-v4-pro | TIER_FAST | 未测 (3a 候选外) | 待测 |
| meta/llama-3.3-70b-instruct | TIER_FAST | **死 0/2 (400 + TOUT 30s)** | **死模型当 fast 主力** |
| meta/llama-3.1-8b-instruct | (5.0 未列) | 活 2/2, **2.15s total** (lat 89/111ms) | **真 fast, 5.0 漏** |
| minimaxai/minimax-m3 | (5.0 列 RESTRICTED 是 minimax-m2.7 非 m3) | 活 1/2, 5.85s (lat 128ms) | 中档 |
| mistral-7b/gemma-3-4b/gemma-3-12b/qwen3-next-80b/gpt-oss-20b/step-3.7-flash | — | **全 403 (NIM key entitlement 缺)** | 死 |
| moonshotai/kimi-k2.6 | TIER_RESTRICTED | 死 (400 + 403) | 死, 当 restricted 也活不了 |

**5.0 SSOT 错处一览**:
- fast 档 4 个: 1 死 (llama-3.3-70b), 1 最慢 (deepseek-v4-flash 20.7s tail), 1 中档 (glm-5.2 4.84s) — 真正 fast (llama-3.1-8b 2.15s) 反而没列
- stable 档: gemma-4-31b (gemma-3 系列已全 403 死, gemma-4 待测但同类高危); gpt-oss-120b (gpt-oss-20b 已 403 死, 120b 待测)
- restricted 档: 全是限流高危或已死

**结论**: 5.0 TIER 三档依据模型参数名 (70b/120b/397b) 想当然排, 完全没考虑 NIM key entitlement (8/12 探针模型 403 缺权限) 和 reasoning tail (deepseek-v4-flash 20.7s 思考)。**旁支分档不可用**。

---

## 4. 最佳模型分档分析方案 (提炼+修正+优化)

### 4.1 分档维度 (3 轴, 按可测可改优先)

| 轴 | 可测来源 | 可改 | 用途 |
|----|---------|------|------|
| **活死 (entitlement)** | /v1/chat/completions 探针 HTTP 码 (200/403/400/TOUT) | 改不了 (NIM key 权限面) | 第一道: 死模型不入任何 combo |
| **latency 总时延** | 探针 `time_total` + gate `x-omniroute-latency-ms` (上游真生成) | 改不了 (上游侧) | 第二道: 按快/中/慢入池档 |
| **token 长度 (context/input/output)** | catalog `contextLength` (读) / mutation `max_input_tokens` `max_output_tokens` (写) | **可写** | 第三道: 长上下文模型独立 combo |

### 4.2 探针驱动的活模型分档 (取代 5.0 写死 SSOT)

**铁律**: 分档数据必须来自 `/v1` 探针真测, 不能凭模型名写死。建议流程:
1. 周期 / Rebuild 时跑探针 (12+ chat 模型 × N 发 --max-time 60, 记 http/total/lat-ms/finish)
2. 死 (403/400/TOUT) → 压底 / 标 isHidden (API PATCH 可写 isHidden)
3. 活 → 按 `time_total` 分档:
   - **fast**: total < 3s (实测 llama-3.1-8b 2.15s ≈ 89ms lat)
   - **mid**: 3-7s (glm-5.2 4.84s, minimax-m3 5.85s)
   - **slow/tail**: > 7s 或 reasoning model (deepseek-v4-flash 20.7s 思 640 tok) → 独立 combo 或 gate 长 timeout 容差

### 4.3 落地骨架 (candidate 增量, 不复活 5.0 旁支)

```bash
# 不写死 TIER 数组。探针结果读 DB / 临时文件。
# combo 保持 candidate 2-combo + 可选扩展 nim-fast (探针活且 total<3s):
upsert_combo "nim-pool"  "$_POOL_STRATEGY"  "${MID_ALIVE[@]}"   # 通用: mid 档活模型
upsert_combo "nim-codex" "$_CODEX_STRATEGY" "${CODEX_ALIVE[@]}"  # code-gen, strategy=priority (FIX#4 保留)
# 可选 (探针显示 fast 档有价值时):
upsert_combo "nim-fast"  "round-robin"      "${FAST_ALIVE[@]}"  # 仅 total<3s 活模型
```

**strategy 约束**:
- codex 永远 `priority` (FIX#4, 5.0/5.1 退化成 round-robin 是 bug)
- fast 用 round-robin (快模型轮换省风控)
- pool 多 key 用 p2c, 单 key 回退 round-robin

### 4.4 长上下文分档 (probe 驱动 + 可写字段)

若需按 context 分档:
- 读 catalog `contextLength` 选候选 (大上下文模型)
- 写 `max_input_tokens`/`max_output_tokens` (mutation schema 可写, 持久 inputTokenLimit/outputTokenLimit) 作实际限
- **不依赖 API 改 `contextLength`** (不可写, 仅读态)
- 单独 combo 或 gate 按 model 名判 timeout (gate 当前不识 model, 需改 gate 加 model→timeout map — 慎, 增 gate 复杂度)

### 4.5 风控耦合 (跟 [[omniroute-gateway-goal-and-risks]] 三轴)

- 25 NIM key 不被风控 = 死模型莫入池 (403 entitlement 缺的 key 反复试触 breaker 罚 1s reset)
- 探针清死模型 = 降 breaker 触发率 = 保 key 池卫生
- slow/tail reasoning 模型 (deepseek-v4-flash 20.7s) 在 gate CONCURRENT_LIMIT=1 下占槽致 429 (R3+ 组1v2 死锁根因) → 慢模型归独立 combo 或限流, 不与 fast 混池

---

## 5. 待验证项 (P2 NEEDS-INSTANCE)

- [ ] deepseek-v4-pro / nemotron-3-super-120b / gpt-oss-120b / qwen3.5-397b / gemma-4-31b / mistral-small-4 3a 未测, 需扩探针清单
- [ ] 5.0 SSOT TIER 各模型 entitlement 真测 (大概率 gemma-4 / gpt-oss-120b 同族 403)
- [ ] 长上下文 token 限写 `max_input_tokens` 在 3.8.43 实例真生效 read-back (K5 FIX 后候选不依赖此写, 但 future 启用需验)
- [ ] 探针周期化 (Rebuild 跑 / 定时跑) 落地 init-nim-keys.sh 增量

---

## 6. 一句话结论

生产实跑无分档 (candidate 2-combo 按场景切); 5.0/5.1 旁支的 4-combo 三档是凭模型名写死的瞎分, 跟真活死/latency 全不符且未继承 FIX#4, **不可采用**。最佳方案 = 探针驱动活死过滤 + latency 分 fast/mid/slow, combo 增量加 nim-fast (可选), codex 保 priority, 慢模型独立档避 CONCURRENT_LIMIT 占槽 429。
