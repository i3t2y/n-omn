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
