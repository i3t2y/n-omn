#!/bin/sh
# helper.sh · boot hooks before gate (entrypoint calls this, then node gate.js)
#
# 红线: 禁止在运行中改写 /logic/entrypoint.sh。
#   bash 边执行边读脚本文件; helper 若 rewrite entrypoint → 行号错位 →
#   syntax error near unexpected token `)' (2026-10-18 实证 Exit 2).
# entrypoint 的 db-local / init-hold 已固化进仓内 entrypoint.sh。
# 本脚本只: (1) 幂等 patch gate.js  (2) 本 boot 的 init 锁文件
set -u

log() { echo "[helper] $*"; }

LOGIC="${LOGIC_DIR:-/logic}"
DATA_DIR="${DATA_DIR:-/app/data}"

# ── 1) gate.js only (never touch entrypoint.sh here) ───────────────────────
if [ -f "$LOGIC/patch_init_hold.py" ] && [ -f "$LOGIC/gate.js" ]; then
  if python3 "$LOGIC/patch_init_hold.py" --gate "$LOGIC/gate.js" 2>&1 | sed 's/^/[helper] /'; then
    :
  else
    log "WARN: patch_init_hold gate failed (gate may still work without hold)"
  fi
else
  log "patch_init_hold skip"
fi

# ── 2) init lock sanity ─---------------------------------------------------
# entrypoint 在起 init 时把 PID 写进 $RUN_A, init 退出时清掉 (监控循环)。
# helper 只做一件事: 活锁绝不删, 死锁/空锁才清。不用 pgrep: 精简镜像常无 procps,
# 且进程名匹配本就脆弱, PID 文件是精确判定 (2026-10-18 实测 pgrep 漏检运行中的 init)。
RUN_A="$DATA_DIR/.init-running"
FAIL_A="$DATA_DIR/.init-failed"
RUN_B="/data/.init-running"
FAIL_B="/data/.init-failed"

_lock_pid() { tr -d ' \t\r\n' < "$RUN_A" 2>/dev/null; }

_lp=$(_lock_pid)
if [ -n "$_lp" ] && kill -0 "$_lp" 2>/dev/null; then
  rm -f "$FAIL_A" "$FAIL_B" 2>/dev/null || true
  log "init still running (pid $_lp) -> hold locks kept ($RUN_A)"
else
  if [ -f "$RUN_A" ] || [ -f "$RUN_B" ] || [ -f "$FAIL_A" ] || [ -f "$FAIL_B" ]; then
    log "no live init -> clearing stale locks"
  fi
  rm -f "$RUN_A" "$RUN_B" "$FAIL_A" "$FAIL_B" 2>/dev/null || true
fi

log "boot hooks done"
