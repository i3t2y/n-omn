#!/bin/bash
set -eo pipefail

# ─────────────────────────────────────────────────────────────
# NIM OmniRoute initializer
# v3.4.0
# 修复历史：
#   v2.2.0  原始版本（基于 OmniRoute v3.5.x 时代的 schema）
#   v3.0.0  适配 OmniRoute v3.8.0：移除不可用模型、Resilience/Compression 差量 PATCH
#   v3.0.1  删除 Qoder AI 注册段
#   v3.1.5  修复环境变量覆盖问题；Litestream + R2 持久化集成
#   v3.2.0  移除可硬编码环境变量依赖；新增 Memory/Skills/nim-codex Combo
#   v3.2.1  修复 Memory extended fields API field 名（去掉 memory 前缀）
#   v3.2.2  修复 Memory legacy fields 端点错误
#   v3.3.0  解决 NIM 32K 超限触发的 502 风暴（per-model override + 压缩端点纠正 + maxBodySizeMb）
#   v3.4.0  【本次·真态核对后修复】
#            【修复1】增量修复的 nim-pool 清单与首次清单不一致，且多出的模型未被
#                     32K context override 覆盖 → 触发增量修复时 502 风暴复发。
#            【修复2】三份互相打架的模型清单（register / 首次 combo / 增量 combo）
#                     统一为脚本顶部单一 SSOT 数组，一处改处处生效。
#            【修复3】Memory embeddingSource 由 remote(voyage) 改回 static，
#                     与注释一致，且 HF 免费层无需外部 Voyage API key。
#            【修复4】版本号漂移：运行时 echo 全部对齐 v3.4.0。
#            【修复5】NIM_RPM 默认值 40（贴上限无缓冲）→ 35，留 12.5% 缓冲防 429。
#            【修复6】DELETE domain_circuit_breakers 改用 $_DB_PATH；
#                     HF Dataset 导出逻辑抽成函数 hf_snapshot()，消除两处重复。
# ─────────────────────────────────────────────────────────────

# ── 端口配置 ──────────────────────────────────────────────────
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
THINKING_RESP_FILE="/tmp/omniroute-thinking-response.json"
MEMORY_LEGACY_RESP_FILE="/tmp/omniroute-memory-legacy-response.json"
MEMORY_EXT_RESP_FILE="/tmp/omniroute-memory-ext-response.json"
COMBO_RESP_FILE="/tmp/omniroute-combo-response.json"
VERSION_FILE="/tmp/omniroute-version.json"

REGISTERED=0
SKIPPED=0
FAILED=0

# ═════════════════════════════════════════════════════════════
# 【修复1+2 核心】模型清单单一事实来源 SSOT — v3.4.1
# ─────────────────────────────────────────────────────────────
# 此前脚本存在三份互相打架的 NIM 模型清单：
#   (a) register_model 注册的 10 个
#   (b) 首次创建 nim-pool combo 的 8 个
#   (c) 增量修复 nim-pool 的 11 个（多出 gpt-oss-120b / nemotron-ultra 等）
# 而 32K context override 循环只覆盖 (a) 的 10 个 → (c) 多出的模型没有 32K 上限，
# 一旦触发增量修复就会按标称 128K 处理，复发 502 风暴。
#
# 现统一为下面两个数组。所有环节（注册 / 首次 combo / 增量 combo / 32K override /
# 巡检）全部引用它们，改一处即全局生效，杜绝漂移。
# 验证状态标注（build.nvidia.com 目录页逐字核对，2026-07-07）：
#   [✓实证]  = 已在 build.nvidia.com 模型页确认 ID 与 Free Endpoint
#   [!待核]  = 用户口头确认上架，但我未抓到 model 页实证，请在 /v1/models 核对确切 ID
# ⚠️ 维护须知：新增/删除 NIM 模型，只改这两个数组即可，不要在下文任何地方硬编码模型名。
# ═════════════════════════════════════════════════════════════
# nim-pool：通用池（round-robin）
NIM_POOL_MODELS=(
  "minimaxai/minimax-m2.7"                    # [✓实证] Free Endpoint
  "moonshotai/kimi-k2.6"                       # [✓实证] Free Endpoint
  "z-ai/glm-5.2"                               # [✓实证] Free Endpoint 旗舰 agentic
  "nvidia/nemotron-3-super-120b-a12b"          # [✓实证] modelcard 确认
  "qwen/qwen3-next-80b-a3b-instruct"           # [✓实证] 代码编程主力
  "mistralai/mistral-small-4-119b-2603"        # [✓实证]
  "mistralai/mistral-medium-3.5-128b"          # [✓实证] Free Endpoint
  "meta/llama-3.2-90b-vision-instruct"         # [✓实证] 多模态
  "openai/gpt-oss-120b"                        # [!待核] 用户确认上架；请核对确切前缀/ID
  "nvidia/nemotron-3-ultra-550b-a55b"          # [✓实证] Free Endpoint 1M context
  "mistralai/mistral-large-3-675b-instruct-2512"  # [!待核] 用户确认上架；请核对 ID 尾缀
)

# nim-codex：代码任务池（context-relay）
NIM_CODEX_MODELS=(
  "openai/gpt-oss-120b"                        # [!待核] 见上，代码任务头号
  "qwen/qwen3-next-80b-a3b-instruct"           # [✓实证]
  "deepseek-ai/deepseek-v4-pro"                # [✓实证] Free Endpoint 1M context 代码
  "mistralai/mistral-medium-3.5-128b"          # [✓实证]
)

# 备用目录项：注册进目录但不进任何 combo（供单模型 alias 直接调用）
NIM_EXTRA_MODELS=(
  "deepseek-ai/deepseek-v4-pro"                # [✓实证]
  "deepseek-ai/deepseek-v4-flash"              # [✓实证] Free Endpoint 快速代码
)

# 全部需要 32K context override 的模型 = pool ∪ codex ∪ extra（去重）。
# 【修复1】override 必须覆盖所有可能进入 combo 或被 alias 调用的模型，一个不漏。
build_all_models() {
  printf '%s\n' \
    "${NIM_POOL_MODELS[@]}" \
    "${NIM_CODEX_MODELS[@]}" \
    "${NIM_EXTRA_MODELS[@]}" \
  | awk '!seen[$0]++'   # 保序去重
}

# 把 bash 数组转成 JSON 数组字符串，如：["a","b","c"]
# 用法：models_to_json "${NIM_POOL_MODELS[@]}"
models_to_json() {
  printf '%s\n' "$@" | jq -R . | jq -s -c .
}

# ── 动态参数（优先从环境变量读取，未设置则用默认值）───────────────────────
# 在 HF Space 的 Settings > Variables and Secrets 中添加同名变量即可覆盖。
_RPM=${NIM_RPM:-35}                                    # 【修复5】NIM 官方上限 40，默认 35 留缓冲防 429
_CONCURRENT=${NIM_CONCURRENT:-5}
_MIN_INTERVAL_MS=${NIM_MIN_INTERVAL_MS:-500}
_COMPRESS_THRESHOLD=${NIM_COMPRESS_THRESHOLD:-12000}
_FALLBACK_STRATEGY="round-robin"
_STICKY_LIMIT=1
# 上游字段名 maxBodySizeMb（单位 MB）。范围 [1,500]，取下限 1MB，超大请求上游 413 拦截。
_REQUEST_BODY_LIMIT_MB=${NIM_REQUEST_BODY_LIMIT_MB:-1}
_COMPRESS_MODE="stacked"
_THINKING_MODE="adaptive"
_THINKING_BUDGET=8000
# NIM 标称 128K 实测 32K 截断 → 写 model_context_overrides(manual)，24h reconciler 永不覆盖。
_NIM_REAL_CONTEXT=${NIM_REAL_CONTEXT:-32768}

# ── SQLite 路径（真实 OmniRoute 库，与引擎一致）─────────────────────────────
_DB_PATH="${DATA_DIR:-/data}/storage.sqlite"

# sql_escape：转义字符串用于 SQLite 单引号字面量（' → ''）
sql_escape() {
  printf '%s' "$1" | sed "s/'/''/g"
}

echo "[init] Starting NIM OmniRoute initializer v3.4.0..."   # 【修复4】版本对齐
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

# ── 等待 OmniRoute 就绪（含超时上限，防止死循环）──────────────
echo "[init] Waiting for OmniRoute to start..."

HWAIT=0
until curl -sf "$BASE_URL/api/monitoring/health" > /dev/null 2>&1; do
  sleep 3
  HWAIT=$((HWAIT + 3))
  if [ "$HWAIT" -ge 180 ]; then
    echo "[init] FATAL: OmniRoute not ready within 180s during init"
    exit 1
  fi
done

echo "[init] OmniRoute is up (after ${HWAIT}s)."

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

LOGIN_BODY=$(jq -n --arg password "$INITIAL_PASSWORD" '{password: $password}')

LOGIN_HTTP=$(curl -s -o "$LOGIN_RESP_FILE" -w "%{http_code}" \
  -c "$COOKIE_FILE" \
  -X POST "$BASE_URL/api/auth/login" \
  -H "Content-Type: application/json" \
  -d "$LOGIN_BODY")

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

# resolve_or_key：OR_KEY 统一解析——env 优先、回退文件、首尾 trim。
resolve_or_key() {
  printf '%s' "${OMNIROUTE_API_KEY:-$(cat "$OR_API_KEY_FILE" 2>/dev/null)}" \
    | sed 's/^[[:space:]]*//;s/[[:space:]]*$//'
}

# ── 创建或复用 OmniRoute 内部 API Key ────────────────────────
if [ -n "$OMNIROUTE_API_KEY" ]; then
  OR_KEY="$(printf '%s' "$OMNIROUTE_API_KEY" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
  if [ -z "$OR_KEY" ]; then
    echo "[init] FATAL: OMNIROUTE_API_KEY env 为纯空白，无效配置。" >&2
    exit 1
  fi
  echo "$OR_KEY" > "$OR_API_KEY_FILE" 2>/dev/null || echo "[init] WARN: 镜像写入 $OR_API_KEY_FILE 失败（非阻塞，env 已设）。"
  chmod 600 "$OR_API_KEY_FILE" 2>/dev/null || true
  echo "[init] OMNIROUTE_API_KEY env set, env-bypass 模式，跳过 /api/keys 创建。"
elif [ -f "$OR_API_KEY_FILE" ] && [ -s "$OR_API_KEY_FILE" ]; then
  OR_KEY="$(cat "$OR_API_KEY_FILE" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
  echo "[init] OR_API_KEY file already exists, skipping creation."
else
  echo "[init] Creating OmniRoute API Key via /api/keys..."

  KEY_BODY=$(jq -n --arg name "gate-internal" '{name: $name, expiresAt: null}')

  KEY_HTTP=$(curl -s -o "$KEY_RESP_FILE" -w "%{http_code}" \
    -b "$COOKIE_FILE" \
    -X POST "$BASE_URL/api/keys" \
    -H "Content-Type: application/json" \
    -d "$KEY_BODY")

  if [ "$KEY_HTTP" = "200" ] || [ "$KEY_HTTP" = "201" ]; then
    OR_API_KEY_VALUE=$(jq -r '.key // empty' "$KEY_RESP_FILE")

    if [ -z "$OR_API_KEY_VALUE" ] || [ "$OR_API_KEY_VALUE" = "null" ]; then
      echo "[init] ERROR: Created key but could not parse key field from response."
      jq 'del(.key, .secret)' "$KEY_RESP_FILE" 2>/dev/null || echo "(response not parseable or empty)"
      exit 1
    fi

    echo "$OR_API_KEY_VALUE" > "$OR_API_KEY_FILE"
    chmod 600 "$OR_API_KEY_FILE"
    OR_KEY="$OR_API_KEY_VALUE"
    echo "[init] OR_API_KEY written to $OR_API_KEY_FILE"
  else
    echo "[init] ERROR: /api/keys returned HTTP $KEY_HTTP"
    jq 'del(.key, .secret)' "$KEY_RESP_FILE" 2>/dev/null || echo "(response not parseable or empty)"
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

# ── 全局路由策略 + maxBodySizeMb（POST 超大请求前置 413 拦截）──────────────
echo "[init] Applying routing strategy + maxBodySizeMb (=$_REQUEST_BODY_LIMIT_MB MB)..."

SETTINGS_CODE=$(curl -s -o "$SETTINGS_RESP_FILE" -w "%{http_code}" \
  -b "$COOKIE_FILE" \
  -X PATCH "$BASE_URL/api/settings" \
  -H "Content-Type: application/json" \
  -d "{
    \"fallbackStrategy\": \"$_FALLBACK_STRATEGY\",
    \"stickyRoundRobinLimit\": $_STICKY_LIMIT,
    \"requestRetry\": 2,
    \"maxRetryIntervalSec\": 5,
    \"maxBodySizeMb\": $_REQUEST_BODY_LIMIT_MB
  }")

echo "[init] Settings routing + maxBodySizeMb HTTP $SETTINGS_CODE"

if [ "$SETTINGS_CODE" != "200" ] && [ "$SETTINGS_CODE" != "204" ]; then
  echo "[init] WARN: Settings routing config may have failed:"
  cat "$SETTINGS_RESP_FILE" || true
fi

# ── Compression（独立端点 PUT /api/settings/compression，body 扁平）─────────
echo "[init] Applying compression (mode=$_COMPRESS_MODE, autoTriggerTokens=$_COMPRESS_THRESHOLD)..."

COMPRESS_CODE=$(curl -s -o "$COMPRESS_RESP_FILE" -w "%{http_code}" \
  -b "$COOKIE_FILE" \
  -X PUT "$BASE_URL/api/settings/compression" \
  -H "Content-Type: application/json" \
  -d "{
    \"enabled\": true,
    \"defaultMode\": \"$_COMPRESS_MODE\",
    \"autoTriggerTokens\": $_COMPRESS_THRESHOLD
  }")

echo "[init] Compression HTTP $COMPRESS_CODE"

if [ "$COMPRESS_CODE" != "200" ] && [ "$COMPRESS_CODE" != "204" ]; then
  echo "[init] WARN: Compression config may have failed:"
  cat "$COMPRESS_RESP_FILE" || true
fi

# ── Thinking Budget（独立端点 PUT /api/settings/thinking-budget）────────────
echo "[init] Applying thinking budget (mode=$_THINKING_MODE, baseBudget=$_THINKING_BUDGET)..."

THINKING_CODE=$(curl -s -o "$THINKING_RESP_FILE" -w "%{http_code}" \
  -b "$COOKIE_FILE" \
  -X PUT "$BASE_URL/api/settings/thinking-budget" \
  -H "Content-Type: application/json" \
  -d "{
    \"mode\": \"$_THINKING_MODE\",
    \"baseBudget\": $_THINKING_BUDGET
  }")

echo "[init] Thinking budget HTTP $THINKING_CODE"

if [ "$THINKING_CODE" != "200" ] && [ "$THINKING_CODE" != "204" ]; then
  echo "[init] WARN: Thinking budget config may have failed:"
  cat "$THINKING_RESP_FILE" || true
fi

# ── Memory legacy config + Skills（PATCH /api/settings）───────
echo "[init] Applying Memory legacy config + Skills..."

MEMORY_LEGACY_CODE=$(curl -s -o "$MEMORY_LEGACY_RESP_FILE" -w "%{http_code}" \
  -b "$COOKIE_FILE" \
  -X PATCH "$BASE_URL/api/settings" \
  -H "Content-Type: application/json" \
  -d '{
    "memoryEnabled": true,
    "memoryStrategy": "hybrid",
    "memoryMaxTokens": 2000,
    "memoryRetentionDays": 30,
    "skillsEnabled": true
  }')

echo "[init] Memory legacy + Skills HTTP $MEMORY_LEGACY_CODE"

if [ "$MEMORY_LEGACY_CODE" != "200" ] && [ "$MEMORY_LEGACY_CODE" != "204" ]; then
  echo "[init] WARN: Memory legacy + Skills may have failed:"
  cat "$MEMORY_LEGACY_RESP_FILE" || true
fi

# ── Memory extended config（PUT /api/settings/memory）────────
# 【修复3·源码验证】MemorySettingsExtendedSchema(.strict()) 确认字段名：
#   embeddingSource ∈ {remote,static,transformers,auto} / staticEnabled / transformersEnabled
# static = 内置模型无需外部 key，HF 免费层可用。（remote 需 Voyage key，会静默失效）
echo "[init] Applying Memory extended config (static embedding, no external key)..."

MEMORY_EXT_CODE=$(curl -s -o "$MEMORY_EXT_RESP_FILE" -w "%{http_code}" \
  -b "$COOKIE_FILE" \
  -X PUT "$BASE_URL/api/settings/memory" \
  -H "Content-Type: application/json" \
  -d '{
    "embeddingSource": "static",
    "staticEnabled": true,
    "transformersEnabled": false
  }')

echo "[init] Memory extended config HTTP $MEMORY_EXT_CODE"

if [ "$MEMORY_EXT_CODE" != "200" ] && [ "$MEMORY_EXT_CODE" != "204" ]; then
  echo "[init] WARN: Memory extended config may have failed:"
  cat "$MEMORY_EXT_RESP_FILE" || true
fi

# ── 重置所有 circuit breaker ──────────────────────────────────
echo "[init] Resetting circuit breakers..."

CB_RESET_CODE=$(curl -s -o /dev/null -w "%{http_code}" \
  -b "$COOKIE_FILE" \
  -X POST "$BASE_URL/api/resilience/reset" \
  -H "Content-Type: application/json")

echo "[init] Circuit breaker reset HTTP $CB_RESET_CODE"
echo "[init] Clearing persisted circuit breaker states from DB..."
# 【修复6】改用 $_DB_PATH，与全脚本 DB 路径变量统一（原为硬编码 /data/storage.sqlite）
sqlite3 "$_DB_PATH" "DELETE FROM domain_circuit_breakers;" 2>/dev/null || true
echo "[init] Persisted breaker states cleared"

# ── per-model context override（NIM 32K 真实上限）──
# 【修复1】覆盖范围改为 build_all_models（pool ∪ codex ∪ extra），
# 确保任何可能进入 combo 或被调用的模型都有 32K 上限，杜绝增量修复后 502 复发。
echo "[init] Applying per-model context override (NIM 32K cap, source=manual)..."

OVERRIDE_APPLIED=0
OVERRIDE_SKIPPED=0

apply_context_override() {
  local MODEL_ID="$1"
  local CONTEXT="$2"
  # 注意：勿用 `sqlite ... && x || y` 写法——bash 算术赋值退出码恒为 0。用 if/then。
  if sqlite3 "$_DB_PATH" \
    "INSERT OR REPLACE INTO model_context_overrides
       (provider, model_id, real_context, source, refreshed_at)
     VALUES
       ('nvidia', '$(sql_escape "$MODEL_ID")', $CONTEXT, 'manual', datetime('now'));" \
    2>/dev/null; then
    OVERRIDE_APPLIED=$((OVERRIDE_APPLIED + 1))
  else
    OVERRIDE_SKIPPED=$((OVERRIDE_SKIPPED + 1))
  fi
}

while IFS= read -r _M; do
  [ -z "$_M" ] && continue
  apply_context_override "$_M" "$_NIM_REAL_CONTEXT"
done < <(build_all_models)

echo "[init] per-model context override: $OVERRIDE_APPLIED applied, $OVERRIDE_SKIPPED failed (real_context=$_NIM_REAL_CONTEXT)."

# 校验：读回确认 override 已存
OVERRIDE_VERIFY=$(sqlite3 "$_DB_PATH" \
  "SELECT COUNT(*) FROM model_context_overrides
     WHERE provider='nvidia' AND source='manual';" 2>/dev/null || echo 0)
echo "[init] Verify: $OVERRIDE_VERIFY manual overrides persisted in model_context_overrides."

# ── 打印当前参数配置 ──────────────────────────────────────────
echo "[init] ─────────────────────────────────────────────"
echo "[init] 当前参数配置："
echo "[init]   NIM_RPM                = $_RPM"
echo "[init]   NIM_MIN_INTERVAL_MS    = $_MIN_INTERVAL_MS ms"
echo "[init]   NIM_CONCURRENT         = $_CONCURRENT"
echo "[init]   NIM_FALLBACK_STRATEGY  = $_FALLBACK_STRATEGY"
echo "[init]   NIM_STICKY_LIMIT       = $_STICKY_LIMIT"
echo "[init]   NIM_REQUEST_BODY_LIMIT_MB = $_REQUEST_BODY_LIMIT_MB MB (maxBodySizeMb)"
echo "[init]   NIM_COMPRESS_MODE      = $_COMPRESS_MODE"
echo "[init]   NIM_COMPRESS_THRESHOLD = $_COMPRESS_THRESHOLD tokens"
echo "[init]   NIM_REAL_CONTEXT       = $_NIM_REAL_CONTEXT tokens (NIM 32K cap override)"
echo "[init]   NIM_THINKING_MODE      = $_THINKING_MODE"
echo "[init]   NIM_THINKING_BUDGET    = $_THINKING_BUDGET tokens"
echo "[init] ─────────────────────────────────────────────"

# ── 巡检函数：检测 NIM 模型可用性 ──
# 【修复2】巡检清单也引用 SSOT（pool ∪ codex ∪ extra），与注册/override 完全一致。
check_nim_model_health() {
  echo "[init] check_nim_model_health: checking NIM model availability..."
  > /tmp/nim-deprecated.txt
  local _first_key
  _first_key=$(printf '%s\n' "$NIM_KEYS" | head -n1)
  local _models_json
  _models_json=$(curl -s --max-time 10 \
    -H "Authorization: Bearer ${_first_key}" \
    "https://integrate.api.nvidia.com/v1/models" 2>/dev/null || echo "")
  local _model_count
  _model_count=$(printf '%s' "$_models_json" | jq -r '.data[]?.id' 2>/dev/null | wc -l)
  if [ "${_model_count:-0}" -lt 5 ]; then
    echo "[init] check_nim_model_health: NIM API returned $_model_count models (<5), skipping"
    return 0
  fi
  while IFS= read -r model; do
    [ -z "$model" ] && continue
    # any() 聚合为单一布尔（避免 jq -e 只看最后一个输出值导致误判）
    if ! printf '%s' "$_models_json" | jq -e --arg m "$model" \
      'any(.data[]?.id == $m; .)' >/dev/null 2>&1; then
      echo "[init]   $model — DEPRECATED, skipping"
      echo "$model" >> /tmp/nim-deprecated.txt
    else
      echo "[init]   $model — available"
    fi
  done < <(build_all_models)
  local _dep_count
  _dep_count=$(wc -l < /tmp/nim-deprecated.txt 2>/dev/null || echo 0)
  echo "[init] check_nim_model_health: $_dep_count deprecated, $_model_count available on NIM"
}

# ── HF Dataset 配置快照导出（仅导出冷备，恢复走 R2）──
# 【修复6】抽成函数，消除首次/增量两分支的重复代码。
hf_snapshot() {
  if [ -z "$HF_TOKEN" ] || [ -z "$HF_DATASET_REPO" ]; then
    return 0
  fi
  echo "[init] Exporting readable config snapshot to HF Dataset..."
  local BACKUP_DIR="/tmp/omni-snapshot"
  mkdir -p "$BACKUP_DIR"

  # 安全：apiKeys[].key 与 providerConnections[].credentials 含明文，导出阶段即 del。
  local OR_KEY
  OR_KEY="$(resolve_or_key)"
  curl -sf "$BASE_URL/api/settings/export-json" \
    -H "Authorization: Bearer $OR_KEY" \
    | jq 'del(.usageHistory, .domainCostHistory, .domainBudgets) |
          (if (.apiKeys|type)=="array" then .apiKeys |= map(del(.key)) else . end) |
          (if (.providerConnections|type)=="array" then .providerConnections |= map(del(.credentials)) else . end)' \
    > "$BACKUP_DIR/omni_config.json"

  jq '.apiKeys'             "$BACKUP_DIR/omni_config.json" > "$BACKUP_DIR/keys.json"
  jq '.providerConnections' "$BACKUP_DIR/omni_config.json" > "$BACKUP_DIR/providerConnections.json"
  jq '.providerNodes'       "$BACKUP_DIR/omni_config.json" > "$BACKUP_DIR/providerNodes.json"
  jq '.settings'            "$BACKUP_DIR/omni_config.json" > "$BACKUP_DIR/settings.json"
  jq '.combos'              "$BACKUP_DIR/omni_config.json" > "$BACKUP_DIR/combos.json"

  python3 - <<'PYEOF'
import os
from datetime import datetime
from huggingface_hub import HfApi

api = HfApi(token=os.environ["HF_TOKEN"])
api.upload_folder(
    folder_path="/tmp/omni-snapshot",
    path_in_repo="omni_data",
    repo_id=os.environ["HF_DATASET_REPO"],
    repo_type="dataset",
    commit_message=f"Sync omni_data - {datetime.utcnow().isoformat()}",
)
print("[init] HF Dataset snapshot uploaded.")
PYEOF
}

# ── 增量 Combo 修复：按 SSOT 重算 models（剔除已下架）并 PUT ──
# 【修复1+2】models 来源改为 SSOT 数组，不再硬编码另一份 11 模型清单。
repair_combo() {
  local COMBO_NAME="$1"; shift
  local STRAT="$1"; shift
  local ALL_MODELS=("$@")   # 该 combo 的完整 SSOT 模型列表

  local COMBOS_JSON CID
  COMBOS_JSON=$(curl -s -b "$COOKIE_FILE" "$BASE_URL/api/combos" || true)
  CID=$(printf '%s' "$COMBOS_JSON" | jq -r --arg n "$COMBO_NAME" \
    '.combos[]? // .[]? | select(.name==$n) | .id' | head -n1)

  if [ -z "$CID" ]; then
    echo "[init] Incremental: $COMBO_NAME not found in DB, skip repair."
    return 0
  fi

  # 剔除已下架模型
  local KEEP=()
  local m
  for m in "${ALL_MODELS[@]}"; do
    grep -Fxq "$m" /tmp/nim-deprecated.txt 2>/dev/null || KEEP+=("$m")
  done

  if [ "${#KEEP[@]}" -eq 0 ]; then
    echo "[init] WARN: Incremental: $COMBO_NAME 所有候选模型均下架，skip PUT。"
    return 0
  fi

  local PUT_BODY
  PUT_BODY=$(jq -n --arg name "$COMBO_NAME" --arg strat "$STRAT" \
    --argjson models "$(models_to_json "${KEEP[@]}")" \
    '{name:$name, strategy:$strat, models:$models}')

  local PUT_CODE
  PUT_CODE=$(curl -s -o /dev/null -w "%{http_code}" \
    -b "$COOKIE_FILE" -X PUT "$BASE_URL/api/combos/$CID" \
    -H "Content-Type: application/json" -d "$PUT_BODY" || true)

  if [ "$PUT_CODE" = "200" ] || [ "$PUT_CODE" = "204" ]; then
    echo "[init] Incremental: PUT /api/combos/$CID ($COMBO_NAME) HTTP $PUT_CODE OK"
  else
    echo "[init] WARN: Incremental: PUT /api/combos/$CID ($COMBO_NAME) HTTP $PUT_CODE（Combo 修复失败但非致命）"
  fi
}

# ── 首次初始化检查（SQLite 感知，替代文件标记）─────────────────────────────
if [ -f "$_DB_PATH" ]; then
  COMBO_COUNT=$(sqlite3 "$_DB_PATH" \
    "SELECT COUNT(*) FROM combos WHERE name='$(sql_escape "nim-pool")';" 2>/dev/null || echo 0)
  if [ "${COMBO_COUNT:-0}" -gt 0 ]; then
    echo "[init] Already initialized (nim-pool found in DB), skip first-time setup."

    # ===== 巡检 + 增量 Combo 修复 =====
    check_nim_model_health

    if [ -s /tmp/nim-deprecated.txt ]; then
      echo "[init] Incremental: deprecated models detected, repairing Combos..."
      repair_combo "nim-pool"  "round-robin"   "${NIM_POOL_MODELS[@]}"
      repair_combo "nim-codex" "context-relay" "${NIM_CODEX_MODELS[@]}"
    else
      echo "[init] Incremental: no deprecated models, Combos OK."
    fi

    # ===== 配置快照导出到 HF Dataset =====
    hf_snapshot

    echo "[init] Done (incremental mode). v3.4.0"
    exit 0
  fi
else
  echo "[init] DB not present yet (first deploy or pre-engine). Proceeding with first-time init."
fi

# ── 模型目录注册 ──────────────────────────────────────────────
# 【修复2】注册清单 = SSOT（pool ∪ codex ∪ extra），与 override/巡检完全一致。
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

while IFS= read -r _M; do
  [ -z "$_M" ] && continue
  register_model "$_M"
done < <(build_all_models)

echo "[init] Model registration done."

# ── 创建 Combo：nim-pool（通用，round-robin）─────────────────
# 【修复2】models 由 SSOT 数组生成，不再硬编码。
echo "[init] Creating Combo nim-pool (strategy=round-robin)..."

NIM_POOL_JSON=$(models_to_json "${NIM_POOL_MODELS[@]}")

COMBO_CODE=$(curl -s -o "$COMBO_RESP_FILE" -w "%{http_code}" \
  -b "$COOKIE_FILE" \
  -X POST "$BASE_URL/api/combos" \
  -H "Content-Type: application/json" \
  -d "$(jq -n --argjson models "$NIM_POOL_JSON" \
    '{name:"nim-pool", strategy:"round-robin", models:$models}')")

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
echo "[init] Creating Combo nim-codex (strategy=context-relay)..."

CODEX_COMBO_RESP_FILE="/tmp/omniroute-codex-combo-response.json"
NIM_CODEX_JSON=$(models_to_json "${NIM_CODEX_MODELS[@]}")

CODEX_COMBO_CODE=$(curl -s -o "$CODEX_COMBO_RESP_FILE" -w "%{http_code}" \
  -b "$COOKIE_FILE" \
  -X POST "$BASE_URL/api/combos" \
  -H "Content-Type: application/json" \
  -d "$(jq -n --argjson models "$NIM_CODEX_JSON" \
    '{name:"nim-codex", strategy:"context-relay", models:$models}')")

echo "[init] Combo nim-codex HTTP $CODEX_COMBO_CODE"

if [ "$CODEX_COMBO_CODE" = "200" ] || [ "$CODEX_COMBO_CODE" = "201" ]; then
  echo "[init] Combo nim-codex created OK"
elif [ "$CODEX_COMBO_CODE" = "400" ] && grep -q "already exists" "$CODEX_COMBO_RESP_FILE" 2>/dev/null; then
  echo "[init] Combo nim-codex already exists, skipped"
else
  echo "[init] WARN: Combo nim-codex unexpected response (HTTP $CODEX_COMBO_CODE):"
  cat "$CODEX_COMBO_RESP_FILE" || true
fi

# ── 可读配置快照 → HF Dataset（首次）──
# 【修复6】复用 hf_snapshot 函数，与增量分支同一实现。
hf_snapshot

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
echo "[init] Done (first-init mode). v3.4.0"
