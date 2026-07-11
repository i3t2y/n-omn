# Stage B · 冲突清单 (audit/03-conflicts.md)

> 第六独立审查者 · Stage B 产出 · 未改任何生产文件, 未调真实 API, 未生成候选
> 生成日期: 2026-07-11
> 三基准: B1 nomn/main @ `42ea8e7` | B2 working tree @ `9a1a7f0` | B3 omniroute-v3.8.43 @ `b729a8f`
> 关联: audit/02-claim-matrix.md (主张编号 M## 在此引用)

## 0. 范围与排除

- **三硬红线主张 ACCEPT, 不进冲突表** (audit/02 §7): 红线1 Secret 不进 snapshot/日志; 红线2 Gate 暴露面 ≤ /healthz + /v1[/.]; 红线3 本地 SQLite 非空 LiteStream 不覆盖。但**红线执行细节** (如 timing-safe PSK 是否直改 / DEBUG Dataset 默认开关) 若无 Stage B 内部冲突则**不列**: 列为 ACCEPT-WITH-GUARD 已具定向。
- **REJECT 类主张不列冲突** (audit/02 §3): 外部 Relay / 线性扩容 / 直写内部表 / context-relay / latest / 自动写 Secret — 已定。
- 本文件只列**Stage B 内仍有路径分歧、证据矛盾、跨候选立场冲突**的项。

---

## 1. 冲突按优先级排序

### CF-1 [最关键, 待用户裁决] cf-worker 双层网关角色: 保留合规 Gate / 删除单层

- **关联**: M31 (保留), M32 (删除), 联动 M04 (PSK timing-safe), 红线1 "禁任何外部 Relay (Cloudflare)"
- **现状** (L1): cf-worker v1.3.0 在 omn-merge 仓, `.github/workflows/deploy-cf-worker.yml` 在 `push main + 改 cf-worker/**` 时用 `wrangler@4` 部署。白名单 `/`+`/healthz`+`/__health`+`/v1*`, CLIENT_TOKEN 裸比 (L181), INTERNAL_PSK 转发, 429/5xx 分桶统计, Resend+企微告警。
- **冲突点**:
  - 红线 "禁任何外部 Relay (Cloudflare)" 写法与 cf-worker "白名单 Gate" 语义冲突。cf-worker 并非无差别流量转发 Relay, 是同构白名单+PSK+告警的另一层 Gate; 但它属 Cloudflare 外部依赖。
  - `/__health` 路径超出 `/healthz`+`/v1` 清单 (违覆盖修正 #4 的暴露面)。
  - CLIENT_TOKEN 裸 `===` 裸比绝非 timing-safe (M04 共性)。
- **保留 (M31) 利弊**: 利 CF 边缘 DDoS 防护 + 告警外移 + CLIENT_TOKEN 预校验减 HF 负载; 弊 外部 CF 依赖 + 红线歧义 + 须修 timing-safe/去 `/__health`。
- **删除 (M32) 利弊**: 利 消外部依赖 + 红线歧义消除 + 暴露面收至单层; 弊 失 CF 边缘防护与告警外移, HF Space 直面公网。
- **决策**: **不预决**。等用户在 B 阶段后定。这是 Stage D 候选是否含 cf-worker 改动的前提。
- **风险等级**: 高 (影响部署拓扑 + 红线解释)。

### CF-2 B2 已禁自动回写但 B1 已部署仍启用: 候选 v4.3 须显式对齐

- **关联**: M11 (直写内部表 REJECT), M12 (B2 禁用 ACCEPT), 红线1 (SQLite 非空保护无关, 但绕 API 契约)
- **现状** (L1 git): B1 已部署 `42ea8e7` 中 init-nim-keys.sh **自动回写 enabled** (`INSERT INTO model_context_overrides ... ON CONFLICT DO UPDATE`, source='monitor+manual'); B2 feature/slim-monitor `9a1a7f0` 已**注释禁** (4632e8c)。
- **冲突点**: B2 行为对齐背景 #7 "只观测不自动回写", 但**未部署**; B1 仍运行 enabled 版。若 v4.3 候选默认沿用 B2 方向 (禁) 但**未确保部署同步** → 候选与实际运行不一致风险。
- **细化**: 直写 `model_context_overrides` SQLite 内部表本身按 M11/M30 REJECT (约束 c 未经验证直写); 但 B2 已注释禁属"降复杂减写"方向 ACCEPT。矛盾在"禁用方式": B2 保留注释可恢复, 候选是否应**整段删除**而非注释?
- **决策建议**: 候选整段删除自动回写 SQL (非注释), 改走"读 back / API patch / 手动 case 三选一显式", 并确保**部署 commit 推 nomn/main 同步**; 不留可恢复注释 (防误启用)。
- **风险等级**: 中 (候选/运行偏差)。

### CF-3 限流双重风险: Gate (候选固定 28/1/2200ms) vs OmniRoute 服务端 requestQueue 是否已限

- **关联**: M07 (用 ACCEPT-WITH-GUARD 改固定), M07a (G3 NEEDS-SOURCE)
- **冲突点**: 候选改 init-nim-keys.sh 推算式 → 固定 28 RPM/1 并发/2200ms, 但若 OmniRoute 服务端 `requestQueue` (B3 `types.ts` RequestQueueSettings: RequestsPerMinute/MinTimeBetweenMs/ConcurrentRequests) **已对 NIM 直连启用限流**, Gate 再行限流 = 双重掐流, 实际预算低于 28。
- **现状**: 限流执行点未在 B3 源核 (M07a G3)。init-nim-keys.sh L129-140 的 _RPM/_CONCURRENT/_MIN_INTERVAL_MS 写入 OmniRoute 设定 (需核写入点 route), 与 OmniRoute 自身 requestQueue 可能并存。
- **决策**: Stage C **须先解 G3** (读 B3 requestQueue route + 是否对 NIM 启用); 否则候选改 28/1/2200ms 可能与 OmniRoute 叠加误替代。
- **风险等级**: 中 → Stage C 前候选不应落定限流数值。

### CF-4 contextLength 候选字段 vs real_context SQLite 列 vs max_input_tokens API — 三套不一致

- **关联**: M09 (contextLength REJECT), M11 (real_context SQLite REJECT), M10 (max_input_tokens/max_output_tokens ACCEPT)
- **冲突点 (三套各自被拒/受不同约束)**:
  - 候选若主张用 **`contextLength` 写 /api/provider-models**: M09 REJECT (schema 无此字段)。
  - 候选若主张直写 **SQLite `model_context_overrides.real_context`** (B1/B2 现行): M11/M30 REJECT (约束 c 未经验证直写)。
  - 候选走 API **`max_input_tokens`/`max_output_tokens`** (`providerModelMutationSchema`): M10 ACCEPT (仅 schema; 须配读回)。
- **决策**: 候选 v4.3 Context Override 方案唯一可路径 = **API PATCH `max_input_tokens` + 读 back 验证**; 直写内部表与 contextLength 字段两路均禁。
- **风险等级**: 高 (三套混淆致候选错路)。
- **残余需解**: max_input_tokens vs real_context 语义差异 (max_input_tokens=模型宣称上限 token, real_context=修正上下文窗口) — `init-nim-keys.sh` 现用 real_context 是否真意表 max_input?  Stage C 须语义对账。

### CF-5 Resilience schema ACCEPT 与 429 默认 NEEDS-INSTANCE-TEST 的"伪推翻"风险

- **关联**: M01/M01a/M01b (ACCEPT), M01c (NEEDS-INSTANCE-TEST-G1), 背景 #2
- **冲突点**: audit/00 §6.1 称"部分推翻背景 #2", 但"推翻"分两层 — 第一层 schema 真实可配 **ACCEPT (L2)**, 第二层 NIM 429 默认 **NEEDS-INSTANCE-TEST-G1 (L3 未验)**。若 Stage D 候选引用 audit/00 "部分推翻"措辞但未带 G1 待验状态, 可能误用成"NIM 429 默认 breaker 开启"。
- **决策**: 任何候选主张引用 §6.1 必须显带 G1 tag; Stage C 须先脱敏 read-back `/api/resilience` (M01c) 或追 NIM provider 分类。
- **风险等级**: 中 (误用致候选默认误判)。

### CF-6 _VALID_STRATS 枚举含 context-relay/fusion 但 NIM 默认不选 — 消歧方式未定

- **关联**: M21 (ACCEPT-WITH-GUARD), 红线 (context-relay 禁 NIM)
- **现状** (L1): init-nim-keys.sh:102 `_VALID_STRATS` 枚举含 context-relay/fusion; 但 L143 _POOL_STRATEGY=p2c, L148 _CODEX_STRATEGY=round-robin, L150 _FALLBACK=round-robin — 默认不选 context-relay/fusion。
- **冲突点**: 枚举存在歧义; 候选是否从 _VALID_STRATS 删 context-relay/fusion 消歧? 删利无歧义; 删弊失未来 codex 场景的 context-relay 选型可能 (但背景明禁 NIM 用)。
- **决策建议**: 从 `_VALID_STRATS` 删 `context-relay` (NIM 永不用, 红线对应); `fusion` 保留 (codex 池可用, 背景 #3 限定 Codex 账号轮换)。
- **风险等级**: 低。

### CF-7 nim_probe (9a1a7f0 删) vs check_nim_model_health (静态 catalog 探针) 是否重叠

- **关联**: M16 (删 nim_probe ACCEPT), M22 (G6 NEEDS-SOURCE)
- **冲突点**: 9a1a7f0 删 `nim_probe` (运行探针 15s timeout 误报); 但 init-nim-keys.sh 另含 `check_nim_model_health` 静态 catalog 探针 (调真实 NVIDIA /v1/models 一次/init), 仍耗配额。两者是否冗余? 删一个仍用另一个?
- **现状**: M22 G6 未核 check_nim_model_health 默认门控全跑否。
- **决策**: Stage C 读 B2 check_nim_model_health 段; 候选可仅保留 catalog health (低频 + 一次/init) 或门控 (NIM_PROBE=0 时跳)。
- **风险等级**: 中 (配额浪费)。

### CF-8 DEBUG Dataset 默认开 (M08 ACCEPT-WITH-GUARD) 与 B2 禁自动回写方向: 共启时风险链

- **关联**: M08 (DEBUG Dataset), M12 (禁自动回写 B2)
- **冲突点 非 Stage B 内冲突, 但风险链识别**: B2 禁自动回写降写 SQLite, 但 DEBUG log 上传 Dataset 仍开 (M08 红线1 动态)。两降复杂方向不同: 一降 SQLite 写, 一增 Dataset 上传。后者须默认关+脱敏 (M08 候选)。
- **决策**: 候选 v4.3 重组: DEBUG Dataset **默认关**, 须读 back 时显式集; 上传前字段级脱敏 Authorization/NIM_KEY/Cookie/Set-Cookie。**残余动态验证**: M08a (G4 需生产实例观测 DEBUG 日志实际是否含凭据)。
- **风险等级**: 高 (红线1 动态)。

### CF-9 记忆中 export-json expiresAt 漂移修复 (M38 G10) 须本仓 git 重验

- **关联**: M38 (G10 NEEDS-SOURCE)
- **冲突点**: 记忆/历史档案称 main `f9c743c` 修 export-json expiresAt 字段漂移。但 omn-merge HEAD nomn = `42ea8e7`; 须核 f9c743c 是否在 omn-merge 历史。若不在, 记忆属 L4 不可信。
- **决策**: Stage C 在 omn-merge `git log --oneline | grep expiresAt` 重验; 不直信记忆 L4。
- **风险等级**: 低 (历史记忆, 单点)。

### CF-10 nvidia 前缀三输入路由判定 (背景#4) 未到 L2, 候选如早定有误区

- **关联**: M18 (G5 NEEDS-SOURCE)
- **冲突点**: init-nim-keys.sh L99 `sed 's/^/nvidia\//'` 静态层统一加前缀; 但 OmniRoute 路由层 `nvidia/nvidia_nim` 别名 (B3 `auth.ts:1095` Fix #922) 对 `meta/*`/`nvidia/*`/`nvidia/nvidia/*` 三输入未逐符号验 (M18 G5)。
- **现状**: 候选如直接写"nvidia/*/* 三段自动归一" 须 G5 先验。
- **决策**: Stage C 读 B3 `resolveProviderId` + 写不联网单测验三输入, 后候选定向。
- **风险等级**: 中 (双前缀路由错配)。

---

## 2. B1 → B2 两 commit 差异冲突汇总 (用户约束 #8, 单列)

| commit | 哈希 | 改动 (矩阵#) | 冲突/风险 | 处理 |
|--------|------|------------|----------|------|
| 4632e8c | 禁 context-monitor 自动回写 + 删 nim_health_pick | M12 (禁回写), M13 (删健康打分) | 见 CF-2 (B1 已部署仍 enabled, B2 未部署); 禁用方式: 注释 vs 整段删 | 候选整段删自动回写 SQL + 确保部署同步 |
| 9a1a7f0 | 第二轮精简 4 块 | M14 (Memory), M15 (Thinking), M16 (nim_probe), M17 (check_dangerous_env) | 见 CF-7 (nim_probe 与 catalog 探针重叠需解); 其余三块 ACCEPT 无冲突 | ACCEPT (B2 现行); nim_probe 相关待 G6 |

两 commit 均**未推 nomn/main** → B1 部署未含; 候选 v4.3 须以 B2 方向为准并经显式部署同步动作 (用户授权后)。

---

## 3. 冲突优先级总览

| 冲突 | 优先级 | 阻断 Stage D? |
|------|--------|--------------|
| CF-1 cf-worker 去留 | 最关键 | **是** (待用户定) |
| CF-4 contextLength/real_context/max_input 三套 | 高 | 是 (须 Stage C 先解语义) |
| CF-3 限流双重 | 中 | 部分 (须 G3 先解) |
| CF-2 B1/B2 自动回写偏差 | 中 | 否 (定向: 整段删 + 部署同步) |
| CF-5 #2 伪推翻误用 | 中 | 否 (候选引用须带 G1 tag) |
| CF-8 DEBUG Dataset 红线1 动态 | 高 | 否 (定向: 默认关+脱敏; G4 动态验) |
| CF-7 nim_probe 重叠 | 中 | 否 (待 G6) |
| CF-10 nvidia 前缀 | 中 | 否 (待 G5) |
| CF-6 _VALID_STRATS 消歧 | 低 | 否 |
| CF-9 expiresAt 记忆重验 | 低 | 否 (待 G10) |

---

## 4. 待 Stage C 解决 (NEEDS-* 移表)

与 audit/02 §6 一致, 冲突表相关:
- G1 (CF-5): NIM direct-cloud 429 默认 — 需实例 read-back `/api/resilience`
- G3 (CF-3): OmniRoute requestQueue 限流执行点
- G4 (CF-8): DEBUG 日志务含凭据动态
- G5 (CF-10): resolveProviderId + nvidia_nim 别名
- G6 (CF-7): check_nim_model_health 默认门控
- G10 (CF-9): export-json expiresAt 本仓 git 重验

---

## 5. Stage B 守纪声明

未改任何生产文件 (mtime 未验在本文件但 audit/02 §9 验过; 本轮仅新增 audit/03); 未调真实 NVIDIA API; 未生成候选; 未 push; 未触发工作流。仅写本文件 (audit/03-conflicts.md)。

