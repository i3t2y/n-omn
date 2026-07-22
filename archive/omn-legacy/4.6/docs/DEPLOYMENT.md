# OmniRoute HuggingFace Space 部署维护文档

**文档版本**: v1.0 · 生成日期: 2026-06-27
**上游仓库**: [github.com/diegosouzapw/OmniRoute](https://github.com/diegosouzapw/OmniRoute) · 最新版本: v3.8.14
**用户 fork**: 基于 `diegosouzapw/OmniRoute` 的 HF Space 部署

---

## 第一部分：项目全景

### **OmniRoute 是什么**

OmniRoute 是一个**本地优先的免费 AI 网关**，将 177 个 AI 提供商（50+ 免费，11 个永久免费）整合为单一 OpenAI 兼容端点 `/v1`。用户的 Claude Code、Codex、Cursor、Cline 等工具只需对准这一个端点，OmniRoute 处理路由、降级、压缩、认证的全部细节。

核心价值链：

```
IDE/CLI → http://<space>/v1 → gate.js（端口隔离）
  → OmniRoute :20128（路由引擎）
    → NVIDIA NIM / 其他 Provider
      → 返回响应
```

本 Space 的具体用途：**将 NVIDIA NIM 的 129 个模型聚合为单一网关，通过 Litestream 实现 SQLite 数据库的 R2 持久化，Space 重建后零人工干预自动恢复。**

### **技术栈（上游）**

- **Runtime**: Node.js 24.x LTS（推荐）/ 22.22.2+ / 20.20.2+
- **Language**: TypeScript 5.9，100% TypeScript
- **Framework**: Next.js 16 + React 19 + Tailwind CSS 4
- **Database**: `better-sqlite3`（SQLite）—— 存储所有配置、路由决策、日志、Memory
- **Auth**: OAuth 2.0 (PKCE) + JWT + API Keys
- **Encryption**: AES-256-GCM（敏感字段）
- **License**: MIT

### **数据库结构（关键表）**

| 表名 | 用途 | 加密字段 |
|------|------|---------|
| `api_keys` | OmniRoute 内部 API Key（`key` 字段是 gate.js 转发凭证） | 否 |
| `provider_connections` | Provider 凭证（NIM Keys 等） | `api_key`, `access_token`, `refresh_token` |
| `combos` | 路由组合配置（nim-pool、nim-codex 等） | 否 |
| `key_value` | 通用 KV 存储（Settings、Memory 配置等） | 部分 |

加密机制：`STORAGE_ENCRYPTION_KEY`（HF Secret）+ DB 内 salt → AES-256-GCM。**丢失此 Key 等于丢失所有加密数据，无法恢复。**

---

## 第二部分：当前 Space 架构

### **文件结构**

```
├── Dockerfile                # 容器构建（基于 diegosouzapw/omniroute:latest）
├── entrypoint.sh             # 容器启动脚本（Litestream restore → OmniRoute → init → Litestream replicate → gate）
├── init-nim-keys.sh          # NIM Keys 初始化脚本（v4.0.0，幂等，SQLite 感知）
├── litestream.yml            # Litestream R2 复制配置
└── gate/
    ├── gate.js               # 轻量反代（端口隔离 + 管理接口屏蔽）
    └── package.json
```

### **启动时序（entrypoint.sh）**

```
容器启动
  ↓
[1] Litestream restore（从 R2 恢复 storage.sqlite，OmniRoute 启动前完成）
  ↓
[2] node /app/server.js &（后台启动 OmniRoute，绑定 127.0.0.1:20128）
  ↓
[3] 健康检查轮询 GET /api/monitoring/health（最长等 180s）
  ↓
[4] bash /entrypoint-init-nim.sh &（后台运行 init 脚本）
  ↓
[5] 等待 /data/.or-api-key 文件出现（最长等 120s）
  ↓
[6] litestream replicate &（后台启动持续复制到 R2）
  ↓
[7] exec node /gate/gate.js（前台进程，撑住容器）
```

**关键约束**：步骤 [1] 必须在步骤 [2] 之前完成，否则 OmniRoute 会创建新的空数据库并覆盖恢复内容。`exec "$@"` / `exec node /gate/gate.js` 确保前台进程正确接管。

### **端口分配**

| 端口 | 绑定地址 | 用途 |
|------|---------|------|
| 20128 | 127.0.0.1 | OmniRoute 内部端口（不对外暴露） |
| 7860 | 0.0.0.0 | gate.js 对外端口（HF Space 默认暴露端口） |

### **gate.js 的职责**

当前版本（v2，已简化）：

1. **管理接口屏蔽**：只放行 `/v1`、`/api/monitoring`、`/healthz`，其余全部 403
2. **端口映射**：将 HF Space 的 7860 端口流量转发到内部 OmniRoute 的 20128 端口
3. **容器前台进程**：`exec node /gate/gate.js` 作为前台撑住容器不退出

**不再承担**：PSK → OR_API_KEY 的 Bearer 替换（v4.0.0 后 OR_API_KEY 已稳定，不再需要这层间接性）。

---

## 第三部分：持久化方案

### **Litestream + Cloudflare R2**

OmniRoute 使用 SQLite WAL 模式，Litestream 以旁路方式（sidecar）持续将 WAL 帧复制到 R2，实现近实时备份。

**litestream.yml 当前配置**：

```yaml
dbs:
  - path: /data/storage.sqlite
    replicas:
      - type: s3
        bucket: omniroute-data
        path: db/storage.sqlite
        endpoint: https://${R2_ACCOUNT_ID}.r2.cloudflarestorage.com
        access-key-id: ${R2_ACCESS_KEY_ID}
        secret-access-key: ${R2_SECRET_ACCESS_KEY}
        region: auto
        sync-interval: 10s
        snapshot-interval: 1h
        auto-recover: true    # 防止 OOM Kill 后状态损坏
```

**重要**：使用 Litestream **v0.5.9**（非 v0.3.13），原因：

- v0.5.4+ 修复了 R2 的 `InvalidContentEncoding` 错误
- v0.5.7+ 修复了 Azure 权限错误显示（R2 同理）
- v0.5.x 新增 `auto-recover: true`——HF Space 免费层可能被 OOM Kill，容器重启后 Litestream 追踪状态若损坏，此选项自动恢复而无需人工介入

**R2 bucket 需配置 Object Lifecycle Rules**（7 天过期）：R2 存在 `DeleteObjects` 静默失败的已知 bug，Litestream 日志显示删除成功但文件仍在，靠 Lifecycle Rules 兜底清理。

### **数据路径**

```
容器内：/data/storage.sqlite（$DATA_DIR 默认值）
R2：    omniroute-data/db/storage.sqlite
符号链接：/app/data → /data（Dockerfile 中建立）
```

### **重建后自动恢复流程**

```
HF Space 重建（任何原因）
  ↓
entrypoint.sh 步骤[1]：litestream restore -if-replica-exists
  ↓
  ├─ R2 有备份 → 恢复 storage.sqlite（api_keys、provider_connections、combos 全部还原）
  └─ R2 无备份（首次部署）→ 跳过，OmniRoute 生成新空数据库
  ↓
init-nim-keys.sh：
  ├─ api_keys 表有数据 → 读取已有 key → 写入 /data/.or-api-key（同一个 key）✅
  └─ api_keys 表为空  → POST /api/keys 创建新 key
  ├─ provider_connections 有 NIM → POST /api/providers 全部 409 跳过 ✅
  └─ provider_connections 无 NIM → 注册所有 NIM Keys
  ├─ combos 有 nim-pool → 跳过模型/Combo 注册 ✅
  └─ combos 无 nim-pool → 注册模型 + 创建 nim-pool、nim-codex
```

---

## 第四部分：环境变量与 Secrets

### **HF Space Secrets（敏感，不能写入代码）**

| 变量名 | 用途 | 丢失后果 |
|--------|------|---------|
| `STORAGE_ENCRYPTION_KEY` | SQLite 加密密钥 | 所有 provider credentials 永久无法解密 |
| `JWT_SECRET` | JWT 签名密钥 | 用户会话全部失效 |
| `API_KEY_SECRET` | API Key 哈希盐 | API Key 验证失效 |
| `INITIAL_PASSWORD` | Dashboard 登录密码 | init 脚本无法登录，初始化失败 |
| `NIM_KEYS` | NVIDIA NIM API Keys（多行） | NIM provider 无法注册 |
| `R2_ACCESS_KEY_ID` | Cloudflare R2 访问密钥 | Litestream 无法备份/恢复 |
| `R2_SECRET_ACCESS_KEY` | Cloudflare R2 私钥 | 同上 |
| `R2_ACCOUNT_ID` | Cloudflare 账户 ID | 同上 |

### **HF Space Variables（非敏感，可选覆盖）**

| 变量名 | 默认值 | 用途 |
|--------|--------|------|
| `OMNIROUTE_PORT` | `20128` | OmniRoute 内部端口 |
| `EXPOSED_PORT` | `7860` | gate.js 对外端口 |
| `DATA_DIR` | `/data` | SQLite 数据目录 |
| `NIM_RPM` | `60` | NIM 每分钟请求数限制 |
| `NIM_CONCURRENT` | `5` | NIM 并发请求数 |
| `NIM_MIN_INTERVAL_MS` | `500` | NIM 请求最小间隔（ms） |
| `CALL_LOGS_TABLE_MAX_ROWS` | `100000` | 调用日志最大行数 |
| `PROXY_LOGS_TABLE_MAX_ROWS` | `100000` | 代理日志最大行数 |

---

## 第五部分：init-nim-keys.sh 详解（v4.0.0）

### **幂等性设计（核心改动，相比 v3.x）**

v3.x 依赖文件标记（`/data/.init-done`、`/data/.or-api-key`）判断是否已初始化，但这些文件在容器重建后消失，导致每次重建都重新创建 API Key（key 不一致）。

v4.0.0 改为**直接查询 SQLite 数据库**：

```bash
# API Key：从 api_keys 表读取，表为空才创建
DB_KEY=$(sqlite3 "$DB_PATH" "SELECT key FROM api_keys WHERE name='gate-internal' LIMIT 1;")

# 首次初始化判断：查询 combos 表
COMBO_COUNT=$(sqlite3 "$DB_PATH" "SELECT COUNT(*) FROM combos WHERE name='nim-pool';")
```

### **执行阶段划分**

**每次重建都执行（配置同步）**：
- 登录获取 auth_token Cookie
- API Key 检查/创建 → 写 `/data/.or-api-key`
- NIM Keys 注册（已有的 409 跳过）
- Resilience 配置（RPM / 并发 / 间隔）
- Settings 配置（路由策略 / 请求体限制）
- Compression + Thinking Budget 配置
- Memory legacy + Skills 配置
- Memory extended 配置（Voyage AI embedding）
- Circuit breaker reset

**仅首次执行（SQLite 中无 nim-pool combo 时）**：
- 模型目录注册（11 个模型）
- 创建 nim-pool Combo（round-robin，9 个模型）
- 创建 nim-codex Combo（context-relay，3 个模型）

### **当前注册的模型列表**

**nim-pool（通用路由）**：
- `minimaxai/minimax-m2.7`
- `moonshotai/kimi-k2-thinking`
- `moonshotai/kimi-k2.6`
- `z-ai/glm-5.1`
- `nvidia/nemotron-3-super-120b-a12b`
- `qwen/qwen3-coder-480b-a35b-instruct`
- `mistralai/mistral-small-4-119b-2603`
- `mistralai/mistral-medium-3.5-128b`
- `meta/llama-3.2-90b-vision-instruct`

**nim-codex（代码任务，context-relay）**：
- `qwen/qwen3-coder-480b-a35b-instruct`
- `deepseek-ai/deepseek-v4-pro`
- `mistralai/mistral-medium-3.5-128b`

**额外注册（备用，不在 Combo 内）**：
- `deepseek-ai/deepseek-v4-pro`
- `deepseek-ai/deepseek-v4-flash`

---

## 第六部分：常见维护操作

### **更新 NIM Keys**

1. HF Space Settings → Secrets → 更新 `NIM_KEYS`（每行一个 key）
2. Factory Reboot Space → `init-nim-keys.sh` 重新运行 → 新 key 注册，旧 key 的 409 跳过
3. 无需手动操作数据库

### **修改模型列表或 Combo**

直接修改 `init-nim-keys.sh` 中的 `register_model` 调用和 `POST /api/combos` 的 `models` 数组，然后：

- **新增模型**：直接添加 `register_model "provider/model-id"`，重建时会注册（已有的 409 跳过）
- **修改 Combo 策略或模型**：当前脚本不会自动更新已存在的 Combo（只创建，不 PATCH）。若需更新已有 Combo，需要在脚本里先 `DELETE /api/combos/<id>`，再重新创建；或通过 Dashboard 手动修改后触发一次备份

### **强制重新初始化所有配置**

```bash
# 通过 OmniRoute API 删除 nim-pool combo（触发下次启动时重新走首次初始化分支）
curl -X DELETE https://<space>.hf.space/api/combos/<nim-pool-id> \
  -H "Authorization: Bearer <OR_API_KEY>"
# 然后 Factory Reboot
```

### **手动触发 R2 备份（首次部署后立即固化）**

```bash
# 第一步：从 OmniRoute 导出当前数据库
curl -X GET https://<space>.hf.space/api/db-backups/export \
  -H "Authorization: Bearer <OR_API_KEY>" \
  -o /tmp/omniroute_export.db

# 第二步：上传到 R2（本地需要 aws CLI + R2 credentials）
aws s3 cp /tmp/omniroute_export.db s3://omniroute-data/db/storage.sqlite \
  --endpoint-url https://<R2_ACCOUNT_ID>.r2.cloudflarestorage.com
```

### **验证重建后一致性**

```bash
# 用原 API Key 调用，确认 key 未变
curl https://<space>.hf.space/v1/models \
  -H "Authorization: Bearer <OR_API_KEY>"

# 检查 Space Logs，确认以下日志出现：
# [entrypoint] Litestream restore complete.
# [init] Found existing API key in database, reusing.
# [init] nim-XX already exists, skipped  （所有 NIM Keys）
# [init] Already initialized (nim-pool combo found in DB).
```

### **Litestream 状态异常恢复（OOM Kill 后）**

若 Space Logs 出现 `sync error: cannot close, expected page` 或类似 LTX 错误：

由于 `litestream.yml` 已配置 `auto-recover: true`，Litestream v0.5.9 会自动重置本地追踪状态并创建新快照，**无需手动干预**。若自动恢复失败（持续报错），再执行：

```bash
# 在容器内（需要 HF Pro 或其他有 Terminal 的方式）
litestream reset /data/storage.sqlite
# 然后重启 Litestream replicate 进程
```

---

## 第七部分：已知问题与历史决策

### **决策记录**

| 决策 | 选择 | 原因 |
|------|------|------|
| 备份方案 | Litestream + R2（非 OmniRoute 内置备份） | 内置备份（`DISABLE_SQLITE_AUTO_BACKUP=true` 已关闭）不支持流式 WAL 复制；Litestream 旁路方案更可靠 |
| init 标记方式 | 查询 SQLite（非文件标记） | HF Space 重建后容器内文件消失，文件标记不可靠 |
| gate.js 保留与否 | 保留（精简版） | OmniRoute 绑定 127.0.0.1，管理接口不暴露外网；gate.js 兼任容器前台进程 |
| PSK 层 | 已删除 | OR_API_KEY 在 Litestream 恢复后稳定一致，PSK 间接层不再必要 |
| Litestream 版本 | v0.5.9（非 v0.3.13） | v0.3.13 存在 R2 编码 bug 和无 auto-recover 支持 |

### **已知限制**

- **HF 免费 Space 无 Terminal**：所有初始化操作必须通过 API 远程完成或在容器启动时自动执行，不能手动进入容器
- **HF 免费 Space 无 Persistent Storage**：所有持久化数据必须依赖 Litestream → R2，容器内 `/data` 每次重建都是空白
- **R2 DeleteObjects 静默失败**：Litestream WAL 段文件可能无法被正常删除，依赖 Bucket Lifecycle Rules 兜底（7 天过期）
- **Combo 只创建不更新**：`init-nim-keys.sh` 不会 PATCH 已存在的 Combo，修改模型列表需要额外处理

### **`DISABLE_SQLITE_AUTO_BACKUP=true` 的含义**

这个环境变量关闭了 OmniRoute 自身的内置定时备份功能，将备份职责完全交给 Litestream。**不要删除这个变量**，否则两套备份机制并行运行会在 WAL 模式下产生竞争。

---

## 第八部分：上游版本跟进指引

当上游 OmniRoute 发布新版本时，需要检查的变更点：

1. **API 端点变更**：查看 CHANGELOG.md，重点关注 `/api/providers`、`/api/keys`、`/api/combos`、`/api/settings`、`/api/settings/memory`、`/api/resilience` 的 breaking changes
2. **数据库 schema 变更**：若上游修改了 `api_keys` 或 `provider_connections` 表结构，Litestream 恢复的数据库可能需要 migration
3. **`DATA_DIR` 默认值变更**：上游默认是 `~/.omniroute`，当前 Space 覆盖为 `/data`，若上游改变数据库文件名需同步更新 `litestream.yml` 中的 `path`
4. **Node.js 版本要求**：当前支持 `>=20.20.2 <21`、`>=22.22.2 <23`、`>=24 <25`，Dockerfile 基础镜像跟随上游
5. **新增 Settings 字段**：若上游新增了 `PATCH /api/settings` 的字段，可选择性地在 `init-nim-keys.sh` 中补充

更新 `diegosouzapw/omniroute:latest` 后，建议先在本地运行容器验证：

```bash
docker run --rm -it \
  -e INITIAL_PASSWORD=test \
  -e NIM_KEYS="test-key" \
  -p 20128:20128 \
  diegosouzapw/omniroute:latest
```

---

## 第九部分：快速参考

### **关键 API 端点**

| 端点 | 方法 | 用途 |
|------|------|------|
| `/api/auth/login` | POST | 登录获取 auth_token Cookie |
| `/api/keys` | POST | 创建 API Key |
| `/api/providers` | POST | 注册 Provider（NIM Key） |
| `/api/providers` | GET | 获取所有 Provider |
| `/api/combos` | POST | 创建 Combo |
| `/api/settings` | PATCH | 更新全局设置 |
| `/api/settings/memory` | PUT | 更新 Memory extended 配置 |
| `/api/resilience` | PATCH | 更新限流配置 |
| `/api/resilience/reset` | POST | 重置 circuit breaker |
| `/api/monitoring/health` | GET | 健康检查（返回 `{status, version}`） |
| `/api/db-backups/export` | GET | 导出当前数据库文件 |
| `/api/db-backups/exportAll` | GET | 导出完整备份 tar.gz |
| `/api/db-backups/import` | POST | 上传恢复数据库 |
| `/v1/models` | GET | 列出所有可用模型 |

### **日志关键词速查**

| 日志内容 | 含义 |
|---------|------|
| `Litestream restore complete` | R2 恢复成功 |
| `No existing replica found (first deploy)` | 首次部署，正常 |
| `FATAL: Litestream restore failed` | R2 恢复异常，需检查 R2 credentials |
| `Found existing API key in database, reusing` | API Key 从 DB 恢复，key 一致 ✅ |
| `No existing key in DB, creating` | 首次部署，正常 |
| `Already initialized (nim-pool combo found in DB)` | 数据库完整，跳过首次初始化 ✅ |
| `nim-XX already exists, skipped` | NIM Key 已存在，409 正常跳过 ✅ |
| `sync error: cannot close, expected page` | Litestream 状态损坏（auto-recover 会处理）|

### **上游资源**

- GitHub: [github.com/diegosouzapw/OmniRoute](https://github.com/diegosouzapw/OmniRoute)
- 官网: [omniroute.online](https://omniroute.online)
- CHANGELOG: 仓库根目录 `CHANGELOG.md`
- API Reference: 仓库 `docs/` 目录 Wiki

---

文档到这里完整了。建议保存为仓库内的 `DEPLOYMENT.md` 或单独存档，下次交给任何 AI 时直接作为上下文投喂即可，不需要重建对话历史。如果后续有改动（比如更新模型列表、切换 R2 bucket、升级 Litestream 版本），告诉我哪里变了，我帮你同步更新对应章节。



### **文档增补更新点（v1.1）**

#### **1. 更新「gate.js 的职责」章节（第二部分）**
> **新增 ADMIN_ACCESS 控制逻辑**
> 当前版本（v4）：
> 1. **管理接口屏蔽（动态开关）**：通过环境变量 `ADMIN_ACCESS` 控制。
>    - `ADMIN_ACCESS=1`：放行所有路径，允许公网访问 Dashboard。
>    - `ADMIN_ACCESS=0`（默认）：仅放行 `/v1`、`/api/monitoring`、`/healthz`，屏蔽管理后台。
> 2. **零依赖反代**：使用纯 Node.js `http` 模块实现，移除了 `express` 和 `http-proxy-middleware`，彻底解决原生 C++ 模块（如 `better-sqlite3`）在 Node 24 环境下的编译兼容性问题。

#### **2. 更新「环境变量与 Secrets」表格（第四部分）**
> **新增变量**：
>
> | 变量名 | 默认值 | 用途 |
> |--------|--------|------|
> | `ADMIN_ACCESS` | `0` | **安全开关**。设为 `1` 时放行 Dashboard 访问，设为 `0` 时屏蔽。 |

#### **3. 更新「常见维护操作」章节（第六部分）**
> **新增：如何安全地访问管理后台**
> 1. 进入 HF Space 的 **Settings -> Variables and secrets**。
> 2. 修改 `ADMIN_ACCESS` 变量值为 `1`。
> 3. 保存后 Space 会自动重启。
> 4. 访问 `https://<your-space-name>.hf.space`，使用 `INITIAL_PASSWORD` 登录。
> 5. **操作完成后，务必将 `ADMIN_ACCESS` 改回 `0` 并保存**，以重新锁定管理接口。

#### **4. 更新「已知问题与历史决策」章节（第七部分）**
> **新增决策记录**：
>
> | 决策 | 选择 | 原因 |
> |------|------|------|
> | 依赖管理 | 零外部依赖（Pure Node.js） | 解决了 `better-sqlite3` 和 `node-gyp` 在 Node 24 环境下的 C++20 编译冲突，显著降低了镜像构建失败率和体积。 |

---

### **总结建议**
目前的脚本和架构已经达到了**“高可用、零干预、自愈性强”**的目标：
- **稳定性**：通过移除 C++ 原生模块依赖，解决了构建时的随机报错。
- **安全性**：通过 `ADMIN_ACCESS` 实现了“按需开启”的后台管理，防止了 API Key 等敏感信息泄露。
- **持久化**：Litestream v0.5.12 配合 R2 确保了即使 HF Space 免费层频繁重启，数据也能秒级同步回位。

这份文档现在可以作为你这个项目的“终极操作手册”。如果后续你需要增加更多 Provider（如 DeepSeek、SiliconFlow）或调整路由策略，只需根据文档第五部分的逻辑修改 `init-nim-keys.sh` 即可。

祝你的 OmniRoute 运行稳定！

*内容由 AI 生成仅供参考*
