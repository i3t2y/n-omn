#!/bin/bash
set -eo pipefail

# ─────────────────────────────────────────────────────────────
# NIM OmniRoute initializer
# v1.3.0-final anti-variable-swallow version
#
# Responsibilities:
# 1. Wait for OmniRoute health
# 2. Login with INITIAL_PASSWORD and obtain auth_token cookie
# 3. Create/reuse internal OmniRoute API key and write /data/.or-api-key
# 4. Register NIM provider keys from NIM_KEYS
# 5. Re-fetch all NVIDIA provider IDs
# 6. Apply Resilience config
# 7. Run provider connection tests
# 8. Enable rate-limit protection
# 9. Reset circuit breakers
# 10. On first init only: register models and create nim-pool Combo
# ─────────────────────────────────────────────────────────────

if [ -z "${OMNIROUTE_PORT:-}" ]; then
  OMNIROUTE_PORT=20128
fi

BASE_URL="http://127.0.0.1:${OMNIROUTE_PORT}"
INIT_MARKER="/data/.init-done"
OR_API_KEY_FILE="/data/.or-api-key"
COOKIE_FILE="/tmp/omniroute-cookie.txt"

LOGIN_RESP_FILE="/tmp/omniroute-login.json"
KEY_RESP_FILE="/tmp/omniroute-key-response.json"
PROVIDERS_FILE="/tmp/omniroute-providers.json"
RESILIENCE_RESP_FILE="/tmp/omniroute-resilience-response.json"
COMBO_RESP_FILE="/tmp/omniroute-combo-response.json"

REGISTERED=0
SKIPPED=0
FAILED=0

PROVIDER_IDS=()

echo "[init] Starting NIM OmniRoute initializer..."
echo "[init] BASE_URL=${BASE_URL}"
echo "[init] INIT_MARKER=${INIT_MARKER}"
echo "[init] OR_API_KEY_FILE=${OR_API_KEY_FILE}"

# ── 必要环境变量检查 ────────────────────────────────────────────────

if [ -z "${INITIAL_PASSWORD:-}" ]; then
  echo "[init] ERROR: INITIAL_PASSWORD is required"
  exit 1
fi

if [ -z "${NIM_KEYS:-}" ]; then
  echo "[init] ERROR: NIM_KEYS is required"
  exit 1
fi

# ── 等待 OmniRoute 就绪 ─────────────────────────────────────────────

echo "[init] Waiting for OmniRoute to start..."

until curl -sf "${BASE_URL}/api/monitoring/health" > /dev/null 2>&1; do
  sleep 3
done

echo "[init] OmniRoute is up."

# ── 登录 Dashboard，获取 auth_token Cookie ─────────────────────────

echo "[init] Logging in..."

LOGIN_HTTP=$(curl -s -o "${LOGIN_RESP_FILE}" -w "%{http_code}" \
  -c "${COOKIE_FILE}" \
  -X POST "${BASE_URL}/api/auth/login" \
  -H "Content-Type: application/json" \
  -d "{\"password\":\"${INITIAL_PASSWORD}\"}")

if [ "${LOGIN_HTTP}" != "200" ] && [ "${LOGIN_HTTP}" != "201" ]; then
  echo "[init] ERROR: Login failed, HTTP ${LOGIN_HTTP}"
  echo "[init] Response:"
  cat "${LOGIN_RESP_FILE}" || true
  exit 1
fi

if ! grep -q "auth_token" "${COOKIE_FILE}" 2>/dev/null; then
  echo "[init] ERROR: Login failed, no auth_token cookie received"
  echo "[init] Cookie file content:"
  cat "${COOKIE_FILE}" || true
  exit 1
fi

echo "[init] Logged in, token acquired."

# ── 创建或复用 OmniRoute 内部 API Key ───────────────────────────────
# 注意：
# 这里创建的是 gate.js 转发 /v1/* 到 OmniRoute 时使用的内部 API Key。
# 不使用 OMNIROUTE_API_KEY 环境变量。

if [ -f "${OR_API_KEY_FILE}" ] && [ -s "${OR_API_KEY_FILE}" ]; then
  echo "[init] OR_API_KEY file already exists, skipping creation."
else
  echo "[init] Creating OmniRoute API Key via /api/keys..."

  KEY_HTTP=$(curl -s -o "${KEY_RESP_FILE}" -w "%{http_code}" \
    -b "${COOKIE_FILE}" \
    -X POST "${BASE_URL}/api/keys" \
    -H "Content-Type: application/json" \
    -d '{"name":"gate-internal","expiresAt":null}')

  if [ "${KEY_HTTP}" = "200" ] || [ "${KEY_HTTP}" = "201" ]; then
    OR_API_KEY_VALUE=$(jq -r '.key // empty' "${KEY_RESP_FILE}")

    if [ -z "${OR_API_KEY_VALUE}" ] || [ "${OR_API_KEY_VALUE}" = "null" ]; then
      echo "[init] ERROR: Created key but could not parse key field from response."
      echo "[init] Response body:"
      cat "${KEY_RESP_FILE}" || true
      exit 1
    fi

    echo "${OR_API_KEY_VALUE}" > "${OR_API_KEY_FILE}"
    chmod 600 "${OR_API_KEY_FILE}"
    echo "[init] OR_API_KEY written to ${OR_API_KEY_FILE}"
  else
    echo "[init] ERROR: /api/keys returned HTTP ${KEY_HTTP}"
    echo "[init] Response:"
    cat "${KEY_RESP_FILE}" || true
    exit 1
  fi
fi

# ── NIM Keys 批量注册 ───────────────────────────────────────────────
# NIM_KEYS 格式：
# 一行一个 nvapi key。
#
# 重启时如果 provider 已存在，可能返回 409，属于正常情况。

echo "[init] Registering NIM provider keys..."

INDEX=1

while IFS= read -r RAW_KEY; do
  KEY=$(printf '%s' "${RAW_KEY}" | tr -d '\r' | xargs)

  if [ -z "${KEY}" ]; then
    continue
  fi

  NAME=$(printf "nim-%02d" "${INDEX}")
  RESP_FILE="/tmp/omniroute-provider-${INDEX}.json"

  BODY=$(jq -n \
    --arg provider "nvidia" \
    --arg apiKey "${KEY}" \
    --arg name "${NAME}" \
    '{
      provider: $provider,
      apiKey: $apiKey,
      name: $name,
      priority: 1,
      testStatus: "unknown"
    }')

  HTTP_CODE=$(curl -s -o "${RESP_FILE}" -w "%{http_code}" \
    -b "${COOKIE_FILE}" \
    -X POST "${BASE_URL}/api/providers" \
    -H "Content-Type: application/json" \
    -d "${BODY}")

  if [ "${HTTP_CODE}" = "201" ] || [ "${HTTP_CODE}" = "200" ]; then
    echo "[init] ${NAME} registered OK"
    REGISTERED=$((REGISTERED + 1))
  elif [ "${HTTP_CODE}" = "409" ]; then
    echo "[init] ${NAME} already exists, skipped"
    SKIPPED=$((SKIPPED + 1))
  else
    echo "[init] ${NAME} unexpected HTTP ${HTTP_CODE}"
    echo "[init] Response:"
    cat "${RESP_FILE}" || true
    FAILED=$((FAILED + 1))
  fi

  INDEX=$((INDEX + 1))
done <<< "${NIM_KEYS}"

echo "[init] Keys: ${REGISTERED} registered, ${SKIPPED} skipped, ${FAILED} failed."

# ── 重新读取所有 NVIDIA Provider IDs ───────────────────────────────
# 这里不依赖注册接口返回值。
# 原因：
# - 首次构建时 provider 可能新建成功。
# - 重启时 provider 可能返回 409。
# - 统一重新读取 /api/providers 最稳。

echo "[init] Fetching NVIDIA provider IDs from /api/providers..."

PROVIDERS_HTTP=$(curl -s -o "${PROVIDERS_FILE}" -w "%{http_code}" \
  -b "${COOKIE_FILE}" \
  "${BASE_URL}/api/providers")

if [ "${PROVIDERS_HTTP}" = "200" ]; then
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
    ' "${PROVIDERS_FILE}" 2>/dev/null
  )
else
  echo "[init] WARN: /api/providers returned HTTP ${PROVIDERS_HTTP}"
  echo "[init] Response:"
  cat "${PROVIDERS_FILE}" || true
fi

PROVIDER_COUNT="${#PROVIDER_IDS[@]}"
echo "[init] Provider IDs collected: ${PROVIDER_COUNT}"

if [ "${PROVIDER_COUNT}" -eq 0 ]; then
  echo "[init] WARN: No NVIDIA provider IDs found. Connection test and rate-limit protection will be skipped."
fi

# ── Resilience 配置 ─────────────────────────────────────────────────
# 当前采用 v1.3.0 后段实测定版：
# requestsPerMinute=28
# minTimeBetweenRequests=1
# concurrentRequests=5

echo "[init] Applying Resilience config..."

RESILIENCE_BODY='{
  "profiles": {
    "apikey": {
      "transientCooldown": 90000,
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

RESILIENCE_CODE=$(curl -s -o "${RESILIENCE_RESP_FILE}" -w "%{http_code}" \
  -b "${COOKIE_FILE}" \
  -X PATCH "${BASE_URL}/api/resilience" \
  -H "Content-Type: application/json" \
  -d "${RESILIENCE_BODY}")

echo "[init] Resilience HTTP ${RESILIENCE_CODE}"

if [ "${RESILIENCE_CODE}" != "200" ] && [ "${RESILIENCE_CODE}" != "204" ]; then
  echo "[init] WARN: Resilience config may have failed:"
  cat "${RESILIENCE_RESP_FILE}" || true
fi

# ── 批量连接测试 ────────────────────────────────────────────────────
# 目的：
# 将 provider 状态从 unknown 刷新为 active/invalid。
# 这一步每次启动都做，不只首次做。

echo "[init] Running connection tests (${PROVIDER_COUNT} providers)..."

for PID in "${PROVIDER_IDS[@]}"; do
  if [ -z "${PID}" ]; then
    continue
  fi

  TEST_CODE=$(curl -s -o /dev/null -w "%{http_code}" \
    -b "${COOKIE_FILE}" \
    -X POST "${BASE_URL}/api/providers/${PID}/test")

  echo "[init] provider ${PID} test HTTP ${TEST_CODE}"
done

echo "[init] Connection tests done."

# ── 批量开启速率限制保护 ─────────────────────────────────────────────
# 注意：
# rate-limit protection 必须走 /api/rate-limits。
# 不要尝试通过 PUT /api/providers/:id 写 rateLimitProtection 字段。

echo "[init] Enabling rate limit protection for all providers..."

for PID in "${PROVIDER_IDS[@]}"; do
  if [ -z "${PID}" ]; then
    continue
  fi

  RATE_BODY=$(jq -n \
    --arg connectionId "${PID}" \
    '{connectionId: $connectionId, enabled: true}')

  RATE_CODE=$(curl -s -o /dev/null -w "%{http_code}" \
    -b "${COOKIE_FILE}" \
    -X POST "${BASE_URL}/api/rate-limits" \
    -H "Content-Type: application/json" \
    -d "${RATE_BODY}")

  echo "[init] provider ${PID} rate-limit HTTP ${RATE_CODE}"
done

echo "[init] Rate limit protection enabled."

# ── 重置所有 circuit breaker ────────────────────────────────────────
# 目的：
# 防止上一次测试中的 429、超时、Combo quality check 失败残留熔断状态。

echo "[init] Resetting circuit breakers..."

CB_RESET_CODE=$(curl -s -o /dev/null -w "%{http_code}" \
  -b "${COOKIE_FILE}" \
  -X POST "${BASE_URL}/api/resilience/reset" \
  -H "Content-Type: application/json")

echo "[init] Circuit breaker reset HTTP ${CB_RESET_CODE}"

# ── 首次初始化专属步骤 ───────────────────────────────────────────────
# HF 免费 Space：
# - 重启：/data/.init-done 通常还在，所以跳过模型注册和 Combo 创建。
# - 重建：/data 通常消失，所以 marker 消失，脚本会重新首初始化。

if [ -f "${INIT_MARKER}" ]; then
  echo "[init] Already initialized (marker exists). Skipping model registration and Combo creation."
  echo "[init] Done (incremental mode)."
  exit 0
fi

# ── 模型目录注册 ────────────────────────────────────────────────────
# 注意：
# /api/provider-models 使用原始模型 ID，不加 nvidia/ 前缀。
# Combo models 数组才使用 nvidia/ 前缀。

echo "[init] First-time init: registering models to OmniRoute model directory..."

register_model() {
  local MODEL_ID="$1"
  local MODEL_BODY
  local MODEL_CODE

  MODEL_BODY=$(jq -n \
    --arg provider "nvidia" \
    --arg modelId "${MODEL_ID}" \
    '{provider: $provider, modelId: $modelId}')

  MODEL_CODE=$(curl -s -o /dev/null -w "%{http_code}" \
    -b "${COOKIE_FILE}" \
    -X POST "${BASE_URL}/api/provider-models" \
    -H "Content-Type: application/json" \
    -d "${MODEL_BODY}")

  echo "[init] model ${MODEL_ID} -> HTTP ${MODEL_CODE}"
}

# 生产 nim-pool 7 模型
register_model "meta/llama-3.3-70b-instruct"
register_model "z-ai/glm-5.1"
register_model "minimaxai/minimax-m2.7"
register_model "qwen/qwen3-coder-480b-a35b-instruct"
register_model "deepseek-ai/deepseek-v4-pro"
register_model "deepseek-ai/deepseek-v4-flash"
register_model "moonshotai/kimi-k2.5"

# 额外保留模型目录项，便于后续手动测试或扩展 Combo
register_model "qwen/qwen3-next-80b-a3b-thinking"
register_model "qwen/qwen2.5-coder-32b-instruct"
register_model "mistralai/devstral-2-123b-instruct-2512"
register_model "nvidia/llama-3.3-nemotron-super-49b-v1.5"
register_model "nvidia/nemotron-3-super-120b-a12b"
register_model "nvidia/llama-3.1-nemotron-ultra-253b-v1"
register_model "nvidia/llama-3.1-nemotron-nano-8b-v1"
register_model "meta/llama-3.1-405b-instruct"
register_model "meta/llama-4-maverick-17b-128e-instruct"

echo "[init] Model registration done."

# ── 创建 Combo：nim-pool ────────────────────────────────────────────
# 注意：
# Combo models 数组必须带 nvidia/ 前缀。
# 这是路由前缀，不是 provider-models 注册前缀。

echo "[init] First-time init: creating Combo nim-pool..."

COMBO_BODY='{
  "name": "nim-pool",
  "strategy": "round-robin",
  "models": [
    "nvidia/meta/llama-3.3-70b-instruct",
    "nvidia/z-ai/glm-5.1",
    "nvidia/minimaxai/minimax-m2.7",
    "nvidia/qwen/qwen3-coder-480b-a35b-instruct",
    "nvidia/deepseek-ai/deepseek-v4-pro",
    "nvidia/deepseek-ai/deepseek-v4-flash",
    "nvidia/moonshotai/kimi-k2.5"
  ]
}'

COMBO_CODE=$(curl -s -o "${COMBO_RESP_FILE}" -w "%{http_code}" \
  -b "${COOKIE_FILE}" \
  -X POST "${BASE_URL}/api/combos" \
  -H "Content-Type: application/json" \
  -d "${COMBO_BODY}")

echo "[init] Combo nim-pool HTTP ${COMBO_CODE}"

if [ "${COMBO_CODE}" != "200" ] && [ "${COMBO_CODE}" != "201" ] && [ "${COMBO_CODE}" != "409" ]; then
  echo "[init] WARN: Combo creation response:"
  cat "${COMBO_RESP_FILE}" || true
fi

touch "${INIT_MARKER}"
echo "[init] Marker written: ${INIT_MARKER}"
echo "[init] Done (first-init mode)."
