# HANDOFF.md · omn 交接 / watcher 模式清单

> 会话/班次交接 + 长跑 watcher 哨兵串。每次交接补"交接时刻状态"行; watcher 串清单是 in_progress 长跑探活/巡的命中表。
> SSOT 角色与 ops/STATUS.md 互补: STATUS 记部署态硬指标, HANDOFF 记"此刻谁在跑/盯什么/等什么信号"。

## 交接时刻状态

### 2026-07-25 (本轮末) · 切换 ② boot 前固化批落地完毕 — 待圣上 Restart (执行人: cg52 侧, Claude Code 侧落引导前修源/固化)
- 本地 HEAD: `dbedbed` (动态见 `git log --oneline -1`)
- 本轮四 commit: `5ee3778`(K3三件) `e76ccf3`(②三钉点) `1159de6`(probe修源+三样固化) `dbedbed`(STATUS)
- 远端 Dataset: init=`a1640dd5` (probe 修态 push 闭环 byte-for-byte), 余4件见 ops/STATUS.md
- ⚠ CLAUDE.md v3 圣上签改未 commit (留圣上自 commit / 明令)
- ✅ 拓扑漂移已收敛: v3 §1 `dev/logic/` 路径落地本轮 (git mv omn-logic→dev/logic, 五件 history 保留); Dataset repo 名 `nonoke/omn-logic` 保持不变 (Dataset 名≠仓内目录, bootstrap 契约 Dataset 根平铺一字不动)
- n-omn GitHub 远端 ahead 38 commit 未推 (§3 禁 push 待圣上判)

### ② 启动门 四项 (已全落地 ✅)
1. ✅ Space Variable `GATE_UPSTREAM_TIMEOUT_MS=180000` (已注入, boot#2 行为实证生效)
2. ✅ Secret `NIM_KEYS` 填 32 行 (非预案 25, 圣上裁决一照准 32 是地面真值)
3. ✅ `GATE_ADMIN_ENABLED=0` (非删 token, 布尔开关关 — 钉 3 后台收敛, boot#2 `[gate] admin UI: disabled`)
4. ✅ Restart dev Space (§2 圣上手动) → boot#1 11:02 + boot#2 11:22

### boot 后验 (验收四笔 + 裁决五第五项)
- ✅ 2 次干净 boot (boot#1 11:02 + boot#2 11:22 主动 Restart 验 32 key 幂等, 读回 `300/200/96/300000` 一字不差)
- ⏳ **池成分健康 (裁决五第五项, release-checklist B4)**: matrix 四笔缺口 — nim-pool 笔1 200 (2.2s nemotron-3-super) / nim-pool 笔2 超时 101s (p2c 命中挂) / nim-codex 笔1 超时 101s (priority 挂无 fallback). 根因 = **池成分病非 combo 路由病**: gpt-oss-120b + llama-3.3-70b 上游挂/极慢, probe 只测 glm-5.2 无 init 期感知, pool p2c 25% 染慢 codex priority 100% 掉. 达成路径 = 圣上从 8 模型意向池剔两挂模型 → cg52 复跑 matrix 到双 combo 绿
- ✅ 长思考一笔 (B3 + GATE_UPSTREAM 180000 实证): glm-5.2 SSE 真流式 (首 token 2.1s) + gpt-oss-120b 3.8s `: omniroute-keepalive` (gate 主动 keepalive 维持长连接无 30s 错包切 → 行为闭环, boot 日志无 echo 不追究)
- ✅ 429 基线改挂③ (裁决三): 不重开 admin, 切 R2 生产 bucket omniroute-data 时 litestream 同一 storage.sqlite (含 dev 期 call_logs 全量) 复制到生产侧, 一行 SQL status_code 分桶白捡; 原"生产限流档裁决"时点改挂 429 基线 + ③ 后 24h 风暴串计数 = 0 两项齐后落 DECISIONS
- ② 加速版退出六绿: 2 boot ✅ / 长思考 ✅ / 429 改挂 ✅ / 池成分 ⏳ / 过夜 ⏳ — 剩圣上剔挂模型 + 过夜 + 圣上手动链 (HF_TOKEN_NONOKE→push→sync-logic-dev 首跑绿→BASE_IMAGE 钉锚→dispatch 骨架→Rebuild FROM=9c9aecf) 三件

## watcher 模式: 风暴特征串 (命中即告警)

> #4 OOM 链 + 账户级 fallback 的运行时签名。任一命中 → 不是池行为本身, 是病链尾部征兆, 第一排查 #4 / 配额共享 / 真 dead key。

| 串 | 出现场景 | 含义 | 首排查 |
|----|----------|------|--------|
| `FALLBACK MODE - excluded_count` | omniroute 对超大 body / 400-context-overflow 走 N-key round-robin | #4 病链中段, 非 400 终态拒而走全 fallback | gate 前 1.5MB 拦是否漏 (chunked / 比率<8), body 是否超阈该被 413 拦 |
| `all .* accounts unavailable` | 25-key fallback 跑完全空转 | #4 病链尾段终态拒 (生产 90秒空转签名) | 同上源头 + 此 key 批是否全死 (NIM 账户级封) |
| `Preserving last upstream error` | fallback 跑完保留上游错 | 终态拒回显, 前探 `Excluded`/`FALLBACK MODE` 追链 | 追 `FALLBACK MODE - excluded_count` 递增计数, 定 400 主体 |
| `ECONNREFUSED 127.0.0.1:20129` | `ProxyFetch` 运行时探 20129 | 20129 幽灵 (purge 0/0/0 但脏 proxyUrl 存他处) | 迁移日 M1 定点清, 非紧急不碰, §1 历史遗留 |
| `Excluded due to decommission` | 25-key round-robin 跳过死 key | 正常淘汰(死 key 跳), 非 #4 | 配 `FALLBACK MODE` 同看: 单 `Excluded` 计 = 常规, 配 `excluded_count` 递增 + `all unavailable` = #4 |

## watch 命令(本地合成探, 不触生产 / 不含真 key)

```bash
# boot 日志尾段抓风暴串 (仅本地可读 / HF Space 日志圣上贴回后我侧 grep)
tail -f /tmp/dev-boot.log | grep --line-buffered -E 'FALLBACK MODE|all .* accounts unavailable|Preserving last upstream error|ECONNREFUSED 127.0.0.1:20129|Excluded due to decommission'
```

## 战后建设队列 (③ 稳定后按依赖序启动; ② 浸泡期逻辑层零变更, 列队不插队)

> 圣上 2026-07-25 令: 六件 + 每模型 probe 列入此节, 防战后喧嚣遗忘。排序 = 依赖序 (前崩不阻后, 每件独立可验证)。阻塞点 = push (③ 后 nomn 首推 + 分支保护由圣上 GitHub 侧设)。

| 序 | 件 | 动哪个文件 | 依赖前件 | 阻塞 |
|----|----|-----------|---------|------|
| 1 | **P0 entrypoint 统一落盘** (LOG_DIR tee 前缀, 持久落盘解 HF 30min 抓取窗口死线) | `dev/logic/entrypoint.sh` (逻辑层, ② 后动) | 无 (地基) | ② 稳 |
| 2 | 每模型 probe (init 探活扩到池内全模型, 与 P0-tee 同批) | `dev/logic/init-nim-keys.sh` | P0-tee 落盘才能看全模型探活日志 | ② 稳 + P0 |
| 3 | **P1 incidents 库进 litestream 复制链** (ops/incidents 随 storage.sqlite 同步到 R2, 非仅仓 git) | `dev/logic/litestream.yml` | P0-tee (日志归档前提) | ② 稳 |
| 4 | **P2 watcher 本体 + 模板化摘要生成器** (消费特征串清单落地为进程, 非仅 HANDOFF 静态表) | 新 skill `incident-digest` + 脚本 | P1 (读 incidents 库) | P1 |
| 5 | **P3 外推 + handoff-sync 防漂移检查** (跨会话 HANDOFF/STATUS/DECISIONS 对账, 漂移告警) | 新 workflow / 新 skill `handoff-sync` | P2 (摘要源) | P2 |
| 6 | **T6 base-image.yml** (BASE_IMAGE 钉锚变 Variable 化 workflow, Rebuild FROM=9c9aecf 守门) | `.github/workflows/` 新件 | ③ 中 dispatch 骨架首跑绿后定型 | push |
| 7 | **claude-code-action cron 异步解读层** (脱敏证据包定时解读, 非同步链) | `.github/workflows/` 新件 + Anthropic API key secret | P0~P2 产脱敏证据包 + ③ 稳 | P3 + push + secret |

注:
- 现役 `handoff` skill = §0 交接块生成器, 非 `handoff-sync`。当初规划的 `incident-digest`/`handoff-sync` 两 skill 一件未建 (疑点一核实)。
- claude-code-action 需 Anthropic API key 作 GitHub Secret, 该 secret 从未配置, workflow 写好也跑不起来 (疑点三)。
- 分支保护依赖 nomn 首推后由圣上 GitHub 侧设 (非仓内改动)。
- 此节为圣上 must① 落地, 非 must② (push 闸) / should (③ 后动) / could (T6/claude-code-action 同批 P3)。

## 历史 watcher 闭环 (已除病, 留作特征参考)

- express `MODULE_NOT_FOUND` crashloop → saga express fix 闭环 (audit/2026-07-23-crashloop-express-fix-landed.md)
- init upload_folder 403 crashloop → C1 token 加 write 权 + C2 upload try/except 闭环 (audit saga)
- `jq: Cannot index array` → C1 jq 归一化闭环 (task5)
- `7 registered` 静默终断 → C2 pipefail 闭环 (ops/incidents/2026-07-25-c2-pipefail-init-silent-death.md)
- probe subshell exit1 经裸 wait 触 set-e 杀 init (2026-07-31, 同源病族第三轮) → `_probe_one` 子shell最后语句非verbose模test返exit1→裸`wait`收1→`set-e`杀init→container exit1, 两boot崩05:24/05:25。治法L675末`||true`兜恒exit0 (commit `ef16b46`)。诊断弯路教训: 我前臆测"HF supervisor杀"被圣上驳回退查源坐实代码bug, 排障先穷尽代码退出码传播链再归外因。06:14 boot PROBE=1真路透rc0+40秒三轮对照定谳。(ops/incidents/2026-07-31-probe-subshell-exit1-crash.md)

## FT Worker 100 池架构交接 (2026-08-12 落地})

> GitHub Actions 自控部署 CF Worker 出口换 IP 层 (非 n-vless/n-edget)。血统 + 契约 + 排障入口在此, 历史裁决见 ops/DECISIONS.md (2026-08-12 三段)。

### 不变量
- **拓扑**: 10 CF 账号 × 10 Worker = 100 上限, 现役启 4 账号 40 Worker (`ACTIVE_ACCOUNTS` Variable 控扩, 加 f05~f10 zone 仅改此值 workflow 矩阵自适应)。
- **域名派生**: `{worker 1-10}.f{account 01-10}.cc.cd` (圣上定 f, 非 n-vless `%10` 循环回0)。Worker 名 `<W1>-<W2>-ft{1-10}` (每账号独立抽双词, 后缀 `ft` 非 `v`)。
- **鉴权铁律**: Worker `env.RELAY_AUTH` ↔ 桥 (HF Space Secret) `RELAY_AUTH` 同值, 异值则桥 401。fail-closed (`env.RELAY_AUTH||null` + `!AUTH_KEY`)。
- **endpoint.json = worker-major 排**: idx0-9=worker1 各账号, ..., idx90-99=worker10。nim 桥 `workers:"0-39"` 连续直取 = 每账号前4 worker。真身 in HF Dataset `nonoke/omn-logic` `flaretunnel_endpoints.json` (workflow publish-endpoints job 自动派生传)。
- **bridges.json 圣上域**: `flaretunnel_bridges.json` (HF Dataset同仓) 圣上手设 UI, workflow 不传 bridges。现役 `[{nim,8081,0-39,nvidia}]`。
- **触发 tag-driven**: `on.push.tags:['deploy-*']` 普通 push 零触部署; workflow_dispatch 输入框 preset 即时覆盖 Variable。
- **§2 secret 真值零入 git/会话**: CF_API_TOKENS/CF_ACCOUNT_IDS/RELAY_AUTH/GH_PAT/HF_TOKEN_NONOKE 全 GitHub Secrets, wrangler secret put 加密存 CF。

### PRESET 场景表 (圣上手工定 deploy 路径)
| PRESET | 动作 | pass_mode | deploy 格 |
|--------|------|-----------|----------|
| `gen` | 生 100 名写 WORKER_NAMES Variable | - | 跳 |
| `first` | 首次全量建 Worker 双 pass 绕 CF 扫描 | 2 | 100 |
| `daily` | 日常单 pass 全量重部署 | 1 | 100 (~16m) |
| `publish` | **仅派生 endpoint.json 传 Dataset, deploy 跳省 16m** | - | 跳 |
| `solo:N` | 单账号 N 部署 10 Worker | 1 | 10 |
| `secrets` | 仅更 RELAY_AUTH secret 不重绑域 | - | 100 (deploy 注 secret) |
| `delete:1` | 删 WORKER_NAMES 对应单 Worker 后重建 | 2 | 100 |
| `delete:v` | 删账号下全 Worker (全删无滤波) 后重建 | 2 | 100 |
| `delete:o` | 删旧/孤儿/过时词基 Worker 唯保留现役名单, 无部署 | 0 | 跳 |

### 链序 (新 zone 扩池)
1. 圣上 CF 侧加 zone (f05~f10.cc.cd) + 建对应 token (锁该账号+zone)
2. GitHub Secrets 加 CF_ACCOUNT_IDS/CF_API_TOKENS 该账号位序
3. GitHub Variable `ACTIVE_ACCOUNTS` 改 N (现 4→N)
4. `PRESET=gen` 触生名 → `PRESET=first` 触全量建 (双 pass) → Worker+域绑成
5. `PRESET=publish` 触 (deploy 跳) → endpoint.json 自动传 Dataset (worker-major 重排含新 Worker)
6. 圣上 HF UI 改 bridges.json nim `workers:"0-{N*4-1}"` (扩账号扩取前4)
7. Restart dev Space → boot 真验池 N×10 Worker

### 排障入口
- **Worker 401 全拒**: RELAY_AUTH 未注或异值 → 查 `PRESET=secrets` run log 印 `Successfully created secret for key: RELAY_AUTH` (workflow Deploy1st/2nd `with.secrets:` 输入须有)
- **某 Worker 域 `no such host`**: CF zone DNS 未绑/nameserver 未接 (非 Worker/部署错, 同代码他 zone 全活证) → 圣上 CF 侧修 zone DNS 服务器, 无须重部署。round-robin fallback 兜跳死 Worker 仍 200 = 韧性。
- **Worker 池数不符**: `ACTIVE_ACCOUNTS` Variable 控, endpoint.json 看 publish-endpoints 派生条数 = ACTIVE_ACCOUNTS×10
- **proxy 真生效证**: HF Dataset `nonoke/omn-logic` `save/ft/` capture log (每 60s 一件, `via Worker:` + `✅ 200` + Prometheus `flaretunnel_worker_requests_total`)
- **per-Worker 计数**: FT 桥 `/metrics` (容器内 127.0.0.1:8081, 公网 gate 未暴露; boot 时 init 内 curl 印一次; 持续观 Save/ft/ 件 `FT METRICS DUMP` 段)
- **本地拉 save 日志**: `source ~/.omn-secrets; env HF_TOKEN="$HF_TOKEN_DATASET_WRITE" python3 -c "from huggingface_hub import hf_hub_download as f; print(f('nonoke/omni-logic','save/ft/<件>',repo_type='dataset',token=__import__('os').environ['HF_TOKEN']))"` (repo 真 nonoke/omni-logic 非 omn-logic)

### commit 链 (本会话及前轮)
`008c48d` 雏 → `6c78f2d` 100 拓扑 → `1431b0f` delete:o → `08d272a` tag-driven → `c10d544` secrets bug → `517357f` RELAY_AUTH 真注 → `d1c324b` publish-endpoints job → `c22b3a9` PRESET=publish。nomn/main 远端 = `b577e5b` (含 STATUS)。

### 待办/下一步
- gate 加路由暴露 FT 桥 `/metrics` 公网 (现容器内 127.0.0.1:8081, 公网取不得 per-Worker 计数) → 下会话事
- ACTIVE_ACCOUNTS 现役启 4 账号 40 Worker (满额 100 待圣上加 f05~f10 zone)
- 5 deprecated model (kimi-k3/deepseek-v4-flash/pro/qwen3.8-max/mistral-small-4) NVIDIA 目录无 → 圣上定剔或留
