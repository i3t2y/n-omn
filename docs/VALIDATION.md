# Validation Record

> ⚠️ **历史快照**（v1.0.0, 2026-04-26 当期实测证据），**勿改**（正文是 v1.0.0 当时跑通的实测记录，改则证据失真）。当前真态见 [`docs/CURRENT_STATE_v3.8.md`](CURRENT_STATE_v3.8.md)。

2026-04-26 实验模型单测结果：

以下模型在 70 秒 curl 超时窗口内均未返回任何 HTTP 响应，表现为 HTTP=000、0 bytes received：

- nvidia/deepseek-ai/deepseek-v4-pro
- nvidia/deepseek-ai/deepseek-v4-flash
- nvidia/minimaxai/minimax-m2.7
- nvidia/moonshotai/kimi-k2.5

结论：
上述模型不进入 nim-pool，不进入默认 nim-pool-lab，仅保留为隔离观察对象。
生产 nim-pool 固定为 3 个稳定模型：
- nvidia/meta/llama-3.3-70b-instruct
- nvidia/z-ai/glm-5.1
- nvidia/qwen/qwen3-coder-480b-a35b-instruct

本文档记录 `nim-omniroute-gateway` GitHub `v1.0.0` 基线的实测证据。

定稿日期：2026-04-25

## 1. 部署启动验证

实测日志显示：

```text
[entrypoint] OmniRoute ready after 2s
[init] logged in, token acquired
[init] setupComplete PATCH → HTTP 200
[init] nim-01 registered (HTTP 201)
...
[init] NIM Keys: 25 registered, 0 skipped
[init] applying Resilience config...
[init] Resilience PATCH → HTTP 200
[init] first-time init: creating Combo nim-pool...
[init] Combo nim-pool → HTTP 201
[entrypoint] starting gate on 0.0.0.0:7860
```

结论：

- OmniRoute 启动成功。
- init 脚本成功登录 Dashboard。
- 25 个 NIM provider 全部注册成功。
- Resilience 写入成功。
- `nim-pool` Combo 创建成功。
- gate 作为外部入口启动成功。

## 2. Provider 验证

启动后验证结果：

| 项目 | 结果 | 结论 |
|---|---:|---|
| NIM provider 注册 | 25/25 HTTP 201 | 通过 |
| Provider connection test | 25/25 HTTP 200 | 通过 |
| Rate-limit protection | 25/25 HTTP 200 | 通过 |
| Resilience PATCH | HTTP 200 | 通过 |
| Circuit breaker reset | HTTP 200 | 通过 |

结论：25 个 NIM Key 不是单纯写入环境变量，而是已经进入 OmniRoute provider 管理体系，并启用了保护机制。

## 3. Combo 路由验证

曾经错误状态：

```text
nim-pool → openai/nim-pool
No credentials for provider: openai
```

修复后实测日志：

```text
Combo "nim-pool" [round-robin] with 1 models
[RR #0] → nvidia/meta/llama-3.3-70b-instruct
Provider: nvidia, Model: meta/llama-3.3-70b-instruct
nvidia/meta/llama-3.3-70b-instruct succeeded
```

结论：

- `nim-pool` 必须使用 `models` 字段。
- 模型路由键必须包含 `nvidia/` 前缀。
- 修复后 `nim-pool` 能正确路由到 NVIDIA provider。

## 4. 模型目录验证

问题：

```text
Combo 实际可用，但 Dashboard 显示“没有模型”
```

修复方式：

```text
POST /api/provider-models
```

实测结论：

- `provider` 使用 `nvidia`。
- `modelId` 使用不带 `nvidia/` 的模型 ID。
- Combo `models` 使用带 `nvidia/` 的完整路由键。
- 注册 provider model 后，Dashboard Combo 卡片可正常显示模型名。

## 5. 生产模型 round-robin 验证

14 轮 round-robin 验证后，生产池收敛为 3 个模型。

| 模型 | 实测表现 | 结论 |
|---|---|---|
| `nvidia/meta/llama-3.3-70b-instruct` | 返回 200 + tokens | 生产可用 |
| `nvidia/z-ai/glm-5.1` | 返回 200 + tokens | 生产可用 |
| `nvidia/qwen/qwen3-coder-480b-a35b-instruct` | 返回 200 + tokens | 生产可用 |
| `nvidia/deepseek-ai/deepseek-v4-pro` | 出现 504 / 长延迟 | 不进生产 |
| `nvidia/deepseek-ai/deepseek-v4-flash` | 稳定性不足 | 不进生产 |
| `nvidia/minimaxai/minimax-m2.7` | 出现 504 / 长延迟 | 不进生产 |
| `nvidia/moonshotai/kimi-k2.5` | 多次 0 token / empty content | 不进生产 |

结论：`v1.0.0` 生产池只保留 Llama、GLM、Qwen-Coder。其余模型放入 `nim-pool-lab`。

## 6. Dashboard 状态解释

密集测试后观察到：

```text
25 providers protected
17 providers connected
8 providers short rate-limit cooldown
10 providers Provider returned empty content
```

判定：

- `protected` 是正常状态。
- 短暂限流是保护机制生效。
- `Provider returned empty content` 不等于 Key 失效。
- 生产验证以 `/v1/chat/completions` 返回 token 为准。

## 7. v1.0.0 验收标准

`v1.0.0` 发布前必须满足：

- HF Space 构建成功。
- `/healthz` 返回 200。
- OmniRoute `/api/monitoring/health` 可访问。
- 25 个 provider 注册成功。
- Resilience PATCH 返回 200。
- rate-limit protection 写入成功。
- `nim-pool` 至少包含 3 个生产模型。
- 生产请求连续 6 次能返回非空 token。
- GitHub Release `v1.0.0` 已创建。

## 8. 最小生产验证命令

```bash
for i in $(seq 1 6); do
  echo "---- round $i ----"
  curl -sS --max-time 90 "$PUBLIC_BASE_URL/v1/chat/completions" \
    -H "Authorization: Bearer $CLIENT_TOKEN" \
    -H "Content-Type: application/json" \
    -d '{
      "model": "nim-pool",
      "stream": false,
      "messages": [
        {"role": "user", "content": "Reply with one short sentence."}
      ],
      "max_tokens": 16
    }'
  echo
  sleep 3
done
```

通过标准：

- 至少 5/6 返回 200。
- 返回体包含 `choices[0].message.content`。
- 内容非空。
- 没有连续 502/504。
- Dashboard 未出现大面积 invalid key。
```

原因：`VALIDATION.md` 的作用是把“已经跑通过”的证据固化，未来发版、回滚、AI 接手时不用重新猜测哪些步骤真的验证过。  
实测证据：`1.3.0.txt` Line 6001 记录完整启动与注册日志；Line 6024 记录验证表；Line 7593 记录 `nim-pool → nvidia → meta/llama-3.3-70b-instruct` 成功；当前对话摘要记录 14 轮 round-robin 结果。

---



1. HF Space OmniRoute 启动成功。
2. init-nim-keys.sh 初始化成功。
3. /data/.or-api-key 创建成功。
4. gate.js 成功读取内部 API Key。
5. /gate/package.json 改造成功。
6. gate 防吞噬日志正常。
7. 25 个 NIM Provider 注册成功。
8. 25 个 Provider 连接测试 HTTP 200。
9. 25 个 Provider rate-limit protection 开启成功。
10. Resilience 写入成功。
11. circuit breaker reset 成功。
12. model catalog 注册成功。
13. nim-pool Combo 创建成功。
14. Cloudflare Worker /healthz 成功。
15. Cloudflare Worker /v1/chat/completions 成功返回非空 token。

