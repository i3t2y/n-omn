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
[ -z "$LITESTREAM_STRICT" ] && LITESTREAM_STRICT=1

DB="$DATA_DIR/storage.sqlite"
DB_TMP="$DATA_DIR/.storage.sqlite.restore.$$"

OR_PID=""
INIT_PID=""
LS_PID=""
GATE_PID=""

cleanup_done=0
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
  echo "[entrypoint] shutdown: force-kill残留..."
  _forward_signal KILL
  for pid in "$OR_PID" "$INIT_PID" "$LS_PID" "$GATE_PID"; do
    [ -z "$pid" ] && continue
    wait "$pid" 2>/dev/null || true
  done
  echo "[entrypoint] shutdown complete."
  exit 0
}
trap '_shutdown' TERM
trap '_shutdown' INT

echo "[entrypoint] cold-boot (restore→purge→replicate→OmniRoute, 严格时序)..."
echo "[entrypoint] OMNIROUTE_PORT=$OMNIROUTE_PORT EXPOSED_PORT=$EXPOSED_PORT DATA_DIR=$DATA_DIR STRICT=$LITESTREAM_STRICT"

# ── 文件锁: 防多容器同时 restore/purge/替换 $DB ───────────
# P3: LOCK_FILE 可配置; 目录不可写时 WARN 降级无锁继续.
# 修复: 将 fd 打开与 flock 合并为同一行 (兼容 busybox sh / dash / bash),
#       避免 "exec 9> 在子 shell 打开、父 shell flock" 导致 Bad file descriptor.
LOCK_FILE="${LOCK_FILE:-${DATA_DIR}/.entrypoint.lock}"
_lock_dir=$(dirname "$LOCK_FILE")
echo "[entrypoint] flock path=$LOCK_FILE"
if command -v flock >/dev/null 2>&1; then
  if [ -w "$_lock_dir" ]; then
    # 关键修复: flock -n 9 9>"$LOCK_FILE" 在同一行完成 fd 打开 + 加锁,
    # 不依赖 exec fd 继承, busybox/dash/bash 全兼容.
    if ! flock -n 9 9>"$LOCK_FILE"; then
      echo "[entrypoint] FATAL: 无法获取文件锁 $LOCK_FILE (另一容器占用?). abort." >&2
      exit 1
    fi
    echo "[entrypoint] lock acquired (flock $LOCK_FILE, fd 9)."
  else
    echo "[entrypoint] WARN: 锁目录不可写 LOCK_FILE=$LOCK_FILE dir=$_lock_dir → 降级无锁继续 (跨容器无互斥)." >&2
  fi
else
  echo "[entrypoint] WARN: flock 不可用, 跳过跨容器互斥 (HF Space 优先单实例)."
fi

# ── 1. Litestream restore (启动前; 红线3: 不覆盖有效 DB) ─
has_r2=0
[ -n "$R2_ACCESS_KEY_ID" ] && [ -n "$R2_SECRET_ACCESS_KEY" ] && [ -n "$R2_ACCOUNT_ID" ] && has_r2=1

if [ "$has_r2" = 0 ]; then
  echo "[entrypoint] R2 creds 缺失 → skip restore. 空库启动 (init 重建)."
elif [ -f "$DB" ] && [ -s "$DB" ]; then
  echo "[entrypoint] 本地 DB 非空 ($DB) → skip restore (红线3: 不覆盖有效 DB)."
else
  rm -f "$DB_TMP" "$DB_TMP-wal" "$DB_TMP-shm"
  printf '%s' "" > /tmp/ls_restore.err
  rc=0
  litestream restore -config /litestream.yml -if-replica-exists -o "$DB_TMP" "$DB" 2>/tmp/ls_restore.err || rc=$?
  used_tmp=1
  if echo "$(cat /tmp/ls_restore.err 2>/dev/null)" | grep -qiE 'unknown flag|invalid option|flag provided but not defined.*-o'; then
    echo "[entrypoint] litestream 0.5.9 不支持 -o → 回退直接 restore $DB."
    rm -f "$DB_TMP" "$DB_TMP-wal" "$DB_TMP-shm"
    printf '%s' "" > /tmp/ls_restore.err
    rc=0
    litestream restore -config /litestream.yml -if-replica-exists "$DB" 2>/tmp/ls_restore.err || rc=$?
    used_tmp=0
  fi

  if [ "$rc" -ne 0 ]; then
    echo "[entrypoint] WARN: restore rc=$rc."
    [ "$LITESTREAM_STRICT" = 1 ] && echo "[entrypoint]   STRICT=1: 仅告警, 不 exit (空库启动)."
    rm -f "$DB_TMP" "$DB_TMP-wal" "$DB_TMP-shm" 2>/dev/null || true
  elif [ "$used_tmp" = 1 ] && { [ ! -f "$DB_TMP" ] || [ ! -s "$DB_TMP" ]; }; then
    echo "[entrypoint] restore rc=0 但无文件 (R2 无副本或首次部署). 空库启动."
    rm -f "$DB_TMP" "$DB_TMP-wal" "$DB_TMP-shm" 2>/dev/null || true
  elif [ "$used_tmp" = 1 ]; then
    qc_ok=0
    if command -v sqlite3 >/dev/null 2>&1; then
      if sqlite3 "$DB_TMP" "PRAGMA quick_check;" 2>/dev/null | grep -q "^ok$"; then
        qc_ok=1
      else
        echo "[entrypoint] WARN: quick_check 失败. 丢弃临时 $DB_TMP, 空库启动."
        [ "$LITESTREAM_STRICT" = 1 ] && echo "[entrypoint]   STRICT=1: 仅告警, 不 exit."
        rm -f "$DB_TMP" "$DB_TMP-wal" "$DB_TMP-shm" 2>/dev/null || true
      fi
    else
      echo "[entrypoint] sqlite3 不可用, 跳过 quick_check."
      qc_ok=1
    fi
    if [ "$qc_ok" = 1 ]; then
      mv "$DB_TMP" "$DB" && echo "[entrypoint] restore complete (原子 mv $DB_TMP → $DB)."
    fi
  else
    if [ ! -f "$DB" ] || [ ! -s "$DB" ]; then
      echo "[entrypoint] restore rc=0 但 $DB 无文件 (R2 无副本). 空库启动."
    elif command -v sqlite3 >/dev/null 2>&1; then
      if sqlite3 "$DB" "PRAGMA quick_check;" 2>/dev/null | grep -q "^ok$"; then
        echo "[entrypoint] restore complete (直接 $DB, quick_check ok)."
      else
        echo "[entrypoint] WARN: quick_check 失败 on $DB. 空库启动."
        rm -f "$DB" "$DB-wal" "$DB-shm" 2>/dev/null || true
      fi
    else
      echo "[entrypoint] restore complete (直接 $DB, 文件非空)."
    fi
  fi
fi

# ── 2. FIX #5 pre-purge ──────────────────────────────────
[ "$_PURGE_PROXY" != "0" ] && _PURGE_PROXY=1
if [ -n "$DB" ] && [ -f "$DB" ] && [ -x "$(command -v sqlite3 2>/dev/null || true)" ] && [ "$_PURGE_PROXY" = "1" ]; then
  _P5=${NIM_PROXY_RELAY_PORT:-20129}
  _H5=${NIM_PROXY_RELAY_HOST:-127.0.0.1}
  _SQLITE3_BIN=$(command -v sqlite3 2>/dev/null || true)
  _SQLITE_RAN=0
  if [ -n "$_SQLITE3_BIN" ]; then
    _pre=$(sqlite3 "$DB" "SELECT COUNT(*) FROM proxy_registry WHERE host IN ('127.0.0.1','::1','localhost','0.0.0.0') AND port=$_P5;" 2>/dev/null || echo "?")
    echo "[entrypoint] FIX #5 pre-purge: relay ${_H5}:${_P5} purge 前=$_pre 条."
    purge_rc=0
    sqlite3 "$DB" <<SQL 2>/tmp/purge.err || purge_rc=$?
BEGIN;
DELETE FROM proxy_assignments WHERE proxy_id IN
  (SELECT id FROM proxy_registry WHERE host IN ('127.0.0.1','::1','localhost','0.0.0.0') AND port=$_P5);
UPDATE provider_connections SET proxy_enabled=0 WHERE provider='nvidia';
DELETE FROM proxy_registry WHERE host IN ('127.0.0.1','::1','localhost','0.0.0.0') AND port=$_P5;
COMMIT;
SQL
    if [ "$purge_rc" -ne 0 ]; then
      echo "[entrypoint] FATAL: pre-purge 事务失败 rc=$purge_rc. abort." >&2
      exit 1
    fi
    _purge_del=$(sqlite3 "$DB" "SELECT changes();" 2>/dev/null || echo "?")
    echo "[entrypoint] pre-purge deleted=${_purge_del} rows"
    _SQLITE_RAN=1
    _ckpt=$(sqlite3 "$DB" "PRAGMA wal_checkpoint(TRUNCATE);" 2>/dev/null | tr '|' '	' || echo "")
    _ck_busy=$(printf '%s' "$_ckpt" | cut -f1)
    _ck_log=$(printf '%s' "$_ckpt" | cut -f2)
    _ck_ckptd=$(printf '%s' "$_ckpt" | cut -f3)
    echo "[entrypoint] wal_checkpoint busy=${_ck_busy:-?} log=${_ck_log:-?} checkpointed=${_ck_ckptd:-?}"
    if [ -n "$_ck_busy" ] && [ "$_ck_busy" -gt 0 ] 2>/dev/null; then
      echo "[entrypoint] WARN: wal_checkpoint busy=${_ck_busy}, WAL not fully checkpointed." >&2
    fi
    rm -f "$DB-wal" "$DB-shm" 2>/dev/null || true
    _post=$(sqlite3 "$DB" "SELECT COUNT(*) FROM proxy_registry WHERE host IN ('127.0.0.1','::1','localhost','0.0.0.0') AND port=$_P5;" 2>/dev/null || echo "?")
    echo "[entrypoint] FIX #5 pre-purge: relay ${_H5}:${_P5} purge 后=$_post 条 (必须=0)."
    if [ "$_post" != "0" ]; then
      echo "[entrypoint] FATAL: pre-purge assert 失败 (残留=$_post !=0). 整个容器 exit." >&2
      exit 1
    fi
    echo "[entrypoint] ✓ pre-purge assert pass (残留=0)."
  else
    echo "[entrypoint] FIX #5 pre-purge: sqlite3 CLI 缺 → fallback node:sqlite."
    _P5_N="$_P5" _DB_N="$DB" _H5_N="$_H5" node -e '
const { DatabaseSync } = require("node:sqlite");
const dbPath = process.env._DB_N, port = Number(process.env._P5_N), host = process.env._H5_N;
const hosts = ["127.0.0.1","::1","localhost","0.0.0.0"];
const placeholders = "(" + hosts.map(()=>"?").join(",") + ")";
let db;
try { db = new DatabaseSync(dbPath); } catch (e) { console.error("[entrypoint] FATAL: node:sqlite 打开失败: " + e.message); process.exit(1); }
const pre = db.prepare("SELECT COUNT(*) AS c FROM proxy_registry WHERE host IN " + placeholders + " AND port=?").all(...hosts, port)[0].c;
console.log("[entrypoint] FIX #5 pre-purge: relay " + host + ":" + port + " purge 前=" + pre + " 条.");
try {
  db.exec("BEGIN");
  db.prepare("DELETE FROM proxy_assignments WHERE proxy_id IN (SELECT id FROM proxy_registry WHERE host IN " + placeholders + " AND port=?)").run(...hosts, port);
  db.prepare("UPDATE provider_connections SET proxy_enabled=0 WHERE provider=?").run("nvidia");
  const del = db.prepare("DELETE FROM proxy_registry WHERE host IN " + placeholders + " AND port=?").run(...hosts, port);
  db.exec("COMMIT");
  console.log("[entrypoint] pre-purge deleted=" + del.changes + " rows");
  try {
    const ck = db.prepare("PRAGMA wal_checkpoint(TRUNCATE)").get();
    const busy = String(ck && ck.busy != null ? ck.busy : "?");
    const log = String(ck && ck.log != null ? ck.log : "?");
    const ckptd = String(ck && ck.checkpointed != null ? ck.checkpointed : "?");
    console.log("[entrypoint] wal_checkpoint busy=" + busy + " log=" + log + " checkpointed=" + ckptd);
    if (!isNaN(Number(busy)) && Number(busy) > 0) {
      console.error("[entrypoint] WARN: wal_checkpoint busy=" + busy + ", WAL not fully checkpointed.");
    }
  } catch (e) { console.log("[entrypoint] wal_checkpoint busy=? log=? checkpointed=? (" + e.message + ")"); }
  const post = db.prepare("SELECT COUNT(*) AS c FROM proxy_registry WHERE host IN " + placeholders + " AND port=?").all(...hosts, port)[0].c;
  console.log("[entrypoint] FIX #5 pre-purge: relay " + host + ":" + port + " purge 后=" + post + " 条 (必须=0).");
  if (String(post) !== "0") { console.error("[entrypoint] FATAL: pre-purge assert 失败 (残留=" + post + "). 整个容器 exit."); db.close(); process.exit(1); }
  console.log("[entrypoint] ✓ pre-purge assert pass (残留=0).");
  db.close();
} catch (e) {
  console.error("[entrypoint] FATAL: pre-purge 事务失败 (" + e.message + "). abort.");
  try { db.exec("ROLLBACK"); } catch (_) {}
  db.close(); process.exit(1);
}
' || { echo "[entrypoint] FATAL: node:sqlite purge fallback 失败. abort." >&2; exit 1; }
    _SQLITE_RAN=1
  fi
else
  echo "[entrypoint] FIX #5 pre-purge: skip (DB 未就绪/sqlite3 缺/NIM_PURGE_PROXY=0)."
fi

# ── 3. LiteStream replicate ───────────────────────────────
export NODE_OPTIONS="--max-old-space-size=4096"
if [ "$has_r2" = 1 ]; then
  mkdir -p "$DATA_DIR" 2>/dev/null || true
  echo "[entrypoint] Starting Litestream replication..."
  printf '%s' "$DB" | grep -q "^${DATA_DIR}/storage.sqlite$" || {
    echo "[entrypoint] FATAL: \$DB=$DB 与 litestream.yml dbs[].path 不一致." >&2; exit 1; }
  litestream replicate -config /litestream.yml &
  LS_PID=$!
  sleep 1
  if ! kill -0 "$LS_PID" 2>/dev/null; then
    echo "[entrypoint] FATAL: Litestream replicate 退出过早. abort." >&2
    [ "$LITESTREAM_STRICT" = 1 ] && exit 1 || { LS_PID=""; echo "[entrypoint] STRICT=0: 降级无 replicate 继续."; }
  else
    echo "[entrypoint] Litestream PID=$LS_PID."
  fi
else
  echo "[entrypoint] WARN: LiteStream replication disabled (无 R2 creds)."
fi

# ── 4. OmniRoute ─────────────────────────────────────────
echo "[entrypoint] starting OmniRoute..."
PORT="$OMNIROUTE_PORT" \
DATA_DIR="$DATA_DIR" \
REQUIRE_API_KEY=true \
HOSTNAME=127.0.0.1 \
NIM_MODE="$NIM_MODE" \
DISABLE_SQLITE_AUTO_BACKUP=true \
PROVIDER_LIMITS_SYNC_INTERVAL_MINUTES=1440 \
CALL_LOGS_TABLE_MAX_ROWS="$CALL_LOGS_TABLE_MAX_ROWS" \
PROXY_LOGS_TABLE_MAX_ROWS="$PROXY_LOGS_TABLE_MAX_ROWS" \
JWT_SECRET="$JWT_SECRET" \
API_KEY_SECRET="$API_KEY_SECRET" \
OMNIROUTE_API_KEY="$OMNIROUTE_API_KEY" \
INITIAL_PASSWORD="$INITIAL_PASSWORD" \
NODE_OPTIONS="--max-old-space-size=4096" \
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

# ── 版本护栏 ─────────────────────────────────────────────
EXPECTED_OR_VERSION="${EXPECTED_OR_VERSION:-3.8.43}"
_OR_VER=$(curl -sf --max-time 3 "http://127.0.0.1:$OMNIROUTE_PORT/api/monitoring/health" 2>/dev/null | jq -r '.version // "unknown"' 2>/dev/null || echo "unknown")
echo "[entrypoint] base version: $_OR_VER (expected $EXPECTED_OR_VERSION)"
if [ "$_OR_VER" != "$EXPECTED_OR_VERSION" ] && [ "$_OR_VER" != "unknown" ]; then
  echo "[entrypoint] WARN: 版本($_OR_VER)与期望($EXPECTED_OR_VERSION)不一致——疑似 FROM 漂移。"
fi

# ── NIM init ─────────────────────────────────────────────
echo "[entrypoint] running NIM init in background..."
bash /entrypoint-init-nim.sh &
INIT_PID=$!
echo "[entrypoint] init PID=$INIT_PID"

# ── OR_API_KEY 等待 ───────────────────────────────────────
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

# ── 启动前二次确认 ────────────────────────────────────────
if ! kill -0 "$OR_PID" 2>/dev/null; then
  echo "[entrypoint] FATAL: OmniRoute died before gate. abort." >&2
  _shutdown; exit 1
fi

echo "[entrypoint] starting gate on port $EXPOSED_PORT..."
node /gate/gate.js &
GATE_PID=$!
echo "[entrypoint] gate PID=$GATE_PID"

# ── 监督循环 ──────────────────────────────────────────────
while true; do
  if ! kill -0 "$GATE_PID" 2>/dev/null; then
    echo "[entrypoint] gate exited. 停止其余并退出."
    _shutdown; exit 1
  fi
  if ! kill -0 "$OR_PID" 2>/dev/null; then
    echo "[entrypoint] OmniRoute exited. 停止其余并退出."
    _shutdown; exit 1
  fi
  if [ -n "$INIT_PID" ] && ! kill -0 "$INIT_PID" 2>/dev/null; then
    [ "$_init_logged" = 1 ] || { echo "[entrypoint] NIM init 已退出 (非致命)."; _init_logged=1; }
  fi
  if [ -n "$LS_PID" ] && ! kill -0 "$LS_PID" 2>/dev/null; then
    if [ "$LITESTREAM_STRICT" = 1 ]; then
      echo "[entrypoint] FATAL: Litestream replicate exited (strict). 停止."
      _shutdown; exit 1
    else
      echo "[entrypoint] WARN: Litestream replicate exited (LITESTREAM_STRICT=0)."
      LS_PID=""
    fi
  fi
  sleep 1
done