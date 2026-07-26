# ops/STATUS.md · omn dev 部署态快照

> 每轮部署/验证后更新。SSOT = 本文件 + 对应 ops/incidents/ + audit/。生产态见 §1 禁触, 此处只记 dev。

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
- [ ] R2 鉴别器 Space 侧三子读锁案分道 (圣上全只读, **7-26 铁证更新真根**): 步1 env DATA_DIR + ls 双路径 / 步2 litestream databases 自报路径 / 步3 litestream snapshots + R2 bucket mtime+snapshots+lifecycle — **铁证真根 = restore-WAL-tail 半态致 compaction txid gap** (非 dbs.path 漂移, 路径铁证全同). 新增两步: ① `sqlite3 /app/data/storage.sqlite "PRAGMA wal_checkpoint; SELECT * FROM pragma_wal_checkpoint;"` 看 db_txid 真态 (是否=0x0 还原态) ② R2 bucket 列 snapshots/*.ltx 全 txid 范围 + db/storage.sqlite/wal/ L0 seg txid 序列, 验链完整 (0x10→?→0x2c 中间真缺段 或 R2 只存 0x10+0x2c 两 seg) + entrypoint restore 选 snapshot 还是 WAL tail 逻辑分支审
- [ ] Phase 2 六步冻结: R2 三子读数报回前一律不启 (R2 先证后建铁律, compaction txid gap 真根未闭前禁 Rebuild)
