我需要先搜索查证方案中的核心技术断言，特别是 HF Space 的 Factory reboot 行为和持久化存储机制，这些是整个方案可行性的基石。

以下是基于搜索查证后的完整方案输出。我将严格遵循抗幻觉五规则，对每一个技术断言标注验证状态，对无法验证的假设明确声明"信息不足"。

---

## 第一部分：方案可行性查证报告

### 查证项一：Docker Tag 覆盖机制

**验证状态：🟢 已确认（Docker Registry 标准行为）**

Docker Registry（含 GHCR、Docker Hub）允许同一个 tag 被覆盖。`docker push` 新镜像到已存在的 tag 会替换该 tag 指向的 manifest digest。这是 Docker Distribution 的标准行为，所有兼容 OCI 标准的 Registry 都支持。此机制无需额外验证——它是 Docker 的基础设计。

### 查证项二：`huggingface-cli download` 在容器内可用

**验证状态：🟢 已确认（官方工具 + 用户实际部署日志验证）**

`huggingface-cli` 是 Hugging Face 官方提供的命令行工具，支持 `--repo-type dataset` 从 Private Dataset 下载文件到本地目录。在 HF Space 容器内执行此命令走 HF 内部网络。用户前序部署日志中已实际验证此路径——bootstrap.sh 的 `huggingface-cli download` 成功拉取了 Dataset 中的脚本并执行。

### 查验项三：HF Space Restart 是否重新拉取 FROM 镜像

**验证状态：🔴 无法确认，基于 Docker 标准行为推断"不重新拉取"**

搜索未找到 HF 官方文档明确说明 Restart 的镜像拉取行为。基于 Docker 标准机制分析：

`docker build` 执行时，`FROM` 指令被解析为 registry 中的 manifest digest，并拉取镜像层缓存到构建节点。后续 `docker run`（容器启动/重启）使用的是已缓存的镜像层。`docker restart`（容器重启）不触发重新 build，不重新解析 FROM tag，不重新拉取镜像层。

HF Space 的 Restart 按钮等效于 `docker restart`——它重启容器进程（重新执行 ENTRYPOINT），不触发 Docker build。因此，如果在 GHCR 上覆盖了 tag 内容，Restart 不会拉取新镜像。此结论基于 Docker 标准行为的逻辑推断，非 HF 官方文档确认。

### 查验项四：HF Space Factory reboot 行为

**验证状态：🟡 信息不足——以下两个关键行为均无法从公开信息确认**

**行为 A——Factory reboot 是否重新拉取 FROM 镜像？**

搜索未找到 HF 官方文档明确说明 Factory reboot 会清除构建缓存并重新执行 `docker build`。我前序对话中声称"Factory reboot 等效于 `docker build --no-cache`，会重新拉取 FROM 镜像"——**此断言缺乏证据支持，我必须撤回此断言的确定性。**

基于第一性原理推断：Factory reboot 的"工厂重置"语义暗示清除缓存、从零重建。如果它不重新 build，那它和 Restart 没有区别，"工厂重置"这个名称就没有意义。但这是语义推断，非事实确认。

**行为 B——Factory reboot 是否清除 `/data` 持久化存储？**

搜索未找到 HF 官方文档明确说明 Factory reboot 是否清除 `/data` 目录。我前序对话中声称"Factory reboot 会清除 `/data` 中的本地数据库"——**此断言同样缺乏证据支持，我必须撤回此断言的确定性。**

HF Space 的持久化存储机制（`/data` 目录）是否在 Factory reboot 后保留，是一个关键未验证点。如果 `/data` 在 Factory reboot 后保留，那么 R2 restore 不需要执行，数据库直接可用。如果 `/data` 被清除，R2 restore 会自动恢复。

**诚实结论**：我无法确认 Factory reboot 的精确行为。方案中对此路径的描述应标注为"待验证假设"。

### 查验项五：HF Space 持久化存储 `/data` 目录

**验证状态：🟡 部分确认（用户部署日志确认存在，但持久化策略未确认）**

用户前序部署日志中明确显示 `DATA_DIR=/data` 和 `SQLite database ready: /data/storage.sqlite`，确认 `/data` 目录是 OmniRoute 的数据目录。HF Space 的 Docker 容器中 `/data` 被挂载为持久化卷——这一点从用户多次 Restart 后数据库仍然存在得到间接验证（日志显示数据库持续运行，未出现空库重建）。

但 HF Space 的持久化存储在以下场景是否保留，无法确认：
- Factory reboot 后
- 长时间 Sleep 后唤醒
- HF 平台维护性重启后

### 查证项六：HF 2026 年 7 月免费层级限制

**验证状态：🟡 基于用户第一手信息，非独立查证确认**

搜索未找到 HF 官方公告或权威媒体报道确认"2026 年 7 月免费 Docker Space 被标记为 Paid"或"1 小时 8 次重建永久卡在 Building"。这些限制信息来自用户的第一手观察。我无法独立验证这些断言的真实性，但将其作为方案设计的前提条件（因为用户是实际部署者，其第一手信息可信度高于第三方报道）。

---

## 第二部分：架构总览

### 设计目标

在 HF Space 免费 Docker 环境下部署 OmniRoute 3.8.43，实现：

1. **日常业务更新零 rebuild**——修改 Dataset 中的脚本后 Restart 即可生效，不触发 Docker 构建
2. **镜像切换近零成本**——通过 GHCR Tag 覆盖 + 触发 1 次重建完成 A/B 镜像切换
3. **数据持久化**——通过 Litestream + Cloudflare R2 实现数据库实时备份与灾难恢复
4. **无上下文可接手**——全套脚本和文档自包含，任何人或 AI 拿到即可理解和执行

### 三层架构

```
┌─────────────────────────────────────────────────────────┐
│              环境层（HF Space 仓库，极低频变更）            │
│                                                         │
│  Dockerfile ── FROM ghcr.io/your/omniroute-base:stable  │
│  bootstrap.sh ── 自适应引导（环境自愈 + 逻辑注入）        │
│  README.md ── HF Space 元数据                            │
│                                                         │
│  变更方式：git push → 1 次 Docker rebuild               │
│  变更频率：每季度 0-1 次（仅镜像切换或 OmniRoute 升级时）  │
└───────────────────────┬─────────────────────────────────┘
                        │ COPY bootstrap.sh
                        ▼
┌─────────────────────────────────────────────────────────┐
│              镜像层（GHCR 私有仓库，Tag 覆盖机制）         │
│                                                         │
│  ghcr.io/your/omniroute-base:stable                     │
│    ├─ 方案 A：官方镜像 diegosouzapw/omniroute:3.8.43 副本│
│    └─ 方案 B：全栈预装镜像（官方 + 工具链）               │
│                                                         │
│  切换方式：本地 docker tag + push 覆盖 → 触发 1 次 rebuild│
│  切换频率：极低频（仅风控收紧或版本升级时）                │
└───────────────────────┬─────────────────────────────────┘
                        │ FROM
                        ▼
┌─────────────────────────────────────────────────────────┐
│              逻辑层（HF Private Dataset，中频变更）        │
│                                                         │
│  entrypoint.sh ── 进程编排（OmniRoute + Gate + Litestream）│
│  gate.js ── 零依赖 PSK 鉴权 + SSE 透传 + 限流            │
│  init-nim-keys.sh ── 25 Key 注册 + Resilience + Combo    │
│  litestream.yml ── SQLite → R2 实时复制                  │
│  package.json ── gate.js 依赖声明（空依赖）               │
│                                                         │
│  更新方式：修改 Dataset → HF Space Restart（零 rebuild）  │
│  更新频率：每周数次（限流参数/Key/模型列表调整）           │
└─────────────────────────────────────────────────────────┘
```

### 数据流

```
客户端请求 → Gate (:7860) →[PSK 鉴权 + 限流]→ OmniRoute (:20128) →[API Key]→ NVIDIA NIM API
                                         ↓
                                   OmniRoute 写入 /data/storage.sqlite
                                         ↓
                                   Litestream 实时复制 → Cloudflare R2
```

### Secrets 清单

| 变量名 | 用途 | 示例值格式 |
|--------|------|-----------|
| `HF_TOKEN` | Dataset 拉取权限 | `hf_xxxxxxxx` |
| `LOGIC_BUCKET_REPO` | Dataset 仓库 ID | `your-name/omni-logic` |
| `INTERNAL_PSK` | Gate 接入令牌 | 70 字符随机字符串 |
| `NIM_KEYS` | NVIDIA NIM API Keys | `nvapi-xxx\nnvapi-yyy` |
| `INITIAL_PASSWORD` | OmniRoute admin 密码 | 自定义 |
| `OMNIROUTE_API_KEY` | env-bypass 模式 API Key | `sk-omniroute-xxx` |
| `R2_ACCESS_KEY_ID` | Cloudflare R2 | R2 Access Key |
| `R2_SECRET_ACCESS_KEY` | Cloudflare R2 | R2 Secret Key |
| `R2_ACCOUNT_ID` | Cloudflare R2 | Account ID |
| `NIM_MODE` | 调试模式（可选） | `DEBUG` |
| `NIM_RPM_LIMIT` | 限流 RPM（可选） | `28` |
| `NIM_CONCURRENT_LIMIT` | 限流并发（可选） | `1` |
| `NIM_MIN_INTERVAL_MS` | 限流间隔（可选） | `100` |

---

## 第三部分：全套脚本

### 文件 1：Dockerfile（环境层 · HF Space 仓库 · 极低频变更）

```dockerfile
# ════════════════════════════════════════════════════════════════
# OmniRoute 永续节点 · Dockerfile
# ════════════════════════════════════════════════════════════════
# 镜像来源由 GHCR Tag 覆盖机制控制。
# 本文件不包含版本号——切换镜像时无需修改本文件。
#
# 镜像切换流程：
#   1. 本地构建/拉取目标镜像
#   2. docker tag + docker push 覆盖 ghcr.io/your-username/omniroute-base:stable
#   3. 更新 IMAGE_VERSION 文件并 git push（触发 1 次 rebuild）
#      或使用 HF Space Settings → Factory reboot（待验证是否清除 /data）
#
# 已知限制（基于用户第一手信息）：
#   - HF 免费 Docker Space 1 小时内 8 次代码修改引起的重建会永久卡在 Building
#   - 7 月后免费账号无法新建 Docker Space（存量 Space 不受影响）
# ════════════════════════════════════════════════════════════════

FROM ghcr.io/your-username/omniroute-base:stable

# 注入自适应引导程序
COPY bootstrap.sh /bootstrap.sh
RUN chmod +x /bootstrap.sh

EXPOSE 7860

# 使用 Node.js 内置模块探活（兼容方案 A 无 curl 的情况）
HEALTHCHECK --interval=30s --timeout=10s --start-period=180s --retries=3 \
    CMD node -e "require('http').get('http://127.0.0.1:7860/healthz',r=>{process.exit(r.statusCode===200?0:1)}).on('error',()=>process.exit(1))" || exit 1

ENTRYPOINT ["/bootstrap.sh"]
```

### 文件 2：bootstrap.sh（环境层 · HF Space 仓库 · 极低频变更）

```bash
#!/bin/sh
# ════════════════════════════════════════════════════════════════
# OmniRoute 永续节点 · 自适应引导程序
# ════════════════════════════════════════════════════════════════
# 兼容两种镜像：
#   方案 A（官方纯副本）：运行时检测工具缺失 → 自动安装（约 60s）
#   方案 B（全栈预装）：工具已存在 → 跳过安装（秒级启动）
#
# 职责：
#   1. 环境自愈（检测并安装缺失工具）
#   2. 从 HF Private Dataset 拉取业务脚本
#   3. 拉取失败时回滚到上次缓存版本
#   4. 移交控制权给 entrypoint.sh
# ════════════════════════════════════════════════════════════════
set -e

echo "[bootstrap] >>> 永续节点启动 <<<"
echo "[bootstrap] 时间: $(date '+%Y-%m-%d %H:%M:%S')"

# ═══ 第一层：环境自愈 ═══
# 检测关键工具是否已预装（方案 B 镜像中已预装，方案 A 需运行时安装）
_need_install=0
for _t in jq sqlite3 python3 huggingface-cli litestream; do
  if ! command -v "$_t" >/dev/null 2>&1; then
    echo "[bootstrap] 缺失工具: $_t"
    _need_install=1
    break
  fi
done

if [ "$_need_install" = "1" ]; then
  echo "[bootstrap] 镜像模式：方案 A（官方纯净版）。补全环境（约 60s）..."

  apt-get update && apt-get install -y --no-install-recommends \
    curl jq python3 python3-pip sqlite3 ca-certificates
  rm -rf /var/lib/apt/lists/*

  pip3 install --no-cache-dir --break-system-packages huggingface_hub

  # 安装 Litestream v0.5.9
  if ! command -v litestream >/dev/null 2>&1; then
    _arch=$(uname -m | sed 's/aarch64/arm64/')
    curl -fsSL \
      "https://github.com/benbjohnson/litestream/releases/download/v0.5.9/litestream-0.5.9-linux-${_arch}.tar.gz" \
      | tar -xz -C /usr/local/bin litestream
    chmod +x /usr/local/bin/litestream
  fi

  echo "[bootstrap] 环境补全完成"
else
  echo "[bootstrap] 镜像模式：方案 B（全栈预装版）。工具链已就绪"
fi

# ═══ 第二层：变量校验 ═══
if [ -z "$HF_TOKEN" ] || [ -z "$LOGIC_BUCKET_REPO" ]; then
  echo "[bootstrap] FATAL: 必须配置 HF_TOKEN 和 LOGIC_BUCKET_REPO"
  echo "[bootstrap] HF_TOKEN: ${HF_TOKEN:+已设置} ${HF_TOKEN:-未设置}"
  echo "[bootstrap] LOGIC_BUCKET_REPO: ${LOGIC_BUCKET_REPO:-未设置}"
  exit 1
fi

# ═══ 第三层：备份当前版本（回滚用） ═══
_BACKUP_AVAILABLE=0
if [ -f /entrypoint.sh ]; then
  cp /entrypoint.sh /entrypoint.sh.bak 2>/dev/null || true
  [ -f /gate/gate.js ] && cp /gate/gate.js /gate/gate.js.bak 2>/dev/null || true
  [ -f /entrypoint-init-nim.sh ] && cp /entrypoint-init-nim.sh /entrypoint-init-nim.sh.bak 2>/dev/null || true
  [ -f /litestream.yml ] && cp /litestream.yml /litestream.yml.bak 2>/dev/null || true
  _BACKUP_AVAILABLE=1
  echo "[bootstrap] 已备份当前版本"
fi

# ═══ 第四层：从 Dataset 拉取业务逻辑 ═══
echo "[bootstrap] 同步存储桶: $LOGIC_BUCKET_REPO ..."

if huggingface-cli download --repo-type dataset "$LOGIC_BUCKET_REPO" \
    --local-dir /tmp/logic --token "$HF_TOKEN" --quiet; then

  # 分发新版本
  cp /tmp/logic/entrypoint.sh /entrypoint.sh
  cp /tmp/logic/gate.js /gate/gate.js
  cp /tmp/logic/init-nim-keys.sh /entrypoint-init-nim.sh
  cp /tmp/logic/litestream.yml /litestream.yml
  [ -f "/tmp/logic/package.json" ] && cp /tmp/logic/package.json /gate/package.json || true

  echo "[bootstrap] 逻辑注入完成"
else
  echo "[bootstrap] ⚠ Dataset 拉取失败！"

  if [ "$_BACKUP_AVAILABLE" = "1" ]; then
    echo "[bootstrap] 回滚到备份版本"
    cp /entrypoint.sh.bak /entrypoint.sh 2>/dev/null || true
    [ -f /gate/gate.js.bak ] && cp /gate/gate.js.bak /gate/gate.js 2>/dev/null || true
    [ -f /entrypoint-init-nim.sh.bak ] && cp /entrypoint-init-nim.sh.bak /entrypoint-init-nim.sh 2>/dev/null || true
    [ -f /litestream.yml.bak ] && cp /litestream.yml.bak /litestream.yml 2>/dev/null || true
  else
    echo "[bootstrap] FATAL: 无备份可用且 Dataset 拉取失败，无法启动"
    exit 1
  fi
fi

chmod +x /entrypoint.sh /entrypoint-init-nim.sh 2>/dev/null || true
rm -rf /tmp/logic

# ═══ 第五层：移交控制权 ═══
echo "[bootstrap] 进入业务生命周期"
exec /entrypoint.sh
```

### 文件 3：README.md（环境层 · HF Space 仓库）

```markdown
---
title: OmniRoute Node
emoji: 🚀
sdk: docker
app_port: 7860
pinned: false
---
# OmniRoute 永续节点

本 Space 仅作为运行底座。业务逻辑由关联的 Dataset 存储桶动态注入。

## 架构概要

- **环境层**：本 Dockerfile + bootstrap.sh（永久不变，变更频率极低）
- **逻辑层**：HF Private Dataset（entrypoint.sh / gate.js / init-nim-keys.sh / litestream.yml）
- **镜像层**：GHCR 私有仓库（Tag 覆盖机制实现 A/B 切换）

## 必需的 Secrets

| 变量名 | 说明 |
|--------|------|
| HF_TOKEN | HF Access Token（需对 Dataset 有 Read 权限） |
| LOGIC_BUCKET_REPO | Dataset 仓库 ID（如 your-name/omni-logic） |
| INTERNAL_PSK | Gate PSK 接入令牌（≥16 字符） |
| NIM_KEYS | NVIDIA NIM Keys（换行分隔） |
| INITIAL_PASSWORD | OmniRoute admin 密码 |
| OMNIROUTE_API_KEY | env-bypass 模式 API Key |
| R2_ACCESS_KEY_ID | Cloudflare R2 Access Key |
| R2_SECRET_ACCESS_KEY | Cloudflare R2 Secret Key |
| R2_ACCOUNT_ID | Cloudflare R2 Account ID |

## 更新方式

- **业务脚本更新**：修改 Dataset 文件 → Settings → Restart（零 rebuild）
- **镜像切换**：覆盖 GHCR tag → 更新 IMAGE_VERSION 文件 push → 1 次 rebuild
```

### 文件 4：Dockerfile.fullstack（本地构建 · 方案 B 镜像）

```dockerfile
# ════════════════════════════════════════════════════════════════
# 全栈预装镜像 · 本地构建后推送到 GHCR 覆盖 stable tag
# 基于 OmniRoute 官方镜像 + 预装所有工具链
# ════════════════════════════════════════════════════════════════
# 构建命令：
#   docker build -f Dockerfile.fullstack -t ghcr.io/your-username/omniroute-base:stable .
#   docker push ghcr.io/your-username/omniroute-base:stable
# ════════════════════════════════════════════════════════════════

FROM diegosouzapw/omniroute:3.8.43

ENV OMNIROUTE_IMAGE_VERSION=3.8.43 \
    OMNIROUTE_USE_TURBOPACK=0 \
    OMNIROUTE_MAX_PENDING_MIGRATIONS=0

USER root

# 预装系统工具（方案 B 优势：构建时装好，运行时秒级启动）
RUN apt-get update && apt-get install -y --no-install-recommends \
    curl jq python3 python3-pip sqlite3 ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# 预装 huggingface-cli（用于 Dataset 拉取）
RUN pip3 install --no-cache-dir --break-system-packages huggingface_hub

# 预装 Litestream v0.5.9（SQLite → R2 实时复制）
ARG LITESTREAM_VERSION=0.5.9
RUN ARCH=$(uname -m | sed 's/aarch64/arm64/') && \
    curl -fsSL \
      "https://github.com/benbjohnson/litestream/releases/download/v${LITESTREAM_VERSION}/litestream-${LITESTREAM_VERSION}-linux-${ARCH}.tar.gz" \
    | tar -xz -C /usr/local/bin litestream && chmod +x /usr/local/bin/litestream

# 目录初始化
RUN mkdir -p /data /gate /tmp/logic && chmod 777 /data /gate /tmp/logic
RUN rm -rf /app/data && ln -sf /data /app/data

# 注意：不 COPY bootstrap.sh
# bootstrap.sh 从 HF Space 仓库通过 Dockerfile COPY 注入
# 这样修改 bootstrap.sh 不需要重新构建全栈镜像
```

### 文件 5：entrypoint.sh（逻辑层 · Dataset）

```bash
#!/bin/bash
# ════════════════════════════════════════════════════════════════
# OmniRoute 3.8.43 · 进程编排总控
# ════════════════════════════════════════════════════════════════
# 职责：
#   1. R2 数据库恢复（空库时从 R2 拉取）
#   2. 启动 OmniRoute 主进程
#   3. 等待健康就绪 + 版本校验
#   4. 后台启动 NIM 初始化（Key 注册 + Resilience + Combo）
#   5. 后台启动 Litestream 复制
#   6. 前台启动 Gate（阻塞）
# ════════════════════════════════════════════════════════════════
set -eo pipefail

OMNIROUTE_PORT="${OMNIROUTE_PORT:-20128}"
EXPOSED_PORT="${EXPOSED_PORT:-7860}"
DATA_DIR="${DATA_DIR:-/data}"
DB_PATH="$DATA_DIR/storage.sqlite"
EXPECTED_OR_VERSION="${OMNIROUTE_IMAGE_VERSION:-3.8.43}"

echo "[entrypoint] =============================================================="
echo "[entrypoint] OmniRoute 3.8.43 · 启动中"
echo "[entrypoint] PORT=$OMNIROUTE_PORT EXPOSED=$EXPOSED_PORT DATA=$DATA_DIR"
echo "[entrypoint] =============================================================="

# ── R2 恢复 ──
if [ -n "$R2_ACCESS_KEY_ID" ] && [ -n "$R2_SECRET_ACCESS_KEY" ] && [ -n "$R2_ACCOUNT_ID" ]; then
  echo "[entrypoint] R2 凭据已配置。执行 Litestream restore..."
  if [ ! -f "$DB_PATH" ] || [ ! -s "$DB_PATH" ]; then
    litestream restore -o "$DB_PATH" "$DB_PATH" 2>/dev/null && \
      echo "[entrypoint] ✓ 数据库已从 R2 恢复" || \
      echo "[entrypoint] ⚠ WARN: restore 失败或无副本。空库启动继续。"
  else
    echo "[entrypoint] 本地数据库已存在且非空，跳过 restore"
  fi
else
  echo "[entrypoint] R2 凭据未配置，跳过 restore"
fi

# ── 启动 OmniRoute ──
echo "[entrypoint] 启动 OmniRoute..."
cd /app
node server.js &
OR_PID=$!
echo "[entrypoint] OmniRoute PID=$OR_PID"

# ── 等待健康就绪 ──
_HEALTH_DEADLINE=$(( $(date +%s) + 180 ))
echo "[entrypoint] 等待健康就绪（最大 180s）..."

while [ $(date +%s) -lt $_HEALTH_DEADLINE ]; do
  if curl -sf "http://127.0.0.1:$OMNIROUTE_PORT/api/monitoring/health" >/dev/null 2>&1; then
    echo "[entrypoint] ✓ 就绪"
    break
  fi
  if ! kill -0 $OR_PID 2>/dev/null; then
    echo "[entrypoint] ✗ OmniRoute 进程已退出"
    exit 1
  fi
  sleep 2
done

# 版本校验（非阻断）
_OR_VER=$(curl -sf "http://127.0.0.1:$OMNIROUTE_PORT/api/monitoring/health" \
  | jq -r '.version // "unknown"' 2>/dev/null || echo "unknown")
echo "[entrypoint] 版本: $_OR_VER (期望 $EXPECTED_OR_VERSION)"

# ── 启动 NIM 初始化（后台） ──
echo "[entrypoint] 启动 NIM 初始化（后台）..."
if [ -f "/entrypoint-init-nim.sh" ] && [ -n "$NIM_KEYS" ]; then
  bash /entrypoint-init-nim.sh &
  INIT_PID=$!
  echo "[entrypoint] Init PID=$INIT_PID"
else
  echo "[entrypoint] NIM 初始化脚本或 NIM_KEYS 缺失，跳过"
fi

# ── 启动 Litestream 复制（后台） ──
if [ -n "$R2_ACCESS_KEY_ID" ] && [ -f /litestream.yml ]; then
  echo "[entrypoint] 启动 Litestream 复制..."
  litestream replicate -config /litestream.yml "$DB_PATH" &
  LS_PID=$!
  echo "[entrypoint] Litestream PID=$LS_PID"
fi

# ── 启动 Gate（前台） ──
echo "[entrypoint] =============================================================="
echo "[entrypoint] 所有服务已启动:"
echo "[entrypoint]   OmniRoute : PID=$OR_PID  port=$OMNIROUTE_PORT"
[ -n "$INIT_PID" ] && echo "[entrypoint]   Init      : PID=$INIT_PID (后台)"
[ -n "$LS_PID" ] && echo "[entrypoint]   Litestream: PID=$LS_PID (后台)"
echo "[entrypoint]   Gate      : port=$EXPOSED_PORT (前台)"
echo "[entrypoint] =============================================================="

# 信号转发
trap 'kill $OR_PID ${INIT_PID:-} ${LS_PID:-} 2>/dev/null; exit 0' SIGTERM SIGINT

# Gate 前台运行（阻塞）
if [ -f /gate/gate.js ]; then
  exec node /gate/gate.js
else
  echo "[entrypoint] FATAL: gate.js 不存在"
  exit 1
fi
```

### 文件 6：gate.js（逻辑层 · Dataset）

```javascript
// ════════════════════════════════════════════════════════════════
// OmniRoute Gate · 零依赖纯 Node.js
// ════════════════════════════════════════════════════════════════
// 仅使用 Node.js 内置模块：http / crypto
// 功能：PSK 鉴权 + SSE 透传 + 内存令牌桶限流
// ════════════════════════════════════════════════════════════════
const http = require('http');
const crypto = require('crypto');

const GATE_PORT = parseInt(process.env.EXPOSED_PORT || '7860', 10);
const UPSTREAM_PORT = parseInt(process.env.OMNIROUTE_PORT || '20128', 10);
const UPSTREAM_HOST = '127.0.0.1';
const PSK = process.env.INTERNAL_PSK || '';
const OR_API_KEY = process.env.OMNIROUTE_API_KEY || '';

// 限流参数
const RPM_LIMIT = parseInt(process.env.NIM_RPM_LIMIT || '28', 10);
const CONCURRENT_LIMIT = parseInt(process.env.NIM_CONCURRENT_LIMIT || '1', 10);
const MIN_INTERVAL_MS = parseInt(process.env.NIM_MIN_INTERVAL_MS || '100', 10);

// 内存令牌桶
let _tokens = RPM_LIMIT;
let _lastRefill = Date.now();
let _lastRequest = 0;
let _active = 0;

function tryAcquire() {
  const now = Date.now();
  const elapsed = now - _lastRefill;
  _tokens = Math.min(RPM_LIMIT, _tokens + (elapsed / 60000) * RPM_LIMIT);
  _lastRefill = now;
  if (_tokens < 1) return false;
  if (_active >= CONCURRENT_LIMIT) return false;
  if (now - _lastRequest < MIN_INTERVAL_MS) return false;
  _tokens -= 1;
  _active += 1;
  _lastRequest = now;
  return true;
}

function release() { _active = Math.max(0, _active - 1); }

// timing-safe PSK 比较
function safeCompare(a, b) {
  const bufA = Buffer.from(a);
  const bufB = Buffer.from(b);
  if (bufA.length !== bufB.length) return false;
  return crypto.timingSafeEqual(bufA, bufB);
}

const server = http.createServer((req, res) => {
  // 健康检查
  if (req.url === '/healthz') {
    res.writeHead(200, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify({ status: 'ok', active: _active, tokens: Math.floor(_tokens) }));
    return;
  }

  // PSK 鉴权
  const auth = req.headers['x-internal-psk'] || req.headers['authorization'] || '';
  const token = auth.startsWith('Bearer ') ? auth.slice(7) : auth;
  if (!PSK || !safeCompare(token, PSK)) {
    res.writeHead(401, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify({ error: 'unauthorized' }));
    return;
  }

  // 限流
  if (!tryAcquire()) {
    console.log(`[gate] 限流触发 (active=${_active}/${CONCURRENT_LIMIT})`);
    res.writeHead(429, { 'Content-Type': 'application/json', 'Retry-After': '3' });
    res.end(JSON.stringify({ error: 'rate_limited', retry_after: 3 }));
    return;
  }

  // 注入 OR_API_KEY
  const headers = { ...req.headers };
  if (OR_API_KEY) headers['authorization'] = `Bearer ${OR_API_KEY}`;
  delete headers['x-internal-psk'];

  // 代理到上游
  const proxyReq = http.request({
    hostname: UPSTREAM_HOST,
    port: UPSTREAM_PORT,
    path: req.url,
    method: req.method,
    headers: headers,
    timeout: 0,
  }, (proxyRes) => {
    res.writeHead(proxyRes.statusCode, proxyRes.headers);
    proxyRes.pipe(res);
  });

  proxyReq.on('error', (e) => {
    console.error(`[gate] upstream error: ${e.message} (${req.url})`);
    if (!res.headersSent) {
      res.writeHead(502, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify({ error: 'bad_gateway', detail: e.message }));
    }
    release();
  });

  req.pipe(proxyReq);
  req.on('close', () => {
    if (!proxyReq.destroyed) proxyReq.destroy();
    release();
  });
});

server.listen(GATE_PORT, '0.0.0.0', () => {
  console.log(`[gate] listening on 0.0.0.0:${GATE_PORT} → ${UPSTREAM_HOST}:${UPSTREAM_PORT}`);
  console.log(`[gate] 限流: ${RPM_LIMIT} RPM / ${CONCURRENT_LIMIT} 并发 / ${MIN_INTERVAL_MS}ms 间隔`);
  console.log(`[gate] PSK 长度=${PSK.length}, OR_API_KEY 源=${OR_API_KEY ? 'env' : 'none'}`);
});
```

### 文件 7：litestream.yml（逻辑层 · Dataset）

```yaml
# ════════════════════════════════════════════════════════════════
# Litestream v0.5.9 配置 · SQLite → Cloudflare R2
# ════════════════════════════════════════════════════════════════
# 重要：使用 v0.5.x 的 `replica` 语法（单数），不是 `replicas`（复数）
# 环境变量在 entrypoint.sh 中通过 litestream replicate -config 引用
# ════════════════════════════════════════════════════════════════
dbs:
  - path: /data/storage.sqlite
    replica:
      type: s3
      bucket: omniroute-data
      path: db/storage.sqlite
      endpoint: https://${R2_ACCOUNT_ID}.r2.cloudflarestorage.com
      access-key-id: ${R2_ACCESS_KEY_ID}
      secret-access-key: ${R2_SECRET_ACCESS_KEY}
      region: auto
      sync-interval: 10s
      auto-recover: false

snapshot:
  interval: 1h
  retention: 24h
```

### 文件 8：package.json（逻辑层 · Dataset）

```json
{
  "name": "omniroute-gate",
  "version": "1.0.0",
  "private": true,
  "description": "Zero-dependency gate for OmniRoute (http + crypto only)",
  "main": "gate.js",
  "dependencies": {}
}
```

### 文件 9：init-nim-keys.sh（逻辑层 · Dataset）

此文件较长，包含完整的 20 步 NIM 初始化流程。以下为关键结构说明和核心段落，完整版本需参考前序对话中确认修复的版本。

**已修复的 BUG 清单（前序对话验证）**：

| BUG | 位置 | 修复 |
|-----|------|------|
| `local` 在函数外使用（8 处） | Step 2/4/5/7/8/13/14/18 | 删除 `local`，无赋值的变量加 `=` |
| 变量名拼写 `$stamp` | §8 nim_probe | 改为 `$_stamp` |
| 变量名拼写 `$m` | Step 13 Context Override | 改为 `$_m` |
| 变量名拼写 `$snapshot_dir` | §HF Dataset 快照 | 改为 `$_snapshot_dir` |
| Key 注册 API 路径 | Step 4 | `/api/providers/nvidia/connections` → `/api/providers` |
| Key 注册请求体 | Step 4 | `{credentials:{apiKey:$key},enabled:true}` → `{provider:"nvidia",apiKey:$key,name:$name,priority:1,testStatus:"unknown"}` |

**核心段落——Step 4 Key 注册（已修复版）**：

```bash
# ── Step 4: 注册 NIM Keys（幂等，409 跳过）────────────────────
echo "[init] Registering NIM keys..."
mapfile -t _KEYS < <(printf '%s\n' "$NIM_KEYS" | sed '/^[[:space:]]*$/d')
_ki=0 _key= _masked= _kresp= _khttp=
for _key in "${_KEYS[@]}"; do
  [ -z "$_key" ] && continue
  _ki=$((_ki+1))
  _masked="nim-$(printf '%02d' $_ki)"
  _kresp="$(_resp omniroute-provider-${_ki}.json)"
  _khttp=$(curl -s -o "$_kresp" -w "%{http_code}" -b "$COOKIE_FILE" \
    -X POST "$BASE_URL/api/providers" \
    -H "Content-Type: application/json" \
    -d "$(jq -n --arg provider "nvidia" --arg apiKey "$_key" --arg name "$_masked" \
      '{provider:$provider, apiKey:$apiKey, name:$name, priority:1, testStatus:"unknown"}')" 2>/dev/null || echo "000")

  case "$_khttp" in
    200|201) echo "[init] $_masked OK"; REGISTERED=$((REGISTERED+1)) ;;
    409)     echo "[init] $_masked exists"; SKIPPED=$((SKIPPED+1)) ;;
    *)       echo "[init] $_masked FAIL HTTP $_khttp"; FAILED=$((FAILED+1)); cat "$_kresp" 2>/dev/null || true ;;
  esac
done
echo "[init] Keys: $REGISTERED registered, $SKIPPED skipped, $FAILED failed."
```

**完整脚本的其他 19 个步骤（Step 0-3, 5-20）结构**：

- Step 0：输入校验（NIM_KEYS / INITIAL_PASSWORD 非空检查）
- Step 1：危险环境变量扫描（check_dangerous_env）
- Step 2：等待 OmniRoute 健康就绪
- Step 3：Cookie Login（三重安全网：200/201 + exit 1 + grep auth_token）
- Step 4：Key 注册（上方已展示）
- Step 5：获取 Provider IDs
- Step 6：ProxyFetch 三重防御（purge_proxy_db）
- Step 7：Resilience PATCH + 读回验证
- Step 8：Settings PATCH（清除代理 + body limit）
- Step 9-12：Compression / Thinking / Memory / CB Reset（部分 API 路径待确认）
- Step 13：per-model Context Override（SQL INSERT OR REPLACE）
- Step 14：增量检测
- Step 15：再次 purge_proxy_db
- Step 16：模型健康检查（查询 NVIDIA 目录过滤已下架模型）
- Step 17：nim_probe（可选探针）
- Step 18：创建/更新 Combos（nim-pool / nim-codex / nim-fast / nim-stable）
- Step 19：Context 累积观测
- Step 20：HF Dataset 快照（best-effort）

**待确认的 API 路径（Step 9-12）**：

以下 API 路径在 OmniRoute 3.8.43 中返回 404/405/400，需要查证正确路径：

| 功能 | 当前路径 | HTTP 状态 | 可能的正确路径 |
|------|---------|-----------|--------------|
| Compression | `PUT /api/compression` | 404 | `PUT /api/settings/compression`（待确认） |
| Thinking | `PUT /api/thinking-budget` | 404 | `PUT /api/settings/thinking-budget`（待确认） |
| Memory legacy | `PATCH /api/memory` | 405 | `PATCH /api/settings`（待确认） |
| Memory extended | `PUT /api/memory/extended` | 400 | `PUT /api/settings/memory`（待确认） |
| CB reset | `POST /api/circuit-breakers/reset` | 404 | `POST /api/resilience/reset`（待确认） |

这些 API 路径错误不影响核心功能——Compression/Thinking/Memory/CB 都是可选配置，即使配置失败也不阻断 Key 注册和推理。建议通过 `curl -s -b "$COOKIE_FILE" "$BASE_URL/api/settings" | jq .` 查看完整 Settings 响应结构，确认正确的 API 路径。

---

## 第四部分：运维操作手册

### 首次部署

**步骤 1——创建 Private Dataset**

在 HF 创建 Private Dataset（如 `your-name/omni-logic`），上传以下 5 个文件：

1. `entrypoint.sh`（文件 5）
2. `gate.js`（文件 6）
3. `init-nim-keys.sh`（文件 9 完整版）
4. `litestream.yml`（文件 7）
5. `package.json`（文件 8）

**步骤 2——推送镜像到 GHCR**

在本地执行（需安装 Docker 并已登录 GHCR）：

```bash
# 方案 A（推荐首次部署）：官方镜像纯副本
docker pull diegosouzapw/omniroute:3.8.43
docker tag diegosouzapw/omniroute:3.8.43 ghcr.io/your-username/omniroute-base:stable
docker push ghcr.io/your-username/omniroute-base:stable
```

**步骤 3——创建 HF Space**

上传 3 个文件到 HF Space 仓库：

1. `Dockerfile`（文件 1）
2. `bootstrap.sh`（文件 2）
3. `README.md`（文件 3）

在 Settings → Variables and Secrets 中配置全部环境变量（见 Secrets 清单）。

**步骤 4——验证**

Space 构建完成后，检查日志确认：

- `[bootstrap] 镜像模式：方案 A` 或 `方案 B`
- `[bootstrap] 逻辑注入完成`
- `[entrypoint] ✓ 就绪`
- `[init] Logged in (HTTP 200)`
- `[init] Keys: 25 registered, 0 skipped, 0 failed`
- `[init] ✓ Resilience 读回全字段一致`
- `[gate] listening on 0.0.0.0:7860`
- `litestream ... snapshot complete`

### 日常更新业务脚本（零 rebuild）

1. 在 Dataset 网页端修改脚本（如 init-nim-keys.sh 调整限流参数）
2. 回到 Space 页面，Settings → Restart Space
3. bootstrap.sh 在 3-5 秒内拉取最新脚本并启动
4. 检查日志确认变更生效

### 镜像 A→B 切换（1 次 rebuild）

```bash
# 1. 本地构建全栈镜像
docker build -f Dockerfile.fullstack -t ghcr.io/your-username/omniroute-base:stable .

# 2. 推送覆盖 stable tag
docker push ghcr.io/your-username/omniroute-base:stable

# 3. 触发 1 次 rebuild（二选一）
#    方式 A（推荐）：更新 IMAGE_VERSION 文件并 push
echo "B-$(date +%Y%m%d)" > IMAGE_VERSION
git add IMAGE_VERSION && git commit -m "switch to fullstack image" && git push

#    方式 B（待验证）：HF Space Settings → Factory reboot
#    注意：Factory reboot 是否清除 /data 尚未验证
#    如果清除 /data，entrypoint.sh 会从 R2 自动恢复数据库
```

### 镜像 B→A 切换（1 次 rebuild）

```bash
# 1. 拉取官方镜像覆盖 tag
docker pull diegosouzapw/omniroute:3.8.43
docker tag diegosouzapw/omniroute:3.8.43 ghcr.io/your-username/omniroute-base:stable
docker push ghcr.io/your-username/omniroute-base:stable

# 2. 触发 1 次 rebuild（同上）
echo "A-$(date +%Y%m%d)" > IMAGE_VERSION
git add IMAGE_VERSION && git commit -m "switch to official image" && git push
```

### 灾难恢复

**场景 1——Dataset 不可访问**

bootstrap.sh 自动回滚到上次缓存的脚本版本。如果首次部署时 Dataset 不可访问（无缓存），Space 启动失败，需修复 Dataset 权限后 Restart。

**场景 2——R2 数据库恢复**

如果本地数据库损坏或被清除，删除 `/data/storage.sqlite` 后 Restart，entrypoint.sh 会从 R2 恢复最新快照。

**场景 3——Space 卡在 Building**

如果因频繁 rebuild 导致 Space 永久卡在 Building，无法通过 git push 恢复。需要联系 HF 支持或升级 PRO 后创建新 Space。

**场景 4——官方镜像 diegosouzapw/omniroute:3.8.43 被删除**

在镜像仍可拉取时推送到自有 GHCR 仓库（首次部署时已完成）。如果未提前备份且官方镜像已消失，需要从 OmniRoute GitHub 源码自行构建。

---

## 第五部分：未验证假设清单

以下假设在方案中被使用但未经独立查证确认。任何人接手方案时应优先验证这些假设：

| 编号 | 假设内容 | 风险等级 | 验证方法 |
|------|---------|---------|---------|
| A1 | HF Space Restart 不重新拉取 FROM 镜像 | 高 | 覆盖 GHCR tag 后 Restart，检查日志是否拉取新镜像 |
| A2 | HF Space Factory reboot 重新拉取 FROM 镜像 | 高 | 覆盖 GHCR tag 后 Factory reboot，检查日志 |
| A3 | HF Space Factory reboot 清除 /data 持久化存储 | 高 | Factory reboot 后检查 /data/storage.sqlite 是否存在 |
| A4 | HF 免费 Docker Space 1 小时 8 次重建永久卡在 Building | 高 | 用户第一手信息，建议保守对待 |
| A5 | HF 7 月后免费账号无法新建 Docker Space | 中 | 用户第一手信息 |
| A6 | Step 9-12 的 API 路径在 3.8.43 中不存在 | 低 | 日志已确认 404/405/400 |
| A7 | `NIM_MIN_INTERVAL_MS=100` 能解决请求 abort 问题 | 中 | 前序日志显示 2200ms 间隔导致客户端重试冲突 |

---

## 第六部分：已知问题与待解决项

### 问题 1——请求在 12-24ms 内 abort

前序部署日志显示所有请求在 12-24ms 内 `disconnect: request_signal_aborted` + `client_disconnect`。根因可能是 Gate 的 2200ms pacing 限流与客户端自动重试行为冲突。建议将 `NIM_MIN_INTERVAL_MS` 从 2200 降为 100，仅保留 RPM 限流。

### 问题 2——多个 API 路径返回 404/405/400

Compression/Thinking/Memory/CB reset 的 API 路径需要查证 OmniRoute 3.8.43 的正确路径。这些是可选配置，不影响核心推理功能。

### 问题 3——Settings 读回 `proxyUrl=<NOT_SET>`

Settings PATCH 成功（HTTP 200），但读回时 `proxyUrl` 字段显示 `<NOT_SET>` 而非 `null`。可能是 3.8.43 的 Settings 响应结构与预期不同。SQL 兜底层（purge_proxy_db）已执行成功，不影响功能。

---

以上为全套方案文档。任何人或 AI 接手时，应首先阅读"未验证假设清单"（第五部分），优先验证 A1-A3 三个高风险假设——它们决定了镜像切换路径的可行性。

*内容由 AI 生成仅供参考*