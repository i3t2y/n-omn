import subprocess, re, sys, base64, os
repo, path = sys.argv[1], sys.argv[2]
outfile = sys.argv[3] if len(sys.argv) > 3 else None
out = subprocess.run(['cnb','git','get-content','--repo',repo,'--file-path',path],
                     capture_output=True, text=True, encoding='utf-8', errors='replace').stdout
m = re.search(r'^  content: (\S+)\s*$', out, re.M)
if not m:
    print('[NOT-BLOB] ' + path); print(out[:1500]); sys.exit(2)
data = base64.b64decode(m.group(1))
if outfile:
    with open(outfile,'wb') as f: f.write(data)
    print(f'[ok] {path} -> {outfile} ({len(data)} bytes)')
else:
    sys.stdout.write(data.decode('utf-8','replace'))
