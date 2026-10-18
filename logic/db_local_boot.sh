#!/bin/sh
# n-omn · 双盘 SQLite 启动 (治本: 活库离开 Bucket FUSE)
#
# 根因: HF Bucket mount = 网络 FS 语义; SQLite WAL/mmap 官方不支持 →
#   SIGBUS / SQLITE_CORRUPT / READONLY。Dataset→Bucket 后若活库仍在 mount 上会放大。
#
# 合同 (对齐 nexus A 方案):
#   活库 = 容器本地盘  $OMN_LOCAL_DATA/storage.sqlite   (WAL/DELETE 都稳)
#   真源快照 = Bucket  $OMN_BUCKET_DATA/backups/… + 可选整库副本
#   Boot: 本地无库或坏库 → 从 Bucket 健康快照/副本拉回
#   运行中: App 只写本地; 周期推快照仍由 entrypoint 既有 _snap_gen 做
#
# 环境:
#   OMN_LOCAL_DATA   默认 /opt/omn-data     (本地, 重启可丢, 靠快照回)
#   OMN_BUCKET_DATA  默认 $DATA_DIR 或 /app/data  (Bucket mount)
#   成功后 export DATA_DIR=$OMN_LOCAL_DATA  并写到 /tmp/omn-data-dir
#     (供同 shell 的 entrypoint source; 子进程靠 env 已 export)
#
# 用法 (entrypoint 在设 DATA_DIR 后、开库前):
#   . /logic/db_local_boot.sh   # 注意点 source, 才能改父 shell DATA_DIR
#   或: eval "$(sh /logic/db_local_boot.sh --print-export)"
#
# 开关: OMN_DB_LOCAL=0 关闭本脚本 (回退整库在 Bucket 上, 仅靠 db_harden)

set -u

log() { echo "[db-local] $*"; }

OMN_DB_LOCAL="${OMN_DB_LOCAL:-1}"
if [ "$OMN_DB_LOCAL" = "0" ]; then
  log "disabled (OMN_DB_LOCAL=0)"
  return 0 2>/dev/null || exit 0
fi

BUCKET="${OMN_BUCKET_DATA:-${DATA_DIR:-/app/data}}"
LOCAL="${OMN_LOCAL_DATA:-/opt/omn-data}"
SNAPDIR="$BUCKET/backups"
LIVE_LOCAL="$LOCAL/storage.sqlite"
LIVE_BUCKET="$BUCKET/storage.sqlite"

mkdir -p "$LOCAL" "$SNAPDIR" 2>/dev/null || true

_db_ok() {
  command -v sqlite3 >/dev/null 2>&1 || return 1
  [ -f "$1" ] || return 1
  sqlite3 "$1" "PRAGMA integrity_check;" 2>/dev/null | head -1 | grep -q '^ok$'
}

_db_ok_src() {
  [ -s "$1" ] || return 1
  _db_ok "$1"
}

# ── 本地已有健康库: 直接用 ─────────────────────────────────────
if _db_ok "$LIVE_LOCAL"; then
  log "local live ok → DATA_DIR=$LOCAL"
  export DATA_DIR="$LOCAL"
  export DB_PATH="$LIVE_LOCAL"
  echo "$LOCAL" > /tmp/omn-data-dir 2>/dev/null || true
  return 0 2>/dev/null || exit 0
fi

# ── 从 Bucket 恢复 ─────────────────────────────────────────────
picked=""
for cand in \
  $(ls -t "$SNAPDIR"/db-snap.*.db "$SNAPDIR"/storage.last-good.sqlite 2>/dev/null | head -5) \
  "$LIVE_BUCKET"
do
  [ -n "$cand" ] || continue
  if _db_ok_src "$cand"; then
    picked="$cand"
    break
  fi
  log "skip bad candidate $(basename "$cand" 2>/dev/null || echo "$cand")"
done

if [ -n "$picked" ]; then
  if cp -f "$picked" "$LIVE_LOCAL" 2>/dev/null; then
    rm -f "$LIVE_LOCAL-wal" "$LIVE_LOCAL-shm" 2>/dev/null || true
    # 本地再翻 DELETE, 避免从历史 WAL 库带进 WAL 模式
    if command -v sqlite3 >/dev/null 2>&1; then
      sqlite3 "$LIVE_LOCAL" "PRAGMA wal_checkpoint(TRUNCATE); PRAGMA journal_mode=DELETE;" >/dev/null 2>&1 || true
    fi
    if _db_ok "$LIVE_LOCAL"; then
      log "restored local from $(basename "$picked") → DATA_DIR=$LOCAL"
    else
      log "WARN: copy ok but integrity still bad; keep local for App rebuild"
    fi
  else
    log "WARN: copy from bucket failed"
  fi
else
  log "no healthy bucket source; empty local (init will seed)"
  rm -f "$LIVE_LOCAL" "$LIVE_LOCAL-wal" "$LIVE_LOCAL-shm" 2>/dev/null || true
fi

export DATA_DIR="$LOCAL"
export DB_PATH="$LIVE_LOCAL"
echo "$LOCAL" > /tmp/omn-data-dir 2>/dev/null || true
log "export DATA_DIR=$LOCAL DB_PATH=$LIVE_LOCAL"
return 0 2>/dev/null || exit 0
