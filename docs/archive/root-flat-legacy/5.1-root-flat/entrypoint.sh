#!/bin/sh
# ── OmniRoute v5.1 · 容器入口点 ──────────────────────────────
set -e

[ -z "$OMNIROUTE_PORT" ]  && OMNIROUTE_PORT=20128
[ -z "$EXPOSED_PORT" ]    && EXPOSED_PORT=7860
[ -z "$DATA_DIR" ]        && DATA_DIR=/data
[ -z "$CALL_LOGS_TABLE_MAX_ROWS" ]  && CALL_LOGS_TABLE_MAX_ROWS=100000
[ -z "$PROXY_LOGS_TABLE_MAX_ROWS" ] && PROXY_LOGS_TABLE_MAX_ROWS=100000

log() { printf '[entrypoint] %s\n' "$1"; }

log "=============================================================="
log "OmniRoute v5.1 · PORT=$OMNIROUTE_PORT EXPOSED=$EXPOSED_PORT DATA=$DATA_DIR"
log "=============================================================="

# ── §1 Litestream restore(-o 临时目标 + 配置内 db path 作为标识)──
DB_PATH="$DATA_DIR/storage.sqlite"
DB_TMP="$DATA_DIR/storage.sqlite.restore.tmp"
rm -f "$DB_TMP"

if [ -f "$DB_PATH" ] && [ -s "$DB_PATH" ]; then
  log "✓ 本地 DB 已存在且非空($(wc -c < "$DB_PATH") bytes),跳过 restore(红线:绝不覆盖有效本地库)"
elif [ -n "$R2_ACCESS_KEY_ID" ] && [ -n "$R2_SECRET_ACCESS_KEY" ] && [ -n "$R2_ACCOUNT_ID" ]; then
  log "R2 凭据已配置,执行原子 restore..."
  if litestream restore -config /litestream.yml -if-replica-exists -o "$DB_TMP" "$DB_PATH" 2>/dev/null && [ -s "$DB_TMP" ]; then
    if sqlite3 "$DB_TMP" "PRAGMA quick_check;" >/dev/null 2>&1; then
      mv -f "$DB_TMP" "$DB_PATH"
      log "✓ 原子 restore 成功(quick_check 通过)"
    else
      log "✗ quick_check 失败,丢弃损坏恢复数据,空库启动"
      rm -f "$DB_TMP"
    fi
  else
    log "⚠ restore 失败或无副本,空库启动继续"
    rm -f "$DB_TMP"
  fi
else
  log "⚠ R2 凭据未配置,LOCAL-ONLY 模式"
fi

# ── §2 启动 OmniRoute ──
log "启动 OmniRoute..."
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
log "OmniRoute PID=$OR_PID"

# ── §3 健康等待(绝对时间戳截止,防 cgroup throttle)──
HEALTH_TIMEOUT=${HEALTH_TIMEOUT:-180}
deadline=$(( $(date +%s) + HEALTH_TIMEOUT ))
log "等待健康就绪(最大 ${HEALTH_TIMEOUT}s)..."
while [ "$(date +%s)" -lt "$deadline" ]; do
  kill -0 "$OR_PID" 2>/dev/null || { log "✗ FATAL: OmniRoute 提前退出"; exit 1; }
  # 源码确认的健康端点:/api/monitoring/health
  if curl -sf "http://127.0.0.1:$OMNIROUTE_PORT/api/monitoring/health" >/dev/null 2>&1; then
    log "✓ 就绪($(( $(date +%s) - deadline + HEALTH_TIMEOUT ))s)"; break
  fi
  sleep 2
done
[ "$(date +%s)" -ge "$deadline" ] && { log "✗ FATAL: ${HEALTH_TIMEOUT}s 内未就绪"; exit 1; }

# ── §4 版本护栏 ──
EXPECTED_OR_VERSION="${EXPECTED_OR_VERSION:-3.8.43}"
_OR_VER=$(curl -sf "http://127.0.0.1:$OMNIROUTE_PORT/api/monitoring/health" 2>/dev/null | jq -r '.version // "unknown"' 2>/dev/null || echo "unknown")
log "版本: $_OR_VER (期望 $EXPECTED_OR_VERSION)"
if [ "$_OR_VER" != "$EXPECTED_OR_VERSION" ] && [ "$_OR_VER" != "unknown" ] && [ "${STRICT_VERSION_LOCK:-0}" = "1" ]; then
  log "✗ STRICT_VERSION_LOCK=1 且版本不一致,终止"; exit 1
fi

# ── §5 NIM 初始化(后台)──
log "启动 NIM 初始化(后台)..."
bash /entrypoint-init-nim.sh &
INIT_PID=$!

# ── §6 Litestream replicate ──
if [ -n "$R2_ACCESS_KEY_ID" ] && [ -n "$R2_SECRET_ACCESS_KEY" ] && [ -n "$R2_ACCOUNT_ID" ]; then
  litestream replicate -config /litestream.yml & LT_PID=$!
  log "Litestream PID=$LT_PID"
else
  LT_PID=""
fi

# ── §7 进程监督 + 信号转发 ──
shutdown() {
  log "收到终止信号,关闭子进程..."
  kill -TERM "$OR_PID" "$INIT_PID" 2>/dev/null || true
  [ -n "$LT_PID" ] && kill -TERM "$LT_PID" 2>/dev/null || true
  sleep 3
  kill -KILL "$OR_PID" "$INIT_PID" 2>/dev/null || true
  [ -n "$LT_PID" ] && kill -KILL "$LT_PID" 2>/dev/null || true
}
trap shutdown INT TERM EXIT

(
  while true; do
    kill -0 "$OR_PID" 2>/dev/null || { log "✗ OmniRoute 退出,容器终止"; exit 1; }
    if [ -n "$LT_PID" ] && ! kill -0 "$LT_PID" 2>/dev/null; then
      [ "${LITESTREAM_REQUIRED:-0}" = "1" ] && { log "✗ Litestream 退出且必需,终止"; exit 1; }
      log "⚠ Litestream 退出(非必需)"; LT_PID=""
    fi
    sleep 10
  done
) &

log "启动 Gate on port $EXPOSED_PORT(前台 PID 1)..."
exec node /gate/gate.js
