#!/bin/bash
set -eo pipefail

# ─────────────────────────────────────────────────────────────
# NIM OmniRoute initializer
# v1.5.0 — RTK/Caveman compression + nim-pool binding
# ─────────────────────────────────────────────────────────────

if [ -z "$OMNIROUTE_PORT" ]; then
  OMNIROUTE_PORT=20128
fi

BASE_URL="http://127.0.0.1:$OMNIROUTE_PORT"
INIT_MARKER="/data/.init-done"
OR_API_KEY_FILE="/data/.or-api-key"
COOKIE_FILE="/tmp/omniroute-cookie.txt"

LOGIN_RESP_FILE="/tmp/omniroute-login.json"
KEY_RESP_FILE="/tmp/omniroute-key-response.json"
PROVIDERS_FILE="/tmp/omniroute-providers.json"
RESILIENCE_RESP_FILE="/tmp/omniroute-resilience-response.json"
SETTINGS_RESP_FILE="/tmp/omniroute-settings-response.json"
COMBO_RESP_FILE="/tmp/omniroute-combo-response.json"
RTK_RESP_FILE="/tmp/omniroute-rtk-response.json"
CAVEMAN_RESP_FILE="/tmp/omniroute-caveman-response.json"
CCOMBO_RESP_FILE="/tmp/omniroute-ccombo-response.json"

REGISTERED=0
SKIPPED=0
FAILED=0

PROVIDER_IDS=()

echo "[init] Starting NIM OmniRoute initializer (v1.5.0)..."
echo "[init] BASE_URL=$BASE_URL"

# ── 必要环境变量检查 ────────────────────────────────────────────────

if [ -z "$INITIAL_PASSWORD" ]; then
  echo "[init] ERROR: INITIAL_PASSWORD is required"
  exit 1
fi

if [ -z "$NIM_KEYS" ]; then
  echo "[init] ERROR: NIM_KEYS is required"
  exit 1
fi

# ── 等待 OmniRoute 就绪 ─────────────────────────────────────────────

echo "[init] Waiting for OmniRoute to start..."

until curl -sf "$BASE_URL/api/monitoring/health" > /dev/null 2>&1; do
  sleep 3
done

echo "[init] OmniRoute is up."

# ── 登录 Dashboard ──────────────────────────────────────────────────

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
  cat "$COOKIE_FILE" || true
  exit 1
fi

echo "[init] Logged in, token acquired."

# ── 创建或复用 OmniRoute 内部 API Key ───────────────────────────────

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

# ── NIM Keys 批量注册 ───────────────────────────────────────────────

echo "[init] Registering NIM provider keys..."

INDEX=1

while IFS= read -r RAW_KEY; do
  KEY=$(printf '%s' "$RAW_KEY" | tr -d '\r' | xargs)

  if [ -z "$KEY" ]; then
    continue
  fi

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

# ── Qoder AI Key 注册 ───────────────────────────────────────────────

echo "[init] Registering Qoder AI key..."

if [ -n "$QODER_API_KEY" ]; then
  QODER_RESP_FILE="/tmp/omniroute-provider-qoder.json"

  QODER_BODY=$(jq -n \
    --arg provider "qoder" \
    --arg apiKey "$QODER_API_KEY" \
    --arg name "qoder-01" \
    '{
      provider: $provider,
      apiKey: $apiKey,
      name: $name,
      priority: 1,
      testStatus: "unknown",
      providerSpecificData: {
        authMode: "pat",
        transport: "qodercli"
      }
    }')

  QODER_HTTP=$(curl -s -o "$QODER_RESP_FILE" -w "%{http_code}" \
    -b "$COOKIE_FILE" \
    -X POST "$BASE_URL/api/providers" \
    -H "Content-Type: application/json" \
    -d "$QODER_BODY")

  if [ "$QODER_HTTP" = "201" ] || [ "$QODER_HTTP" = "200" ]; then
    echo "[init] qoder-01 registered OK"
  elif [ "$QODER_HTTP" = "409" ]; then
    echo "[init] qoder-01 already exists, skipped"
  else
    echo "[init] WARN: qoder-01 unexpected HTTP $QODER_HTTP"
    cat "$QODER_RESP_FILE" || true
  fi
else
  echo "[init] WARN: QODER_API_KEY not set, skipping Qoder AI registration"
fi

# ── 重新读取所有 Provider IDs ───────────────────────────────────────

echo "[init] Fetching NVIDIA provider IDs from /api/providers..."

PROVIDERS_HTTP=$(curl -s -o "$PROVIDERS_FILE" -w "%{http_code}" \
  -b "$COOKIE_FILE" \
  "$BASE_URL/api/providers")

if [ "$PROVIDERS_HTTP" = "200" ]; then
  mapfile -t PROVIDER_IDS < <(
    jq -r '
      [
        .. |
        objects |
        select((.provider? // "") == "nvidia") |
        select((.id? // "") != "") |
        .id
      ] |
      unique |
      .[]
    ' "$PROVIDERS_FILE" 2>/dev/null
  )
else
  echo "[init] WARN: /api/providers returned HTTP $PROVIDERS_HTTP"
  cat "$PROVIDERS_FILE" || true
fi

PROVIDER_COUNT=${#PROVIDER_IDS[@]}
echo "[init] Provider IDs collected: $PROVIDER_COUNT"

if [ "$PROVIDER_COUNT" -eq 0 ]; then
  echo "[init] WARN: No NVIDIA provider IDs found. Connection test and rate-limit protection will be skipped."
fi

# ── Resilience 配置 ─────────────────────────────────────────────────

echo "[init] Applying Resilience config..."

RESILIENCE_BODY='{
  "profiles": {
    "apikey": {
      "transientCooldown": 30000,
      "rateLimitCooldown": 60000,
      "maxBackoffLevel": 3,
      "circuitBreakerThreshold": 3,
      "circuitBreakerReset": 600000
    },
    "oauth": {
      "transientCooldown": 5000,
      "rateLimitCooldown": 60000,
      "maxBackoffLevel": 8,
      "circuitBreakerThreshold": 3,
      "circuitBreakerReset": 60000
    }
  },
  "defaults": {
    "requestsPerMinute": 28,
    "minTimeBetweenRequests": 1,
    "concurrentRequests": 5
  }
}'

RESILIENCE_CODE=$(curl -s -o "$RESILIENCE_RESP_FILE" -w "%{http_code}" \
  -b "$COOKIE_FILE" \
  -X PATCH "$BASE_URL/api/resilience" \
  -H "Content-Type: application/json" \
  -d "$RESILIENCE_BODY")

echo "[init] Resilience HTTP $RESILIENCE_CODE"

if [ "$RESILIENCE_CODE" != "200" ] && [ "$RESILIENCE_CODE" != "204" ]; then
  echo "[init] WARN: Resilience config may have failed:"
  cat "$RESILIENCE_RESP_FILE" || true
fi

# ── 全局路由策略 ────────────────────────────────────────────────────

echo "[init] Applying routing strategy: round-robin, stickyLimit=1..."

SETTINGS_CODE=$(curl -s -o "$SETTINGS_RESP_FILE" -w "%{http_code}" \
  -b "$COOKIE_FILE" \
  -X PATCH "$BASE_URL/api/settings" \
  -H "Content-Type: application/json" \
  -d '{"fallbackStrategy":"round-robin","stickyRoundRobinLimit":1}')

echo "[init] Settings routing HTTP $SETTINGS_CODE"

if [ "$SETTINGS_CODE" != "200" ] && [ "$SETTINGS_CODE" != "204" ]; then
  echo "[init] WARN: Settings routing config may have failed:"
  cat "$SETTINGS_RESP_FILE" || true
fi

# ═══════════════════════════════════════════════════════════════════
# ★ 新增：RTK Engine 配置
# ═══════════════════════════════════════════════════════════════════

echo "[init] ★ Configuring RTK Engine (Aggressive, 300/30000)..."

RTK_BODY='{
  "enabled": true,
  "intensity": "aggressive",
  "maxLines": 300,
  "maxChars": 30000,
  "deduplicateThreshold": 3,
  "rawOutputMaxBytes": 1048576,
  "rawOutputRetention": "rawOutputFailures",
  "filterToolResults": true,
  "filterAssistantMessages": false,
  "filterCodeBlocks": false,
  "customFilters": true,
  "trustProjectFilters": false
}'

RTK_CODE=$(curl -s -o "$RTK_RESP_FILE" -w "%{http_code}" \
  -b "$COOKIE_FILE" \
  -X PATCH "$BASE_URL/api/context/rtk" \
  -H "Content-Type: application/json" \
  -d "$RTK_BODY")

echo "[init] RTK Engine HTTP $RTK_CODE"

if [ "$RTK_CODE" != "200" ] && [ "$RTK_CODE" != "204" ]; then
  echo "[init] WARN: RTK config may have failed (will retry with PUT):"
  cat "$RTK_RESP_FILE" || true

  # 部分版本端点用 PUT，做一次兜底
  RTK_CODE=$(curl -s -o "$RTK_RESP_FILE" -w "%{http_code}" \
    -b "$COOKIE_FILE" \
    -X PUT "$BASE_URL/api/context/rtk" \
    -H "Content-Type: application/json" \
    -d "$RTK_BODY")
  echo "[init] RTK Engine PUT fallback HTTP $RTK_CODE"
fi

# ═══════════════════════════════════════════════════════════════════
# ★ 新增：Caveman Engine 配置
# ═══════════════════════════════════════════════════════════════════

echo "[init] ★ Configuring Caveman Engine (en pack, output mode disabled)..."

CAVEMAN_BODY='{
  "enabled": false,
  "autoDetectLanguage": true,
  "language": "en",
  "languagePacks": ["en"],
  "outputMode": {
    "enabled": false,
    "level": "full",
    "autoClarityBypass": true
  }
}'

CAVEMAN_CODE=$(curl -s -o "$CAVEMAN_RESP_FILE" -w "%{http_code}" \
  -b "$COOKIE_FILE" \
  -X PATCH "$BASE_URL/api/context/caveman" \
  -H "Content-Type: application/json" \
  -d "$CAVEMAN_BODY")

echo "[init] Caveman Engine HTTP $CAVEMAN_CODE"

if [ "$CAVEMAN_CODE" != "200" ] && [ "$CAVEMAN_CODE" != "204" ]; then
  echo "[init] WARN: Caveman config may have failed (will retry with PUT):"
  cat "$CAVEMAN_RESP_FILE" || true

  CAVEMAN_CODE=$(curl -s -o "$CAVEMAN_RESP_FILE" -w "%{http_code}" \
    -b "$COOKIE_FILE" \
    -X PUT "$BASE_URL/api/context/caveman" \
    -H "Content-Type: application/json" \
    -d "$CAVEMAN_BODY")
  echo "[init] Caveman Engine PUT fallback HTTP $CAVEMAN_CODE"
fi

# ── 批量连接测试 ────────────────────────────────────────────────────

echo "[init] Running connection tests ($PROVIDER_COUNT providers)..."

for PID in "${PROVIDER_IDS[@]}"; do
  if [ -z "$PID" ]; then
    continue
  fi

  TEST_CODE=$(curl -s -o /dev/null -w "%{http_code}" \
    -b "$COOKIE_FILE" \
    -X POST "$BASE_URL/api/providers/$PID/test")

  echo "[init] provider $PID test HTTP $TEST_CODE"
done

echo "[init] Connection tests done."

# ── 批量开启速率限制保护 ────────────────────────────────────────────

echo "[init] Enabling rate limit protection for all providers..."

for PID in "${PROVIDER_IDS[@]}"; do
  if [ -z "$PID" ]; then
    continue
  fi

  RATE_BODY=$(jq -n \
    --arg connectionId "$PID" \
    '{connectionId: $connectionId, enabled: true}')

  RATE_CODE=$(curl -s -o /dev/null -w "%{http_code}" \
    -b "$COOKIE_FILE" \
    -X POST "$BASE_URL/api/rate-limits" \
    -H "Content-Type: application/json" \
    -d "$RATE_BODY")

  echo "[init] provider $PID rate-limit HTTP $RATE_CODE"
done

echo "[init] Rate limit protection enabled."

# ── 重置 circuit breaker ────────────────────────────────────────────

echo "[init] Resetting circuit breakers..."

CB_RESET_CODE=$(curl -s -o /dev/null -w "%{http_code}" \
  -b "$COOKIE_FILE" \
  -X POST "$BASE_URL/api/resilience/reset" \
  -H "Content-Type: application/json")

echo "[init] Circuit breaker reset HTTP $CB_RESET_CODE"

# ── 首次初始化专属步骤 ──────────────────────────────────────────────

if [ -f "$INIT_MARKER" ]; then
  echo "[init] Already initialized (marker exists). Skipping model registration and Combo creation."
  echo "[init] Done (incremental mode)."
  exit 0
fi

# ── 模型目录注册 ────────────────────────────────────────────────────

echo "[init] First-time init: registering models to OmniRoute model directory..."

register_model() {
  local MODEL_ID="$1"
  local MODEL_BODY
  local MODEL_CODE

  MODEL_BODY=$(jq -n \
    --arg provider "nvidia" \
    --arg modelId "$MODEL_ID" \
    '{provider: $provider, modelId: $modelId}')

  MODEL_CODE=$(curl -s -o /dev/null -w "%{http_code}" \
    -b "$COOKIE_FILE" \
    -X POST "$BASE_URL/api/provider-models" \
    -H "Content-Type: application/json" \
    -d "$MODEL_BODY")

  echo "[init] model $MODEL_ID -> HTTP $MODEL_CODE"
}

register_model "minimaxai/minimax-m2.7"
register_model "moonshotai/kimi-k2-thinking"
register_model "moonshotai/kimi-k2.6"
register_model "z-ai/glm-5.1"
register_model "nvidia/nemotron-3-super-120b-a12b"
register_model "qwen/qwen3-coder-480b-a35b-instruct"
register_model "mistralai/mistral-small-4-119b-2603"
register_model "mistralai/mistral-medium-3.5-128b"
register_model "meta/llama-3.2-90b-vision-instruct"
register_model "nvidia/nemotron-3-nano-omni-30b-a3b-reasoning"
register_model "deepseek-ai/deepseek-v4-pro"
register_model "deepseek-ai/deepseek-v4-flash"
register_model "if/qwen3-max-preview"
register_model "if/kimi-k2-0905"
register_model "if/deepseek-v3.2"

echo "[init] Model registration done."

# ── 创建 Combo：nim-pool ────────────────────────────────────────────

echo "[init] First-time init: creating Combo nim-pool..."

COMBO_BODY='{
  "name": "nim-pool",
  "strategy": "round-robin",
  "models": [
    "minimaxai/minimax-m2.7",
    "moonshotai/kimi-k2-thinking",
    "moonshotai/kimi-k2.6",
    "z-ai/glm-5.1",
    "nvidia/nemotron-3-super-120b-a12b",
    "qwen/qwen3-coder-480b-a35b-instruct",
    "nvidia/nemotron-3-nano-omni-30b-a3b-reasoning",
    "deepseek-ai/deepseek-v4-flash"
  ]
}'

COMBO_CODE=$(curl -s -o "$COMBO_RESP_FILE" -w "%{http_code}" \
  -b "$COOKIE_FILE" \
  -X POST "$BASE_URL/api/combos" \
  -H "Content-Type: application/json" \
  -d "$COMBO_BODY")

echo "[init] Combo nim-pool HTTP $COMBO_CODE"

if [ "$COMBO_CODE" != "200" ] && [ "$COMBO_CODE" != "201" ] && [ "$COMBO_CODE" != "409" ]; then
  echo "[init] WARN: Combo creation response:"
  cat "$COMBO_RESP_FILE" || true
fi

# ═══════════════════════════════════════════════════════════════════
# ★ 新增：创建 Compression Combo 并绑定到 nim-pool
# ═══════════════════════════════════════════════════════════════════

echo "[init] ★ Creating Compression Combo: rtk-aggressive-en..."

CCOMBO_BODY='{
  "name": "rtk-aggressive-en",
  "description": "RTK aggressive + Caveman EN, bound to nim-pool",
  "pipeline": [
    {"engine": "rtk", "level": "aggressive"},
    {"engine": "caveman", "level": "full"}
  ],
  "languagePacks": ["en"],
  "outputMode": {
    "enabled": false,
    "level": "full"
  },
  "routingCombos": ["nim-pool"],
  "default": true
}'

CCOMBO_CODE=$(curl -s -o "$CCOMBO_RESP_FILE" -w "%{http_code}" \
  -b "$COOKIE_FILE" \
  -X POST "$BASE_URL/api/compression-combos" \
  -H "Content-Type: application/json" \
  -d "$CCOMBO_BODY")

echo "[init] Compression Combo HTTP $CCOMBO_CODE"

if [ "$CCOMBO_CODE" = "200" ] || [ "$CCOMBO_CODE" = "201" ]; then
  echo "[init] ★ Compression Combo created and bound to nim-pool"
elif [ "$CCOMBO_CODE" = "409" ]; then
  echo "[init] Compression Combo already exists, skipped"
else
  echo "[init] WARN: Compression Combo creation may have failed:"
  cat "$CCOMBO_RESP_FILE" || true

  echo "[init] Note: If endpoint path differs, check Dashboard Network tab and adjust /api/compression-combos accordingly."
fi

touch "$INIT_MARKER"
echo "[init] Marker written: $INIT_MARKER"
echo "[init] Done (first-init mode, v1.5.0)."
