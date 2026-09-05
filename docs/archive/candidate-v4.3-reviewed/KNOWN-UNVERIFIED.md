# KNOWN-UNVERIFIED — omniroute 太空舱 v4.3 candidate

> 候选已守"不把源码验证写成生产实例验证". 以下项未实例验证, 不入默认生产路径.

## G1 — NIM direct-cloud 与 useUpstream429BreakerHints

- **状态**: 未实例验证.
- **原因**: 实例与凭据不可用 (Stage D 不访问真实实例/真实 NVIDIA API).
- **候选处置**: `useUpstream429BreakerHints=false` 保守默认 (Resilience PATCH body). 不声称 NIM direct-cloud 行为已被实例验证.
- **启用条件**: 实例可达 + 有效 NIM 凭据 + read-back `/api/providers` 确认 NIM provider type + `/api/resilience` 确认 breaker 字段语义.
- **最小验证方案**:
  1. 只读 GET `/api/resilience` 读回 `useUpstream429BreakerHints` schema 字段存在.
  2. GET `/api/providers` 看 NIM provider 是否 `type=direct-cloud` (源码 providerHints.ts:56 default-cloud 兜底 true; 实例实际写值未证).
  3. 触发 NIM 429 (测试 key, 真实但要非生产 key) 观察 breaker 分支.
  4. 如证 direct-cloud 分支正确, 设 `useUpstream429BreakerHints=true`; 反之保守 false.
- **回归**: 不开 breaker hints 不影响 requestQueue 限流 (G3 在 OmniRoute 服务端执行).

## 实例 read-back 未执行

- **未执行**: `/api/resilience`, `/api/providers`, `/api/provider-models`, `/api/monitoring/health` 真实响应结构未通过实例 read-back.
- **候选处置**: 基于 B3 源码 schema (L2 证据) 推断 requestQueue 字段名 camel; Resilience 写后**有读回** (init), 但读回未对真实实例运行 (mock 上游返回预置 schema).
- **未验证风险**: 若实例 schema 版本漂移 (v3.8.43+1 minor), camel 字段名或结构变化 → Read-back `jq` 路径默认 null, 候选 "不回滚 OmniRoute 旧配置" 行为保留 (safe-fail); 不直接写 SQLite.
- **补救**: 部署后立即只读 GET `/api/resilience` 验字段; 读回不符预期则告警 (init 已有) 不强写.

## 后台完整白名单 (页面 + /_next + 登录回调 + 写 API) 未实例验证

- **当前白名单来源**: B3 `src/app` 真实路由 (L2 路由结构证据):
  - 页面: `/`, `/login`, `/forgot-password`, `/auth/callback`, `/callback`, `/authorize`, `/connect`, `/terms`, `/privacy`, `/docs`, `/docs/[...slug]`, `/docs/api-explorer`, `/status`, `/landing`, `/home`, `(dashboard)/dashboard`.
  - 静态: `/_next/*` (运行时构建产物, 路径未实跑确认具体子路径), public/ 顶层文件 (`favicon.ico`, `favicon.svg`, `apple-touch-icon.{png,svg}`, `icon-192.svg`, `icon-512.png`, `sw.js`, `openapi.yaml`).
  - 只读 API: B3 `src/app/api/<route>/route.ts` 顶层只读子集 (providers/combos/resilience/keys/provider-models/models/settings/provider-stats/provider-metrics/sessions/session-pools/rate-limit/rate-limits/token-health/synced-available-models/free-models/free-provider-rankings/tags).
- **未实例验证**: 完整后台 UI (登录流程+看板交互+静态资源链) 实际所需路径集未在真实构建产物内跑; WebSocket/动态代理路径未确认.
- **未验证部分保留原因**: 默认关 (`GATE_ADMIN_TOKEN` 未设 → 全 404); 仅维护窗口开, 此时白名单已收窄; 缺的路径补再开不迟.
- **高风险能力**默认不开放 (列此以明):
  - `restart`, `shutdown`, `restart/:id` (OmniRoute `/api/restart`, `/api/shutdown`)
  - `init`, `webhooks`, `plugins`, `agent-skills`, `skills`, `policies`, `guardrails`, `evals`, `assess`, `batches`, `files`, `cache`, `memory`, `model-combo-mappings`, `db-backups`, `pricing`, `tags` 写路径 (POST/PATCH/PUT/DELETE, backend admin 写能力)
  - 任意 `POST`/`PATCH`/`PUT`/`DELETE` 写操作 (除非显式加白名单前实例证)
- **启用写 API 前置**: 实例真实构建产物 + 登录会话验证后, 逐条加写路径至 `ADMIN_API_ROUTES` 方法白名单; 未证前不"页面可能需要"扩大白名单.
- **为何后台仍保留**: 维护便利 (一键看板只读); 已默认关(全 404, 不增加默认攻击面).

## HF 可信代理拓扑及真实客户端 IP 未验证

- **未验证**: HF Space 前方平台代理链未知; `req.socket.remoteAddress` 可能只是平台代理; `X-Forwarded-For` 可能伪造.
- **候选处置**: **不默认实现 IP/CIDR 限制** (不在 GATE_ADMIN_TOKEN 开启前提只靠 IP); 不 `app.set('trust proxy', true)`; 不读 `X-Forwarded-For` 左侧作管理员 IP.
- **无 IP 防护宣称**: README 已明"不声称有 IP 防护".
- **前置**: 获取可信代理链 L1 证据 (HF 文档/实测代理 IP CIDR 范围) 后才可加 IP 白名单; 优先不加 (降攻击面 + 降依赖).
- **Gate 后台依靠**: GATE_ADMIN_TOKEN (强随机 ≥16) + HTTP Basic Auth + OmniRoute 自身认证 (三层), 不靠 IP.

## 自动 Context Override API PATCH 路径

- **候选处置**: **默认关闭** (init 删直写 SQLite 整段); 启用路径:
  1. 判 provider alias (G5 两段 `nvidia`/`nvidia_nim`).
  2. API `PATCH /api/provider-models` body 仅 `max_input_tokens`/`max_output_tokens` (源码 schema provider.ts:129-169+ 已证可写字段, 无 contextLength).
  3. **写后读回** GET `/api/provider-models/{id}` 验 token 字段落定.
  4. 失败保留旧 (不强写 SQLite, 读回不符不强行改).
- **未实例验证**: 写后值落定 (real `max_input_tokens` schema 字段写回行为) 未实例测试; 启用前须先实例验证 PATCH+读回 round-trip.

## `proxy_enabled` 直写 provider_connections (历史遗留)

- init L203/208 直接 `UPDATE provider_connections SET proxy_enabled=...` SQLite 写 (B1 历史功能, 非 candidate 本次主热点).
- **候选处置**: 保留 (B1 已有, 未列入本次重构 L1/L2 移植热点); 后续 API 化待办.
- **未验证理由**: 改该项须全业务上下文重构 (provider 代理状态读写跨多模块), 超 Stage D 收紧范围; KNOWN-UNVERIFIED 记待办.
