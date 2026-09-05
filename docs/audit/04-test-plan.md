# Stage C · 测试计划 (audit/04-test-plan.md)

> 第六独立审查者 · Stage C 产出 · 未改任何生产文件, 未生成候选
> 生成日期: 2026-07-11
> 三基准: B1 nomn/main @ `42ea8e7` | B2 working tree @ `9a1a7f0` | B3 omniroute-v3.8.43 @ `b729a8f`
> CF-1 裁决: cf-worker 彻底移除 (Stage D 动作; Stage C 不删生产文件, 仅扫描确认残留)

## 0. 工具退化声明

- `shellcheck`: **未安装** → 退化 `bash -n` (语法层); 逻辑层靠人工静态追踪 + git blame。
- `yq`: 未安装 → YAML 用 `python3 -c "import yaml"` (已验 OK)。
- `node v22` / `jq 1.6` 可用。
- 不安装额外工具 (守 Stage A/B 纪律, 不动环境)。

## 1. C1 静态分析计划 (无副作用)

| 项 | 工具/方法 | 门控准则 | 结果落 audit/05 §1 |
|----|----------|---------|--------------------|
| C1.1 shell语法 | `bash -n` 所有 `.sh` | 语法 0 error | OK/ERR |
| C1.2 JS语法 | `node --check` 所有 `.js` | 0 error | OK/ERR |
| C1.3 JSON语法 | `jq empty` 所有 `.json` | 0 error | OK/ERR |
| C1.4 YAML语法 | `python3 yaml.safe_load` litestream.yml + workflows | 0 error | OK/ERR |
| C1.5 PSK timing-safe | gate.js L32 静态 | 须 `crypto.timingSafeEqual` | 现 `!==` 裸比 = FAIL |
| C1.6 SSE flush/chunk | gate.js L37 静态追踪 | 须显式 SSE 透传 + 无缓冲 | 现无显式 streaming/selfHandleResponse = L2 待 mock |
| C1.7 LiteStream restore 分支 | entrypoint.sh L14-21 静态 | 须 pre-restore 非空 guard + post-restore quick_check + 失败 safe-fail | 现无 guard + 失败仍 continue = FAIL |
| C1.8 PID1/SIGTERM/wait | entrypoint.sh L37/59/77/84 静态 | 须 trap SIGTERM/SIGINT 转发 + wait + 无孤儿 | 现无 trap + 孤儿 init/litestream = FAIL |
| C1.9 cf-worker 残留 | grep 全仓 | 须清零 (Stage D 删; Stage C 仅扫描) | 仓内仍存 (预期, 不删) |
| C1.10 RELAY/x-relay 残留 | grep 全仓 RELAY_URL_*/RELAY_TOKEN_*/x-relay-*/context-relay | 须清零 | past: RELAY 0 命中 ✓; context-relay 在 _VALID_STRATS (待 Stage D 删) |
| C1.11 nvidia 前缀 (G5) | B3 `resolveProviderId` + `auth.ts:998-1005` 静态 | 验三输入判定与层级 | OmniRoute 两段 `{provider}/{model}` + nvidia↔nvidia_nim provider 别名; **非三段** |

## 2. C2 只读实例 read-back 计划 (硬约束严守)

### 2.1 目标
- G1: NIM 429 是否 direct-cloud → `useUpstream429BreakerHints` 当前值
- CF-4: `/api/provider-models` response schema 是否含 `contextLength` 字段

### 2.2 请求清单 (合 3 GET, ≥3s 间隔, 无循环)
1. `GET /api/resilience` → 读 providerBreaker/connectionCooldown/useUpstream429BreakerHints 当前值
2. `GET /api/providers` → 确认 NIM provider type (direct-cloud/managed/other)
3. `GET /api/provider-models` (仅读回, 不写) → 验 contextLength 是否在 response schema

### 2.3 硬约束
- 全 GET; 禁 PATCH/POST/DELETE
- 不改任何配置
- 响应 key/token/secret/credential 字段脱敏后记录
- 401/403: 立即停止, 不重试, 标"无权限"
- 429: 立即停止, 不重试, 标 NEEDS-INSTANCE-TEST-G1
- 请求间隔 ≥3s; 合计 ≤3 次, 无循环
- 日志/审计文件不明文 API Key/Bearer Token

### 2.4 前置阻断 (已探测)
本地无 OmniRoute 实例 (port 20128 不可达), 无 Gate (7860), 全 env 凭据 UNSET, 无 `/data/.or-api-key`。
→ **0 请求发出** (连不到目标, 既非 401 也非 429, 属前置阻断)。G1/CF-4 维持 NEEDS-INSTANCE-TEST-*, 标"无实例/无权限"。

## 3. C3 模拟测试计划 (本地 mock, 不接触实例)

### 3.1 mock 范围
- mock OmniRoute 返回 14 状态: 200 / 400 / 401 / 403 / 404 / 410 / 413 / 422 / 429 / 500 / 502 / 503 / 504 / 超时
- gate.js 对每码转发/错误处理/日志行为
- 限流 28 RPM/1 并发/2200ms 是否 Gate 层执行 (解 G3 静态+模拟部)
- /healthz 格式 + 暴露面 (仅 /healthz + /v1[/...])
- SSE 是否被缓冲截断

### 3.2 执行方式 (守产出约束)
- mock 脚本放 `/tmp/` (非生产路径, 非仓内, 跑后清理), 不生成候选脚本入仓。
- 仅 audit/04 (本计划) + audit/05 (结果) 入仓。
- mock 用 node v22 + express + http (gate.js deps 已装于 node_modules? 见 §4)

### 3.3 G3 静态+模拟部 (解 Q G3)
- 静态: gate.js 全文**无任何限流代码** (无 rate map、无 setInterval 重置、无 concurrency semaphore)。createProxyMiddleware 也无限流。
- → **限流不在 Gate 执行**。init-nim-keys.sh 的 28 RPM/1 并发/2200ms 写入 OmniRoute 配置 (Resilience requestQueue), 限流实际由 **OmniRoute 服务端 requestQueue 执行**。
- **G3 解 (静态)**: Gate 无重复限流 (M07a G3 答案: 限流执行点 = OmniRoute 服务端 requestQueue; Gate 仅代理转发, 无重复限)。candidate 改 init-nim-keys.sh 固定 28/1/2200ms 不会双重掐流。
- 模拟证: C3 mock 验 gate.js 透传不限流 (并发请求直透), 不重复限。

### 3.4 SSE 截断风险 (解 G7)
- mock SSE generator + gate.js 透传 + 测客户端是否逐 chunk 收 (无缓冲)。
- 静态疑: createProxyMiddleware 默认 `selfHandleResponse=false` → 流透传; 但 Node 默认 socket timeout > SSE 长连接可能不截断 (keep-alive)。需 mock 验长流 (>30s) 不被截。

## 4. node_modules / gate.js deps 可用性

- gate.js 依赖: express + http-proxy-middleware + node fs。
- omn-merge 有 node_modules? 见 §1 探测。若无, mock 用全局或临时 npm install (守不装依赖原则 → 替代: 用 `node` 内置 `http` 自写极简 mock + proxy 不依赖 gate.js实际跑)。

## 5. 产出落点

- `audit/04-test-plan.md` (本文件)
- `audit/05-test-results.md` (C1 结果 + C2 状态 + C3 mock 结果 + G1/G3/G5/CF-4 解决状态)

## 6. 守纪声明

Stage C 不改生产文件 (gate.js/entrypoint.sh/init-nim-keys.sh/litestream.yml/Dockerfile/package.json); 不生成候选; 不 push; 不触发工作流; 不安装依赖 (退化工具); mock 脚本仅在 /tmp 跑后清理。

