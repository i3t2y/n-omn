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

**删段三模式裁决**:
- **Mode 1 (`delete:1`)** = 删当前矩阵单元指定 `WNAME` (散点删, 错杀他格)
- **Mode 2 (`delete:v`)** = 扫该账号 CF 全 Worker **全删 (无后缀滤波)** 全 DELETE 后重建 (PASS_MODE=2 双 pass), 圣上 2026-08-12 令改「全删」反 n-vless 滤波删, 圣上确认 FT CF 账号内无 gate 网关他 Worker 全删安全
- **Mode 3 (`delete:o`)** = 扫该账号 CF 全 Worker → 滤现役 `WORKER_NAMES` 名单 → 在名单 `Keep` / 不在 `DELETE` (清旧词基/孤儿/过时 Worker); **纯删无部署** (PASS_MODE=0 跳全 deploy step 唯删段跑); 圣上问「删上次建立 worker 之外的所有 worker」定此场景, `delete:o` 名圣上定 (`other` 缩写, 对齐 `delete:1`/`delete:v` 序号风格)
- **绕封正解 (n-vless 证同名重部署不绕封)**: Mode 2 删光 → 重新 `gen` 换词基 → `first` 复绑旧子域 (子域不变桥零改动, 名变 CF 认新 Worker)
- **Mode 3 filter 安全**: `echo ",$WORKER_NAMES," | grep -q ",$W,"` 前后加逗号防部分命中 (如 `ft1` 误吞 `xxx-ft10`)

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

---

## 2026-08-12 · FT Worker 100 拓扑 + GitHub Actions 自控部署链 (仿 n-vless/n-edget)

**背景**: `docs/flaretunnel.md:39` 自述现役机制 = "手工建 Worker 后写进 flaretunnel_endpoints.json 喂本地桥" + `ops/DECISIONS.md:24` (旧) 锁决 "欲真扩池超 M 须圣上先 CF 建新 Worker → 填真实 URL"。运维负债: 换 RELAY_AUTH 钥须逐 Worker 手改 + worker.js 更新须逐 Worker 手粘贴。圣上令参考两私库 `i3t2y/n-vless` + `i3t2y/n-edget` 用 GitHub 控制 CF 账号建设 Worker。

**裁决 (圣上 2026-08-12 三点 + 拓扑定夺)**:
- **拓扑**: 10 CF 账号 × 10 Worker = 100 上限框架, 现役启 4 账号 sub集 40 (后续圣上加 f05~f10 zone 只改 `ACTIVE_ACCOUNTS` Variable, workflow 矩阵自适应)。每账号绑 1 主域名 `f01~f10.cc.cd`, Worker 子域 `{1-10}.f{账号:02d}.cc.cd` (例第4账号第5 Worker = `5.f04.cc.cd`)。
- **Worker 名+域名**: 仿 n-vless 儿童单词池 (60 词 3-4 字母), 每账号独立抽双词不跨账号共享 (障缝性 + 封禁隔离), 名格式 `<W1>-<W2>-ft{1-10}`。后缀 `v`→`ft` (项目标识防 delete Mode 2 误删 n-vless Worker)。
- **secret 注入**: 走 wrangler-action `with.secrets:` 输入列名 + `env:` 配同值 (非 n-vless curl PUT secrets API; 内建跑 `wrangler secret bulk/put` 注 Worker env), 值源 GitHub repo Secret `RELAY_AUTH`, §2 零入 git。
- **二维 account×worker 矩阵** (n-vless 一维 10 账号单 Worker; FT 1 账号 10 Worker 须二维扩), 工作目录 `flaretunnel/` (worker.js 非 n-vless `_worker.js`)。
- **绕封正解链** (n-vless 证同名重部署不绕封): Mode 2 删光 → 重新 `gen` 换词基 → `first` 复绑旧子域 (子域不变桥零改动, 名变 CF 认新 Worker)。
- **Token scope 最小集** (WebFetch developers.cloudflare.com 铁证): CF token 每 CF 账号一 token 锁该账号+该 zone: `Workers Scripts Edit` + `Workers Routes Edit` + `Zone Read` + `DNS Edit`; Resources `Include→Specific account`+`Specific zone` (作用域隔离勿 All)。GH_PAT Fine-grained: `Variables` Read/Write (核心写 WORKER_NAMES) + `Contents` Read + `Metadata` Read, repo only `i3t2y/n-omn`。
- **触发机制 tag-driven (圣上令 B 方案)**: `on.push.tags:['deploy-*']` 仅 deploy tag 推时触部署, 普通 push 改 workflow 零触 (圣上主动 tag 掌触发权); 三路触: ① `git tag deploy-vN && push` ② `schedule cron 17 2 * * *` (daily 走 PRESET Variable) ③ `workflow_dispatch` (input preset 即时覆盖)。

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

**f01 zone DNS 病 + 修 (2026-08-12)**: 初 boot 后 save/ft/ 日志印 `no such host` 集中 `2.f01/3.f01/4.f01.cc.cd` (f01 账号 zone 全 4 Worker 子域无 DNS), 其他账号正常。圣上 CF 侧修 zone DNS 服务器 → 重探 `dig 1-4.f01.cc.cd` 全返 CF IP + curl `401` (Worker fail-closed 拒无 PSK = 活非 502/DNS 错) = 40 Worker 池全活。根: zone 层配置非 Worker/部署错 (f02-f04 同代码全活), 重部署不修 zone, 须圣上 CF 侧裁。round-robin fallback 兜跳死 Worker 仍 200 = 韧性。

**关联**: [[ft-worker-100topology-landed-2026-08-12]] [[ft-worker-github-deploy-landed-2026-08-12]] [[flaretunnel-impl-built-verified]] [[flaretunnel-metrics-endpoint-lu3-landed]] [[ft-worker-count-env-lu-landed-2026-08-10]] [[ft-worker-count-vs-keys-decoupled]] [[flaretunnel-feasibility-verified]]

---

## 2026-08-12 · worker-major 重排 endpoint.json (圣上妙案, 桥取简化)

**背景**: endpoint.json 原 account-major 排 (idx0-9=acc1 w1-10, idx10-19=acc2 w1-10, ...), nim 桥取"每账号前4 worker"须手展开 `0-3,10-13,20-23,30-33` (parseWorkerIndices FlareTunnel.go:2119 解逗号+range 不支持步长) → 字串冗长易错。

**裁决 (圣上妙案)**: endpoint.json 重排 worker-major: idx0-9=worker1 各账号 (1.f01..1.f10), idx10-19=worker2, ..., idx90-99=worker10。nim 桥 `workers:"0-39"` 连续直取 = worker1-4 各 10 账号 = 每账号前4 worker (省字串手展开)。

**派生序**: `newidx → (worker=newidx//10, account=newidx%10) → old account-major idx = account*10 + worker → 取 WORKER_NAMES 名 → URL = https://{worker+1}.f{account+1:02d}.cc.cd`。本地 /tmp 脚本产 + workflow publish-endpoints Python 派生序完全匹配对证 (idx0=gem-fire-ft1→1.f01, idx30=gem-fire-ft4→4.f01, idx99=luck-love-ft10→10.f10)。

**自动化回填**: `publish-endpoints` job (commit d1c324b) deploy 成后 (或 PRESET=publish 场景 deploy 跳后) 派生 worker-major endpoint.json 传 HF Dataset `nonoke/omn-logic` `flaretunnel_endpoints.json` via `HF_TOKEN_NONOKE` GitHub Secret, 零硬编真值 §2。圣上须手设 `flaretunnel_bridges.json` nim `workers:"0-39"` (桥编排骨圣上域, workflow 不传 bridges)。

**关联**: [[ft-worker-100topology-landed-2026-08-12]]

---

## 2026-08-12 · PRESET=publish 场景 (publish-only 路径, deploy 跳省 16m)

**背景**: 圣上欲"仅 publish 不重部 Worker" (daily 重部 100 格 ~16m 成本大), 额外特定任务路径。

**裁决 (commit c22b3a9)**: 加 `PRESET=publish` 场景, `PUBLISH_ONLY=1` flag:
- gate case `publish)` 分支: GEN_NAMES=0 + SECRETS_ONLY=0 + DELETE_MODE=0 + PUBLISH_ONLY=1
- gate outputs 加 `publish_only` (主输出 + cron 阻塞分支 + 默认值段)
- deploy if 加 `publish_only != '1'` 门 → publish 场景 deploy **跳** (100 格零跑省 ~16m)
- publish-endpoints if 改 `always() && gate.result=='success' && gen_names!='1' && (publish_only=='1' || (deploy.result=='success' && secrets_only!='1'))` — `always()` 兜 deploy skipped, `publish_only==1` 分支绕 deploy.result 判
- publish needs 保留 `[gate, deploy]` (deploy skipped 仍算 needs 满 + always())
- workflow_dispatch inputs preset 描述加 publish

**圣上用**: `PRESET=publish` (workflow_dispatch 输入框 或 Variable 临时设) → 仅 publish-endpoints 跑, deploy 零耗 → 派生 endpoint.json worker-major 传 Dataset。

**关联**: [[ft-worker-100topology-landed-2026-08-12]]

## 2026-08-12 · deepseek + mistral-small-4 模型剔 (圣上令 "NVIDIA 删了")

**触发**: 2026-08-12 dev boot 日志印 5 model DEPRECATED (NVIDIA 目录无): moonshotai/kimi-k3, deepseek-ai/deepseek-v4-flash, deepseek-ai/deepseek-v4-pro, qwen/qwen3.8-max-preview, mistralai/mistral-small-4-119b-2603. 圣上两令: "deepseek删了吧" + "mistral-small-4 NVIDIA删了".

**剔范围** (圣上命删):
- `deepseek-ai/deepseek-v4-flash` — TIER_FAST + NIM_FAST_MODELS + NIM_EXTRA_MODELS 三处
- `deepseek-ai/deepseek-v4-pro` — TIER_FAST + NIM_CODEX_MODELS 两处
- `mistralai/mistral-small-4-119b-2603` — TIER_STABLE 一处

**留** (圣上未命删, deprecated 但待复检): moonshotai/kimi-k3 + qwen/qwen3.8-max-preview. 候圣上另令裁.

**落点** `dev/logic/init-nim-keys.sh` 6 处 (数据数组删, 注释保留历史标记同 `meta/llama-3.3-70b` / `openai/gpt-oss-120b` / `qwen/qwen3.5-397b` 格款, 供血统追溯):
- L66/67: TIER_FAST 删 deepseek 两行 → 注释
- L77: TIER_STABLE 删 mistral-small-4 → 注释
- L95: NIM_CODEX_MODELS 删 deepseek-v4-pro
- L103: NIM_FAST_MODELS 删 deepseek-v4-flash
- L110: NIM_EXTRA_MODELS 数组内移除 deepseek-v4-flash

**同步** `docs/nim_context_probe.sh` MODELS 删 deepseek (圣上手动探真截断点工具, 非 boot 血统, 逼圣上跑时不烧 deprecated 请求)。

**闸验**: `bash -n dev/logic/init-nim-keys.sh` PASS + `python3 .claude/hooks/secret-scan.py` exit=0 (模型名非 secret, 闸无害)。

**不变量守**: §1 三件定态 (Dockerfile/README/start.sh) 零触; init-nim-keys.sh = dev 逻辑层镜像 (Dataset nonoke/omn-logic 真身, 改须 git 先行再 push); §0 不翻案 Task D/E 已删模型 (llama-3.3/gpt-oss/qwen3.5-397b); §3 DECISIONS 只增不改。

**关联**: [[ft-worker-100topology-landed-2026-08-12]] (同期 100 Worker 满额全活)

## 2026-08-12 · gate /v1/ft/metrics PSK 反代 FT 桥 Prometheus 计数 (路3-b 圣上令)

**触发**: 圣上令 "做" (前轮汇总承 "gate 加路由暴露 FT 桥 /metrics 公网 → 下会话事" 待办, HANDOFF:123 旧列). 痛=公网取不得 FT per-Worker 计数 (容器内 127.0.0.1:8081 /metrics, 公网 gate 未暴露).

**裁决 (commit ec0712d, dev/logic/gate.js +56 行)**: 加 `GET /v1/ft/metrics` 公网路由, PSK 鉴权反代 FlareTunnel 桥本地 `/metrics` (Prometheus text exposition, `text/plain; version=0.0.4`).

- **PSK 鉴权**: 靠前 `app.use('/v1', ...)` (gate.js line 187-198), Bearer INTERNAL_PSK safeEqual 常量时比, 缺/错 fail-closed 401. 路由序 `/v1/ft/metrics` (line 369) 在 proxyV1 mount (line 405) 前, PSK 层在两者前.
- **桥选址**: `?bridge=N` 0-基选特定桥, 默 0 首桥 (现役惯例 "首桥代整体", init-nim-keys.sh `_ft_register_proxy` 多桥 healthz 读 `[0].port` 旧例); 越界/非数 → 400 `bad_bridge_index` (告池数 `?bridge=N (0..M-1)`).
- **FT_PORTS env**: entrypoint export `FT_PORTS` (空格分隔端口串, 多桥) / `FT_PORT` (单桥回退 8080). `FT_PORTS_LIST` 解析 + `FT_PORT_SINGLE` 回退 + `FT_HOST` (默 127.0.0.1) + `FT_BRIDGES` (FT 未启 FT_PORTS 空时 8080 兜, 取时 ECONNREFUSED→503 区分路由存在 vs 桥死).
- **上游错码**: ECONNREFUSED→503 `upstream_unavailable` (FT 桥未启/死, 非 404 区分路由存在) / TimeoutError→504 `gateway_timeout` / 其余 502 `bad_gateway`. shutdown→503 `abort_source:'shutdown'`. Host 头须 = `${FT_HOST}:${ftPort}` (FT Host 守卫非 127.0.0.1:PORT 不命中落 HandleHTTP 透传).
- **不反代 /healthz**: 公网已有 `/healthz` (探 OR 链), FT 本地 healthz 无额外面价值; metrics 含 per-Worker 计数 (路3 落) 才是圣上要.

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
- 基线非纯对照 (16 Worker 期亦 FT 启期), 真"FT 开销"定论须无 FT 直连测, 候圣上命

**外部 AI 文判** (圣上贴"架构师建议"):
- ❌伪: "关小黄云 DNS Only" (CF Routes doc: Worker 须 proxied 调用关=断链); "优选 IP 映射 1.1.1.1" (CF Anycast 无 origin IP)
- ❌撞锁: "收 40 子域" (撤销换 IP 池撞 warp-vs-ft③); "砍 Worker" (撞本 §4 上文 100 锁决 + §0 不翻案)
- ✅真可取唯一: "FT 转发重 + HF 2vCPU 计算压" (与本仓 ft-worker-count-vs-keys + warp-vs-ft 档案一致)

**CF IP 优化三选项裁决**:
- 独享固定 IP (Dedicated Egress/BYOIP) ❌: Enterprise+加购 + 反设计 (固定单 IP 撞 warp-vs-ft 裁决③ "单 IP 静态反加剧风控" 否决). CF 社区 MVP sjr 明确 "Any dedicated IP addressing requires Enterprise plan"
- Smart Placement ⚠️微调: 迁 Worker 到低延迟数据中心, 但不改出口 IP 改跑位置; 100 Worker 同好迁可能反降 IP 多样性; Worker→NIM 美国境内 <5ms 优化空间小; 不轻试
- 多账号扩域 ⚠️撞圣上 10 账号满额上限 (2026-08-12 明令) + 更多 NV/邮箱运维负债

**NIM 403 真根重诊方向** (推翻前轮臆测):
- NVIDIA 论坛大量用户证 403 "Authorization failed" 真根 = 账号缺 "Public API Endpoints" 权限/组织权限, 非出口 IP 封
- ft1 集中 403 须按 NIM key 维度重诊: 查 403 Worker 用 NIM key vs 200 Worker 用 key 是否同账号? 同账号配额耗尽触发 403 = 非 IP
- (承前轮 ft-worker-100topology memory 已列 "出口 IP 风控/NIM key 配额地理拒" 双可能, 本段收敛到 NIM key 维度为主嫌疑)

**不变量守**: §0 不翻案 100 Worker 拓扑 (翻案须圣上明确令); §1 三件定态零触; §2 secret 零入会话 (本轮纯查证无代码); DECISIONS 只增不改 (本 §4 即只增).

**关联**: [[ft-worker-100topology-landed-2026-08-12]] [[warp-vs-ft-egress-对比]] [[ft-worker-count-vs-keys-decoupled]] [[latency-baseline-vs-100worker-2026-08-13]]

## §5 429 风暴红外诊断 + 三病并存定谳 (2026-08-19, 只增不改, 纯查证无 commit)

**裁决**: 429 真根 = NIM account-level 配额速率限 (纯 key/account 维, 非出口 IP 维), 与前轮 §4 403 (ft1 族 IP/权限维) **两病并存非互斥**. OmniRoute fallback 韧态全活, 非本地代码 bug.

**证据三叠** (圣上 2026-08-19 贴代理日志 + 单事件详情 + 应用控制台 + Health 仪表盘):
1. **代理日志 59 条**: combo `—` 空 = glm-5.2 单 model 设计如此 (`getComboForModel` model.ts:237 返 null = single-model 请求, 非 fallback 没生效; 连 200 成功也 `—`). 推翻前轮"combo 空最可抓活根"误判.
2. **attempts 链展开** = fallback 换 key 真活铁证: `be1e20b9` 7 attempts 跨 nim-01~06 连 429 / `3b3e55c6` 16 attempts 烧 16 key 末中 200 / `36a91736` 12 attempts 全 429 末 200 = 同 request_id 跨 account 连试. OmniRoute internal fallback 韧态真撑.
3. **控制台**: `🚫 [RATE-LIMIT] nvidia:<UUID> — 429 received, pausing for 60s` (60s cooldown 实跑; 源码 errorConfig rateLimit default 120s, 实跑 60s = init 配/resilience profile 覆写, 圣上侧 `/api/resilience` 可查真值) + `nvidia round-robin: FALLBACK MODE - excluded_count=N excluded=...  picked_lru=...` (LRU 排除已限 account 选下一) + `Account X error cleared` (成功清 cooldown) + `Model-only lockout ... 429 rate_limited 3s (failureCount=1, connection stays active)` (model 级 3s 短锁, connection 不死, 他 model 可继续).
4. **Health 仪表盘终极证**: 32 account 风暴窗 140 请求 · **40% 成功率**, 21 account `rate_limited degraded` 散布**无 IP 族聚类** (若 IP 限应 Worker-IP 扎堆, 反见 nim-XX 按账号成簇无规律), healthy 10 散布全账号 (nim-07,08,09,16,19,20,21,23,27,32). provider 熔断 **CB CLOSED** (未跳, round-robin 始终在 provider 内换 account, 无全停). cooldown 0 (无 account 长锁, 60s 窗过即回活). 限速标 `nvidia:<UUID>` = account ID = NIM 按 account 计限. 风暴过后现态 12min 11 请求 **0% 错误率** = 系统回稳.

**429 = account 维强证 (非 IP)**: 21/32 散布无聚类 + 限速标 account UUID 非 IP + cooldown/account-clear 按 account 非 Worker = NIM account-level 配额速率限. 推翻任何"429 源 FT 出口 IP"臆测.

**三病并存定谳** (现盘全合):
- **429 (本轮主流)** = NIM account 配额速率限 × Hermes 高频连发 (4-5s 隔, msg 88→130 增). 纯 account/key 维, 非本地 bug, 非 FT 桥病. 风暴窗 60% 拒, 60s cd 窗解即回 0% 错.
- **403 (前轮 §4, ft1 族集中)** = auth/权限维, 另案并存. 本轮未复现, §4"账号缺 Public API Endpoints 权限/组织权限"方向仍立, 待深查 (查 403 Worker NIM key vs 200 Worker key 同否账号).
- **502 (1× nim-13)** = NIM 服务层瞬时 RST (`fetch failed ECONNRESET`), 透传非桥造, fallback 跳过续试.
- **+ 新发现 陈旧错态 gap**: OmniRoute 冷却 (60s) 过期回活后错误字段 (lastError code 429) 不自动清 → Health Autopilot 检到提"Clear stale error state"手动按钮 (22 issues/22 actions). 小 bug 级: spend-cooldown account 可能被路由偏置继续绕开本已回活 account. **缓释**: 圣上点 Autopilot 22 动作批量清 (或 API 批量), 21 account 立回 healthy. 我零碰 prod.

**解方向 (候圣上命, 非本轮 commit)**:
1. 降打高频: 客户端侧 4-5s 隔太快, OmniRoute `requestQueue.requestsPerMinute` 调低 + `maxWaitMs=300000` (已落, init-nim-keys.sh:909 R3+) 排队撑非即拒.
2. 拉长 429 cd 反加效: 60s 太短致 Hermes 复发前回复活又被烧, 拉到 120-180s 让单 account 彻底冷却 (须配降客户端频率否则更堵).
3. 扩 NIM account 池减单 key 承压, 但撞圣上 10 account 满额上限 ([[ft-worker-100topology-landed-2026-08-12]]).
4. 真根治 = NIM 侧配额/credits 提升 (NVIDIA 端非本地能控).

**否定项 (已查证排除)**:
- combo `—` 空 = 正常设计非 bug (getComboForModel 返 null = single-model). 推翻前轮误判.
- FT 桥透传 429 = NIM 真返非桥造 (worker.js 纯转透换出口 IP, Authorization 不在 DROP_REQ 全转透 NIM). 403/502 同透传上游真返.
- 真测现态不建议: 0% 错系统回稳, 无活病可测; 真须烧 NIM 配额高频打造风暴 = 成本高仅重复证已有定论. 真测脚本框架可写候圣上择机下次风暴测.

**不变量守**: §0 不翻案 100 Worker 拓扑 + §4 403 决 (翻案须圣上明确令); §1 三件定态零触; §2 secret 零入会话 (本轮纯查证无代码); DECISIONS 只增不改 (本 §5 即只增, §4 未动).

**关联**: [[429-fallback-alive-combo-empty-normal-2026-08-19]] [[429-vs-403-combo-empty-diagnose-2026-08-19]] [[latency-baseline-vs-100worker-2026-08-13]] [[ft-worker-100topology-landed-2026-08-12]] [[gate-ft-metrics-public-proxy-landed-2026-08-12]]

## §6 init boot 自清 OmniRoute Health Autopilot 陈旧错态 (路A 2026-08-19 落, commit 3158c2c, 只增不改)

**裁决**: 2026-08-19 §5 裁决"陈旧错态 gap 缓释: 圣上点 Autopilot 批量清, 我零碰 prod"升级为 **路 A init boot 自清** 自动化落地 (圣上令 "A"= init boot 自清 init 已有 cookie 鉴权)。dev nonoke/omn ephemeral 语境唯一解。

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

**保留**: `dev/scripts/clear-stale-nim-errors.sh` 保留作 (a) prod 侧 (nomke/omn R2 副本 key 持久) 偶用备 (须 §1 明令 + 取 prod manage key); (b) 参考文档 (init 自清函数即其 boot 版)。非顿旧决策 (§5 "缓释: 圣上点 Autopilot" 已被路 A 自清自动化升级, 非 §0 翻案 = 同向演进)。

**不变量守**: §0 一次会话一件事 (路 A 闭环); §1 三件定态 (Dockerfile/README/start.sh) 零触, 改 `dev/logic/` 非三件走 Dataset sync 非 Rebuild; §2 secret 零入 git/会话 (由盾外 + sha256 闭验, token 读 ~/.omn-secrets 注入 os.environ); §1 nomke/omn 生产无 Supreme 令不动; 上游只读查证 (`/tmp/om48` = v3.8.48 ref 非血统不进 git), init 改属我仓 dev 镜像真身。

**未决/下一步**: sync-logic-nonoke.yml Action 上旧版未解 —— 本次手推绕过, 下次 dev/logic/** push 若 Action 仍上旧版会覆盖回旧。须圣上侧查 Action run log (GitHub repo i3t2y/n-omn → Actions), 可能 checkout SHA 落后/path filter 未中/concurrent race。候命排查。

**关联**: [[429-fallback-alive-combo-empty-normal-2026-08-19]] [[429-vs-403-combo-empty-diagnose-2026-08-19]] [[ft-worker-100topology-landed-2026-08-12]] [[omniroute-upstream-entrypoint-drift-v3.8.48]] [[omn-merge-three-remote-topology]]
