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
- **拓扑**: 10 CF 账号 × 10 Worker = 100 上限, 现役**满额 10 账号 100 Worker 全活** (`ACTIVE_ACCOUNTS=10` Variable 已设, f01~f10 zone 全启; 扩/缩仅改此值, workflow 矩阵自适应)。
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
3. GitHub Variable `ACTIVE_ACCOUNTS` 改 N (现 10→N)
4. `PRESET=gen` 触生名 → `PRESET=first` 触全量建 (双 pass) → Worker+域绑成
5. `PRESET=publish` 触 (deploy 跳) → endpoint.json 自动传 Dataset (worker-major 重排含新 Worker)
6. 圣上 HF UI 改 bridges.json nim `workers:"0-{N*4-1}"` (扩账号扩取前4)
7. Restart dev Space → boot 真验池 N×10 Worker

### 排障入口
- **Worker 401 全拒**: RELAY_AUTH 未注或异值 → 查 `PRESET=secrets` run log 印 `Successfully created secret for key: RELAY_AUTH` (workflow Deploy1st/2nd `with.secrets:` 输入须有)
- **某 Worker 域 `no such host`**: CF zone DNS 未绑/nameserver 未接 (非 Worker/部署错, 同代码他 zone 全活证) → 圣上 CF 侧修 zone DNS 服务器, 无须重部署。round-robin fallback 兜跳死 Worker 仍 200 = 韧性。
- **Worker 池数不符**: `ACTIVE_ACCOUNTS` Variable 控, endpoint.json 看 publish-endpoints 派生条数 = ACTIVE_ACCOUNTS×10
- **proxy 真生效证**: HF Dataset `nonoke/omn-logic` `save/ft/` capture log (每 60s 一件, `via Worker:` + `✅ 200` + Prometheus `flaretunnel_worker_requests_total`)
- **per-Worker 计数**: FT 桥 `/metrics` (容器内 127.0.0.1:8081) + 公网 `gate /v1/ft/metrics` (PSK 鉴权反代, commit `ec0712d` 路3-b 落; `?bridge=N` 0-基选桥默首桥, ECONNREFUSED→503); boot 时 init 内 curl 印一次; 持续观 Save/ft/ 件 `FT METRICS DUMP` 段
- **公网取 FT metrics**: `curl -H "Authorization: Bearer $INTERNAL_PSK" https://<Space>/v1/ft/metrics` (PSK fail-closed, 缺/错 401); `?bridge=N` 选桥 (0-基, 越界 400 `bad_bridge_index`), 不带参默首桥 (首桥代整体, init-nim-keys.sh `_ft_register_proxy` 旧例)
- **本地拉 save 日志**: `source ~/.omn-secrets; env HF_TOKEN="$HF_TOKEN_DATASET_WRITE" python3 -c "from huggingface_hub import hf_hub_download as f; print(f('nonoke/omni-logic','save/ft/<件>',repo_type='dataset',token=__import__('os').environ['HF_TOKEN']))"` (repo 真 nonoke/omni-logic 非 omn-logic)
- **慢诊 (2026-08-13 时延基线对比, 详 ops/STATUS + DECISIONS §4)**:
  - 基线 `audit/2026-07-20-r3plus-group2-3parallel-10rounds.md` (16 Worker 扩 100 前, 3 并发 10 轮): 200 2.17-14.15s; 现态 100 Worker 3.5-33.7s + 30s client abort. 差上限 +19.6s (+138%) 翻倍. 慢真.
  - 慢真四根: ① 100 Worker round-robin 游标长+冷端握手 ② `unhandledRejection AbortError` 30s client abort 漏 catch ③ ft1 集中 403 (NIM 侧非 IP, 重诊 NIM key 维度) ④ HF 2vCPU 计算压 (90k token 注入, 恒定非升级)
  - CF IP 优化: 100 Worker 共享池 = CF 免费层 IP 多样性天花板. 独享固定 IP = Enterprise + 反设计 (撞 warp-vs-ft③否决). Smart Placement 微调不轻试. 多账号撞圣上 10 上限.
  - 外部 AI 文"关小黄云/优选 IP 映射/收子域/砍 Worker" 全伪或撞锁, 不可执行 (详 DECISIONS §4).
  - 无 FT 直连 NVIDIA 测 = 真"FT 开销"定论前提, 候圣上命.
- **429 风暴诊断 (2026-08-19 红外, 详 ops/STATUS + DECISIONS §5)**:
  - **429 = NIM account-level 配额速率限** (纯 key/account 维, 非出口 IP 维). 真根非本地 bug 非 FT 桥病.
  - 签名: 32 account 窗 140 请求 40% 成功, 21 account rate_limited **散布无 IP 族聚类** (IP 限应扎堆反成簇), 限速标 `nvidia:<UUID>` (account 非 IP), 熔断 CB CLOSED (未跳, round-robin 始终换 account), cooldown 0 (60s 窗过即回活). 现态 0% 错 = 风暴过回稳.
  - **combo `—` 空 = 正常非病**: glm-5.2 单 model 设计 (`getComboForModel` 返 null = single-model 非 fallback 失效, 连 200 也 `—`). 勿按"combo 空最可抓活根"误判.
  - **fallback 韧态全活**: attempts 链跨 account 连试 (be1e20b9 7/3b3e55c6 16 末 200/36a91736 12 末 200) + 控制台 `🚫 [RATE-LIMIT] pausing for 60s` (cd 实跑 60s, 源码 default 120s = 配覆写, 查 `/api/resilience`) + `FALLBACK MODE excluded_count ... picked_lru` (LRU 排已限选下一) + `Account X error cleared`.
  - **三病并存** (非互斥): 429 (account 维主流) / 403 (ft1 族 IP/权限维, 前轮 §4 另案候查) / 502 (1× nim-13 NIM 服务层 RST 透传).
  - **陈旧错态 gap**: 冷却 (60s) 过期回活后 lastError code 429 不自动清 → Health Autopilot 检 22 issues 提"Clear stale error state"手动清 (小 bug: 路由偏置或绕开本已回活 account).
  - **路 A 自清已落 (2026-08-19 ✅ commit 3158c2c)**: init boot 自清 `clear_stale_nim_errors()` (dev/logic/init-nim-keys.sh, gc_stale_providers 后调)。走 Dashboard session cookie 鉴权链 (login→auth_token cookie 调管理端) 调 `GET/POST /api/providers/health-autopilot`, 提 `issues[].actions[]` 里 `type=clear_stale_connection_error` 的 (connectionId, preconditionsHash) 逐清。fail-open (非200跳过, set +eo pipefail 抬门防空 pipefail 杀 init, 0 stale return 0, 终态连接 409 skip)。ENV 闸 `OMN_CLEAR_STALE` 默1开 =0 跳整段。dev ephemeral 语境唯一解 (R2 无副本每 boot 空库 → external manage key catch-22 不持久)。boot 真活回显三态: 无 stale 空转 / 清 N / fail-open 跳 (2026-08-19 13:25Z 实测无 stale 空转)。clear-stale-nim-errors.sh 保留 prod 备 + 参考文档。源 3.8.48 `src/app/api/providers/health-autopilot/{route.ts,actions/route.ts}` + `providerHealthAutopilot.ts executeProviderHealthAutopilotAction` actionSchema。
  - 解候命: 降客户端高频 / 拉长 429 cd 120-180s / 扩 account 池撞 10 上限 / NIM 侧提配额 (真根治非本地能控). 真测现态不建议 (0% 错无活病, 造风暴成本高).
  - **路 B R2 持久化真根治已批待落 (2026-08-19 圣上令 "加 r2 搞定持久化")**: 路A自清乃绕过 ephemeral 死结; 路B = 补 R2 凭据启 litestream replicate 写 R2 → restore 拉 R2 真库 → manage key 跨 boot 持久 catch-22 破 → 路径1 external 脚本 `dev/scripts/clear-stale-nim-errors.sh` 可真跑。**零代码改动 = 纯 HF Space Variables**: 代码链已全建好 (litestream.yml R2 s3 replica / entrypoint.sh has_r2 判活 L124-125 + restore L128-166 + replicate L391-407 + STRICT L499)。**实证病根①**: 3 R2 凭据 (`R2_ACCESS_KEY_ID`/`R2_SECRET_ACCESS_KEY`/`R2_ACCOUNT_ID`) 未齐 → `has_r2=0` skip restore 空库 (STATUS line 170 钉死)。**待核病根②**: `OMN_PERSIST_WRITE` 现态未实证 — 该闸 2026-08-10 加入默认未设=1开 (entrypoint L400 闸 `$\{OMN_PERSIST_WRITE:-1\}`, memory `omn-persist-write-request-landed-2026-08-10` line 13 "现状本就是保存的 replicate 无条件跑"), 圣上 08-10 加闸后可能从未设0故默1开 replicate 跑; 关态病根乃前轮摘要记忆断言**未经 boot 日志实证**, 真根若"加 key 重启丢"可能是 litestream 链有病 (replicate 死/restore 断/sync-10s 窗口) 非设计不保存 (memory line 13 "须贴 boot 日志取证定根 未结")。圣上侧补凭据后 boot 验 `[entrypoint] Litestream:` 行态定关态真伪, 若设0关须处置设1或删回默1; 若未设默1开则跳处置仅补 3 凭据。`R2_BUCKET=omn-data` 圣上已设 (STATUS line 210) 但 has_r2 不验此故不生效。**§1 拓扑翻案 (同期圣上明令)**: 撤 nomke 生产, 剩 **nonoke/omn 单 Space 兼生产+dev**; R2 = omn-data (dev 桶升正单桶, omniroute-data 旧生产桶不动存历史); 单 Space 单桶无双写问题 (旧双 Space "R2 永不双写" 铁律随 nomke 撤失效, CLAUDE.md §1 已改 单源单Space)。治法: 圣上侧 nonoke/omn Space (唯一) 补 3 R2 凭据 (token scope **锁 omn-data 单桶 Write+Read**) + boot 验 PERSIST 行态后决定是否处置。Restart 非 Rebuild (零数据清零)。验签两次: 首 boot 见 `[entrypoint] Litestream: PID=...` 开态行 (非关态) 建 R2 snapshot (litestream sync 写 R2) / 二 boot 真持久化 (restore rc=0 拉真库 + 本地非空 skip + manage key 跨 boot 存)。**遗留疑点**: 2026-07-27 04:55Z boot snapshot 全链 (STATUS line 173, audit §2.1 证 replicate 启拍 snapshot 成功) = 那时 has_r2=1 凭据齐 replicate 跑写 omn-data 桶, 但 STATUS line 170 后期"无 3.8.48 snapshot" = R2 副本后期已无 (可能 lifecycle 清/凭据撤/关态无写致空/桶误删), 须圣上侧 R2 Dashboard 核 omn-data 桶 `db/storage.sqlite` path 历史代数现状。候圣上补凭据 (§2 零入会话)。
  - **2026-08-20 连续 boot 实证更新 (四病根)** — 病根①**已解除** (凭据齐 has_r2=1, boot 走 restore 分支非 skip), 病根②**已解除** (圣上处置 PERSIST, boot 印 `Litestream PID=149/151/156` 开态非关态), 病根③**已解除 (c790e05 + 手推)** = **litestream.yml `path` 硬编码 `/app/data/storage.sqlite` 对不上运行 DB path**: entrypoint 默认 DATA_DIR=/app/data (L16) 但 HF Space env 设 `DATA_DIR=/data` → 运行 DB 实际 `/data/storage.sqlite` (boot 印 `SQLite database ready`), 13:53 boot 报 `database not found in config: /data/storage.sqlite` → **`⚠ restore 失败 rc=1 空库启动`**。**修法 (commit c790e05)**: path 改 `$\{DATA_DIR\}/storage.sqlite` env 派生。**15:36 boot 实证生效**: 错误从 `database not found in config` **变成** `s3: ListObjectsV2 403 AccessDenied` = path 正确展开成 `/data/storage.sqlite` 匹配运行 DB, 已到 S3 访问阶段。**手推链路**: c24c959 push 触 sync-logic-nonoke Action **失败** (job 0 steps 2 秒 fail, run id 32373926257, 根未查 — 疑 runner 分配/触发级, 非 step 失败), 手推 litestream.yml 上 Dataset (Python hf upload 注入 HF_TOKEN_DATASET_WRITE, 读回 sha256 闭验 `982a050f3a4f539b` 匹配)。**病根④实锤真根** = **R2 S3 token 缺 List 权限**: 15:36 boot 报 `s3: list generations: ListObjectsV2, 403 AccessDenied` — litestream 启动列 omn-data 桶 `db/storage.sqlite` generation 被拒 = token (R2_ACCESS_KEY_ID 对应) 无 omn-data 桶 Object List 权限. litestream 需 **ListObjectsV2 + GetObject + PutObject + DeleteObject** 全权限. 圣上侧 R2 Dashboard 核 token scope 含 omn-data 桶全读写 List, 补后 Restart 复验 v1-v5. **验签判定**: 首 boot 复验 `restore rc=0 原子 mv` 或 `无副本空库启动` + replicate PID + init rc=0 + litestream sync 写 R2 + R2 Dashboard 首个 generation; 二 boot 真持久化 (restore 拉真库 + manage key 跨 boot 存)。
  - 解候命: 降客户端高频 / 拉长 429 cd 120-180s / 扩 account 池撞 10 上限 / NIM 侧提配额 (真实治非本地能控). 真测现态不建议 (0% 错无活病, 造风暴成本高).
  - **自定义 provider 前缀路由遮蔽排障 (2026-08-21, 源码级定谳)**: 现象 = 自定义节点 `sensenova` (prefix=sensenova, 连接 provider=75176e99) 前缀调用 `sensenova/<model>` 报 "No credentials", 而结构完全对称的自定义节点 `amd` (prefix=amd, 连接 484711e6) 前缀调用通。**后台 Test 功能直调长 ID `openai-compatible-chat-75176e99-.../<model>` 200 通** (节点+连接+key 全健康)。**真根 = `sensenova` 是 OmniRoute 内置 provider** (regional.ts:331-348, id+alias 均 `sensenova`): model.ts:277 `getReservedProviderPrefixes()` 把内置 id+alias 全入 reserved 集合, L280 `if(!isReservedPrefix)` 对 `sensenova`=false → **跳过自定义节点匹配块 (L281-326)** → 落回 getModelInfoCore 查内置无连接 → No credentials。`amd` 非内置 → 走 L285 自定义节点匹配 → 通。**治法 = 自定义节点 prefix 不得与内置 provider id/alias 撞名** (改非内置名如 `snova`, 已验证不在 REGISTRY; 连接 providerSpecificData.prefix 同步改或删旧重建; 长 ID 直调不受影响)。诊断自定义前缀路由须先 `grep REGISTRY` 确认前缀非内置。详见 DECISIONS §8.1 追更段。
  - **2026-08-21 boot 真持久化闭环 (task #12+#13 全绿, 路 B 收官)** — 首 boot (01:11Z) v1-v4 验签全过: v1 `✓ 已从 R2 恢复 (原子 mv ...restore.1 → /data/storage.sqlite)` = restore rc=0 真拉 R2 库; v2 `Litestream PID=150` 开态; v4 litestream.log `replicating to type=s3 sync-interval=10s bucket=omn-data path=db/storage.sqlite` + 持续 `compaction complete` (txid 0x100→0x123 递增) = **每 10s 新数据写 R2**; 前轮 `snapshot complete txid=0xc0 size=121786` = snapshot 建立。**二次 boot (01:56Z) 真持久化铁证**: `restore rc=0 原子 mv` + `JWT_SECRET restored` + **`sensenova/glm-5.2` 调用成功 (02:01:24, AUTH: Using sensenova account: 1a7e54ff)`** = 重启后节点/连接/key 全在且可路由 = **catch-22 破** = 配置跨 boot 真持久。**结论**: 路 B R2 持久化真根治**完成**, manage key 持久 → 路径1 external 脚本 (`dev/scripts/clear-stale-nim-errors.sh`) 可真跑。litestream restore+replicate 链真活。

### commit 链 (本会话及前轮)
- FT Worker deploy 链: `008c48d` 雏 → `6c78f2d` 100 拓扑 → `1431b0f` delete:o → `08d272a` tag-driven → `c10d544` secrets bug → `517357f` RELAY_AUTH 真注 → `d1c324b` publish-endpoints job → `c22b3a9` PRESET=publish → **`(本 commit)` FT Worker 拓扑全可配变量化 (WORKERS_PER_ACCOUNT + PRESET=reorg, DECISIONS §10)**。
- dev/logic 镜像链: `3b1564c` deepseek/mistral-small-4 剔 → `ec0712d` gate /v1/ft/metrics PSK 反代 (路3-b) → `54b1b5a` clear-stale-nim-errors.sh fail-loud 修 → `3158c2c` init boot 自清 OmniRoute 陈旧错态 clear_stale_connection_error (路A)。nomn/main 远端 = `3158c2c` (含 STATUS, sync-logic-nonoke.yml 推 HF Dataset nonoke/omni-logic auto sync)。
- 诊断链 (本会话, nomn main): `e888712` 路B §8.1 实证修订 (自定义 provider 路由两段链 prefix→节点UUID查连接, 长 UUID 直调不通根因) → **待 commit**: §8.1 追更段 (sensenova 撞内置名遮蔽根因, 源码级) + 本 HANDOFF 排障入口。**候选 commit 号待 HEAD 前序确认 (e888712 之后)**, push nomn main (§5 圣上手推)。

### 待办/下一步
- ✅ init boot 自清 OmniRoute Health Autopilot 陈旧错态 (commit `3158c2c` 路A落, clear_stale_nim_errors() 函数; boot 真活回显 2026-08-19 13:25Z 无 stale 空转; Dataset nonoke/omni-logic 手推 `169bc09c` sha256 闭验)
- ✅ gate 加路由暴露 FT 桥 `/metrics` 公网 (commit `ec0712d` 路3-b 落, `GET /v1/ft/metrics` PSK 反代 + `?bridge=N` 选桥; 真路测五态全绿 2026-08-12)
- FT Worker 100 拓扑已满额全活 (2026-08-12 圣上扩 f05~f10 zone + Variable `ACTIVE_ACCOUNTS=10`)
- deprecated model 剔: 2026-08-12 圣上令删 deepseek-v4-flash + deepseek-v4-pro + mistral-small-4-119b-2603 (NVIDIA 目录无, 已落 init-nim-keys.sh); 留 kimi-k3 + qwen3.8-max (圣上未命删, deprecated 但待复检)
- ⏳ **FT 健康感知轮转已落码待启用** (2026-08-23 落码, docs/ft-health-aware-rotation.md + DECISIONS §9): FlareTunnel.go GetWorkerURL 顺序扫跳不健康 worker + entrypoint.sh `FT_HEALTH_COOLDOWN` env 控. 默认关 (不设=纯 RR 不变), 要启用设 `FT_HEALTH_COOLDOWN=30` → Restart. 待圣上定推 HF Dataset + 真启用 (对治慢根①死 worker 照轮打冷端)
- ✅ **FT Worker 拓扑已收缩到 10×3 (全账号 × 每账号 3)** (2026-08-23 圣上触发 `PRESET=reorg` run#23 成功, deploy-ft-workers.yml + DECISIONS §10): 新增 `WORKERS_PER_ACCOUNT` 变量 (默认 3, 甜点) + 账号数 `ACTIVE_ACCOUNTS` (**全账号都用上**: Variable 已设 10=f01~f10 全 zone), **两端全可配**贯穿全链 (矩阵/gen-names/deploy POS/publish worker-major 派生). 新增 `PRESET=reorg` 拓扑重组专用 (先重生成名→删旧 worker→全量建新). 查证结论: 单 CF 账号 2-3 worker 收益最大 (共享 Anycast 出口池 + 共享 100K 配额), 扩 IP 多样性的杠杆是加账号数非加每账号 worker 数. **真触发验证 (run#23)**: 30 个新 worker 名 + 30 个 deploy 全 success (删旧+双 pass 建新) + publish 派生 30 条 worker-major endpoint.json 传 nonoke/omn-logic (first 1.f01/1.f02/1.f03, last 3.f10). **排障教训**: 私库 Actions 额度耗尽致全部 workflow run 秒败 (steps=0), 圣上改公开后恢复 (DECISIONS §10 记). 后续扩/缩拓扑: 只改 GitHub Variable `ACTIVE_ACCOUNTS`/`WORKERS_PER_ACCOUNT` → 输入框选 reorg 触发一次, **永不用改 workflow 代码**
- ✅ **逻辑层换源 Bucket 已批实施中** (2026-08-25 圣上批 B, docs/logic-switch-bucket-design.md + DECISIONS §11): nonoke 锁 → boot 拉 403 FATAL → 换 xnexus/logic Bucket. **四件武器全绑私库 n-omn 不丢, 唯一成本=丢 Dataset 白送 `--revision` atomic 锁, manifest.json 版本钉补回** (Bucket 根记 n-omn SHA+每文件 sha256, boot 校验哈希不匹配 fail 重试). **代码侧三改动已落 (本会话)**: ① sync-logic CI 新建 sync-logic-xnexus.yml (batch_bucket_files 上传+manifest+readback) ② start.sh §3 改 S3 拉+manifest 校验+另拉 flaretunnel_endpoints.json (破 §1 铁律, 圣上已批) ③ **deploy-ft-workers.yml publish-endpoints 改推 xnexus/logic Bucket (新发现 FT 端点依赖, entrypoint 读 /logic/flaretunnel_endpoints.json)**. **阻塞: xnexus 写凭据 + xnexus/logic Bucket 建 + xnexus/omn 在线确认**. 待办: 圣上建 Bucket (`hf buckets create logic --private`) + 配 xnexus Space Secrets (清单 docs/xnexus-deploy-checklist.md) + GitHub secrets HF_TOKEN_XNEXUS → 首次推 8 件+manifest → 切 xnexus/omn Space
