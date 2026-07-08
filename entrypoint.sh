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

# ── 新增：Litestream restore（在 OmniRoute 启动前恢复数据库）──
if [ -n "$R2_ACCESS_KEY_ID" ] && [ -n "$R2_SECRET_ACCESS_KEY" ] && [ -n "$R2_ACCOUNT_ID" ]; then
  echo "[entrypoint] R2 credentials found. Attempting Litestream restore..."
  litestream restore \
    -config /litestream.yml \
    -if-replica-exists \
    "$DATA_DIR/storage.sqlite" && \
    echo "[entrypoint] Litestream restore complete." || \
    echo "[entrypoint] WARN: Litestream restore failed or no replica found. Continuing."
else
  echo "[entrypoint] WARN: R2 credentials not set. Skipping Litestream restore."
fi
# ──────────────────────────────────────────────────────────────

# ── 修正后的启动段 ──
PORT="$OMNIROUTE_PORT" \
DATA_DIR="$DATA_DIR" \
REQUIRE_API_KEY=true \
HOSTNAME=127.0.0.1 \
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
# ──────────────────

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

# ── 基础镜像版本护栏：打印实际版本并与期望比对（只告警，不中断）──
EXPECTED_OR_VERSION="${EXPECTED_OR_VERSION:-3.8.43}"
_OR_VER=$(curl -sf "http://127.0.0.1:$OMNIROUTE_PORT/api/monitoring/health" 2>/dev/null \
  | jq -r '.version // "unknown"' 2>/dev/null || echo "unknown")
echo "[entrypoint] OmniRoute base image version: $_OR_VER (expected $EXPECTED_OR_VERSION)"
if [ "$_OR_VER" != "$EXPECTED_OR_VERSION" ] && [ "$_OR_VER" != "unknown" ]; then
  echo "[entrypoint] ⚠️ WARN: base 版本($_OR_VER)与期望($EXPECTED_OR_VERSION)不一致——"
  echo "[entrypoint] ⚠️ 可能是 FROM 漂移。若卡在 starting，优先检查 Dockerfile 的 FROM 是否被 latest 冲走。"
fi
# ──────────────────────────────────────────────────────────────

echo "[entrypoint] running NIM key init script in background..."
# init 内部 env 守卫（见 init-nim-keys.sh）：env 模式跳过 /api/keys 创建，
# 仍写 .or-api-key 镜像作诊断/兼容；gate env 优先，不读该文件。
bash /entrypoint-init-nim.sh &

if [ -n "$OMNIROUTE_API_KEY" ]; then
  echo "[entrypoint] OMNIROUTE_API_KEY env set, env-bypass 模式，跳过等待 .or-api-key。"
else
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
fi

export NODE_OPTIONS="--max-old-space-size=4096"
# ── 新增：Litestream replicate（后台旁路，持续复制 WAL 到 R2）──
if [ -n "$R2_ACCESS_KEY_ID" ] && [ -n "$R2_SECRET_ACCESS_KEY" ] && [ -n "$R2_ACCOUNT_ID" ]; then
  echo "[entrypoint] Starting Litestream replication in background..."
  litestream replicate -config /litestream.yml &
  LS_PID=$!
  echo "[entrypoint] Litestream PID=$LS_PID"
else
  echo "[entrypoint] WARN: Litestream replication disabled (no R2 credentials)."
fi
# ──────────────────────────────────────────────────────────────

echo "[entrypoint] starting gate on port $EXPOSED_PORT..."
exec node /gate/gate.js
