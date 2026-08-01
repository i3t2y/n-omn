# ops/DECISIONS.md · omn 决策只增不改

> SSOT 决策层 (§3): 只增不改的裁决账本。翻案须 Supreme 明确指令 (§0)。冲突以 HANDOFF.md 为准, 其次本文件。
> 冲突次序: HANDOFF.md > DECISIONS.md (CLAUDE.md §3)。
>
> ⚠ 本文件 2026-07-31 新建。**旧决策全集尚未回填** (散落 audit/ / ops/incidents/ / ops/STATUS.md 段内, 未迁入)。新建前决策仍以原载体为真源;
> 本文件先承载 2026-07-31 起新决策, 旧决策回填留圣上令 (避免半建误导 / 翻案误触)。

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

<!-- 旧决策回填区 (待圣上令, 散落 audit/ / ops/incidents/ / ops/STATUS.md 段内未迁入) -->
