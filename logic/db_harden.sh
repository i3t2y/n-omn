#!/bin/sh
# n-omn · SQLite 网络 FS 治本: WAL→DELETE + mmap=0 (2026-09-26)
#
# 背景: HF 持久卷是网络 FS, SQLite WAL 官方明言不可靠
#       (-wal/-shm 需跨进程共享内存 + mmap/本地锁, 网络 FS 均不保证)。
#   09-25 实证反复 SIGBUS(core dumped) 与 SQLITE_READONLY 崩溃循环,
#   第一性根因 = "WAL 跑在网络 FS"。
#
# 治本三连(必须在拉起上游 node server.js 之前执行):
#   a) DB 文件:  checkpoint + journal_mode=DELETE   → 清掉现存 -wal/-shm 残留(09-25 的坏 WAL)
#   b) 编译产物: 字面量 journal_mode = WAL -> DELETE → 阻止 App 开库时把 WAL 开回来 ← 关键治本
#   c) key_value(databaseSettings/mmapSize)=0       → App 打开时跳过 mmap(缺省 256MiB) 杀 SIGBUS
#
# 说明: 编译产物每次 boot 由镜像重建 ⇒ 每 boot 都要改(b 步); 故本件须每 boot 跑。
#
# 用法: bash /logic/db_harden.sh [DB_PATH]
#   DB_PATH 缺省取环境变量 $DB_PATH, 再缺省 /data/storage.sqlite
#
# 约定: 只告警、不得非 0 退出 —— 本件不得打断 entrypoint 启动链。
#       (调用点已 `|| true`; 本脚本内部亦逐条 if 兜底, 不用 set -e)

DBP="${1:-${DB_PATH:-/data/storage.sqlite}}"

# a) DB 文件: checkpoint + 翻 DELETE(顺带清 -wal/-shm)
if command -v sqlite3 >/dev/null 2>&1 && [ -f "$DBP" ]; then
  if sqlite3 "$DBP" "PRAGMA wal_checkpoint(TRUNCATE); PRAGMA journal_mode=DELETE;" >/dev/null 2>&1; then
    echo "[db-harden] a) DB journal_mode -> delete (已 checkpoint 并清理 -wal)"
  else
    echo "[db-harden] ⚠ a) DB pragma 设置失败(库只读? 卷被 remount-ro?)"
  fi
else
  echo "[db-harden] ⚠ a) 跳过: sqlite3 缺失或 DB 不存在 ($DBP)"
fi

# b) 编译产物: 根除 WAL 字面量(排除 node_modules, 避免误改依赖与拖慢扫描)
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

# c) mmap: 置 0(空库首启 key_value 表可能尚未建立 ⇒ 失败仅告警, 下个 boot 自动补)
if command -v sqlite3 >/dev/null 2>&1 && [ -f "$DBP" ]; then
  if sqlite3 "$DBP" "INSERT OR REPLACE INTO key_value(namespace,key,value) VALUES('databaseSettings','mmapSize','0');" >/dev/null 2>&1; then
    echo "[db-harden] c) key_value mmapSize=0 (mmap 关闭, 杀 SIGBUS)"
  else
    echo "[db-harden] ⚠ c) 置 mmapSize=0 失败 (空库首启 key_value 表未建? 下个 boot 自动补)"
  fi
fi

exit 0
