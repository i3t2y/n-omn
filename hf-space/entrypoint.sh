#!/bin/sh
set -e

echo "[entrypoint] starting OmniRoute via /app/server.js..."

PORT=20128 \
DATA_DIR=/data \
REQUIRE_API_KEY=false \
HOSTNAME=127.0.0.1 \
NODE_OPTIONS="--max-old-space-size=1024" \
DISABLE_SQLITE_AUTO_BACKUP=true \
PROVIDER_LIMITS_SYNC_INTERVAL_MINUTES=1440 \
node /app/server.js &

OR_PID=$!
echo "[entrypoint] OmniRoute PID=$OR_PID"

echo "[entrypoint] waiting for OmniRoute (max 180s)..."
i=0
while [ $i -lt 180 ]; do
  if curl -sf "http://127.0.0.1:20128/api/monitoring/health" >/dev/null 2>&1; then
    echo "[entrypoint] OmniRoute ready after ${i}s"
    break
  fi
  sleep 2
  i=$((i + 2))
done

echo "[entrypoint] running NIM key init script..."
bash /entrypoint-init-nim.sh &

echo "[entrypoint] starting gate on port 7860..."
exec node /gate/gate.js
