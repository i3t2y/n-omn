# Stage B · 主张矩阵 (audit/02-claim-matrix.md)

> 第六独立审查者 · Stage B 产出 · 未改任何生产文件, 未调真实 API, 未生成候选, 未推送
> 生成日期: 2026-07-11
> 三基准: B1 nomn/main @ `42ea8e7` | B2 working tree @ `9a1a7f0` | B3 omniroute-v3.8.43 @ `b729a8f`

## 主张矩阵列定义

`主张 | 来源候选 | 影响文件 | 证据等级(+来源) | 正确性评估 | 风险 | 决策`

决策枚举 (仅): ACCEPT | ACCEPT-WITH-GUARD | REJECT | NEEDS-INSTANCE-TEST | NEEDS-SOURCE

---

## 0. 约束执行说明

- **REJECT 类主张不在矩阵主体的"讨论"展开** (但仍在表中标 REJECT 并注明)。以下五类直接 REJECT:
  (a) 引入外部 Relay; (b) 按 Key 线性扩 RPM/并发; (c) 未经验证直接写 SQLite 内部表 (无读回); (d) context-relay 作 NIM Combo 策略; (e) latest 镜像; (f) 自动写 Secret 到日志/快照。
- **三硬红线主张直接 ACCEPT**, 不进冲突表 (audit/03): 红线1 Secret 不进 snapshot/日志; 红线2 Gate 暴露面 ≤ /healthz + /v1[/...]; 红线3 本地 SQLite 非空时 LiteStream 不覆盖恢复。
- 涉及 OmniRoute 内部 API 主张必标 **B3 文件:行**; 不得用候选文档字段名代源码符号。
- 证据等级赋**具体主张**, 不整体赋文件。
- cf-worker (候选 C8) 去留**不预先决策**, 矩阵只记现状+候选+风险, 等用户定。

---

## 1. 主张矩阵

| # | 主张 | 来源候选 | 影响文件 | 证据等级(+来源) | 正确性评估 | 风险 | 决策 |
|---|------|---------|---------|----------------|-----------|------|------|
| M01 | Resilience `providerBreaker` 字段真实存在于 `/api/resilience` PATCH Schema | 背景#2挑战 + 候选 | init-nim-keys.sh(候选可读) | **L2** B3 `types.ts:163`; B3 `route.ts:153(PATCH),:189(body.providerBreaker),:130(响应)` | 真 camel 字段, API 可读写 | 低 | **ACCEPT** |
| M01a | (配套) `connectionCooldown` 同上 | 同上 | init-nim-keys.sh | **L2** B3 `types.ts:162`; `route.ts:129,184` | 同 | 低 | **ACCEPT** |
| M01b | (配套) `useUpstream429BreakerHints` (camel) 可选字段真实存在 | 同上 | init-nim-keys.sh | **L2** B3 `types.ts:35`; `route.ts:227-230`; `normalize.ts:135-136` | 同, 注释明 opt-in | 低 | **ACCEPT** |
| M01c | NIM API Key 是否走 direct-cloud 分支 → 429 是否默认计入 breaker | 背景#2第二层 | 候选默认假设 | **L3** B3 `providerHints.ts:43-56` (defaultUseUpstream429BreakerHints: direct-cloud=true L56, proxy/self-hosted/CLI=false); NIM 是否落 direct-cloud 分支**未见显式白名单** | 推断 direct-cloud 但未验 NIM 分类 | 选错默认致 429 行为误判 | **NEEDS-INSTANCE-TEST-G1** |
| M02 | Gate `/healthz` 探测后端而非只证 Gate 存活 | 候选 C1/维度7 | gate.js:24-27 | **L1** (B1+B2 一致) gate.js `fetch /api/monitoring/health, r?.ok 否 503` | 正确, 当前已探测 | 低 | **ACCEPT** |
| M03 | Gate 暴露面须仅 `/healthz` + `/v1[/.]`, 其余 404 | 候选 C1/红线2 | gate.js:29-37 | **L1** (B1+B2) gate.js 现 `if !/v1 → next()` 透传到 proxy, **未 404** | **现不自洽违红线2** | 高 (穿透 /api 等) | **ACCEPT-WITH-GUARD** (候选改白名单 404) |
| M04 | Gate PSK 比较须 timing-safe equal, 无 PSK fail closed | 候选 C2/红线2 | gate.js:10-13,32; cf-worker:index.js:65,181 | **L1** gate.js L10 fail-closed exit(1)✓ 但 L32 `bearer !== INTERNAL_PSK` 裸比; cf-worker L181 `token === env.CLIENT_TOKEN` 裸比; cf-worker L65 fail-closed ✓ | fail-closed 现 OK; timing-safe 两处均违 | 中 (时序侧信道) | **ACCEPT-WITH-GUARD** (候选改 crypto.timingSafeEqual / Web Crypto constant-time) |
| M05 | LiteStream 本地非空库跳过 restore | 候选 C3/红线3 | entrypoint.sh:13-21 | **L1** (B1+B2 一致) 现 `litestream restore -if-replica-exists` **无非空 guard**, 无 post-restore 非空校验 + `PRAGMA quick_check` | **违红线3** | 高 (覆盖非空本地) | **ACCEPT-WITH-GUARD** (候选加 pre-restore 非空 + post-restore quick_check) |
| M06 | 进程监督: OmniRoute/litestream/init 须收 SIGTERM/SIGINT, wait, 无僵尸 | 候选 C4/维度8 | entrypoint.sh:23-59,84 | **L1** (B1+B2 一致) 现 OmniRoute/init/litestream 后台 `&`, gate.js `exec` 成前台 PID1, 子进程不收信号; `curl -sf` 无 `--max-time` | **违维度8** | 中 (僵尸/不优雅退出/init 崩溃静默) | **ACCEPT-WITH-GUARD** (候选加 trap SIGTERM/SIGINT 转发 + wait + curl `--max-time`) |
| M07 | 限流默认须固定 28 RPM / 1 并发 / 2200ms (不按 Key 线性扩) | 用户修正#2/#3 | init-nim-keys.sh:129-140 | **L1** 现行算式 `_PER_KEY_RPM=35, _RPM=_ALIVE_KEYS*35 封顶300, _CONCURRENT=_ALIVE_KEYS*3, _MIN_INTERVAL=60000/_RPM` **按 Key 线性扩** | **违用户修正#3** | 高 (无故线性扩, 触配额) | **ACCEPT-WITH-GUARD** (候选改成固定 28/1/2200ms 可审计预算 + 需先确认执行点 Gate vs OmniRoute, 否则重复限流, 见 M07a) |
| M07a | 限流由 Gate 还是 OmniRoute 执行 (避免重复限流) | M07 子问题 | OmniRoute 服务端 (B3) | **NEEDS-SOURCE** B3 `requestQueue` ResilienceSettings (types.ts 内 RequestQueueSettings: `RequestsPerMinute`/`MinTimeBetweenMs`/`ConcurrentRequests`/`MaxWaitMs`) 暗示服务端限流存在; Route.ts:122 GET 可读 | OmniRoute 可能已有限流, Gate 再限→双重 | 中 | **NEEDS-SOURCE-G3** (Stage C 读 B3 requestQueue 实际执行点 + 是否对 NIM 直连启用) |
| M08 | DEBUG 日志入 Dataset 须默认关 + 字段级脱敏 Authorization/NIM_KEY/Cookie | 候选 C6/红线1 | init-nim-keys.sh:7-9,18-27 | **L1** B2 注释 `v4.2.3⑨ DEBUG log 上传 Dataset 默认开, NIM_DEBUG_LOG_TO_DATASET=0 关`; 若日志含 Bearer/Cookie 则违红线1 | **违红线1 (动态)** | 高 (凭据进 Dataset) | **ACCEPT-WITH-GUARD** (候选改默认关 + 上传前脱敏, 动态验证见 NEEDS-INSTANCE-TEST-G4) |
| M08a | DEBUG 日志内容是否真含凭据 (动态风险确认) | M08 子问题 | 运行时日志 (生产实例) | **NEEDS-INSTANCE-TEST** | — | 仅只读最小捕获 + 脱敏 | **NEEDS-INSTANCE-TEST-G4** |
| M09 | Context Override 候选用 `contextLength` 字段写 `/api/provider-models` | 候选 文档 | provider-models route | **L2** B3 `providerModelMutationSchema` (`schemas/provider.ts:129-169+`): 字段含 `provider/modelId/modelName?/source?/apiFormat/supportedEndpoints/targetFormat?/max_input_tokens?/max_output_tokens?/normalizeToolCallId?`; **无 `contextLength`** | 候选字段名**不存在于可写 schema** | 高 (写入被 schema 拒, 400) | **REJECT** (基于 D1, §3) |
| M10 | Context Override 候选正确字段 = `max_input_tokens` / `max_output_tokens` | B3 schema rectify | provider-models POST/PUT | **L2** B3 `schemas/provider.ts:167-168` (`max_input_tokens`, `max_output_tokens` 可选正整数, wire shape; 持久化为 inputTokenLimit/outputTokenLimit 注释 L165-166) | 可写入真实 schema | 低 | **ACCEPT** (仅 schema 字段; 是否写入决策见 M11) |
| M11 | 自动回写 `model_context_overrides` SQLite 内部表 (init-nim-keys.sh) | B1 vs B2 | init-nim-keys.sh (B1 含 L463 旧自动回写) | **L2** B3 `migrations/110_model_context_overrides.sql:8-11` (表+real_context+idx_mco_source 真实存在); `db/modelContextOverrides.ts:30/50/66/102-103/115` 含 INSERT OR REPLACE/SELECT/DELETE 封装 | 表真实; 但**脚本直写内部表不经 API + 无读回验证** | 中 (绕 API 契约; 与 OmniRoute 内部 modelContextOverrides.ts 并发写竞态) | **REJECT** (按约束 (c) 未经验证直接写内部表; 等候选改为 API `patch /api/provider-models` + 读回验证后再议) |
| M12 | B1→B2 commit 4632e8c: 禁用 context-monitor 自动回写 (`INSERT INTO model_context_overrides ... ON CONFLICT DO UPDATE` 整段注释禁) | git B1→B2 | init-nim-keys.sh | **L1 git diff** `git show 4632e8c` 注释掉 monitor→override INSERT SQL; 主动干预转被动观测 | **正确方向**: B2 已对齐背景#7"只观测不自动回写" | 低 | **ACCEPT** (B2 现行; 候选须保留禁用并对齐 B1 部署) |
| M13 | B1→B2 commit 4632e8c: 移除 `nim_health_pick()` (启康打分选型, 读 call_logs) | git B1→B2 | init-nim-keys.sh | **L1 git diff** 删除 nim_health_pick 函数; 保留 context_recommendations 被动观测 | 正确, 降复杂 | 低 | **ACCEPT** |
| M14 | B1→B2 commit 9a1a7f0: 删 Memory legacy+extended (`PATCH /api/settings` memory 字段 + `PUT /api/settings/memory`) | git B1→B2 | init-nim-keys.sh | **L1 git** msg 注释 "skills.injection.skipped reason:no_enabled_skills 从未生效" | 正确, 删失效块 | 低 | **ACCEPT** |
| M15 | B1→B2 commit 9a1a7f0: 删 Thinking budget (`PUT /api/settings/thinking-budget`) | git B1→B2 | init-nim-keys.sh | **L1 git** 删 _THINKING_MODE/_THINKING_BUDGET | 正确删冗余 | 低 | **ACCEPT** |
| M16 | B1→B2 commit 9a1a7f0: 删 nim_probe (含 15s timeout 探针) | git B1→B2 | init-nim-keys.sh | **L1 git** msg "探针 15s timeout 慢推理误报, 不联动 combo 决策"; 探针默认关对齐背景"禁默认高频探针" | **正确**, 对齐红线 | 低 | **ACCEPT** (注意: 静态 catalog 探针另见 M22) |
| M17 | B1→B2 commit 9a1a7f0: 删 check_dangerous_env (exec 前 unset 已覆盖该函数永远报 clean) | git B1→B2 | init-nim-keys.sh | **L1 git** msg "exec 前 unset 已覆盖清理, 该函数 unset 之后执行永远报 clean" | 正确删死代码 | 低 | **ACCEPT** |
| M18 | `nvidia/*/*` 三段式前缀判断须覆盖 `meta/*` / `nvidia/*`(裸) / `nvidia/nvidia/*`(双前缀) 三输入 | 背景#4 / 候选 | init-nim-keys.sh:99 models_to_json; OmniRoute 路由层 | **L1** init-nim-keys.sh L99 `sed 's/^/nvidia\//'` 统一加前缀 (静态层); **NEEDS-SOURCE** 路由层 (B3 `resolveProviderId` auth.ts:58/960; `nvidia/nvidia_nim` 别名 auth.ts:1095 "Fix #922") | init 加前缀 OK; 路由层三输入判定**未逐符号验** | 中 (双前缀 nvidia/nvidia/* 可能路由错) | **NEEDS-SOURCE-G5** (Stage C 读 B3 resolveProviderId + nvidia_nim 别名判定逻辑 + 写不联网单测) |
| M19 | OmniRoute 代理生态强制关闭 (ONEPROXY/SOCKS5/RELAY_BACKEND/BIFROST unset/false) | 背景#1 | init-nim-keys.sh:30-35 | **L1** (B1+B2 一致) | 正确, 守背景#1 | 低 | **ACCEPT** |
| M20 | proxy registry 清理 (host=127.0.0.1:20129) 用本地 loopback 名, 非外部 Relay | 维度2 | init-nim-keys.sh:171-203 | **L1** (B1+B2) | 正确分类 | 低 | **ACCEPT** |
| M21 | `_VALID_STRATS` 含 `context-relay`/`fusion` 枚举但 NIM 池默认 p2c, codex 默认 round-robin (不选 context-relay/fusion 作 NIM) | 背景红线 | init-nim-keys.sh:102,143,148,150 | **L1** (B1+B2) | 默认未选, 守"禁 context-relay 作 NIM" | 低 (枚举存在歧义) | **ACCEPT-WITH-GUARD** (候选可从 _VALID_STRATS 删 context-relay/fusion 消歧) |
| M22 | 静态 catalog 探针 `check_nim_model_health` (init 调真实 NVIDIA /v1/models, 一次) | 维度11 | init-nim-keys.sh (212-230 当前未读细; B2 9a1a7f0 删 nim_probe 但 catalog 探针是否另立) | **NEEDS-SOURCE** B2 删的是运行探针 nim_probe; catalog 健康 `check_nim_model_health` 用 _first_key 调真实 API, 每次 init 一次 | 量受限但仍耗配额; 需确认默认是否全跑还是门控 | 中 | **NEEDS-SOURCE-G6** (Stage B 内补读 init-nim-keys.sh check_nim_model_health 段; Stage C 动态测) |
| M23 | Gate / SSE 不被缓冲截断 (createProxyMiddleware streaming) | 维度7 | gate.js:37 | **NEEDS-SOURCE** 现 `createProxyMiddleware({target, changeOrigin:true})` 未显式 `streaming/selfHandleResponse`; http-proxy-middleware 默认透传流但需验 | SSE 长连接链路关键 | 中 | **NEEDS-SOURCE-G7** (Stage C SSE 模拟) |
| M24 | Docker pin 须 `omniroute:3.8.43@sha256:517c160643c56ad72e3e305458d961c9a4c87f711393c13020450f9f088d1570`, TURBOPACK=0, MAX_PENDING_MIGRATIONS=0 | 红线latest禁 | Dockerfile (B1+B2 一致) | **L1** (B1+B2 一致) FROM pin digest, ENV OMNIROUTE_USE_TURBOPACK=0, ENV OMNIROUTE_MAX_PENDING_MIGRATIONS=0 | 正确, 守红线 | 低 | **ACCEPT** |
| M25 | 候选用 latest 镜像 | 候选 (若有) | Dockerfile | — | — | 违红线 | **REJECT** (约束 (e)) |
| M26 | 按 Key 数线性扩容 RPM 或并发 | B1/B2 现行算式 (M07) | init-nim-keys.sh:129-140 | **L1** 现 `_RPM=_ALIVE_KEYS*35` `_CONCURRENT=_ALIVE_KEYS*3` | 违用户修正#3 | 高 | **REJECT** (约束 (b), 与 M07 ACCEPT-WITH-GUARD 联动: 候选须改固定) |
| M27 | 引入外部 Relay (Vercel/Deno/Cloudflare 作为流量转发 Relay) | 候选 (若有) | — | — | — | 违红线 | **REJECT** (约束 (a)) |
| M28 | 自动写入 Secret 到 HF 日志或 Dataset 快照明文 | B1 现行 DEBUG Dataset 默认开 (M08) | init-nim-keys.sh (DEBUG 日志) | **L1** | 违红线1 | 高 | **REJECT** (约束 (f); 配套候选须默认关+脱敏, 见 M08) |
| M29 | context-relay 作为 NIM Combo 策略 | 候选 (若有) | init-nim-keys.sh | **L1** 现 NIM 默认 p2c 非此; 若候选误选 | 违红线 | 中 | **REJECT** (约束 (d)) |
| M30 | 未经验证直接写 SQLite 内部表 (无读回) | M11 关联 | init-nim-keys.sh (B1 自动回写) | **L2** B3 表真实但脚本直写无读回 | 违约束 (c) | 中 | **REJECT** (约束 (c), 即 M11) |
| M31 | cf-worker 保留为双层网关外层 (白名单+PSKINTERNAL+告警, 非流量 Relay) | cf-worker 现状 | cf-worker/index.js + deploy-cf-worker.yml | **L1** (cf-worker 在仓, workflow 部署) 现状: 白名单 `/`、`/healthz`、`/__health`、`/v1*`、CLIENT_TOKEN 裸比、INTERNAL_PSK 转发、429/5xx 分桶、Resend/企微告警 | 角色语义: 是 Gate 还是外部 Relay? 两可; 暴露 `/__health` 超 /healthz+/v1; CLIENT_TOKEN 裸比违 timing-safe (M04) | 依赖外部 CF; 若作合规 Gate 须修 timing-safe + 去额外路径; 若按红线禁外部 CF 则删 | **不预决** (等用户) |
| M32 | 反向主张: cf-worker 删除, 仅保留 gate.js 单层 | cf-worker 去 | — | — | — | 消外部依赖; 失 CF 边缘 DDoS / 告警外移 | **不预决** (等用户) |
| M33 | init 错误码边界: 仅 413 / 带语义的 400/422 才算 Context 边界; 401/403/429/5xx/超时不计 | 背景红线 + 候选 | init-nim-keys.sh:240-307 | **L1** (B1+B2 一致, B2 context_recommendations 累积判读) 失败口径只纳 status>=500/413/(2xx且out=0), 排除 401/403/429 ("鉴权/限频信号污染") | 正确守红线 | 低 | **ACCEPT** |
| M34 | Combo 幂等 upsert (存在则 PUT, 不存在才 POST; 不先删旧) | 维度10 | init-nim-keys.sh:105-125 | **L1** (B1+B2 一致) upsert_combo 查 CID, 存在 PUT 否则 POST | 正确幂等 | 低 | **ACCEPT** |
| M35 | 增量门不漏 (任一 nim-* combo 或 INIT_MARKER 才进 init; 四 combo 评估对应策略) | 维度10 | init-nim-keys.sh (增量门段) | **NEEDS-SOURCE** 四 Combo (stable/codex/fast/pool) 对应 priority/round-robin/round-robin/p2c; 全逻辑需逐行核 | 增量门漏判致重复 init | 中 | **NEEDS-SOURCE-G8** (Stage C 逐读 init 增量门+四 combo 策略映射段) |
| M36 | Combo models_to_json 粘名已修 (\n bug) | B1→B2 历史 | init-nim-keys.sh:99 | **L1 git** commit 8e5bafa "models_to_json 粘名 bug 修复 (%s -> %s\n)" | 已修 | 低 | **ACCEPT** (B1+B2 已含) |
| M37 | CompressionConfig PATCH /api/settings endpoint 真存在 | init-nim-keys.sh 调 | OmniRoute 服务端 | **NEEDS-SOURCE** init-nim-keys.sh 调 `Compression HTTP` (含 enabled/defaultMode/autoTriggerTokens); B3 是否有 `/api/settings/compression` 或 compression PATCH | 端点名未验 | 中 | **NEEDS-SOURCE-G9** (Stage C 读 B3 compression settings route) |
| M38 | export-json `jq` 字段名漂移已修 (init POST expiresAt 无害冗余) | 记忆+ git f9c743c | docs/archive/VALIDATION.md | **L1 git** 记忆称 main f9c743c 修 (但本仓 HEAD nomn 42ea8e7; 需核该 commit 在不在 omn-merge 历史) | 记忆属 L4 须以 本仓 git 重验 | 误信记忆致结论漂 | **NEEDS-SOURCE-G10** (Stage C `git log --oneline | grep expiresAt` 在 omn-merge + B3 验) |

---

## 2. Resilience 分层裁定 (用户约束 #2)

- **第一层 (字段真实存在, /api/resilience PATCH Schema)**: M01/M01a/M01b → **ACCEPT (L2)**。B3 逐符号 camel 核对通过 (见 audit/00 §6.1 台账)。
- **第二层 (NIM direct-cloud 分支 + 429 默认计入)**: M01c → **NEEDS-INSTANCE-TEST-G1**。**禁止在矩阵写 ACCEPT/ACCEPT-WITH-GUARD**。理由: B3 `providerHints.ts` direct-cloud 兜底 true (L56) 但 NIM 显式白名单未见; 需 read-back `/api/resilience` 脱敏当前值或追 NIM provider 分类源码。

---

## 3. Context Override 分层裁定 (用户约束 #3)

- `/api/provider-models` POST/PUT 精确 request body schema: **L2 确认** 在 B3 `src/shared/validation/schemas/provider.ts:129` `providerModelMutationSchema`。
- 字段: `provider`(req,min1,max120) `modelId`(req,min1,max240) `modelName?`(max240) `source?`(max80) `apiFormat`(enum, default "chat-completions") `supportedEndpoints`(enum[], default ["chat"]) `targetFormat?`(enum openai/openai-responses/claude/gemini/antitravity) `max_input_tokens?`(int positive) `max_output_tokens?`(int positive) `normalizeToolCallId?`(boolean) [续读 L170+ 可能更多]。
- **`contextLength` 字段在 mutation schema 中不存在** (经 grep + 精读 L129-169+ 确认)。真实可写 token 字段 = `max_input_tokens`/`max_output_tokens` (wire shape, 持久化 inputTokenLimit/outputTokenLimit)。
- 基于不存在的 `contextLength` 的候选主张 (M09) → **REJECT**。
- 基于真实字段 `max_input_tokens`/`max_output_tokens` 的候选主张 (M10) → **ACCEPT** (仅 schema; 是否真写入须配读回, M11/M30 直写内部表 REJECT)。
- 内部表 `model_context_overrides` (含 `real_context`) 在 B3 `migrations/110_...sql:8` 真实存在, 但脚本直写它且无读回 (M11/M30) → **REJECT (约束 c)**; 等候选改走 API PATCH + 读回再议。

---

## 4. 三基准差异: B1→B2 两 commit (单列, 用户约束 #8)

| commit | 哈希 | 改动主张 | 矩阵# | 决策 |
|--------|------|---------|--------|------|
| 4632e8c | 禁自动回写 + 移 nim_health_pick | (1) 注释禁 context-monitor 自动回写 INSERT SQL; (2) 删 nim_health_pick() 函数 | M12, M13 | ACCEPT (B2 现行, 候选须保留并对齐 B1 部署) |
| 9a1a7f0 | 第二轮精简 4 块 | 删 Memory legacy+extended / Thinking budget / nim_probe / check_dangerous_env; 纯删不增 | M14-M17 | ACCEPT (B2 现行) |

注: 此 2 commit **未推 nomn/main → 未部署**, 故 B1 部署仍含自动回写 enabled (M11 直写内部表)。候选 v4.3 须以 B2 禁用方向为准并确保部署同步。

---

## 5. cf-worker (C8) 现状与候选 (用户约束 #6, 不预决)

- 现状 (M31): 双层网关外层, Cloudflare Worker v1.3.0, 白名单 `/`+`/healthz`+`/__health`+`/v1*`, CLIENT_TOKEN/INTERNAL_PSK, 429/5xx 分桶统计, Resend+企微告警, `.github/workflows/deploy-cf-worker.yml` 在 cf-worker 改动时部署 (push to main)。
- 候选 A (保留, M31): 修 timing-safe (M04) + 去 `/__health` 额外路径 + fail-closed 已具备; 利: CF 边缘防护+告警外移。[风险: 外部依赖 + 角色语义与红线禁外部 Relay 冲突]
- 候选 B (删除, M32): 仅保留 gate.js 单层; 利: 消外部依赖与红线歧义; 风险: 失 CF 边缘 DDoS 防护与告警外移。
- **决策**: 不预决, 等用户在 B 阶段后定 (audit/03 标为最关键冲突置顶)。

---

## 6. NEEDS-* 与 REJECT 汇总

### 6.1 NEEDS-INSTANCE-TEST (需生产实例只读验证, 须用户授权最小只读计划)
- G1 (M01c): NIM direct-cloud 分支 → 429 默认计入真否; 脱敏 read-back `/api/resilience` (M01c)
- G4 (M08a): DEBUG 日志内容是否真含凭据

### 6.2 NEEDS-SOURCE (Stage C 读 B3 源码补)
- G3 (M07a): OmniRoute `requestQueue` 限流执行点 (避免与 Gate 重复限流)
- G5 (M18): `resolveProviderId` + `nvidia_nim` 别名路由前缀三输入判定 + 不联网单测
- G6 (M22): `check_nim_model_health` 静态 catalog 探针默认门控
- G7 (M23): Gate SSE 流不截断验证 (Stage C SSE 模拟)
- G8 (M35): 增量门 + 四 combo 策略映射逐行核
- G9 (M37): CompressionConfig PATCH endpoint 真实存在性 (B3 compression settings route)
- G10 (M38): export-json expiresAt 漂移修复在 omn-merge 本仓 git 重验 (非记忆)

### 6.3 REJECT (不进矩阵讨论, 但本表收列)
- M09 (contextLength 字段被 schema 拒, Context Override 方案错)
- M11/M30 (未经验证直写 SQLite 内部表无读回)
- M25 (latest 镜像)
- M26 (按 Key 线性扩容 RPM/并发)
- M27 (外部 Relay 流量转发)
- M28 (自动写 Secret 到日志/快照)
- M29 (context-relay 作 NIM Combo)

### 6.4 ACCEPT (硬红线自明, 不进冲突表)
- 红线1 Secret 不进 snapshot/日志
- 红线2 Gate 暴露面 ≤ /healthz + /v1[/.]
- 红线3 本地 SQLite 非空时 LiteStream 不覆盖恢复

---

## 7. 红线自明 ACCEPT 主张 (用户约束 #7, 不进冲突)

- **红线1 (Secret 不进 HF snapshot/日志)**: ACCEPT。基线静态 0 明文; 动态 DEBUG Dataset 风险在 M08 处理。
- **红线2 (Gate 暴露面 ≤ /healthz + /v1[/.])**: ACCEPT。具体执行: M03 (白名单 404) + M04 (timing-safe PSK) + M31 (/__health 裁处)。
- **红线3 (本地 SQLite 非空 LiteStream 不覆盖)**: ACCEPT。具体执行: M05 (pre-restore 非空 guard + post-restore quick_check)。

---

## 8. L1+L2 升级项 (用户约束 #5)

须 B1/B2 与 B3 均支持才标 L1+L2:
- **Gate 白名单现有实现 (M03 部分)**: B1+B2 (gate.js:24-37) + OmniRoute `/api/monitoring/health` (gate 探测目标, OmniRoute 内部) → 门探测 L1; 白名单不足部分 (非 /v1 透传) 仅 L1。**升级未达 L1+L2 (因违部分)** → 维持 L1 + ACCEPT-WITH-GUARD。
- **LiteStream 本地非空库跳过 restore (M05)**: B1+B2 entrypoint (L1) + LiteStream 是外部 binary (无 B3 源) → **无 B3 支持**, 维持 L1 + ACCEPT-WITH-GUARD。
- **nvidia/?/* 判断 (M18)**: B1+B2 init L99 (L1) + B3 resolveProviderId (待 G5 核) → 未达 L1+L2, **NEEDS-SOURCE-G5**。

→ 此约束下三项均**未达 L1+L2 联合等级** (因 OmniRoute 侧源未全验或违部分), 现均 L1 或 NEEDS-SOURCE。Stage C 须补 B3 证据方可升 L1+L2。

---

## 9. Stage B 守纪声明

未改任何生产文件 (gate.js/entrypoint.sh/init-nim-keys.sh/Dockerfile/litestream.yml/package.json mtime 未动); 未生成候选脚本; 未调真实 NVIDIA API; 未 push; 未触发任何工作流; 未创建主张矩阵以外文档。仅写本文件 + audit/03-conflicts.md。

