#!/bin/sh
set -e

if [ -z "$OMNIROUTE_PORT" ]; then
  OMNIROUTE_PORT=20128
fi

if [ -z "$EXPOSED_PORT" ]; then
  EXPOSED_PORT=7860
fi

if [ -z "$DATA_DIR" ]; then
  DATA_DIR=/data
fi

if [ -z "$CALL_LOGS_TABLE_MAX_ROWS" ]; then
  CALL_LOGS_TABLE_MAX_ROWS=100000
fi

if [ -z "$PROXY_LOGS_TABLE_MAX_ROWS" ]; then
  PROXY_LOGS_TABLE_MAX_ROWS=100000
fi

echo "[entrypoint] starting OmniRoute via /app/server.js..."
echo "[entrypoint] OMNIROUTE_PORT=$OMNIROUTE_PORT"
echo "[entrypoint] EXPOSED_PORT=$EXPOSED_PORT"
echo "[entrypoint] DATA_DIR=$DATA_DIR"

PORT="$OMNIROUTE_PORT" \
DATA_DIR="$DATA_DIR" \
REQUIRE_API_KEY=true \
HOSTNAME=127.0.0.1 \
NODE_OPTIONS="--max-old-space-size=1024" \
DISABLE_SQLITE_AUTO_BACKUP=true \
PROVIDER_LIMITS_SYNC_INTERVAL_MINUTES=1440 \
CALL_LOGS_TABLE_MAX_ROWS="$CALL_LOGS_TABLE_MAX_ROWS" \
PROXY_LOGS_TABLE_MAX_ROWS="$PROXY_LOGS_TABLE_MAX_ROWS" \
JWT_SECRET="$JWT_SECRET" \
API_KEY_SECRET="$API_KEY_SECRET" \
INITIAL_PASSWORD="$INITIAL_PASSWORD" \
node /app/server.js &

OR_PID=$!
echo "[entrypoint] OmniRoute PID=$OR_PID"

echo "[entrypoint] waiting for OmniRoute health check (max 180s)..."
i=0
while [ "$i" -lt 180 ]; do
  if ! kill -0 "$OR_PID" 2>/dev/null; then
    echo "[entrypoint] FATAL: OmniRoute exited before becoming ready"
    exit 1
  fi

  if curl -sf "http://127.0.0.1:$OMNIROUTE_PORT/api/monitoring/health" >/dev/null 2>&1; then
    echo "[entrypoint] OmniRoute ready after ${i}s"
    break
  fi

  sleep 2
  i=$((i + 2))
done

if [ "$i" -ge 180 ]; then
  echo "[entrypoint] FATAL: OmniRoute did not become ready within timeout"
  exit 1
fi

echo "[entrypoint] running NIM key init script in background..."
bash /entrypoint-init-nim.sh &

echo "[entrypoint] waiting for OR_API_KEY to be written (max 120s)..."
j=0
while [ "$j" -lt 120 ]; do
  if [ -f "/data/.or-api-key" ] && [ -s "/data/.or-api-key" ]; then
    echo "[entrypoint] OR_API_KEY ready"
    break
  fi

  if ! kill -0 "$OR_PID" 2>/dev/null; then
    echo "[entrypoint] FATAL: OmniRoute exited while waiting for OR_API_KEY"
    exit 1
  fi

  sleep 2
  j=$((j + 2))
done

if [ ! -f "/data/.or-api-key" ] || [ ! -s "/data/.or-api-key" ]; then
  echo "[entrypoint] FATAL: OR_API_KEY not created within timeout"
  exit 1
fi

echo "[entrypoint] starting gate on port $EXPOSED_PORT..."
exec node /gate/gate.js
