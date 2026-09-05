# 部署链核准 + Restart A 推 Dataset 前置卡 (2026-07-20)

> R3+ Step3 执行中暴露的部署链真源分叉裁决卡。
> 首席裁决 (选 1′): 推 818 行 candidate 版覆盖生产 157 行 R2 瘦身版; 三条推前前置 + 两条验收修正; jq 双容修正式追认; 818 行唯一 SSOT, 157 行废止。

## 0. 分叉事实 (执行 cg52 暴露, 非任务包 §0 预设)

任务包 §0 自举默认 "candidate 即生产真源", 实际生产跑的是 157 行 R2 瘦身版 — **部署链起点未验真源**。首席追认: 此为任务包缺陷, 非 cg52 执行偏差。后续所有任务包 §0 硬增步骤: Dataset 实跑文件 hash 对照 repo candidate hash, 不一致即先报首席再动手。

| 文件 | Dataset nonoke/omni-logic (生产真源) | candidate-v4.3-reviewed (审计定稿) | 关系 |
|------|--------------------------------------|--------------------------------------|------|
| gate.js | 285 行 (snapshot e91a3bc2) | gate.v43-merged.js 287 行 (commit 50f5e05) | **近同, 唯一差异 = 本 Step3 改的 L40** (CONCURRENT '1'→'3' + 注释 2 行) |
| init-nim-keys.sh | **157 行 R2 瘦身版** | 818 行审计加固版 (commit 50f5e05 +48) | **严重分叉** — 818 行含 upsert_combo/filter_alive/models_to_json/maxWaitMs/jq修正/只读三GET 全套; 157 行无此三件基础设施 |
| entrypoint.sh | 250 行 | entrypoint-merged.sh 270 行+ | 近同 |

**157 行版缺口 (裁决否选项 2 的依据)**: 无 upsert_combo / 无 filter_alive / 无 models_to_json 三件基础设施 → jq 修正式无处落 (它修的就是 upsert_combo 内 CID 查询) → Step5 写跳分档 (POST 创建 nim-codex/pool/fast/stable) 整段无承载体。移植到 157 行 = 先移半套, Step5 再 157→818 量级切换 = 两次高风险生产真源替换而非一次。

## 1. 前置一: 行为差分卡 (三轴 diff)

### 1.1 env/secrets 期望 (硬门槛 — 缺一 Secret 启动即败)

818 行 init 所需 env/Secret 清单, 对照 Space 当前是否全存:

| env/Secret | 818 行用途 | Space 是否必存 | 来源/校验 |
|-----------|-----------|--------------|----------|
| `NIM_KEYS` / NIM key 池 | check_nim_model_health + register_model 探针 + provider 注册 | **必存** (entrypoint L198 `[ -n "$NIM_KEYS" ]` 守) | Space Secrets |
| `INTERNAL_PSK` | gate X-Internal-PSK 校验 | 必存 (R1 探活验 len=65 ✓) | Space Secrets |
| `HF_TOKEN` + `HF_DATASET_REPO` | hf_snapshot 上传 + litestream R2 | 必存 (~/.omn-secrets HF_TOKEN_DATASET_WRITE 验过) | Space Secrets |
| `HF_USER` / `LOGIC_BUCKET_REPO` | Dataset repo id | 必存 (LOGIC_BUCKET_REPO=nonoke/omni-logic 验过) | Space Secrets |
| `OMN_BASE_URL` / `OMN_TOKEN` | (157 行版同, 共用) | 必存 | Space Secrets |
| `BASE_IMAGE` / `EXPECTED_VERSION` | entrypoint 版本校验 | 必存 (EXPECTED_VERSION=3.8.43) | Space Variables |
| `NIM_FIXED_RPM` / `NIM_FIXED_CONCURRENT` / `NIM_FIXED_MIN_INTERVAL_MS` | 818 行限流固定值 (可选 env 覆盖) | 可选 (默认 28/1/2200ms) | env 覆盖, 无则用默认 |
| `NIM_MAX_WAIT_MS` | 本 Step3 新增 (默认 300000) | 可选 (默认 300000) | env 覆盖 |
| `NIM_POOL_STRATEGY` / `NIM_CODEX_STRATEGY` | combo strategy (FIX#4 codex=priority 默认) | 可选 | env 覆盖 |
| `NIM_CONCURRENT_LIMIT` | gate L40 (本 Step3 默认改 3) | 可选 (默认 3) | env 覆盖 |

**Space Secrets 实存态需 Restart 前验**: 启动后 Space runtime 日志 `[init] NIM_KEYS=...` / `[gate] PSK=set` 通即显齐; 若有缺, init L198 gate 不启 / gate PSK=unset 报错。

### 1.2 写面超集 (818 行比 157 行多写什么, 全显性化)

按 init 执行序, 818 行多写操作 (157 行版均无):

| 段 | 818 行写操作 | API | 影响 | 归因面 (Restart A 是否污染 C=3/maxWaitMs 归因) |
|----|------------|-----|------|----------------|
| L534 resilience PATCH | `requestQueue.{RPM, minMs, concurrent=1, maxWaitMs=300000}` | PATCH /api/resilience | 限流落定 + 本 Step3 新增 maxWaitMs | **正归因目标** (本 Step3 b 项) |
| L619 settings PATCH | `fallbackStrategy/stickyLimit/requestRetry/maxBodySizeMb` 等 | PATCH /api/settings | 路由 + body 限 | 独立, 不污 C=3 |
| L637 compression PUT | `enabled/defaultMode/autoTriggerTokens` | PUT /api/settings/compression | 压缩开启 (12000token autoTrigger) | 独立, 不污 |
| L643 CB reset | POST /api/resilience/reset | 清熔断 | 首启动清冷启动, 不污 |
| L790+ register_model ×N | POST /api/provider-models (nvidia 各模型 provider+modelId) | provider-models 注册 | 模型注册面扩大 | 独立 (探针走 /v1 不依赖注册表, 但 mock 测试可能依赖) |
| L766+ upsert_combo nim-pool/nim-codex | POST/PUT /api/combos (jq 修正式双容 CID) | combo 创建/更新 | **修正式新增项** (本 Step3 c 项) — 生产当前 combos 空 → POST 创建 nim-pool/nim-codex | **归因隔离成立** (裁决修正 1): 组1v5/组2 glm-5.2 直发 + auto×3 均不引用 combo 名, combo 存在与否不污 C=3/maxWaitMs 并发归因 |
| L705+ context_accumulator / 模型 override | 内部 per-model 32K override (apply_context_override) | context 限调整 | 独立, 不污 |

### 1.3 失败模式 (818 行 exit 1 触发点清单 — 恢复路径前置 3)

818 行比 157 行 fail-closed 严格 (配置没落定不报 ready), exit 1 触发点:

| 触发点 | 条件 | 恢复 |
|--------|------|------|
| L141-160 strategy 非法 | pool/codex strategy 非 round-robin/p2c/priority → init 失败 | env 设回合法 |
| L552 resilience 输入非法 | RPM∉[1,60000] / minMs∉[0,600000] / conc∉[1,1000] / **maxWaitMs∉[1,600000]** (本 Step3 新增校验) | env 设回默认 |
| L600 resilience GET 读回 transport-err | curl 超时/DNS → init 失败 (CF-4) | 网络恢复后 Restart |
| L613 resilience 读回不一致 | 四字段 (含本 Step3 新增 maxWaitMs) 任一不符 → init 失败 | PATCH 重发或 env 调 |
| L217 上游服务 died before gate | OmniRoute 启动崩 → entrypoint abort | 上游镜像/env 核 |

**init 失败 (exit 1) Space 表现**: entrypoint L198 init `bash /logic/init-nim-keys.sh &` — 失败 exit 1 但**不阻断 entrypoint 主循环** (background, entrypoint 继续起 gate)。**结果**: gate 仍启, OmniRoute 仍跑, 但 init 配置未落定 → 生产跑**未配置态** (28/1/2200ms 默认而非 maxWaitMs=300000 + 无 combo)。**降级运行**而非 boot 挂起。恢复: HF factory reboot 或 Dataset revert (回 157 行版) + Restart。

## 2. 前置二: 回滚锚定

- **Dataset git 历史可恢复**: Dataset nonoke/omni-logic 当前 snapshot `e91a3bc2ea87c0ba57b4dc7145f56297a7ed44ed` (157 行 init 版), HF Dataset 有完整 commit 历史, revert 此 commit 即恢复 157 行。
- **额外备份**: 推 818 行前, 显式上传 `init-nim-keys.r2-157.bak` (157 行版原内容) 进 Dataset 作为命名备份 (git revert 之外双保险)。
- **回滚程序 (两步)**:
  1. Dataset revert 至 e91a3bc2 (或删除 818 行 init, 改 r2-157.bak→init-nim-keys.sh) — ~1 次 Dataset commit
  2. Space Restart (factory reboot) — 1 个重启周期
  3. 总耗时 ≈ 两个重启周期 (~6-8min)

## 3. 前置三: 启动失败路径 (见 §1.3)

- init exit 1 → **降级运行** (gate+OmniRoute 起但配置未落定), 非 boot 挂起。
- 恢复路径: HF factory reboot (Space 设置页) / Dataset revert + Restart / Space factory reset (末手段)。
- **818 行 fail-closed 严格** = 优 (配置没落定不报 ready), 但触发失败场景多, 恢复路径先备妥 (前置 2 回滚锚定 + HF factory reboot 程序熟)。

## 4. Restart A 验收表 (修正后, 含 combo 读回新增项)

Restart 后验收 (init 全绿定义: 四字段读回一致 + restore txid 连续 + 三份只读 GET 落 log + combo 读回一致):

| 验收项 | 预期 | 验法 |
|--------|------|------|
| gate 启动显 3 并发 | `[gate] ...3并发/...` | Space runtime 日志 |
| version 3.8.43 | x-omniroute-version=3.8.43 | 任一发 chat 响应头 |
| restore txid 连续 | litestream restore 无 GAP, txid 递增 | restore 日志 + DB 查 |
| maxWaitMs 读回 300000 | `[init] Resilience 读回: ...maxWaitMs=300000` + `✓ 全字段一致` | init 日志 |
| resilience 四字段读回一致 | RPM=28 concurrent=1 minMs=2200 maxWaitMs=300000 全中 | init 日志 |
| 三份只读 GET 落 log | `[init] [readonly] GET /api/combos HTTP 2xx :: combos=[...]` 等 3 行 | init 日志 |
| **combo 读回 (修正 1 新增)** | GET /api/combos 读回 nim-pool / nim-codex 存在, models + strategy 与创建一致 | jq 修正式读 id + GET combos 验 |
| jq 修正式生效 | upsert nim-pool/nim-codex 不报 400 "Combo name already exists" (旧 bug 式会 CID 永空→POST→400 死循环) | init 日志无 400 + 组合读回一致 |
| 零写副作用 (只读跳) | 除 combo upsert(candidate 固有预设行为) 外, 不 Post 新分档 / 不 PATCH isHidden (Restart B 才写跳) | init 日志无 POST combo 非 nim-pool/codex |

## 5. 验收两条修正 (首席裁决)

- **修正 1 (增 combo 创建验收项)**: 818 行固有行为启动即 upsert nim-pool/nim-codex (生产 combos 空 → POST 创建)。超任务包 "Restart A=只读跳" 字面, 但放行 — 理由: 两基础 combo 是 candidate 预设行为不依赖只读跳发现新结构 (新写跳仍全留 Restart B), 归因隔离成立 (组1v5/组2 不引用 combo 名)。验收表增上表 "combo 读回" 行。
- **修正 2 (组2 启动时序)**: 818 行 filter_alive 启动期发探针, breaker reset-after-1s 快但罚态轮转可能延至重启早期。组2 须 init 全绿后 **settle ≥5min 窗口**再开跑, 记组2 起始 ts 对照 init 完成 ts, 落 audit 卡。

## 6. 追认与勘误

- **追认 jq 双容修正式**: `(if type=="array" then . else (.combos // []) end)[]? | select(.name==$n) | .id` — 对象/数组双容。**正式取代任务包 §4 修正式** `(.combos // .)[]?` (后者纯数组根下失控: 数组不接受字符串索引) 作为**唯一合法式**。
- **追认 read-back 校验补 maxWaitMs 第四字段**: 方向与 fail-closed 纪律一致 (CF-4: 写必须读回)。
- **50f5e05 commit 确认**: gate C=3 / maxWaitMs / jq 双容修正式 / 只读三 GET 四改全部符合任务包纪律。

## 7. 放行序列 (裁决 §五)

1. 前置 1-3 落 audit (本卡) 并 commit
2. 推 818 行版 (commit 50f5e05 状态) 到 Dataset nonoke/omni-logic
3. Space Restart (factory reboot)
4. 修正后验收表验 Restart A (含 combo 读回新增项)
5. init 全绿 + settle ≥5min
6. Step4 组2 并发观测

任一前置不满足 / Restart 后 init 非全绿 → 走前置 2 回滚程序, 不现场抢修。

## 8. R3+ §四 补遗 (双层并发槽澄清 + 时序纪律成文化)

> 裁决 §四第①步 (gate 只读核 + 5并诊断) 落地后追加。说明 C=3 真实实现层位与验收时序铁律。

### 8.1 双层并发槽澄清 (勘误本卡 §1.1/§4 表)

C=3 端到端 = **两道并发槽**, 各自有独立逻辑:

| 层 | 槽 | 落定处 | 拒签 429 证据 (header 形态) |
|----|----|----|----|
| **上游 (OmniRoute)** | `requestQueue.concurrentRequests` | init L145 `_CONCURRENT` → PATCH /api/resilience (R3+ 改 `:-1`→`:-3`) | 429 **带** `x-omniroute-request-id`/`x-omniroute-provider`/`cache` (§四第①步早期 #2/#3 形态) |
| **gate 本地** | `CONCURRENT_LIMIT` | gate.v43-merged.js L40 (R3+ 改 `'1'`→`'3'`, init L142 注释勘误) | 429 **只带** `Retry-After:3` (无上游头; §四第①步 5并诊断 #4/#5 形态坐实) |

**主辅关系**: 上游为主力杠杆 (OmniRoute 真正排队分发), gate 双保险 (gate 进程本地背压, 防单进程过载)。两层各 C=3, 端到端实际通过 3 并发 (上游消化 3 并行, gate 容 3 并发不自发拒)。

**§1.1 env 表勘误**: `NIM_FIXED_CONCURRENT` row 默认值由 `1` → `3`, 用途补 "(上游 requestQueue 主力 C=3)" 与 gate L40 双保险对齐。本卡 §4 验收表 "resilience 四字段读回一致" row concurrent=**3** (非 1)。

**§1.2 写面超集 L534 row**: `concurrent=1` 勘误为 `concurrent=3` (R3+ Restart A 主归因目标)。

**rootcause 卡 L16 勘注**: 指向 L27 段, 已加勘误注 (双层同=1 期任一可签 429, 单独归因 gate 欠定; C=3 补正为上游为主 gate双保险)。

### 8.2 时序纪律成文化 (验收/行为探测前置铁律)

任何验收探测或并发观测的前置 = 三件齐:

1. **阶段 = RUNNING** (Space status 不在 `RUNNING_APP_STARTING`/`BUILDING`/`BUILDING` 等过渡态)
2. **init 全绿行为代理确认** (四字段读回一致 + restore txid 连续 + 三份只读 GET 落 log + combo 读回一致)
3. **settle ≥5min** (init 完成 ts → 观测起始 ts, 间隔 ≥300s 落 audit 卡)

前置不齐即停, 不早探。命中异常分支按裁决 §三表升级, Space Secrets 核查向用户请求, 不自行试探 HF 行政区。

### 8.3 放行补遗

§7 放行序列中 init `:-1→:-3` 修正已随第②步落地, commit 同卡 (rootcause L16 勘误 + L142 注释勘误 + 本卡补遗)。推 Dataset 仅 `init-nim-keys.sh` (gate 自首次推送未动 L40)。

---

*2026-07-20 R3+ Restart A 部署链核准卡 · 首席 1′ 裁决 · 818 行 candidate 唯一 SSOT 废 157 行 R2 · jq 双容修正式追认取代任务包 §4 式 · 三前置 (行为差分/回滚锚定/失败路径) + 两验收修正 (combo 读回/settle≥5min) · §四补遗 (双层并发槽澄清 + 时序纪律成文化) · commit 50f5e05 + §四第②步同卡 · 推 Dataset + factory reboot + 时序前置验收 + 3并复测 依次放行*
