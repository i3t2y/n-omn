# **OmniRoute × NVIDIA NIM 多账号网关（HF Space 部署，v4.2.3）**

> **快速部署文档** · 深度版见 [`DEPLOYMENT_GUIDE.md`](DEPLOYMENT_GUIDE.md) · 变更日志见 [`CHANGELOG.md`](CHANGELOG.md)
> 旧版本/历史快照/nog 项目文档已归档至 [`archive/`](archive/)

> 在 Hugging Face 免费 Docker Space 上自托管 OmniRoute，接入多个 NVIDIA NIM 免费 Key，通过多账号池化 + p2c 调度 + 多层兜底，把单账号 ~40 RPM 的硬限横向放大为 N×40。

---

## **1. 核心事实与版本策略**

- **基础镜像钉死 `3.8.43`**：禁止使用 `latest`。新版（3.8.46+）存在严重的 NIM 路由 404 回归（Issue #6773）且强制触发 Turbopack 构建导致 Space 启动挂起。**3.8.43 是目前验证过最稳定的锚点。**
- **扩容路径**：NIM 免费层 ~40 RPM 且官方不提额。提升吞吐的唯一合规路径是增加独立账号数，让 N 个 `nvapi-` Key 组池，理论可用 ≈ N×40 RPM。
- **combo 策略**：`quota-share` 是内部机制，直接传给 API 会报 400。多账号池摊平请使用 `p2c`（25 池规模避热点最优）或 `round-robin`。脚本已内置合法性白名单。

---

## **2. 环境变量（HF Space → Settings → Secrets）**

### **必填**
| 变量 | 说明 |
| --- | --- |
| `INITIAL_PASSWORD` | OmniRoute 管理员密码 |
| `NIM_KEYS` | 多行，每行一个 `nvapi-` Key；**行数即池大小，决定 RPM** |
| `INTERNAL_PSK` | 客户端 `/v1` 请求需带的 Bearer，gate 会换成内部 OR_API_KEY |

### **NIM 池调优**
| 变量 | 默认 | 说明 |
| --- | --- | --- |
| `NIM_POOL_STRATEGY` | `p2c` | 多账号建议 `p2c`。非法值自动回退 `round-robin` |
| `NIM_PER_KEY_RPM` | `35` | 每 Key 计入 RPM（40 留 12% 退避余量）|
| `NIM_PROBE` | `0` | 设 `1` 启用轻量模型探针（每模型每小时限频 + 跨 key 轮换）。建议仅排查时开启 |
| `NIM_FALLBACK_MODELS_OVERRIDE` | 空 | 空格分隔，覆盖 `nim-max` 的非 NIM 兜底节点 |

### **持久化与日志**
| 变量 | 默认 | 说明 |
| --- | --- | --- |
| `NIM_MODE` | `NORMAL` | 设 `DEBUG` 开启日志归档。init 日志随 Space 日志可见 |
| `NIM_DEBUG_LOG_TO_DATASET` | `1` | DEBUG 模式下是否把 `debug_*.log` 上传到 HF Dataset |
| `NIM_DEBUG_LOG_KEEP` | `5` | 本地 `/data/` 只保留最近 N 个 `init_*.log` |
| `R2_ACCOUNT_ID` / `R2_ACCESS_KEY_ID` / `R2_SECRET_ACCESS_KEY` | **强烈建议**：配置后启用 Litestream 实时备份 SQLite 到 R2 |
| `HF_TOKEN` / `HF_DATASET_REPO` | 配置后每次启动自动备份脱敏配置（及 debug log）到 Dataset |

---

## **3. Combo 分工与启动推荐**

脚本会自动创建/更新以下三个 Combo，并执行幂等 upsert 防撞名：

| Combo | 策略 | 组成 | 适用 |
| --- | --- | --- | --- |
| `nim-max` | priority | NIM 存活池 → 免费兜底（Cerebras/Pol/CF）| **日常主入口，永不断供** |
| `nim-pool` | p2c | 纯 NIM 存活池 | 纯 NIM 高吞吐场景 |
| `nim-codex` | round-robin | DeepSeek-V4-Pro / GPT-OSS-120B / GLM-5.2 | 代码专项任务 |

### **启动推荐主力（样例输出）**
每次启动末尾，`nim_health_pick` 会读取近 1 小时本地 `call_logs` 成功率与延迟，输出决策参考：
```text
[init] ══════════ 本次推荐主力（按分档）══════════
[init]   🧑 💻 编程/复杂推理 : deepseek-ai/deepseek-v4-pro (ok 99%, 420ms, n=37)
[init]   ⚡ 低延迟/日常快答 : deepseek-ai/deepseek-v4-flash (ok 100%, 180ms, n=12)
[init]   🎯 综合均衡首选   : z-ai/glm-5.2 (ok 98%, 310ms, n=25)
[init] ────────────────────────────────────────
[init]   直调示例：model = nvidia/deepseek-ai/deepseek-v4-pro
```

---

## **4. 客户端接入**

### **Claude Code —— 用根地址，不要加 `/v1`**
```json
// ~/.claude/settings.json
{
  "env": {
    "ANTHROPIC_BASE_URL": "https://<your-space>.hf.space",
    "ANTHROPIC_AUTH_TOKEN": "<INTERNAL_PSK>"
  }
}
```
模型填 `nim-max` 或 `auto/coding`。

### **OpenAI 兼容工具 (Cursor / Codex / Hermes) —— 必须带 `/v1`**
- **Base URL**: `https://<your-space>.hf.space/v1`
- **API Key**: `<INTERNAL_PSK>`

---

## **5. 运维与故障排查**

- **卡在 Starting**：检查 Dockerfile 的 `FROM` 是否被改成 `latest`；entrypoint 会打印版本比对，若非 `3.8.43` 则存在漂移风险。
- **400 Invalid Strategy**：确保 `NIM_POOL_STRATEGY` 不含 `quota-share`。脚本已内置白名单，非法值会自动降级为 `round-robin`。
- **Combo 撞名报错**：v4.2.2+ 已切换为 `upsert_combo`（GET 查名 → PUT 更新），彻底解决 R2 restore 后的 POST 冲突。
- **Schema 不匹配**：若 `nim_health_pick` 报错，请运行 `sqlite3 /data/storage.sqlite ".schema call_logs"` 确认列名是否为 `model_id`/`status_code`。
- **升级建议**：**暂不升级。** 3.8.46 存在 NIM 路由 404 严重 bug（Issue #6773）。待该 issue 关闭且 3.8.47+ 发布后，先在独立测试 Space 验证再切换。

---

## **6. 合规与风险**

- **NIM 免费层**：为 eval/prototyping 用途。单人持多账号绕过速率限制处于 ToS 灰区，建议自建自用，控制在合理规模，不宜商用。
- **数据安全**：DEBUG log 包含注册过程及模型决策，虽不含 Key 明文，但仍建议保持 Dataset 为 **Private** 状态。

---
*Base image: 3.8.43@sha256:517c1606... · Init script: v4.2.3 · Updated: 2026-07-10*

*内容由 AI 生成仅供参考*