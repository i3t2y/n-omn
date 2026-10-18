#!/usr/bin/env python3
"""Insert the init-hold into the live logic copies. Idempotent.

Does not rewrite the files. Refuses to run twice. /healthz is not touched:
keepalive must keep seeing 200 while /v1 answers 503 Retry-After.
"""

from __future__ import annotations

import argparse
from pathlib import Path

MARK = "init-hold-v1"

GATE_REQUIRE = "const routeSplit = require('./route-split.js');\n"
GATE_REQUIRE_NEW = (
    "const routeSplit = require('./route-split.js');\n"
    "const { initHoldMiddleware } = require('./init_hold.js'); // init-hold-v1\n"
)

GATE_ANCHOR = """  req.headers.authorization = `Bearer ${OR_API_KEY}`;   // /v1 转发用 OR_API_KEY
  next();
});
"""

GATE_INSERT = """  req.headers.authorization = `Bearer ${OR_API_KEY}`;   // /v1 转发用 OR_API_KEY
  next();
});

// init-hold-v1: PSK 已过才拦, 未认证仍是 401. 只挡 /v1, 不挡 /healthz.
app.use('/v1', initHoldMiddleware({
  hold: process.env.GATE_INIT_HOLD,
  runningFile: process.env.INIT_RUNNING_FILE || '/data/.init-running',
  failedFile: process.env.INIT_FAILED_FILE || '/data/.init-failed',
  log: (req, fields) => logGate(req, Object.assign({
    elapsedMs: Date.now() - (req._gateT0 || 0), destroyInitiator: null,
  }, fields)),
}));
"""

ENTRY_ANCHOR = """if [ -f /logic/init-nim-keys.sh ] && [ -n "${NIM_KEYS:-}" ]; then
  bash /logic/init-nim-keys.sh & INIT_PID=$!
  echo "[entrypoint] Init PID=$INIT_PID"
fi
"""

ENTRY_INSERT = """if [ -f /logic/init-nim-keys.sh ] && [ -n "${NIM_KEYS:-}" ]; then
  # init-hold-v1: 锁先于 init 出现, gate 起来时 /v1 还进不去.
  export GATE_INIT_HOLD=1
  export INIT_RUNNING_FILE="${DATA_DIR}/.init-running"
  export INIT_FAILED_FILE="${DATA_DIR}/.init-failed"
  rm -f "$INIT_FAILED_FILE"
  : > "$INIT_RUNNING_FILE"
  bash /logic/init-nim-keys.sh & INIT_PID=$!
  echo "[entrypoint] Init PID=$INIT_PID"
else
  rm -f "${DATA_DIR}/.init-running" "${DATA_DIR}/.init-failed"
fi
"""

LOOP_ANCHOR = """[ "$_init_logged" = 1 ] || { wait "$INIT_PID" 2>/dev/null && _init_rc=0 || _init_rc=$?; if [ "$_init_rc" -ne 0 ]; then echo "[entrypoint] ✗ NIM init 已退出 rc=$_init_rc (fail-closed 触发或异常)."; else echo "[entrypoint] NIM init 已退出 rc=0 (正常完成)."; fi; _init_logged=1; }"""

LOOP_INSERT = """[ "$_init_logged" = 1 ] || { wait "$INIT_PID" 2>/dev/null && _init_rc=0 || _init_rc=$?; if [ "$_init_rc" -ne 0 ]; then echo "[entrypoint] ✗ NIM init 已退出 rc=$_init_rc (fail-closed 触发或异常)."; : > "${INIT_FAILED_FILE:-$DATA_DIR/.init-failed}"; else echo "[entrypoint] NIM init 已退出 rc=0 (正常完成)."; rm -f "${INIT_FAILED_FILE:-$DATA_DIR/.init-failed}"; fi; rm -f "${INIT_RUNNING_FILE:-$DATA_DIR/.init-running}"; _init_logged=1; }"""


def _once(text: str, anchor: str, insert: str, label: str) -> str:
    if MARK in text and anchor not in text:
        return text
    if insert in text:
        return text
    if anchor not in text:
        raise SystemExit(f"{label}: anchor missing, refusing to guess")
    if text.count(anchor) != 1:
        raise SystemExit(f"{label}: anchor not unique")
    return text.replace(anchor, insert, 1)


def patch_gate(text: str) -> str:
    text = _once(text, GATE_REQUIRE, GATE_REQUIRE_NEW, "gate require")
    return _once(text, GATE_ANCHOR, GATE_INSERT, "gate middleware")


def patch_entrypoint(text: str) -> str:
    text = _once(text, ENTRY_ANCHOR, ENTRY_INSERT, "entrypoint start")
    return _once(text, LOOP_ANCHOR, LOOP_INSERT, "entrypoint loop")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--gate", type=Path)
    parser.add_argument("--entrypoint", type=Path)
    args = parser.parse_args()
    if args.gate:
        args.gate.write_text(patch_gate(args.gate.read_text(encoding="utf-8")), encoding="utf-8")
        print(f"[patch_init_hold] gate {args.gate}")
    if args.entrypoint:
        args.entrypoint.write_text(
            patch_entrypoint(args.entrypoint.read_text(encoding="utf-8")), encoding="utf-8"
        )
        print(f"[patch_init_hold] entrypoint {args.entrypoint}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
