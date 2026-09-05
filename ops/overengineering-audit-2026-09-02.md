# ops/overengineering-audit-2026-09-02.md · n-omn 现状汇总 + 过度设计查证

> 2026-09-02 归档。性质 = 审计/盘点（非锁定决策，DECISIONS 只增改约束不在此列）。
> 证据 = 生产 boot 日志（2026-09-02 14:30）+ 代码库实读（PROVIDERS 表 / entrypoint.sh / deploy-ft-workers.yml / private-space-proxy-plan.md）。
> 结论分三类：实锤过度设计 / 状态不明 / 确认为合理。

---

## 一、n-omn 当前状态（生产 boot 实证）

### 拓扑（§1 铁律执行态）
- 单 Space 单血统：`xnexus/o` = 唯一生产 Space，已私有化
- 上游只读：基座 3.8.50（`ghcr.io/i3t2y/omn-base@sha256:db9037a7...`）
- R2 持久化：`omn-data` 桶，经 litestream 生效（boot 实证 `本地库非空 → skip restore` + `JWT_SECRET restored`）
- 三层解耦：环境层（GHCR stable）+ 逻辑层（xnexus/logic Bucket）+ 运营层（ops/，永不进 Space）

### 入站链路（私有化闭环）
```
sonoke (base_url=https://omn.360710.xyz/v1)
  → CF Pages 反代 ho-proxy (pages/ho-proxy/_middleware.js)
     · 出站覆盖 Authorization: Bearer <HF_TOKEN>（私有 Space 门票）
     · 透传 X-Gate-PSK: Bearer <INTERNAL_PSK>（gate.js /v1 优先读此头）
  → xnexus-o.hf.space（私有，只认所属账号 token）
```
- cron-job.org 每分钟探反代 `/healthz`，只带 PSK 不带 token
- 生产三坑已闭环：`_middleware.js` 文件名 / `cd` + `deploy .` / `--branch main` 强制 production

### 出站与模型（boot 实证）
- FT 30 workers（10 账号 × 3，round-robin 轮换）；存在理由 = HF egress allowlist 只放 80/443/8080
- 32 keys 注册；`dp4f-pool`（nvidia+sensenova+amd 跨 provider 轮询）+ openrouter/mistral/gemini/sensenova/amd 各池
- PROVIDERS 表内置轨：gemini/openrouter/sensenova/mistral=builtin，amd=custom node

### 待办 / 不确定项
- ~~sonoke 真业务闭环~~：**✅ 已确认 (2026-09-05 实证)** — 660s 窗 38 条 Claude Code Messages 业务请求 (`/v1/v1/messages`, 经反代门票→gate→app→上游): 200×28 (74%, 含 33~35s 完整推理流) + `/count_tokens` 全 200; **503×10 真源 = `chat-admission` 准入 `queue_timeout`**(app 层, reason=queue_timeout + activeHeavy=1 + lane=key_..., 时间戳逐条对齐 gate 503; 该 key lane 已有 1 重型请求在跑, 新重型请求排队超 2.2s 被拒) — **非上游过载、与 dp4f-pool 529 链不同源**, 非链路断. 私有化闭环链路 (sonoke→CF Pages→gate→上游) 已实证. 双 `/v1` 路径为**设计允许** (gate 原样透传 + 上游 `chat.ts:497` 用 `pathname.includes("/messages")` 子串匹配定 claudeFormat; base_url 带 /v1 为 §6 契约, 非配置错)
- `FT_HEALTH_COOLDOWN`：码已落、状态两处文档矛盾（docs 说启用 / HANDOFF 说待定）
- 清单 POST 后建设队列：incident-digest / handoff-sync skills 未构建

---

## 二、过度设计查证结果

### 🔴 实锤过度设计（生产 boot 证据）

**① openrouter/mistral/gemini 三条内置轨全线空转**
```
CredentialHealth: openrouter ❌ Invalid API key
                   mistral    ❌ Invalid API key
                   gemini     ❌ Invalid API key
ProxyEgress:      error ... host not allowed（枚举 502）
```
- 这三家的**完整注册机制（建连接/枚举模型/建 pool/轮询）每 boot 都在跑**，但 key 无效 → 交付零请求
- `init-nim-keys.sh`（1720 行）的 **multi-provider 泛化**（PROVIDERS 表 + 通用注册循环 + FT 单桥泛化绑族）对 3/6 内置轨是**为死 provider 建基础设施**

**② Route A `clear_stale_nim_errors` 已冗余**
```
boot 实证: clear_stale: 无陈旧错态（空转）
```
- 当年设计背景 = ephemeral 存储（无 R2 副本每 boot 空库 → catch-22）。**现在 litestream→R2 持久化已落地，该函数每次 boot 空跑**

**③ deploy-ft-workers.yml（661 行）+ 9 PRESET 场景（已精简 → 7 场景 + 变量兜底）**
- 为 30 worker egress 池；但历史裁决（`ft-worker-count-vs-keys-decoupled.md`）铁证 **8~16 worker 最优，32 浪费**，现 30 已超最优上沿
- PRESET 矩阵（gen/first/daily/publish/solo:N/secrets/delete:1/delete:v/delete:o/reorg）多为一次性建池操作，日常只用 daily + secrets（**2026-09-04 Zen裁折中: 已删 3 一次性 gen/first/publish, 保留 7 场景含防封应急 delete/solo/reorg, gen/first/publish 改经 Variables 兜底**）

**④ FT 桥绑族短名盲区（新增证据 2026-09-02 15:26 boot）**
```
bind:  scopeIds=[nvidia gemini openrouter sensenova mistral amd], updated=6
egress: amd-node 全 Direct / sensenova 全 127.0.0.1:8080
```
- 机制：`resolveProxyForConnection` 取连接 `provider` 名查 registry scope（settings.ts L546）；`normalizeAssignmentScopeId` 对 provider scope **原样透传**（mappers.ts L164）
- 根因：**绑族在 `_register_multi_provider` 之前**（init L494 vs L1340），node 模式 provider 的 UUID 节点还没建/查 → 只能绑字面短名 `amd`，库中无此 provider 名 → 落空直连
- 后果：`updated=6` 中 1 个是**绑给不存在名字的空 assignment**（对 amd 无效冗余绑定）；amd 5 key 共享 HF 容器单出口 IP（多 key 直连同 IP 触风控 = 封号风险）
- Zen令 2026-09-03：**按 A 方向修复——amd 多 key 必须走 FT 桥**（node 注册后补绑 UUID 到 FT proxy，commit b67a91f 已落地+push）
  - 落实：`_register_multi_provider` node 段建/复用节点后补绑 `_nid`(UUID)→`_FT_PROXY_ID`；上游 `assignProxyToScope` #6365 覆盖语义无冲突。boot 判据=日志见 `amd: node <UUID> 补绑 FT 桥 ✓`

### ⚠️ 状态不明（需定夺，非纯过度设计）
**⑤ FT_HEALTH_COOLDOWN**：代码 L251-253 已落、boot 显示 `rotation_mode:round-robin, blacklist_patterns:0`；docs 声称"已落码启用" vs HANDOFF/DECISIONS 说"待Zen定...真启用" —— **两处矛盾，需定一面**

### 🟢 查证后确认为合理（不砍）
- Pages 反代 + 私有化：私有 Space 必带 token 入站，反代唯一持有 token 侧，刚需
- cron-job 探活：走反代 = 探用户真实路径，免费档够用
- litestream→R2：48h 休眠冷启丢盘唯一解
- NIM 32-key pool：真实生产流量承载，非过度
- 日志归档到 Dataset：HF 免费层 30min 日志丢 + 私库 100GB 硬限，双痛点都真 —— 注意：归档指 save/ 抓取推送（保留）；**7天窗 tar.gz 推新私库那层已于 2026-09-04 Zen裁案 A 激进停用**（见下 🚨 处置补充）

### 🚨 真实问题（不是过度设计，是待修 bug）
- **SQLITE_CORRUPT `database disk image is malformed`**：boot **多次复发**（09-02 14:30 + 15:26 两轮均现：`resolveConversationId failed, continuing without conversation tracking` + `[ProxyHealth] Egress summary skipped` + `Cleanup Error: no such table: compression_run_telemetry`）—— **⚠ 2026-09-05 boot 实证更正**：`compression_run_telemetry` 缺表 = **上游幽灵表 bug**（`compressionRunTelemetry.ts:31` 的 `CREATE TABLE IF NOT EXISTS` 仅写入时执行，`cleanup.ts:386` 无条件 `DELETE FROM` 盲删不确保建表；压缩 disabled 时每启必报，try/catch 吞成 errors=1，非损坏、非致命），**应从损坏证据中剔除**；而真损坏信号 `resolveConversationId failed` 与 `Egress summary skipped` **本次已消失** → "持续性损坏"定性大幅弱化，仅存的损坏证据已由 e7b16b3 quick_check + 丢弃强制 restore 消除。**2026-09-04 Zen裁案 A（治标最轻：可见性 + 调低周期）已落码**——`omn_scheduler.py` 加 `_db_health_loop` 探针（周期 GET `/api/db/health`→issues 打日志持久，`OMNIROUTE_API_KEY` 空则 skip）；探针让复发可见，为治本提供观测依据。见交接块下一步
- **dp4f-pool 失败链**：`nvidia/deepseek-v4-flash-0731 超时 → 529 Service temporarily overloaded → Model-only lockout → FALLBACK(另一 nvidia key) → 200` —— 主路上游过载，已能同 provider 内 key fallback 自愈（15:29:51 最终 200，36s），备路可靠性 OK；529 为 nvidia 上游过载而非代码缺陷

---

## 三、下一步建议

| # | 动作 | 优先级 |
|---|---|---|
| 1 | ~~死 provider 轨（openrouter/mistral/gemini）摘除或标记 disabled~~：**Zen裁"标记 disabled 保留代码"** — 加 `DISABLED_PROVIDERS` 数组（两处禁入：ALL_FT_FAMILIES 绑族 + _register_multi_provider 注册段），删名即复活 | **✅ 已实施（mock 全绿, boot 待验）** |
| 2 | ~~amd 补绑 FT 桥（A 方向，Zen令 2026-09-03）~~：node 注册后把真实 UUID 绑进 FT proxy，多 key 走桥轮换出口 IP | **✅ 已完成 b67a91f（boot 待验）** |
| 2b | ~~SQLITE_CORRUPT 排查~~：e7b16b3 quick_check 落地（本地非空也验损，坏则丢弃强制 restore），堵复发；20:56 boot 实证 `quick_check ok` | **✅ 已闭环（DECISIONS §13）** |
| 2c | ~~amd 403 根因~~：**§13 推翻更正 — 真根 = FT Worker 白名单缺 `developer.amd.com.cn`（b67a91f 补绑 FT 桥后推理过桥被 Worker 拒 403 host not allowed），非账户级死 key**。修复 3cb5c39 已 commit，生效须 `deploy-ft-*` tag 重部署 Worker + 重启 Space | **✅ 已修（DECISIONS 2026-09-04 追加更正，boot 待验）** |
| 3 | `FT_HEALTH_COOLDOWN` 状态定一面（启用 or 移除），消文档矛盾 | 中 |
| 4 | ~~deploy-ft-workers.yml 精简 PRESET，保留 daily/secrets~~：**✅ 已实施（2026-09-04, Zen裁折中: 删 gen/first/publish 3 一次性, 保留 7 场景含防封应急, gen/first/publish 经变量兜底）** | ~~低~~ ✅ |
| 5 | sensenova 内置化方案（plan 已备好）执行 | 待Zen令 |
| 6 | ~~备份处置 案 A：归档激进停用（`OMN_LOG_ARCHIVE` 默认 0）~~ | **✅ 已落码（DECISIONS §16①，omn_scheduler.py L54，函数保留可回滚；push 待批）** |
| 7 | ~~SQLITE_CORRUPT 案 A：治标可见性（`/api/db/health` 探针 + 调低周期）~~ | **✅ 已落码（DECISIONS §16②，omn_scheduler.py `_db_health_loop`；Space 须配 `OMNIROUTE_API_KEY` + 可选调低 `OMNIROUTE_DB_HEALTHCHECK_INTERVAL_MS`）** |

---

## 交接块

- **完成**：n-omn 现状汇总 + 过度设计查证（实锤 4 项 / 状态不明 1 项 / 合理保留 5 项 / 真问题 2 项）+ **2026-09-04 双 A 裁定落码**
- **锁定决策 (2026-09-04)**：备份处置 A = 归档激进停用（`OMN_LOG_ARCHIVE` 默认 0，DECISIONS §16①）+ SQLITE_CORRUPT A = 治标可见性探针（DECISIONS §16②）—— 均落码 `omn_scheduler.py`，函数保留可回滚，push 待Zen批
- **文件变更**：本文件新建；补 ④FT scope 短名盲区 + SQLITE_CORRUPT 复发强化 + 建议表 2/2b/6/7 + DECISIONS §16 追加
- **未决**：见「三、下一步建议」表 5/6/7 生效前提项
- **下一步**：~~amd 补绑 FT 桥改码（A 方向已批）~~✅ → ~~SQLITE_CORRUPT 排查~~✅ → ~~死 provider 轨摘除~~✅(disabled 可逆) → ~~FT_HEALTH_COOLDOWN 定一面~~✅(Zen裁启用 env=30, DECISIONS §14) → ~~PRESET 精简~~✅(删 3 一次性, DECISIONS §15) → **~~备份处置 A~~✅ + **~~SQLITE_CORRUPT 案 A~~✅ (均落码, DECISIONS §16; push 待批, 生效须Zen侧配 `OMNIROUTE_API_KEY` + 可选调低 interval)**