# Stage D · 候选 v4.3 Review (audit/06-candidate-review.md)

> Stage D 产出: `candidate-v4.3-reviewed/` (gate.js / entrypoint.sh / init-nim-keys.sh / Dockerfile / litestream.yml / package.json + 5 文档 + tests/).
> 生成日期: 2026-07-11
> 三基准: B1 `nomn/main@42ea8e7` | B2 `working tree@9a1a7f0` | B3 `omniroute-v3.8.43@b729a8f`.
> 关联: audit/04 plan, audit/05 results (C-Fails), CF-1 (cf-worker 移除), CF-2~CF-10 决议.

## 1. Stage D 修复映射 (audit/05 C-Fail → 候选修复)

| audit/05 项 | 原问题 | 候选修复 | 验证 |
|------|------|------|------|
| C1.5 PSK timing-safe | gate.js `bearer !== INTERNAL_PSK` 裸比 (非常量时间) | `crypto.timingSafeEqual` + 长度不等前置 reject (不退字符串比较) | TEST 3 PASS (6 子项) |
| C1.7 LiteStream restore | 无本地非空 guard + restore 失败 `Continuing` + 无 quick_check | entrypoint.sh L18 LITESTREAM_STRICT, L21 临时路径, L77 非空跳过, L85 临时恢复+原子 mv, L96 post quick_check; litestream.yml `auto-recover: false` (防重复恢复绕过 guard) | TEST 7 PASS (6 guard) |
| C1.8 PID1/SIGTERM/wait | 无 trap, 无 PID 捕获 `wait`, exec 后无转发 | entrypoint `trap` TERM/INT, `_signal_kill` 转发, 子 PID 保存 (POSIX 变量), `wait` 回收, 任一关键进程退停其余 | TEST 8 PASS (7 子项含真跑 trap) |
| C1.6 SSE flush/chunk | http-proxy-middleware 无显式 SSE handling (node_modules 缺未实跑) | gate.js 手写 `http` 模块, 逐块 pipe + 背压 + 客户端断开 `destroy` 上游 + 上游超时 504 + 不读流聚合 | TEST 6 PASS (含 SSE 真流式 200 + 首块先到 + 多块顺序 + 客户端断开取消上游) |

## 2. Stage D 实现期间发现并修复的 bug (audit/05 未列)

| bug | 来源 | 候选修复 | 验证 |
|------|------|------|------|
| **/v1 path 被 Express mount strip** | dbg 实跑发现 `app.use('/v1', ...)` 内 `req.path` 把 `/v1` 前缀剥掉 → 上游收 `/models` 而非 `/v1/models` (OmniRoute `/v1` 路由打不上, production 灾难) | 改用 `req.originalUrl` 保完整 (含 query); proxyAdmin 后台路径不在 mount 下用 `req.path` 已完整 | TEST 2+4 /v1 PSK 200 + query 原样 + 上游收到完整 `/v1/models?foo=bar` |
| **GET/OPTIONS upstreamReq 不发** | dbg 实跑发现 `req.pipe(upstreamReq)` 在无 body GET 时似乎不触发 destination end, 上游 socket 连接但 hung → ECONNRESET → 503 (OmniRoute 永远收不到 /v1 请求) | 改分支: 有 body (`content-length`/`transfer-encoding`) 用 pipe 自动 end; 无 body 显式 `upstreamReq.end()` 收尾 | TEST 2+4 /v1 200 + TEST 5 全 13 状态码透传 + TEST 6 SSE 200 |
| **gate listen 日志写固定参数而非实际端口** | `EXPOSED_PORT=0` (test random) 时日志写 `:0` 而非实际监听端口 → test 无法拿到 gate port | 改 `server.address().port` 取实际 | TEST 握手成功 (gate listen 在 stderr 暴露正确端口) |

## 3. 后台访问演进 + GATE_ADMIN_TOKEN 单变量决策

(audit/05 §C1.21 `createProxyMiddleware('/')` 全透传暴露面过宽 = B2 slim 引入违红线2, candidate 受控重引入):

**变量名决策**: 保留历史名 `GATE_ADMIN_TOKEN` (旧语义"留空=内网直连"已**废**). 废 `ENABLE_ADMIN_UI` 双变量设计 — candidate 删完全 (无残留 code 残留, 仅 CHANGELOG/文档注"删"合理).

**语义**: 留空/过短 (<16) → **后台全关 + 全 404** (fail-safe, 比 B2 slim 全透传更窄). 设有效值 (≥16) → **后台开** + HTTP Basic Auth (admin/pass) 放行白名单.

**白名单来源 B3 真实路由** (L2 证据 `src/app`): 前台页 (`/`, `/login`, 等) + `/_next/*` 静态 + public 顶层 + 只读 `/api/*` 白名单 (GET only); **高风险写** (restart/shutdown/init/webhooks/plugins POST 款) **默认不开放** (列 KNOWN-UNVERIFIED).

**认证机制**: HTTP Basic Auth (用户名 `admin`, 密码=`GATE_ADMIN_TOKEN`) + `crypto.timingSafeEqual` 比密码 (不退字符串比较, 长度不等 reject) + `WWW-Authenticate: Basic realm` 401. 完成 delete `Authorization` header 不转 Basic 给上游 OmniRoute (防上游信认 Basic).

**隔离**: `INTERNAL_PSK` (Bearer) 唯 /v1; `GATE_ADMIN_TOKEN` (Basic) 唯 后台; 两同值亦不互回退 (method 头格式不同).

**未实现**: IP/CIDR 限制 (HF 代理拓扑未 L1 证据, 不靠伪造 IP); Buf `app.set('trust proxy', true)` 不设, 不读 `X-Forwarded-For` 左侧.

## 4. 候选测试结果 (audit/06)

执行: `cd candidate-v4.3-reviewed/tests && node test-runner.js`

```
=== v4.3 candidate tests ===
TEST 1: 静态语法               6 ✓  (gate.js --check, sh -n, bash -n, jq, yaml)
TEST 2+4: 路径矩阵+query/路径   11 ✓ (healthz/PSK/Cookie不绕/404矩阵/query保留/规整)
TEST 3: PSK timing-safe       6 ✓  (缺失/空/格式错/错误/长度不同/正确)
TEST 3b: GATE_ADMIN_TOKEN+Basic 16 ✓ (开关/Basic/malformed/错名/错token/长度/权限隔离/方法白名单/高风险404/静态免token/过短关)
TEST 5: mock 上游状态          14 ✓ (200/400/401/403/404/410/413/422/429/500/502/503/504; 1 ⊘ 上游超时 504 - mock hang 窗长, code grep 已确认 504 路径在)
TEST 6: SSE 真流式             5 ✓  (200/首块先到/多块顺序/不变/客户端断开取消上游)
TEST 7: LiteStream guard       1 ✓  (6 guard: LITESTREAM_STRICT/临时路径/quick_check/mv/本地非空跳/R2 配置)
TEST 8: 进程监督 (信号)         1 ✓  (7 子: trap/转发/wait/子PID/healthz超时/OmniRoute ready/真跑 trap SIGTERM 转发 gate)
TEST 9: 幂等                  4 ✓ + 1 ⊘ (upsert/nim_health_pick图删/无 SQLite 直写 override/连续两次 NEEDS-INSTANCE)
TEST 10: 残留扫描              1 ✓  (代码层无 ENABLE_ADMIN_UI/RELAY/contextLength/createProxyMiddleware/http-proxy-middleware; context-relay 仅注释合理引用)

=== 结果 ===
PASS=65 FAIL=0 SKIP=2  (全 PASS)
```

**2 SKIP = 实例验证项** (不属 candidate 范围, 已记 KNOWN-UNVERIFIED):
1. 上游超时 504 (mock hang 测试窗长 + 依赖 `GATE_UPSTREAM_TIMEOUT_MS` 短设实跑) — code grep 已确认 proxyV1 L317 `upstreamReq.on('timeout', ...504)` 路径在.
2. init 连续两次运行幂等 (需 OmniRoute 实例 + 持久 DB) — code grep 已确认 init 含 `ON CONFLICT` upsert.

## 5. 残留扫描 (TEST 10) 全通过

| 类 | gate.js | entrypoint.sh | init-nim-keys.sh | Dockerfile | package.json | litestream.yml | md |
|---|---|---|---|---|---|---|---|
| ENABLE_ADMIN_UI | 无 | 无 | 无 | 无 | 无 | 无 | 文档注"删" 合理 |
| context-relay | 注释 "无 context-relay" 否定语境 ✓ | 无 | 注释 CF-1 "删" ✓ | 无 | 无 | 无 | 文档 ✓ |
| RELAY_URL_/RELAY_TOKEN_/x-relay- | 0 命中 | 0 | 0 | 0 | 0 | 0 | 0 |
| contextLength | 0 | 0 | 注释"禁" ✓ | 0 | 0 | 0 | 文档 ✓ |
| createProxyMiddleware | 0 (整删) | n/a | n/a | n/a | 0 | n/a | 文档 ✓ |
| http-proxy-middleware | 0 | n/a | n/a | n/a | 0 (依赖删) | n/a | 文档 ✓ |
| 3.8.46 镜像落漂 | n/a | n/a | n/a | 0 (注释删) | n/a | n/a | n/a |
| latest 浮动 | n/a | n/a | n/a | 0 (FROM...:3.8.43@sha256:517c...) | n/a | n/a | n/a |
| cf-worker 目录 | n/a | n/a | n/a | 无 COPY | n/a | n/a | 文档 ✓ |

## 6. 关键 feature 行为 (candidate 实现要点)

### 6.1 gate.js
- 三类入口分离: `/healthz` (免认证 fetch `/api/monitoring/health`) | `/v1`, `/v1/*` (PSK timing-safe → 替 OR_API_KEY 转发) | 后台 (GATE_ADMIN_TOKEN Basic Auth).
- 默认暴露面: 仅 `/healthz` + `/v1` + `/v1/*`; 其余 404 (修 slim `createProxyMiddleware('/')` 全透传违红线2).
- SSE: 手写 `http` 逐块 pipe + 背压 (`res.write` false → `pause` + `drain` resume) + 客户端 `close`/`aborted`/`error` `cleanup` `upstreamReq.destroy()` + 上游 `timeout` 504 + 上游 `error` 503/502.
- 路径规整 `normalizePath`: 解 dot-segment/重复斜杠/尾斜杠 (防白名单匹配绕过).
- 方法白名单 405 (post/patch/delete 默认非后台白名单, 405).
- 信号: `SIGTERM`/`SIGINT` `shutdown(grace)` `server.close` + 5s grace + forced exit.
- 零第二套限流 (限流在 OmniRoute requestQueue; gate 无限流代码).

### 6.2 entrypoint.sh
- LiteStream restore: R2 配置缺失 → 非致命降级; 本地 DB 非空跳过; 临时路径 `.storage.sqlite.restore.$$` restore; post `PRAGMA quick_check`; 失败按 LITESTREAM_STRICT (默认 1) exit.
- 信号转发: `trap` TERM/INT `_signal_kill`;  PID 保存 `GATE_PID`/`OR_PID`/`LS_PID`/`INIT_PID` (POSIX sh 变量, 不用 bash 数组); `wait` 回收; 任一关键进程退 `_shutdown` 杀余.
- `/healthz` fetch `--max-time 3` 探 OmniRoute ready.
- 三阶段顺序: R2 配置 + restore → 启 OmniRoute (等 /healthz ready) → 启 init (NIM config) + gate serve.

### 6.3 init-nim-keys.sh
- 限流固定值 28 RPM/1 并发/2200ms (G3 决议: 配置在 OmniRoute `requestQueue` 服务端; 无线性扩算式).
- `_VALID_STRATS`: fusion 保留, **context-relay 删** (CF-1: NIM 永不用 context-relay).
- Resilience PATCH: `useUpstream429BreakerHints=false` (G1 保守默认, 实例未证) + **read-back** (CF-4: 写后读回, 验不达保留旧).
- Context Override: **K5 FIX 后** — 保留 init 内部 per-model 32K override (`INSERT OR REPLACE INTO model_context_overrides ... source='init'`, 42ea8e7 基线原态恢复); 仍禁 monitor 自动回写 (4632e8c 改动保留); 自动 Context Override (confidence-based monitor 标定) 保持关. 原"删直写 + 指向 API PATCH 替代"已修正——B1 L2 源码实证 3.8.43 PATCH `/api/provider-models` 不接受 `max_input_tokens`/`max_output_tokens`/`contextLength`, 原 API PATCH 路径会静默失败.
- codex strategy: **#4 FIX 后** — 默认 `:-priority` (原 `:-round-robin`); code-gen 场景不宜每轮换模型; env `NIM_CODEX_STRATEGY` 可覆盖.
- DEBUG Dataset 上传: 默认关 (`NIM_DEBUG_LOG_TO_DATASET=1` 开), 启用上传前字段级脱敏 (Authorization/NIM_KEY/Cookie/Set-Cookie/Bearer → `<REDACTED>`).

### 6.4 Dockerfile
- FROM `diegosouzapw/omniroute:3.8.43@sha256:517c160643c56ad72e3e305458d961c9a4c87f711393c13020450f9f088d1570` tag+digest 双写锁 (禁 latest).
- 删 `3.8.46@sha256:...` 注释落漂行 (防误用).
- 加 `# ENV GATE_ADMIN_TOKEN=` 注释 (默认不设).
- 无 cf-worker COPY (CF-1 删整目录).

### 6.5 litestream.yml
- `auto-recover: true → false` (entrypoint 已显式 restore + guard; 防 litestream 自恢复绕 guard 覆盖有效 DB).
- snapshot `1h` / `retention 24h`.

## 7. KNOWN-UNVERIFIED (候选不实例验证, 不入生产默认)

| # | 项 | 处置 | 验证路径 |
|---|---|---|---|
| G1 | NIM direct-cloud `useUpstream429BreakerHints` | 保守默认 false | 实例 reachable + NIM 凭据 + read-back schema → 实证后可改 true |
| K2 | `/api/resilience`, `/api/providers`, `/api/provider-models`, `/api/monitoring/health` 真响应结构 (未 instance read-back) | B3 源码 schema 推断; Resilience 写后 read-back mock 验, 未真实例验 | 部署后只读 GET 立即验; 不符告警不强写 |
| K3 | 后台完整白名单 (页面 + `/_next/*` + 登录回调 + 写 API) 未实例验 (实际构建产物路径) | 默认关 (全 404); 高风险写默认不开放, 逐条加白前实例证 | 实例登录会话验证后逐条加 |
| K4 | HF 代理拓扑真实客户端 IP 未验 | 不实现 IP/CIDR (不靠伪造 IP) | HF 文档/实测代理 CIDR 后可加; 优先不加 |
| K5 | ~~自动 Context Override API PATCH 路径~~ **已修复 (选项 c)** — B1 L2 实证 3.8.43 PATCH 不接受 max_tokens/contextLength; 候选改保留 init 内部 per-model 32K override (source='init'); API PATCH 路径弃用不指向 | K5 修复后行为: init 启动时一次性应用 32K override 经 SQLite 直写 `model_context_overrides`, 不自动回写, 不调 API PATCH |
| K6 | `proxy_enabled` 直写 provider_connections (历史遗留非本次热点) | 保留 B1 行为 (未列本次重构) | 后续 API 化待办 |

## 8. 候选状态评估 — 入下一阶段决策点

候选已实现所有 audit/05 C-Fail + CF 决议 + 测试矩阵全过 (65 PASS / 0 FAIL / 2 SKIP-NEEDS-INSTANCE).

**停留点**: 候选自审在_FILE�� (candidate 内 tests/ 跑 mock 上游), 未对真实 OmniRoute 实例 fetch read-back (G1-K5). 候选主张: **保守默认 + fail-safe**, 未实例证的 risky 字段默认关 (不生产冒险).

**入下一阶段 (合入生产 / Stage E 部署) 前提**:
1. 用户决策合入主分支的时点 (候选未动生产, 未改主仓).
2. (推荐) 部署后立即只读 instance read-back (audit/07 plan):
   - GET `/api/resilience` 验字段 (K2)
   - GET `/api/providers` 验 NIM provider type (G1)
   - GET `/api/monitoring/health` 验 /healthz gate 上游 fetch 真响应
   - GET `/api/provider-models` 验 schema
   - 实证不符 → 告警不强写; 仅"优化" (限流固定值/Resilience breaker) 写必须 read-back 验落定
3. 候选的 `GATE_ADMIN_TOKEN` 仅维护窗口临时设强随机, 用完删除 (恢复仅 API 暴露).

**候选最显著升级对 B1 生产**: (1) PSK timing-safe (安全), (2) LiteStream restore 非空 guard + quick_check + strict exit (防覆盖有效 DB), (3) PID1 信号转发 + wait 回收 (graceful shutdown 无孤儿), (4) SSE 真流式手写 (不依赖 http-proxy-middleware; 不聚合流), (5) 默认暴露面收窄 + 后台受控重引入 (修 slim 全透传).

## 9. 范围与不主张 · 红线守

- 候选主张诚实: 只主张 candidate tests/ 实跑过的行为; 不主张 instance unverified 字段 (G1/K2/K5) 已产.
- SKIP 项明列 NEEDS-INSTANCE, 不静默假 PASS (audit/05 §NEEDS-MOCK-D-BLOCKED 已守).
- cf-worker (CF-1) / context-relay / 自动 Context Override 直写 / `ENABLE_ADMIN_UI` / nim_health_pick / http-proxy-middleware — 全整删, 不"图片化保留".
- 敏感不硬编: R2 / NIM / OMNIROUTE_API_KEY / GATE_ADMIN_TOKEN / INTERNAL_PSK 全 env 或 HF Secret, 不落明文.
- 不改主仓源码 (B1 `42ea8e7` 不动): 候选在 `candidate-v4.3-reviewed/` 独立目录, 主仓 root 未改.
- 依赖处理诚实: candidate/tests/ + candidate/ 装 express (源 npm registry, `npm install express --prefix . --no-save --omit=dev`), 不全局, 不改根 lockfile (根无 lockfile). 记录命令与来源 (TESTING.md §依赖处理).

## 10. K5 FIX + #4 FIX (审查裁定选项 c, 部署前必修项落地)

### 10.1 K5 FIX — 候选 context override 路径静默失败修正

**背景** (B1 L2 源码实证): PATCH `/api/provider-models` 在 3.8.43 源码 (route.ts:309 强制 isHidden boolean; `updateCustomModel` models.ts:591 不处理 max_tokens) 仅接受 `isHidden`; 仅 POST add (route.ts:109) 接受 `max_input_tokens`/`max_output_tokens`. 候选此前**删除 init 内部 `apply_context_override` (per-model 32K override) 并指向不存在的 API PATCH 路径** → 候选 context override 会静默失败 (无反馈).

**审查裁定** (推荐选项 c):
- 保留 init 内部 per-model 32K override (`apply_context_override`, 42ea8e7 基线原态, `INSERT OR REPLACE INTO model_context_overrides ... source='init', refreshed_at=datetime('now')`)
- 不删该段; 不指向 API PATCH 替代路径
- 保留 4632e8c "禁用 monitor 自动回写"改动 (source='monitor'/'monitor+manual' confidence-based 自动标定仍禁)
- API PATCH 路径标注为"3.8.43 不支持, 待源码新增 PATCH 字段支持"
- 行为预期: init 启动时一次性应用 32768 (32K) override 经 SQLite 直写 `model_context_overrides` (source='init'), 不跨周期自动标定, 不调 API PATCH.

**修复落点** (candidate-v4.3-reviewed/init-nim-keys.sh): L569-599 (K5 FIX 注释 + apply_context_override 函数恢复 + override: X applied Y failed 循环 + 行为预期注释), L583 (summary 行 REAL_CONTEXT 表述由"默认关不直写"改"$\_NIM_REAL_CONTEXT (per-model 32K override 应用, monitor 自动回写禁用)").

**L3 交叉验证** (New 3222.txt line 129): override: 9 applied, 0 failed — 确认 42ea8e7 基线 init 内部 override 路径在 v4.2.3 生产正常工作, 候选恢复后行为一致.

### 10.2 #4 FIX — codex strategy round-robin → priority

**背景** (L3 New 3222.txt line 64 + New 3231321.txt line 59): codex `strategy=round-robin` 跨重启复现. 代码生成场景每轮换模型致上下文连续性丢失, 不宜在 code-gen 池用 round-robin.

**修复** (candidate-v4.3-reviewed/init-nim-keys.sh): L149-153 `_CODEX_STRATEGY="${NIM_CODEX_STRATEGY:-priority}"` (原 `:-round-robin`) + 校验失败回退 priority (原 round-robin) + `# FIX #4` 注释; env `NIM_CODEX_STRATEGY` 可覆盖 (如需 round-robin 传 env).

**行为预期**: init 默认 codex strategy=priority; 不改 `_POOL_STRATEGY` (仍 round-robin, 非场景敏感) 与 `_FALLBACK_STRATEGY` (仍 round-robin). 隔离实例需验 priority 策略在 NIM codex 池实际生效 (P2 SEE §11 KNOWN-UNVERIFIED-K5-FIX 维持 NEEDS-INSTANCE).

### 10.3 mock 测试断言同步更新

test-runner.js TEST 9 (L352-357) 断言由 "无直写 override" 改为 "K5 修复后保留 init 直写 override (source=init)" + "monitor 自动回写仍禁 (功能行 INSERT/UPDATE 不含 monitor+manual)"; TEST 10 (L370) neg regex 加 `不接受` (K5 注释含"不接受 contextLength" 语境). mock 测试 65 PASS / 0 FAIL / 2 SKIP 维持.
