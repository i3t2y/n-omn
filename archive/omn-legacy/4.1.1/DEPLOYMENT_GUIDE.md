```markdown
# OmniRoute NIM 部署技术文档

> **版本**：v4.1.1 | **最后更新**：2026-07-09 | **镜像**：OmniRoute 3.8.43  
> **部署平台**：HuggingFace Space (Docker SDK) | **Provider**：NVIDIA NIM

---

## 一、项目概述

本项目在 HuggingFace Space 上部署 OmniRoute（一个 LLM API 网关），代理 NVIDIA NIM 的多个模型。通过 combo 机制实现多模型 round-robin 轮询，对外提供统一的 `/v1/chat/completions` 端点。

### 架构三段式

```
客户端请求
  │
  ▼
gate.js (端口 7860)          ← Express 反向代理，INTERNAL_PSK 鉴权
  │ Bearer 替换为 OMNIROUTE_API_KEY
  ▼
OmniRoute server.js (端口 20128)  ← 模型路由、combo 轮询、熔断器、请求队列
  │ 通过 NVIDIA NIM Key 调用
  ▼
NVIDIA integrate.api.nvidia.com   ← 上游 LLM 推理服务
```

**数据持久化**：SQLite (`/data/storage.sqlite`) + Litestream WAL 实时复制到 Cloudflare R2，支持 OOM 后自动恢复。

---

## 二、文件清单

仓库共 6 个核心文件，全部位于根目录：

| 文件 | 用途 | 当前版本 | 是否需要改动 |
|------|------|---------|-------------|
| `init-nim-keys.sh` | NIM 初始化脚本（key 注册、模型注册、combo 创建、配置写入） | v4.1.1 | 本次更新 |
| `Dockerfile` | 容器构建定义（基础镜像、依赖安装、健康检查） | v3.8.0 基线 | 否 |
| `entrypoint.sh` | 容器入口脚本（Litestream 恢复、OmniRoute 启动、init 调用、gate 启动） | v3.8.0 基线 | 否 |
| `gate.js` | Express 反向代理网关（PSK 鉴权 + Bearer 替换） | v3.8.0 基线 | 否 |
| `litestream.yml` | Litestream 配置（R2 复制目标、快照策略） | v3.8.0 基线 | 否 |
| `package.json` | gate.js 的 npm 依赖声明 | v3.8.0 基线 | 否 |

---

## 三、版本历史

| 版本 | 变更内容 | 状态 |
|------|---------|------|
| v3.4.0 | 统一模型 SSOT；override 覆盖 pool∪codex∪extra；Memory static | 历史版本 |
| v3.6.0 | purge 重写为注册表模型 + 环境自检；确认 20129 是 API_PORT 非代理 | 历史版本 |
| v3.7.0 | context-relay 查证；变量名对齐；nim-codex 改 round-robin | 历史版本 |
| v3.8.0 | body-limit 字节→MB 自动换算；proxy_enabled 强制覆盖；CRLF 修复 | 本地仓库原基线 |
| v4.1.0 | 模型分档(NIM_PROFILE) + 单变量调试(NIM_MODE) + 日志归档 + combo 对象数组格式修正 + 首次探活 | HF Space 已部署验证 |
| **v4.1.1** | v4.1.0 + 扩展模型数组 + `models_to_json` 添加 `nvidia/` 路由前缀 | **当前版本** |

### v4.1.1 相对 v3.8.0 的完整变更

1. **模型分档**：`TIER_FAST`(4) / `TIER_STABLE`(7) / `TIER_RESTRICTED`(5)，由 `NIM_PROFILE=fast|balanced|full` 控制入池范围
2. **单变量调试**：`NIM_MODE=DEBUG` 开启全程日志归档至 `/data/omni-data/log/` + 关闭 SQLite 自动备份
3. **combo 对象数组格式**：`models_to_json` 生成 `[{"model":"x"}]` 而非 `["x"]`（官方 USER_GUIDE 要求）
4. **首次探活**：首次初始化也执行 `check_nim_model_health`，自动过滤 NVIDIA 目录中不存在的模型
5. **路由前缀修正**：`models_to_json` 添加 `sed 's/^/nvidia\//'`，消除 OmniRoute 内置 provider 映射导致的裸 ID 路由歧义
6. **扩展模型数组**：补充 `deepseek-v4-flash`、`llama-3.3-70b`、`gemma-4-31b`、`nemotron-super-49b-v1.5`、`yi-large`、`codestral-22b` 等模型

---

## 四、三大技术坑位与修正

这是本文档最关键的部分。以下三个问题均经过线上实测验证，修正方案已落地到 v4.1.1 脚本中。

### 坑位 1：proxy_registry 全局兜底（Issue #3332）

**现象**：所有请求被路由到 `127.0.0.1:20129`（OmniRoute 的 API 端口，非代理服务），导致 `ECONNREFUSED`，部分模型标记为 DEGRADED。

**根因**：OmniRoute 的 `getProxyCandidates()` 函数在 `proxy_registry` 表存在任何记录时，会将其作为全局兜底代理应用到所有 provider，且**绕过 `proxy_enabled` 字段**。某次运行中 `proxy_registry` 被写入了一条 `127.0.0.1:20129` 记录（可能是把 API 端口误当代理），之后所有流量被灌入这个无服务的端口。

**关键认知**：`NO_PROXY` 环境变量对此**无效**——代理来自数据库而非环境变量，undici 的 `NO_PROXY` 管不到 DB 来源的代理。

**修正**：`purge_proxy_db()` 函数执行三重清理：
- API 层：`DELETE /api/v1/management/proxies?force=1`
- SQL 层：`DELETE FROM proxy_assignments` + `DELETE FROM proxy_registry` + `UPDATE provider_connections SET proxy_enabled=0`
- 环境层：`export ONEPROXY_ENABLED=false` + `export ENABLE_SOCKS5_PROXY=false`

该函数在登录后、注册 key 后、初始化末尾各调用一次。

**官方依据**：[OmniRoute Issue #3332](https://github.com/diegosouzapw/OmniRoute/issues/3332)

### 坑位 2：combo models 格式错误

**现象**：创建 combo 时返回 HTTP 400。

**根因**：OmniRoute 的 `/api/combos` 接口要求 `models` 字段为**对象数组** `[{"model":"x"}]`，而非字符串数组 `["x"]`。v3.8.0 的 `models_to_json` 生成的是字符串数组。

**修正**：`models_to_json()` 使用 `jq -R '{model: .}' | jq -s -c .` 生成正确格式。

**官方依据**：[OmniRoute USER_GUIDE](https://github.com/diegosouzapw/OmniRoute/blob/main/docs/guides/USER_GUIDE.md) 示例：
```json
{ "name": "premium", "strategy": "priority", "models": [{ "model": "cc/claude-opus-4-7" }] }
```

### 坑位 3：裸 ID 路由歧义

**现象**：通过 combo 调用 `nim-pool` 时返回 HTTP 400：`"Ambiguous model 'moonshotai/kimi-k2.6'. Use provider/model prefix"`。直接调用裸模型名时，部分模型返回 404：`"No active credentials for provider: qwen"` 或 `"No active credentials for provider: cline"`。

**根因**：OmniRoute 内置了多个 provider 的模型前缀映射表。当请求中的模型名以某个厂商前缀开头时，OmniRoute 会尝试路由到对应的内置 provider 而非用户注册的 `nvidia` provider：

| 内置 Provider | 拦截的模型前缀 | 表现 |
|---------------|---------------|------|
| `kc` (Kimi Cloud) | `moonshotai/` | 歧义 400（同时匹配 nvidia 和 kc） |
| `qwen` | `qwen/` | 无凭证 404 |
| `cline` | `nvidia/`（作为模型 ID 厂商前缀） | 无凭证 404 |
| `01-ai` | `01-ai/` | 无凭证 404 |

**修正**：`models_to_json()` 添加 `sed 's/^/nvidia\//'`，在每个模型裸 ID 前插入 `nvidia/` 路由前缀，强制 OmniRoute 路由到用户注册的 `nvidia` provider。

**验证**：
- `nvidia/z-ai/glm-5.2` → HTTP 200 ✅
- `nvidia/nvidia/nemotron-3-super-120b-a12b` → HTTP 200 ✅（双重 nvidia/ 格式正确：第一个是路由前缀，第二个是模型 ID 自带的厂商前缀）
- 裸 ID `moonshotai/kimi-k2.6` → HTTP 400 ❌

**影响范围**：此修正仅影响 combo 创建和 `repair_combo` 的 PUT 更新。不影响：
- `register_model`（使用裸 ID 注册，NVIDIA API 要求）
- `check_nim_model_health`（裸 ID 与 NVIDIA `/v1/models` 目录比对）
- `filter_alive`（裸 ID 过滤，输出后传入 `models_to_json` 时自动加前缀）

---

## 五、模型分档与权限层级

### 三档模型池

```bash
# TIER_FAST（4 个）：低延迟、权限门槛低、实测稳定（默认主力）
z-ai/glm-5.2
deepseek-ai/deepseek-v4-pro
deepseek-ai/deepseek-v4-flash
meta/llama-3.3-70b-instruct

# TIER_STABLE（7 个）：可用但偏重/偏慢，作为扩充池
nvidia/nemotron-3-super-120b-a12b
meta/llama-3.2-90b-vision-instruct
openai/gpt-oss-120b
mistralai/mistral-small-4-119b-2603
mistralai/mistral-large-3-675b-instruct-2512
google/gemma-4-31b-it
nvidia/llama-3.3-nemotron-super-49b-v1.5

# TIER_RESTRICTED（5 个）：NVIDIA 目录可见但账号无 Function 调用权限
moonshotai/kimi-k2.6
minimaxai/minimax-m2.7
qwen/qwen3-next-80b-a3b-instruct
nvidia/nemotron-3-ultra-550b-a55b
01-ai/yi-large
```

### NIM_PROFILE 控制入池范围

| Profile | 入池模型 | 数量 | 适用场景 |
|---------|---------|------|---------|
| `fast` | TIER_FAST | 4 | 极致低延迟 |
| `balanced` | TIER_FAST + TIER_STABLE | 11 | **推荐**，全部有调用权限 |
| `full` | 三档全部 | 16 | 需 NVIDIA 账号已申请 Public API Endpoints 权限 |

### 权限两层模型

NVIDIA NIM 存在两层权限验证：

1. **目录可见性**（`/v1/models`）：返回平台所有可用模型 ID。`check_nim_model_health` 查询此端点。
2. **Function 调用权限**（`/v1/chat/completions`）：验证账号是否有权调用该模型的 NIM Function。返回 404 表示账号无权限。

**目录可见 ≠ 可调用**。5 个 RESTRICTED 模型在目录中可见（探活通过），但实际调用返回 404：`Function '23d4f03a-...' Not found for account 'g3IVp0xr...'`。这些模型需在 NVIDIA 开发者控制台申请 Public API Endpoints 权限。

### 探活机制

`check_nim_model_health()` 在首次初始化和增量模式中均会执行：
- 查询 NVIDIA `/v1/models` 获取当前目录
- 将 SSOT 中的模型逐一比对，不存在的写入 `/tmp/nim-deprecated.txt`
- 后续注册和建 combo 时自动过滤 deprecated 模型

这保证了即使 SSOT 中写入了未来下架的模型，初始化也不会因 404 中断。

---

## 六、Combo 架构

### nim-pool

- **策略**：`round-robin`（轮询）
- **模型**：由 `NIM_PROFILE` 控制（balanced = 11 个）
- **用途**：通用对话、问答

### nim-codex

- **策略**：`round-robin`
- **模型**：`deepseek-v4-pro` / `gpt-oss-120b` / `glm-5.2` / `codestral-22b`（共 4 个，受探活过滤）
- **用途**：代码生成场景

### 增量模式行为

容器重启时（`storage.sqlite` 已存在且 `combos` 表中有 `nim-pool` 记录），init 脚本进入增量模式：
1. `purge_proxy_db` — 清理代理注册表
2. 清空 `domain_circuit_breakers` 熔断器
3. `check_nim_model_health` — 实时探活
4. 如有 deprecated 模型：`repair_combo` 用 PUT 更新 combo 的模型列表
5. `hf_snapshot` — 上传配置快照到 HuggingFace Dataset
6. 退出，不重复注册 keys 和模型

修改 `NIM_PROFILE` 或模型数组后，只需 Factory Reboot，`repair_combo` 会自动重建 pool。

---

## 七、环境变量完整清单

### Public Variables（5 个）

| 变量名 | 推荐值 | 默认值 | 消费位置 | 说明 |
|--------|--------|--------|---------|------|
| `NIM_PROFILE` | `balanced` | `balanced` | init: `case` 分支 | 控制模型入池范围 |
| `NIM_MODE` | `NORMAL` | `NORMAL` | init: 头部 if 分支 | `DEBUG` 开启日志归档+关备份 |
| `NIM_RPM` | `28` | `28` | init: `/api/resilience` | 每分钟请求上限 |
| `CONTEXT_LENGTH_DEFAULT` | `32768` | `32768` | init: `model_context_overrides` 表 | 模型上下文窗口覆写 |
| `NIM_COMPRESS_THRESHOLD` | `12000` | `12000` | init: `/api/settings/compression` | 压缩触发 token 阈值 |

### Secrets（12 个）

| 密钥名 | 消费位置 | 说明 |
|--------|---------|------|
| `INITIAL_PASSWORD` | init: `/api/auth/login` | OmniRoute 管理面板登录密码 |
| `NIM_KEYS` | init: 注册为 nvidia provider 的 API key 列表（多 key 换行分隔） | NVIDIA NIM API Keys |
| `OMNIROUTE_API_KEY` | init: env-bypass 模式；gate.js: Bearer 替换 | OmniRoute 内部 API Key |
| `INTERNAL_PSK` | gate.js: `/v1` 路径 Bearer 鉴权 | 客户端访问 gate.js 的密钥 |
| `STORAGE_ENCRYPTION_KEY` | OmniRoute 基础镜像内部消费 | SQLite 数据加密（不可删除） |
| `JWT_SECRET` | entrypoint: 透传给 server.js | JWT 签名密钥 |
| `API_KEY_SECRET` | entrypoint: 透传给 server.js | API Key 加密密钥 |
| `R2_ACCESS_KEY_ID` | entrypoint + litestream.yml | Cloudflare R2 访问密钥 |
| `R2_SECRET_ACCESS_KEY` | entrypoint + litestream.yml | Cloudflare R2 秘密密钥 |
| `R2_ACCOUNT_ID` | entrypoint + litestream.yml | Cloudflare R2 账户 ID |
| `HF_TOKEN` | init: `hf_snapshot()` 中 HfApi 认证 | HuggingFace Dataset 上传 |
| `HF_DATASET_REPO` | init: `hf_snapshot()` 中 repo_id | 配置快照目标仓库 |

### 可选调优变量（均有默认值，通常无需设置）

| 变量名 | 默认值 | 作用 |
|--------|--------|------|
| `NIM_CONCURRENT` | `5` | 并发请求数 |
| `NIM_MIN_INTERVAL_MS` | `500` | 请求最小间隔（毫秒） |
| `NIM_REQUEST_BODY_LIMIT` | `1`（MB） | 请求体大小上限，字节值 >500 自动换算为 MB |
| `NIM_PURGE_PROXY` | `1` | 是否执行 proxy_registry 清理 |
| `NIM_CODEX_STRATEGY` | `round-robin` | nim-codex 调度策略 |
| `NIM_PROXY_RELAY_HOST` | `127.0.0.1` | purge 针对的代理主机 |
| `NIM_PROXY_RELAY_PORT` | `20129` | purge 针对的代理端口 |

---

## 八、部署指南

### 首次部署

1. 将 6 个文件推送到 HF Space 代码仓库
2. 在 HF Space → Settings 中配置全部 17 个变量（5 Public + 12 Secret）
3. 确认 `NIM_PROFILE=balanced`、`NIM_MODE=NORMAL`
4. 执行 Factory Reboot
5. 查看启动日志，确认首次初始化完成

### 预期首次初始化日志

```
[entrypoint] OmniRoute ready after 2s
[entrypoint] OmniRoute base image version: 3.8.43 (expected 3.8.43)
[init] NIM_PROFILE=balanced -> pool 意向 11 个模型
[init] Starting NIM OmniRoute initializer v4.1.1 (profile=balanced, mode=NORMAL)...
[init] OmniRoute up (after 0s).
[init] version: 3.8.43
[init] Logged in.
[init] purge: registry=0 assignments=0 proxy_enabled=1剩余=0（期望 0/0/0）。
[init] Keys: 25 registered, 0 skipped, 0 failed.
[init] Resilience HTTP 200
[init] Settings HTTP 200
[init] Compression HTTP 200
[init] Thinking HTTP 200
[init] Memory legacy HTTP 200
[init] Memory extended HTTP 200
[init] CB reset HTTP 200
[init] override: 16 applied, 0 failed.
[init] check_nim_model_health...
[init] 0 deprecated / 121 available
[init] model z-ai/glm-5.2 OK
[init] ...（全部模型注册 OK）
[init] Creating nim-pool (round-robin, 11 models)...
[init] nim-pool HTTP 201
[init] Creating nim-codex (round-robin, 4 models)...
[init] nim-codex HTTP 201
[init] HF Dataset uploaded.
[init] Status: healthy / 3.8.43
[init] Done (first-init). v4.1.1
```

### 增量重启（配置变更后）

修改 `NIM_PROFILE` 或模型数组后 Factory Reboot，预期日志：

```
[init] NIM_PROFILE=balanced -> pool 意向 11 个模型
[init] Incremental mode.
[init] purge: registry=0 assignments=0 proxy_enabled=1剩余=0
[init] check_nim_model_health...
[init] 0 deprecated / 121 available
[init] Incremental: PUT combos/... (nim-pool) HTTP 200
[init] Incremental: PUT combos/... (nim-codex) HTTP 200
[init] HF Dataset uploaded.
[init] Done (incremental). v4.1.1
```

---

## 九、部署后验证

### 验证 1：Combo 路由

```bash
curl -s -w "\nHTTP %{http_code}" \
  -X POST https://你的SPACE_URL/v1/chat/completions \
  -H "Authorization: Bearer ${INTERNAL_PSK}" \
  -H "Content-Type: application/json" \
  -d '{"model":"nim-pool","messages":[{"role":"user","content":"say hi"}],"max_tokens":5}'
```

期望：HTTP 200，返回模型回复，`x-omniroute-provider` 响应头为 `nvidia`。

### 验证 2：Round-Robin 轮询

```bash
for i in $(seq 1 5); do
  curl -s -D - -o /dev/null \
    -X POST https://你的SPACE_URL/v1/chat/completions \
    -H "Authorization: Bearer ${INTERNAL_PSK}" \
    -H "Content-Type: application/json" \
    -d '{"model":"nim-pool","messages":[{"role":"user","content":"hi"}],"max_tokens":5}' \
    2>/dev/null | grep -i "x-omniroute-model"
  sleep 2
done
```

期望：5 次请求命中的模型名不完全相同。

### 验证 3：nim-codex

```bash
curl -s -w "\nHTTP %{http_code}" \
  -X POST https://你的SPACE_URL/v1/chat/completions \
  -H "Authorization: Bearer ${INTERNAL_PSK}" \
  -H "Content-Type: application/json" \
  -d '{"model":"nim-codex","messages":[{"role":"user","content":"write hello world in python"}],"max_tokens":20}'
```

期望：HTTP 200。

---

## 十、不可改动清单

以下内容经线上实测验证正确，**禁止修改**：

1. **Dockerfile** `FROM diegosouzapw/omniroute:3.8.43@sha256:517c160643c56ad72e3e305458d961c9a4c87f711393c13020450f9f088d1570` — 钉死 tag+digest，禁止 `:latest`（3.8.46 的 Turbopack 缓存 mmap 失败会导致启动卡死）
2. **Dockerfile** `OMNIROUTE_USE_TURBOPACK=0` 和 `OMNIROUTE_MAX_PENDING_MIGRATIONS=0` — 跨版本防御阀
3. **entrypoint.sh** `DISABLE_SQLITE_AUTO_BACKUP=true` — 防止写锁冲突
4. **gate.js** `INTERNAL_PSK` 鉴权逻辑 — 缺失即 `process.exit(1)`
5. **litestream.yml** `auto-recover: true` — HF 免费层 OOM 后自愈
6. **init** `purge_proxy_db` 函数 — Issue #3332 根治
7. **init** `check_nim_model_health` 函数 — 首次+增量探活
8. **init** `hf_snapshot` 函数 — HF Dataset 配置备份
9. **init** `models_to_json` 中的 `jq -R '{model: .}' | jq -s -c .` — 对象数组格式，不可回退为字符串数组
10. **init** `models_to_json` 中的 `sed 's/^/nvidia\//'` — 路由前缀，消除内置 provider 映射歧义

---

## 十一、故障排查

### 问题：Combo 调用返回 400 "Ambiguous model"

**原因**：`models_to_json` 缺少 `nvidia/` 路由前缀。
**修复**：确认 `models_to_json` 函数包含 `sed 's/^/nvidia\//'`。Factory Reboot 触发增量模式，`repair_combo` 会用带前缀的模型名更新 combo。

### 问题：Combo 调用返回 404 "Function not found for account"

**原因**：NVIDIA 账号无该模型的 Function 调用权限。
**修复**：将 `NIM_PROFILE` 改为 `balanced`（排除 RESTRICTED 模型），或在 NVIDIA 开发者控制台申请 Public API Endpoints 权限。

### 问题：启动卡在 "waiting for OmniRoute health check"

**原因**：基础镜像版本漂移到 3.8.46+，Turbopack 构建 mmap 失败。
**修复**：确认 Dockerfile 使用 `3.8.43@sha256:517c...` 双写，而非 `:latest`。

### 问题：请求返回 502 或 DEGRADED

**原因**：`proxy_registry` 表被写入脏数据，触发全局代理兜底（Issue #3332）。
**修复**：确认 `purge_proxy_db` 在登录后、注册 key 后、初始化末尾各执行一次。检查日志中 `registry=0 assignments=0 proxy_enabled=1剩余=0`。

### 问题：请求返回 413 Payload Too Large

**原因**：`maxBodySizeMb=1`，长上下文请求体超限。
**修复**：在 HF Variables 中添加 `NIM_REQUEST_BODY_LIMIT=4`（4MB）。

### 问题：Litestream 恢复失败

**原因**：首次部署时 R2 无备份，`no matching backups found` 是预期行为。若非首次部署则检查 R2 三件套（`R2_ACCESS_KEY_ID` / `R2_SECRET_ACCESS_KEY` / `R2_ACCOUNT_ID`）是否正确。

### 一键排查

在 HF Settings 中设置 `NIM_MODE=DEBUG`，Factory Reboot，查看 `/data/omni-data/log/init_*.log` 获取完整初始化 trace。

---

## 十二、升级路径

### 镜像升级

当前生产钉死 3.8.43。如需升级到新版本：

1. 单独开一个测试 Space，`FROM diegosouzapw/omniroute:{新版本}@sha256:...`（钉具体 digest）
2. 验证：180s 内 ready + combo 201 + 模型 200
3. 灰度全绿后替换生产 FROM
4. **永远不要在生产直接使用 `:latest`**

### 模型目录更新

NVIDIA 目录会随时间更新（模型新增/下架）。`check_nim_model_health` 的实时探活机制保证：
- 新增模型：手动添加到对应 TIER 数组，Factory Reboot 后自动注册入池
- 下架模型：自动写入 deprecated，从 combo 中剔除，无需手动干预

### 恢复 RESTRICTED 模型

如在 NVIDIA 开发者控制台申请到 Public API Endpoints 权限：
1. 将 `NIM_PROFILE` 改为 `full`
2. Factory Reboot
3. `repair_combo` 自动将 5 个 RESTRICTED 模型重新加入 pool

---

## 十三、Dockerfile 关键设计说明

```dockerfile
# 钉死 tag+digest，禁止浮动 latest
FROM diegosouzapw/omniroute:3.8.43@sha256:517c160643c56ad72e3e305458d961c9a4c87f711393c13020450f9f088d1570

# Turbopack 逃生阀：强制走 webpack，绕开 3.8.45+ 的 Docker Turbopack 缓存 mmap 失败
ENV OMNIROUTE_USE_TURBOPACK=0
# 迁移安全阀：从旧库补多个 migration 时不触发 abort 刷屏中断
ENV OMNIROUTE_MAX_PENDING_MIGRATIONS=0

# Litestream v0.5.9（修复 R2 InvalidContentEncoding + auto-recover）
# asset 命名：litestream-{VER}-linux-{ARCH}.tar.gz（无 v 前缀，x86_64 非 amd64）
ARG LITESTREAM_VERSION=0.5.9

# 容器级健康检查：start-period 与 entrypoint 内部 180s 等待对齐
HEALTHCHECK --interval=30s --timeout=10s --start-period=180s --retries=3 \
    CMD curl -sf http://127.0.0.1:7860/healthz || exit 1
```

---

## 十四、gate.js 鉴权流程

```
客户端 → POST /v1/chat/completions
         Authorization: Bearer <INTERNAL_PSK>
                    │
                    ▼
         gate.js 校验 Bearer === INTERNAL_PSK
         失败 → 401 unauthorized
         成功 → 替换为 Authorization: Bearer <OMNIROUTE_API_KEY>
                    │
                    ▼
         转发至 http://127.0.0.1:20128/v1/chat/completions
```

- `INTERNAL_PSK` 缺失 → gate.js 启动时 `process.exit(1)`
- `OMNIROUTE_API_KEY` env 优先，回退读 `/data/.or-api-key` 文件
- 非 `/v1` 路径直接透传（如管理面板 `/admin`）

---

## 十五、Litestream 数据持久化

```yaml
dbs:
  - path: /data/storage.sqlite
    replica:
      type: s3
      bucket: omniroute-data
      path: db/storage.sqlite
      endpoint: https://${R2_ACCOUNT_ID}.r2.cloudflarestorage.com
      sync-interval: 10s
      auto-recover: true    # v0.5.7+ 遇 LTX 错误自动重置本地追踪状态
snapshot:
  interval: 1h
  retention: 24h
```

**启动流程**：entrypoint 在 OmniRoute 启动前执行 `litestream restore`（从 R2 恢复数据库），OmniRoute 就绪后在后台启动 `litestream replicate`（持续复制 WAL）。

**HF 免费层适配**：免费层容器可能因内存超限被 OOM Kill。`auto-recover: true` 确保重启后 Litestream 自动重置本地追踪状态，从 R2 恢复最新数据，无需手动干预。

---

*本文档由 v4.1.1 部署验证生成，所有结论均基于线上实测和官方源码/文档核实。*
```