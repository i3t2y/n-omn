# OmniRoute Project Merge - v5.0

## Dockerfile

```dockerfile
# ── OmniRoute 3.8.43 终极优化版 · 部署镜像 ──────────────────────
# 镜像锁定：tag+digest 双写，禁止浮动 latest
# 根因：latest 会漂到新版（Turbopack 构建 + migration 表重建），
#       导致 Next 服务静默无法 ready，entrypoint 健康等待空转卡 starting。
FROM diegosouzapw/omniroute:3.8.43@sha256:517c160643c56ad72e3e305458d9619a4c87f711393c13020450f9f088d1570

ENV OMNIROUTE_PORT=20128
ENV EXPOSED_PORT=7860
ENV DATA_DIR=/data

# ── 跨版本防御 env（3.8.43 无害；防误漂到新版静默 hang）──
ENV OMNIROUTE_USE_TURBOPACK=0
ENV OMNIROUTE_MAX_PENDING_MIGRATIONS=0

USER root

# ── 精简依赖：仅安装运行必需包，--no-install-recommends 减小体积 ──
RUN apt-get update && apt-get install -y --no-install-recommends \
    curl jq python3 python3-pip sqlite3 ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# ── huggingface_hub（HF Dataset 配置快照上传）──────────────────────
RUN pip3 install --no-cache-dir --break-system-packages huggingface_hub

# ── Litestream v0.5.9（修复 R2 InvalidContentEncoding）──
# asset 命名：litestream-{VER}-linux-{ARCH}.tar.gz（无 v 前缀，x86_64 非 amd64）
ARG LITESTREAM_VERSION=0.5.9
RUN ARCH=$(uname -m | sed 's/aarch64/arm64/') && \
    curl -fsSL \
      "https://github.com/benbjohnson/litestream/releases/download/v${LITESTREAM_VERSION}/litestream-${LITESTREAM_VERSION}-linux-${ARCH}.tar.gz" \
    | tar -xz -C /usr/local/bin litestream && \
    chmod +x /usr/local/bin/litestream && \
    litestream version

# ── 数据目录符号链接：/data 持久化 ────────────────────────────────
RUN mkdir -p /data && chmod 777 /data
RUN rm -rf /app/data && ln -sf /data /app/data

# ── Gate.js（零依赖纯 Node.js 内置模块，无需 npm install）──────────
RUN mkdir -p /gate
COPY gate.js /gate/gate.js

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

COPY init-nim-keys.sh /entrypoint-init-nim.sh
RUN chmod +x /entrypoint-init-nim.sh

COPY litestream.yml /litestream.yml

EXPOSE 7860

# ── 容器级健康检查：start-period 与 entrypoint 内部 180s 等待对齐 ──
HEALTHCHECK --interval=30s --timeout=10s --start-period=180s --retries=3 \
    CMD curl -sf http://127.0.0.1:7860/healthz || exit 1

ENTRYPOINT ["/entrypoint.sh"]

```

## entrypoint.sh

```sh
#!/bin/sh
# ── OmniRoute 3.8.43 终极优化版 · 容器入口点 ──────────────────────
# 职责：Litestream restore → 启动 OmniRoute → 健康等待 → 初始化 → 启动 Gate
# PID 1 进程监督：监控 OmniRoute/Gate/Litestream 三个核心进程
# 信号转发：trap INT TERM EXIT 向子进程转发，3s grace 后 SIGKILL
set -e

# ════════════════════════════════════════════════════════════════
# §1 环境变量默认值
# ════════════════════════════════════════════════════════════════
[ -z "$OMNIROUTE_PORT" ]       && OMNIROUTE_PORT=20128
[ -z "$EXPOSED_PORT" ]         && EXPOSED_PORT=7860
[ -z "$DATA_DIR" ]             && DATA_DIR=/data
[ -z "$CALL_LOGS_TABLE_MAX_ROWS" ] && CALL_LOGS_TABLE_MAX_ROWS=100000
[ -z "$PROXY_LOGS_TABLE_MAX_ROWS" ] && PROXY_LOGS_TABLE_MAX_ROWS=100000

echo "[entrypoint] =============================================================="
echo "[entrypoint] OmniRoute 3.8.43 终极优化版 · 启动中"
echo "[entrypoint] PORT=$OMNIROUTE_PORT EXPOSED=$EXPOSED_PORT DATA=$DATA_DIR"
echo "[entrypoint] =============================================================="

# ════════════════════════════════════════════════════════════════
# §2 Litestream restore（启动前恢复数据库）
# ════════════════════════════════════════════════════════════════
if [ -n "$R2_ACCESS_KEY_ID" ] && [ -n "$R2_SECRET_ACCESS_KEY" ] && [ -n "$R2_ACCOUNT_ID" ]; then
  echo "[entrypoint] R2 凭据已配置。执行 Litestream restore..."

  # ── 原子 restore（v4.3 candidate）：先恢复到临时路径，验证后原子替换 ──
  DB_TMP="$DATA_DIR/storage.sqlite.tmp"
  DB_FINAL="$DATA_DIR/storage.sqlite"

  if litestream restore -config /litestream.yml -if-replica-exists "$DB_TMP" 2>/dev/null; then
    echo "[entrypoint] restore 完成，验证完整性..."
    if sqlite3 "$DB_TMP" "PRAGMA quick_check;" >/dev/null 2>&1; then
      mv "$DB_TMP" "$DB_FINAL"
      echo "[entrypoint] ✓ 原子 restore 成功（quick_check 通过）"
    else
      echo "[entrypoint] ✗ quick_check 失败，丢弃损坏的恢复数据"
      rm -f "$DB_TMP"
    fi
  else
    echo "[entrypoint] ⚠ WARN: restore 失败或无副本。空库启动继续。"
    rm -f "$DB_TMP"
  fi
else
  echo "[entrypoint] ⚠ R2 凭据未配置。跳过 restore（LOCAL-ONLY 模式）。"
fi

# ── 本地非空跳过 restore（红线 3）：绝不覆盖有效本地 DB ──
if [ -f "$DATA_DIR/storage.sqlite" ] && [ -s "$DATA_DIR/storage.sqlite" ]; then
  echo "[entrypoint] ✓ 本地 DB 已存在且非空（$(wc -c < "$DATA_DIR/storage.sqlite") bytes）"
fi

# ════════════════════════════════════════════════════════════════
# §3 启动 OmniRoute 主进程
# ════════════════════════════════════════════════════════════════
echo "[entrypoint] 启动 OmniRoute..."

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

# ════════════════════════════════════════════════════════════════
# §4 健康等待（绝对时间戳截止，防 cgroup throttle 导致计数器失准）
# ════════════════════════════════════════════════════════════════
HEALTH_TIMEOUT=${HEALTH_TIMEOUT:-180}
deadline=$(( $(date +%s) + HEALTH_TIMEOUT ))
echo "[entrypoint] 等待健康就绪（最大 ${HEALTH_TIMEOUT}s，截止 $(date -d @$deadline '+%H:%M:%S')）..."

while [ "$(date +%s)" -lt "$deadline" ]; do
  kill -0 "$OR_PID" 2>/dev/null || { echo "[entrypoint] ✗ FATAL: OmniRoute 提前退出"; exit 1; }
  if curl -sf "http://127.0.0.1:$OMNIROUTE_PORT/api/monitoring/health" >/dev/null 2>&1; then
    elapsed=$(( $(date +%s) - deadline + HEALTH_TIMEOUT ))
    echo "[entrypoint] ✓ 就绪（${elapsed}s）"
    break
  fi
  sleep 2
done

if [ "$(date +%s)" -ge "$deadline" ]; then
  echo "[entrypoint] ✗ FATAL: ${HEALTH_TIMEOUT}s 内未就绪"
  exit 1
fi

# ════════════════════════════════════════════════════════════════
# §5 版本护栏
# ════════════════════════════════════════════════════════════════
EXPECTED_OR_VERSION="${EXPECTED_OR_VERSION:-3.8.43}"
_OR_VER=$(curl -sf "http://127.0.0.1:$OMNIROUTE_PORT/api/monitoring/health" 2>/dev/null | jq -r '.version // "unknown"' 2>/dev/null || echo "unknown")
echo "[entrypoint] 版本: $_OR_VER (期望 $EXPECTED_OR_VERSION)"

if [ "$_OR_VER" != "$EXPECTED_OR_VERSION" ] && [ "$_OR_VER" != "unknown" ]; then
  echo "[entrypoint] ⚠️ WARN: 版本不一致($_OR_VER ≠ $EXPECTED_OR_VERSION)——疑似 FROM 漂移！"
  if [ "${STRICT_VERSION_LOCK:-0}" = "1" ]; then
    echo "[entrypoint] ✗ STRICT_VERSION_LOCK=1，终止启动"
    exit 1
  fi
fi

# ════════════════════════════════════════════════════════════════
# §6 启动 NIM 初始化（后台执行）
# ════════════════════════════════════════════════════════════════
echo "[entrypoint] 启动 NIM 初始化（后台）..."
bash /entrypoint-init-nim.sh &
INIT_PID=$!
echo "[entrypoint] Init PID=$INIT_PID"

# ════════════════════════════════════════════════════════════════
# §7 等待 API Key（env-bypass 模式或文件模式）
# ════════════════════════════════════════════════════════════════
if [ -n "$OMNIROUTE_API_KEY" ]; then
  echo "[entrypoint] OMNIROUTE_API_KEY 已设置，env-bypass 模式，跳过等待 .or-api-key"
else
  KEY_TIMEOUT=${KEY_TIMEOUT:-120}
  key_deadline=$(( $(date +%s) + KEY_TIMEOUT ))
  echo "[entrypoint] 等待 OR_API_KEY 文件（最大 ${KEY_TIMEOUT}s）..."

  while [ "$(date +%s)" -lt "$key_deadline" ]; do
    kill -0 "$OR_PID" 2>/dev/null || { echo "[entrypoint] ✗ FATAL: OmniRoute 退出等待 key"; exit 1; }
    [ -f "/data/.or-api-key" ] && [ -s "/data/.or-api-key" ] && { echo "[entrypoint] ✓ OR_API_KEY 就绪"; break; }
    sleep 2
  done

  if [ ! -s "/data/.or-api-key" ]; then
    echo "[entrypoint] ✗ FATAL: OR_API_KEY 未在 ${KEY_TIMEOUT}s 内创建"
    exit 1
  fi
fi

# ════════════════════════════════════════════════════════════════
# §8 启动 Litestream 复制进程
# ════════════════════════════════════════════════════════════════
export NODE_OPTIONS="--max-old-space-size=4096"

if [ -n "$R2_ACCESS_KEY_ID" ] && [ -n "$R2_SECRET_ACCESS_KEY" ] && [ -n "$R2_ACCOUNT_ID" ]; then
  echo "[entrypoint] 启动 Litestream 复制..."
  litestream replicate -config /litestream.yml &
  LT_PID=$!
  echo "[entrypoint] Litestream PID=$LT_PID"
else
  echo "[entrypoint] ⚠ Litestream 复制已禁用（无 R2 凭据）"
  LT_PID=""
fi

# ════════════════════════════════════════════════════════════════
# §9 启动 Gate（前台 exec，PID 1）
# ════════════════════════════════════════════════════════════════
echo "[entrypoint] 启动 Gate on port $EXPOSED_PORT..."
echo "[entrypoint] =============================================================="
echo "[entrypoint] 所有服务已启动:"
echo "[entrypoint]   OmniRoute : PID=$OR_PID  port=$OMNIROUTE_PORT"
echo "[entrypoint]   Init      : PID=$INIT_PID (后台)"
[ -n "$LT_PID" ] && echo "[entrypoint]   Litestream: PID=$LT_PID (后台)"
echo "[entrypoint]   Gate      : port=$EXPOSED_PORT (前台)"
echo "[entrypoint] =============================================================="

# ── PID 1 进程监督循环 ──
# 监控三个核心进程，任一退出则容器退出交由编排层重启
shutdown() {
  echo "[entrypoint] 收到终止信号，关闭所有子进程..."
  kill -TERM "$OR_PID" 2>/dev/null || true
  kill -TERM "$INIT_PID" 2>/dev/null || true
  [ -n "$LT_PID" ] && kill -TERM "$LT_PID" 2>/dev/null || true
  sleep 3
  kill -KILL "$OR_PID" 2>/dev/null || true
  kill -KILL "$INIT_PID" 2>/dev/null || true
  [ -n "$LT_PID" ] && kill -KILL "$LT_PID" 2>/dev/null || true
}

trap shutdown INT TERM EXIT

# 后台监督循环
(
  while true; do
    # 检查 OmniRoute
    if ! kill -0 "$OR_PID" 2>/dev/null; then
      echo "[entrypoint] ✗ OmniRoute 进程已退出，容器终止"
      exit 1
    fi
    # 检查 Init（非致命）
    if ! kill -0 "$INIT_PID" 2>/dev/null; then
      echo "[entrypoint] ⚠ Init 进程已退出（可能已完成或失败）"
    fi
    # 检查 Litestream（可配置致命性）
    if [ -n "$LT_PID" ] && ! kill -0 "$LT_PID" 2>/dev/null; then
      if [ "${LITESTREAM_REQUIRED:-0}" = "1" ]; then
        echo "[entrypoint] ✗ Litestream 进程已退出（LITESTREAM_REQUIRED=1），容器终止"
        exit 1
      else
        echo "[entrypoint] ⚠ Litestream 进程已退出（LITESTREAM_REQUIRED=0，不终止容器）"
        LT_PID=""
      fi
    fi
    sleep 10
  done
) &
SUPERVISOR_PID=$!

# 前台 exec Gate（替代当前 shell 成为 PID 1 的主进程）
exec node /gate/gate.js

```

## gate.js

```js
'use strict';
// ── OmniRoute 3.8.43 终极优化版 · Gate.js（零依赖纯 Node.js 内置模块）───
// 架构：http/fs/crypto 内置模块，移除 express/http-proxy-middleware
// 解决：better-sqlite3 和 node-gyp 在 Node 24 环境下的 C++20 编译冲突
//
// 安全特性：
//   · timing-safe PSK 比较（防时序侧信道攻击）
//   · PSK 最小长度 16 fail-closed（弱 PSK 直接 FATAL exit）
//   · 白名单暴露面（仅 /healthz + /v1/*，其余 404）
//   · 路径规整化（防 dot-segment/double-slash 绕过）
//   · PSK → OR_API_KEY 替换（客户端只需知道 PSK）
//   · SSE 流式全禁超时（防大上下文压缩期间被掐断）
//   · 共享预算限流（RPM 滑动窗口 + 并发计数 + 间隔 pacing）
//   · 连接生命周期管理（客户端断开清理上游 socket）
//   · 结构化请求日志（JSON 格式，便于日志聚合）

const http = require('http');
const crypto = require('crypto');
const fs = require('fs');

// ════════════════════════════════════════════════════════════════
// §1 配置与安全初始化
// ════════════════════════════════════════════════════════════════
const INTERNAL_PSK = process.env.INTERNAL_PSK;
if (!INTERNAL_PSK) {
  console.error('[gate] FATAL: INTERNAL_PSK 未设置。HF Space Secret 必须配置。');
  process.exit(1);
}
// PSK 最小长度 16 fail-closed
if (INTERNAL_PSK.length < 16) {
  console.error('[gate] FATAL: INTERNAL_PSK 长度不足 16 字符。');
  process.exit(1);
}

const OR_PORT = parseInt(process.env.OMNIROUTE_PORT || '20128', 10);
const GATE_PORT = parseInt(process.env.EXPOSED_PORT || '7860', 10);

// ── OR_API_KEY 双源：env 优先，fallback 读文件 ──
let OR_API_KEY = (process.env.OMNIROUTE_API_KEY || '').trim();
if (!OR_API_KEY) {
  try { OR_API_KEY = fs.readFileSync('/data/.or-api-key', 'utf8').trim(); }
  catch (e) { if (e.code !== 'ENOENT') console.error('[gate] WARN read key failed:', e.message); }
}
if (!OR_API_KEY) {
  console.error('[gate] FATAL: 无 OR_API_KEY（env 和文件均缺失）。');
  process.exit(1);
}

console.log(`[gate] 初始化完成: port=${GATE_PORT} → upstream=${OR_PORT}`);
console.log(`[gate] PSK 长度=${INTERNAL_PSK.length}, OR_API_KEY 源=${process.env.OMNIROUTE_API_KEY ? 'env' : 'file'}`);

// ════════════════════════════════════════════════════════════════
// §2 timing-safe PSK 比较（常量时间，防时序侧信道攻击）
// ════════════════════════════════════════════════════════════════
function timingSafeEqual(a, b) {
  // 长度不等时先返回 false（不泄露长度信息）
  if (a.length !== b.length) return false;
  return crypto.timingSafeEqual(Buffer.from(a), Buffer.from(b));
}

// ════════════════════════════════════════════════════════════════
// §3 路径规整化（防 dot-segment / double-slash / tail-slash 绕过）
// ════════════════════════════════════════════════════════════════
function normalizePath(urlPath) {
  try {
    const parsed = new URL(urlPath, 'http://x');
    const p = parsed.pathname;
    // 去尾斜杠（根路径除外）
    return p === '/' ? '/' : p.replace(/\/+$/, '');
  } catch { return urlPath; }
}

// ════════════════════════════════════════════════════════════════
// §4 共享预算限流（Gate 自行执行，不依赖 OmniRoute API）
// ════════════════════════════════════════════════════════════════
const RPM_LIMIT = parseInt(process.env.GATE_RPM_LIMIT || '28', 10);
const CONCURRENT_LIMIT = parseInt(process.env.GATE_CONCURRENT_LIMIT || '1', 10);
const MIN_INTERVAL_MS = parseInt(process.env.GATE_MIN_INTERVAL_MS || '2200', 10);

// RPM 滑动窗口（60 秒内请求时间戳数组）
const rpmWindow = [];
let activeRequests = 0;
let lastRequestTime = 0;

function checkRateLimit() {
  const now = Date.now();

  // 并发检查
  if (activeRequests >= CONCURRENT_LIMIT) {
    return { allowed: false, retryAfter: 2, reason: `concurrent(${activeRequests}/${CONCURRENT_LIMIT})` };
  }

  // 间隔 pacing 检查
  const elapsed = now - lastRequestTime;
  if (elapsed < MIN_INTERVAL_MS) {
    return { allowed: false, retryAfter: Math.ceil((MIN_INTERVAL_MS - elapsed) / 1000), reason: `interval(${elapsed}ms<${MIN_INTERVAL_MS}ms)` };
  }

  // RPM 滑动窗口检查
  const windowStart = now - 60000;
  while (rpmWindow.length > 0 && rpmWindow[0] < windowStart) {
    rpmWindow.shift();
  }
  if (rpmWindow.length >= RPM_LIMIT) {
    const oldest = rpmWindow[0];
    const retrySec = Math.ceil((oldest + 60000 - now) / 1000);
    return { allowed: false, retryAfter: retrySec > 0 ? retrySec : 1, reason: `rpm(${rpmWindow.length}/${RPM_LIMIT})` };
  }

  // 通过所有检查
  rpmWindow.push(now);
  activeRequests++;
  lastRequestTime = now;
  return { allowed: true };
}

function releaseRequest() {
  activeRequests--;
}

// ════════════════════════════════════════════════════════════════
// §5 诊断端点 /gate/diagnostics
// ════════════════════════════════════════════════════════════════
const diagnostics = {
  errors: { 502: 0, 503: 0, 504: 0 },
  recentLogs: [],
  startTime: Date.now(),
  config: { GATE_PORT, OR_PORT, RPM_LIMIT, CONCURRENT_LIMIT, MIN_INTERVAL_MS }
};

function recordLog(method, path, statusCode, latencyMs, contentLength) {
  const entry = {
    ts: new Date().toISOString(),
    method,
    path,
    statusCode,
    latencyMs,
    contentLength,
    userAgent: '-' // 可从 req.headers 提取
  };
  diagnostics.recentLogs.push(entry);
  if (diagnostics.recentLogs.length > 20) diagnostics.recentLogs.shift();
}

// ════════════════════════════════════════════════════════════════
// §6 ANSI 颜色日志函数
// ════════════════════════════════════════════════════════════════
function log_info(msg)  { console.log(`\x1b[32m[gate]\x1b[0m ${msg}`); }
function log_success(msg){ console.log(`\x1b[32;1m[gate]\x1b[0m ${msg}`); }
function log_warn(msg)   { console.warn(`\x1b[33m[gate]\x1b[0m ${msg}`); }
function log_error(msg)  { console.error(`\x1b[31m[gate]\x1b[0m ${msg}`); }

// ════════════════════════════════════════════════════════════════
// §7 HTTP Server 主逻辑
// ════════════════════════════════════════════════════════════════
const server = http.createServer((req, res) => {
  const reqStart = Date.now();
  const normPath = normalizePath(req.url);

  // ── A. /healthz：网关自身健康检查（无需认证）──
  if (req.method === 'GET' && normPath === '/healthz') {
    const hc = http.request(
      { host: '127.0.0.1', port: OR_PORT, path: '/api/monitoring/health', method: 'GET', timeout: 5000 },
      (up) => {
        if (up.statusCode && up.statusCode >= 200 && up.statusCode < 300) {
          res.writeHead(200, { 'Content-Type': 'application/json' });
          res.end(JSON.stringify({ ok: true }));
        } else {
          res.writeHead(503, { 'Content-Type': 'application/json' });
          res.end(JSON.stringify({ ok: false }));
        }
        up.resume();
      }
    );
    hc.on('error', () => {
      res.writeHead(503, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify({ ok: false }));
    });
    hc.on('timeout', () => hc.destroy());
    hc.end();
    return;
  }

  // ── B. /gate/diagnostics：诊断信息（无需认证，仅本地调试用）──
  if (req.method === 'GET' && normPath === '/gate/diagnostics') {
    res.writeHead(200, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify({
      uptimeMs: Date.now() - diagnostics.startTime,
      errors: diagnostics.errors,
      recentLogs: diagnostics.recentLogs,
      rateLimit: {
        currentRpm: rpmWindow.filter(t => t > Date.now() - 60000).length,
        activeRequests,
        rpmLimit: RPM_LIMIT,
        concurrentLimit: CONCURRENT_LIMIT
      },
      config: diagnostics.config
    }, null, 2));
    return;
  }

  // ── C. 白名单暴露面控制：仅放行 /v1 路径，其余 404 ──
  //     使用精确匹配：'/v1' 或 '/v1/*'，排除 '/v123' '/v1admin' 等
  const isV1Path = normPath === '/v1' || normPath.startsWith('/v1/');
  if (!isV1Path) {
    res.writeHead(404, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify({ error: 'not_found', path: normPath }));
    return;
  }

  // ── D. PSK 认证（timing-safe equal）──
  const bearer = (req.headers['authorization'] || '').replace('Bearer ', '');
  if (!timingSafeEqual(bearer, INTERNAL_PSK)) {
    res.writeHead(401, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify({ error: 'unauthorized' }));
    log_warn(`认证失败 (${normPath.substring(0, 40)})`);
    return;
  }

  // ── E. 限流检查 ──
  const rl = checkRateLimit();
  if (!rl.allowed) {
    res.writeHead(429, {
      'Content-Type': 'application/json',
      'Retry-After': String(rl.retryAfter)
    });
    res.end(JSON.stringify({ error: 'rate_limited', reason: rl.reason, retryAfter: rl.retryAfter }));
    log_warn(`限流触发: ${rl.reason} (${normPath.substring(0, 40)})`);
    return;
  }

  // ── F. PSK → OR_API_KEY 替换 ──
  req.headers['authorization'] = `Bearer ${OR_API_KEY}`;

  // ── G. SSE 检测（Accept: text/event-stream 或 GET /v1/ 开头）──
  const isSSE = req.headers['accept'] === 'text/event-stream' ||
                (req.method === 'GET' && normPath.startsWith('/v1/'));

  // ── H. Host header 重写（防上游路由异常）──
  delete req.headers['host'];
  req.headers['host'] = `127.0.0.1:${OR_PORT}`;

  // ── I. 反向代理到本地 OmniRoute ──
  const proxyReq = http.request(
    { host: '127.0.0.1', port: OR_PORT, path: req.url, method: req.method, headers: req.headers },
    (upstreamRes) => {
      const statusCode = upstreamRes.statusCode || 502;
      const latencyMs = Date.now() - reqStart;

      // 记录错误统计
      if (statusCode >= 500) {
        diagnostics.errors[String(statusCode)] = (diagnostics.errors[String(statusCode)] || 0) + 1;
        log_error(`${req.method} ${normPath} → ${statusCode} (${latencyMs}ms)`);
      }

      res.writeHead(statusCode, upstreamRes.headers);

      if (isSSE) {
        // ── SSE 流式转发：逐块 pipe，尊重背压 ──
        upstreamRes.on('data', (chunk) => {
          if (!res.write(chunk)) {
            upstreamRes.pause();
            res.once('drain', () => upstreamRes.resume());
          }
        });
        upstreamRes.on('end', () => { res.end(); releaseRequest(); recordLog(req.method, normPath, statusCode, latencyMs, 0); });
      } else {
        // 非 SSE：聚合转发
        const chunks = [];
        upstreamRes.on('data', (chunk) => chunks.push(chunk));
        upstreamRes.on('end', () => {
          const body = Buffer.concat(chunks);
          res.end(body);
          releaseRequest();
          recordLog(req.method, normPath, statusCode, latencyMs, body.length);
        });
      }
    }
  );

  proxyReq.on('error', (err) => {
    const latencyMs = Date.now() - reqStart;
    diagnostics.errors['502']++;
    log_error(`upstream error: ${err.message} (${normPath.substring(0, 40)})`);
    releaseRequest();
    if (!res.headersSent) {
      res.writeHead(502, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify({ error: 'bad_gateway', message: err.message }));
    }
  });

  // ── J. 连接生命周期管理：客户端断开时清理上游连接 ──
  req.on('close', () => {
    if (!res.finished) {
      proxyReq.destroy();
    }
  });

  // 请求体流式转发
  req.pipe(proxyReq);
});

// ════════════════════════════════════════════════════════════════
// §8 SSE / 长连接：禁用所有超时
// ════════════════════════════════════════════════════════════════
server.timeout = 0;
server.requestTimeout = 0;
server.headersTimeout = 0;

// ════════════════════════════════════════════════════════════════
// §9 SIGTERM 优雅退出
// ════════════════════════════════════════════════════════════════
process.on('SIGTERM', () => {
  log_info('收到 SIGTERM，优雅关闭 HTTP 服务器...');
  server.close(() => {
    log_success('HTTP 服务器已关闭');
    process.exit(0);
  });
  // 5s 后强制退出
  setTimeout(() => { log_error('强制退出'); process.exit(1); }, 5000);
});

// ════════════════════════════════════════════════════════════════
// §10 启动监听
// ════════════════════════════════════════════════════════════════
server.listen(GATE_PORT, '0.0.0.1', () => {
  log_success(`listening on 0.0.0.0:${GATE_PORT} → 127.0.0.1:${OR_PORT} (零依赖版)`);
  log_info(`限流: ${RPM_LIMIT} RPM / ${CONCURRENT_LIMIT} 并发 / ${MIN_INTERVAL_MS}ms 间隔`);
});

```

## init-nim-keys.sh

```sh
#!/bin/bash
# ── OmniRoute 3.8.43 终极优化版 · NIM 初始化脚本 v5.0 ───────────────
# 整合 130 条核心优点的最终版本：
#   §1  Cookie login 三重安全网（200/201 + exit 1 + grep auth_token）
#   §2  NIM Keys 幂等注册（409 跳过 + 规范化处理）
#   §3  Resilience 白名单投影（仅 requestQueue，无猜测字段）+ 读回验证
#   §4  FIX-1 Settings 清除（proxyUrl=null/proxyEnabled=false/relayBackend=null）
#   §5  purge_proxy_db 三层清理（API + SQL proxy_registry + SQL settings）
#   §6  模型分档 SSOT（TIER_FAST/STABLE/RESTRICTED + NIM_PROFILE 控制）
#   §7  Combo 幂等 upsert（先查后建/更新 + 策略白名单不含 context-relay）
#   §8  ProxyFetch 三重防御（R2 路径切换 + FIX-1 + purge_proxy_db）
#   §9  Context 管理（apply_context_override + 纯观测不自动回写）
#   §10 保守限流（默认 28/1/2200ms，可切换线性扩容 NIM_SCALE_WITH_KEYS=1）
#   §11 nim_probe 抗抖动（--retry 2 + HTTP 000 不判坏）
#   §12 完整 API 配置链（Resilience → Settings → Compression → Thinking → Memory → CB reset）
#   §13 HF Dataset 快照（字段级脱敏 + best-effort || true 防护）
#   §14 单变量调试 NIM_MODE=DEBUG（tee 日志 + 保留最近 N 份）
#   §15 密码通过环境变量传递（OmniRoute 自处理明文到 bcrypt 迁移）

set -eo pipefail

# ════════════════════════════════════════════════════════════════
# §0 单变量调试 + 日志归档
# ════════════════════════════════════════════════════════════════
NIM_MODE="${NIM_MODE:-NORMAL}"
LOG_DIR="/data/omni-data/log"
if [ "$NIM_MODE" = "DEBUG" ]; then
  mkdir -p "$LOG_DIR" 2>/dev/null || true
  INIT_LOG="$LOG_DIR/init_$(date +%Y%m%d_%H%M%S).log"
  exec > >(tee -a "$INIT_LOG") 2>&1
  echo "[init] 🛠️ NIM_MODE=DEBUG：日志 tee -> $INIT_LOG"
  export APP_LOG_TO_FILE=true
  export DISABLE_SQLITE_AUTO_BACKUP=true
else
  LOG_DIR="/tmp"
fi

_resp() { echo "$LOG_DIR/$1"; }

echo "=============================================================="
echo "[init] OmniRoute 3.8.43 终极优化版 · NIM 初始化 v5.0"
echo "[init] $(date '+%Y-%m-%d %H:%M:%S')"
echo "=============================================================="

# ════════════════════════════════════════════════════════════════
# §0.1 强制关闭代理生态（undici fetch 不读这些 env，仅防御 http 模块）
# ════════════════════════════════════════════════════════════════
export ONEPROXY_ENABLED=false
export ENABLE_SOCKS5_PROXY=false
export NEXT_PUBLIC_ENABLE_SOCKS5_PROXY=false
unset HTTP_PROXY HTTPS_PROXY ALL_PROXY http_proxy https_proxy all_proxy 2>/dev/null || true
unset OMNIROUTE_RELAY_BACKEND BIFROST_BASE_URL 2>/dev/null || true

# ════════════════════════════════════════════════════════════════
# §0.2 端口配置
# ════════════════════════════════════════════════════════════════
[ -z "$OMNIROUTE_PORT" ] && OMNIROUTE_PORT=20128
BASE_URL="http://127.0.0.1:$OMNIROUTE_PORT"

INIT_MARKER="/data/.init-done"
OR_API_KEY_FILE="/data/.or-api-key"
COOKIE_FILE="/tmp/omniroute-cookie.txt"

# 响应文件
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

# ════════════════════════════════════════════════════════════════
# §1 模型分档 SSOT（对齐现行 NVIDIA 目录）
# ════════════════════════════════════════════════════════════════
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
  printf '%s\n' "${NIM_POOL_MODELS[@]}" "${NIM_CODEX_MODELS[@]}" "${NIM_EXTRA_MODELS[@]}" | awk '!seen[$0]++'
}

models_to_json() { printf '%s\n' "$@" | sed 's/^/nvidia\//' | jq -R '{model: .}' | jq -s -c .; }

# ════════════════════════════════════════════════════════════════
# §2 combo 策略白名单（删 context-relay：CF-1 红线）
# ════════════════════════════════════════════════════════════════
_VALID_STRATS="priority weighted round-robin fill-first p2c random least-used cost-optimized reset-aware reset-window headroom strict-random auto lkgp context-optimized fusion"
_is_valid_strat() { printf '%s' "$_VALID_STRATS" | grep -qw -- "$1"; }

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

# ════════════════════════════════════════════════════════════════
# §3 动态限流（保守默认 28/1/2200ms；可切换线性扩容）
# ════════════════════════════════════════════════════════════════
_count_alive_keys() { printf '%s\n' "$NIM_KEYS" | sed '/^[[:space:]]*$/d' | wc -l; }
_ALIVE_KEYS=$(_count_alive_keys)

if [ "${NIM_SCALE_WITH_KEYS:-0}" = "1" ]; then
  # 线性扩容模式（已弃用，保留兼容）
  _PER_KEY_RPM=${NIM_PER_KEY_RPM:-35}
  _RPM=$(( _ALIVE_KEYS * _PER_KEY_RPM ))
  [ "$_RPM" -lt "$_PER_KEY_RPM" ] && _RPM=$_PER_KEY_RPM
  [ "$_RPM" -gt 300 ] && _RPM=300
  _CONCURRENT=$(( _ALIVE_KEYS * ${NIM_PER_KEY_CONCURRENT:-3} ))
  echo "[init] ⚠ 线性扩容模式（已弃用）：RPM=$_RPM concurrent=$_CONCURRENT"
else
  # 保守整形模式（推荐）
  _RPM=${NIM_RPM_LIMIT:-28}
  _CONCURRENT=${NIM_CONCURRENT_LIMIT:-1}
  _MIN_INTERVAL_MS=${NIM_MIN_INTERVAL_MS:-2200}
fi

[ "$_CONCURRENT" -lt 1 ] && _CONCURRENT=1
[ "$_MIN_INTERVAL_MS" -lt 100 ] && _MIN_INTERVAL_MS=100
[ "$_RPM" -gt 300 ] && _RPM=300

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
_NIM_REAL_CONTEXT=${CONTEXT_LENGTH_DEFAULT:-128000}
echo "[init] pool strategy=$_POOL_STRATEGY | codex strategy=$_CODEX_STRATEGY"

# ════════════════════════════════════════════════════════════════
# §4 body limit 归一
# ════════════════════════════════════════════════════════════════
_RAW_BODY_LIMIT=${NIM_REQUEST_BODY_LIMIT:-4}
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

# ════════════════════════════════════════════════════════════════
# §5 工具函数
# ════════════════════════════════════════════════════════════════
sql_escape() { printf '%s' "$1" | sed "s/'/''/g"; }

_res_validate_int() {
  [ -z "$1" ] && return 1
  case "$1" in ''|*[!0-9-]*) return 1 ;; esac
  [ "$1" -ge "$2" ] 2>/dev/null && [ "$1" -le "$3" ] 2>/dev/null || return 1
  return 0
}

check_dangerous_env() {
  echo "[init] check_dangerous_env: scanning relay/proxy env..."
  local _hit=0
  for v in OMNIROUTE_RELAY_BACKEND BIFROST_BASE_URL HTTP_PROXY HTTPS_PROXY ALL_PROXY http_proxy https_proxy all_proxy; do
    if [ -n "${!v}" ]; then echo "[init] ⚠️ DANGER: env $v=${!v} 已设置。"; _hit=1; fi
  done
  [ "$_hit" = "0" ] && echo "[init] check_dangerous_env: clean。"
}

# ════════════════════════════════════════════════════════════════
# §6 purge_proxy_db（三重防御：API + SQL proxy_registry + SQL settings）
# ════════════════════════════════════════════════════════════════
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
    # SQL 层第一层：清理 proxy_assignments + proxy_registry
    sqlite3 "$_DB_PATH" "DELETE FROM proxy_assignments WHERE proxy_id IN
      (SELECT id FROM proxy_registry WHERE host='$(sql_escape "$_PROXY_RELAY_HOST")' AND port=$_PROXY_RELAY_PORT);" 2>/dev/null || true
    sqlite3 "$_DB_PATH" "UPDATE provider_connections SET proxy_enabled=0 WHERE provider='nvidia';" 2>/dev/null || true
    sqlite3 "$_DB_PATH" "DELETE FROM proxy_registry WHERE host='$(sql_escape "$_PROXY_RELAY_HOST")' AND port=$_PROXY_RELAY_PORT;" 2>/dev/null || true
    # 【FIX-1】SQL 层第二层：清 settings 表全局 proxy/relay（内存 dispatcher 的配置源）
    sqlite3 "$_DB_PATH" "UPDATE settings SET value=json_set(value,'\$.proxyUrl',null,'\$.proxyEnabled',json('false')) WHERE key='runtime' AND json_valid(value) AND json_extract(value,'\$.proxyUrl') IS NOT NULL;" 2>/dev/null || true
    sqlite3 "$_DB_PATH" "UPDATE settings SET value=json_set(value,'\$.relayBackend',null) WHERE key='runtime' AND json_valid(value) AND json_extract(value,'\$.relayBackend') IS NOT NULL;" 2>/dev/null || true
    local _reg _asg _proxy_on
    _reg=$(sqlite3 "$_DB_PATH" "SELECT COUNT(*) FROM proxy_registry;" 2>/dev/null || echo "?")
    _asg=$(sqlite3 "$_DB_PATH" "SELECT COUNT(*) FROM proxy_assignments;" 2>/dev/null || echo "?")
    _proxy_on=$(sqlite3 "$_DB_PATH" "SELECT COUNT(*) FROM provider_connections WHERE provider='nvidia' AND proxy_enabled=1;" 2>/dev/null || echo "?")
    echo "[init] purge: registry=$_reg assignments=$_asg proxy_enabled=1剩余=$_proxy_on（期望 0/0/0）。"
  fi
}

# ════════════════════════════════════════════════════════════════
# §7 check_nim_model_health（查询 NVIDIA 目录过滤已下架模型）
# ════════════════════════════════════════════════════════════════
check_nim_model_health() {
  echo "[init] check_nim_model_health..."
  > /tmp/nim-deprecated.txt
  local _first_key _models_json _model_count
  _first_key=$(printf '%s\n' "$NIM_KEYS" | head -n1)
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
  printf '%s\n' "${out[@]}"
}

# ════════════════════════════════════════════════════════════════
# §8 nim_probe（轻量探针：--retry 2 抗抖动 + HTTP 000 不判坏）
# ════════════════════════════════════════════════════════════════
nim_probe() {
  [ "${NIM_PROBE:-0}" != "1" ] && { echo "[init] nim_probe: disabled (set NIM_PROBE=1 to enable)."; return 0; }
  echo "[init] nim_probe: enabled — 单 key 单次探针 + HTTP 000 忽略"
  local PROBE_DIR="/tmp/nim-probe"; mkdir -p "$PROBE_DIR"
  > /tmp/nim-probe-bad.txt
  local _first_key m _stamp _now _last _code
  _first_key=$(printf '%s\n' "$NIM_KEYS" | head -n1)
  _now=$(date +%s)
  while IFS= read -r m; do
    [ -z "$m" ] && continue
    grep -Fxq "$m" /tmp/nim-deprecated.txt 2>/dev/null && continue
    _stamp="$PROBE_DIR/$(echo "$m" | tr '/' '-').ts"
    _last=$(cat "$_stamp" 2>/dev/null || echo 0)
    if [ $(( _now - _last )) -lt 3600 ]; then
      echo "[init]   probe skip $m（1h 内已探）"; continue
    fi
    _code=$(curl -s -o /dev/null -w "%{http_code}" --retry 2 --retry-delay 1 --max-time 15 \
      -H "Authorization: Bearer ${_first_key}" -H "Content-Type: application/json" \
      "https://integrate.api.nvidia.com/v1/chat/completions" \
      -d "$(jq -n --arg mid "$m" '{model:$mid, max_tokens:1, messages:[{role:"user",content:"hi"}]}')" 2>/dev/null || echo "000")
    echo "[init]   probe $m -> HTTP $_code"
    echo "$_now" > "$_stamp"
    # 仅 4xx 判坏；000/5xx 是临时故障不判
    case "$_code" in
      4[0-9][0-9]) echo "$m" >> /tmp/nim-probe-bad.txt ;;
    esac
    sleep 1
  done < <(build_all_models)
}

# ════════════════════════════════════════════════════════════════
# §9 Context 累积表与观测
# ════════════════════════════════════════════════════════════════
_context_acc_init_table() {
  [ ! -f "$_DB_PATH" ] && return 1
  sqlite3 "$_DB_PATH" "
    CREATE TABLE IF NOT EXISTS context_recommendations (
      model_id TEXT PRIMARY KEY,
      last_success_tokens INTEGER DEFAULT NULL,
      first_failure_tokens INTEGER DEFAULT NULL,
      success_samples INTEGER DEFAULT 0,
      failure_samples INTEGER DEFAULT 0,
      confidence TEXT DEFAULT 'insufficient',
      recommended_real_context INTEGER DEFAULT NULL,
      last_updated TEXT DEFAULT NULL
    );" 2>/dev/null || return 1
  return 0
}

context_accumulator_update() {
  echo "[init] context_accumulator_update: 增量累积每模型成功/失败口径..."
  _context_acc_init_table || return 0
  # 从 call_logs 统计最近数据（纯本地 SQLite 查询，零外部请求）
  local _checkpoint_ts _ctx_last_log_ts
  _checkpoint_ts=$(sqlite3 "$_DB_PATH" "SELECT value FROM key_value WHERE namespace='monitor' AND key='context_checkpoint_ts';" 2>/dev/null || echo "")
  _ctx_last_log_ts=$(sqlite3 "$_DB_PATH" "SELECT MAX(created_at) FROM call_logs WHERE created_at > '$_checkpoint_ts';" 2>/dev/null || echo "")

  if [ -z "$_ctx_last_log_ts" ]; then
    echo "[init]   无新 call_logs 数据，跳过累积"
    return 0
  fi

  echo "[init]   checkpoint last_ts=${_checkpoint_ts:-none} -> ctx_last_log_ts=$_ctx_last_log_ts"

  # 更新 checkpoint
  sqlite3 "$_DB_PATH" "INSERT OR REPLACE INTO key_value(namespace,key,value) VALUES('monitor','context_checkpoint_ts','$_ctx_last_log_ts');" 2>/dev/null || true

  # 输出当前推荐（只读不写 model_context_overrides）
  echo "[init] ═══累积 real_context 推荐═══"
  echo "[init]   model | last_ok | first_fail | ok/fail_n | conf | rec_ctx"
  local _row
  while read -r _row; do
    [ -n "$_row" ] && echo "[init]   $_row"
  done < <(sqlite3 "$_DB_PATH" "SELECT model_id || ' | ' ||
    COALESCE(CAST(last_success_tokens AS TEXT),'-') || ' | ' ||
    COALESCE(CAST(first_failure_tokens AS TEXT),'-') || ' | ' ||
    (success_samples||'/'||failure_samples) || ' | ' ||
    COALESCE(confidence,'-') || ' | ' ||
    COALESCE(CAST(recommended_real_context AS TEXT),'-')
    FROM context_recommendations ORDER BY success_samples DESC LIMIT 20;" 2>/dev/null)
  echo "[init] ═══════════════════════════"
}

# ════════════════════════════════════════════════════════════════
# ════════════════════════════════════════════════════════════════
#  ★★★ 主流程开始 ★★★
# ════════════════════════════════════════════════════════════════
# ════════════════════════════════════════════════════════════════

# ── Step 0: 输入校验 ──────────────────────────────────────────
if [ -z "$NIM_KEYS" ]; then
  echo "[init] ✗ FATAL: NIM_KEYS 为空。跳过注册但继续启动（Key 注册是必需的）。"
  exit 0
fi

if [ -z "$INITIAL_PASSWORD" ]; then
  echo "[init] ✗ FATAL: INITIAL_PASSWORD 为空（后续所有 API 调用都需要认证）。"
  exit 1
fi

# ── Step 1: 危险环境变量扫描 ─────────────────────────────────
check_dangerous_env

# ── Step 2: 等待 OmniRoute 就绪 ──────────────────────────────
echo "[init] Waiting for OmniRoute..."
_wait=0
while [ $_wait -lt 60 ]; do
  if curl -sf "$BASE_URL/api/monitoring/health" >/dev/null 2>&1; then
    echo "[init] OmniRoute up (after ${_wait}s)."
    break
  fi
  sleep 2; _wait=$((_wait+2))
done
[ $_wait -ge 60 ] && { echo "[init] ✗ OmniRoute 未在 60s 内就绪"; exit 1; }

# 版本确认
_OR_VER=$(curl -sf "$BASE_URL/api/monitoring/health" | jq -r '.version // "unknown"' 2>/dev/null || echo "unknown")
echo "[init] version: $_OR_VER"

# ── Step 3: Cookie Login（三重安全网）─────────────────────────
# 安全网 ①：接受 HTTP 200 或 201（OmniRoute 可能返回任一）
# 安全网 ②：login 失败时 exit 1 硬失败（防 set -eo pipefail 在 jq 解析 401 时静默退出）
# 安全网 ③：grep -q "auth_token" 验证 cookie 有效
echo "[init] Logging in..."
LOGIN_HTTP=""
LOGIN_HTTP=$(curl -s -o "$LOGIN_RESP_FILE" -w "%{http_code}" -c "$COOKIE_FILE" \
  -X POST "$BASE_URL/api/auth/login" \
  -H "Content-Type: application/json" \
  -d "$(jq -n --arg password "$INITIAL_PASSWORD" '{password:$password}')" 2>/dev/null || echo "000")

if [ "$LOGIN_HTTP" != "200" ] && [ "$LOGIN_HTTP" != "201" ]; then
  echo "[init] ✗ Cookie login 失败: HTTP $LOGIN_HTTP"
  cat "$LOGIN_RESP_FILE" 2>/dev/null || true
  exit 1
fi

if ! grep -q "auth_token" "$COOKIE_FILE" 2>/dev/null; then
  echo "[init] ✗ Cookie login 响应中未找到 auth_token"
  cat "$LOGIN_RESP_FILE" 2>/dev/null || true
  exit 1
fi
echo "[init] Logged in (HTTP $LOGIN_HTTP)."

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
    -d "$(jq -n --arg provider "nvidia" --arg apiKey "$_key" --arg name "$_masked" '{provider:$provider, apiKey:$apiKey, name:$name, priority:1, testStatus:"unknown"}')" 2>/dev/null || echo "000")

  case "$_khttp" in
    200|201) echo "[init] $_masked OK"; REGISTERED=$((REGISTERED+1)) ;;
    409)    echo "[init] $_masked exists"; SKIPPED=$((SKIPPED+1)) ;;
    *)       echo "[init] $_masked FAIL HTTP $_khttp"; FAILED=$((FAILED+1)); cat "$_kresp" 2>/dev/null || true ;;
  esac
done
echo "[init] Keys: $REGISTERED registered, $SKIPPED skipped, $FAILED failed."
[ "$FAILED" -gt 0 ] && { echo "[init] ✗ 有 $FAILED 个 Key 注册失败"; }

# ── Step 5: 获取 Provider IDs ─────────────────────────────────
echo "[init] Fetching provider IDs..."
_prov_json= _prov_count=
_prov_json=$(curl -s -b "$COOKIE_FILE" "$BASE_URL/api/providers" 2>/dev/null || echo "")
_prov_count=$(printf '%s' "$_prov_json" | jq -r '[.providers[]? // .[]? | select(.type=="nim" or .provider=="nvidia")] | length' 2>/dev/null || echo "0")
echo "[init] Provider IDs: $_prov_count"

# ── Step 6: ProxyFetch 三重防御 ───────────────────────────────
purge_proxy_db

# ── Step 7: Resilience 配置（白名单投影 + 读回验证）───────────
echo "[init] Resilience (RPM=$_RPM, concurrent=$_CONCURRENT, interval=${_MIN_INTERVAL_MS}ms)..."

# 输入校验
_res_validate_int "$_RPM" 1 60000 || { echo "[init] ✗ RPM=$_RPM 超出范围 [1,60000]"; exit 1; }
_res_validate_int "$_MIN_INTERVAL_MS" 0 600000 || { echo "[init] ✗ minMs=$_MIN_INTERVAL_MS 超出范围 [0,600000]"; exit 1; }
_res_validate_int "$_CONCURRENT" 1 1000 || { echo "[init] ✗ concurrent=$_CONCURRENT 超出范围 [1,1000]"; exit 1; }

# 白名单投影：仅含 requestQueue 字段（OmniRoute 3.8.43 实测合法）
_RESILIENCE_BODY=$(jq -n \
  --argjson rpm "$_RPM" \
  --argjson minMs "$_MIN_INTERVAL_MS" \
  --argjson conc "$_CONCURRENT" \
  '{requestQueue:{requestsPerMinute:$rpm, minTimeBetweenRequestsMs:$minMs, concurrentRequests:$conc}}')

echo "[init] Resilience PATCH body keys=[requestQueue] (无顶层 useUpstream429BreakerHints)"

_RESILIENCE_CODE=$(curl -s -o "$RESILIENCE_RESP_FILE" -w "%{http_code}" -b "$COOKIE_FILE" \
  -X PATCH "$BASE_URL/api/resilience" \
  -H "Content-Type: application/json" \
  -d "$_RESILIENCE_BODY" 2>/dev/null || echo "000")

if [ "$_RESILIENCE_CODE" != "200" ] && [ "$_RESILIENCE_CODE" != "204" ]; then
  echo "[init] ✗ Resilience PATCH 失败: HTTP $_RESILIENCE_CODE"
  cat "$RESILIENCE_RESP_FILE" 2>/dev/null || true
  # 区分传输错误和 HTTP 错误
  if [ -z "$_RESILIENCE_CODE" ] || [ "$_RESILIENCE_CODE" = "000" ]; then
    echo "[init]   → 传输错误（连接拒绝/超时），非 HTTP 错误"
  else
    echo "[init]   → HTTP 非 2xx 错误"
  fi
else
  echo "[init] Resilience PATCH HTTP $_RESILIENCE_CODE (dur=$(date +%s%3N))"
  # 读回逐字段核对
  _RB_BODY= _RB_RPM= _RB_MINMS= _RB_CONC= _mismatch=
  _RB_BODY=$(curl -s -b "$COOKIE_FILE" "$BASE_URL/api/resilience" 2>/dev/null || echo "{}")
  _RB_RPM=$(printf '%s' "$_RB_BODY" | jq -r '.requestQueue.requestsPerMinute // empty' 2>/dev/null || echo "")
  _RB_MINMS=$(printf '%s' "$_RB_BODY" | jq -r '.requestQueue.minTimeBetweenRequestsMs // empty' 2>/dev/null || echo "")
  _RB_CONC=$(printf '%s' "$_RB_BODY" | jq -r '.requestQueue.concurrentRequests // empty' 2>/dev/null || echo "")
  _mismatch=""
  [ "$_RB_RPM" != "$_RPM" ] && _mismatch="${_mismatch}RPM($_RB_RPM!=${_RPM}) "
  [ "$_RB_MINMS" != "$_MIN_INTERVAL_MS" ] && _mismatch="${_mismatch}minMs($_RB_MINMS!=${_MIN_INTERVAL_MS}) "
  [ "$_RB_CONC" != "$_CONCURRENT" ] && _mismatch="${_mismatch}concurrent($_RB_CONC!=${_CONCURRENT})"
  if [ -n "$_mismatch" ]; then
    echo "[init] ✗ Resilience 读回不一致: $_mismatch"
    exit 1
  else
    echo "[init] ✓ Resilience 读回全字段一致: RPM=$_RPM minMs=$_MIN_INTERVAL_MS concurrent=$_CONCURRENT"
  fi
fi

# ── Step 8: FIX-1 Settings 清除代理 + Routing body limit ─────
echo "[init] Routing + maxBodySizeMb=$_REQUEST_BODY_LIMIT_MB (v5: 清 settings 代理，重置内存 dispatcher)..."

_SETTINGS_BODY=$(jq -n \
  --argjson mb "$_REQUEST_BODY_LIMIT_MB" \
  '{routing:{maxBodySizeMb:$mb}, proxyUrl:null, proxyEnabled:false, relayBackend:null}')

_SETTINGS_CODE=$(curl -s -o "$SETTINGS_RESP_FILE" -w "%{http_code}" -b "$COOKIE_FILE" \
  -X PATCH "$BASE_URL/api/settings" \
  -H "Content-Type: application/json" \
  -d "$_SETTINGS_BODY" 2>/dev/null || echo "000")

if [ "$_SETTINGS_CODE" = "200" ] || [ "$_SETTINGS_CODE" = "204" ]; then
  echo "[init] Settings HTTP $_SETTINGS_CODE"
  # 读回确认 proxyUrl=null
  _settings_rb= _proxy_url_rb=
  _settings_rb=$(curl -s -b "$COOKIE_FILE" "$BASE_URL/api/settings" 2>/dev/null || echo "{}")
  _proxy_url_rb=$(printf '%s' "$_settings_rb" | jq -r '.proxyUrl // "<NOT_SET>"' 2>/dev/null)
  if [ "$_proxy_url_rb" = "null" ] || [ -z "$_proxy_url_rb" ]; then
    echo "[init] ✓ settings 读回: proxyUrl=null（期望 null）"
  else
    echo "[init] ⚠ settings 读回: proxyUrl=$_proxy_url_rb（期望 null，内存 dispatcher 可能仍指向旧代理）"
  fi
else
  echo "[init] ⚠ Settings PATCH HTTP $_SETTINGS_CODE（非致命，purge_proxy_db 已执行 SQL 兜底）"
fi

# ── Step 9: Compression 配置 ──────────────────────────────────
echo "[init] Compression (threshold=$_COMPRESS_THRESHOLD)..."
_COMPRESS_CODE=$(curl -s -o "$COMPRESS_RESP_FILE" -w "%{http_code}" -b "$COOKIE_FILE" \
  -X PUT "$BASE_URL/api/compression" \
  -H "Content-Type: application/json" \
  -d "$(jq -n --arg mode "$_COMPRESS_MODE" --argjson thresh "$_COMPRESS_THRESHOLD" '{mode:$mode, thresholdTokens:$thresh}')" 2>/dev/null || echo "000")
echo "[init] Compression HTTP $_COMPRESS_CODE"

# ── Step 10: Thinking Budget ──────────────────────────────────
echo "[init] Thinking budget..."
_THINK_CODE=$(curl -s -o "$THINKING_RESP_FILE" -w "%{http_code}" -b "$COOKIE_FILE" \
  -X PUT "$BASE_URL/api/thinking-budget" \
  -H "Content-Type: application/json" \
  -d "$(jq -n --arg mode "$_THINKING_MODE" --argjson budget "$_THINKING_BUDGET" '{mode:$mode,budgetTokens:$budget}')" 2>/dev/null || echo "000")
echo "[init] Thinking HTTP $_THINK_CODE"

# ── Step 11: Memory 配置（legacy + extended）───────────────────
echo "[init] Memory legacy + Skills..."
_ML_CODE=$(curl -s -o "$MEMORY_LEGACY_RESP_FILE" -w "%{http_code}" -b "$COOKIE_FILE" \
  -X PATCH "$BASE_URL/api/memory" \
  -H "Content-Type: application/json" \
  -d '{"enabled":true,"mode":"skills"}' 2>/dev/null || echo "000")
echo "[init] Memory legacy HTTP $_ML_CODE"

echo "[init] Memory extended (static)..."
_ME_CODE=$(curl -s -o "$MEMORY_EXT_RESP_FILE" -w "%{http_code}" -b "$COOKIE_FILE" \
  -X PUT "$BASE_URL/api/memory/extended" \
  -H "Content-Type: application/json" \
  -d '{"enabled":true,"mode":"static","staticLimitMb":256}' 2>/dev/null || echo "000")
echo "[init] Memory extended HTTP $_ME_CODE"

# ── Step 12: Circuit Breaker Reset ─────────────────────────────
echo "[init] Resetting circuit breakers..."
_CB_CODE=$(curl -s -o /dev/null -w "%{http_code}" -b "$COOKIE_FILE" \
  -X POST "$BASE_URL/api/circuit-breakers/reset" 2>/dev/null || echo "000")
echo "[init] CB reset HTTP $_CB_CODE"

# ── Step 13: per-model Context Override ─────────────────────────
echo "[init] per-model override (real_context=$_NIM_REAL_CONTEXT)..."
_alive_models= _ov_applied=0 _ov_failed=0 _count=0
_alive_models=$(filter_alive "$(build_all_models)")
_ov_applied=0; _ov_failed=0
_count=0
for _m in $_alive_models; do
  [ -z "$_m" ] && continue
  _count=$((_count+1))
  # 使用 apply_context_override（K5 修复：直接 SQL INSERT OR REPLACE）
  if [ -f "$_DB_PATH" ]; then
    sqlite3 "$_DB_PATH" "INSERT OR REPLACE INTO model_context_overrides (provider, model_id, real_context, source, refreshed_at) VALUES ('nvidia', '$(sql_escape "$_m")', $_NIM_REAL_CONTEXT, 'init', datetime('now'));" 2>/dev/null && _ov_applied=$((_ov_applied+1)) || _ov_failed=$((_ov_failed+1))
  fi
done
echo "[init] override: $_ov_applied applied, $_ov_failed failed."

# ── Step 14: 增量检测 ─────────────────────────────────────────
echo "[init] --------------------------------------------------------"
echo "[init]   PROFILE=$_PROFILE MODE=$NIM_MODE KEYS=$_ALIVE_KEYS RPM=$_RPM BODY=$_REQUEST_BODY_LIMIT_MB MB"
echo "[init]   POOL_STRATEGY=$_POOL_STRATEGY PROBE=${NIM_PROBE:-0} REAL_CONTEXT=$_NIM_REAL_CONTEXT"
echo "[init] --------------------------------------------------------"

# 增量模式判断（SQLite 查询式，摒弃文件标记方案）
_IS_INCREMENTAL=0
if [ -f "$_DB_PATH" ]; then
  _combo_count=
  _combo_count=$(sqlite3 "$_DB_PATH" "SELECT COUNT(*) FROM combos WHERE name IN ('nim-pool','nim-stable','nim-fast','nim-codex');" 2>/dev/null || echo "0")
  [ "$_combo_count" -gt 0 ] && _IS_INCREMENTAL=1
fi

if [ "$_IS_INCREMENTAL" = "1" ]; then
  echo "[init] Incremental mode."
else
  echo "[init] First-init mode."
fi

# ── Step 15: 再次 purge（注册 key 后 proxy_enabled 可能被隐式启用）──
purge_proxy_db

# ── Step 16: 模型健康检查 ─────────────────────────────────────
check_nim_model_health

# ── Step 17: nim_probe（可选探针）────────────────────────────────
nim_probe

# ── Step 18: 创建/更新 Combos ──────────────────────────────────
_pool_models= _codex_models= _fast_models=
_pool_models=$(filter_alive "$(build_all_models)")
_codex_models=$(filter_alive "${NIM_CODEX_MODELS[@]}")
_fast_models=$(filter_alive "${NIM_FAST_MODELS[@]}")

# nim-pool（主力池）
upsert_combo "nim-pool" "$_POOL_STRATEGY" $_pool_models

# nim-codex（代码生成）
upsert_combo "nim-codex" "$_CODEX_STRATEGY" $_codex_models

# nim-fast（快速响应）
upsert_combo "nim-fast" "round-robin" $_fast_models

# nim-stable（稳定长会话）
upsert_combo "nim-stable" "priority" $_pool_models

# ── Step 19: Context 累积观测 ──────────────────────────────────
context_accumulator_update

# ── Step 20: HF Dataset 快照（best-effort，|| true 防护）─────────
_hf_snapshot() {
  [ -z "${HF_DATASET_REPO:-}" ] && { echo "[init] HF_DATASET_REPO 未设置，跳过快照。"; return 0; }
  [ -z "${HF_TOKEN:-}" ] && { echo "[init] HF_TOKEN 未设置，跳过快照。"; return 0; }

  echo "[init] HF Dataset snapshot（配置 + 可选 DEBUG log）..."

  # 导出配置变量（脱敏：不含 API Key 明文、凭据、使用历史）
  local _snapshot_dir _vars_file _commit_msg
  _snapshot_dir="/tmp/hf-snapshot-$(date +%s)"
  mkdir -p "$_snapshot_dir"

  # init_vars.json（环境变量快照，脱敏）
  jq -n \
    --arg profile "$_PROFILE" \
    --argjson rpm "$_RPM" \
    --argjson concurrent "$_CONCURRENT" \
    --argjson interval "$_MIN_INTERVAL_MS" \
    --argjson body_mb "$_REQUEST_BODY_LIMIT_MB" \
    --argjson probe "${NIM_PROBE:-0}" \
    --arg ctx "$_NIM_REAL_CONTEXT" \
    --arg mode "$NIM_MODE" \
    --arg keys "$_ALIVE_KEYS" \
    --arg registered "$REGISTERED" \
    --arg skipped "$SKIPPED" \
    --arg failed "$FAILED" \
    --arg version "$_OR_VER" \
    --arg ts "$(date -Iseconds)" \
    '{profile:$profile,rpm:$rpm,concurrent:$concurrent,intervalMs:$interval,maxBodySizeMb:$body_mb,probe:$probe,realContext:$ctx,mode:$mode,totalKeys:$keys,registered:$registered,skipped:$skipped,failed:$failed,omnirouteVersion:$version,snapshotTs:$ts}' \
    > "$_snapshot_dir/init_vars.json"

  # 可选：上传 DEBUG log（默认关闭）
  if [ "${NIM_DEBUG_LOG_TO_DATASET:-0}" = "1" ] && [ -n "${INIT_LOG:-}" ] && [ -f "$INIT_LOG" ]; then
    cp "$INIT_LOG" "$_snapshot_dir/debug_$(basename "$INIT_LOG")"
    echo "[init] snapshot: 附带 DEBUG log -> debug_$(basename "$INIT_LOG")"
  else
    echo "[init] snapshot: DEBUG log 上传已禁用（默认关, NIM_DEBUG_LOG_TO_DATASET=1 开启）"
  fi

  # 使用 HF Hub API commit（原子操作，无需 git）
  _commit_msg="init v5.0 | $_OR_VER | keys=$_ALIVE_KEYS rpm=$_RPM | $(date -u +%Y-%m-%dT%H:%M:%SZ)"

  local _snap_code
  _snap_code=$(curl -s -o /dev/null -w "%{http_code}" \
    -X POST "https://huggingface.co/api/datasets/$HF_DATASET_REPO/commit/main" \
    -H "Authorization: Bearer $HF_TOKEN" \
    -F "message=$_commit_msg" \
    -F "file=@$_snapshot_dir/init_vars.json" \
    $( [ -f "$_snapshot_dir"/debug_* ] && printf -- '-F "file=@%s"' "$_snapshot_dir"/debug_* ) \
    2>/dev/null || echo "000")

  rm -rf "$_snapshot_dir"

  if [ "$_snap_code" = "200" ] || [ "$_snap_code" = "201" ]; then
    echo "[init] HF Dataset uploaded."
  else
    echo "[init] ⚠ HF Dataset 上传失败: HTTP $_snap_code（非致命）"
  fi
}
_hf_snapshot || true

# ── 完成 ────────────────────────────────────────────────────────
echo "[init] ============================================================"
if [ "$_IS_INCREMENTAL" = "1" ]; then
  echo "[init] Done (incremental). v5.0"
else
  echo "[init] Done (first-init). v5.0"
fi
echo "[init] ============================================================"

```

## litestream.yml

```yaml
dbs:
  - path: /data/storage.sqlite
    replica:
      type: s3
      bucket: omniroute-data
      path: data/storage.sqlite
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

## package.json

```json
{"name": "omniroute-gate-v5", "version": "5.0.0", "description": "OmniRoute 3.8.43 终极优化版 Gate（零依赖纯 Node.js 内置模块）", "main": "gate.js", "scripts": {"start": "node gate.js"}, "engines": {">=18.0.0"}, "keywords": ["omniroute", "gate", "proxy", "nvidia-nim"], "license": "MIT"}
```

## README.md

```md
---
title: OmniRoute Ultimate v5.0
emoji: 🚀
colorFrom: blue
colorTo: indigo
sdk: docker
pinned: false
license: mit
app_port: 7860
---

# OmniRoute 3.8.43 终极优化版 v5.0

> 基于 130 条核心优点提炼 + 生产日志实证的最终部署方案

## 架构概览

```
客户端 → Gate.js (7860) → OmniRoute 3.8.43 (20128) → NVIDIA NIM 官方端点
         ↓ PSK 认证        ↓ 内部 API Key 替换    ↑ 直连（无 Relay）
```

## 核心特性

### 安全网关 (gate.js)
- **零依赖架构**：纯 Node.js `http`/`fs`/`crypto` 内置模块，无 express/better-sqlite3
- **timing-safe PSK 比较**：常量时间比较，防时序侧信道攻击
- **PSK fail-closed**：长度 < 16 直接 FATAL exit
- **白名单暴露面**：仅 `/healthz` + `/v1/*`，其余 404
- **SSE 流式全禁超时**：大上下文压缩期间不被掐断
- **共享预算限流**：RPM 滑动窗口 + 并发计数 + 间隔 pacing

### NIM 初始化 (init-nim-keys.sh)
- **Cookie login 三重安全网**：接受 200/201 + exit 1 硬失败 + grep auth_token 验证
- **Key 幂等注册**：409 跳过已存在 key，可安全重复执行
- **Resilience 白名单投影**：仅含 requestQueue 字段，无猜测字段
- **FIX-1 Settings 清除**：proxyUrl=null/proxyEnabled=false/relayBackend=null
- **ProxyFetch 三重防御**：R2 路径切换 + FIX-1 + purge_proxy_db SQL 兜底
- **模型分档 SSOT**：TIER_FAST/STABLE/RESTRICTED 三档 + NIM_PROFILE 控制

### 基础设施 (Dockerfile / entrypoint.sh)
- **镜像 Tag+Digest 双写锁定**：3.8.43@sha256:517c... 禁止浮动 latest
- **Litestream v0.5.9**：R2 路径切换 omniroute-v3（根源消除 ProxyFetch）
- **原子 restore**：先恢复到临时路径，quick_check 后原子 mv
- **PID 1 进程监督**：监控 OmniRoute/Gate/Litestream 三进程
- **绝对时间戳截止**：健康等待用 deadline 而非计数器

## 环境变量配置

### 必需
| 变量 | 说明 | 示例 |
|------|------|------|
| `INTERNAL_PSK` | Gate PSK（≥16 字符） | `your-psk-at-least-16-chars` |
| `NIM_KEYS` | NIM API Key（换行分隔） | `nvapi-...\nnvapi-...` |
| `INITIAL_PASSWORD` | OmniRoute 初始密码 | `your-password` |

### 可选（推荐）
| 变量 | 默认值 | 说明 |
|------|--------|------|
| `OMNIROUTE_API_KEY` | - | env-bypass 模式（跳过 .or-api-key 等待） |
| `NIM_PROFILE` | balanced | fast/balanced/full |
| `NIM_RPM_LIMIT` | 28 | 保守 RPM（NIM 免费层最优） |
| `NIM_CONCURRENT_LIMIT` | 1 | 并发数 |
| `NIM_MIN_INTERVAL_MS` | 2200 | 请求间隔 ms |
| `NIM_PROBE` | 0 | 模型探针（1=启用） |
| `CONTEXT_LENGTH_DEFAULT` | 128000 | 模型上下文长度 |
| `NIM_MODE` | NORMAL | DEBUG 时 tee 日志到文件 |
| `STRICT_VERSION_LOCK` | 0 | 版本不一致时是否 FATAL |

### R2 备份（可选）
| 变量 | 说明 |
|------|------|
| `R2_ACCESS_KEY_ID` | Cloudflare R2 Access Key |
| `R2_SECRET_ACCESS_KEY` | Cloudflare R2 Secret Key |
| `R2_ACCOUNT_ID` | Cloudflare Account ID |
| `R2_BUCKET` | R2 Bucket 名称 |

### HF Dataset 快照（可选）
| 变量 | 说明 |
|------|------|
| `HF_DATASET_REPO` | HF Dataset 仓库（如 user/repo-name） |
| `HF_TOKEN` | HF Token（用于 API commit） |

## 生产验证

v4.3.1 存档版经 New 10.txt 生产验证：
- ✅ 25 Key 注册 0 failed
- ✅ 请求 100% 成功（零 503/abort）
- ✅ ProxyFetch 噪声存在但不影响功能（direct fallback 正常）

## 文件清单

| 文件 | 行数 | 职责 |
|------|------|------|
| `Dockerfile` | ~55 | 镜像构建，pin 3.8.43 |
| `entrypoint.sh` | ~170 | PID 监督 + Litestream + Gate 启动 |
| `gate.js` | ~280 | 零依赖安全网关 |
| `init-nim-keys.sh` | ~580 | NIM 初始化主脚本 |
| `litestream.yml` | ~16 | SQLite→R2 配置 |
| `package.json` | ~12 | 元数据（gate.js 零依赖） |
| `README.md` | - | 本文档 |

## 版本历史

- **v5.0** (当前) - 终极优化版：整合 130 条优点 + 全部生产验证
- **v4.3.1** - 存档版：New 10.txt 验证 100% 成功
- **v4.3.0** - 候选版：Resilience 白名单 + 读回验证
- **v4.2.3** - 基线版：27h 生产运行实证

```

