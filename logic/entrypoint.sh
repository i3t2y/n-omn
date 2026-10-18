#!/bin/bash
# EMERGENCY (2026-10-18): entrypoint was clobbered during automated patch.
# helper.sh is fixed (never rewrites this file mid-boot).
# Restore the full entrypoint from git history on a machine with the repo:
#   git show 726168f:logic/entrypoint.sh > logic/entrypoint.sh
#   python3 logic/patch_db_local.py --entrypoint logic/entrypoint.sh || true
#   python3 logic/patch_init_hold.py --entrypoint logic/entrypoint.sh || true
#   bash -n logic/entrypoint.sh && git add logic/entrypoint.sh && git commit -m 'restore entrypoint' && git push
# Then sync Bucket and Restart.
set -euo pipefail
echo "[entrypoint] FATAL: full entrypoint.sh not in repo yet — restore from 726168f (see script header)" >&2
exit 2
