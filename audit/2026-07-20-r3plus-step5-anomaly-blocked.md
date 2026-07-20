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

## §六① 仓内核 schema+route 真相 (首席裁决2放行序第①步只读核)

上游仓真实路径 `/home/laisi/3.8.43` (非记忆里 `~/omniroute-v3.8.43/@b729a8f`, 该路径本会话已失效). 仓内源码 > 官方文档, 冲突以源码为准.

### 核心文件原文钉死

**`src/shared/validation/schemas/combo.ts` L254-271 `createComboSchema`:**
```ts
export const createComboSchema = z.object({
  name: comboNameSchema,                                    // 必填, regex /^[a-zA-Z0-9_/.\-\[\] ]+$/
  description: z.string().max(2000).optional(),
  models: z.array(comboModelEntry).optional().default([]),  // 可选, 默认空数组
  strategy: comboStrategySchema.optional().default("priority"), // 可选, 默认 priority
  config: comboRuntimeConfigSchema.optional(),
  // ... 其余全 optional
});
```
- `comboModelEntry` L42 = `z.union([z.string()trim().min(1).max(300), comboModelStepInputSchema, comboRefStepInputSchema])` — **models 数组元素可以是纯字符串, 或 {model:...} 对象, 或 combo-ref**.
- `comboModelStepInputSchema` L25: `model` 必填 `min(1).max(300)`, 其余 (`kind/provider/providerId/tags/...`) 全可选. 即 `{model:"nvidia/z-ai/glm-5.2"}` **schema 合规**.

**`src/app/api/combos/route.ts` POST:**
- 守 `requireManagementAuth(request)` (走 dashboard cookie auth_token, init 已 login 建 session).
- `validateBody(createComboSchema, body)` zod 验失败返 400 `{error: validation.error}`.
- `getComboByName(name)` **重名返 400 "Combo name already exists"**.
- DAG 验证失败返 400.
- 成返 **201** (`NextResponse.json(combo, { status: 201 })`).

**`src/app/api/combos/[id]/route.ts` 更新动词:**
- 注册函数 = **`PUT`** (非 PATCH). 无 `PATCH` 注册.
- 成返 200 (json 无 status 字段 = 默认 200).
- `QUOTA_MODEL_PREFIX (qtSd/)` 名前缀返 409.
- `updateComboSchema` L306 + superRefine "No valid fields to update" — `{name, strategy, models}` 全合规.

### F1/F2 裁决推断 证伪

| 裁决2推断 | 仓内核证 | 结论 |
|----------|---------|------|
| F1: models 对象数组化 (init 现 `[{model:"nvidia/<path>"}]`) 与 zod 不符被静默吞 | `comboModelStepInputSchema` model 必填其余可选, `{model:...}` **schema 合规**; `normalizeComboStep` L255 `toTrimmedString(value.model)` 取出, `toFullModelString(model含/原样)` 保留 → **不吞** | 🔴 **F1 推断证伪** |
| F2: 更新动词 PUT→PATCH | `[id]/route.ts` 注册 **PUT**, 无 PATCH; PATCH 会 404 | 🔴 **F2 推断证伪** — init 现 PUT **正确**, 不应改 PATCH |

### init 现 `models_to_json` 实链路核 (合规证)

`models_to_json` L100: `printf '%s\n' "$@" | sed 's/^/nvidia\//' | jq -R '{model: .}' | jq -s -c .`
- TIER_FAST/STABLE/RESTRICTED model 名已带 provider 前缀 (如 `z-ai/glm-5.2`).
- `sed 's/^/nvidia\//'` → `nvidia/z-ai/glm-5.2` (三段).
- 产 `[{model:"nvidia/z-ai/glm-5.2"}]`.
- POST body = `{name:"nim-codex", strategy:"<STRAT>", models:[{model:"nvidia/z-ai/glm-5.2"}]}`.
- zod `comboModelEntry` union 第二支 `comboModelStepInputSchema` `model:"nvidia/z-ai/glm-5.2"` 通过 (`min(1).max(300)`).
- `normalizeComboStep` L255-277: `parseProviderId("nvidia/z-ai/glm-5.2")`=`nvidia`, `shouldTreatAsComboRef` L135 `if(providerId) return false` → 当 model 非 combo-ref. `toFullModelString` 模型含 `/` → 原样. **合规建 combo step**.

### 真根因未定 (仓内核 schema/route 证合规, POST 仍应建)

仓内核证 POST/PUT 路径 schema + 动词 + body 形态全合规, init 现 schema 写法**正确**. 若 init 真发 POST 应返 201 建成. 既探针仍报 combo 路由表无 nim-codex/nim-pool entry, 真根因不为 schema/动词, 推断候选剩:
- **(b')** init upsert 静默失败 (L134 `[ "$CODE" != "200" ] && [ "$CODE" != "201" ] && cat "$F" || true` fail 不 exit) — 但**仅 POST/PUT 真返非2xx时才静默**, 而 schema 合规应返 201, 触发静默需别的因素 (auth 失败返 401/403? cookie 未带? POST body 实发与 schema 偏移?).
- **(e) 新增**: POST/PUT 实发请求**未触达上游** (gate 拦 / 内网 $BASE_URL 未起 / cookie 失效). 但 login fail-closed 证 cookie 建过.
- **(f) 新增**: `requireManagementAuth` 对增量模式 GET 已放行 (cookie 有效), 但 POST 同 cookie 是否放? dashboard session 过期? HF Space 冷启动后 init 跑太早, OmniRoute 服务未起 login 段失败但 fail-closed 应 exit — 不符 "全绿".

### 决策: 冲突即停报首席

裁决2 批 Restart C b+c 合并修复的首席根因推断 (F1 对象数组不符 + F2 改 PATCH) **经仓内核静默证伪**. 按 R3+ 纪律 "与首席推断冲突即停报首席不擅变", 不擅自改 init (init 现 schema 合规, 改了反破).

有效剩余: b 包 ("看得见" — fail-closed L134 删软化 + DB行读回 F4 + 行为终验 F5) 仍为正补强, 但**不为根因**. 使 b 包 ip 须先证真根因 (POST/PUT 真返非2xx?). 无 HF log 通道, 执行侧无法直证 POST 真态.

**报首席决策点**:
1. Restart C "写对(c)" 包前提 (F1+F2 根因) 证伪, c 包**取消** (init 现 schema/动词合规, 改了反破).
2. b 包 (fail-closed + F4 + F5) 是否单独推? 但无真根因时 b 包仅补强观测, **不能解决 combo 未建** 问题 (若 POST 真返非2xx, fail-closed init 会 exit 1 → Space 不 RUNNING 反变坏).
3. **真根因协取仍需 HF instance logs**: 关键查行 `[init] upsert nim-codex: new -> POST HTTP <CODE>` 真态 — 现 audit 卡 §5 已列, 仍待首席协取.
4. 或后备 (II): 接受 combo 不建态, 主路径 glm-5.2 直发稳足日常用, nim-fast/stable 独立 combo 缓建待 Step6 数据.

**不擅跑 Restart C 改 init.** §六②③停. 待首席.

---

*2026-07-20 ~R3+ §六① 仓内核只读核完 · 上游真路径 /home/laisi/3.8.43 · F1/F2 裁决推断证伪 (comboModelEntry union 纯串/对象皆合规 + 更新动词=PUT 非 PATCH) · init 现 models_to_json schema 合规 · 真根因未定 (POST/PUT 真态需 HF log) · c 包取消 b 包前提动摇 · 冲突即停报首席不擅改*

## §六②-1 T0 外部 GET /api/combos 决定性探 (首席裁决3 §3 T0)

T0 = 30s 外部经 gate+PSK GET /api/combos 一发, 命中即按表跳级.

### 执行

- 时 19:21:06 GET `https://nonoke-omn.hf.space/api/combos` X-Internal-PSK + Accept:json --max-time 30
- 结果 **http=404**, body 空 0B
- resp headers: `x-proxied-host: http://10.112.81.68` + `x-proxied-replica: y52yiled-j9xkp` + `x-proxied-path: /api/combos` 齐备 -> 请求经 gate 转发触达上游 OmniRoute 实例 ✓

### 判别归因 (404 非 200 非 401)

**404 非 requireManagementAuth 拒**: 3.8.43 源 `requireManagementAuth.ts` L138 无任一 auth 路径即返 **401 "Authentication required"**, 非 404. 外部非 dashboard session/非 loopback/非 CLI token/非 access token/非 manage-scope API key 应返 401.
**404 非 gate 429 背压**: gate tryAcquire 拒走 429 + retry-after:3 (记忆组2实证), T0 404 无 retry-after.
**404 来源候选**:
- (i) gate ADMIN_API_ROUTES 白名单 `/api/combos` 虽列 GET 但 method 匹配逻辑对 GET 不放, gate 静拒 404 (与记忆 § 行"只列 GET apiRouteMatch 对 POST 退 false 404"同构, 但方法=GET 应放 — 实 404 则 GET 亦被拒, 与记忆不符)
- (ii) 生产 OmniRoute 实际部署的 combos route 与 3.8.43 源码漂移 (镜像 :stable 内部可能 version≠3.8.43 / combos route 路径变)
- (iii) gate 路径改写, `/api/combos` 映到别处返 404
- x-proxied 齐备 -> 请求**真触上游**, 404 由上游或 gate 终点签 (非直读 combos 表)

### T0 结论 → 进 T1

T0 **无法直接读 combos 表真态** (外部 GET /api/combos 被拒 404, X-Internal-PSK 不够 — 外部非 dashboard session 非 loopback 非 manage-scope key). combos 表真相需 **T1 litestream 副本 DB 直读** 或 **HF UI 日志协取** (降级并行可选项).

外部 PSK 通道对 /api/combos 管理 route 不通 — 这亦证 init 写 /api/combos 必走内网 dashboard cookie (init login fail-closed L478-484 证 cookie 已建), 外部探测无权触 combos 真态.

### 下一步: T1 判可达性 + 拉 litestream 副本

先读 Dataset 里 litestream.yml 判副本落点. 若 file:// (容器本地路径) 副本不可达 -> 跳过进 T2. 若副本 R2/S3 远端 -> 拉副本 sqlite3 SELECT.

---

## §六②-2 T1 litestream 副本可达性判

### 副本落点 (本地 candidate-v4.3-reviewed/litestream.yml)

```yaml
dbs:
  - path: /app/data/storage.sqlite
    replica:
      type: s3
      bucket: omn-data
      path: db/storage.sqlite
      endpoint: https://${R2_ACCOUNT_ID}.r2.cloudflarestorage.com
      access-key-id: ${R2_ACCESS_KEY_ID}    # <- R2 凭证
      secret-access-key: ${R2_SECRET_ACCESS_KEY}
      sync-interval: 10s
      auto-recover: false
```

**判: 副本 = R2 Cloudflare S3 远端 (非容器本地 file://)**. 按首席 §3 表 "T1 可达 → 拉副本 sqlite3 读 combos 表".

### 执行侧可达性核

T1 拉副本需 R2 凭证 (`R2_ACCESS_KEY_ID`/`R2_SECRET_ACCESS_KEY`/`R2_ACCOUNT_ID`). 核 `~/.omn-secrets` 键名清单:
```
API_KEY_SECRET GHCR_IMAGE GHCR_PAT GHCR_PAT_CLASSIC GHCR_USER
HF_TOKEN HF_TOKEN_DATASET_WRITE HF_USER INTERNAL_PSK
LOGIC_BUCKET_REPO OMNIROUTE_API_KEY
```
**无任一 R2_* 键**. R2 凭证**只存 HF Space Secrets**, 执行侧本地无通道直拉 S3 副本.

### T1 结论 → 跳过进 T2

T1 **不可达** (副本在 R2, 凭证不在执行侧 ~/.omn-secrets). 按首席 §3 "副本不可达 → 跳过进 T2, 不耗时强取".

T1 不强取 R2 (R2 凭证协取属 Space Secrets 核查类, 按纪律须首席代取或转用户, 不自行试探). 进 T2 决定性零改动 reboot.

---

## §六②-3 T2 决定性零改动 reboot + settle + nim-codex×3 复探

### 执行

- 19:23:58 触 factory reboot (HF Space restart API POST `nonoke/omn`, http=200, stage=RUNNING_BUILDING)
- 19:24:44 stage 抵 **RUNNING** (RUNNING_BUILDING → RUNNING_APP_STARTING → RUNNING, ~46s)
- settle 等 ≥5min (实际至 19:31:20 探针, 距 RUNNING 满 6min36s)
- **零推送零改码** (init/Dataset/entrypoint 全未动, 纯 factory restart)

### settle 满后探针 (19:31:20)

- healthz OK (active=0 tokens=28 — 非罚态 settle 满)
- 主路径 glm-5.2 **200** t=5.50s + `x-omniroute-model: z-ai/glm-5.2` + provider=nvidia (init 全绿行为代理证 OmniRoute ready, provider 注册步成跑)

### T2 决定: nim-codex ×3 复探 (model=nim-codex 直路由)

| # | http | t | upstream-id | x-omniroute-model | body |
|---|------|---|-------------|-------------------|------|
| 1 | 400 | 1.51s | none | none | unable to determine provider for 'nim-codex' |
| 2 | 400 | 1.52s | none | none | (同) |
| 3 | 400 | 1.72s | none | none | (同) |

400 body 原文: `{"error":{"message":"Unable to determine provider for model 'nim-codex'. Use a provider/model prefix (e.g. openai/nim-codex) or ensure the model is added as a combo entry.","type":"invalid_request_error","code":"bad_request"}}`

与重启前 T0 期探针 (Step5 阻塞卡 §2.1) **完全一致**.

### T2 判别表结论 (首席 §3)

首席 §3 判别逻辑: "若 OmniRoute combo 查询按请求读 SQLite (better-sqlite3 同步直读, dashboard 列表始终新鲜, 大概率如此), boot N 的 POST 若真成功, boot N+1 重启后无论 init 再做什么, 探针都该看到 combo; 反之重启后仍 400, 即证明 POST 在每个 boot 都在失败."

**重启后仍 400 = boot N+1 仍无 nim-codex entry = POST 在每个 boot 都在失败** ✓

| 派 | 判别证据 | 结论 |
|----|---------|------|
| H3 (热加载/时序 d 派) | POST 曾成功但内存路由表未刷; 重启后旧进程清 + DB 持久 (litestream R2 sync 10s + 本地 sqlite3) + init 重跑 POST 若成探针应见 | 🔴 **否决** — 仍 400 即 POST 从未成功 (DB 无 entry, 非内存未刷) |
| H1/H2 (POST 未达/被非schema拒) | reboot 后 init 重跑路径同, POST 仍败 | ✓ **POST 在每个 boot 真败** |

### T2 结论 → 进 T3

T2 命中 "POST 真败" 分支. 真根因未定 (POST 真败但 schema/动词已证合规, 必为非 schema 原因 — auth 细粒度/CSRF/Origin/header 缺失/CID 查询非JSON判空走POST重名/...需 init 自持响应体原文证).

按首席 §4: T3 = 唯一批准的代码改动, **纯加法观测面** (fail-visible 落地形态). 前置先核 init 既有 snapshot 上传段通道复用.

---
