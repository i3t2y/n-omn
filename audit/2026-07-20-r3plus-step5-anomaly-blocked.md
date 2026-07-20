# R3+ Step5 写跳验收闭环 — 异常分支命中阻塞卡 (2026-07-20)

> 裁决 A 执行探针发现 combo 未在上游路由表实际建立. nf-codex/nim-pool 两 combo 探针全 400 "Unable to determine provider".
> 命中裁决 §异常分支 "400/404/503 (combo 不存在或路由失败) → 与 init 全绿推断冲突, 立即停, 不抢修, 向首席请求协取 HF instance 日志".

## 1. 裁决 A 执行规格

裁决选 A: 写跳已并入 Restart A 启动期 upsert (init L842-843 POST nim-pool/nim-codex), Step5 重定义为 "写跳验收闭环", 经 /v1 行为探针读 x-omniroute-model 头揭示 combo 解析上游模型. 不改代码 不开 ADMIN 不碰白名单.

时序前置铁律三件齐核查 (18:0X 前 settle 段):
- stage=RUNNING ✓ (复 RUNNING 16:47:23 抵, 与 Step3 验收期一致 stage 已稳)
- init 全绿行为代理确认 ✓ (探针 nvidia/z-ai/glm-5.2 直发 200 ttfb=1.24s → OmniRoute ready, provider 已注册)
- settle ≥5min ✓ (距组2末发 17:03:40 远超 53min + healthz active=0 tokens=26)

## 2. 探针结果

### 2.1 nim-codex 探针 (×3 串行 间隔 3s --max-time 75)

```
#1 http=400 t=3.57s upstream-id=none x-omniroute-model=none retry-after=none
#2 http=400 t=1.58s upstream-id=none x-omniroute-model=none retry-after=none
#3 http=400 t=1.49s upstream-id=none x-omniroute-model=none retry-after=none
```
活=0/3. **全 400**, non 首发→200 轮转 (与 key 罚态轮转纪律不符).

400 body:
```json
{"error":{"message":"Unable to determine provider for model 'nim-codex'. Use a provider/model prefix (e.g. openai/nim-codex) or ensure the model is added as a combo entry.","type":"invalid_request_error","code":"bad_request"}}
```

### 2.2 nim-pool 探针 (×8 串行 间隔 3s)

直测 nim-pool 单发同 400 同 body 提代 `nim-pool` ("Unable to determine provider for model 'nim-pool'...").

### 2.3 异常佐证 / 真源核 (只读)

- **provider 前缀尝试** `nvidia/nim-codex`/`openai/nim-codex`/`anthropic/nim-codex`/`nim/nim-codex` 全 **404** "No active credentials for provider" — 视 nim-codex 为 provider/model 二段, nim-codex 非 provider 真 model
- **GLM-5.2 直发对照** `nvidia/z-ai/glm-5.2` = **200** (`x-omniroute-model: z-ai/glm-5.2` + provider=nvidia + req-id 齐备) → 上游 provider `nvidia` 已注册激活, glm-5.2 在 provider-models 表里合规路由
- **NIM 全成员路由探活** (现时 `nvidia/<model>` 格式 45s timeout):
  - glm-5.2 **200**, nemotron-3-super **200**, qwen3.5-397b **200** — 3 活
  - deepseek-v4-flash 400, gpt-oss-120b 400, mistral-small-4 400 — 3 功态轮转态 (Step1 见 400→200)
  - deepseek-v4-pro 000, meta/llama-3.3-70b 000, gemma-4-31b 000 — 3 timeout 45s 内无返 (Step1 见 TOUT 死)
- **auto 虚拟 combo 探** `model=auto` = **503 "Maximum combo retry limit reached"** (44.7s) — auto 虚拟 combo 尝遍 NIM key 池失败
- **x-proxied-host / x-proxied-replica / x-omniroute-route-class: CLIENT_API** 头齐现 → 请求真触达上游 OmniRoute (400 由上游签, 非 gate 自拒; gate 路径仅签 retry-after:3)

## 3. 异常归因

**400 形态判**: 上游 error "Use a provider/model prefix (e.g. openai/nim-codex) **or ensure the model is added as a combo entry**" — 末句 "added as a combo entry" 暗示**上游 combos 模块存**但 **`nim-codex` 未在其表**.

即派: **init 重启期 upsert_combo POST nim-pool/nim-codex 未实际成功建到上游 combos 路由表**.

**佐证链**:
1. provider `nvidia` 已注册 — nvidia/z-ai/glm-5.2 直发 200 触上游成功 = provider 路由通. **provider 注册步 init 成跑**
2. nvidia/* 9 model 各活/功态/TOUT — provider-models 注册步 init 成跑 (combo 外的 provider/model 直路全活)
3. nim-codex/nim-pool combo 探针全 400 — **combo 路由表无此 entry**

**根因候选** (HF instance logs API 404, 执行侧无通道直证, 均为推断):
- (a) **filter_alive 跳过 + upsert 不 POST**: filter_alive L257 仅排 deprecated list (`grep -Fxq deprecated`), NIM_POOL_MODELS / NIM_CODEX_MODELS (含 glm-5.2 活等) 减去 deprecated 后应非空 → upsert 应 POST. 不太可能.
- (b) **upsert POST 静默失败**: init L134 upsert fail 仅 `cat "$F" || true` 软化, **不 exit 1**. POST /api/combos 报 422/500 时 init 继续跑 exit 0 → Space RUNNING 显绿, **combo 实未建**. 最可能.
- (c) **DB restore 后旧 combos 行 vs init 增量模式**: init L803 增量模式若 DB restore 后 combos 表**已有 nim-pool/nim-codex 旧行** (历史快照), COMBO_COUNT>0 触发增量, 增量仍 upsert 但**Combo 可能因 schema 变更/暗自禁用**. 或增量模式 case 走 `return 0` skip 后续 register (但 L811-814 仍 upsert).
- (d) **持久 combo 调用形式不对**: OmniRoute 3.8.43 期 `model=<combo-name>` 直路由**可能要求前置 combo query 时 engine 加载内存路由表** (POST 写 SQLite 表后须 OmniRoute 服务自身刷新内存缓存). 即 init upsert 写 SQLite 成功但**OmniRoute 进程内存路由表未更新** → Space reboot 后 OmniRoute 旧进程清, init 重新 upsert SQLite 但 OmniRoute 自身**已跑期间 vs init 后**, 内存表是否同步不确定. 需 HF log 证.

## 4. Restart A 验收推断校正

**fd6642b 验收卡 §5 combo 读回行**: "✓ (行为代理; 间接: 探针 200 触上游, OmniRoute 启动即跑 init, init 全绿意味着 upsert 不报 400 即 combo 建成)".

**现校正**: "init 全绿意味着 upsert 不报 400" 推断**不成立** — init L134 upsert fail **不 exit 1**, "全绿" 仅表 init exit 0, **不蕴含 combo 建成**. Restart A 验收卡 §5 行应勘误为 **combo 读回未直接证 = 行为代理推断 fail**.

## 5. 与首裁语境的对齐报告

首席选 A 锚点的语境: "题7放行⑦ 3并复测全绿后进阶段2" + "Q1 路径 A 验现两档读回 = Step5 完成 / 不改代码 不开 ADMIN" + "异常分支 400/404/503 → 与 init 全绿推断冲突 → 立即停升级".

**现命中异常分支**: combo 探针 400 (combo 路由表无 entry) = **与 init 全绿推断冲突**. 按裁决 §四放行纪律 "命中异常分支即停并按表升级, 不现场抢修; Space Secrets 核查类动作直接向我请求".

Step5 A 方案无法在不改代码 不开 ADMIN 路径下闭合 (combo 不存在时无从验读回). **现阻塞, 升级报首席**.

**Chief 协取需求**:
1. HF Space 设置页核 Secrets: `INITIAL_PASSWORD` 是否设 (init login 守门), `NIM_KEYS` 是否齐 8 行活 key (provider 注册依据), `INITIAL_PASSWORD`/`NIM_KEYS`/`NIM_PROFILE`/`NIM_POOL_STRATEGY`/`NIM_CODEX_STRATEGY` 全显态
2. HF instance logs 拉取 reboot 期间 init 输出 — 关键查行:
   - `[init] Incremental mode.` 或 `[init] First-time init.` (走 L801 增量还是 L815 首启分支)
   - `[init] upsert nim-pool: new -> POST HTTP <CODE>` / `nim-codex: new -> POST HTTP <CODE>` (POST 真态)
   - 若 POST 404/422 init 静默跳过 — POST 真失败但 init 不 exit
   - `/tmp/omn_ro_combos.json` GET 时结果 (init L635 只读三 GET 落 log, 上游 combos 列表)
3. HF Space 管理*面*直接查 combos 表 (若可直登 OmniRoute 内侧管理 dashboard — 但 ADMIN_ENABLED=false 时无后台面; 若须启 ADMIN 临时看 combos 列表首席参裁 (C 裁否明禁项 重提))

## 6. 我做不到的 (纪律限)

- 无 ADMIN, 无 HF log 通道, 无 cookie / 内网 $BASE_URL
- 不擅自 POST /api/combos 写新建 (gate 拒 + 纪律 B/C 否)
- 不现场抢修 (改 init 调 upsert fail→exit 1? 此属改代码属 Restart C, 非本 Step5 A 验收闭环)
- 不自查 HF 行政区 Secrets (须首席代取或转用户)

## 7. 步骤替代配置

首席 A 裁原 Step5 = "验现两档读回 = 完成". 现 readback 探 **combo 入 路 由 表 未 建** → A 路径无法闭合. 候选升级:
- (I) 首席协取 HF instance logs / Secrets 清单 → 定根因 (a/b/c/d) → 改 init → Restart C 推 + reboot (走 B 类内部修复路径 非外部 ADMIN 写, 守纪律)
- (II) 接受 combo 不建态 — 主路径 glm-5.2 直发稳, 日常客户端走 `nvidia/z-ai/glm-5.2` 直 model 不依赖 combo; B 选项独立 nim-fast/stable combo 缓建, 等 Step6 数据; 本文件 A 验收闭环以"combo 未建实证已读回"作封 立项跟踪
- (III) 探'Restart C'拟: POST 二 init 文件 + 一 reboot 修 combo 建 (是 B 类非外部写, 不破铁律) — 但需首席明批新重启轮 + 修 upsert fail-exit (fail-closed 闭环)

## 8. 现态

- Step5 阻 #49 (in_progress)
- 任务 Step6/7 阻塞
- 生产无停止风险 (主路径 glm-5.2 活, OmniRoute 200 RUNNING 3.8.43, 仅 combo 模块未建非主路径依赖)

---

*2026-07-20 ~18:05 R3+ Step5 阻卡 · combo 探针全400 "Unable to determine provider for model 'nim-codex/nim-pool'" · provider 已注册激活 (nvidia/* 直发活证) 但 combo 上游路由表无 entry · init upsert 静默失败推断 (L134 不exit) 或 OmniRoute 内存路由表未刷新 · 命中异常分支同首裁纪律停升级 · 待首席协取 HF logs / Secrets 定根因*
