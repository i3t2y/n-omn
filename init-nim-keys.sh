#!/bin/bash
set -eo pipefail

# ─────────────────────────────────────────────────────────────
# NIM OmniRoute initializer
# v3.2.1
# 修复历史：
#   v2.2.0  原始版本（基于 OmniRoute v3.5.x 时代的 schema）
#   v3.0.0  适配 OmniRoute v3.8.0：
#            Fix-1: 移除 nemotron-3-nano-omni-30b-a3b-reasoning
#            Fix-2: Resilience 改为 GET → 差量 PATCH
#            Fix-3: Compression 改为 GET → 差量 PATCH
#            Fix-4: 移除 POST /api/rate-limits
#            Fix-5: maxWaitMs 改为注释说明
#            Fix-6: 增加版本探测
#   v3.0.1  删除 Qoder AI 注册段（api.qoder.com 不稳定）
#   v3.1.5  修复环境变量覆盖问题（: "" 条件赋值）
#            Litestream + R2 持久化集成
#            Compression + Thinking Budget 合并注入
#   v3.2.0  移除所有可硬编码的环境变量依赖（精简 Secrets 至 9 个）
#            新增 Memory 系统配置段
#            新增 Skills 总开关配置段
#            新增 nim-codex Combo（context-relay 策略）
#            Compression + Thinking Budget 合并为单次 PATCH
#            移除调试用 GET 段（Resilience GET、Settings GET）
#            移除批量连接测试段（减少启动耗时）
#   v3.2.1  修复 Memory 配置字段名：v3.8.6 新增字段 API field 无 memory 前缀
#            memoryEmbeddingSource → embeddingSource（DB key ≠ API field）
# ─────────────────────────────────────────────────────────────

# ── 端口配置 ─────────────────────────────────────────────────
if [ -z "$OMNIROUTE_PORT" ]; then
  OMNIROUTE_PORT=20128
fi

BASE_URL="http://127.0.0.1:$OMNIROUTE_PORT"
INIT_MARKER="/data/.init-done"
OR_API_KEY_FILE="/data/.or-api-key"
COOKIE_FILE="/tmp/omniroute-cookie.txt"

# ── 临时文件 ──────────────────────────────────────────────────
LOGIN_RESP_FILE="/tmp/omniroute-login.json"
KEY_RESP_FILE="/tmp/omniroute-key-response.json"
PROVIDERS_FILE="/tmp/omniroute-providers.json"
RESILIENCE_RESP_FILE="/tmp/omniroute-resilience-response.json"
SETTINGS_RESP_FILE="/tmp/omniroute-settings-response.json"
COMPRESS_RESP_FILE="/tmp/omniroute-compress-response.json"
MEMORY_RESP_FILE="/tmp/omniroute-memory-response.json"
SKILLS_RESP_FILE="/tmp/omniroute-skills-response.json"
COMBO_RESP_FILE="/tmp/omniroute-combo-response.json"
VERSION_FILE="/tmp/omniroute-version.json"

REGISTERED=0
SKIPPED=0
FAILED=0

# ── 硬编码参数（不再依赖 HF Space Secrets）──────────────────
# 如需调整，直接修改此处，无需改 Secrets
_RPM="${NIM_RPM:-120}"
_CONCURRENT="${NIM_CONCURRENT:-15}"
_MIN_INTERVAL_MS=100
_FALLBACK_STRATEGY="round-robin"
_STICKY_LIMIT=1
_REQUEST_BODY_LIMIT=10485760
_COMPRESS_MODE="stacked"
_COMPRESS_THRESHOLD=12000
_THINKING_MODE="adaptive"
_THINKING_BUDGET=8000

echo "[init] Starting NIM OmniRoute initializer v3.2.0..."
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

# ── 登录，获取 auth_token Cookie ─────────────────────────────
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

# ── NIM Keys 批量注册 ─────────────────────────────────────────
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

# ── 获取 NVIDIA Provider IDs ──────────────────────────────────
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
fi

PROVIDER_COUNT="${#PROVIDER_IDS[@]}"
echo "[init] Provider IDs collected: $PROVIDER_COUNT"

# ── Resilience 配置 ───────────────────────────────────────────
#
# requestsPerMinute = $_RPM / 25 keys 取整，per-connection 限速
# 但 OmniRoute requestQueue 是 per-provider 级别，不是全局
# 所以直接用 $_RPM 作为单 key 上限（NIM 免费层 40 RPM/key，120 是 3 key 聚合后的全局值）
# 实际 per-key 限速由 NIM 侧强制执行，这里设高一点让 OmniRoute 不做额外节流

echo "[init] Applying Resilience config (RPM=$_RPM, interval=$_MIN_INTERVAL_MS ms, concurrent=$_CONCURRENT)..."

RESILIENCE_CODE=$(curl -s -o "$RESILIENCE_RESP_FILE" -w "%{http_code}" \
  -b "$COOKIE_FILE" \
  -X PATCH "$BASE_URL/api/resilience" \
  -H "Content-Type: application/json" \
  -d "{
    \"requestQueue\": {
      \"requestsPerMinute\": $_RPM,
      \"minTimeBetweenRequestsMs\": $_MIN_INTERVAL_MS,
      \"concurrentRequests\": $_CONCURRENT
    }
  }")

echo "[init] Resilience PATCH HTTP $RESILIENCE_CODE"

if [ "$RESILIENCE_CODE" != "200" ] && [ "$RESILIENCE_CODE" != "204" ]; then
  echo "[init] WARN: Resilience config failed:"
  cat "$RESILIENCE_RESP_FILE" || true
fi

# ── 全局路由策略 ──────────────────────────────────────────────
echo "[init] Applying routing strategy + requestBodyLimit..."

SETTINGS_CODE=$(curl -s -o "$SETTINGS_RESP_FILE" -w "%{http_code}" \
  -b "$COOKIE_FILE" \
  -X PATCH "$BASE_URL/api/settings" \
  -H "Content-Type: application/json" \
  -d "{
    \"fallbackStrategy\": \"$_FALLBACK_STRATEGY\",
    \"stickyRoundRobinLimit\": $_STICKY_LIMIT,
    \"requestBodyLimit\": $_REQUEST_BODY_LIMIT
  }")

echo "[init] Settings routing HTTP $SETTINGS_CODE"

if [ "$SETTINGS_CODE" != "200" ] && [ "$SETTINGS_CODE" != "204" ]; then
  echo "[init] WARN: Settings routing config may have failed:"
  cat "$SETTINGS_RESP_FILE" || true
fi

# ── Compression + Thinking Budget（合并为单次 PATCH）─────────
#
# autoTriggerTokens 与 _COMPRESS_THRESHOLD 保持一致
# thinkingBudget.mode=adaptive：短请求不消耗 thinking token，长请求自动启用
# thinkingBudget.maxTokens=8000：单次最大 thinking 预算

echo "[init] Applying compression + thinking budget (mode=$_COMPRESS_MODE, threshold=$_COMPRESS_THRESHOLD, thinking=$_THINKING_MODE/$_THINKING_BUDGET)..."

COMPRESS_CODE=$(curl -s -o "$COMPRESS_RESP_FILE" -w "%{http_code}" \
  -b "$COOKIE_FILE" \
  -X PATCH "$BASE_URL/api/settings" \
  -H "Content-Type: application/json" \
  -d "{
    \"compression\": {
      \"enabled\": true,
      \"defaultMode\": \"$_COMPRESS_MODE\",
      \"autoTriggerTokens\": $_COMPRESS_THRESHOLD
    },
    \"thinkingBudget\": {
      \"enabled\": true,
      \"mode\": \"$_THINKING_MODE\",
      \"maxTokens\": $_THINKING_BUDGET
    }
  }")

echo "[init] Compression + thinking budget HTTP $COMPRESS_CODE"

if [ "$COMPRESS_CODE" != "200" ] && [ "$COMPRESS_CODE" != "204" ]; then
  echo "[init] WARN: Compression + thinking budget may have failed:"
  cat "$COMPRESS_RESP_FILE" || true
fi

# ── Memory 系统配置（v3.2.1 修复：API field 名与 DB key 不同）────
#
# PUT /api/settings/memory 接受 MemorySettingsExtendedSchema（12 字段）
#
# Legacy fields（DB key = API field，直接用）：
#   memoryEnabled / memoryMaxTokens / memoryRetentionDays / memoryStrategy
#
# v3.8.6 新增 fields（DB key 有 memory 前缀，API field 无前缀）：
#   DB key: memoryEmbeddingSource  → API field: embeddingSource
#   DB key: memoryStaticEnabled    → API field: staticEnabled
#   DB key: memoryTransformersEnabled → API field: transformersEnabled
#   DB key: memoryVectorStore      → API field: vectorStore
#
# embeddingSource=static：使用内置 potion-base-8M，无需外部 API Key
# staticEnabled=true：必须同时设为 true 才能激活 static 源
# strategy 枚举：recent（内部映射 exact）/ semantic / hybrid

MEMORY_RESP_FILE="/tmp/omniroute-memory-response.json"

echo "[init] Applying Memory config..."

MEMORY_CODE=$(curl -s -o "$MEMORY_RESP_FILE" -w "%{http_code}" \
  -b "$COOKIE_FILE" \
  -X PUT "$BASE_URL/api/settings/memory" \
  -H "Content-Type: application/json" \
  -d '{
    "memoryEnabled": true,
    "memoryStrategy": "hybrid",
    "memoryMaxTokens": 2000,
    "memoryRetentionDays": 30,
    "embeddingSource": "static",
    "staticEnabled": true
  }')

echo "[init] Memory config HTTP $MEMORY_CODE"

if [ "$MEMORY_CODE" != "200" ] && [ "$MEMORY_CODE" != "204" ]; then
  echo "[init] WARN: Memory config may have failed:"
  cat "$MEMORY_RESP_FILE" || true
fi

# ── Skills 总开关 ─────────────────────────────────────────────
#
# skillsEnabled=true 后，内置 Skills 自动可用：
#   file_read / file_write / http_request / web_search
# Marketplace Skills 安装需要通过 Dashboard，脚本不处理
#
# 此段每次重启都执行（幂等 PATCH）

echo "[init] Enabling Skills..."

SKILLS_CODE=$(curl -s -o "$SKILLS_RESP_FILE" -w "%{http_code}" \
  -b "$COOKIE_FILE" \
  -X PATCH "$BASE_URL/api/settings" \
  -H "Content-Type: application/json" \
  -d '{"skillsEnabled": true}')

echo "[init] Skills enable HTTP $SKILLS_CODE"

if [ "$SKILLS_CODE" != "200" ] && [ "$SKILLS_CODE" != "204" ]; then
  echo "[init] WARN: Skills enable may have failed:"
  cat "$SKILLS_RESP_FILE" || true
fi

# ── 重置所有 circuit breaker ──────────────────────────────────
# v3.7.7+ Rate Limit Watchdog 会自动重置，这里手动补充一次

echo "[init] Resetting circuit breakers..."

CB_RESET_CODE=$(curl -s -o /dev/null -w "%{http_code}" \
  -b "$COOKIE_FILE" \
  -X POST "$BASE_URL/api/resilience/reset" \
  -H "Content-Type: application/json")

echo "[init] Circuit breaker reset HTTP $CB_RESET_CODE"

# ── 打印当前参数配置 ──────────────────────────────────────────
echo "[init] ─────────────────────────────────────────────"
echo "[init] 当前参数配置："
echo "[init]   NIM_RPM                = $_RPM"
echo "[init]   NIM_MIN_INTERVAL_MS    = $_MIN_INTERVAL_MS ms"
echo "[init]   NIM_CONCURRENT         = $_CONCURRENT"
echo "[init]   NIM_FALLBACK_STRATEGY  = $_FALLBACK_STRATEGY"
echo "[init]   NIM_STICKY_LIMIT       = $_STICKY_LIMIT"
echo "[init]   NIM_REQUEST_BODY_LIMIT = $_REQUEST_BODY_LIMIT bytes"
echo "[init]   NIM_COMPRESS_MODE      = $_COMPRESS_MODE"
echo "[init]   NIM_COMPRESS_THRESHOLD = $_COMPRESS_THRESHOLD tokens"
echo "[init]   NIM_THINKING_MODE      = $_THINKING_MODE"
echo "[init]   NIM_THINKING_BUDGET    = $_THINKING_BUDGET tokens"
echo "[init] ─────────────────────────────────────────────"

# ── 首次初始化检查 ────────────────────────────────────────────
if [ -f "$INIT_MARKER" ]; then
  echo "[init] Already initialized (marker exists). Skipping model registration and Combo creation."
  echo "[init] Done (incremental mode). v3.2.0"
  exit 0
fi

# ── 模型目录注册 ──────────────────────────────────────────────
#
# 已移除：nvidia/nemotron-3-nano-omni-30b-a3b-reasoning
#   → Downloadable 模型，无 hosted API endpoint，404 会触发 circuit breaker
# 已移除：Qoder AI 相关模型（v3.0.1 起）
#
# nim-pool 核心模型：通用任务，round-robin 均衡负载
# nim-codex 专属模型：代码任务，context-relay 保持长对话上下文
# 额外目录项：备用，不放入任何 Combo，按需手动启用

echo "[init] First-time init: registering models..."

register_model() {
  local MODEL_ID="$1"
  local MODEL_RESP_FILE="/tmp/omniroute-model-$(echo "$MODEL_ID" | tr '/' '-').json"

  MODEL_CODE=$(curl -s -o "$MODEL_RESP_FILE" -w "%{http_code}" \
    -b "$COOKIE_FILE" \
    -X POST "$BASE_URL/api/provider-models" \
    -H "Content-Type: application/json" \
    -d "$(jq -n --arg provider "nvidia" --arg modelId "$MODEL_ID" \
      '{provider: $provider, modelId: $modelId}')")

  if [ "$MODEL_CODE" = "200" ] || [ "$MODEL_CODE" = "201" ]; then
    echo "[init] model $MODEL_ID -> OK ($MODEL_CODE)"
  elif [ "$MODEL_CODE" = "409" ]; then
    echo "[init] model $MODEL_ID -> already exists (skipped)"
  else
    echo "[init] model $MODEL_ID -> WARN HTTP $MODEL_CODE"
    cat "$MODEL_RESP_FILE" || true
  fi
}

# nim-pool 模型
register_model "minimaxai/minimax-m2.7"
register_model "moonshotai/kimi-k2-thinking"
register_model "moonshotai/kimi-k2.6"
register_model "z-ai/glm-5.1"
register_model "nvidia/nemotron-3-super-120b-a12b"
register_model "qwen/qwen3-coder-480b-a35b-instruct"
register_model "mistralai/mistral-small-4-119b-2603"
register_model "mistralai/mistral-medium-3.5-128b"
register_model "meta/llama-3.2-90b-vision-instruct"

# nim-codex 模型（同时也在 nim-pool 里，注册一次即可）
# qwen3-coder 已在上方注册，跳过重复注册

# 额外目录项（备用）
register_model "deepseek-ai/deepseek-v4-pro"
register_model "deepseek-ai/deepseek-v4-flash"

echo "[init] Model registration done."

# ── 创建 Combo：nim-pool（通用，round-robin）─────────────────
echo "[init] Creating Combo nim-pool (strategy=round-robin)..."

COMBO_CODE=$(curl -s -o "$COMBO_RESP_FILE" -w "%{http_code}" \
  -b "$COOKIE_FILE" \
  -X POST "$BASE_URL/api/combos" \
  -H "Content-Type: application/json" \
  -d '{
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
  }')

echo "[init] Combo nim-pool HTTP $COMBO_CODE"

if [ "$COMBO_CODE" = "200" ] || [ "$COMBO_CODE" = "201" ]; then
  echo "[init] Combo nim-pool created OK"
elif [ "$COMBO_CODE" = "400" ] && grep -q "already exists" "$COMBO_RESP_FILE" 2>/dev/null; then
  echo "[init] Combo nim-pool already exists, skipped"
else
  echo "[init] WARN: Combo nim-pool unexpected response (HTTP $COMBO_CODE):"
  cat "$COMBO_RESP_FILE" || true
fi

# ── 创建 Combo：nim-codex（代码任务，context-relay）──────────
#
# context-relay 策略：当前 Key 耗尽轮转时，自动生成上下文摘要
# 注入给下一个 Key，保持长对话连贯性
# 适合 Codex CLI / 大型重构任务 / 多轮代码审查
# 使用方式：Codex CLI 里 model 填 nim-codex

CODEX_COMBO_RESP_FILE="/tmp/omniroute-codex-combo-response.json"

echo "[init] Creating Combo nim-codex (strategy=context-relay)..."

CODEX_COMBO_CODE=$(curl -s -o "$CODEX_COMBO_RESP_FILE" -w "%{http_code}" \
  -b "$COOKIE_FILE" \
  -X POST "$BASE_URL/api/combos" \
  -H "Content-Type: application/json" \
  -d '{
    "name": "nim-codex",
    "strategy": "context-relay",
    "models": [
      "qwen/qwen3-coder-480b-a35b-instruct",
      "deepseek-ai/deepseek-v4-pro",
      "mistralai/mistral-medium-3.5-128b"
    ]
  }')

echo "[init] Combo nim-codex HTTP $CODEX_COMBO_CODE"

if [ "$CODEX_COMBO_CODE" = "200" ] || [ "$CODEX_COMBO_CODE" = "201" ]; then
  echo "[init] Combo nim-codex created OK"
elif [ "$CODEX_COMBO_CODE" = "400" ] && grep -q "already exists" "$CODEX_COMBO_RESP_FILE" 2>/dev/null; then
  echo "[init] Combo nim-codex already exists, skipped"
else
  echo "[init] WARN: Combo nim-codex unexpected response (HTTP $CODEX_COMBO_CODE):"
  cat "$CODEX_COMBO_RESP_FILE" || true
fi

# ── 完成 ──────────────────────────────────────────────────────
touch "$INIT_MARKER"
echo "[init] Marker written: $INIT_MARKER"
echo "[init] ─────────────────────────────────────────────"
echo "[init] Final health check..."

HEALTH_FILE="/tmp/omniroute-final-health.json"
HEALTH_HTTP=$(curl -s -o "$HEALTH_FILE" -w "%{http_code}" \
  "$BASE_URL/api/monitoring/health" 2>/dev/null || echo "000")

if [ "$HEALTH_HTTP" = "200" ]; then
  HEALTH_STATUS=$(jq -r '.status // "unknown"' "$HEALTH_FILE" 2>/dev/null || echo "unknown")
  HEALTH_VERSION=$(jq -r '.version // "unknown"' "$HEALTH_FILE" 2>/dev/null || echo "unknown")
  echo "[init]   Status  : $HEALTH_STATUS"
  echo "[init]   Version : $HEALTH_VERSION"
else
  echo "[init]   WARN: Health check failed (HTTP $HEALTH_HTTP)"
fi

echo "[init] ─────────────────────────────────────────────"
echo "[init] Done (first-init mode). v3.2.0"
