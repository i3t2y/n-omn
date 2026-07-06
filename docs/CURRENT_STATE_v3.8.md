# Current State — v3.8.x 实态快照

> **快照日期**：2026-07-06
> **上游版本**：OmniRoute v3.8.44（2026-07-04 最新 release，上游 `github.com/diegosouzapw/OmniRoute`）
> **当前部署分支**：本地 `main`（= 远端 `nomn/main` = n-omn 生产仓 main 分支），与原 `fusion-main` 同 commit（env-bypass 跨重建固定化合龙态 `bd69884`，init export-json 修正 `f9c743c`）
>
> 本文为当前实际代码态的真态快照，随上游演进更新。`docs/RELEASE_NOTES_v1.0.0.md`、`docs/VALIDATION.md`、`docs/implementation-log.md` 是 v1.0.0 当期历史快照，**勿改**。
>
> 活文档（`AI_HANDOFF.md` / `EXPERIENCE.md` / `DECISIONS.md` / `TROUBLESHOOTING.md`）反映 v1.0.0 时代，多处已 drift；其顶部 header 指向本文为准。

---

## 1. 架构与鉴权链路

```
Client
  ↓ Authorization: Bearer <CLIENT_TOKEN>
Cloudflare Worker (cf-worker/index.js, 公网入口, 443)
  ├─ CLIENT_TOKEN 校验
  ├─ Header 清理（cf-* / x-forwarded-* / x-real-ip / true-client-ip）
  ├─ 429/5xx 窗口统计 + Wecom/Resend 告警（STATE KV）
  └─ 注入 Authorization: Bearer <INTERNAL_PSK>
gate.js (HF Space 内部守门, 0.0.0.0:7860)
  ├─ INTERNAL_PSK 校验 + 缺失即 fatal
  ├─ 注入 Authorization: Bearer <OR_API_KEY>
  └─ /healthz → 上游 /api/monitoring/health
OmniRoute (node /app/server.js, 127.0.0.1:20128)
  ├─ OR_API_KEY 经 env-bypass 放行（见 §2）
  ├─ provider pool / combo routing / resilience / circuit breaker
  └─ 25 个 NIM key 轮询
NVIDIA NIM (integrate.api.nvidia.com)
```

**三层鉴权，每层只看自己 token，客户端永远看不到 OR_API_KEY。**

## 2. env-bypass 跨重建固定化（跨重建稳定的核心）

需 HF Space 配置 Secret `OMNIROUTE_API_KEY`（≥32 字节强随机串，建议 `openssl rand -hex 32`）。该值即合法上游 key，**无需写入 sqlite、不依赖 Litestream restore、跨 HF Space 重建不变**。

**源码查证（2026-07，上游 `src/lib/db/apiKeys.ts`）**：

```ts
function isConfiguredEnvApiKey(key): boolean {
  const envKey = process.env.OMNIROUTE_API_KEY || process.env.ROUTER_API_KEY;
  return Boolean(envKey && key === envKey);
}
// validateApiKey: if (isConfiguredEnvApiKey(key)) return true;
```

- env-bypass 在 lifecycle 校验（banned/active/revoked/expired）**之前 return**，env-key 不受 sqlite 行失效牵连。
- `getApiKeyMetadata` 给 env-key 合成 `id:"env-key"`、`scopes:["manage"]`（全权）。
- entrypoint.sh 透传该 env 给 `node /app/server.js`；gate.js 优先读 env（`.trim()`）回退读 `/data/.or-api-key` 文件；init 检测 env 存在时跳过 `/api/keys` 创建段，仍写 `.or-api-key` 镜像作诊断/兼容。

**fallback 链路**：未设 env 时走旧路径——init 调 `/api/keys` 生成、写 `/data/.or-api-key`，gate 读文件。

**旧 Secret 迁移**：残留的 stage3 时代 `OR_API_KEY` Secret 不被 env-bypass 消费（只识别 `OMNIROUTE_API_KEY` / `ROUTER_API_KEY`），应在 HF Space Settings 删除以免命名混淆。

## 3. Resilience / 配置参数（init 默认值，env 可覆盖）

`init-nim-keys.sh` 顶部动态参数（行 48-57），优先读 env，未设则默认：

| 参数 | env 名 | 默认 | 注 |
|------|--------|------|-----|
| requestsPerMinute | `NIM_RPM` | **40** | v1.0.0 时代基线曾是 28；v3.8.x 时代已上调为 40。阶梯压测 45/50 须先实测 |
| concurrentRequests | `NIM_CONCURRENT` | 5 | |
| minTimeBetweenRequestsMs | `NIM_MIN_INTERVAL_MS` | 500 | |
| requestQueue 写入端点 | — | `PATCH /api/resilience` | |

> ⚠️ 旧 `AI_HANDOFF.md` §5 / `DECISIONS.md` D012 写 RPM=28 是 v1.0.0 基线，**已过期**，当前是 40。决策逻辑（"保守稳定优先于最大吞吐"）仍成立，基线值以本文为准。

## 4. Combo 与模型池

### Combo nim-pool（通用，round-robin）

`init-nim-keys.sh` 第 510-531 行创建，9 个模型：

```
minimaxai/minimax-m2.7
moonshotai/kimi-k2-thinking
moonshotai/kimi-k2.6
z-ai/glm-5.2
nvidia/nemotron-3-super-120b-a12b
qwen/qwen3-coder-480b-a35b-instruct
mistralai/mistral-small-4-119b-2603
mistralai/mistral-medium-3.5-128b
meta/llama-3.2-90b-vision-instruct
```

### Combo nim-codex（代码任务，context-relay）

`init-nim-keys.sh` 第 544-565 行创建，3 个模型（Key 耗尽轮转时自动生成上下文摘要注入下一 Key，适合 Codex CLI / 大型重构）：

```
qwen/qwen3-coder-480b-a35b-instruct
deepseek-ai/deepseek-v4-pro
mistralai/mistral-medium-3.5-128b
```

### 模型目录注册（`/api/provider-models`）

`init-nim-keys.sh` 第 469-507 行注册模型目录（首次初始化），含 nim-pool 全集 + 备用 `deepseek-ai/deepseek-v4-pro|flash`（不放入 nim-pool Combo）。

> ⚠️ 前缀规则不变：`/api/provider-models` 的 `modelId` **不带** `nvidia/` 前缀（如 `meta/llama-3.2-90b-vision-instruct`），Combo `models` **带** `nvidia/` 前缀失效——实际 init 直接用无前缀 `modelId` 在 combo models 里（如 `minimaxai/minimax-m2.7`，与 v1.0.0 时代 `nvidia/meta/...` 完整前缀写法不同）。需核实当前上游 combo 路由约定（v3.8.44 provider 命名变更）。

## 5. NIM 模型上架状态

### 5.1 已核验事实（实证级，非推断）

**`qwen/qwen3-coder-480b-a35b-instruct` 已于 2026-06-11 从 NIM 下架**。25 key 池对该模型请求全部返回 HTTP **410 Gone**（实证：上一会话 25-key 全量测得，非研究推断）。影响：

- nim-pool（§4）9 模型中 1 个已死 → round-robin 命中它时浪费一次轮转 + 一次 410 重试。
- nim-codex Combo（§4，3 模型之首）头号模型即此下架模型 → Codex/大型重构路径首选已坏，需尽快替换。
- 别名 `cq3c`（指向 `nvidia/qwen/qwen3-coder-480b`）已失效，待替换为可用模型。

**NIM 免费层隐藏上下文限制 ≈ 32K（未官方文档化）**。329 条消息长会话触发 502 风暴：25 key 全部返回 `Provider returned empty content`。此限是平台级，与模型标称窗口（128K/198K）无关 → 长会话必须切到非 NIM provider 或主动截断。

**RPM**：`init-nim-keys.sh:48` `_RPM=${NIM_RPM:-40}`（默认 40）。生产实测安全值 28，已通过 HF Space `NIM_RPM=28` env 覆盖生效（启动日志确认）。上游默认 `requestsPerMinute:60`（v3.8.44 resilience route.js，研究实测），与 init 本地默认 40 不同——init 的 40 是 OmniRoute 调 NIM 的对外节流，与上游内部 resilience 默认 60 是两层口径，不冲突。

**镜像版本固定**：Dockerfile `FROM diegosouzapw/omniroute:3.8.43`（`:latest` 有 uncaughtException bug，不可用）。

### 5.2 NIM API 鉴权形态

`Authorization: Bearer nvapi-<key>`（nvapi 前缀）。OmniRoute 注册 nvidia provider 时 `apiKey` 即此 nvapi 串，前缀一致性成立。`integrate.api.nvidia.com/v1/models` 为当前可用模型枚举端点（需有效 nvapi key）。

### 5.3 未核验范围（显式标注，待后续带 key 实测）

deep-research workflow（104 agent / 6h11m / 22 src / 25 verified / 8 confirmed）核验范围聚焦 **OmniRoute 上游**（发版线 v3.8.44、6 端点全在、env-bypass 被定位为 static fallback 未废弃），**未覆盖 NIM 各模型逐项上架状态**——`build.nvidia.com` 在研究侧被标 `unreliable / 0 claim`，本项目对其 WebFetch 亦被网络策略拦截（socket hang / 域名验证失败）。

故以下 nim-pool 其余 8 模型当前是否仍上架 / 改名 / 下架，**未核验**，需带 nvapi key 跑 `curl integrate.api.nvidia.com/v1/models` 与 init 注册集交叉比对：

| 模型 ID | 上架状态 |
|---|---|
| `minimaxai/minimax-m2.7` | 未核验 |
| `moonshotai/kimi-k2-thinking` | 未核验 |
| `moonshotai/kimi-k2.6` | 未核验 |
| `z-ai/glm-5.2` | 未核验（中文主力，32K 内可用） |
| `nvidia/nemotron-3-super-120b-a12b` | 未核验 |
| `mistralai/mistral-small-4-119b-2603` | 未核验 |
| `mistralai/mistral-medium-3.5-128b` | 未核验 |
| `meta/llama-3.2-90b-vision-instruct` | 未核验 |
| `qwen/qwen3-coder-480b-a35b-instruct` | 🔴 已下架（410，2026-06-11，实证） |

init 引用的模型集（§4）已在代码中注册，但"代码引用"≠"NIM 仍上架"。下架模型的注册条目不会自愈，需手动清理注册 + Combo + 别名。

## 6. gate.js 当前真态（46 行）与回归风险 ⚠️

gate.js 仅 46 行（`omn-merge/gate.js`），职责：

- `INTERNAL_PSK` 缺失即 fatal
- `OR_API_KEY`：env `OMNIROUTE_API_KEY` 优先（`.trim()`），回退读 `/data/.or-api-key`（try/catch 防 ENOENT），双缺即 fatal
- 对 `/v1*` 路径注入 `Bearer ${OR_API_KEY}`，前替换客户端 `Authorization`（去 `Bearer ${INTERNAL_PSK}`）
- `/healthz` 代理上游 `/api/monitoring/health`

### 关键回归风险：v1.0.0 时代 PATCH-GATE 补丁全丢

v1.0.0 时代 gate.js 191 行含 4 个防回归补丁，当前 46 行版**全部丢失**：

| 补丁 | 旧逻辑 | 当前状态 | 风险 |
|------|--------|----------|------|
| PATCH-GATE-001 | `KNOWN_COMBOS = new Set(['nim-pool','nim-pool-lab'])` 识别 combo | **无** | — |
| PATCH-GATE-002 | `/v1/chat/completions` + `/v1/messages` 强制 `stream=false` | **无** | combo streaming 触发 |
| PATCH-GATE-003 | Combo 删 `stream_options`、直连设 `stream=true` + `stream_options` | **无** | NIM 400 `[400] Validation: 'stream_options' only allowed when 'stream' is true` |
| 工程层 | raw body 转发、Header 双清、防模板吞噬 | **无** | JSON 精度/Header 泄露/日志不完整 |

**源码查证（2026-07）**：上游 `src/sse/handlers/chat.ts:256` 注释 `// stream value (true or false) always wins`，上游**尊重客户端 stream 值、不替 combo 强制 stream=false**。`stream_options` 在上游 chat/completions 主路径**不做净身**（仅 codex-ws/dashboard/translator 非核心处出现）。

即上游**不自愈** combo streaming → NIM 400 路径。当前 nim-pool/nim-codex 在用且 gate 裸转 → **stream_options 400 风险当下活**，Hermes/OpenAI SDK 自动加 `stream_options` 不带 `stream:true` 即犯。

### `/v1/messages` 端点（Claude-compatible）

存在（`src/app/api/v1/messages/route.ts`），走 `handleChat` 同核 chat completions。流式决策按 **`Accept: text/event-stream` header**（非 body `stream` 字段），`withEarlyStreamKeepalive` + `ANTHROPIC_PING_FRAME` 保活。gate 强制非流的旧法（改 body stream=false）对 `/v1/messages` **可能不够**——需动 Accept header。

### 行动项

回填 PATCH-GATE 需**先重验**：上游 v3.8.4x combo streaming 实际触发的错误名（旧 `ALL_ACCOUNTS_INACTIVE` 上游已重命名为 `noActiveProviders` / `noActiveConnectionsInGroup` 系列）。不能照搬 v1.0.0 时代补丁逻辑，需按源码新约定改写（尤其 `/v1/messages` 的 Accept header 策略）。

## 7. Memory / Skills / Compression / Thinking config（v3.8.x 新增）

init `PATCH /api/settings` + `PUT /api/settings/memory` 配置（init 行 329-388）：

- **Memory legacy**：`memoryEnabled=true, memoryStrategy=hybrid, memoryMaxTokens=2000, memoryRetentionDays=30, skillsEnabled=true`（`skillsEnabled=true` 启用内置 Skills：file_read/file_write/http_request/web_search）
- **Memory extended**（`PUT /api/settings/memory`）：`embeddingSource=remote, embeddingProviderModel=voyage-ai/voyage-3, staticEnabled=false, transformersEnabled=false`（remote embedding 经 Voyage AI）
- **Compression + Thinking**：`compression.enabled=true, defaultMode=stacked, autoTriggerTokens=12000`（`NIM_COMPRESS_THRESHOLD` 可覆盖）；`thinkingBudget.enabled=true, mode=adaptive, maxTokens=8000`
- **全局路由**：`fallbackStrategy=round-robin, stickyRoundRobinLimit=1, requestBodyLimit=10485760`

## 8. 持久化（Litestream + HF Dataset）

- **Litestream v0.5.9**（`litestream.yml`）：R2 复制 `storage.sqlite`，`sync-interval=10s`、`snapshot-interval=1h`、**`auto-recover: true`**（遇 LTX 错误自动重置本地追踪状态，HF Space 免费层 OOM Kill 后自愈）
- entrypoint：启动前 `litestream restore -if-replica-exists`，启动后后台 `litestream replicate`
- **HF Dataset 快照**（`nomke/omni-data`，README frontmatter 声明，似 private）：init 调 `GET /api/settings/export-json` 拆分 5 子文件上传，**纯冷备展示**，恢复链路仍赖 R2 restore（不接 dataset 恢复）
  - export-json 字段已对齐上游 v3.8+（`apiKeys`/`providerConnections`/`providerNodes`/`settings`/`combos`）
  - **明文凭证 del**：`apiKeys[].key`（OR_KEY）、`providerConnections[].credentials`（NIM key，上游 `getProviderConnections` 经 `decryptConnectionFields` 解密返明文）在 init jq 阶段即 `del`，防 dataset 误转 public / 协作 token 读泄露；保留 name/scopes/key_hash/provider/id 元数据
  - telemetry `del`（#2125，上游已默认排，本地冗余但无害）

## 9. CF Worker 告警（cf-worker/index.js）

- `CLIENT_TOKEN` 校验（缺即 401）
- Header 清理（cf-* / x-forwarded-* / x-real-ip / true-client-ip）
- 429/5xx 窗口统计（STATE KV，`WINDOW_TTL=180s`）：
  - `WARN_429_THRESHOLD=5`：5 次 429 触发 Wecom + Resend 邮件告警（去重 TTL 24h）
  - `CRITICAL_MIN_SAMPLES=20` + `CRITICAL_5XX_RATIO=0.5`：≥20 样本且 5xx 占比 >50% 触发 CRITICAL 告警
- `UPSTREAM_BASE` 缺即 500；`INTERNAL_PSK` 缺即 500（不转发）
- `/healthz` 回调 gate 上游
- 版本 `nim-worker-v1.3.0-final`

## 10. 错误名映射（旧 doc → 上游现名）

| 旧（v1.0.0 时代 docs） | 现上游 v3.8.x | 注 |
|------------------------|--------------|-----|
| `ALL_ACCOUNTS_INACTIVE` | `noActiveProviders` / `noActiveConnectionsInGroup` | 上游 i18n 重命名；底层风险路径未变 |
| `/v1/messages` 不存在（README 曾不提） | `src/app/api/v1/messages/route.ts` 真存 | 走 handleChat，Accept header 决流式 |

## 11. 上游 v3.8.44 关键演进（2026-07，影响本仓的点）

- **Auto-Combo per-request headers**：`X-OmniRoute-Mode` / `X-OmniRoute-Budget` per-request 重写 combo 评分 + USD 预算（v3.8.44）— 可用于 nim-codex 成本上限
- **Quota 节流**：`OMNIROUTE_QUOTA_FETCH_MIN_INTERVAL_MS`（v3.8.44，Codex quota 网络调用节流防 token 收回）
- **`/v1/ocr`** Mistral OCR 新端点（v3.8.44）
- **`/api/discovery/*`** provider 发现工具（loopback-only，v3.8.44）
- **Bifrost/Mux 一等公民** `/api/services/` 嵌入式服务生命周期（loopback-only）
- **Claude translator 修** `messages: at least one message is required`（v3.8.41，只含 system/developer 时补 user turn）
- **`OMNIROUTE_RELAY_BACKEND`=ts|bifrost|auto** 可选 relay 后端（v3.8.41）
- **V8 heap auto-cal**：默认 ~35% RAM，clamped `[512,4096]`，`OMNIROUTE_MEMORY_MB` 优先（v3.8.39）。entrypoint 现写死 `NODE_OPTIONS=--max-old-space-size=1024`，与环境默认可能低——可评估放开让上游 auto-cal
- **`GET /api/system/version`**（v3.8.39）免 LOCAL_ONLY_API_PREFIXES
- **LLM-tier compression engine + typed memory decay + compression circuit-breaker**（v3.8.43，opt-in default-off）

## 12. 当前下一步落地清单

源自上游查证（非旧 docs）。优先级：

1. **gate.js PATCH-GATE 回填**（#6）——上游不自愈 combo streaming，stream_options 400 风险当下活。需先重验上游实际错误名 + `/v1/messages` Accept header 策略再回填
2. docs 活族隔离补全（本批）
3. init `/api/keys` POST 清理为只传 `{name}`（`expiresAt` 上游 schema 不接但 Zod 非 strict 静默 strip，冗余无害，纯洁收尾）
4. init export-json telemetry `del` 清理（#2125 上游已默认排，本地 del 冗余，可去，但保留兼容旧版无害）
5. NIM 模型池实际核验（§5：deep-research 已收口上游视角，未覆盖 NIM 各模型上架；待带 nvapi key 跑 `curl integrate.api.nvidia.com/v1/models` 交叉比对，qwen3-coder-480b 已实证下架需先替换 + 清 nim-codex Combo + cq3c 别名）
6. 评估放开 entrypoint `--max-old-space-size=1024` 让上游 V8 heap auto-cal（§11）
7. 评估用 v3.8.44 auto-combo per-request headers nim-codex 成本上限

---

## 维护规约

- 本文件随上游演进 / 代码变更更新，是当前真态 SSOT
- 活文档（AI_HANDOFF/EXPERIENCE/DECISIONS/TROUBLESHOOTING）改当前实态时**同步更新本文**
- 历史快照（RELEASE_NOTES_v1.0.0/VALIDATION/implementation-log）只读不改
- 改源码后跑 `git diff` 确认本文引用的行号/真值仍对
