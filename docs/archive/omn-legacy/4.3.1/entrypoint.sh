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

echo "[entrypoint] cold-boot (restore→purge→replicate→OmniRoute, 严格时序)..."
echo "[entrypoint] OMNIROUTE_PORT=$OMNIROUTE_PORT EXPOSED_PORT=$EXPOSED_PORT DATA_DIR=$DATA_DIR STRICT=$LITESTREAM_STRICT"

# ── 文件锁: 防多容器同时 restore/purge/替换 $DB ───────────
# P3: LOCK_FILE 可配置 (多容器部署置共享卷路径获跨容器互斥; 默认 $DATA_DIR/.entrypoint.lock 同旧硬编码).
#   获锁前断言 LOCK_FILE 所在目录可写: 不可写 → WARN 降级无锁继续 (不 exit 1), 记原因 + 实际锁路径.
#   flock 获取逻辑/失败行为不改 (flock 不可用仍 WARN 跳过; flock 失败仍 exit 1).
LOCK_FD=9
LOCK_FILE="${LOCK_FILE:-${DATA_DIR}/.entrypoint.lock}"
_lock_dir=$(dirname "$LOCK_FILE")
if [ -w "$_lock_dir" ]; then
  :
else
  echo "[entrypoint] WARN: 锁目录不可写 ..." >&2
fi
echo "[entrypoint] flock path=$LOCK_FILE"
if command -v flock >/dev/null 2>&1; then
  if ! exec 9>"$LOCK_FILE" 2>/dev/null; then
    # 目录不可写: 走上面已声明的 WARN 降级语义, 不 exit
    echo "[entrypoint] WARN: 无法打开锁文件 $LOCK_FILE (dir 不可写或权限不足) → 降级无锁继续." >&2
  elif ! flock -n -x 9; then
    echo "[entrypoint] FATAL: 锁被占用 $LOCK_FILE (另一进程持有). abort." >&2
    exit 1
  else
    echo "[entrypoint] lock acquired (flock $LOCK_FILE, fd 9)."
  fi
else
  echo "[entrypoint] WARN: flock 不可用, 跳过跨容器互斥 (HF Space 优先单实例)."
fi

# ── 1. Litestream restore (启动前; 红线3: 不覆盖有效 DB) ─
# 设计原则 (优雅降级):
#   R2 无副本 → -if-replica-exists 返回 0 但不创建文件 → 空库启动 (init 重建), 不 exit
#   restore 命令失败 (配置/网络/权限错误) → WARN + 空库启动, 不 exit
#   restore 成功+有文件 → quick_check 通过 → 原子 mv → 正式 $DB
#   restore 成功+quick_check 失败 → 丢弃临时+空库启动, 不 exit
# STRICT 仅控制日志级别 (STRICT=1 多打一行 WARN), 不控制 exit. 永远不因 restore 失败而 FATAL exit.
has_r2=0
[ -n "$R2_ACCESS_KEY_ID" ] && [ -n "$R2_SECRET_ACCESS_KEY" ] && [ -n "$R2_ACCOUNT_ID" ] && has_r2=1

if [ "$has_r2" = 0 ]; then
  echo "[entrypoint] R2 creds 缺失 → skip restore. 空库启动 (init 重建)."
elif [ -f "$DB" ] && [ -s "$DB" ]; then
  echo "[entrypoint] 本地 DB 非空 ($DB) → skip restore (红线3: 不覆盖有效 DB)."
else
  # 本地 DB 空或不存在 → restore.
  # litestream 0.5.9 restore 参数 = 数据库标识符 (litestream.yml dbs[].path 匹配 = $DB), 不是输出路径.
  # 优先 -o "$DB_TMP" 输出临时路径 → 原子 mv. 若 -o 不支持 → 回退直接 $DB restore (冷启动 $DB 空, 无有效 DB 被覆盖).
  rm -f "$DB_TMP" "$DB_TMP-wal" "$DB_TMP-shm"
  printf '%s' "" > /tmp/ls_restore.err
  rc=0
  litestream restore -config /litestream.yml -if-replica-exists -o "$DB_TMP" "$DB" 2>/tmp/ls_restore.err || rc=$?
  used_tmp=1
  if echo "$(cat /tmp/ls_restore.err 2>/dev/null)" | grep -qiE 'unknown flag|invalid option|flag provided but not defined.*-o'; then
    echo "[entrypoint] litestream 0.5.9 不支持 -o → 回退直接 restore $DB (冷启动 $DB 空, 安全)."
    rm -f "$DB_TMP" "$DB_TMP-wal" "$DB_TMP-shm"
    printf '%s' "" > /tmp/ls_restore.err
    rc=0
    litestream restore -config /litestream.yml -if-replica-exists "$DB" 2>/tmp/ls_restore.err || rc=$?
    used_tmp=0
  fi

  if [ "$rc" -ne 0 ]; then
    # restore 命令失败 (配置/网络/权限) → 空库启动 WARN, 不 exit
    echo "[entrypoint] WARN: restore rc=$rc (见 /tmp/ls_restore.err; 已脱敏, 不打凭据)."
    [ "$LITESTREAM_STRICT" = 1 ] && echo "[entrypoint]   STRICT=1: 仅告警, 不 exit (空库启动)."
    rm -f "$DB_TMP" "$DB_TMP-wal" "$DB_TMP-shm" 2>/dev/null || true
  elif [ "$used_tmp" = 1 ] && { [ ! -f "$DB_TMP" ] || [ ! -s "$DB_TMP" ]; }; then
    # rc=0 但临时文件不存在或空 → R2 无副本 → 空库启动 (正常, 不 WARN 不 exit)
    echo "[entrypoint] restore rc=0 但无文件 (R2 无副本或首次部署). 空库启动, init 重建配置."
    rm -f "$DB_TMP" "$DB_TMP-wal" "$DB_TMP-shm" 2>/dev/null || true
  elif [ "$used_tmp" = 1 ]; then
    # 临时文件有效 → quick_check → 原子 mv
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
      echo "[entrypoint] sqlite3 不可用, 跳过 quick_check (验文件非空)."
      qc_ok=1
    fi
    if [ "$qc_ok" = 1 ]; then
      mv "$DB_TMP" "$DB" && echo "[entrypoint] restore complete (原子 mv $DB_TMP → $DB)."
    fi
  else
    # used_tmp=0 (直接 $DB restore): 验 $DB 非空 (R2 无副本文件) + quick_check
    if [ ! -f "$DB" ] || [ ! -s "$DB" ]; then
      echo "[entrypoint] restore rc=0 但 $DB 无文件 (R2 无副本或首次部署). 空库启动, init 重建."
    elif command -v sqlite3 >/dev/null 2>&1; then
      if sqlite3 "$DB" "PRAGMA quick_check;" 2>/dev/null | grep -q "^ok$"; then
        echo "[entrypoint] restore complete (直接 $DB, quick_check ok)."
      else
        echo "[entrypoint] WARN: quick_check 失败 on $DB. 空库启入替换."
        rm -f "$DB" "$DB-wal" "$DB-shm" 2>/dev/null || true
      fi
    else
      echo "[entrypoint] restore complete (直接 $DB, 文件非空)."
    fi
  fi
fi

# ── 2. FIX #5 pre-purge: OmniRoute 启动 *前*, 事务化, 精确条件, 加 assert ──
# B6 源码实证 (L2): runtime patchedFetch (proxyFetch.ts:637) 用内存 account.proxy (pool load 时
# 一次性从 SQLite proxy_registry 读取, proxies.ts:806), 不查 provider_connections.proxy_enabled,
# 无 reload 钩子 → purge 改 SQLite 但 OmniRoute 进程已加载旧条目 → 旧 20129 幽灵 entry 持续.
# 本段在 OmniRoute 启动 *前* SQL-only 清 20129 条目 → pool load 时 SQLite 已无幽灵 → direct 路径.
# purge 时机: 必在 restore 后 (R2 旧库会带回旧条目) → OmniRoute 前. 永不: purge→restore→OmniRoute.
# 删除依据: 精确 host+port 条件 (非 "总数=20129").
# assert: purge 后目标条目残留必须为 0, 否则整个容器 exit (绝不让幽灵条目进 OmniRoute).
[ "$_PURGE_PROXY" != "0" ] && _PURGE_PROXY=1    # NIM_PURGE_PROXY=0 可关全段
if [ -n "$DB" ] && [ -f "$DB" ] && [ -x "$(command -v sqlite3 2>/dev/null || true)" ] && [ "$_PURGE_PROXY" = "1" ]; then
  sql_e5(){ printf '%s' "$1" | sed "s/'/''/g"; }
  _P5=${NIM_PROXY_RELAY_PORT:-20129}
  _H5=${NIM_PROXY_RELAY_HOST:-127.0.0.1}
  _SQLITE3_BIN=$(command -v sqlite3 2>/dev/null || true)
  _SQLITE_RAN=0   # 标记 wal_checkpoint 行 (P5) 与 deleted=N (P4) 是否真输出
  if [ -n "$_SQLITE3_BIN" ]; then
    _pre=$(sqlite3 "$DB" "SELECT COUNT(*) FROM proxy_registry WHERE host IN ('127.0.0.1','::1','localhost','0.0.0.0') AND port=$_P5;" 2>/dev/null || echo "?")
    echo "[entrypoint] FIX #5 pre-purge: relay ${_H5}:${_P5} purge 前=$_pre 条 (host IN 四本地地址变体 + port 约束)."
    # 事务化 purge (BEGIN...COMMIT 包裹): 三条 DELETE 原子提交, 中断回滚不留半状态.
    # P4: WHERE 扩 host IN ('127.0.0.1','::1','localhost','0.0.0.0') + port=$_P5 (保留 port 约束).
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
      echo "[entrypoint] FATAL: pre-purge 事务失败 rc=$purge_rc (见 /tmp/purge.err). abort 启动 (不能让旧条目进 OmniRoute 内存)." >&2
      exit 1
    fi
    # P4: purge 事务提交后用 changes() 取实际删除行数 (proxy_registry DELETE 行数).
    _purge_del=$(sqlite3 "$DB" "SELECT changes();" 2>/dev/null || echo "?")
    echo "[entrypoint] pre-purge deleted=${_purge_del} rows"
    _SQLITE_RAN=1
    # P5: WAL checkpoint (TRUNCATE) 后读 busy/log/checkpointed 三值; busy>0 WARN 不 exit 1.
    _ckpt=$(sqlite3 "$DB" "PRAGMA wal_checkpoint(TRUNCATE);" 2>/dev/null | tr '|' '\t' || echo "")
    # sqlite3 CLI 默认 pipe 分隔返回 busy\tlog\tcheckpointed 三列
    _ck_busy=$(printf '%s' "$_ckpt" | cut -f1)
    _ck_log=$(printf '%s' "$_ckpt" | cut -f2)
    _ck_ckptd=$(printf '%s' "$_ckpt" | cut -f3)
    echo "[entrypoint] wal_checkpoint busy=${_ck_busy:-?} log=${_ck_log:-?} checkpointed=${_ck_ckptd:-?}"
    if [ -n "$_ck_busy" ] && [ "$_ck_busy" -gt 0 ] 2>/dev/null; then
      echo "[entrypoint] WARN: wal_checkpoint busy=${_ck_busy}, WAL not fully checkpointed (Litestream 占 WAL reader 正常, 不阻断启动)." >&2
    fi
    rm -f "$DB-wal" "$DB-shm" 2>/dev/null || true
    # assert: 目标条目残留必须为 0, 否则整个容器 exit (B6 根因硬约束)
    _post=$(sqlite3 "$DB" "SELECT COUNT(*) FROM proxy_registry WHERE host IN ('127.0.0.1','::1','localhost','0.0.0.0') AND port=$_P5;" 2>/dev/null || echo "?")
    echo "[entrypoint] FIX #5 pre-purge: relay ${_H5}:${_P5} purge 后=$_post 条 (必须=0)."
    if [ "$_post" != "0" ]; then
      echo "[entrypoint] FATAL: pre-purge assert 失败 (残留=$_post !=0). 幽灵条目将污染 OmniRoute 内存. 整个容器 exit." >&2
      exit 1
    fi
    echo "[entrypoint] ✓ pre-purge assert pass (残留=0). SQLite 已无 ${_P5} relay → pool load direct 路径."
  else
    # P4/P5 fallback: sqlite3 CLI 不可用 → 改 node -e + node:sqlite (Node22+ experimental) 做同等 purge+checkpoint+assert.
    echo "[entrypoint] FIX #5 pre-purge: sqlite3 CLI 缺 → fallback node:sqlite 做 purge+checkpoint+assert."
    _P5_N="$_P5" _DB_N="$DB" _H5_N="$_H5" node -e '
      const { DatabaseSync } = require("node:sqlite");
      const dbPath = process.env._DB_N, port = Number(process.env._P5_N), host = process.env._H5_N;
      const hosts = ["127.0.0.1","::1","localhost","0.0.0.0"];
      const placeholders = "(" + hosts.map(()=>"?").join(",") + ")";
      let db;
      try { db = new DatabaseSync(dbPath); } catch (e) { console.error("[entrypoint] FATAL: node:sqlite 打开 $DB 失败: " + e.message); process.exit(1); }
      // WAL mode + checkpoint helper
      const q = (s,p=[]) => { const st = db.prepare(s); return p.length ? st.all(...p) : st.all(); };
      const pre = db.prepare("SELECT COUNT(*) AS c FROM proxy_registry WHERE host IN " + placeholders + " AND port=?").all(...hosts, port)[0].c;
      console.log("[entrypoint] FIX #5 pre-purge: relay " + host + ":" + port + " purge 前=" + pre + " 条 (host IN 四本地地址变体 + port 约束).");
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
            console.error("[entrypoint] WARN: wal_checkpoint busy=" + busy + ", WAL not fully checkpointed (Litestream 占 WAL reader 正常, 不阻断启动).");
          }
        } catch (e) { console.log("[entrypoint] wal_checkpoint busy=? log=? checkpointed=? (pragma 失败: " + e.message + ")"); }
        const post = db.prepare("SELECT COUNT(*) AS c FROM proxy_registry WHERE host IN " + placeholders + " AND port=?").all(...hosts, port)[0].c;
        console.log("[entrypoint] FIX #5 pre-purge: relay " + host + ":" + port + " purge 后=" + post + " 条 (必须=0).");
        if (String(post) !== "0") { console.error("[entrypoint] FATAL: pre-purge assert 失败 (残留=" + post + " !=0). 幽灵条目将污染 OmniRoute 内存. 整个容器 exit."); db.close(); process.exit(1); }
        console.log("[entrypoint] ✓ pre-purge assert pass (残留=0). SQLite 已无 " + port + " relay → pool load direct 路径.");
        db.close();
      } catch (e) {
        console.error("[entrypoint] FATAL: pre-purge 事务失败 (" + e.message + "). abort 启动 (不能让旧条目进 OmniRoute 内存).");
        try { db.exec("ROLLBACK"); } catch (_) {}
        db.close(); process.exit(1);
      }
    ' || { echo "[entrypoint] FATAL: node:sqlite purge fallback 失败. abort." >&2; exit 1; }
    _SQLITE_RAN=1
  fi
else
  echo "[entrypoint] FIX #5 pre-purge: skip (DB 未就绪/sqlite3 缺/NIM_PURGE_PROXY=0)."
fi

# ── 3. LiteStream replicate (后台启动, OmniRoute 启动 *前*) ─
# 顺序: restore→purge→replicate→OmniRoute. litestream 先占 purge 后干净 $DB 作 L0 baseline,
# OmniRoute 后续写入 WAL → litestream 复制新 generation 不被旧 L0 覆盖.
# 验: litestream.yml dbs[].path = /data/storage.sqlite = $DB (匹配, 非 $DB_TMP).
export NODE_OPTIONS="--max-old-space-size=4096"
if [ "$has_r2" = 1 ]; then
  mkdir -p "$DATA_DIR" 2>/dev/null || true
  # 删除可能残留的临时 -wal/-shm (purge 后正式 $DB 可能落 wal; litestream 启前清, replicate 会从 $DB 重建基线)
  echo "[entrypoint] Starting Litestream replication (OmniRoute 启动前, 占 purge 后干净 baseline)..."
  # 验 matches litestream.yml dbs[].path
  printf '%s' "$DB" | grep -q "^${DATA_DIR}/storage.sqlite$" || {
    echo "[entrypoint] FATAL: \$DB=$DB 与 litestream.yml dbs[].path 不一致 → replicate db-path 不匹配." >&2; exit 1; }
  litestream replicate -config /litestream.yml &
  LS_PID=$!
  sleep 1
  if ! kill -0 "$LS_PID" 2>/dev/null; then
    echo "[entrypoint] FATAL: Litestream replicate 退出过早 (config/R2 错误? 见 stderr). abort." >&2
    [ "$LITESTREAM_STRICT" = 1 ] && exit 1 || { LS_PID=""; echo "[entrypoint] STRICT=0: 降级无 replicate 继续."; }
  else
    echo "[entrypoint] Litestream PID=$LS_PID (replicate $DB → R2)."
  fi
else
  echo "[entrypoint] WARN: LiteStream replication disabled (无 R2 creds). STRICT=$LITESTREAM_STRICT."
fi

# ── 4. OmniRoute (启动在 purge + replicate 之后) ──────────
echo "[entrypoint] starting OmniRoute via /app/server.js (PIDs OR=$OR_PID background)..."
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
