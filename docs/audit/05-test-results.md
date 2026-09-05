# Stage C · 测试结果 (audit/05-test-results.md)

> 第六独立审查者 · Stage C 产出 · 未改任何生产文件, 未生成候选
> 生成日期: 2026-07-11
> 三基准: B1 nomn/main @ `42ea8e7` | B2 working tree @ `9a1a7f0` | B3 omniroute-v3.8.43 @ `b729a8f`
> 关联: audit/04-test-plan.md (计划) · CF-1 裁决 cf-worker 彻底移除 (Stage D 动作)

## 1. C1 静态分析结果

### 1.1 工具退化
- `shellcheck`/`yq` 未安装; 退 `bash -n` + `python3 yaml.safe_load`。
- `node v22` / `jq 1.6` 可用。未装新依赖 (守纪)。

### 1.2 静态分析矩阵

| 项 | 文件:行 | 工具 | 结果 | 门控 |
|----|--------|------|------|------|
| C1.1 shell语法 | entrypoint.sh; init-nim-keys.sh | `bash -n` | **OK** (0 err) | ✓ |
| C1.2 JS语法 | gate.js; cf-worker/index.js | `node --check` | **OK** (0 err) | ✓ |
| C1.3 JSON语法 | package.json; .claude/settings.local.json | `jq empty` | **OK** | ✓ |
| C1.4 YAML语法 | litestream.yml; sync-to-hf-space.yml; deploy-cf-worker.yml | `python3 yaml.safe_load` | **OK**³ (wrangler.toml 注: 是 TOML 非 YAML, 此项豁免) | ✓ |
| C1.5 PSK timing-safe | gate.js:32 | 静态 | **FAIL** (`bearer !== INTERNAL_PSK` 裸比, 非常量时间) | ✗ Stage D 修 |
| C1.6 SSE flush/chunk | gate.js:37 | 静态 | **风险-未实跑** (无 `selfHandleResponse`/streaming 标记, node_modules 缺故 mock 未实跑; http-proxy-middleware 默认流透传但无显式 SSE 须 mock 验) | ⚠ 标 NEEDS-MOCK-D |
| C1.7 LiteStream restore 分支 | entrypoint.sh:14-21 | 静态 | **FAIL** (L16 `-if-replica-exists` 无 pre-restore 本地非空 guard; L18 restore 失败仍 `Continuing`; 无 post-restore `PRAGMA quick_check`) | ✗ Stage D 修 |
| C1.8 PID1/SIGTERM/wait | entrypoint.sh:37/59/77/84 | 静态 | **FAIL** (无 `trap` SIGTERM/SIGINT 转发; init L59 与 litestream L77 孤儿无 PID 捕获无 `wait`; L84 `exec node gate.js` 成 PID1 后子进程无信号转发) | ✗ Stage D 修 |
| C1.9 cf-worker 残留 | 全仓 grep | `grep` | **仓内仍存** (cf-worker/index.js 447 行 + readme.md + wrangler.toml, workflow deploy-cf-worker.yml; **预期**: Stage C 不删生产文件, 留 Stage D 清零)。**audit/00 文档内引用 cf-worker** (§5 等) 须 Stage D 同步清理 | ⏸ Stage D |
| C1.10 RELAY/x-relay残留 | 全仓 grep | `grep` | **RELAY_URL_*/RELAY_TOKEN_*/x-relay-*: 0 命中** ✓; `context-relay` 在 init-nim-keys.sh:102 `_VALID_STRATS` (Stage D 删, CF-6 解) | ✓ RELAY 清零; ⏸ context-relay Stage D |
| C1.11 nvidia 前缀 (G5) | B3 `providers.ts:339`; auth.ts:998-1005; init-nim-keys.sh:99 | 静态 B3 | **解** (见 §4.3 G5) | ✓ |

### 1.3 C1 汇总
- 静态 **错误 (FAIL)**: 3 (C1.5 PSK, C1.7 LiteStream guard, C1.8 进程监督) — 均对应 audit/02 M04/M05/M06 ACCEPT-WITH-GUARD, 待 Stage D。
- 警告风险: 1 (C1.6 SSE mock 未实跑, 标 NEEDS-MOCK-D)。
- **通过**: 7 项 (语法/JSON/YAML/残留清除/cf-worker 现状扫描/G5)。
- cf-worker 移除 + context-relay 删 + timing-safe/restore/signal 修正 = **Stage D 必修**。

---

## 2. C2 只读实例 read-back 结果

### 2.1 前置阻断 (硬约束守)
- 探测 (只读, 未发请求): OmniRoute port 20128 **不可达** (无实例); Gate port 7860 **不可达**; env `INTERNAL_PSK`/`OMNIROUTE_API_KEY`/`JWT_SECRET`/`API_KEY_SECRET` **全 UNSET**; 无 `/data/.or-api-key`。
- → **0 请求发出** (连不到目标 = 前置阻断, 既非 401 也非 429; 严守硬约束不发请求)。

### 2.2 各项状态
- **G1** (NIM 429 direct-cloud → `useUpstream429BreakerHints` 当前值):
  - 无法 read-back `/api/resilience` 与 `/api/providers` → **NEEDS-INSTANCE-TEST-G1 维持** (无实例/无凭据)。
  - 静态旁证: B3 `providerHints.ts:56` default-cloud=true 兜底; NIM 落 direct-cloud 分支未见显式白名单, 待实例只读验证。
- **CF-4** (response schema 是否含 `contextLength`):
  - 无法 read-back `/api/provider-models` → 实例侧维持 NEEDS-INSTANCE-TEST。
  - **源码侧已 L2 解** (见 §4.4 CF-4): mutation schema 无 `contextLength` 字段 (B3 `schemas/provider.ts:129-169+`), 可写字段 `max_input_tokens`/`max_output_tokens`; `contextLength` 仅在 catalog 读态。→ 候选方案不依赖 instance read-back, 可 Stage D 落地。

### 2.3 守纪
- 未发任何 GET/PATCH/POST/DELETE (前置阻断致 0 请求); 未读/输出任何凭据; env 探测仅看变量名存在性不打印值。

---

## 3. C3 模拟测试结果

### 3.1 mock 实跑阻断
- omn-merge **无 node_modules** → gate.js deps (express, http-proxy-middleware) 未装。
- 守"不安装依赖"原则 → **mock 不实跑**, 退化**纯静态推导 gate.js 行为** (代码 41 行全读)。
- **NEEDS-MOCK-D**: Stage D candidate 须装 deps 跑真 mock 验 SSE/状态码; Stage B/C 标 G7 待此解 (静态已推导, mock 实跑未补)。

### 3.2 gate.js 状态码行为静态推导表

| 上游响应 | gate.js 行为 (静态) | 正确性 | 备注 |
|---------|---------------------|--------|------|
| 200 | L37 proxy 透传 → 客户端收 200 | ✓ | 正常路径 |
| 400/404/410/422 | proxy 透传 → 客户端收原码 | ✓ | 透传 OK |
| 401(上游)、401(gate) | gate L32 PSK 不符→401 `{error:unauthorized}`; 上游 401 透传 | ✓ PSK 层; ⚠ 上游 401 透传泄露 | 上游 401 经 L33 已替换 Authorization, 实际 OmniRoute 收到正确 key 故上游 401 应是真鉴权失败 |
| 403 | 透传 | ✓ | OmniRoute 鉴权/限权 |
| 413 | 透传 | ✓ | Context 边界 (init M33 纳入) |
| 429 | 透传 | ✓ | OmniRoute requestQueue 限流出口; gate 不限流 |
| 500/502/503/504 | 透传 | ✓ | 上游错 |
| 超时 | L37 无 `proxyTimeout`/`timeout`, Node 默认 socket timeout → 上游 hang 致客户端长挂 | ✗ FAIL | Stage D 候选加 proxyTimeout |

### 3.3 /healthz 格式 + 暴露面 (静态)

- `/healthz` (L24-27): 无 PSK 公网可探; 探 OmniRoute `/api/monitoring/health`; `r.ok→200{ok:true}` 否 `503{ok:false}`。
- **暴露面违红 (#4/M03)**: L30 `if !startsWith('/v1') return next()` → 非 /v1 **next 透传到 L37 proxy**, **不 404**。`/`、`/api/*`、`/settings/*` 等任意路径透传 OmniRoute → **暴露面远超 /healthz + /v1**。
- `/healthz` 自 L25 `fetch` 无 timeout → OmniRoute hang 致 /healthz 挂 (维度7)。
- **Stage D 候选**: 显式白名单仅 `/healthz` + `/v1` 与 `/v1/...`, 其余 `res.status(404).end()`; `/healthz` fetch 加 `AbortSignal.timeout(2000)`。

### 3.4 限流 simulated-q (G3 解 — 静态+模拟推算)

- gate.js **0 限流代码** (grep 空, C1 已验) → Gate 无 RPM/并发/间隔限制, 纯代理透传。
- init-nim-keys.sh:549 `PATCH /api/resilience -d '{"requestQueue":{"requestsPerMinute":$_RPM,"minTimeBetweenRequestsMs":$_MIN_INTERVAL_MS,"concurrentRequests":$_CONCURRENT}}'` → 限流**完全由 OmniRoute 服务端 requestQueue 执行** (B3 `types.ts:16-18` 字段名 camel 一致)。
- **G3 解 (静态+模拟推算)**: 限流执行点 = OmniRoute 服务端; **Gate 不重复限流** → 候选改 init 固定 28/1/2200ms (**不**在 Gate 加限流) 无双重掐流。M07a CF-3 冲突**关闭**。
- 模拟推算: gate.js 并发请求 n 全直透 OmniRoute → 受 requestQueue.concurrentRequests=1 (候选值) 调度 → 无 Gate 层并发信号量。透传正确。

### 3.5 SSE 截断 (G7 静态 + 待 mock)

- L37 `createProxyMiddleware({target, changeOrigin:true})` **未显式 `selfHandleResponse`/`proxyTimeout`**。
- http-proxy-middleware 默认 `selfHandleResponse=false` → 上游 `res` pipe 直转下游 `res`, text/event-stream 流透传**不缓冲** (proxy 不会自聚合 chunk)。
- **风险 (静态)**: (a) Node 默认 socket keep-alive timeout 对 >120s SSE 长连接可能触发 close; (b) 无显式 `X-Accel-Buffering: no` 头注入 (HF 反代若 Nginx 似物可能缓冲); (c) 上游中断 gate 是否正确 end 客户端不确定 (proxy error handler 缺)。
- **G7 状态**: 静态推算"可能不缓冲但无显式保障" → **部分解**, 标 `NEEDS-MOCK-D` (Stage D 装 deps 后实跑 SSE 长流验证)。Stage C 无 node_modules 致不能更。

---

## 4. G1/G3/G5/CF-4 解决状态汇总

### 4.1 G1 (NIM 429 direct-cloud → useUpstream429BreakerHints)
- **状态**: **仍待测 (NEEDS-INSTANCE-TEST-G1 维持)**。
- 原因: C2 前置阻断 (无实例/无凭据), 未 read-back `/api/resilience`+`/api/providers`。
- 静态旁证: B3 providerHints.ts:56 default-cloud 兜底 true, NIM 白名单未见。
- Stage D 阻断? 否 (candidate 不依赖 G1 决断; 默认开关可保守设 useUpstream429BreakerHints=false 直到 read-back 证; 读 back 待实例可用)。

### 4.2 G3 (限流双重 — OmniRoute requestQueue vs Gate)
- **状态**: **已解 (静态+模拟推算)**。
- 证据: gate.js 0 限流代码; init-nim-keys.sh:549 限流值写 OmniRoute requestQueue (B3 types.ts:16-18 camel 一致) → 限流在 OmniRoute 服务端执行, Gate 不重复。
- 对候选: 改 init 固定 28/1/2200ms 不双重掐流。CF-3 冲突关闭。

### 4.3 G5 (nvidia 前缀三输入判定)
- **状态**: **已解 (L2)**。
- 证据 (B3 v3.8.43 b729a8f):
  - `resolveProviderId()` 定义 `src/shared/constants/providers.ts:339`; 运行时 `src/sse/services/auth.ts:58` + `960` + `998-1005` + `1062`。
  - nvidia 别名 (auth.ts:998-1005): `resolveProviderId("nvidia")→["nvidia","nvidia_nim"]`; `resolveProviderId("nvidia_nim")→["nvidia_nim","nvidia"]`。provider **二级互为别名** (nvidia↔nvidia_nim), DB lookup 两 ID 都试。
  - model ID 格式: **两段 `{provider}/{model}`** (非三段 `nvidia/owner/model`), 证于 B3 `inference-hosts.ts:95` `"nvidia/llama-3.3-70b-instruct"`、combos/page.tsx nvidia 各两段。
  - init-nim-keys.sh:99 `sed 's/^/nvidia\//'` 给裸 model 加 `nvidia/` 前缀 → 成 `nvidia/{model}` 两段, 与 OmniRoute 约定一致。
  - **背景 #4 "nvidia/*/* 三段式" 描述错** — OmniRoute 是两段 `{provider}/{model}` + nvidia↔nvidia_nim provider 别名; **无 `nvidia/owner/model` 三段式**。
- 对候选 (M18 CF-10): 候选判定逻辑按**两段**写: `provider=nvidia (或 nvidia_nim 别名), model=<后段>`; 不按三段写。CF-10 解。

### 4.4 CF-4 (contextLength response schema 是否存在)
- **状态**: **源码侧已解 (L2); 实例侧仍待测 (NEEDS-INSTANCE-TEST, 非阻断)**。
- 证据 (B3 静态):
  - `providerModelMutationSchema` (`src/shared/validation/schemas/provider.ts:129-169+`): 字段 `provider`(req) `modelId`(req) `modelName?` `source?` `apiFormat` `supportedEndpoints` `targetFormat?` **`max_input_tokens?`** **`max_output_tokens?`** `normalizeToolCallId?`。
  - **mutation schema 无 `contextLength` 字段** (grep + 精读 L129-169+ 确认)。
  - `contextLength` 仅在 catalog 读态 (`managedAvailableModels.ts:7`, `modelMetadataRegistry.ts:312-315`, `modelDiscovery.ts:100-102`), 非可写 body。
  - 可写 token 字段 = `max_input_tokens`/`max_output_tokens` (wire shape, 持久 inputTokenLimit/outputTokenLimit)。
- 对候选 (M09 REJECT/M10 ACCEPT): 候选 v4.3 Context Override 走 **API PATCH `max_input_tokens` + 读 back**, 不用 `contextLength` 字段 (REJECT 路径), 不直写 `real_context` 内部表 (M11 REJECT)。CF-4 关三路变一路。
- 实例 read-back (验 response schema 真返字段): 前置阻断未跑, 但源码 L2 决断足用; "仍待测" 非阻断 (源码已证 mutation schema 无此字段)。

---

## 5. 新发现阻断项

- **NEEDS-MOCK-D** (新): Stage C 因 node_modules 缺失未实跑 mock (gate.js deps express/http-proxy-middleware 未装); SSE 截断 (G7) 与状态码路径仅静态推导。Stage D 候选 env 须装 deps 后跑真 mock 长流验证 SSE 不截断 + 14 状态码路径。**非 Stage D 阻断** (静态推导已足推断候选方向), 但属 G7 完结前提。
- 无其他新阻断。原 NEEDS-* (G1/G4/G6/G7/G8/G9/G10) 维持 Stage D 前/候选内继续解。

---

## 6. 就绪进入 Stage D 判定

- **G3/G5/CF-4**: 已解 (静态+源码 L2) — **候选可定方向**。
- **G1**: 仍 NEEDS-INSTANCE-TEST, **非 Stage D 阻断** (candidate 保守设 useUpstream429BreakerHints=false 待实例证)。
- **G7**: 部分解 (静态), 标 NEEDS-MOCK-D Stage D 内补实跑。
- **C1 发 3 FAIL** (PSK/restore/signal): 已定 ACCEPT-WITH-GUARD, Stage D 候选必修。
- **cf-worker 移除 + context-relay 删 + 暴露面 404*: Stage D 候选必修 (CF-1 裁决 + CF-6)。
- **CF-1 阻断 Stage D 触发项?** CF-1 已由用户裁决 (cf-worker 彻底移除) → **Stage D 候选含 cf-worker 删除动作**, 不再待议。

→ **就绪进入 Stage D**: 候选方向已锁 (两段前缀 / requestQueue 写限流不双限 / max_input_tokens PATCH / cf-worker 删 / PSK timing-safe / restore guard / signal 转发 / 暴露面 404 / context-relay 删 / DEBUG Dataset 默认关脱敏)。G1 保守默认 + G7 实跑在候选内补。

---

## 7. 守纪声明

- 未改生产文件 (gate.js/entrypoint.sh/init-nim-keys.sh/litestream.yml/Dockerfile/package.json mtime 未动)。
- 未生成候选脚本。
- 未调真实 NVIDIA API; C2 0 请求发出 (前置阻断)。
- 未 push; 未触发工作流; 未安装依赖 (shellcheck/yq/node_modules 均未装, 工具退化)。
- mock 未实跑 (node_modules 缺); 静态推导足入文档。
- 仅写 audit/04-test-plan.md + 本文件。

---

## 8. 静态 FAIL 细节 (供 Stage D 候选直引)

### 8.1 gate.js:32 PSK timing-safe (C1.5)
- 现: `if (bearer !== INTERNAL_PSK) return res.status(401)...` — `!==` 字符串比非常量时间 (length diff short-circuit 泄露 PSK 长度)。
- 修: `const a=Buffer.from(bearer); const b=Buffer.from(INTERNAL_PSK); if(a.length!==b.length||!crypto.timingSafeEqual(a,b)) return res.status(401)...`。

### 8.2 entrypoint.sh:14-21 LiteStream restore (C1.7)
- 现: `litestream restore -if-replica-exists $DB` + `|| echo WARN Continuing`; 无本地非空 guard, 无 post quick_check, 失败仍启动。
- 修: pre-restore `[ -s "$DB" ]` 跳过 + post-restore `sqlite3 "$DB" "PRAGMA quick_check"` 校 + 失败 exit 1 (safe-fail)。

### 8.3 entrypoint.sh:37/59/77/84 进程监督 (C1.8)
- 现: OmniRoute/init/litestream 后台 `&`, 无 trap 转发 SIGTERM/SIGINT, 无 wait; gate.js exec 成 PID1 后子进程无信号。
- 修: `trap 'kill -TERM $OR_PID $INIT_PID $LS_PID; wait' TERM INT` + 各后台 PID 捕获 + exec 前置 trap; 或 gate.js 内 `process.on('SIGTERM'/'SIGINT')` 转发。

### 8.4 gate.js:30 暴露面 (C1.5/红线2)
- 现: `if !req.path.startsWith('/v1') return next()` → next 到 L37 proxy 透传。
- 修: 白名单 `if (!req.path.startsWith('/v1') && req.path !== '/healthz') return res.status(404).end()`。

### 8.5 gate.js:25 /healthz 无 timeout
- 修: `fetch(url, {signal: AbortSignal.timeout(2000)})`。
