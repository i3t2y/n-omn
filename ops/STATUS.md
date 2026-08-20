# ops/STATUS.md · omn dev 部署态快照

> 每轮部署/验证后更新。SSOT = 本文件 + 对应 ops/incidents/ + audit/。生产态见 §1 禁触, 此处只记 dev。

## 2026-08-12 · FT Worker GitHub Actions 自控部署 (三件本地改完待 commit+push) — 仿 n-edget 手搓→自动 + fail-closed 鉴权根除

圣上 2026-08-12 令 "参考 i3t2y/n-vless、i3t2y/n-edget, 用 GitHub 控制 CF 账号建设 Worker"。落 `DECISIONS` 2026-08-10 段 + `docs/flaretunnel.md:39` 自述运维负债: 现役手搓法 = "CF Dashboard 全选删除粘贴 worker.js → 部署 → 手填真实 URL 进 endpoints.json"。`worker.js:5` `AUTH_KEY="PASTE_NEW_RELAY_AUTH_HERE"` 硬编占位圣上手填, 换钥逐 Worker 手改 → 密钥漏面大。

### 改动 (3 件)
- **`flaretunnel/worker.js`** (+12/-7): ①fetch 签名加 `env` 参 `async fetch(request, env)` ②硬编占位 `AUTH_KEY="PASTE_NEW_RELAY_AUTH_HERE"` → `const AUTH_KEY = env.RELAY_AUTH || null` 读 wrangler secret 注入 ③**鉴权 fail-closed 双守** `if (!AUTH_KEY || request.headers.get("x-relay-auth") !== AUTH_KEY)` — `!AUTH_KEY` 短路守 `undefined`/`null`/空串全先硬拒 401, 根除原占位逻辑 fail-open 裸奔洞 (`undefined !== 真 string` 误 pass = 开放代理裸奔, docs/flaretunnel.md:41 裸奔警告实证)
- **`flaretunnel/wrangler.toml`** (新建): Workers 非 Pages 最小骨架, `name="flaretunnel"` + `main="worker.js"` + `compatibility_date="2026-04-26"` + `workers_dev=true`
- **`.github/workflows/deploy-ft-workers.yml`** (新建): 仿圣上 `i3t2y/n-edget` `sync-deploy.yml` 机制转 Workers 路径。`cloudflare/wrangler-action@v4` + `secrets:` 输入内建走 `wrangler secret put` (非 n-edget Pages `curl PATCH CF API` 注 `env_vars.secret_text`)。`push` paths 触 (worker.js/wrangler.toml/workflow 自) + `workflow_dispatch` 手动

### n-edget 我仓差异 (机制移植转路径)
- n-edget 走 **Pages** (`pages deploy .` + PATCH CF API 注 `env_vars` + `wrangler.toml` 用 `pages_build_output_dir`)
- 我仓 worker.js 走 **Workers** (`wrangler deploy` + `wrangler.toml` `main` 必填 + `wrangler-action` `secrets:` 输入走 `wrangler secret put`)
- 目标件 = `flaretunnel/worker.js` (FT 出口换 IP), 非 worktree `cf-worker/index.js` (gate 网关前置代理, 别混)

### 前置验全绿 (本地)
- `python3 .claude/hooks/secret-scan.py` exit 0 (worker.js env.RELAY_AUTH 无硬编真值)
- `python3 -c "import yaml; yaml.safe_load(open('.github/workflows/deploy-ft-workers.yml'))"` OK
- wrangler.toml 手解 OK (`name`/`main`/`compatibility_date`/`workers_dev`)
- grep 零真 secret 值残留 (注释作废旧钥名 `OmniRouteFlareTunnelSecret2026` 非真值)
- **worker.js fail-closed 五态真 fetch 调测全绿** (node 加载模块 mock env+request): CASE A env无→401 / B 头=钥→200 / C 头≠钥→401 / D 无头→401 / E 空串→401 — fail-closed 双守根除裸奔洞

### 部署链
- [x] 本地三件改完: worker.js (改3处) + wrangler.toml (新建) + deploy-ft-workers.yml (新建)
- [x] 前置验五闸全绿 (含 fail-closed 五态真 fetch 调测)
- [ ] commit ask 圣上 (§5 git add/commit 一律 ask) → 圣上 push nomn main
- [ ] 圣上 GitHub repo 设 Secrets: `CF_ACCOUNT_ID` + `CF_API_TOKEN` (scope Workers Scripts:Edit + Workers Secrets Storage 写) + `RELAY_AUTH` (圣上 `openssl rand -hex 24` 真值, 须与 HF Space Secret RELAY_AUTH 同值 Worker 鉴权 ↔ 桥 RELAY_AUTH 铁律)
- [ ] GitHub Actions 跑通 → `wrangler deploy` 出 Worker URL
- [ ] Worker URL 回填 `flaretunnel_endpoints.json` (真身在 Dataset nonoke/omn-logic, 回流机制待圣上定)
- [ ] Restart dev Space → boot 真验桥 round-robin N/M Worker 计数增 (路3 /metrics 已落)

### 待圣上裁决 6 项 (卡矩阵扩 N, 单 Worker 先落)
1. **矩阵规模**: 单 Worker 先落 vs 直接矩阵 16? 真 M=16 池须圣上拉 HF `flaretunnel_endpoints.json` 件裁 (本地零件 git 从未 tracked)
2. **2池×8 vs 4池×4 矛盾**: `DECISIONS` 2026-08-10 (flaare/flbare 1-8) vs `audit/2026-08-01` :169-176 prometheus 钉死 (flaare/flbare/flcare/fldare 1-4) 冲突, 须圣上 HF 件终极裁决真族结构
3. **单钥共享 vs 每省各钥**: 全 Worker 同 `RELAY_AUTH`? 还是每 CF 账号各钥? (单钥共享风险面最小)
4. **endpoints.json URL 回流机制**: Worker 建成后 URL 怎回填 Dataset — n-edget 不涉此我独有项; 手填? Action dump? 待圣上定
5. **deploy 触发路径**: 仅 `worker.js` 改 push 触发? `workflow_dispatch` 已含, 圣上验后定是否加定时
6. **wrangler-action 版本**: `@v4` (主推) vs `@v3.15.0` (固定防移动 tag 劫持, 跟 n-edget `@v3` 一致)

### 不变量
- §1 拓扑: 三件定态 (space 根 Dockerfile/README/start.sh) 零触。worker.js + wrangler.toml + deploy workflow 均非三件。不新建 HF Space (CF Worker 非 Space)。不翻 `FT_WORKER_COUNT` 控池语义, 不改 endpoints.json 池结构
- §2 secrets: `RELAY_AUTH` 真值零入 git/会话。走 GitHub repo Secret → wrangler secret put 加密存 CF。worker.js 读 env.RELAY_AUTH 运行时绑定。换钥时 GitHub Secret + HF Space Secret 同值同步改
- §0 翻案: 本段落 2026-08-10 "欲真扩池超 M 须圣上先 CF 建新 Worker" 运维负债 (变 "设 Secret + 跑 Action"), 不翻案不改池语义
- §5 护栏: git add/commit 一律 ask。secret-scan exit=0 五态测全绿
- 详见 `DECISIONS.md` 2026-08-12 段

## 2026-08-10 · FT_WORKER_COUNT ENV 控桥轮换池规模 (dev/logic 层) — commit 67b6b8c push 通 nomn, 待 boot 真验

圣上 2026-08-10 令加 Worker 数变量 (原题 "RELAY_AUTH 改 32 worker 重建仍 16")。病根钉死: `RELAY_AUTH` = 桥鉴权密钥与 worker 数 **正交**, worker 数物理源 = `flaretunnel_endpoints.json` 写死 16 条 Worker URL, 改鉴权不动池。

### 改动 (1 件)
- **`dev/logic/entrypoint.sh`** `_ft_start` 函数 L222-248 (+23/-3): 加 ENV `FT_WORKER_COUNT` 控桥 round-robin 轮换池规模 N。
  - 规则 `实际轮换数 = min(FT_WORKER_COUNT, M)`:
    - ENV < M → 取前 N 条子集 (`--workers 0-(N-1)` 索引锁, Go `LoadWorkers`+`parseWorkerIndices` 实证)
    - ENV ≥ M → 全用 M (印提醒 ENV 过头用满池, 不凭空造 Worker)
    - 未设/≤0 → 原行为全用 M (回滚 = 删 Variable + Restart 零代码改)
  - 日志行改印 `${_ft_n}/${_ft_phys}` 双数 + ENV 子集标注
  - 不改 Go 源 (`--workers` flag 已支持) / 不改 endpoints.json (URL 源圣上控) / 零重编译

### 前置验全绿 (本地)
- `bash -n dev/logic/entrypoint.sh` SYNTAX OK
- `python3 .claude/hooks/secret-scan.py` exit 0 无命中
- 五边界自验全对 (ENV 0/4/8/16/32 × 池 16 → 轮换 16/4/8/16/16)

### 部署链
- [x] 本地 commit 67b6b8c (1 file +23/-3)
- [x] push nomn main (圣上 `!` 亲跑 §5 护栏, 远端已追平 HEAD)
- [ ] sync-logic-nonoke CI 推 Dataset nonoke/omn-logic (push 后自派)
- [ ] 圣上 Restart dev Space (零 Rebuild, dev/logic path)
- [ ] boot 真验: `[entrypoint] FT:` 行印 `N/M Worker round-robin` 双数 (设 ENV=8 看 `8/16 Worker (ENV FT_WORKER_COUNT=8 子集)`)
- [ ] DECISIONS.md 2026-08-10 段已落 ✅

### 待办
- [ ] 圣上设 Space Variable `FT_WORKER_COUNT` (建议先 8 验子集, 后按需调) → Restart → 看 FT 行双数真容
- [ ] 若欲真扩 32 Worker: 圣上先 CF 建 16 新 Worker → 填真实 URL 加 endpoints.json (现 16 → 32) → 推 Dataset → Restart (ENV=32 时用满池 32)
- [ ] 桥 boot 真验后圣上发 1 真 chat 验流量计数 (路3 /metrics 续尾项)

## 2026-07-31 · omn-logic 用不着件移出 (dev/logic 层) — 本地改完待 commit+push (圣上裁决)

圣上 2026-07-31 令 "omn-logic 中的脚本文件整理下, 用不着的移出, 并在文档中说明"。范围 (圣上 AskUserQuestion 答准): **仅扫 Dataset 根多余资产** + **omn_bucket_sync 插件包可选件** + **omn_encrypt 路2 死代码** 三类。helper.sh runtime 退场段未选保留。

### 移出件 (2 件 + 引用段清理)
- **`dev/logic/omn_bucket_sync.py` 移出** (插件静态包推公开 S3 Bucket, `OMN_BUCKET_SYNC` 默0不触): 圣上裁插件包可选件状态, 非现役链。`init-nim-keys.sh` L1125-1133 调用段 (注释+`if [ "${OMN_BUCKET_SYNC:-0}" = "1" ] && [ -x /logic/omn_bucket_sync.py ]` 块) 同删, 留移出挂记注释 + 恢复路径 (git 历史检出)。
- **`dev/logic/omn_encrypt.py` 移出** (路2 Fernet tar.gz 整体字节级加密): 圣上 2026-07-29 裁个人最小方案降级砍七成, `ENCRYPTION_KEY` 已删路2 降级, `EncryptedScheduler` 从未实例化 = 死代码。`omn_scheduler.py` 同步清理:
  - `_try_import` 删 omn_encrypt import block (except 兜底已就绪 fail-open, 但件不在更净) → `OMN_REDACT = _try_import()` (单返)
  - `EncryptedScheduler` 死类整删 (L99-144 全段) → 留移出挂记注释
  - `ENC_SRC`/`ENC_STAGING` 死路径定义 + `_ensure_dirs` 引用同删
  - 顶部依赖注释 + L35 PYTHONPATH 注释 + main docstring 同步更新路2 已移除

### 不变量
- §1 拓扑: 三件定态 (space 根 Dockerfile/README/start.sh) 零触。改 `dev/logic/init-nim-keys.sh` + `dev/logic/omn_scheduler.py` 两件 + `git rm` 两 deadcode 件, 走 dev/logic Dataset sync (非 Dockerfile path, 不触 Rebuild)。
- 主链 fail-open 保证: scheduler `_try_import` 删 omn_encrypt block 后 main 链路1 (CommitScheduler STDOUT staging → save) 不依赖 `OMN_ENCRYPT`, 删间件零运行态调用 (EncryptedScheduler 未实例化)。init OMN_BUCKET_SYNC 段删后 `OMN_BUCKET_SYNC` 阈若圣上仍设 =1 也无件可触 (`[ -x /logic/omn_bucket_sync.py ]` false 短路)。零回归。
- §2 secrets: 移出件无 secret 入档 (omn_bucket_sync 用 boto3 读 `~/.omn-secrets`, omn_encrypt Fernet 读 ENV `ENCRYPTION_KEY`, 均运行时绑定不留值)。
- Dataset 根资产侧零动作: 扫 Dataset 13 根件全真实资产 (10 git 跟踪件 + flaretunnel 二进制 + flaretunnel_endpoints.json 配件 + .gitattributes), 无多余隐藏件; `save/` 子目 = 永续日志不算资产。圣上裁"仅扫" = 零多余不动。

### 前置验全绿
- `bash -n dev/logic/init-nim-keys.sh` SYNTAX OK
- `python3 -c "import ast; ast.parse(open('dev/logic/omn_scheduler.py').read())"` AST OK
- `python3 .claude/hooks/secret-scan.py` exit 0 无命中

### 待办
- [ ] 本地改完 (2 git rm + 2 Edit); 待 §5 圣上裁决 commit + push nomn main → sync-logic-nonoke CI 推 Dataset + HfApi 删 Dataset 根两件 (用 `~/.omn-secrets` HF_TOKEN_DATASET_WRITE, source 不打印值)
- [ ] boot 真验 (Restart dev 零 Rebuild): 主链 init rc=0 + scheduler 起 + save 推正常 + 无 omn_encrypt/omn_bucket_sync ImportError / 无 `[ -x /logic/omn_bucket_sync.py ]` 残留回显

## 2026-07-31 · probe 慢启治法 + subshell exit1 崩根闭环 (dev/logic 层) — commit 16c70dc/e935ec2/ef16b46 push 通 nomn, boot PROBE=1 真路透 rc=0

圣上 2026-07-31 令治 "上轮慢有办法修正" (probe 串行拖慢起 5 分)。boot 日志实证慢根颠覆: 7key probe **首发全 HTTP 000** 触 30s 宽超时重试 4 分 34 秒全耗等待 (非 HF egress 非 NIM 限速是 probe 串行 + 000 重试架构慢, NVCF 首请求冷启热身/排队瞬态非 key 死)。

### 治法四件 (X2+X2.1+X4+脱敏) 落地链
- **X2 probe 并发3分批** (`NIM_PROBE_CONCURRENCY` 默3封顶): keys 入数组 + `mktemp -d` 隔离每key结果文件免并发竞写 + 后台子shell `( _probe_one ) &` + `wait` 收批. 32key最坏11批×30s≈5.5分 (vs串行16分)。commit `16c70dc` (+126/-55)。
- **X2.1 重试闸** (`NIM_PROBE_RETRY_ENABLED` 默0整跳重试): 首发000直接 fail-open alive, runtime LocalHealthCheck 60s tick 兜底真死key。slogan 印 `重试关(000→alive)`。commit `e935ec2`。
- **verbose 脱敏** (sed `gi`): verbose 模 `curl -v 2>&1` 明文回显 `Authorization: Bearer <key>` → sed `s/(Authorization:\s*Bearer\s+)[A-Za-z0-9._\-]+/\1<REDACTED>/gi` (`gi` 捕大小写双变体)。§2 明文根除。commit `e935ec2`。
- **X4 ENV 闸** (`NIM_PROBE_ENABLED` 默1): =1 跑 X2 并发 probe; =0 整跳 register-and-go (死key入池 runtime LocalHealthCheck 60s tick + PROXY_ALIVE_PREDICATE 兜底标死 p2c 轮换)。省首boot后 Restart 0秒起轨。

### 真·崩根定谳 (非 HF supervisor 臆测, 是 set-e + 子shell exit1 代码 bug) — commit ef16b46
`_probe_one` 子shell **最后一条** L675 `[ "$_pverbose" = "1" ] && [...] && printf ... | sed ... > file` 在非 verbose 模 (`_pverbose=0`, boot 默认) 首项 test `[ "0" = "1" ]` 返 **exit 1** → `&&` 链短路 exit 1 → **子shell 退出码 = 1**。主循环 L692 裸 `wait "$_p"` 收 1 → **`set -eo pipefail` (init 行 2) 杀主进程 init** → container exit 1, 两 boot 崩 (05:24/05:25, 日志断 probe 起行无收判无 rc=0)。

诊断弯路: 我首推 "HF Space supervisor 健康 probe 静默期杀 container" (外因臆测) → 圣上驳回 "不是被杀就是代码有问题" → 退回查源本地复现坐实: `bash -c 'set -eo pipefail; _pverbose=0; p(){ [ "$_pverbose" = "1" ] && echo x; }; (p)& w=$!; wait $w; echo OK'` → EXIT 1 无 OK, 精确复现崩。

**治本**: L675 末补 `|| true` (commit `ef16b46`, +4/-1): =0 test fail → `|| true` 强制 exit 0; =1 printf 写满 exit 0 覆盖 `|| true` 不损功能. 子shell 退出码恒 0 → `wait` 收 0 → `set -e` 不杀 → init 透。前置验全绿 (bash -n + secret-scan + 两态隔离测)。

### 三轮 boot 对照定谳 (真根闭环)

| boot | ENV PROBE | ENV VERBOSE | L675 态 | 结局 |
|---|---|---|---|---|
| 02:50 | =1 跑 | =1 开 | 旧无 `\|\| true` | 透 rc=0 (printf exit0 覆盖) 但 3 分 40 秒慢 + §2 明文 key 泄露 |
| 05:24/05:25 | =1 跑 | 未开 | 旧无 `\|\| true` | **崩 exit 1** (子shell exit1 → wait1 → set-e 杀) |
| 05:47 | =0 跳 | 未开 | 旧无 `\|\| true` | 透 rc=0 (ENV 绕治标, 未触子 shell, 非真治) |
| 06:14 | =1 跑 | 未开 | **修 `\|\| true`** | **透 rc=0 + 40 秒** (真根根除铁证) |

05:25 崩 ↔ 06:14 透 唯一变量 = L675 `|| true`。程 7 key 全 HTTP **200 → alive** (NVCF 已暖证实瞬态非 key 死) + `Done (first-init) v4.3.2` rc=0 06:15:31, 全 boot 78 秒 (probe ~40 秒 3 批并发3)。

### 不变量
- §1 拓扑: 单改 `dev/logic/init-nim-keys.sh` 一件, 三件定态 (space 根 Dockerfile/README/start.sh) 零触。走 dev/logic Dataset sync (非 Dockerfile path, 不触 sync-space-nonoke Rebuild)。
- §2 secrets: verbose 脱敏治本; 历史 02:50 boot 明文 key 已推 Dataset 须圣上判清理 (仅记位置零值入档 — 见 ops/incidents/2026-07-31-probe-subshell-exit1-crash.md §2 泄露挂账段)。
- §5 git: 单 commit push 三批 (16c70dc / e935ec2 / ef16b46) 避逐文件 push 触 HF build 冻。
- 教训入册: 排障先穷尽代码 bug 再归外因 (我前臆测 HF supervisor 杀错, 圣上驳回退查源坐实); `set -e` + 子shell + `wait` 三元组是隐藏地雷, `wait` 收子 shell 非零退出杀主进程, 治 = `|| true` 兜恒 exit 0。同源病族 (C2 pipefail 2026-07-25) 第三轮复发。

### 待办
- [x] commit `ef16b46` 修 L675 `|| true` 兜 → push `e935ec2..ef16b46` nomn 通
- [x] 06:14 boot `NIM_PROBE_ENABLED=1` 真路验真根根除 (rc=0 + 40 秒)
- [ ] §2 历史泄露清理 (圣上侧): HF Space `NIM_PROBE_VERBOSE` ENV 若仍开则关 + Dataset `nonoke/omn-logic` 历史 init_*.log/debug_*.log 含明文 key 件圣上判删/重写剥明文版重推
- [ ] 真业务 chat 流量验证 (经网关 /v1/chat/completions 带真 NIM 键走桥 200 + healthz Worker 计数增) — 圣上若发一发贴回核

## 2026-07-27 · 3.8.48 整体切换 (径 C 裁决) — ARG 改动已 push+sync+dev boot 三绿 (02:48Z) + ARG→Space 路径 runbook 入册, 待 gate 413 三防伪 + snapshot 多帧两笔补 → 24h 窗正式启 (起算两笔绿末时间戳)
圣上 2026-07-27 裁决走径 C: 整体切 3.8.48 base (上游真 release), 不构建新镜像 (GHCR 预构建已就绪), 仅改 BASE_IMAGE 切换。不翻 CLAUDE.md:23 (3.8.49 分支仍定点移植源池, 本次切 3.8.48 非 fork)。不用上游官方镜像三理由: 无 litestream / Hub 速率限制 / digest 钉锚统一 GHCR (入 DECISIONS). step -1 兼容性静态核毕 → 3.8.48 vs 3.8.43 互斥铁证表 (modelCapabilities 81 行含三新机制, modelContextOverrides/contextWindowResolver 0 行零改, modelSpecs 102 行含 GLM-5.2 authoritative 表) + 我侧 real_context=200000 消费链 getModelContextLimit 3.8.48:513-526 与 3.8.43:436-449 字节级一致 (Feature 5004 persisted override wins) + 新增迁移 9 件全清单 (113-122, 117_proxy_pool_rotation 破坏式但自带回填+我侧血统未用 proxy_assignments 表, 余 8 件累加无损). 出处: audit/2026-07-27-3.8.48-compat-static-audit.md.

### 切换机制实证修正 (2026-07-27 首演现形 + dev boot 反证成立定稿)
径 C 切换首演实证推翻旧前提 "改 Space Variable → Rebuild 切换": HF Space Variables 只注 runtime env, **不透 docker build --build-arg 通道**。圣上 nonoke/omn Rebuild 后 build log 仍 `FROM ghcr.io/i3t2y/omniroute-base:stable@sha256:9c9aecfd...` — `:stable` = Dockerfile 行 8 ARG 默认值原文 (非圣上改的 Variable 值 `:3.8.48@da99fac1...f408f`), Variable 未进 build 期。**切换权威开关 = Dockerfile ARG 默认值 (git 管理, commit 历史可查), 非 Space Variable**。旧 Variable 成死配置 (build 不读, bootstrap 不读即纯摆设)。径 C 精神不破: 仍不构建新镜像 + 仍 digest 钉锚; 回滚升级 `git revert` 该 commit + push + rebuild 即回 9c9aecfd (原回滚路径自带同 bug 一并修)。详见 DECISIONS "切换机制实证修正" 条 + Dockerfile 行 1-9 注释。

### 切换机制双轨回归 (2026-07-28 圣上裁, 回应实证与官方义冲突)
2026-07-27 首演实证 "Variable 未透 build-arg" 与 HF 官方文档义 (Variables §Buildtime "passed as build-args") 冲突。圣上 2026-07-28 裁不一锤定音判 Variable 路径伪 — 改采**双轨机制** (病根待下次升级真验: Rebuild 缓存命中 / 改值未真 Rebuild 两假说未验, 非官方义为假):
- **ARG BASE_IMAGE = `:stable` 占位符 + 兜底**: Dockerfile 行 26 `ARG BASE_IMAGE=ghcr.io/i3t2y/omniroute-base:stable` (回退 digest 钉死, 非钉; HF 不注入 Variable 退回 :stable 仍构建不崩)
- **作用域铁律补强** (docs.docker.com/reference/dockerfile/#scope): FROM 后指令须重声明 ARG 才可见。Dockerfile 行 39 `ARG BASE_IMAGE` (FROM 后重声明) + 行 40 `ENV BASE_IMAGE=${BASE_IMAGE}` (转存 runtime env) — 顺铁律
- **start.sh 排障接口**: 启动 echo 后 `echo "[start] 基础镜像: ${BASE_IMAGE:-(未注入 ENV, 历史镜像层)}"` — runtime env 入 boot log, dev/prod 鉴别+排障
- **日常升级路径 A (推荐)**: GHCR 推新版镜像到 `:stable` → dev/prod Space Rebuild 即拉新版, ARG/Variable 不动零 git 变更
- **钉 digest 路径 B (备选, 即径 C 首演径)**: 改 ARG 默认值钉 digest → git commit+push → sync-space-nonoke auto → 24h 绿 → workflow_dispatch sync-space-nomke。回滚: A `:stable` 重推旧 digest; B `git revert`+push+Rebuild
- 现 dev nonoke/omn 跑径 C 首演结果 (ARG 钉 3.8.48 digest, commit 68ee550 已 boot 三绿入 24h 窗) — 本批改 ARG 回 :stable + 作用域补强 + ENV 转存 (待圣上累积多条一并 push 后真生效)。
- 出处: DECISIONS "ARG 双轨机制回归" 条 (2026-07-28) + Dockerfile 行 26/39/40 + bootstrap.sh echo ENV 段。

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

### 切换执行序四步 (径 C 路径 B = 钉 digest 备选径, 见上双轨回归段; 日常路径 A 走 GHCR :stable 覆盖无须此序)
1. **cg52 push** (等圣上 commit 令): Dockerfile ARG 默认值改钉 <新标签>@sha256:<digest> (径 C 路径 B 首演已走此序钉 3.8.48 da99fac1, commit 68ee550) + 行 1-3 注释修正 + DECISIONS + STATUS 同批
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
- [x] 永续日志架构自动化一条龙落地 (E 双路并存, 圣上令 2026-07-28/29) ✅ — 8 任务 #44-#52 全本地落地 + AST/bash-n/yaml 语法全绿:
    · 五新 lib: helper.sh (补包 cryptography/boto3) + omn_redact.py (6 正则脱敏) + omn_encrypt.py (Fernet tar.gz 加密路2) + omn_scheduler.py (3 CommitScheduler 长驻 路1明文/路2加密/db + EncryptedScheduler 子类重写 push_to_hub) + omn_bucket_sync.py (插件包推公开 Bucket)
    · 两改: entrypoint.sh (SCHED_PID 5处 + gate stderr 2>> 重定向 + helper.sh 调 + scheduler 启动 + 监督 WARN 非 exit) + init-nim-keys.sh (链② db 表快照 + 链③ OMN_BUCKET_SYNC=1 触发)
    · sync-logic-nonoke.yml (5→10 件白名单双同步) + docs/HF永续架构模板.md (通用模板提炼)
    · 三件定态红线零触 (五件全 dev/logic/ sync-logic paths 不触 Rebuild, entrypoint/helper/init 读 ENV 不改三件), 链①设计经核冗余撤销 (scheduler 全掖 gate stderr 文件不漏 boot 段早期行)
    详 DECISIONS "2026-07-29 永续日志架构" 条. 未 commit 待圣上.
- [ ] 永续日志批后续 (个人最小方案降级后, 圣上 2026-07-29 裁砍七成): ① 圣上 Space Secrets 配 3~4 ENV (HF_TOKEN dataset-write + OMN_DATASET_REPO 复用 + 插件包套 OMN_BUCKET_* 5件+OMN_BUCKET_SYNC=1 若需; OMN_SCHED_EVERY/OMN_CAPTURE_INTERVAL 默认值兜底不配; ENCRYPTION_KEY 已删路2降级) ② 圣上 commit + push 触 sync-logic-nonoke 自派 → Dataset 第十件平铺 ③ 圣上手动 Restart (零 Rebuild) ④ boot 真验: scheduler PID 现 + helper.sh 装 boto3 绿 + gate-stderr.log 有内容 + Dataset repo omn_data/logs/stdout 落地单件

## 2026-08-12 · FT Worker 100 拓扑本地 commit 6c78f2d 待 push (承 008c48d 雏)

**本批改动 (commit 6c78f2d, 本地已落, 待 push)**:
- `.github/workflows/deploy-ft-workers.yml` 单维 → **二维矩阵 10×10=100 上限**框架重写 (+525/-47, rewrite 65%): 三 job (gate PRESET 8 场景 + 动态矩阵 / gen-names 60 词池每账号独立抽双词不共享 / deploy 二维矩阵 6 step)
- 守三件: `worker.js` (008c48d fail-closed) + `wrangler.toml` (git 版单 Worker 骨架, workflow 动态覆写) 未动
- 详 [[ft-worker-100topology-landed-2026-08-12]] + DECISIONS "2026-08-12 FT Worker 二维矩阵 10×10=100" 条

**圣上手设 GitHub repo (我零碰真值 §2, push 前置)**:
- **Variables**: `ACTIVE_ACCOUNTS=10` `PRESET=`(空默认 gen) `CRON_ENABLE=true` `DEPLOY_SCOPE=2` `PASS_MODE=2` `SOLO_ACCOUNT=1` `GEN_NAMES=0` `DELETE_MODE=0` `SECRETS_ONLY=0`
- **Secrets**: `CF_ACCOUNT_IDS` (10 accID 逗号串) + `CF_API_TOKENS` (10 tok 逗号串每锁该账号其 zone: Workers Scripts Edit + Workers Routes Edit + Zone Read + DNS Edit) + `RELAY_AUTH` (`openssl rand -hex 24` 须同 HF Space Secret) + `GH_PAT` (Fine-grained 仅 n-omn: Variables RW + Contents R + Metadata R, 90 天)
- 圣上补 10 CF 账号 + 10 zone (`f01.cc.cd`~`f10.cc.cd`) + 每 zone 建 token

**链序 (圣上裁决先 push 后配 or 先配后 push 未定)**:
1. push nomn main → 触 `GEN_NAMES=0` 默认 gen Phase → 写 `WORKER_NAMES` (100 名)
2. 改 `PRESET=first` → 双 pass 全量建 100 Worker + custom domain + 关 workers.dev
3. 验 GitHub Actions 绿 + CF Dashboard 见 100 Worker + 100 子域
4. URL 回填 `flaretunnel_endpoints.json` (HF Dataset `nonoke/omn-logic`) → Restart dev Space → boot 真验桥 round-robin N/M 计数增

**未决/扩展待批**:
- 旧 `flare*.workers.dev` 删 (圣上"到时临时删下"): **Mode 2 全删 + Mode 3 delete:o 均含** (圣上 2026-08-12 令改 Mode 2 全删无滤波 → 旧 `flare*` 自然删; Mode 3 delete:o 滤现役名单外删 → 旧 `flare*` 不在名单亦删; 无须另扩正则)
- push 须圣上亲启 (§5 ask 仅 commit 已落, push 另准; 前轮 008c48d 圣上自掌 push 私库惯例)
- memory 项 [[ft-worker-github-deploy-landed-2026-08-12]] :34 旧误记 "Workers Secrets Storage 写" 已更正归 Workers Scripts Edit (secret 绑 script 无独立权限)

## 2026-08-12 · deploy workflow 加 delete:o 模式 (commit 本批)

**改动**: `deploy-ft-workers.yml` 加 `PRESET=delete:o` (新场景, `DELETE_MODE=3` + `PASS_MODE=0` 纯删无部署)。
- gate case `delete:o` → `DELETE_MODE=3; PASS_MODE=0` (纯删不重建)
- Delete 段 Mode 3: 列账号全 Worker → `echo ",$WORKER_NAMES," | grep -q ",$W,"` 滤现役名单 → 在 Keep / 不在 DELETE (清旧词基/孤儿/过时)
- 全 deploy step `if` 加 `pass_mode != '0'` 门控 (Generate wrangler.toml/Deploy1st/Wait stable/Verify&Bind 跳; 双 pass step `pass_mode=='2'` 跳; 纯删仅跑 Extract + Mode 3 删段)
- PRESET desc 顶部加 `delete:o` 场景
- DECISIONS 删段裁决改三模式 (Mode 1/2/3)
- 详 [[ft-worker-100topology-landed-2026-08-12]] + DECISIONS "2026-08-12 FT Worker 二维矩阵" 条删段裁决

**YAML 闸过 + secret-scan exit=0**. push 须圣上亲启。

## 2026-08-12 · deploy workflow 触发改 tag-driven (圣上令 B 方案)

**改动**: `.github/workflows/deploy-ft-workers.yml` `on.push` 段 branches+paths → **push.tags: `deploy-*`** (圣上主动 tag 掌触发权)。普通 push 改 workflow **不触全自动全量重 deploy** (B 方案, 省浪费 + 净 Actions 历史)。

**触 workflow 三路**:
1. **`git tag deploy-vN && git push nomn deploy-vN`** → 触 (圣上定 deploy tag)
2. **schedule cron `17 2 * * *`** → 触 daily (现 `PRESET` Variable 定场景)
3. **workflow_dispatch (GitHub UI / `gh workflow run`)** → 手触 (input preset 可即时覆盖 Variable)

**普通 push 改 workflow**: 零触 (不消耗 Actions 配额, 历史 pollution 零)。

commit 三件 (workflow + STATUS, DECISIONS 不动触发机制非裁决)。

## 2026-08-12 · deploy workflow secrets 场景 bug 修 (RELAY_AUTH 不注根因)

**病根**: `secrets` PRESET 场景 (`SECRETS_ONLY=1`) design 意图"只更 RELAY_AUTH secret 不重绑域" (:116 注), 但实现错: `Generate wrangler.toml` (:390) + `Deploy Worker 1st pass` (:418) 两 step 门控含 `secrets_only == '0'` → secrets 场景两 step 跳 → 无 wrangler.toml + 无 deploy → env.RELAY_AUTH 不注 → Worker 鉴权 401 全拒 → 桥连不上。

**铁证** (圣上贴两格 Actions log):
- 格 (1,2) `gem-fire-ft2` build OK 44s = first 场景跑过 (Worker 已建 + 域绑 ✓)
- 格 (2,8) `tiny-snow-ft8` 7s 全 step 0s = secrets 场景跑但 secrets_only=1 门控跳全 deployment step → secret 未注

**治法 (圣上准, 路 2 豁)**: 去 `Generate wrangler.toml` + `Deploy1st` 两 step 的 `secrets_only == '0'` 守。secrets 场景现跑此两 step = `wrangler deploy` (代码 0 变 worker.js 未动) 注 `env.RELAY_AUTH` = wrangler secret put。域绑相关步 (Wait stable / DeleteFlagged / Deploy2nd / Verify&Bind) 仍守 `secrets_only == '0'` → secrets 场景跳不重绑域。

**secrets 场景跑链**: Extract Credentials → Generate wrangler.toml → Deploy1st (注 RELAY_AUTH) → 跳 Delete/双 pass/Verify。

**圣上补设两处同值 RELAY_AUTH**:
1. GitHub repo Secret `RELAY_AUTH` (圣上 `openssl rand -hex 24` 48 字符随机串)
2. HF Space Secret `RELAY_AUTH` = **同上值** (Worker 鉴权 ↔ 桥同值铁律, 两处异值则桥 401)

**触 secrets**: 圣上改 GitHub repo Variable `PRESET=secrets` → workflow_dispatch → deploy job 100 格跑 Deploy1st 注 RELAY_AUTH 100 Worker → Restart dev Space → boot 真验桥 round-robin N/M 计数增。

闸验: YAML 通 (jobs gate/gen-names/deploy) + secret-scan exit=0 + secrets_only 守残留 6 处皆域绑步 (须跳)。

## 2026-08-12 · deploy workflow RELAY_AUTH 真不注根因 (原雏 008c48d bug, wrangler-action @v4 secrets: 输入缺)

**病根 (圣上贴格 (2,8) Actions log 诊 + Context7 wrangler-action @v4 docs 铁证)**:
- Deploy Worker 1st pass (:424) + 2nd pass (:467) 两 step 仅 `env.RELAY_AUTH: ${{ secrets.RELAY_AUTH }}` (值源对)
- 但 **`with.secrets:` 输入缺** → wrangler-action @v4 不跑 `wrangler secret put/bulk` 注 Worker env
- @v4 机制 (Context7 docs): secret 注须 `secrets:` newline 分隔列名 + `env:` 配同值 → wrangler-action 内建跑 `wrangler secret bulk/put`. 仅 env 不触发 secret 注, 仅 `wrangler deploy` 上传代码
- 铁证 log: `🚀 Running Wrangler Commands / npx wrangler deploy` → 只 deploy, 无 `wrangler secret put RELAY_AUTH` 行 → RELAY_AUTH 真未注 → Worker `AUTH_KEY=env.RELAY_AUTH||null` = null → fail-closed 401 全拒 → 桥全断

**治法 (Context7 docs 导正)**: Deploy1st + Deploy2nd 两 step `with:` 加 `secrets: | RELAY_AUTH` 输入。env.RELAY_AUTH 值源对不变。@v4 检测 secrets 输入 → 跑 `wrangler secret bulk/put RELAY_AUTH=<env值>` 注 Worker。

**原雏 008c48d 血统债**: 此 bug 原雏代码引入 (memory [[ft-worker-github-deploy-landed-2026-08-12]] :16 注称 "secrets:输入走 wrangler secret put" 设计意图对, 但实装漏 secrets: 输入 = 注释对代码错). 经 secrets PRESET 场景门控改 (c10d544) 后圣上触 secrets run 暴露: Deploy1st 跑但空注入.

闸验: YAML 通 (jobs gate/gen-names/deploy) + secrets: 两处 (:432 + :474) 对应 env RELAY_AUTH 两处 (:434 + :476) + secret-scan exit=0.

## 2026-08-12 · deploy workflow 加 publish-endpoints job (圣上令自动化回填 endpoint.json 到 Dataset)

**动机**: 圣上令"actions 有没有没法按新顺序生成 endpoint.json 并传到 bucket" → 加 publish-endpoints job 自动化派生 worker-major endpoint + 传 HF Dataset.

**新 job `publish-endpoints`** (workflow 末):
- `needs: [gate, deploy]` deploy 成后跑
- `if`: `deploy.result == 'success' && gen_names != '1' && secrets_only != '1'` (gen 场景跳=未建 Worker URL 未 live; secrets 场景跳=Worker URL 不变 无须重传)
- 2 step: checkout + Python 派生
- 派生 logic (worker-major 排): newidx → (worker=`newidx//10`, account=`newidx%10`) → old account-major idx = `account*10 + worker` → 取 WORKER_NAMES 名 → URL = `https://{worker+1}.f{account+1:02d}.cc.cd`
- 铁律: `WORKER_NAMES` (account-major 圣上 Variable) + f{XX}.cc.cd 拓扑 → worker-major endpoint.json 派生 (本地 /tmp 脚本产对证 Python 派生序完全匹配)
- 传 `nonoke/omn-logic` `flaretunnel_endpoints.json` via `HF_TOKEN_NONOKE` GitHub Secret (圣上已有 write scope, 零硬编真值 §2)
- 不涉 bridges.json (桥编排骨圣上域, workflow 不动)

**拓扑对照 (worker-major 排)**:
| idx | worker | account | name | URL |
|-----|--------|---------|------|-----|
| 0-9 | 1 | f01-f10 | 各账号 ft1 | 1.f01..1.f10.cc.cd |
| 10-19 | 2 | f01-f10 | 各账号 ft2 | 2.f01..2.f10.cc.cd |
| ... | ... | ... | ... | ... |
| 90-99 | 10 | f01-f10 | 各账号 ft10 | 10.f01..10.f10.cc.cd |

→ `nim` 桥 `workers:"0-39"` = worker1-4 各 10 账号 = 每账号前4 worker (圣上目标)

**圣上须 vistas**: bridges.json nim workers `0-39` (现 `0-31`) 须圣上天 UI 改 (workflow 不传 bridges).

闸验: YAML 通 (jobs gate/gen-names/deploy/publish-endpoints = 4) + publish needs[gate,deploy] + if 门控 + secret-scan exit=0 + Python 派生序与 /tmp 脚本对证全匹配.

### 2026-08-12 commit c22b3a9 — PRESET=publish 场景 (publish-only 路径)
圣上令 "额外特定任务路径" = PRESET=publish: deploy 100 格跳 (省 ~16m 重部 Worker), 仅 publish-endpoints 直跑派生 endpoint.json 传 Dataset.
- gate case 加 `publish)` 分支: `PUBLISH_ONLY=1` + GEN_NAMES=0 + SECRETS_ONLY=0 + DELETE_MODE=0
- gate outputs 加 `publish_only` flag (主输出段 + cron 阻塞分支 + 默认值段 全补)
- deploy if 加 `publish_only != '1'` 门 → publish 场景 deploy **跳** (skipped, 100 格零跑)
- publish-endpoints if 改: `always() && gate.result=='success' && gen_names!='1' && (publish_only=='1' || (deploy.result=='success' && secrets_only!='1'))`
  - `always()` 兜 deploy skipped (publish-only 场景 deploy 跳 needs 仍跑)
  - `publish_only==1` 分支绕 `deploy.result=='success'` 判 (deploy 跳不阻 publish)
- publish needs 保留 `[gate, deploy]` (deploy skipped 仍算 needs 满 + always())
- workflow_dispatch inputs preset 描述加 publish
闸验: YAML 通 4 jobs + deploy if publish_only 门 + publish if always()+publish_only 分支 + gate outputs publish_only + secret-scan exit=0.
圣上用: `PRESET=publish` (workflow_dispatch 输入框 或 Variable 临时设) → 仅 publish 跑, deploy 零耗. push 待圣上亲启.

## 2026-08-12 续 · 100 Worker 满额全活 + deepseek/mistral-small-4 剔

**FT Worker 100 拓扑满额全活 (圣上宣告 "10账号100worker全都搞定了")**:
- 圣上 GitHub Variable `ACTIVE_ACCOUNTS=10` 已设 (f01~f10 zone 全启 + 10 CF 账号 token + Secrets 全配齐)
- `PRESET=publish` workflow_dispatch 触发 → publish-endpoints 自动派生 100 条 worker-major endpoint.json 传 HF Dataset `nonoke/omni-logic`
- boot 真验 (dev Space nonoke-omn): 9 段全绿 + FT 桥 nim 建 40 Worker 池 (现役取每账号前 4, `bridges.json` `workers="0-39"`) round-robin 全活
- f01 zone DNS 病 (2-4.f01.cc.cd no such host, 圣上诊 "DNS 服务器没设好") → 圣上 CF 侧修 zone DNS 服务器 → 40 池全活 (curl 401 fail-closed, 非 502)
- 代理真生效铁证三证 (HF Dataset save/ft/ capture log): ① Prometheus `flaretunnel_worker_requests_total{name="calm-mist-ft1"} 1` successes=1 ② round-robin 真轮跨 worker 跨账号 (1.f10→2.f01, 3.f08→4.f03) ③ 真业务穿链 POST integrate.api.nvidia.com via Worker 3.f02 ✅200 GLM-5.2 Pong. 10 chat 全 200 时延 3.5-33.7s (40 Worker 各独立 CF 出口 IP 致散布)
- SSOT 落: DECISIONS +3 段 +69 行 + HANDOFF +51 行 FT 架构交接段 = commit 2b74731, 圣上亲推 nomn/main (b577e5b..2b74731 成)

**deepseek + mistral-small-4 模型剔 (圣上令 "deepseek删了吧 + mistral-small-4 NVIDIA删了")**:
- 2026-08-12 boot 日志印 5 model DEPRECATED (NVIDIA 目录无): moonshotai/kimi-k3, deepseek-ai/deepseek-v4-flash, deepseek-ai/deepseek-v4-pro, qwen/qwen3.8-max-preview, mistralai/mistral-small-4-119b-2603
- 圣上命删 deepseek 二组 (flash + pro) + mistral-small-4 一组; 留 kimi-k3 + qwen3.8-max (deprecated 但待复检, 圣上未命删)
- 落点 `dev/logic/init-nim-keys.sh` 6 处删: TIER_FAST (66/67) + TIER_STABLE (77) + NIM_CODEX_MODELS (95) + NIM_FAST_MODELS (103) + NIM_EXTRA_MODELS (110, 数组内移除); 注释保留历史标记 (同 llama-3.3 / gpt-oss 格款)
- `docs/nim_context_probe.sh` 探针脚本 MODELS 同步删 deepseek (圣上手动探真截断点工具, 非 boot 血统)
- 闸验: `bash -n` PASS + `secret-scan exit=0`

## 2026-08-12 续二 · gate /v1/ft/metrics PSK 反代 FT 桥计数 (路3-b)

圣上令 "做" (承 HANDOFF:123 待办 "gate 加路由暴露 FT /metrics 公网"). 落 commit `ec0712d` (dev/logic/gate.js +56).

- `GET /v1/ft/metrics` 公网路由: PSK 鉴权 (靠前 /v1 app.use safeEqual) 后反代 FT 桥本地 127.0.0.1:$PORT/metrics (Prometheus text exposition)
- `?bridge=N` 0-基选桥默首桥 (首桥代整体旧例), 越界 400 `bad_bridge_index`; ECONNREFUSED→503 (桥死非路由缺); timeout→504; 其余→502
- FT_PORTS env 读多桥 (entrypoint export), FT 未启 8080 兜取时 503
- 真路测五态全绿: 无PSK401 / 对PSK+bridge0活桥→200计数命中 / bridge1死桥→503 / bridge99越界→400 / 错PSK401
- 闸验: node --check PASS + secret-scan exit=0 + pre-commit 过
- push 待圣上亲启 (§5, dev/logic 真身 Dataset nonoke/omn-logic 须 git 先行; commit 3b1564c+ec0712d 两轮待推)

SSOT 同步: HANDOFF 排障入口加 /v1/ft/metrics 公网取法 + 待办 ✅ 移 + commit 链分两支; DECISIONS 加 §3 gate metrics 段 (只增).

## 2026-08-13 · 时延基线对比 + CF IP 优化裁决 (无 commit, 纯查证存档)

圣上问 "比之前慢多少" + "CF IP 来源没法优化吗" + 贴外部 AI 文逐条裁. 搜证 (anysearch) 落.

**时延基线对比** (基线 `audit/2026-07-20-r3plus-group2-3parallel-10rounds.md` = 16 Worker 扩 100 前, 3 并发 10 轮):
- 基线 200: 2.17s ~ 14.15s (中位 ~7-8s); 429 快拒 1.45-1.98s
- 现态 100 Worker: 3.5s ~ 33.7s + 30s client abort + 502 lockout 3s
- 差值: 下限 +1.3s (+60%), **上限 +19.6s (+138%) 翻倍**, 新增 30s abort
- 基线非纯对照 (16 Worker 期亦 FT 启期, 非"无 FT vs 有 FT"), 真"FT 开销"定论须无 FT 直连测, 候圣上命

**外部 AI 文判** (圣上贴"架构师建议"):
- "关小黄云/DNS Only" ❌ 伪 (CF Routes doc: Worker 须 proxied 调用, 关=Worker 死断链)
- "优选 IP/Local Host 映射 1.1.1.1" ❌ 伪 (CF Anycast 无 origin IP 可直穿)
- "收 40 子域单域" ❌ 撞锁 (撤销换 IP 池设计, 撞 warp-vs-ft 裁决③)
- "简化 FT 砍 Worker" ❌ 撞 DECISIONS 100 满额锁决 (§0 不翻案)
- 真可取唯一: "FT 转发重 + HF 2vCPU 计算压" = 与本仓 ft-worker-count-vs-keys + warp-vs-ft 档案一致

**CF IP 优化裁决**:
- 现状 100 Worker 共享池 = CF 免费层 IP 多样性天花板 (免费 Worker 出口=CF 全球共享池, CF 内部路由决定, 非钉死账号/worker)
- 独享固定 IP (Dedicated Egress/BYOIP) ❌ Enterprise+加购且反设计 (固定单 IP 撞 warp-vs-ft 裁决③否决); CF 社区 MVP sjr 明 "Any dedicated IP requires Enterprise plan"
- Smart Placement ⚠️ 微调 (迁 Worker 位置不改出口 IP, 100 同好迁可能反降多样性, 不轻试)
- 多账号扩域 ⚠️ 撞圣上 10 账号满额上限 + 邮箱负债
- **NIM 403 真根重诊方向**: NVIDIA 论坛大量证 403 "Authorization failed" 真根 = 账号缺 "Public API Endpoints" 权限/组织权限, 非快 IP 封. ft1 集中 403 须按 NIM key 维度重诊 (查 403 Worker 用 key vs 200 Worker 用 key), 候圣上命深入

**慢真四根** (综合): ① 100 Worker round-robin 游标长+冷端握手 ② 30s client abort 漏 catch (unhandledRejection) ③ ft1 集中 403 (NIM 侧非 IP) ④ HF 2vCPU 计算压 (90k token, 恒定)

**可取三小调** (非升 tier 非翻案): NIM 403 key 维度重诊 / Smart Placement 谨审监控多样性 / 10 账号 40 Worker 真出口 IP 取件比对

本轮无 commit (纯查证, memory + SSOT 落存档). 翻案 100 Worker 数或 FT 拓扑须圣上明确令 (§0).

## 2026-08-19 · 429 风暴红外诊断 + 三病并存定谳 (无 commit, 纯查证存档)

圣上贴代理日志 + 单事件详情 + 应用控制台 + Health 仪表盘四路证据, 闭环 429 真根诊断 (前轮 #3 NIM 403 key 维度重诊延伸).

**429 真根 = NIM account-level 配额速率限** (纯 key/account 维, **非出口 IP 维**):
- 32 account 风暴窗 140 请求 · 40% 成功率, 21 account rate_limited 散布**无 IP 族聚类** (若 IP 限应 Worker-IP 扎堆)
- 限速标 `nvidia:<UUID>` = account ID = NIM 按 account 计; cooldown/error-clear 按 account 非 Worker
- healthy 10 散布全账号 (nim-07,08,09,16,19,20,21,23,27,32), 熔断 CB CLOSED (未跳, round-robin 始终换 account), cooldown 0 (60s 窗过即回活)
- 风暴过后现态 12min 11 请求 0% 错误率 = 系统回稳

**OmniRoute fallback 韧态全活** (非本地 bug):
- combo `—` 空 = glm-5.2 单 model 设计如此 (getComboForModel 返 null = single-model 非 fallback 失效; 连 200 也 `—`). 推翻前轮误判
- attempts 链真活: be1e20b9 7 attempts 跨 nim-01~06 / 3b3e55c6 16 attempts 末 200 / 36a91736 12 attempts 末 200
- 控制台: 🚫[RATE-LIMIT] pausing for 60s (cd 实跑 60s, 源码 default 120s = 配覆写, 圣上查 /api/resilience) + FALLBACK MODE excluded_count LRU 排除选下一 + Account error cleared 真清 + Model-only lockout 3s (connection 不死)

**三病并存定谳** (现盘全合):
- 429 (主流) = NIM account 配额限 × Hermes 高频 (4-5s 隔). account 维. 非桥病
- 403 (前轮 §4, ft1 族) = auth/权限维, 另案. 本轮未复现, 仍候深查
- 502 (1× nim-13) = NIM 服务层 RST 透传非桥造
- + 陈旧错态 gap: 冷却过期回活后 lastError 不自动清 → Autopilot 22 issues 提手动清 (缓释: 圣上点 Autopilot 清, 我零碰 prod)

**否定项**: combo 空非 bug (推翻前判); FT 桥透传 429/403/502 全 NIM 真返非桥造; 真测现态不建议 (0% 错无活病可测, 真须烧配额造风暴成本高仅重复证已有定论). 真测脚本可写候圣上择机下次风暴测.

**解方向候命** (非本轮 commit): 降客户端频率 / 拉长 429 cd 120-180s / 扩 account 池撞 10 上限 / NIM 侧提配额 (真根治非本地能控).

本轮无 commit (纯查证, DECISIONS §5 + STATUS 落 SSOT). 翻案 §4 403 决或 100 Worker 拓扑须圣上明确令 (§0). 排障入口看 HANDOFF 历史 watcher 闭环段 (FALLBACK MODE / all accounts unavailable / Preserving last upstream error 三签名表).

## 2026-08-19 · init boot 自清 OmniRoute 陈旧错态 路A 落闭环 (commit 3158c2c)

§5 "陈旧错态 gap 缓释: 圣上点 Autopilot 批量清" 升级为 **路 A init boot 自清** 自动化落地 (圣上令 "A"). dev nonoke/omn ephemeral 死结 (R2 无副本每 boot 空库 → external manage key catch-22 不持久) → 用 init 既有 Dashboard session cookie 鉴权链调 autopilot actions = 不依赖 external 持久 key.

**落点**: `dev/logic/init-nim-keys.sh` +86 行 `clear_stale_nim_errors()` 函数 (gc_stale_providers 后插, 调用点 line 965). 机制: GET `/api/providers/health-autopilot?provider=nvidia&includeActions=true` (cookie 鉴权) → python3 解 `issues[].actions[]` type=`clear_stale_connection_error` 提 (connectionId,preconditionsHash) → 逐 POST `/actions` 清. fail-open 范式 (仿 gc_stale, 非200 skip / set +eo pipefail 抬门 / 0 stale return 0 / 409 终态 skip). ENV 闸 `OMN_CLEAR_STALE` 默1开. 语法修: `$(curl -d "$(python3 -c '...')")` 双层 sub 须 `))` 双配. 闸验 `bash -n`+`secret-scan` exit 0.

**部署链实**: commit `3158c2c` push nomn main 成 (`54b1b5a..3158c2c`). `sync-logic-nonoke.yml` Action 触但**上 Dataset 旧版** (init-nim-keys.sh 不含函数, sha256 `1e0d2fad` vs 本地 `bab088f0` 差 4363 bytes = 函数体) —— 真根未查 (可能 checkout SHA 落后/path filter 未中/concurrent race). **手推修**: Python 读 `~/.omn-secrets` `HF_TOKEN_DATASET_WRITE` 注入 os.environ (§2 token 零 cli 字面) → upload_file + hf_hub_download 读回 sha256 闭验 (Dataset `169bc09c` == 本地 ✓, 函数内嵌 True).

**boot 真活闭环** (dev nonoke/omn Restart × 全绿):
- 2026-08-19 13:25Z: Dataset HEAD `ea08edbb256c` (含手推新版系) → init rc=0, 32 key alive (200/429 鉴权链通), 40 Worker 池全活, 7 模型 (2 deprecated = kimi-k3/qwen3.8-max 预期), Resilience 落定 300/96/200/300000. **关键回显**: `[init] gc_stale: 无待删连接` → `[init] clear_stale: 无陈旧错态 (Autopilot issues=0 stale_connection_error)` → `Fetching provider IDs` = 函数真跑, 预期三态之一 (本 boot 全新空库无历史 stale). fail-open 空转幂等零副作用 ✓.
- 前 2 次 Restart (12:51 / 13:00) 缺回显 = boot 抽旧版 logic (Dataset sync Action 未跃或上旧) = 手推修后 13:25Z 闭.

**保留**: `dev/scripts/clear-stale-nim-errors.sh` 保留作 prod 备 + 参考文档 (非顿旧, 路A 自清 = its boot 版). §5 缓释已被路A 自动化同向演进非翻案.

**未决/下一步**:
- **sync-logic-nonoke.yml Action 上旧版未解** (本轮手推绕过) —— 须圣上侧查 Action run log, 下次 dev/logic/** push 若仍上旧版会覆盖回旧. 候命排查.
- §2 副排: 两暴露 token (OpenRouter sk-or- / dev oma_live_) 前轮已入会话记录不可撤, 须圣上侧 revoke+regen.
- §4 403 NIM account 公开发行权限深查仍候命 (本轮未触).

本轮 commit 1 (`3158c2c` 路A函数), SSOT 落 (HANDOFF 陈旧错态段+commit链+待办 / DECISIONS §6 / STATUS 本段). DECISIONS 只增不改 (§4 §5 未动). 翻案 §4 403 决或 100 Worker 拓扑须圣上明确令 (§0).

## 2026-08-19 · 加 R2 副本根治 nonoke/omn ephemeral 持久化 (路B 裁批待落, 0 代码改动)

**圣上令** "怎么也要实现路径1啊,直接把r2加上,搞定持久化不就行了" = 超越路A自清 (commit 3158c2c, 绕过 ephemeral 死结兜底), 真根治 R2 副本持久化。DECISIONS §7 裁决落 (只增不改)。

**§1 拓扑翻案 (同期, 圣上明令)**: 撤 nomke 生产, **nonoke/omn 单 Space 兼生产+dev**。R2 bucket = omn-data (dev 桶升正; omniroute-data 旧生产桶不动存历史)。单 Space 单桶无双写问题 (旧双 Space 铁律随 nomke 撤失效)。CLAUDE.md §1 已改 (单源单Space)。本段按单 Space 单桶 omn-data 论。

**架构已全建好 — 零代码改动** (代码链 litestream.yml + entrypoint.sh L124/L128-166/L391-407/L499 全在, 详见 DECISIONS §7 代码段)。**纯 HF Space Variables 配置**:

- **病根**:
  1. **(已解除)** 3 R2 凭据 `R2_ACCESS_KEY_ID`/`R2_SECRET_ACCESS_KEY`/`R2_ACCOUNT_ID` 圣上已补齐 → `has_r2=1` (entrypoint L124 判活 3 凭据已齐)。**2026-08-20 boot 实证**: 走 restore 分支 (印 `⚠ restore 失败 rc=1` 非 L128 `skip restore 空库启动`) = 凭据在, has_r2=1。
  2. **(已解除)** `OMN_PERSIST_WRITE` 关态 = 圣上已处置 (设1 或删回默1)。**2026-08-20 boot 实证**: 印 `Litestream PID=149/151/156` 开态分支 (L403), 无 `OMN_PERSIST_WRITE=0 关态` 行 = replicate 启。
  3. **(已解除 c790e05)** litestream.yml `path` 硬编码 `/app/data/storage.sqlite` 对不上运行 DB path。**2026-08-20 13:53 boot 实证**: `error="database not found in config: /data/storage.sqlite"` — entrypoint 默认 DATA_DIR=/app/data (L16) 但 HF Space env 设 `DATA_DIR=/data` → 运行 DB 实际 `/data/storage.sqlite`, litestream.yml path 硬编码 /app/data 匹配不上 restore 目标 arg $DB_PATH. **修法 (commit c790e05 + 手推)**: path 改 `$\{DATA_DIR\}/storage.sqlite` env 派生对齐运行态. **2026-08-20 15:36 boot 实证生效**: 错误从 `database not found in config` **变成** `s3: ListObjectsV2 403 AccessDenied` = path 正确展开成 `/data/storage.sqlite` 匹配运行 DB, 已到 S3 访问阶段。**手推链路**: c24c959 push 触 sync-logic-nonoke Action 失败 (job 0 steps 2 秒 fail, run id 32373926257, 根未查), 手推 litestream.yml 上 Dataset (Python hf upload 注入 HF_TOKEN_DATASET_WRITE, 读回 sha256 闭验 `982a050f3a4f539b` 匹配).
  4. **(实锤真根)** R2 S3 token 缺 List 权限。**2026-08-20 15:36 boot 实证**: `s3: list generations: ListObjectsV2, StatusCode: 403, AccessDenied` — litestream 启动列 omn-data 桶 `db/storage.sqlite` generation 被拒 = **token (R2_ACCESS_KEY_ID 对应) 无 omn-data 桶 Object List 权限**. litestream 需 **ListObjectsV2 (列 generation) + GetObject (读 snapshot) + PutObject (写 segment) + DeleteObject (清过期)** 全权限. 圣上侧 R2 Dashboard 核 token scope 须含 omn-data 桶全读写 List, 补后 Restart 复验 v1-v5.
- `R2_BUCKET=omn-data` 圣上已补设 (本文件 line 210 ✅) — replica 配置 (litestream.yml bucket: ${R2_BUCKET}) 用之。

**治法** (圣上侧操作, 我无 HF UI 权限 §2 凭据零入会话):
1. nonoke/omn Space (现唯一 Space) → Settings → Variables 补 3 R2 凭据 (`R2_ACCESS_KEY_ID`/`R2_SECRET_ACCESS_KEY`/`R2_ACCOUNT_ID`, 圣上手填, token **scope 锁 omn-data 单桶 Write+Read**, 单桶无双写越权面) — **✅ 已补 (2026-08-20 boot 实证 has_r2=1)**。
2. Restart 非 Rebuild (纯 Variable 改零数据清零) → boot 看 `[entrypoint] Litestream:` 行态定病根②真伪 — **✅ 已处置 (2026-08-20 boot 实证 PID=151 开态 replicate 启)**。
3. **litestream.yml path env 派生修复 (c790e05)**: `/app/data/storage.sqlite` → `$\{DATA_DIR\}/storage.sqlite` 对齐运行 DATA_DIR=/data (病根③) — **✅ 已改 (待 push nomn → sync → Dataset → Restart 生效)**。

**§1 单 Space 单桶**: nomke 废剩 nonoke 唯一 Space; R2=omn-data (dev桶升正, omniroute-data 不动存历史); 单 Space 单桶无双写问题。**遗留疑点** (不阻塞本次, 须圣上侧排查): 2026-07-27 04:55Z boot snapshot 全链 (本文件 line 173) audit 证那时 replicate 启写 omn-data 桶, 但本文件 line 170 后期"无 3.8.48 snapshot" = R2 副本后期已无。须圣上侧 R2 Dashboard 核 omn-data 桶 `db/storage.sqlite` path 历史代数现状。

**验证两轮** (候圣上侧):
- **首 boot 复验** (c790e05 部署后, 建首个 R2 snapshot): Restart → 5 验签点: ① restore 段 **`restore rc=0 原子 mv` 或 `无副本空库启动`** (path 对齐后 config 找得到 DB, 不再 `database not found`) ② replicate PID 印 (L403 开态, 病根②已解除 2026-08-20 实证) ③ init rc=0 ④ ≥10s litestream sync 写 R2 (log `replica: sync: wrote segment/snapshot complete`) ⑤ R2 Dashboard omn-data 桶 `db/storage.sqlite` 首个 generation 建。**判定**: 若仍 `database not found in config: /data/storage.sqlite` = path 修未生效 (sync 未上 Dataset / env 展开不支) → 回我侧查。
- **二 boot** (真持久化铁证): 再 Restart → boot `restore rc=0 原子 mv` + 本地非空 skip (L130) → Dashboard 手加 manage key → 再 Restart 仍存 (catch-22 破) → 路径1 external 脚本可真跑。

**与路A关系**: 非互斥并存。R2 持久化后 manage key 持久 → 路径1 external 可跑; 但 init boot 自清 (路A) 仍留 dev 自愈兜底 (每 boot 重建同步清上轮风暴残留, 不依赖 external key)。

**待办/下一步**:
- [ ] 圣上侧补 3 R2 凭据 + OMN_PERSIST_WRITE 处置 (§2 零入会话 我侧候命)
- [ ] 圣上侧 R2 Dashboard 核 omn-data 桶 `db/storage.sqlite` path 历史代数现状 (副本后期空根排查)
- [ ] 首 boot 验签 v1-v5 (候 boot 日志贴回)
- [ ] 二 boot 验真持久化 (restore 拉真库 + manage key 跨 boot 持久)
- [ ] 全绿续真持久化闭环段

本轮 0 代码改动, SSOT 落 (HANDOFF ephemeral 死结段+commit链 / DECISIONS §7 / STATUS 本段). DECISIONS 只增不改 (§4 §5 §6 未动). 翻案须圣上明确令 (§0).
