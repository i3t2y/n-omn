# OmniRoute Project Merge - v4.3.0

## Dockerfile

```dockerfile
# ── 基础镜像：钉死到验证过健康的 3.8.43，禁止浮动 latest ──────────
# 根因：latest 会漂到 3.8.46（默认 Turbopack 构建 + migration 117 表重建），
#       导致 Next 服务进程静默无法 ready，entrypoint 健康等待空转卡在 starting。
# 拿 digest：docker pull diegosouzapw/omniroute:3.8.43
#           docker inspect --format='{{index .RepoDigests 0}}' diegosouzapw/omniroute:3.8.43
# 用 tag+digest 双写：digest 保证不可变，tag 便于人读。
FROM diegosouzapw/omniroute:3.8.43@sha256:517c160643c56ad72e3e305458d961c9a4c87f711393c13020450f9f088d1570

ENV OMNIROUTE_PORT=20128
ENV EXPOSED_PORT=7860
ENV DATA_DIR=/data
# ── 后台访问开关 (v4.3): GATE_ADMIN_TOKEN 空即关闭后台 (默认不设); 设强随机 token 开启后台并可 Basic Auth ──
# 注意: 设此变量会扩大公网暴露面 (后台白名单), 后台仍受 OmniRoute 自身认证约束. 不设 IP 限制 (HF 代理拓扑未验证).
# ENV GATE_ADMIN_TOKEN=

# ── 跨版本防御 env（3.8.43 无害；若将来误漂到新版可避免静默 hang）──
# Turbopack 逃生阀：强制走 webpack，绕开 3.8.45+ 的 Docker Turbopack 缓存 mmap 失败
ENV OMNIROUTE_USE_TURBOPACK=0
# 迁移安全阀：从旧库补多个 migration（含 117 表重建）时不触发 abort 刷屏中断
ENV OMNIROUTE_MAX_PENDING_MIGRATIONS=0

USER root

RUN apt-get update && apt-get install -y --no-install-recommends \
    curl \
    jq \
    python3 \
    python3-pip \
    sqlite3 \
    ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# ── huggingface_hub（HF Dataset 配置快照上传）──────────────────────
RUN pip3 install --no-cache-dir --break-system-packages huggingface_hub

# ── Litestream v0.5.9（修复 R2 InvalidContentEncoding + auto-recover）──
# asset 命名：litestream-{VER}-linux-{ARCH}.tar.gz（无 v 前缀，x86_64 非 amd64）
ARG LITESTREAM_VERSION=0.5.9
RUN ARCH=$(uname -m | sed 's/aarch64/arm64/') && \
    curl -fsSL \
      "https://github.com/benbjohnson/litestream/releases/download/v${LITESTREAM_VERSION}/litestream-${LITESTREAM_VERSION}-linux-${ARCH}.tar.gz" \
    | tar -xz -C /usr/local/bin litestream && \
    chmod +x /usr/local/bin/litestream && \
    litestream version

RUN mkdir -p /data && chmod 777 /data
RUN rm -rf /app/data && ln -sf /data /app/data

RUN mkdir -p /gate
COPY package.json /gate/package.json
COPY gate.js /gate/gate.js
RUN cd /gate && npm install --omit=dev --silent

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

COPY init-nim-keys.sh /entrypoint-init-nim.sh
RUN chmod +x /entrypoint-init-nim.sh

COPY litestream.yml /litestream.yml

EXPOSE 7860

# ── 容器级健康检查：start-period 与 entrypoint 内部 180s 等待对齐 ──
HEALTHCHECK --interval=30s --timeout=10s --start-period=180s --retries=3 \
    CMD curl -sf http://127.0.0.1:7860/healthz || exit 1

ENTRYPOINT ["/entrypoint.sh"]

```

## entrypoint.sh

```sh
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
```

## gate.js

```js
// gate.js — v4.3 candidate (Stage D)
// OmniRoute PSK 出口 Proxy (HF Space :7860 -> 127.0.0.1:20128)
// 唯一出口代理, 经 OmniRoute 直连, 无外部 Relay / cf-worker / context-relay.
//
// 红线 2 (暴露面, 看管性改写——受后台开关约束):
//   默认 (GATE_ADMIN_TOKEN 未设/空/过短): 后台关闭, 外网仅 GET /healthz + /v1 + /v1/*; 其余 404.
//   设置有效 GATE_ADMIN_TOKEN: 后台白名单路径经 HTTP Basic Auth (admin/<token>) 放行;
//     白名单为 B3 v3.8.43 真实路由的最小权限保守子集, 非全量; 未验证路径恒 404, 不 allow-everything.
// 兼容: 保留原变量名 GATE_ADMIN_TOKEN (v8.0 后台鉴权变量, slim 删除前);
//   废弃 v8.0 "空 Token 内网直连不鉴权" 旧语义; 现: 空 Token = 后台关闭 (404).
// 三类入口分离: /healthz(免认证) | /v1,/v1/*(INTERNAL_PSK) | 后台白名单(GATE_ADMIN_TOKEN via Basic Auth).
//   互不回退, PSK 不访问后台, admin token 不访问 /v1.
// 后台认证仅外层入口保护, 不替代/OmniRoute 自身认证; Gate 不注入 Session, 不伪造 Cookie.
//   完成 Basic Auth 校验后, 删除/替换外层 Authorization 头, 不转发给上游 (防凭据泄露).
// 红线 (PSK/admin token): 缺失/格式错/长度不同/内容不同 → 401; crypto.timingSafeEqual 常量时间; 长度不等不退字符串比较.
// SSE: 逐块转发 (不聚合), 不 text/json 读流, 尊重背压, 客户端断开取消上游, 清理监听/定时器/流.
// 进程: SIGTERM/SIGINT 自处理优雅关 (entrypoint.sh trap 亦转发).
// 无第二套限流: 28 RPM/1 并发/2200ms 由 OmniRoute requestQueue 执行, 本文件零限流代码.
// IP/CIDR 限制: 不默认实现 (HF 代理拓扑未验证, 无 L1 证据 trust proxy); 预留能力默认关, KNOWN-UNVERIFIED 记.

const express = require('express');
const http = require('http');
const crypto = require('crypto');
const fs = require('fs');

const INTERNAL_PSK = process.env.INTERNAL_PSK || '';
const GATE_ADMIN_TOKEN = process.env.GATE_ADMIN_TOKEN || '';
const OR_PORT = parseInt(process.env.OMNIROUTE_PORT || '20128', 10);
const GATE_PORT = parseInt(process.env.EXPOSED_PORT || '7860', 10);
const UPSTREAM_TIMEOUT_MS = parseInt(process.env.GATE_UPSTREAM_TIMEOUT_MS || '30000', 10) || 30000;
const SHUTDOWN_GRACE_MS = parseInt(process.env.GATE_SHUTDOWN_GRACE_MS || '5000', 10) || 5000;
const ADMIN_TOKEN_MIN_LEN = 16;
const ADMIN_REALM = 'OmniRoute Admin';

// ── fail-closed: PSK 必须非空且最小长度 ──────────────────────
if (!INTERNAL_PSK || INTERNAL_PSK.length < 16) {
  console.error('[gate] FATAL: INTERNAL_PSK missing or <16 chars. HF Space Secret 必须配置。');
  process.exit(1);
}
let OR_API_KEY = (process.env.OMNIROUTE_API_KEY || '').trim();
if (!OR_API_KEY) {
  try { OR_API_KEY = fs.readFileSync('/data/.or-api-key', 'utf8').trim(); }
  catch (e) { if (e.code !== 'ENOENT') console.error('[gate] WARN read key failed:', e.message); }
}
if (!OR_API_KEY) {
  console.error('[gate] FATAL: No OR_API_KEY (env nor /data/.or-api-key).');
  process.exit(1);
}

// ── 后台开关 (单变量 GATE_ADMIN_TOKEN, 兼任开关 + 入口认证) ──
// 空/过短 → 后台关闭 (路径 404); 有效 → 后台白名单 + Basic Auth.
// 不记录/回显/转发 GATE_ADMIN_TOKEN.
const ADMIN_ENABLED = GATE_ADMIN_TOKEN.length >= ADMIN_TOKEN_MIN_LEN;
if (process.env.GATE_ADMIN_TOKEN && GATE_ADMIN_TOKEN.length < ADMIN_TOKEN_MIN_LEN) {
  console.error(`[gate] WARN: GATE_ADMIN_TOKEN 长度 <${ADMIN_TOKEN_MIN_LEN}, 后台关闭 (不记录 token 值).`);
}
console.log(`[gate] admin UI: ${ADMIN_ENABLED ? 'enabled' : 'disabled'} (开关状态可记, 不记 token).`);

// timing-safe equal: 双方 Buffer, 长度不等先返回不泄露内容, 长度相等路径走 timingSafeEqual.
function safeEqual(a, b) {
  if (!a || !b) return false;
  const ba = Buffer.from(a);
  const bb = Buffer.from(b);
  if (ba.length !== bb.length) return false;
  return crypto.timingSafeEqual(ba, bb);
}
// HTTP Basic Auth: user 固定 'admin', password = GATE_ADMIN_TOKEN. timing-safe 比密码.
function adminBasicAuthOk(req) {
  const header = req.headers.authorization || '';
  if (!header.startsWith('Basic ')) return false;
  let decoded;
  try { decoded = Buffer.from(header.slice('Basic '.length).trim(), 'base64').toString('utf8'); }
  catch (e) { return false; }          // base64 解码失败
  if (typeof decoded !== 'string' || decoded.indexOf(':') < 0) return false;
  const sep = decoded.indexOf(':');
  const user = decoded.slice(0, sep);
  const pass = decoded.slice(sep + 1);
  if (user !== 'admin') return false;
  return safeEqual(pass, GATE_ADMIN_TOKEN);   // timing-safe, 长度不等不退字符串比较
}

// ── 后台白名单 (B3 v3.8.43 真实路由最小权限保守子集, 源码 audit/06 ◆) ──
// 页面导航 (Next App Router 真实存在):
const ADMIN_PAGE_PREFIXES = [
  '/login', '/forgot-password', '/auth/callback', '/callback', '/authorize',
  '/connect', '/terms', '/privacy', '/docs', '/status', '/landing',
  '/home', '/dashboard',
];
// 页面允许方法 (GET 导航):
const ADMIN_PAGE_METHODS = ['GET'];
// 只读看板管理 API (B3 src/app/api 顶层只读子集; 排除 restart/shutdown/init/webhooks 等高风险写执行):
const ADMIN_API_ROUTES = [
  { pre: '/api/providers',          methods: ['GET'] },
  { pre: '/api/combos',             methods: ['GET'] },
  { pre: '/api/resilience',         methods: ['GET'] },
  { pre: '/api/keys',               methods: ['GET'] },
  { pre: '/api/provider-models',     methods: ['GET'] },
  { pre: '/api/models',             methods: ['GET'] },
  { pre: '/api/settings',           methods: ['GET'] },
  { pre: '/api/provider-stats',     methods: ['GET'] },
  { pre: '/api/provider-metrics',   methods: ['GET'] },
  { pre: '/api/sessions',           methods: ['GET'] },
  { pre: '/api/session-pools',      methods: ['GET'] },
  { pre: '/api/rate-limit',         methods: ['GET'] },
  { pre: '/api/rate-limits',        methods: ['GET'] },
  { pre: '/api/token-health',       methods: ['GET'] },
  { pre: '/api/synced-available-models', methods: ['GET'] },
  { pre: '/api/free-models',        methods: ['GET'] },
  { pre: '/api/free-provider-rankings', methods: ['GET'] },
  { pre: '/api/tags',               methods: ['GET'] },
];

function isStaticAssetPath(p) {
  if (p.startsWith('/_next/')) return true;
  return /^\/(favicon\.ico|favicon\.svg|apple-touch-icon\.(png|svg)|icon-192\.svg|icon-512\.png|sw\.js|openapi\.yaml)/.test(p);
}
function isAdminPagePath(p) {
  if (p === '/') return true;
  if (isStaticAssetPath(p)) return true;
  return ADMIN_PAGE_PREFIXES.some(pre => p === pre || p.startsWith(pre + '/') || p.startsWith(pre));
}
function apiRouteMatch(p, method) {
  for (const r of ADMIN_API_ROUTES) {
    if (p === r.pre || p.startsWith(r.pre + '/')) {
      return r.methods.includes(method);
    }
  }
  return false;
}

// ── 结构化诊断日志 (gate 出口 proxy 错误/abort) ──
//   一行 JSON stderr (HF Space 抓取): requestId/path/method/upstream/elapsedMs/httpStatus/errorCode/abortSource/destroyInitiator
//   abortSource 区分: 'upstream_error' (上游真错) / 'client_close' (客户端断开反发) / 'timeout' (gate 30s 超时) / 'shutdown'
//   destroyInitiator: 'gate_timeout' / 'client' / 'upstream' / 'null' (无主动 destroy)
//   不打印 headers/PSK/token/body (脱敏). 仅 path+method+errorCode (无敏感).
function genReqId() {
  try { return crypto.randomBytes(8).toString('hex'); } catch { return 'rid_unknown'; }
}
function logGate(req, fields) {
  try {
    const v = (n) => (typeof n === 'number' || typeof n === 'string') ? n : null;
    const line = JSON.stringify({
      ts: Date.now(),
      level: 'error',
      component: 'gate',
      stage: 'upstream_proxy',
      requestId: req?._gateReqId || null,
      method: req?.method || null,
      path: req?._normPath || null,
      upstream_path: req?._upstreamPath || null,
      upstream_target: `127.0.0.1:${OR_PORT}`,
      elapsedMs: v(fields.elapsedMs),
      httpStatus: v(fields.httpStatus),
      errorCode: fields.errorCode || null,
      abortSource: fields.abortSource || null,
      socketPhase: fields.socketPhase || null,
      destroyInitiator: fields.destroyInitiator || null,
      msg: fields.msg || null,
    });
    process.stderr.write(line + '\n');
  } catch { /* never throw from logger */ }
}

// abort source 区分: 从上游 error 事件 + 标记位判断谁发起 destroy
//   gateTimeout=true → 'timeout'; clientAborted=true → 'client_close'; shuttingDown → 'shutdown';
//   ECONNRESET + elapsedMs<5000 → 'upstream_reset' (短时窗 socket reset, 候选 stale pooled socket);
//   else 'upstream_error'.
//   timeout/client_close/shutdown 三类判断逻辑不变 (task#23 仅增 upstream_reset 兜底前).
function classifyAbortSource(e, { gateTimeout, clientAborted, elapsedMs } = {}) {
  if (gateTimeout) return 'timeout';
  if (clientAborted) return 'client_close';
  if (shuttingDown) return 'shutdown';
  if (e?.code === 'ECONNRESET' && typeof elapsedMs === 'number' && elapsedMs < 5000) {
    return 'upstream_reset';
  }
  return 'upstream_error';
}

// HTTP status 映射: ECONNREFUSED/ECONNRESET=503 (upstream unavailable/rest),
//   timeout/ETIMEDOUT/ESOCKETTIMEDOUT=504 (gateway_timeout), 其余=502 (bad_gateway)
function mapUpstreamStatus(e, { gateTimeout } = {}) {
  if (gateTimeout || e?.code === 'ETIMEDOUT' || e?.code === 'ESOCKETTIMEDOUT') return 504;
  if (e?.code === 'ECONNREFUSED' || e?.code === 'ECONNRESET') return 503;
  return 502;
}
function statusErrorLabel(code) {
  return code === 504 ? 'gateway_timeout'
    : code === 503 ? 'service_unavailable'
    : 'bad_gateway';
}

const app = express();
let shuttingDown = false;

// 注入 requestId + 开始时间 (per-request, 在路径规整化中间件后可用 _normPath)
app.use((req, res, next) => {
  req._gateReqId = genReqId();
  req._gateT0 = Date.now();
  next();
});

// ── /healthz: 免认证探活 ─────────────────────────────────
app.get('/healthz', async (req, res) => {
  if (shuttingDown) return res.status(503).json({ ok: false });
  let r;
  try {
    r = await fetch(`http://127.0.0.1:${OR_PORT}/api/monitoring/health`, {
      signal: AbortSignal.timeout(2000),
    });
  } catch (e) {
    return res.status(503).json({ ok: false });
  }
  r?.ok ? res.json({ ok: true }) : res.status(503).json({ ok: false });
});

// 路径规整化: 解 dot-segment, 重复斜杠, 尾斜杠 (防绕过白名单匹配)
function normalizePath(p) {
  try {
    const u = new URL(p, 'http://x');
    let n = u.pathname.replace(/\/+/g, '/').replace(/\/$/, '');
    if (n === '') n = '/';
    return n;
  } catch (e) {
    return p;
  }
}

// ── 暴露面白名单 (默认仅 /healthz + /v1; 管理白名单仅 token 有效时) ──
//   非 /healthz / 非 /v1: 须 ADMIN_ENABLED 且路径在白名单 (页/api/静态), 否则 404.
//   后台关闭时即使带 OmniRoute Cookie/Session 也 404 (不泄露后台是否存在).
app.use((req, res, next) => {
  req._normPath = normalizePath(req.path);
  if (shuttingDown && req._normPath !== '/healthz') return res.status(503).json({ ok: false });
  if (req._normPath === '/healthz') return next();
  if (req._normPath === '/v1' || req._normPath.startsWith('/v1/')) return next();
  // 后台
  if (!ADMIN_ENABLED) return res.status(404).end();
  const p = req._normPath;
  // 静态资源 (开关开后免 Basic Auth, 仍须白名单)
  if (isAdminPagePath(p)) {
    if (isStaticAssetPath(p)) return next();   // 静态免 token, 仅须开关开
    // 页面导航须 method GET + Basic Auth (后中间件)
    if (ADMIN_PAGE_METHODS.includes(req.method)) return next();
    return res.status(405).json({ error: 'method_not_allowed' });
  }
  if (apiRouteMatch(p, req.method)) return next();
  if (apiRouteMatch(p, 'GET') && req.method !== 'GET') {
    return res.status(405).json({ error: 'method_not_allowed' });
  }
  return res.status(404).end();   // 非白名单 + 未知 → 404, 开启用时仍 404
});

// ── 后台页 + api Basic Auth (静态免) ──
//   通过后删除 Authorization 头 (不转发 Basic 给上游 OmniRoute, 防凭据泄露).
app.use((req, res, next) => {
  if (req._normPath === '/healthz' || req._normPath === '/v1' || req._normPath.startsWith('/v1/')) return next();
  if (!ADMIN_ENABLED) return next();   // 后台关 (已在白名单中间件 404, 此处不到)
  const p = req._normPath;
  if (isStaticAssetPath(p)) return next();   // 静态免 token
  if (!isAdminPagePath(p) && !apiRouteMatch(p, req.method)) return next();   // 非白名单 (已 404, 不到)
  if (!adminBasicAuthOk(req)) {
    res.setHeader('WWW-Authenticate', `Basic realm="${ADMIN_REALM}", charset="UTF-8"`);
    return res.status(401).json({ error: 'unauthorized' });
  }
  delete req.headers.authorization;   // 不转发 Basic 给上游; OmniRoute 自身认证照走 (Cookie/Session)
  next();
});

// ── /v1 PSK 校验: Internal PSK timing-safe ──
app.use('/v1', (req, res, next) => {
  const auth = req.headers.authorization || '';
  if (!auth.startsWith('Bearer ')) {
    return res.status(401).json({ error: 'unauthorized' });
  }
  const bearer = auth.slice('Bearer '.length).trim();
  if (!safeEqual(bearer, INTERNAL_PSK)) {
    return res.status(401).json({ error: 'unauthorized' });
  }
  req.headers.authorization = `Bearer ${OR_API_KEY}`;   // /v1 转发用 OR_API_KEY
  next();
});

// ── SSE 透传代理: 手写 http, 逐块 pipe, 客户端断开 abort 上游 ─
function proxyV1(req, res) {
  // app.use('/v1', ...) mount 下 req.path 被 Express strip '/v1' 前缀; 用 originalUrl 保完整 (含 query).
  const upstreamPath = req.originalUrl;
  const headers = { ...req.headers };
  delete headers.host;
  headers.host = `127.0.0.1:${OR_PORT}`;

  const upstreamReq = http.request({
    host: '127.0.0.1',
    port: OR_PORT,
    method: req.method,
    path: upstreamPath,
    headers,
    timeout: UPSTREAM_TIMEOUT_MS,
  }, (upstreamRes) => {
    req._socketPhase = 'streaming';   // 已收 response head → 进入流相 (含 SSE 逐块)
    res.writeHead(upstreamRes.statusCode, upstreamRes.headers);
    upstreamRes.on('data', (chunk) => {
      if (!res.write(chunk)) {
        upstreamRes.pause();
        res.once('drain', () => upstreamRes.resume());
      }
    });
    upstreamRes.on('end', () => { if (!res.writableEnded) res.end(); });
    upstreamRes.on('error', (e) => {
      // 上游响应流中途错 (已 head, 非 connect 错): fallback 502 + 结构化日志
      // task#23: 复用 classifyAbortSource (非硬码 'upstream_error'); 流相 elapsedMs 多 >5000 → 落 upstream_error
      const elapsedMs = Date.now() - (req._gateT0 || 0);
      const abortSource = classifyAbortSource(e, { gateTimeout, clientAborted, elapsedMs });
      logGate(req, { elapsedMs, httpStatus: 502,
        errorCode: e?.code || e?.message || 'upstream_response_stream_error',
        abortSource, socketPhase: req._socketPhase || 'streaming',
        destroyInitiator: 'upstream', msg: 'upstream_response_stream_error' });
      if (!res.headersSent) res.status(502).json({ error: 'bad_gateway', abort_source: abortSource });
      else if (!res.writableEnded) res.end();
    });
  });

  // socketPhase 跟踪: connecting → headers → streaming (供 upstream_reset/upstream_error 日志区分断在哪相)
  req._socketPhase = 'connecting';
  upstreamReq.on('socket', (socket) => {
    socket.on('connect', () => { if (req._socketPhase === 'connecting') req._socketPhase = 'headers'; });
  });

  // abort source tracking: 区分 client 断开 vs gate 超时 vs upstream 真错
  let aborted = false;
  let gateTimeout = false;   // gate 主动超时 destroy
  let clientAborted = false; // 客户端断开触发 cleanup
  let firstError = null;      // 首个上游 error (后续 destroy 反发不覆盖)
  function cleanup() {
    if (aborted) return;
    aborted = true;
    if (upstreamReq) {
      // 仅在 client 断开机上标记 (timeout handler 自己标记, 避免误判)
      if (!gateTimeout) { clientAborted = true; upstreamReq.destroy(); }
    }
    res.removeAllListeners('drain');
  }
  req.on('error', () => { clientAborted = true; cleanup(); });
  req.on('aborted', () => { clientAborted = true; cleanup(); });
  req.on('close', () => { clientAborted = true; cleanup(); });

  upstreamReq.on('timeout', () => {
    gateTimeout = true;
    upstreamReq.destroy(new Error('upstream_timeout'));
    const code = 504;
    logGate(req, { elapsedMs: Date.now() - (req._gateT0 || 0), httpStatus: code, errorCode: 'ETIMEDOUT',
      abortSource: 'timeout', destroyInitiator: 'gate_timeout', msg: 'upstream_request_timeout' });
    if (!res.headersSent) res.status(code).json({ error: statusErrorLabel(code), abort_source: 'timeout' });
    else if (!res.writableEnded) res.end();
  });
  upstreamReq.on('error', (e) => {
    // 首个 error 仅记一次 (后续 destroy 同事件反发不覆盖诊断)
    if (!firstError) firstError = e;
    // abort source 区分: client 已断开 + 这是 cleanup 反发的 destroy → client_close (不响应, client 已走)
    const elapsedMs = Date.now() - (req._gateT0 || 0);
    const abortSource = classifyAbortSource(e, { gateTimeout, clientAborted, elapsedMs });
    const code = clientAborted ? null : mapUpstreamStatus(e, { gateTimeout });
    // 不打 504 重复日志 (timeout handler 已打)
    if (!gateTimeout) {
      // socketPhase 仅附加于 upstream_reset/upstream_error (timeout/client_close/shutdown 不附, 非其语义)
      const phase = (abortSource === 'upstream_reset' || abortSource === 'upstream_error')
        ? (req._socketPhase || null) : null;
      logGate(req, {
        elapsedMs,
        httpStatus: code,
        errorCode: e?.code || e?.message || 'unknown_error',
        abortSource,
        socketPhase: phase,
        destroyInitiator: clientAborted ? 'client' : (gateTimeout ? 'gate_timeout' : 'upstream'),
        msg: abortSource === 'client_close' ? 'client_disconnected_proxy_aborted'
          : abortSource === 'shutdown' ? 'gate_shutting_down'
          : abortSource === 'upstream_reset' ? 'upstream_socket_reset_short_lived'
          : 'upstream_error',
      });
    }
    // client 断开: client 已不可达, 不再写 res (headersSent与否都直接 end)
    if (clientAborted) {
      if (!res.writableEnded) { try { res.end(); } catch {} }
      return;
    }
    if (!res.headersSent && code) {
      res.status(code).json({ error: statusErrorLabel(code), abort_source: abortSource });
    } else if (!res.writableEnded) {
      res.end();
    }
  });

  // 转发 body: 有 body 用 pipe 自动 end; 无 body (GET/OPTIONS) 须显式 end 发请求 (req 在 Express 已 end
  // 但 pipe 不一定触发 destination end; 显式收尾确保上游收到完整请求).
  if (req.readable && (req.headers['content-length'] || req.headers['transfer-encoding'])) {
    req.pipe(upstreamReq);
  } else {
    upstreamReq.end();
  }
}

app.use('/v1', (req, res) => proxyV1(req, res));

// 后台页 + api 转发 (经 Basic Auth + Authorization 已删); /v1 已各别处理
function proxyAdmin(req, res) {
  const qIdx = req.url.indexOf('?');
  const qs = qIdx >= 0 ? req.url.slice(qIdx) : '';
  const upstreamPath = req.path + qs;
  const headers = { ...req.headers };
  delete headers.host;
  headers.host = `127.0.0.1:${OR_PORT}`;
  // Authorization 已在 Basic Auth 中间件 delete; OmniRoute 自身认证 (Cookie/Session) 原样上行.

  const upstreamReq = http.request({
    host: '127.0.0.1',
    port: OR_PORT,
    method: req.method,
    path: upstreamPath,
    headers,
    timeout: UPSTREAM_TIMEOUT_MS,
  }, (upstreamRes) => {
    res.writeHead(upstreamRes.statusCode, upstreamRes.headers);
    upstreamRes.on('data', (chunk) => {
      if (!res.write(chunk)) {
        upstreamRes.pause();
        res.once('drain', () => upstreamRes.resume());
      }
    });
    upstreamRes.on('end', () => { if (!res.writableEnded) res.end(); });
    upstreamRes.on('error', (e) => {
      // 上游响应流中途错 (非 connect 错): 已 head, fallback 502 + 结构化日志
      logGate(req, { elapsedMs: Date.now() - (req._gateT0 || 0), httpStatus: 502,
        errorCode: e?.code || e?.message || 'upstream_response_stream_error',
        abortSource: 'upstream_error', destroyInitiator: 'upstream', msg: 'upstream_response_stream_error' });
      if (!res.headersSent) res.status(502).json({ error: 'bad_gateway', abort_source: 'upstream_error' });
      else if (!res.writableEnded) res.end();
    });
  });
  // abort source tracking (同 proxyV1): 区分 client 断开 vs gate 超时 vs upstream 真错
  let aborted = false;
  let gateTimeout = false;
  let clientAborted = false;
  let firstError = null;
  function cleanup() {
    if (aborted) return;
    aborted = true;
    if (upstreamReq) {
      if (!gateTimeout) { clientAborted = true; upstreamReq.destroy(); }
    }
    res.removeAllListeners('drain');
  }
  req.on('error', () => { clientAborted = true; cleanup(); });
  req.on('aborted', () => { clientAborted = true; cleanup(); });
  req.on('close', () => { clientAborted = true; cleanup(); });
  upstreamReq.on('timeout', () => {
    gateTimeout = true;
    upstreamReq.destroy(new Error('upstream_timeout'));
    const code = 504;
    logGate(req, { elapsedMs: Date.now() - (req._gateT0 || 0), httpStatus: code, errorCode: 'ETIMEDOUT',
      abortSource: 'timeout', destroyInitiator: 'gate_timeout', msg: 'admin_upstream_request_timeout' });
    if (!res.headersSent) res.status(code).json({ error: statusErrorLabel(code), abort_source: 'timeout' });
    else if (!res.writableEnded) res.end();
  });
  upstreamReq.on('error', (e) => {
    if (!firstError) firstError = e;
    const abortSource = classifyAbortSource(e, { gateTimeout, clientAborted });
    const code = clientAborted ? null : mapUpstreamStatus(e, { gateTimeout });
    if (!gateTimeout) {
      logGate(req, {
        elapsedMs: Date.now() - (req._gateT0 || 0),
        httpStatus: code,
        errorCode: e?.code || e?.message || 'unknown_error',
        abortSource,
        destroyInitiator: clientAborted ? 'client' : (gateTimeout ? 'gate_timeout' : 'upstream'),
        msg: abortSource === 'client_close' ? 'admin_client_disconnected_proxy_aborted'
          : abortSource === 'shutdown' ? 'gate_shutting_down' : 'admin_upstream_error',
      });
    }
    if (clientAborted) {
      if (!res.writableEnded) { try { res.end(); } catch {} }
      return;
    }
    if (!res.headersSent && code) {
      res.status(code).json({ error: statusErrorLabel(code), abort_source: abortSource });
    } else if (!res.writableEnded) {
      res.end();
    }
  });
  // 转发 body: 有 body 用 pipe 自动 end; 无 body (GET/OPTIONS) 须显式 end 发请求 (req 在 Express 已 end
  // 但 pipe 不一定触发 destination end; 显式收尾确保上游收到完整请求).
  if (req.readable && (req.headers['content-length'] || req.headers['transfer-encoding'])) {
    req.pipe(upstreamReq);
  } else {
    upstreamReq.end();
  }
}
// catch-all: 白名单已过中间件的 (后台页/api 非 /v1) → proxyAdmin; /v1 已前处理
app.use((req, res) => {
  if (req._normPath === '/healthz') return res.status(502).json({ error: 'bad_gateway' });  // /healthz 后端挂
  if (req._normPath === '/v1' || req._normPath.startsWith('/v1/')) return proxyV1(req, res);
  // 后台 (白名单已过 + Basic Auth 已过)
  return proxyAdmin(req, res);
});

const server = app.listen(GATE_PORT, '0.0.0.0', () => {
  const actualPort = server.address().port;   // GATE_PORT=0 (test/random) 时取实际监听端口; 生产 7860 同值
  console.log(`[gate] listening on 0.0.0.0:${actualPort} -> 127.0.0.1:${OR_PORT}`);
});

function shutdown(sig) {
  if (shuttingDown) return;
  shuttingDown = true;
  console.log(`[gate] received ${sig}, shutting down (grace ${SHUTDOWN_GRACE_MS}ms)...`);
  server.close(() => { process.exit(0); });
  setTimeout(() => {
    console.error('[gate] forced exit after grace.');
    process.exit(1);
  }, SHUTDOWN_GRACE_MS).unref();
}
process.on('SIGTERM', () => shutdown('SIGTERM'));
process.on('SIGINT', () => shutdown('SIGINT'));

```

## init-nim-keys.sh

```sh
#!/bin/bash
set -eo pipefail

# ─────────────────────────────────────────────────────────────
# NIM OmniRoute initializer  v4.2.3（基于 v4.2.2）
# 相对 v4.2.2 的变更：
#   【v4.2.3·⑨ 】DEBUG log 上传 Dataset: 默认**关闭** (NIM_DEBUG_LOG_TO_DATASET=1 开启);
#              开启时上传前字段级脱敏 Authorization/NIM_KEY/Cookie/Set-Cookie (红线1 动态);
#              本地仅留最近 NIM_DEBUG_LOG_KEEP(默认5) 个.
#              v4.3 改: 默认关 (原 v4.2.3 默认开违红线1 动态; B2 9a1a7f0 精简方向降写 Dataset).
# 继承 v4.2.2：⑦ 幂等 upsert_combo ⑧ 增量门放宽（任一 nim-* combo 或 INIT_MARKER）。
# 继承 v4.2.1：① 移除 quota-share/主池 p2c+白名单 ② nim-codex 响应体打印
#              ⑤ 增量只清过期熔断 ⑥ context_recommendations 累积推荐（被动观测）。
# ─────────────────────────────────────────────────────────────

# ══ 单变量调试 + 日志归档（stdout 实时 tee；DEBUG 时另上传 Dataset，见⑨）═══════
NIM_MODE="${NIM_MODE:-NORMAL}"
LOG_DIR="/data/omni-data/log"
if [ "$NIM_MODE" = "DEBUG" ]; then
  mkdir -p "$LOG_DIR" 2>/dev/null || true
  INIT_LOG="$LOG_DIR/init_$(date +%Y%m%d_%H%M%S).log"
  exec > >(tee -a "$INIT_LOG") 2>&1
  echo "[init] 🛠️ NIM_MODE=DEBUG：日志 tee -> $INIT_LOG（仅容器内，随 Space 日志可见，不入 Dataset）"
  export APP_LOG_TO_FILE=true
  export DISABLE_SQLITE_AUTO_BACKUP=true
else
  LOG_DIR="/tmp"
fi
_resp() { echo "$LOG_DIR/$1"; }

# ── 强制关闭代理生态 ──────────────────────────────────────────
export ONEPROXY_ENABLED=false
export ENABLE_SOCKS5_PROXY=false
export NEXT_PUBLIC_ENABLE_SOCKS5_PROXY=false
unset HTTP_PROXY HTTPS_PROXY ALL_PROXY http_proxy https_proxy all_proxy 2>/dev/null || true
unset OMNIROUTE_RELAY_BACKEND BIFROST_BASE_URL 2>/dev/null || true

# ── 端口配置 ──────────────────────────────────────────────────
[ -z "$OMNIROUTE_PORT" ] && OMNIROUTE_PORT=20128
BASE_URL="http://127.0.0.1:$OMNIROUTE_PORT"
INIT_MARKER="/data/.init-done"
OR_API_KEY_FILE="/data/.or-api-key"
COOKIE_FILE="/tmp/omniroute-cookie.txt"

LOGIN_RESP_FILE="$(_resp omniroute-login.json)"
KEY_RESP_FILE="$(_resp omniroute-key-response.json)"
PROVIDERS_FILE="$(_resp omniroute-providers.json)"
RESILIENCE_RESP_FILE="$(_resp omniroute-resilience.json)"
SETTINGS_RESP_FILE="$(_resp omniroute-settings.json)"
COMPRESS_RESP_FILE="$(_resp omniroute-compress.json)"
COMBO_RESP_FILE="$(_resp omniroute-combo.json)"
VERSION_FILE="$(_resp omniroute-version.json)"

REGISTERED=0; SKIPPED=0; FAILED=0

# ══ 模型分档 SSOT（对齐现行 NVIDIA 目录）═══════════════════════
TIER_FAST=(
  "z-ai/glm-5.2"
  "deepseek-ai/deepseek-v4-flash"
  "deepseek-ai/deepseek-v4-pro"
  "meta/llama-3.3-70b-instruct"
)
TIER_STABLE=(
  "nvidia/nemotron-3-super-120b-a12b"
  "openai/gpt-oss-120b"
  "qwen/qwen3.5-397b-a17b"
  "mistralai/mistral-small-4-119b-2603"
  "google/gemma-4-31b-it"
)
TIER_RESTRICTED=(
  "moonshotai/kimi-k2.6"
  "minimaxai/minimax-m2.7"
  "mistralai/mistral-large-3-675b-instruct-2512"
)

_PROFILE="${NIM_PROFILE:-balanced}"
case "$_PROFILE" in
  fast)     NIM_POOL_MODELS=("${TIER_FAST[@]}") ;;
  full)     NIM_POOL_MODELS=("${TIER_FAST[@]}" "${TIER_STABLE[@]}" "${TIER_RESTRICTED[@]}") ;;
  *)        _PROFILE="balanced"; NIM_POOL_MODELS=("${TIER_FAST[@]}" "${TIER_STABLE[@]}") ;;
esac
echo "[init] NIM_PROFILE=$_PROFILE -> pool 意向 ${#NIM_POOL_MODELS[@]} 个模型"

NIM_CODEX_MODELS=(
  "deepseek-ai/deepseek-v4-pro"
  "openai/gpt-oss-120b"
  "z-ai/glm-5.2"
)
NIM_FAST_MODELS=(
  "deepseek-ai/deepseek-v4-flash"
  "meta/llama-3.3-70b-instruct"
  "google/gemma-4-31b-it"
)
NIM_EXTRA_MODELS=( "deepseek-ai/deepseek-v4-flash" )

build_all_models() {
  printf '%s
' "${NIM_POOL_MODELS[@]}" "${NIM_CODEX_MODELS[@]}" "${NIM_EXTRA_MODELS[@]}" | awk '!seen[$0]++'
}
models_to_json() { printf '%s\n' "$@" | sed 's/^/nvidia\//' | jq -R '{model: .}' | jq -s -c .; }

# ══ combo 策略白名单（3.8.43 实测合法枚举，不含 quota-share）═════
_VALID_STRATS="priority weighted round-robin fill-first p2c random least-used cost-optimized reset-aware reset-window headroom strict-random auto lkgp context-optimized fusion"
# v4.3: 删 context-relay (CF-1/红线: NIM 永不用 context-relay; cf-worker 已删, 无外部 Relay 层); 保留 fusion (Codex 池可用).
_is_valid_strat() { printf '%s' "$_VALID_STRATS" | grep -qw -- "$1"; }

# ══ 【⑦ 】幂等 upsert：存在则 PUT，不存在才 POST ═══════════════
upsert_combo() {
  local NAME="$1" STRAT="$2"; shift 2; local MODELS=("$@")
  _is_valid_strat "$STRAT" || { echo "[init] upsert_combo: '$STRAT' 非法 -> round-robin"; STRAT="round-robin"; }
  [ "${#MODELS[@]}" -eq 0 ] && { echo "[init] upsert_combo: $NAME 无存活模型，跳过。"; return 0; }
  local BODY CID CODE F
  BODY=$(jq -n --arg name "$NAME" --arg strat "$STRAT" \
               --argjson models "$(models_to_json "${MODELS[@]}")" \
               '{name:$name, strategy:$strat, models:$models}')
  CID=$(curl -s -b "$COOKIE_FILE" "$BASE_URL/api/combos" \
        | jq -r --arg n "$NAME" '.combos[]? // .[]? | select(.name==$n) | .id' | head -n1)
  F="$(_resp omniroute-combo-$NAME.json)"
  if [ -n "$CID" ]; then
    CODE=$(curl -s -o "$F" -w "%{http_code}" -b "$COOKIE_FILE" \
      -X PUT "$BASE_URL/api/combos/$CID" -H "Content-Type: application/json" -d "$BODY")
    echo "[init] upsert $NAME: existed -> PUT combos/$CID HTTP $CODE"
  else
    CODE=$(curl -s -o "$F" -w "%{http_code}" -b "$COOKIE_FILE" \
      -X POST "$BASE_URL/api/combos" -H "Content-Type: application/json" -d "$BODY")
    echo "[init] upsert $NAME: new -> POST HTTP $CODE"
  fi
  [ "$CODE" != "200" ] && [ "$CODE" != "201" ] && cat "$F" || true
}

# ══ 按存活 Key 数动态推导 RPM/并发 ═════════════════════════════
_count_alive_keys() { printf '%s
' "$NIM_KEYS" | sed '/^[[:space:]]*$/d' | wc -l; }
_ALIVE_KEYS=$(_count_alive_keys)
# v4.3: 限流固定值 (G3 解: 限流仅 OmniRoute requestQueue 执行, 非线性扩; M26 REJECT 按 Key 线性).
# 候选固定 28 RPM / 1 并发 / 2200ms, 写 requestQueue; Gate 不重复限流 (gate.js 零限流代码).
_PER_KEY_RPM=${NIM_PER_KEY_RPM:-35}   # 单 Key 上限 (仅诊断用, 不入 requestQueue.RPM 算式)
_RPM=${NIM_FIXED_RPM:-28}              # 固定 28 RPM (G3)
_CONCURRENT=${NIM_FIXED_CONCURRENT:-1} # 固定 1 并发 (G3)
_MIN_INTERVAL_MS=${NIM_FIXED_MIN_INTERVAL_MS:-2200}   # 固定 2200ms (G3)
echo "[init] 固定限流 RPM=$_RPM concurrent=$_CONCURRENT interval=${_MIN_INTERVAL_MS}ms (alive_keys=$_ALIVE_KEYS 仅诊断)"

if [ "$_ALIVE_KEYS" -gt 1 ]; then
  _POOL_STRATEGY="${NIM_POOL_STRATEGY:-p2c}"
else
  _POOL_STRATEGY="round-robin"
fi
_is_valid_strat "$_POOL_STRATEGY" || { echo "[init] WARN: pool strategy '$_POOL_STRATEGY' 非法，回退 round-robin"; _POOL_STRATEGY="round-robin"; }
# FIX #4: codex strategy=priority for code generation scenarios.
# round-robin rotates model each turn — unsuitable for coding (上下文连续性丢失).
# 改默认 :-priority; env NIM_CODEX_STRATEGY 可覆盖 (如需 round-robin 传 NIM_CODEX_STRATEGY=round-robin).
_CODEX_STRATEGY="${NIM_CODEX_STRATEGY:-priority}"
_is_valid_strat "$_CODEX_STRATEGY" || { echo "[init] WARN: codex strategy '$_CODEX_STRATEGY' 非法，回退 priority"; _CODEX_STRATEGY="priority"; }
_FALLBACK_STRATEGY="round-robin"
_STICKY_LIMIT=1
_COMPRESS_THRESHOLD=${NIM_COMPRESS_THRESHOLD:-12000}
_COMPRESS_MODE="stacked"
_NIM_REAL_CONTEXT=${CONTEXT_LENGTH_DEFAULT:-32768}
echo "[init] pool strategy=$_POOL_STRATEGY | codex strategy=$_CODEX_STRATEGY"

# ── body limit 归一 ───────────────────────────────────────────
_RAW_BODY_LIMIT=${NIM_REQUEST_BODY_LIMIT:-1}
if [ "$_RAW_BODY_LIMIT" -gt 500 ] 2>/dev/null; then
  _REQUEST_BODY_LIMIT_MB=$(( _RAW_BODY_LIMIT / 1048576 ))
  [ "$_REQUEST_BODY_LIMIT_MB" -lt 1 ] && _REQUEST_BODY_LIMIT_MB=1
elif [ "$_RAW_BODY_LIMIT" -lt 1 ] 2>/dev/null; then
  _REQUEST_BODY_LIMIT_MB=1
else
  _REQUEST_BODY_LIMIT_MB=$_RAW_BODY_LIMIT
fi
[ "$_REQUEST_BODY_LIMIT_MB" -gt 500 ] 2>/dev/null && _REQUEST_BODY_LIMIT_MB=500
echo "[init] body limit: raw=$_RAW_BODY_LIMIT -> maxBodySizeMb=$_REQUEST_BODY_LIMIT_MB"

_PURGE_PROXY=${NIM_PURGE_PROXY:-1}
_PROXY_RELAY_HOST=${NIM_PROXY_RELAY_HOST:-127.0.0.1}
_PROXY_RELAY_PORT=${NIM_PROXY_RELAY_PORT:-20129}
_DB_PATH="${DATA_DIR:-/data}/storage.sqlite"
sql_escape() { printf '%s' "$1" | sed "s/'/''/g"; }

# int 范围校验器 (供 Resilience PATCH 白名单构造): $1=值 $2=下限(int) $3=上限(int); 返回 0 合格, 1 不合格
_res_validate_int() {
  [ -z "$1" ] && return 1
  case "$1" in
    ''|*[!0-9-]*) return 1 ;;   # 非数字 (允许负号作前缀, 实际范围校验拦截)
  esac
  [ "$1" -ge "$2" ] 2>/dev/null && [ "$1" -le "$3" ] 2>/dev/null || return 1
  return 0
}

purge_proxy_db() {
  [ "$_PURGE_PROXY" != "1" ] && { echo "[init] purge_proxy_db: skipped."; return 0; }
  local LIST_JSON
  LIST_JSON=$(curl -s -b "$COOKIE_FILE" "$BASE_URL/api/v1/management/proxies" 2>/dev/null || echo "")
  if [ -n "$LIST_JSON" ] && printf '%s' "$LIST_JSON" | jq -e . >/dev/null 2>&1; then
    local BAD_IDS
    BAD_IDS=$(printf '%s' "$LIST_JSON" | jq -r --arg h "$_PROXY_RELAY_HOST" --argjson p "$_PROXY_RELAY_PORT" \
      '(.proxies // .data // .) | (if type=="array" then . else [] end)
       | .[] | select((.host==$h) and ((.port|tonumber?)==$p)) | .id' 2>/dev/null)
    if [ -n "$BAD_IDS" ]; then
      local _id _c
      while IFS= read -r _id; do
        [ -z "$_id" ] && continue
        _c=$(curl -s -o /dev/null -w "%{http_code}" -b "$COOKIE_FILE" \
          -X DELETE "$BASE_URL/api/v1/management/proxies?id=${_id}&force=1" 2>/dev/null || echo "000")
        echo "[init] purge: API force-delete $_id -> HTTP $_c"
      done <<< "$BAD_IDS"
    else
      echo "[init] purge: 注册表无 ${_PROXY_RELAY_HOST}:${_PROXY_RELAY_PORT}。"
    fi
  else
    echo "[init] purge: 管理 API 暂不可用，走 SQL 兜底。"
  fi
  if [ -f "$_DB_PATH" ]; then
    sqlite3 "$_DB_PATH" "DELETE FROM proxy_assignments WHERE proxy_id IN
      (SELECT id FROM proxy_registry WHERE host='$(sql_escape "$_PROXY_RELAY_HOST")' AND port=$_PROXY_RELAY_PORT);" 2>/dev/null || true
    sqlite3 "$_DB_PATH" "UPDATE provider_connections SET proxy_enabled=0 WHERE provider='nvidia';" 2>/dev/null || true
    sqlite3 "$_DB_PATH" "DELETE FROM proxy_registry WHERE host='$(sql_escape "$_PROXY_RELAY_HOST")' AND port=$_PROXY_RELAY_PORT;" 2>/dev/null || true
    local _reg _asg _proxy_on
    _reg=$(sqlite3 "$_DB_PATH" "SELECT COUNT(*) FROM proxy_registry;" 2>/dev/null || echo "?")
    _asg=$(sqlite3 "$_DB_PATH" "SELECT COUNT(*) FROM proxy_assignments;" 2>/dev/null || echo "?")
    _proxy_on=$(sqlite3 "$_DB_PATH" "SELECT COUNT(*) FROM provider_connections WHERE provider='nvidia' AND proxy_enabled=1;" 2>/dev/null || echo "?")
    echo "[init] purge: registry=$_reg assignments=$_asg proxy_enabled=1剩余=$_proxy_on（期望 0/0/0）。"
  fi
}

check_nim_model_health() {
  echo "[init] check_nim_model_health..."
  > /tmp/nim-deprecated.txt
  local _first_key _models_json _model_count
  _first_key=$(printf '%s
' "$NIM_KEYS" | head -n1)
  _models_json=$(curl -s --max-time 10 -H "Authorization: Bearer ${_first_key}" \
    "https://integrate.api.nvidia.com/v1/models" 2>/dev/null || echo "")
  _model_count=$(printf '%s' "$_models_json" | jq -r '.data[]?.id' 2>/dev/null | wc -l)
  [ "${_model_count:-0}" -lt 5 ] && { echo "[init] only $_model_count models, skip 过滤"; return 0; }
  while IFS= read -r model; do
    [ -z "$model" ] && continue
    if ! printf '%s' "$_models_json" | jq -e --arg m "$model" 'any(.data[]?.id == $m; .)' >/dev/null 2>&1; then
      echo "[init]   $model — DEPRECATED（NVIDIA 目录无）"; echo "$model" >> /tmp/nim-deprecated.txt
    else
      [ "$NIM_MODE" = "DEBUG" ] && echo "[init]   $model — available"
    fi
  done < <(build_all_models)
  echo "[init] $(wc -l < /tmp/nim-deprecated.txt 2>/dev/null || echo 0) deprecated / $_model_count available"
}

filter_alive() {
  local out=() m
  for m in "$@"; do grep -Fxq "$m" /tmp/nim-deprecated.txt 2>/dev/null || out+=("$m"); done
  printf '%s
' "${out[@]}"
}

# ══ 【⑥+ 上下文累积判读】跨 call_logs 淘汰周期保留每模型成功/失败口径 ═══
# 背景：call_logs 表有 ~10 万行上限（trimCallLogsToMaxRows），旧日志被淘汰后
#       历史划定信号丢失。本节把"曾经跑通的最大 input"与"首次报错的最小 input"
#       沉降到 context_recommendations 表，跨淘汰周期保留，供自动标定 real_context。
# 约束：只读不写外部服务；checkpoint 存 key_value(namespace='monitor')；
#       ON CONFLICT DO UPDATE 保证 last_success_tokens 只增不减。
_context_acc_init_table() {
  [ ! -f "$_DB_PATH" ] && return 1
  sqlite3 "$_DB_PATH" "
    CREATE TABLE IF NOT EXISTS context_recommendations (
      model_id TEXT PRIMARY KEY,
      last_success_tokens INTEGER DEFAULT NULL,
      first_failure_tokens INTEGER DEFAULT NULL,
      success_samples INTEGER DEFAULT 0,
      failure_samples INTEGER DEFAULT 0,
      confidence TEXT DEFAULT 'insufficient',
      recommended_real_context INTEGER DEFAULT NULL,
      last_updated TEXT DEFAULT NULL
    );" 2>/dev/null || return 1
  return 0
}

# 探测 call_logs 的 input/output token 列名。3.8.43 实测 tokens_in/tokens_out；
# 兼容 input_tokens/in_tokens/total_input_tokens 等（探测命中即用）。
# 单次 PRAGMA（#4 合一：旧版 _detect_input_col/_detect_output_col 各跑一次，
# 对同一 call_logs 表重复打两次 PRAGMA table_info，合一省一次磁盘扫）。
# PRAGMA table_info 列序 cid|name|type|notnull|dflt|pk → 列名在 $2。
# 输出两行：第1行 input 列名、第2行 output 列名；未命中留空行。用两行而非 \t 分隔，
# 避免 IFS tab 空白折叠致列错位（Bug A 同类回归：仅 output 命中时前导 tab 被 read 剥离，
# output 列名错位落入 input 字段）。调用方按行读两变量。
_detect_io_cols() {
  sqlite3 "$_DB_PATH" "PRAGMA table_info(call_logs);" 2>/dev/null \
    | awk -F'|' '
        $2~/^tokens_in$|^input_tokens$|^in_tokens$|^total_input_tokens$/ {if(!ic) ic=$2}
        $2~/^tokens_out$|^output_tokens$|^out_tokens$|^total_output_tokens$/ {if(!oc) oc=$2}
        END{print ic; print oc}'
}

# 增量更新：读 checkpoint -> 查 id>checkpoint 新日志 -> 累积 -> 落表 -> 推 checkpoint
context_accumulator_update() {
  echo "[init] context_accumulator_update: 增量累积每模型成功/失败口径..."
  [ ! -f "$_DB_PATH" ] && { echo "[init]   no DB, skip."; return 0; }
  _context_acc_init_table || { echo "[init]   建表失败，skip。"; return 0; }

  local _has_tbl
  _has_tbl=$(sqlite3 "$_DB_PATH" "SELECT name FROM sqlite_master WHERE type='table' AND name='call_logs';" 2>/dev/null || echo "")
  [ -z "$_has_tbl" ] && { echo "[init]   call_logs 不存在（无流量），预约表就绪。"; return 0; }

  # 列名探测（单次 PRAGMA 两行输出，失败则兜默认/跳过）
  local _input_col _output_col _io
  _io=$(_detect_io_cols)
  _input_col=$(printf '%s' "$_io" | sed -n '1p')
  _output_col=$(printf '%s' "$_io" | sed -n '2p')
  [ -z "$_input_col" ] && { echo "[init]   WARN: call_logs 无已知 input token 列，skip。"; return 0; }
  [ -z "$_output_col" ] && _output_col="tokens_out"
  echo "[init]   列探测 input=$_input_col output=$_output_col"

  # checkpoint：call_logs.id 是 TEXT(UUID) 无数值序，改用 timestamp 串比较
  # ISO-8601 字典序 == 时间序；checkpoint str 存 key_value(monitor/ctx_last_log_ts)
  local _ckpt_key="ctx_last_log_ts" _last_ts _new_max_ts
  _last_ts=$(sqlite3 "$_DB_PATH" "SELECT value FROM key_value WHERE namespace='monitor' AND key='$(sql_escape "$_ckpt_key")';" 2>/dev/null || echo "")
  [ -z "$_last_ts" ] && _last_ts="1970-01-01T00:00:00.000Z"
  echo "[init]   checkpoint last_ts=$_last_ts"

  # 成功：status 2xx 且 output>0；
  # 失败：status>=500、status=413（context/body 过大，上游 chatBodyAdmission 对 oversized 发 413）、
  #       或 (2xx 且 output=0)。
  # 不纳 401/403/429：鉴权/限频信号会污染 first_failure_tokens。
  # 按模型分桶累积 MAX(成功 input) / MIN(失败 input)，并累计 samples
  local _q
  _q="
    SELECT
      model                                                   AS mid,
      MAX(CASE WHEN status BETWEEN 200 AND 299 AND ${_output_col}>0
               THEN ${_input_col} END)                        AS suc_max,
      MIN(CASE WHEN (status>=500) OR (status=413) OR (status BETWEEN 200 AND 299 AND ${_output_col}=0)
               THEN ${_input_col} END)                        AS fail_min,
      SUM(CASE WHEN status BETWEEN 200 AND 299 AND ${_output_col}>0 THEN 1 ELSE 0 END) AS suc_n,
      SUM(CASE WHEN (status>=500) OR (status=413) OR (status BETWEEN 200 AND 299 AND ${_output_col}=0) THEN 1 ELSE 0 END) AS fail_n,
      MAX(timestamp)                                          AS max_ts
    FROM call_logs
    WHERE provider='nvidia' AND timestamp > '$(sql_escape "$_last_ts")'
      AND model LIKE '%/%' AND model != 'model-sync'
    GROUP BY model;"

  local _rows _cnt=0
  _rows=$(sqlite3 -separator $'\t' "$_DB_PATH" "$_q" 2>/dev/null || echo "")
  if [ -z "$_rows" ]; then echo "[init]   本轮无新日志（timestamp > checkpoint）。"; return 0; fi

  # #1 根因：IFS=$'\t' read 把 tab 当 IFS 空白类——折叠加空字段、剥离前导 tab，
  # 一旦某列（model 或中间 suc_max/fail_min）NULL→空串，6 列被折叠成 <6 段，
  # max_ts 串错位落入 _fail_n，进 $(( )) 触发八进制解析（error token "09T22"）。
  # 修复：改用 mapfile -t -d $'\t' 数组逐字段拆行，保留空字段、不折叠不剥离首，
  # 6 索引严格对齐 SQL 列序；数字列空时兜 0。
  local _line _mid _suc_max _fail_min _suc_n _fail_n _max_ts
  while IFS= read -r _line; do
    local _acc=(); mapfile -t -d $'\t' _acc <<<"$_line"
    _mid=${_acc[0]}; _suc_max=${_acc[1]}; _fail_min=${_acc[2]}
    _suc_n=${_acc[3]}; _fail_n=${_acc[4]}; _max_ts=${_acc[5]}
    [ -z "$_mid" ] && continue
    # ON CONFLICT DO UPDATE：last_success 只增不减（取 MAX(旧,新)），
    # first_failure 只减不增（取 COALESCE(MIN,旧)）。samples 累加。
    local _rec_real _conf _new_total
    _new_total=$(( (${_suc_n:-0} + ${_fail_n:-0}) ))
    sqlite3 "$_DB_PATH" "
      INSERT INTO context_recommendations (model_id, last_success_tokens, first_failure_tokens,
                                           success_samples, failure_samples, confidence,
                                           recommended_real_context, last_updated)
      VALUES ('$(sql_escape "$_mid")',
              $([ -n "$_suc_max" ] && echo "$_suc_max" || echo 'NULL'),
              $([ -n "$_fail_min" ] && echo "$_fail_min" || echo 'NULL'),
              ${_suc_n:-0}, ${_fail_n:-0},
              'insufficient', NULL, datetime('now'))
      ON CONFLICT(model_id) DO UPDATE SET
        last_success_tokens = MAX(COALESCE(excluded.last_success_tokens, 0),
                                  COALESCE(context_recommendations.last_success_tokens, 0)),
        first_failure_tokens = CASE
          WHEN context_recommendations.first_failure_tokens IS NULL THEN excluded.first_failure_tokens
          WHEN excluded.first_failure_tokens IS NULL THEN context_recommendations.first_failure_tokens
          ELSE MIN(excluded.first_failure_tokens, context_recommendations.first_failure_tokens)
        END,
        success_samples  = context_recommendations.success_samples  + excluded.success_samples,
        failure_samples  = context_recommendations.failure_samples  + excluded.failure_samples,
        last_updated     = datetime('now');" 2>/dev/null || continue

    # 推荐值 + 置信度：需历史累计样本，读回
    local _hist_suc_n _hist_fail_n _hist_suc _hist_fail
    _hist_suc_n=$(sqlite3 "$_DB_PATH" "SELECT success_samples FROM context_recommendations WHERE model_id='$(sql_escape "$_mid")';" 2>/dev/null || echo 0)
    _hist_fail_n=$(sqlite3 "$_DB_PATH" "SELECT failure_samples FROM context_recommendations WHERE model_id='$(sql_escape "$_mid")';" 2>/dev/null || echo 0)
    _hist_suc=$(sqlite3 "$_DB_PATH" "SELECT last_success_tokens FROM context_recommendations WHERE model_id='$(sql_escape "$_mid")';" 2>/dev/null || echo "")
    _hist_fail=$(sqlite3 "$_DB_PATH" "SELECT first_failure_tokens FROM context_recommendations WHERE model_id='$(sql_escape "$_mid")';" 2>/dev/null || echo "")

    local _total=$((_hist_suc_n + _hist_fail_n))
    if [ "$_total" -lt 10 ]; then _conf="insufficient"
    elif [ "$_total" -lt 50 ]; then _conf="low"
    elif [ "$_total" -lt 200 ]; then _conf="medium"
    else _conf="high"; fi

    # 推荐口径：有失败边界 → first_failure*0.85；否则 last_success*0.9
    if [ -n "$_hist_fail" ] && [ "$_hist_fail" -gt 0 ] 2>/dev/null; then
      _rec_real=$(( _hist_fail * 85 / 100 ))
    elif [ -n "$_hist_suc" ] && [ "$_hist_suc" -gt 0 ] 2>/dev/null; then
      _rec_real=$(( _hist_suc * 90 / 100 ))
    else
      _rec_real=""
    fi

    # ⚠️ confidence='$_conf' 必须用变量展开；早期 '$(_conf)' 是命令替换误用——
    # bash 执行命令 _conf → "command not found" → confidence 写空 → 下游 #2 回写
    # WHERE confidence IN ('medium','high') 不命中 → monitor+manual 行数恒 0。
    sqlite3 "$_DB_PATH" "
      UPDATE context_recommendations
      SET confidence='$_conf',
          recommended_real_context=$([ -n "$_rec_real" ] && echo "$_rec_real" || echo 'NULL')
      WHERE model_id='$(sql_escape "$_mid")';" 2>/dev/null || true
    _cnt=$((_cnt+1))
  done <<< "$_rows"

  # token 成功 only 增不减已由 ON CONFLICT 保证；checkpoint 推到本轮 max_ts
  _new_max_ts=$(printf '%s\n' "$_rows" | awk -F'\t' -v OFS='\t' '{print $6}' | sort | tail -n1)
  [ -n "$_new_max_ts" ] && sqlite3 "$_DB_PATH" "
    INSERT INTO key_value (namespace, key, value) VALUES ('monitor', '$(sql_escape "$_ckpt_key")', '$(sql_escape "$_new_max_ts")')
    ON CONFLICT(namespace, key) DO UPDATE SET value = excluded.value;" 2>/dev/null \
    && echo "[init]   checkpoint -> ctx_last_log_ts=$_new_max_ts"
  echo "[init]   累积更新 ${_cnt} 个模型。"

  # v4.3: 自动回写 context_recommendations → model_context_overrides 整段删除 (CF-2 + M30 REJECT).
  # 原实现 (B1 enabled, B2 注释禁) 直写 model_context_overrides 绕过 API/校验 → 违红线; 整段删 (非注释保留).
  # 自动 Context Override 默认关闭 (CF-4); 启用路径见 KNOWN-UNVERIFIED (API PATCH max_input_tokens + 读回).

  # 【⑥+ 】累积推荐表输出（跨 call_logs 淘汰周期保留的口径）。
  # 表输出与聚合同函数：context_accumulator_update 每轮增量/first-init 结束即打印当前推荐全表，
  # 属被动观测（不触发任何写入）；原 nim_health_pick 仅"本次推荐主力(按分档)"部分已移除。
  local _acc_rows
  _acc_rows=$(sqlite3 -separator '|' "$_DB_PATH" "
    SELECT model_id,
           COALESCE(last_success_tokens,'-'),
           COALESCE(first_failure_tokens,'-'),
           (success_samples||'/'||failure_samples),
           confidence,
           COALESCE(recommended_real_context,'-')
    FROM context_recommendations
    ORDER BY CASE confidence WHEN 'high' THEN 0 WHEN 'medium' THEN 1
             WHEN 'low' THEN 2 ELSE 3 END, model_id;" 2>/dev/null || echo "")
  if [ -z "$_acc_rows" ]; then
    echo "[init] （累积推荐表为空：尚无成功/失败样本）"
  else
    echo "[init] ═══累积 real_context 推荐（跨淘汰周期保留）═══"
    echo "[init]   model | last_ok | first_fail | ok/fail_n | conf | rec_ctx"
    while IFS='|' read -r _m _ok _fail _n _c _r; do
      [ -z "$_m" ] && continue
      printf '[init]   %s | %s | %s | %s | %s | %s\n' "$_m" "$_ok" "$_fail" "$_n" "$_c" "$_r"
    done <<< "$_acc_rows"
    echo "[init] ═════════════════════════════════════════"
  fi
}

# ══════════════════════════════════════════════════════════════
echo "[init] Starting NIM OmniRoute initializer v4.2.3 (profile=$_PROFILE, mode=$NIM_MODE)..."
echo "[init] BASE_URL=$BASE_URL"

[ -z "$INITIAL_PASSWORD" ] && { echo "[init] ERROR: INITIAL_PASSWORD required"; exit 1; }
[ -z "$NIM_KEYS" ] && { echo "[init] ERROR: NIM_KEYS required"; exit 1; }

echo "[init] Waiting for OmniRoute..."
HWAIT=0
until curl -sf "$BASE_URL/api/monitoring/health" > /dev/null 2>&1; do
  sleep 3; HWAIT=$((HWAIT + 3))
  [ "$HWAIT" -ge 180 ] && { echo "[init] FATAL: not ready within 180s"; exit 1; }
done
echo "[init] OmniRoute up (after ${HWAIT}s)."

VERSION_HTTP=$(curl -s -o "$VERSION_FILE" -w "%{http_code}" "$BASE_URL/api/monitoring/health" 2>/dev/null || echo "000")
[ "$VERSION_HTTP" = "200" ] && echo "[init] version: $(jq -r '.version // "unknown"' "$VERSION_FILE" 2>/dev/null)"

echo "[init] Logging in..."
LOGIN_BODY=$(jq -n --arg password "$INITIAL_PASSWORD" '{password: $password}')
LOGIN_HTTP=$(curl -s -o "$LOGIN_RESP_FILE" -w "%{http_code}" -c "$COOKIE_FILE" \
  -X POST "$BASE_URL/api/auth/login" -H "Content-Type: application/json" -d "$LOGIN_BODY")
[ "$LOGIN_HTTP" != "200" ] && [ "$LOGIN_HTTP" != "201" ] && { echo "[init] ERROR login HTTP $LOGIN_HTTP"; cat "$LOGIN_RESP_FILE" || true; exit 1; }
grep -q "auth_token" "$COOKIE_FILE" 2>/dev/null || { echo "[init] ERROR no auth_token"; exit 1; }
echo "[init] Logged in."

purge_proxy_db

resolve_or_key() {
  printf '%s' "${OMNIROUTE_API_KEY:-$(cat "$OR_API_KEY_FILE" 2>/dev/null)}" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//'
}

if [ -n "$OMNIROUTE_API_KEY" ]; then
  OR_KEY="$(printf '%s' "$OMNIROUTE_API_KEY" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
  [ -z "$OR_KEY" ] && { echo "[init] FATAL: OMNIROUTE_API_KEY blank"; exit 1; }
  echo "$OR_KEY" > "$OR_API_KEY_FILE" 2>/dev/null || echo "[init] WARN write $OR_API_KEY_FILE failed"
  chmod 600 "$OR_API_KEY_FILE" 2>/dev/null || true
  echo "[init] OMNIROUTE_API_KEY env set, skip /api/keys."
elif [ -f "$OR_API_KEY_FILE" ] && [ -s "$OR_API_KEY_FILE" ]; then
  OR_KEY="$(cat "$OR_API_KEY_FILE" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
  echo "[init] OR_API_KEY file exists."
else
  echo "[init] Creating OmniRoute API Key..."
  KEY_BODY=$(jq -n --arg name "gate-internal" '{name: $name, expiresAt: null}')
  KEY_HTTP=$(curl -s -o "$KEY_RESP_FILE" -w "%{http_code}" -b "$COOKIE_FILE" \
    -X POST "$BASE_URL/api/keys" -H "Content-Type: application/json" -d "$KEY_BODY")
  if [ "$KEY_HTTP" = "200" ] || [ "$KEY_HTTP" = "201" ]; then
    OR_API_KEY_VALUE=$(jq -r '.key // empty' "$KEY_RESP_FILE")
    [ -z "$OR_API_KEY_VALUE" ] && { echo "[init] ERROR parse key"; exit 1; }
    echo "$OR_API_KEY_VALUE" > "$OR_API_KEY_FILE"; chmod 600 "$OR_API_KEY_FILE"; OR_KEY="$OR_API_KEY_VALUE"
    echo "[init] OR_API_KEY written."
  else
    echo "[init] ERROR /api/keys HTTP $KEY_HTTP"; exit 1
  fi
fi

echo "[init] Registering NIM keys..."
INDEX=1
while IFS= read -r RAW_KEY; do
  KEY=$(printf '%s' "$RAW_KEY" | tr -d '' | xargs)
  [ -z "$KEY" ] && continue
  NAME=$(printf "nim-%02d" "$INDEX")
  RESP_FILE="$(_resp omniroute-provider-$INDEX.json)"
  BODY=$(jq -n --arg provider "nvidia" --arg apiKey "$KEY" --arg name "$NAME" \
    '{provider:$provider, apiKey:$apiKey, name:$name, priority:1, testStatus:"unknown"}')
  HTTP_CODE=$(curl -s -o "$RESP_FILE" -w "%{http_code}" -b "$COOKIE_FILE" \
    -X POST "$BASE_URL/api/providers" -H "Content-Type: application/json" -d "$BODY")
  if [ "$HTTP_CODE" = "201" ] || [ "$HTTP_CODE" = "200" ]; then echo "[init] $NAME OK"; REGISTERED=$((REGISTERED+1))
  elif [ "$HTTP_CODE" = "409" ]; then echo "[init] $NAME exists"; SKIPPED=$((SKIPPED+1))
  else echo "[init] $NAME HTTP $HTTP_CODE"; cat "$RESP_FILE" || true; FAILED=$((FAILED+1)); fi
  INDEX=$((INDEX+1))
done <<< "$NIM_KEYS"
echo "[init] Keys: $REGISTERED registered, $SKIPPED skipped, $FAILED failed."

echo "[init] Fetching provider IDs..."
PROVIDERS_HTTP=$(curl -s -o "$PROVIDERS_FILE" -w "%{http_code}" -b "$COOKIE_FILE" "$BASE_URL/api/providers")
if [ "$PROVIDERS_HTTP" = "200" ]; then
  mapfile -t PROVIDER_IDS < <(jq -r '[.. | objects | select((.provider? // "")=="nvidia") | select((.id? // "")!="") | .id] | unique | .[]' "$PROVIDERS_FILE" 2>/dev/null)
fi
echo "[init] Provider IDs: ${#PROVIDER_IDS[@]}"

purge_proxy_db

echo "[init] Resilience (RPM=$_RPM, concurrent=$_CONCURRENT, interval=${_MIN_INTERVAL_MS}ms)..."

# ── 3.8.43 PATCH 白名单 (SSOT: src/app/api/resilience/route.ts:153 + schemas/settings.ts:131-180) ──
# updateResilienceSchema z.strict(): 顶层仅 requestQueue/connectionCooldown/providerBreaker/
#   waitForCooldown/comboCooldownWait/quotaShareConcurrencyLimit/providerCooldown/profiles/defaults.
# requestQueueSettingsSchema z.strict(): {requestsPerMinute int>=1, minTimeBetweenRequestsMs int>=0 (毫秒!),
#   concurrentRequests int>=1, autoEnableApiKeyProviders boolean, maxWaitMs int>=1}.
# useUpstream429BreakerHints 仅在 connectionCooldown.{oauth,apikey}.useUpstream429BreakerHints (boolean|null),
#   顶层该字段 → z.strict() 拒绝 → HTTP 400 (根因 #1 已证).
# 28  → requestQueue.requestsPerMinute (int, 单位 RPM)
#  1  → requestQueue.concurrentRequests (int, 单位=并发槽位数, 个)
# 2200→ requestQueue.minTimeBetweenRequestsMs (int, 单位=ms 毫秒, 2200ms=2.2s)
# PATCH = 部分更新 (mergeResilienceSettings), 非完整对象; 未传字段保留旧值.

# 显式白名单构造: 从空对象只复制 route.ts:309 接受字段, 禁 ...透传, 不发 undefined, 不发顶层 useUpstream429BreakerHints.
# 输入校验 (类型/范围) — 28∈[1,60000] RPM, 2200∈[0,600000] ms, 1∈[1,1000] 并发; 非法 init 失败 (不静默 SKIP)
if ! _res_validate_int "$_RPM" 1 60000 || ! _res_validate_int "$_MIN_INTERVAL_MS" 0 600000 || ! _res_validate_int "$_CONCURRENT" 1 1000; then
  echo "[init] ✗ Resilience 输入非法 (_RPM=$_RPM / _MIN_INTERVAL_MS=$_MIN_INTERVAL_MS / _CONCURRENT=$_CONCURRENT). init 失败."
  return 1 2>/dev/null || exit 1
fi
RESILIENCE_BODY=$(jq -nc \
  --argjson rpm "$_RPM" \
  --argjson minMs "$_MIN_INTERVAL_MS" \
  --argjson conc "$_CONCURRENT" \
  '{requestQueue:{requestsPerMinute:$rpm, minTimeBetweenRequestsMs:$minMs, concurrentRequests:$conc}}')
echo "[init] Resilience PATCH body keys=[$(echo "$RESILIENCE_BODY" | jq -rc 'keys|join(",")')] requestQueue.keys=[$(echo "$RESILIENCE_BODY" | jq -rc '.requestQueue|keys|join(",")')] (无顶层 useUpstream429BreakerHints)"

# 错误处理区分 HTTP 4xx/5xx vs transport error (根因 #2: status 空无原始异常 → 必留底层 error 信息)
_t0=$(date +%s%N 2>/dev/null || date +%s)
RESILIENCE_CODE=$(curl -s -o "$RESILIENCE_RESP_FILE" -w "%{http_code}" --connect-timeout 5 --max-time 20 \
  -b "$COOKIE_FILE" -X PATCH "$BASE_URL/api/resilience" -H "Content-Type: application/json" \
  -d "$RESILIENCE_BODY" 2>/tmp/res_patch.err)
res_curl_rc=$?
_t1=$(date +%s%N 2>/dev/null || date +%s)
_res_dur_ms=$(( (_t1 - _t0) / 1000000 ))
_res_dur_ms=$(( _res_dur_ms < 0 ? 0 : _res_dur_ms ))
_res_err=$(cat /tmp/res_patch.err 2>/dev/null | head -c 300)

if [ "$res_curl_rc" -ne 0 ] || [ -z "$RESILIENCE_CODE" ]; then
  # 没收到 HTTP 响应 (transport error / timeout / abort / DNS) — 保留底层异常信息
  echo "[init] ⚠️ Resilience PATCH transport-error: curl_rc=$res_curl_rc dur=${_res_dur_ms}ms"
  echo "[init]   curl_err: ${_res_err:-<empty>}"
  echo "[init]   abort_source: $( [ "$res_curl_rc" = 28 ] && echo 'request_timeout' || ([ "$res_curl_rc" = 7 ] && echo 'proxy_connect_failure' || echo 'curl_unknown') )"
  echo "[init]   不伪装成 HTTP 错误. 保留旧配置 (CF-4). PATCH 失败 → init 仍可继续其他步, 但 readiness 不得报告 resilience 健康."
  RESILIENCE_CODE="transport_err"
else
  echo "[init] Resilience PATCH HTTP $RESILIENCE_CODE (dur=${_res_dur_ms}ms)"
  case "$RESILIENCE_CODE" in
    200|201) : ;;   # 2xx ok
    *)
      # 收到 HTTP 响应但非 2xx — 记 status/body/path/字段名
      echo "[init] ⚠️ Resilience PATCH HTTP $RESILIENCE_CODE (收到响应): body=[$(head -c 500 "$RESILIENCE_RESP_FILE" 2>/dev/null)] path=/api/resilience"
      echo "[init]   fields_sent: $(echo "$RESILIENCE_BODY" | jq -rc '.requestQueue|keys|join(",")' 2>/dev/null)"
      ;;
  esac
fi

# Read-back: PATCH 成功后立即 GET 验 28/1/2200ms 全三字段 — 不一致 init 失败 (CF-4: 写必须读回)
if [ "$RESILIENCE_CODE" = "200" ] || [ "$RESILIENCE_CODE" = "201" ]; then
  _RB=$(curl -s --connect-timeout 5 --max-time 20 -b "$COOKIE_FILE" "$BASE_URL/api/resilience" 2>/tmp/res_get.err)
  res_get_rc=$?
  _res_get_err=$(cat /tmp/res_get.err 2>/dev/null | head -c 300)
  if [ "$res_get_rc" -ne 0 ] || [ -z "$_RB" ]; then
    echo "[init] ✗ Resilience GET 读回 transport-error: curl_rc=$res_get_rc err=${_res_get_err:-<empty>}"
    echo "[init]   abort_source: $( [ "$res_get_rc" = 28 ] && echo 'request_timeout' || ([ "$res_get_rc" = 7 ] && echo 'get_connect_failure' || echo 'get_unknown') )"
    echo "[init]   CF-4 约束: 写必须读回. 读回失败 → init 失败 (OmniRoute resilience 未确认达预期限流)."
    return 1 2>/dev/null || exit 1
  fi
  _RB_RPM=$(echo "$_RB" | jq -r '.requestQueue.requestsPerMinute // "null"' 2>/dev/null || echo "jq_fail")
  _RB_MINMS=$(echo "$_RB" | jq -r '.requestQueue.minTimeBetweenRequestsMs // "null"' 2>/dev/null || echo "jq_fail")
  _RB_CONC=$(echo "$_RB" | jq -r '.requestQueue.concurrentRequests // "null"' 2>/dev/null || echo "jq_fail")
  echo "[init] Resilience 读回: RPM=$_RB_RPM minMs=$_RB_MINMS concurrent=$_RB_CONC (预期 $_RPM/$_MIN_INTERVAL_MS/$_CONCURRENT)"
  # 严格逐字段验证三目标值; 任一不符 → init 失败 (不再仅 WARN)
  _mismatch=""
  [ "$_RB_RPM" != "$_RPM" ] && _mismatch="$_mismatch RPM($_RB_RPM!=$_RPM)"
  [ "$_RB_MINMS" != "$_MIN_INTERVAL_MS" ] && _mismatch="$_mismatch minTimeMs($_RB_MINMS!=$_MIN_INTERVAL_MS)"
  [ "$_RB_CONC" != "$_CONCURRENT" ] && _mismatch="$_mismatch concurrent($_RB_CONC!=$_CONCURRENT)"
  if [ -n "$_mismatch" ]; then
    echo "[init] ✗ Resilience 读回不一致:$_mismatch → init 失败 (CF-4: 限流配置未落定, 不能报告 ready)"
    return 1 2>/dev/null || exit 1
  fi
  echo "[init] ✓ Resilience 读回全字段一致 (28/1/2200ms 已落定)"
fi

echo "[init] Routing + maxBodySizeMb=$_REQUEST_BODY_LIMIT_MB..."
SETTINGS_CODE=$(curl -s -o "$SETTINGS_RESP_FILE" -w "%{http_code}" -b "$COOKIE_FILE" \
  -X PATCH "$BASE_URL/api/settings" -H "Content-Type: application/json" \
  -d "{\"fallbackStrategy\":\"$_FALLBACK_STRATEGY\",\"stickyRoundRobinLimit\":$_STICKY_LIMIT,\"requestRetry\":2,\"maxRetryIntervalSec\":5,\"maxBodySizeMb\":$_REQUEST_BODY_LIMIT_MB}")
echo "[init] Settings HTTP $SETTINGS_CODE"
[ "$SETTINGS_CODE" != "200" ] && [ "$SETTINGS_CODE" != "201" ] && { echo "[init] ⚠️ Settings 非 2xx："; cat "$SETTINGS_RESP_FILE" || true; }

echo "[init] Compression (threshold=$_COMPRESS_THRESHOLD)..."
curl -s -o "$COMPRESS_RESP_FILE" -w "%{http_code}
" -b "$COOKIE_FILE" \
  -X PUT "$BASE_URL/api/settings/compression" -H "Content-Type: application/json" \
  -d "{\"enabled\":true,\"defaultMode\":\"$_COMPRESS_MODE\",\"autoTriggerTokens\":$_COMPRESS_THRESHOLD}" | sed 's/^/[init] Compression HTTP /'

echo "[init] Resetting circuit breakers (first-init clean start)..."
curl -s -o /dev/null -w "[init] CB reset HTTP %{http_code}
" -b "$COOKIE_FILE" \
  -X POST "$BASE_URL/api/resilience/reset" -H "Content-Type: application/json"

# K5 FIX (审查裁定推荐选项 c):
# API PATCH /api/provider-models 在 3.8.43 源码中仅接受 isHidden 字段,
# 不接受 contextLength / max_input_tokens / max_output_tokens (B1 L2 源码实证:
# route.ts:309 强制 isHidden boolean; updateCustomModel models.ts:591 不处理
# max_tokens; 仅 POST add route.ts:109 接受 max_input/output_tokens).
# 候选此前删除 init 内部 per-model override 逻辑并指向 API PATCH 替代路径 →
# 该路径在源码层不存在, 候选 context override 会静默失败.
# 修复: 保留 init 内部的 per-model 32K override (apply_context_override, 42ea8e7
# 基线原态), 不删; 保留 4632e8c 的"禁用 monitor 自动回写"改动 (L407-409 已删
# monitor 回写段不动). API PATCH 路径在文档中标注为"3.8.43 不支持, 待源码新增
# PATCH 字段支持"——不作为候选 context override 配置路径.
# 自动回写 (confidence-based monitor → model_context_overrides) 仍保持禁用
# (CF-4): init 仅应用一次性 per-model 32768 override, 不跨周期自动标定.

# per-model 32K override (real_context=$_NIM_REAL_CONTEXT) — 42ea8e7 基线原态恢复.
echo "[init] per-model 32K override (real_context=$_NIM_REAL_CONTEXT)..."
OVERRIDE_APPLIED=0; OVERRIDE_SKIPPED=0
apply_context_override() {
  if sqlite3 "$_DB_PATH" \
    "INSERT OR REPLACE INTO model_context_overrides (provider, model_id, real_context, source, refreshed_at)
     VALUES ('nvidia', '$(sql_escape "$1")', $2, 'init', datetime('now'));" 2>/dev/null; then
    OVERRIDE_APPLIED=$((OVERRIDE_APPLIED+1))
  else OVERRIDE_SKIPPED=$((OVERRIDE_SKIPPED+1)); echo "[init]   override FAILED: $1"; fi
}
while IFS= read -r _M; do [ -z "$_M" ] && continue; apply_context_override "$_M" "$_NIM_REAL_CONTEXT"; done < <(build_all_models)
echo "[init] override: $OVERRIDE_APPLIED applied, $OVERRIDE_SKIPPED failed."
# K5 行为预期: init 启动时一次性应用 32K override (real_context=32768) 经 SQLite 直写
# model_context_overrides (source='init'), 不自动回写, 不调 API PATCH. 3.8.43 源码层
# 该直写路径与运行时 loadCustomModels 一致 (models.ts:591 读路径同表), 唯一可用.

echo "[init] ─────────────────────────────────────────────"
echo "[init]   PROFILE=$_PROFILE MODE=$NIM_MODE KEYS=$_ALIVE_KEYS RPM=$_RPM BODY=$_REQUEST_BODY_LIMIT_MB MB"
echo "[init]   POOL_STRATEGY=$_POOL_STRATEGY REAL_CONTEXT=$_NIM_REAL_CONTEXT (per-model 32K override 应用, monitor 自动回写禁用)"
echo "[init] ─────────────────────────────────────────────"

hf_snapshot() {
  [ -z "$HF_TOKEN" ] || [ -z "$HF_DATASET_REPO" ] && return 0
  echo "[init] HF Dataset snapshot（配置 + 可选 DEBUG log）..."
  local BACKUP_DIR="/tmp/omni-snapshot"; mkdir -p "$BACKUP_DIR"
  local OR_KEY; OR_KEY="$(resolve_or_key)"
  curl -sf "$BASE_URL/api/settings/export-json" -H "Authorization: Bearer $OR_KEY" \
    | jq 'del(.usageHistory, .domainCostHistory, .domainBudgets) |
          (if (.apiKeys|type)=="array" then .apiKeys |= map(del(.key)) else . end) |
          (if (.providerConnections|type)=="array" then .providerConnections |= map(del(.credentials)) else . end)' \
    > "$BACKUP_DIR/omni_config.json"
  jq '.apiKeys' "$BACKUP_DIR/omni_config.json" > "$BACKUP_DIR/keys.json"
  jq '.providerConnections' "$BACKUP_DIR/omni_config.json" > "$BACKUP_DIR/providerConnections.json"
  jq '.settings' "$BACKUP_DIR/omni_config.json" > "$BACKUP_DIR/settings.json"
  jq '.combos' "$BACKUP_DIR/omni_config.json" > "$BACKUP_DIR/combos.json"

  # ── 【⑥+ 】init_vars.json：把脚本运行时变量（profile/TIER/RPM/策略/口径）随快照上传 ──
  #   目的：HF Dataset 侧可回溯本空间的真实初始化参数，无需翻容器日志。
  _arr_json() { # bash 数组 -> JSON 字符串数组（jq 正规转义，防 \"/\\ 破坏 JSON）
    [ "$#" -eq 0 ] && { printf '[]'; return; }
    printf '%s\n' "$@" | jq -R . | jq -s -c .
  }
  { jq -n \
      --arg version "4.2.3" \
      --arg profile "$_PROFILE" \
      --arg mode "$NIM_MODE" \
      --argjson tier_fast "$(_arr_json "${TIER_FAST[@]}")" \
      --argjson tier_stable "$(_arr_json "${TIER_STABLE[@]}")" \
      --argjson tier_restricted "$(_arr_json "${TIER_RESTRICTED[@]}")" \
      --argjson pool_models "$(_arr_json "${NIM_POOL_MODELS[@]}")" \
      --argjson codex_models "$(_arr_json "${NIM_CODEX_MODELS[@]}")" \
      --argjson fast_models "$(_arr_json "${NIM_FAST_MODELS[@]}")" \
      --arg alive_keys "$_ALIVE_KEYS" \
      --arg rpm "$_RPM" \
      --arg concurrent "$_CONCURRENT" \
      --arg min_interval_ms "$_MIN_INTERVAL_MS" \
      --arg pool_strategy "$_POOL_STRATEGY" \
      --arg codex_strategy "$_CODEX_STRATEGY" \
      --arg fallback_strategy "$_FALLBACK_STRATEGY" \
      --arg real_context "$_NIM_REAL_CONTEXT" \
      --arg body_limit_mb "$_REQUEST_BODY_LIMIT_MB" \
      --arg compress_threshold "$_COMPRESS_THRESHOLD" \
      --arg per_key_rpm "${_PER_KEY_RPM}" \
      '{version:$version, profile:$profile, mode:$mode,
        tiers:{fast:$tier_fast, stable:$tier_stable, restricted:$tier_restricted},
        pools:{pool:$pool_models, codex:$codex_models, fast:$fast_models},
        dynamic_rpm:{alive_keys:($alive_keys|tonumber), rpm:($rpm|tonumber),
                     concurrent:($concurrent|tonumber), min_interval_ms:($min_interval_ms|tonumber),
                     per_key_rpm:($per_key_rpm|tonumber)},
        strategies:{pool:$pool_strategy, codex:$codex_strategy, fallback:$fallback_strategy},
        context:{real_context:($real_context|tonumber)},
        limits:{body_mb:($body_limit_mb|tonumber), compress_threshold:($compress_threshold|tonumber)}}'; } > "$BACKUP_DIR/init_vars.json" \
    && echo "[init] snapshot: init_vars.json written" \
    || echo "[init] snapshot: WARN init_vars.json 写入失败"

  # ── 【v4.2.3·⑨ 】DEBUG log 上传到 Dataset（debug_<时间戳>.log）──
  #   仅 DEBUG 模式 + 显式开启 (NIM_DEBUG_LOG_TO_DATASET=1) + INIT_LOG 存在时; **默认关闭** (v4.3 红线1 动态).
  #   上传前字段级脱敏: Authorization/NIM_KEY/Cookie/Set-Cookie/Bearer 替换为 <REDACTED>.
  #   同时本地只保留最近 NIM_DEBUG_LOG_KEEP(默认5) 个。
  if [ "$NIM_MODE" = "DEBUG" ] && [ "${NIM_DEBUG_LOG_TO_DATASET:-0}" = "1" ] && [ -n "$INIT_LOG" ] && [ -f "$INIT_LOG" ]; then
    local _keep=${NIM_DEBUG_LOG_KEEP:-5}
    local _dbg="$BACKUP_DIR/debug_$(basename "$INIT_LOG" | sed 's/^init_//')"
    cp -f "$INIT_LOG" "$_dbg" 2>/dev/null \
      && echo "[init] snapshot: 附带 DEBUG log -> debug_$(basename "$INIT_LOG" | sed 's/^init_//')" \
      || echo "[init] snapshot: WARN 复制 DEBUG log 失败，跳过。"
    # 字段级脱敏 (红线1 动态: 不上传凭据明文)
    if [ -f "$_dbg" ]; then
      sed -i -E \
        -e 's/(Authorization:[[:space:]]*Bearer[[:space:]]+)[A-Za-z0-9._\-]+/\1<REDACTED>/gI' \
        -e 's/(NIM_KEY=|nvapi-)[A-Za-z0-9._\-]+/\1<REDACTED>/gI' \
        -e 's/(Cookie:[[:space:]]+)[^[:space:]]+/\1<REDACTED>/gI' \
        -e 's/(Set-Cookie:[[:space:]]+)[^[:space:]]+/\1<REDACTED>/gI' \
        -e 's/(Bearer )[A-Za-z0-9._\-]+/\1<REDACTED>/g' \
        "$_dbg" 2>/dev/null || true
    fi
    # 本地滚动清理：只保留最近 _keep 个 init_*.log
    if [ -d "$LOG_DIR" ]; then
      ls -1t "$LOG_DIR"/init_*.log 2>/dev/null | tail -n +$(( _keep + 1 )) | xargs -r rm -f 2>/dev/null || true
    fi
  else
    [ "$NIM_MODE" = "DEBUG" ] && echo "[init] snapshot: DEBUG log 上传已禁用（默认关, NIM_DEBUG_LOG_TO_DATASET=1 开启)."
  fi

  python3 - <<'PYEOF'
import os
from datetime import datetime, timezone
from huggingface_hub import HfApi
api = HfApi(token=os.environ["HF_TOKEN"])
api.upload_folder(folder_path="/tmp/omni-snapshot", path_in_repo="omni_data",
    repo_id=os.environ["HF_DATASET_REPO"], repo_type="dataset",
    commit_message=f"Sync omni_data - {datetime.now(timezone.utc).isoformat()}")
print("[init] HF Dataset uploaded.")
PYEOF
}

# ── 增量模式（⑧ 增量门放宽：任一 nim-* combo 或 INIT_MARKER 存在）──
if [ -f "$_DB_PATH" ]; then
  COMBO_COUNT=$(sqlite3 "$_DB_PATH" "SELECT COUNT(*) FROM combos WHERE name IN ('nim-pool','nim-codex');" 2>/dev/null || echo 0)
  if [ "${COMBO_COUNT:-0}" -gt 0 ] || [ -f "$INIT_MARKER" ]; then
    echo "[init] Incremental mode."
    purge_proxy_db
    # ⑤ 只清"已过期"熔断，保留仍在冷却窗内的历史信号
    sqlite3 "$_DB_PATH" "DELETE FROM domain_circuit_breakers WHERE cooldown_until < datetime('now');" 2>/dev/null || true
    check_nim_model_health
    # ⑦ 增量也走幂等 upsert（同时修复 deprecated 与撞名）
    mapfile -t POOL_ALIVE  < <(filter_alive "${NIM_POOL_MODELS[@]}")
    mapfile -t CODEX_ALIVE < <(filter_alive "${NIM_CODEX_MODELS[@]}")
    upsert_combo "nim-pool"  "$_POOL_STRATEGY"  "${POOL_ALIVE[@]}"
    upsert_combo "nim-codex" "$_CODEX_STRATEGY" "${CODEX_ALIVE[@]}"
    context_accumulator_update
    hf_snapshot
    echo "[init] Done (incremental). v4.2.3"
    exit 0
  fi
else
  echo "[init] DB not present. First-time init."
fi

check_nim_model_health

echo "[init] Registering models..."
register_model() {
  local MODEL_ID="$1" F="$(_resp omniroute-model-$(echo "$1" | tr '/' '-').json)" C
  C=$(curl -s -o "$F" -w "%{http_code}" -b "$COOKIE_FILE" -X POST "$BASE_URL/api/provider-models" \
    -H "Content-Type: application/json" -d "$(jq -n --arg provider "nvidia" --arg modelId "$MODEL_ID" '{provider:$provider, modelId:$modelId}')")
  if [ "$C" = "200" ] || [ "$C" = "201" ]; then echo "[init] model $MODEL_ID OK"
  elif [ "$C" = "409" ]; then echo "[init] model $MODEL_ID exists"
  else echo "[init] model $MODEL_ID WARN $C"; cat "$F" || true; fi
}
while IFS= read -r _M; do [ -z "$_M" ] && continue; register_model "$_M"; done < <(build_all_models | { grep -Fxvf /tmp/nim-deprecated.txt || true; })
echo "[init] Model registration done."

mapfile -t POOL_ALIVE  < <(filter_alive "${NIM_POOL_MODELS[@]}")
mapfile -t CODEX_ALIVE < <(filter_alive "${NIM_CODEX_MODELS[@]}")

# ⑦ first-init 也走幂等 upsert（根治 R2 restore 后撞名）
upsert_combo "nim-pool"  "$_POOL_STRATEGY"  "${POOL_ALIVE[@]}"
upsert_combo "nim-codex" "$_CODEX_STRATEGY" "${CODEX_ALIVE[@]}"

context_accumulator_update
hf_snapshot
purge_proxy_db

touch "$INIT_MARKER"
echo "[init] Final health check..."
HEALTH_FILE="$(_resp omniroute-final-health.json)"
HEALTH_HTTP=$(curl -s -o "$HEALTH_FILE" -w "%{http_code}" "$BASE_URL/api/monitoring/health" 2>/dev/null || echo "000")
[ "$HEALTH_HTTP" = "200" ] && echo "[init]   Status: $(jq -r '.status // "unknown"' "$HEALTH_FILE") / $(jq -r '.version // "unknown"' "$HEALTH_FILE")"
echo "[init] Done (first-init). v4.2.3"

```

## litestream.yml

```yaml
dbs:
  - path: /data/storage.sqlite
    replica:
      type: s3
      bucket: omniroute-data
      path: db/storage.sqlite
      endpoint: https://${R2_ACCOUNT_ID}.r2.cloudflarestorage.com
      access-key-id: ${R2_ACCESS_KEY_ID}
      secret-access-key: ${R2_SECRET_ACCESS_KEY}
      region: auto
      sync-interval: 10s
      # v4.3 红线3: 改 false. entrypoint.sh 已显式 restore (含本地非空 guard + 临时路径 + quick_check);
      # 若 auto-recover true, litestream replicate 启动时自恢复会绕过 entrypoint 的 guard, 可能覆盖有效 DB.
      auto-recover: false

snapshot:
  interval: 1h
  retention: 24h

```

## package.json

```json
{
  "name": "omniroute-gate",
  "version": "4.3.0",
  "private": true,
  "description": "PSK (INTERNAL_PSK for /v1) + admin-token (GATE_ADMIN_TOKEN via Basic Auth for admin UI) gate in front of OmniRoute (HF Space :7860 -> :20128)",
  "main": "gate.js",
  "engines": {
    "node": ">=22.0.0"
  },
  "scripts": {
    "start": "node gate.js"
  },
  "dependencies": {
    "express": "^4.21.2"
  }
}

```

## README.md

```md
---
title: OmniRoute Candidate v4.3
emoji: 🚀
colorFrom: blue
colorTo: indigo
sdk: docker
pinned: false
license: mit
app_port: 7860
---

# omniroute 太空舱 · v4.3 candidate (Stage D)

> 候选版仅评审. 来自 `candidate-v4.3-reviewed/`, 不在生产实例部署. 已通过 candidate 内 tests/.
> 基线: B1 `nomn/main@42ea8e7` (生产行为) + B2 `working tree@9a1a7f0` (已验证保守修正) + B3 `omniroute-v3.8.43@b729a8f` (OmniRoute 契约).
> 详细差异见 audit/06-candidate-review.md, 未决见 KNOWN-UNVERIFIED.md.

## 架构

```
公网 :7860  ─►  gate.js (PSK + admin Basic Auth + SSE 透传)  ─►  127.0.0.1:20128  OmniRoute (Next.js)
                     │                                                  │
                     │ /healthz 免认证                                    │ SQLite /data/storage.sqlite
                     │ /v1,/v1/* PSK (INTERNAL_PSK) → 替 OR_API_KEY      │
                     │ 后台白名单 Basic Auth (GATE_ADMIN_TOKEN)            │
                     └ 无第二套限流 (28/1/2200ms 在 OmniRoute requestQueue)  └─ Litestream → R2
```

唯一出口代理直连 OmniRoute, **无外部 Relay / cf-worker / context-relay**

## 配置 (HF Space Secrets)

| Secret | 必需 | 用途 | 默认 |
|--------|------|------|------|
| `INTERNAL_PSK` | 是 (≥16 chars) | /v1 推理请求鉴权 (Gate 入口, Bearer PSK) | fail-closed |
| `JWT_SECRET`, `API_KEY_SECRET`, `INITIAL_PASSWORD`, `OMNIROUTE_API_KEY` | 是 (OmniRoute 内部) | OmniRoute 自身认证 | — |
| `NIM_KEYS` | 是 | NVIDIA NIM API keys (换行分隔) | — |
| `R2_ACCESS_KEY_ID`, `R2_SECRET_ACCESS_KEY`, `R2_ACCOUNT_ID` | 否 | R2 备份; 缺失则复制非致命降级 | 跳过 |
| `GATE_ADMIN_TOKEN` | 否 (≥16 chars) | **后台访问开关兼 Basic Auth 密码**; 留空/过短 → 后台关闭 (全 404) | 不设=关 |
| `LITESTREAM_STRICT` | 否 (默认 1) | 复制失败严格(exit)/非致命(warn)| 1 (严格) |
| `HF_TOKEN`, `HF_DATASET_REPO` | 否 | 配置快照上传 Dataset | 跳过 |
| `GATE_UPSTREAM_TIMEOUT_MS` | 否 (30000) | 上游超时 | 30000 |

## 默认值与 fail-closed 行为

- **PSK 缺失/过短 (<16)**: gate.js 启动 `process.exit(1)` (fail-closed).
- **OR_API_KEY 缺失** (env 和 `/data/.or-api-key` 均无): gate.js `exit(1)`.
- **GATE_ADMIN_TOKEN 未设/空/过短**: **后台关闭**, 后台路径全 404 (不泄露后台存在); 有 OmniRoute Cookie/Session 仍 404.
- **GATE_ADMIN_TOKEN 设有效值 (≥16)**: **后台开启**, 白名单路径经 HTTP Basic Auth (用户名 `admin`, 密码=token) 放行; 非白名单仍 404; `/_next/*`, public 静态资源免 admin token (仅须开关开).
- **LiteStream restore**: 本地 DB 存在且非空 → 跳过 (绝不覆盖); 临时路径恢复 + post `PRAGMA quick_check`; 失败按 `LITESTREAM_STRICT` 严格 exit / 非致命 warn.
- **Debug Dataset 日志上传**: **默认关闭** (`NIM_DEBUG_LOG_TO_DATASET=1` 开启); 开启时上传前字段级脱敏 Authorization/NIM_KEY/Cookie/Bearer → `<REDACTED>`.
- **限流**: 固定 28 RPM / 1 并发 / 2200ms, 仅写 OmniRoute `requestQueue`; Gate 不重复限流 (零限流代码).
- **Resilience `useUpstream429BreakerHints=false`** (保守默认; NIM direct-cloud 分支实例未证).
- **自动 Context Override**: **默认关闭**; 启用须经 API `PATCH /api/provider-models` 的 `max_input_tokens`/`max_output_tokens` + 读回 (见 KNOWN-UNVERIFIED).

## 后台访问 (GATE_ADMIN_TOKEN) — 扩大公网暴露面

**默认关闭** (不设 `GATE_ADMIN_TOKEN`). **设置该变量会扩大公网暴露面**:
- 开启后, 后台白名单页面 (登录、看板、文档、静态资源) + 只读管理 API 可经 Basic Auth 访问.
- 后台仍**受 OmniRoute 自身认证约束** (登录/Session/Cookie 保留), Gate 仅控可达性, 不替代/OmniRoute 鉴权.
- **无 IP/CIDR 限制**: HF 平台代理拓扑未验证, 暂不实现 (见 KNOWN-UNVERIFIED); 不得声称有 IP 防护.
- **建议**: 仅在维护窗口临时配置强随机 token (≥16 chars), 使用后删除该 Secret 即恢复仅 API 暴露模式.
- 禁止能力: restart/shutdown/任意执行/插件安装/通配 `/api/*` 默认不开放; 写操作 (POST/PATCH/PUT/DELETE) 默认不在白名单 (见 KNOWN-UNVERIFIED).

## 三类入口分离

| 路径 | 方法 | 认证 |
|------|------|------|
| `/healthz` | GET | 免认证 |
| `/v1`, `/v1/*` | 任意 (SSE 透传) | `INTERNAL_PSK` (Bearer) |
| 后台白名单页面/静态 | GET | `GATE_ADMIN_TOKEN` (Basic Auth; 静态免) |
| 只读 `/api/*` 白名单 | GET | `GATE_ADMIN_TOKEN` (Basic Auth) |
| 其他 | 任意 | 404 |

`INTERNAL_PSK` 与 `GATE_ADMIN_TOKEN` **用途隔离**, 不得互相回退.

## 测试

见 TESTING.md. candidate 内 tests/ 完整 (路径矩阵、PSK、Basic Auth、SSE 真流式、信号、LiteStream、幂等、残留扫描).

## 回退

见 ROLLBACK.md. 删除 `GATE_ADMIN_TOKEN` + 重启即关闭后台 (仅 API 暴露).

```

