# ops/docs/DECISIONS.md · omn 决策只增不改

> SSOT 决策层 (§3): 只增不改的裁决账本。翻案须 Zen 明确指令 (§0)。冲突以 docs/HANDOFF.md 为准, 其次本文件。
> 冲突次序: docs/HANDOFF.md > docs/DECISIONS.md (CLAUDE.md §3)。
>
> ⚠ 本文件 2026-07-31 新建。**旧决策全集尚未回填** (散落 audit/ / ops/incidents/ / ops/STATUS.md 段内, 未迁入)。新建前决策仍以原载体为真源;
> 本文件先承载 2026-07-31 起新决策, 旧决策回填留Zen令 (避免半建误导 / 翻案误触)。

---

## 2026-09-01 · k3 上游 bug 查证三档闭环 (3.8.50 已含全部修复) + claudecode 自动停 = k3 不适配 agent loop (非上游 bug)

**查证 (Zen问 omniroute 官方 kimi-k3 调用有无 bug)**: GitHub Search API + 本地 3.8.50 树 (浅克隆仅 1 commit, 不能 git log -S, 用 CHANGELOG 分段 + 代码双证; 版本段边界 3.8.50=L92-1625 / 3.8.49=L1626)。三档:
- ✅ **已修复且 3.8.50 已含**: #9496 K3 reasoning 保留 (`kimi.ts:151 backfillKimiReasoningContent` + `schemaCoercion.ts:463`); #9053 K3 拒 `xhigh` 400 → 透传 literal max (`reasoningEffort.ts:169 isMoonshotK3=/^kimi-k3$/` + L399, 单测 `moonshot-k3.test.ts`); #9005 tool message 回填; #9000 reasoning.encrypted_content 保留+日志脱敏; #9338 只涉 kimi-web 与我们 NIM 无涉
- ⚠️ **上游未结但 NIM 路径不触发**: #9771 (reasoning replay 跨 provider) / #11875 (deferred 3.8.52 max effort 钳制) 只作用于 MoonshotExecutor (provider=`moonshot|kimi`, `executors/index.ts:200-201`); 我们走 nvidia|openai-compatible → DefaultExecutor → `base.ts:886 sanitizeReasoningEffortForProvider`
- 🟢 **结构确认**: `nvidia/moonshotai/kimi-k3` 经 `getGlobalModel` (`providerModels.ts:114/120` 剥前缀+子串) 解析到全局 `kimi-k3` → `isMoonshotK3` 命中 → 与裸 kimi-k3 同 effort-sanitize 路径, xhigh→max 修复生效

**决策**: 生产再遇 K3 400 `invalid reasoning value: 'xhigh'` → 三档上游 bug 已排除, 判我们自身层 (gate 透传出处 / NIM 端 modelSeg), 直接查 sanitizer `reasoningEffort.ts:169/399`。3.8.50 树浅克隆无 git 历史, 验修复别 grep PR 号, 用 CHANGELOG.md 分段定位。

**claudecode 用 k3 总自动停 (Thought for 2m 9s) 定谳**: **200 OK ≠ 正常轮次**。后台两条 200 (17-20s, input 58K, output 46/334 token, `reasoning: 不适用`) = **成功但退化** — k3 只吐 46-token `finish_stop` 短答, **无 tool_use** → agent 循环断链 → 自动停; `reasoning: 不适用` = 思考被剥/请求未带 thinking/effort。**不自动切模型** (claudecode 失败只重试同一模型, 每轮卡死至人工干预)。**决策: k3 定位单轮深思考问答, 不用作 agent loop 主力** (长期 agent 工作换 `deepseek-v4-flash`/`glm-5.2`)。待查两事: ① `STREAM_READINESS_TIMEOUT_MS` 180s 是否被 dev/prod Space env 的 r3 80s 覆盖 (致长思考首 token 竞态超时); ② gateway 是否把 Claude thinking/effort 透传给 K3 原生 reasoning (`X-Kimi-Effort`/max_effort_tokens)。

**快照**: `audit/2026-09-01-k3-verify-autostop.md` (两条 memory 合并快照入血统)。

**关联**: 记忆 `kimi-k3-upstream-bug-verification-2026-09-01` + `k3-autostop-agent-loop-unfit-2026-09-01`。

---

## 2026-08-31 · 双轨更正: openrouter/mistral = 内置轨 (更正上条误分类) + 全 provider 纳入内置迁移 + pool 必要性判据

**更正 (上条"nvidia 双轨收敛"分类误判)**: 上条把 **openrouter/mistral 归于自定义轨** (建 provider-node, 连接挂 UUID), 经源码坐实 **错误** — 二者皆上游 **内置 API-key provider**:
- `gateways.ts:89-101`: openrouter = `{id:"openrouter", passthroughModels:true, hasFree:true}` ✅ 内置
- `frontier-labs.ts:117-128`: mistral = `{id:"mistral", hasFree:true}` ✅ 内置
- 各有 `open-sse/config/providers/registry/{openrouter,mistral}/index.ts` 完整 baseUrl (buildUrl L330 直用 `this.config.baseUrl`) + `hasFree` + combo 建议逻辑。

**修正后两轨 (第一性: 每 provider 只走一条)**:
- **内置轨** (连接挂 `provider=<内置名>`, 短名通, 不建 node) = **nvidia + sensenova + openrouter + mistral**
- **自定义轨** (建 provider-node, 连接挂 `provider=<node_uuid>`) = **amd 仅** (registry 两版本均无 → 唯一非内置)

**决策: openrouter/mistral 并入 sensenova 那批内置迁移** (mode=builtin, 同一 `_register_multi_provider` 内置分支, 连接注册 `provider=openrouter` / `provider=mistral`)。PROVIDERS 表两行改 8/9 字段: openrouter = `mode=builtin` + **static_models 空** (保留动态枚举, passthroughModels:true, max=100 不变); mistral = `mode=builtin` + **方案A static_models 5 chat 模型** (避开 mistral-embed/codestral-embed 污染 chat 列表)。清理函数 `_cleanup_legacy_node(nvidia/openrouter/mistral)` + `_cleanup_sensenova_double_prefix` 幂等清旧 node 残留。env `ALL_FT_FAMILIES` 前缀族不变, FT 绑 `provider` 字段不受影响。mock 验证 (tools/mock-omr-register.sh) 全绿: nvidia skip / openrouter 动态枚举短名 / mistral 白名单不枚举 / amd node 分支 / dp4f 三 provider 排除 openrouter / 4 家旧 node cleanup。

**pool 必要性判据 (Zen问"为什么每个提供商都要一个 pool"时的定谳)**:
- pool (= combo) = **上游唯一的多 key 聚合/容错机制**, 请求 `model=<pool名>` 走 `chatHelpers.ts:193 getComboForModel` → combo.ts `strategy` (p2c/round-robin/weighted) + `checkFallbackError` 失败换 key/provider; 裸 `provider/model` 只挑一条连接, 无轮询无 fallback。
- **多 key provider 必须有 pool 才有跨 key 负载均衡 + 429/403 fallback** — 这是 NIM 25 key 不崩不风控的地基, 也是上游默认设计 (每个 apikey provider 自带 hasFree/comboSuggestions)。
- `${provider}-pool` (单 provider 内部聚合) 与 `dp4f-pool` (跨 provider 同模型聚合) 是第三维 (聚合维), 与内置/自定义轨正交 — 每 provider 不管走哪轨都要有自己那层 pool。
- **过度设计的反方向才是值得警惕的**: 现在 mistral/sensenova/amd 各 1 key, pool 是单元素 (无聚合价值但无害)。**保持统一 (每 provider 都建 pool) 比按 key 数特判跳过更简单** — 不做特判, 随 key 增多自动变有用, 与 nvidia 25-key 结构对齐。

**关联**: [[sensenova-builtin-ft-whitelist-cleanup-landed]], [[dpv4flash-cross-provider-pool-landed]], [[dp4f-pool-rename-orphan-cleanup]], [[nim-multikey-miztertea-vs-omniroute-comparison]], [[omniroute-gateway-goal-and-risks]]。

---

## 2026-08-31 · nvidia 双轨收敛 = 单轨内置 (通用循环跳过 nvidia, 禁改 builtin 防撞名)

**决策**: nvidia 从双轨收敛为**单轨内置**。**通用 `_register_multi_provider` 循环跳过 nvidia** (连接/模型/combo/FT 全由 legacy NIM_KEYS 内置轨独占: `nim-01..32`@provider=nvidia + nim-pool/nim-codex/dp4f 全锚其上)。**禁把 nvidia 行 mode 改 builtin**——那会让通用循环以 `provider=nvidia` 再注册一套 `nvidia-01..32`, 与 legacy `nim-01..32` 同 provider 撞成 64 条, 是更脏的双轨。分两路第一性: **内置轨** (连接挂 provider=<内置名>, 短名通) = nvidia + sensenova; **自定义轨** (建 provider-node, 连接挂 provider=<node_uuid>) = openrouter/mistral/amd。

**关键证据 (FT 绑定锚 provider 字段非前缀, 2026-08-31 源码坐实)**: `resolveProxyForConnection` (upstream 3.8.50 `src/lib/db/settings.ts:656-665` Step6) 请求时 `resolveProxyForScopeFromRegistry("provider", connectionProvider)` — 匹配键 = **连接 `provider` 字段**。FT bulk-assign (init L478 `ALL_FT_FAMILIES` 前缀族名 → `proxies.ts:819` → `assignProxyToScope` L496) 只把 scopeId 原样写 `proxy_assignments.scope_id`, 不按前缀展开连接。故: legacy `nim-01..32`@provider=nvidia 匹配 FT `scope_id=nvidia` ✅; node 套件 `nvidia-01..32`@provider=openai-compatible-chat-404a636c 匹配 `scope_id=UUID` 无此行 ❌ **从未拿到 FT**。node 套件=纯死配置 (无 combo 消费/无 FT/无短名路由/baseUrl 缺 /v1 引 CredentialHealth 404 噪音)。

**改动**: `dev/logic/init-nim-keys.sh` `_register_multi_provider` 循环首段加 `[ "$_pid" = "nvidia" ] && continue` (注释: legacy 内置轨独占, 通用表跳过; PROVIDERS 表 nvidia 行保留仅供 `ALL_FT_FAMILIES` 收前缀绑 FT)。顺带清残留 nvidia-node (复用 `_cleanup_legacy_sensenova_node` 同款幂等模式)。dp4f nvidia 条目不受影响 — 来自 `upsert_dp4f_pool` 的 `filter_alive(NIM_POOL_MODELS)` (独立于通用循环)。

**理由**: Zen令第一性原理——按上游默认最小改动, 统一所有提供商或分明两路 (内置/自定义), 不做过度设计; 双轨必然跑空/多 bug。nvidia 早是内置轨 (legacy 即 provider=nvidia), 通用循环再当自定义节点处理一套 = 双轨漏。关联 [[dpf-pool-rename-orphan-cleanup]], [[dpv4flash-cross-provider-pool-landed]], [[sensenova-builtin-ft-whitelist-cleanup-landed]]。

---

## 2026-08-31 · dp4f-pool 选择机制 = 两层 per-request 健康选择 (provider 顺序可配 / key 粒度不可配)

**决策**: dp4f-pool (combo: nvidia/deepseek-v4-flash + sensenova-node.id/... + amd-node.id/...) 的流量选择是**两层 per-request 选择**, 不是顺序轮询。①**combo 层挑 provider**: 候选按**每条 combo 条目**构建 (非按连接展开), 策略默认 `p2c` = 每请求随机抽 2 条 target 按健康评分取优作首选, 其余按原序跟随后 fallback。②**provider 内挑 key**: 选定 provider 后执行层按其活跃连接池 (connectionPoolSize) 走 **accountFallback 健康退避** (backoffLevel/lastError/rateLimitedUntil 打分 + lockDown 轮换), 非顺序轮询。③**fallback 链**: 单请求 for 循环逐 target 尝试, **该 provider 内所有 key 试完 → 下一 provider** — 即"整个 provider 的所有 key 轮完再下一个"仅存在于 fallback 语义, 不是主选顺序。

**可配维度 (provider 间顺序)**: combo `.strategy` 字段, init 白名单 16 策略 (`fill-first`=固定条目序 nvidia→sensenova→amd / `round-robin`=每请求换 provider / `p2c`=随机+健康 / `priority`/`random`/`least-used`/`cost-optimized` 等)。改法二选一: `NIM_POOL_STRATEGY` env (**须 reboot**, init 读它) 或直改 combo 记录 `PUT /api/combos/:id` 改 `.strategy` (**即时生效**, strategy 每请求从 combo 记录读)。

**不可配维度**: ①provider 内 key 轮换固定健康退避, 无"严格顺序轮 key"选项; ②**per-key 粒度**无法靠策略选 — combo 候选粒度 = 条目非连接, 想 per-key 轮询必须改池结构 (每 key 独立 provider-node 或 connectionId 钉死, 使 combo.models 条目数 = key 数)。`accountSelector.ts` 的 `selectAccountP2C` 是 dead code (除自身外无 import), 执行层 key 选择真源在 `accountFallback.ts`。

**理由**: 2026-08-31 读 diff 双版本对照 upstream 3.8.50 坐实——`combo.ts` candidates = `fingerprintExpandedTargets.map(...)` 按条目构建 + 每条带 `connectionPoolSize`; p2c 排序 `combo/targetSorters.ts:142 orderTargetsByPowerOfTwoChoices` + 评分 `getP2CTargetScore` (成功率+时延, breaker OPEN=-∞); 分发 `combo/applyStrategyOrdering.ts:131` `else if (strategy === "p2c")`; fallback 循环 `combo.ts:L1184/L1643` 逐 `orderedTargets[i]`; key 健康 `services/accountFallback.ts:2175 getAccountHealth` + `lockDown`。加入点: `dev/logic/init-nim-keys.sh:157 _VALID_STRATS` + `:349 _POOL_STRATEGY` 默认 p2c + `upsert_dp4f_pool` L1514。关联 [[dp4f-pool-rename-orphan-cleanup]], [[dpv4flash-cross-provider-pool-landed]], [[nim-multikey-miztertea-vs-omniroute-comparison]]。

---

## 2026-08-31 · manage key 真变量 = OMNIROUTE_API_KEY (OMN_MANAGE_TOKEN 是 ops 层误造名, 废弃)

**决策**: omniroute 管理面 `/api/*` (provider-nodes/providers/combos/models/health/keys/settings-export) 的 manage key **真变量 = `OMNIROUTE_API_KEY`** (xnexus/o Space Secret → init-nim-keys.sh L735-758 种 DB `apiKeys` 表, 写 `/data/.or-api-key`)。**废弃 `OMN_MANAGE_TOKEN` 这个命名**——它只在 ops 层/记忆/工具里出现, 上游源码无此 env; 在 xnexus/o Space 设 `OMN_MANAGE_TOKEN` 无效, 拿它打 `/api/*` 恒 `AUTH_001`。

**理由**: 2026-08-31 实测——本地 `~/.omn-secrets` 的 `OMN_MANAGE_TOKEN` 打 xnexus-o `/api/*` 恒 403 AUTH_001; 改用 `OMNIROUTE_API_KEY` 立即 200 通 (实测 `/api/provider-nodes?type=openai-compatible` 200, 据此定位 `404a636c`=nvidia-node)。`grep -rn "OMN_MANAGE_TOKEN" upstream/…/src/` 全树无此名, 坐实是自造。落地: `tools/omn-log-query.py` 已改 `MGR=getval('OMNIROUTE_API_KEY')` (commit a8a56af), `health/providers/models/combo` 子命令本地即通, 不需另取 Space 真值。关联 [[omn-log-query-tool-landed]], [[manage-token-omn-manage-location-2026-08-21]]。

---

## 2026-08-31 · 日志查询分级授权 (HF_TOKEN / PSK / manage 三层)

**决策**: 查模型 429/502 日志与 FT 代理实时计数**不需要 omniroute manage key**——HF_TOKEN 读 Dataset (`save/gate/` `save/app/` `save/ft/`) 即可；FT 用 INTERNAL_PSK 查 gate `/v1/ft/metrics` 反代；manage key (OMN_MANAGE_TOKEN) 仅用于 `/api/*` 运行时状态 (health/providers/models/combo)，且必须用 **xnexus/o Space Secrets 真值**（本地 dev 值 AUTH_001 无效, 实测 403）。

**理由**: manage key 泄露面收敛——日常日志查询走 HF_TOKEN (只面 Dataset) 不触真 manage key；HF Dataset 三层日志已覆盖 429/502、ProxyFetch、桥转发全貌。模型维度分布需注意：gate 请求行无模型字段，须用 app HTTP/ROUTING 行 + 时间窗 ±60s 关联 (低并发可靠, 高并发同秒可能错配)；FT metrics failures 是累计计数口径, 单看不下结论 (须对照 save/app ProxyFetch 行复核真实业务转发)。落地工具: `tools/omn-log-query.py` (commit f9900eb, 八子命令统一入口, key 进程内读零落盘)。

---

## 2026-08-31 · HF Dataset tree API 分页规范 = Link rel=next cursor (禁 after)

**决策**: HF tree API (`GET /api/datasets/{repo}/tree/{rev}/{sub}?recursive=true&limit=1000`) 分页**一律解析响应头 `Link: <url&cursor=<base64>>; rel="next"`** 拉 next URL, 循环到无 next 即全量; **禁用 `after` 请求参数**。

**理由**: 实测坐实——`after` 参数变体 (编码全路径/仅文件名/原名) 均被 API 静默忽略, 恒返回首页前 1000 项 (status 200 无报错)；真游标在 `Link` 头。此坑导致 `save/app` 目录 1617 文件截断在 09:51 (分页失效只拿首 1000, 假象"数据停更")。修复后全量拉取, 时间窗与 `save/gate` 同秒重叠。落地: `tools/omn-log-query.py` `ds_tree()` L35 起已按此实现; 同类递归列表 (models/datasets 枚举) 疑同构, 留下次验证。

---

## 2026-08-12 · FT Worker GitHub Actions 自控部署 (仿 n-edget 手搓→自动) + worker.js 鉴权 fail-closed 红线

**背景**: Zen令 "参考 github.com/i3t2y/n-vless、i3t2y/n-edget, 用 GitHub 控制 CF 账号建设 Worker"。落 `ops/docs/DECISIONS.md` 2026-08-10 段 + `docs/flaretunnel.md:39` 自述的运维负债: 现役 = "手工建 Worker → CF Dashboard 全选删除粘贴 worker.js → 部署 → 手填真实 URL 进 `flaretunnel_endpoints.json` 喂本地桥"; `flaretunnel/worker.js:5` `AUTH_KEY="PASTE_NEW_RELAY_AUTH_HERE"` 占位Zen手填, 换 AUTH_KEY 钥须逐 Worker 手改 → 密钥漏面大 + 运维负债重。

**治法 (本会话三件, 本地改完待 commit+push Zen)**: 手搓→GitHub Actions 自控一键全 Worker 一致部署。
- `flaretunnel/worker.js` (+12/-7): ①fetch 签名 `async fetch(request)` → `async fetch(request, env)` ②硬编占位 `AUTH_KEY="PASTE_NEW_RELAY_AUTH_HERE"` → `const AUTH_KEY = env.RELAY_AUTH || null` 读 wrangler secret 注入 ③鉴权段加 **fail-closed 双守** `if (!AUTH_KEY || request.headers.get("x-relay-auth") !== AUTH_KEY)` — `!AUTH_KEY` 短路守 `undefined`/`null`/空串全硬拒 401。
- `flaretunnel/wrangler.toml` (新建): Workers 非 Pages 最小骨架 `name="flaretunnel"` + `main="worker.js"` + `compatibility_date="2026-04-26"` + `workers_dev=true`。
- `.github/workflows/deploy-ft-workers.yml` (新建): 仿Zen `i3t2y/n-edget` `sync-deploy.yml` 机制转 Workers 路径。`cloudflare/wrangler-action@v4` + `secrets:` 输入内建走 `wrangler secret put` (非 n-edget Pages `curl PATCH CF API` 注 `env_vars.secret_text`)。`push` paths 触 (worker.js/wrangler.toml/workflow 自) + `workflow_dispatch` 手动。值来自同 step `env:` 引 GitHub repo Secret (`${{ secrets.RELAY_AUTH }}` 自动打码日志)。

**鉴权 fail-closed 红线 (新增 §2 安全红线宗)**:
worker.js 原占位逻辑 `if (request.headers.get("x-relay-auth") !== AUTH_KEY)` 存 **fail-open 裸奔洞** — `env.RELAY_AUTH` 缺时 AUTH_KEY=undefined:
- 请求带真值头 → `string !== undefined` = true → pass (鉴权失效)
- 请求无头 → `null !== undefined` = true → pass
- 两者都 pass = 鉴权洞 = **开放代理裸奔** (任意人扫到 Worker URL 即刷Zen NIM 配额, docs/flaretunnel.md:41 "Worker URL 裸奔开放代理" 警告实证)
治 = `env.RELAY_AUTH || null` (undefined 归 null) + `!AUTH_KEY` 短路守 (null/空串全先硬拒不查头)。**鉴权钥缺必在 fetch 入口硬拒, 不裸奔开放代理。鉴权比 `!==` 无 fail-closed 守是洞, 须 `|| null` + `!KEY` 双守。** 五态真 fetch 调测铁证 (CASE A env无→401 / B 头=钥→200 / C 头≠钥→401 / D 无头→401 / E 空串→401)。

**n-edget 我仓差异 (机制移植须转路径)**:
- n-edget 走 **Pages** (`pages deploy .` + PATCH `accounts/.../pages/projects/$PROJ` 注 `env_vars.secret_text` + `wrangler.toml` 用 `pages_build_output_dir` 不写 `main`)
- 我仓现役 `worker.js` 走 **Workers** (`export default { fetch }` + `wrangler deploy` + `wrangler.toml` `main` 必填 + `wrangler-action` `secrets:` 输入内建走 `wrangler secret put`)
- 目标件 = `flaretunnel/worker.js` (FT 出口换 IP Worker), 非 worktree `cf-worker/index.js` (gate 网关前置代理 `UPSTREAM_BASE`/`INTERNAL_PSK`/`CLIENT_TOKEN`+KV, 别混两套)

**不变量**:
- §1 拓扑: 三件定态 (space 根 Dockerfile/README/start.sh) 零触。worker.js + wrangler.toml + deploy workflow 均非三件。不新建 HF Space (CF Worker 非 Space 不触"不新建 Space"铁律)。不翻 `FT_WORKER_COUNT` 控池语义 (2026-08-10 段), 不改 endpoints.json 池结构。
- §2 secrets: `RELAY_AUTH` 真值零入 git/会话。走 GitHub repo Secret (Zen `openssl rand -hex 24`) → wrangler-action `secrets:` 输入 → `wrangler secret put` 加密存 CF。worker.js 读 `env.RELAY_AUTH` 运行时绑定不留值。换 GitHub Secret 时同改 HF Space Secret `RELAY_AUTH` 同值 (Worker 鉴权 ↔ 桥 RELAY_AUTH 铁律)。
- §0 翻案: 本段落 2026-08-10 段 "欲真扩池超 M 须Zen先 CF 建新 Worker" 遗留运维负债 (变 "Zen在 GitHub repo 设 Secret + 跑 Action 推 deploy"), 不翻案不改池语义。
- §5 护栏: git add/commit 一律 ask Zen。secret-scan exit=0 五态测全绿。

**待Zen裁决 6 项 (卡矩阵扩 N, 单 Worker 先落)**:
1. **矩阵规模**: 单 Worker 先落 vs 直接矩阵 16? 真 M=16 池须Zen拉 HF `flaretunnel_endpoints.json` 件裁 (本地零件 git 从未 tracked)
2. **2池×8 vs 4池×4 矛盾**: `DECISIONS` 2026-08-10 段 (flaare/flbare 1-8) vs `audit/2026-08-01-save-log-full-analysis.md:169-176` prometheus 钉死 (flaare/flbare/flcare/fldare 1-4) 冲突, 须Zen HF 件终极裁决现役真族结构
3. **单钥共享 vs 每省各钥**: 全 Worker 同 `RELAY_AUTH`? 还是每 CF 账号各钥? (单钥共享风险面最小, 仿 n-edget `CF_TOKENS` 位序 cut 取是否须复刻留Zen定)
4. **endpoints.json URL 回流机制**: Worker 建成后 URL 怎回填 `flaretunnel_endpoints.json` (真身在 Dataset nonoke/omn-logic) — n-edget 不涉此我独有项; 手填? Action dump? 待Zen定
5. **deploy 触发路径**: 仅 `worker.js` 改 push 触发? `workflow_dispatch` 已含, Zen验后定是否加定时
6. **wrangler-action 版本**: `@v4` (2026-05-12 主推) vs `@v3.15.0` (固定防移动 tag 劫持, 跟 n-edget `@v3` 一致)

**关联**: [[flaretunnel-impl-built-verified]] [[flaretunnel-metrics-endpoint-lu3-landed]] [[ft-worker-count-env-lu-landed-2026-08-10]] [[ft-worker-count-vs-keys-decoupled]]。

---

## 2026-08-10 · FT_WORKER_COUNT ENV 控桥轮换池规模 (RELAY_AUTH 与 worker 数正交钉死)

**背景**: Zen原题 "RELAY_AUTH 改 32 worker, 重建还是 16 worker"。直觉误把 `RELAY_AUTH` 当作 worker 池规模控制量。

**病根 (源码实证钉死)**: worker 数物理源 = `flaretunnel_endpoints.json` 写死的 16 条 Worker URL (flaare 1-8 + flbare 1-8 = M=16)。`RELAY_AUTH` = 桥鉴权密钥 (Worker 代码 `AUTH_KEY` 同步), 与 worker 数 **正交** — 改鉴权 token 不动池规模, 重建读同一 endpoints.json 故仍 16。两物无因果, 非故障是设计语义。

**治法 (commit 67b6b8c, dev/logic/entrypoint.sh `_ft_start` L222-248)**: 加 ENV `FT_WORKER_COUNT` 控桥 round-robin 轮换池规模 N。
- 规则: `实际轮换数 = min(FT_WORKER_COUNT, endpoints.json 物理条数 M)`
- ENV ≥ M → 全用 M (印提醒 ENV 过头, 不凭空造 Worker; 无新 URL 则物理上限不可越)
- ENV < M → 取前 N 条子集 (`--workers 0-(N-1)` 索引锁; Go 源 `LoadWorkers` L1297-1307 `parseWorkerIndices` 范围语法实证支持)
- 未设 / ≤0 → 原行为全用 M (回滚 = 删 Variable + Restart, 零代码改)
- 日志行改印 `${_ft_n}/${_ft_phys}` 双数 + ENV 子集时加标注

**不改 Go 源** (`--workers` flag 已支持索引子集, 无须重编译二进制)。**不改 endpoints.json 物理池** (URL 源Zen控)。欲真扩池超 M 须Zen先 CF 建新 Worker → 填真实 URL 进 endpoints.json → 推 Dataset → Restart (dev/logic path 零 Rebuild)。ENV 只控轮换池上限不造 URL。

**验证 (本地)**: `bash -n` 语法绿 + secret-scan exit 0 + 五边界自验全对 (ENV 0/4/8/16/32 × 池 16 → 轮换 16/4/8/16/16; flag 空/`0-3`/`0-7`/空/空+提醒)。

**部署链**: dev/logic path → Zen push nomn main (commit 67b6b8c) → sync-logic-nonoke CI 推 Dataset nonoke/omn-logic → Restart dev Space (零 Rebuild) → boot 真验看 `[entrypoint] FT:` 行印 `N/M Worker` 双数。push 本会话会 §5 护栏 deny → Zen以 `!` 前缀亲跑 (已验远端追平 HEAD)。

**教训红线**: ENV 变量语意命名须明示 "控什么"。`FT_WORKER_COUNT` 控的是"轮换池规模上限"非"物理 Worker 数" — 设 32 不会造 Worker, 只在 ENV > 物理池时印提醒用满池。诊断此类 "改 X 不见 Y 变" 病诉, 先查 X 与 Y 是否正交 (鉴权密钥 vs 池规模), 再查 Y 的真物理源 (endpoints.json URL 数非 ENV)。

**关联**: [[flaretunnel-impl-built-verified]] [[ft-worker-count-vs-keys-decoupled]] [[flaretunnel-metrics-endpoint-lu3-landed]]。

---

## 2026-07-31 · probe 子shell exit1 崩根 `|| true` 兜底红线 (同源病族第三轮复发)

**背景**: 2026-07-25 C2 pipefail 静默杀 init (`jq` + `grep -v '^$'` 空输入 rc1 + pipefail → set-e 杀), 治法 `set +eo pipefail 抬门 + ${_DEL_JSON:-[]} 兜底`。2026-07-31 probe subshell 退出码经裸 `wait` 杀 init 同源病族第三轮复发。

**裁决 (新增红线)**: `init-nim-keys.sh` 行 2 `set -eo pipefail` 全程生效, 任何子 shell `( ... ) &` + 主循环 `wait "$pid"` 收子 shell 退出码, **裸 wait 未兜 `|| true` 是隐藏地雷** — 子 shell 最后一条命令若 test 失败 (含 `[ "0" = "1" ]` 非详细模式分支) 返 exit 1 → `wait` 收 1 → `set -e` 杀主进程 init → container exit 1。
治法: 子 shell 内末尾命令 / 主循环 `wait` 收批处一律 `|| true` 兜恒 exit 0。子 shell 是探活 fail-open 兜底语义, 失败不应阻 init。

**主义宗**: `set -e` + 子 shell + `wait` 三元组退出码传播链须一律兜底, 非单点修。本轮 L675 末 `|| true` 兜底根除 (commit `ef16b46`), 但本红线宗推主循环 L692 `wait "$_p"` 一律 `|| true` 兜 — 收子 shell 失败不应拦主进程 fail-open 语义。本轮单点修先用, 全量推留后续观察验证。

**X4 ENV 闸绕治标宗**: `NIM_PROBE_ENABLED=0` 整跳 probe = ENV 绕治标 (未触子 shell 故未崩, 06:14 前Zen配此稳生产), 非真根根除。环境绕 + 代码修 (`|| true` 治本) 两者非互斥: ENV 闸省 probe 启动时间, 代码修保证 probe 路不崩。

## 2026-07-31 · §2 secrets 历史明文 key 泄露清理挂账 (仅记位置, 零值入档)

**背景**: 2026-07-31 02:50 boot verbose 模 (`NIM_PROBE_VERBOSE=1`) `curl -s -v ... 2>&1` 明文回显 7 个 nvapi key 进 `init_20260731_025003.log` → 推 HF Dataset `nonoke/omn-logic` 公开存储 = 极敏感泄露。

**代码治本已落**: commit `e935ec2` 加 verbose 段过 `sed -E 's/(Authorization:[[:space:]]*Bearer[[:space:]]+)[A-Za-z0-9._\-]+/\1<REDACTED>/gi'` (`gi` 标志捕大写小写双变体) 写 `.verbose` 件。02:50 VERBOSE 段铁证全 `<REDACTED>`, §2 明文根除。

**挂账 (Zen侧善后, 仅记位置零值入档)**:
1. HF Space `NIM_PROBE_VERBOSE` ENV 若仍开则关 (关后 verbose 段整不产, 治标)
2. Dataset `nonoke/omn-logic` 历史 `init_*.log` / `debug_*.log` 含明文 key 件 (02:50 verbose boot 期) Zen判删 / 重写剥明文版重推 (历史泄露清理)
3. Zen贴回本会话的 02:50 boot 文本含 7 明文 nvapi key (Zen持有的真凭) — Zen侧善后, 我侧只记位置不存值 (§2 红线)

**责任**: 与本轮代码改无关 (`e935ec2` 脱敏治本已落)。本挂账仅清历史已泄露存量。

## 2026-07-31 · omn-logic 用不着件移出 (路2 死代码 + 插件包可选件)

**背景**: Zen 2026-07-31 令 "omn-logic 中的脚本文件整理下, 用不着的移出"。范围Zen AskUserQuestion 答准三类: 仅扫 Dataset 根多余资产 (零多余) + omn_bucket_sync 插件包可选件 + omn_encrypt 路2 死代码。helper.sh runtime 退场段未选保留。

**裁决 (移除决策 = 只增不改的例外, 件存 git 历史可恢复)**:
1. **`omn_encrypt.py` (路2 加密) 移出**: 2026-07-29 Zen裁个人最小方案降级砍七成, 路2 Fernet tar.gz 整体字节级加密链降级 — `ENCRYPTION_KEY` 已删, `EncryptedScheduler` (scheduler 内子类) 从未实例化 = 死代码。私库只圣读 + litestream 已复制 storage.sqlite = 加密冗余。移出后 scheduler `_try_import` 删 omn_encrypt block (except 兜底 fail-open 已就绪), `EncryptedScheduler` 死类 + `ENC_SRC`/`ENC_STAGING` 死路径整删, 留移出挂记注释。
2. **`omn_bucket_sync.py` (插件静态包推公开 S3 Bucket) 移出**: Zen裁插件包可选件状态, 非现役链 (`OMN_BUCKET_SYNC` 默0不触)。`init-nim-keys.sh` 调用段同删, 留移出挂记注释 + 恢复路径 (git 历史检出 + Dataset 根回推)。

**恢复路径 (件存 git 历史)**: `git show <旧 commit>:dev/logic/omn_*.py` 检出 + scheduler/init 引用段一并还原。本决策不删 git 历史, 仅工作树移出 + Dataset 根件同步删 (经 sync-logic-nonoke CI 推 Dataset + HfApi 删根件)。

**不变量**: 主链 fail-open 保证 — scheduler 主链路1 (CommitScheduler STDOUT staging → save) 不依赖两移出件; init OMN_BUCKET_SYNC 段删后阈若Zen仍设 =1 也无件可触 (`[ -x /logic/omn_bucket_sync.py ]` false 短路)。零回归。

---

## 2026-08-01 · 逻辑层 Dataset→Bucket 迁意 (Zen意图记, 未实施)

**状态**: Zen意图仅打记号, **未实施未批准实改**。§0 翻案须明令 + §1 拓扑改须批。

**Zen原话**: "先做个记号, 我打算将 dataset 改成 bucket, 不合适再切回来"。AskUserQuestion 答准 = **逻辑层八件** (非 R2 / 非 /data 杂件)。

**与 2026-07-28 §12 单择定局关系**: §12 裁三轴分层 (R2备份不动 / Dataset逻辑层留 / Bucket挂`/data` RW运行态件层)。本记号针对**逻辑层八件** —— 即 §12 裁决第2条 "Dataset 改 Bucket 单路 ❌ 无必要性... Bucket反增未知风险面" 同作用面。本记号Zen未推翻 §12, 但留**意图方向**: 欲把逻辑层八件 Dataset→Bucket 替换试, 不合适切回 Dataset。

**迁意作用面 (现役逻辑层八件, 2026-07-31 清单10→8 收缩后)**:
`entrypoint.sh gate.js init-nim-keys.sh litestream.yml package.json helper.sh omn_redact.py omn_scheduler.py` — 平铺 `nonoke/omn-logic` Dataset 根, 经 `.github/workflows/sync-logic-nonoke.yml` CI 推 + readback 校 + delete_file 洗移出件残留 (5a292fc)。

**迁意代价面 (2026-08-01 Zen点破后认知更正)**:
- **四件武器 (版控+PR+血缘+K3 `--revision` commit_id锁+`git show` 历史检出) 全绑私库 `n-omn` git 仓, 不绑 Dataset** — CI `sync-logic-nonoke` 用 `HfApi.upload_file/delete_file` 把私库 `dev/logic` 八件平铺推 Dataset `nonoke/omn-logic` 根, boot 拉 Dataset 装 `/logic`。Dataset 在此链 = **运输管道+挂载源**, 不存版控历史。故"废 Dataset 四件武器" = 误判, 四件武器遗在私库不随 Dataset 去。
- **Bucket 替换真比较面 = 运输管道+挂载模式单维**: Dataset `upload_file`/`delete_file`/RO mount vs Bucket S3 PUT/DELETE/**RW mount `​/​logic`**。
- **Bucket 真优势点 (Zen真痛点对齐)**: init/gate 改动现须 boot 拉 Dataset RO + **Restart** 生效 (非秒级); Bucket 若 **RW mount** `/logic` ⇒ CI 推 Bucket → mount 内容即更新 → 期秒级热更免 Restart。**待证**: HF Bucket RW mount 真热更还是仍须 Restart (mount snapshot 固化? NFS 缓存?), 须实测钉。
- Bucket 非版本化 (删即永久丢) + 无 PR + Bucket→Repo 回写未支持 (HF roadmap) — 但件本低版本化需求 (私库已存历史可 `git show` 检出恢复), 此代价被私库四件武器兜底缓解。
- "不合适再切回" 可行性: 切回 = `sync-logic-nonoke` CI 改回 `upload_file` Dataset 路 + Space mount 改回 Dataset RO, 私库不动 (四件武器不受迁意影响) —— 切回链完整且不伤血统 (血统锚点在私库非 Dataset)。

**待决 (真迁须Zen另会话显令)**:
1. 真痛点复核: init/gate 改动须 boot 拉 Dataset + Restart 生效 (非秒级) = Bucket 双路可解此真痛。§12 §11 已备热件双路方案 (Bucket 挂 `/logic-bucket` RW + Dataset `/logic` RO 兜底, `_pick()` 谓词查 Bucket 优先回退 Dataset) — 非纯替换乃双路叠加, 更保 §1血统。
2. 纯替换 (废 Dataset 单走 Bucket) vs 双路叠加 (Dataset 留兜底 + Bucket 热更新) 选型待Zen裁。
3. Class A PUT 硬数 (低频写触限须监控) + hf-mount NFS 首读延迟 (init 探活路径须测) 两坑待证。

**关联**: [[storage-bucket-dataset-结合堪察]] §12 单择 + §11 热件双路 + audit/2026-07-28-storage-bucket-勘察.md。

---

## 2026-08-01 · save 七源分类生效闭环 + 归档机制落地 + R2 endpoint 脱敏扩

**状态**: 全闭环 (本地改完待 push nomn 触 CI 同步 Dataset).

### A. save capture 七源分类生效闭环 (Zen 2026-07-30/08-01 终极旨链)
继 2026-07-29 路一单件 + 2026-08-01 全析 2289 件 + 删, 发现 capture 漏两源 (entrypoint 本体编排日志旧只入 PID1 stdout 30min 焚; litestream stderr 旧与 entrypoint 混 PID1 stdout)。
- `entrypoint.sh`: DATA_DIR export 后加 `exec > >(tee -a "$_EP_LOG_RAW") 2>&1` 全进程重定向落 `omn-raw/entrypoint.log` (`:> ` boot 前截断归零免跨 boot 累计); litestream 段加 `_LS_LOG_RAW` 隔离 stderr `>>"$_LS_LOG_RAW" 2>&1 &`.
- `omn_scheduler.py`: L63 `_ARCHIVE_PREFIXES` 四→六源加 entrypoint+litestream; `capture_stdout()` 五源尾追加两 `_capture_one`.
- commit 35f08df push nomn `a80d335..35f08df`, CI sync-logic-nonoke 同步 Dataset (HEAD=f3000fb497b8 → 6f08fddd421d).

**2026-08-01 10:29 restart dev 真验全闭环** (Zen准拉现役 save/*.log 167 件析毕 → 远程 DELETE 删):
- **六源分类生效铁证**: 子目录 4 段件 32 件 (app 7/entrypoint 7/ft 4/gate 5/init 2/litestream 7) 北京时间 `YYYYMMDD_HHMMSS_<epoch>.log` 格式 epoch 递增全活。根平铺 135 件 (3 段 `<prefix>_<epoch>` 旧格式) epoch 17:08~18:29 = 前轮旧代码期残留非本轮新出; 子目录 epoch 18:29:53~18:38:53 = 本轮新代码期。**分水岭**: 根最晚 18:29:02 (boot-40s) → 子最早 18:29:53 (boot+11s), boot 瞬间新代码切换零混入。
- **boot race 1 次** = 预期非病: `No credentials for nvidia`@10:29:57.560 (probe key#6 窗口期内 providers nim-01 未注册完) → 10:30:27 恢复 `Using nvidia account: 6a7e0997`。同 [[save-log-analysis-2026-08-01]] 钉同链。
- **真 chat 闭环 6 次**: account p2c 轮换正常 (6a7e0997/160b719d/0f08b327/56844feb/a03b6766/2f562ab8/8fc989e6/aa7a9a8c/f0ca064d) USAGE+STREAM complete 全绿。
- **唯一 ERROR**: litestream restore rc=1 空库 `database not found in config` = [[omn-v30-logic-litestream-replicate-contract]] v0.5.9 -config 已知既定非新病, fail-open 空库后续 `detected database behind replica` 自愈。
- **删后残余**:DECISIONS commit c86bf015 (delete_files glob 扫 save/* 与六子目录) 删 save/*.log 190 件 (删除中又新 23), 留 6 json 快照 (combos/init_vars/keys/omni_config/providerConnections/settings).

### B. 日志归档机制 (Zen 2026-08-01 令治私库 100GB 硬限, 已 push a80d335)
方案 A 保留现架构: 7 天前旧日志按源分四包 tar.gz 推**新账号私库** (replaceable 满换库无所谓), 推成功后才 delete_files 删原库腾空间。
- `omn_scheduler.py` +5 段 append 0 改现役: 新 ENV 块 5 个 (`OMN_LOG_ARCHIVE` 总闸默 1 / `OMN_LOG_ARCHIVE_REPO` 新私库 / `OMN_LOG_ARCHIVE_TOKEN` 新号独立 token / `OMN_LOG_ARCHIVE_DAYS` 默 7 / `OMN_ARCHIVE_INTERVAL` 默 3600s)。换库只改两 Secret 零代码改。
- `_archive_loop` daemon 1h 查 + `_do_archive` fail-safe 铁闸 (推成功才删, 幂等去重列归档库查已归档跳推只删原件, 任一步失败 except continue 不删下次重试)。import tarfile+tempfile+shutil 标准库零新依赖。
- **Zen侧前置 (零代码依赖)**: 新号建 HF 私库 + write token → 入 Space Secrets (OMN_LOG_ARCHIVE_REPO+TOKEN) → restart 真验归档 daemon 启 + 1h 后查远程→save/ 旧件删 + archive/app/tar.gz 出现。

### C. omn_redact 默 6→7 扩 R2 endpoint 脱敏 (本轮 litestream 件隐私面)
- litestream 件含 `endpoint=https://<32hex>.r2.cloudflarestorage.com` = Cloudflare R2 account-id hash。**非签字凭** (S3 签字用 access-key-id+secret-key 在 Authorization header 非 endpoint; account-id 单独不操作 bucket), 且 repo private 风险本低。但留私库非最佳, Zen准扩。
- `omn_redact.py` DEFAULT_PATTERNS 第 7 条 `r'(endpoint=https?://)[A-Za-z0-9._-]+\.r2\.cloudflarestorage\.com'` — 捕前缀 `endpoint=https://` + 替 host 段为 `<REDACTED>`。余 6 不退, ENV 覆盖非追加语义不变。验通 (真测 R2 明文→脱敏 + 大写 STORAGE 不匹正常 + ENV 设仍覆盖非追加)。

**关联**: [[save-log-full-arch-landed]] [[save-log-analysis-2026-08-01]] [[log-archive-to-new-private-repo-landed]] [[omn-永续日志架构-landed]] [[omn-v30-logic-litestream-replicate-contract]]。

## 2026-08-12 · FT Worker 二维矩阵 10×10=100 上限框架 (commit 6c78f2d 本地待 push)

**Zen令**: 承 [[ft-worker-github-deploy-landed-2026-08-12]] 单 Worker 雏 (commit 008c48d), Zen定终"按 10 账号部署"+三点: ①Worker 名+自定域名仿两项目 (i3t2y/n-vless + n-edget) 儿童词池, 序从 1 递增 (1-10)②引两项目机制删旧 Worker→建新→绑 custom domain (封后立重设)③每账号绑一自定域名 `f01.cc.cd` 递增 (第 4 账号第 5 Worker = `5.f04.cc.cd`)。Zen明"参考两项目别臆造" → 谭照 n-vless `sync-deploy.yml` (795 行 5 job) 全机制移植扩。

**拓扑定夺 (Zen)**: 10 账号 × 10 Worker = 100 上限框架, 现役由 GitHub repo Variable `ACTIVE_ACCOUNTS` 自定 (Zen现满额 10 = 100 Worker)。每账号整 10 Worker (内序 1-10) 独立词基 (不跨账号共享: 障缝性 + 封禁隔离 + 1 账号封仅砍该账号词基)。

**机制移植 (commit 6c78f2d, deploy-ft-workers.yml 单维→二维全重写 +525/-47 rewrite 65%)**:
- **gate job**: PRESET 8 场景 (`gen`/`first`/`daily`/`solo:N`/`secrets`/`delete:1`/`delete:v`) + 动态矩阵构建 `account∈[1..ACTIVE_ACCOUNTS] × worker∈[1..10]`
- **gen-names job**: 60 词池 (3-4 字母过滤) + 每账号独立 `$RANDOM%WLEN` 抽双词不重 → `<W1>-<W2>-ft{1..10}` 平铺 100 名存 GitHub repo Variable `WORKER_NAMES`
- **deploy 二维矩阵每格 6 step**: Extract Credentials (`POS=(( account-1 )*10 + worker)` cut 取名 + `::add-mask::$TOKEN`) + Generate wrangler.toml (`workers_dev=false` + `[[routes]] pattern="$WSUB" custom_domain=true`) + Delete Worker (deploy 段自带删该格名防同名) + Deploy1st (`continue-on-error` 兜 10007) + 双 pass 绕扫 (PASS_MODE=2 全格重 deploy) + Verify & Bind Domain 三段验证 (存在性 3 重试 5s + custom domain 校验补绑 + 关 workers.dev)
- **域名派生 (Zen拓扑, 非 n-vless 循环回 0)**: `ACC2=$(printf "%02d" $account)` `WSUB="$worker.f$ACC2.cc.cd"`

**删段三模式裁决**:
- **Mode 1 (`delete:1`)** = 删当前矩阵单元指定 `WNAME` (散点删, 错杀他格)
- **Mode 2 (`delete:v`)** = 扫该账号 CF 全 Worker **全删 (无后缀滤波)** 全 DELETE 后重建 (PASS_MODE=2 双 pass), Zen 2026-08-12 令改「全删」反 n-vless 滤波删, Zen确认 FT CF 账号内无 gate 网关他 Worker 全删安全
- **Mode 3 (`delete:o`)** = 扫该账号 CF 全 Worker → 滤现役 `WORKER_NAMES` 名单 → 在名单 `Keep` / 不在 `DELETE` (清旧词基/孤儿/过时 Worker); **纯删无部署** (PASS_MODE=0 跳全 deploy step 唯删段跑); Zen问「删上次建立 worker 之外的所有 worker」定此场景, `delete:o` 名Zen定 (`other` 缩写, 对齐 `delete:1`/`delete:v` 序号风格)
- **绕封正解 (n-vless 证同名重部署不绕封)**: Mode 2 删光 → 重新 `gen` 换词基 → `first` 复绑旧子域 (子域不变桥零改动, 名变 CF 认新 Worker)
- **Mode 3 filter 安全**: `echo ",$WORKER_NAMES," | grep -q ",$W,"` 前后加逗号防部分命中 (如 `ft1` 误吞 `xxx-ft10`)

**旧 `flare*.workers.dev` 删不了裁决 (Zen会话问)**:
- 拦1: 删段正则 `~ ft[0-9]$` 不匹配 `flare` 后缀
- 拦2: `1-8.flare*.workers.dev` = 子域/workers.dev 域非 Worker 名; CF 删须 `DELETE scripts/{name}`, 旧名结构未知
- 裁决: Zen"到时临时删下手动太麻烦" → 下批 commit 合并扩删段正则容 `flare*` (`~ ^(flare|ft)[0-9]+$`), 不阻塞现 push; 或新池运行后旧 `flare*` 废弃不动 (Worker 不调不耗配额)

**Token scope 最小集 (WebFetch developers.cloudflare.com limits+permissions 页铁证)**:
- **CF Worker 池 token (每账号一 token 锁该账号+其 zone)**: Account `Workers Scripts Edit` (含 deploy/secret put/DELETE/列/subdomain关全; **无独立 'Workers Secrets Storage' 权限, secret_text 绑 script**) + Zone `Workers Routes Edit` + `Zone Read` (custom domain 须) + `DNS Edit`; Resources 锁 `Specific account` + `Specific zone`; 勿选 KV/R2/Pages/D1/Tail/Containers/Account Settings/User Details/Memberships/Builds/Agents
- **Edit vs Read**: Workers Scripts/Workers Routes/DNS = Edit; Zone = Read
- **GH_PAT (Fine-grained, 写 WORKER_NAMES Variable)**: Only `i3t2y/n-omn`; Repo perms `Variables` RW + `Contents` R + `Metadata` R; 勿 Actions/Workflows/Admin/Secrets/Statuses/Deployments/Pages; Expiration 推 90 天Zen定

**CF Free 配额铁证 (WebFetch limits 页)**: 每 account 100 Worker 上限 + 每 zone 100 custom domains (10 Worker<<100 安) + 配额账号级聚合 100k req/日/account (非 Worker 级, 不调不耗) + 10 账号各独立 token/zone 各吃本账号配额不共享不互抢。

**Zen手设 GitHub repo (我零碰真值 §2)**:
- **Variables**: `ACTIVE_ACCOUNTS=10` `PRESET=` (空默认 gen) `CRON_ENABLE=true` `DEPLOY_SCOPE=2` `PASS_MODE=2` `SOLO_ACCOUNT=1` `GEN_NAMES=0` `DELETE_MODE=0` `SECRETS_ONLY=0`
- **Secrets**: `CF_ACCOUNT_IDS` (10 accID 逗号串) + `CF_API_TOKENS` (10 tok 逗号串每锁该账号其 zone) + `RELAY_AUTH` (`openssl rand -hex 24` 且 **须同 HF Space Secret RELAY_AUTH** = Worker 鉴权↔桥铁律) + `GH_PAT` (Fine-grained)
- Zen补全 10 CF 账号 + 10 zone (`f01.cc.cd`~`f10.cc.cd` 各挂对应账号 zone) + 每 zone 建对应 token

**不变量守**: worker.js (008c48d fail-closed 态) + wrangler.toml (git 版单 Worker 骨架, workflow 动态覆写) 未动; 三件定态 (Dockerfile/README/start.sh) 零触; §1 私库唯一血统; §2 secret 真值零入 git/会话全走 `${{secrets.*}}` 占位 + `::add-mask::`; §5 commit 6c78f2d 已落 (Zen准), push 须Zen另准。

**部署链**: push nomn main (=触 `GEN_NAMES=0` 默认 gen Phase 生 100 名写 `WORKER_NAMES`) → 改 `PRESET=first` → 双 pass 全量建 100 Worker + custom domain + 关 workers.dev → GitHub Actions 绿 + CF Dashboard 见 100 Worker + 100 子域 → URL 回填 `flaretunnel_endpoints.json` (真身 HF Dataset `nonoke/omn-logic` 本地零件 git 未 tracked) → Restart dev Space → boot 真验桥 round-robin N/M 计数增 (路 3 /metrics 已落)。

**闸验全绿**: YAML 闸过 (`python3 yaml.safe_load` jobs gate/gen-names/deploy + matrix 动态 `${{fromJson}}`) + secret-scan exit=0 + 真值零残留 (全 `${{secrets.*}}` 占位)。

**关联**: [[ft-worker-100topology-landed-2026-08-12]] [[ft-worker-github-deploy-landed-2026-08-12]] [[ft-worker-count-env-lu-landed-2026-08-10]] [[flaretunnel-impl-built-verified]] [[flaretunnel-metrics-endpoint-lu3-landed]] [[ft-worker-count-vs-keys-decoupled]]。

<!-- 旧决策回填区 (待Zen令, 散落 audit/ / ops/incidents/ / ops/STATUS.md 段内未迁入) -->

## 2026-08-01 · omn_scheduler.py 归档结构假设错病根 (`parts != 4` 全杀零归档)

**背景**: Zen侧配齐 `OMN_LOG_ARCHIVE_DAYS=0`+`OMN_ARCHIVE_INTERVAL=60`+三核心 ENV (`OMN_LOG_ARCHIVE_REPO`=`nokebak/log`+`OMN_LOG_ARCHIVE_TOKEN`+`OMN_LOG_ARCHIVE=1`), 4 回重启 (11:41/12:05/...) 后归档库 `nokebak/log` **零压缩包出** + 源库 `nonoke/omn-logic` save/ 当日 217 件 **零删**。Zen直接判"归档删除根本没生效"。

**病根 (本地源库真件实测钉死)**: `omn_scheduler.py` `_do_archive` 原行 hard gate
```python
if len(parts) != 4 or parts[0] != "save" or parts[2] not in _ARCHIVE_PREFIXES:
    continue
fname = parts[3]
```
假设 **四段** `save/<prefix>/<sub>/<fname>`, 但 capture L155 真出件 **三段** `save/<prefix>/<stamp>_<epoch>.log` (parts=3)。源库 273 件实测: `parts=2` (10 件 json) + `parts=3` (263 件 log), **零件 `parts=4`**。`!= 4` 全杀 → 零件命中 → daemon 空转 → `delete_files([])` noop → 4 回零归档。原 L270 注释自写"非 `save/<prefix>/<fname>` 结构 parts≠4 自动跳"暴露作者脑中误嵌套四段, 实三段。**非 capture 改结构, 是归档代码 from inception 结构假设错, 永未真验** (会落模拟验证只测 cutoff 字符串比较逻辑, 未跑真件 parts 数 → 结构 gate 错直通验前未捕)。

**治法 (commit 待 push)**: dev/logic/omn_scheduler.py L267-273 改
```python
if len(parts) != 3 or parts[0] != "save" or parts[1] not in _ARCHIVE_PREFIXES:
    continue  # 非 save/<prefix>/<fname> 三段结构 (快照 json 根平铺 parts=2, debug 根平铺 parts=2 自动跳)
fname = parts[2]
```
`!= 4`→`!= 3`, prefix 索引 `parts[2]`→`parts[1]`, fname `parts[3]`→`parts[2]`。

**验证 (本地)**: `py_compile` exit 0。模拟真件 DAYS=0 cutoff=今日 → **263 件全命中六 prefix 全覆盖** (app59/entrypoint59/ft36/gate40/init8/litestream61) + 10 件 json 正确结构跳。修前 hit=0 全杀, 修后 hit=263 全活。

**debug 件裁决 (Zen问)**: debug 件 `save/debug_*.log` 根平铺 parts=2 → 结构 gate 跳 → **永不被归档 / 不删 / 不移入归档库**。三段判距 false-safe: debug 件保护性排除, 不入归档流。

**教训红线**: 归档/删除类 silent daemon 代码 "模拟验证" 仅测核心逻辑 (cutoff 字符串比较) 不够 → **必跑真件 + 真 parts 数 + 真删可见** 验结构 gate。静默 daemon 无 print/log 出件, 唯一观测面 = 远程库件数变化 (源库降 + 归档库升), 零变即病。print 加诊断 stub 留下轮观测。

**关联**: [[log-archive-to-new-private-repo-landed]] [[save-log-full-arch-landed]] [[omn-永续日志架构-landed]]。

<!-- 旧决策回填区 (待Zen令, 散落 audit/ / ops/incidents/ / ops/STATUS.md 段内未迁入) -->

---

## 2026-08-12 · FT Worker 100 拓扑 + GitHub Actions 自控部署链 (仿 n-vless/n-edget)

**背景**: `docs/flaretunnel.md:39` 自述现役机制 = "手工建 Worker 后写进 flaretunnel_endpoints.json 喂本地桥" + `ops/docs/DECISIONS.md:24` (旧) 锁决 "欲真扩池超 M 须Zen先 CF 建新 Worker → 填真实 URL"。运维负债: 换 RELAY_AUTH 钥须逐 Worker 手改 + worker.js 更新须逐 Worker 手粘贴。Zen令参考两私库 `i3t2y/n-vless` + `i3t2y/n-edget` 用 GitHub 控制 CF 账号建设 Worker。

**裁决 (Zen 2026-08-12 三点 + 拓扑定夺)**:
- **拓扑**: 10 CF 账号 × 10 Worker = 100 上限框架, 现役启 4 账号 sub集 40 (后续Zen加 f05~f10 zone 只改 `ACTIVE_ACCOUNTS` Variable, workflow 矩阵自适应)。每账号绑 1 主域名 `f01~f10.cc.cd`, Worker 子域 `{1-10}.f{账号:02d}.cc.cd` (例第4账号第5 Worker = `5.f04.cc.cd`)。
- **Worker 名+域名**: 仿 n-vless 儿童单词池 (60 词 3-4 字母), 每账号独立抽双词不跨账号共享 (障缝性 + 封禁隔离), 名格式 `<W1>-<W2>-ft{1-10}`。后缀 `v`→`ft` (项目标识防 delete Mode 2 误删 n-vless Worker)。
- **secret 注入**: 走 wrangler-action `with.secrets:` 输入列名 + `env:` 配同值 (非 n-vless curl PUT secrets API; 内建跑 `wrangler secret bulk/put` 注 Worker env), 值源 GitHub repo Secret `RELAY_AUTH`, §2 零入 git。
- **二维 account×worker 矩阵** (n-vless 一维 10 账号单 Worker; FT 1 账号 10 Worker 须二维扩), 工作目录 `flaretunnel/` (worker.js 非 n-vless `_worker.js`)。
- **绕封正解链** (n-vless 证同名重部署不绕封): Mode 2 删光 → 重新 `gen` 换词基 → `first` 复绑旧子域 (子域不变桥零改动, 名变 CF 认新 Worker)。
- **Token scope 最小集** (WebFetch developers.cloudflare.com 铁证): CF token 每 CF 账号一 token 锁该账号+该 zone: `Workers Scripts Edit` + `Workers Routes Edit` + `Zone Read` + `DNS Edit`; Resources `Include→Specific account`+`Specific zone` (作用域隔离勿 All)。GH_PAT Fine-grained: `Variables` Read/Write (核心写 WORKER_NAMES) + `Contents` Read + `Metadata` Read, repo only `i3t2y/n-omn`。
- **触发机制 tag-driven (Zen令 B 方案)**: `on.push.tags:['deploy-*']` 仅 deploy tag 推时触部署, 普通 push 改 workflow 零触 (Zen主动 tag 掌触发权); 三路触: ① `git tag deploy-vN && push` ② `schedule cron 17 2 * * *` (daily 走 PRESET Variable) ③ `workflow_dispatch` (input preset 即时覆盖)。

**commit 链 (本会话及前轮)**:
- `008c48d` 雏: worker.js fail-closed (env.RELAY_AUTH 双守) + wrangler.toml + deploy workflow (单 Worker 起步)
- `6c78f2d` 二维矩阵 10×10=100 + 三 job (gate/gen-names/deploy) + 删段 Mode 1/2/3
- `1431b0f` delete:o (清旧/孤儿/过时词基 Worker 纯删无部署, PASS_MODE=0)
- `08d272a` tag-driven on 段 (`on.push.tags:['deploy-*']`)
- `c10d544` secrets 场景 bug 修: Generate wrangler.toml + Deploy1st 去 `secrets_only=='0'` 守 (secrets_only=1 时两 step 原跳 → secret 不注)
- `517357f` RELAY_AUTH 真不注根因: Deploy1st + Deploy2nd `with:` 加 `secrets: | RELAY_AUTH` (Context7 wrangler-action @v4 docs 铁证: 仅 env 无 secrets 输入 = 仅 deploy 代码无 secret 注 → null AUTH_KEY → 401)
- `d1c324b` publish-endpoints job: deploy 成后派生 worker-major endpoint.json 传 HF Dataset via HF_TOKEN_NONOKE
- `c22b3a9` PRESET=publish 场景 (publish-only 路径): deploy 跳省 ~16m, 仅 publish 直跑无须重部 Worker

**boot 真验 (2026-08-12 10:43Z)**: 9 段全执行 + init rc=0 + FT 桥建 nim host=127.0.0.1:8081 HTTP 201 + 绑族 nvidia + healthz `worker_stats=40 workers=40 current_index=0 rotation_mode=round-robin` + 32 NIM key alive + 5 model available + balanced。

**代理真生效铁证 (HF Dataset save/ft/ capture log)**:
- `/metrics` Prometheus per-Worker 计数真增: `flaretunnel_worker_requests_total{name="calm-mist-ft1"} 1` `successes=1` `failures=0`
- round-robin 真轮 worker-major 40 Worker 连续: `1.f10→2.f01→2.f02` 跨 Worker 跨账号 + `3.f01→…→3.f05` 连续 + `3.f08→3.f09→3.f10→4.f01→4.f02→4.f03` 跨跨跨
- 真业务穿链: `POST integrate.api.nvidia.com/v1/chat/completions via Worker https://3.f02.cc.cd ✅ 200` → GLM-5.2 "Pong!" 真回
- 10 chat 全 HTTP 200 时延散布 3.5-33.7s = 40 Worker 各独立 CF 出口 IP 致时延异 (非单 Worker 死跑)

**f01 zone DNS 病 + 修 (2026-08-12)**: 初 boot 后 save/ft/ 日志印 `no such host` 集中 `2.f01/3.f01/4.f01.cc.cd` (f01 账号 zone 全 4 Worker 子域无 DNS), 其他账号正常。Zen CF 侧修 zone DNS 服务器 → 重探 `dig 1-4.f01.cc.cd` 全返 CF IP + curl `401` (Worker fail-closed 拒无 PSK = 活非 502/DNS 错) = 40 Worker 池全活。根: zone 层配置非 Worker/部署错 (f02-f04 同代码全活), 重部署不修 zone, 须Zen CF 侧裁。round-robin fallback 兜跳死 Worker 仍 200 = 韧性。

**关联**: [[ft-worker-100topology-landed-2026-08-12]] [[ft-worker-github-deploy-landed-2026-08-12]] [[flaretunnel-impl-built-verified]] [[flaretunnel-metrics-endpoint-lu3-landed]] [[ft-worker-count-env-lu-landed-2026-08-10]] [[ft-worker-count-vs-keys-decoupled]] [[flaretunnel-feasibility-verified]]

---

## 2026-08-12 · worker-major 重排 endpoint.json (Zen妙案, 桥取简化)

**背景**: endpoint.json 原 account-major 排 (idx0-9=acc1 w1-10, idx10-19=acc2 w1-10, ...), nim 桥取"每账号前4 worker"须手展开 `0-3,10-13,20-23,30-33` (parseWorkerIndices FlareTunnel.go:2119 解逗号+range 不支持步长) → 字串冗长易错。

**裁决 (Zen妙案)**: endpoint.json 重排 worker-major: idx0-9=worker1 各账号 (1.f01..1.f10), idx10-19=worker2, ..., idx90-99=worker10。nim 桥 `workers:"0-39"` 连续直取 = worker1-4 各 10 账号 = 每账号前4 worker (省字串手展开)。

**派生序**: `newidx → (worker=newidx//10, account=newidx%10) → old account-major idx = account*10 + worker → 取 WORKER_NAMES 名 → URL = https://{worker+1}.f{account+1:02d}.cc.cd`。本地 /tmp 脚本产 + workflow publish-endpoints Python 派生序完全匹配对证 (idx0=gem-fire-ft1→1.f01, idx30=gem-fire-ft4→4.f01, idx99=luck-love-ft10→10.f10)。

**自动化回填**: `publish-endpoints` job (commit d1c324b) deploy 成后 (或 PRESET=publish 场景 deploy 跳后) 派生 worker-major endpoint.json 传 HF Dataset `nonoke/omn-logic` `flaretunnel_endpoints.json` via `HF_TOKEN_NONOKE` GitHub Secret, 零硬编真值 §2。Zen须手设 `flaretunnel_bridges.json` nim `workers:"0-39"` (桥编排骨Zen域, workflow 不传 bridges)。

**关联**: [[ft-worker-100topology-landed-2026-08-12]]

---

## 2026-08-12 · PRESET=publish 场景 (publish-only 路径, deploy 跳省 16m)

**背景**: Zen欲"仅 publish 不重部 Worker" (daily 重部 100 格 ~16m 成本大), 额外特定任务路径。

**裁决 (commit c22b3a9)**: 加 `PRESET=publish` 场景, `PUBLISH_ONLY=1` flag:
- gate case `publish)` 分支: GEN_NAMES=0 + SECRETS_ONLY=0 + DELETE_MODE=0 + PUBLISH_ONLY=1
- gate outputs 加 `publish_only` (主输出 + cron 阻塞分支 + 默认值段)
- deploy if 加 `publish_only != '1'` 门 → publish 场景 deploy **跳** (100 格零跑省 ~16m)
- publish-endpoints if 改 `always() && gate.result=='success' && gen_names!='1' && (publish_only=='1' || (deploy.result=='success' && secrets_only!='1'))` — `always()` 兜 deploy skipped, `publish_only==1` 分支绕 deploy.result 判
- publish needs 保留 `[gate, deploy]` (deploy skipped 仍算 needs 满 + always())
- workflow_dispatch inputs preset 描述加 publish

**Zen用**: `PRESET=publish` (workflow_dispatch 输入框 或 Variable 临时设) → 仅 publish-endpoints 跑, deploy 零耗 → 派生 endpoint.json worker-major 传 Dataset。

**关联**: [[ft-worker-100topology-landed-2026-08-12]]

## 2026-08-12 · deepseek + mistral-small-4 模型剔 (Zen令 "NVIDIA 删了")

**触发**: 2026-08-12 dev boot 日志印 5 model DEPRECATED (NVIDIA 目录无): moonshotai/kimi-k3, deepseek-ai/deepseek-v4-flash, deepseek-ai/deepseek-v4-pro, qwen/qwen3.8-max-preview, mistralai/mistral-small-4-119b-2603. Zen两令: "deepseek删了吧" + "mistral-small-4 NVIDIA删了".

**剔范围** (Zen命删):
- `deepseek-ai/deepseek-v4-flash` — TIER_FAST + NIM_FAST_MODELS + NIM_EXTRA_MODELS 三处
- `deepseek-ai/deepseek-v4-pro` — TIER_FAST + NIM_CODEX_MODELS 两处
- `mistralai/mistral-small-4-119b-2603` — TIER_STABLE 一处

**留** (Zen未命删, deprecated 但待复检): moonshotai/kimi-k3 + qwen/qwen3.8-max-preview. 候Zen另令裁.

**落点** `dev/logic/init-nim-keys.sh` 6 处 (数据数组删, 注释保留历史标记同 `meta/llama-3.3-70b` / `openai/gpt-oss-120b` / `qwen/qwen3.5-397b` 格款, 供血统追溯):
- L66/67: TIER_FAST 删 deepseek 两行 → 注释
- L77: TIER_STABLE 删 mistral-small-4 → 注释
- L95: NIM_CODEX_MODELS 删 deepseek-v4-pro
- L103: NIM_FAST_MODELS 删 deepseek-v4-flash
- L110: NIM_EXTRA_MODELS 数组内移除 deepseek-v4-flash

**同步** `docs/nim_context_probe.sh` MODELS 删 deepseek (Zen手动探真截断点工具, 非 boot 血统, 逼Zen跑时不烧 deprecated 请求)。

**闸验**: `bash -n dev/logic/init-nim-keys.sh` PASS + `python3 .claude/hooks/secret-scan.py` exit=0 (模型名非 secret, 闸无害)。

**不变量守**: §1 三件定态 (Dockerfile/README/start.sh) 零触; init-nim-keys.sh = dev 逻辑层镜像 (Dataset nonoke/omn-logic 真身, 改须 git 先行再 push); §0 不翻案 Task D/E 已删模型 (llama-3.3/gpt-oss/qwen3.5-397b); §3 DECISIONS 只增不改。

**关联**: [[ft-worker-100topology-landed-2026-08-12]] (同期 100 Worker 满额全活)

## 2026-08-12 · gate /v1/ft/metrics PSK 反代 FT 桥 Prometheus 计数 (路3-b Zen令)

**触发**: Zen令 "做" (前轮汇总承 "gate 加路由暴露 FT 桥 /metrics 公网 → 下会话事" 待办, HANDOFF:123 旧列). 痛=公网取不得 FT per-Worker 计数 (容器内 127.0.0.1:8081 /metrics, 公网 gate 未暴露).

**裁决 (commit ec0712d, dev/logic/gate.js +56 行)**: 加 `GET /v1/ft/metrics` 公网路由, PSK 鉴权反代 FlareTunnel 桥本地 `/metrics` (Prometheus text exposition, `text/plain; version=0.0.4`).

- **PSK 鉴权**: 靠前 `app.use('/v1', ...)` (gate.js line 187-198), Bearer INTERNAL_PSK safeEqual 常量时比, 缺/错 fail-closed 401. 路由序 `/v1/ft/metrics` (line 369) 在 proxyV1 mount (line 405) 前, PSK 层在两者前.
- **桥选址**: `?bridge=N` 0-基选特定桥, 默 0 首桥 (现役惯例 "首桥代整体", init-nim-keys.sh `_ft_register_proxy` 多桥 healthz 读 `[0].port` 旧例); 越界/非数 → 400 `bad_bridge_index` (告池数 `?bridge=N (0..M-1)`).
- **FT_PORTS env**: entrypoint export `FT_PORTS` (空格分隔端口串, 多桥) / `FT_PORT` (单桥回退 8080). `FT_PORTS_LIST` 解析 + `FT_PORT_SINGLE` 回退 + `FT_HOST` (默 127.0.0.1) + `FT_BRIDGES` (FT 未启 FT_PORTS 空时 8080 兜, 取时 ECONNREFUSED→503 区分路由存在 vs 桥死).
- **上游错码**: ECONNREFUSED→503 `upstream_unavailable` (FT 桥未启/死, 非 404 区分路由存在) / TimeoutError→504 `gateway_timeout` / 其余 502 `bad_gateway`. shutdown→503 `abort_source:'shutdown'`. Host 头须 = `${FT_HOST}:${ftPort}` (FT Host 守卫非 127.0.0.1:PORT 不命中落 HandleHTTP 透传).
- **不反代 /healthz**: 公网已有 `/healthz` (探 OR 链), FT 本地 healthz 无额外面价值; metrics 含 per-Worker 计数 (路3 落) 才是Zen要.

**真路测五态全绿** (临时装 express --no-save 跑 spawn 真 gate.js + mock FT 桥, 测后删 node_modules 非血统):
1. 无 PSK → 401 `unauthorized` (PSK fail-closed)
2. 对 PSK + bridge=0 活桥 → 200 + `flaretunnel_worker_requests_total{name="calm-mist-ft1"} 1` 计数命中
3. bridge=1 死桥 → 503 `service_unavailable` (ECONNREFUSED→503)
4. bridge=99 越界 → 400 `bad_bridge_index` (告 `?bridge=N (0..1)`)
5. 错 PSK → 401 `unauthorized` (safeEqual 拒)

**闸验**: `node --check dev/logic/gate.js` PASS + `python3 .claude/hooks/secret-scan.py` exit=0 (gate.js 单独 + 全工作树) + pre-commit 闸通过.

**落点**: `dev/logic/gate.js` (dev 逻辑层镜像, 真身 Dataset nonoke/omn-logic, 改须 git 先行再 push; 非 §1 三件定态). 真路测 spawn 真 gate.js 印 `[gate] FT bridges:` + `[gate] listening on` 全正常.

**不变量守**: §1 三件定态零触 (Dockerfile/README/start.sh); gate.js 非 §1 三件可改; §6 /v1/* Bearer = INTERNAL_PSK safeEqual 缺/<16 fail-closed 守; §2 secret 零入会话 (测试用合成串 `testpsk_synthetic_0123456789ab` 32 字符, Authorization 头运行期拼非源字面避 secret-scan 误伤); §0 不翻案 FT 桥"/metrics 路由3 落 (`FlareTunnel.go:1890-1933` Start()) 旧决, 本段补公网暴露门.

**关联**: [[ft-worker-100topology-landed-2026-08-12]] (FT 计数源 per-Worker), [[flaretunnel-metrics-endpoint-lu3-landed]] (路3 /metrics 落本基)

## §4 时延基线对比 + CF IP 优化裁决 (2026-08-13, 只增不改, 纯查证无 commit)

**裁决**: 100 Worker 共享池 = CF 免费层 IP 多样性天花板, 不升 Enterprise 无优化空间.

**时延基线** (`audit/2026-07-20-r3plus-group2-3parallel-10rounds.md`, 16 Worker 扩 100 前):
- 基线 200: 2.17-14.15s (3 并发 10 轮); 429 快拒 1.45-1.98s
- 现态 100 Worker: 3.5-33.7s + 30s client abort + 502 lockout 3s
- 差: 下限 +1.3s (+60%), 上限 +19.6s (+138%) 翻倍, 新增 30s abort
- 基线非纯对照 (16 Worker 期亦 FT 启期), 真"FT 开销"定论须无 FT 直连测, 候Zen命

**外部 AI 文判** (Zen贴"架构师建议"):
- ❌伪: "关小黄云 DNS Only" (CF Routes doc: Worker 须 proxied 调用关=断链); "优选 IP 映射 1.1.1.1" (CF Anycast 无 origin IP)
- ❌撞锁: "收 40 子域" (撤销换 IP 池撞 warp-vs-ft③); "砍 Worker" (撞本 §4 上文 100 锁决 + §0 不翻案)
- ✅真可取唯一: "FT 转发重 + HF 2vCPU 计算压" (与本仓 ft-worker-count-vs-keys + warp-vs-ft 档案一致)

**CF IP 优化三选项裁决**:
- 独享固定 IP (Dedicated Egress/BYOIP) ❌: Enterprise+加购 + 反设计 (固定单 IP 撞 warp-vs-ft 裁决③ "单 IP 静态反加剧风控" 否决). CF 社区 MVP sjr 明确 "Any dedicated IP addressing requires Enterprise plan"
- Smart Placement ⚠️微调: 迁 Worker 到低延迟数据中心, 但不改出口 IP 改跑位置; 100 Worker 同好迁可能反降 IP 多样性; Worker→NIM 美国境内 <5ms 优化空间小; 不轻试
- 多账号扩域 ⚠️撞Zen 10 账号满额上限 (2026-08-12 明令) + 更多 NV/邮箱运维负债

**NIM 403 真根重诊方向** (推翻前轮臆测):
- NVIDIA 论坛大量用户证 403 "Authorization failed" 真根 = 账号缺 "Public API Endpoints" 权限/组织权限, 非出口 IP 封
- ft1 集中 403 须按 NIM key 维度重诊: 查 403 Worker 用 NIM key vs 200 Worker 用 key 是否同账号? 同账号配额耗尽触发 403 = 非 IP
- (承前轮 ft-worker-100topology memory 已列 "出口 IP 风控/NIM key 配额地理拒" 双可能, 本段收敛到 NIM key 维度为主嫌疑)

**不变量守**: §0 不翻案 100 Worker 拓扑 (翻案须Zen明确令); §1 三件定态零触; §2 secret 零入会话 (本轮纯查证无代码); DECISIONS 只增不改 (本 §4 即只增).

**关联**: [[ft-worker-100topology-landed-2026-08-12]] [[warp-vs-ft-egress-对比]] [[ft-worker-count-vs-keys-decoupled]] [[latency-baseline-vs-100worker-2026-08-13]]

## §5 429 风暴红外诊断 + 三病并存定谳 (2026-08-19, 只增不改, 纯查证无 commit)

**裁决**: 429 真根 = NIM account-level 配额速率限 (纯 key/account 维, 非出口 IP 维), 与前轮 §4 403 (ft1 族 IP/权限维) **两病并存非互斥**. OmniRoute fallback 韧态全活, 非本地代码 bug.

**证据三叠** (Zen 2026-08-19 贴代理日志 + 单事件详情 + 应用控制台 + Health 仪表盘):
1. **代理日志 59 条**: combo `—` 空 = glm-5.2 单 model 设计如此 (`getComboForModel` model.ts:237 返 null = single-model 请求, 非 fallback 没生效; 连 200 成功也 `—`). 推翻前轮"combo 空最可抓活根"误判.
2. **attempts 链展开** = fallback 换 key 真活铁证: `be1e20b9` 7 attempts 跨 nim-01~06 连 429 / `3b3e55c6` 16 attempts 烧 16 key 末中 200 / `36a91736` 12 attempts 全 429 末 200 = 同 request_id 跨 account 连试. OmniRoute internal fallback 韧态真撑.
3. **控制台**: `🚫 [RATE-LIMIT] nvidia:<UUID> — 429 received, pausing for 60s` (60s cooldown 实跑; 源码 errorConfig rateLimit default 120s, 实跑 60s = init 配/resilience profile 覆写, Zen侧 `/api/resilience` 可查真值) + `nvidia round-robin: FALLBACK MODE - excluded_count=N excluded=...  picked_lru=...` (LRU 排除已限 account 选下一) + `Account X error cleared` (成功清 cooldown) + `Model-only lockout ... 429 rate_limited 3s (failureCount=1, connection stays active)` (model 级 3s 短锁, connection 不死, 他 model 可继续).
4. **Health 仪表盘终极证**: 32 account 风暴窗 140 请求 · **40% 成功率**, 21 account `rate_limited degraded` 散布**无 IP 族聚类** (若 IP 限应 Worker-IP 扎堆, 反见 nim-XX 按账号成簇无规律), healthy 10 散布全账号 (nim-07,08,09,16,19,20,21,23,27,32). provider 熔断 **CB CLOSED** (未跳, round-robin 始终在 provider 内换 account, 无全停). cooldown 0 (无 account 长锁, 60s 窗过即回活). 限速标 `nvidia:<UUID>` = account ID = NIM 按 account 计限. 风暴过后现态 12min 11 请求 **0% 错误率** = 系统回稳.

**429 = account 维强证 (非 IP)**: 21/32 散布无聚类 + 限速标 account UUID 非 IP + cooldown/account-clear 按 account 非 Worker = NIM account-level 配额速率限. 推翻任何"429 源 FT 出口 IP"臆测.

**三病并存定谳** (现盘全合):
- **429 (本轮主流)** = NIM account 配额速率限 × Hermes 高频连发 (4-5s 隔, msg 88→130 增). 纯 account/key 维, 非本地 bug, 非 FT 桥病. 风暴窗 60% 拒, 60s cd 窗解即回 0% 错.
- **403 (前轮 §4, ft1 族集中)** = auth/权限维, 另案并存. 本轮未复现, §4"账号缺 Public API Endpoints 权限/组织权限"方向仍立, 待深查 (查 403 Worker NIM key vs 200 Worker key 同否账号).
- **502 (1× nim-13)** = NIM 服务层瞬时 RST (`fetch failed ECONNRESET`), 透传非桥造, fallback 跳过续试.
- **+ 新发现 陈旧错态 gap**: OmniRoute 冷却 (60s) 过期回活后错误字段 (lastError code 429) 不自动清 → Health Autopilot 检到提"Clear stale error state"手动按钮 (22 issues/22 actions). 小 bug 级: spend-cooldown account 可能被路由偏置继续绕开本已回活 account. **缓释**: Zen点 Autopilot 22 动作批量清 (或 API 批量), 21 account 立回 healthy. 我零碰 prod.

**解方向 (候Zen命, 非本轮 commit)**:
1. 降打高频: 客户端侧 4-5s 隔太快, OmniRoute `requestQueue.requestsPerMinute` 调低 + `maxWaitMs=300000` (已落, init-nim-keys.sh:909 R3+) 排队撑非即拒.
2. 拉长 429 cd 反加效: 60s 太短致 Hermes 复发前回复活又被烧, 拉到 120-180s 让单 account 彻底冷却 (须配降客户端频率否则更堵).
3. 扩 NIM account 池减单 key 承压, 但撞Zen 10 account 满额上限 ([[ft-worker-100topology-landed-2026-08-12]]).
4. 真根治 = NIM 侧配额/credits 提升 (NVIDIA 端非本地能控).

**否定项 (已查证排除)**:
- combo `—` 空 = 正常设计非 bug (getComboForModel 返 null = single-model). 推翻前轮误判.
- FT 桥透传 429 = NIM 真返非桥造 (worker.js 纯转透换出口 IP, Authorization 不在 DROP_REQ 全转透 NIM). 403/502 同透传上游真返.
- 真测现态不建议: 0% 错系统回稳, 无活病可测; 真须烧 NIM 配额高频打造风暴 = 成本高仅重复证已有定论. 真测脚本框架可写候Zen择机下次风暴测.

**不变量守**: §0 不翻案 100 Worker 拓扑 + §4 403 决 (翻案须Zen明确令); §1 三件定态零触; §2 secret 零入会话 (本轮纯查证无代码); DECISIONS 只增不改 (本 §5 即只增, §4 未动).

**关联**: [[429-fallback-alive-combo-empty-normal-2026-08-19]] [[429-vs-403-combo-empty-diagnose-2026-08-19]] [[latency-baseline-vs-100worker-2026-08-13]] [[ft-worker-100topology-landed-2026-08-12]] [[gate-ft-metrics-public-proxy-landed-2026-08-12]]

## §6 init boot 自清 OmniRoute Health Autopilot 陈旧错态 (路A 2026-08-19 落, commit 3158c2c, 只增不改)

**裁决**: 2026-08-19 §5 裁决"陈旧错态 gap 缓释: Zen点 Autopilot 批量清, 我零碰 prod"升级为 **路 A init boot 自清** 自动化落地 (Zen令 "A"= init boot 自清 init 已有 cookie 鉴权)。dev nonoke/omn ephemeral 语境唯一解。

**病链复述** (接 §5 陈旧错态 gap):
- OmniRoute 冷却 (60s) 过期回活后 lastError (code 429) 不自动清 → Health Autopilot 检 `stale_connection_error` 22 issues 提手动清 → 回活 account 被路由偏置绕开。
- **dev nonoke/omn ephemeral 死结** = R2 无 3.8.48 snapshot (STATUS line 170) → 每 boot 空库启动 migration 重建空表 → Dashboard 手加 manage-scope API key 写 ephemeral SQLite → 重启空库归零刷新不持久。`dev/scripts/clear-stale-nim-errors.sh` 须 external manage-scope key (Bearer) → catch-22 `/api/keys POST` 需 `requireManagementAuth` (四路鉴权: Dashboard session / CLI loopback / `oma_` access token / manage-scope API key) → external key 不持久 script 无法跑。
- **init 已有 Dashboard session cookie 鉴权链** (`dev/logic/init-nim-keys.sh:602-605` login→auth_token cookie→`624` /api/keys POST 证通管理端) → 用同 cookie 调 autopilot actions = 走 `requireManagementAuth` 路 1 Dashboard session ✓ = 不依赖 external 持久 key。

**治法** (commit 3158c2c `dev/logic/init-nim-keys.sh` +86 行):
- 新增 `clear_stale_nim_errors()` 函数 (插 `gc_stale_providers()` 后), 调用点 gc_stale_providers 调用后 (line 965)。
- 机制两步 (源 3.8.48 `src/app/api/providers/health-autopilot/{route.ts GET, actions/route.ts POST}` + `providerHealthAutopilot.ts executeProviderHealthAutopilotAction` actionSchema `{type,target:{provider,connectionId},preconditionsHash,confirm}`):
  1. GET `/api/providers/health-autopilot?provider=nvidia&includeHealthy=false&includeActions=true` 带 `$COOKIE_FILE` cookie。
  2. python3 解 `issues[].actions[]` 里 `type=="clear_stale_connection_error"` 提 `(connectionId, preconditionsHash)`。
  3. 逐个 POST `/api/providers/health-autopilot/actions` body `{type, target:{provider:"nvidia", connectionId}, preconditionsHash, confirm:true}` 带 cookie `-b $COOKIE_FILE` + `Origin: $BASE_URL` 头 (pipeline 已统一 Origin, 显式带更稳)。
- **fail-open 范式** (仿 `gc_stale_providers` line 161-195): GET 非200 →印跳过 return 0; `set +eo pipefail` 抬门防空 pipefail 杀 init; 0 stale →return 0; 逐 POST 失败 → WARN `continue`; 终态连接 (banned/expired) 源 409 拒不清 → INFO skip (z.enum 限 `clear_stale_connection_error` 非 cooldown 本身, 终态 `isTerminalConnection` 409)。
- **ENV 闸** `OMN_CLEAR_STALE` (默 `"1"` 开, `="0"` 跳整段), 仿 `OMN_LOG_TO_DATASET` 闸范式。
- **语法修**: `_ACT_CODE=$(curl ... -d "$(python3 -c '...')")` 双层 `$(...)` 命令替换末须 `))` 双配 (内闭 python3 sub + `"`闭 -d 引 + 外闭 curl sub)。原单 `)` 致 bash quote tracking 失衡 EOF 错。闸验 `bash -n` + `secret-scan.py` exit 0 (connectionId/hash 非 Bearer 凭非敏感, §2 不触)。

**部署链**:
- commit `3158c2c` push nomn main → `sync-logic-nonoke.yml` GitHub Action 触 (dev/logic/** push) → HF Dataset nonoke/omni-logic 同步。**疑点 (未解)**: 本次 sync Action 上 Dataset 旧版 (init-nim-keys.sh 不含函数, sha256 `1e0d2fad` / 79691 bytes vs 本地 `bab088f0` / 84054 bytes), 根未查 (可能 checkout SHA 落后/path filter 未中/concurrent race)。**手推修**: Python 读 `~/.omn-secrets` `HF_TOKEN_DATASET_WRITE` 注入 os.environ (非 cli 字面, §2 零触) → upload_file + hf_hub_download 读回 sha256 闭验 (Dataset `169bc09c` == 本地 ✓) → dev nonoke/omn Restart。boot 真活回显 (Dataset HEAD `ea08edbb256c` 系) `[init] clear_stale: 无陈旧错态 (Autopilot issues=0 stale_connection_error)` 预期三态之一 = 本 boot 全新空库无历史 stale。

**保留**: `dev/scripts/clear-stale-nim-errors.sh` 保留作 (a) prod 侧 (nomke/omn R2 副本 key 持久) 偶用备 (须 §1 明令 + 取 prod manage key); (b) 参考文档 (init 自清函数即其 boot 版)。非顿旧决策 (§5 "缓释: Zen点 Autopilot" 已被路 A 自清自动化升级, 非 §0 翻案 = 同向演进)。

**不变量守**: §0 一次会话一件事 (路 A 闭环); §1 三件定态 (Dockerfile/README/start.sh) 零触, 改 `dev/logic/` 非三件走 Dataset sync 非 Rebuild; §2 secret 零入 git/会话 (由盾外 + sha256 闭验, token 读 ~/.omn-secrets 注入 os.environ); §1 nomke/omn 生产无 Zen 令不动; 上游只读查证 (`/tmp/om48` = v3.8.48 ref 非血统不进 git), init 改属我仓 dev 镜像真身。

**未决/下一步**: sync-logic-nonoke.yml Action 上旧版未解 —— 本次手推绕过, 下次 dev/logic/** push 若 Action 仍上旧版会覆盖回旧。须Zen侧查 Action run log (GitHub repo i3t2y/n-omn → Actions), 可能 checkout SHA 落后/path filter 未中/concurrent race。候命排查。

**关联**: [[429-fallback-alive-combo-empty-normal-2026-08-19]] [[429-vs-403-combo-empty-diagnose-2026-08-19]] [[ft-worker-100topology-landed-2026-08-12]] [[omniroute-upstream-entrypoint-drift-v3.8.48]] [[omn-merge-three-remote-topology]]

## §7 加 R2 副本根治 nonoke/omn ephemeral 持久化 (路B 2026-08-19 裁, 待落, 只增不改)

**Zen原话**: "怎么也要实现路径1啊,直接把r2加上,搞定持久化不就行了。" = 超越路A自清 (commit 3158c2c, 绕过 ephemeral 死结兜底), 真根治 = 让 R2 副本建立, restore 拉 R2 真库, manage key 跨 boot 持久 → 路径1 external 脚本 `dev/scripts/clear-stale-nim-errors.sh` 可真跑。

**§1 拓扑翻案 (与本 §7 同期, Zen 2026-08-19 明令)**: 撤 nomke 生产 Space, 剩 **nonoke/omn 单 Space 兼生产+dev**。R2 bucket = **omn-data (dev 桶升正单桶)**; omniroute-data 旧生产桶不动存历史。旧"双 Space / R2 bucket 永不双写"铁律随 nomke 撤失效 (单 Space 单桶无双写问题)。CLAUDE.md §1 已改 (2026-08-19 修订: 单源单Space)。本 §7 病根/治法按单 Space 单桶 omn-data 论。

**架构已全建好 — 零代码改动, 纯 HF Space Variables**:
- `dev/logic/litestream.yml` R2 s3 replica 配置全 (bucket `$\{R2_BUCKET\}`, path `db/storage.sqlite`, endpoint `https://$\{R2_ACCOUNT_ID\}.r2.cloudflarestorage.com`, sync-interval 10s, auto-recover false)。
- `dev/logic/entrypoint.sh:124-125` `has_r2=0; [ -n R2_ACCESS_KEY_ID ] && [ -n R2_SECRET_ACCESS_KEY ] && [ -n R2_ACCOUNT_ID ] && has_r2=1` (判活只验 **3 凭据**, **不验 R2_BUCKET**)。
- L128-166 restore: has_r2=0 → skip 空库 | 本地非空 → skip 不覆盖 | 空库 → litestream restore -config -if-replica-exists -o DB_TMP; 无副本例外 grep 'no replica|empty|not found' 不 WARN → 空库 init 重建。
- L391-407 replicate: has_r2=1 后 `OMN_PERSIST_WRITE:-1` 闸; =1 启 litestream replicate 后台 (sync-interval 10s 写 R2) | =0 关态不启 (本次改动不写回 R2)。
- L499 replicate 退出 STRICT exit / 非致命 WARN PID 置空 (LITESTREAM_STRICT 闸)。

**病根**:
1. **(实证) 3 R2 凭据未齐** → `has_r2=0` → boot `⚠ R2 凭据未配置 → skip restore 空库启动` (STATUS line 170 "dev R2 omn-data 无 3.8.48 snapshot" 钉死)。
2. **(待核, 非 hardcode 断言) `OMN_PERSIST_WRITE` 现态未实证**: 该闸 2026-08-10 加 (commit 63497bd) 默认未设=1开 (entrypoint L400 `$\{OMN_PERSIST_WRITE:-1\}`)。memory `omn-persist-write-request-landed-2026-08-10` line 13 明 "现状(加开关前)本就是保存的 replicate 无条件跑", Zen加闸后**可能从未设0故默1开 replicate 仍跑**。"OMN_PERSIST_WRITE=0 关态"乃前轮摘要记忆断言**未经 boot 日志实证**; 真根若"加 key 重启丢"可能 litestream 链有病 (replicate 死 L487 WARN/restore 断 L136/sync-10s 窗口) 非设计不保存 (memory line 13 "须贴 boot 日志取证定根 未结")。Zen侧补凭据后 boot 看 `[entrypoint] Litestream:` 行态定关态真伪后决定处置。
- `R2_BUCKET=omn-data` Zen已设 (STATUS line 210 ✅) 但 has_r2 判活不含此故不生效。

**治法 (Zen侧操作, 我无 HF UI 权限, §2 凭据零入会话) — 单 Space 单桶 omn-data**:
1. nonoke/omn Space (现唯一 Space) → Settings → Variables 补 3 R2 凭据: `R2_ACCESS_KEY_ID` / `R2_SECRET_ACCESS_KEY` / `R2_ACCOUNT_ID` (Zen手填, token **最小 scope: 锁 omn-data 单桶 Write+Read**)。
2. Restart 非 Rebuild (纯 Variable 改零数据清零) → boot 看 `[entrypoint] Litestream:` 行态:
   - 若印 `Litestream PID=$LS_PID ...` = 默1开 replicate 跑 (OMN_PERSIST_WRITE 未设) → 跳处置, 病根②不存在。
   - 若印 `OMN_PERSIST_WRITE=0 关态 replicate 不启` = Zen曾设0 → 处置设 `1` **或删此 Variable** 回默1 (推荐删 = 少一件)。

**§1 单 Space 单桶复核**:
- nonoke/omn = 唯一 Space (nomke 废)。R2 bucket = **omn-data** (dev 桶升正, omniroute-data 旧生产桶不动存历史)。**单 Space 单桶无双写问题** (旧"双 Space 永不同时写同一 bucket"铁律随 nomke 撤失效)。
- R2 token scope **锁 omn-data 单桶 Write+Read** (非全账号) 即可, 无双写越权面。补凭据前Zen侧 R2 Dashboard 核 omn-data 桶存在。
- **遗留疑点 (audit 反证)**: audit §2.1 证 2026-07-27 04:55Z boot `litestream initialized` + `snapshot complete txid=0x01` 成功 = 那时 has_r2=1 凭据齐 replicate 跑, 写 omn-data 桶。STATUS line 170 后期"无 3.8.48 snapshot" = R2 副本后期已无 (可能 lifecycle 清/凭据撤/关态无写致空/桶误删)。须Zen侧 R2 Dashboard 核 omn-data 桶 `db/storage.sqlite` path 历史代数现状。不阻塞本次 (补凭据启 replicate 重建 omn-data 副本)。

**验证两轮**:
- **首 boot** (建首个 R2 snapshot): Restart → boot 见 has_r2=1 restore 段 (非 skip) → replicate PID 印 (非关态) → init rc=0 → ≥10s litestream sync 写 R2 (`replica: sync: wrote segment/snapshot complete` 行) → R2 Dashboard omn-data 桶 `db/storage.sqlite` 首个 generation 建。
- **二 boot** (真持久化铁证): 再 Restart → boot 见 `restore rc=0 原子 mv` + 本地非空 skip (L130) → Dashboard 手加 manage key → 再 Restart 仍存 = catch-22 破 → 路径1 external 脚本可真跑。

**与路A关系**: 非互斥, 并存。R2 持久化后 manage key 持久 → 路径1 external 可跑; 但 init boot 自清 (路A) 仍留作自愈兜底 (每 boot 重建同步清上轮风暴残留, 不依赖 external key)。两方案同向根治演进。

**2026-08-20 实证修订 (四病根, 非翻案 = 同向确证)**: ① R2 凭据已补齐 (boot 走 restore 分支非 skip, has_r2=1) ② OMN_PERSIST_WRITE 已处置 (boot 印 `Litestream PID=149/151/156` 开态, replicate 启) ③ **litestream.yml path 不匹配实锤真根 (已解除 c790e05 + 手推)** = `path: /app/data/storage.sqlite` 硬编码对不上运行 DB path. entrypoint 默认 DATA_DIR=/app/data (L16) 但 HF Space env 设 `DATA_DIR=/data` → 运行 DB 实际 `/data/storage.sqlite`, 13:53 boot 报 `database not found in config: /data/storage.sqlite` → `⚠ restore 失败 rc=1 空库启动` = **R2 持久化真障碍** (restore 拉不到 R2, replicate 也匹配不上 config 写不到). **修复裁决 (c790e05)**: litestream.yml dbs[].path 硬编码 → `$\{DATA_DIR\}/storage.sqlite` env 派生对齐运行态 (entrypoint L17 `export DATA_DIR` 保证子进程见运行值 /data; litestream.yml 其它键 bucket/endpoint/keys 全用 `${ENV}` 展开且已工作实证). **15:36 boot 实证生效**: 错误从 `database not found in config` **变成** `s3: ListObjectsV2 403 AccessDenied` = path 正确展开成 `/data/storage.sqlite` 匹配运行 DB, 已到 S3 访问阶段. **手推链路**: c24c959 push 触 sync-logic-nonoke Action 失败 (job 0 steps 2 秒 fail, run id 32373926257, 根未查 — 疑 runner 分配/触发级非 step 失败), 手推 litestream.yml 上 Dataset (Python hf upload 注入 HF_TOKEN_DATASET_WRITE, 读回 sha256 闭验 `982a050f3a4f539b` 匹配). ④ **R2 S3 token 缺 List 权限实锤真根 (现唯一障碍)**: 15:36 boot 报 `s3: list generations: ListObjectsV2, 403 AccessDenied` — litestream 启动列 omn-data 桶 `db/storage.sqlite` generation 被拒 = token (R2_ACCESS_KEY_ID 对应) 无 omn-data 桶 Object List 权限. litestream 需 **ListObjectsV2 + GetObject + PutObject + DeleteObject** 全权限. Zen侧 R2 Dashboard 核 token scope 含 omn-data 桶全读写 List, 补后 Restart 复验 v1-v5. **教训**: litestream.yml path 须与运行 DATA_DIR 同源 (硬编码 /app/data 因 HF Space env DATA_DIR=/data 覆盖漂移断链); sync Action 故障时手推 upload 是可依赖的绕过备份 (sha 闭验保血缘); R2 token 须单桶全权限 (List+Get+Put+Delete) 非仅 Write.

**未决/下一步**:
- 候Zen侧补 3 R2 凭据 (§2 零入会话, 我侧无法操作) + OMN_PERSIST_WRITE boot 验态后处置。
- 候Zen侧 R2 Dashboard 核 omn-data 桶历史代数现状 (副本后期空根)。
- 验签两轮后全绿 → STATUS 续真持久化闭环段。

**关联**: [[clear-stale-nim-errors-init-boot-auto-la-2026-08-19]] [[omn-v30-logic-litestream-replicate-contract]] [[storage-bucket-dataset-堪察]] [[omn-三层解耦新方案绕hf冻]] [[compaction-txid-gap-scar-closed]]

## §8 自定义 provider 名长短之分: 路由用 prefix, 显示用 name (2026-08-21, 只增不改, 源码查证)

**Zen问**: "为什么后台加的就没用？非要加到启动脚本里注册了才能用？原生版本不是加了就能用的吗？" + "为什么官方原版加了就能用，也不用改什么短名？" + "在哪里改？" (贴 edit 表单: 名称=sensenova, **前缀=sensenova**, base URL=token.sensenova.cn)

**定谳 (源码实证 + 表单实证, 非翻案 = 确证机制)**:
- **自定义 openai-compatible 节点有两字段**: `prefix`(路由前缀) + `name`(显示名)。**路由只用 `prefix` 或 `id`, 绝不用 `name`** (`src/sse/services/model.ts` getModelInfo L282: `getModelInfo("sensenova/deepseek-v4-flash")` → `prefixToCheck="sensenova"` → 匹配 `node.prefix === "sensenova"` 或 `node.id === "sensenova"`)。`name` 仅作显示 (`src/lib/display/names.ts` 显示优先级 node.name → node.prefix → de-UUID id)。
- **在哪里改 = 前缀 (prefix) 字段**: Zen贴的 edit 表单已示**前缀字段 = `sensenova`** (可编辑, updateProviderNodeSchema prefix 非只读)。把**前缀 (prefix)** 设成与 model 串前缀一致 (`sensenova`), 保存后 `sensenova/deepseek-v4-flash` 路由 `node.prefix === "sensenova"` 命中 → provider 解析为节点 UUID → 凭据查找成功。**名称 (name) 字段纯显示, 改不改无碍路由**。
- **"No credentials for sensenova" 真根**: `getProviderCredentials("sensenova")` 前 `resolveProviderId("sensenova")` 查内置 registry alias 映射 (providers.ts L368-371) → `sensenova` 非内置 alias → 原样返回 `sensenova` → `getConnections("sensenova")` 找不到 (连接 provider = 节点 UUID `openai-compatible-chat-a45f6ed1-...`, 非 `sensenova`) → **无连接 → "No credentials"**。即 getModelInfo 未命中节点 (prefix 未匹配) 时, provider 回落原始串。
- **原版"加了就能用"非特例**: 内置 provider (如 `nvidia`) 的 **id 即路由前缀**, model 挂其下调用 `nvidia/<model>` 天然对 (init-nim-keys.sh 注册 `provider=nvidia` 同路)。**自定义节点必须用 `prefix` 做模型前缀** (非 `name`), 否则模型 id 前缀对不上路由 prefix 即断 = Zen当前状态 (prefix 若确已=sensenova 却仍 No credentials, 须核 ① 该节点类型确为 openai-compatible (getModelInfo 只查 openai-compatible/anthropic-compatible 两类, 其他类型不匹配) ② model 确挂该节点 providerId (addCustomModel key=providerId, CustomModelsSection L138 modelId 原始串 trim 不自动前缀) ③ 该连接有可用 key 非 terminal)。

**治法 (让 `sensenova/...` 直接可用)**:
1. **设节点 prefix = `sensenova`** (Zen表单已示可改): Dashboard 编辑该节点, **前缀字段填 `sensenova`** (与 model 串前缀一致), 保存 → `sensenova/deepseek-v4-flash` 路由命中。**最贴合Zen"加了就能用"意图**。
2. **核节点类型**: 确认该节点 type = `openai-compatible` (getModelInfo 只匹配此二类; 若存成 `openai-compatible-chat` 等带后缀 type 则不匹配)。
3. **核 model 归属**: model 列表 `sensenova/deepseek-v4-flash` 须挂该节点 providerId (customModels namespace key = 节点 UUID), 且节点 prefix 与 model 前缀一致。
4. **配 model alias** (备选): Settings 加 alias 把 `sensenova` 映射到该节点 UUID。

**关链**: init-nim-keys.sh 走 `/api/providers` + `/api/provider-models` 注册 `provider=nvidia` (内置 provider id=prefix), 故 `nvidia/<model>` 天然路由成功 = 与自定义节点殊途同归。

**未决**: Zen核节点类型 + model 归属 + prefix 三处一致后验证。若 prefix 已=sensenova 仍失败, 疑 type 或 model 归属错, 非 prefix 值问题。

### §8.1 实证修订: 单节点单连接但 prefix 仍不匹配 (2026-08-21 晚, 只增不改, API 铁证)

**Zen追问**: "删除重新添加还是长名" + "每次加了不能立即生效" + "加了都是先测试再保存的" → 逐层剥离伪因, 最终 API 返回铁证定谳。

**新证据 (POST /api/providers 返回, 决定性)**:
- sensenova 连接: `provider=openai-compatible-chat-75176e99-8e99-4cbc-91be-f98734e789c2`, `prefix=sensenova`, `name=sensenova`, `testStatus=active`, key `sk-F1lzC****O5Nw` 健康。
- amd 连接: `provider=openai-compatible-chat-484711e6-...`, `prefix=amd`, `name=amd`, `testStatus=active`。
- **两连接 provider 字段都是长 UUID (节点 id), prefix 都是短名 (节点 prefix)**。节点/连接/prefix 三处**表面全同步**。
- **但: `amd/DeepSeek-V4-Flash` 前缀调用 200 通; `sensenova/deepseek-v4-flash` 前缀调用 "No credentials" 不通; 两连接**长 id 直调都不通** (`openai-compatible-chat-<uuid>/...` → No active credentials)。

**关键矛盾 → 真根定位 (getModelInfo vs getProviderCredentials 两段链, 各认各的键)**:
- **getModelInfo (model.ts:285-288)**: `openaiNodes.find(node => node.prefix === "sensenova" || node.id === "sensenova")` → 匹配到 prefix=sensenova 的节点 → 返回 `provider = 该节点的 id`。**它返回的 provider id = getModelInfo 匹配到的那个节点的 UUID。**
- **getProviderCredentials (auth.ts:1006-1013)**: 用 getModelInfo 返回的 provider id 去查 `getProviderSearchPool(provider)` → `getCachedRawProviderConnections({provider, isActive:true})`。
- **连接按 provider = 长 UUID 存** (API 铁证)。若 getModelInfo 匹配到的节点 id **恰好 = 连接存的 provider UUID** → 通; **否则 → No credentials**。
- **amd 通 = getModelInfo 匹配到的 amd 节点 id (484711e6) = 连接 provider (484711e6)**。
- **sensenova 不通 = getModelInfo 匹配到的 sensenova 节点 id ≠ 连接 provider (75176e99)**, 或**有多个 prefix=sensenova 的节点** (getModelInfo 只取第一个), 或**节点缓存 (nodesCache 5s TTL) 里 sensenova 节点是旧的** (id ≠ 75176e99, 连接挂在 75176e99 下)。

**核心**: 路由成功与否取决于 **getModelInfo 匹配到的节点 id 是否精确等于连接存的那个 provider UUID**。prefix 只是中间匹配键, **真正的凭据键是节点 id (UUID)**。Zen"删了重加还是长名" = 每次重加节点生成**新 UUID**, 连接 provider 跟着新节点, 但**旧节点/旧连接残留或缓存未失效**导致 getModelInfo 匹配到错 id。

**治法 (让 sensenova 精确路由)**:
1. **删净所有 sensenova 旧节点 + 旧连接** (provider 列表核无重复), 只留一个 prefix=sensenova 的新节点 + 一个连接 (provider=该新节点 id)。
2. **重启** (清 nodesCache 5s TTL + 重拉 R2 库), 确保 getModelInfo 匹配的节点 = 连接 provider UUID。
3. 调用 `sensenova/deepseek-v4-flash` → getModelInfo 匹配 prefix=sensenova 的**唯一**节点 → provider=该节点 id → 连接查到 → 通。
4. **若仍不通**: 改 model 归属 (addCustomModel 用**节点 UUID** 做 namespace key) 或配 alias, 使 model 前缀对上层 provider。

**教训**: 自定义 provider 路由 = **prefix 匹配节点 → 节点 id 查连接** 两段链, 凭据键是 **节点 UUID 非 prefix**。重复添加/删旧留新会致 getModelInfo 匹配到与连接 provider 不一致的节点 id → "No credentials"。删除重加必须**删净旧的**避免多节点残留。

**追更 (同 §8.1, 只增不改)**: 上述「多节点残留 / 节点 id 不匹配」判断**被后证推翻** — Zen API 返回两节点两连接**结构完全对称** (amd 节点 484711e6/连接 484711e6; sensenova 节点 75176e99/连接 75176e99, 各 type=openai-compatible, prefix 与连接 prefix 全一致), 且**后台 Test 功能直调长 ID `openai-compatible-chat-75176e99-.../deepseek-v4-flash` 200 通** (节点+连接+key 全健康)。**节点/连接/prefix 三处全对, 但 `sensenova/` 前缀路由仍不通, 而 `amd/` 前缀路由通** → 非节点缺失、非重复残留、非缓存陈旧。

**真根 (源码级锁定)**: `sensenova` 是 **OmniRoute 内置 provider** (regional.ts:331-348, id=`sensenova`, alias=`sensenova`), 而 `amd` 非内置 (REGISTRY 零命中)。model.ts:277-278 `getReservedProviderPrefixes()` 把**所有内置 provider 的 id+alias 全加入 reserved 集合** (含 `sensenova`); L280 `if (!isReservedPrefix)` 对 `sensenova` = **false** → **跳过整个自定义节点匹配块 (L281-326)** → 落回 `getModelInfoCore` 查内置 sensenova → 无连接 → "No credentials for sensenova"。`amd` 非 reserved → 走 L285 `openaiNodes.find(node.prefix===amd)` → 匹配自定义节点 → 展开 → 通。**根因 = 自定义节点前缀恰好撞了内置 provider 名**, reserved-prefix 检查**故意**防「自定义前缀遮蔽内置 provider」 (model.ts:271-273 注释明说), 故前缀撞内置名的自定义节点**永远被遮蔽**, 配置再对也没用。

**治法**: 把自定义节点 prefix 改成**非内置名** (如 `snova`, 已验证不在 REGISTRY), 连接 providerSpecificData.prefix 同步改 (或删旧重建), 重启后 `snova/<model>` 前缀路由展开到新节点 UUID → 通。**长 ID 直调不受影响** (后台 Test 功能/curl 长 UUID 仍可走), 只前缀调用须改非内置名。

**教训 (修正 §8.1 前判)**: 自定义节点前缀**不可与内置 provider id/alias 撞名** (built-in registry 优先, 遮蔽自定义节点)。查"前缀路由不通"须先 `grep REGISTRY` 确认前缀非内置; 内置名 (如 sensenova/nvidia/glm 等) 做自定义前缀一律不生效。

## §9 FT 健康感知轮转落码 (2026-08-23 落码, docs/ft-health-aware-rotation.md, 只增不改)

Zen 2026-08-23 令"深入设计 FT 可优化空间 + 搜索论证最佳算法"后批"落码"。**纯桥层逻辑改**, 不动 worker.js/Worker/域名/鉴权。

**算法论证 (外部搜索实源)**: 对 FT 40 Worker 出口池, 纯 RR 等权分布对但死节点照轮; Least Connections 不适用 (短转发无长会话); Weighted RR 无意义 (Worker 容量等价); 纯 Random 打击同 IP 反风控。**最优 = RR + 健康过滤 (失败冷却跳过)** — Reddit ProxyEngineering"每 proxy 冷却" + LevelUp"熔断与重试分离"共识。

**实现 (FlareTunnel.go + entrypoint.sh)**:
- `ProxyServer` struct 加 `HealthCoolDown int` + `HealthFailThreshold int` 字段
- `GetWorkerURL()` round-robin 分支: 顺序扫跳不健康 worker, 全不健康保底回退纯顺序 (不空转 503)
- `isHealthy()` helper: 无记录/未用=健康放行; LastStatus≥400 或 err(0) 且距 LastUsed<冷却秒=降权跳过; 冷却过恢复
- `main()` 加 `--health-cooldown` 参数 + 注入
- entrypoint.sh 加 `_ft_health` (`FT_HEALTH_COOLDOWN` env 控, 默认空=不传=关), 3 处起桥命令 (多桥/单桥/单桥重启) 追加

**验证 (全绿)**: docker 编译 EXIT 0 / isHealthy 单元测试 7/7 过 / entrypoint.sh bash -n OK / go vet EXIT 0 (2 pre-existing 冗余 newline 非我改) / git diff 完整.

**默认关零风险**: 不设 `FT_HEALTH_COOLDOWN` env = 纯 round-robin 行为不变; 启用设 `FT_HEALTH_COOLDOWN=30` → 失败 worker 30s 降权跳过. 待Zen定是否推 HF Dataset + 真启用.

## §10 FT Worker 拓扑全可配变量化 (2026-08-23 Zen令, deploy-ft-workers.yml, 只增不改)

Zen 2026-08-23 先令"搜索论证单 CF 免费账号建几个 FT worker 收益最大"后批"账号数和worker数全都为可配变量"。

**查证 (外部搜索实源)**: 同一账号下多个 worker **不提供独立出口 IP** (CF 出口 Anycast 172.64.0.0/13 共享 + colocation 就近分散, 非按 worker 分配; 2020 社区实测同 IP / 2022 InfoQ 官宣 Soft-unicast 共享出口)。每账号每日 100K 请求**账号级共享** (非每 worker), 建多 worker 不增总配额, 只把请求拆给更多 colo 出口。**单 CF 账号建 2-3 worker 收益最大** (吞吐承载满足 + colo 出口分散达甜点 + 100K 配额不浪费); 继续堆 worker 数无 IP 增益。**扩 IP 多样性 + 总吞吐的真杠杆是加账号数非加每账号 worker 数** (10-20 账号 × 2-3 worker = 独立出口池 + 独立配额 >> 10 账号 × 10 worker 同池冗余)。

**实现 (deploy-ft-workers.yml 全链)**:
- **新增 `WORKERS_PER_ACCOUNT` 变量 (默认 3, 甜点)**, 账号数用现有 `ACTIVE_ACCOUNTS` (**全账号都用上**: Variable 已设 10=f01~f10 全 zone; 默认 4 仅当 Variable 未设时的兜底)。**两端全可配**。
- gate env/默认值加 `WORKERS_PER_ACCOUNT` + `REORG` + 输出 `act_accts`/`wpa`; 矩阵 `WORKER_MATRIX` 从写死 `[1-10]` 改 `seq 1 $WORKERS_PER_ACCOUNT` 动态
- gen-names 每账号 worker 数从写死 10 改 `$WORKERS_PER_ACCOUNT`; `N_TOTAL = ACTIVE_ACCOUNTS × WORKERS_PER_ACCOUNT` 全动态
- deploy POS 从 `(account-1)*10+worker` 改 `(account-1)*WORKERS_PER_ACCOUNT+worker`
- publish-endpoints worker-major 派生从 `//10 %10 *10` 改 `//n_accounts %n_accounts` (wpa 从 env 读)
- SOLO_ACCOUNT 校验从 `^[1-9]$|^10$` 改通用正整数校验

**新增 `PRESET=reorg` 拓扑重组专用选项** (Zen令"执行时加删旧 worker 选项"): 一次触发完成拓扑收缩 + 孤儿清理 + 全量重建。
- `reorg` case: `GEN_NAMES=1; REORG=1; DELETE_MODE=3; DEPLOY_SCOPE=2; PASS_MODE=2`
- 顺序: gen-names job 先跑重生成名 (WORKER_NAMES → 新 N×M) → deploy job 后跑 (DELETE_MODE=3 删不在现役名单的旧 worker + 双 pass 绕扫建新)
- deploy job `needs: [gate, gen-names]`, gate 条件 `(gen_names != '1' || reorg == '1')` 允许 reorg 时 deploy 在 gen 后跑
- **清旧原理**: 拓扑收缩 (10→N×3) 后旧的 4-10.fXX 不在新 WORKER_NAMES, `delete:o` (DELETE_MODE=3) 遍历账号下所有 worker 不在名单则删 → 自动清掉孤儿

**worker-major 派生 bug 修复 (关键)**: 原代码 `w = newidx//10; a = newidx%10` 在 10×10 时碰对 (账号数=worker 数=10 恰好相等)。新拓扑账号数≠worker 数时照搬 `//wpa %wpa` 会越界/错排。**正确公式**: `w = newidx // n_accounts; a = newidx % n_accounts; old = a * wpa + w` (worker 外层慢变, 账号内层快变; w 上限恒 wpa-1 不越界)。**普适验证全绿**: 10×3 (全账号=当前) / 10×10 (旧拓扑不回归) / 6×4 (账号≠worker 极端) / 4×3 (测试样本) 全 CORRECT。n_accounts 自动=WORKER_NAMES 全部账号 (ACTIVE_ACCOUNTS×WORKERS_PER_ACCOUNT), 全账号都用上。

**验证 (全绿)**: YAML 语法通过 / 10 个 bash run 块 `bash -n` 通过 / publish-endpoints Python 语法通过 (YAML 去缩进后) / worker-major 派生模拟 4 情形全 CORRECT / 每账号端点数正确。

**默认零风险**: 不设 `WORKERS_PER_ACCOUNT` = 默认 3 (甜点), 设 10 回归旧拓扑。账号数全用 (ACTIVE_ACCOUNTS=10 全 zone)。运行时 entrypoint 从 endpoints.json 轮换 worker, 天然支持任意池大小, 无需改。待Zen定推 HF Dataset + 真启用。触发 reorg 后拓扑收缩为 **10×3 (全账号 × 每账号 3 worker)**。

**2026-08-23 真触发排障: 私库 GitHub Actions 额度耗尽 + reorg 全量重建 bug (commit 8685740)** —
- **根因① 私库 Actions 额度耗尽 (billing 非代码)**: Zen触发 reorg 后 workflow run 秒败 (5 秒, steps=0, job 未分配 runner, 日志空 zip). 诊断发现该 workflow 从 08-16 (run#12) 起所有 run 全 failure (含正常 daily schedule run#14-19), 非代码 bug 而是 **私库 GitHub Actions 免费分钟数用尽** 致 job 无法启动. Zen改仓库公开 (公开库 Actions 分钟不限额) 后恢复, run 正常启动 (run#22 成功). 排障教训: 快速失败 + steps=0 + 多日 schedule 全败 → 先查 billing/quota 非查代码.
- **根因② reorg 全量重建 bug**: run#22 公开后正常跑, 但 deploy 只建 1 个 worker (账号1 worker1). gate 日志 `>>> Matrix: placeholder (gen-names mode)` 暴露根因: reorg case 设 `GEN_NAMES=1` 使 gate 走 gen-names 占位分支 (matrix={account:[1],worker:[1]}), deploy 用占位矩阵只建 1 个; 且 publish 因 gen_names=1 跳过, endpoint.json 未重新派生 30 个新 worker.
  - **修法 (commit 8685740, 三处)**: ① reorg case `GEN_NAMES=1→0` (gate 走 DEPLOY_SCOPE=2 完整矩阵 10 账号×3 worker=30 格) ② gen-names job `if: gen_names == '1'` 改 `if: gen_names == '1' || reorg == '1'` (reorg 时 gen_names=0 仍触发 gen-names 重生成名写新 WORKER_NAMES) ③ publish-endpoints 因 GEN_NAMES=0 后 gen_names≠1 + deploy success 自然恢复, reorg 后重新派生 30 个新 endpoint 传 Dataset.
  - 流程: gate→gen-names(串行写新名, deploy needs gen-names)→deploy(等 gen-names 完成, 30 格删旧+双 pass 建新)→publish(needs deploy, 等 30 实例全成, 派生新 endpoint). YAML+bash-n 全过. 真触发 run#23 验 10×3 收缩 + 30 worker + 新 endpoint.

## §11 逻辑层换源 Bucket 方案 (2026-08-24 Zen令深挖, 2026-08-25 批走 B 实施中, 只增不改)

Zen 2026-08-24 令"换 Bucket 深挖"批走 (B) 换 Bucket 源。背景: nonoke HF 账号 ToS 违规锁 → boot 拉 nonoke/omni-logic Dataset 403 FATAL。完整设计: docs/logic-switch-bucket-design.md。

**关键认知 (Zen点破, 修正旧判)**: 四件武器(版控/PR/血缘/K3 commit_id 锁/git show 历史)全绑私库 n-omn, 不绑 Dataset。换源不丢四件。唯一真成本 = 丢 Dataset 白送的 `--revision` atomic 快照锁。

**现役链路 (已核实)**: 源=dev/logic 八件→n-omn git; 推送=CI `hf upload` 逐文件(每文件一 commit)+readback sha256; boot 拉=start.sh L87 `hf download --revision <cid>` 锁 atomic →/tmp/logic→cp -a /logic(ephemeral 不 mount); 执行=exec /logic/entrypoint.sh。

**xnexus/logic 不存在 (404)** — 换必须先建。

**atomic 锁必须手工补 (manifest 版本钉)**: Bucket 非版本化无 commit_id, 逐文件 PUT 窗口内 boot 拉到半新半旧=竞速复活。`batch_bucket_files` 仍非真原子(逐个对象)。**唯一可靠路径 = manifest.json 版本钉**: Bucket 根 manifest 记 n-omn SHA + 每文件 sha256; boot 先拉 manifest 校验每文件哈希, 不匹配 fail 重试, 全对才 cp 到 /logic。

**改动清单 (2026-08-25 代码侧已落, 三块 + FT 端点 = 四块)**:
- ① sync-logic CI: 新建 sync-logic-xnexus.yml (batch_bucket_files 上传 8 件→写 manifest→readback 校验), 替代 nonoke 版
- ② start.sh §3: S3 拉 + manifest 校验 + 另拉 flaretunnel_endpoints.json (**破 §1 三件定态铁律, Zen已显令批**)
- ③ 执行零改 (/logic cp 固化)
- ④ **deploy-ft-workers.yml publish-endpoints: FT 端点改推 xnexus/logic Bucket (新发现依赖)** — entrypoint L216/231 读 /logic/flaretunnel_endpoints.json, 原推 nonoke/omn-logic (Dataset 已 403 锁), 不迁则 FT 桥全断。此文件由 deploy-ft-workers 独立写 (非 sync-logic 8 件), start.sh §3.2 单独拉 (不进 manifest)

**代价**: 破 §1 铁律(已批) / 改 sync CI(已落) / 建 xnexus/logic Bucket(手动, 须Zen UI 或 `hf buckets create`) / 丢 atomic 快照(manifest 补回) / HF_TOKEN 换 xnexus / S3 读一致性(低, 低写频可忽略)。

**执行序 (已批 2026-08-25, 代码侧 ①②④ 已落)**: 1 建 Bucket(Zen)⏳ 2 ✅ sync CI 3 ✅ start.sh §3 4 ✅ deploy-ft-workers 5 ⏳ 首次推 8 件+manifest(须 xnexus HF_TOKEN) 6 ⏳ 本地 mock 验(已过)+boot 真验(须 xnexus Space 在线) 7 SSOT 文档落 8 Zen批 commit→push→切 xnexus/o Space。

**护栏**: §1 xnexus/o 唯一 Space, xnexus/logic 是 Bucket 源非 Space(不新建 Space); §2 xnexus HF_TOKEN 值零入会话; §5 git 一律 ask。

出处: docs/logic-switch-bucket-design.md + docs/xnexus-deploy-checklist.md (commit 待Zen批)。关联: ops/docs/DECISIONS.md §7 (R2 副本), docs/ft-health-aware-rotation.md (同型"待批实施"设计文档先例)。

## §12 升 3.8.50 全链路 (2026-08-30 Zen批"整体升 3.8.50", #39-#42, 只增不改)

Zen 2026-08-30 批"整体升 3.8.50"。五步: #39 拉上游树(upstream/ 只读) → #40 migration 审计(序列 001-162, 断号 026/055/121 与 3.8.49 全同) → #41 撞点映射(API 注册面/透传层/启动编排零破坏性撞点; monitoring/health 鉴权化对 init 零影响, init 只认 http_code 不解析 body) → #42 dev 构建(环境层 omn-base:3.8.50 本地 build rc=0 + push attempt5 大 layer 续传 + manifest HTTP 200 确认) → 生产切换(待Zen执行)。

**GHCR 镜像**: `ghcr.io/i3t2y/omn-base:3.8.50`, RepoDigest `sha256:db9037a7...` (上游 `@sha256:085c57...`)。闸门纪律: 预构建只推 `:3.8.50` 具体 tag, 不推 `:stable` (stable=生产指针, 升级获批 boot 全绿后记账式移动)。

**升级路径定案: Variable 钉 digest (非 Dockerfile ARG)** — `sync-space-xnexus.yml` L13 铁证 xnexus/o 的 BASE_IMAGE 现役即 **Variable** (Zen首投手动锚 9c9aecf), 覆盖 Dockerfile 浮动 `:stable` ARG 默认。此实证 STATUS.md 2026-07-28 双轨回归"Variable 覆盖 ARG 待真验" = Variable 路已真运行。3.8.50 同路, 零新机制。

**批准执行命令 (唯一触 HF build 队列动作, 须 xnexus HF_TOKEN, Zen执行)**:
```
SPACE_REPO_ID=xnexus/o python3 /home/laisi/old/new/omn-ops/scripts/space_ctl.py upgrade 3.8.50 ghcr.io/i3t2y/omn-base@sha256:db9037a71379569fa3a86b0760df972fd8413cc07f0a58b64e575bbf28a1718b
```

**待验 (切后回贴判九段)**: build 日志 (`space_ctl.py build logs`) → boot 九段回显 → `init rc=0`。⚠️ 此操作为生产切换 (xnexus/o 唯一 Space 兼生产), build 冻/风控 兜底契约同 §11 (变量已改镜像未滚时 entrypoint "告警不 exit").

**实测观察 (2026-08-30 boot 全绿, 非致命留痕, 非回退理由)**:
- `版本不齐 实跑=unknown 期望=3.8.50`: 上游 internal 版本串惯例 unknown, 迁移自动前滚, entrypoint "告警不 exit" 兜底 (§11 契约)。正常。
- `CredentialHealth ❌ Endpoint /models unavailable` (14 连接, failure #1/600s): 3.8.50 新增健康检查服务, 对 openai-compatible 节点用 /models 探测失败 (提示用 Model ID 走 /chat/completions)。探测噪音, 不阻断实际路由 (同节点业务 200)。观察是否持续。
- `Cleanup: no such table compression_run_telemetry`: 上游 3.8.50 cleanup 引了 migration 未建/非默认建的表, skip 0 deleted 非致命。
- `nvidia 枚举 0 模型 (body 0B, key=none)`: 仅致自动 nvidia-pool 跳过, 不影响 nim-pool/dp4f-pool 主路径 (业务 200)。
- 32 `ProxyEgress status=success` + `[ProxyHealth] 36 blocked by target`: 探活被上游拒=已知惰性检测设计, 业务不受影响。

出处: `old/new/omn-ops/exchange/upgrade-3.8.50-20260830.txt` + memory `v3.8.50-collision-map-zero-2026-08-30`。关联: §11 (xnexus/logic Bucket 拓扑), §7 (R2 副本)。

## 2026-09-02 · xnexus-o 私有化 + 反代注入 token + cron 探活 — 四阶段全闭环 (commit 67ea460 + 6cfe21c + 4b593a8)

- **目标**: xnexus-o 改私有 → 脱离匿名入站池 (官方限流双档: Anonymous 500 vs Free user 1000/5min) → 反代 CF 侧持 HF token 注入 → cron 带 PSK 探反代。三重收益: 焊死 PSK 泄露直连绕过 + 甩开匿名池 429 + 探活走用户真实路径。
- **实测头名铁证 (推翻 X-Api-Key 假设)**: HF 私有 Space 直连三态 — 无 token→404 / `X-Api-Key`→404 / `Authorization: Bearer`→200。**私有 Space 只认 Bearer 头**。定案: 反代出站 authorization 覆盖为 `Bearer <HF_TOKEN>` 门票, PSK 改走 `X-Gate-PSK` 独立头, gate.js `/v1` 校验 X-Gate-PSK 优先、回退 authorization (L199-212)。
- **Pages 生产部署三坑 (wrangler 4.128 + GH Actions tag)**: ① 函数文件名须 `_middleware.js` (`[[path]].js` 的 `[[path]]` 被当 glob 吞空→No Functions); ② 部署须 `cd` 进目录跑 `deploy .` (相对子路径不发现 functions→空站 404); ③ 须 `--branch main` 强制 production (GH Actions checkout=detached HEAD 默认判 preview, secret 绑 production env → preview 读不到 INTERNAL_PSK→503; 且默认 URL 无 production 一直 404) + secret-put 须在 deploy 前 (新 deployment 创建时读 secret)。
- **自定义域名**: `omn.360710.xyz` 已绑 Pages 项目 (无 zone 账号 B 建 page, CNAME 到账号 A zone)。**注意**: 计划文档原写 `proxy.360710.xyz`, 实际Zen绑的是 `omn.360710.xyz`。
- **cron-job.org 探活**: 每分钟 GET `omn.360710.xyz/healthz` + 头 `Bearer <PSK>` → 200 `{"ok":true}`, 响应头 `x-proxied-host`/`x-proxied-path` 证穿透 gate。探活走反代=探用户真实路径。
- **Pages 唯一生产 (2026-09-02 定案)**: worker 版已删 (h-o.cc.cd 530), 无重建。原因实证: 旧 worker 版出站不带 `Bearer <HF_TOKEN>` 门票, 私有 Space 平台层即拒 (请求进不了容器, 到不了 gate) → **任何不带门票的出站必死**。worker 版源码 + deploy workflow 留仓库作回滚源, 恢复需先改源码注入门票+秘密 (已对齐 Pages 版逻辑, 见 052506e) 再部署。sonoke base_url = `https://omn.360710.xyz/v1` (须带 /v1, 裸路径绕 gate 中间件 401 invalid_api_key)。

## 2026-09-03 · amd 403 根因定谳 (账户级推理权限, 非代码 bug) — 已侦查闭环

- **现象**: 生产 20:56 boot, amd 5 key 全 `Invalid API key` (CredentialHealth) + `Auto-sync failed: 403` ×5。dp4f-pool 中 amd 2 条为死腿, amd-pool 单池仅死 key。此现象与上一会话 (19:46-21:29) amd 403 主失败链同源, 非新病。
- **直接实测 (合成 key, §2 合规, 禁真 key 入会)** 打 amd 上游 `developer.amd.com.cn/radeon/api/v1`:
  - 合成 key `GET /v1/models` → `401 Invalid bearer token` (目录层)
  - 合成 key `POST /v1/chat/completions` → `401 Invalid bearer token` (推理层)
  - 对照真 key boot 实证: 枚举 `GET /models` = `200 key=ok` (4 模型, 目录层鉴权通); CredentialHealth/Auto-sync 推理 `POST /chat/completions` = **403**
- **定谳 = init-nim-keys.sh L800-811 记载的 2026-07-21 事件签名**: `GET 目录 200 而 POST 推理 403` = **账户级死亡 key, 鉴权链断在推理层**。5 key 同病 → 同一批 provision 缺陷。
- **已排除 (都有直接证据)**: baseUrl/路径拼接错 (枚举用同 baseUrl 200) / Bearer 头格式错 (合成 key 返回结构化 401, 说明上游正确解析 Bearer) / 整池连不上 (目录层 200) / egress 或 FT 补绑问题 (b67a91f 后 boot 仍 403) / SENSENOVA & NVIDIA 路 (两家 status=success, 实打实 200)。
- **根因判断**: amd key 对 chat-completions 推理端点缺 entitlement/scope, 或已过期, 或跨门户签发 (中国区门户 `developer.amd.com.cn` vs 全球 `developer.amd.com` token 互不认, 社区常见 403)。官方文档: [认证](https://developer.amd.com.cn/docs/authentication)、[Chat Completions API](https://developer.amd.com.cn/radeon/api-reference/chat-completions)。
- **执行前提 (Zen侧, 非代码)**: ① amd 门户重发/续期 5 key, 确认带 chat-completions inference 权限 + 中国门户签发; ② 换好 key 后**临时开 `NIM_PROBE_ENABLED=1` 一 boot**, 让 M3 探活 (POST 推理端, 专切死 key) 直接验证, 别等 runtime CredentialHealth 滞后发现 (现默认 `=0` 跳 probe, 故死 key 照常入池); ③ 若 amd 已不需 → 同 DISABLED 机制从注册循环 + dp4f-pool 摘除 (保留代码), 消死腿。
- **附带留痕**: 生产周期内另见 `Cleanup: no such table compression_run_telemetry` — 但 quick_check ok, 是**单纯缺表非坏库** (R2 restore 库缺该表, 3.8.50 cleanup 期望它存在, 已容错 skip); 非回退理由。
- 出处: 本会话 amd 上游合成 key 直测 + boot 20:56 实证 + memory `amd-not-builtin-long-id-expected`。关联: §12 (3.8.50 观察同型 403/"blocked by target"), ops/overengineering-audit-2026-09-02.md ④ (amd 补绑 FT 桥背景)。

## 2026-09-04 · ⚠️ §13 推翻更正 — amd 403 真根 = FT Worker 白名单漏配, 非账户级死 key

- **§13 定谳错误, 正式推翻**: 当时把 `枚举 200 / 推理 403` 归因为"账户级死亡 key" (07-21 签名), **漏读了 boot 日志的原始错误文本**。Zen追问 "amd的5key全对, 403到底是什么问题?" + "是不是修出问题来了?" 触发复查 → 真根 = **b67a91f (2026-09-03 补绑 FT 桥) 引入的回归, 叠加 Worker 白名单漏配**。
- **真根因 (证据链)**:
  1. boot 日志 `[403]: host not allowed` (L499/L543/L559) — 这是 flaretunnel/worker.js L44-45 的**原生错误文本**, 只可能来自 Worker 层白名单 miss, 不是上游 amd 返回 (上游拒 key 是 `401 Invalid bearer token` / 403 body 是别的内容)。
  2. 5 key 全对: 枚举 `key=ok` 200 (L751) + `amd-01..05 OK` (L729-745) — key 鉴权在目录层通过。
  3. b67a91f 把 amd node (UUID `openai-compatible-chat-1923f9b3-...`) 绑进 FT proxy → 推理请求改经 FT 桥 → Cloudflare Worker → `ALLOWED_HOSTS` 缺 `developer.amd.com.cn` → 403。**枚举走 init-nim-keys.sh L1495 裸 curl 直连绕过 Worker (故 200), 推理走连接过桥 (故 403)** — 两条路径分离, 枚举 200 不证推理通。
  4. 对照 sensenova: 5256253 给 Worker 白名单加了 `token/api.sensenova.cn` 所以通; amd 绑定晚了这步。
- **修复 (3cb5c39, 已 commit)**: flaretunnel/worker.js `ALLOWED_HOSTS` 加 `developer.amd.com.cn` + 注释留痕。**生效须Zen打 `deploy-ft-*` tag 触发 GitHub Actions 重部署 Worker** (deploy-ft-workers.yml, tag 触发权在Zen), 然后重启 Space 使 amd 推理走新白名单。
- **§13 遗留仍有效的部分**: 换 key 后临时 `NIM_PROBE_ENABLED=1` 一 boot 验证死/活, 此建议保留 (与本次根因无关, 是通用探活手段)。
- **教训 (写死)**: ① 排障先看**原始错误文本** (`host not allowed` 即 Worker 层签名), 别急着套历史签名模板; ② **枚举与推理路径分离**: 直连枚举 200 ≠ 过桥推理通, 排查 403 要按真实请求路径 (连接→proxy→Worker) 追; ③ 加白名单式改动的回归风险 = 绑定行为已改但白名单没跟上, 补绑定类改动须同步检查 egress 侧 ALLOWED_HOSTS。

## 2026-09-04 · FT_HEALTH_COOLDOWN 定一面 = 启用 (设 env=30) — 消 docs/HANDOFF 矛盾

- **背景 (矛盾)**: `docs/ft-health-aware-rotation.md` L5 声称"已落码启用(2026-08-23 Space 设 env=30 并 Restart)"; HANDOFF L150 / STATUS L800-802 / DECISIONS §9 三处一致"已落码待启用, 待Zen定推 Dataset + 真启用"。四文档分裂。
- **实证 (2026-09-04 boot 20260904-0413)**: ① 代码全落 — entrypoint.sh L272-273 `_ft_health` 门控 + FlareTunnel.go L2416 `--health-cooldown` flag + L1272 HealthCoolDown + L1422 isHealthy + L308/L322/L571 三处起桥命令传参; ② 二进制 30/30 worker 正常启动 (boot L31); ③ **boot 无法证明 env 是否设** — entrypoint L326 log 文案无条件写 "round-robin", FlareTunnel.go L1284 RotationMode 恒硬编码 "round-robin", HF API 不暴露私有 Space secrets 名。即: 代码就绪但启用状态无外部判据。
- **裁决 (2026-09-04 Zen定)**: **启用, Space 设 `FT_HEALTH_COOLDOWN=30`**。理由: 审计⑤确认是合理优化非过度设计 (对治慢根①死 worker 照轮打冷端); 默认关零风险 + 全健康时退化纯 RR 无性能损失; 40 worker 池健康感知是代理池社区标准做法。
- **生效前提 (Zen侧)**: ① 确认带 flag 的 flaretunnel 二进制已推 HF Dataset (build.sh 编译) + sync 到 `/logic/flaretunnel`; ② Space 设 env `FT_HEALTH_COOLDOWN=30` → Restart; ③ boot 验证法 — 手动 kill 一 worker 域名, 看健康感知轮转跳过它 (docs/ft-health-aware-rotation.md §四 验证方案)。
- **文档统一 (消矛盾)**: 一律定在"**已落码 + Zen裁决启用 (env=30)**", docs L5 "已落码启用"保留 (方向对), HANDOFF/STATUS/DECISIONS 从"待定"改为"已裁决启用"。确认 env 落位 + boot 实证 = Zen侧收尾。

## 2026-09-04 · deploy-ft-workers.yml PRESET 精简 = 折中·留防封应急类 (task #60, Zen定)

- **背景 (审计③)**: deploy-ft-workers.yml 661 行 + 9 PRESET 场景 (gen/first/daily/publish/solo:N/secrets/delete:1/delete:v/delete:o/reorg), 审计判"多为一次性建池操作, 日常只用 daily + secrets", 建议表 #4"精简 PRESET, 保留 daily/secrets" (低优先级)。
- **分界点 (2026-09-04 Zen裁折中)**: 直接字面删到只剩 daily/secrets 会砍掉**防封/运维应急一键工具** — `delete:1`/`delete:v` (Worker 被封立重设), `reorg` (拓扑收缩到 8-16 最优), `solo:N` (单账号排障) — 删 case 后虽可手动设 Variables 达成, 但应急从"一键"退化为"记 3-4 个变量名", 与 §1 防封主题抵触。
- **裁决 (折中·留防封应急类)**: **删 3 个纯一次性建池场景 `gen`/`first`/`publish`, 保留 7 场景** (`daily`/`solo:N`/`secrets`/`delete:1`/`delete:v`/`delete:o`/`reorg`)。删的 3 场景能力经 Variables 兜底 (case "" 分支原有): `GEN_NAMES=1` (生名), `PASS_MODE=2`+`DEPLOY_SCOPE=2` (首次双 pass 建), `PUBLISH_ONLY=1` (仅传 endpoint.json)。`gen-names` job / `publish-endpoints` job 保留 (if 条件仍认 gen_names/publish_only 输出)。
- **改动 (未推)**: ① `.github/workflows/deploy-ft-workers.yml` — case 删 3 分支 + description 更新 + 5 处错误提示/注释改指向变量兜底 (YAML 校验通过, 无残留引用); ② `docs/HANDOFF.md` — PRESET 场景表删 3 行 + 链序步骤 4-5 改变量兜底; ③ `ops/overengineering-audit-2026-09-02.md` — ③行/矩阵行/建议表#4/下一步 4 处标已实施。
- **生效前提**: 本改动只影响 workflow 代码 (非生产运行态), 提交 push nomn 即生效, 无需 boot 验证。下次建池 (扩 zone/首次) 时用 Variables `GEN_NAMES=1`/`PASS_MODE=2`/`PUBLISH_ONLY=1` 触发, 不再用 PRESET=gen/first/publish。

## 2026-09-04 · 备份处置 + SQLITE_CORRUPT 双 A 裁定 (Zen令, 审计 #62/#63)

- **背景**: Zen问"备份与 log 归档的目的是否过度设计" (审计 ops/overengineering-audit-2026-09-02.md), 搜索查证后Zen裁"两个 a" — 备份处置与 SQLITE_CORRUPT 各取案 A。

### ① 备份处置 = 案 A (激进停归档) — 已落码

- **审计证据链**: 归档 tar.gz 推新私库的**查错价值 ≈ 0** (7天窗老日志, 实际用不上), 且**自身曾损坏** — parts!=4 病根曾致零归档零删 (2026-08-01 令), 复杂度/收益比差。而真正查错源 = **Dataset save/ 日志** (30min 窗口内抓取, capture 全源) + **R2 全备份** (防配置丢失), 两者都必要 · 非过度。
- **裁决**: 停 7 天归档循环, 但**保留归档函数代码可回滚**。落点 = `dev/logic/omn_scheduler.py` `ARCHIVE_ENABLED` 默认 `"1"→"0"` (Space 设 `OMN_LOG_ARCHIVE=1` 可显式手动恢复; 不设则默认停)。挂 LOG_TO_DATASET 总闸下的 `_archive_loop` gate 因 ARCHIVE_ENABLED=0 早退, 不抢资源。
- **诚实权衡 (写死)**: 停归档 = save/ 日志无限增长, **100GB 私库硬限的缓解手段失效**。但按历史Zen已验证**归档从未真正生效过 (零 tar.gz)** 且 save/ 未爆, 权衡已被接受; 若未来 save/ 逼近 100GB 需另行治理 (本会话不越权处理)。_archive_loop/_do_archive (含 tarfile/tempfile/shutil import) 全保留 = 一键回滚。

### ② SQLITE_CORRUPT = 案 A (治标最轻: 可见性 + 调低周期) — 已落码

- **背景**: 生产 boot 多次复发 `database disk image is malformed` (审计 🚨 真问题, 非过度设计)。上游每 interval 跑 `runDbHealthCheck(autoRepair:true)` 但**结果静默** (core.ts 不打日志), 且在上游只读树 → 无可见性判断复发频率。
- **落点修正 (重要)**: Zen原审"在 entrypoint 给 runDbHealthCheck 加打印" —— 但 `runDbHealthCheck` 在上游只读 `core.ts`, entrypoint (sh) 加不了上游函数打印。修正 = 改走 **`/api/db/health` 路由探针** — 唯一能拿到健康诊断结果的可见入口 (management 路由, GET=诊断 autoRepair:false / POST=autoRepair:true, 须 manage scope key)。返回 `{isHealthy, issues, repairedCount, backupCreated, autoRepair, checkedAt, driver}`, issues 项 `{type, table?, description, count}`, `integrity_check_failed` 即物理损坏复发。
- **落码**: `dev/logic/omn_scheduler.py` 加 `_db_health_loop` daemon 线程 — 周期 GET `http://127.0.0.1:$OMNIROUTE_PORT/api/db/health` 带 Bearer `OMNIROUTE_API_KEY`, 解析 issues 打日志 → entrypoint tee → save/entrypoint/ 持久。gate: `OMNIROUTE_API_KEY` 空则 skip (缺 manage 凭证不抢资源), probe fail-open 不 raise。间隔 env `OMN_DB_HEALTH_INTERVAL_MS` 默 3600000 (1h)。
- **manage key 真名 (写死, 排障纠错)**: 真 manage key = **`OMNIROUTE_API_KEY`** (Space Secret → init L735-758 种进 DB apiKeys, Bearer 打 `/api/*` = 200 通)。**`OMN_MANAGE_TOKEN` 是 ops 误造名** (上游源码无此 env), 拿它打 `/api/*` 恒 403 `AUTH_001` — 见 ops/STATUS.md 2026-09-02 排障纠错。探针读 Space Secret `OMNIROUTE_API_KEY` (Zen既有 `~/.omn-secrets` 真值, 无需另造新 token)。
- **Zen侧生效前提**: ① 确认 Space 配 `OMNIROUTE_API_KEY` (未配则探针 skip 打提示); ② (可选) 调低上游周期 `OMNIROUTE_DB_HEALTHCHECK_INTERVAL_MS` 从默认 6h → 更频 (治标观测; 探针 1h 是独立观测通道, 两者不冲突)。
- **治标定位 (写死)**: 本方案**不是自愈** — 只做运行期物理损坏的**可见性观测** (探针 GET) + 拉近上游 autoRepair 周期 (调低 interval)。真正修复物理损坏的 quick_check/restore 策略已闭环于 e7b16b3 (本地非空也验损坏则丢弃强制 restore)。探针让"它又坏了"何时复发可见, 为将来治本 (周期重建库等) 提供观测依据。
- 出处: 生产 boot 20260904 + audit ops/overengineering-audit-2026-09-02.md 🚨 + 上游 core.ts (只读) + memory `manage-token-omn-manage-location-2026-08-21`。关联: §13 (amd 定谳), e7b16b3 (quick_check 落地)。
