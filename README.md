# nim-omniroute-gateway

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
