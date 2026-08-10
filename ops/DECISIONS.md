# ops/DECISIONS.md · omn 决策只增不改

> SSOT 决策层 (§3): 只增不改的裁决账本。翻案须 Supreme 明确指令 (§0)。冲突以 HANDOFF.md 为准, 其次本文件。
> 冲突次序: HANDOFF.md > DECISIONS.md (CLAUDE.md §3)。
>
> ⚠ 本文件 2026-07-31 新建。**旧决策全集尚未回填** (散落 audit/ / ops/incidents/ / ops/STATUS.md 段内, 未迁入)。新建前决策仍以原载体为真源;
> 本文件先承载 2026-07-31 起新决策, 旧决策回填留圣上令 (避免半建误导 / 翻案误触)。

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
