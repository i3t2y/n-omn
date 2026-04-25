# AI Handoff

本文档给无上下文 AI 使用。任何新会话接手 `nim-omniroute-gateway` 时，必须先读本文档，再读 `README.md`、`docs/DECISIONS.md`、`docs/TROUBLESHOOTING.md`、`docs/VALIDATION.md`。

## 0. 当前唯一基线

GitHub 仓库名：

```text
nim-omniroute-gateway
```

GitHub 正式版本：

```text
v1.0.0
```

内部演进来源：

```text
v1.3.0 防吞噬版跑通方案
```

定稿日期：

```text
2026-04-25
```

当前状态：

```text
已跑通，不是草案。
```

## 1. 接手 AI 的第一规则

不要基于通用经验重写整套方案。

只能做增量 Patch。

每次回答必须先确认当前依据：

```text
当前基于仓库文件工作。
```

如果用户没有上传仓库文件，只给摘要，则必须声明：

```text
当前基于摘要工作，存在信息损耗风险，建议上传文件。
```

如果用户要求修改代码或文档，但没有提供当前文件内容，不允许直接生成替换整文件方案，只能给“建议 Patch 草案”。

## 2. 当前架构一句话

这是一个 Hugging Face Space 上的 OmniRoute 网关，通过 gate.js 做外部鉴权和内部 API Key 注入，用 25 个 NVIDIA NIM Key 作为 provider pool，再通过 `nim-pool` Combo 暴露稳定生产模型。

## 3. 架构链路

```text
Client
  ↓
Cloudflare Worker
  - CLIENT_TOKEN
  ↓
gate.js
  - INTERNAL_PSK
  - raw body proxy
  - header cleanup
  - inject internal OmniRoute API key
  ↓
OmniRoute
  - provider pool
  - model catalog
  - combo routing
  - resilience
  - rate-limit protection
  - circuit breaker
  ↓
NVIDIA NIM
```

## 4. 当前生产模型池

生产 `nim-pool` 只允许包含：

```text
nvidia/meta/llama-3.3-70b-instruct
nvidia/z-ai/glm-5.1
nvidia/qwen/qwen3-coder-480b-a35b-instruct
```

不要把下面模型加入生产池，除非有新的连续实测证据：

```text
nvidia/deepseek-ai/deepseek-v4-pro
nvidia/deepseek-ai/deepseek-v4-flash
nvidia/minimaxai/minimax-m2.7
nvidia/moonshotai/kimi-k2.5
```

这些只能放入：

```text
nim-pool-lab
```

## 5. 当前 Resilience 基线

GitHub `v1.0.0` 固化值：

```json
{
  "defaults": {
    "requestsPerMinute": 28,
    "minTimeBetweenRequests": 1,
    "concurrentRequests": 5
  }
}
```

不要擅自把 28 改成 35。

如果用户问 28 是否保守，正确回答是：

```text
28 偏保守，但适合作为 v1.0.0 稳定基线。32/35 应通过后续 Issue 做阶梯压测，不直接覆盖基线。
```

## 6. 已确认关键端点

OmniRoute 官方 API 文档确认以下端点存在：

```text
POST /v1/chat/completions
GET  /v1/models
POST /api/auth/login
GET  /api/providers
POST /api/providers
POST /api/providers/[id]/test
GET  /api/provider-models
POST /api/provider-models
GET  /api/combos
POST /api/combos
GET  /api/keys
POST /api/keys
GET  /api/resilience
PATCH /api/resilience
POST /api/resilience/reset
GET  /api/rate-limits
GET  /api/monitoring/health
```

注意：管理 API 使用 Dashboard cookie 鉴权。不要把 `/api/*` 全部当成 Bearer API Key 调用。

## 7. 已确认坑点

### 7.1 Combo 字段坑

错误：

```json
{
  "providers": ["nvidia"]
}
```

正确：

```json
{
  "models": [
    "nvidia/meta/llama-3.3-70b-instruct"
  ]
}
```

### 7.2 模型 ID 前缀坑

在 `/api/provider-models` 中：

```json
{
  "provider": "nvidia",
  "modelId": "meta/llama-3.3-70b-instruct"
}
```

在 Combo 中：

```json
"nvidia/meta/llama-3.3-70b-instruct"
```

### 7.3 Dashboard 显示坑

Combo 能推理成功，不代表 Dashboard 会显示模型名。Dashboard 显示依赖 `/api/provider-models`。

### 7.4 Empty content 坑

`Provider returned empty content` 不等于 Key 失效。先等冷却，再测生产 `/v1/chat/completions`。

### 7.5 防吞噬坑

不要在关键路径里使用可能被二次渲染吞掉的模板字符串。日志、URL、Authorization、端口拼接等位置优先使用字符串拼接。

### 7.6 `stream:false` 坑

`stream:false` 不会导致格式错误。它是为了减少 SSE 与 JSON 解析路径冲突。

## 8. 修改时必须遵守的 Patch 格式

每次修改只输出增量 Patch，不重写整份文件。

格式：

```text
PATCH-[ID]
文件: [文件名]
操作: [插入/替换/删除]
位置: [精确位置]
---
[具体内容]
---
原因: [一句话]
实测证据: [文件名 Line N / 命令返回值 / 用户截图]
```

如果没有上传当前文件，不能写“第 N 行替换”，只能写：

```text
位置: 新建文件 / 建议插入到某标题之后
```

## 9. 回答前检查清单

回答任何技术修改前，先检查：

- 用户是否上传当前文件。
- 是否存在真实行号。
- 是否要求修改代码还是修改文档。
- 是否涉及 Secret。
- 是否会推翻已实测结论。
- 是否需要联网查 OmniRoute/GitHub/HF/NIM 当前文档。
- 是否只是摘要，不是 SSOT 文件。

## 10. 不允许做的事

不允许：

- 把 `nim-pool` 重新扩成 7 模型生产池。
- 在没有压测证据时把 RPM 28 直接改成 35 作为基线。
- 把 `Provider returned empty content` 直接判定为 Key 坏。
- 把 Dashboard 显示问题误判为 Combo 路由失败。
- 把 `/api/provider-models` 的 `modelId` 写成带 `nvidia/` 前缀。
- 把 Combo 的 `models` 写成不带 `nvidia/` 前缀。
- 把真实 Secret 写入文档或代码。
- 无文件时声称已经基于行号精确修改。
- 重新生成整份方案覆盖当前基线。

## 11. 当前下一步

当前最优下一步是：

```text
1. 创建 GitHub private repo: nim-omniroute-gateway
2. 上传 hf-space/ 四个核心文件
3. 上传 cf-worker/index.js
4. 上传 README.md
5. 上传 docs/DECISIONS.md
6. 上传 docs/TROUBLESHOOTING.md
7. 上传 docs/VALIDATION.md
8. 上传 docs/AI_HANDOFF.md
9. 创建 tag v1.0.0
10. 创建 GitHub Release v1.0.0
11. 为 RPM 32/35 压测创建后续 Issue
12. 为不稳定模型健康监测创建后续 Issue
```

## 12. 当前发布说明草案

```text
v1.0.0 establishes the first stable GitHub baseline for nim-omniroute-gateway.

Included:
- Hugging Face Space deployment files.
- gate.js anti-template-loss proxy layer.
- OmniRoute init script for 25 NVIDIA NIM keys.
- Provider registration and rate-limit protection.
- Resilience baseline configuration.
- Production nim-pool with 3 validated models.
- Experimental nim-pool-lab plan for unstable models.
- Documentation for decisions, troubleshooting, validation, and AI handoff.

This release prioritizes reproducibility and stability over maximum throughput.
```
```

原因：`AI_HANDOFF.md` 是防止下一次无上下文 AI 重复犯错的核心文件，它必须明确“什么不能改、什么已经验证、什么只是待测”。  
实测证据：`1.3.0.txt` Line 7593 证明 Combo 正确路由；Line 9163、9182 证明模型目录与 Dashboard 显示的关系；当前对话摘要确认 GitHub `v1.0.0`、3 模型生产池、7 模型实验池策略。

---
