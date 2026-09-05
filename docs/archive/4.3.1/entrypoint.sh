# === ARCHIVED entrypoint.sh ===
# 来源版本: 4.3.1 中间 version
# 生成日期: 2026-07-15 (mtime)
# 状态: DEPRECATED — 永久禁止作为任何新生成的起点, 仅作指纹比对素材
# === END META ===

#!/bin/sh
set -e

DB="/data/storage.sqlite"
LOCK_FILE="/data/.entrypoint.lock"

_shutdown() {
  echo "[entrypoint] shutting down..."
  kill -TERM "$OR_PID" "$LS_PID" "$GATE_PID" 2>/dev/null || true
  exit 0
}
trap '_shutdown' TERM INT

exec 9>"$LOCK_FILE"
flock -n 9 || { echo "[entrypoint] FATAL: another instance running"; exit 1; }

# ── R2 配置完整性校验 (修复 bucket required 报错) ──
R2_READY=0
if [ -n "$R2_ACCOUNT_ID" ] && [ -n "$R2_BUCKET" ] \
   && [ -n "$R2_ACCESS_KEY_ID" ] && [ -n "$R2_SECRET_ACCESS_KEY" ]; then
  R2_READY=1
else
  echo "[entrypoint] WARN: R2 config incomplete -> running in LOCAL-ONLY mode (no backup/restore)."
fi

# ── R2 恢复 (仅在配置齐全且本地无库时) ──
if [ "$R2_READY" = 1 ] && [ ! -s "$DB" ]; then
  echo "[entrypoint] restoring from R2..."
  litestream restore -config /litestream.yml -if-replica-exists "$DB" || true
fi

# ═══════════════════════════════════════════════════════════════
# 【核心修复·已验证有效】启动前禁用代理生态 (根治 20129)
# ═══════════════════════════════════════════════════════════════
export ENABLE_SOCKS5_PROXY=false
export ONEPROXY_ENABLED=false
export NEXT_PUBLIC_ENABLE_SOCKS5_PROXY=false
unset OMNIROUTE_RELAY_BACKEND BIFROST_BASE_URL HTTP_PROXY HTTPS_PROXY ALL_PROXY 2>/dev/null || true

if [ -f "$DB" ]; then
  echo "[entrypoint] pre-purging proxy settings from DB..."
  sqlite3 "$DB" "UPDATE settings SET value='false' WHERE key='proxyEnabled';" 2>/dev/null || true
  sqlite3 "$DB" "UPDATE provider_connections SET proxy_enabled=0;" 2>/dev/null || true
  sqlite3 "$DB" "DELETE FROM proxy_registry;" 2>/dev/null || true
  sqlite3 "$DB" "PRAGMA wal_checkpoint(TRUNCATE);" 2>/dev/null || true
fi
# ═══════════════════════════════════════════════════════════════

# ── R2 复制 (仅在配置齐全时) ──
[ "$R2_READY" = 1 ] && { litestream replicate -config /litestream.yml & LS_PID=$!; }

echo "[entrypoint] starting OmniRoute..."
PORT="${OMNIROUTE_PORT:-20128}" DATA_DIR="/data" REQUIRE_API_KEY=true \
INITIAL_PASSWORD="$INITIAL_PASSWORD" NODE_OPTIONS="--max-old-space-size=3072" \
DISABLE_SQLITE_AUTO_BACKUP=true PROVIDER_LIMITS_SYNC_INTERVAL_MINUTES=1440 \
node /app/server.js --log &
OR_PID=$!

# ── 等待就绪 (拉长至 120s，日志实测冷启动含 109 迁移较慢) ──
i=0
while [ "$i" -lt 120 ]; do
  kill -0 "$OR_PID" 2>/dev/null || { echo "[entrypoint] FATAL: OR exited early"; _shutdown; }
  curl -sf "http://127.0.0.1:${OMNIROUTE_PORT:-20128}/api/monitoring/health" >/dev/null && break
  sleep 2; i=$((i+2))
done
echo "[entrypoint] OmniRoute ready (waited ${i}s)."

# ── NIM 注册 (现在会真正写入 connections) ──
bash /entrypoint-init-nim.sh &

node /gate/gate.js &
GATE_PID=$!

while sleep 5; do
  kill -0 "$OR_PID" "$GATE_PID" 2>/dev/null || _shutdown
done