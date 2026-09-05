这是经过 **v4.2.3** 最终验证、完全收拢后的完整文档。它涵盖了全部新增环境变量、启动推荐主力样例、R2/Dataset 持久化逻辑、升级论证以及运维排查。

你可以直接将以下内容替换到仓库根目录的 `docs/README.md` 中。

***

# **OmniRoute × NVIDIA NIM 多账号网关（HF Space 部署，v4.2.3）**

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

这是为您整理的 **v4.2.x 系列版本变更日志 (Changelog)**。你可以将其追加到 `README.md` 的末尾，或者单独保存为 `CHANGELOG.md`。

这份日志记录了从最初的 v3.8.0 增量脚本，到解决 400 策略错误、R2 冲突、再到实现被动健康决策和日志入库的全过程。

---

## **OmniRoute NIM Initializer Changelog**

### **v4.2.3 (2026-07-10)**
- **[新功能] DEBUG 日志入库**：`hf_snapshot` 现在支持将 `init_*.log` 拷入 snapshot 目录并重命名为 `debug_*.log` 上传至 HF Dataset。
- **[运维] 本地日志滚动**：新增 `NIM_DEBUG_LOG_KEEP` 变量（默认 5），自动清理容器内 `/data` 目录下的旧初始化日志，防止磁盘膨胀。
- **[文档] 升级论证**：基于 GitHub Issue #6773 (NIM 404) 论证了维持 3.8.43 版本的必要性，并制定了升级复查触发条件。

### **v4.2.2 (2026-07-09)**
- **[修复] 幂等 Combo 创建**：新增 `upsert_combo` 函数，通过“先 GET 查名再决定 PUT/POST”的逻辑，彻底解决了 R2 restore 回旧 DB 后导致的 `Combo name already exists` (400) 报错。
- **[优化] 增量判定逻辑**：放宽增量模式入口，任一 `nim-*` combo 存在或 `INIT_MARKER` 存在即跳过首次注册，提升 Space 重启速度。
- **[修复] 探针鲁棒性**：修复了探针在某些极端网络下可能导致的变量残留问题，确保 `nim-probe-bad.txt` 每次运行前重置。

### **v4.2.1 (2026-07-09)**
- **[核心修复] 移除非法策略**：彻底移除 `quota-share` 策略（确认为内部机制而非合法 combo strategy），主池默认切换为 `p2c`。
- **[新功能] 策略白名单**：引入 `_is_valid_strat` 校验，所有 combo 策略必须通过 3.8.43 合法性白名单，非法值强制降级 `round-robin`，根治 400 错误。
- **[新功能] 被动健康选型**：新增 `nim_health_pick()` 函数。通过 SQL 统计本地 `call_logs` 近 1 小时的真实成功率与延迟，实现“零风控足迹”的模型推荐。
- **[优化] 熔断历史保留**：修改增量模式下的 breaker 清理逻辑，仅删除过期熔断，保留仍在冷却窗内的健康信号。
- **[新功能] 轻量主动探针**：新增 `nim_probe()` 函数（默认关闭），实现每模型每小时 1 次、max_tokens=1 的极低频跨 key 轮换探测。

### **v4.2.0 (2026-07-08)**
- **[优化] 模型目录对齐**：全量更新 `TIER_FAST` / `TIER_STABLE` 清单，对齐 2026-07 现行 NVIDIA NIM 官方 slug（如 `glm-5.2` / `deepseek-v4-pro`）。
- **[优化] 动态配额推导**：RPM 与并发数不再写死，改为按 `存活 Key 数 × 35` 动态计算，充分榨取多账号池性能。
- **[新功能] 多层兜底 Combo**：新增 `nim-max` 组合，实现“NIM 存活池 → 免费供应商（Cerebras/Pollinations/CF）”的自动滑落，确保永不断供。

### **v4.1.0 (2026-07-01)**
- **[架构] 基础镜像钉死**：引入 digest 双写锁定 `3.8.43`，规避 `latest` 标签导致的 Turbopack 构建失败与 migration 117 挂起问题。
- **[功能] 实时探活**：引入 `check_nim_model_health`，启动时通过 `/v1/models` 自动过滤已被 NVIDIA 下架的模型，根治 404 报错。
- **[修复] 格式订正**：将 combo models 格式由字符串数组修正为对象数组 `[{"model":"x"}]`。

---
*Base Version: v3.8.0-legacy*


## Dockerfile

```Dockerfile
# ── 基础镜像：钉死 3.8.43 + digest 双写，禁止浮动 latest ──────────
# 根因：latest 会漂到新版（Turbopack 构建 + migration 表重建），
#       导致 Next 服务静默无法 ready，entrypoint 健康等待空转卡 starting。
FROM diegosouzapw/omniroute:3.8.43@sha256:517c160643c56ad72e3e305458d961c9a4c87f711393c13020450f9f088d1570

ENV OMNIROUTE_PORT=20128
ENV EXPOSED_PORT=7860
ENV DATA_DIR=/data

# ── 跨版本防御 env（3.8.43 无害；防误漂到新版静默 hang）──
ENV OMNIROUTE_USE_TURBOPACK=0
ENV OMNIROUTE_MAX_PENDING_MIGRATIONS=0

USER root

RUN apt-get update && apt-get install -y --no-install-recommends \
    curl jq python3 python3-pip sqlite3 ca-certificates \
    && rm -rf /var/lib/apt/lists/*

RUN pip3 install --no-cache-dir --break-system-packages huggingface_hub

ARG LITESTREAM_VERSION=0.5.9
RUN ARCH=$(uname -m | sed 's/aarch64/arm64/') && \
    curl -fsSL \
      "https://github.com/benbjohnson/litestream/releases/download/v${LITESTREAM_VERSION}/litestream-${LITESTREAM_VERSION}-linux-${ARCH}.tar.gz" \
    | tar -xz -C /usr/local/bin litestream && \
    chmod +x /usr/local/bin/litestream && \
    litestream version

RUN mkdir -p /data && chmod 777 /data
RUN rm -rf /app/data && ln -sf /data /app/data

RUN mkdir -p /gate
COPY package.json /gate/package.json
COPY gate.js /gate/gate.js
RUN cd /gate && npm install --omit=dev --silent

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

COPY init-nim-keys.sh /entrypoint-init-nim.sh
RUN chmod +x /entrypoint-init-nim.sh

COPY litestream.yml /litestream.yml

EXPOSE 7860

HEALTHCHECK --interval=30s --timeout=10s --start-period=180s --retries=3 \
    CMD curl -sf http://127.0.0.1:7860/healthz || exit 1

ENTRYPOINT ["/entrypoint.sh"]
```


## entrypoint.sh

```sh
#!/bin/sh
set -e

[ -z "$OMNIROUTE_PORT" ] && OMNIROUTE_PORT=20128
[ -z "$EXPOSED_PORT" ] && EXPOSED_PORT=7860
[ -z "$DATA_DIR" ] && DATA_DIR=/data
[ -z "$CALL_LOGS_TABLE_MAX_ROWS" ] && CALL_LOGS_TABLE_MAX_ROWS=100000
[ -z "$PROXY_LOGS_TABLE_MAX_ROWS" ] && PROXY_LOGS_TABLE_MAX_ROWS=100000

echo "[entrypoint] starting OmniRoute via /app/server.js..."
echo "[entrypoint] OMNIROUTE_PORT=$OMNIROUTE_PORT EXPOSED_PORT=$EXPOSED_PORT DATA_DIR=$DATA_DIR"

# ── Litestream restore（启动前恢复 DB）──
if [ -n "$R2_ACCESS_KEY_ID" ] && [ -n "$R2_SECRET_ACCESS_KEY" ] && [ -n "$R2_ACCOUNT_ID" ]; then
  echo "[entrypoint] R2 creds found. Litestream restore..."
  litestream restore -config /litestream.yml -if-replica-exists "$DATA_DIR/storage.sqlite" \
    && echo "[entrypoint] restore complete." \
    || echo "[entrypoint] WARN: restore failed or no replica. Continuing."
else
  echo "[entrypoint] WARN: R2 creds not set. Skip restore."
fi

PORT="$OMNIROUTE_PORT" \
DATA_DIR="$DATA_DIR" \
REQUIRE_API_KEY=true \
HOSTNAME=127.0.0.1 \
NIM_MODE="$NIM_MODE" \
NODE_OPTIONS="--max-old-space-size=4096" \
DISABLE_SQLITE_AUTO_BACKUP=true \
PROVIDER_LIMITS_SYNC_INTERVAL_MINUTES=1440 \
CALL_LOGS_TABLE_MAX_ROWS="$CALL_LOGS_TABLE_MAX_ROWS" \
PROXY_LOGS_TABLE_MAX_ROWS="$PROXY_LOGS_TABLE_MAX_ROWS" \
JWT_SECRET="$JWT_SECRET" \
API_KEY_SECRET="$API_KEY_SECRET" \
OMNIROUTE_API_KEY="$OMNIROUTE_API_KEY" \
INITIAL_PASSWORD="$INITIAL_PASSWORD" \
node /app/server.js --log &
OR_PID=$!
echo "[entrypoint] OmniRoute PID=$OR_PID"

echo "[entrypoint] waiting for health (max 180s)..."
i=0
while [ "$i" -lt 180 ]; do
  kill -0 "$OR_PID" 2>/dev/null || { echo "[entrypoint] FATAL: OmniRoute exited early"; exit 1; }
  curl -sf "http://127.0.0.1:$OMNIROUTE_PORT/api/monitoring/health" >/dev/null 2>&1 && { echo "[entrypoint] ready after ${i}s"; break; }
  sleep 2; i=$((i + 2))
done
[ "$i" -ge 180 ] && { echo "[entrypoint] FATAL: not ready within timeout"; exit 1; }

# ── 版本护栏（只告警不中断）──
EXPECTED_OR_VERSION="${EXPECTED_OR_VERSION:-3.8.43}"
_OR_VER=$(curl -sf "http://127.0.0.1:$OMNIROUTE_PORT/api/monitoring/health" 2>/dev/null | jq -r '.version // "unknown"' 2>/dev/null || echo "unknown")
echo "[entrypoint] base version: $_OR_VER (expected $EXPECTED_OR_VERSION)"
if [ "$_OR_VER" != "$EXPECTED_OR_VERSION" ] && [ "$_OR_VER" != "unknown" ]; then
  echo "[entrypoint] ⚠️ WARN: 版本($_OR_VER)与期望($EXPECTED_OR_VERSION)不一致——疑似 FROM 漂移。"
fi

echo "[entrypoint] running NIM init in background..."
bash /entrypoint-init-nim.sh &

if [ -n "$OMNIROUTE_API_KEY" ]; then
  echo "[entrypoint] OMNIROUTE_API_KEY set, env-bypass 模式，跳过等待 .or-api-key。"
else
  echo "[entrypoint] waiting for OR_API_KEY (max 120s)..."
  j=0
  while [ "$j" -lt 120 ]; do
    [ -f "/data/.or-api-key" ] && [ -s "/data/.or-api-key" ] && { echo "[entrypoint] OR_API_KEY ready"; break; }
    kill -0 "$OR_PID" 2>/dev/null || { echo "[entrypoint] FATAL: OmniRoute exited waiting key"; exit 1; }
    sleep 2; j=$((j + 2))
  done
  [ ! -s "/data/.or-api-key" ] && { echo "[entrypoint] FATAL: OR_API_KEY not created"; exit 1; }
fi

export NODE_OPTIONS="--max-old-space-size=4096"
if [ -n "$R2_ACCESS_KEY_ID" ] && [ -n "$R2_SECRET_ACCESS_KEY" ] && [ -n "$R2_ACCOUNT_ID" ]; then
  echo "[entrypoint] Starting Litestream replication..."
  litestream replicate -config /litestream.yml &
  echo "[entrypoint] Litestream PID=$!"
else
  echo "[entrypoint] WARN: Litestream replication disabled (no R2 creds)."
fi

echo "[entrypoint] starting gate on port $EXPOSED_PORT..."
exec node /gate/gate.js
```


## gate.js

```js
const express = require('express');
const { createProxyMiddleware } = require('http-proxy-middleware');
const fs = require('fs');

const app = express();
const INTERNAL_PSK = process.env.INTERNAL_PSK;
const OR_PORT = parseInt(process.env.OMNIROUTE_PORT || '20128', 10);
const GATE_PORT = parseInt(process.env.EXPOSED_PORT || '7860', 10);

if (!INTERNAL_PSK) {
  console.error('[gate] FATAL: INTERNAL_PSK not set. HF Space Secret 必须配置。');
  process.exit(1);
}
let OR_API_KEY = (process.env.OMNIROUTE_API_KEY || '').trim();
if (!OR_API_KEY) {
  try { OR_API_KEY = fs.readFileSync('/data/.or-api-key', 'utf8').trim(); }
  catch (e) { if (e.code !== 'ENOENT') console.error('[gate] WARN read key failed:', e.message); }
}
if (!OR_API_KEY) {
  console.error('[gate] FATAL: No OR_API_KEY (env nor file).');
  process.exit(1);
}

app.get('/healthz', async (req, res) => {
  const r = await fetch(`http://127.0.0.1:${OR_PORT}/api/monitoring/health`).catch(() => null);
  r?.ok ? res.json({ ok: true }) : res.status(503).json({ ok: false });
});

app.use((req, res, next) => {
  if (!req.path.startsWith('/v1')) return next();
  const bearer = (req.headers.authorization || '').replace('Bearer ', '');
  if (bearer !== INTERNAL_PSK) return res.status(401).json({ error: 'unauthorized' });
  req.headers.authorization = `Bearer ${OR_API_KEY}`;
  next();
});

app.use('/', createProxyMiddleware({ target: `http://127.0.0.1:${OR_PORT}`, changeOrigin: true }));
app.listen(GATE_PORT, '0.0.0.0', () => {
  console.log(`[gate] listening on 0.0.0.0:${GATE_PORT} -> 127.0.0.1:${OR_PORT}`);
});
```


## init-nim-keys.sh

```sh
#!/bin/bash
set -eo pipefail

# ───────────────────────────────────────────────────────────
# NIM OmniRoute initializer  v4.2.3（基于 v4.2.2）
# 相对 v4.2.2 的变更：
#   【v4.2.3·⑨ 】DEBUG log 上传 Dataset（debug_<时间戳>.log，默认开启，
#              NIM_DEBUG_LOG_TO_DATASET=0 关闭）；本地仅留最近 NIM_DEBUG_LOG_KEEP(默认5) 个。
#              取代 v4.2.1 继承的 "DEBUG log 不入 Dataset" 旧策略。
# 继承 v4.2.2：⑦ 幂等 upsert_combo ⑧ 增量门放宽（任一 nim-* combo 或 INIT_MARKER）。
# 继承 v4.2.1：① 移除 quota-share/主池 p2c+白名单 ② nim-codex 响应体打印
#              ④ 可选探针 NIM_PROBE ⑤ 增量只清过期熔断 ⑥ nim_health_pick 分档推荐。
# ───────────────────────────────────────────────────────────

# ══ 单变量调试 + 日志归档（只走 stdout，不持久化到 Dataset）═══════
NIM_MODE="${NIM_MODE:-NORMAL}"
LOG_DIR="/data/omni-data/log"
if [ "$NIM_MODE" = "DEBUG" ]; then
  mkdir -p "$LOG_DIR" 2>/dev/null || true
  INIT_LOG="$LOG_DIR/init_$(date +%Y%m%d_%H%M%S).log"
  exec > >(tee -a "$INIT_LOG") 2>&1
  echo "[init] 🛠️ NIM_MODE=DEBUG：日志 tee -> $INIT_LOG（仅容器内，随 Space 日志可见，不入 Dataset）"
  export APP_LOG_TO_FILE=true
  export DISABLE_SQLITE_AUTO_BACKUP=true
else
  LOG_DIR="/tmp"
fi
_resp() { echo "$LOG_DIR/$1"; }

# ── 强制关闭代理生态 ──────────────────────────────────────────
export ONEPROXY_ENABLED=false
export ENABLE_SOCKS5_PROXY=false
export NEXT_PUBLIC_ENABLE_SOCKS5_PROXY=false
unset HTTP_PROXY HTTPS_PROXY ALL_PROXY http_proxy https_proxy all_proxy 2>/dev/null || true
unset OMNIROUTE_RELAY_BACKEND BIFROST_BASE_URL 2>/dev/null || true

# ── 端口配置 ──────────────────────────────────────────────────
[ -z "$OMNIROUTE_PORT" ] && OMNIROUTE_PORT=20128
BASE_URL="http://127.0.0.1:$OMNIROUTE_PORT"
INIT_MARKER="/data/.init-done"
OR_API_KEY_FILE="/data/.or-api-key"
COOKIE_FILE="/tmp/omniroute-cookie.txt"

LOGIN_RESP_FILE="$(_resp omniroute-login.json)"
KEY_RESP_FILE="$(_resp omniroute-key-response.json)"
PROVIDERS_FILE="$(_resp omniroute-providers.json)"
RESILIENCE_RESP_FILE="$(_resp omniroute-resilience.json)"
SETTINGS_RESP_FILE="$(_resp omniroute-settings.json)"
COMPRESS_RESP_FILE="$(_resp omniroute-compress.json)"
THINKING_RESP_FILE="$(_resp omniroute-thinking.json)"
MEMORY_LEGACY_RESP_FILE="$(_resp omniroute-memory-legacy.json)"
MEMORY_EXT_RESP_FILE="$(_resp omniroute-memory-ext.json)"
COMBO_RESP_FILE="$(_resp omniroute-combo.json)"
VERSION_FILE="$(_resp omniroute-version.json)"

REGISTERED=0; SKIPPED=0; FAILED=0

# ══ 模型分档 SSOT（对齐现行 NVIDIA 目录）═══════════════════════
TIER_FAST=(
  "z-ai/glm-5.2"
  "deepseek-ai/deepseek-v4-flash"
  "deepseek-ai/deepseek-v4-pro"
  "meta/llama-3.3-70b-instruct"
)
TIER_STABLE=(
  "nvidia/nemotron-3-super-120b-a12b"
  "openai/gpt-oss-120b"
  "qwen/qwen3.5-397b-a17b"
  "mistralai/mistral-small-4-119b-2603"
  "google/gemma-4-31b-it"
)
TIER_RESTRICTED=(
  "moonshotai/kimi-k2.6"
  "minimaxai/minimax-m2.7"
  "mistralai/mistral-large-3-675b-instruct-2512"
)

_PROFILE="${NIM_PROFILE:-balanced}"
case "$_PROFILE" in
  fast)     NIM_POOL_MODELS=("${TIER_FAST[@]}") ;;
  full)     NIM_POOL_MODELS=("${TIER_FAST[@]}" "${TIER_STABLE[@]}" "${TIER_RESTRICTED[@]}") ;;
  *)        _PROFILE="balanced"; NIM_POOL_MODELS=("${TIER_FAST[@]}" "${TIER_STABLE[@]}") ;;
esac
echo "[init] NIM_PROFILE=$_PROFILE -> pool 意向 ${#NIM_POOL_MODELS[@]} 个模型"

NIM_CODEX_MODELS=(
  "deepseek-ai/deepseek-v4-pro"
  "openai/gpt-oss-120b"
  "z-ai/glm-5.2"
)
NIM_FAST_MODELS=(
  "deepseek-ai/deepseek-v4-flash"
  "meta/llama-3.3-70b-instruct"
  "google/gemma-4-31b-it"
)
NIM_EXTRA_MODELS=( "deepseek-ai/deepseek-v4-flash" )

build_all_models() {
  printf '%s
' "${NIM_POOL_MODELS[@]}" "${NIM_CODEX_MODELS[@]}" "${NIM_EXTRA_MODELS[@]}" | awk '!seen[$0]++'
}
models_to_json() { printf '%s' "$@" | sed 's/^/nvidia\//' | jq -R '{model: .}' | jq -s -c .; }

# ══ combo 策略白名单（3.8.43 实测合法枚举，不含 quota-share）═════
_VALID_STRATS="priority weighted round-robin context-relay fill-first p2c random least-used cost-optimized reset-aware reset-window headroom strict-random auto lkgp context-optimized fusion"
_is_valid_strat() { printf '%s' "$_VALID_STRATS" | grep -qw -- "$1"; }

# ══ 【⑦ 】幂等 upsert：存在则 PUT，不存在才 POST ═══════════════
upsert_combo() {
  local NAME="$1" STRAT="$2"; shift 2; local MODELS=("$@")
  _is_valid_strat "$STRAT" || { echo "[init] upsert_combo: '$STRAT' 非法 -> round-robin"; STRAT="round-robin"; }
  [ "${#MODELS[@]}" -eq 0 ] && { echo "[init] upsert_combo: $NAME 无存活模型，跳过。"; return 0; }
  local BODY CID CODE F
  BODY=$(jq -n --arg name "$NAME" --arg strat "$STRAT" \
               --argjson models "$(models_to_json "${MODELS[@]}")" \
               '{name:$name, strategy:$strat, models:$models}')
  CID=$(curl -s -b "$COOKIE_FILE" "$BASE_URL/api/combos" \
        | jq -r --arg n "$NAME" '.combos[]? // .[]? | select(.name==$n) | .id' | head -n1)
  F="$(_resp omniroute-combo-$NAME.json)"
  if [ -n "$CID" ]; then
    CODE=$(curl -s -o "$F" -w "%{http_code}" -b "$COOKIE_FILE" \
      -X PUT "$BASE_URL/api/combos/$CID" -H "Content-Type: application/json" -d "$BODY")
    echo "[init] upsert $NAME: existed -> PUT combos/$CID HTTP $CODE"
  else
    CODE=$(curl -s -o "$F" -w "%{http_code}" -b "$COOKIE_FILE" \
      -X POST "$BASE_URL/api/combos" -H "Content-Type: application/json" -d "$BODY")
    echo "[init] upsert $NAME: new -> POST HTTP $CODE"
  fi
  [ "$CODE" != "200" ] && [ "$CODE" != "201" ] && cat "$F" || true
}

# ══ 按存活 Key 数动态推导 RPM/并发 ═════════════════════════════
_count_alive_keys() { printf '%s
' "$NIM_KEYS" | sed '/^[[:space:]]*$/d' | wc -l; }
_ALIVE_KEYS=$(_count_alive_keys)
_PER_KEY_RPM=${NIM_PER_KEY_RPM:-35}
_RPM=$(( _ALIVE_KEYS * _PER_KEY_RPM ))
[ "$_RPM" -lt "$_PER_KEY_RPM" ] && _RPM=$_PER_KEY_RPM
[ "$_RPM" -gt 300 ] && _RPM=300
_CONCURRENT=$(( _ALIVE_KEYS * ${NIM_PER_KEY_CONCURRENT:-3} ))
[ "$_CONCURRENT" -lt 3 ] && _CONCURRENT=3
_MIN_INTERVAL_MS=$(( 60000 / (_RPM > 0 ? _RPM : 1) ))
echo "[init] alive_keys=$_ALIVE_KEYS -> RPM=$_RPM concurrent=$_CONCURRENT interval=${_MIN_INTERVAL_MS}ms"

if [ "$_ALIVE_KEYS" -gt 1 ]; then
  _POOL_STRATEGY="${NIM_POOL_STRATEGY:-p2c}"
else
  _POOL_STRATEGY="round-robin"
fi
_is_valid_strat "$_POOL_STRATEGY" || { echo "[init] WARN: pool strategy '$_POOL_STRATEGY' 非法，回退 round-robin"; _POOL_STRATEGY="round-robin"; }
_CODEX_STRATEGY="${NIM_CODEX_STRATEGY:-round-robin}"
_is_valid_strat "$_CODEX_STRATEGY" || { echo "[init] WARN: codex strategy '$_CODEX_STRATEGY' 非法，回退 round-robin"; _CODEX_STRATEGY="round-robin"; }
_FALLBACK_STRATEGY="round-robin"
_STICKY_LIMIT=1
_COMPRESS_THRESHOLD=${NIM_COMPRESS_THRESHOLD:-12000}
_COMPRESS_MODE="stacked"
_THINKING_MODE="adaptive"
_THINKING_BUDGET=8000
_NIM_REAL_CONTEXT=${CONTEXT_LENGTH_DEFAULT:-32768}
echo "[init] pool strategy=$_POOL_STRATEGY | codex strategy=$_CODEX_STRATEGY"

# ── body limit 归一 ───────────────────────────────────────────
_RAW_BODY_LIMIT=${NIM_REQUEST_BODY_LIMIT:-1}
if [ "$_RAW_BODY_LIMIT" -gt 500 ] 2>/dev/null; then
  _REQUEST_BODY_LIMIT_MB=$(( _RAW_BODY_LIMIT / 1048576 ))
  [ "$_REQUEST_BODY_LIMIT_MB" -lt 1 ] && _REQUEST_BODY_LIMIT_MB=1
elif [ "$_RAW_BODY_LIMIT" -lt 1 ] 2>/dev/null; then
  _REQUEST_BODY_LIMIT_MB=1
else
  _REQUEST_BODY_LIMIT_MB=$_RAW_BODY_LIMIT
fi
[ "$_REQUEST_BODY_LIMIT_MB" -gt 500 ] 2>/dev/null && _REQUEST_BODY_LIMIT_MB=500
echo "[init] body limit: raw=$_RAW_BODY_LIMIT -> maxBodySizeMb=$_REQUEST_BODY_LIMIT_MB"

_PURGE_PROXY=${NIM_PURGE_PROXY:-1}
_PROXY_RELAY_HOST=${NIM_PROXY_RELAY_HOST:-127.0.0.1}
_PROXY_RELAY_PORT=${NIM_PROXY_RELAY_PORT:-20129}
_DB_PATH="${DATA_DIR:-/data}/storage.sqlite"
sql_escape() { printf '%s' "$1" | sed "s/'/''/g"; }

check_dangerous_env() {
  echo "[init] check_dangerous_env: scanning relay/proxy env..."
  local _hit=0
  for v in OMNIROUTE_RELAY_BACKEND BIFROST_BASE_URL HTTP_PROXY HTTPS_PROXY ALL_PROXY http_proxy https_proxy all_proxy; do
    if [ -n "${!v}" ]; then echo "[init] ⚠️ DANGER: env $v=${!v} 已设置。"; _hit=1; fi
  done
  [ "$_hit" = "0" ] && echo "[init] check_dangerous_env: clean。"
}

purge_proxy_db() {
  [ "$_PURGE_PROXY" != "1" ] && { echo "[init] purge_proxy_db: skipped."; return 0; }
  local LIST_JSON
  LIST_JSON=$(curl -s -b "$COOKIE_FILE" "$BASE_URL/api/v1/management/proxies" 2>/dev/null || echo "")
  if [ -n "$LIST_JSON" ] && printf '%s' "$LIST_JSON" | jq -e . >/dev/null 2>&1; then
    local BAD_IDS
    BAD_IDS=$(printf '%s' "$LIST_JSON" | jq -r --arg h "$_PROXY_RELAY_HOST" --argjson p "$_PROXY_RELAY_PORT" \
      '(.proxies // .data // .) | (if type=="array" then . else [] end)
       | .[] | select((.host==$h) and ((.port|tonumber?)==$p)) | .id' 2>/dev/null)
    if [ -n "$BAD_IDS" ]; then
      local _id _c
      while IFS= read -r _id; do
        [ -z "$_id" ] && continue
        _c=$(curl -s -o /dev/null -w "%{http_code}" -b "$COOKIE_FILE" \
          -X DELETE "$BASE_URL/api/v1/management/proxies?id=${_id}&force=1" 2>/dev/null || echo "000")
        echo "[init] purge: API force-delete $_id -> HTTP $_c"
      done <<< "$BAD_IDS"
    else
      echo "[init] purge: 注册表无 ${_PROXY_RELAY_HOST}:${_PROXY_RELAY_PORT}。"
    fi
  else
    echo "[init] purge: 管理 API 暂不可用，走 SQL 兜底。"
  fi
  if [ -f "$_DB_PATH" ]; then
    sqlite3 "$_DB_PATH" "DELETE FROM proxy_assignments WHERE proxy_id IN
      (SELECT id FROM proxy_registry WHERE host='$(sql_escape "$_PROXY_RELAY_HOST")' AND port=$_PROXY_RELAY_PORT);" 2>/dev/null || true
    sqlite3 "$_DB_PATH" "UPDATE provider_connections SET proxy_enabled=0 WHERE provider='nvidia';" 2>/dev/null || true
    sqlite3 "$_DB_PATH" "DELETE FROM proxy_registry WHERE host='$(sql_escape "$_PROXY_RELAY_HOST")' AND port=$_PROXY_RELAY_PORT;" 2>/dev/null || true
    local _reg _asg _proxy_on
    _reg=$(sqlite3 "$_DB_PATH" "SELECT COUNT(*) FROM proxy_registry;" 2>/dev/null || echo "?")
    _asg=$(sqlite3 "$_DB_PATH" "SELECT COUNT(*) FROM proxy_assignments;" 2>/dev/null || echo "?")
    _proxy_on=$(sqlite3 "$_DB_PATH" "SELECT COUNT(*) FROM provider_connections WHERE provider='nvidia' AND proxy_enabled=1;" 2>/dev/null || echo "?")
    echo "[init] purge: registry=$_reg assignments=$_asg proxy_enabled=1剩余=$_proxy_on（期望 0/0/0）。"
  fi
}

check_nim_model_health() {
  echo "[init] check_nim_model_health..."
  > /tmp/nim-deprecated.txt
  local _first_key _models_json _model_count
  _first_key=$(printf '%s
' "$NIM_KEYS" | head -n1)
  _models_json=$(curl -s --max-time 10 -H "Authorization: Bearer ${_first_key}" \
    "https://integrate.api.nvidia.com/v1/models" 2>/dev/null || echo "")
  _model_count=$(printf '%s' "$_models_json" | jq -r '.data[]?.id' 2>/dev/null | wc -l)
  [ "${_model_count:-0}" -lt 5 ] && { echo "[init] only $_model_count models, skip 过滤"; return 0; }
  while IFS= read -r model; do
    [ -z "$model" ] && continue
    if ! printf '%s' "$_models_json" | jq -e --arg m "$model" 'any(.data[]?.id == $m; .)' >/dev/null 2>&1; then
      echo "[init]   $model — DEPRECATED（NVIDIA 目录无）"; echo "$model" >> /tmp/nim-deprecated.txt
    else
      [ "$NIM_MODE" = "DEBUG" ] && echo "[init]   $model — available"
    fi
  done < <(build_all_models)
  echo "[init] $(wc -l < /tmp/nim-deprecated.txt 2>/dev/null || echo 0) deprecated / $_model_count available"
}

filter_alive() {
  local out=() m
  for m in "$@"; do grep -Fxq "$m" /tmp/nim-deprecated.txt 2>/dev/null || out+=("$m"); done
  printf '%s
' "${out[@]}"
}

# ══ 【④ 】轻量探针：默认关闭；NIM_PROBE=1 才跑 ═══════════════════
nim_probe() {
  [ "${NIM_PROBE:-0}" != "1" ] && { echo "[init] nim_probe: disabled (set NIM_PROBE=1 to enable)."; return 0; }
  echo "[init] nim_probe: enabled — 每模型每小时限频 + 跨 key 轮换 (max_tokens=1)"
  local PROBE_DIR="/tmp/nim-probe"; mkdir -p "$PROBE_DIR"
  > /tmp/nim-probe-bad.txt
  mapfile -t _KEYS < <(printf '%s
' "$NIM_KEYS" | sed '/^[[:space:]]*$/d')
  local _nkeys=${#_KEYS[@]}; [ "$_nkeys" -eq 0 ] && return 0
  local _ki=0 m _stamp _now _last _key _code
  _now=$(date +%s)
  while IFS= read -r m; do
    [ -z "$m" ] && continue
    grep -Fxq "$m" /tmp/nim-deprecated.txt 2>/dev/null && continue
    _stamp="$PROBE_DIR/$(echo "$m" | tr '/' '-').ts"
    _last=$(cat "$_stamp" 2>/dev/null || echo 0)
    if [ $(( _now - _last )) -lt 3600 ]; then
      echo "[init]   probe skip $m（1h 内已探）"; continue
    fi
    _key="${_KEYS[$(( _ki % _nkeys ))]}"; _ki=$(( _ki + 1 ))
    _code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 15 \
      -H "Authorization: Bearer ${_key}" -H "Content-Type: application/json" \
      "https://integrate.api.nvidia.com/v1/chat/completions" \
      -d "$(jq -n --arg mid "$m" '{model:$mid, max_tokens:1, messages:[{role:"user",content:"hi"}]}')" 2>/dev/null || echo "000")
    echo "[init]   probe $m (key#$(( (_ki-1) % _nkeys ))) -> HTTP $_code"
    echo "$_now" > "$_stamp"
    [ "$_code" != "200" ] && echo "$m" >> /tmp/nim-probe-bad.txt
    sleep 1
  done < <(build_all_models)
}

# ══ 【⑥ 】启动健康打分选型：读本地 call_logs，分档输出推荐 ═══════
nim_health_pick() {
  echo "[init] nim_health_pick: 读近1h本地 call_logs 打分（零外部请求）..."
  [ ! -f "$_DB_PATH" ] && { echo "[init]   no DB, skip pick."; return 0; }
  local _has_tbl
  _has_tbl=$(sqlite3 "$_DB_PATH" "SELECT name FROM sqlite_master WHERE type='table' AND name='call_logs';" 2>/dev/null || echo "")
  [ -z "$_has_tbl" ] && echo "[init]   call_logs 表不存在（尚无流量），本次按默认分档推荐。"

  _score_model() {
    local mid="$1" row
    [ -z "$_has_tbl" ] && { echo "NA"; return; }
    row=$(sqlite3 -separator '|' "$_DB_PATH" "
      SELECT
        printf('%.0f', SUM(CASE WHEN status_code BETWEEN 200 AND 299 THEN 1 ELSE 0 END)*100.0/COUNT(*)),
        printf('%.0f', AVG(latency_ms)),
        COUNT(*)
      FROM call_logs
      WHERE provider='nvidia' AND model_id='nvidia/$(sql_escape "$mid")'
        AND created_at > datetime('now','-1 hour');" 2>/dev/null || echo "")
    [ -z "$row" ] || [ "${row%%|*}" = "" ] && { echo "NA"; return; }
    echo "$row"
  }

  _pick_from() {
    local best="" best_ok=-1 best_ms=999999 m sc ok ms n
    for m in "$@"; do
      grep -Fxq "$m" /tmp/nim-deprecated.txt 2>/dev/null && continue
      grep -Fxq "$m" /tmp/nim-probe-bad.txt 2>/dev/null && continue
      sc=$(_score_model "$m")
      if [ "$sc" = "NA" ]; then
        [ -z "$best" ] && best="$m (无历史数据, 默认档位首选)"
        continue
      fi
      ok="${sc%%|*}"; ms=$(echo "$sc" | cut -d'|' -f2); n=$(echo "$sc" | cut -d'|' -f3)
      if [ "${ok:-0}" -gt "$best_ok" ] 2>/dev/null || \
         { [ "${ok:-0}" -eq "$best_ok" ] 2>/dev/null && [ "${ms:-999999}" -lt "$best_ms" ] 2>/dev/null; }; then
        best_ok=$ok; best_ms=$ms; best="$m (ok ${ok}%, ${ms}ms, n=${n})"
      fi
    done
    [ -z "$best" ] && best="（无存活候选）"
    echo "$best"
  }

  local PICK_CODE PICK_FAST PICK_GEN
  PICK_CODE=$(_pick_from "${NIM_CODEX_MODELS[@]}")
  PICK_FAST=$(_pick_from "${NIM_FAST_MODELS[@]}")
  PICK_GEN=$(_pick_from "${NIM_POOL_MODELS[@]}")

  echo "[init] ══════════ 本次推荐主力（按分档）══════════"
  echo "[init]   🧑 💻 编程/复杂推理 : $PICK_CODE"
  echo "[init]   ⚡ 低延迟/日常快答 : $PICK_FAST"
  echo "[init]   🎯 综合均衡首选   : $PICK_GEN"
  echo "[init] ────────────────────────────────────────"
  echo "[init]   直调示例：model = nvidia/${PICK_CODE%% *}"
  echo "[init] ═════════════════════════════════════════"
}

# ══════════════════════════════════════════════════════════════
echo "[init] Starting NIM OmniRoute initializer v4.2.3 (profile=$_PROFILE, mode=$NIM_MODE)..."
echo "[init] BASE_URL=$BASE_URL"
check_dangerous_env

[ -z "$INITIAL_PASSWORD" ] && { echo "[init] ERROR: INITIAL_PASSWORD required"; exit 1; }
[ -z "$NIM_KEYS" ] && { echo "[init] ERROR: NIM_KEYS required"; exit 1; }

echo "[init] Waiting for OmniRoute..."
HWAIT=0
until curl -sf "$BASE_URL/api/monitoring/health" > /dev/null 2>&1; do
  sleep 3; HWAIT=$((HWAIT + 3))
  [ "$HWAIT" -ge 180 ] && { echo "[init] FATAL: not ready within 180s"; exit 1; }
done
echo "[init] OmniRoute up (after ${HWAIT}s)."

VERSION_HTTP=$(curl -s -o "$VERSION_FILE" -w "%{http_code}" "$BASE_URL/api/monitoring/health" 2>/dev/null || echo "000")
[ "$VERSION_HTTP" = "200" ] && echo "[init] version: $(jq -r '.version // "unknown"' "$VERSION_FILE" 2>/dev/null)"

echo "[init] Logging in..."
LOGIN_BODY=$(jq -n --arg password "$INITIAL_PASSWORD" '{password: $password}')
LOGIN_HTTP=$(curl -s -o "$LOGIN_RESP_FILE" -w "%{http_code}" -c "$COOKIE_FILE" \
  -X POST "$BASE_URL/api/auth/login" -H "Content-Type: application/json" -d "$LOGIN_BODY")
[ "$LOGIN_HTTP" != "200" ] && [ "$LOGIN_HTTP" != "201" ] && { echo "[init] ERROR login HTTP $LOGIN_HTTP"; cat "$LOGIN_RESP_FILE" || true; exit 1; }
grep -q "auth_token" "$COOKIE_FILE" 2>/dev/null || { echo "[init] ERROR no auth_token"; exit 1; }
echo "[init] Logged in."

purge_proxy_db

resolve_or_key() {
  printf '%s' "${OMNIROUTE_API_KEY:-$(cat "$OR_API_KEY_FILE" 2>/dev/null)}" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//'
}

if [ -n "$OMNIROUTE_API_KEY" ]; then
  OR_KEY="$(printf '%s' "$OMNIROUTE_API_KEY" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
  [ -z "$OR_KEY" ] && { echo "[init] FATAL: OMNIROUTE_API_KEY blank"; exit 1; }
  echo "$OR_KEY" > "$OR_API_KEY_FILE" 2>/dev/null || echo "[init] WARN write $OR_API_KEY_FILE failed"
  chmod 600 "$OR_API_KEY_FILE" 2>/dev/null || true
  echo "[init] OMNIROUTE_API_KEY env set, skip /api/keys."
elif [ -f "$OR_API_KEY_FILE" ] && [ -s "$OR_API_KEY_FILE" ]; then
  OR_KEY="$(cat "$OR_API_KEY_FILE" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
  echo "[init] OR_API_KEY file exists."
else
  echo "[init] Creating OmniRoute API Key..."
  KEY_BODY=$(jq -n --arg name "gate-internal" '{name: $name, expiresAt: null}')
  KEY_HTTP=$(curl -s -o "$KEY_RESP_FILE" -w "%{http_code}" -b "$COOKIE_FILE" \
    -X POST "$BASE_URL/api/keys" -H "Content-Type: application/json" -d "$KEY_BODY")
  if [ "$KEY_HTTP" = "200" ] || [ "$KEY_HTTP" = "201" ]; then
    OR_API_KEY_VALUE=$(jq -r '.key // empty' "$KEY_RESP_FILE")
    [ -z "$OR_API_KEY_VALUE" ] && { echo "[init] ERROR parse key"; exit 1; }
    echo "$OR_API_KEY_VALUE" > "$OR_API_KEY_FILE"; chmod 600 "$OR_API_KEY_FILE"; OR_KEY="$OR_API_KEY_VALUE"
    echo "[init] OR_API_KEY written."
  else
    echo "[init] ERROR /api/keys HTTP $KEY_HTTP"; exit 1
  fi
fi

echo "[init] Registering NIM keys..."
INDEX=1
while IFS= read -r RAW_KEY; do
  KEY=$(printf '%s' "$RAW_KEY" | tr -d '' | xargs)
  [ -z "$KEY" ] && continue
  NAME=$(printf "nim-%02d" "$INDEX")
  RESP_FILE="$(_resp omniroute-provider-$INDEX.json)"
  BODY=$(jq -n --arg provider "nvidia" --arg apiKey "$KEY" --arg name "$NAME" \
    '{provider:$provider, apiKey:$apiKey, name:$name, priority:1, testStatus:"unknown"}')
  HTTP_CODE=$(curl -s -o "$RESP_FILE" -w "%{http_code}" -b "$COOKIE_FILE" \
    -X POST "$BASE_URL/api/providers" -H "Content-Type: application/json" -d "$BODY")
  if [ "$HTTP_CODE" = "201" ] || [ "$HTTP_CODE" = "200" ]; then echo "[init] $NAME OK"; REGISTERED=$((REGISTERED+1))
  elif [ "$HTTP_CODE" = "409" ]; then echo "[init] $NAME exists"; SKIPPED=$((SKIPPED+1))
  else echo "[init] $NAME HTTP $HTTP_CODE"; cat "$RESP_FILE" || true; FAILED=$((FAILED+1)); fi
  INDEX=$((INDEX+1))
done <<< "$NIM_KEYS"
echo "[init] Keys: $REGISTERED registered, $SKIPPED skipped, $FAILED failed."

echo "[init] Fetching provider IDs..."
PROVIDERS_HTTP=$(curl -s -o "$PROVIDERS_FILE" -w "%{http_code}" -b "$COOKIE_FILE" "$BASE_URL/api/providers")
if [ "$PROVIDERS_HTTP" = "200" ]; then
  mapfile -t PROVIDER_IDS < <(jq -r '[.. | objects | select((.provider? // "")=="nvidia") | select((.id? // "")!="") | .id] | unique | .[]' "$PROVIDERS_FILE" 2>/dev/null)
fi
echo "[init] Provider IDs: ${#PROVIDER_IDS[@]}"

purge_proxy_db

echo "[init] Resilience (RPM=$_RPM, concurrent=$_CONCURRENT, interval=${_MIN_INTERVAL_MS}ms)..."
RESILIENCE_CODE=$(curl -s -o "$RESILIENCE_RESP_FILE" -w "%{http_code}" -b "$COOKIE_FILE" \
  -X PATCH "$BASE_URL/api/resilience" -H "Content-Type: application/json" \
  -d "{\"requestQueue\":{\"requestsPerMinute\":$_RPM,\"minTimeBetweenRequestsMs\":$_MIN_INTERVAL_MS,\"concurrentRequests\":$_CONCURRENT}}")
echo "[init] Resilience HTTP $RESILIENCE_CODE"

echo "[init] Routing + maxBodySizeMb=$_REQUEST_BODY_LIMIT_MB..."
SETTINGS_CODE=$(curl -s -o "$SETTINGS_RESP_FILE" -w "%{http_code}" -b "$COOKIE_FILE" \
  -X PATCH "$BASE_URL/api/settings" -H "Content-Type: application/json" \
  -d "{\"fallbackStrategy\":\"$_FALLBACK_STRATEGY\",\"stickyRoundRobinLimit\":$_STICKY_LIMIT,\"requestRetry\":2,\"maxRetryIntervalSec\":5,\"maxBodySizeMb\":$_REQUEST_BODY_LIMIT_MB}")
echo "[init] Settings HTTP $SETTINGS_CODE"
[ "$SETTINGS_CODE" != "200" ] && [ "$SETTINGS_CODE" != "201" ] && { echo "[init] ⚠️ Settings 非 2xx："; cat "$SETTINGS_RESP_FILE" || true; }

echo "[init] Compression (threshold=$_COMPRESS_THRESHOLD)..."
curl -s -o "$COMPRESS_RESP_FILE" -w "%{http_code}
" -b "$COOKIE_FILE" \
  -X PUT "$BASE_URL/api/settings/compression" -H "Content-Type: application/json" \
  -d "{\"enabled\":true,\"defaultMode\":\"$_COMPRESS_MODE\",\"autoTriggerTokens\":$_COMPRESS_THRESHOLD}" | sed 's/^/[init] Compression HTTP /'

echo "[init] Thinking budget..."
curl -s -o "$THINKING_RESP_FILE" -w "%{http_code}
" -b "$COOKIE_FILE" \
  -X PUT "$BASE_URL/api/settings/thinking-budget" -H "Content-Type: application/json" \
  -d "{\"mode\":\"$_THINKING_MODE\",\"baseBudget\":$_THINKING_BUDGET}" | sed 's/^/[init] Thinking HTTP /'

echo "[init] Memory legacy + Skills..."
curl -s -o "$MEMORY_LEGACY_RESP_FILE" -w "%{http_code}
" -b "$COOKIE_FILE" \
  -X PATCH "$BASE_URL/api/settings" -H "Content-Type: application/json" \
  -d '{"memoryEnabled":true,"memoryStrategy":"hybrid","memoryMaxTokens":2000,"memoryRetentionDays":30,"skillsEnabled":true}' | sed 's/^/[init] Memory legacy HTTP /'

echo "[init] Memory extended (static)..."
curl -s -o "$MEMORY_EXT_RESP_FILE" -w "%{http_code}
" -b "$COOKIE_FILE" \
  -X PUT "$BASE_URL/api/settings/memory" -H "Content-Type: application/json" \
  -d '{"embeddingSource":"static","staticEnabled":true,"transformersEnabled":false}' | sed 's/^/[init] Memory extended HTTP /'

echo "[init] Resetting circuit breakers (first-init clean start)..."
curl -s -o /dev/null -w "[init] CB reset HTTP %{http_code}
" -b "$COOKIE_FILE" \
  -X POST "$BASE_URL/api/resilience/reset" -H "Content-Type: application/json"

echo "[init] per-model 32K override (real_context=$_NIM_REAL_CONTEXT)..."
OVERRIDE_APPLIED=0; OVERRIDE_SKIPPED=0
apply_context_override() {
  if sqlite3 "$_DB_PATH" \
    "INSERT OR REPLACE INTO model_context_overrides (provider, model_id, real_context, source, refreshed_at)
     VALUES ('nvidia', '$(sql_escape "$1")', $2, 'manual', datetime('now'));" 2>/dev/null; then
    OVERRIDE_APPLIED=$((OVERRIDE_APPLIED+1))
  else OVERRIDE_SKIPPED=$((OVERRIDE_SKIPPED+1)); echo "[init]   override FAILED: $1"; fi
}
while IFS= read -r _M; do [ -z "$_M" ] && continue; apply_context_override "$_M" "$_NIM_REAL_CONTEXT"; done < <(build_all_models)
echo "[init] override: $OVERRIDE_APPLIED applied, $OVERRIDE_SKIPPED failed."

echo "[init] ─────────────────────────────────────────────"
echo "[init]   PROFILE=$_PROFILE MODE=$NIM_MODE KEYS=$_ALIVE_KEYS RPM=$_RPM BODY=$_REQUEST_BODY_LIMIT_MB MB"
echo "[init]   POOL_STRATEGY=$_POOL_STRATEGY PROBE=${NIM_PROBE:-0} REAL_CONTEXT=$_NIM_REAL_CONTEXT"
echo "[init] ─────────────────────────────────────────────"

hf_snapshot() {
  [ -z "$HF_TOKEN" ] || [ -z "$HF_DATASET_REPO" ] && return 0
  echo "[init] HF Dataset snapshot（配置 + 可选 DEBUG log）..."
  local BACKUP_DIR="/tmp/omni-snapshot"; mkdir -p "$BACKUP_DIR"
  local OR_KEY; OR_KEY="$(resolve_or_key)"
  curl -sf "$BASE_URL/api/settings/export-json" -H "Authorization: Bearer $OR_KEY" \
    | jq 'del(.usageHistory, .domainCostHistory, .domainBudgets) |
          (if (.apiKeys|type)=="array" then .apiKeys |= map(del(.key)) else . end) |
          (if (.providerConnections|type)=="array" then .providerConnections |= map(del(.credentials)) else . end)' \
    > "$BACKUP_DIR/omni_config.json"
  jq '.apiKeys' "$BACKUP_DIR/omni_config.json" > "$BACKUP_DIR/keys.json"
  jq '.providerConnections' "$BACKUP_DIR/omni_config.json" > "$BACKUP_DIR/providerConnections.json"
  jq '.settings' "$BACKUP_DIR/omni_config.json" > "$BACKUP_DIR/settings.json"
  jq '.combos' "$BACKUP_DIR/omni_config.json" > "$BACKUP_DIR/combos.json"

  # ── 【v4.2.3·⑨ 】DEBUG log 上传到 Dataset（debug_<时间戳>.log）──
  #   仅 DEBUG 模式且 INIT_LOG 存在时；默认开启，可用 NIM_DEBUG_LOG_TO_DATASET=0 关闭。
  #   同时本地只保留最近 NIM_DEBUG_LOG_KEEP(默认5) 个，避免 /data 与 Dataset 无限堆积。
  if [ "$NIM_MODE" = "DEBUG" ] && [ "${NIM_DEBUG_LOG_TO_DATASET:-1}" = "1" ] && [ -n "$INIT_LOG" ] && [ -f "$INIT_LOG" ]; then
    local _keep=${NIM_DEBUG_LOG_KEEP:-5}
    # 落盘完成前先刷新一次（tee 是行缓冲，通常已写入；这里确保文件存在且非空）
    cp -f "$INIT_LOG" "$BACKUP_DIR/debug_$(basename "$INIT_LOG" | sed 's/^init_//')" 2>/dev/null \
      && echo "[init] snapshot: 附带 DEBUG log -> debug_$(basename "$INIT_LOG" | sed 's/^init_//')" \
      || echo "[init] snapshot: WARN 复制 DEBUG log 失败，跳过。"
    # 本地滚动清理：只保留最近 _keep 个 init_*.log
    if [ -d "$LOG_DIR" ]; then
      ls -1t "$LOG_DIR"/init_*.log 2>/dev/null | tail -n +$(( _keep + 1 )) | xargs -r rm -f 2>/dev/null || true
    fi
  else
    [ "$NIM_MODE" = "DEBUG" ] && echo "[init] snapshot: DEBUG log 上传已禁用（NIM_DEBUG_LOG_TO_DATASET=0）。"
  fi

  python3 - <<'PYEOF'
import os
from datetime import datetime, timezone
from huggingface_hub import HfApi
api = HfApi(token=os.environ["HF_TOKEN"])
api.upload_folder(folder_path="/tmp/omni-snapshot", path_in_repo="omni_data",
    repo_id=os.environ["HF_DATASET_REPO"], repo_type="dataset",
    commit_message=f"Sync omni_data - {datetime.now(timezone.utc).isoformat()}")
print("[init] HF Dataset uploaded.")
PYEOF
}

# ── 增量模式（⑧ 增量门放宽：任一 nim-* combo 或 INIT_MARKER 存在）──
if [ -f "$_DB_PATH" ]; then
  COMBO_COUNT=$(sqlite3 "$_DB_PATH" "SELECT COUNT(*) FROM combos WHERE name IN ('nim-pool','nim-codex');" 2>/dev/null || echo 0)
  if [ "${COMBO_COUNT:-0}" -gt 0 ] || [ -f "$INIT_MARKER" ]; then
    echo "[init] Incremental mode."
    purge_proxy_db
    # ⑤ 只清"已过期"熔断，保留仍在冷却窗内的历史信号
    sqlite3 "$_DB_PATH" "DELETE FROM domain_circuit_breakers WHERE cooldown_until < datetime('now');" 2>/dev/null || true
    check_nim_model_health
    nim_probe
    # ⑦ 增量也走幂等 upsert（同时修复 deprecated 与撞名）
    mapfile -t POOL_ALIVE  < <(filter_alive "${NIM_POOL_MODELS[@]}")
    mapfile -t CODEX_ALIVE < <(filter_alive "${NIM_CODEX_MODELS[@]}")
    upsert_combo "nim-pool"  "$_POOL_STRATEGY"  "${POOL_ALIVE[@]}"
    upsert_combo "nim-codex" "$_CODEX_STRATEGY" "${CODEX_ALIVE[@]}"
    nim_health_pick
    hf_snapshot
    echo "[init] Done (incremental). v4.2.3"
    exit 0
  fi
else
  echo "[init] DB not present. First-time init."
fi

check_nim_model_health
nim_probe

echo "[init] Registering models..."
register_model() {
  local MODEL_ID="$1" F="$(_resp omniroute-model-$(echo "$1" | tr '/' '-').json)" C
  C=$(curl -s -o "$F" -w "%{http_code}" -b "$COOKIE_FILE" -X POST "$BASE_URL/api/provider-models" \
    -H "Content-Type: application/json" -d "$(jq -n --arg provider "nvidia" --arg modelId "$MODEL_ID" '{provider:$provider, modelId:$modelId}')")
  if [ "$C" = "200" ] || [ "$C" = "201" ]; then echo "[init] model $MODEL_ID OK"
  elif [ "$C" = "409" ]; then echo "[init] model $MODEL_ID exists"
  else echo "[init] model $MODEL_ID WARN $C"; cat "$F" || true; fi
}
while IFS= read -r _M; do [ -z "$_M" ] && continue; register_model "$_M"; done < <(build_all_models | { grep -Fxvf /tmp/nim-deprecated.txt || true; })
echo "[init] Model registration done."

mapfile -t POOL_ALIVE  < <(filter_alive "${NIM_POOL_MODELS[@]}")
mapfile -t CODEX_ALIVE < <(filter_alive "${NIM_CODEX_MODELS[@]}")

# ⑦ first-init 也走幂等 upsert（根治 R2 restore 后撞名）
upsert_combo "nim-pool"  "$_POOL_STRATEGY"  "${POOL_ALIVE[@]}"
upsert_combo "nim-codex" "$_CODEX_STRATEGY" "${CODEX_ALIVE[@]}"

nim_health_pick
hf_snapshot
purge_proxy_db

touch "$INIT_MARKER"
echo "[init] Final health check..."
HEALTH_FILE="$(_resp omniroute-final-health.json)"
HEALTH_HTTP=$(curl -s -o "$HEALTH_FILE" -w "%{http_code}" "$BASE_URL/api/monitoring/health" 2>/dev/null || echo "000")
[ "$HEALTH_HTTP" = "200" ] && echo "[init]   Status: $(jq -r '.status // "unknown"' "$HEALTH_FILE") / $(jq -r '.version // "unknown"' "$HEALTH_FILE")"
echo "[init] Done (first-init). v4.2.3"
```


## litestream.yml

```yml
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
      auto-recover: true

snapshot:
  interval: 1h
  retention: 24h
```


## package.json

```json
{
  "name": "omniroute-gate",
  "version": "4.2.0",
  "private": true,
  "description": "PSK auth gate in front of OmniRoute (HF Space :7860 -> :20128)",
  "main": "gate.js",
  "engines": {
    "node": ">=22.0.0"
  },
  "scripts": {
    "start": "node gate.js"
  },
  "dependencies": {
    "express": "^4.21.2",
    "http-proxy-middleware": "^3.0.3"
  }
}
```


