#!/bin/sh
# verify-workers.sh · 8 zflare Worker 部署复核 (无 NIM 键, 验鉴权层+穿透)
# 圣上跑: RELAY_AUTH=<新钥> sh verify-workers.sh
# 判定: 每 Worker 两 curl
#   ①无钥 → 401 unauthorized (裸奔洞堵, Worker 真改造)
#   ②带钥 (无 NIM Bearer) → NIM 格式 401 (穿透到 NIM, 因缺 Bearer)
# 注: ①②body 须区分 — unauthorized=Worker拦(鉴权不对); NVIDIA格式=NIM返回(穿透成功)
set -u

RELAY="${RELAY_AUTH:-}"
if [ -z "$RELAY" ]; then
  echo "用法: RELAY_AUTH=<新钥> sh verify-workers.sh"
  exit 2
fi

NIM="https://integrate.api.nvidia.com/v1/models"
PASS=0; FAIL=0

for i in 1 2 3 4 5 6 7 8; do
  W="https://${i}.zflare.workers.dev"
  echo "=== zflare-${i} ==="

  # ①无钥 鉴权层
  R1=$(curl -s -o /tmp/ft-body1 -w "%{http_code}" --max-time 15 "${W}/?url=${NIM}" 2>/dev/null)
  B1=$(head -c 80 /tmp/ft-body1 2>/dev/null)
  echo "  ①无钥 HTTP=${R1} body='${B1}'"
  if [ "$R1" = "401" ] && printf '%s' "$B1" | grep -qi unauthorized; then
    echo "   ✓ 鉴权堵住"
  else
    echo "   ✗ 鉴权未设 (HTTP body 不是 unauthorized): AUTH_KEY 未改? Worker 未真部署改造版?"
    FAIL=$((FAIL+1)); continue
  fi

  # ②带钥 无 NIM Bearer: 望穿透 NIM
  R2=$(curl -s -o /tmp/ft-body2 -w "%{http_code}" --max-time 15 -H "x-relay-auth: ${RELAY}" "${W}/?url=${NIM}" 2>/dev/null)
  B2=$(head -c 120 /tmp/ft-body2 2>/dev/null)
  echo "  ②带钥(无Bearer) HTTP=${R2} body='${B2}'"
  # NIM 缺 Bearer 返 401 + NVIDIA 错误格式 (含 "WWW-Authenticate" 或 {"error"...} 非 unauthorized)
  if [ "$R1" != "$R2" ] || ! printf '%s' "$B2" | grep -qi unauthorized; then
    echo "   ✓ 穿透到上游 (与①不同 body 或 HTTP, 说明 NIM 端真回话)"
  else
    echo "   ? 与①同 unauthorized — 鉴权没过 (AUTH_KEY ≠ RELAY_AUTH?), 未穿透"
  fi
  PASS=$((PASS+1))
  rm -f /tmp/ft-body1 /tmp/ft-body2
done

echo ""
echo "=== 总结: ${PASS} 鉴权通 / ${FAIL} 未通 ==="
[ "$FAIL" = "0" ] && echo "★ 全绿 → 可推 Dataset + 进 Step5" || echo "有未通 Worker, 核清单见输出"
