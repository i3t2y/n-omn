# Stage E · audit/07-instance-readback-plan.md (实例只读 read-back 验证计划)

> 目标: 候选 `candidate-v4.3-reviewed` 已部署后, **只读** read-back 把 audit/06 KNOWN-UNVERIFIED 的 G1 / K2–K5 从 NEEDS-INSTANCE-TEST 降级为 L1 结论; 后台白名单真实可达确认. 全过 → 入主分支合入决策.
> 生成日期: 2026-07-11
> 关联: audit/06-candidate-review.md (候选 review), KNOWN-UNVERIFIED G1/K2/K3/K4/K5.
> 试验性质: **本轮只读, 零写**. 不修 provider/resilience/model/combo/key, 不写 SQLite, 不 restart/shutdown, 不耗 NIM 配额.

## 0. 执行前提核 (任一不满足 → BLOCKED-DEPLOY, 停)

核日期: 2026-07-11 (本轮执行实情)

| # | 前提 | 满足? | 证据 |
|---|------|------|------|
| P1 | 候选 `candidate-v4.3-reviewed` 已部署到目标环境 (影子 Space / 灰度实例), 未覆盖 B1 `42ea8e7` 生产 | **❌** | 候选未构建/未部署任何实例; 无 HF Space 凭据 (env 无 `HF_*`/`SPACE_*`); 本机 7860/20128 端口无响应 (curl 000); 无 base URL (grep 候选无 hf.space 提及). 无 docker build target dir. |
| P2 | 记录本例 base URL, OmniRoute 内部端口, 镜像 Tag+Digest (= 已核验 v3.8.43 digest, 非 latest) | **❌** | base URL: **无**; OmniRoute port: **无**; image: 本机 docker 仅有 `diegosouzapw/omniroute:3.8.46@sha256:3e254...` — **≠** 候选 Dockerfile 锁的 `3.8.43@sha256:517c...`. 本机无 3.8.43 image. |
| P3 | `INTERNAL_PSK` 与 `GATE_ADMIN_TOKEN` 已配置 (HF Space Secret); 值**不入文档** | **❌** | env 无 `INTERNAL_PSK`/`GATE_ADMIN_TOKEN`/`OMNIROUTE_API_KEY`/`NIM_KEYS`/`R2_*` 任一. |
| P4 | 本例只读凭据可用 (OmniRoute 登录会话 Cookie/Session) | **❌** | 无 OmniRoute 登录凭据. |

**任一 ❌ → BLOCKED-DEPLOY 停执行**. 本轮 P1-P4 全 ❌ → **不执行 R 矩阵** (下方 §2 R 矩阵留空, NEEDS-INSTANCE-TEST 维持).

### 0.1 BLOCKED-DEPLOY 处置 (已按硬约束执行)

- ✅ 清理本轮前面 dbg 测试遗留 6 个孤儿 `candidate-v4.3-reviewed/gate.js` 进程 (pkill -9, 已全清 verify).
- ✅ 未构建候选 docker image (不构 push) — P2 image 不符前提, 不启 build.
- ✅ 未发 GET /v1 推理 (不耗 NIM 配额).
- ✅ 未修配置, 未写 SQLite, 未 restart/shutdown (本属 0 次).
- ✅ 未触候选或主仓 (B1 `42ea8e7` 不动).
- ✅ 不猜测不伪造 R 矩阵结果 (R1-R5 全留空 ___).

### 0.2 注意: 本机 docker `diegosouzapw/omniroute:3.8.46` ≠ 候选锁的 3.8.43

本机偶存 `3.8.46@sha256:3e254...` 镜像 (3 days ago 构建痕迹, 属历史). 候选 Dockerfile 锁 **3.8.43** (audit/05+audit/06 已 fixed; 3.8.46 被 audit/05 C1.10 列"镜像落漂"风险). **此偶存 3.8.46 不应被本轮误用** — 即便将来候选 build 跑, 须 `docker pull diegosouzapw/omniroute:3.8.43@sha256:517c...` 重新核 digest, 不可 `:latest` 或 `:3.8.46`.

## 1. 只读硬约束 (整轮通用, 违一即停)

## 1. 只读硬约束 (整轮通用, 违一即停)

- 仅 GET + 只读探活; 禁 PATCH/POST/PUT/DELETE.
- 不改 provider / resilience / model / combo / key 配置.
- 不写 SQLite; 不触 restart / shutdown / 高频探针.
- 每请求间隔 ≥ 3 秒; 不循环/批量/压测.
- 响应含 key/token/secret/credential/cookie 字段 → 脱敏, 只记字段是否存在 + 非敏感取值, 绝不落明文.
- 任一 401/403 → 立停该项, 标"无权限", 不重试.
- 任一 429 → 立停该项, 标 NEEDS-INSTANCE-TEST 维持, 不重试/不改配置绕过.
- 不耗 NIM 配额: 本轮**不发真实 /v1 推理** (G1 只读配置快照, 不靠 429 触发).

---

## 2. R 矩阵 (执行项, 逐项填表)

> `{base}` = 候选 gate 公网入口 (HF Space URL). 每 R 子项完成后填: status / method / path / headers(脱敏) / 期望 / 实际 HTTP / 实际 脱敏 body 头字段掩 / 结论.
> 间隔 ≥ 3s. 401/403 立停标无权限. 429 立停 NEEDS-INSTANCE.

### R1: Gate 暴露面与 PSK (红线 2 实例确认)

| # | 请求 | 期望 | 实际 | 结论 | 备注 |
|---|------|------|------|------|------|
| R1.1 | GET {base}/healthz, 无 PSK | 200 探活体 `{ok:true}` 或 503 (上游探活未 ready 时; 上游起 ready 后 200) | ___ | ___ | /healthz 免认证 fetch 上游 /api/monitoring/health |
| R1.2 | GET {base}/ (后台关或开? 见 P2) | 404 (后台关) 或 200 (后台开 + Basic 对) | ___ | ___ | 后台关: 全非白名单 404; 后台开 + 无 Basic 401; 后台开 + Basic 正确 200 |
| R1.3 | GET {base}/api/providers, **无 Basic**, OmniRoute Cookie 无 | 404 (后台关) OR 401 (后台开) | ___ | ___ | 红线2: OmniRoute Cookie 不绕过 |
| R1.4 | GET {base}/v1/models, 无 PSK | 401 | ___ | ___ | PSK 必须 |
| R1.5 | GET {base}/v1/models, PSK 正确 (Bearer) | 200 (上游 OmniRoute /v1/models 透传) | ___ | ___ | 验 /v1 path 完整到上游 (candidate bug 修) + query 原样 |
| R1.5b | GET {base}/v1/models?limit=5, PSK 正确 | 200, 上游收 `/v1/models?limit=5` | ___ | ___ | query 原样保留 (不丢) |
| R1.6 | GET {base}/v1//models, PSK 正确 | 200 (规整为 /v1/models) | ___ | ___ | normalizePath 防绕过 + 非 404 |
| R1.7 | GET {base}/api/providers POST (无 Basic 或 Basic 对) | 405 (Basic 对) OR 404/401 (Basic 缺) | ___ | ___ | 方法白名单: 后台 POST 默认 405 (写非白名单) |
| R1.8 | GET {base}/_next/static/x.js (后台开时) | 200 (静态免 Basic) OR 404 (后台关) | ___ | ___ | 静态免 admin token (开关开时); 后台关 → 静态 404 |
| R1.9 | GET {base}/any-random-path-404, PSK 错 | 401 (前缀 /v1? 验) OR 404 (非 /v1) | ___ | ___ | 非 /v1 + 非 /healthz → 404 (后台关) / 401 (后台开无 Basic) |

### R2: PSK 边界 timing-safe 实例确认 (红线1)

| # | 请求 | 期望 | 实际 | 结论 |
|---|------|------|------|------|
| R2.1 | GET /v1/models, PSK 空 `Bearer ` | 401 | ___ | ___ |
| R2.2 | GET /v1/models, PSK 格式错 (`Basic x`) | 401 | ___ | ___ |
| R2.3 | GET /v1/models, PSK 错误值 | 401 (timing-safe 不与正确值同响应时间显) | ___ | ___ |
| R2.4 | GET /v1/models, PSK 长度不同 | 401 (timing-safe 长度不等不退字符串比较) | ___ | ___ |
| R2.5 | GET /v1/models, GATE_ADMIN_TOKEN (Basic) 作 PSK | 401 | ___ | ___ | 权限隔离: admin token 不能 /v1 |

### R3: 后台白名单真实可达 (K3 核) + 高风险 404 矩阵

> 前提 P4 OmniRoute 登录凭据: 有 → 验登录后页可达; 无 → 仅验 Basic Auth 关 + 白名单 404 矩阵 (列 NEEDS-UNVERIFIED 仍).

**后台关场景** (P2 GATE_ADMIN_TOKEN 未设, 不应在本轮 — 但若 P2 临时未设):

| # | 请求 | 期望 | 实际 | 结论 |
|---|------|------|------|------|
| R3.1 | GET /, OmniRoute Cookie, 后台关 | 404 (Cookie 不绕) | ___ | ___ |

**后台开场景** (P2 GATE_ADMIN_TOKEN 设):

| # | 请求 | 期望 | 实际 | 结论 |
|---|------|------|------|------|
| R3.2 | GET /login, 无 Basic | 401 + WWW-Authenticate: Basic | ___ | ___ |
| R3.3 | GET /login, Basic admin 正确 | 200 (OmniRoute 登录页透传) | ___ | ___ |
| R3.4 | GET /login, Basic admin 错误 token | 401 | ___ | ___ |
| R3.5 | GET /login, OmniRoute Cookie + Basic admin 正确 | OmniRoute 登录会话 → 首页 302/200 | ___ | ___ | (P4 有) |
| R3.6 | GET /api/providers, Basic 正确 | 200 + 配置 list (敏感脱敏) | ___ | ___ | (P4 有) 验真实可达白名单 |
| R3.7 | GET /api/combos, Basic 正确 | 200 + combos list | ___ | ___ | (P4 有) |
| R3.8 | GET /api/resilience, Basic 正确 | 200 + resilience 配置 | ___ | ___ | (P4 有) R5 复用 |
| R3.9 | GET /api/provider-models, Basic 正确 | 200 + provider models list | ___ | ___ | (P4 有) R5 复用 |
| R3.10 | GET /api/keys, Basic 正确 | 200 OR 401 (OmniRoute 权限) | ___ | ___ | (P4 有) keys 敏感, 验可达不录值 |

**高风险白名单 404 矩阵** (红线2: 这些不该开):

| # | 请求 (Basic 正确) | 期望 | 实际 | 结论 |
|---|------|------|------|------|
| R3.H1 | POST /api/restart | 404 (未开) | ___ | ___ |
| R3.H2 | POST /api/shutdown | 404 | ___ | ___ |
| R3.H3 | POST /api/init | 404 | ___ | ___ |
| R3.H4 | POST /api/webhooks/x | 404 | ___ | ___ |
| R3.H5 | PATCH /api/providers/x | 405 (方法非白) OR 404 | ___ | ___ | 写非默认 |
| R3.H6 | DELETE /api/keys/x | 405 OR 404 | ___ | ___ | 写非默认 |
| R3.H7 | GET /api/db-backups | 404 (写能力不白单) | ___ | ___ | db-backups 风险 |
| R3.H8 | GET /api/plugins | 404 | ___ | ___ | 插件风险 |

### R4: LiteStream 治理 read-back (LITESTREAM_STRICT + auto-recover 本轮不能直验)

> LiteStream 复制/restore 行为不属只读 API; 本轮**不**实跑 restore (会写 SQLite, 违约束). 仅 read 间接证据:

| # | 项 | 期望 | 实际 | 结论 |
|---|------|------|------|------|
| R4.1 | 部署日志 (entrypoint stderr) 含 `[entrypoint]` LiteStream 复制状态行 (LITESTREAM_STRICT=1 / R2 配置 found / 复制 enabled) | 日志记录 strict + R2 creds found + 复制启 OR 跳过理由 | ___ | ___ | (HF Space logs read) |
| R4.2 | 部署日志含 `auto-recover=false` 生效证据? (litestream.yml 实际加载值) | 启动 log 含 litestream 配置加载, auto-recover=false | ___ | ___ | (log) |
| R4.3 | 关键: 本轮**不发 restore** (会触发 LiteStream restore 写 SQLite, 违约束); restore 分支 (audit/05 C1.7 修) 仅靠 candidate tests/ TEST 7 + entrypoint.sh code grep 已验 | 维持 TEST 7 PASS 证据 + code guard 足 | ___ | ___ | 不实跑; 写此行明示不绕约束 |

### R5: K2–K5 schema read-back (只读, 不修配置)

> 目标: GET 真实 OmniRoute API schema 验证 candidate 基于 B3 源码推断的 camel 字段名 + 结构是否对真实实例 (v3.8.43). 不读不敏感整 body, 只录字段是否存在 + 非敏感 sample value. 敏感字段仅存 booleanness (key field 是否 present). **401/403 → "无权限" 立停, NEEDS-INSTANCE 维持.**

| # | GET | 期望关键字段 (B3 源码推断) | 实际 | 结论 |
|---|------|------|------|------|
| R5.K2.1 | /api/resilience (Basic 对) | 顶层有 `useUpstream429BreakerHints` 字段 (G1) | ___ | ___ |
| R5.K2.2 | /api/resilience | `requestQueue` 子结构含 `fixedWindowMs`/`intervalMs` (限流字段) 或 B3 源码 schema 名 | ___ | ___ | 限流固定值 28/1/2200ms 写处 (OmniRoute 服务端) schema 验 |
| R5.G1 | /api/providers (Basic 对) | NIM provider `type` 字段值是 `direct-cloud` (G1 实例证) OR `nim` OR 其它 (B3 providerHints.ts:56 default-cloud 兜底 true) | ___ | ___ | 实例 NIM provider type 实际写值未证 → 此 read-back 直接证 |
| R5.K2.3 | /api/providers | NIM provider 字段结构含 `providerApiKey`/`providerModels` (B3 路径 schema) | ___ | ___ |
| R5.K2.4 | /api/provider-models (Basic 对) | 顶层含 `max_input_tokens` / `max_output_tokens` 字段 (无 `contextLength`) | ___ | ___ | K5 L2 实证: API PATCH 仅 isHidden; POST add 接受 max_tokens. K5 FIX 后候选不依赖此字段写, 但 read-back 仍验字段存在以定 future 启用 |
| R5.K5 | ~~API PATCH 读回~~ → **K5 FIX 后改 SQLite read-back**: init 直写 `model_context_overrides` 表查 `SELECT provider, model_id, real_context, source, refreshed_at FROM model_context_overrides WHERE source='init'` | 期望: NIM 模型行 source='init' + real_context=32768 全覆盖 | ___ | ___ | K5 FIX: 候选恢复 init per-model 32K override source='init'; 不再验 API PATCH 路径 (3.8.43 不支持). SQLite read-back 验 init override 已正确落表 |
| R5.K2.5 | /api/monitoring/health (免 Basic? 或 Basic 对) | 顶层含 `status`/`ok` 字段 (gate /healthz fetch 上游此路径) | ___ | ___ | 验 gate /healthz 上游 path 真存在 |
| R5.K3 | (后台白名单路径已 R3 验) | 整白名单页 (login/dashboard/api-provider 等) 真实可达 | R3 并 行 | ___ | 整合 R3 |
| R5.K4 | (HF 代理拓扑) | 本轮**不**实例验 (需 HF 平台层级探针, 不属 OmniRoute API read-back); 仅 LOG: `X-Forwarded-For` 实测是否包含可信代理链 (但本轮不读 IP 头作管理员, 候选不实现 IP) | 不实跑 (范围外) | ___ | K4 仍 NEEDS-PLATFORM 或 加 release decision |

## 3. 结论汇总表 (执行后填)

**本轮 BLOCKED-DEPLOY → 未执行 R 矩阵 → G1 与 K2–K5 维持 NEEDS-INSTANCE-TEST, 不降级 L1, 不进合入决策.**

| 项 | 结果 | L1 结论降级? | 备注 |
|---|------|------|------|
| R1 Gate 暴露面/PSK | **未跑** (BLOCKED) | 否 | 维持 candidate tests/ TEST 2+4+5+6 (mock 上游) PASS 证据 + code grep; 不实例 L1 |
| R2 PSK 边界 | **未跑** (BLOCKED) | 否 | 维持 TEST 3 PASS; 不实例 L1 |
| R3 后台白名单 | **未跑** (BLOCKED) | 否 | K3 维持 NEEDS-UNVERIFIED; TEST 3b + TEST 10 cff 已 mock 验高风险 404; 不实例 L1 |
| R4 LiteStream 治理 | **未跑** (BLOCKED) | 否 | 维持 TEST 7 + entrypoint.sh code guard L1 证据 (不实跑 restore 本属 0 写约束) |
| R5 K2-K5 read-back | **未跑** (BLOCKED) | 否 | K2/K5 维持 NEEDS-UNVERIFIED (B3 源码推断); G1 维持保守 false (default-cloud 兜底); K4 范围外 |
| G1 useUpstream429BreakerHints | **未跑** (BLOCKED) | 否 | G1 保守 false 维持; 须实例 + NIM direct-cloud + 真实 429 触发后才能 L1 — 但本轮"不耗 NIM 配额"约束 (不真推理), G1 L1 本就无法在本轮降级, 仅靠 R5.G1 NIM provider type 实例证 + K2.1 字段存在证间接 |
| K2-K5 | **全未跑** (BLOCKED) | 否 | 维持 KNOWN-UNVERIFIED 状态原状 (audit/06 §7) |



## 4. 进主分支合入决策判据

**过 (入合入决策)**:
1. R1 全子项实测期望 (200/401/404 矩阵); 不出现非期响应.
2. R2 全子项 PSK 边界 401 (timing-safe 实例不泄时差).
3. R3 高风险 H1-H8 全 404/405 (写能力默认不开 L1 确认).
4. R3 页面 R3.5-R3.10 (P4 有则可达; P4 无则该项 NEEDS-UNVERIFIED 但不阻合入 — 高风险全关已证).
5. R5 K2 schema 字段名与 B3 推断一致 (camel/无明显漂移).
6. G1 NIM provider type 真实写值已读回 (direct-cloud/nim/其它).
7. K5 max_tokens 字段读回存在 (启用路径 L1 触发点).

**不过 (维持 NEEDS-INSTANCE-TEST, 不入合入)**:
- 任一 R1-R3 实测非期 (含 High-risk 意外 200) → 阻.
- R5 K2 schema 与 B3 推断**显著漂移** (字段缺失或结构不符) → 告警 + 不合入 (candidate 的 read-back mock 验已无真实 schema 依据).
- G1 NIM provider type 实例未证 → G1 维持保守 false (但**不阻合入**, false 已保守默认).
- 任一前提 P1-P4 不满足 → BLOCKED-DEPLOY 根.

## 5. 执行结果 — BLOCKED-DEPLOY (本轮实际)

**状态**: **BLOCKED-DEPLOY**. P1-P4 全 ❌ → 未执行 R 矩阵.

**处置已执行** (本节为已执行事实记录):
- R 矩阵 (§2 R1-R5) 全留空 `___`, 不猜测不伪造.
- audit/06 §7 KNOWN-UNVERIFIED (G1/K2/K3/K4/K5) 字段**维持原状**, 不降级.
- candidate-v4.3-reviewed/ **不动** (无 build/push/重启).
- B1 `42ea8e7` 主仓 git 不动.
- 清理本轮前面 candidate tests 调试遗留 6 个孤儿 `gate.js` 进程 (已全清楚 verify).
- 本机 docker 偶存 `diegosouzapw/omniroute:3.8.46` 不被本轮误用 (候选锁 3.8.43, 已 §0.2 明示).

**未降级清单** (G1 与 K2-K5 维持 NEEDS-INSTANCE-TEST, 不 L1):
- G1 (useUpstream429BreakerHints): 保守 default false 维持
- K2 (B3 schema 推断未实例验, 但 mock read-back 在 candidate tests/ TEST 5 PASS)
- K3 (后台白名单真实可达未实例验, 但高风险 404 矩阵在 candidate tests/ TEST 3b + TEST 10 已 mock PASS)
- K4 (HF 代理拓扑, 范围外, 不实跑)
- K5 (自动 Context Override API PATCH 路径, 仅字段读回未验)

**结论**: **本轮不进主分支合入决策**. 候选的 candidate tests/ (65 PASS / 0 FAIL / 2 SKIP) + audit/06 已守所有 NEEDS-UNVERIFIED 保守默认, fail-safe — 候选自身保留可作合入决策的备选, 但合入前须用户在真实部署环境重跑本 audit/07 R 矩阵并全过.

## 6. 重启本轮的解锁前提 (供用户下一轮)

用户若解锁本 audit/07 R 矩阵执行, 需提供:
1. **base URL** (候选 gate 公网入口, HF Space URL 或灰度实例域名).
2 **镜像 Tag+Digest** 证 (= v3.8.43 已核 digest `sha256:517c...` 非 latest 非 3.8.46); 若实际部署用不同 tag → 须先停 +重核 digest.
3. 已设 `INTERNAL_PSK` (≥16 字符) 与 `GATE_ADMIN_TOKEN` (≥16 字符) 在该实例 HF Space Secret; 值不入对话/文档.
4. (可选, FOR R3.5-R3.10 真实登录后页可达) OmniRoute 登录会话凭据 (用户名/密码 or Cookie string); 无则 R3 仅验 Basic Auth 关 + 高风险 404 矩阵.
5. 确认该实例**不覆盖** B1 `42ea8e7` 生产 (影子/灰度).
6. (核 echo) 用户在本会话执行 `! curl -s -o /dev/null -w "%{http_code}" {base}/healthz` 把结果粘回, 证 base URL 可达 (避免我猜).

满足后, 重启 audit/07 §1-§4, 每 R 子项 3s 间隔, 401/403 立标无权限, 429 立停 NEEDS, 脱敏落文档. 全过 → G1/K2-K5 降 L1 + 入主分支合入决策.
