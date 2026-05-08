#!/bin/bash
set -eo pipefail

# ─────────────────────────────────────────────────────────────
# NIM OmniRoute initializer
# v2.2.0
# 修复历史：
#   v1.4.0  原始版本
#   v1.9.0  修复密码变量引用 / NIM_KEYS 解析 / QODER_API_KEY 对齐
#   v2.0.0  新增压缩配置 / requestBodyLimit / 保留已验证逻辑
#   v2.1.0  修正 for 循环数组展开 / Combo 重名判断改为 400+body
#   v2.2.0  Fix-1: maxWaitMs=0 禁用队列超时
#            Fix-2: RPM=35 / minTime=200ms / concurrent=3
#            Fix-3: 压缩配置独立段 / requestBodyLimit 保留
#            Bug-1: PROVIDER_COUNT 显式赋值确认
#            Bug-2: PROVIDER_COUNT 空值防护
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
COMPRESS_RESP_FILE="/tmp/omniroute-compress-response.json"
COMBO_RESP_FILE="/tmp/omniroute-combo-response.json"

REGISTERED=0
SKIPPED=0
FAILED=0

PROVIDER_IDS=()

echo "[init] Starting NIM OmniRoute initializer v2.2.0..."
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
  echo "[init] Response:"
  cat "$LOGIN_RESP_FILE" || true
  exit 1
fi

if ! grep -q "auth_token" "$COOKIE_FILE" 2>/dev/null; then
  echo "[init] ERROR: Login failed, no auth_token cookie received"
  echo "[init] Cookie file content:"
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
      echo "[init] ERROR: Created key but could not parse key field from response."
      echo "[init] Response body:"
      cat "$KEY_RESP_FILE" || true
      exit 1
    fi

    echo "$OR_API_KEY_VALUE" > "$OR_API_KEY_FILE"
    chmod 600 "$OR_API_KEY_FILE"
    echo "[init] OR_API_KEY written to $OR_API_KEY_FILE"
  else
    echo "[init] ERROR: /api/keys returned HTTP $KEY_HTTP"
    echo "[init] Response:"
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
    echo "[init] Response:"
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
  echo "[init] Response:"
  cat "$PROVIDERS_FILE" || true
fi

# Bug-1 fix: 显式赋值，防止 XML/摘要截断导致歧义
# Bug-2 fix: 空值兜底，防止 [ "" -eq 0 ] 报 integer expression expected
PROVIDER_COUNT="${#PROVIDER_IDS[@]}"
PROVIDER_COUNT="${PROVIDER_COUNT:-0}"
echo "[init] Provider IDs collected: $PROVIDER_COUNT"

if [ "$PROVIDER_COUNT" -eq 0 ]; then
  echo "[init] WARN: No NVIDIA provider IDs found. Connection test and rate-limit protection will be skipped."
fi

# ── Resilience 配置（v2.3.0）────────────────────────────────────────
# maxWaitMs: 1 = schema 允许的最小值（min(1)），等效于"立即 fallback"
# 不能设 0：z.number().int().min(1) 硬约束，会返回 400 导致整段配置失效

echo "[init] Applying Resilience config (v2.3.0)..."

RESILIENCE_BODY='{
  "requestQueue": {
    "requestsPerMinute": 35,
    "minTimeBetweenRequestsMs": 200,
    "concurrentRequests": 3,
    "maxWaitMs": 1
  },
  "connectionCooldown": {
    "apikey": {
      "baseCooldownMs": 60000,
      "maxBackoffSteps": 3,
      "useUpstreamRetryHints": true
    },
    "oauth": {
      "baseCooldownMs": 60000,
      "maxBackoffSteps": 8,
      "useUpstreamRetryHints": true
    }
  },
  "providerBreaker": {
    "apikey": {
      "failureThreshold": 3,
      "resetTimeoutMs": 600000
    },
    "oauth": {
      "failureThreshold": 3,
      "resetTimeoutMs": 60000
    }
  }
}'

RESILIENCE_CODE=$(curl -s -o "$RESILIENCE_RESP_FILE" -w "%{http_code}" \
  -b "$COOKIE_FILE" \
  -X PATCH "$BASE_URL/api/resilience" \
  -H "Content-Type: application/json" \
  -d "$RESILIENCE_BODY")

echo "[init] Resilience HTTP $RESILIENCE_CODE"

if [ "$RESILIENCE_CODE" != "200" ] && [ "$RESILIENCE_CODE" != "204" ]; then
  echo "[init] ERROR: Resilience config failed — this is critical, check response:"
  cat "$RESILIENCE_RESP_FILE" || true
  # 不 exit，让后续步骤继续，但明确标记为错误
fi

# ── 全局路由策略 + requestBodyLimit（Fix-3）────────────────────────
# requestBodyLimit=10485760: v3.7.9 新字段，防止 62K+ 大请求被截断
# fallbackStrategy=round-robin / stickyRoundRobinLimit=1: 保持原策略

echo "[init] Applying routing strategy + requestBodyLimit..."

SETTINGS_CODE=$(curl -s -o "$SETTINGS_RESP_FILE" -w "%{http_code}" \
  -b "$COOKIE_FILE" \
  -X PATCH "$BASE_URL/api/settings" \
  -H "Content-Type: application/json" \
  -d '{
    "fallbackStrategy": "round-robin",
    "stickyRoundRobinLimit": 1,
    "requestBodyLimit": 10485760
  }')

echo "[init] Settings routing HTTP $SETTINGS_CODE"

if [ "$SETTINGS_CODE" != "200" ] && [ "$SETTINGS_CODE" != "204" ]; then
  echo "[init] WARN: Settings routing config may have failed:"
  cat "$SETTINGS_RESP_FILE" || true
fi

# ── 压缩配置：RTK aggressive + Caveman full stacked（Fix-3）─────────
# 独立段，避免与 routing settings 合并导致字段冲突
# autoTriggerTokens=32000: 超过 32K token 自动触发压缩
# stackedPipeline: RTK 先跑 aggressive，再 Caveman full，预期节省 ~89%

echo "[init] Applying compression config (RTK+Caveman stacked)..."

COMPRESS_BODY='{
  "compression": {
    "enabled": true,
    "defaultMode": "stacked",
    "autoTriggerMode": "stacked",
    "autoTriggerTokens": 32000,
    "stackedPipeline": [
      {"engine": "rtk", "intensity": "aggressive"},
      {"engine": "caveman", "intensity": "full"}
    ],
    "rtkConfig": {
      "intensity": "aggressive",
      "maxLinesPerResult": 200,
      "maxCharsPerResult": 20000,
      "rawOutputRetention": "failures"
    },
    "cavemanConfig": {
      "compressRoles": ["user", "assistant"],
      "intensity": "full"
    }
  }
}'

COMPRESS_CODE=$(curl -s -o "$COMPRESS_RESP_FILE" -w "%{http_code}" \
  -b "$COOKIE_FILE" \
  -X PATCH "$BASE_URL/api/settings" \
  -H "Content-Type: application/json" \
  -d "$COMPRESS_BODY")

echo "[init] Compression config HTTP $COMPRESS_CODE"

if [ "$COMPRESS_CODE" != "200" ] && [ "$COMPRESS_CODE" != "204" ]; then
  echo "[init] WARN: Compression config may have failed:"
  cat "$COMPRESS_RESP_FILE" || true
fi

# ── 批量连接测试 ────────────────────────────────────────────────────
# v2.1.0 fix: 使用 "${PROVIDER_IDS[@]}" 正确展开数组（原 v1.4.0 用 "" 不展开）

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
# v2.1.0 fix: 同上，正确展开数组

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

echo "[init] Rate limit protection true."

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

# 生产 nim-pool 模型（多模型 fallback 用途）
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
# 额外保留模型目录项，便于后续手动测试或扩展 Combo
register_model "deepseek-ai/deepseek-v4-pro"
register_model "deepseek-ai/deepseek-v4-flash"
register_model "if/qwen3-max-preview"
register_model "if/kimi-k2-0905"
register_model "if/deepseek-v3.2"

echo "[init] Model registration done."

# ── 创建 Combo：nim-pool ────────────────────────────────────────────
# v2.1.0 fix: Combo 重名返回 400（非 409），需检查响应体含 "already exists"
# 源码验证：combos/route.ts → if (existing) return 400 "Combo name already exists"

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

if [ "$COMBO_CODE" = "200" ] || [ "$COMBO_CODE" = "201" ]; then
  echo "[init] Combo nim-pool created OK"
elif [ "$COMBO_CODE" = "400" ] && grep -q "already exists" "$COMBO_RESP_FILE" 2>/dev/null; then
  echo "[init] Combo nim-pool already exists, skipped"
else
  echo "[init] WARN: Combo creation unexpected response (HTTP $COMBO_CODE):"
  cat "$COMBO_RESP_FILE" || true
fi

touch "$INIT_MARKER"
echo "[init] Marker written: $INIT_MARKER"
echo "[init] Done (first-init mode)."
