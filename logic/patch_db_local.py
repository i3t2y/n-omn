#!/usr/bin/env python3
"""Wire db_local_boot.sh into entrypoint.sh (idempotent).

Must run before OmniRoute opens storage.sqlite. helper.sh invokes this so the
*next* Restart picks it up; if already patched, current file is used as-is.
"""
from __future__ import annotations

import argparse
from pathlib import Path

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
        args.entrypoint.write_text(new, encoding="utf-8")
        print(f"[patch_db_local] patched {args.entrypoint}")
    else:
        print(f"[patch_db_local] already ok {args.entrypoint}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
