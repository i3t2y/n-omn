#!/bin/sh
# entrypoint.sh — v4.3 candidate (Stage D)
# OmniRoute + LiteStream + NIM init + gate.js 编排
#
# 红线 3 (LiteStream): restore 前判本地文件存在且非空则跳过; 临时路径原子; 不可覆盖有效 DB.
# 进程监督: trap SIGTERM/SIGINT 转发, 子进程 PID 保存, wait 回收, 任一关键进程退出停其余, 无孤儿.
# POSIX sh: 无 bash 数组/`mapfile`/`[[`.
# 复制非致命 vs 严格: LITESTREAM_STRICT=1 时 restore 复制失败 safe-fail exit; 0 时 warn 继续.

set -e

[ -z "$OMNIROUTE_PORT" ] && OMNIROUTE_PORT=20128
[ -z "$EXPOSED_PORT" ] && EXPOSED_PORT=7860
[ -z "$DATA_DIR" ] && DATA_DIR=/data
[ -z "$CALL_LOGS_TABLE_MAX_ROWS" ] && CALL_LOGS_TABLE_MAX_ROWS=100000
[ -z "$PROXY_LOGS_TABLE_MAX_ROWS" ] && PROXY_LOGS_TABLE_MAX_ROWS=100000
# 复制失败模式开关: 严格(exit) 或 非致命(warn+continue). 默认严格 (红线3 safe-fail).
[ -z "$LITESTREAM_STRICT" ] && LITESTREAM_STRICT=1

DB="$DATA_DIR/storage.sqlite"
DB_TMP="$DATA_DIR/.storage.sqlite.restore.$$"   # 临时恢复路径 (原子保护)

# 子进程 PID 全局 (POSIX sh 用变量, 不用数组)
OR_PID=""
INIT_PID=""
LS_PID=""      # litestream replicate PID
GATE_PID=""

cleanup_done=0
# trap 转发: 向仍存活子进程发 SIGTERM, 短 grace 后 SIGKILL, wait 回收
_forward_signal() {
  sig="$1"
  for pid in "$OR_PID" "$INIT_PID" "$LS_PID" "$GATE_PID"; do
    [ -z "$pid" ] && continue
    kill -0 "$pid" 2>/dev/null && kill -"$sig" "$pid" 2>/dev/null || true
  done
}
_shutdown() {
  [ "$cleanup_done" = 1 ] && return
  cleanup_done=1
  echo "[entrypoint] shutdown: forwarding SIGTERM to children..."
  _forward_signal TERM
  # grace 短等
  g=0
  while [ "$g" -lt 50 ]; do
    alive=0
    for pid in "$OR_PID" "$INIT_PID" "$LS_PID" "$GATE_PID"; do
      [ -z "$pid" ] && continue
      kill -0 "$pid" 2>/dev/null && alive=1
    done
    [ "$alive" = 0 ] && break
    sleep 0.1 2>/dev/null || sleep 1
    g=$((g + 1))
  done
  # 残留 SIGKILL (无孤儿)
  echo "[entrypoint] shutdown: force-kill残留..."
  _forward_signal KILL
  # wait 回收
  for pid in "$OR_PID" "$INIT_PID" "$LS_PID" "$GATE_PID"; do
    [ -z "$pid" ] && continue
    wait "$pid" 2>/dev/null || true
  done
  echo "[entrypoint] shutdown complete."
  exit 0
}
trap '_shutdown' TERM
trap '_shutdown' INT

echo "[entrypoint] starting OmniRoute via /app/server.js..."
echo "[entrypoint] OMNIROUTE_PORT=$OMNIROUTE_PORT EXPOSED_PORT=$EXPOSED_PORT DATA_DIR=$DATA_DIR STRICT=$LITESTREAM_STRICT"

# ── Litestream restore (启动前恢复 DB; 红线3) ──────────────
# Condition A: R2 凭据缺失 → 明确降级, 不打印凭据, skip restore.
if [ -z "$R2_ACCESS_KEY_ID" ] || [ -z "$R2_SECRET_ACCESS_KEY" ] || [ -z "$R2_ACCOUNT_ID" ]; then
  echo "[entrypoint] WARN: R2 creds not set. Skip restore (复制非致命: LITESTREAM_STRICT=$LITESTREAM_STRICT)."
else
  # Condition B: 本地 DB 已存在且非空 → 跳过 restore (绝不覆盖有效 DB)
  if [ -f "$DB" ] && [ -s "$DB" ]; then
    echo "[entrypoint] 本地 DB 已存在且非空 ($DB), 跳过 restore (红线3: 不覆盖)."
  else
    echo "[entrypoint] R2 creds found + 本地 DB 空或不存在. Litestream restore (临时路径)..."
    # restore 到临时路径, 不直接覆盖 (原子保护)
    rm -f "$DB_TMP"
    if litestream restore -config /litestream.yml -if-replica-exists "$DB_TMP" 2>/tmp/ls_restore.err; then
      # restore 命令返回 0 ≠ 恢复成功: 验文件存在+非空+quick_check
      if [ ! -f "$DB_TMP" ] || [ ! -s "$DB_TMP" ]; then
        echo "[entrypoint] WARN: restore 返回 0 但临时文件无效. 丢弃, 保留原(空)."
        rm -f "$DB_TMP" "$DB_TMP-wal" "$DB_TMP-shm" 2>/dev/null || true
        if [ "$LITESTREAM_STRICT" = 1 ]; then
          echo "[entrypoint] FATAL: restore 无效 (strict). exit." >&2; exit 1
        fi
      else
        # quick_check (工具可用时)
        qc_ok=0
        if command -v sqlite3 >/dev/null 2>&1; then
          if sqlite3 "$DB_TMP" "PRAGMA quick_check;" 2>/dev/null | grep -q "^ok$"; then
            qc_ok=1
          else
            echo "[entrypoint] WARN: PRAGMA quick_check 失败. 丢弃临时, 保留原(空)."
            rm -f "$DB_TMP" "$DB_TMP-wal" "$DB_TMP-shm" 2>/dev/null || true
            if [ "$LITESTREAM_STRICT" = 1 ]; then
              echo "[entrypoint] FATAL: quick_check fail (strict). exit." >&2; exit 1
            fi
          fi
        else
          echo "[entrypoint] (sqlite3 不可用, 跳过 quick_check; 已验文件非空.)"
          qc_ok=1
        fi
        if [ "$qc_ok" = 1 ]; then
          mv "$DB_TMP" "$DB" && echo "[entrypoint] restore complete (原子 mv)."
        fi
      fi
    else
      echo "[entrypoint] WARN: restore 命令失败 (见 /tmp/ls_restore.err, 已脱敏: 不打印凭据)."
      rm -f "$DB_TMP" "$DB_TMP-wal" "$DB_TMP-shm" 2>/dev/null || true
      if [ "$LITESTREAM_STRICT" = 1 ]; then
        echo "[entrypoint] FATAL: restore fail (strict). exit." >&2; exit 1
      fi
    fi
  fi
fi

# ── FIX #5: pre-purge SQLite 20129 relay 条目 (OmniRoute 启动前, B6 root cause) ──
# B6 源码实证 (L2): runtime patchedFetch (proxyFetch.ts:637) 用内存 account.proxy
# (pool load 时一次性从 SQLite proxy_registry 读取, proxies.ts:806), 不查
# provider_connections.proxy_enabled, 无 reload 钩子. init L747 purge_proxy_db 在
# OmniRoute 启动后执行 → pool 已加载历史 20129 条目 → purge 改 SQLite 不刷新内存
# → 27h ProxyFetch ECONNREFUSED 127.0.0.1:20129 持续 (3222.txt L204-4523 + 3231321.txt 跨重启复现).
# 本段在 OmniRoute 启动 *前* SQL-only 清 20129 条目 + 关 nvidia proxy_enabled →
# pool load 时 SQLite 已无 20129 → account.proxy 空 → patchedFetch direct 路径.
# SQL-only: 此时 OmniRoute 未启, 走 API 路径不可能; SQL DELETE 直读 SQLite 文件即可.
# 默认 20129 与 init L176 一致 (供历史条目 host:port 锚定); 不依赖 init 写 relay (init 无 INSERT).
[ "$_PURGE_PROXY" != "0" ] && _PURGE_PROXY=1   # 承接 init purge 意图; NIM_PURGE_PROXY=0 可关全段.
if [ -n "$DB" ] && [ -f "$DB" ] && [ -x "$(command -v sqlite3 2>/dev/null || true)" ] && [ "$_PURGE_PROXY" = "1" ]; then
  sql_e5(){ printf '%s' "$1" | sed "s/'/''/g"; }
  _P5=${NIM_PROXY_RELAY_PORT:-20129}; _H5=${NIM_PROXY_RELAY_HOST:-127.0.0.1}
  sqlite3 "$DB" "DELETE FROM proxy_assignments WHERE proxy_id IN (SELECT id FROM proxy_registry WHERE host='$(sql_e5 "$_H5")' AND port=$_P5);" 2>/dev/null || true
  sqlite3 "$DB" "UPDATE provider_connections SET proxy_enabled=0 WHERE provider='nvidia';" 2>/dev/null || true
  sqlite3 "$DB" "DELETE FROM proxy_registry WHERE host='$(sql_e5 "$_H5")' AND port=$_P5;" 2>/dev/null || true
  _reg5=$(sqlite3 "$DB" "SELECT COUNT(*) FROM proxy_registry WHERE host='$(sql_e5 "$_H5")' AND port=$_P5;" 2>/dev/null || echo "?")
  echo "[entrypoint] FIX #5 pre-purge: relay ${_H5}:${_P5} 条目残留=$_reg5 (0=已清; pool load 时 SQLite 已无幽灵 20129)."
else
  echo "[entrypoint] FIX #5 pre-purge: skip (DB 未就绪/sqlite3 缺/NIM_PURGE_PROXY=0)."
fi

# ── OmniRoute ─────────────────────────────────────────────
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
  kill -0 "$OR_PID" 2>/dev/null || { echo "[entrypoint] FATAL: OmniRoute exited early"; _shutdown; exit 1; }
  curl -sf --max-time 3 "http://127.0.0.1:$OMNIROUTE_PORT/api/monitoring/health" >/dev/null 2>&1 && { echo "[entrypoint] ready after ${i}s"; break; }
  sleep 2; i=$((i + 2))
done
[ "$i" -ge 180 ] && { echo "[entrypoint] FATAL: not ready within 180s"; _shutdown; exit 1; }

# ── 版本护栏 (只告警不中断) ──────────────────────────────
EXPECTED_OR_VERSION="${EXPECTED_OR_VERSION:-3.8.43}"
_OR_VER=$(curl -sf --max-time 3 "http://127.0.0.1:$OMNIROUTE_PORT/api/monitoring/health" 2>/dev/null | jq -r '.version // "unknown"' 2>/dev/null || echo "unknown")
echo "[entrypoint] base version: $_OR_VER (expected $EXPECTED_OR_VERSION)"
if [ "$_OR_VER" != "$EXPECTED_OR_VERSION" ] && [ "$_OR_VER" != "unknown" ]; then
  echo "[entrypoint] WARN: 版本($_OR_VER)与期望($EXPECTED_OR_VERSION)不一致——疑似 FROM 漂移。"
fi

# ── NIM init (后台) ───────────────────────────────────────
echo "[entrypoint] running NIM init in background..."
bash /entrypoint-init-nim.sh &
INIT_PID=$!
echo "[entrypoint] init PID=$INIT_PID"

# ── OR_API_KEY file 等待 ──────────────────────────────────
if [ -n "$OMNIROUTE_API_KEY" ]; then
  echo "[entrypoint] OMNIROUTE_API_KEY set, env-bypass 模式，跳过等待 .or-api-key。"
else
  echo "[entrypoint] waiting for OR_API_KEY (max 120s)..."
  j=0
  while [ "$j" -lt 120 ]; do
    [ -f "/data/.or-api-key" ] && [ -s "/data/.or-api-key" ] && { echo "[entrypoint] OR_API_KEY ready"; break; }
    kill -0 "$OR_PID" 2>/dev/null || { echo "[entrypoint] FATAL: OmniRoute exited waiting key"; _shutdown; exit 1; }
    sleep 2; j=$((j + 2))
  done
  [ ! -s "/data/.or-api-key" ] && { echo "[entrypoint] FATAL: OR_API_KEY not created"; _shutdown; exit 1; }
fi

# ── LiteStream replicate (后台, PID 保存) ─────────────────
export NODE_OPTIONS="--max-old-space-size=4096"
if [ -n "$R2_ACCESS_KEY_ID" ] && [ -n "$R2_SECRET_ACCESS_KEY" ] && [ -n "$R2_ACCOUNT_ID" ]; then
  echo "[entrypoint] Starting Litestream replication..."
  litestream replicate -config /litestream.yml &
  LS_PID=$!
  echo "[entrypoint] Litestream PID=$LS_PID"
else
  echo "[entrypoint] WARN: Litestream replication disabled (no R2 creds). LITESTREAM_STRICT=$LITESTREAM_STRICT."
fi

# ── 启动前: OmniRoute 健康二次确认 ────────────────────────
# 若 OmniRoute 已退出, 不启 gate (避免孤儿)
if ! kill -0 "$OR_PID" 2>/dev/null; then
  echo "[entrypoint] FATAL: OmniRoute died before gate. abort." >&2
  _shutdown; exit 1
fi

echo "[entrypoint] starting gate on port $EXPOSED_PORT..."
node /gate/gate.js &
GATE_PID=$!
echo "[entrypoint] gate PID=$GATE_PID"

# ── 监督循环: 任一关键进程退出 → 停其余 ──────────────────
# gate 为对外服务; OmniRoute 为必需; init 非致命 (告警). litestream 退出按 STRICT.
while true; do
  # gate 退出 (对外不服务) → 停一切
  if ! kill -0 "$GATE_PID" 2>/dev/null; then
    echo "[entrypoint] gate exited. 停止其余并退出."
    _shutdown; exit 1
  fi
  # OmniRoute 退出 → 停一切
  if ! kill -0 "$OR_PID" 2>/dev/null; then
    echo "[entrypoint] OmniRoute exited. 停止其余并退出."
    _shutdown; exit 1
  fi
  # init 退出 (非致命) → 仅日志
  if [ -n "$INIT_PID" ] && ! kill -0 "$INIT_PID" 2>/dev/null; then
    [ "$_init_logged" = 1 ] || { echo "[entrypoint] NIM init 已退出 (非致命)."; _init_logged=1; }
  fi
  # litestream 退出 → 按 STRICT (严格 exit, 非致命告警并标记 PID 空)
  if [ -n "$LS_PID" ] && ! kill -0 "$LS_PID" 2>/dev/null; then
    if [ "$LITESTREAM_STRICT" = 1 ]; then
      echo "[entrypoint] FATAL: Litestream replicate exited (strict). 停止."
      _shutdown; exit 1
    else
      echo "[entrypoint] WARN: Litestream replicate exited (非致命). DB 不再备份 (LITESTREAM_STRICT=0)."
      LS_PID=""
    fi
  fi
  sleep 1
done
