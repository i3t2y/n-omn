我先对文档中标记的关键未验证假设进行联网查证，重点是 HF Space 的 Factory reboot / Restart 行为、`/data` 持久化机制，以及 Litestream 配置语法等基石性断言。

第一轮查证已有关键发现：HF 的持久化存储（Persistent Storage）疑似已下线，这将直接影响方案中 `/data` 持久化的核心假设。我继续查证 HF 官方文档和 Litestream 语法。

官方文档确认了两个决定性事实：免费磁盘是临时的、旧版持久化存储已被 Storage Buckets 取代；2026 年 7 月起 Docker SDK 新建 Space 需要 PRO。我再查证 Storage Buckets 细节和 OmniRoute 的 API 路径。

HF 侧的关键事实已全部查证完毕。现在深入 OmniRoute 官方 Wiki 的 API Reference，核实 Step 9-12 的 API 路径。

OmniRoute 的 API 路径已全部核实完毕。最后核实 Litestream v0.5 的精确配置语法，确保配置文件字段名正确。

查证工作已全部完成，且有两个**改变方案根基**的重大发现。先给出查证结论与修正说明，然后输出完整的 v2.0 自包含方案文档。

---

## 第一部分：联网查证结论（2026-07-18）

### **平台级重大事实（原文档假设被推翻或确认）**

| # | 原文档断言 | 查证结果 |
|---|-----------|---------|
| 1 | `/data` 是 HF 挂载的持久化卷 | **❌ 错误，已推翻**。HF 官方文档明确："Every Space comes with a small amount of disk storage. This disk space is **ephemeral**, meaning its content will be lost if your Space restarts or is stopped." 免费层 50GB 磁盘全部是非持久的。旧的付费 Persistent Storage（small/medium/large 三档）**已下线**，由新的 **Storage Buckets**（可挂载卷，有免费额度）取代 |
| 2 | Restart 不重新拉取 FROM 镜像（A1） | **✅ 确认**。社区与 HF 员工证实：Restart 使用缓存镜像，"the source code is taken from the cache until you run a factory rebuild" |
| 3 | Factory reboot 清缓存重建（A2） | **✅ 确认**。HF 员工原话："That will rebuild the space with a clean cache"——即等效 `docker build --no-cache`，会重新解析 FROM tag |
| 4 | Factory reboot 清除 `/data`（A3） | **✅ 确认等效成立**。既然磁盘本身 ephemeral，任何重建/容器回收都会产生全新文件系统，`/data` 必被清空。R2 restore 路径不是"备选"，而是**数据存续的主路径** |
| 5 | 2026 年 7 月后免费账号无法新建 Docker Space（A5） | **✅ 确认**。2026-07-08 起多名用户报告 Docker SDK 标记为 Paid，官方提示 "Static Spaces are free for everyone, but hosting Gradio and Docker Spaces on free cpu-basic requires a PRO subscription"。存量 Space 暂可继续运行 |
| 6 | 出站网络限制 | **✅ 官方确认**：仅允许 80/443/8080 端口出站。R2（443）、NIM API（443）、GitHub Releases（443）、HF Hub（443）均不受影响 |
| 7 | 免费层休眠策略 | **✅ 官方确认**：cpu-basic 无活动 48 小时后自动休眠，任何人访问 Space 页面会自动唤醒（唤醒 = 冷启动，ephemeral 数据丢失，走 R2 restore） |
| 8 | 1 小时 8 次重建永久卡 Building（A4） | **🟡 仍无法独立证实**，维持用户一手信息定性；但论坛中 "Perpetually building" 类报告大量存在，风险真实，保守对待的策略不变 |
| 9 | GHCR Tag 覆盖机制 | **✅ 确认**（OCI 标准行为，无需改动） |

上述事实来源：[Hugging Face 官方文档·Disk usage on Spaces](https://huggingface.co/docs/hub/spaces-storage) [Hugging Face 官方文档·Spaces Overview](https://huggingface.co/docs/hub/spaces-overview) [Hugging Face 官方文档·Storage Buckets](https://huggingface.co/docs/hub/storage-buckets) [Hugging Face Forums·Docker SDK Paid](https://discuss.huggingface.co/t/docker-sdk-now-marked-as-paid-when-creating-a-new-space/177580) [Hugging Face Forums·Force rebuild](https://discuss.huggingface.co/t/can-i-force-rebuild-a-huggingface-space/18419) [Hugging Face Forums·Restart does not pull](https://discuss.huggingface.co/t/restarting-a-space-does-not-pulls-last-version/142838)

### **OmniRoute API 路径（Step 9-12 全部查实）**

对照官方 Wiki 的完整 API Reference，原文档中全部 404/405/400 路径均已找到正确答案：[OmniRoute Wiki·API Reference](https://github.com/diegosouzapw/OmniRoute/wiki/API-Reference)

| 功能 | 原错误路径 | 官方正确路径（已确认） |
|------|-----------|----------------------|
| Compression | `PUT /api/compression` (404) | `GET/PUT /api/settings/compression` |
| Thinking Budget | `PUT /api/thinking-budget` (404) | `GET/PUT /api/settings/thinking-budget` |
| Memory legacy | `PATCH /api/memory` (405) | `/api/memory` 仅支持 GET/POST；**v3.8.30+ 记忆默认关闭**，无需配置，此步骤删除 |
| Memory extended | `PUT /api/memory/extended` (400) | **该端点不存在**，删除此步骤 |
| CB Reset | `POST /api/circuit-breakers/reset` (404) | `POST /api/resilience/reset`（需管理端鉴权，Cookie 可用） |
| 代理清除（Step 8 改进） | `PATCH /api/settings` | 有专用端点 `GET/PUT /api/settings/proxy` |
| Resilience | — | `GET/PATCH /api/resilience` 确认；官方明确 PATCH 体结构为 `providerBreaker.oauth` / `providerBreaker.apikey`，各含 `degradationThreshold`、`failureThreshold`、`resetTimeoutMs` |

Memory 默认关闭的官方依据：[OmniRoute·MEMORY.md](https://github.com/diegosouzapw/OmniRoute/blob/main/docs/frameworks/MEMORY.md)

### **Litestream 配置（语法确认 + 发现一个真 BUG）**

litestream.yml 的全部字段（`replica` 单数、`type: s3`、`endpoint`、`sync-interval`、`auto-recover`、`snapshot` 块、`${VAR}` 环境变量展开）均在 v0.5 官方配置参考中逐字确认有效。但 **entrypoint.sh 的 restore 命令有 BUG**：`litestream restore -o "$DB_PATH" "$DB_PATH"` 缺少 `-config /litestream.yml`，不写配置路径时 Litestream 会去读默认的 `/etc/litestream.yml`（不存在），导致 restore 永远静默失败、只靠 `||` 分支兜底——v2.0 已修复。[Litestream 官方文档·Configuration File](https://litestream.io/reference/config)

### **本轮流产出的最重要发现：12-24ms abort 的真正根因**

原文档把"所有请求在 12-24ms 内 `request_signal_aborted`"归因于 2200ms pacing 与客户端重试冲突（假设 A7）。查证 Node.js 流语义后可以确定：**根因在 gate.js 的 `req.on('close')` 处理器**。`http.IncomingMessage` 是 `autoDestroy: true` 的 Readable 流，客户端请求体（小 JSON，正好十几毫秒传完）被 `req.pipe(proxyReq)` 消费完毕后，流触发 `end` → 自动销毁 → 立即触发 `close` → 处理器执行 `proxyReq.destroy()` **把刚建立的上游请求杀掉**，OmniRoute 侧于是记录 `request_signal_aborted`，客户端随即断连。12-24ms 正是请求体上传耗时，与日志严丝合缝。调 `MIN_INTERVAL_MS` 永远修不好它。正确做法是在 `res.on('close')` 里做清理（响应真正结束/中止时才释放并发槽并销毁上游）。**A7 撤回，v2.0 的 gate.js 已按此修复。**

---

## 第二部分：OmniRoute 永续节点方案 v2.0（自包含完整版）

> 本文档不依赖任何前序对话。任何人或 AI 拿到本文档即可完成部署、运维与故障恢复。所有技术断言标注验证状态：🟢 已查证 / 🟡 部分确认 / 🔴 待验证。

# 第 0 章 · 接手须知（5 分钟导读）

本方案在 Hugging Face Space（免费 CPU，Docker SDK）上运行 OmniRoute 3.8.43，作为 NVIDIA NIM API 的中转网关。核心设计思想是**把"会变的东西"和"不能变的东西"彻底分离**：

- **Space 仓库（环境层）**只有 3 个文件，改一次就要触发一次 Docker 重建，而重建在 HF 风控下是稀缺资源，所以这一层设计为"永不需要改"；
- **业务脚本（逻辑层）**全部放在 HF Private Dataset 里，每次容器启动时由引导程序拉取——改脚本后点 Restart 即生效，**零重建**；
- **Docker 镜像（镜像层）**放在自己的 GHCR 仓库用固定 tag `:stable` 引用，换镜像 = 本地覆盖 tag + 触发一次重建；
- **数据（SQLite）**落盘即丢（HF 免费磁盘是临时的），靠 Litestream 实时复制到 Cloudflare R2，启动时自动恢复。

# 第 1 章 · 平台事实与硬约束（2026-07-18 查证）

以下全部是已查证事实，是方案设计的边界条件：

| 约束 | 内容 | 状态 |
|------|------|------|
| 磁盘 | 免费层磁盘 **ephemeral**，Restart/停止即可能丢失；不要把它当存储用 | 🟢 |
| 持久化 | 旧付费 Persistent Storage 已下线；官方替代是 **Storage Buckets**（可挂载到容器路径，有免费额度） | 🟢 |
| 网络出站 | 仅 80/443/8080。本方案所有外部依赖均走 443 | 🟢 |
| 休眠 | 免费 cpu-basic 闲置 48h 休眠；被访问自动唤醒（冷启动） | 🟢 |
| 重建 | 每次 git push 触发重建；Factory reboot = 清缓存完整重建；Restart = 用缓存镜像直接起容器 | 🟢 |
| 风控 | Docker SDK 新建已需 PRO（2026-07 起）；存量 Space 暂不受影响。**现有 Space 是不可再生资产，避免一切非必要重建** | 🟢/🟡 |
| Secrets | 修改 Secrets/硬件配置会触发 Restart（不重建） | 🟢 |
| 资源 | 2 vCPU / 16GB RAM / 50GB 临时盘 | 🟢 |

**推论**：R2 备份不是灾难恢复手段，而是数据的**唯一可靠载体**；本地 SQLite 只是它的运行时缓存。

# 第 2 章 · 架构总览

```
客户端 → [HF 边缘 TLS] → Gate :7860（PSK 鉴权 + 限流）
                            │
                            ▼
                    OmniRoute :20128（Key 池 / 路由 / Combo）
                            │ 写 /data/storage.sqlite（临时盘）
                            ▼
                    Litestream 实时复制 → Cloudflare R2（数据主副本）

启动链：HF 构建镜像(FROM ghcr/...:stable + COPY bootstrap.sh)
  → 容器启动 → bootstrap.sh（自检环境 + 从 Dataset 拉脚本，失败回滚）
  → entrypoint.sh（R2 restore → OmniRoute → 健康等待 → init 后台 → Litestream 后台 → Gate 前台）
```

三层变更成本：

| 层 | 位置 | 变更方式 | 成本 |
|---|------|---------|------|
| 环境层 | Space 仓库：Dockerfile / bootstrap.sh / README.md | git push | 1 次重建（极力避免） |
| 镜像层 | GHCR：`ghcr.io/<you>/omniroute-base:stable` | 本地 tag 覆盖 + 推 IMAGE_VERSION 文件触发重建 | 1 次重建 |
| 逻辑层 | Private Dataset：entrypoint.sh / gate.js / init-nim-keys.sh / litestream.yml / package.json | 网页端改文件 → Space Restart | **零重建** |

# 第 3 章 · Secrets 清单（Space Settings → Variables and secrets）

| 变量 | 必需 | 说明 |
|------|------|------|
| `HF_TOKEN` | ✅ | 对 Dataset 有读权限的 HF token |
| `LOGIC_BUCKET_REPO` | ✅ | Dataset ID，如 `your-name/omni-logic` |
| `INTERNAL_PSK` | ✅ | Gate 接入令牌，建议 ≥48 位随机串 |
| `NIM_KEYS` | ✅ | NVIDIA NIM Key，换行分隔 |
| `INITIAL_PASSWORD` | ✅ | OmniRoute 管理密码（官方确认登录回退到此密码） |
| `OMNIROUTE_API_KEY` | ✅ | OmniRoute env-bypass API Key，Gate 注入上游用 |
| `R2_ACCESS_KEY_ID` / `R2_SECRET_ACCESS_KEY` / `R2_ACCOUNT_ID` | ✅ | Cloudflare R2 凭据（数据主路径，不可省） |
| `NIM_RPM_LIMIT` / `NIM_CONCURRENT_LIMIT` / `NIM_MIN_INTERVAL_MS` | 可选 | 默认 28 / 1 / 100 |
| `NIM_PROBE` | 可选 | `1` 时 init 末尾对每个 Key 做一次目录探针 |

# 第 4 章 · 全套文件

## 4.1 Dockerfile（Space 仓库）

```dockerfile
# OmniRoute 永续节点 · Dockerfile（环境层，极低频变更）
# 镜像由 GHCR tag 覆盖机制控制；本文件不含版本号。
FROM ghcr.io/your-username/omniroute-base:stable

COPY bootstrap.sh /bootstrap.sh
RUN chmod +x /bootstrap.sh

EXPOSE 7860

# 用 Node 内置模块探活（兼容无 curl 的镜像 A）。
# 注：HF 有自有健康检查机制，本 HEALTHCHECK 为补充，无害。
HEALTHCHECK --interval=30s --timeout=10s --start-period=180s --retries=3 \
    CMD node -e "require('http').get('http://127.0.0.1:7860/healthz',r=>{process.exit(r.statusCode===200?0:1)}).on('error',()=>process.exit(1))" || exit 1

ENTRYPOINT ["/bootstrap.sh"]
```

## 4.2 bootstrap.sh（Space 仓库）

```bash
#!/bin/sh
# OmniRoute 永续节点 · 自适应引导
# 职责：环境自愈 → 变量校验 → 备份旧版 → 从 Dataset 拉取业务脚本（失败回滚）→ 移交
set -e
echo "[bootstrap] >>> 启动 $(date '+%F %T') <<<"

# ── 1. 环境自愈：检测工具，缺失则补装（镜像 A 约 60s；镜像 B 秒过）──
_need=0
for t in jq sqlite3 python3 curl; do
  command -v "$t" >/dev/null 2>&1 || { echo "[bootstrap] 缺失: $t"; _need=1; break; }
done
command -v litestream >/dev/null 2>&1 || _need=1
{ command -v huggingface-cli >/dev/null 2>&1 || command -v hf >/dev/null 2>&1; } || _need=1

if [ "$_need" = "1" ]; then
  echo "[bootstrap] 镜像 A 模式：补全环境..."
  apt-get update && apt-get install -y --no-install-recommends \
    curl jq python3 python3-pip sqlite3 ca-certificates && rm -rf /var/lib/apt/lists/*
  pip3 install --no-cache-dir --break-system-packages "huggingface_hub[cli]"
  if ! command -v litestream >/dev/null 2>&1; then
    _a=$(uname -m | sed 's/aarch64/arm64/')
    curl -fsSL "https://github.com/benbjohnson/litestream/releases/download/v0.5.9/litestream-0.5.9-linux-${_a}.tar.gz" \
      | tar -xz -C /usr/local/bin litestream && chmod +x /usr/local/bin/litestream
  fi
else
  echo "[bootstrap] 镜像 B 模式：工具链就绪"
fi

# ── 2. 变量校验 ──
[ -n "$HF_TOKEN" ] && [ -n "$LOGIC_BUCKET_REPO" ] || {
  echo "[bootstrap] FATAL: 缺 HF_TOKEN 或 LOGIC_BUCKET_REPO"; exit 1; }

# ── 3. 备份当前脚本（仅存活在容器临时层，供同一容器生命周期内回滚）──
_bak=0
[ -f /entrypoint.sh ] && {
  cp /entrypoint.sh /entrypoint.sh.bak
  [ -f /gate/gate.js ] && cp /gate/gate.js /gate/gate.js.bak
  [ -f /entrypoint-init-nim.sh ] && cp /entrypoint-init-nim.sh /entrypoint-init-nim.sh.bak
  [ -f /litestream.yml ] && cp /litestream.yml /litestream.yml.bak
  _bak=1; echo "[bootstrap] 已备份当前版本"; }

# ── 4. 拉取逻辑层（新版 hf CLI 优先，huggingface-cli 兜底）──
echo "[bootstrap] 同步 Dataset: $LOGIC_BUCKET_REPO"
_dl() {
  if command -v hf >/dev/null 2>&1; then
    hf download "$LOGIC_BUCKET_REPO" --repo-type dataset --local-dir /tmp/logic --token "$HF_TOKEN" --quiet
  else
    huggingface-cli download --repo-type dataset "$LOGIC_BUCKET_REPO" \
      --local-dir /tmp/logic --token "$HF_TOKEN" --quiet
  fi
}
if _dl; then
  mkdir -p /gate
  cp /tmp/logic/entrypoint.sh /entrypoint.sh
  cp /tmp/logic/gate.js /gate/gate.js
  cp /tmp/logic/init-nim-keys.sh /entrypoint-init-nim.sh
  cp /tmp/logic/litestream.yml /litestream.yml
  [ -f /tmp/logic/package.json ] && cp /tmp/logic/package.json /gate/package.json
  echo "[bootstrap] 逻辑注入完成"
elif [ "$_bak" = "1" ]; then
  echo "[bootstrap] ⚠ 拉取失败，回滚备份版本"
  cp /entrypoint.sh.bak /entrypoint.sh
  [ -f /gate/gate.js.bak ] && cp /gate/gate.js.bak /gate/gate.js
  [ -f /entrypoint-init-nim.sh.bak ] && cp /entrypoint-init-nim.sh.bak /entrypoint-init-nim.sh
  [ -f /litestream.yml.bak ] && cp /litestream.yml.bak /litestream.yml
else
  echo "[bootstrap] FATAL: 拉取失败且无备份"; exit 1
fi

chmod +x /entrypoint.sh /entrypoint-init-nim.sh 2>/dev/null || true
rm -rf /tmp/logic
echo "[bootstrap] 进入业务生命周期"
exec /entrypoint.sh
```

## 4.3 README.md（Space 仓库）

```markdown
---
title: OmniRoute Node
emoji: 🚀
sdk: docker
app_port: 7860
pinned: false
---
# OmniRoute 永续节点

运行底座。业务逻辑由关联 Dataset 动态注入；数据经 Litestream 实时备份至 R2。
运维手册见方案文档 v2.0 第 5-7 章。
```

## 4.4 Dockerfile.fullstack（本地构建镜像 B）

```dockerfile
# 全栈预装镜像（镜像 B）：官方镜像 + 工具链
# 构建：docker build -f Dockerfile.fullstack -t ghcr.io/your-username/omniroute-base:stable .
FROM diegosouzapw/omniroute:3.8.43

ENV OMNIROUTE_IMAGE_VERSION=3.8.43 \
    OMNIROUTE_USE_TURBOPACK=0 \
    OMNIROUTE_MAX_PENDING_MIGRATIONS=0

USER root
RUN apt-get update && apt-get install -y --no-install-recommends \
    curl jq python3 python3-pip sqlite3 ca-certificates \
    && rm -rf /var/lib/apt/lists/*
RUN pip3 install --no-cache-dir --break-system-packages "huggingface_hub[cli]"
RUN ARCH=$(uname -m | sed 's/aarch64/arm64/') && \
    curl -fsSL "https://github.com/benbjohnson/litestream/releases/download/v0.5.9/litestream-0.5.9-linux-${ARCH}.tar.gz" \
    | tar -xz -C /usr/local/bin litestream && chmod +x /usr/local/bin/litestream
RUN mkdir -p /data /gate /tmp/logic && chmod 777 /data /gate /tmp/logic \
    && rm -rf /app/data && ln -sf /data /app/data
# 不 COPY bootstrap.sh——它由环境层 Dockerfile 注入
```

## 4.5 entrypoint.sh（Dataset · 已修复 restore BUG）

```bash
#!/bin/bash
# OmniRoute 进程编排总控
# v2.0 修复：restore 增加 -config（v1 缺此参数会读默认 /etc/litestream.yml 导致恢复永远静默失败）
set -eo pipefail

OMNIROUTE_PORT="${OMNIROUTE_PORT:-20128}"
EXPOSED_PORT="${EXPOSED_PORT:-7860}"
DATA_DIR="${DATA_DIR:-/data}"
DB_PATH="$DATA_DIR/storage.sqlite"
EXPECTED_VER="${OMNIROUTE_IMAGE_VERSION:-3.8.43}"

echo "[entrypoint] OmniRoute 启动 | PORT=$OMNIROUTE_PORT EXPOSED=$EXPOSED_PORT DATA=$DATA_DIR"

# ── R2 恢复（本地无库或空库时）──
if [ -n "${R2_ACCESS_KEY_ID:-}" ] && [ -n "${R2_SECRET_ACCESS_KEY:-}" ] && [ -n "${R2_ACCOUNT_ID:-}" ]; then
  if [ ! -s "$DB_PATH" ]; then
    echo "[entrypoint] 本地库为空，从 R2 restore..."
    # -if-replica-exists：无副本时返回 0 不报错（若所用版本不支持此 flag，删除即可，|| 分支仍会兜底）
    litestream restore -config /litestream.yml -if-replica-exists -o "$DB_PATH" "$DB_PATH" \
      && echo "[entrypoint] ✓ 已从 R2 恢复" \
      || echo "[entrypoint] ⚠ restore 失败或无副本，空库启动"
  else
    echo "[entrypoint] 本地库存在，跳过 restore"
  fi
else
  echo "[entrypoint] ⚠ R2 凭据未配置——数据将不可持久，强烈建议补齐"
fi

# ── 启动 OmniRoute ──
cd /app
node server.js &
OR_PID=$!
echo "[entrypoint] OmniRoute PID=$OR_PID"

# ── 健康等待（180s）──
_DL=$(( $(date +%s) + 180 ))
while [ $(date +%s) -lt $_DL ]; do
  curl -sf "http://127.0.0.1:$OMNIROUTE_PORT/api/monitoring/health" >/dev/null 2>&1 && { echo "[entrypoint] ✓ 就绪"; break; }
  kill -0 $OR_PID 2>/dev/null || { echo "[entrypoint] ✗ OmniRoute 已退出"; exit 1; }
  sleep 2
done

_VER=$(curl -sf "http://127.0.0.1:$OMNIROUTE_PORT/api/monitoring/health" | jq -r '.version // "unknown"' 2>/dev/null || echo unknown)
echo "[entrypoint] 版本=$_VER（期望 $EXPECTED_VER）"

# ── NIM 初始化（后台）──
INIT_PID=""
if [ -f /entrypoint-init-nim.sh ] && [ -n "${NIM_KEYS:-}" ]; then
  bash /entrypoint-init-nim.sh & INIT_PID=$!
  echo "[entrypoint] Init PID=$INIT_PID"
fi

# ── Litestream 复制（后台）──
LS_PID=""
if [ -n "${R2_ACCESS_KEY_ID:-}" ] && [ -f /litestream.yml ]; then
  litestream replicate -config /litestream.yml "$DB_PATH" & LS_PID=$!
  echo "[entrypoint] Litestream PID=$LS_PID"
fi

echo "[entrypoint] 全部就绪：OR=$OR_PID Init=${INIT_PID:-无} LS=${LS_PID:-无} Gate→:$EXPOSED_PORT"
trap 'kill $OR_PID ${INIT_PID:-} ${LS_PID:-} 2>/dev/null; exit 0' SIGTERM SIGINT

[ -f /gate/gate.js ] && exec node /gate/gate.js
echo "[entrypoint] FATAL: gate.js 不存在"; exit 1
```

## 4.6 gate.js（Dataset · 已修复 abort 根因）

```javascript
// OmniRoute Gate · 零依赖（仅 http/crypto）
// v2.0 根因修复：清理逻辑从 req.on('close') 迁到 res.on('close')。
//   Node 的 IncomingMessage 是 autoDestroy 流：请求体被 pipe 消费完后立即触发 close，
//   v1 在此 destroy() 上游请求 → 所有请求 12-24ms 内被误杀（request_signal_aborted）。
//   正确时机是 res close（响应结束或客户端真的断开）。
const http = require('http');
const crypto = require('crypto');

const GATE_PORT = parseInt(process.env.EXPOSED_PORT || '7860', 10);
const UPSTREAM_PORT = parseInt(process.env.OMNIROUTE_PORT || '20128', 10);
const UPSTREAM_HOST = '127.0.0.1';
const PSK = process.env.INTERNAL_PSK || '';
const OR_API_KEY = process.env.OMNIROUTE_API_KEY || '';

const RPM_LIMIT = parseInt(process.env.NIM_RPM_LIMIT || '28', 10);
const CONCURRENT_LIMIT = parseInt(process.env.NIM_CONCURRENT_LIMIT || '1', 10);
const MIN_INTERVAL_MS = parseInt(process.env.NIM_MIN_INTERVAL_MS || '100', 10);

let _tokens = RPM_LIMIT, _lastRefill = Date.now(), _lastReq = 0, _active = 0;

function tryAcquire() {
  const now = Date.now();
  _tokens = Math.min(RPM_LIMIT, _tokens + ((now - _lastRefill) / 60000) * RPM_LIMIT);
  _lastRefill = now;
  if (_tokens < 1 || _active >= CONCURRENT_LIMIT || now - _lastReq < MIN_INTERVAL_MS) return false;
  _tokens -= 1; _active += 1; _lastReq = now;
  return true;
}

function safeCompare(a, b) {
  const x = Buffer.from(a), y = Buffer.from(b);
  return x.length === y.length && crypto.timingSafeEqual(x, y);
}

http.createServer((req, res) => {
  if (req.url === '/healthz') {
    res.writeHead(200, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify({ status: 'ok', active: _active, tokens: Math.floor(_tokens) }));
    return;
  }

  const auth = req.headers['x-internal-psk'] || req.headers['authorization'] || '';
  const token = auth.startsWith('Bearer ') ? auth.slice(7) : auth;
  if (!PSK || !safeCompare(token, PSK)) {
    res.writeHead(401, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify({ error: 'unauthorized' }));
    return;
  }

  if (!tryAcquire()) {
    res.writeHead(429, { 'Content-Type': 'application/json', 'Retry-After': '3' });
    res.end(JSON.stringify({ error: 'rate_limited', retry_after: 3 }));
    return;
  }

  let released = false;
  const done = () => { if (!released) { released = true; _active = Math.max(0, _active - 1); } };

  const headers = { ...req.headers };
  if (OR_API_KEY) headers['authorization'] = `Bearer ${OR_API_KEY}`;
  delete headers['x-internal-psk'];
  headers['connection'] = 'close'; // 避免 keep-alive 复用导致的边界问题

  const proxyReq = http.request({
    hostname: UPSTREAM_HOST, port: UPSTREAM_PORT,
    path: req.url, method: req.method, headers, timeout: 0,
  }, (proxyRes) => {
    res.writeHead(proxyRes.statusCode, proxyRes.headers);
    proxyRes.pipe(res); // SSE/流式透传
  });

  proxyReq.on('error', (e) => {
    console.error(`[gate] upstream error: ${e.message} (${req.url})`);
    if (!res.headersSent) {
      res.writeHead(502, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify({ error: 'bad_gateway', detail: e.message }));
    } else res.destroy();
    done();
  });

  // 响应关闭（正常结束或客户端断开）= 唯一的清理点
  res.on('close', () => {
    if (!proxyReq.destroyed) proxyReq.destroy();
    done();
  });

  req.pipe(proxyReq);
}).listen(GATE_PORT, '0.0.0.0', () => {
  console.log(`[gate] :${GATE_PORT} → ${UPSTREAM_HOST}:${UPSTREAM_PORT} | ${RPM_LIMIT}rpm/${CONCURRENT_LIMIT}并发/${MIN_INTERVAL_MS}ms | PSK=${PSK.length}字符`);
});
```

## 4.7 litestream.yml（Dataset · 语法已逐字段对照官方 v0.5 参考确认）

```yaml
# Litestream v0.5.9 · SQLite → Cloudflare R2
# 已对照官方配置参考逐字段确认：replica(单数)/type/bucket/path/endpoint/region/
# sync-interval/auto-recover/snapshot 块/${VAR}展开 全部为 v0.5 有效语法。
# endpoint 设置后 force-path-style 自动启用（R2 需要），无需显式声明。
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
      sync-interval: 10s   # 默认 1s；调大可省 PUT 请求费
      auto-recover: false  # true 会在 LTX 错误时自动重置本地状态（丢 PITR 历史），保守关闭

snapshot:
  interval: 1h
  retention: 24h
```

## 4.8 package.json（Dataset）

```json
{
  "name": "omniroute-gate",
  "version": "2.0.0",
  "private": true,
  "description": "Zero-dependency gate for OmniRoute (http + crypto only)",
  "main": "gate.js",
  "dependencies": {}
}
```

## 4.9 init-nim-keys.sh（Dataset · 完整版，API 路径全部按官方 Wiki 修正）

```bash
#!/bin/bash
# OmniRoute NIM 初始化 · 完整自包含版
# 所有管理 API 均经 Cookie 鉴权（POST /api/auth/login → auth_token）。
# 端点已对照官方 API Reference 确认；个别 body schema 官方未文档化的，
# 脚本一律"先 GET 读结构、再写入、失败不阻断"。
set -uo pipefail   # 不用 -e：单步失败不阻断整体

BASE="http://127.0.0.1:${OMNIROUTE_PORT:-20128}"
COOKIE="/tmp/omni_cookie.txt"
DATA_DIR="${DATA_DIR:-/data}"
DB="$DATA_DIR/storage.sqlite"
REG=0; SKIP=0; FAIL=0

log() { echo "[init] $*"; }

# ── Step 0: 输入校验 ──
[ -n "${NIM_KEYS:-}" ] || { log "FATAL: NIM_KEYS 为空"; exit 1; }
[ -n "${INITIAL_PASSWORD:-}" ] || { log "FATAL: INITIAL_PASSWORD 为空"; exit 1; }

# ── Step 1: 危险环境变量扫描（代理类变量会劫持出站）──
env | grep -iE '^(http_proxy|https_proxy|all_proxy|no_proxy)=' \
  && log "⚠ 检测到代理环境变量（见上），如非预期请从 Secrets 中移除" \
  || log "✓ 无代理环境变量"

# ── Step 2: 等待健康（entrypoint 已等过，这里兜底 120s）──
_DL=$(( $(date +%s) + 120 ))
until curl -sf "$BASE/api/monitoring/health" >/dev/null 2>&1; do
  [ $(date +%s) -ge $_DL ] && { log "FATAL: 健康等待超时"; exit 1; }
  sleep 2
done
log "✓ OmniRoute 健康"

# ── Step 3: 登录（官方确认：密码哈希优先，回退 INITIAL_PASSWORD）──
_ok=0
for i in 1 2 3; do
  _code=$(curl -s -o /tmp/login.json -w "%{http_code}" -c "$COOKIE" \
    -X POST "$BASE/api/auth/login" -H "Content-Type: application/json" \
    -d "$(jq -n --arg p "$INITIAL_PASSWORD" '{password:$p}')" 2>/dev/null || echo 000)
  if [ "$_code" = "200" ] || [ "$_code" = "201" ]; then
    grep -q auth_token "$COOKIE" 2>/dev/null && { _ok=1; break; }
  fi
  log "登录尝试 $i: HTTP $_code，3s 后重试"; sleep 3
done
[ "$_ok" = "1" ] || { log "FATAL: 登录失败"; exit 1; }
log "✓ 已登录"

# ── Step 4: 注册 NIM Keys（幂等；路径与 body 已按官方 Wiki 确认）──
log "注册 NIM Keys..."
_i=0
while IFS= read -r _key; do
  _key="$(printf '%s' "$_key" | tr -d '[:space:]')"
  [ -z "$_key" ] && continue
  _i=$((_i+1))
  _name="nim-$(printf '%02d' $_i)"
  _code=$(curl -s -o "/tmp/key_$_i.json" -w "%{http_code}" -b "$COOKIE" \
    -X POST "$BASE/api/providers" -H "Content-Type: application/json" \
    -d "$(jq -n --arg provider "nvidia" --arg apiKey "$_key" --arg name "$_name" \
      '{provider:$provider, apiKey:$apiKey, name:$name, priority:1, testStatus:"unknown"}')" 2>/dev/null || echo 000)
  case "$_code" in
    200|201) log "  $_name ✓"; REG=$((REG+1));;
    409)     log "  $_name 已存在，跳过"; SKIP=$((SKIP+1));;
    *)       log "  $_name ✗ HTTP $_code: $(cat /tmp/key_$_i.json 2>/dev/null | head -c 200)"; FAIL=$((FAIL+1));;
  esac
done <<< "$NIM_KEYS"
log "Keys: $REG 注册 / $SKIP 跳过 / $FAIL 失败"

# ── Step 5: 读回 Provider 列表核对 ──
_cnt=$(curl -sf -b "$COOKIE" "$BASE/api/providers" 2>/dev/null \
  | jq '[.. | objects | select(.provider? == "nvidia")] | length' 2>/dev/null || echo "?")
log "✓ nvidia 连接数（读回）: $_cnt"

# ── Step 6: 清除代理残留（SQL 兜底，表名自动探测）──
if command -v sqlite3 >/dev/null 2>&1 && [ -f "$DB" ]; then
  for _t in $(sqlite3 "$DB" "SELECT name FROM sqlite_master WHERE type='table' AND (name LIKE '%setting%' OR name LIKE '%prox%');" 2>/dev/null); do
    sqlite3 "$DB" "UPDATE \"$_t\" SET value='null' WHERE key LIKE '%prox%';" 2>/dev/null \
      && log "  SQL 代理清除: $_t" || true
  done
fi

# ── Step 7: 代理配置清除（官方专用端点 GET/PUT /api/settings/proxy）──
_cur=$(curl -sf -b "$COOKIE" "$BASE/api/settings/proxy" 2>/dev/null || echo "{}")
log "  当前 proxy 配置: $(printf '%s' "$_cur" | head -c 200)"
curl -s -o /dev/null -w "[init]   proxy disable: HTTP %{http_code}\n" -b "$COOKIE" \
  -X PUT "$BASE/api/settings/proxy" -H "Content-Type: application/json" \
  -d '{"enabled":false}' 2>/dev/null || log "  ⚠ proxy PUT 失败（非阻断，Step 6 已兜底）"

# ── Step 8: Resilience（官方确认 PATCH 结构：providerBreaker.{oauth,apikey}）──
_body=$(jq -n '{providerBreaker:{apikey:{degradationThreshold:3,failureThreshold:5,resetTimeoutMs:60000},oauth:{degradationThreshold:3,failureThreshold:5,resetTimeoutMs:60000}}}')
curl -s -o /dev/null -w "[init]   resilience PATCH: HTTP %{http_code}\n" -b "$COOKIE" \
  -X PATCH "$BASE/api/resilience" -H "Content-Type: application/json" -d "$_body" 2>/dev/null
curl -sf -b "$COOKIE" "$BASE/api/resilience" 2>/dev/null | jq -c '.providerBreaker // .' 2>/dev/null \
  | head -c 300 | xargs -I{} log "  resilience 读回: {}"

# ── Step 9: Compression（官方路径 /api/settings/compression；schema 未文档化 → 先读后写）──
curl -sf -b "$COOKIE" "$BASE/api/settings/compression" 2>/dev/null \
  | head -c 300 | xargs -I{} log "  compression 当前: {}"
# 按需启用：取消下行注释并按读回的结构补全字段
# curl -s -b "$COOKIE" -X PUT "$BASE/api/settings/compression" -H "Content-Type: application/json" -d '{"mode":"lite"}' -o /dev/null -w "[init]   compression PUT: HTTP %{http_code}\n"

# ── Step 10: Thinking Budget（官方路径 /api/settings/thinking-budget）──
curl -sf -b "$COOKIE" "$BASE/api/settings/thinking-budget" 2>/dev/null \
  | head -c 300 | xargs -I{} log "  thinking-budget 当前: {}"

# ── Step 11: Memory —— 官方确认 v3.8.30+ 默认关闭，无需任何操作 ──
log "✓ Memory 默认关闭（v3.8.30+），跳过"

# ── Step 12: 熔断器重置（官方路径 /api/resilience/reset，需管理端鉴权）──
curl -s -o /dev/null -w "[init]   breaker reset: HTTP %{http_code}\n" -b "$COOKIE" \
  -X POST "$BASE/api/resilience/reset" 2>/dev/null

# ── Step 13: NIM Key 探针（可选，NIM_PROBE=1 时启用；走 443，HF 出站允许）──
if [ "${NIM_PROBE:-0}" = "1" ]; then
  _j=0
  while IFS= read -r _key; do
    _key="$(printf '%s' "$_key" | tr -d '[:space:]')"
    [ -z "$_key" ] && continue
    _j=$((_j+1))
    _n=$(curl -sf -H "Authorization: Bearer $_key" \
      "https://integrate.api.nvidia.com/v1/models" 2>/dev/null | jq '.data | length' 2>/dev/null || echo "FAIL")
    log "  探针 nim-$(printf '%02d' $_j): 模型数=$_n"
  done <<< "$NIM_KEYS"
fi

# ── Step 14: Combo 管理（/api/combos 存在已确认；body schema 未文档化）──
# 策略：先 GET 读现有结构。首次部署建议登录 Dashboard 手工建一次 combo，
# 再用 GET 读回 JSON 作为本步模板。脚本不盲写。
curl -sf -b "$COOKIE" "$BASE/api/combos" 2>/dev/null \
  | head -c 500 | xargs -I{} log "  combos 当前: {}" || log "  combos 读取失败（非阻断）"

log "════════ 初始化完成：Keys $REG+$SKIP/$((REG+SKIP+FAIL)) ════════"
exit 0
```

# 第 5 章 · 首次部署手册

**前置**：Docker、GHCR 账号（`gh auth` 或 PAT）、HF 账号、Cloudflare R2 bucket（如 `omniroute-data`）。

1. **建 Private Dataset**（如 `your-name/omni-logic`），上传 5 个文件：`entrypoint.sh`、`gate.js`、`init-nim-keys.sh`、`litestream.yml`、`package.json`（第 4.5-4.9 节）。
2. **推镜像到 GHCR**（镜像 A，官方纯副本）：
   ```bash
   docker pull diegosouzapw/omniroute:3.8.43
   docker tag diegosouzapw/omniroute:3.8.43 ghcr.io/your-username/omniroute-base:stable
   docker push ghcr.io/your-username/omniroute-base:stable
   ```
3. **建 Space**：上传 `Dockerfile`、`bootstrap.sh`、`README.md`（第 4.1-4.3 节），配齐第 3 章全部 Secrets。
4. **（推荐）挂载 Storage Bucket**：Space Settings 中创建一个 private bucket 挂载到 `/data`（读写模式）。这是 2026 年官方唯一持久化渠道，可让数据库跨重建存活；R2 仍保留为异地副本。免费额度以 [hf.co/storage](https://huggingface.co/storage) 页面为准。🟡 挂载行为与免费额度请创建时现场确认。
5. **验收**（日志依次出现）：`镜像 A 模式` → `逻辑注入完成` → `✓ 已从 R2 恢复`（首启为空库提示属正常）→ `✓ 就绪` → `✓ 已登录` → `Keys: N 注册` → `[gate] :7860 →`。
6. **客户端接入**：`POST https://<space>.hf.space/v1/chat/completions`，头 `X-Internal-PSK: <INTERNAL_PSK>`。

# 第 6 章 · 日常运维

| 操作 | 步骤 | 重建？ |
|------|------|--------|
| 改业务脚本（限流/Key/初始化逻辑） | Dataset 网页端改文件 → Space Settings → **Restart** | 否 |
| 镜像 A↔B 切换 / OmniRoute 升级 | 本地构建或 pull → `docker tag` 覆盖 `:stable` → push → Space 仓库提交任一文件变更（如更新 `IMAGE_VERSION` 文本）触发重建 | 是（1 次） |
| 手动备份数据库 | 已挂载 bucket 则直接复制 `/data/storage.sqlite`；或调官方端点 `GET /api/db-backups/export`（需管理 Cookie） | 否 |
| 防休眠 | 免费层 48h 闲置休眠、访问自醒；唤醒即冷启动走 restore。不要用脚本刷流量保活（违反 ToS 风险） | — |
| 重启语义速查 | Restart = 用缓存镜像重启容器（逻辑层更新走这里）；Factory reboot = 清缓存完整重建（镜像切换才用，且必清 `/data`） | — |

# 第 7 章 · 灾难恢复

| 场景 | 处置 |
|------|------|
| Dataset 拉取失败 | bootstrap 自动回滚到容器内 `.bak` 版本（同一容器生命周期内有效）；首次部署即失败则需修复 Dataset 权限后 Restart |
| 本地库损坏/被清 | 删 `/data/storage.sqlite` → Restart → entrypoint 自动从 R2 恢复（v2.0 已修复 restore 命令） |
| Space 永久卡 Building | 无法自救时联系 HF 支持（website@huggingface.co）；因 Docker SDK 已转付费，**不要删除现有 Space**——删了免费账号建不回来 |
| 官方镜像 `diegosouzapw/omniroute:3.8.43` 消失 | 首次部署时已推入自有 GHCR，天然免疫；未备份则从 GitHub 源码自建 |
| R2 不可用 | 核心推理不受影响（仅备份暂停）；恢复后 Litestream 自动续传。若配置了 `/data` bucket 挂载，则本地副本仍在 |

# 第 8 章 · 未验证假设清单（v2.0）

| 编号 | 内容 | 状态 | 验证方法 |
|------|------|------|---------|
| A1-A3 | Restart/Factory reboot 行为、`/data` 清除 | 🟢 已结案（第 1 章） | — |
| A4 | 高频重建永久卡 Building | 🟡 用户一手信息，社区有佐证 | 无需主动验证，保守规避即可 |
| A5 | Docker SDK 需 PRO | 🟢 已确认；**存量 Space 长期可用性仍需持续观察** | 关注 HF 公告 |
| A6 | Step 9-12 路径 | 🟢 已结案（已给出正确路径） | — |
| A7 | 2200ms pacing 致 abort | 🔴 **已撤回**——真根因是 gate.js 的 `req.on('close')`，v2.0 已修复 | 部署 v2.0 后观察日志中 abort 是否消失 |
| A8 | Storage Bucket 免费额度与挂载细节 | 🟡 官方功能确认，额度待现场确认 | 创建时查看 hf.co/storage |
| A9 | compression / combos 的写入 body schema | 🟡 端点确认存在，schema 未文档化 | 脚本已按"先 GET 读回"设计，按读回结构补全 |
| A10 | `-if-replica-exists` flag 在 v0.5.9 可用 | 🟡 v0.3 文档存在，v0.5 未逐字确认 | 若 restore 报 flag 错误，删除该参数即可（有 `\|\|` 兜底） |

# 第 9 章 · v2.0 变更日志

1. **推翻**：`/data` 持久化假设——HF 免费磁盘实为 ephemeral，旧持久化产品已下线；R2 从"灾备"升格为"数据主路径"，并新增 Storage Bucket 挂载为推荐增强。
2. **修复（关键）**：gate.js 清理时机 `req.on('close')` → `res.on('close')`，根治全部请求 12-24ms 被误杀的问题；并发槽释放加幂等保护。
3. **修复**：entrypoint.sh 的 `litestream restore` 补 `-config /litestream.yml`（原命令必然静默失败）。
4. **修正**：Step 9-12 全部 API 路径按官方 Wiki 更正；删除不存在的 `/api/memory/extended` 与 Memory 配置步骤（v3.8.30+ 默认关闭）；代理清除改用专用端点 `/api/settings/proxy`。
5. **补全**：init-nim-keys.sh 提供完整可运行版本（原文档引用"前序对话"，违背自包含原则）。
6. **确认**：2026-07 Docker SDK 转 PRO（存量 Space 保护写入运维手册）；出站端口 80/443/8080 限制；48h 休眠语义。
7. **增强**：bootstrap.sh 支持新版 `hf` CLI 并保留 `huggingface-cli` 兜底；gate 增加 `connection: close` 头规避 keep-alive 边界问题。

---

**两处需要你在部署时留意的点**：一是第 5 章第 4 步的 Storage Bucket 挂载是 2026 年新机制，创建时请以 Space Settings 实际界面为准；二是 v2.0 的 gate.js 上线后，建议观察一段时间日志确认 `request_signal_aborted` 不再出现——如果仍有 abort，再回头查限流参数，但根因修复应先见效。

*内容由 AI 生成仅供参考*