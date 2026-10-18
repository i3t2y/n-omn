#!/usr/bin/env python3
"""Wire db_local_boot.sh into entrypoint.sh (idempotent).

NOTE (2026-10-18): logic/entrypoint.sh in git now bakes the db-local block in
directly, and helper.sh no longer invokes this at boot (runtime patching of
entrypoint.sh can neither affect the running process nor survive the next
Bucket re-pull). Kept for manual backfill use only.

Writes are atomic (tmp + os.replace): never truncate a file a running
interpreter may hold open.
"""
from __future__ import annotations

import argparse
import os
from pathlib import Path


def atomic_write(path: Path, text: str) -> None:
    """Write via temp file + os.replace (see patch_init_hold.py)."""
    tmp = path.with_name(path.name + ".tmp")
    tmp.write_text(text, encoding="utf-8")
    os.replace(tmp, path)

MARK = "db-local-v1"

# After DATA_DIR is set and exported — before DB_PATH / restore.
ANCHOR = 'export DATA_DIR   # 须 export: init/scheduler 子进程须见同值 (_raw 路径两端对齐, 否子进程回默认 /data 歧义)\n'

INSERT = '''export DATA_DIR   # 须 export: init/scheduler 子进程须见同值 (_raw 路径两端对齐, 否子进程回默认 /data 歧义)

# db-local-v1: 活库改本地盘, Bucket 只留快照 (治 FUSE+WAL 坏库)
if [ -f /logic/db_local_boot.sh ]; then
  OMN_BUCKET_DATA="${DATA_DIR}"
  # shellcheck disable=SC1091
  . /logic/db_local_boot.sh || echo "[entrypoint] WARN: db_local_boot failed"
fi
'''

# Harden must target the live path after dual-disk.
HARDEN_ANCHOR = None  # optional; entrypoint may call db_harden elsewhere


def patch(text: str) -> str:
    if MARK in text:
        return text
    if ANCHOR not in text:
        raise SystemExit("entrypoint: DATA_DIR export anchor missing")
    if text.count(ANCHOR) != 1:
        raise SystemExit("entrypoint: DATA_DIR export anchor not unique")
    return text.replace(ANCHOR, INSERT, 1)


def main() -> int:
    p = argparse.ArgumentParser()
    p.add_argument("--entrypoint", type=Path, required=True)
    args = p.parse_args()
    raw = args.entrypoint.read_text(encoding="utf-8")
    new = patch(raw)
    if new != raw:
        atomic_write(args.entrypoint, new)
        print(f"[patch_db_local] patched {args.entrypoint}")
    else:
        print(f"[patch_db_local] already ok {args.entrypoint}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
