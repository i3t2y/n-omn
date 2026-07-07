---

# Current State — v3.8.x 实态快照

> **快照日期**：2026-07-07
> **上游版本**：OmniRoute v3.8.44（2026-07-04 最新 release）
> **当前部署版本**：v3.8.43（Dockerfile `FROM diegosouzapw/omniroute:3.8.43`）
> **当前部署分支**：本地 `main`（= 远端 `nomn/main`），init 脚本 v3.3.0
>
> 本文为当前实际代码态的真态快照，随上游演进更新。历史快照文档（RELEASE_NOTES_v1.0.0 / VALIDATION / implementation-log）只读不改。

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
  ├─ OR_API_KEY 经 env-bypass 放行
  ├─ provider pool / combo routing / resilience / circuit breaker
  └─ 25 个 NIM key 轮询
NVIDIA NIM (integrate.api.nvidia.com)
```

三层鉴权，每层只看自己 token，客户端永远看不到 OR_API_KEY。

## 2. env-bypass 跨重建固定化

需 HF Space 配置 Secret `OMNIROUTE_API_KEY`（≥32 字节强随机串）。该值即合法上游 key，无需写入 sqlite、不依赖 Litestream restore、跨 HF Space 重建不变。

源码查证（`src/lib/db/apiKeys.ts`）：`isConfiguredEnvApiKey()` 在 lifecycle 校验之前 return，env-key 不受 sqlite 行失效牵连。`getApiKeyMetadata` 给 env-key 合成 `id:"env-key"`、`scopes:["manage"]`。entrypoint.sh 透传该 env；gate.js 优先读 env 回退读文件；init 检测 env 存在时跳过 `/api/keys` 创建段。

## 3. Resilience / 配置参数

`init-nim-keys.sh` 顶部动态参数，优先读 env，未设则默认：

| 参数 | env 名 | 默认 | 生产值 | 注 |
|------|--------|------|--------|-----|
| requestsPerMinute | `NIM_RPM` | 40 | 28（HF env 覆盖） | 生产实测安全值 28 |
| concurrentRequests | `NIM_CONCURRENT` | 5 | 5 | |
| minTimeBetweenRequestsMs | `NIM_MIN_INTERVAL_MS` | 500 | 500 | |
| maxBodySizeMb | — | 1 | 1 | 字段名从 requestBodyLimit 纠正，单位从 bytes 改为 MB。schema `[MIN=1, MAX=500]`，取下限 1MB 作前置 413 拦截 |
| requestRetry | — | 2 | 2 | 空/502 有限重试 |
| maxRetryIntervalSec | — | 5 | 5 | |
| fallbackStrategy | — | round-robin | round-robin | |
| stickyRoundRobinLimit | — | 1 | 1 | |

### 3.1 per-model token limits override（502 风暴核心修复）

NIM 标称 128K 上下文，实测 32K token 处静默截断（返回 HTTP 200 + 空 SSE 流）。此前压缩引擎按 128K 标称值工作，不压缩超限请求，触发 502 风暴。

init 脚本直接写 SQLite `model_context_overrides` 表（source='manual'，real_context=32768），让压缩引擎据真实 32K 上限算压缩目标。manual override 永不被 24h contextWindowReconciler 覆盖。无 HTTP API 可写 manual override，故直接操作 DB。

```sql
INSERT OR REPLACE INTO model_context_overrides
  (provider, model_id, real_context, source, refreshed_at)
VALUES
  ('nvidia', '<model_id>', 32768, 'manual', datetime('now'));
-- 10 个模型
```

实测日志验证：`per-model context override: 10 applied, 0 failed (real_context=32768)`

### 3.2 Compression 配置（端点纠正）

上游 v3.8.4x `compressionSettingsUpdateSchema` 为 `.strict()`，多余字段返回 400。此前 `PATCH /api/settings` + `compression.{...}` 嵌套格式被拒，压缩从未生效。

纠正为独立端点 `PUT /api/settings/compression`，扁平 body：

```json
{"enabled": true, "defaultMode": "stacked", "autoTriggerTokens": 12000}
```

`autoTriggerTokens=12000`：请求 token 超 12000 时触发 proactive compression（非 32768，留足压缩空间）。

### 3.3 Thinking Budget 配置（端点纠正）

上游 v3.8.4x 将 thinking-budget 拆为独立端点 `PUT /api/settings/thinking-budget`。字段从旧 `{enabled, maxTokens}` 变为 `{mode, baseBudget}`。旧拼字段静默 WARN 失败。

纠正后：

```json
{"mode": "adaptive", "baseBudget": 8000}
```

### 3.4 NODE_OPTIONS 4GB 堆上限

entrypoint.sh 此前 line 47 硬编码 `--max-old-space-size=1024`（1GB），覆盖了 line 114 gate 进程的 4096。导致 OmniRoute 主进程处理大请求时频繁 OOM。统一为 4096。

### 3.5 domain_circuit_breakers 持久化清除（DEGRADED 修复）

见 §13。

## 4. Combo 与模型池

### Combo nim-pool（通用，round-robin）

init 脚本首次初始化时创建，8 个模型（已移除 kimi-k2-thinking，替换 qwen3-coder-480b 为 qwen3-next-80b）：

```
minimaxai/minimax-m2.7
moonshotai/kimi-k2.6
z-ai/glm-5.2
nvidia/nemotron-3-super-120b-a12b
qwen/qwen3-next-80b-a3b-instruct
mistralai/mistral-small-4-119b-2603
mistralai/mistral-medium-3.5-128b
meta/llama-3.2-90b-vision-instruct
```

增量模式下由巡检函数（§14）检测下架模型并通过 `PUT /api/combos/{id}` 修复。

### Combo nim-codex（代码任务，context-relay）

3 个模型（头号 target 已替换为 qwen3-next-80b）：

```
qwen/qwen3-next-80b-a3b-instruct
deepseek-ai/deepseek-v4-pro
mistralai/mistral-medium-3.5-128b
```

### 模型目录注册

10 个模型注册到 `/api/provider-models`：nim-pool 全集 8 个 + 备用 `deepseek-ai/deepseek-v4-pro|flash`。

## 5. NIM 模型上架状态（已全量核验）

通过巡检函数 curl `integrate.api.nvidia.com/v1/models`（2026-07-07 实证）：

| 模型 ID | 上架状态 | 说明 |
|---------|---------|------|
| `minimaxai/minimax-m2.7` | ✅ available | |
| `moonshotai/kimi-k2.6` | ✅ available | |
| `z-ai/glm-5.2` | ✅ available | 中文主力 |
| `nvidia/nemotron-3-super-120b-a12b` | ✅ available | |
| `qwen/qwen3-next-80b-a3b-instruct` | ✅ available | 新增替换 qwen3-coder-480b |
| `mistralai/mistral-small-4-119b-2603` | ✅ available | |
| `mistralai/mistral-medium-3.5-128b` | ✅ available | |
| `meta/llama-3.2-90b-vision-instruct` | ✅ available | |
| `deepseek-ai/deepseek-v4-pro` | ✅ available | |
| `deepseek-ai/deepseek-v4-flash` | ✅ available | |
| `qwen/qwen3-coder-480b-a35b-instruct` | 🔴 已下架 | 410 Gone（2026-06-11） |
| `moonshotai/kimi-k2-thinking` | 🔴 已下架 | 不在 /v1/models 列表 |

NIM `/v1/models` 共返回 121 个模型。

**NIM 免费层隐藏上下文限制 ≈ 32K**（未官方文档化）。超限请求返回 HTTP 200 + 空 SSE 流，不返回 413。此限是平台级，与模型标称窗口无关。

## 6. gate.js 当前真态（46 行）与回归风险

gate.js 仅 46 行，职责：INTERNAL_PSK 校验、OR_API_KEY 注入、/healthz 代理。

v1.0.0 时代 PATCH-GATE 补丁全丢，stream_options 400 风险当下活。回填需先重验上游 v3.8.4x combo streaming 实际错误名（旧 `ALL_ACCOUNTS_INACTIVE` 已重命名为 `noActiveProviders` / `noActiveConnectionsInGroup`）。不能照搬旧补丁逻辑。

## 7. Memory / Skills / Compression / Thinking config

init 配置（已纠正端点）：

- **Memory legacy**（`PATCH /api/settings`）：`memoryEnabled=true, memoryStrategy=hybrid, memoryMaxTokens=2000, memoryRetentionDays=30, skillsEnabled=true`
- **Memory extended**（`PUT /api/settings/memory`）：`embeddingSource=remote, embeddingProviderModel=voyage-ai/voyage-3, staticEnabled=false`
- **Compression**（`PUT /api/settings/compression`）：`enabled=true, defaultMode=stacked, autoTriggerTokens=12000`（端点从 PATCH 纠正为 PUT，body 从嵌套改为扁平）
- **Thinking Budget**（`PUT /api/settings/thinking-budget`）：`mode=adaptive, baseBudget=8000`（端点从 PATCH /api/settings 拆出，字段从 {enabled,maxTokens} 改为 {mode,baseBudget}）
- **全局路由**（`PATCH /api/settings`）：`fallbackStrategy=round-robin, stickyRoundRobinLimit=1, requestRetry=2, maxRetryIntervalSec=5, maxBodySizeMb=1`（字段名从 requestBodyLimit 纠正，单位从 bytes 改为 MB）

> ⚠️ Memory legacy 段字段名可能已 schema 漂移，应走 `PUT /api/settings/memory` 独立端点。当前 WARN 失败但不阻塞。

## 8. 持久化（Litestream + HF Dataset）

- **Litestream v0.5.9**：R2 复制 `storage.sqlite`，`sync-interval=10s`，`auto-recover: true`。entrypoint 启动前 `litestream restore -if-replica-exists`，启动后后台 `litestream replicate`。
- **HF Dataset 快照**（`nomke/omni-data`）：init 调 `GET /api/settings/export-json` 拆分 5 子文件上传，纯冷备。明文凭证（apiKeys[].key、providerConnections[].credentials）在 jq 阶段 del。

## 9. CF Worker 告警

版本 `nim-worker-v1.3.0-final`。CLIENT_TOKEN 校验、Header 清理、429/5xx 窗口统计（WARN_429_THRESHOLD=5、CRITICAL_MIN_SAMPLES=20 + CRITICAL_5XX_RATIO=0.5）、Wecom/Resend 告警。

## 10. 错误名映射

| 旧（v1.0.0 时代） | 现上游 v3.8.x | 注 |
|-------------------|--------------|-----|
| `ALL_ACCOUNTS_INACTIVE` | `noActiveProviders` / `noActiveConnectionsInGroup` | 上游 i18n 重命名 |
| `/v1/messages` 不存在 | `src/app/api/v1/messages/route.ts` 真存 | 走 handleChat，Accept header 决流式 |

## 11. alias 矩阵现状

### 核心层 7 个

| alias | 模型 | 场景 | 32K 适用性 |
|-------|------|------|-----------|
| cq3n | qwen3-next-80b-a3b-instruct | 代码编程 | ✅ 77+ msgs 验证通过（4392ms 实测） |
| cd4p | deepseek-v4-pro | 深度代码/推理 | ✅ |
| ck26 | kimi-k2.6 | 长文本/小说 | ✅ |
| cm27 | minimax-m2.7 | 创意写作 | ✅ |
| cn3s | nemotron-3-super-120b-a12b | 深度推理 | ✅ |
| cl9v | llama-3.2-90b-vision-instruct | 多模态/视觉 | ✅ |
| cg52 | glm-5.2 | 中文通用 | ⚠️ 35 tools 场景易超限触发 DEGRADED |

### 扩展层 8 个

cmtm → mistral-medium-3.5-128b、cmts → mistral-small-4-119b-2603、cd4f → deepseek-v4-flash、cyil → 01-ai/yi-large、cm30 → minimax-m3、cgpt → openai/gpt-oss-120b、cml3 → mistral-large-3-675b-instruct-2512、cn3u → nemotron-3-ultra-550b-a55b。

**使用建议**：Claude Code 编程场景用 cq3n，中文对话/创意场景用 cg52（无 tools 或少 tools 时）。

## 12. 502 风暴消除验证记录

per-model limits + 两阶段压缩组合方案实战验证通过：

| 消息数 | 原始 token | proactive 压缩后 | 压缩率 | 耗时 | 结果 |
|--------|-----------|-----------------|--------|------|------|
| 2 | 31596 | 31589（未触发） | 0% | 6425ms | ✅ |
| 6 | 35607 | ~31505 | 11% | 3860ms | ✅ |
| 35 | 30672 | ~32400 | — | 6126ms | ✅ |
| 50 | 36396 | ~32150 | 12% | 8008ms | ✅ |
| 77 | 54324 | ~32250 | 41% | 5339ms | ✅ |

两阶段压缩流程：stacked（caveman-rules/rtk-filter）→ proactive context（trim_tools/compress_thinking/purify_history）。proactive compression 将可压缩部分稳定压到 ~5000 token，保留不可压缩部分（35 tools 定义 + system prompt + 最近消息）约 27000 token。

## 13. DEGRADED 持久化问题与修正

### 问题

OmniRoute circuit breaker 有四种状态：CLOSED → DEGRADED → OPEN → HALF_OPEN → CLOSED。DEGRADED 状态持久化到 SQLite `domain_circuit_breakers` 表（源码 `src/lib/db/domainState.ts` line 557-568），通过 Litestream 同步到 R2，重启后恢复。

per-model limits 修正后，请求被压缩到 32K 边界附近。大部分成功，少数压缩后仍超限（如 34323 token）。NIM 对"刚好超限"的请求返回 HTTP 200 + 空 SSE 流，OmniRoute 分类为 function 级别 DEGRADED（持久化到 DB，不自动恢复）。DEGRADED 后请求被拒绝（`DEGRADED function cannot be invoked`），无论请求大小。

### 修正

init 脚本在 circuit breaker reset API 之后增加 DB 级别清除：

```bash
echo "[init] Clearing persisted circuit breaker states from DB..."
sqlite3 /data/storage.sqlite "DELETE FROM domain_circuit_breakers;" 2>/dev/null || true
echo "[init] Persisted breaker states cleared"
```

`POST /api/resilience/reset` 只清除内存计数器，不清除 DB 持久化。`DELETE FROM domain_circuit_breakers` 清空整张表，让所有 breaker 从 CLOSED 重新开始。

### 局限性

此清除只在 init（容器启动/重建）时执行一次。运行期间新触发的 DEGRADED 仍会持久化，直到下次重建。彻底避免需 gate.js 层预拦截（超限请求不发送给 NIM）或引入 128K provider 兜底。

## 14. 巡检函数 check_nim_model_health

### 设计

init 脚本中的 `check_nim_model_health()` 函数，在增量模式（非首次初始化）时执行。curl NIM `/v1/models` API，交叉比对 10 个 PRODUCTION_MODELS，将不在可用列表中的模型写入 `/tmp/nim-deprecated.txt`。后续增量 Combo 修复逻辑读取该文件，通过 `PUT /api/combos/{id}` 剔除下架模型。

保护逻辑：API 返回 <5 个模型时跳过巡检（防止端点故障误判）。

### jq 匹配 bug 修复

初始版本使用 `.data[]?.id == $m`，对 121 个元素产生 121 个 true/false 输出，`jq -e` 只检查最后一个——导致所有模型被误判 DEPRECATED，Combo 核心模型被错误剔除。

修复为 `any(.data[]?.id == $m; .)`，将 121 个比较聚合为单一布尔值。

### 验证

```
[init] check_nim_model_health: 0 deprecated, 121 available on NIM
[init] Incremental: no deprecated models, Combos OK.
```

## 15. commit 记录

| commit | 内容 |
|--------|------|
| 34eba8e | init 脚本配置优化（per-model limits + compression/thinking-budget 端点纠正 + maxBodySizeMb） |
| 3a99dd3 | entrypoint 统一 NODE_OPTIONS 4GB 堆上限 |
| 7af84e1 | 增量模式 Combo 修复 + 巡检函数调用 + PUT /api/combos/{id} |
| af446a4 | grep -qx 改 -Fxq 与全局字面匹配一致 |
| 94c768f | curl 兜底 + PUT HTTP code 校验 + 空集 skip |
| (后续1) | domain_circuit_breakers 持久化状态清除 |
| (后续2) | 补全 check_nim_model_health 函数定义 + 模型列表更新 |
| (后续3) | jq any() 匹配修复 |

## 16. 已知问题

- **ProxyFetch ECONNREFUSED 127.0.0.1:20129**：每请求 6 次无效连接（3 组 × Undici + native），端口 20129 无服务监听。第三层直连 fallback 成功，非阻塞。修复需定位 OmniRoute 配置中引用 20129 的位置。
- **memory legacy 段字段名漂移**：应走 `PUT /api/settings/memory` 独立端点。当前 WARN 失败但不阻塞。
- **HF Space env NIM_COMPRESS_THRESHOLD=8000**：init 已 API 硬编码 12000 覆盖，env 值建议对齐消除混淆。
- **domain_circuit_breakers 残留 2 条过期 override**：kimi-k2-thinking 和 qwen3-coder-480b 的 manual override 仍在 DB（INSERT OR REPLACE 不删除旧行），不影响功能。
- **nim-pool Combo 被巡检 jq bug 错误更新**：核心模型曾被剔除，需清空 R2 重新首次初始化修复。日常通过单模型 alias 调用不受影响。

## 17. 待办（按优先级）

1. **gate.js PATCH-GATE 回填**：上游不自愈 combo streaming，stream_options 400 风险当下活。需先重验上游实际错误名再回填。
2. **清空 R2 修复 nim-pool Combo**：Cloudflare Dashboard 删除 omniroute-data/db/ 下所有文件 → HF Space Restart → first-time setup 用正确 8 模型重建 Combo。
3. **Groq 128K 兜底**：35 tools 不可压缩部分约 27K，NIM 32K 留给对话空间不足 6K。引入 Groq（llama-3.3-70b-versatile，128K 真实上下文）作为 NIM fallback，根治长会话场景。
4. **gate.js token 估算预拦截**：请求发送前估算 token 数，超 32K 直接返回 413，不发送给 NIM，从根本上避免运行期间 DEGRADED。
5. **ProxyFetch 20129 排查**：定位 OmniRoute 配置中引用 20129 端口的位置并移除。
6. **memory legacy 段修复**：字段名纠正，走独立端点。
7. **init export-json telemetry del 清理**：上游 #2125 已默认排，本地冗余可去。

## 18. 上游 v3.8.44 关键演进

- Auto-Combo per-request headers（`X-OmniRoute-Mode` / `X-OmniRoute-Budget`）
- Quota 节流（`OMNIROUTE_QUOTA_FETCH_MIN_INTERVAL_MS`）
- `/v1/ocr` Mistral OCR 端点
- `/api/discovery/*` provider 发现工具（loopback-only）
- Bifrost/Mux 嵌入式服务生命周期
- Claude translator 修 `messages: at least one message is required`
- V8 heap auto-cal（默认 ~35% RAM，clamped [512,4096]，`OMNIROUTE_MEMORY_MB` 优先）
- LLM-tier compression engine + typed memory decay + compression circuit-breaker（opt-in default-off）

## 维护规约

- 本文件随上游演进 / 代码变更更新，是当前真态 SSOT
- 改源码后跑 `git diff` 确认本文引用的行号/真值仍对
- Claude Code 编程场景用 cq3n，不用 cg52
- 运行期间出现 DEGRADED 时，Restart HF Space 即可清除
- 修改 init 脚本后 `git push nomn main` 触发 HF Space 自动重建验证

---

粘贴保存后执行：

```bash
cd /home/laisi/omn-merge
git add docs/CURRENT_STATE_v3.8.md
git commit -m "docs: SSOT 同步 v3.8 当前实态（2026-07-07）

- §3: 新增 per-model limits / compression 端点纠正 / thinking-budget / maxBodySizeMb / NODE_OPTIONS
- §4: Combo 模型列表更新（移除 kimi-k2-thinking，替换 qwen3-coder-480b）
- §5: 全量核验 10 可用 + 2 下架
- §7: 端点纠正记录
- §11: 新增 alias 矩阵
- §12: 新增 502 风暴消除验证记录
- §13: 新增 DEGRADED 持久化问题与修正
- §14: 新增巡检函数 check_nim_model_health
- §15: 新增 commit 记录
- §16-17: 已知问题与待办更新"
git push nomn main
```

SSOT 更新 + push 完成后，带着此前生成的交接文档 + 最新仓库直接交给强模型即可。交接指令用上一轮我给的那份。

*内容由 AI 生成仅供参考*