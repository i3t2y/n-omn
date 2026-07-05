# Troubleshooting

本文档记录 `nim-omniroute-gateway` 已遇到的问题、根因和处理方法。这里不写架构决策，架构决策见 `docs/DECISIONS.md`。

## 1. gate 日志显示端口或 target 不完整

### 现象

日志中出现类似：

```text
listening :7860
proxying :20128
```

而不是完整显示：

```text
listening on 0.0.0.0:7860
proxying to 127.0.0.1:20128
```

### 根因

文档渲染或复制过程中 JavaScript 模板字符串变量被吞噬。

### 处理

关键路径不要使用模板字符串，改用字符串拼接。

### 结论

防吞噬版是当前 GitHub `v1.0.0` 基线的一部分，不要回退到旧版 gate.js。

## 2. `nim-pool` 请求被路由到 openai

### 现象

请求 `nim-pool` 时日志出现：

```text
ROUTING nim-pool → openai/nim-pool
No credentials for provider: openai
```

### 根因

Combo 创建时使用了错误字段：

```json
{
  "providers": ["nvidia"]
}
```

这会创建空壳 Combo。空 Combo 可能触发默认 provider 路由，最终落到 openai。

### 处理

Combo 必须使用 `models` 字段，并使用完整模型路由键：

```json
{
  "name": "nim-pool",
  "strategy": "round-robin",
  "models": [
    "nvidia/meta/llama-3.3-70b-instruct",
    "nvidia/z-ai/glm-5.1",
    "nvidia/qwen/qwen3-coder-480b-a35b-instruct"
  ]
}
```

## 3. Dashboard 中 `nim-pool` 显示“没有模型”

### 现象

实际请求能成功，但 Dashboard 的 Combo 卡片显示没有模型。

### 根因

Combo 路由和 Dashboard model catalog 是两层系统。Combo 可以直接用完整模型路由键成功转发，但 Dashboard 卡片显示依赖 `/api/provider-models` 中的模型目录。

### 处理

为每个生产模型注册 provider model。

示例：

```bash
curl -sS -X POST "<OMNI_BASE_URL>/api/provider-models" \
  -H "Content-Type: application/json" \
  -H "Cookie: auth_token=<AUTH_TOKEN>" \
  -d '{
    "provider": "nvidia",
    "modelId": "meta/llama-3.3-70b-instruct",
    "modelName": "Llama 3.3 70B Instruct (NIM)"
  }'
```

注意：

- `provider` 填 `nvidia`。
- `modelId` 不带 `nvidia/` 前缀。
- Combo 里的 `models` 要带 `nvidia/` 前缀。

## 4. `Provider returned empty content`

### 现象

Dashboard provider test 出现：

```text
Provider returned empty content
```

### 判断

这不等同于：

- API Key 失效
- gate.js 故障
- OmniRoute 崩溃
- Combo 一定不可用

### 常见原因

- 上游模型返回空内容。
- Provider test 使用的模型与生产模型不同。
- 模型响应格式不符合 OmniRoute 当前解析路径。
- 刚做完大量测试，上游处于短暂压制或冷却。

### 处理

不要连续点击 25 个 provider 的重新测试。

推荐流程：

1. 停止全量 retest。
2. 等待 90 到 120 秒。
3. 刷新 Dashboard。
4. 只用生产 `nim-pool` 执行 `/v1/chat/completions`。
5. 观察是否返回非空 token。

## 5. provider 显示被限流几十秒

### 现象

Dashboard 显示：

```text
被限流 3s
被限流 21s
被限流 45s
```

### 判断

几十秒级限流是保护机制，不是故障。

### 处理

等待倒计时自然恢复。不要在冷却期间连续 retest。

### 需要排障的情况

只有以下情况才视为异常：

- 限流长时间不消失。
- 大面积 provider disconnected。
- 大量 invalid key。
- 生产 3 模型连续 502/504。
- reset circuit breaker 后仍无法恢复。

## 6. DeepSeek / MiniMax 长时间 504

### 现象

部分模型请求卡住，最后 504，可能持续数分钟。

### 根因

这是模型或上游稳定性问题，不是 gate 主故障。

### 处理

不要放入生产 `nim-pool`。保留在 `nim-pool-lab` 观察。

## 7. Kimi 返回 200 但 0 token

### 现象

请求看似成功，但没有有效输出。

### 判断

这类 success-shaped failure 不适合生产池。

### 处理

从生产 `nim-pool` 移除，只保留在实验池。

## 8. `stream:false` 是否会导致格式错误

### 结论

不会。`stream:false` 是生产请求的推荐字段。

### 原因

它用于避免 Combo 或上游 SSE 响应被客户端误当普通 JSON 解析。

## 9. Circuit breaker OPEN

### 现象

部分 provider 或模型短期内持续失败，后续请求被阻断。

### 处理

先确认上游模型真的可用，再重置：

```bash
curl -sS -X POST "<OMNI_BASE_URL>/api/resilience/reset" \
  -H "Cookie: auth_token=<AUTH_TOKEN>"
```

不要在上游仍不可用时反复 reset，否则会制造更密集的失败。

## 10. 什么时候认为系统是健康的

满足以下条件即可认为生产入口健康：

- `/healthz` 返回 200。
- `/api/monitoring/health` 返回可用状态。
- 大多数 provider connected。
- provider protected 生效。
- `nim-pool` 连续请求能返回非空 token。
- 没有大面积 invalid key。
- 没有长期 circuit breaker open。
```

原因：把踩坑记录从 README 中剥离，形成可检索的故障手册。  
实测证据：`1.3.0.txt` Line 6102 记录 `nim-pool` 被误解析成 openai；Line 6179 记录空 Combo 问题；Line 7194 记录 `models` 为空；Line 7593 记录正确路由成功；Line 9163 记录模型目录显示问题根因。

## 11. `stream_options` 400 错误

### 现象

请求 OmniRoute 直连模型时返回：

```text
[400]: Validation: The 'stream_options' field is only allowed when 'stream' is set to true.
```

即使用户没有显式设置 `stream_options`，也可能出现此错误。

### 根因

OpenAI SDK（以及 Hermes Agent 等使用该 SDK 的客户端）会在请求中自动添加 `stream_options` 字段用于获取 token 用量统计，但不一定设 `stream: true`。

NVIDIA NIM API 比 OpenAI API 更严格：`stream_options` **必须**与 `stream: true` 共存。

请求流：
```
Client 发送 { stream_options: {include_usage: true}, stream: false }
→ gate.js 对 Combo 强制 stream=false（正确行为）
→ 但 stream_options 残留
→ NIM 拒绝 stream_options + stream:false 组合
→ 400 错误
```

### 处理

已通过 PATCH-GATE-003（gate.js 第 150-161 行）自动处理：

- **Combo 模型**：删除 `stream_options`，保持 `stream=false`（防 ALL_ACCOUNTS_INACTIVE）
- **直连模型**：设置 `stream=true`，保留 `stream_options`（支持 usage tracking）

如果仍有问题，检查：
1. gate.js 是否为最新版本（包含 PATCH-GATE-003）
2. HF Space 是否已重新部署
3. 是否有新的 Combo 未加入 `KNOWN_COMBOS`

### 验证命令

```bash
# 测试直连模型 + stream_options
curl -s -X POST "$ENDPOINT/v1/chat/completions" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"model":"nvidia/qwen/qwen3-coder-480b-a35b-instruct","messages":[{"role":"user","content":"hi"}],"max_tokens":10,"stream_options":{"include_usage":true}}'
# 应返回 200 + SSE 格式响应

# 测试 Combo 模型 + stream_options
curl -s -X POST "$ENDPOINT/v1/chat/completions" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"model":"nim-pool","messages":[{"role":"user","content":"hi"}],"max_tokens":10,"stream_options":{"include_usage":true}}'
# 应返回 200 + JSON 格式响应（stream_options 已被删除）
```

---
