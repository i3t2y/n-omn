#!/usr/bin/env python3
"""PreToolUse secret-scan: 扫Bash/Write/Edit载荷, 命中密钥形态exit 2拦截。
env占位(${VAR})、短占位(nvapi-xxx)放行; stdin非JSON时fail-open(无可扫内容)。"""
import json, re, sys

PATTERNS = [
    ("NIM key",  re.compile(r'nvapi-[A-Za-z0-9_\-]{20,}')),
    ("PSK 头明文", re.compile(r'X-Internal-PSK["\']?\s*[:=]\s*["\']?(?!\$\{|\$\(|<)[A-Za-z0-9_\-]{16,}')),
    ("Bearer 明文", re.compile(r'Bearer\s+(?!\$\{|\$\(|<)[A-Za-z0-9_\-]{20,}')),
]

def main():
    try:
        payload = json.load(sys.stdin)
    except Exception:
        sys.exit(0)
    text = json.dumps(payload.get("tool_input") or {}, ensure_ascii=False)
    if not text or text == "{}":
        sys.exit(0)
    for name, pat in PATTERNS:
        if pat.search(text):
            sys.stderr.write(f"[secret-scan] BLOCKED: 命中 {name} 形态。改用env占位后重试; 如为误伤请报Supreme裁决。\n")
            sys.exit(2)
    sys.exit(0)

main()
