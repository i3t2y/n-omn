#!/bin/bash
set -eo pipefail

# ─────────────────────────────────────────────────────────────
# NIM OmniRoute initializer
# v3.1.4
# 修复历史：
#   v2.2.0  原始版本
#   v3.0.0  适配 OmniRoute v3.8.0
#   v3.0.1  删除 Qoder AI 注册段
#   v3.1.0  环境变量驱动参数配置
#   v3.1.1  修复 Combo 失败不写 marker 问题；移除 alias 注册
#   v3.1.2  Thinking Budget 合并进 PATCH /api/settings
#   v3.1.3  删除 POST /api/resilience/clear-cooldowns（端点不存在）
#   v3.1.4  注释掉连接测试段、Resilience GET debug、Settings GET debug
#            （功能保留，暂不执行，减少启动耗时约 10~15s）
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
# RESILIENCE_GET_FILE="/tmp/omniroute-resilience-get.json"
RESILIENCE_RESP_FILE="/tmp/omniroute-resilience-response.json"
# SETTINGS_GET_FILE="/tmp/omniroute-settings-get.json"
SETTINGS_RESP_FILE="/tmp/omniroute-settings-response.json"
COMPRESS_RESP_FILE="/tmp/omniroute-compress-response.json"
COMBO_RESP_FILE="/tmp/omniroute-combo-response.json"
VERSION_FILE="/tmp/omniroute-version.json"

REGISTERED=0
SKIPPED=0
FAILED=0

PROVIDER_IDS=()

echo "[init] Starting NIM OmniRoute initializer v3.1.4..."
echo "[init] BASE_URL=$BASE_URL"

# ── 必要环境变量检查 ─────────────────────────────────────────────────

if [ -z "$INITIAL_PASSWORD" ]; then
  echo "[init] ERROR: INITIAL_PASSWORD is required"
  exit 1
fi

if [ -z "$NIM_KEYS" ]; then
  echo "[init] ERROR: NIM_KEYS is required"
  exit 1
fi

# ── 参数默认值 ───────────────────────────────────────────────────────

NIM_RPM=""
NIM_MIN_INTERVAL_MS=""
NIM_CONCURRENT=""
NIM_FALLBACK_STRATEGY=""
NIM_STICKY_LIMIT=""
NIM_REQUEST_BODY_LIMIT=""
NIM_COMPRESS_MODE=""
NIM_COMPRESS_THRESHOLD=""
NIM_THINKING_MODE=""
NIM_THINKING_BUDGET=""
COMBO_STRATEGY=""

# ── 等待 OmniRoute 就绪 ──────────────────────────────────────────────

echo "[init] Waiting for OmniRoute to start..."

until curl -sf "$BASE_URL/api/monitoring/health" > /dev/null 2>&1; do
  sleep 3
done

echo "[init] OmniRoute is up."

# ── 版本探测 ─────────────────────────────────────────────────────────

VERSION_HTTP=$(curl -s -o "$VERSION_FILE" -w "%{http_code}" \
  "$BASE_URL/api/monitoring/health" 2>/dev/null || echo "000")

if [ "$VERSION_HTTP" = "200" ]; then
  OR_VERSION=$(jq -r '.version // "unknown"' "$VERSION_FILE" 2>/dev/null || echo "unknown")
  echo "[init] OmniRoute version: $OR_VERSION"
else
  echo "[init] WARN: Could not fetch version (HTTP $VERSION_HTTP)"
fi

# ── 登录 ─────────────────────────────────────────────────────────────

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

# ── 创建或复用 OmniRoute 内部 API Key ────────────────────────────────

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
      echo "[init] ERROR: Created key but could not parse key field from response."
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

# ── NIM Keys 批量注册 ────────────────────────────────────────────────

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

# ── 读取所有 NVIDIA Provider IDs ─────────────────────────────────────
# （连接测试段已注释，Provider IDs 仍需采集供将来取消注释时使用）

echo "[init] Fetching NVIDIA provider IDs..."

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

PROVIDER_COUNT=
echo "[init] Provider IDs collected: $PROVIDER_COUNT"

# ── Resilience 配置 ──────────────────────────────────────────────────

# [debug] 注释掉 Resilience GET（取消注释可查看当前 schema）
# echo "[init] Fetching current Resilience schema (for debug)..."
# RESILIENCE_GET_HTTP=$(curl -s -o "$RESILIENCE_GET_FILE" -w "%{http_code}" \
#   -b "$COOKIE_FILE" \
#   "$BASE_URL/api/resilience")
# echo "[init] Resilience GET HTTP $RESILIENCE_GET_HTTP"
# if [ "$RESILIENCE_GET_HTTP" = "200" ]; then
#   echo "[init] Current resilience schema:"
#   jq '.' "$RESILIENCE_GET_FILE" || cat "$RESILIENCE_GET_FILE" || true
# else
#   echo "[init] WARN: Could not fetch resilience schema"
# fi

echo "[init] Applying Resilience config (RPM=$NIM_RPM, interval=$NIM_MIN_INTERVAL_MS ms, concurrent=$NIM_CONCURRENT)..."

RESILIENCE_BODY=$(jq -n \
  --argjson rpm "$NIM_RPM" \
  --argjson interval "$NIM_MIN_INTERVAL_MS" \
  --argjson concurrent "$NIM_CONCURRENT" \
  '{
    "requestQueue": {
      "requestsPerMinute": $rpm,
      "minTimeBetweenRequestsMs": $interval,
      "concurrentRequests": $concurrent
    }
  }')

RESILIENCE_CODE=$(curl -s -o "$RESILIENCE_RESP_FILE" -w "%{http_code}" \
  -b "$COOKIE_FILE" \
  -X PATCH "$BASE_URL/api/resilience" \
  -H "Content-Type: application/json" \
  -d "$RESILIENCE_BODY")

echo "[init] Resilience PATCH HTTP $RESILIENCE_CODE"

if [ "$RESILIENCE_CODE" != "200" ] && [ "$RESILIENCE_CODE" != "204" ]; then
  echo "[init] WARN: Resilience config failed:"
  cat "$RESILIENCE_RESP_FILE" || true
fi

# ── 全局路由策略 + requestBodyLimit ──────────────────────────────────

# [debug] 注释掉 Settings GET（取消注释可查看当前 settings）
# echo "[init] Fetching current Settings schema (for debug)..."
# SETTINGS_GET_HTTP=$(curl -s -o "$SETTINGS_GET_FILE" -w "%{http_code}" \
#   -b "$COOKIE_FILE" \
#   "$BASE_URL/api/settings")
# echo "[init] Settings GET HTTP $SETTINGS_GET_HTTP"
# if [ "$SETTINGS_GET_HTTP" = "200" ]; then
#   echo "[init] Current settings (routing-related):"
#   jq '{fallbackStrategy, stickyRoundRobinLimit, requestBodyLimit}' \
#     "$SETTINGS_GET_FILE" 2>/dev/null || jq '.' "$SETTINGS_GET_FILE" || true
# fi

echo "[init] Applying routing strategy + requestBodyLimit..."

SETTINGS_BODY=$(jq -n \
  --arg strategy "$NIM_FALLBACK_STRATEGY" \
  --argjson sticky "$NIM_STICKY_LIMIT" \
  --argjson bodyLimit "$NIM_REQUEST_BODY_LIMIT" \
  '{
    "fallbackStrategy": $strategy,
    "stickyRoundRobinLimit": $sticky,
    "requestBodyLimit": $bodyLimit
  }')

SETTINGS_CODE=$(curl -s -o "$SETTINGS_RESP_FILE" -w "%{http_code}" \
  -b "$COOKIE_FILE" \
  -X PATCH "$BASE_URL/api/settings" \
  -H "Content-Type: application/json" \
  -d "$SETTINGS_BODY")

echo "[init] Settings routing HTTP $SETTINGS_CODE"

if [ "$SETTINGS_CODE" != "200" ] && [ "$SETTINGS_CODE" != "204" ]; then
  echo "[init] WARN: Settings routing config may have failed:"
  cat "$SETTINGS_RESP_FILE" || true
fi

# ── 压缩配置 + Thinking Budget ───────────────────────────────────────

echo "[init] Applying compression config + thinking budget (mode=$NIM_COMPRESS_MODE, threshold=$NIM_COMPRESS_THRESHOLD, thinking=$NIM_THINKING_MODE/$NIM_THINKING_BUDGET)..."

COMPRESS_BODY=$(jq -n \
  --arg mode "$NIM_COMPRESS_MODE" \
  --argjson threshold "$NIM_COMPRESS_THRESHOLD" \
  --arg thinkingMode "$NIM_THINKING_MODE" \
  --argjson thinkingBudget "$NIM_THINKING_BUDGET" \
  '{
    "compression": {
      "enabled": true,
      "defaultMode": $mode,
      "autoTriggerTokens": $threshold
    },
    "thinking": {
      "mode": $thinkingMode,
      "budgetTokens": $thinkingBudget
    }
  }')

COMPRESS_CODE=$(curl -s -o "$COMPRESS_RESP_FILE" -w "%{http_code}" \
  -b "$COOKIE_FILE" \
  -X PATCH "$BASE_URL/api/settings" \
  -H "Content-Type: application/json" \
  -d "$COMPRESS_BODY")

echo "[init] Compression + thinking budget PATCH HTTP $COMPRESS_CODE"

if [ "$COMPRESS_CODE" != "200" ] && [ "$COMPRESS_CODE" != "204" ]; then
  echo "[init] WARN: Compression config may have failed:"
  cat "$COMPRESS_RESP_FILE" || true
fi

# ── 连接测试 ─────────────────────────────────────────────────────────
# [debug] 注释掉连接测试（取消注释可手动验证各 provider 连通性）
# OmniRoute LocalHealthCheck 会在启动 15s 后自动执行，无需脚本重复触发
#
# if [ "$PROVIDER_COUNT" -gt 0 ]; then
#   echo "[init] Running connection tests ($PROVIDER_COUNT providers)..."
#   for PID in ""; do
#     if [ -z "$PID" ]; then
#       continue
#     fi
#     TEST_CODE=$(curl -s -o /dev/null -w "%{http_code}" \
#       -b "$COOKIE_FILE" \
#       -X POST "$BASE_URL/api/providers/$PID/test")
#     echo "[init] provider $PID test HTTP $TEST_CODE"
#   done
#   echo "[init] Connection tests done."
# else
#   echo "[init] WARN: No NVIDIA provider IDs found, skipping connection tests."
# fi

# ── 重置所有 circuit breakers（同时清除 model lockouts）────────────
# 源码 reset/route.ts 确认：POST /api/resilience/reset 内部调用了
# clearAllModelLockouts()，一次请求同时完成两件事

echo "[init] Resetting circuit breakers..."

CB_RESET_CODE=$(curl -s -o /dev/null -w "%{http_code}" \
  -b "$COOKIE_FILE" \
  -X POST "$BASE_URL/api/resilience/reset" \
  -H "Content-Type: application/json")

echo "[init] Circuit breaker reset HTTP $CB_RESET_CODE"

# ── 打印当前参数配置 ─────────────────────────────────────────────────

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

# ── 首次初始化专属步骤 ────────────────────────────────────────────────

if [ -f "$INIT_MARKER" ]; then
  echo "[init] Already initialized (marker exists). Skipping model registration and Combo creation."
  echo "[init] ─────────────────────────────────────────────"
  echo "[init] Final health check..."
  HEALTH_RESP=$(curl -s "$BASE_URL/api/monitoring/health")
  echo "[init]   Status  : $(echo "$HEALTH_RESP" | jq -r '.status // "unknown"')"
  echo "[init]   Version : $(echo "$HEALTH_RESP" | jq -r '.version // "unknown"')"
  echo "[init] ─────────────────────────────────────────────"
  echo "[init] Done (incremental mode). v3.1.4"
  exit 0
fi

# ── 模型目录注册 ─────────────────────────────────────────────────────

echo "[init] First-time init: registering models..."

register_model() {
  local MODEL_ID="$1"
  local MODEL_BODY
  local MODEL_CODE
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

# 额外模型目录项（备用，不放入 Combo）
register_model "deepseek-ai/deepseek-v4-pro"
register_model "deepseek-ai/deepseek-v4-flash"

echo "[init] Model registration done."

# ── 创建 Combo：nim-pool ─────────────────────────────────────────────

echo "[init] Creating Combo nim-pool (strategy=$COMBO_STRATEGY)..."

COMBO_BODY=$(jq -n \
  --arg strategy "$COMBO_STRATEGY" \
  '{
    "name": "nim-pool",
    "strategy": $strategy,
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
  }')

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
  echo "[init] WARN: Combo creation unexpected response (HTTP $COMBO_CODE):"
  cat "$COMBO_RESP_FILE" || true
  echo "[init] ERROR: Combo creation failed. Not writing init marker."
  exit 1
fi

touch "$INIT_MARKER"
echo "[init] Marker written: $INIT_MARKER"

# ── Final health check ───────────────────────────────────────────────

echo "[init] ─────────────────────────────────────────────"
echo "[init] Final health check..."
HEALTH_RESP=$(curl -s "$BASE_URL/api/monitoring/health")
echo "[init]   Status  : $(echo "$HEALTH_RESP" | jq -r '.status // "unknown"')"
echo "[init]   Version : $(echo "$HEALTH_RESP" | jq -r '.version // "unknown"')"
echo "[init] ─────────────────────────────────────────────"
echo "[init] Done (first-init mode). v3.1.4"
