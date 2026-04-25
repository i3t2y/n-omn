# NOG
`nim-omniroute-gateway` 是一个部署在 Hugging Face Space 上的 NVIDIA NIM 多 Key 轮询网关。它以 OmniRoute 为核心，通过前置 gate 层实现外部鉴权、请求清洗、内部 API Key 注入和稳定性兜底，用 25 个 NIM API Key 构建可恢复、可复现、可交接的生产网关。

当前 GitHub 基线版本：`v1.0.0`

内部演进版本：`v1.3.0`

定稿日期：2026-04-25

## 当前状态

当前基线不是理论方案，而是已跑通方案。

已验证能力包括：

- Hugging Face Space 防吞噬版重建成功。
- 25 个 NIM provider 全部注册成功。
- 25 个 provider 全部启用 rate-limit protection。
- OmniRoute Resilience 配置写入成功。
- `/api/provider-models` 模型目录注册成功。
- `nim-pool` Combo 创建成功。
- gate 层转发、外层 PSK 鉴权、内部 API Key 注入均已跑通。
- 生产池模型已从 7 个收敛为 3 个稳定模型。
- 实验池保留 7 个模型用于后续观测。

## 架构概览

```text
Client
  ↓
Cloudflare Worker
  - CLIENT_TOKEN 校验
  - 请求入口治理
  ↓
gate.js
  - INTERNAL_PSK 校验
  - 清理 Cloudflare 透传头
  - raw body 转发
  - 自动注入内部 OmniRoute API Key
  ↓
OmniRoute
  - Provider 轮询
  - Combo 路由
  - Resilience
  - Rate-limit protection
  - Circuit breaker
  ↓
NVIDIA NIM
  - 25 个 API Key
  - 多模型推理
```

## 目录结构

```text
.
├── hf-space/
│   ├── Dockerfile
│   ├── entrypoint.sh
│   ├── gate.js
│   └── init-nim-keys.sh
├── cf-worker/
│   └── index.js
├── docs/
│   ├── DECISIONS.md
│   ├── TROUBLESHOOTING.md
│   ├── VALIDATION.md
│   └── AI_HANDOFF.md
└── README.md
```

## 生产模型池

`nim-pool` 只包含已通过 round-robin 实测的稳定模型：

| 模型 | 用途 | 当前结论 |
|---|---|---|
| `nvidia/meta/llama-3.3-70b-instruct` | 通用推理 | 生产可用 |
| `nvidia/z-ai/glm-5.1` | 中文与通用任务 | 生产可用 |
| `nvidia/qwen/qwen3-coder-480b-a35b-instruct` | 代码任务 | 生产可用 |

## 实验模型池

`nim-pool-lab` 用于继续观察不稳定模型，不作为默认生产入口：

| 模型 | 当前问题 | 处理方式 |
|---|---|---|
| `nvidia/deepseek-ai/deepseek-v4-pro` | 可能长时间卡住并 504 | 实验池观察 |
| `nvidia/deepseek-ai/deepseek-v4-flash` | 稳定性不足 | 实验池观察 |
| `nvidia/minimaxai/minimax-m2.7` | 可能 504 | 实验池观察 |
| `nvidia/moonshotai/kimi-k2.5` | 多次 empty content / 0 token | 实验池观察 |

## v1.0.0 Resilience 基线

`v1.0.0` 使用稳定优先配置：

| 参数 | 值 | 说明 |
|---|---:|---|
| `requestsPerMinute` | 28 | 稳定基线，后续可通过 Issue 测试 32/35 |
| `minTimeBetweenRequests` | 1 | 沿用实测跑通配置 |
| `concurrentRequests` | 5 | 沿用实测跑通配置 |
| `rateLimitCooldown` | 60000 | 1 分钟冷却窗口 |
| `circuitBreakerThreshold` | 3 | 连续失败后熔断 |
| `circuitBreakerReset` | 600000 | 10 分钟重置窗口 |

说明：仓库内 `v1.0.0` 以可恢复和稳定为优先，不以最大吞吐为优先。RPM 32/35 应进入后续性能优化 Issue，而不是直接覆盖基线。

## 必需 Secrets

不要把任何真实 Secret 提交到 GitHub。

| Secret | 说明 |
|---|---|
| `NIM_KEYS` | 多行文本，每行一个 `nvapi-...` |
| `INTERNAL_PSK` | gate 层内部预共享密钥 |
| `INITIAL_PASSWORD` | OmniRoute Dashboard 初始密码 |
| `JWT_SECRET` | OmniRoute 登录会话相关密钥 |
| `API_KEY_SECRET` | OmniRoute API Key 签名/加密相关密钥 |
| `CALL_LOGS_TABLE_MAX_ROWS` | 推荐值 `100000` |
| `PROXY_LOGS_TABLE_MAX_ROWS` | 推荐值 `100000` |

## 部署原则

HF Space 免费层存储视为临时存储，不能依赖 SQLite 在容器重建后保留 provider、combo、model catalog 或 API key 配置。因此，`init-nim-keys.sh` 必须能在每次重建后幂等地完成：

- 登录 OmniRoute。
- 注册 25 个 NIM provider。
- 写入 Resilience 配置。
- 启用 rate-limit protection。
- 注册模型目录。
- 创建或修复 `nim-pool`。
- 必要时重置 circuit breaker。

## 验证入口

生产验证只看 `/v1/chat/completions` 是否能通过 `nim-pool` 返回非空 token，不以 Dashboard 单次 provider test 作为唯一标准。

最小验证请求：

```bash
curl -sS --max-time 90 "<PUBLIC_BASE_URL>/v1/chat/completions" \
  -H "Authorization: Bearer <CLIENT_TOKEN>" \
  -H "Content-Type: application/json" \
  -d '{
    "model": "nim-pool",
    "stream": false,
    "messages": [
      {"role": "user", "content": "Reply with one short sentence."}
    ],
    "max_tokens": 16
  }'
```

## 关键文档

- [Architecture decisions](docs/DECISIONS.md)
- [Troubleshooting](docs/TROUBLESHOOTING.md)
- [Validation record](docs/VALIDATION.md)
- [AI handoff](docs/AI_HANDOFF.md)

## 版本策略

GitHub `v1.0.0` 对应当前已跑通的内部 `v1.3.0` 防吞噬版方案。后续版本只通过 Issue 和 Pull Request 增量演进，不直接覆盖稳定基线。
```

原因：GitHub 官方建议仓库必须有 README；README 应承担快速理解和导航职责，不承载全部踩坑细节。  
实测证据：`1.3.0.txt` Line 6001 显示 25 Key 注册、Resilience、Combo、gate 启动流程；Line 6024 显示核心启动验证项成功；Line 7593 显示 `nim-pool` 路由到 nvidia 成功。
