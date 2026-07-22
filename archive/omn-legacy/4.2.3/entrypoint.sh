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