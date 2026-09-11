#!/usr/bin/env bash
# 用法: ./fetch.sh <repo> <file-path> [outfile]
repo="$1"; p="$2"; out="${3:-cache/$(basename "$p")}"
mkdir -p cache
cnb git get-content --repo "$repo" --file-path "$p" > "cache/.raw.tmp" 2>&1
python - "$p" "$out" <<'PY'
import re, base64, sys
p, out = sys.argv[1], sys.argv[2]
t = open('cache/.raw.tmp', encoding='utf-8', errors='replace').read()
m = re.search(r'^  content: (\S+)\s*$', t, re.M)
if not m:
    print('[NOT-BLOB]', p); print(t[:600]); sys.exit(2)
open(out, 'wb').write(base64.b64decode(m.group(1)))
print('[ok]', p, '->', out)
PY
