# ops/DECISIONS.md · omn 决策只增不改

> SSOT 决策层 (§3): 只增不改的裁决账本。翻案须 Supreme 明确指令 (§0)。冲突以 HANDOFF.md 为准, 其次本文件。
> 冲突次序: HANDOFF.md > DECISIONS.md (CLAUDE.md §3)。
>
> ⚠ 本文件 2026-07-31 新建。**旧决策全集尚未回填** (散落 audit/ / ops/incidents/ / ops/STATUS.md 段内, 未迁入)。新建前决策仍以原载体为真源;
> 本文件先承载 2026-07-31 起新决策, 旧决策回填留圣上令 (避免半建误导 / 翻案误触)。

---

## 2026-08-12 · FT Worker GitHub Actions 自控部署 (仿 n-edget 手搓→自动) + worker.js 鉴权 fail-closed 红线

**背景**: 圣上令 "参考 github.com/i3t2y/n-vless、i3t2y/n-edget, 用 GitHub 控制 CF 账号建设 Worker"。落 `ops/DECISIONS.md` 2026-08-10 段 + `docs/flaretunnel.md:39` 自述的运维负债: 现役 = "手工建 Worker → CF Dashboard 全选删除粘贴 worker.js → 部署 → 手填真实 URL 进 `flaretunnel_endpoints.json` 喂本地桥"; `flaretunnel/worker.js:5` `AUTH_KEY="PASTE_NEW_RELAY_AUTH_HERE"` 占位圣上手填, 换 AUTH_KEY 钥须逐 Worker 手改 → 密钥漏面大 + 运维负债重。

**治法 (本会话三件, 本地改完待 commit+push 圣上)**: 手搓→GitHub Actions 自控一键全 Worker 一致部署。
- `flaretunnel/worker.js` (+12/-7): ①fetch 签名 `async fetch(request)` → `async fetch(request, env)` ②硬编占位 `AUTH_KEY="PASTE_NEW_RELAY_AUTH_HERE"` → `const AUTH_KEY = env.RELAY_AUTH || null` 读 wrangler secret 注入 ③鉴权段加 **fail-closed 双守** `if (!AUTH_KEY || request.headers.get("x-relay-auth") !== AUTH_KEY)` — `!AUTH_KEY` 短路守 `undefined`/`null`/空串全硬拒 401。
- `flaretunnel/wrangler.toml` (新建): Workers 非 Pages 最小骨架 `name="flaretunnel"` + `main="worker.js"` + `compatibility_date="2026-04-26"` + `workers_dev=true`。
- `.github/workflows/deploy-ft-workers.yml` (新建): 仿圣上 `i3t2y/n-edget` `sync-deploy.yml` 机制转 Workers 路径。`cloudflare/wrangler-action@v4` + `secrets:` 输入内建走 `wrangler secret put` (非 n-edget Pages `curl PATCH CF API` 注 `env_vars.secret_text`)。`push` paths 触 (worker.js/wrangler.toml/workflow 自) + `workflow_dispatch` 手动。值来自同 step `env:` 引 GitHub repo Secret (`${{ secrets.RELAY_AUTH }}` 自动打码日志)。

**鉴权 fail-closed 红线 (新增 §2 安全红线宗)**:
worker.js 原占位逻辑 `if (request.headers.get("x-relay-auth") !== AUTH_KEY)` 存 **fail-open 裸奔洞** — `env.RELAY_AUTH` 缺时 AUTH_KEY=undefined:
- 请求带真值头 → `string !== undefined` = true → pass (鉴权失效)
- 请求无头 → `null !== undefined` = true → pass
- 两者都 pass = 鉴权洞 = **开放代理裸奔** (任意人扫到 Worker URL 即刷圣上 NIM 配额, docs/flaretunnel.md:41 "Worker URL 裸奔开放代理" 警告实证)
治 = `env.RELAY_AUTH || null` (undefined 归 null) + `!AUTH_KEY` 短路守 (null/空串全先硬拒不查头)。**鉴权钥缺必在 fetch 入口硬拒, 不裸奔开放代理。鉴权比 `!==` 无 fail-closed 守是洞, 须 `|| null` + `!KEY` 双守。** 五态真 fetch 调测铁证 (CASE A env无→401 / B 头=钥→200 / C 头≠钥→401 / D 无头→401 / E 空串→401)。

**n-edget 我仓差异 (机制移植须转路径)**:
- n-edget 走 **Pages** (`pages deploy .` + PATCH `accounts/.../pages/projects/$PROJ` 注 `env_vars.secret_text` + `wrangler.toml` 用 `pages_build_output_dir` 不写 `main`)
- 我仓现役 `worker.js` 走 **Workers** (`export default { fetch }` + `wrangler deploy` + `wrangler.toml` `main` 必填 + `wrangler-action` `secrets:` 输入内建走 `wrangler secret put`)
- 目标件 = `flaretunnel/worker.js` (FT 出口换 IP Worker), 非 worktree `cf-worker/index.js` (gate 网关前置代理 `UPSTREAM_BASE`/`INTERNAL_PSK`/`CLIENT_TOKEN`+KV, 别混两套)

**不变量**:
- §1 拓扑: 三件定态 (space 根 Dockerfile/README/start.sh) 零触。worker.js + wrangler.toml + deploy workflow 均非三件。不新建 HF Space (CF Worker 非 Space 不触"不新建 Space"铁律)。不翻 `FT_WORKER_COUNT` 控池语义 (2026-08-10 段), 不改 endpoints.json 池结构。
- §2 secrets: `RELAY_AUTH` 真值零入 git/会话。走 GitHub repo Secret (圣上 `openssl rand -hex 24`) → wrangler-action `secrets:` 输入 → `wrangler secret put` 加密存 CF。worker.js 读 `env.RELAY_AUTH` 运行时绑定不留值。换 GitHub Secret 时同改 HF Space Secret `RELAY_AUTH` 同值 (Worker 鉴权 ↔ 桥 RELAY_AUTH 铁律)。
- §0 翻案: 本段落 2026-08-10 段 "欲真扩池超 M 须圣上先 CF 建新 Worker" 遗留运维负债 (变 "圣上在 GitHub repo 设 Secret + 跑 Action 推 deploy"), 不翻案不改池语义。
- §5 护栏: git add/commit 一律 ask 圣上。secret-scan exit=0 五态测全绿。

**待圣上裁决 6 项 (卡矩阵扩 N, 单 Worker 先落)**:
1. **矩阵规模**: 单 Worker 先落 vs 直接矩阵 16? 真 M=16 池须圣上拉 HF `flaretunnel_endpoints.json` 件裁 (本地零件 git 从未 tracked)
2. **2池×8 vs 4池×4 矛盾**: `DECISIONS` 2026-08-10 段 (flaare/flbare 1-8) vs `audit/2026-08-01-save-log-full-analysis.md:169-176` prometheus 钉死 (flaare/flbare/flcare/fldare 1-4) 冲突, 须圣上 HF 件终极裁决现役真族结构
3. **单钥共享 vs 每省各钥**: 全 Worker 同 `RELAY_AUTH`? 还是每 CF 账号各钥? (单钥共享风险面最小, 仿 n-edget `CF_TOKENS` 位序 cut 取是否须复刻留圣上定)
4. **endpoints.json URL 回流机制**: Worker 建成后 URL 怎回填 `flaretunnel_endpoints.json` (真身在 Dataset nonoke/omn-logic) — n-edget 不涉此我独有项; 手填? Action dump? 待圣上定
5. **deploy 触发路径**: 仅 `worker.js` 改 push 触发? `workflow_dispatch` 已含, 圣上验后定是否加定时
6. **wrangler-action 版本**: `@v4` (2026-05-12 主推) vs `@v3.15.0` (固定防移动 tag 劫持, 跟 n-edget `@v3` 一致)

**关联**: [[flaretunnel-impl-built-verified]] [[flaretunnel-metrics-endpoint-lu3-landed]] [[ft-worker-count-env-lu-landed-2026-08-10]] [[ft-worker-count-vs-keys-decoupled]]。

---

## 2026-08-10 · FT_WORKER_COUNT ENV 控桥轮换池规模 (RELAY_AUTH 与 worker 数正交钉死)

**背景**: 圣上原题 "RELAY_AUTH 改 32 worker, 重建还是 16 worker"。直觉误把 `RELAY_AUTH` 当作 worker 池规模控制量。

**病根 (源码实证钉死)**: worker 数物理源 = `flaretunnel_endpoints.json` 写死的 16 条 Worker URL (flaare 1-8 + flbare 1-8 = M=16)。`RELAY_AUTH` = 桥鉴权密钥 (Worker 代码 `AUTH_KEY` 同步), 与 worker 数 **正交** — 改鉴权 token 不动池规模, 重建读同一 endpoints.json 故仍 16。两物无因果, 非故障是设计语义。

**治法 (commit 67b6b8c, dev/logic/entrypoint.sh `_ft_start` L222-248)**: 加 ENV `FT_WORKER_COUNT` 控桥 round-robin 轮换池规模 N。
- 规则: `实际轮换数 = min(FT_WORKER_COUNT, endpoints.json 物理条数 M)`
- ENV ≥ M → 全用 M (印提醒 ENV 过头, 不凭空造 Worker; 无新 URL 则物理上限不可越)
- ENV < M → 取前 N 条子集 (`--workers 0-(N-1)` 索引锁; Go 源 `LoadWorkers` L1297-1307 `parseWorkerIndices` 范围语法实证支持)
- 未设 / ≤0 → 原行为全用 M (回滚 = 删 Variable + Restart, 零代码改)
- 日志行改印 `${_ft_n}/${_ft_phys}` 双数 + ENV 子集时加标注

**不改 Go 源** (`--workers` flag 已支持索引子集, 无须重编译二进制)。**不改 endpoints.json 物理池** (URL 源圣上控)。欲真扩池超 M 须圣上先 CF 建新 Worker → 填真实 URL 进 endpoints.json → 推 Dataset → Restart (dev/logic path 零 Rebuild)。ENV 只控轮换池上限不造 URL。

**验证 (本地)**: `bash -n` 语法绿 + secret-scan exit 0 + 五边界自验全对 (ENV 0/4/8/16/32 × 池 16 → 轮换 16/4/8/16/16; flag 空/`0-3`/`0-7`/空/空+提醒)。

**部署链**: dev/logic path → 圣上 push nomn main (commit 67b6b8c) → sync-logic-nonoke CI 推 Dataset nonoke/omn-logic → Restart dev Space (零 Rebuild) → boot 真验看 `[entrypoint] FT:` 行印 `N/M Worker` 双数。push 本会话会 §5 护栏 deny → 圣上以 `!` 前缀亲跑 (已验远端追平 HEAD)。

**教训红线**: ENV 变量语意命名须明示 "控什么"。`FT_WORKER_COUNT` 控的是"轮换池规模上限"非"物理 Worker 数" — 设 32 不会造 Worker, 只在 ENV > 物理池时印提醒用满池。诊断此类 "改 X 不见 Y 变" 病诉, 先查 X 与 Y 是否正交 (鉴权密钥 vs 池规模), 再查 Y 的真物理源 (endpoints.json URL 数非 ENV)。

**关联**: [[flaretunnel-impl-built-verified]] [[ft-worker-count-vs-keys-decoupled]] [[flaretunnel-metrics-endpoint-lu3-landed]]。

---

## 2026-07-31 · probe 子shell exit1 崩根 `|| true` 兜底红线 (同源病族第三轮复发)

**背景**: 2026-07-25 C2 pipefail 静默杀 init (`jq` + `grep -v '^$'` 空输入 rc1 + pipefail → set-e 杀), 治法 `set +eo pipefail 抬门 + ${_DEL_JSON:-[]} 兜底`。2026-07-31 probe subshell 退出码经裸 `wait` 杀 init 同源病族第三轮复发。

**裁决 (新增红线)**: `init-nim-keys.sh` 行 2 `set -eo pipefail` 全程生效, 任何子 shell `( ... ) &` + 主循环 `wait "$pid"` 收子 shell 退出码, **裸 wait 未兜 `|| true` 是隐藏地雷** — 子 shell 最后一条命令若 test 失败 (含 `[ "0" = "1" ]` 非详细模式分支) 返 exit 1 → `wait` 收 1 → `set -e` 杀主进程 init → container exit 1。
治法: 子 shell 内末尾命令 / 主循环 `wait` 收批处一律 `|| true` 兜恒 exit 0。子 shell 是探活 fail-open 兜底语义, 失败不应阻 init。

**主义宗**: `set -e` + 子 shell + `wait` 三元组退出码传播链须一律兜底, 非单点修。本轮 L675 末 `|| true` 兜底根除 (commit `ef16b46`), 但本红线宗推主循环 L692 `wait "$_p"` 一律 `|| true` 兜 — 收子 shell 失败不应拦主进程 fail-open 语义。本轮单点修先用, 全量推留后续观察验证。

**X4 ENV 闸绕治标宗**: `NIM_PROBE_ENABLED=0` 整跳 probe = ENV 绕治标 (未触子 shell 故未崩, 06:14 前圣上配此稳生产), 非真根根除。环境绕 + 代码修 (`|| true` 治本) 两者非互斥: ENV 闸省 probe 启动时间, 代码修保证 probe 路不崩。

## 2026-07-31 · §2 secrets 历史明文 key 泄露清理挂账 (仅记位置, 零值入档)

**背景**: 2026-07-31 02:50 boot verbose 模 (`NIM_PROBE_VERBOSE=1`) `curl -s -v ... 2>&1` 明文回显 7 个 nvapi key 进 `init_20260731_025003.log` → 推 HF Dataset `nonoke/omn-logic` 公开存储 = 极敏感泄露。

**代码治本已落**: commit `e935ec2` 加 verbose 段过 `sed -E 's/(Authorization:[[:space:]]*Bearer[[:space:]]+)[A-Za-z0-9._\-]+/\1<REDACTED>/gi'` (`gi` 标志捕大写小写双变体) 写 `.verbose` 件。02:50 VERBOSE 段铁证全 `<REDACTED>`, §2 明文根除。

**挂账 (圣上侧善后, 仅记位置零值入档)**:
1. HF Space `NIM_PROBE_VERBOSE` ENV 若仍开则关 (关后 verbose 段整不产, 治标)
2. Dataset `nonoke/omn-logic` 历史 `init_*.log` / `debug_*.log` 含明文 key 件 (02:50 verbose boot 期) 圣上判删 / 重写剥明文版重推 (历史泄露清理)
3. 圣上贴回本会话的 02:50 boot 文本含 7 明文 nvapi key (圣上持有的真凭) — 圣上侧善后, 我侧只记位置不存值 (§2 红线)

**责任**: 与本轮代码改无关 (`e935ec2` 脱敏治本已落)。本挂账仅清历史已泄露存量。

## 2026-07-31 · omn-logic 用不着件移出 (路2 死代码 + 插件包可选件)

**背景**: 圣上 2026-07-31 令 "omn-logic 中的脚本文件整理下, 用不着的移出"。范围圣上 AskUserQuestion 答准三类: 仅扫 Dataset 根多余资产 (零多余) + omn_bucket_sync 插件包可选件 + omn_encrypt 路2 死代码。helper.sh runtime 退场段未选保留。

**裁决 (移除决策 = 只增不改的例外, 件存 git 历史可恢复)**:
1. **`omn_encrypt.py` (路2 加密) 移出**: 2026-07-29 圣上裁个人最小方案降级砍七成, 路2 Fernet tar.gz 整体字节级加密链降级 — `ENCRYPTION_KEY` 已删, `EncryptedScheduler` (scheduler 内子类) 从未实例化 = 死代码。私库只圣读 + litestream 已复制 storage.sqlite = 加密冗余。移出后 scheduler `_try_import` 删 omn_encrypt block (except 兜底 fail-open 已就绪), `EncryptedScheduler` 死类 + `ENC_SRC`/`ENC_STAGING` 死路径整删, 留移出挂记注释。
2. **`omn_bucket_sync.py` (插件静态包推公开 S3 Bucket) 移出**: 圣上裁插件包可选件状态, 非现役链 (`OMN_BUCKET_SYNC` 默0不触)。`init-nim-keys.sh` 调用段同删, 留移出挂记注释 + 恢复路径 (git 历史检出 + Dataset 根回推)。

**恢复路径 (件存 git 历史)**: `git show <旧 commit>:dev/logic/omn_*.py` 检出 + scheduler/init 引用段一并还原。本决策不删 git 历史, 仅工作树移出 + Dataset 根件同步删 (经 sync-logic-nonoke CI 推 Dataset + HfApi 删根件)。

**不变量**: 主链 fail-open 保证 — scheduler 主链路1 (CommitScheduler STDOUT staging → save) 不依赖两移出件; init OMN_BUCKET_SYNC 段删后阈若圣上仍设 =1 也无件可触 (`[ -x /logic/omn_bucket_sync.py ]` false 短路)。零回归。

---

## 2026-08-01 · 逻辑层 Dataset→Bucket 迁意 (圣上意图记, 未实施)

**状态**: 圣上意图仅打记号, **未实施未批准实改**。§0 翻案须明令 + §1 拓扑改须批。

**圣上原话**: "先做个记号, 我打算将 dataset 改成 bucket, 不合适再切回来"。AskUserQuestion 答准 = **逻辑层八件** (非 R2 / 非 /data 杂件)。

**与 2026-07-28 §12 单择定局关系**: §12 裁三轴分层 (R2备份不动 / Dataset逻辑层留 / Bucket挂`/data` RW运行态件层)。本记号针对**逻辑层八件** —— 即 §12 裁决第2条 "Dataset 改 Bucket 单路 ❌ 无必要性... Bucket反增未知风险面" 同作用面。本记号圣上未推翻 §12, 但留**意图方向**: 欲把逻辑层八件 Dataset→Bucket 替换试, 不合适切回 Dataset。

**迁意作用面 (现役逻辑层八件, 2026-07-31 清单10→8 收缩后)**:
`entrypoint.sh gate.js init-nim-keys.sh litestream.yml package.json helper.sh omn_redact.py omn_scheduler.py` — 平铺 `nonoke/omn-logic` Dataset 根, 经 `.github/workflows/sync-logic-nonoke.yml` CI 推 + readback 校 + delete_file 洗移出件残留 (5a292fc)。

**迁意代价面 (2026-08-01 圣上点破后认知更正)**:
- **四件武器 (版控+PR+血缘+K3 `--revision` commit_id锁+`git show` 历史检出) 全绑私库 `n-omn` git 仓, 不绑 Dataset** — CI `sync-logic-nonoke` 用 `HfApi.upload_file/delete_file` 把私库 `dev/logic` 八件平铺推 Dataset `nonoke/omn-logic` 根, boot 拉 Dataset 装 `/logic`。Dataset 在此链 = **运输管道+挂载源**, 不存版控历史。故"废 Dataset 四件武器" = 误判, 四件武器遗在私库不随 Dataset 去。
- **Bucket 替换真比较面 = 运输管道+挂载模式单维**: Dataset `upload_file`/`delete_file`/RO mount vs Bucket S3 PUT/DELETE/**RW mount `​/​logic`**。
- **Bucket 真优势点 (圣上真痛点对齐)**: init/gate 改动现须 boot 拉 Dataset RO + **Restart** 生效 (非秒级); Bucket 若 **RW mount** `/logic` ⇒ CI 推 Bucket → mount 内容即更新 → 期秒级热更免 Restart。**待证**: HF Bucket RW mount 真热更还是仍须 Restart (mount snapshot 固化? NFS 缓存?), 须实测钉。
- Bucket 非版本化 (删即永久丢) + 无 PR + Bucket→Repo 回写未支持 (HF roadmap) — 但件本低版本化需求 (私库已存历史可 `git show` 检出恢复), 此代价被私库四件武器兜底缓解。
- "不合适再切回" 可行性: 切回 = `sync-logic-nonoke` CI 改回 `upload_file` Dataset 路 + Space mount 改回 Dataset RO, 私库不动 (四件武器不受迁意影响) —— 切回链完整且不伤血统 (血统锚点在私库非 Dataset)。

**待决 (真迁须圣上另会话显令)**:
1. 真痛点复核: init/gate 改动须 boot 拉 Dataset + Restart 生效 (非秒级) = Bucket 双路可解此真痛。§12 §11 已备热件双路方案 (Bucket 挂 `/logic-bucket` RW + Dataset `/logic` RO 兜底, `_pick()` 谓词查 Bucket 优先回退 Dataset) — 非纯替换乃双路叠加, 更保 §1血统。
2. 纯替换 (废 Dataset 单走 Bucket) vs 双路叠加 (Dataset 留兜底 + Bucket 热更新) 选型待圣上裁。
3. Class A PUT 硬数 (低频写触限须监控) + hf-mount NFS 首读延迟 (init 探活路径须测) 两坑待证。

**关联**: [[storage-bucket-dataset-结合堪察]] §12 单择 + §11 热件双路 + audit/2026-07-28-storage-bucket-勘察.md。

---

## 2026-08-01 · save 七源分类生效闭环 + 归档机制落地 + R2 endpoint 脱敏扩

**状态**: 全闭环 (本地改完待 push nomn 触 CI 同步 Dataset).

### A. save capture 七源分类生效闭环 (圣上 2026-07-30/08-01 终极旨链)
继 2026-07-29 路一单件 + 2026-08-01 全析 2289 件 + 删, 发现 capture 漏两源 (entrypoint 本体编排日志旧只入 PID1 stdout 30min 焚; litestream stderr 旧与 entrypoint 混 PID1 stdout)。
- `entrypoint.sh`: DATA_DIR export 后加 `exec > >(tee -a "$_EP_LOG_RAW") 2>&1` 全进程重定向落 `omn-raw/entrypoint.log` (`:> ` boot 前截断归零免跨 boot 累计); litestream 段加 `_LS_LOG_RAW` 隔离 stderr `>>"$_LS_LOG_RAW" 2>&1 &`.
- `omn_scheduler.py`: L63 `_ARCHIVE_PREFIXES` 四→六源加 entrypoint+litestream; `capture_stdout()` 五源尾追加两 `_capture_one`.
- commit 35f08df push nomn `a80d335..35f08df`, CI sync-logic-nonoke 同步 Dataset (HEAD=f3000fb497b8 → 6f08fddd421d).

**2026-08-01 10:29 restart dev 真验全闭环** (圣上准拉现役 save/*.log 167 件析毕 → 远程 DELETE 删):
- **六源分类生效铁证**: 子目录 4 段件 32 件 (app 7/entrypoint 7/ft 4/gate 5/init 2/litestream 7) 北京时间 `YYYYMMDD_HHMMSS_<epoch>.log` 格式 epoch 递增全活。根平铺 135 件 (3 段 `<prefix>_<epoch>` 旧格式) epoch 17:08~18:29 = 前轮旧代码期残留非本轮新出; 子目录 epoch 18:29:53~18:38:53 = 本轮新代码期。**分水岭**: 根最晚 18:29:02 (boot-40s) → 子最早 18:29:53 (boot+11s), boot 瞬间新代码切换零混入。
- **boot race 1 次** = 预期非病: `No credentials for nvidia`@10:29:57.560 (probe key#6 窗口期内 providers nim-01 未注册完) → 10:30:27 恢复 `Using nvidia account: 6a7e0997`。同 [[save-log-analysis-2026-08-01]] 钉同链。
- **真 chat 闭环 6 次**: account p2c 轮换正常 (6a7e0997/160b719d/0f08b327/56844feb/a03b6766/2f562ab8/8fc989e6/aa7a9a8c/f0ca064d) USAGE+STREAM complete 全绿。
- **唯一 ERROR**: litestream restore rc=1 空库 `database not found in config` = [[omn-v30-logic-litestream-replicate-contract]] v0.5.9 -config 已知既定非新病, fail-open 空库后续 `detected database behind replica` 自愈。
- **删后残余**:DECISIONS commit c86bf015 (delete_files glob 扫 save/* 与六子目录) 删 save/*.log 190 件 (删除中又新 23), 留 6 json 快照 (combos/init_vars/keys/omni_config/providerConnections/settings).

### B. 日志归档机制 (圣上 2026-08-01 令治私库 100GB 硬限, 已 push a80d335)
方案 A 保留现架构: 7 天前旧日志按源分四包 tar.gz 推**新账号私库** (replaceable 满换库无所谓), 推成功后才 delete_files 删原库腾空间。
- `omn_scheduler.py` +5 段 append 0 改现役: 新 ENV 块 5 个 (`OMN_LOG_ARCHIVE` 总闸默 1 / `OMN_LOG_ARCHIVE_REPO` 新私库 / `OMN_LOG_ARCHIVE_TOKEN` 新号独立 token / `OMN_LOG_ARCHIVE_DAYS` 默 7 / `OMN_ARCHIVE_INTERVAL` 默 3600s)。换库只改两 Secret 零代码改。
- `_archive_loop` daemon 1h 查 + `_do_archive` fail-safe 铁闸 (推成功才删, 幂等去重列归档库查已归档跳推只删原件, 任一步失败 except continue 不删下次重试)。import tarfile+tempfile+shutil 标准库零新依赖。
- **圣上侧前置 (零代码依赖)**: 新号建 HF 私库 + write token → 入 Space Secrets (OMN_LOG_ARCHIVE_REPO+TOKEN) → restart 真验归档 daemon 启 + 1h 后查远程→save/ 旧件删 + archive/app/tar.gz 出现。

### C. omn_redact 默 6→7 扩 R2 endpoint 脱敏 (本轮 litestream 件隐私面)
- litestream 件含 `endpoint=https://<32hex>.r2.cloudflarestorage.com` = Cloudflare R2 account-id hash。**非签字凭** (S3 签字用 access-key-id+secret-key 在 Authorization header 非 endpoint; account-id 单独不操作 bucket), 且 repo private 风险本低。但留私库非最佳, 圣上准扩。
- `omn_redact.py` DEFAULT_PATTERNS 第 7 条 `r'(endpoint=https?://)[A-Za-z0-9._-]+\.r2\.cloudflarestorage\.com'` — 捕前缀 `endpoint=https://` + 替 host 段为 `<REDACTED>`。余 6 不退, ENV 覆盖非追加语义不变。验通 (真测 R2 明文→脱敏 + 大写 STORAGE 不匹正常 + ENV 设仍覆盖非追加)。

**关联**: [[save-log-full-arch-landed]] [[save-log-analysis-2026-08-01]] [[log-archive-to-new-private-repo-landed]] [[omn-永续日志架构-landed]] [[omn-v30-logic-litestream-replicate-contract]]。

## 2026-08-12 · FT Worker 二维矩阵 10×10=100 上限框架 (commit 6c78f2d 本地待 push)

**圣上令**: 承 [[ft-worker-github-deploy-landed-2026-08-12]] 单 Worker 雏 (commit 008c48d), 圣上定终"按 10 账号部署"+三点: ①Worker 名+自定域名仿两项目 (i3t2y/n-vless + n-edget) 儿童词池, 序从 1 递增 (1-10)②引两项目机制删旧 Worker→建新→绑 custom domain (封后立重设)③每账号绑一自定域名 `f01.cc.cd` 递增 (第 4 账号第 5 Worker = `5.f04.cc.cd`)。圣上明"参考两项目别臆造" → 谭照 n-vless `sync-deploy.yml` (795 行 5 job) 全机制移植扩。

**拓扑定夺 (圣上)**: 10 账号 × 10 Worker = 100 上限框架, 现役由 GitHub repo Variable `ACTIVE_ACCOUNTS` 自定 (圣上现满额 10 = 100 Worker)。每账号整 10 Worker (内序 1-10) 独立词基 (不跨账号共享: 障缝性 + 封禁隔离 + 1 账号封仅砍该账号词基)。

**机制移植 (commit 6c78f2d, deploy-ft-workers.yml 单维→二维全重写 +525/-47 rewrite 65%)**:
- **gate job**: PRESET 8 场景 (`gen`/`first`/`daily`/`solo:N`/`secrets`/`delete:1`/`delete:v`) + 动态矩阵构建 `account∈[1..ACTIVE_ACCOUNTS] × worker∈[1..10]`
- **gen-names job**: 60 词池 (3-4 字母过滤) + 每账号独立 `$RANDOM%WLEN` 抽双词不重 → `<W1>-<W2>-ft{1..10}` 平铺 100 名存 GitHub repo Variable `WORKER_NAMES`
- **deploy 二维矩阵每格 6 step**: Extract Credentials (`POS=(( account-1 )*10 + worker)` cut 取名 + `::add-mask::$TOKEN`) + Generate wrangler.toml (`workers_dev=false` + `[[routes]] pattern="$WSUB" custom_domain=true`) + Delete Worker (deploy 段自带删该格名防同名) + Deploy1st (`continue-on-error` 兜 10007) + 双 pass 绕扫 (PASS_MODE=2 全格重 deploy) + Verify & Bind Domain 三段验证 (存在性 3 重试 5s + custom domain 校验补绑 + 关 workers.dev)
- **域名派生 (圣上拓扑, 非 n-vless 循环回 0)**: `ACC2=$(printf "%02d" $account)` `WSUB="$worker.f$ACC2.cc.cd"`

**删段两模式裁决**:
- **Mode 1 (`delete:1`)** = 删当前矩阵单元指定 `WNAME` (散点删, 错杀他格)
- **Mode 2 (`delete:v`)** = 扫该账号 CF 全 Worker **全删 (无后缀滤波)** 全 DELETE (圣上 2026-08-12 令改「全删」反 n-vless 滤波删, 圣上确认 FT CF 账号内无 gate 网关他 Worker, 全删安全); 前态滤波 `~ ft[0-9]$` (仿 n-vless 防误删他项目) 已去
- **绕封正解 (n-vless 证同名重部署不绕封)**: Mode 2 删光 → 重新 `gen` 换词基 → `first` 复绑旧子域 (子域不变桥零改动, 名变 CF 认新 Worker)

**旧 `flare*.workers.dev` 删不了裁决 (圣上会话问)**:
- 拦1: 删段正则 `~ ft[0-9]$` 不匹配 `flare` 后缀
- 拦2: `1-8.flare*.workers.dev` = 子域/workers.dev 域非 Worker 名; CF 删须 `DELETE scripts/{name}`, 旧名结构未知
- 裁决: 圣上"到时临时删下手动太麻烦" → 下批 commit 合并扩删段正则容 `flare*` (`~ ^(flare|ft)[0-9]+$`), 不阻塞现 push; 或新池运行后旧 `flare*` 废弃不动 (Worker 不调不耗配额)

**Token scope 最小集 (WebFetch developers.cloudflare.com limits+permissions 页铁证)**:
- **CF Worker 池 token (每账号一 token 锁该账号+其 zone)**: Account `Workers Scripts Edit` (含 deploy/secret put/DELETE/列/subdomain关全; **无独立 'Workers Secrets Storage' 权限, secret_text 绑 script**) + Zone `Workers Routes Edit` + `Zone Read` (custom domain 须) + `DNS Edit`; Resources 锁 `Specific account` + `Specific zone`; 勿选 KV/R2/Pages/D1/Tail/Containers/Account Settings/User Details/Memberships/Builds/Agents
- **Edit vs Read**: Workers Scripts/Workers Routes/DNS = Edit; Zone = Read
- **GH_PAT (Fine-grained, 写 WORKER_NAMES Variable)**: Only `i3t2y/n-omn`; Repo perms `Variables` RW + `Contents` R + `Metadata` R; 勿 Actions/Workflows/Admin/Secrets/Statuses/Deployments/Pages; Expiration 推 90 天圣上定

**CF Free 配额铁证 (WebFetch limits 页)**: 每 account 100 Worker 上限 + 每 zone 100 custom domains (10 Worker<<100 安) + 配额账号级聚合 100k req/日/account (非 Worker 级, 不调不耗) + 10 账号各独立 token/zone 各吃本账号配额不共享不互抢。

**圣上手设 GitHub repo (我零碰真值 §2)**:
- **Variables**: `ACTIVE_ACCOUNTS=10` `PRESET=` (空默认 gen) `CRON_ENABLE=true` `DEPLOY_SCOPE=2` `PASS_MODE=2` `SOLO_ACCOUNT=1` `GEN_NAMES=0` `DELETE_MODE=0` `SECRETS_ONLY=0`
- **Secrets**: `CF_ACCOUNT_IDS` (10 accID 逗号串) + `CF_API_TOKENS` (10 tok 逗号串每锁该账号其 zone) + `RELAY_AUTH` (`openssl rand -hex 24` 且 **须同 HF Space Secret RELAY_AUTH** = Worker 鉴权↔桥铁律) + `GH_PAT` (Fine-grained)
- 圣上补全 10 CF 账号 + 10 zone (`f01.cc.cd`~`f10.cc.cd` 各挂对应账号 zone) + 每 zone 建对应 token

**不变量守**: worker.js (008c48d fail-closed 态) + wrangler.toml (git 版单 Worker 骨架, workflow 动态覆写) 未动; 三件定态 (Dockerfile/README/start.sh) 零触; §1 私库唯一血统; §2 secret 真值零入 git/会话全走 `${{secrets.*}}` 占位 + `::add-mask::`; §5 commit 6c78f2d 已落 (圣上准), push 须圣上另准。

**部署链**: push nomn main (=触 `GEN_NAMES=0` 默认 gen Phase 生 100 名写 `WORKER_NAMES`) → 改 `PRESET=first` → 双 pass 全量建 100 Worker + custom domain + 关 workers.dev → GitHub Actions 绿 + CF Dashboard 见 100 Worker + 100 子域 → URL 回填 `flaretunnel_endpoints.json` (真身 HF Dataset `nonoke/omn-logic` 本地零件 git 未 tracked) → Restart dev Space → boot 真验桥 round-robin N/M 计数增 (路 3 /metrics 已落)。

**闸验全绿**: YAML 闸过 (`python3 yaml.safe_load` jobs gate/gen-names/deploy + matrix 动态 `${{fromJson}}`) + secret-scan exit=0 + 真值零残留 (全 `${{secrets.*}}` 占位)。

**关联**: [[ft-worker-100topology-landed-2026-08-12]] [[ft-worker-github-deploy-landed-2026-08-12]] [[ft-worker-count-env-lu-landed-2026-08-10]] [[flaretunnel-impl-built-verified]] [[flaretunnel-metrics-endpoint-lu3-landed]] [[ft-worker-count-vs-keys-decoupled]]。

<!-- 旧决策回填区 (待圣上令, 散落 audit/ / ops/incidents/ / ops/STATUS.md 段内未迁入) -->

## 2026-08-01 · omn_scheduler.py 归档结构假设错病根 (`parts != 4` 全杀零归档)

**背景**: 圣上侧配齐 `OMN_LOG_ARCHIVE_DAYS=0`+`OMN_ARCHIVE_INTERVAL=60`+三核心 ENV (`OMN_LOG_ARCHIVE_REPO`=`nokebak/log`+`OMN_LOG_ARCHIVE_TOKEN`+`OMN_LOG_ARCHIVE=1`), 4 回重启 (11:41/12:05/...) 后归档库 `nokebak/log` **零压缩包出** + 源库 `nonoke/omn-logic` save/ 当日 217 件 **零删**。圣上直接判"归档删除根本没生效"。

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

**debug 件裁决 (圣上问)**: debug 件 `save/debug_*.log` 根平铺 parts=2 → 结构 gate 跳 → **永不被归档 / 不删 / 不移入归档库**。三段判距 false-safe: debug 件保护性排除, 不入归档流。

**教训红线**: 归档/删除类 silent daemon 代码 "模拟验证" 仅测核心逻辑 (cutoff 字符串比较) 不够 → **必跑真件 + 真 parts 数 + 真删可见** 验结构 gate。静默 daemon 无 print/log 出件, 唯一观测面 = 远程库件数变化 (源库降 + 归档库升), 零变即病。print 加诊断 stub 留下轮观测。

**关联**: [[log-archive-to-new-private-repo-landed]] [[save-log-full-arch-landed]] [[omn-永续日志架构-landed]]。

<!-- 旧决策回填区 (待圣上令, 散落 audit/ / ops/incidents/ / ops/STATUS.md 段内未迁入) -->
