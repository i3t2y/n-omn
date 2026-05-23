#!/bin/bash
set -eo pipefail

# ─────────────────────────────────────────────────────────────
# NIM OmniRoute initializer
# v3.2.0  (基于 main 分支源码核对 + 移除 Qoder)
#
# 与 v3.1.0 的差异:
#   [Remove] 移除 Qoder AI 注册逻辑
#            原因:上游 api.qoder.com 不稳定(issue #1167 HTTP 500、
#                 #1283 TOKEN_INVALID),v3.6.9 #1391 仅做软处理但实际不可用
#            → 待 Qoder 上游恢复时单独评估再加回
#
# 继承自 v3.1.0 的源码级修正:
#   [Fix-A] /api/keys POST 移除 expiresAt 字段
#   [Fix-B] 压缩配置改用 PUT /api/settings/compression
#   [Fix-C] /api/settings 字段 requestBodyLimit → maxBodySizeMb
#   [Fix-D] /api/providers/{id}/test 调用容错
#   [Fix-E] Combo 字符串数组合法(normalizeComboModels 自动转换)
#   [Fix-F] strategy "round-robin" 在 ROUTING_STRATEGY_VALUES 中
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
RESILIENCE_GET_FILE="/tmp/omniroute-resilience-get.json"
RESILIENCE_RESP_FILE="/tmp/omniroute-resilience-response.json"
SETTINGS_RESP_FILE="/tmp/omniroute-settings-response.json"
COMPRESS_GET_FILE="/tmp/omniroute-compress-get.json"
COMPRESS_RESP_FILE="/tmp/omniroute-compress-response.json"
COMBO_RESP_FILE="/tmp/omniroute-combo-response.json"
VERSION_FILE="/tmp/omniroute-version.json"

REGISTERED=0
SKIPPED=0
FAILED=0
PROVIDER_IDS=()

echo "[init] Starting NIM OmniRoute initializer v3.2.0 (Qoder removed)..."
echo "[init] BASE_URL=$BASE_URL"

# ── 必要环境变量检查 ───────────────────────────────────────
if [ -z "$INITIAL_PASSWORD" ]; then
  echo "[init] ERROR: INITIAL_PASSWORD is required"
  exit 1
fi

if [ -z "$NIM_KEYS" ]; then
  echo "[init] ERROR: NIM_KEYS is required"
  exit 1
fi

# ── 等待 OmniRoute 就绪 ────────────────────────────────────
echo "[init] Waiting for OmniRoute to start..."
until curl -sf "$BASE_URL/api/monitoring/health" > /dev/null 2>&1; do
  sleep 3
done
echo "[init] OmniRoute is up."

# ── 版本探测(仅日志) ─────────────────────────────────────
VERSION_HTTP=$(curl -s -o "$VERSION_FILE" -w "%{http_code}" \
  "$BASE_URL/api/monitoring/health" 2>/dev/null || echo "000")
if [ "$VERSION_HTTP" = "200" ]; then
  OR_VERSION=$(jq -r '.version // "unknown"' "$VERSION_FILE" 2>/dev/null || echo "unknown")
  echo "[init] OmniRoute version: $OR_VERSION"
fi

# ── 登录 Dashboard,获取 auth_token Cookie ────────────────
# 源码:src/app/api/auth/login/route.ts loginSchema = {password:string}
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
  echo "[init] ERROR: Login OK but no auth_token cookie"
  cat "$COOKIE_FILE" || true
  exit 1
fi
echo "[init] Logged in, token acquired."

# ── 创建或复用 OmniRoute 内部 API Key ──────────────────────
# 源码:src/app/api/keys/route.ts createKeySchema = {name, noLog?, scopes?}
if [ -f "$OR_API_KEY_FILE" ] && [ -s "$OR_API_KEY_FILE" ]; then
  echo "[init] OR_API_KEY file already exists, skipping creation."
else
  echo "[init] Creating OmniRoute API Key via /api/keys..."
  KEY_HTTP=$(curl -s -o "$KEY_RESP_FILE" -w "%{http_code}" \
    -b "$COOKIE_FILE" \
    -X POST "$BASE_URL/api/keys" \
    -H "Content-Type: application/json" \
    -d '{"name":"gate-internal"}')

  if [ "$KEY_HTTP" = "200" ] || [ "$KEY_HTTP" = "201" ]; then
    OR_API_KEY_VALUE=$(jq -r '.key // empty' "$KEY_RESP_FILE")
    if [ -z "$OR_API_KEY_VALUE" ] || [ "$OR_API_KEY_VALUE" = "null" ]; then
      echo "[init] ERROR: Created key but could not parse .key field"
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

# ── NIM Keys 批量注册 ─────────────────────────────────────
# 源码:src/shared/validation/schemas.ts createProviderSchema
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

# ── (Qoder AI 注册段落已移除,详见脚本顶部 [Remove] 注释) ──

# ── 收集 NVIDIA Provider IDs ──────────────────────────────
echo "[init] Fetching NVIDIA provider IDs..."
PROVIDERS_HTTP=$(curl -s -o "$PROVIDERS_FILE" -w "%{http_code}" \
  -b "$COOKIE_FILE" \
  "$BASE_URL/api/providers")

if [ "$PROVIDERS_HTTP" = "200" ]; then
  mapfile -t PROVIDER_IDS < <(
    jq -r '
      [
        .. | objects |
        select((.provider? // "") == "nvidia") |
        select((.id? // "") != "") |
        .id
      ] | unique | .[]
    ' "$PROVIDERS_FILE" 2>/dev/null
  )
fi

PROVIDER_COUNT=
echo "[init] Provider IDs collected: $PROVIDER_COUNT"

# ── Resilience 配置 ───────────────────────────────────────
# 源码:src/app/api/resilience/route.ts + updateResilienceSchema
echo "[init] Fetching current Resilience schema..."
RESILIENCE_GET_HTTP=$(curl -s -o "$RESILIENCE_GET_FILE" -w "%{http_code}" \
  -b "$COOKIE_FILE" "$BASE_URL/api/resilience")
echo "[init] Resilience GET HTTP $RESILIENCE_GET_HTTP"
if [ "$RESILIENCE_GET_HTTP" = "200" ]; then
  echo "[init] Current resilience.requestQueue:"
  jq '.requestQueue' "$RESILIENCE_GET_FILE" 2>/dev/null || true
fi

echo "[init] Applying Resilience requestQueue patch..."
RESILIENCE_BODY='{
  "requestQueue": {
    "requestsPerMinute": 35,
    "minTimeBetweenRequestsMs": 200,
    "concurrentRequests": 5
  }
}'
RESILIENCE_CODE=$(curl -s -o "$RESILIENCE_RESP_FILE" -w "%{http_code}" \
  -b "$COOKIE_FILE" \
  -X PATCH "$BASE_URL/api/resilience" \
  -H "Content-Type: application/json" \
  -d "$RESILIENCE_BODY")
echo "[init] Resilience PATCH HTTP $RESILIENCE_CODE"
if [ "$RESILIENCE_CODE" != "200" ] && [ "$RESILIENCE_CODE" != "204" ]; then
  echo "[init] WARN: Resilience response:"
  cat "$RESILIENCE_RESP_FILE" || true
fi

# ── 全局 Settings(路由策略 + 请求体上限) ────────────────
# 源码:src/shared/validation/settingsSchemas.ts updateSettingsSchema
echo "[init] Applying routing strategy + maxBodySizeMb..."
SETTINGS_CODE=$(curl -s -o "$SETTINGS_RESP_FILE" -w "%{http_code}" \
  -b "$COOKIE_FILE" \
  -X PATCH "$BASE_URL/api/settings" \
  -H "Content-Type: application/json" \
  -d '{
    "fallbackStrategy": "round-robin",
    "stickyRoundRobinLimit": 1,
    "maxBodySizeMb": 10
  }')
echo "[init] Settings PATCH HTTP $SETTINGS_CODE"
if [ "$SETTINGS_CODE" != "200" ] && [ "$SETTINGS_CODE" != "204" ]; then
  echo "[init] WARN: Settings response:"
  cat "$SETTINGS_RESP_FILE" || true
fi

# ── Compression 配置(独立端点) ──────────────────────────
# 源码:src/app/api/settings/compression/route.ts (PUT)
echo "[init] Fetching current compression settings..."
COMPRESS_GET_HTTP=$(curl -s -o "$COMPRESS_GET_FILE" -w "%{http_code}" \
  -b "$COOKIE_FILE" "$BASE_URL/api/settings/compression")
echo "[init] Compression GET HTTP $COMPRESS_GET_HTTP"
if [ "$COMPRESS_GET_HTTP" = "200" ]; then
  jq '{enabled, defaultMode, autoTriggerTokens}' "$COMPRESS_GET_FILE" 2>/dev/null || true
fi

echo "[init] Applying compression config (PUT /api/settings/compression)..."
COMPRESS_BODY='{
  "enabled": true,
  "defaultMode": "stacked",
  "autoTriggerMode": "stacked",
  "autoTriggerTokens": 32000
}'
COMPRESS_CODE=$(curl -s -o "$COMPRESS_RESP_FILE" -w "%{http_code}" \
  -b "$COOKIE_FILE" \
  -X PUT "$BASE_URL/api/settings/compression" \
  -H "Content-Type: application/json" \
  -d "$COMPRESS_BODY")
echo "[init] Compression PUT HTTP $COMPRESS_CODE"
if [ "$COMPRESS_CODE" != "200" ] && [ "$COMPRESS_CODE" != "204" ]; then
  echo "[init] WARN: Compression response:"
  cat "$COMPRESS_RESP_FILE" || true
fi

# ── 批量连接测试(容错调用) ─────────────────────────────
if [ "$PROVIDER_COUNT" -gt 0 ]; then
  echo "[init] Running provider connection tests ($PROVIDER_COUNT)..."
  for PID in ""; do
    [ -z "$PID" ] && continue
    TEST_CODE=$(curl -s -o /dev/null -w "%{http_code}" \
      -b "$COOKIE_FILE" \
      -X POST "$BASE_URL/api/providers/$PID/test" 2>/dev/null || echo "000")
    echo "[init] provider $PID test HTTP $TEST_CODE"
  done
fi

# ── 重置 circuit breakers ────────────────────────────────
# 源码:src/app/api/resilience/reset/route.ts
echo "[init] Resetting circuit breakers..."
CB_RESET_CODE=$(curl -s -o /dev/null -w "%{http_code}" \
  -b "$COOKIE_FILE" \
  -X POST "$BASE_URL/api/resilience/reset" \
  -H "Content-Type: application/json")
echo "[init] Circuit breaker reset HTTP $CB_RESET_CODE"

# ── 首次初始化:模型注册 + Combo 创建 ─────────────────────
if [ -f "$INIT_MARKER" ]; then
  echo "[init] Already initialized (marker exists). Done (incremental)."
  exit 0
fi

# 模型目录注册
register_model() {
  local MODEL_ID="$1"
  local MODEL_BODY MODEL_CODE
  local MODEL_RESP_FILE="/tmp/omniroute-model-$(echo "$MODEL_ID" | tr '/' '-').json"

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
    echo "[init] model $MODEL_ID -> already exists"
  else
    echo "[init] model $MODEL_ID -> WARN HTTP $MODEL_CODE"
    cat "$MODEL_RESP_FILE" 2>/dev/null || true
  fi
}

echo "[init] First-time init: registering models..."
register_model "minimaxai/minimax-m2.7"
register_model "moonshotai/kimi-k2-thinking"
register_model "moonshotai/kimi-k2.6"
register_model "z-ai/glm-5.1"
register_model "nvidia/nemotron-3-super-120b-a12b"
register_model "qwen/qwen3-coder-480b-a35b-instruct"
register_model "mistralai/mistral-small-4-119b-2603"
register_model "mistralai/mistral-medium-3.5-128b"
register_model "meta/llama-3.2-90b-vision-instruct"
register_model "deepseek-ai/deepseek-v4-pro"
register_model "deepseek-ai/deepseek-v4-flash"
register_model "if/qwen3-max-preview"
register_model "if/kimi-k2-0905"
register_model "if/deepseek-v3.2"
echo "[init] Model registration done."

# Combo 创建
# 源码:src/lib/combos/steps.ts normalizeComboModels
echo "[init] Creating Combo nim-pool..."
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
    "mistralai/mistral-small-4-119b-2603",
    "mistralai/mistral-medium-3.5-128b",
    "meta/llama-3.2-90b-vision-instruct"
  ]
}'

COMBO_CODE=$(curl -s -o "$COMBO_RESP_FILE" -w "%{http_code}" \
  -b "$COOKIE_FILE" \
  -X POST "$BASE_URL/api/combos" \
  -H "Content-Type: application/json" \
  -d "$COMBO_BODY")
echo "[init] Combo nim-pool HTTP $COMBO_CODE"

if [ "$COMBO_CODE" = "200" ] || [ "$COMBO_CODE" = "201" ]; then
  echo "[init] Combo nim-pool created OK"
elif [ "$COMBO_CODE" = "400" ] && grep -q "already exists" "$COMBO_RESP_FILE" 2>/dev/null; then
  echo "[init] Combo nim-pool already exists, skipped"
else
  echo "[init] WARN: Combo creation HTTP $COMBO_CODE:"
  cat "$COMBO_RESP_FILE" || true
fi

touch "$INIT_MARKER"
echo "[init] Marker written: $INIT_MARKER"
echo "[init] Done (first-init mode)."
