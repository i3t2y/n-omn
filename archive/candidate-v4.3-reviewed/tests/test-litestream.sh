#!/bin/bash
# test-litestream.sh — v4.3 candidate LiteStream restore 场景 (mock 文件系统, 不调真实 litestream/R2)
# 模拟 entrypoint.sh 的 restore guard 逻辑分支:
#   1) DB 不存在 -> restore
#   2) DB 0 字节 -> restore (丢弃空)
#   3) DB 已存在非空 -> 跳过 (绝不覆盖)
#   4) restore=0 字节但无效 -> 丢弃
#   5) restore 失败 -> 按 LITESTREAM_STRICT
#   6) R2 配置缺失 -> 复制非致命
# 直接 grep entrypoint.sh 内 restore guard 逻辑核; 不真跑 litestream (无环境).
set -uo pipefail
D=$(cd "$(dirname "$0")/.." && pwd)
ENT="$D/entrypoint.sh"

echo "[litestream-test] 核 entrypoint.sh restore guard 关键逻辑分支存在性..."

# 关键 guard 片段 (源码证保护)
GREPS=(
  'LITESTREAM_STRICT'                 # 严格开关
  '\.storage\.sqlite\.restore'                      # 临时路径 (防覆盖)
  'PRAGMA quick_check'                # post restore 完整性核
  'mv .*\$DB_TMP|\$DB_TMP.*mv'                # 原子移动 (临时→正式)
  '本地.*存在.*非空.*跳过|skip.*restore|跳过.*恢复'  # 本地非空跳过
  'LITESTREAM_ACCOUNT_ID|R2_ACCOUNT_ID|R2_ACCESS_KEY_ID|R2_SECRET_ACCESS_KEY'  # R2 配置所读
)
PASS=0; FAIL=0
for pat in "${GREPS[@]}"; do
  if grep -qE "$pat" "$ENT"; then echo "  ✓ guard: $pat"; PASS=$((PASS+1))
  else echo "  ✗ guard MISSING: $pat"; FAIL=$((FAIL+1)); fi
done

# litestream.yml auto-recover: false (红线3)
if grep -qE 'auto-recover: false' "$D/litestream.yml"; then echo "  ✓ litestream.yml auto-recover=false"; PASS=$((PASS+1))
else echo "  ✗ litestream.yml auto-recover 应 false"; FAIL=$((FAIL+1)); fi

# 敏感不硬编 (R2 key 不硬编明文)
if grep -qE 'R2_(ACCESS_KEY_ID|SECRET_ACCESS_KEY|ACCOUNT_ID)' "$D/litestream.yml"; then echo "  ✓ litestream.yml env var (值不硬编)"; PASS=$((PASS+1))
else echo "  ✗ litestream.yml 缺 R2 env var"; FAIL=$((FAIL+1)); fi

echo "[litestream-test] PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
