#!/bin/bash
set -eo pipefail

# =============================================================
# NIM OmniRoute Initializer
# v3.1.0 — 全环境变量化版（忠于 v3.0.1 逻辑）
#
# 变更日志：
#   v3.0.1  基础版本（生产验证）
#   v3.1.0  在 v3.0.1 基础上最小化升级：
#           Fix-1: Compression 改用 PUT /api/settings/compression + PATCH fallback
#           Fix-2: 新增 DELETE /api/resilience/model-cooldowns（每次启动执行）
#           Fix-3: 移除 minimax-m3（NIM 不托管）
#           Fix-4: 新增 Thinking Budget 配置
#           Fix-5: 所有调参环境变量化（NIM_RPM/NIM_CONCURRENT 等）
#           Fix-6: Health check 结构化打印
#           Fix-7: Model Alias 注册（首次）
#           保留：NIM_KEYS 多行单变量解析、OR_API_KEY 持久化、
#                 jq 构建 body、按 Provider ID 逐个测试、
#                 INIT_MARKER 幂等逻辑（与原版一致）
# =============================================================

# ── OmniRoute 服务配置 ────────────────────────────────────────
if [ -z "$OMNIROUTE_PORT" ]; then
  OMNIROUTE_PORT=20128
fi
BASE_URL="http://127.0.0.1:$OMNIROUTE_PORT"

# ── 持久化路径（与原版一致）──────────────────────────────────
INIT_MARKER="/data/.init-done"
OR_API_KEY_FILE="/data/.or-api-key"
COOKIE_FILE="/tmp/omniroute-cookie.txt"

# ── 临时文件 ──────────────────────────────────────────────────
LOGIN_RESP_FILE="/tmp/omniroute-login.json"
KEY_RESP_FILE="/tmp/omniroute-key-response.json"
PROVIDERS_FILE="/tmp/omniroute-providers.json"
RESILIENCE_GET_FILE="/tmp/omniroute-resilience-get.json"
RESILIENCE_RESP_FILE="/tmp/omniroute-resilience-response.json"
SETTINGS_GET_FILE="/tmp/omniroute-settings-get.json"
SETTINGS_RESP_FILE="/tmp/omniroute-settings-response.json"
COMPRESS_RESP_FILE="/tmp/omniroute-compress-response.json"
COMBO_RESP_FILE="/tmp/omniroute-combo-response.json"
VERSION_FILE="/tmp/omniroute-version.json"

# ── 可调参数（全部从环境变量读取，HF Space Secrets 注入）──────
# Resilience / 请求队列
NIM_RPM=""                    # 整体出站 RPM（25 Key 推荐 120）
NIM_MIN_INTERVAL_MS=""        # 请求间最小间隔 ms（推荐 100）
NIM_CONCURRENT=""             # 并发连接数（25 Key 推荐 15）

# 全局路由 Settings
NIM_FALLBACK_STRATEGY=""      # 推荐 round-robin
NIM_STICKY_LIMIT=""           # 推荐 1
NIM_REQUEST_BODY_LIMIT=""     # 推荐 10485760（10MB）

# 压缩配置
NIM_COMPRESS_THRESHOLD=""     # 推荐 12000（glm-5.1 安全阈值）
NIM_COMPRESS_MODE=""          # 推荐 stacked

# Thinking Budget
NIM_THINKING_BUDGET=""        # 推荐 8000
NIM_THINKING_MODE=""          # 推荐 adaptive

# Combo 策略
COMBO_STRATEGY=""             # 推荐 round-robin

# ── 计数器 ────────────────────────────────────────────────────
REGISTERED=0
SKIPPED=0
FAILED=0
PROVIDER_IDS=()

echo "[init] Starting NIM OmniRoute initializer v3.1.0..."
echo "[init] BASE_URL=$BASE_URL"

# ── 必要环境变量检查 ──────────────────────────────────────────
if [ -z "$INITIAL_PASSWORD" ]; then
  echo "[init] ERROR: INITIAL_PASSWORD is required"
  exit 1
fi

if [ -z "$NIM_KEYS" ]; then
  echo "[init] ERROR: NIM_KEYS is required"
  exit 1
fi

# ── 等待 OmniRoute 就绪 ───────────────────────────────────────
echo "[init] Waiting for OmniRoute to start..."
until curl -sf "$BASE_URL/api/monitoring/health" > /dev/null 2>&1; do
  sleep 3
done
echo "[init] OmniRoute is up."

# ── 版本探测 ──────────────────────────────────────────────────
VERSION_HTTP=$(curl -s -o "$VERSION_FILE" -w "%{http_code}" \
  "$BASE_URL/api/monitoring/health" 2>/dev/null || echo "000")
if [ "$VERSION_HTTP" = "200" ]; then
  OR_VERSION=$(jq -r '.version // "unknown"' "$VERSION_FILE" 2>/dev/null || echo "unknown")
  echo "[init] OmniRoute version: $OR_VERSION"
else
  echo "[init] WARN: Could not fetch version (HTTP $VERSION_HTTP)"
fi

# ── 登录 ──────────────────────────────────────────────────────
echo "[init] Logging in..."
LOGIN_HTTP=$(curl -s -o "$LOGIN_RESP_FILE" -w "%{http_code}" \
  -c "$COOKIE_FILE" \
  -X POST "$BASE_URL/api/auth/login" \
  -H "Content-Type: application/json" \
  -d "{\"password\":\"$INITIAL_PASSWORD\"}")

if [ "$LOGIN_HTTP" != "200" ] && [ "$LOGIN_HTTP" != "201" ]; then
  echo "[init] ERROR: Login failed, HTTP $LOGIN_HTTP"
  cat "$LOGIN_RESP_FILE" || true
  exit 1
fi
if ! grep -q "auth_token" "$COOKIE_FILE" 2>/dev/null; then
  echo "[init] ERROR: Login failed, no auth_token cookie received"
  exit 1
fi
echo "[init] Logged in, token acquired."

# ── 创建或复用 OmniRoute 内部 API Key ────────────────────────
if [ -f "$OR_API_KEY_FILE" ] && [ -s "$OR_API_KEY_FILE" ]; then
  echo "[init] OR_API_KEY file already exists, skipping creation."
else
  echo "[init] Creating OmniRoute API Key via /api/keys..."
  KEY_HTTP=$(curl -s -o "$KEY_RESP_FILE" -w "%{http_code}" \
    -b "$COOKIE_FILE" \
    -X POST "$BASE_URL/api/keys" \
    -H "Content-Type: application/json" \
    -d '{"name":"gate-internal","expiresAt":null}')

  if [ "$KEY_HTTP" = "200" ] || [ "$KEY_HTTP" = "201" ]; then
    OR_API_KEY_VALUE=$(jq -r '.key // empty' "$KEY_RESP_FILE")
    if [ -z "$OR_API_KEY_VALUE" ] || [ "$OR_API_KEY_VALUE" = "null" ]; then
      echo "[init] ERROR: Created key but could not parse key field."
      cat "$KEY_RESP_FILE" || true
      exit 1
    fi
    echo "$OR_API_KEY_VALUE" > "$OR_API_KEY_FILE"
    chmod 600 "$OR_API_KEY_FILE"
    echo "[init] OR_API_KEY written to $OR_API_KEY_FILE"
  else
    echo "[init] ERROR: /api/keys returned HTTP $KEY_HTTP"
    cat "$KEY_RESP_FILE" || true
    exit 1
  fi
fi

# ── NIM Keys 批量注册（从多行单变量 NIM_KEYS 解析）───────────
echo "[init] Registering NIM provider keys..."
INDEX=1
while IFS= read -r RAW_KEY; do
  KEY=$(printf '%s' "$RAW_KEY" | tr -d '\r' | xargs)
  [ -z "$KEY" ] && continue

  NAME=$(printf "nim-%02d" "$INDEX")
  RESP_FILE="/tmp/omniroute-provider-$INDEX.json"

  BODY=$(jq -n \
    --arg provider "nvidia" \
    --arg apiKey "$KEY" \
    --arg name "$NAME" \
    '{
      provider: $provider,
      apiKey: $apiKey,
      name: $name,
      priority: 1,
      testStatus: "unknown"
    }')

  HTTP_CODE=$(curl -s -o "$RESP_FILE" -w "%{http_code}" \
    -b "$COOKIE_FILE" \
    -X POST "$BASE_URL/api/providers" \
    -H "Content-Type: application/json" \
    -d "$BODY")

  if [ "$HTTP_CODE" = "201" ] || [ "$HTTP_CODE" = "200" ]; then
    echo "[init] $NAME registered OK"
    REGISTERED=$((REGISTERED + 1))
  elif [ "$HTTP_CODE" = "409" ]; then
    echo "[init] $NAME already exists, skipped"
    SKIPPED=$((SKIPPED + 1))
  else
    echo "[init] $NAME unexpected HTTP $HTTP_CODE"
    cat "$RESP_FILE" || true
    FAILED=$((FAILED + 1))
  fi
  INDEX=$((INDEX + 1))
done <<< "$NIM_KEYS"

echo "[init] Keys: $REGISTERED registered, $SKIPPED skipped, $FAILED failed."

# ── 读取所有 NVIDIA Provider IDs ─────────────────────────────
echo "[init] Fetching NVIDIA provider IDs..."
PROVIDERS_HTTP=$(curl -s -o "$PROVIDERS_FILE" -w "%{http_code}" \
  -b "$COOKIE_FILE" \
  "$BASE_URL/api/providers")

if [ "$PROVIDERS_HTTP" = "200" ]; then
  mapfile -t PROVIDER_IDS < <(
    jq -r '
      [.. | objects | select((.provider? // "") == "nvidia") |
       select((.id? // "") != "") | .id] | unique | .[]
    ' "$PROVIDERS_FILE" 2>/dev/null
  )
else
  echo "[init] WARN: /api/providers returned HTTP $PROVIDERS_HTTP"
fi
PROVIDER_COUNT=${#PROVIDER_IDS[@]}
echo "[init] Provider IDs collected: $PROVIDER_COUNT"

# ── Resilience 配置（先 GET 打印，再差量 PATCH）───────────────
echo "[init] Fetching current Resilience schema (for debug)..."
RESILIENCE_GET_HTTP=$(curl -s -o "$RESILIENCE_GET_FILE" -w "%{http_code}" \
  -b "$COOKIE_FILE" \
  "$BASE_URL/api/resilience")
echo "[init] Resilience GET HTTP $RESILIENCE_GET_HTTP"
if [ "$RESILIENCE_GET_HTTP" = "200" ]; then
  echo "[init] Current resilience schema:"
  jq '.' "$RESILIENCE_GET_FILE" || cat "$RESILIENCE_GET_FILE" || true
fi

echo "[init] Applying Resilience config (RPM=$NIM_RPM, interval=$NIM_MIN_INTERVAL_MS ms, concurrent=$NIM_CONCURRENT)..."
RESILIENCE_CODE=$(curl -s -o "$RESILIENCE_RESP_FILE" -w "%{http_code}" \
  -b "$COOKIE_FILE" \
  -X PATCH "$BASE_URL/api/resilience" \
  -H "Content-Type: application/json" \
  -d "{
    \"requestQueue\": {
      \"requestsPerMinute\": $NIM_RPM,
      \"minTimeBetweenRequestsMs\": $NIM_MIN_INTERVAL_MS,
      \"concurrentRequests\": $NIM_CONCURRENT
    }
  }")
echo "[init] Resilience PATCH HTTP $RESILIENCE_CODE"
if [ "$RESILIENCE_CODE" != "200" ] && [ "$RESILIENCE_CODE" != "204" ]; then
  echo "[init] WARN: Resilience config failed:"
  cat "$RESILIENCE_RESP_FILE" || true
fi

# ── 全局路由 Settings（先 GET 打印，再 PATCH）────────────────
echo "[init] Fetching current Settings schema (for debug)..."
SETTINGS_GET_HTTP=$(curl -s -o "$SETTINGS_GET_FILE" -w "%{http_code}" \
  -b "$COOKIE_FILE" \
  "$BASE_URL/api/settings")
echo "[init] Settings GET HTTP $SETTINGS_GET_HTTP"
if [ "$SETTINGS_GET_HTTP" = "200" ]; then
  echo "[init] Current settings (routing-related):"
  jq '{fallbackStrategy, stickyRoundRobinLimit, requestBodyLimit}' \
    "$SETTINGS_GET_FILE" 2>/dev/null || true
fi

echo "[init] Applying routing strategy + requestBodyLimit..."
SETTINGS_CODE=$(curl -s -o "$SETTINGS_RESP_FILE" -w "%{http_code}" \
  -b "$COOKIE_FILE" \
  -X PATCH "$BASE_URL/api/settings" \
  -H "Content-Type: application/json" \
  -d "{
    \"fallbackStrategy\": \"$NIM_FALLBACK_STRATEGY\",
    \"stickyRoundRobinLimit\": $NIM_STICKY_LIMIT,
    \"requestBodyLimit\": $NIM_REQUEST_BODY_LIMIT
  }")
echo "[init] Settings routing HTTP $SETTINGS_CODE"
if [ "$SETTINGS_CODE" != "200" ] && [ "$SETTINGS_CODE" != "204" ]; then
  echo "[init] WARN: Settings routing config may have failed:"
  cat "$SETTINGS_RESP_FILE" || true
fi

# ── 压缩配置（Fix-1：优先 PUT 专用端点，失败回退 PATCH）──────
echo "[init] Applying compression config (mode=$NIM_COMPRESS_MODE, threshold=$NIM_COMPRESS_THRESHOLD)..."
COMPRESS_BODY="{
  \"enabled\": true,
  \"defaultMode\": \"$NIM_COMPRESS_MODE\",
  \"autoTriggerTokens\": $NIM_COMPRESS_THRESHOLD
}"

COMPRESS_CODE=$(curl -s -o "$COMPRESS_RESP_FILE" -w "%{http_code}" \
  -b "$COOKIE_FILE" \
  -X PUT "$BASE_URL/api/settings/compression" \
  -H "Content-Type: application/json" \
  -d "$COMPRESS_BODY")
echo "[init] Compression PUT HTTP $COMPRESS_CODE"

if [ "$COMPRESS_CODE" = "404" ] || [ "$COMPRESS_CODE" = "405" ]; then
  echo "[init] Dedicated endpoint unavailable, falling back to PATCH /api/settings..."
  FB_CODE=$(curl -s -o /dev/null -w "%{http_code}" \
    -b "$COOKIE_FILE" \
    -X PATCH "$BASE_URL/api/settings" \
    -H "Content-Type: application/json" \
    -d "{
      \"compression\": {
        \"enabled\": true,
        \"defaultMode\": \"$NIM_COMPRESS_MODE\",
        \"autoTriggerTokens\": $NIM_COMPRESS_THRESHOLD
      }
    }")
  echo "[init] Compression PATCH fallback HTTP $FB_CODE"
elif [ "$COMPRESS_CODE" != "200" ] && [ "$COMPRESS_CODE" != "204" ]; then
  echo "[init] WARN: Compression config may have failed:"
  cat "$COMPRESS_RESP_FILE" || true
fi

# ── Thinking Budget（Fix-4）──────────────────────────────────
echo "[init] Setting thinking budget (mode=$NIM_THINKING_MODE, maxTokens=$NIM_THINKING_BUDGET)..."
TB_CODE=$(curl -s -o /dev/null -w "%{http_code}" \
  -b "$COOKIE_FILE" \
  -X PUT "$BASE_URL/api/settings/thinking-budget" \
  -H "Content-Type: application/json" \
  -d "{
    \"mode\": \"$NIM_THINKING_MODE\",
    \"maxTokens\": $NIM_THINKING_BUDGET,
    \"enabled\": true
  }")
echo "[init] Thinking budget PUT HTTP $TB_CODE"

# ── 按 Provider ID 逐个连接测试（与原版一致）─────────────────
if [ "$PROVIDER_COUNT" -gt 0 ]; then
  echo "[init] Running connection tests ($PROVIDER_COUNT providers)..."
  for PID in "${PROVIDER_IDS[@]}"; do
    [ -z "$PID" ] && continue
    TEST_CODE=$(curl -s -o /dev/null -w "%{http_code}" \
      -b "$COOKIE_FILE" \
      -X POST "$BASE_URL/api/providers/$PID/test")
    echo "[init] provider $PID test HTTP $TEST_CODE"
  done
  echo "[init] Connection tests done."
else
  echo "[init] WARN: No NVIDIA provider IDs found, skipping connection tests."
fi

# ── Circuit Breaker Reset（与原版一致）───────────────────────
echo "[init] Resetting circuit breakers..."
CB_RESET_CODE=$(curl -s -o /dev/null -w "%{http_code}" \
  -b "$COOKIE_FILE" \
  -X POST "$BASE_URL/api/resilience/reset" \
  -H "Content-Type: application/json")
echo "[init] Circuit breaker reset HTTP $CB_RESET_CODE"

# ── Model Cooldowns 清理（Fix-2：新增）───────────────────────
echo "[init] Clearing model cooldowns..."
MC_CODE=$(curl -s -o /dev/null -w "%{http_code}" \
  -b "$COOKIE_FILE" \
  -X DELETE "$BASE_URL/api/resilience/model-cooldowns" \
  -H "Content-Type: application/json" \
  -d '{"all": true}')
echo "[init] Model cooldowns clear HTTP $MC_CODE"

# ════════════════════════════════════════════════════════════
# 以下为首次初始化专属（与原版 INIT_MARKER 逻辑一致）
# ════════════════════════════════════════════════════════════
if [ -f "$INIT_MARKER" ]; then
  echo "[init] Already initialized (marker exists). Skipping model/combo/alias registration."
  echo "[init] Done (incremental mode)."
  exit 0
fi

# ── 模型目录注册 ──────────────────────────────────────────────
echo "[init] First-time init: registering models..."

register_model() {
  local MODEL_ID="$1"
  local MODEL_RESP_FILE="/tmp/omniroute-model-$(echo "$MODEL_ID" | tr '/' '-').json"
  local MODEL_BODY
  local MODEL_CODE

  MODEL_BODY=$(jq -n \
    --arg provider "nvidia" \
    --arg modelId "$MODEL_ID" \
    '{provider: $provider, modelId: $modelId}')

  MODEL_CODE=$(curl -s -o "$MODEL_RESP_FILE" -w "%{http_code}" \
    -b "$COOKIE_FILE" \
    -X POST "$BASE_URL/api/provider-models" \
    -H "Content-Type: application/json" \
    -d "$MODEL_BODY")

  if [ "$MODEL_CODE" = "200" ] || [ "$MODEL_CODE" = "201" ]; then
    echo "[init] model $MODEL_ID -> OK ($MODEL_CODE)"
  elif [ "$MODEL_CODE" = "409" ]; then
    echo "[init] model $MODEL_ID -> already exists (skipped)"
  else
    echo "[init] model $MODEL_ID -> WARN HTTP $MODEL_CODE"
    cat "$MODEL_RESP_FILE" || true
  fi
}

# nim-pool 核心模型
register_model "minimaxai/minimax-m2.7"
register_model "moonshotai/kimi-k2-thinking"
register_model "moonshotai/kimi-k2.6"
register_model "z-ai/glm-5.1"
register_model "nvidia/nemotron-3-super-120b-a12b"
register_model "qwen/qwen3-coder-480b-a35b-instruct"
register_model "mistralai/mistral-small-4-119b-2603"
register_model "mistralai/mistral-medium-3.5-128b"
register_model "meta/llama-3.2-90b-vision-instruct"

# 额外备用模型（不放入 Combo）
register_model "deepseek-ai/deepseek-v4-pro"
register_model "deepseek-ai/deepseek-v4-flash"
# register_model "minimax-m3"  # 已确认 NIM 不托管，Fix-3 移除

echo "[init] Model registration done."

# ── 创建 Combo nim-pool（Fix-5：COMBO_STRATEGY 变量）─────────
echo "[init] Creating Combo nim-pool (strategy=$COMBO_STRATEGY)..."
COMBO_BODY=$(jq -n \
  --arg name "nim-pool" \
  --arg strategy "$COMBO_STRATEGY" \
  '{
    name: $name,
    strategy: $strategy,
    models: [
      "minimaxai/minimax-m2.7",
      "moonshotai/kimi-k2-thinking",
      "moonshotai/kimi-k2.6",
      "z-ai/glm-5.1",
      "nvidia/nemotron-3-super-120b-a12b",
      "qwen/qwen3-coder-480b-a35b-instruct",
      "mistralai/mistral-small-4-119b-2603",
      "mistralai/mistral-medium-3.5-128b",
      "meta/llama-3.2-90b-vision-instruct"
    ]
  }')

COMBO_CODE=$(curl -s -o "$COMBO_RESP_FILE" -w "%{http_code}" \
  -b "$COOKIE_FILE" \
  -X POST "$BASE_URL/api/combos" \
  -H "Content-Type: application/json" \
  -d "$COMBO_BODY")
echo "[init] Combo nim-pool HTTP $COMBO_CODE"

if [ "$COMBO_CODE" = "200" ] || [ "$COMBO_CODE" = "201" ]; then
  echo "[init] Combo nim-pool created OK"
elif grep -q "already exists" "$COMBO_RESP_FILE" 2>/dev/null; then
  echo "[init] Combo nim-pool already exists, skipped"
else
  echo "[init] WARN: Combo creation unexpected response (HTTP $COMBO_CODE):"
  cat "$COMBO_RESP_FILE" || true
fi

# ── Model Alias 注册（Fix-7：首次注册）───────────────────────
echo "[init] Registering model aliases..."
register_alias() {
  local ALIAS_NAME="$1"
  local ALIAS_TARGET="$2"
  local ALIAS_CODE
  ALIAS_CODE=$(curl -s -o /dev/null -w "%{http_code}" \
    -b "$COOKIE_FILE" \
    -X POST "$BASE_URL/api/models/alias" \
    -H "Content-Type: application/json" \
    -d "{\"alias\": \"$ALIAS_NAME\", \"target\": \"$ALIAS_TARGET\"}")
  echo "[init] alias '$ALIAS_NAME' -> '$ALIAS_TARGET' HTTP $ALIAS_CODE"
}

register_alias "nim-glm"      "z-ai/glm-5.1"
register_alias "nim-qwen"     "qwen/qwen3-coder-480b-a35b-instruct"
register_alias "nim-kimi"     "moonshotai/kimi-k2-thinking"
register_alias "nim-kimi2"    "moonshotai/kimi-k2.6"
register_alias "nim-nemotron" "nvidia/nemotron-3-super-120b-a12b"
register_alias "nim-mistral"  "mistralai/mistral-medium-3.5-128b"

# ── Health Check + 参数打印（Fix-6）──────────────────────────
echo "[init] ─────────────────────────────────────────────"
echo "[init] Final health check..."
HEALTH=$(curl -s -b "$COOKIE_FILE" \
  "$BASE_URL/api/monitoring/health" 2>/dev/null)
STATUS=$(echo  "$HEALTH" | jq -r '.status         // "unknown"' 2>/dev/null)
VERSION=$(echo "$HEALTH" | jq -r '.version        // "unknown"' 2>/dev/null)
CFG=$(echo    "$HEALTH" | jq -r '.configuredCount // "?"'      2>/dev/null)
ACT=$(echo    "$HEALTH" | jq -r '.activeCount     // "?"'      2>/dev/null)
echo "[init]   Status  : $STATUS"
echo "[init]   Version : $VERSION"
echo "[init]   Keys    : $ACT active / $CFG configured"
echo "[init] ─────────────────────────────────────────────"
echo "[init] 当前参数配置："
echo "[init]   NIM_RPM                = $NIM_RPM"
echo "[init]   NIM_MIN_INTERVAL_MS    = $NIM_MIN_INTERVAL_MS ms"
echo "[init]   NIM_CONCURRENT         = $NIM_CONCURRENT"
echo "[init]   NIM_FALLBACK_STRATEGY  = $NIM_FALLBACK_STRATEGY"
echo "[init]   NIM_STICKY_LIMIT       = $NIM_STICKY_LIMIT"
echo "[init]   NIM_REQUEST_BODY_LIMIT = $NIM_REQUEST_BODY_LIMIT bytes"
echo "[init]   NIM_COMPRESS_MODE      = $NIM_COMPRESS_MODE"
echo "[init]   NIM_COMPRESS_THRESHOLD = $NIM_COMPRESS_THRESHOLD tokens"
echo "[init]   NIM_THINKING_MODE      = $NIM_THINKING_MODE"
echo "[init]   NIM_THINKING_BUDGET    = $NIM_THINKING_BUDGET tokens"
echo "[init]   COMBO_STRATEGY         = $COMBO_STRATEGY"
echo "[init] ─────────────────────────────────────────────"

touch "$INIT_MARKER"
echo "[init] Marker written: $INIT_MARKER"
echo "[init] Done (first-init mode). v3.1.0"
