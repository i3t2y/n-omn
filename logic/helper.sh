#!/bin/sh
# helper.sh · boot hooks before gate (entrypoint calls this, then node gate.js)
# 1) Idempotent patch of gate.js + entrypoint.sh for init-hold middleware
# 2) This-boot lock files so /v1 returns 503 while init-nim-keys.sh is alive
# /healthz stays on gate and is never held.
set -u

log() { echo "[helper] $*"; }

LOGIC="${LOGIC_DIR:-/logic}"
DATA_DIR="${DATA_DIR:-/app/data}"

# ── 1) source patch (this boot's gate.js must contain middleware) ───────────
if [ -f "$LOGIC/patch_init_hold.py" ] && [ -f "$LOGIC/gate.js" ]; then
  if python3 "$LOGIC/patch_init_hold.py" --gate "$LOGIC/gate.js" --entrypoint "$LOGIC/entrypoint.sh" 2>&1 | sed 's/^/[helper] /'; then
    :
  else
    log "WARN: patch_init_hold failed (gate may still work without hold)"
  fi
else
  log "patch skip (patch_init_hold.py or gate.js missing)"
fi

# ── 2) this-boot init lock ─────────────────────────────────────────────────
# entrypoint starts init before helper; parent shell may not export INIT_PID.
# Detect by process name. Mirror locks under DATA_DIR and /data (path drift).
RUN_A="$DATA_DIR/.init-running"
FAIL_A="$DATA_DIR/.init-failed"
RUN_B="/data/.init-running"
FAIL_B="/data/.init-failed"
DONE_A="$DATA_DIR/.init-done"
DONE_B="/data/.init-done"

init_alive() {
  pgrep -f 'init-nim-keys\.sh' >/dev/null 2>&1
}

touch_both() {
  # $1 = path A, $2 = path B
  : > "$1" 2>/dev/null || true
  : > "$2" 2>/dev/null || true
}

rm_both() {
  rm -f "$1" "$2" 2>/dev/null || true
}

if init_alive; then
  rm_both "$FAIL_A" "$FAIL_B"
  touch_both "$RUN_A" "$RUN_B"
  log "init still running → hold locks set ($RUN_A)"
  (
    while init_alive; do sleep 2; done
    if [ -f "$DONE_A" ] || [ -f "$DONE_B" ]; then
      rm_both "$RUN_A" "$RUN_B"
      rm_both "$FAIL_A" "$FAIL_B"
      log "init finished ok → hold locks cleared"
    else
      rm_both "$RUN_A" "$RUN_B"
      touch_both "$FAIL_A" "$FAIL_B"
      log "init finished without .init-done → fail lock set"
    fi
  ) &
else
  # Stale running lock would 503 forever; clear if no init process.
  if [ -f "$RUN_A" ] || [ -f "$RUN_B" ]; then
    log "no init process; clearing stale running locks"
    rm_both "$RUN_A" "$RUN_B"
  fi
fi

log "boot hooks done"
