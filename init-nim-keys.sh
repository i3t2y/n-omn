#!/bin/bash
set -eo pipefail

# =============================================================
# NIM OmniRoute Initializer  v3.1.0
# 变更：
#   Fix-1  Compression 专用端点 + PATCH fallback
#   Fix-2  Model Cooldowns 清理（主流程，每次执行）
#   Fix-3  移除 minimax-m3
#   Fix-4  连接测试 POST /api/models/test-all + 串行回退
#   Fix-5  COMBO_STRATEGY 环境变量
#   Fix-6  末尾 health check 状态打印
#   Fix-7  NIM_COMPRESS_THRESHOLD 环境变量控制压缩阈值
# =============================================================

BASE_URL="${OMNIBASE_URL:-}"
COOKIE_FILE="/tmp/omniroute-cookies.txt"
INIT_MARKER="/tmp/omniroute-nim-initialized"
LOG_PREFIX="[init-nim v3.1.0]"

# ── 可配置环境变量 ────────────────────────────────────────────
# 压缩触发阈值（tokens）。NIM glm-5.1 context=131072，建议 10000~14000
# 设得越低，压缩越激进，长对话越稳定，但短对话会有轻微延迟开销
NIM_COMPRESS_THRESHOLD="${NIM_COMPRESS_THRESHOLD:-12000}"

# Combo 策略：round-robin | least-used | random
COMBO_STRATEGY="${COMBO_STRATEGY:-round-robin}"

# 并发请求数（NIM 免费层建议 3~5）
NIM_CONCURRENT="${NIM_CONCURRENT:-5}"

# 响应文件
RESILIENCE_RESP="/tmp/omni-resilience.json"
SETTINGS_RESP="/tmp/omni-settings.json"
COMPRESS_RESP="/tmp/omni-compress.json"
COMBO_RESP="/tmp/omni-combo.json"
COMBOS_LIST="/tmp/omni-combos-list.json"

log() { echo "$LOG_PREFIX $*"; }

# ── 1. 登录 ──────────────────────────────────────────────────
log "Logging in..."
LOGIN_CODE=$(curl -s -o /tmp/omni-login.json -w "%{http_code}" \
  -c "$COOKIE_FILE" \
  -X POST "$BASE_URL/api/auth/login" \
  -H "Content-Type: application/json" \
  -d "{\"password\": \"${OMNI_PASSWORD:-}\"}")
log "Login HTTP $LOGIN_CODE"
[ "$LOGIN_CODE" != "200" ] && { log "ERROR: Login failed"; exit 1; }

# ── 2. 幂等性检查 ─────────────────────────────────────────────
if [ -f "$INIT_MARKER" ]; then
  log "Marker found — skipping Key/Resilience/Settings/Combo registration."
  log "Running mandatory refresh (Cooldowns + Alias)..."
  INCREMENTAL=true
else
  INCREMENTAL=false
fi

# ── 3. NIM Key 注册（首次）──────────────────────────────────
if [ "$INCREMENTAL" = "false" ]; then
  log "Registering NIM API Keys..."
  KEY_INDEX=1
  while true; do
    KEY_VAR="NIM_KEY_${KEY_INDEX}"
    KEY_VAL="${!KEY_VAR:-}"
    [ -z "$KEY_VAL" ] && break
    REG_CODE=$(curl -s -o /dev/null -w "%{http_code}" \
      -b "$COOKIE_FILE" \
      -X POST "$BASE_URL/api/providers" \
      -H "Content-Type: application/json" \
      -d "{
        \"name\": \"NIM-Key-${KEY_INDEX}\",
        \"type\": \"nvidia\",
        \"apiKey\": \"$KEY_VAL\",
        \"baseUrl\": \"https://integrate.api.nvidia.com/v1\"
      }")
    log "Key $KEY_INDEX HTTP $REG_CODE"
    KEY_INDEX=$((KEY_INDEX + 1))
  done
  [ "$KEY_INDEX" -eq 1 ] && log "WARN: No NIM_KEY_* vars found."

  # ── 4. Resilience ─────────────────────────────────────────
  log "Applying Resilience config..."
  RESILIENCE_CODE=$(curl -s -o "$RESILIENCE_RESP" -w "%{http_code}" \
    -b "$COOKIE_FILE" \
    -X PATCH "$BASE_URL/api/resilience" \
    -H "Content-Type: application/json" \
    -d "{
      \"requestQueue\": {
        \"requestsPerMinute\": 35,
        \"minTimeBetweenRequestsMs\": 200,
        \"concurrentRequests\": $NIM_CONCURRENT
      }
    }")
  log "Resilience PATCH HTTP $RESILIENCE_CODE"

  # ── 5. 全局 Settings ──────────────────────────────────────
  log "Applying global settings..."
  SETTINGS_CODE=$(curl -s -o "$SETTINGS_RESP" -w "%{http_code}" \
    -b "$COOKIE_FILE" \
    -X PATCH "$BASE_URL/api/settings" \
    -H "Content-Type: application/json" \
    -d '{
      "fallbackStrategy": "round-robin",
      "stickyRoundRobinLimit": 1,
      "requestBodyLimit": 10485760
    }')
  log "Settings PATCH HTTP $SETTINGS_CODE"

  # ── 6. Compression（Fix-1：专用端点 + PATCH fallback）────
  log "Applying compression (threshold=${NIM_COMPRESS_THRESHOLD} tokens)..."
  COMPRESS_BODY="{
    \"enabled\": true,
    \"defaultMode\": \"stacked\",
    \"autoTriggerTokens\": $NIM_COMPRESS_THRESHOLD
  }"

  # 优先尝试 v3.8 专用端点
  COMPRESS_CODE=$(curl -s -o "$COMPRESS_RESP" -w "%{http_code}" \
    -b "$COOKIE_FILE" \
    -X PUT "$BASE_URL/api/settings/compression" \
    -H "Content-Type: application/json" \
    -d "$COMPRESS_BODY")
  log "Compression PUT HTTP $COMPRESS_CODE"

  # Fix-1 fallback：若 PUT 返回 404/405，回退到旧版 PATCH /api/settings
  if [ "$COMPRESS_CODE" = "404" ] || [ "$COMPRESS_CODE" = "405" ]; then
    log "WARN: Dedicated compression endpoint unavailable, falling back to PATCH /api/settings..."
    FB_CODE=$(curl -s -o /dev/null -w "%{http_code}" \
      -b "$COOKIE_FILE" \
      -X PATCH "$BASE_URL/api/settings" \
      -H "Content-Type: application/json" \
      -d "{
        \"compression\": {
          \"enabled\": true,
          \"defaultMode\": \"stacked\",
          \"autoTriggerTokens\": $NIM_COMPRESS_THRESHOLD
        }
      }")
    log "Compression PATCH fallback HTTP $FB_CODE"
  fi

  # ── 7. Thinking Budget ────────────────────────────────────
  log "Setting thinking budget..."
  TB_CODE=$(curl -s -o /dev/null -w "%{http_code}" \
    -b "$COOKIE_FILE" \
    -X PUT "$BASE_URL/api/settings/thinking-budget" \
    -H "Content-Type: application/json" \
    -d '{
      "mode": "adaptive",
      "maxTokens": 8000,
      "enabled": true
    }')
  log "Thinking budget PUT HTTP $TB_CODE"

fi  # end INCREMENTAL=false

# ── 8. 双重 Resilience 清理（每次启动，Fix-2）───────────────
log "Resetting circuit breakers..."
CB_CODE=$(curl -s -o /dev/null -w "%{http_code}" \
  -b "$COOKIE_FILE" \
  -X POST "$BASE_URL/api/resilience/reset")
log "Circuit breaker reset HTTP $CB_CODE"

log "Clearing model cooldowns..."
MC_CODE=$(curl -s -o /dev/null -w "%{http_code}" \
  -b "$COOKIE_FILE" \
  -X DELETE "$BASE_URL/api/resilience/model-cooldowns" \
  -H "Content-Type: application/json" \
  -d '{"all": true}')
log "Model cooldowns clear HTTP $MC_CODE"

# ── 9. 连接测试（Fix-4：test-all + 串行回退）────────────────
log "Running connection test (POST /api/models/test-all)..."
TESTALL_CODE=$(curl -s -o /tmp/omni-testall.json -w "%{http_code}" \
  -b "$COOKIE_FILE" \
  -X POST "$BASE_URL/api/models/test-all" \
  -H "Content-Type: application/json" \
  --max-time 30)
log "test-all HTTP $TESTALL_CODE"

# Fix-4 fallback：若 test-all 不支持，串行测试每个关键模型
if [ "$TESTALL_CODE" = "404" ] || [ "$TESTALL_CODE" = "405" ]; then
  log "test-all unavailable, running serial model tests..."
  SERIAL_MODELS=(
    "z-ai/glm-5.1"
    "qwen/qwen3-coder-480b-a35b-instruct"
    "moonshotai/kimi-k2-thinking"
  )
  for MODEL_ID in ""; do
    TEST_CODE=$(curl -s -o /dev/null -w "%{http_code}" \
      -b "$COOKIE_FILE" \
      -X POST "$BASE_URL/api/models/test" \
      -H "Content-Type: application/json" \
      -d "{\"modelId\": \"$MODEL_ID\"}" \
      --max-time 15)
    log "  Serial test [$MODEL_ID] HTTP $TEST_CODE"
  done
fi

# ── 10. Model Alias 注册（每次刷新）─────────────────────────
log "Registering model aliases..."
declare -A ALIASES=(
  ["nim-glm"]="z-ai/glm-5.1"
  ["nim-qwen"]="qwen/qwen3-coder-480b-a35b-instruct"
  ["nim-kimi"]="moonshotai/kimi-k2-thinking"
  ["nim-kimi2"]="moonshotai/kimi-k2.6"
  ["nim-nemotron"]="nvidia/nemotron-3-super-120b-a12b"
  ["nim-mistral"]="mistralai/mistral-medium-3.5-128b"
)
for ALIAS_NAME in ""; do
  ALIAS_TARGET="${ALIASES[$ALIAS_NAME]}"
  ALIAS_CODE=$(curl -s -o /dev/null -w "%{http_code}" \
    -b "$COOKIE_FILE" \
    -X POST "$BASE_URL/api/models/alias" \
    -H "Content-Type: application/json" \
    -d "{\"alias\": \"$ALIAS_NAME\", \"target\": \"$ALIAS_TARGET\"}")
  log "Alias '$ALIAS_NAME' → '$ALIAS_TARGET' HTTP $ALIAS_CODE"
done

# ── 11. Combo 创建（首次，Fix-5：COMBO_STRATEGY 变量）───────
if [ "$INCREMENTAL" = "false" ]; then
  log "Creating Combo nim-pool (strategy=${COMBO_STRATEGY})..."
  COMBO_CODE=$(curl -s -o "$COMBO_RESP" -w "%{http_code}" \
    -b "$COOKIE_FILE" \
    -X POST "$BASE_URL/api/combos" \
    -H "Content-Type: application/json" \
    -d "{
      \"name\": \"nim-pool\",
      \"strategy\": \"$COMBO_STRATEGY\",
      \"models\": [
        \"z-ai/glm-5.1\",
        \"qwen/qwen3-coder-480b-a35b-instruct\",
        \"moonshotai/kimi-k2-thinking\",
        \"moonshotai/kimi-k2.6\",
        \"nvidia/nemotron-3-super-120b-a12b\",
        \"mistralai/mistral-medium-3.5-128b\",
        \"mistralai/mistral-small-4-119b-2603\",
        \"minimaxai/minimax-m2.7\",
        \"meta/llama-3.2-90b-vision-instruct\"
      ]
    }")
  log "Combo nim-pool HTTP $COMBO_CODE"
fi

# ── 12. Health Check（Fix-6：结构化状态打印）─────────────────
log "─────────────────────────────────────────"
log "Final health check..."
HEALTH=$(curl -s -b "$COOKIE_FILE" \
  "$BASE_URL/api/monitoring/health" 2>/dev/null)

# 提取关键字段并格式化打印
STATUS=$(echo "$HEALTH"    | jq -r '.status    // "unknown"' 2>/dev/null)
VERSION=$(echo "$HEALTH"   | jq -r '.version   // "unknown"' 2>/dev/null)
CFG_CNT=$(echo "$HEALTH"   | jq -r '.configuredCount // "?"' 2>/dev/null)
ACT_CNT=$(echo "$HEALTH"   | jq -r '.activeCount    // "?"' 2>/dev/null)
UPTIME=$(echo "$HEALTH"    | jq -r '.uptime    // "unknown"' 2>/dev/null)

log "  Status  : $STATUS"
log "  Version : $VERSION"
log "  Keys    : $ACT_CNT active / $CFG_CNT configured"
log "  Uptime  : $UPTIME"
log "  Compress: threshold=${NIM_COMPRESS_THRESHOLD} mode=stacked"
log "  Combo   : strategy=${COMBO_STRATEGY}"
log "─────────────────────────────────────────"

touch "$INIT_MARKER"
log "Done. v3.1.0"
log ""
log "Claude Code 快速配置："
log "  主力: z-ai/glm-5.1  (alias: nim-glm)"
log "  备用: nim-pool combo (按需，非强制)"
log ""
log "环境变量调参："
log "  NIM_COMPRESS_THRESHOLD  当前=${NIM_COMPRESS_THRESHOLD}  建议范围 10000~16000"
log "  COMBO_STRATEGY          当前=${COMBO_STRATEGY}  可选 round-robin|least-used|random"
log "  NIM_CONCURRENT          当前=${NIM_CONCURRENT}  NIM 免费层建议 3~5"
