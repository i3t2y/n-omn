#!/bin/sh
# n-omn · SQLite 网络 FS 治本 + 坏库自愈 (2026-09-26)
#
# ── 背景 ──────────────────────────────────────────────────────────
# HF 持久卷是网络 FS, SQLite WAL 官方明言不可靠
#   (-wal/-shm 需跨进程共享内存 + mmap/本地锁, 网络 FS 均不保证)。
# 09-25 实证反复 SIGBUS(core dumped) 与 SQLITE_READONLY 崩溃循环,
#   第一性根因 = "WAL 跑在网络 FS"。
#
# ── 本件职责(每 boot 跑, 在拉起上游 node server.js 之前) ──────────
#   0) 体检 + 自愈: 坏库(SQLITE_CORRUPT)自动从最新"健康快照"恢复
#      —— 堵两个已坐实的门禁缺口:
#        ① entrypoint 只判非空不判健康 (09-17/09-26 坏库顺利过闸);
#        ② _snap_gen 检的是 .backup 出来的"副本"不是"源", 09-26 出现
#           副本 integrity_check=ok 但活库 malformed (callLogs/proxyLogger
#           全量写失败) ⇒ 体检必须以"活库 + 其 -wal"的视角做, 且要查"能不能写"。
#    a) DB 文件: checkpoint + journal_mode=DELETE → 清掉 -wal/-shm 残留
#    b) 编译产物: 字面量 journal_mode = WAL -> DELETE → 阻止 App 开库把 WAL 开回来 ← 关键治本
#    c) key_value(databaseSettings/mmapSize)=0 → App 打开时跳过 mmap(缺省 256MiB) 杀 SIGBUS
#
# ── 用法 ──────────────────────────────────────────────────────────
#   bash /logic/db_harden.sh [DB_PATH]
#   DB_PATH 缺省取环境变量 $DB_PATH, 再缺省 /data/storage.sqlite
#
# ── 约定 ──────────────────────────────────────────────────────────
#   只告警、不得非 0 退出 —— 本件不得打断 entrypoint 启动链。
#   (调用点已 `|| true`; 本脚本内部亦逐条 if 兜底, 不用 set -e)
#
# ── 自愈安全约束 ──────────────────────────────────────────────────
#   * 绝不盲信"最新"快照: entrypoint 每 boot 会给当前库(可能已坏)拍快照入池,
#     故候选必须逐个 integrity_check, 只取返回 ok 的, 按 mtime 新→旧取第一个。
#   * 恢复后必清 -wal/-shm (只换主文件留旧 WAL ⇒ 立刻 CORRUPT, 09-17 教训)。
#   * 恢复后复检, 结果入日志; 复检不过也要如实告警, 绝不谎报成功。
#   * "结构坏"才隔离; 仅"不可写"(卷 remount-ro)不动库 —— 换档也救不了, 别毁数据。
#   * 绝不静默删数据: 最后手段是把坏库改名保留为 .corrupt-<ts>, 而非 rm。

DBP="${1:-${DB_PATH:-/data/storage.sqlite}}"
SNAPDIR="${SNAP_DIR:-$(dirname "$DBP")/backups}"

HAVE_SQLITE=1
command -v sqlite3 >/dev/null 2>&1 || HAVE_SQLITE=0

# 结构全检: PRAGMA integrity_check (不用 quick_check —— 09-26 血案就是浅检漏过)
_db_ok() {
  [ "$HAVE_SQLITE" = 1 ] && [ -f "$1" ] || return 1
  sqlite3 "$1" "PRAGMA integrity_check;" 2>/dev/null | head -1 | grep -q '^ok$'
}
# 恢复源专用: 必须非空 —— 0 字节文件是"合法空库", integrity_check 会返回 ok,
#   若不挡住, .recover 失败产出的空档会被当成"抢救成功"覆盖活库(= 静默丢库)
_db_ok_src() {
  [ -s "$1" ] || return 1
  _db_ok "$1"
}
# 可写性探测: 库"完好但只读"会让 App 初始化即炸(SQLITE_READONLY), 结构检查查不出
#   create+drop 净零页, 事务内完成 —— 健康库上无副作用
_db_writable() {
  [ "$HAVE_SQLITE" = 1 ] && [ -f "$1" ] || return 1
  sqlite3 "$1" "BEGIN IMMEDIATE;
    CREATE TABLE IF NOT EXISTS _db_harden_probe(id INTEGER PRIMARY KEY);
    DROP TABLE IF EXISTS _db_harden_probe;
    COMMIT;" >/dev/null 2>&1
}
# 恢复: 拷回主库 + 必清 -wal/-shm
_restore_from() {
  cp -f "$1" "$DBP" 2>/dev/null || return 1
  rm -f "$DBP-wal" "$DBP-shm"
  return 0
}

# ══ 0) 体检 + 自愈 ════════════════════════════════════════════
if [ "$HAVE_SQLITE" = 0 ]; then
  echo "[db-harden] ⚠ 0) 跳过体检: sqlite3 缺失"
elif [ ! -f "$DBP" ]; then
  echo "[db-harden] 0) DB 不存在, 跳过体检 (交由 App/entrypoint 重建)"
elif ! _db_ok "$DBP"; then
  echo "[db-harden] ⚠ 0) DB 结构检查失败(损坏) → 启动自愈"
  _picked=""
  # 候选按 mtime 新→旧, 最多验 3 个(控制 boot 耗时); 逐个 integrity_check, 绝不信"最新"
  for cand in $(ls -t "$SNAPDIR"/db-snap.*.db "$SNAPDIR"/storage.last-good.sqlite 2>/dev/null | head -3); do
    if _db_ok_src "$cand"; then _picked="$cand"; break; fi
    echo "[db-harden]   候选 $(basename "$cand") 体检非 ok, 跳过"
  done

  if [ -n "$_picked" ]; then
    if _restore_from "$_picked"; then
      if _db_ok "$DBP"; then
        echo "[db-harden] 0) 自愈 ✓ 已从快照 $(basename "$_picked") 恢复并复检 ok (已清 -wal/-shm)"
      else
        echo "[db-harden] ⚠ 0) 自愈: 已从 $(basename "$_picked") 恢复, 但复检仍非 ok"
      fi
    else
      echo "[db-harden] ⚠ 0) 自愈: 快照拷贝失败 (卷只读/IO)"
    fi
  else
    echo "[db-harden] ⚠ 0) 自愈: 无健康快照, 尝试 .recover 抢救"
    _rc="$DBP.recovered.$$"
    _dump="$DBP.dump.$$"
    # ⚠ 不得写成 `sqlite3 .recover | sqlite3 目标`: 管道退出码取最后一条,
    #   .recover 失败会静默产出 0 字节档, 而 0 字节档 integrity_check=ok → 误判成功覆盖活库
    if sqlite3 "$DBP" ".recover" > "$_dump" 2>/dev/null && [ -s "$_dump" ] \
       && sqlite3 "$_rc" < "$_dump" 2>/dev/null && _db_ok_src "$_rc"; then
      if cp -f "$_rc" "$DBP" 2>/dev/null; then
        rm -f "$DBP-wal" "$DBP-shm" "$_rc" "$_dump"
        echo "[db-harden] 0) 自愈 ✓ .recover 抢救成功并恢复"
      else
        rm -f "$_rc" "$_dump"
        echo "[db-harden] ⚠ 0) 自愈: .recover 产出健康档, 但拷回失败 (卷只读/IO)"
      fi
    else
      rm -f "$_rc" "$_dump"
      # 最后手段: 隔离坏库(改名保留, 绝不 rm), 让 App/entrypoint 空库重建(init 幂等)
      echo "[db-harden] ⚠ 0) 自愈: 抢救失败 → 隔离坏库, 交由 App 空库重建"
      mv -f "$DBP" "$DBP.corrupt-$(date +%s)" 2>/dev/null \
        && echo "[db-harden]   坏库已隔离保留为 $(basename "$DBP").corrupt-*" \
        || echo "[db-harden] ⚠ 隔离失败(卷只读), 保留原库"
      rm -f "$DBP-wal" "$DBP-shm"
    fi
  fi
elif ! _db_writable "$DBP"; then
  # 结构好但写不进 —— 换档也救不了(病根在卷, 不在档), 只告警不动库
  echo "[db-harden] ⚠ 0) DB 结构 ok 但不可写 (卷 remount-ro / 权限) —— 不动库, 换档无益, 请查卷"
else
  echo "[db-harden] 0) DB 体检: integrity_check=ok 且可写 (健康, 无需自愈)"
fi

# ══ a) DB 文件: checkpoint + 翻 DELETE(顺带清 -wal/-shm) ═════════
if [ "$HAVE_SQLITE" = 1 ] && [ -f "$DBP" ]; then
  if sqlite3 "$DBP" "PRAGMA wal_checkpoint(TRUNCATE); PRAGMA journal_mode=DELETE;" >/dev/null 2>&1; then
    echo "[db-harden] a) DB journal_mode -> delete (已 checkpoint 并清理 -wal)"
  else
    echo "[db-harden] ⚠ a) DB pragma 设置失败(库只读? 卷被 remount-ro?)"
  fi
else
  echo "[db-harden] ⚠ a) 跳过: sqlite3 缺失或 DB 不存在 ($DBP)"
fi

# ══ b) 编译产物: 根除 WAL 字面量(排除 node_modules) ══════════════
_n=0
for _f in $(grep -rl --exclude-dir=node_modules 'journal_mode = WAL' /app 2>/dev/null | head -50); do
  if sed -i 's/journal_mode = WAL/journal_mode = DELETE/g' "$_f" 2>/dev/null; then _n=$((_n+1)); fi
done
if [ "$_n" -gt 0 ]; then
  echo "[db-harden] b) 编译产物 $_n 处 journal_mode WAL->DELETE (WAL 已根除)"
else
  echo "[db-harden] ⚠ b) 未在编译产物找到 'journal_mode = WAL' (路径/版本漂移?) WAL 仍在 — 需人工核对"
fi
if grep -rq --exclude-dir=node_modules 'journal_mode = WAL' /app 2>/dev/null; then
  echo "[db-harden] ⚠ b) 仍残留 'journal_mode = WAL', 补丁未完全生效"
fi

# ══ c) mmap: 置 0(空库首启 key_value 表可能未建 ⇒ 失败仅告警) ═══
if [ "$HAVE_SQLITE" = 1 ] && [ -f "$DBP" ]; then
  if sqlite3 "$DBP" "INSERT OR REPLACE INTO key_value(namespace,key,value) VALUES('databaseSettings','mmapSize','0');" >/dev/null 2>&1; then
    echo "[db-harden] c) key_value mmapSize=0 (mmap 关闭, 杀 SIGBUS)"
  else
    echo "[db-harden] ⚠ c) 置 mmapSize=0 失败 (空库首启 key_value 表未建? 下个 boot 自动补)"
  fi
fi

exit 0
