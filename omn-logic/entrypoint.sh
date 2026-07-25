#!/bin/bash
# 进程编排总控 (合并版)
# =====================================================
# K3 v2.0 骨架 (已修 litestream restore -config; ephemeral 盘认清 → R2 是数据主路径)
# + candidate v4.3 加固迁移:
#   1. restore guard 完善版: flock 跨容器互斥 + -o 临时路径原子 mv + quick_check + -if-replica-exists 自适应 + STRICT 日志
#   2. trap SIGTERM/SIGINT: 向 上游服务/init/litestream/gate 四后台子进程转 SIGTERM, grace wait, SIGKILL 兜底, 无孤儿
# gate 用 background 运行 (node /logic/gate.js &) + GATE_PID 纳入 _shutdown 转发;
#   entrypoint 持 PID 1 主监控循环 (while true) 管四子进程。
#   (非 exec 接管 PID 1 — exec 会让三后台成 gate 兄弟变孤儿, trap 失效)
set -eo pipefail

OMNIROUTE_PORT="${OMNIROUTE_PORT:-20128}"
EXPOSED_PORT="${EXPOSED_PORT:-7860}"
# 默认 /app/data = 上游镜像固设 DATA_DIR (3.8.43 基线); env 可改
DATA_DIR="${DATA_DIR:-/app/data}"
DB_PATH="$DATA_DIR/storage.sqlite"
DB_TMP="$DATA_DIR/.storage.sqlite.restore.$$"   # 临时恢复路径 (原子保护)
LOCK_FILE="$DATA_DIR/.omniroute.lock"
# 版本校验：硬编码已驱逐，改读 EXPECTED_VERSION env（未设则只记录不比对）。
# 值放 Space Variable 与 BASE_IMAGE 同步更新，三文件永久免改。
EXPECTED_VER="${EXPECTED_VERSION:-}"

# v4.3.2 [M7·查证定版]: 超时 env 外科单注 (官方 Environment wiki §15 实证, 2026-07-22).
#   查证结论(wiki 有 CI check:env-doc-sync 强制 wiki↔.env.example 同步, 缺席=未识别):
#     · STREAM_READINESS_TIMEOUT_MS 默 80000(80s) = 首个非 ping SSE 事件时限 — 长思考"首 token 前静默"
#       真杀手(122s 级思考静默正对此刀). 外科抬至 180s, 不动其他预算; 未设 REQUEST_TIMEOUT_MS 时读自身值.
#     · REQUEST_TIMEOUT_MS = 全局快捷键, 同覆 FETCH_TIMEOUT_MS(默600000)/STREAM_IDLE_TIMEOUT_MS(默600000) —
#       注它会把总时限/流空闲从 600s 拉低到所注值, 双面刃; 本场景无降额需求, 故不注.
#     · DEFAULT_REQUEST_TIMEOUT_MS 不在官方变量表 → 规则五修正: 删除, 早前"双注"方案作废.
#   gate GATE_UPSTREAM_TIMEOUT_MS(行30 默30000) 仍零 diff: Node http.request timeout=socket 不活跃超时,
#     流式有数据即重置、思考静默>30s 触发 — 122s 级首 token 静默经 gate 如何完成列 K3 题5, 解冻后走 env 调.
STREAM_READINESS_TIMEOUT_MS="${STREAM_READINESS_TIMEOUT_MS:-180000}"
export STREAM_READINESS_TIMEOUT_MS
echo "[entrypoint] STREAM_READINESS_TIMEOUT_MS=$STREAM_READINESS_TIMEOUT_MS (M7 外科单注, wiki §15 实证)"

OR_PID=""; INIT_PID=""; LS_PID=""; GATE_PID=""

echo "[entrypoint] 上游服务启动 | PORT=$OMNIROUTE_PORT EXPOSED=$EXPOSED_PORT DATA=$DATA_DIR (ephemeral, R2 是数据主路径)"

# ── trap 转发: 向 上游服务/init/litestream/gate 四发 SIGTERM, grace 后 SIGKILL, wait 回收 ──
# 重要: gate 用 background (非 exec 接管 PID 1), entrypoint 持 PID 1 主监控循环;
#   否则 exec gate 会让三后台成 gate 兄弟 (孤儿), trap 失效。
cleanup_done=0
_forward_signal() {
  local sig="$1"
  for pid in "$OR_PID" "$INIT_PID" "$LS_PID" "$GATE_PID"; do
    [ -z "$pid" ] && continue
    kill -0 "$pid" 2>/dev/null && kill -"$sig" "$pid" 2>/dev/null || true
  done
}
_shutdown() {
  [ "$cleanup_done" = 1 ] && return
  cleanup_done=1
  echo "[entrypoint] shutdown: forwarding SIGTERM to background children..."
  _forward_signal TERM
  local g=0 alive
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
  echo "[entrypoint] shutdown: force-kill 残留..."
  _forward_signal KILL
  for pid in "$OR_PID" "$INIT_PID" "$LS_PID" "$GATE_PID"; do
    [ -z "$pid" ] && continue
    wait "$pid" 2>/dev/null || true
  done
  echo "[entrypoint] shutdown complete."
}
trap '_shutdown' TERM
trap '_shutdown' INT

# ── 文件锁: 防多容器同时 restore/替换 $DB (HF Space 优先单实例, flock 不可用则 WARN 跳过) ──
exec 9>"$LOCK_FILE"
if command -v flock >/dev/null 2>&1; then
  flock -x 9 || { echo "[entrypoint] FATAL: 无法获取文件锁 $LOCK_FILE (另一容器占用?). abort." >&2; exit 1; }
  echo "[entrypoint] lock acquired (flock $LOCK_FILE, fd 9)."
else
  echo "[entrypoint] WARN: flock 不可用, 跳过跨容器互斥 (HF Space 优先单实例)."
fi

# ── 1. Litestream restore (启动前; 红线: 不覆盖有效 DB; ephemeral → R2 是数据主路径) ─
# 优雅降级:
#   R2 无副本 → -if-replica-exists rc=0 但不创建文件 → 空库启动 (init 重建), 不 exit
#   restore 失败 (配置/网络/权限) → WARN + 空库启动, 不 exit (永不因 restore 失败 FATAL)
#   restore 成功+有文件 → quick_check 通过 → 原子 mv → 正式 $DB
#   restore 成功+quick_check 失败 → 丢弃临时+空库启动, 不 exit
# K3 v2.0 修复: restore 增加 -config /litestream.yml (v1 缺此参数读默认 /etc/litestream.yml 导致静默失败)
has_r2=0
[ -n "${R2_ACCESS_KEY_ID:-}" ] && [ -n "${R2_SECRET_ACCESS_KEY:-}" ] && [ -n "${R2_ACCOUNT_ID:-}" ] && has_r2=1

if [ "$has_r2" = 0 ]; then
  echo "[entrypoint] ⚠ R2 凭据未配置 → skip restore, 空库启动 (数据将不可持久, 强烈建议补齐)"
elif [ -f "$DB_PATH" ] && [ -s "$DB_PATH" ]; then
  echo "[entrypoint] 本地库非空 ($DB_PATH) → skip restore (不覆盖有效 DB)"
else
  # 本地库空或不存在 → restore
  rm -f "$DB_TMP" "$DB_TMP-wal" "$DB_TMP-shm"
  printf '%s' "" > /tmp/ls_restore.err
  rc=0
  litestream restore -config /logic/litestream.yml -if-replica-exists -o "$DB_TMP" "$DB_PATH" 2>/tmp/ls_restore.err || rc=$?
  used_tmp=1
  # flag 自适应回退: 仅当某 flag 不支持才降级, 保留其它仍可支持 flag。
  # 优先级: -if-replica-exists -o tmp (最佳, R2 无副本 rc=0 无文件不 WARN)
  #   → -if-replica-exists 单独 (-o 不支持, 仍 R2 无副本 rc=0 无文件不 WARN)
  #   → 裸 restore (两 flag 都不支持, R2 无副本会 rc≠0 → 走 WARN 分支, 但有 "no replica/empty/not found" 字串例外不 WARN)
  if echo "$(cat /tmp/ls_restore.err 2>/dev/null)" | grep -qiE 'unknown flag|invalid option|flag provided but not defined'; then
    _err1="$(cat /tmp/ls_restore.err 2>/dev/null)"
    if printf '%s' "$_err1" | grep -qiE '\-o|output'; then
      # -o 不支持: 保留 -if-replica-exists, 去 -o, 直接 restore $DB_PATH (冷启动空, 无有效 DB 被覆盖)
      echo "[entrypoint] litestream 不支持 -o → 回退 -if-replica-exists 单独 restore $DB_PATH."
      rm -f "$DB_TMP" "$DB_TMP-wal" "$DB_TMP-shm"
      printf '%s' "" > /tmp/ls_restore.err
      rc=0
      litestream restore -config /logic/litestream.yml -if-replica-exists "$DB_PATH" 2>/tmp/ls_restore.err || rc=$?
      used_tmp=0
    elif printf '%s' "$_err1" | grep -qiE 'if-replica-exists'; then
      # -if-replica-exists 不支持: 裸 restore (R2 无副本会 rc≠0, 下文 "no replica" 例外不 WARN)
      echo "[entrypoint] litestream 不支持 -if-replica-exists → 回退裸 restore $DB_PATH."
      rm -f "$DB_TMP" "$DB_TMP-wal" "$DB_TMP-shm"
      printf '%s' "" > /tmp/ls_restore.err
      rc=0
      litestream restore -config /logic/litestream.yml "$DB_PATH" 2>/tmp/ls_restore.err || rc=$?
      used_tmp=0
    fi
  fi

  if [ "$rc" -ne 0 ]; then
    # 裸 restore (两 flag 都不支持) 在 R2 无副本时会 rc≠0, 但属正常首次部署, 不该 WARN。
    # litestream 无副本常见错误字串: "no replica"/"no data"/"not found"/"does not exist"/"empty"。
    if printf '%s' "$(cat /tmp/ls_restore.err 2>/dev/null)" | grep -qiE 'no replica|no (matching )?replica|no data|not found|does not exist|no entries|empty'; then
      echo "[entrypoint] restore rc=$rc 但匹配 '无副本' 错误 (R2 无副本或首次部署, 正常). 空库启动, init 重建配置."
    else
      echo "[entrypoint] ⚠ restore 失败 rc=$rc (见 /tmp/ls_restore.err; 已脱敏, 不打凭据). 空库启动."
      [ "${LITESTREAM_STRICT:-0}" = 1 ] && echo "[entrypoint]   STRICT=1: 仅告警, 不 exit (空库启动)."
    fi
    rm -f "$DB_TMP" "$DB_TMP-wal" "$DB_TMP-shm" 2>/dev/null || true
  elif [ "$used_tmp" = 1 ] && { [ ! -f "$DB_TMP" ] || [ ! -s "$DB_TMP" ]; }; then
    echo "[entrypoint] restore rc=0 但无文件 (R2 无副本或首次部署). 空库启动, init 重建配置."
    rm -f "$DB_TMP" "$DB_TMP-wal" "$DB_TMP-shm" 2>/dev/null || true
  elif [ "$used_tmp" = 1 ]; then
    # 临时文件有效 → quick_check → 原子 mv
    qc_ok=0
    if command -v sqlite3 >/dev/null 2>&1; then
      if sqlite3 "$DB_TMP" "PRAGMA quick_check;" 2>/dev/null | grep -q "^ok$"; then
        qc_ok=1
      else
        echo "[entrypoint] ⚠ quick_check 失败. 丢弃临时 $DB_TMP, 空库启动."
        [ "${LITESTREAM_STRICT:-0}" = 1 ] && echo "[entrypoint]   STRICT=1: 仅告警, 不 exit."
        rm -f "$DB_TMP" "$DB_TMP-wal" "$DB_TMP-shm" 2>/dev/null || true
      fi
    else
      echo "[entrypoint] sqlite3 不可用, 跳过 quick_check (验文件非空)."
      qc_ok=1
    fi
    [ "$qc_ok" = 1 ] && mv "$DB_TMP" "$DB_PATH" && echo "[entrypoint] ✓ 已从 R2 恢复 (原子 mv $DB_TMP → $DB_PATH)"
  else
    # used_tmp=0 (直接 $DB restore): 验 $DB 非空 + quick_check
    if [ ! -f "$DB_PATH" ] || [ ! -s "$DB_PATH" ]; then
      echo "[entrypoint] restore rc=0 但 $DB_PATH 无文件 (R2 无副本或首次部署). 空库启动, init 重建."
    elif command -v sqlite3 >/dev/null 2>&1; then
      if sqlite3 "$DB_PATH" "PRAGMA quick_check;" 2>/dev/null | grep -q "^ok$"; then
        echo "[entrypoint] ✓ 已从 R2 恢复 (直接 $DB_PATH, quick_check ok)"
      else
        echo "[entrypoint] ⚠ quick_check 失败 on $DB_PATH. 丢弃空库启动."
        rm -f "$DB_PATH" "$DB_PATH-wal" "$DB_PATH-shm" 2>/dev/null || true
      fi
    else
      echo "[entrypoint] ✓ 已从 R2 恢复 (直接 $DB_PATH, 文件非空)"
    fi
  fi
fi

# ── 2. 启动上游服务 ──
# 2026-07-25 #4 回归修复: 4.2.3 entrypoint 启动行内联 NODE_OPTIONS=--max-old-space-size=4096,
# 4.3.2 迁移时丢失 → dev Node 默认堆 ~1GB, 经 25-key 同体 fallback 堆载累积触顶 OOM 崩盘
# (弹H末日: Mark-Compact 1015→1023MB 触顶 → heap out of memory → Space 关机)。
# 生产 4.2.3 同 #4 链用 4GB 堆扛过 25 次未崩 → 4GB 是该链生产验证过的值, SSOT 优先于推测。
cd /app
NODE_OPTIONS="${NODE_OPTIONS:---max-old-space-size=4096}" node server.js &
OR_PID=$!
echo "[entrypoint] 上游服务 PID=$OR_PID (heap ${NODE_OPTIONS:-default})"

# ── 3. 健康等待 (180s) ──
_DL=$(( $(date +%s) + 180 ))
_ready=0
while [ $(date +%s) -lt $_DL ]; do
  curl -sf "http://127.0.0.1:$OMNIROUTE_PORT/api/monitoring/health" >/dev/null 2>&1 && { _ready=1; break; }
  kill -0 $OR_PID 2>/dev/null || { echo "[entrypoint] ✗ 上游服务已退出"; exit 1; }
  sleep 2
done
if [ "$_ready" = 0 ]; then
  echo "[entrypoint] ✗ 健康等待超时 (180s 未就绪, 上游 PID $OR_PID 仍活但不响应 /api/monitoring/health)"; exit 1
fi
echo "[entrypoint] ✓ 就绪"
_VER=$(curl -sf "http://127.0.0.1:$OMNIROUTE_PORT/api/monitoring/health" | jq -r '.version // "unknown"' 2>/dev/null || echo unknown)
if [ -n "$EXPECTED_VER" ]; then
  if [ "$_VER" = "$EXPECTED_VER" ]; then
    echo "[entrypoint] 版本=$_VER ✓ (期望 $EXPECTED_VER)"
  else
    # 只告警不 exit：上游前滚迁移会让旧库自动进新 schema，版本不齐仍可跑。
    echo "[entrypoint] ⚠ 版本不齐 实跑=$_VER 期望=$EXPECTED_VER (非致命, 上游迁移自动前滚)"
  fi
else
  echo "[entrypoint] 版本=$_VER (期望未设置, 跳过比对)"
fi

# ── 4. NIM 初始化 (后台) ──
if [ -f /logic/init-nim-keys.sh ] && [ -n "${NIM_KEYS:-}" ]; then
  bash /logic/init-nim-keys.sh & INIT_PID=$!
  echo "[entrypoint] Init PID=$INIT_PID"
fi

# ── 5. Litestream 复制 (后台) ──
# v0.5.9契约: replicate -config 模式 fs.NArg()必须=0 (走配置文件内 dbs[].path).
#   传 $DB_PATH 位置参数会命中 case 1 → "must specify at least one replica URL" 报错.
#   db 路径已在 /logic/litestream.yml 的 dbs[].path 内定义, 命令行不可再传.
if [ "$has_r2" = 1 ] && [ -f /logic/litestream.yml ]; then
  litestream replicate -config /logic/litestream.yml & LS_PID=$!
  echo "[entrypoint] Litestream PID=$LS_PID"
fi

echo "[entrypoint] 全部就绪：OR=$OR_PID Init=${INIT_PID:-无} LS=${LS_PID:-无} Gate→:$EXPOSED_PORT (background, entrypoint 持 PID 1 主监)"

# ── 6. 启动 gate (background, entrypoint 持 PID 1 主监控循环) ──
# 上游健康二次确认: 若上游已死, 不启 gate (避孤儿 gate 空转)
if ! kill -0 "$OR_PID" 2>/dev/null; then
  echo "[entrypoint] FATAL: 上游服务 died before gate. abort"; _shutdown; exit 1
fi
if [ ! -f /logic/gate.js ]; then
  echo "[entrypoint] FATAL: gate.js 不存在"; _shutdown; exit 1
fi

# ── 5.5 预装 gate 依赖 (三层解耦: /logic 逐 boot 重建 = ephemeral, 每次 boot 装一次) ──
# gate.js = express 版 (require('express')), bootstrap 仅拉 Dataset 文件不跑 npm install,
# /logic/node_modules 缺 → require 崩 crashloop。此处 boot 时补装 express(非 dev)。
if [ -f /logic/package.json ]; then
  if [ ! -d /logic/node_modules/express ]; then
    echo "[entrypoint] 预装 gate 依赖 (npm install --omit=dev)..."
    if (cd /logic && npm install --omit=dev --silent --no-audit --no-fund 2>&1); then
      echo "[entrypoint] gate 依赖就绪"
    else
      echo "[entrypoint] FATAL: npm install 失败, gate require express 必崩"; _shutdown; exit 1
    fi
  else
    echo "[entrypoint] gate 依赖已就绪 (node_modules/express 存在, 跳过 npm install)"
  fi
else
  echo "[entrypoint] FATAL: /logic/package.json 不存在, 无法预装 gate 依赖"; _shutdown; exit 1
fi

echo "[entrypoint] starting gate on port $EXPOSED_PORT..."
node /logic/gate.js &
GATE_PID=$!
echo "[entrypoint] gate PID=$GATE_PID"

# ── 7. 监督循环: 任一关键进程退出 → 停其余 ──
# gate 为对外服务 = 退出停一切; 上游服务为必需 = 退出停一切;
# init 非致命 (仅日志); litestream 退出按 STRICT (严格 exit / 非致命告警 PID 置空)
_init_logged=0
while true; do
  if ! kill -0 "$GATE_PID" 2>/dev/null; then
    echo "[entrypoint] gate exited. 停止其余并退出."; _shutdown; exit 1
  fi
  if ! kill -0 "$OR_PID" 2>/dev/null; then
    echo "[entrypoint] 上游服务 exited. 停止其余并退出."; _shutdown; exit 1
  fi
  if [ -n "$INIT_PID" ] && ! kill -0 "$INIT_PID" 2>/dev/null; then
    [ "$_init_logged" = 1 ] || { wait "$INIT_PID" 2>/dev/null; _init_rc=$?; if [ "$_init_rc" -ne 0 ]; then echo "[entrypoint] ✗ NIM init 已退出 rc=$_init_rc (fail-closed 触发或异常)."; else echo "[entrypoint] NIM init 已退出 rc=0 (正常完成)."; fi; _init_logged=1; }
  fi
  if [ -n "$LS_PID" ] && ! kill -0 "$LS_PID" 2>/dev/null; then
    if [ "${LITESTREAM_STRICT:-0}" = 1 ]; then
      echo "[entrypoint] FATAL: Litestream replicate exited (strict). 停止."; _shutdown; exit 1
    else
      echo "[entrypoint] WARN: Litestream replicate exited (非致命). DB 不再备份 (LITESTREAM_STRICT=0)."
      LS_PID=""
    fi
  fi
  sleep 1
done
