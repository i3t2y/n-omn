# ops/STATUS.md · omn dev 部署态快照

> 每轮部署/验证后更新。SSOT = 本文件 + 对应 ops/incidents/ + audit/。生产态见 §1 禁触, 此处只记 dev。

## 2026-07-27 · 3.8.48 整体切换 (径 C 裁决) — ARG 改动已 push+sync+dev boot 三绿 (02:48Z) + ARG→Space 路径 runbook 入册, 待 gate 413 三防伪 + snapshot 多帧两笔补 → 24h 窗正式启 (起算两笔绿末时间戳)
圣上 2026-07-27 裁决走径 C: 整体切 3.8.48 base (上游真 release), 不构建新镜像 (GHCR 预构建已就绪), 仅改 BASE_IMAGE 切换。不翻 CLAUDE.md:23 (3.8.49 分支仍定点移植源池, 本次切 3.8.48 非 fork)。不用上游官方镜像三理由: 无 litestream / Hub 速率限制 / digest 钉锚统一 GHCR (入 DECISIONS). step -1 兼容性静态核毕 → 3.8.48 vs 3.8.43 互斥铁证表 (modelCapabilities 81 行含三新机制, modelContextOverrides/contextWindowResolver 0 行零改, modelSpecs 102 行含 GLM-5.2 authoritative 表) + 我侧 real_context=200000 消费链 getModelContextLimit 3.8.48:513-526 与 3.8.43:436-449 字节级一致 (Feature 5004 persisted override wins) + 新增迁移 9 件全清单 (113-122, 117_proxy_pool_rotation 破坏式但自带回填+我侧血统未用 proxy_assignments 表, 余 8 件累加无损). 出处: audit/2026-07-27-3.8.48-compat-static-audit.md.

### 切换机制实证修正 (2026-07-27 首演现形 + dev boot 反证成立定稿)
径 C 切换首演实证推翻旧前提 "改 Space Variable → Rebuild 切换": HF Space Variables 只注 runtime env, **不透 docker build --build-arg 通道**。圣上 nonoke/omn Rebuild 后 build log 仍 `FROM ghcr.io/i3t2y/omniroute-base:stable@sha256:9c9aecfd...` — `:stable` = Dockerfile 行 8 ARG 默认值原文 (非圣上改的 Variable 值 `:3.8.48@da99fac1...f408f`), Variable 未进 build 期。**切换权威开关 = Dockerfile ARG 默认值 (git 管理, commit 历史可查), 非 Space Variable**。旧 Variable 成死配置 (build 不读, bootstrap 不读即纯摆设)。径 C 精神不破: 仍不构建新镜像 + 仍 digest 钉锚; 回滚升级 `git revert` 该 commit + push + rebuild 即回 9c9aecfd (原回滚路径自带同 bug 一并修)。详见 DECISIONS "切换机制实证修正" 条 + Dockerfile 行 1-9 注释。

### dev boot 三绿实证 (2026-07-27 02:48Z, 移迁链动态印证 + 病根反证成立)
圣上手跑 commit `68ee550` (Dockerfile ARG 改) + push `747356b..68ee550 main -> main` → sync-space-nonoke.yml workflow run `30233008154` event=push auto-trigger conclusion=success → 同步 Dockerfile 到 dev nonoke/omn + 触 HF Rebuild → boot 02:48:44Z 全绿:
- **① 版本=3.8.48** ✓ 三铁证: `[entrypoint] 版本=3.8.48` + `[init] version: 3.8.48` + `[init] Status: healthy / 3.8.48` — 机制修正反证成立 (改 ARG 默认值即切, 病根诊断无悬念, 旧 `no build stage` build error 根除)
- **② real_context 读回=200000** ✓: `[init] per-model 200K override (real_context=200000)` + `override: 6 applied, 0 failed` + `POOL_STRATEGY=p2c REAL_CONTEXT=200000` — 静态核"persisted override wins 链字节级一致"动态印证
- **④ 25-key 探活+snapshot 基础全绿** ✓: probe `alive=7 dead=0` + `Keys: 7 registered, 0 skipped, 0 failed` + Resilience 读回 `RPM=245/244/21/300000` 全字段一致 + `HF Dataset uploaded.` + `[entrypoint] NIM init 已退出 rc=0`
- **移迁链动态印证**: 113-122 九件迁移 boot 时全跑 (`113_provider_node_icon_url` ... `122_free_proxy_sync_errors` 全 `Applied`, 含 `117_proxy_pool_rotation` 破坏式 + `119_model_capability_overrides` 新表) + `118 migration(s) applied successfully` 无中断 — 静态核"117 破坏式自带回填+我侧未用 proxy_assignments + 119 累加 CREATE TABLE"判与 dev 实态完全吻合
- **dev 侧 restore 空库启动 (非阻塞, prod 侧须验 R2)**: `[entrypoint] ⚠ restore 失败 rc=1 (空库启动)` + `database not found in config` — dev nonoke/omn R2 omn-data 无 3.8.48 历史 snapshot (新 bucket 首 boot), litestream restore 空走空库 + migration 重建表。dev 无持久数据须保正常, **prod 切前须盯 R2 restore 拉 omniroute-data 真库 — restore 失败即停 (数据丢失风险)**
- **K3 审计裁决入账 (2026-07-27, 04:55 boot 完整 log 复核)**: K3 (审计员 Kimi-K3) 复核圣上贴 04:55:18Z 完整 boot log 裁决:
  - **ERROR 定性修正 (原"litestream 启动竞态"措辞作废)**: ERROR = entrypoint 空库恢复分支**设计行为**, 非 litestream 故障 — litestream 04:55:46 初始化晚于 ERROR 04:55:40 整 6 秒, litestream 未在场无竞态可能。时序铁证推翻旧稿措辞。audit `2026-07-27-3.8.48-dev-snapshot-multiframe-landed.md §3` 已修正。
  - **04:55 boot snapshot 全链铁证追加**: txid 0x01→0x03→0x15→0x19→0x1a→0x1b 跨 ≥27 代 monotonic 递增, size 105383→182563 (+77180B 真 WAL), compaction L0/L1/L2 多级活动正常。audit §2.1 已落。
  - **异常 1 (05:01 时段 "真id" 测试流量混入, 排除验收外)**: 有客户端发送字面量"真id"作 model 名 → `Unable to determine provider for model '真id'` + HTTP400。非 3.8.48 回归, 标注为无效样本, **不纳入 24h 窗验收标准**, 防未来检索误判。
  - **异常 2 (05:07-05:08 opencode.ai Cloudflare Error 1010 触发 CB)**: 与 3.8.48 无关 (上游 provider 访问控制非本仓代码), 上游限制非本次升级回归。导致闸③ combo 池降级, combo 30min CB lockout 30min 设计容灾正常。
  - **24h 窗状态锁**: 起算冻 2026-07-27T05:31:55Z (笔2 绿末, txid 0x0f) / 出门 2026-07-28T05:31:55Z / 窗内监控标准 = 每 30min 验 evidence 新帧 txid 递增 + 零**新增** ERROR (§3 entrypoint 空库恢复分支 ERROR 不算阻, 仅"新增"≠恢复分支的 ERROR 才算阻)

### 版本断言软观察口子 (dev 阶段够, prod 切前补硬门)
dev boot 版本行括号 `版本=3.8.48 (期望未设置, 跳过比对)` — entrypoint 有版本比对机制但未武装 (EXPECTED_VERSION 未设), 版本被**观察**非被**断言**。dev 阶段人眼核够, prod 切换时补 `EXPECTED_VERSION=3.8.48` 变量让版本不符直接 boot 失败, 把"boot 三硬标"里的版本标从人眼核升级机器拦截。此列入 prod 切换前变量清单, 与 prod 侧其他设置一起下。

### dev/prod 隔离拓扑 (push 前已核, code-level 钉死)
- sync-space-nonoke.yml (dev): `push: branches: [main] paths: [Dockerfile]` 自动触 → 同步 Dockerfile 到 nonoke/omn + 触 HF Rebuild
- sync-space-nomke.yml (prod): **仅 `workflow_dispatch` (圣上显令点火, 无 push 触发)** — 行 18-19 铁证
- **判**: push Dockerfile 改 ARG 到 main → 仅 dev nonoke/omn 自动切 3.8.48, prod nomke/omn 仍 9c9aecfd 直到圣上 workflow_dispatch 显令。24h 隔离窗口有效, code-level 隔离非靠人守。prod 侧 rebuild 唯一触发源 = 圣上显令 workflow_dispatch。

### 切换执行序四步 (机制修正后)
1. **cg52 push** (等圣上 commit 令): Dockerfile 行 8 ARG 默认值 `:stable` → `ghcr.io/i3t2y/omniroute-base:3.8.48@sha256:da99fac1a697022a0529805294c58a10923fc1c758616f4f0b2ea8428b0f408f` + 行 1-3 注释修正 + DECISIONS + STATUS 同批
2. **dev 自动切**: push 到 main → sync-space-nonoke.yml 自动同步 dev nonoke/omn + 触 HF Rebuild (Factory rebuild); 圣上 nonoke/omn 补设 `R2_BUCKET=omn-data` (旧账并行, 与本次独立)
3. **dev 验收四点** (dev side): ① build log FROM 行 = `:3.8.48@sha256:da99fac1...f408f` (机制修正生效铁证) + 版本=3.8.48 ② real_context 读回=200000 ③ gate 1.5MB 413 实测 (三道防伪见 §剩两笔) ④ 25-key 探活全绿 + litestream snapshot 多帧持续; fetch-nonoke-logs 抓帧留证
4. **dev 24h 全绿 → 圣上 workflow_dispatch sync-space-nomke.yml** (prod 显令点火): 同步 prod nomke/omn (走 Space git remote 直推径, 见 §ARG→Space 路径 runbook) + 触 Rebuild; boot 三硬标 — 版本=3.8.48 (EXPECTED_VERSION=3.8.48 硬断言) / bucket=omniroute-data 不变 / snapshot complete; prod 侧 compaction/AccessDenied **无白名单, 见一即停**

### ARG→Space 路径 runbook (sync workflow 唯一径, prod 切换执行单)
ARG 改动进 HF Space 走 **Space git remote 直推** (非 web UI 手改, 有 commit 可查守 §3 SSOT 不悬空):
- **机制**: sync-space-*.yml workflow 跑时 `git init /tmp/hf-sync` → `cp Dockerfile bootstrap.sh README.md .gitattributes` (白名单四件) → `git commit -qm "sync: n-omn@<SHA>"` → `git remote add hf https://oauth2:${HF_TOKEN}@huggingface.co/spaces/<owner>/<space>` → `git push --force hf main`。Space git remote 直推带 commit 标签 `sync: n-omn@<sha>` 可回溯血统。
- **dev**: sync-space-nonoke.yml `push: paths:[Dockerfile]` auto-trigger → 走上径推 nonoke/omn (run `30233008154` 已证 success)
- **prod**: sync-space-nomke.yml `workflow_dispatch` (圣上显令点火) → 走同径推 nomke/omn (同血统, commit 可查)
- **两校验 (圣上切 nomke 前手核)**:
  - ① Space 侧 Dockerfile 与 git 仓根 ARG 行字字比对 (防 repo 与 Space 拷贝漂移): 圣上 HF Space nomke/omn → Files → Dockerfile ARG 行 vs git 仓根 `git show nomn/main:Dockerfile` ARG 行逐字对比, 应 `ghcr.io/i3t2y/omniroute-base:3.8.48@sha256:da99fac1a697022a0529805294c58a10923fc1c758616f4f0b2ea8428b0f408f`
  - ② web UI 手改禁用 — 切换必走 Space git remote 直推 (sync workflow), 不走 HF web UI 手改 (web 无 commit 破 §3 SSOT 悬空账)。dev 本次已实证走 sync workflow 非 web, prod 沿用

### 回滚底牌 (升级版)
- `git revert` 改 ARG 的 commit + push 到 main → sync-space-nonoke.yml 自动同步 dev 回 9c9aecfd; prod 须圣上再 workflow_dispatch sync-space-nomke.yml 显令回滚
- 若新迁移已跑过 prod 库, 连 DB 从切换前 litestream 快照一起恢复 (原回滚约束不变)

### 待办清单
- [ ] cg52 等 commit 令后提交本批 (Dockerfile ARG + 注释 + DECISIONS + STATUS 四件)
- [ ] cg52 push 到 main → sync-space-nonoke.yml 自动同步 dev nonoke/omn + 触 Rebuild
- [x] cg52 commit `68ee550` + push `747356b..68ee550 main -> main` (Dockerfile ARG + 注释 + DECISIONS + STATUS 四件定点替换/纯增)
- [x] sync-space-nonoke.yml auto-trigger run `30233008154` conclusion=success → 同步 dev nonoke/omn + 触 HF Rebuild
- [x] 圣上 nonoke/omn 补设 R2_BUCKET=omn-data (旧账落地, boot log bucket=omn-data 验)
- [x] dev 验收四点之 ① 版本=3.8.48 (三铁证) + ② real_context=200000 (override 6 applied) + ④ 25-key 探活 7 alive/7 registered/0 failed + Resilience 读回一致 + init rc=0 + snapshot 首帧 (HF Dataset uploaded)
- [x] 移迁链动态印证: 113-122 九件迁移全跑无中断 + 117 破坏式自带回填无报错 (静态核吻合)
- [ ] **剩两笔 (24h 钟正式走前置)**:
  - [ ] **笔1 gate 1.5MB 413 实测 (三道防伪闸全过才算绿)**:
    - 闸1 body 线上实超 1.5MB: JSON 封装有开销, 填充放 1.6+MB (单一 message content 塞重复字符), 别临界构造自以为超了其实没超
    - 闸2 413 必归属 gate: 看响应体错误格式/签名, 确认是 gate.js CTX_GUARD 发的 413 (含 `type:"context_length_exceeded"` 等签名), 非上游 provider 400/413 张冠李戴 (假象要防的)
    - 闸3 低于阈值放行是完整端到端回归: body 刚低于 1.5MB 的请求返正常上游响应 (证堤坝既没溃也没误伤), 两结果缺一不算绿
    - 路径: dev env 直通 (记忆 `dev env 直通闭环` ~/.omn-env-dev source 后 urllib POST)
  - [ ] **笔2 litestream snapshot 持续性核 (多帧语义)**:
    - 验收: boot 后至少两个不同时间戳的 snapshot 代数递增 + 日志零 litestream ERROR (单帧只证"能拍", 多帧才证"持续在拍")
    - 语义认清: 现产出迁移后快照, dev 无所谓; nomke 切换时回滚锚点 = 切换前**最后一帧快照** (113-122 一旦在 prod 跑过, 回滚须连 DB 一起还原)
    - 笔2 证快照链可信 → prod 切换前锚记动作才有意义
    - 路径: fetch-nonoke-logs.yml workflow 抓 boot 后多帧 (不只首帧)
- [ ] **24h 钟正式走 (上两笔最后证据时间戳起算)**: 起算钉两笔全绿末时间戳 (非 02:48Z boot), 两笔拖久窗顺延防观察期缩水; + 24h = 验收窗满
- [ ] **24h 出门标准 (钉死防窗满扯皮)**:
  - 验收四点全绿且证据入档 (含 413 三道防伪双铁证 + snapshot 多帧)
  - 日志面窗内零 ERROR、零 crash loop / 非预期重启
  - 25-key 周期探活持续全绿 (不只 boot 首探)
  - litestream snapshot 节奏正常、无断档
- [ ] **prod 切前 checklist (圣上下令切 prod 时三笔)**:
  - [ ] nomke/omn 此刻仍 3.8.43 且未 rebuild (dev/prod 隔离真实成立经验证据, 顺手验版本行即可)
  - [ ] nonoke/omn 死配置 BASE_IMAGE Variable 了断 (删或注明 ARG 默认值为唯一权威开关, 别留到 prod 切时误导操作)
  - [ ] nomke/omn 切前补设 EXPECTED_VERSION=3.8.48 (版本断言升硬门, 不符直接 boot 失败, prod 不留"期望未设置跳过比对"口子)
- [ ] 圣上 workflow_dispatch sync-space-nomke.yml 显令切 prod + 盯 R2 restore 拉 omniroute-data 真库 (restore 失败即停 数据丢失风险) + boot 三硬标验 (版本/bucket/snapshot) + prod 侧 compaction/AccessDenied 监控见一即停
- [ ] 回滚底牌预备: 切换前 litestream 快照锚记 (回滚连 DB 一起恢复)

## 2026-07-27 · 3.8.49 升级 Step -1 静态核毕 (互斥表已核正交 + 3 卡口锁径) — 裁决权归圣上, 未预设

> 圣上 2026-07-26 "搜索查证能升级 3.8.49 吗" 令 → cg52 Step -1 纯本地只读静态核毕, 未触 Space/未联网 (仅 GH API 验 release tag)/未触生产凭。互斥表 + 3 卡口双实证入 SSOT (DECISIONS 顶插 + audit 落盘)。

### Step -1 结论双实证
- **互斥核 — 3.8.49 三新机制与我侧血统五件全正交** (audit §6):
  - real_context=200000 override 走 `model_context_overrides` 表 (init:893), 3.8.49 该表/接口/消费函数体 getModelContextLimit 双版 diff rc=0 字节级零改, Feature 5004 注释双版同句 "persisted override wins over static catalog + models.dev sync" (modelCapabilities.ts:524 ≡ 3.8.43:447)
  - nvidia 不在 3.8.49 GLM-5.2 authoritative provider 6 map 中, 1M 静态表仅填 fallback 路径不触 (我 override `??` 之前 wins, 生产 effective=200K 不变)
  - gate.js #4 CTX guard (1.5MB 字节硬拦) 与 3.8.49 token 数机制正交, 无双重限制误杀
- **3 卡口锁执行径** (audit §11): ① 上游 GitHub 无 v3.8.49 tag (最高 v3.8.48, `git/refs/tags/v3.8.49` 404); ② 3.8.49 = fork release/v3.8.49 分支 ce80af6 非上游 release (CLAUDE.md:23 §1 至高 + audit/全维度 §1.5 锁 "基座 3.8.43 + 3.8.49 定点移植" "禁整体升 3.8.49"); ③ upstream_check.sh 取 /releases/latest 自动流最高只到 3.8.48 (3.8.49 不可触自动流, 整体切须手动 build)

### 4 升级径候选 (裁决权归圣上, 未预设)
1. **定点移植径 (守 §1)** — 欲拿 3.8.49 某 patch 走 dev/logic/** 五件 backport, 非切 base
2. **整体切 3.8.49 base (破 §1 基座钉锚)** — 须圣上明令改 CLAUDE.md:23 + DECISIONS (新裁决覆盖旧锚), 手动 build :3.8.49 fork digest 钉版
3. **整体切 3.8.48 base (守自动流)** — 上游真 release, da99fac1 已就绪, 须 3.8.48 vs 3.8.43 互斥重核 + Step 0 dev 24h
4. **不升级 (互斥表归档)** — 现 nomke 25-key 九段绿 rc=0 稳, 升级非必项

### 待办 (Step -1 后, 阻塞于裁决令)
- ⏳ 圣上裁决 4 径中哪条 (或新径) — audit §1.5 "禁整体升 3.8.49" 翻案须明令
- (若选径1) cg52 出 3.8.49 backport 适用候选清单 (#6524 max_token override / GLM-5.2 1M authoritative / 等)
- (若选径2/3) K3 Step 0 dev nonoke/omn 24h 实证四点 (real_context 读回 / gate 1.5MB 拦 / 25-key 探活 / litestream snapshot)
- 出处: audit/2026-07-27-3.8.49-compat-static-audit.md §6/§11/§12 + DECISIONS 2026-07-27 条

## 2026-07-26 · Phase 2 切流链六步全闭环 (变量切换径, 零 Rebuild) — production nomke/omn 现跑 dev logic 4.3.2

> 圣上 7-26 钉死: nomke boot 跑 dev logic 升级态 4.3.2, 无须重建。切流走**变量切换径** (非骨架重推 Rebuild 径), 15:23Z nomke boot 坐实生产切流后态。

### 切流链六步终态 (production 稳态)
- ① **git SSOT** ✅ — workflow 六件制 + litestream.yml 参数化 + DECISIONS/STATUS/saga 全推远端 (commit `5d78728`, force push `--force-with-lease` 覆盖远端 c5df91b web UI 链; 反向键证六件 sha 全 == 本地)
- ② **BASE_IMAGE 钉锚** ✅ — digest `9c9aecf` 设而无须 Rebuild 触发 (dev logic 4.3.2 赑 dev/logic/** Dataset 注入, 不依赖新镜像; Variable 6h 前 Updated)
- ③ **Dispatch Skeleton 跳** ✅ — 圣上钉死 boot 已跑 4.3.2, ③④均免
- ④ **Rebuild 跳** ✅ — 零 Rebuild 数据清零事件, R2 可恢复先证铁律无涉 (非 first-init 路径)
- ⑤ **R2_BUCKET omn-data→omniroute-data** ✅ — 变量切换落 production 桶 (圣上 3h 前设, 跳过步⑤ nominal)
- ⑥ **Restart** ✅ — 15:23Z nomke boot 九段全绿 rc=0 (见下铁证段)

### 切流治理径定谳
切流走**变量切换径** (production Space identity 不变 + dev/logic/** 已经 Sync 至 nomke/omn-logic Dataset + bootstrap 拉 dev logic 升级态注入 production Space runtime + R2 bucket 切生产桶 omniroute-data), **非骨架重推 Rebuild 径**。nomke/omn 跑 dev logic 4.3.2 血统 = 我 push dev/logic/** 已 Sync 至 nomke/omn-logic, bootstrap atomic --revision 锁拉注入, production Space runtime 升级态。

### 双事故根治铁证落地 (15:23Z boot 实印)
- **事故一 403 断供根治**: `bucket=omniroute-data` = prod R2 key 有权生产桶 → compaction complete txid=0x2d size=237949 平稳写入 (403 死链已绝)
- **事故二 YAML 损坏根治**: git SSOT `bucket: ${R2_BUCKET}` (litestream.yml 真态 git 出货非 web 手编排) 正确解析 → litestream 进程 15:23:51 启 PID=699 + L1/L2/L3/L9 compaction monitor 全启 (进程未崩退/apimachinery 链路通)

### 切流尾剩待 (非卡点, 战后/监控)
1. **compaction txid gap 疡自愈监控**: 15:23Z 仍现 `detected db behind replica db=0x0 replica=0x2c` → `fetched L0 0x2c` → `max_l1_txid=0x2d` 新链扫地。疤疤摸一次非病 (前会话裸删留疤自愈中), 须盯下次 boot compaction 是否续号接连续号无新断档, gap 合规判到位。
2. **LITESTREAM_STRICT=1 下次 Restart 才全生效**: 15:23Z boot litestream 启成功 PID=699 进程活, STRICT=1 路径仅在 litestream crash/exit 非 0 时触 `_shutdown; exit 1` (entrypoint.sh:278-284)。下次 Space 重启判:
   - litestream 正常启 = STRICT 路径不触, production 仍跑 (fail-早仅在 litestream 真崩退时 apply)
   - litestream 崩退 = graceful exit 1 boot 死, 显红胜静默死
   - **容错边界 (DECISIONS 已记)**: R2 偶发 503/网络抖触 litestream 退出 = Space 重启循环风险, 须配合 R2 稳定性 + 监控告警
3. **战后矩阵补验**: matrix 四笔 (③matrix 四 combo) 单 prod 写态跑 + 24h compaction ERROR 计数 + 新桶 omniroute-data 持续 snapshot 生成核 (切流后挂载验证, ③ 后白捡的基线无涉)

## 2026-07-26 · 切流执行期两事故闭环 + workflow 六件制落地 + litestream.yml 桶名参数化 (web 手改回 git)

> 承接 Phase 2 冻结令解 (compaction 疡定谳不阻切流)。切流链步2-6 执行期 nomke/omn 生产侧连发两起事故, 均圣上 HF web 手动修复 (cg52 瘫痪期旁观)。本日工作 = 改动落回 git 恢复"仓=SSOT"。

### 事故时间线 (nomke/omn 生产侧, 圣上 web 手动全程)
- **12:13Z boot #1 — prod 403 断供**: `dev/logic/litestream.yml:5` 桶名硬写 `omn-data` (dev 桶) 随 logic 平铺机制越界进入 prod Space → prod R2 key (`HF_TOKEN_NOMKE` 所属) 对 dev 桶无写权 → litestream 每次 S3 PUT/POST `403 AccessDenied` → **备份链断供** (replicate 死, 不写新 WAL)。cg52 经网关调模型失败 → 旁观。根 = 命名空间越界 (prod key 写 dev 桶)。
- **12:13Z~12:53Z — cg52 瘫痪**: prod 应用层挂期间无法经网关调模型 → 全部修复权属圣上 HF web 手动。
- **12:53Z boot #2 — web 手改 YAML 损坏**: 圣上 web 手改 Dataset 内 `litestream.yml` 做桶名参数化意图 → YAML line 9 结构损坏 → litestream 进程读 `-config` 解析崩退 → litestream **进程退出** (无复制无本地库 handle)。非 code 病非 env 病, 是 web 手编辑无 yaml lint。nomke/omn 进一步瘫痪。
- **12:53Z~恢复 — 圣上 web 手修**: 修 YAML 结构 + 桶名参数化定态 → nomke/omn 接单恢复。
- **本日 (切流后改回 git)**: dev/logic/litestream.yml 参数化 + workflow 六件制改名/新增, 恢复 "仓 = SSOT"。

### 本日 git 落地 (改动未 commit, 待圣上批后推)
- **dev/logic/litestream.yml**: 单行 `bucket: omn-data` → `bucket: ${R2_BUCKET}` (litestream v0.5.9 内建 `${VAR}` envsubst, logic 层环境无关根治)
- **workflow 六件制** (`.github/workflows/`):
  - git mv `fetch-space-logs.yml` → `fetch-nonoke-logs.yml` (dev, 内容三改: name 加角色缀 + 顶部注释补改名出处 + commit msg 出处行)
  - git mv `sync-logic-dev.yml` → `sync-logic-nonoke.yml` (dev, paths 自引用改名)
  - git mv `sync-space-skeleton.yml` → `sync-space-nonoke.yml` (dev, 去 matrix 单投 nonoke/omn, 直引 HF_TOKEN_NONOKE)
  - 新增 `fetch-nomke-logs.yml` (prod, 克隆自 dev 版 + 5 处差异: SPACE=nomke/omn + HF_TOKEN_NOMKE + logs/nomke--omn 卷 + cron 错峰 07/37 + 健康指纹摘要步)
  - 新增 `sync-logic-nomke.yml` (prod nomke/omn-logic, HF_TOKEN_NOMKE, 仅 workflow_dispatch)
  - 新增 `sync-space-nomke.yml` (prod nomke/omn, HF_TOKEN_NOMKE, 仅 workflow_dispatch 无 push 触发)
  - 命名空间隔离实证: `*-nomke.yml` 零 `nonoke/omn`/`HF_TOKEN_NONOKE` 字面, `*-nonoke.yml` 零 `nomke`/`HF_TOKEN_NOMKE` 字面 (grep 字面零命中)
  - yaml 解析全六件 OK

### DECISIONS 入册 (4+1 条同案, 参见 DECISIONS.md 顶)
- (a) R2 桶名参数化 `${R2_BUCKET}` (logic 层环境无关)
- (b) workflow 六件命名规约 (`*-nonoke`=dev / `*-nomke`=prod, prod 三件仅 `workflow_dispatch`)
- (c) HF_TOKEN 命名空间隔离 (NONOKE/NOMKE 双 token, 爆炸半径各半)
- (d) LITESTREAM_STRICT=1 已裁落地 (圣上 7-26 批 prod fail-早; entrypoint.sh:278-284 主循环探 LS_PID 亡 → exit 1 graceful 收尾 boot 死; 零代码改纯 env 0→1)
- 变量血统核实: `LOGIC_BUCKET_REPO` (bootstrap 拉逻辑层唯一真消费) + `OMN_DATASET_REPO` (init upload_folder 回写) 互为别名同一 logic Dataset 根; `HF_DATASET_REPO` 死名零消费划除。prod 两名同赋 `nomke/omn-logic`, dev 同赋 `nonoke/omn-logic`。
- 四死名 Variable 划除 (圣上 Space web 侧删, 我核消费点证死名): `NIM_RPM` / `NIM_PROBE` / `NIM_FREE_CONCURRENT` / `NIM_SCALE_WITH_KEYS` (现役 bootstrap/entrypoint/dev/logic 零真消费; worktree 残留引用非现役血统)

### 环境变更记录 (只记不执行, 圣上 web 手通)
- **nomke/omn 已设/应设**: `R2_BUCKET=omniroute-data` (Variable) + `OMN_DATASET_REPO=nomke/omn-logic` + `LITESTREAM_STRICT=1` (圣上 7-26 设)
- **nomke/omn 已删四死名 V**: `NIM_RPM` / `NIM_PROBE` / `NIM_FREE_CONCURRENT` / `NIM_SCALE_WITH_KEYS` (圣上 7-26 删)
- **nonoke/omn 应设 (litestream 参数化前置)**: `R2_BUCKET=omn-data` — **须 sync logic 前先设** (否则 dev 端 env 缺得不扩致 R2 拒)

### 2026-07-26 15:23Z nomke 生产 boot 铁证 (git SSOT 切流链步 ① 通)
- **bootstrap**: 同步 Dataset `nomke/omn-logic` revision=`2b03a1992693` atomic 锁拉 (我 force push d66deb1 后远端 HEAD, 非圣上 web UI 中介态 = git SSOT 真生效)
- **litestream**: `replicating to bucket=omniroute-data` (事故一根治: prod key 有权生产桶) + compaction monitor L1/L2/L3/L9 全启 + `compaction complete level=1 txid=0x2d size=237949` (事故二根治: YAML 解析通 litestream 进程未崩退, 退出且正常跑 compaction)
- **compaction txid gap 疡自愈推进**: `15:23:52 detected database behind replica db=0x0 replica=0x2c` → `fetched L0 file 0x2c` → `15:24:04 l0 retention deleted_count=4 max_l1_txid=0x2d` 新链扫地 (疤疤摸一次非病, 前会话裸删留疤自愈中)
- **九段全绿**: bootstrap 环境补全 ~60s (镜像 A 模式缺 python3/curl/jq/sqlite3/huggingface_hub, 自愈设计非病) + OR Next.js Ready 20128 (heap 4096) + R2 `已从恢复`✅ + init probe 25 key 全 200 alive + **25 registered 0 skipped 0 failed** + Resilience 读回 `300/75/200/300000` (concurrent=75=25×3 推导) + combo upsert PUT 两 200 (nim-pool + nim-codex) + override 6 applied + HF Dataset uploaded + **init rc=0**
- **意向池 6 模型全绿**: glm-5.2/deepseek-v4-flash/deepseek-v4-pro/nemotron-3-super-120b/mistral-small-4-119b/gemma-4-31b (圣上剔挂模型后纯净池)
- **LITESTREAM_STRICT 此 boot 未触** (15:23:51 litestream 启 PID=699 进程活, STRICT=1 路径仅 litestream 退出才触 exit 1; 圣上建 V 时点 boot 已过 15:23, 下次 Restart STRICT 路径才全生效)

### saga 续写
- `ops/incidents/2026-07-25-task-e-model-prune-saga.md` §8.3 续写切流两事故 + 修复时间线 + 根因闭环 + 教训四条。

### 待办 (force push 已落 nomn, 切流链推进中)
- [x] 本批六件 workflow + litestream.yml + DECISIONS/STATUS/saga 一并 commit + **force push nomn 落定** (commit `d66deb1`, 圣上"以你的为准"令 + `--force-with-lease` 覆盖远端 c5df91b web UI 链, 反向键证六件 sha 全 == 本地)
- [x] LITESTREAM_STRICT 裁决 = 1 (圣上 7-26 批 prod fail-早, Space Variable 已设)
- [x] 四死名 Variable 划除 (圣上 Space web 删)
- [ ] nonoke/omn 设 `R2_BUCKET=omn-data` Variable (圣上 web, sync logic 前置, dev 侧切流时)
- [ ] 切流链步 ②-⑥ 推进 (② BASE_IMAGE 锚定 digest 9c9aecf → ③ Dispatch Skeleton → ④ Rebuild → ⑤ 变量切换 omn-data→omniroute-data → ⑥ Restart), 待圣上令

## 2026-07-26 · sync 真态实证 + admin 404 实证落地 + ③④按圣令跳过

> 承接 K3 裁 "账册补齐三印" 序。①②⑤ cg52 实证升格落地, ③④结构性不可执行按圣令跳过。

### ①sync-logic-dev 链真态 — 推测升实证 (gh run list via git credential)
- **run #30164340629** | head=`968b1a1` (Task E 主剔 7f39a25 第一父) | **success** | event=push | 创建 2026-07-25T**15:48:05Z** → 完成 15:48:24Z
- run #30155204189 | head=`9fe67be` | success | push | 2026-07-25T10:51:14Z
- **步骤级绿**: `Upload logic files to Dataset (5 files)` ✅ + `Verify sha256 readback (逐字节血缘验证)` ✅ — 即 workflow :46-66 sha256 cmp 步骤绿, 5 件 dev/logic** 与 Dataset nonoke/omn-logic 逐字节等
- 假说分家: ①push自动触绿实证 (event=push 非 dispatch, conclusion=success 非失败); ②圣上手动 dispatch / ③sync失败后手改 Dataset 两假说排除
- 时序: sync **15:48Z绿** → boot 16:25Z拉, boot 拉的是 sync 后 Dataset 终点货. 链通.

### ②admin /admin 404 行为实证落地 (boot回显 ↔ 行为双向闭合)
- Space runtime `stage=RUNNING` (HF API 元数据, hw=cpu-basic)
- /admin → **HTTP 404** | /api/providers → **HTTP 404** (gate.js:24 `GATE_ADMIN_ENABLED!=='1'` 路径, fail-closed 纯 /v1/* API 模式)
- /healthz → 200 `{"ok":true}` | /v1/models 无PSK → 401 unauthorized | 带PSK → 200 model list
- **gate.js:64 `admin UI: disabled` 软件回显态 ⟺ /admin 404 行为实证 等价证成立**, K3 裁 "②admin 404 补扎" 印收

### ③④按圣令跳过 — 双 Space 共用同批 NIM key 冲撞
- 探 `/v1/chat/completions` model=`z-ai/glm-5.2` → `No active credentials for provider: z-ai` 真态暴露
- **圣上裁真因 (钉死)**: 两 Space (nomke/omn 生产 + nonoke/omn dev) **共用同一批 NIM keys**, nonoke 多 8 key; **cg52 自身即通过 nomke 生产 glm-5.2 跑** — 在 nonoke dev 再发用同 batch key → 占额度冲撞 → 报错
- 处置: ③matrix 四 combo / ④C1 归因**按圣令跳过**, 非卡顿未解是真结构性不可执行, matrix 实测留切流后 (单 Space 写态) 补验
- 主链九段全绿 + 五处剔令注释化 + override 6 applied (boot#3/4 8/9 数缩即剔除生效) 作晋级判据

### incidents 新档
- `ops/incidents/2026-07-25-task-e-model-prune-saga.md` 七段式回填: §1病历(boot matrix) §2五处落点 §3漏网补剔 §4sync真态 §5probe缺位认知 §6C1前置闸 §6.5③④停测真因

### 遣憾未闭 (待圣上) → b6fa1bb 闭环 (7-25 17:43Z)
- ✅ **圣上推 b6fa1bb Task E 漏网补剔**: `968b1a1..b6fa1bb main -> main` → 触 sync run #30168186734 (success @17:43Z, 步骤级 8 步全绿含 upload+sha256 readback 双核心步) → Dataset 侧 init sha256 等 8e67fc4e38d0 逐字节等, 行 94 llama 注释痕真态落 Dataset → **init_vars.json 快照 llama 残影说谎病根治**, b6fa1bb commit "Restart 前置闸两证"全收 (sync 绿证 + Dataset readback 含注释痕)
### bootstrap 硬化案 — `hf download` 钉 revision 竞速根除 (K3 7-26 准推)
**病链**: bootstrap.sh:49 `hf download` 无 `--revision` → main HEAD resolve → 内容取决于 boot 时刻 vs sync push 完成时刻竞速 + HF resolve 缓存浮动. boot#4 15:30Z 拉出 8 员旧池 (sync 15:48Z 迟 18min 抢跑旧 HEAD) 即此病.

**治法**: bootstrap.sh 拉取前先经 `HfApi().list_repo_commits()` 取 Dataset HEAD commit_id, 该 id 作 `--revision` 参数喂 hf download → 锁定 atomic 同 commit 全件拉取, 竞速根除. 取 HEAD 失败 fail-open (空 rev → main HEAD 兼),  静默 log WARN 不阻塞 boot.

**patch 落地**: `bootstrap.sh :42-85` 段 (旧 :42-58 扩为前置 resolve revision 段 + _dl 内嵌 _rev_arg) `sh -n PASS`.

**验证 (本机 atomic lock 真拉)**:
- HEAD commit_id `995f3e656e6e` (= sync-logic-dev workflow upload 步产物 commit)
- `hf download --revision 995f3e656e6e...`: init sha256 `8e67fc4e38d0` == 本地 == 前回 readback 逐字节等 ✅, entrypoint `05e0dc29d712` / gate.js `c00a3aba1b0e` 同 atomic 拉到 ✓
- 行94 注释痕 `# "meta/llama-3.3-70b-instruct" # 2026-07-25 Task E 漏网补剔...` 真态落 Dataset ✅

**待落**: ①git add/commit bootstrap.sh — ②推触发 (旧 sync 触发是为 dev/logic/**, bootstrap 在根不入此 path, 不触 sync; 但可走 push 触 Bootstrap 镜像须知) — 待圣上批

### 5e5d9eb bootstrap dash 崩 → printf 热修 (7-26 01:45Z Space crashloop P0)
- **崩**: 5e5d9eb 推后 Space 01:45Z boot 真跑即崩 `/bootstrap.sh: 65: Bad substitution` → crashloop. 根 = bootstrap.sh:65 我引入 bash-only `${_rev:0:12}` 截取, Space `/bin/sh`=dash 不支持 → `set -e` 杀 boot.
- **我疏漏**: `sh -n` 仅语法核不捕运行时 expansion 崩, 编辑期未 `dash -c` 真验 expansion → bash-ism 漏过闸. §1 根件=生产血统即此.
- **热修**: `${_rev:0:12}` → `$(printf %.12s "$_rev")` (POSIX dash 兼), +1-1 单点. bash-ism 全文扫净 + dash 实跑 `_rev` 解析段双路 (成功截 12 字符 + 空路回退) 均退 0.
- **教训 (入 DECISIONS)**: 根件 (`#!/bin/sh`) 改动须三闸 — ①`sh -n` ②dash 实跑 expansion 段 ③bash-ism grep 全扫. 缺一不可.
- **推送**: 热修 + saga §7 入档 + 本段同车 commit, 待圣上 push nomn main + Restart 验 boot 通解 crashloop.

## 2026-07-25 (本轮) · 切换 ② boot 前固化批 + CLAUDE.md v3 — 待圣上 Restart
### CLAUDE.md v3 (圣上签发, 工作宪法修订)
- §0 生命周期: 会话开始读 HANDOFF+STATUS+DECISIONS; 翻案须 Supreme 明令; 改码只 diff 禁整文件重写
- **§1 拓扑铁律修订: n-omn 私库=唯一血统; 根目录=生产血统; `dev/logic/`=dev逻辑层镜像; `dev/base/`=基镜像; ops/=运营层永不进 Space. ✅ 本轮 git mv omn-logic→dev/logic 收敛; Dataset repo 名 `nonoke/omn-logic` 不变. ⚠ omn-v2 第三个 Space 撤销(2026-07-25): HF 免费层关闭新建 Docker Space 通道, 复用现役 nomke/omn + nonoke/omn 两 Space, 全程不再新建; nonoke/omn 晋级生产仅变量切换+Restart 零净室首跑(详见 DECISIONS 新拓扑条)**
- §4 健康=九段+rc=0 入宪法; §6 gate 180000 入宪法

### 切换 ② boot 前固化批 (K3 令六项并②前三件, 本轮落地)
- **probe 000 重试小修**: dev/logic/init-nim-keys.sh `probe_nim_keys_real` 000 分支单发→重试一次 (-m 30); 二次 403→AUTH_DEAD / 200/429→alive / 仍000→fail-open alive; bash -n 过 + case 合验
- **push Dataset MATCH**: 远端 init = `a1640dd5` (probe 修源态入远端, byte-for-byte 验)
- **三样固化**: release-checklist B3 具体化 + M 段 (20129/双层盘点/24h风暴计数); DECISIONS 三行 (gate超时180000/阈值不动/20129迁移日); HANDOFF.md 新建 (watcher 风暴特征串)
- 本轮 commit: `1159de6` (probe 修源 + 三样固化合一)

### 待圣上 boot 时 (② 启动门 六项, 圣上手动)
1. Space Variable 加 `GATE_UPSTREAM_TIMEOUT_MS=180000` (Variable, 与换 key 同次 Restart 生效)
2. Secret `NIM_KEYS` 换 25 行; 3. `GATE_ADMIN_ENABLED`=0 (单布尔开关); 4. Restart dev Space
(注: probe 修源已 push Dataset = `a1640dd5`, bootstrap 拉新件即含重试态)

### boot 后验 (cg52 四项 + 裁决五第五项)
- **boot #1 (2026-07-25 11:02) 全绿**: 九段全执行 + init rc=0 + Resilience 读回 `300/200/96/300000` (32 key 触 cap 300 首次实证, concurrent=96=32×3 缩放验讫) + probe 32 活 0 死 + M7 180000/heap 4096 读回层面坐实 + 付费墙零触发
- **boot #2 (2026-07-25 11:22) 全绿 = 幂等复现 + admin 404 双验**: 九段全执行 + init rc=0 + Resilience 读回 `300/200/96/300000` 与 boot #1 一字不差 (写路径稳定非首 boot 偶中) + probe 32 活 0 死 + `[gate] admin UI: disabled` (GATE_ADMIN_ENABLED=0 裁决二坐实) + bootstrap 自愈补 python3/curl/jq/sqlite3/huggingface_hub 约 60s 复跑 (裁决四设计认账, 每次重跑不持久化) → 退出标准 [2 次干净 boot] ✅
- **key 池基线 = 32 (非预案 25, 圣上裁决 32 是地面真值照准)**: 见 DECISIONS "② key 池基线 32" 条 + incidents 32 偏差裁决节
- **✅ 长思考一笔 (B3 + GATE_UPSTREAM_TIMEOUT_MS=180000 生效铁证)**: glm-5.2 SSE 真流式 (首 token 2.1s, 全 4.2s, 34 chunks 真流增量) + gpt-oss-120b 3.8s 收 `: omniroute-keepalive` SSE 注释行 = gate 主动 keepalive 维持长连接 (若 gate socket 默 30s 切, 应在 ~30s 收 502/504 错包, 实测两发均 urllib 自超 TimeoutError 无错包 = 不在 30s 切). boot 日志无 GATE_UPSTREAM echo 行, 但行为证据闭环, 不再追究
- **✗ 请求矩阵四笔 (B4 裁决五第五项缺口)**: nim-pool 笔1 200 (2.2s, nemotron-3-super-120b) ✅ / nim-pool 笔2 超时 101s (p2c 命中挂模型) / nim-codex 笔1 超时 101s (priority 钉首模型挂则无 fallback)。直模型对照: glm-5.2 200 (2.1s) / deepseek-v4-flash 200 (11.6s) / gpt-oss-120b 超时 (90s/200s) / llama-3.3-70b 超时 (47s/120s)。**根因非 combo 路由病非网病非 gate 切, 是池成分病—gpt-oss-120b + llama-3.3-70b 上游挂/极慢, probe 探活只测 glm-5.2 无 init 期感知, pool p2c 25% 染慢 codex priority 100% 掉**。达成路径 = 圣上从 8 模型意向池剔除两挂模型 → cg52 复跑 matrix 到 double-green
- **429 基线改挂③ (裁决三不开后台不读库)**: 钉 3 纪律刚执行不为一条基线重开 admin。③ 变量切换 R2→生产 bucket 时 litestream 同一 storage.sqlite (含 dev 期 32 key 全 call_logs) 复制到 omniroute-data → 切换后从生产侧只读副本跑一次 status_code 分桶 = dev 期基线白捡, 一行 SQL 的事。原"生产限流档裁决"改挂: 429 基线 + ③ 后 24h 风暴特征串计数 = 0 两项齐后落 DECISIONS
- ② 加速版退出六绿: 2 次干净 boot ✅ + 长思考 ✅ + 矩阵全绿 (圣上剔挂模型后 ⏳) + 过夜一轮 ⏳ + 429 改挂③ + 池成分健康 (B4 第五项)

---

## 2026-07-25 07:09 · C2 闭环 + 九段终验 — dev 全绿
- **Space**: nonoke/omn (HF dev, v4.3.2 init, 3.8.43 基座, 7 NIM key)
- **远端 Dataset**: nonoke/omn-logic
  - init-nim-keys.sh: `2832f694` (本轮 C2 修源态)
  - entrypoint.sh: `05e0dc29`
  - gate.js: `c00a3aba`
  - litestream.yml: `1563c08d`
  - package.json: `5ed9981b`
- **本地 HEAD**: b662bd1 (C2 commit) — task5 五件 9d5f42e / #4 OOM 9e2319e 已并入
- **Boot 实证**: 7 registered → gc_stale(无待删) → Provider IDs 7 → Resilience 245/21/244/300000 读回一致 → combo upsert PUT 200 两件 → override 8 applied → hf_snapshot uploaded → **init rc=0**
- **R2**: ✓ 已从 R2 恢复 (副本健康, 非本轮关注)
- **M1 限流**: RPM=245 concurrent=21 interval=244ms (alive=7, per_key 35/3)
- **gate**: listening 0.0.0.0:7860 → 127.0.0.1:20128, CTX guard 1.5MB 阈就位

## 切换五步序列态 (C2 落地后)
- ① **清空** ✅ (本轮 C2 闭环即第一步清空)
- ② dev 换 32 key 稳态浸泡 — ★boot #1(11:02) + boot #2(11:22, 幂等+admin 404)双绿 + 长思考一笔✅ + 429 改挂③✅, 剩三件: ①圣上从 8 模型意向池剔 gpt-oss-120b/llama-3.3-70b → cg52 matrix 复跑四笔到双 combo 绿 ✅→ ②过夜观察(明早收: 无 OOM/重启循+litestream txid 推+成功率无塌) ③圣上手动链 HF_TOKEN_NONOKE→push→sync-logic-dev 首跑绿→BASE_IMAGE Variable 钉锚→dispatch 骨架→Rebuild FROM=9c9aecf
- ③ nonoke/omn 晋级生产: 变量切换 R2→生产 bucket omniroute-data + GATE_ADMIN 按生产纪律 + Restart, 零建新 Space 零 Rebuild
- ④ restore 生产副本验证数据连续
- ⑤ 金丝雀放量, 旧 nomke 冻结一周

## 待办
- [ ] ② 退出三件: 圣上剔 gpt-oss-120b/llama-3.3-70b → cg52 matrix 复跑四笔双 combo 绿 + 过夜观察一轮 + 圣上手动链 (HF_TOKEN_NONOKE/push/sync-logic-dev/BASE_IMAGE 钉锚/dispatch 骨架/Rebuild FROM=9c9aecf)
- [ ] CI 侧: fetch-space-logs.yml 首跑绿 (push 后圣上手动 dispatch run — 验: evidence 分支出快照 + secret-scan 闸已执行 + 内容确为 boot/run 日志); 与 P0-tee 互补 (P0-tee=容器内持久落盘战后, 本通道=HF 可见窗口仓内归档现), 走当前执行流非战后队列
- [ ] 战后建设队列: 每模型 probe (init 探活扩展到池内全模型, 与 P0-tee 同批) — 现 probe 只测 glm-5.2 单模型, 挂模型 init 期无感知 (② 行为暴露)
- [ ] ③ 后: 429 基线 (从生产 bucket omniroute-data 只读副本一行 SQL 分桶) + 24h 风暴特征串计数 = 0 → 落 DECISIONS "生产限流档裁决"
- [x] 全文件排查同类 jq/grep 空输入 pipeline(痛点1根治) — 2026-07-26 实测净: 存货=0 (init-nim-keys.sh 已修地雷唯一 jq@tsv 行159-178 set+eo抬门+${:-[]}兜底; 其余 models_to_json/:108/_is_valid_strat 三调用处全 || 兜底; merge_files.py 废弃不达标)
- [ ] audit/2026-07-25-k3-架构调整总览.md + docs/k3* 三 untracked commit 入档待判
- [x] fetch-logs 补丁三 commit + push (.github/workflows/fetch-space-logs.yml +9/-8, Checkout 步移 job 首) + 圣上 dispatch 验三硬标 ✅ — run 绿 (dispatch da0cf23, commit 9d06883 evidence 分支落地 1 file +1184) + 文件头 Application Startup at 07:45:40 真日志 + grep compaction 收 07:46-08:13 持续 ERROR 实录入证袋. 通道端到端 §8 闭环.
- [x] R2 鉴别器 Space 侧三子读锁案分道 ✅ (圣上 7-26 定谳三答归一): dbs.path 漂移假说推翻 (路径铁证全同) + compaction txid gap 真根 = **昨晚 cg52 首测裸删 R2 备份留疤** (0x10+0x2c 两代残件断档 28 txid) — 非故障自愈中 (08:00:01 snapshot 0x32 重建链 + retention 到期清旧残件 + 切桶零迁移), 不阻切流. cg52 四铁证独立对账: 行1121 snapshot 0x32 size=267503 + 57 次 compaction ERROR 一字未差 + 时序 57×30s=28.5min 数学对齐
- [x] Phase 2 冻结令解 ✅ — compaction 疡定谳不阻切流 (圣上 7-26 令), 切流链即刻启: ① HF_TOKEN → ② BASE_IMAGE 锚定 → ③ Dispatch Skeleton → ④ Rebuild → ⑤ 变量切换 (bucket omn-data → omniroute-data) → ⑥ Restart. 切流后验证: matrix (单 space 写模式) + 盯新桶 snapshot 持续生成 + 确认新桶 compaction 报错零出现
- [ ] DECISIONS 护栏条入册: 删 R2 备份 = 断代级破坏操作 (禁裸删 litestream 路径, 仅 test 前缀 或 删前书面确认本地库可弃) — 本批同 commit 入
