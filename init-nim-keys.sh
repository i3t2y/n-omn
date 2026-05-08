#!/bin/bash
set -eo pipefail

# ─────────────────────────────────────────────────────────────
# NIM OmniRoute initializer
# v2.1.0 — 基于 v1.4.0 原脚本
# 修正：
#   1. Combo 重名判断从 409 改为兼容 400（源码返回 400）
#   2. 连接测试/限速循环从字面量改为正确的数组展开
# 新增：
#   3. RTK+Caveman stacked 压缩配置
#   4. requestBodyLimit 写入 settings（v3.7.9）
# OmniRoute v3.7.9 源码锚定：
#   combos/route.ts       — 重名返回 400，字段 models[]
#   provider-models/route.ts — 字段 provider + modelId
#   rate-limits/route.ts  — 字段 connectionId + enabled
#   keys/route.ts         — 字段 name，响应 .key
#   types.ts              — CavemanIntensity / RtkIntensity 枚举
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
COMPRESSION_RESP_FILE="/tmp/omniroute-compression-response.json"
COMBO_RESP_FILE="/tmp/omniroute-combo-response.json"

REGISTERED=0
SKIPPED=0
FAILED=0

PROVIDER_IDS=()

echo "[init] Starting NIM OmniRoute initializer v2.1.0..."
echo "[init] BASE_URL=$BASE_URL"
echo "[init] INIT_MARKER=$INIT_MARKER"
echo "[init] OR_API_KEY_FILE=$OR_API_KEY_FILE"

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

# ── 登录 Dashboard，获取 auth_token Cookie ─────────────────────────

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
# 源码锚定：keys/route.ts — body 字段 name（不是 label），响应字段 .key

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
      echo "[init] ERROR: Created key but could not parse .key field."
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
# NIM_KEYS 格式：换行分隔，每行一个 key

echo "[init] Registering NIM provider keys..."

INDEX=1

while IFS= read -r RAW_KEY; do
  KEY=$(printf '%s' "$RAW_KEY" | tr -d '' | xargs)

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

PROVIDER_COUNT=""
echo "[init] Provider IDs collected: $PROVIDER_COUNT"

if [ "$PROVIDER_COUNT" -eq 0 ]; then
  echo "[init] WARN: No NVIDIA provider IDs found. Tests and rate-limit protection will be skipped."
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

# ── 全局 Settings：路由策略 + requestBodyLimit（v3.7.9 新字段）────────

echo "[init] Applying global settings..."

SETTINGS_CODE=$(curl -s -o "$SETTINGS_RESP_FILE" -w "%{http_code}" \
  -b "$COOKIE_FILE" \
  -X PATCH "$BASE_URL/api/settings" \
  -H "Content-Type: application/json" \
  -d '{
    "fallbackStrategy": "round-robin",
    "stickyRoundRobinLimit": 1,
    "requestBodyLimit": 10485760
  }')

echo "[init] Settings HTTP $SETTINGS_CODE"

if [ "$SETTINGS_CODE" != "200" ] && [ "$SETTINGS_CODE" != "204" ]; then
  echo "[init] WARN: Settings config may have failed:"
  cat "$SETTINGS_RESP_FILE" || true
fi

# ── ★ 压缩配置（RTK aggressive + Caveman full stacked）──────────────
# 源码锚定：
#   CavemanIntensity = "lite" | "full" | "ultra"        (types.ts)
#   RtkIntensity = "minimal" | "standard" | "aggressive" (types.ts)
#   v3.7.9 fix(auth): compression preview 强制 ManagementSessionAuth

echo "[init] ★ Applying compression config (stacked: RTK aggressive + Caveman full)..."

COMPRESSION_CODE=$(curl -s -o "$COMPRESSION_RESP_FILE" -w "%{http_code}" \
  -b "$COOKIE_FILE" \
  -X PUT "$BASE_URL/api/settings/compression" \
  -H "Content-Type: application/json" \
  -d '{
    "enabled": true,
    "defaultMode": "stacked",
    "autoTriggerMode": "stacked",
    "autoTriggerTokens": 32000,
    "cacheMinutes": 5,
    "preserveSystemPrompt": true,
    "mcpDescriptionCompressionEnabled": true,
    "stackedPipeline": [
      {"engine": "rtk",     "intensity": "aggressive"},
      {"engine": "caveman", "intensity": "full"}
    ],
    "rtkConfig": {
      "enabled": true,
      "intensity": "aggressive",
      "applyToToolResults": true,
      "applyToCodeBlocks": false,
      "applyToAssistantMessages": false,
      "enabledFilters": [],
      "disabledFilters": [],
      "maxLinesPerResult": 200,
      "maxCharsPerResult": 20000,
      "deduplicateThreshold": 3,
      "customFiltersEnabled": true,
      "trustProjectFilters": false,
      "rawOutputRetention": "failures",
      "rawOutputMaxBytes": 1048576
    },
    "cavemanConfig": {
      "enabled": true,
      "compressRoles": ["user", "assistant"],
      "skipRules": [],
      "minMessageLength": 50,
      "preservePatterns": [],
      "intensity": "full"
    },
    "cavemanOutputMode": {
      "enabled": false,
      "intensity": "full",
      "autoClarity": true
    },
    "languageConfig": {
      "enabled": true,
      "defaultLanguage": "en",
      "autoDetect": true,
      "enabledPacks": ["en"]
    }
  }')

echo "[init] Compression PUT HTTP $COMPRESSION_CODE"

if [ "$COMPRESSION_CODE" != "200" ] && [ "$COMPRESSION_CODE" != "204" ]; then
  echo "[init] WARN: Compression config may have failed:"
  cat "$COMPRESSION_RESP_FILE" || true
fi

# ── 批量连接测试 ────────────────────────────────────────────────────
# 修正：原脚本 for PID in "" 不展开数组，改为 "${PROVIDER_IDS[@]}"

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

# ── 批量开启速率限制保护 ─────────────────────────────────────────────
# 修正：同上，改为 "${PROVIDER_IDS[@]}"
# 源码锚定：rate-limits/route.ts — 字段 connectionId + enabled

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

# ── 重置所有 circuit breaker ────────────────────────────────────────

echo "[init] Resetting circuit breakers..."

CB_RESET_CODE=$(curl -s -o /dev/null -w "%{http_code}" \
  -b "$COOKIE_FILE" \
  -X POST "$BASE_URL/api/resilience/reset" \
  -H "Content-Type: application/json")

echo "[init] Circuit breaker reset HTTP $CB_RESET_CODE"

# ── 首次初始化专属步骤 ───────────────────────────────────────────────

if [ -f "$INIT_MARKER" ]; then
  echo "[init] Already initialized (marker exists). Skipping model registration and Combo creation."
  echo "[init] Done (incremental mode)."
  exit 0
fi

# ── 模型目录注册 ────────────────────────────────────────────────────
# 源码锚定：provider-models/route.ts — 必填 provider + modelId

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
# 源码锚定：combos/route.ts — 字段 models[]，重名返回 400（非 409）

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
    "nvidia/nemotron-3-nano-omni-30b-a3b-reasoning"
  ]
}'

COMBO_CODE=$(curl -s -o "$COMBO_RESP_FILE" -w "%{http_code}" \
  -b "$COOKIE_FILE" \
  -X POST "$BASE_URL/api/combos" \
  -H "Content-Type: application/json" \
  -d "$COMBO_BODY")

echo "[init] Combo nim-pool HTTP $COMBO_CODE"

# 修正：重名返回 400（combos/route.ts 源码），检查响应体区分重名与真实错误
if [ "$COMBO_CODE" = "201" ] || [ "$COMBO_CODE" = "200" ]; then
  echo "[init] Combo nim-pool created OK"
elif [ "$COMBO_CODE" = "400" ]; then
  COMBO_ERR=$(jq -r '.error // ""' "$COMBO_RESP_FILE" 2>/dev/null)
  if echo "$COMBO_ERR" | grep -qi "already exists"; then
    echo "[init] Combo nim-pool already exists, skipped"
  else
    echo "[init] WARN: Combo creation 400 — unexpected error: $COMBO_ERR"
    cat "$COMBO_RESP_FILE" || true
  fi
else
  echo "[init] WARN: Combo creation unexpected HTTP $COMBO_CODE"
  cat "$COMBO_RESP_FILE" || true
fi

touch "$INIT_MARKER"
echo "[init] Marker written: $INIT_MARKER"
echo "[init] Done (first-init mode)."
