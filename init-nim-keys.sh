#!/bin/bash
set -eo pipefail

# ─────────────────────────────────────────────────────────────
# NIM OmniRoute initializer
# v3.3.0
# 修复历史：
#   v2.2.0  原始版本（基于 OmniRoute v3.5.x 时代的 schema）
#   v3.0.0  适配 OmniRoute v3.8.0：移除不可用模型、Resilience/Compression 差量 PATCH
#   v3.0.1  删除 Qoder AI 注册段
#   v3.1.5  修复环境变量覆盖问题；Litestream + R2 持久化集成
#   v3.2.0  移除可硬编码环境变量依赖；新增 Memory/Skills/nim-codex Combo
#   v3.2.1  修复 Memory extended fields API field 名（去掉 memory 前缀）
#   v3.2.2  修复 Memory legacy fields 端点错误：
#            memoryEnabled/Strategy/MaxTokens/RetentionDays 走 PATCH /api/settings
#            embeddingSource/staticEnabled 走 PUT /api/settings/memory
#            skillsEnabled 合并进 PATCH /api/settings，减少一次 HTTP 调用
#   v3.3.0  解决 NIM 32K 超限触发的 502 风暴（对齐 OmniRoute v3.8.4x schema）：
#            (1) per-model context override：直接写 storage.sqlite 的 model_context_overrides
#                表（source='manual'，real_context=32768，全 11 个 NIM 模型），让压缩引擎
#                据真实 32K 上限算目标，而非标称 128K。manual 永不被 24h reconciler 覆盖。
#                无 HTTP API 写 manual override，故经 DB。
#            (2) compression 端点纠正：PATCH /api/settings + compression.{...} 嵌套 →
#                PUT /api/settings/compression 扁平 body（上游 .strict() 会拒多余字段）。
#            (3) thinkingBudget 独立端点：拆出 PUT /api/settings/thinking-budget，字段
#                {mode,baseBudget}（旧拼 {enabled,maxTokens} 全错，静默 WARN）。
#            (4) maxBodySizeMb：字段名 requestBodyLimit → maxBodySizeMb，单位 MB（非 bytes），
#                上游 MIN=1MB → 取 1MB（较原 10MB 收紧 10 倍），超限请求上游返回 413 拦截。
#            (5) routing 加 requestRetry=2 / maxRetryIntervalSec=5（空响应/502 有限重试）。
#            阈值 threshold=12000（HF env 覆盖时需在 Dashboard 改回，仓库内已默认 12000）。
#            memory legacy 段（memoryEnabled/skillsEnabled）schema 漂移留旧患，本次不动。
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

# ── 动态参数（优先从环境变量读取，若未设置则使用默认值） ───────────────────
# 在 HF Space 的 Settings > Variables and Secrets 中添加同名变量即可
_RPM=${NIM_RPM:-40}
_CONCURRENT=${NIM_CONCURRENT:-5}
_MIN_INTERVAL_MS=${NIM_MIN_INTERVAL_MS:-500}
_COMPRESS_THRESHOLD=${NIM_COMPRESS_THRESHOLD:-12000}
_FALLBACK_STRATEGY="round-robin"
_STICKY_LIMIT=1
# 上游字段名 maxBodySizeMb（单位 MB，非 bytes）。范围 [MIN=1, MAX=500]。
# 任务原意 512KB 拦截超大请求，但 schema 强制 ≥1MB。取下限 1MB（较现状 10MB 仍收紧 10 倍），
# 在发送给 NIM 前由上游拦截超大请求返回 413，而非透传触发 NIM 侧 502 风暴。
# 注：MB 字节限非 token 限，高密度小体积仍可能漏过——是 NIM 32K 超限前置守门第一道。
_REQUEST_BODY_LIMIT_MB=${NIM_REQUEST_BODY_LIMIT_MB:-1}
_COMPRESS_MODE="stacked"
_THINKING_MODE="adaptive"
_THINKING_BUDGET=8000
# ── NIM 真实上下文上限（标称 128K，实测 NIM 32K 截断 → 压缩引擎须知道 32768）───
# 写入 model_context_overrides 表 source='manual'，24h reconciler 永不覆盖。
_NIM_REAL_CONTEXT=${NIM_REAL_CONTEXT:-32768}

# ── SQLite 路径（真实 OmniRoute 库，与引擎一致）─────────────────────────────
_DB_PATH="${DATA_DIR:-/data}/storage.sqlite"

# sql_escape：转义字符串用于 SQLite 单引号字面量（' → ''）
# 用法：sqlite3 "$_DB_PATH" "SELECT ... WHERE name='$(sql_escape "$VAL")'"
sql_escape() {
  printf '%s' "$1" | sed "s/'/''/g"
}

echo "[init] Starting NIM OmniRoute initializer v3.2.2..."
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
# env 设置（含纯空白）时 ${:-} 短路不触发 cat，避免文件缺失报错。
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
# 上游 v3.8.4x compressionSettingsUpdateSchema 为 .strict()：多余字段 400。
# 厉害点：(1) 必须扁平（非 compression.{...} 嵌套）；(2) 端点是 PUT 不是 PATCH；
# (3) thinkingBudget 不在此端点（拆独立 /api/settings/thinking-budget，见下）。
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
# 上游 updateThinkingBudgetSchema(.strict()) 字段：mode / customBudget / effortLevel /
# baseBudget / complexityMultiplier（无 enabled/maxTokens，旧拼字段全部失败为静默 WARN）。
# mode=adaptive 时 baseBudget 是思考预算基线 tokens。
echo "[init] Applying thinking budget (mode=$_THINKING_MODE, baseBudget=$_THINKING_BUDGET)..."

THINKING_RESP_FILE="/tmp/omniroute-thinking-response.json"
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
#
# legacy memory fields（DB key = API field）与 skillsEnabled
# 统一走 PATCH /api/settings，合并为一次调用
#
# memoryStrategy 枚举：recent（内部映射 exact）/ semantic / hybrid
# skillsEnabled=true 后内置 Skills 自动可用：
#   file_read / file_write / http_request / web_search

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
#
# v3.8.6 新增的 extended fields 走独立端点 PUT /api/settings/memory
# API field 名无 memory 前缀（与 DB key 不同）：
#   embeddingSource（DB key: memoryEmbeddingSource）
#   staticEnabled  （DB key: memoryStaticEnabled）
#
# embeddingSource=static：内置 potion-base-8M，无需外部 API Key
#   冷启动 ~200ms，HF Space 免费层完全可用
# staticEnabled=true：必须同时设为 true 才能激活 static 源

echo "[init] Applying Memory extended config (remote embedding via Voyage AI)..."

MEMORY_EXT_CODE=$(curl -s -o "$MEMORY_EXT_RESP_FILE" -w "%{http_code}" \
  -b "$COOKIE_FILE" \
  -X PUT "$BASE_URL/api/settings/memory" \
  -H "Content-Type: application/json" \
  -d '{
    "embeddingSource": "remote",
    "embeddingProviderModel": "voyage-ai/voyage-3",
    "staticEnabled": false,
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
sqlite3 /data/storage.sqlite "DELETE FROM domain_circuit_breakers;" 2>/dev/null || true
echo "[init] Persisted breaker states cleared"

# ── per-model context override（NIM 32K 真实上限 → 压缩引擎据此目标压到 32K 以内）──
#
# 上游 v3.8.4x：getModelContextLimit() 优先级 = model_context_overrides(manual) >
# static catalog / models.dev sync。source='manual' 的 override 永不被 24h
# contextWindowReconciler（source='auto:discovery'）覆盖。无 HTTP API 写 manual
# override（setModelContextOverride 仅 reconciler 内部调用），故直接写 DB 表。
#
# NIM 标称 128K，实测 32K 截断 → 压缩引擎按 128K 算目标，压完仍 >32K 触发 NIM 502 风暴。
# 写 real_context=32768 让引擎把压缩目标下移到 32K 以内。覆盖全部经 nvidia provider
# 注册的 NIM 模型（与 register_model 列表一致），不只任务列的 5 个。
#
# DB 路径与引擎一致（$_DB_PATH）；表 migration 110 已随 OmniRoute 启动建成。
# 每行 INSERT OR REPLACE，重复执行幂等（PK = provider+model_id）。
echo "[init] Applying per-model context override (NIM 32K cap, source=manual)..."

OVERRIDE_APPLIED=0
OVERRIDE_SKIPPED=0

apply_context_override() {
  local MODEL_ID="$1"
  local CONTEXT="$2"

  # 注意：勿用 `sqlite ... && count=$((x+1)) || y=$((y+1))` 写法——
  # bash 算术赋值退出码恒为 0，会令 || 分支永不触发、失败也计 applied。
  # 用 if/then 据 sqlite3 真退出码判断。
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

for _M in \
  "minimaxai/minimax-m2.7" \
  "moonshotai/kimi-k2-thinking" \
  "moonshotai/kimi-k2.6" \
  "z-ai/glm-5.2" \
  "nvidia/nemotron-3-super-120b-a12b" \
  "qwen/qwen3-coder-480b-a35b-instruct" \
  "mistralai/mistral-small-4-119b-2603" \
  "mistralai/mistral-medium-3.5-128b" \
  "meta/llama-3.2-90b-vision-instruct" \
  "deepseek-ai/deepseek-v4-pro" \
  "deepseek-ai/deepseek-v4-flash"
do
  apply_context_override "$_M" "$_NIM_REAL_CONTEXT"
done

echo "[init] per-model context override: $OVERRIDE_APPLIED applied, $OVERRIDE_SKIPPED failed (real_context=$_NIM_REAL_CONTEXT)."

# 校验：读回确认 override 已存（manual source 列不应为空）
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

# ── 首次初始化检查（SQLite 感知，替代文件标记）─────────────────────────────
# HF Space 重建后容器内文件标记消失，故改为查询 combos 表判断是否已初始化
if [ -f "$_DB_PATH" ]; then
  COMBO_COUNT=$(sqlite3 "$_DB_PATH" \
    "SELECT COUNT(*) FROM combos WHERE name='$(sql_escape "nim-pool")';" 2>/dev/null || echo 0)
  if [ "${COMBO_COUNT:-0}" -gt 0 ]; then
    echo "[init] Already initialized (nim-pool found in DB), skip first-time setup."

    # ===== 巡检 + 增量 Combo 修复（spec §4.6）=====
    check_nim_model_health

    if [ -s /tmp/nim-deprecated.txt ]; then
      echo "[init] Incremental: deprecated models detected, repairing Combos..."
      # GET /api/combos 找各 Combo id
      COMBOS_JSON=$(curl -s -b "$COOKIE_FILE" "$BASE_URL/api/combos" || true)
      for combo_name in nim-pool nim-codex; do
        CID=$(printf '%s' "$COMBOS_JSON" | jq -r --arg n "$combo_name" \
          '.combos[]? // .[]? | select(.name==$n) | .id' | head -n1)
        if [ -n "$CID" ]; then
          # 按 Combo 名重算 models（剔除下架）
          NEW_MODELS=""
          if [ "$combo_name" = "nim-pool" ]; then
            for m in "minimaxai/minimax-m2.7" "moonshotai/kimi-k2.6" "z-ai/glm-5.2" \
                     "nvidia/nemotron-3-super-120b-a12b" "mistralai/mistral-small-4-119b-2603" \
                     "meta/llama-3.2-90b-vision-instruct" "openai/gpt-oss-120b" \
                     "qwen/qwen3-next-80b-a3b-instruct" "nvidia/nemotron-3-ultra-550b-a55b" \
                     "deepseek-ai/deepseek-v4-pro" "mistralai/mistral-large-3-675b-instruct-2512"; do
              grep -Fxq "$m" /tmp/nim-deprecated.txt 2>/dev/null || NEW_MODELS="${NEW_MODELS},\"$m\""
            done
            STRAT="round-robin"
          else
            for m in "openai/gpt-oss-120b" "qwen/qwen3-next-80b-a3b-instruct" "mistralai/mistral-medium-3.5-128b"; do
              grep -Fxq "$m" /tmp/nim-deprecated.txt 2>/dev/null || NEW_MODELS="${NEW_MODELS},\"$m\""
            done
            STRAT="context-relay"
          fi
          NEW_MODELS="${NEW_MODELS#,}"
          if [ -z "$NEW_MODELS" ]; then
            echo "[init] WARN: Incremental: $combo_name 所有候选模型均下架,skip PUT(空 models Combo 无可用模型)"
            continue
          fi
          PUT_BODY=$(jq -n --arg name "$combo_name" --arg strat "$STRAT" \
            --argjson models "$(printf '[%s]' "$NEW_MODELS")" \
            '{name:$name, strategy:$strat, models:$models}')
          PUT_CODE=$(curl -s -o /dev/null -w "%{http_code}" \
            -b "$COOKIE_FILE" -X PUT "$BASE_URL/api/combos/$CID" \
            -H "Content-Type: application/json" -d "$PUT_BODY" || true)
          PUT_OK=0
          if [ "$PUT_CODE" = "200" ] || [ "$PUT_CODE" = "204" ]; then PUT_OK=1; fi
          if [ "$PUT_OK" = "1" ]; then
            echo "[init] Incremental: PUT /api/combos/$CID ($combo_name) HTTP $PUT_CODE OK"
          else
            echo "[init] WARN: Incremental: PUT /api/combos/$CID ($combo_name) HTTP $PUT_CODE (非 200/204,Combo 修复失败但非致命)"
          fi
        else
          echo "[init] Incremental: $combo_name not found in DB, skip repair."
        fi
      done
    else
      echo "[init] Incremental: no deprecated models, Combos OK."
    fi

    # ===== 配置快照导出到 HF Dataset（重建场景：DB 有完整配置）=====
    if [ -n "$HF_TOKEN" ] && [ -n "$HF_DATASET_REPO" ]; then
      echo "[init] Exporting readable config snapshot to HF Dataset..."
      BACKUP_DIR="/tmp/omni-snapshot"
      mkdir -p "$BACKUP_DIR"

      # export-json 上游 v3.8+：默认已排 telemetry（#2125，opt-in ?includeHistory=true）
      # 这里仍显式 del 兼容旧版。字段名已重构：keys→apiKeys、providers→providerConnections+providerNodes
      # 安全：apiKeys[].key 与 providerConnections[].credentials 含明文（上游 getProviderConnections 解密返明文），
      # dataset 即便 private 也不可存明文凭证 → 导出阶段即 del，保留元数据（name/scopes/key_hash/provider/id）
      OR_KEY="$(resolve_or_key)"
      curl -sf "$BASE_URL/api/settings/export-json" \
        -H "Authorization: Bearer $OR_KEY" \
        | jq 'del(.usageHistory, .domainCostHistory, .domainBudgets) |
              (if (.apiKeys|type)=="array" then .apiKeys |= map(del(.key)) else . end) |
              (if (.providerConnections|type)=="array" then .providerConnections |= map(del(.credentials)) else . end)' \
        > "$BACKUP_DIR/omni_config.json"

      # 拆分成可读子文件（字段名对齐上游 v3.8+）
      jq '.apiKeys'             "$BACKUP_DIR/omni_config.json" > "$BACKUP_DIR/keys.json"
      jq '.providerConnections' "$BACKUP_DIR/omni_config.json" > "$BACKUP_DIR/providerConnections.json"
      jq '.providerNodes'       "$BACKUP_DIR/omni_config.json" > "$BACKUP_DIR/providerNodes.json"
      jq '.settings'            "$BACKUP_DIR/omni_config.json" > "$BACKUP_DIR/settings.json"
      jq '.combos'              "$BACKUP_DIR/omni_config.json" > "$BACKUP_DIR/combos.json"

      # 上传到 HF Dataset
      python3 - <<'PYEOF'
import os, json
from pathlib import Path
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
    fi

    echo "[init] Done (incremental mode)."
    exit 0
  fi
else
  echo "[init] DB not present yet (first deploy or pre-engine). Proceeding with first-time init."
fi

# ── 模型目录注册 ──────────────────────────────────────────────
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

# nim-pool 核心模型
register_model "minimaxai/minimax-m2.7"
register_model "moonshotai/kimi-k2-thinking"
register_model "moonshotai/kimi-k2.6"
register_model "z-ai/glm-5.2"
register_model "nvidia/nemotron-3-super-120b-a12b"
register_model "qwen/qwen3-coder-480b-a35b-instruct"
register_model "mistralai/mistral-small-4-119b-2603"
register_model "mistralai/mistral-medium-3.5-128b"
register_model "meta/llama-3.2-90b-vision-instruct"

# 额外目录项（备用，不放入 Combo）
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
      "z-ai/glm-5.2",
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
# context-relay：Key 耗尽轮转时自动生成上下文摘要注入给下一个 Key
# 适合 Codex CLI / 大型重构 / 多轮代码审查
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

# ── 可读配置快照 → HF Dataset ────────────────────────────────
# 仅导出冷备，恢复链路仍走 stage2 的 R2 restore（本轮不接 HF Dataset 恢复）
# 仅在 HF_TOKEN 和 HF_DATASET_REPO 已设置时执行
if [ -n "$HF_TOKEN" ] && [ -n "$HF_DATASET_REPO" ]; then
  echo "[init] Exporting readable config snapshot to HF Dataset..."
  BACKUP_DIR="/tmp/omni-snapshot"
  mkdir -p "$BACKUP_DIR"

  # export-json 上游 v3.8+：默认已排 telemetry（#2125，opt-in ?includeHistory=true）
  # 这里仍显式 del 兼容旧版。字段名已重构：keys→apiKeys、providers→providerConnections+providerNodes
  # 安全：apiKeys[].key 与 providerConnections[].credentials 含明文（上游 getProviderConnections 解密返明文），
  # dataset 即便 private 也不可存明文凭证 → 导出阶段即 del，保留元数据（name/scopes/key_hash/provider/id）
  OR_KEY="$(resolve_or_key)"
  curl -sf "$BASE_URL/api/settings/export-json" \
    -H "Authorization: Bearer $OR_KEY" \
    | jq 'del(.usageHistory, .domainCostHistory, .domainBudgets) |
          (if (.apiKeys|type)=="array" then .apiKeys |= map(del(.key)) else . end) |
          (if (.providerConnections|type)=="array" then .providerConnections |= map(del(.credentials)) else . end)' \
    > "$BACKUP_DIR/omni_config.json"

  # 拆分成可读子文件（字段名对齐上游 v3.8+）
  jq '.apiKeys'             "$BACKUP_DIR/omni_config.json" > "$BACKUP_DIR/keys.json"
  jq '.providerConnections' "$BACKUP_DIR/omni_config.json" > "$BACKUP_DIR/providerConnections.json"
  jq '.providerNodes'       "$BACKUP_DIR/omni_config.json" > "$BACKUP_DIR/providerNodes.json"
  jq '.settings'            "$BACKUP_DIR/omni_config.json" > "$BACKUP_DIR/settings.json"
  jq '.combos'              "$BACKUP_DIR/omni_config.json" > "$BACKUP_DIR/combos.json"

  # 上传到 HF Dataset
  python3 - <<'PYEOF'
import os, json
from pathlib import Path
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
echo "[init] Done (first-init mode). v3.2.2"
