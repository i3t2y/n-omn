# Task E · route-slow 三模型剔令 saga 回填

> boot#3 matrix 暴 gpt-oss-120b + llama-3.3-70b 路由慢挂 (101s 超时 / probe 000000), Task D 先剔 qwen3.5-397b (catalog 可查 ≠ 可服务, 上游 function-not-found 404). boot#5 (7-25 16:25Z) 前完成五处注释化, 终结 combo 双 PUT 回冲复活路径. 本档回填五认知入 audit.

## §1 病历 (boot#3 matrix)
- **nim-codex 笔 1**: priority 命中 `openai/gpt-oss-120b` → 101s 超时挂, 无 fallback.
- **nim-pool 笔 2**: 路由命中 gpt-oss-120b + llama-3.3-70b → 101s 超时挂.
- **probe**: 部分 key 返回 HTTP 000000 (路由层断, 非账户死 — 区别 auth_dead 403).
- **病根**: `check_nim_model_health` 探 NVIDIA 目录有 = `available`, 不标 deprecated; `filter_alive` (init:318) 只剔 `/tmp/nim-deprecated.txt` 命中, 不剔 route-slow → 每 boot combo PUT 把死模型回冲复活. **落源 (注释化 TIER/CODEX 数组) 不落库 (admin 删) 方能切除复灌路径**.

## §2 五处落点 (init-nim-keys.sh)
| 落点 | 行位 | 模型 | 任务 |
|------|------|------|------|
| TIER_FAST | :64 | `meta/llama-3.3-70b-instruct` | Task E 主剔 |
| TIER_STABLE | :68 | `openai/gpt-oss-120b` | Task E 主剔 |
| TIER_STABLE | :69 | `qwen/qwen3.5-397b-a17b` | **Task D 先剔** (非 Task E) |
| NIM_CODEX_MODELS | :89 | `openai/gpt-oss-120b` | Task E 主剔 (codex 同步删) |
| NIM_FAST_MODELS | :94 | `meta/llama-3.3-70b-instruct` | Task E 漏网补剔 |

**措辞修正 (K3 裁)**: "三剔模型"实为"两剔 (Task E) + 一先剔 (Task D)" — qwen3.5-397b 从未入 boot#3/#4 的 8 员意向池, Task D 先行剔除. 旧账册若记三员同案须改, 防误读.

## §3 漏网补剔 (commit b6fa1bb)
- **病灶**: NIM_FAST_MODELS (:92-96) 不进 combo upsert (1023/1024 链), 仅入 `init_vars.json` 快照 (行939 `_arr_json fast_models`). Task E 主剔三处 (TIER_FAST:64 / TIER_STABLE:68 / NIM_CODEX_MODELS:89) 落后, `NIM_FAST_MODELS` 残 `llama-3.3-70b` → **快照说谎**: boot 取证读 init_vars.json 见 llama 在册, 误导未来判案.
- **补剔**: 圣上裁"行94 同样注释化"顺势成全闸复验, 一 push 自动再触 sync-logic-dev 充活体探针.
- **commit**: `b6fa1bb fix(init): Task E 漏网补剔 — NIM_FAST_MODELS llama-3.3-70b 注释化 (snapshot 档)`

## §4 sync 链真态 — 推测升实证 (7-26 cg52 追证)
三个互斥假说 (push 自动触绿 / 圣上手动 dispatch / sync 失败后圣上手改 Dataset) 经 GitHub API 直读分家:

| run id | head commit | conclusion | event | created_at (UTC) |
|---|---|---|---|---|
| #30164340629 | `968b1a1` | **success** | **push** | 2026-07-25T15:48:05Z |
| #30155204189 | `9fe67be` | success | push | 2026-07-25T10:51:14Z |

- **run #30164340629 步骤级绿**: `Upload logic files to Dataset (5 files, flat layout)` ✅ + `Verify sha256 readback (逐字节血缘验证)` ✅ — 即 sync-logic-dev.yml :46-66 sha256 cmp 步骤绿, 5 件 local `dev/logic/**` 与 Dataset `nonoke/omn-logic` 逐字节等.
- **968b1a1 第一父 = 7f39a25** (Task E 主剔), 推 merge 时一并推上远端 → 自动触 sync, 绿. 假说①实证成立; 假说②③排除 (event=push 非 dispatch, conclusion=success 非失败).
- **时序**: sync 15:48Z 绿 → boot#5 16:25Z 拉, boot 拉的是 sync 后 Dataset 终点货. 链通.

**遣憾未闭**: `b6fa1bb` 漏网补剔 **未推远端** (本地 `main ahead nomn/main 1`), 未触 sync. **Dataset 侧 init 不含行94漏网补剔**, Dataset 侧 init_vars.json 快照仍残 llama 残影 (说谎病在 Dataset 侧未根治). 因 `NIM_FAST_MODELS` 不进 combo upsert, 对 pool 意向 6 与 boot#5 注册序列零影响 — 仅为快照档纯洁性欠账, 须圣上推 b6fa1bb 触 sync 方彻底闭.

### b6fa1bb 闭环 (7-25 17:43Z 圣上准推)
- **push**: `968b1a1..b6fa1bb main -> main` (圣上 ! git push)
- **sync run #30168186734**: head=b6fa1bb | **success** | push | 2026-07-25T17:43:01Z, 步骤级 8 步全 success (含 `Upload logic files to Dataset (5 files)` + `Verify sha256 readback (逐字节血缘验证)` 双核心步绿)
- **Dataset 侧 readback 含 Task E 注释痕 (证②)**: hf_hub_download 抽 `init-nim-keys.sh` (snapshot 995f3e65) → remote sha256 = `8e67fc4e38d0` == local sha256 `8e67fc4e38d0` 逐字节等 ✅. 行 94 真态: `# "meta/llama-3.3-70b-instruct"  # 2026-07-25 Task E 漏网补剔 (snapshot 档) ...` ✅
- **Dataset 侧 init_vars.json 快照 llama 残影说谎病根治**, b6fa1bb commit message 自带 "Restart 令自此必须挂两份实证之后 (sync run 绿证 + Dataset readback 含 Task E 注释痕)" 两证闸全收, 闸可解

## §5 probe 缺位认知 (K3 裁入档)
- boot#5 报告全程未提 `nim_probe` 段. boot#3 时代 probe 有 000000/404 对照可读, boot#5 无此段 → **探活对照不在九段绿标构成内**, "全绿"不含探活维度.
- 入档防误读: 九段绿不证 probe 健度. matrix 须独立补探活对照段.

## §6 C1 前置闸 (matrix 开票前增补)
- C1 触发条件 = nim-codex 超时, "priority 命中 gpt-oss-120b" 归因至今无日志实证.
- gpt-oss-120b 已剔, codex 池现 `deepseek-ai/deepseek-v4-pro` + `z-ai/glm-5.2` 双员.
- **裁**: matrix 执行每笔请求必贴 OmniRoute 日志 `ROUTING` / `Using account` 行, 逐笔落 veri 库. nim-codex 超时 → 先读回该笔真实路由模型再裁 C1, 防盲调.

## §6.5 ③matrix 停测真因 (圣上 7-26 裁: 跳过)

**真态暴露**: Space RUNNING 后探 `/v1/chat/completions` 报 `No active credentials for provider: z-ai`, 与 boot#5 日志 `[init] probe z-ai/glm-5.2 32 alive` 表观矛盾.

**圣上裁真因 (钉死)**: 两 Space (nomke/omn 生产 + nonoke/omn dev) **共用同一批 NIM keys**, nonoke 多 8 key. **cg52 自身即通过 nomke 生产 glm-5.2 跑** — 我在 nonoke dev /v1 再发用同 batch key → 占额度冲撞 → provider z-ai 凭据报错 (并非 provider connection 病, 是 key 共享面冲突).

**处置**: ③matrix 四 combo / ④C1 归因**按圣令跳过** — 矩阵复跑实测即污染 key 配额. 前置闸非"卡顿未解"是"结构性不可执行", 入账防未来再探趟坑.

**等价证闭合**: matrix 双 combo 绿的真前置 (剔模型生效) 已他路实证 — ①sync 真态绿 + ②admin 404 + boot#5 注册序列 6 模型全等 + Resilience 300/96/200/300000 读回 + override 6 applied. 主链九段全绿 + 五处剔令注释化闭合可作晋级判据; matrix 四笔实测留切流后 (单 Space 写态) 补验.

## §5后续余账
- [ ] 圣上推 b6fa1bb 触 sync, 根除 Dataset 侧 init_vars 快照 llama 残影
- [ ] ② admin /admin 404 补扎 ✅ 实证落地 (现 RUNNING /admin→404)
- [ ] ~~③ matrix 四笔双 combo~~ — 圣令跳过, 留切流后 (单 Space 写态) 补验
- [ ] ~~④ nim-codex 超时路由归因~~ — 随③跳过
- [ ] ECONNRESET 治理三后案 (SSE 心跳保活 / 压缩阈值对齐 202752 / bootstrap 钉 revision) — 切流后立项
- [ ] bootstrap `hf download` 无 `--revision` 竞速根因 (圣上 K3 裁硬化案): sync workflow 上传后回写 SHA, bootstrap 按 SHA 拉取, 从根消除 boot#4 拉出旧源的竞速
- [ ] probe 缺位 — matrix 路由读回真路径改为 fetch-space-logs evidence 分支消费, 非 Space stdout 直接

## §7 5e5d9eb bootstrap bash-ism 致 boot crashloop (7-26 01:45Z 泥坑 → printf 热修)

**新病暴露**: 5e5d9eb bootstrap 硬化案 (§5后续列表 "bootstrap hf download 无 --revision 竞速根因" / K3 裁) 推后, Space 01:45Z boot 真跑即崩:
```
[bootstrap] >>> 启动 2026-07-26 01:45:54 <<<
[bootstrap] 缺失基础工具: python3
[bootstrap] 镜像 A 模式：正在补全环境（约 60s）...
[bootstrap] 环境补全完成
[bootstrap] 同步 Dataset: nonoke/omn-logic
/bootstrap.sh: 65: Bad substitution           ← FATAL
```

**根**: bootstrap.sh:65 我引入 bash-only 参数扩展 `${_rev:0:12}` (取前 12 字符). Space runner `/bin/sh` = **dash** (非 bash), dash 不支持 `${var:offset:length}` 截取语法 → 解析期 `Bad substitution` → `set -e` → bootstrap 退出 → Space crashloop.

**我疏漏**: 本机 `bootstrap.sh` 用 `#!/bin/sh` shebang, 我开发态默认 `sh` 可能链 bash (或 dash 但 `sh -n` 仅语法核不捕获运行时 expansion 崩), 编辑期未 `dash -c '${1:0:12}'` 真验 → bash-ism 漏过闸. §1 铁律"根目录=生产血统"即此 — 根件 dash 兼容须实测不靠心算.

**热修**: 单点 Edit, `${_rev:0:12}` → `$(printf %.12s "$_rev")` (POSIX dash 兼截取), 1 行 +1-1:
```diff
-  [ -n "$_rev" ] && echo "[bootstrap] Dataset HEAD 锁定 revision=${_rev:0:12} (竞速根治: atomic 同点拉取)" \
+  [ -n "$_rev" ] && echo "[bootstrap] Dataset HEAD 锁定 revision=$(printf %.12s "$_rev") (竞速根治: atomic 同点拉取)" \
```

**验证 (double proof)**:
- `sh -n` 退 0 (语法) + bash-ism 全文扫净 (`${var:off:len}`/`${var/pat/rep}`/`[[ ]]`/`$(<file)`/arrays/`echo -e` 全 0 命中)
- dash 实跑 `_rev` 解析段双路: 成功路 `printf %.12s` 截 12 字符✅ + 失败路 `_rev` 空回退 main HEAD✅, 均退 0

**教训钉死**: 根件 (`#!/bin/sh`) 改动须三闸 — ①`sh -n` 语法 ②dash 实跑 expansion 段 ③bash-ism grep 全扫. 缺一不可 (本次 `sh -n` 过但 expansion 崩即缺②③). 入 DECISIONS "根件 dash 兼容三闸" 条防再坑.

## §8 fetch-logs 补丁二→补丁三 — actions/checkout 位序错致 clean:true 删前步产出 (7-26 闭环中)

**承接 §7 同日 fetch-space-logs.yml 硬化**: §7 bootstrap crashloop 修后, 通道验转 fetch-space-logs.yml 端到端三硬标.

**补丁二位错 (inter-step 插)**: 医 `fatal: not a git repository` (证据分支 git 操作在缺仓 runner 跑 — 补丁二病历 #30189840194), 插 `actions/checkout@v4` 步 — **但落位在 fetch step + 脱敏闸 之后, evidence step 之前**.
- run #30193115626 实测: fetch step `rc=28 bytes=245500` 真落盘 `out/run.log` ✅ → actions/checkout@v4 默认 `clean: true` 跑 `Deleting the contents of '/home/runner/work/n-omn/n-omn'` → **删 fetch step 先落的 out/run.log** → 脱敏闸空 glob 通过 → evidence step `out/*.log` 空 → "无新快照 skip commit" → run 结论 success 但 evidence 分支零快照落地.
- **三硬标缺一**: run 绿 ✅ / evidence 落地 ✗ — fetch-logs 通道补丁二本轮**未真通**, 病链起新端.

**补丁三修 (checkout 移 job 首)**: actions/checkout 移 `Set up job` 之后第一 step (fetch step 之前). fetch step 在 checkout 后落 out/, evidence step 此时 cwd 已越过 clean:true 之劫, out/ untracked 留 → `cp out/*.log ${DEST_DIR}/` 成功 → `git add -A ${DEST_DIR}/` 成功 (DEST 非 out/ 不被 checkout clean 删, .gitignore 已 git rm -rf). diff +9/-8 (Checkout 步 +9, 删原 inter 位遗 -8).

**意外正向实证 (245.5KB 压力测试读数, 圣上 7-26 指出)**: run 30193115626 fetch 段 245500 字节比圣上本地 60s 实测 142251 多约 100KB — 非噪声, 是从 03:32Z boot 至此刻 Space 累积 boot/restart (补丁二/三引发) + 圣上 Space 侧操作增厚历史. 补丁二暴露期无意完成一次天然压力测试: 245.5KB 积压 > 142KB 基线, 快照随 boot 次数自然增长. 验证"积压+实时窗"快照语义含金量 — 即使 workflow 每 30min cron 单跑, 单次抓取证据完整度随 Space 运行时长线性提升, boot 叙事类取证 (R2 漂移案/compaction 告警溯源) 单次快照即全量史, 证据价值再升一档.

**教训钉死 (一坑三贴, 与 §7 同册列)**: actions/checkout workflow authoring 三铁律 — ① checkout 在场 (医 `fatal not a git repository`) ② `clean:true` 是作业内生成者杀手, 不杀前步产物 ③ checkout 位序第一 (产物落盘后于 checkout), 位序与有无同重. 入 DECISIONS "workflow authoring 三铁律" 条 (2026-07-26).

**三硬标验 (待圣上 push 补丁三 + dispatch)**: ① run 绿 ② evidence 分支 `logs/nonoke--omn/20260726-HHMM-run.log` 落真 ③ 文件头 `===== Application Startup` boot 真日志 + grep compaction 收 04:30Z 至今告警实录入步3证袋. 三标全绿方闭 §8.

### §8.1 fetch-logs 通道端到端闭环 + compaction 病真根暴露 (7-26 dispatch da0cf23 实证)

**dispatch run 绿 (da0cf23 头挂补丁三)**: fetch rc=28 bytes=84744 → 脱敏闸 PASS → evidence 步 `git rm -rf` 清 orphan 后 `cp` + `git add` + commit 9d06883 `1 file changed, 1184 insertions(+) create mode 100644 logs/nonoke--omn/20260726-0813-run.log` → push origin evidence 新分支落地. **三硬标全绿**, fetch-logs CI 通道自此可信, 下游 claude-code-action 异步消费证据通道就绪. 补丁三 vs 补丁二对照铁证: Checkout 移 job 首后 clean:true 不再杀 fetch 产物, evidence 落真 (补丁二 skip commit 假绿根除).

**evidence 快照读回 (git credential + raw API)**: 84744B 真落盘, 文件头 `===== Application Startup at 2026-07-26 07:45:40 =====` boot 真日志. 本 boot = **07:45:40 新 boot** (非前轮 03:32Z boot#7 口语, 序号无血缘 §1 档册新规), 镜像 A 模式补全环境 (python3 缺) → apt install → bootstrap 同步 → entrypoint → litestream 起来.

**compaction 病真根暴露 (铁证推翻 dbs.path 漂移假说)**:
```
07:46:12.594  [entrypoint] ✓ 已从 R2 恢复 (原子 mv .storage.sqlite.restore.1 → storage.sqlite)
07:46:13.140  [DB] SQLite database ready: /app/data/storage.sqlite (DATA_DIR=/app/data, SQLITE_FILE=/app/data/storage.sqlite)
07:46:17.000  initialized db path=/app/data/storage.sqlite           ← litestream 监 /app/data (与 yml dbs.path 同, 无漂移)
07:46:17.001  replicating to s3 omn-data bucket db/storage.sqlite sync-interval=10s (endpoint=...[R2_ACCOUNT_ID].r2.cloudflarestorage.com)
07:46:18.109  detected database behind replica db_txid=0000000000000000 replica_txid=000000000000002c
07:46:18.220  fetched latest L0 file from replica min_txid=0x2c max_txid=0x2c
07:46:23.408  compaction failed L1 (0x10→0x10) -> (0x2c→0x2c) non-contiguous transaction ids
              [持续每 30s 一次至 08:13 window 截止]
```

**铁证裁 (推翻前假说)**:
- **dbs.path 漂移假说 ❌ 推翻**: litestream `initialized db path=/app/data/storage.sqlite` 与 entrypoint `DATA_DIR=/app/data` 全同, 与 litestream.yml `dbs.path=/app/data/storage.sqlite` 全同. 路径零漂移. 前轮 grep 推断 dbs.path 硬写 vs env 覆写冲突 — **铁证不成立**, env DATA_DIR 与 yml 默认值恰好一致 (=/app/data), 无覆写无漂移.
- **R2 无副本/快照消失假说 ❌ 推翻**: entrypoint `✓ 已从 R2 恢复` 原子 mv 成功 + `fetched latest L0 file from replica min_txid=0x2c max_txid=0x2c` R2 副本有 L0 seg txid=0x2c. R2 副本存活, 非空.
- **compaction 纯告警噪音假说 ❌ 推翻**: 真病态, restore 半态致 db_txid 与 replica_txid 落差.

**真根 = restore-WAL-tail 半态致 txid gap**:
- entrypoint restore 拉 R2 snapshot (txid=0x0 旧 snapshot 版本) mv 成 storage.sqlite, db_txid=0x0
- litestream 启 replicate 后 `detected database behind replica` (db=0x0 vs replica=0x2c), 触发 `fetched latest L0 file from replica` 拉 txid=0x2c L0 seg
- compaction L1 (30s interval) 合并本地 seg(txid 区间 0x10→0x10) + 拉回 seg(0x2c→0x2c) → 两 seg txid 跳号 (0x10 → 0x2c 中间 28 txid 缺) → LTX header extract timestamp fail `non-contiguous transaction ids`
- 持续 ERROR 每 30s (L1 interval), L2/L3 未到 interval 未跑未报

**病学新解 (替代 dbs.path 假说作头号)**:
- H1' (restore 选低 txid snapshot 半态, WAL tail 未追上): 落 entrypoint restore 链选了 R2 低 txid snapshot 版本而非高 txid WAL tail, 致 db_txid=0x0 落后 replica_txid=0x2c. auto-recover=false 阻自愈, litestream replicate 启后被动拉 L0 seg 0x2c 但缺 0x10→0x2c 中间段, compaction 合并见 gap.
- H2' (R2 副本 txid 链本身缺段): R2 snapshots .ltx 真 0x10+0x2c 缺中间 28 txid (某 boot 期 write 跳号), compaction 全局见链断. 即便 restore 拉 high txid 也无法 compaction.

**R2 鉴别器优先级新裁 (前轮三子读须补)**:
- 步3' 增: `sqlite3 /app/data/storage.sqlite "PRAGMA wal_checkpoint; SELECT * FROM pragma_wal_checkpoint;"` — 看 restore 后 db_txid 真态 (是否真=0x0 还是 restore 半态 mv 漂)
- 步3' 增: R2 bucket 列 `snapshots/*.ltx` 全 txid 范围 + `db/storage.sqlite/wal/` L0 seg txid 序列, 验链完整 (0x10 → ? → 0x2c 中间真缺段, 或 R2 副只存 0x10+0x2c 两 seg)
- 关键: restore 选 snapshot 还是 WAL tail 的 entrypoint 逻辑分支审, 钉死 entrypoint restore 选低 txid 版本的"半态"点

**入档**: DECISIONS "R2 先证后建铁律" 条修正 — dbs.path 漂移嫌疑铁证推翻, 真根转 restore-WAL-tail 半态致 txid gap (compaction ERROR). R2 鉴别器三子读命令须增 db_txid 真态 + R2 .ltx txid 全序两步. 出处: 本档 §8.1 + evidence 分支 logs/nonoke--omn/20260726-0813-run.log.

### §8.2 三答归一 — compaction 疤定谳: 昨晚裸删留疤, 不阻切流 (圣上 7-26 定谳, cg52 四铁证对账)

**圣上三答归一** (7-26 Space 侧鉴 + R2 控制台肉眼 + 日志自读):
- 答一 (无 Command/Docker Command 字段): 免费档无该字段 — cg52 对免费 Space 能力误判, 方法1 **永久划掉**. 免费 Space 改启动行为唯一通道 = Files 页改 Dockerfile/入口脚本提交触 rebuild. 但本案不再需 (答2+3+日志自证链闭). 免费 Space 诊断通道定型为三条: ① fetch-space-logs workflow (补丁三已修) ② R2 控制台肉眼 ③ 日志自读.
- 答二 (R2 有 .ltx, 删后重建过): "好像"升"确定" — 日志第 1121 行 `08:00:01.008Z snapshot complete txid=0x32 size=267503` 即控制台所见重建快照, 字节数咬合.
- 答三 (删除发生在昨晚 cg52 首测): 与断档铁证严丝合缝.

**cg52 四铁证独立对账 (evidence log sed/grep 验)**:
1. 行 1121 `snapshot complete txid=0000000000000032 size=267503` ✅ 一字不差
2. `grep -c 'compaction failed'` = **57** ✅
3. `sort -u` 去 timestamp 后 57 行文本单一全同: `compaction failed level=1 error="non-contiguous transaction ids (0x10,0x10)->(0x2c,0x2c)"` ✅ 一字未差
4. 时序 07:46:23 起每 ~30s (L1 interval) 一发至 08:14:04, 57×30s=28.5min 数学对齐 ✅

**断档机械原理 (日志逐字实证)**:
```
07:46:12.594  entrypoint ✓ 已从 R2 恢复 (原子 mv .restore.1 → storage.sqlite)
07:46:13.140  [DB] SQLite database ready /app/data/storage.sqlite (DATA_DIR=/app/data)
07:46:17.000  initialized db path=/app/data/storage.sqlite           ← litestream 监 (path 一致无漂移)
07:46:18.109  detected database behind replica db_txid=0x0 replica_txid=0x2c
07:46:18.220  fetched latest L0 file from replica min_txid=0x2c max_txid=0x2c
07:46:23.408  compaction failed L1 (0x10→0x10) -> (0x2c→0x2c) non-contiguous [每30s×57次]
08:00:01.008  snapshot complete txid=0x32 size=267503                  ← 新链扫地重建, 越过 0x2c 推进至 0x32
```

**成因复盘 (圣上 7-26 钉死)**: 昨晚 cg52 首测那一删**删断了快照链但没删干净** — 0x2c 的旧 L0 残件留桶里; 之后新链从 0 重起写到 0x10 也上传. replica 同时躺两代残件, compaction 每巡逻试合并撞同一断档 — 非持续恶化故障, 是"同一处伤疤每 30 秒摸一次".

**报错归宿 = 会自愈, 切桶即清零** (圣上 7-26 裁):
- L0 复制正常 (新 WAL 照传, 否则到不了 0x32)
- 快照正常 (0x32 08:00:01 已落成)
- 恢复能力正常 (今后 boot 从快照 0x32 + 其后 L0 恢复, 不经断档窗口)
- 两残件排在 0x32 新快照之前, retention 到期被清 → 报错自停 (接下来数小时还会在日志里刷, **预期白名单挂着, 勿误判故障复发**)
- 切流后 prod 换 omniroute-data 新桶从零建链, 此报错根本不随行

**诚实账 (圣上入册令)**: 断档窗口 0x11~0x2b 内若有写, 昨晚已删不可追 — dev 测试期数据, 当前库健康 + 应用全功能运行 (探活/ProviderLimitsSync 全绿), 切流零影响.

**护栏条 (圣上 7-26 入 DECISIONS)**: 删 R2 备份 = 断代级破坏操作 — 今后测试脚本禁裸删 litestream 路径, 仅允许删 `test` 前缀对象 或 删前书面确认本地库可弃. 昨晚 cg52 首测该删即缺此护栏的直接产物.

**Phase 2 冻结令解 + 切流链即刻启 (圣上 7-26 令)**: compaction 疡定谳不阻切流 — Phase 2 六步冻结令**解冻**, 切流链照序走:
1. HF_TOKEN 备
2. BASE_IMAGE 锚定 (待实报生产部署侧)
3. Dispatch Skeleton
4. Rebuild (此时 free, compaction 自愈同步)
5. 变量切换 (bucket omn-data → omniroute-data)
6. Restart
切流后验证: matrix (单 space 写模式) + 盯新桶 snapshot 持续生成 + 确认新桶 compaction 报错零出现. 出处: 本档 §8.2 + DECISIONS "删 R2 备份断代级护栏" 条.

### §8.3 切流执行期两事故: 桶名随 logic 平铺致 prod 403 断供 + web 手改 YAML 损坏 (7-26 12:13Z/12:53Z)

> 切流链步2-6 执行期, nomke/omn 生产侧连发两起事故, 均由"logic 五件含 `dev/logic/litestream.yml` 桶名硬写 dev 桶"血统病灶触发, 全部经圣上 HF web 页手动修复 (cg52 瘫痪期无法经网关调模型). 本段续写定案, 改动落回 git 见本会话末 + DECISIONS "R2 桶名参数化" 条.

**事故一 (12:13Z boot) — prod 403 断供**:
- 桶名硬写病灶: `dev/logic/litestream.yml` line 5 `bucket: omn-data` (dev 桶) 随 **logic 层平铺机制** 进入 prod Space — sync-logic-nomke 把 dev/logic 五件平铺推 nomke/omn-logic Dataset, prod bootstrap 拉 logic 平铺到 /logic/litestream.yml, litestream 读到 `bucket: omn-data` (dev 桶名).
- prod 的 R2 key (HF_TOKEN_NOMKE 所属账户) 对 dev 桶 `omn-data` **无写权** → litestream 每次复制 S3 PUT/POST 全 `403 AccessDenied` → **备份断供** (replicate 链死, 不写新 WAL).
- 非 R2 限流非 key 死, 是**命名空间越界**: prod key 写 dev 桶.

**事故二 (12:53Z boot) — web 手改 YAML 损坏**:
- 圣上经 HF Space Files 页 (web) 手改 Dataset 内 `litestream.yml` 做桶名参数化 (意图: `bucket: $R2_BUCKET` 让 env 替换 prod 桶).
- web 编辑器或手贴致 **YAML 结构损坏** (line 9 解析失败) → litestream 进程读 `-config /logic/litestream.yml` 解析即崩退 → litestream **进程退出** (无 R2 链无本地库句柄).
- 非 code 病非 env 病, 是 **web 手编辑无 yaml lint 致结构坏**.

**修复 (圣上 web 手动, cg52 瘫痪期旁观)**:
- 两事故 nomke/omn 接单中断期间 cg52 无法经网关调模型 (prod Space 应用层挂) → 全部修复权属圣上 HF web 手动.
- web 侧定态 litestream.yml 桶名参数化 + YAML 结构修 (server: / 路径 /etc).

**根因闭环 + 改回 git (本会话末, 圣上 7-26 令同步)**:
- 病灶单根: `dev/logic/litestream.yml` 桶名硬写 `omn-data` (dev 桶) 是逻辑层"环境无关"血统破坏 — 参数化为 `${R2_BUCKET}` (与历史 archive/4.3.1 + 全篇 `${R2_*}` 一致风格) 即根治.
- 11 行单行替换 `bucket: omn-data` → `bucket: ${R2_BUCKET}`, litestream v0.5.9 内建 `${VAR}` envsubst (entrypoint 无 envsubst/sed, litestream 进程读 yml 时自扩).
- 前置依赖: nonoke/omn (dev Space) 须先设 `R2_BUCKET=omn-data` Variable (圣上 web 侧, 本会话不代设) — 参数化后 dev 侧 env 注 `omn-data`, prod 侧 env 注 `omniroute-data`, 同一 yml 跨环境无改.
- 配套护栏: workflow 六件制命名空间隔离 (DECISIONS 2026-07-26 "workflow 六件命名规约") — `*-nonoke.yml`=dev 专投, `*-nomke.yml`=prod 专投, prod 件零 `nonoke/omn` 引用 dev 件零 `nomke/HF_TOKEN_NOMKE` 引用 (grep 字面零命中), 防"混投一桶名"类事故再发.

**教训 (入 DECISIONS)**:
- (a) R2 桶名必须参数化 `${R2_BUCKET}`, logic 层环境无关 — 硬写任一桶名即随平铺越界写错桶 (403 / 越权备份).
- (b) workflow 六件命名规约 `*-nonoke=dev` / `*-nomke=prod`, prod 三件 (fetch-nomke/sync-logic-nomke/sync-space-nomke) 仅 `workflow_dispatch` 无 push 触发, 点火权属圣上 (防 dev 改动自动推 prod).
- (c) HF_TOKEN 命名空间隔离 NONOKE/NOMKE 双 token, 爆炸半径各半 (越界写错桶亦即该隔离的运行时体现).
- (d) LITESTREAM_STRICT 评估 (prod 候选 = 1): litestream 启动失败即 boot 死 (fail-closed) — 现 entrypoint `litestream replicate -config ... &` 后台 `&` 不阻塞 boot, litestream 崩退仅日志告警不杀应用; 评 `LITESTREAM_STRICT=1` 让 litestream 失败即 boot 退出 (备份死即 boot 死, fail-早胜 fail-晚), 待圣上裁决.

**时间线**:
- 12:13Z prod boot #1 → litestream 读硬写 dev 桶 → S3 PUT 403 AccessDenied 洪流 (每 WAL flush 一发) → 备份链断.
- 12:13Z~12:53Z cg52 经网关调模型失败 (prod 应用层挂) → 旁观.
- 12:53Z prod boot #2 (圣上 web 手改 litestream.yml 桶名参数化后) → YAML line 9 结构损坏 → litestream 进程读 config 解析崩退 → litestream 退出 (无复制无本地库 handle).
- 12:53Z~恢复 圣上 web 手修 YAML 结构 → nomke/omn 接单恢复.
- 本会话末 落回 git: dev/logic/litestream.yml 参数化 + 六件制改名/新增, 恢复"仓=SSOT". 出处: 本档 §8.3 + DECISIONS "R2 桶名参数化"+"workflow 六件命名规约"+"HF_TOKEN 命名空间隔离"+"LITESTREAM_STRICT 评估" 条 (本会话末同车入).

