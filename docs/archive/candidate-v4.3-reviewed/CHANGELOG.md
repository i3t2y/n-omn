# CHANGELOG — omniroute 太空舱 candidate v4.3

> 本文件列 v4.3 candidate 相对 B1 `nomn/main@42ea8e7` 的变更,
> 区分“从 B2 9a1a7f0 移植的修正”与“本候选新增改动”.
> 未部署生产; 已通过 candidate 内 tests/.

## 后台访问的演进 (CHANGELOG 重点)

- **v8.0 (历史)**: gate.js 含全量管理 API (`/api/providers` 等), 由 `GATE_ADMIN_TOKEN` 控制; **旧语义: 留空=内网直连不鉴权** (违当前红线).
- **slim (commit cbbcf41 "entrypoint.sh + gate.js slim")**: 删除全部后台管理 API, 改 `createProxyMiddleware('/', ...)` 对非 /v1 路径**全透传 OmniRoute** → 暴露面**比 404 更宽** (OmniRoute 自身后台经 proxy 直达). `GATE_ADMIN_TOKEN` 变量删除.
- **v4.3 candidate (本版)**: **受控重引入后台访问**, 关键决策:
  1. **删除 `ENABLE_ADMIN_UI` 布尔开关 + Token 的双变量设计** (配置状态组合过多) → 实际代码已无 `ENABLE_ADMIN_UI` 残留.
  2. **采用历史变量名 `GATE_ADMIN_TOKEN`**, 兼任“后台开关”与“后台入口认证密码”; **废弃 v8.0 留空不鉴权旧语义**, 改为: 留空/过短 → 后台**关闭** (全 404).
  3. **不恢复 slim 的 `createProxyMiddleware('/')` 全路径透传**; 亦不“除 /v1 外全部放行”.
  4. 后台白名单**来自 OmniRoute v3.8.43 真实路由最小权限保守子集** (B3 `src/app`): 前台页面 + `/_next/*` 静态 + 只读管理 API (GET); **高风险 (restart/shutdown/init/webhooks/任意写) 默认不开放** (列 KNOWN-UNVERIFIED).
  5. 后台认证用 **HTTP Basic Auth** (用户名 `admin`, 密码=`GATE_ADMIN_TOKEN`), `crypto.timingSafeEqual` 比密码 (非常量时间, 长度不等不退字符串比较). 浏览器导航可附加, 无须自创会话系统.
  6. **不实现 IP/CIDR 限制** (HF 代理拓扑未 L1 证据, 防伪造); 预留能力默认关.

## 自 B1 移植的修正 (来自 B2 9a1a7f0 已验证)

- gate.js PSK 改 `crypto.timingSafeEqual` (原裸 `!==` 非常量时间) — **Stage C FAIL C1.5 修复**.
- LiteStream restore 加本地非空 guard + post `PRAGMA quick_check` + 失败 strict exit — **Stage C FAIL C1.7 修复**.
- entrypoint 加 `trap` SIGTERM/SIGINT 转发 + 子进程 PID 保存 + `wait` 回收 + 无孤儿 — **Stage C FAIL C1.8 修复**.
- init 删自动回写 `model_context_overrides` (B2 注释禁 → candidate **整段删**, CF-2 决议).
- init 删 `nim_health_pick` 分档推荐 (B2 已删).
- init 删 4 个无价值功能块 (B2 第二轮精简 9a1a7f0).

## 本候选新增改动 (v4.3 Stage D)

### gate.js
- 暴露面白名单: 默认仅 `/healthz` + `/v1` + `/v1/*`; **其余 404** (修 slim `createProxyMiddleware('/')` 全透传违红线2).
- 后台受控重引入: `GATE_ADMIN_TOKEN` 单变量 (删 `ENABLE_ADMIN_UI` 双关).
- 后台 HTTP Basic Auth (`admin`/password) + timing-safe + `WWW-Authenticate` + 完成 delete `Authorization` 头不转发上游.
- 三类入口隔离: `/healthz` | `/v1`(PSK) | 后台(admin token), 互不回退.
- SSE 透传: 手写 `http` 模块逐块 pipe + 背压 (pause/drain) + 客户端断开 `destroy` 上游 + 上游超时 502/503/504; 不聚合不 `text/json` 读流.
- 路径规整 (`normalizePath`) 防 dot-segment/重复斜杠/尾斜杠绕过; 方法白名单 `405`.
- 静态资源 `/_next/*`、public favicon 等免 admin token (仅须开关开); 不可形成任意上游路径透传.
- 进程: `SIGTERM`/`SIGINT` 优雅关 (entrypoint trap 亦转发).
- **零第二套限流** (28/1/2200ms 在 OmniRoute requestQueue).
- 不 `app.set('trust proxy', true)`, 不读 `X-Forwarded-For` 左侧 (防伪造).

## Stage E 修复 (audit/06 任务一 · audit/09 任务二 · audit/11 任务三)

> 三任务 (CF-4 / New3213 3.txt abort 时间线) 套 priver working tree 修复, mock 65→80→88 PASS.

### 任务三 (audit/11) — gate ECONNRESET 结构化诊断 + abort source 区分 (gate.js)
- 新增 `classifyAbortSource(e, {gateTimeout, clientAborted, elapsedMs})`: 5 类优先级 timeout > client_close > shutdown > upstream_reset (ECONNRESET + elapsedMs<5000) > upstream_error; 三类前类判断逻辑零改动.
- `mapUpstreamStatus` 对外 HTTP 状态码契约 (503/504/502) **零改动** (abortSource 仅进结构化日志 + 响应 body `abort_source`, 不改 status).
- `socketPhase` 三相跟踪 (`connecting`→`headers`→`streaming`), 仅附 upstream_reset/upstream_error 日志 (三类语义外不附).
- proxyV1 上游 error handler 复用 classifyAbortSource + `firstError` 守门 (首 error 仅记一次, 反发 destroy 不覆盖); clientAborted → 不回写 (client 已走) + destroyInitiator=client; gateTimeout 已由 timeout handler 自己打 504 日志, global handler `if (!gateTimeout)` 跳不打重复.
- logGate 输出增 `socketPhase`/`destroyInitiator` 字段 (修前 serialize 丢 undefined → proxyV1 传了不输出).
- TEST 13 (7 项静态/动态) 全 PASS: 短时窗 ECONNRESET→upstream_reset+503, 长时窗 (>5000ms)→upstream_error+503, timeout→504, client close→client_close 无回写.

### entrypoint.sh
- LiteStream restore: 本地 DB 非空跳过 -> 临时路径 `$DB_TMP` -> post `quick_check` -> 原子 `mv`; 失败按 `LITESTREAM_STRICT` (默认 1) exit.
- 复制非致命 vs 严格开关 `LITESTREAM_STRICT` (0=非致命 warn / 1=严格 exit).
- 进程监督: `trap '...' TERM INT`; 子进程 PID 保存 (POSIX sh 变量不用 bash 数组); 向存活子进程转发信号; `wait` 回收; 任一关键进程 (gate/OmniRoute) 退出停其余; LiteStream replicate 退出按 STRICT.
- `/healthz` fetch 探活加 `--max-time 3`.

### init-nim-keys.sh
- 限流固定值 28 RPM/1 并发/2200ms (原按 alive_keys 线性扩 → 固定; G3 解).
- `_VALID_STRATS` 删 `context-relay` (保留 fusion; CF-1 红线: NIM 永不用 context-relay).
- Resilience PATCH 加 `useUpstream429BreakerHints=false` (G1 保守默认, 实例未证).
- Resilience PATCH **加读回验证** (CF-4: 写必须读回; 失败保留旧).
- context override **整段删 SQLite 直写** `model_context_overrides` (CF-4: 禁直写 SQLite; 自动 Context Override 默认关; 启用路径 API PATCH `max_input_tokens`/`max_output_tokens` + 读回, KNOWN-UNVERIFIED).
- DEBUG Dataset 日志上传 **默认关** (`NIM_DEBUG_LOG_TO_DATASET=1` 开); 启用上传前字段级脱敏 Authorization/NIM_KEY/Cookie/Set-Cookie/Bearer → `<REDACTED>` (红线1 动态).

### Dockerfile
- 删 `3.8.46@sha256:...` 注释落漂行 (防误用); 保留 `FROM ...:3.8.43@sha256:517c160...` tag+digest 双写锁 (禁 latest).
- 加 `# ENV GATE_ADMIN_TOKEN=` 注释说明 (默认不设).

### litestream.yml
- `auto-recover: true` → **`false`** (entrypoint.sh 已显式 restore 含 guard; 防重复恢复绕过 guard 覆盖有效 DB).

### package.json
- `4.2.3` → `4.3.0`; 删 `http-proxy-middleware` 依赖 (gate.js 改用 Node 内置 `http`).

## 删除项 (L5)

- `cf-worker/` 目录及其 workflow `deploy-cf-worker.yml` (CF-1: cf-worker 彻底移除, 不图片化保留).
- `context-relay` 纯strat (init).
- 自动 Context Override 直写 (init).
- `nim_health_pick` 分档推荐 (init).
- slim 版 `createProxyMiddleware('/')` 全路径透传 (gate.js).
- `ENABLE_ADMIN_UI` 双变量设计 (废弃, 单 `GATE_ADMIN_TOKEN`).

## 禁止项保持禁止

- 禁 `latest` 镜像; 锁 `v3.8.43@digest`.
- 禁外部 Relay / `RELAY_URL_*` / `RELAY_TOKEN_*` / `x-relay-*`.
- 禁 `contextLength` 字段 (用 `max_input_tokens`/`max_output_tokens`).
- 禁 NIM `nvidia/*/* 三段式` (源码证两段 `{provider}/{model}` + provider alias; G5 解, CF-10).
- 禁 gate 加第二套限流 (G3 解).
