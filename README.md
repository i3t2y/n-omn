---
title: omn
emoji: 📊
colorFrom: purple
colorTo: red
sdk: docker
datasets:
  - nomke/omni-data
app_port: 7860
pinned: false
license: mit
---

## 配置说明

### HF Space Secrets

| Secret | 作用 | 要求 |
|--------|------|------|
| `INTERNAL_PSK` | 客户端→gate 外层鉴权（`Authorization: Bearer <PSK>`） | 值须与客户端 `$OMN_TOKEN` 一致 |
| `OMNIROUTE_API_KEY` | gate→OmniRoute 内层鉴权，固定 `OR_API_KEY`，经上游 env-bypass 实现跨重建稳定 | ≥32 字节强随机串，建议 `openssl rand -hex 32` 生成 |
| `JWT_SECRET` / `API_KEY_SECRET` / `INITIAL_PASSWORD` | OmniRoute 引擎内部 | 详见 init 脚本 |

`INTERNAL_PSK` 与 `OMNIROUTE_API_KEY` 独立配置、值不同：前者是外层客户端鉴权，后者是内层上游鉴权（env-bypass，不写入 sqlite、不依赖 Litestream restore）。

### 迁移：清理旧 `OR_API_KEY` Secret

若 HF Space 中残留旧 `OR_API_KEY` Secret（stage3 时期命名），应在 Settings → Variables and secrets 中删除：env-bypass 只识别 `OMNIROUTE_API_KEY` 或 `ROUTER_API_KEY`，不识别 `OR_API_KEY`，残留值不被任何代码消费，仅致命名混淆。

未设 `OMNIROUTE_API_KEY` 时，仍走旧链路（init 调 `/api/keys` 生成、写 `/data/.or-api-key`），行为不变。

> 完整架构与当前实态（三层鉴权链路、env-bypass 跨重建固定化、生产模型池、gate.js 46 行回归风险、Litestream 复制、NIM 模型上架状态）见 [`docs/CURRENT_STATE_v3.8.md`](docs/CURRENT_STATE_v3.8.md)。该文档为当前真态 SSOT；其余 `docs/` 下的活文档已按 drift header 区分 v1.0.0 时代与当前实态，历史快照文件只读不改。
