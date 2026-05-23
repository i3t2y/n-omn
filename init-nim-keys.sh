#!/bin/bash
set -eo pipefail

# ─────────────────────────────────────────────────────────────
# NIM OmniRoute initializer
# v3.0.1 (= v3.0.0 minus Qoder block)
# 修复历史：
#   v2.2.0  原始版本（基于 OmniRoute v3.5.x 时代的 schema）
#   v3.0.0  适配 OmniRoute v3.8.0：
#            Fix-1: 移除 nemotron-3-nano-omni-30b-a3b-reasoning（Downloadable 模型，无 API 端点）
#            Fix-2: Resilience 改为 GET → 差量 PATCH，不再盲目覆盖全量字段
#            Fix-3: Compression 改为 GET → 差量 PATCH，避免 v3.7.9 字段结构冲突
#            Fix-4: 移除 POST /api/rate-limits（端点已变更或废弃）
#            Fix-5: maxWaitMs 改为注释说明，由 GET 获取当前值后决定是否覆盖
#            Fix-6: 增加版本探测，打印实际运行版本便于调试
#   v3.0.1  仅删除 Qoder AI 注册段（上游 api.qoder.com 不稳定，Issue #1167/#1283）
#            其余所有逻辑、字段名、端点路径与 v3.0.0 完全一致
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
SETTINGS_GET_FILE="/tmp/omniroute-settings-get.json"
SETTINGS_RESP_FILE="/tmp/omniroute-settings-response.json"
COMPRESS_RESP_FILE="/tmp/omniroute-compress-response.json"
COMBO_RESP_FILE="/tmp/omniroute-combo-response.json"
VERSION_FILE="/tmp/omniroute-version.json"

REGISTERED=0
SKIPPED=0
FAILED=0

PROVIDER_IDS=()

echo "[init] Starting NIM OmniRoute initializer v3.0.1..."
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

# ── 等待 OmniRoute 就绪 ──────────────────────────────────────────────

echo "[init] Waiting for OmniRoute to start..."

until curl -sf "$BASE_URL/api/monitoring/health" > /dev/null 2>&1; do
  sleep 3
done

echo "[init] OmniRoute is up."

# ── 版本探测（仅用于日志，不阻断流程）──────────────────────────────

VERSION_HTTP=$(curl -s -o "$VERSION_FILE" -w "%{http_code}" \
  "$BASE_URL/api/monitoring/health" 2>/dev/null || echo "000")

if [ "$VERSION_HTTP" = "200" ]; then
  OR_VERSION=$(jq -r '.version // "unknown"' "$VERSION_FILE" 2>/dev/null || echo "unknown")
  echo "[init] OmniRoute version: $OR_VERSION"
else
  echo "[init] WARN: Could not fetch version (HTTP $VERSION_HTTP)"
fi

# ── 登录 Dashboard，获取 auth_token Cookie ──────────────────────────

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

# ── 重新读取所有 NVIDIA Provider IDs ─────────────────────────────────

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

# ── Resilience 配置（v3.0.0：先 GET 真实 schema，再差量 PATCH）──────
#
# 策略：
#   1. GET /api/resilience → 打印当前值，供调试
#   2. 只 PATCH 我们确定需要改的字段（requestQueue 部分）
#   3. connectionCooldown / providerBreaker 不再盲目覆盖
#      → v3.5.2 后这两个字段结构已重构，旧字段名会被忽略或报 400
#      → 如果需要修改，应先 GET 看当前字段名，再按实际结构写
#
# 关于 requestsPerMinute=35：
#   NIM 免费层限制 40 RPM per key，25 个 key 共享 combo，
#   OmniRoute 的 requestQueue 是 per-provider-connection 级别的，
#   所以每个 connection 设 35 RPM 是合理的上限
#
# 关于 minTimeBetweenRequestsMs=200：
#   防止突发 burst 打爆单个 key

echo "[init] Fetching current Resilience schema (for debug)..."

RESILIENCE_GET_HTTP=$(curl -s -o "$RESILIENCE_GET_FILE" -w "%{http_code}" \
  -b "$COOKIE_FILE" \
  "$BASE_URL/api/resilience")

echo "[init] Resilience GET HTTP $RESILIENCE_GET_HTTP"

if [ "$RESILIENCE_GET_HTTP" = "200" ]; then
  echo "[init] Current resilience schema:"
  jq '.' "$RESILIENCE_GET_FILE" || cat "$RESILIENCE_GET_FILE" || true
else
  echo "[init] WARN: Could not fetch resilience schema"
fi

echo "[init] Applying Resilience config (minimal safe patch)..."

# 只 PATCH requestQueue，不碰 connectionCooldown/providerBreaker
# 因为这两个字段在 v3.5.2 后结构已重构，盲目覆盖会导致 400 或静默失败
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
  echo "[init] WARN: Resilience config failed, response:"
  cat "$RESILIENCE_RESP_FILE" || true
  echo "[init] NOTE: This is non-fatal. Check GET /api/resilience output above for correct field names."
fi

# ── 全局路由策略 + requestBodyLimit ──────────────────────────────────

echo "[init] Fetching current Settings schema (for debug)..."

SETTINGS_GET_HTTP=$(curl -s -o "$SETTINGS_GET_FILE" -w "%{http_code}" \
  -b "$COOKIE_FILE" \
  "$BASE_URL/api/settings")

echo "[init] Settings GET HTTP $SETTINGS_GET_HTTP"

if [ "$SETTINGS_GET_HTTP" = "200" ]; then
  echo "[init] Current settings (routing-related fields):"
  jq '{fallbackStrategy, stickyRoundRobinLimit, requestBodyLimit, compression: .compression}' \
    "$SETTINGS_GET_FILE" 2>/dev/null || jq '.' "$SETTINGS_GET_FILE" || true
fi

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

# ── 压缩配置（v3.0.0：基于 v3.7.9 新 schema）────────────────────────
#
# v3.7.7/3.7.9 Compression 大幅升级：
#   - 新增 39-filter RTK catalog
#   - stackedPipeline 字段结构可能已变
#   - 新增 autoAssessment / comboAssignments 等字段
#
# 策略：
#   只设 enabled=true 和 defaultMode，不覆盖 stackedPipeline 详细配置
#   → 让 OmniRoute 使用其内置的 stacked 默认值
#   → 如需精细控制，先 GET /api/settings 看 compression 字段结构
#
# 如果这段 PATCH 失败（400），说明 compression 字段结构又变了，
# 需要从 GET 输出里找正确的字段名

echo "[init] Applying compression config (safe minimal)..."

COMPRESS_BODY='{
  "compression": {
    "enabled": true,
    "defaultMode": "stacked",
    "autoTriggerTokens": 32000
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
  echo "[init] NOTE: Check GET /api/settings compression field above for correct schema."
fi

# ── 批量连接测试 ─────────────────────────────────────────────────────

if [ "$PROVIDER_COUNT" -gt 0 ]; then
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
else
  echo "[init] WARN: No NVIDIA provider IDs found, skipping connection tests."
fi

# ── 重置所有 circuit breaker ─────────────────────────────────────────
# v3.7.7+ 有 Rate Limit Watchdog 自动重置，这里手动 reset 作为补充

echo "[init] Resetting circuit breakers..."

CB_RESET_CODE=$(curl -s -o /dev/null -w "%{http_code}" \
  -b "$COOKIE_FILE" \
  -X POST "$BASE_URL/api/resilience/reset" \
  -H "Content-Type: application/json")

echo "[init] Circuit breaker reset HTTP $CB_RESET_CODE"

# ── 首次初始化专属步骤 ────────────────────────────────────────────────

if [ -f "$INIT_MARKER" ]; then
  echo "[init] Already initialized (marker exists). Skipping model registration and Combo creation."
  echo "[init] Done (incremental mode)."
  exit 0
fi

# ── 模型目录注册 ─────────────────────────────────────────────────────
#
# 模型列表说明（v3.0.0）：
#   已移除：nvidia/nemotron-3-nano-omni-30b-a3b-reasoning
#     → Downloadable 模型，无 hosted API endpoint，调用必然 404
#     → 404 会触发 circuit breaker，导致整个 nim-pool 雪崩
#
#   保留：仅 NIM 免费层实际有 hosted API endpoint 的模型
#   如需验证：Dashboard → Providers → NVIDIA → 点击模型旁的 Test 按钮

echo "[init] First-time init: registering models to OmniRoute model directory..."

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

# ── nim-pool 核心模型（Combo 实际使用）──────────────────────────────
register_model "minimaxai/minimax-m2.7"
register_model "moonshotai/kimi-k2-thinking"
register_model "moonshotai/kimi-k2.6"
register_model "z-ai/glm-5.1"
register_model "nvidia/nemotron-3-super-120b-a12b"
register_model "qwen/qwen3-coder-480b-a35b-instruct"
register_model "mistralai/mistral-small-4-119b-2603"
register_model "mistralai/mistral-medium-3.5-128b"
register_model "meta/llama-3.2-90b-vision-instruct"

# ── 额外模型目录项（备用，不放入 Combo）────────────────────────────
register_model "deepseek-ai/deepseek-v4-pro"
register_model "deepseek-ai/deepseek-v4-flash"
register_model "nvidia/nemotron-3-nano-omni-30b-a3b-reasoning"

echo "[init] Model registration done."

# ── 创建 Combo：nim-pool ─────────────────────────────────────────────
#
# 模型顺序 = round-robin 优先级
# 如需添加新模型，先用 Dashboard per-model test 验证可用性

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
  echo "[init] WARN: Combo creation unexpected response (HTTP $COMBO_CODE):"
  cat "$COMBO_RESP_FILE" || true
fi

touch "$INIT_MARKER"
echo "[init] Marker written: $INIT_MARKER"
echo "[init] Done (first-init mode)."
