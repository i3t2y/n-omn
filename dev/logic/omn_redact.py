"""omn-redact · 单一脱敏引擎 lib
圣上令 2026-07-28: 脱敏公式变量化, 单 ENV 管道分隔多正则 + 硬默认六条 ENV 空跑默认设则覆盖.
复用现役 init-nim-keys.sh:975-981 sed 五正则真逻辑迁移 python re + secret-scan PSK 头类.

消费链:
  - init-nim-keys.sh hf_snapshot() 新链 (stdout 自抓 + DB 表快照)
  - omn-scheduler.py capture_stdout / capture_db
  - 路2 加密前 (源 = 路1 已 redact 文本, tar 前已脱敏 = 加密保机密不破保真)
  - omn-bucket-sync.py 错误日志脱敏 (boto3 错误可能含 endpoint/key 片段)
"""
import os
import re

# ── 硬默认七正则 (现役 init:976-980 五条 + secret-scan PSK 头类 + R2 endpoint) ──
#   捕获组形式: 保留前缀 (Authorization: Bearer / NIM_KEY= / endpoint= 等) + 替后段为 <REDACTED>.
#   与 init:975-981 sed -E 's/(前缀)[模式]/\1<REDACTED>/g' 语义对等 (python re.sub \\1 == sed \\1).
#   第7条 R2 endpoint: litestream日志含 `endpoint=https://<32hex>.r2.cloudflarestorage.com`
#   = Cloudflare R2 account-id hash (非签字凭, S3签字用access-key-id+secret-key在Authorization
#   header非endpoint; 但account-id可关联bucket =隐私面, repo虽private仍扫入默). 捕前缀 endpoint= + #替host段.
DEFAULT_PATTERNS = [
    r'(Authorization:[ \t]*Bearer[ \t]+)[A-Za-z0-9._\-]+',   # init:976
    r'(NIM_KEY=|nvapi-)[A-Za-z0-9._\-]+',                    # init:977
    r'(Cookie:[ \t]+)[^ \t]+',                               # init:978
    r'(Set-Cookie:[ \t]+)[^ \t]+',                           # init:979
    r'(Bearer )[A-Za-z0-9._\-]+',                           # init:980
    r'(X-Internal-PSK["\']?\s*[:=]\s*["\']?)[A-Za-z0-9_\-]+',  # secret-scan PSK 头类
    r'(endpoint=https?://)[A-Za-z0-9._-]+\.r2\.cloudflarestorage\.com',  # R2 account-id hash (2026-08-01 litestream件隐私面)
]
REPLACEMENT = r'\1<REDACTED>'

_patterns_cache = None


def load_patterns():
    """读 REDACT_PATTERNS ENV 管道分隔多正则; ENV 空 -> 硬默认六条; ENV 设 -> 完全覆盖非追加.
    返回编译后 re.Pattern list (复用避免每调重编译)."""
    global _patterns_cache
    if _patterns_cache is not None:
        return _patterns_cache
    env = os.environ.get("REDACT_PATTERNS", "").strip()
    if env:
        # 管道分隔; 正则内若需 | 须 \| 转义 (圣上配置时明示)
        pats = [p for p in env.split("|") if p.strip()]
    else:
        pats = list(DEFAULT_PATTERNS)  # 圣上决策 ENV 空跑默认六条
    _patterns_cache = [re.compile(p) for p in pats]
    return _patterns_cache


def reload_patterns():
    """ENV 变动后强制重读 (dev 调试用)."""
    global _patterns_cache
    _patterns_cache = None
    return load_patterns()


def redact_text(text, compiled_patterns=None):
    """对 text 依次跑所有正则 -> <REDACTED>. text None/空原样返回. compiled_patterns 可传入复用."""
    if not text:
        return text
    pats = compiled_patterns if compiled_patterns is not None else load_patterns()
    for pat in pats:
        text = pat.sub(REPLACEMENT, text)
    return text
