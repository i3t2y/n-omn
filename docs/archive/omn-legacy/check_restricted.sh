#!/bin/bash
SPACE_URL="$1"
PSK="$2"

MODELS=(
  "moonshotai/kimi-k2.6"
  "minimaxai/minimax-m2.7"
  "qwen/qwen3-next-80b-a3b-instruct"
  "nvidia/nemotron-3-ultra-550b-a55b"
  "01-ai/yi-large"
)

echo "============================================"
echo "  RESTRICTED 模型权限验证（nvidia/ 前缀版）"
echo "  目标: $SPACE_URL"
echo "  时间: $(date '+%Y-%m-%d %H:%M:%S')"
echo "============================================"
echo ""

PASS=0; FAIL=0; OTHER=0

for MODEL in "${MODELS[@]}"; do
  ROUTING_NAME="nvidia/${MODEL}"
  RESP=$(curl -s -w "\n%{http_code}" \
    -X POST "$SPACE_URL/v1/chat/completions" \
    -H "Authorization: Bearer $PSK" \
    -H "Content-Type: application/json" \
    -d "{\"model\":\"$ROUTING_NAME\",\"messages\":[{\"role\":\"user\",\"content\":\"hi\"}],\"max_tokens\":5}" \
    --max-time 30)

  HTTP_CODE=$(echo "$RESP" | tail -n1)
  BODY=$(echo "$RESP" | sed '$d')

  case "$HTTP_CODE" in
    200)
      echo "✅ $MODEL → HTTP 200（权限充足）"
      PASS=$((PASS+1))
      ;;
    403)
      ERR_MSG=$(echo "$BODY" | jq -r '.error.message // .detail // .message // "无错误详情"' 2>/dev/null || echo "无错误详情")
      echo "❌ $MODEL → HTTP 403（权限不足）"
      echo "   详情: $ERR_MSG"
      FAIL=$((FAIL+1))
      ;;
    429)
      echo "⚠️  $MODEL → HTTP 429（速率限制，稍后重试）"
      OTHER=$((OTHER+1))
      ;;
    500|502|503)
      echo "⚠️  $MODEL → HTTP $HTTP_CODE（上游错误）"
      OTHER=$((OTHER+1))
      ;;
    *)
      echo "❓ $MODEL → HTTP $HTTP_CODE"
      echo "   响应: $(echo "$BODY" | head -c 300)"
      OTHER=$((OTHER+1))
      ;;
  esac
done

echo ""
echo "============================================"
echo "  汇总: ✅ $PASS 通过 / ❌ $FAIL 失败 / ⚠️ $OTHER 其他"
echo "============================================"

if [ "$FAIL" -gt 0 ]; then
  echo "建议: 将 NIM_PROFILE 改为 balanced 以排除失败的模型"
elif [ "$PASS" -eq 5 ]; then
  echo "全部通过，NIM_PROFILE=full 可持续使用"
fi
