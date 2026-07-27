# DECISIONS.md · omn 锁定决策日志

> 每项不可逆/影响后续工作流方向的决策追加一行。变更须 Supreme 批准。
> 格式: 日期 · 决策标题: 内容简述。(出处指向对应 ops/incidents/ 或 audit/)

## 2026-07-27 · 整体切 3.8.48 裁决 (径 C): 守自动流, GHCR 预构建镜像 da99fac1 就绪, 仅改 BASE_IMAGE 变量切换, 不构建新镜像
圣上 2026-07-27 裁决走径 C — 整体切 3.8.48 base (上游真 release, 2026-07-13), 不构建新镜像 (GHCR 预构建镜像 `ghcr.io/i3t2y/omniroute-base:3.8.48@sha256:da99fac1a697022a0529805294c58a10923fc1c758616f4f0b2ea8428b0f408f` 已就绪), 仅改 BASE_IMAGE 变量切换 (dev nonoke/omn 先行蹚 24h → prod nomke/omn 后切, 回滚=改回 `ghcr.io/i3t2y/omniroute-base@sha256:9c9aecfd9eb529f44ab99cf94970aea896328146c64adc8ba146bfe809231347` 3.8.43 重启即回).
- **不翻 CLAUDE.md:23**: §1 至高 "基座 3.8.43 + 4.2.3 行为参数 + 3.8.49 定点移植" 不动; 3.8.49 分支 (ce80af6) 仍为定点移植源池, 本次切的是 3.8.48 (上游真 release, 非 fork 分支), 不破基座钉锚.
- **不用上游官方镜像三理由入册**: ① 官方 diegosouzapw/omniroute 镜像无 litestream 二进制 (备份链会断, 我方 omn-ops/ghcr/Dockerfile:43-54 自带 litestream-0.5.9 本地 tar COPY + 解 /usr/local/bin); ② HF 构建机拉 Docker Hub 有匿名速率限制 (Rebuild 可靠性风险); ③ digest 钉锚与供应链统一走自有 GHCR (BASE_IMAGE 钉 digest 不可变防漂移).
- **3.8.48 兼容性 Step -1 静态核毕** (audit/2026-07-27-3.8.48-compat-static-audit.md): 三新机制 (getAuthoritativeStaticContextWindow / max_token override / maxInputTokens 新链) 在 3.8.48 全落地 + 我侧 real_context=200000 消费链 getModelContextLimit 3.8.48:513-526 与 3.8.43:436-449 字节级一致 (Feature 5004 persisted override wins); GLM-5.2 authoritative 静态表 3.8.48 modelSpecs.ts:54-75 已落, nvidia 不进 provider 6 map (我侧走 model_context_overrides 表径正交); 新增迁移 9 件 (113-122, 121 跳号, 117_proxy_pool_rotation 破坏式但自带回填且我侧血统未用 proxy_assignments 表, 余 8 件累加无损).
- 出处: audit/2026-07-27-3.8.48-compat-static-audit.md (互斥铁证表 + 迁移清单 + litestream grep 实证). 切换执行序五步见 ops/STATUS.md 2026-07-27 段.

## 2026-07-27 · 3.8.49 升级可行性 Step -1 静态核定谳: 互斥表已核正交 + 3 卡口锁执行径 (裁决权归圣上, 未预设)
圣上 2026-07-26 "搜索查证能升级 3.8.49 吗" 令 → cg52 跑 Step -1 (静态核, 纯本地只读). 两阶段实证:
- **互斥核 (§6)**: 3.8.49 三新机制 (getAuthoritativeStaticContextWindow / max_token override #6524 / maxInputTokens 新链) 与我侧血统五件 **全正交**. 我侧 real_context=200000 走 `model_context_overrides` 表 (init-nim-keys.sh:893), 3.8.49 该表/接口/消费函数体 getModelContextLimit 字节级零改 (双版 diff rc=0), Feature 5004 注释双版同句 "persisted override wins over static catalog + models.dev sync" (modelCapabilities.ts:524 ≡ 3.8.43:447). nvidia 不在 3.8.49 GLM-5.2 authoritative provider 6 map 中, 1M 静态表仅填 fallback 路径不触 (我 override `??` 之前 wins, 生产 effective=200000 不变). gate.js #4 CTX guard (Patch B 1.5MB 字节硬拦) 与 3.8.49 token 数机制正交 (gate 防字节堤, 3.8.49 防模型 catalog 错), 无双重限制误杀.
- **执行径卡口 (§11)**: 3 卡口实证 — ① 上游 GitHub diegosouzapw/OmniRoute 无 v3.8.49 tag (最高 release=v3.8.48 2026-07-13, `git/refs/tags/v3.8.49` HTTP 404); ② 3.8.49 是 fork 的 release/v3.8.49 分支 ce80af6 非上游 tag release (CLAUDE.md:23 §1 至高 + audit/2026-07-22-全维度接手方案 §1.5 锁 "基座 3.8.43 + 3.8.49 定点移植", "禁整体升级 3.8.49"); ③ upstream_check.sh 取 /releases/latest → 自动流最高只能到 3.8.48 (3.8.48 base da99fac1 已预构建就绪), 3.8.49 不可触自动流 (整体切须手动 build fork 分支 digest 钉版).
- **4 升级径候选 (本档不预设裁决, 裁决权归圣上)**: 1.定点移植径 (守 §1, backport 至 dev/logic/**) / 2.整体切 3.8.49 base (破 §1 基座钉锚, 须明令改 CLAUDE.md:23+本条) / 3.整体切 3.8.48 base (守自动流, 真上游 release, 须 3.8.48 vs 3.8.43 互斥重核 + Step 0) / 4.不升级 (互斥表归档, 现 nomke 25-key 九段绿 rc=0 稳). 裁决令未至前, audit/2026-07-22-全维度接手方案 §1.5 "禁整体升 3.8.49" 仍锁, 守 CLAUDE.md §0 "不重复已锁定决策 (翻案须 Supreme 明确指令)". 出处: audit/2026-07-27-3.8.49-compat-static-audit.md §6 互斥表 + §11 三卡口 + §12 四径候选.

## 2026-07-26 · 四死名 Variable 划除 (zero 真消费, 圣上 Space web 删) — NIM_RPM/NIM_PROBE/NIM_FREE_CONCURRENT/NIM_SCALE_WITH_KEYS
切流 git SSOT 落地后圣上审 Space Variables 清单, 我核消费点定谳四死名 (现役 bootstrap.sh/entrypoint.sh/dev/logic/* 零真消费), 圣上 2026-07-26 Space web 侧删:
- **NIM_RPM**: 现 boot 限流 RPM 由 init-nim-keys.sh 动态推导 (cap=300, `init:208/667` 算法), 非 env 注; `dev/logic/init-nim-keys.sh` 零 `${NIM_RPM}` 引用. (仅 `.claude/worktrees/nim-pool-rebuild/init-nim-keys.sh:48 _RPM=${NIM_RPM:-40}` = worktree 历史分叉态, 非现役血统.)
- **NIM_PROBE / NIM_FREE_CONCURRENT / NIM_SCALE_WITH_KEYS**: 仓内零全引命中 (bootstrap/entrypoint/dev/logic 全扫). probe 逻辑现硬编码 POST glm-5.2 + 25 key 探活, 无 env 调参位.
- **划除依据**: §1 生产禁触, Space Variable 删除属圣上 web 手 (我禁触 Space); 我仅核消费点证死名供圣上删. 删后无运行时影响 (零消费即删无回退风险), Variable 列表淆读净化 (四死名占位淆误读为现役配置).
- **关联裁决 (LITESTREAM_STRICT=1 已裁, 见同日 (d) 条升格)**: 圣上同次设 `LITESTREAM_STRICT=1` (prod fail-早). 其余 Variables 真消费留: CONTEXT_LENGTH_DEFAULT (init:229 real_context 默认源) / NIM_COMPRESS_THRESHOLD (init:227) / NIM_MODE (init:20) / NIM_PROFILE (init:79) / NIM_REQUEST_BODY_LIMIT (init:233) / NODE_OPTIONS (entrypoint:186 堆 4096) / GATE_ADMIN_ENABLED (gate:24 布尔) / GATE_UPSTREAM_TIMEOUT_MS (gate:27 180000) / LOGIC_BUCKET_REPO+OMN_DATASET_REPO (双阶段别名见血统条) / R2_BUCKET (参数化生效). Secrets: HF_TOKEN (Space 容器 huggingface_hub 默认读名, boot Logged in+uploaded 通 = 活, 非删). 出处: 本会话圣上 Space Variables 审 + 我消费点核验.

## 2026-07-26 · R2 桶名参数化 $R2_BUCKET + workflow 六件命名规约 + HF_TOKEN 命名空间隔离 + LITESTREAM_STRICT 评估 (切流期两事故根因闭环, 圣上 7-26 令同步 web 手改回 git)
切流链步2-6 执行期 nomke/omn 生产侧连发两起事故, 同根 = `dev/logic/litestream.yml` 桶名硬写 dev 桶 `omn-data` 随 logic 层平铺机制越界写 prod 端 (prod R2 key 无 dev 桶写权 → 403 AccessDenied 备份断供 → 12:13Z boot #1; web 手改 YAML line 9 损坏 → 12:53Z boot #2 litestream 进程崩退). 全全程圣上 HF web 手动修复 (cg52 瘫痪期旁观). 本日四条同案闭环:

- **(a) R2 桶名参数化 $R2_BUCKET (logic 层环境无关根治)**: `dev/logic/litestream.yml` 单行 `bucket: omn-data` → `bucket: ${R2_BUCKET}` (litestream v0.5.9 内建 `${VAR}` envsubst, entrypoint 无 envsubst/sed 进程自扩; 与历史 archive/4.3.1 + 全篇 `${R2_ACCOUNT_ID}`/`${R2_ACCESS_KEY_ID}`/`${R2_SECRET_ACCESS_KEY}` 同风格). logic 层 logic 层"环境无关"血统恢复 — 硬写任一桶名即随平铺越界, 参数化后 dev Space env 注 `R2_BUCKET=omn-data`, prod Space env 注 `R2_BUCKET=omniroute-data`, 同一 yml 跨环境零改. 前置依赖 (圣上 web 侧, 本会话不代设): nonoke/omn 必须先设 `R2_BUCKET=omn-data` Variable 再 sync logic (否则 dev 端 env 缺得不扩致 R2 拒). 出处: saga §8.3 事故一/二 + dev/logic/litestream.yml:5.

- **(b) workflow 六件命名规约 (*-nonoke=dev / *-nomke=prod, prod 三件仅手动 dispatch)**: 六件制 = 双侧对称 (dev/prod 各三): `fetch-nonoke-logs.yml` / `fetch-nomke-logs.yml` (日志取证), `sync-logic-nonoke.yml` / `sync-logic-nomke.yml` (逻辑层同步), `sync-space-nonoke.yml` / `sync-space-nomke.yml` (骨架同步). prod 三件 (`*-nomke.yml`) 仅 `workflow_dispatch` 无 `push:` 触发 — 点火权属圣上显令, 防 dev/logic/** 改动自动平铺推 prod 致"混投一桶名"类事故再发 (事故一根 = dev sync 自动触推逻辑层越界). dev 三件保持 push 触发 (dev 改动自动 sync 是 dev 工作流常态). 命名空间隔离铁律: `*-nomke.yml` 内零 `nonoke/omn` / `HF_TOKEN_NONOKE` 字面, `*-nonoke.yml` 内零 `nomke` / `HF_TOKEN_NOMKE` 字面 (grep 字面零命中实证, 含注释层). 出处: saga §8.3 教训 (b) + .github/workflows/ 六件.

- **(c) HF_TOKEN 命名空间隔离 NONOKE/NOMKE 双 token (爆炸半径各半)**: `HF_TOKEN_NONOKE` 写 nonoke 系列 (dev Space + nonoke/omn-logic Dataset, write 仅 target scope), `HF_TOKEN_NOMKE` 写 nomke 系列 (prod Space + nomke/omn-logic Dataset). 双 token 越界即该隔离的运行时体现 — 事故一根本质 = prod 任务用 prod key 写 dev 桶, 参数化 + 命名空间隔离双闸后越界在 CI 阶段即拒 (而非 boot 期 403 才暴露). 原 GitHub repo secret `HF_TOKEN` 2026-07-26 删除, 仓内 env 名 `HF_TOKEN` (Space 容器 huggingface_hub 默认读名) 无改名涉. 出处: saga §8.3 教训 (c) + DECISIONS 同日 "删 R2 备份护栏" 条副作用收编.

- **(d) LITESTREAM_STRICT=1 已裁落地 (prod fail-早, 圣上 7-26 批)**: 现 entrypoint.sh:278-284 `litestream replicate -config /logic/litestream.yml &` 后台 `&` 不阻塞 boot, 主循环每 1s 探 `kill -0 $LS_PID`, litestream 进程崩退时: `[ "${LITESTREAM_STRICT:-0}" = 1 ]` 成立 → `echo FATAL...; _shutdown; exit 1` (graceful 收尾 gateway/init 子进程后 boot 退出 1, 非 `kill 1` 硬杀); `= 0` 则仅 WARN + `LS_PID=""` 不阻塞应用 (事故二态: boot 绿但备份死). 圣上 2026-07-26 批 prod `LITESTREAM_STRICT=1` (nomke Space Variable 已设 =1, 圣上 web 侧) — 备份死即 boot 死, fail-早胜 fail-晚, 应用层早挂显红胜过静默无备份跑. **容错边界 (启用须记)**: 一次 R2 偶发瞬时故障 (503/网络抖) 触 litestream 退出即 Space 重启循环风险, 须配合 R2 稳定性 + 监控告警 (litestream 崩退即 boot 死 = 告警信号强, 非静默死); dev 侧非oke 默认留 0 容错演练期. dash 兼容已验 (`[ "${LITESTREAM_STRICT:-0}" = 1 ]` POSIX 兼, entrypoint 走 `#!/bin/bash` 非 dash 无 bash-ism 风险). 零代码改 (entrypoint 现有代码现支持, 纯 env 0→1 切换生效). 出处: saga §8.3 教训 (d) + dev/logic/entrypoint.sh:278-284 + 圣上 2026-07-26 裁决令.

## 2026-07-26 · 变量血统核实: LOGIC_BUCKET_REPO + OMN_DATASET_REPO 双生不同消费点 (HF_DATASET_REPO 死名)
切流前悬案 (圣上令 §3 变量血统核实) 定谳 — `grep -n 'OMN_DATASET_REPO\|LOGIC_BUCKET_REPO\|HF_DATASET_REPO' bootstrap.sh entrypoint.sh dev/logic/*` 双件双命中实证:
- **`LOGIC_BUCKET_REPO`** = **bootstrap.sh 唯一真消费项** (bootstrap.sh:39 缺则 FATAL + :48 echo + :55/:60 python list_repo_commits 取 HEAD commit_id + :74/:76 hf download --revision 拉逻辑层) — bootstrap 拉逻辑层 Dataset 的血统契约变量, **dev 应设 `nonoke/omn-logic`, prod 应设 `nomke/omn-logic`**.
- **`OMN_DATASET_REPO`** = **dev/logic/init-nim-keys.sh 唯一消费项** (init-nim-keys.sh:910 缺则 skip return 0 + :999 hf upload_folder repo_id 回写 Dataset) — init 阶段 upload_folder 回写同一逻辑层 Dataset.
- **互为别名 (同 repo 不同消费点)**: LOGIC_BUCKET_REPO (bootstrap 拉) + OMN_DATASET_REPO (init 写) 都指**同一逻辑层 Dataset 根** — 拉与写同一 repo, 仅 boot/init 两阶段不同命名. dev 两名同赋 `nonoke/omn-logic`, prod 同赋 `nomke/omn-logic` (两阶段同值, 勿分裂).
- **`HF_DATASET_REPO` = 死名零消费**: 仓内 bootstrap/entrypoint/dev/logic/* 零命中, 残留旧名 (历史命名层), 划除. 出处: saga §8.3 切流前置核实 + 本会话 §3 任务.
- **环境变更记录 (只记不设, 圣上 web 手通)**: nomke/omn 已设/应设 `R2_BUCKET=omniroute-data` (Variable) + `OMN_DATASET_REPO=nomke/omn-logic`; nonoke/omn 应设 `R2_BUCKET=omn-data` (litestream 参数化前置, 见 (a) 条). `LOGIC_BUCKET_REPO` 两侧同 OMN_DATASET_REPO 值.

## 2026-07-26 · bootstrap.sh 硬化案落地 + 根件 dash 兼容三闸 (5e5d9eb → 热修)
bootstrap.sh `hf download --revision <HEAD commit_id>` 竞速根治案落地 (K3 裁, 圣上准): boot 前取 Dataset HEAD commit_id 作 --revision 锁 atomic 同点拉取, 根除 boot#4 拉旧 8 员意向池竞速; 失败 fail-open 回退 main HEAD 静默不阻塞 boot. 推后 5e5d9eb 触 Space 01:45Z crashloop — bootstrap.sh:65 引入 bash-only `${_rev:0:12}` 截取, Space `/bin/sh`=dash 不支持 → Bad substitution → set -e 杀 boot. 热修 `${_rev:0:12}`→`$(printf %.12s "$_rev")` (POSIX 兼) 解. **钉死**: 根件 (`#!/bin/sh`) 改动须三闸全过方推 — ①`sh -n` 语法 ②dash 实跑 expansion 段 ③bash-ism grep 全扫 (`${v:off:len}`/`${v/pat/rep}`/`[[ ]]`/`$(<file)`/arrays/`echo -e`), 缺一不可 (本次 ① 过但缺 ②③ 致崩). 出处: ops/incidents/2026-07-25-task-e-model-prune-saga.md §7.

## 2026-07-26 · 档册新规三件 + false-negative 复核规 + workflow 闸规 (K3 裁, 圣上准)
四件同日裁入, 防未来再坑:
- **① boot 编号语义漂移修正**: boot 序号跨会话无血缘续接 (cg52 口语 "boot#7 03:32Z" 实为 fetch-logs 实证期的 boot, 在册 saga 用 boot#5/#6 与本轮无血缘). **档册新规**: 档册只认时间戳 (如 "7-26 03:32Z boot"), 口语序号限对话当轮禁入档; 引用须带时间戳双锚防漂移误读.
- **② false-negative 复核规**: cg52 上轮 grep "DECISIONS 漏存盘" 假象 — 路径臆读 `ops/DECISIONS.md` (§3 文档链措辞漂, 真件在仓根 DECISIONS.md). **裁**: grep 否定结论必先复核路径再报 "未命中"; false negative 不得入账. 档册引用裁决出处时以 "档+段名" 双锚 (如 "§5后续列表 'bootstrap hf download 无 --revision'"), 防 §6.5 式臆挂.
- **③ R2 先证后建铁律**: Phase 2 链含 Rebuild — 若 R2 恢复链断, Rebuild 即 first-init 数据清零事件正撞单写铁律. **裁**: 步2 三子读数 (litestream snapshots / R2 bucket L0+WAL mtime+snapshots .ltx / lifecycle) 报回前 Phase 2 六步一律不启; 切流铁律增 "先证 R2 可恢复, 再谈重建". 切流后补验清单加: matrix 四笔外验证一次 snapshot 生成 + 恢复演练, "可恢复"从推断变实证. **关联悬案 (7-26 dispatch 铁证更新)**: ~~dbs.path=/app/data vs entrypoint DATA_DIR=/data 漂移嫌疑~~ 铁证推翻 (日志 `initialized db path=/app/data/storage.sqlite` 与 entrypoint `DATA_DIR=/app/data` 与 litestream.yml 全同, 零漂移). **真根**: restore-WAL-tail 半态致 compaction txid gap — entrypoint restore 拉 R2 低 txid snapshot (db_txid=0x0), litestream 启 replicate 后 `detected database behind replica` (db=0x0 vs replica=0x2c) 触发 fetched L0 seg (0x2c), compaction L1 合并本地 seg(0x10) + 拉回 seg(0x2c) txid 跳号 → `non-contiguous transaction ids` ERR每 30s. R2 鉴别器三子读须增两步: ① `sqlite3 /app/data/storage.sqlite "PRAGMA wal_checkpoint; SELECT * FROM pragma_wal_checkpoint;"` 看 db_txid 真态 ② R2 bucket 列 snapshots/*.ltx 全 txid 范围 + db/storage.sqlite/wal/ L0 seg txid 序列验链完整性 + entrypoint restore 选 snapshot 还是 WAL tail 逻辑分支审. 出处: saga §8.1 + evidence 分支 logs/nonoke--omn/20260726-0813-run.log.
- **④ workflow 通用闸规**: fetch-space-logs.yml 补丁二暴露 — job 内 git 操作首步无 actions/checkout, 空白 runner 报 `fatal: not a git repository`. **裁**: 凡 job 内含 git 操作, 首步必有 `actions/checkout` (含 fetch-depth 按需) 或由前序 job 产物显式重建仓; "默认在仓内"是 runner 上最贵假设, 与"流式端点有限化误判"同册列本仓 Actions authoring 双铁律. 出处: ops/INCIDENTS 待建 (fetch-logs checkout 缺口 saga), 现 fetch-space-logs.yml 补丁二 inline 注释留痕 + 本 DECISIONS 条.

## 2026-07-26 · 删 R2 备份 = 断代级破坏操作护栏 + 免费 Space 诊断通道定型 (圣上 7-26 定谳)
- **护栏条 (圣上令)**: 删 R2 备份 = 断代级破坏操作. 今后任何测试脚本**禁止裸删 litestream 路径** (R2 bucket `db/storage.sqlite/wal/` L0 seg + `snapshots/*.ltx` 全链), 仅允许: ① 删 `test` 前缀对象 (测试专用), 或 ② 删前书面确认本地库可弃 (与 bootstrap 流程解耦). **直接产物**: 2026-07-25 cg52 首测裸删 R2 备份 → 0x10+0x2c 两代残件断档 28 txid (0x11~0x2b 缺段) → litestream v0.5.9 compaction L1 (interval=30s) 每 30s 撞断疤一次 (日志 57 次 ERROR 一字未差 07:46:23→08:14) → "疤疤摸一次"非故障. 自愈中: 08:00:01 snapshot complete txid=0x32 (267,503B) 新链扫地重建 + retention 到期清旧残件自停 + 切流换 omniroute-data 新桶疤零迁移. 出处: saga §8.2.
- **免费 Space 诊断通道定型 (圣上 7-26 纠正入册)**: 免费档改启动行为的唯一真实通道 = Space 仓库 Files 页直接编辑 Dockerfile/入口脚本 + 提交触 rebuild. **不存在** "Command / Docker Command 字段" — 该假设是对免费 Space 能力的误判, 永久划掉 (方法1 划除). 免费 Space 诊断通道定型为三条: ① fetch-space-logs workflow (补丁三已修端到端通) ② R2 控制台肉眼 (bucket L0/WAL/snapshots txid 范围 + lifecycle) ③ 日志自读 (evidence 分支 raw API). 无直接 exec 通道.
- **诚实账 (圣上令入册)**: 断档窗口 (0x11~0x2b) 内若有写入, 昨晚已删不可追 — 属 dev 测试期数据, 当前库健康 + 应用全功能运行 (探活/ProviderLimitsSync 全绿), 切流零影响. 入册防未来误判病态复发.


fetch-space-logs.yml 同日连中两坑, 暴露本仓 Actions authoring 三铁律. **一坑三贴演进**:
- **贴①补丁二 (checkout 缺失)**: 证据分支 git 操作首步无 `actions/checkout`, 空白 runner 报 `fatal: not a git repository` (run 30193115626 前序 #30189840194 病). 修插 `actions/checkout@v4` 步. **铁律①**: 凡 job 内含 git 操作, 首步必有 `actions/checkout` (含 fetch-depth 按需) 或由前序 job 产物显式重建仓; "默认在仓内"是 runner 上最贵假设.
- **贴②补丁二位错 (clean:true 杀产物)**: 补丁二插位在 fetch step + 脱敏闸**之后** evidence 之前. actions/checkout@v4 默认 `clean: true` 跑 "Deleting the contents of <cwd>" — 删 fetch step 先落的 out/run.log (run 30193115626 实测 fetch rc=28 bytes=245500 真落盘后被 checkout clean 一扫而空) → 脱敏闸空 glob 通过 → evidence step `out/*.log` 空 → "无新快照 skip commit" → run 绿**假绿**, evidence 分支零快照落地. 三硬标缺一: run 绿 ✅ / evidence 落地 ✗ → 通道补丁二本轮**未真通**. **铁律②**: `clean:true` 是作业内**生成者杀手**, 凡 job 含"前步落产物" checkout 不得在该产物落盘之后.
- **贴③补丁三 (位序第一)**: actions/checkout 移 `Set up job` 之后第一 step (fetch step 之前), fetch step 在 checkout 后落 out/, evidence step 此时 cwd 已越过 clean 之劫, out/ untracked 留 → cp out/*.log 成功 → git add DEST 成功 (DEST 非 out/ 不被 .gitignore 守). diff +9/-8. **铁律③**: checkout **位序**与**有无**同重 — 凡 job 含"前步落产物 + 后步 git 操作", checkout 必为 job 第一步, 产物落盘路径必在 checkout 之后.
- **意外正向实证 (245.5KB 增长读数)**: run 30193115626 fetch 段 245500 字节比圣上本地 60s 实测 142251 多约 100KB — 非噪声, 是从 03:32Z boot 至此刻 Space 累积 boot/restart 历史自然增厚. 验证"积压+实时窗"快照语义含金量: 单次抓取证据完整度随 Space 运行时长线性提升, boot 叙事类取证 (R2 漂移案/compaction 告警溯源) 单次快照即全量史. 此读数入 saga §8 附注.
**钉死**: workflow authoring 三铁律 — ① checkout 在场 ② clean 不杀前步产物 ③ checkout 位序第一 (产物落盘后于 checkout). 三者缺一即通道假绿或 fatal. 与"根件 dash 三闸"(§同日条)并列本仓工程双闸. 出处: ops/incidents/2026-07-25-task-e-model-prune-saga.md §8 + fetch-space-logs.yml 补丁三 inline 注释 (行41-48).



## 2026-07-25 · GATE_ADMIN_TOKEN 机制废弃确认与文档同步: 单布尔开关 GATE_ADMIN_ENABLED 取代
代码实证: gate.js:24 `ADMIN_ENABLED = process.env.GATE_ADMIN_ENABLED === '1'` 纯布尔开关 (fail-closed: 未设/'0'/他值均关), gate.js 现行血统无 Token 认证代码, `git log -S "GATE_ADMIN_TOKEN" -- dev/logic/gate.js` 空命中 (path rename 后此线无 token 残留)。废弃时点锁定 `82d6559` (audit(landed): saga闭环留证+saga期源改回填+本轮闭环三件; "gate单开关" 改造在此回填, gate.js 由 `GATE_ADMIN_TOKEN.length` 判换为 `GATE_ADMIN_ENABLED === '1'` 纯布尔)。注: `35baba3` 是纯目录 rename (omn-logic→dev/logic, content 0 行改), 非机制改造点。影响: boot 日志 `[gate] admin UI: enabled/disabled` (gate.js:64) 仅反映开关状态, 非 Token 认证有效性; 历史 boot 的 "enabled" 不含有效凭据语义。操作标准修订: **维护窗口临时配 `GATE_ADMIN_ENABLED=1` (非临时配 Token), 用后恢复 `0`/删除仅 API 模式; 不再涉及 Token 删除** (机制已废无物可删)。整顿落地 (切流 Phase 0 前置): 宪法 §6 line 52 (CLAUDE.md) + 活文档 (ops/STATUS, ops/incidents 2026-07-25-switch-step2, HANDOFF) + 元数据 (package.json ×2 description → "admin UI toggle (GATE_ADMIN_ENABLED)") 已同步; docs/ v4.3.0/v4.3.1/k3-review 三件含嵌入旧 gate.js 全代码块作历史制品冻结不动 + 各加历史快照声明 (避免误读现行); audit/ archive/ 全冻结 (历史层考古不触); .github/workflows/fetch-space-logs.yml 脱敏闸注释+正则补 GATE_ADMIN_TOKEN 模式 (防御性历史泄露检测, 防日志残留/回滚旧版)。出处: 圣上 2026-07-25 机制废弃确认令 + cg52 代码审计 (gate.js:24/64, git log -S + 82d6559 diff 核)。

---

## 2026-07-25 · HF Space 日志抓取通道: GitHub Actions → n-omn evidence 分支, OpenConnector 日志线废弃
圣上令: 抓取 Space 日志用 GitHub Actions, 直接放 n-omn 私库。落地形态: fetch-space-logs.yml (cron 30min + dispatch), 单投 nonoke/omn (matrix 留 nomke 扩位, 待 HF_TOKEN_NOMKE), 脱敏闸 fail-closed (复用 secret-scan), evidence 分支与 main 分层。定位: CI 侧证据采集, 非逻辑层, 不受 ② 零变更约束, 阻塞仅 push+secret。与 P0-tee 互补: P0-tee 解决容器内持久落盘 (战后), 本通道解决 HF 可见窗口的仓内归档 (现在)。下游: claude-code-action 异步解读层未来从 evidence 分支消费 (机器产事实, LLM 产解读不变)。出处: 圣上 2026-07-25 令 + HF logs API 社区实证 (api/spaces/{ns}/{repo}/logs/{run,build})。

---

## 2026-07-25 · ② key 池基线 32 (非预案 25): 生产实池 32 行入池照准, cap 300 首触 + concurrent=96 缩放双验讫
② 预案原拟 25 key 稳态, 圣上重启后 NIM_KEYS 填 32 行 = 地面真值。圣上裁决 32 照准 (非偏差): ② 终极目的是验证 ③ 晋级生产将真实使用的配置, 直接验 32 行生产实池比验虚构 25 更对准目标。三点支撑: (1) cap 行为等价——25×35=875 与 32×35=1120 同远超 300, cap 300 首触已验讫与 key 数无关; (2) 最强证据在读回——Resilience 推导按 alive=32 重算 concurrent=32×3=96 (非 25 预案 75), boot #1 读回 `300/200/96/300000` 与 32 推导一字不差, 无 cap 的 concurrent 缩放路径一并验讫 (25 预案验不到); (3) 共享配额风险随池变大进一步稀释, 429 概率更低。③ 生产以 32 行为准 (非 25)。落库: STATUS ②行刷 32 + incidents 偏差裁决节, 文件名保留 `...-25key-baseline.md` 不动 (落笔时刻计划历史, 改名是考古污染)。出处: 圣上 2026-07-25 裁决一 + boot #1 (11:02) 读回实证 32×3=96。

---

## 2026-07-25 · ② 退出标准第五项: 池成分健康 (matrix 四笔全绿), release-checklist B4 入闸
② boot#2(11:22 双绿) 后 matrix 四笔验出一件事: probe 探活只测 glm-5.2 单模型 (init-nim-keys `probe_nim_keys_real` model=z-ai/glm-5.2), 池内 gpt-oss-120b / llama-3.3-70b 上游挂/极慢 init 期无感知; pool p2c 随机命中约 2/8 染慢 (~25% 超时), codex priority 钉首模型若挂则 100% 掉。**非 combo 路由病非网病非 gate 切, 是池成分病**。圣上 2026-07-25 裁决五: 池成分健康必须成为晋级标准一部分 (must 非 could, 池原样晋级 ③ = 已知坏成分带进生产)。落地: release-checklist B4 新条 — 矩阵四笔全绿 (nim-pool ≥2 笔 + nim-codex ≥1 笔成功), 达成路径 = 从意向上线模型池剔除挂/极慢模型 (本轮 gpt-oss-120b / llama-3.3-70b) 后复跑 matrix 到双 combo 绿; post-② 不变律 — ③ 之后每次池变更按此过闸。达成路径 = 圣上手 (Space 后台模型池配置), 剔完 cg52 复跑。"每模型 probe" (init 探活扩展到池内全模型) 入战后建设队列与 P0-tee 同批, 现在不动逻辑层。出处: 圣上 2026-07-25 裁决五 + ops/release-checklist.md B4 + STATUS 验收四笔矩阵实证 + incidents ② 退出标准条。

---

## 2026-07-25 · 429 基线改挂③: 不开后台不读库, litestream 切 R2 生产 bucket 时白捡
② 验收"429 监视基线"原列 dev 期 call_logs status_code 分桶。圣上 2026-07-25 裁决三: 钉 3 纪律 (后台暴露面收敛) 刚执行, 不为一条基线重开 admin (GATE_ADMIN_ENABLED=1) 触更大暴露面换可有可无数据, 不值——换零成本获取路径: ③ 变量切换 R2→生产 bucket omniroute-data 时, litestream 把 dev 期同一 storage.sqlite (含 32 key 期 call_logs 全量) 复制到生产 bucket, 切换后从生产侧只读副本跑一次 status_code 分桶 = dev 期基线白捡到手, 一行 SQL 的事。原"生产限流档裁决" (动态 cap 300 vs 保守 28/1) 裁决时点改挂两项齐后: 429 基线 (③ 后白捡) + ③ 后 24h 风暴特征串计数 = 0, 两项齐落 DECISIONS。出处: 圣上 2026-07-25 裁决三 + STATUS 429 基线改挂③ 条 + ops/release-checklist.md M3 (24h 风暴计数)。

---

## 2026-07-25 · GHCR BASE_IMAGE digest 钉锚 9c9aecf 作永久锚(T6 前替代浮动 :stable tag)
基座 digest 钉锚: Space Variable `BASE_IMAGE=ghcr.io/i3t2y/omniroute-base@sha256:9c9aecfd9eb529f44ab99cf94970aea896328146c64adc8ba146bfe809231347`(圣上手动改, 下次 Rebuild 生效, Dockerfile 一字不动)。浮动 :stable 是过渡, :X.Y.Z 钉版 tag 才是常态; 本仓 :3.8.43 tag 从未建过, 故 audit 唯一锚本就是这串 digest。digest 钉锚拆除整个"骨架首投 Rebuild 用浮动 tag 错误基座"风险类; T6 base-image.yml 未来只把此锚自动化。出处: 本轮 registry API index digest 仲裁 + audit/k3-review-r2-v30.md:519 落定记。

---

## 2026-07-25 · digest 真漂移仲裁证伪: :stable 未漂, 0b29aefb 是 platform manifest 伪 artifact
本轮前报 ":stable=0b29aefb 已漂离 audit 9c9aecf" 经 registry API 仲裁证伪: `docker manifest inspect :stable` 取的 0b29aefb 是单架构 platform manifest digest(量法非 tag 指针); registry 用 `Accept: application/vnd.oci.image.manifest.v1+json` 量 :stable 真 index digest = `9c9aecf` = audit519 落定一字不差 → :stable 实指 3.8.43 base 未动。同理 :3.8.48 我报 dad5d5e5 platform digest, registry index digest=da99fac1 与 audit519 一致。教训: 量漂移必须查 manifest `Docker-Content-Digest` header 走 index 量法, manifest inspect 的 config/platform digest 是测量伪影。出处: 本轮两闸仲裁 + audit519 "判漂必须查 manifest Docker-Content-Digest" 闸门纪律。

---

## 2026-07-25 · 落库完整性纪律: Write/Edit 返回成功不构成落库证据, read-back 才算
圣上改判闸根因: 两轮我 cat 错路径(DECISIONS.md 根→ops/DECISIONS.md、audit/k3总览→docs/)致错报"DECISIONS 空文件 stop-the-line", 实根 DECISIONS.md 真存 4701字节 9 条齐。若照"Write/Edit 返回成功即落库"惯性, 此类自欺会在更大动作中炸。固化: (1) 每个文件落库后必 `cat` 或 `git diff` 全文 read-back 验, 不在路径臆测; (2) commit 前 `git diff --cached` 全文审, 只 `--stat` 不许提交; (3) git show <commit>:<path> 路径须用 stat 确认的真路径, 凭臆测路径 read-back 会假 0 行/假空。健康信号标准向落库路径的自然延伸: 中间段回显不构成健康证据, 写入回显同样不构成。出处: 本轮完整性闸反转 + ops/incidents/2026-07-25-c2-pipefail-init-silent-death.md "假健康 boot" 同构教训。

---

## 2026-07-25 · 协作校验范式: AI 间结论可互驳, 驳须带 git/日志证据, 无证据服从与反驳同罪
固化 cg52 本轮三处协作表现: 对 K3 事实核查用 `git ls-files`/`git log` 证据而非服从权威(omn-logic 已 tracked 的纠正)、引用分治不一刀切(Dataset repo id `nonoke/omn-logic` 与本地目录名 `dev/logic/` 的辨析)、主动识别并放弃冗余设计(STATUS hash 自记 amend 无解循环)。范式: AI 间任何结论可被另一 AI 驳, 但驳必须带 git/日志证据; 无证据的服从(顺权威不验)与无证据的反驳(臆测路径/伪 artifact)同罪, 二者皆饮自欺。出处: 本轮两闸 K3 驳 cg52(digest 平台伪 artifact + Restart 不重拉基镜像两纠错) 续 cg52 驳回(路径错验) 的双向校验闭环。

---

## 2026-07-25 · 一库双器新拓扑: 撤销 nomke/omn-v2 第三个 Space, 复用现役两 Space
HF 免费 Docker SDK 自 2026-07 关闭新建通道(报错 "hosting Gradio and Docker Spaces on free cpu-basic requires PRO"), 现役 nomke/omn + nonoke/omn 是祖父条款保护稀缺资产。omn-v2 原蓝绿净室首跑定位撤: nonoke/omn 现已跑三层架构真机验(C2/九段/②全在其上), ②退出六绿即"已验证现役架构", 晋级生产仅变量切换(R2 指生产 bucket + GATE_ADMIN 按生产纪律)+ Restart, 零 Rebuild 零净室首跑。③④⑤改: nonoke/omn 晋级生产, nomke/omn(v4.2.3) Pause 停写冻结作回退底牌; C3 单写铁律执行序钉死(先 Pause nomke 写停 → 改 nonoke R2 变量 Restart → 全宇宙任何时刻仅一个写者), 回滚对称。DefaultCloseOperation 最终态回"一生产一开发"双 Space 永久闭环, 全程未新建任何 Space, 配额墙绕开。轴: sync-space-skeleton.yml matrix 单投 nonoke/omn(matrix 结构留双投一行扩展); HF_TOKEN_NOMKE 暂缓建(待 nomke 原地三层升级转 dev 时), 现 HF_TOKEN_NONOKE 单 token 覆盖 Dataset+dev 骨架。出处: 圣上 2026-07-25 裁决 + HF 免费层关闭报告。

---

## 2026-07-25 · gate 上游超时对齐 M7: GATE_UPSTREAM_TIMEOUT_MS=180000 (Variable, Restart 即生效非 Rebuild)
生产日志实证 91s/199s/297s 长思考流是常态流量(首 token 前静默期), gate 30s socket 超时会切断首 token 前静默, 误伤②期间长思考验收数据。② boot 前生效(Variable 变更, 与换 key 合并同一次 Restart, 不额外占窗口)。与 M7 STREAM_READINESS_TIMEOUT_MS=180000 上游对齐。**② 行为实证生效 (boot #2 期, 2026-07-25)**: GATE_UPSTREAM_TIMEOUT_MS Variable 已注入 (Space 列表 Updated 35 min, boot #2 前); boot 日志无该 Variable echo 行 (gate.js:27 `process.env || 30000` 默 fallback 不打印注入态), 但行为反推闭环 — gpt-oss-120b 长静默请求 3.8s 收 `: omniroute-keepalive` SSE 注释行 (gate 主动 keepalive 维持长连接), 两发分别 91.5s/200s 全 TimeoutError 无 502/504 错包 (若 gate socket 默 30s 切应在 ~30s 收错包, 实测无 = 不在 30s 切) → 超时已升 180000 生效。圣上 2026-07-25 裁决二判 boot 日志 echo 行缺失不追究, 行为证据闭环。出处: 本决策由 4.2.3 生产日志零采数据推得, ② boot 前并 ops/incidents/2026-07-25-switch-step2-25key-baseline.md 事前三钉点; ② 行为实证见 STATUS 长思考一笔。

---

## 2026-07-25 · 阈值不动决议: gate CTX_MAX_BYTES=1500000 / real_context=200000 维持, 不因 ② 25 key 触 cap 300 调
gate 1.5MB 字节硬拦(#4 OOM Patch B) 与 real_context 200000(压缩 Governor) 经 7弹+8B-tok 标定双验证, 与 key 数无耦合。② 25 key 触 cap 300 RPM 是 init 动态推导预期(init:208/667), 非阈值信号。调阈值前须有新病链数据, 不预动。出处: audit/2026-07-25-ctx-guard-oom-fix-landed.md + realctx200k landed, 防误调写入 ops/incidents/2026-07-25-switch-step2-25key-baseline.md。

---

## 2026-07-25 · 20129 幽灵处置: 迁移日 M1 定点清, 禁全库 LIKE 盲删, boot 前不碰
生产 14:15 起 `ProxyFetch ECONNREFUSED 127.0.0.1:20129` 幽灵仍现 (purge 0/0/0 但运行时有连接尝试, 脏 proxyUrl 存他处历史遗留)。② boot 前不动 (非本轮管, §1 生产禁触本项根源在生产侧)。迁移日 M1: strings 粗筛表名 → 定点 SELECT 确认 → 定点 UPDATE 清除 → litestream 同步绝育。禁全库 LIKE 盲删(数据面风险)。出处: ops/release-checklist.md M1 + audit/2026-07-25-ctx-guard-oom-fix-landed.md 遗留 audit 项 (2)。

---

## 2026-07-25 · 健康信号标准: 验收以 boot 九段全执行 + init rc=0 为准, 任何中间段回显不构成健康证据
前两轮假健康 boot (07-25 05:26 两 boot 均停 "7 registered", 实则 set -eo pipefail 杀 init 后段全崩无回显) 换来的验收标准固化。九段见 ops/release-checklist.md A1。出处: ops/incidents/2026-07-25-c2-pipefail-init-silent-death.md。

---

## 2026-07-25 · C2 gc_stale_providers pipefail bug 闭环: set +eo pipefail 抬门 + ${_DEL_JSON:-[]} 兜底
init:2 `set -eo pipefail` 下 `_DEL_JSON=$(jq...|grep -v '^$'|jq -R .|jq -s 'unique')` 赋值, 无待删态 jq 输出空 → grep 空输入 rc=1 → pipefail 杀 init, 7 registered 后全段不执行。修源 commit b662bd1 + push Dataset MATCH 2832f694 + 07:09 boot 九段全绿。出处: ops/incidents/2026-07-25-c2-pipefail-init-silent-death.md。

---

## 2026-07-25 · #4 OOM 病链双 patch: entrypoint NODE_OPTIONS 4096 回归 + gate 单阈值字节硬拦 1.5MB
dev 7key heap OOM / 生产 25key 90秒空转终态拒 同源链: 超大 body → NVIDIA 400(glm-5.2 硬顶 202752) → omniroute N-key round-robin fallback(auth.ts:1592) → 堆载累积终态拒/OOM。Patch A 堆 4GB 回归(env 可覆); Patch B gate CTX_MAX_BYTES=1500000/8B-tok 标定前拦 413, 仅判 content-length 不缓冲 body 保 SSE。出处: audit/2026-07-25-ctx-guard-oom-fix-landed.md。

---

## 2026-07-25 · real_context 200000 + body 4MB (per-key 能力握实, 非"防400盾")
init 三改 (real_context 32768→200000 / body raw 1→4 / echo 同步) 推 73e71f30。8B/tok 标定使 real_context 降级为"压缩 Governor"(122083 阈值派生), 非 NVIDIA 400 盾 (200000 + 压缩省3% 数学不防 400, 防线上移至 gate 字节硬拦)。出处: audit/2026-07-25-realctx200k-body4mb-landed.md。

---

## 2026-07-24 · 窗规解除: dev Dataset push ambient 授权(不再逐批显式令内)
原铁句"03:16Z前禁推"作废, 后续 dev Dataset 推送不再逐批请示。不变项: 生产 nomke 零触碰 / 凭禁触 / Space Restart Supreme 手动 / upstream 只读。出处: audit/2026-07-23-crashloop-saga-landed.md。

---

## 2026-07-23 · saga 双期闭环: express fix(supervisor crashloop 源) + rar2 init 副崩 403 fail-open
两 crashloop 全根除: (1) gate push 后 bootstrap 三层解耦不跑 npm install 致 /logic 无 node_modules 撞 require('express') → entrypoint 加预装段; (2) init upload_folder 403 (token 账户级读非写) 致 set -e 杀 init → python upload 包 try/except 降 WARN + hf_snapshot||true。五件远端终态: init 21cc7cdb/entry 4803e290/gate 616047c6/litestream 1563c08d/package 5ed9981b 全 == 本地。出处: audit/2026-07-23-crashloop-saga-landed.md。
