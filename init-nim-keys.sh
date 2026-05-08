#!/bin/bash
# ============================================================================
# OmniRoute Init Script v1.9.0 — v3.7.9 Final Edition
# 基于 OmniRoute v3.7.9 (2026-05-06 Latest)
# 源码锚定：
#   openapi.yaml          — 所有端点 schema
#   types.ts              — CavemanIntensity / RtkIntensity 枚举
#   CHANGELOG v3.7.9      — 新增 requestBodyLimit / compression preview auth
#   RESILIENCE_GUIDE.md   — resilience 默认值与字段语义
# ============================================================================
set -eo pipefail

# ─── 配置常量（从环境变量注入，禁止硬编码凭据）────────────────────────────────
: "${OMNIROUTE_PORT:=20128}"
: "${OMNIROUTE_DATA_DIR:=/data}"
: "${OMNIROUTE_PASSWORD:=123456}"          # 对应 INITIAL_PASSWORD env var
: "${OMNIROUTE_COMBO_MODEL:=deepseek-ai/deepseek-r1}"

BASE_URL="http://127.0.0.1:${OMNIROUTE_PORT}"
DATA_DIR="$OMNIROUTE_DATA_DIR"
INIT_MARKER="$DATA_DIR/.init-done"
OR_KEY_FILE="$DATA_DIR/.or-api-key"
COOKIE_FILE="/tmp/omniroute-cookie-$$.txt"   # $$ 避免并发冲突
RESP_DIR="/tmp/omniroute-init-$$"

# 上游 provider 凭据（从宿主 env 注入）
NIM_KEY_1="${NIM_KEY_1:-}"
NIM_KEY_2="${NIM_KEY_2:-}"
NIM_KEY_3="${NIM_KEY_3:-}"
QODER_KEY="${QODER_KEY:-}"

NIM_BASE_URL="https://integrate.api.nvidia.com/v1"
QODER_BASE_URL="https://api.qoder.com/v1"

# ─── 初始化工作目录 ───────────────────────────────────────────────────────────
mkdir -p "$DATA_DIR" "$RESP_DIR"
trap 'rm -rf "$RESP_DIR" "$COOKIE_FILE"' EXIT   # 退出时清理临时文件

log()  { echo "[init] $*"; }
warn() { echo "[init] WARN: $*" >&2; }
die()  { echo "[init] FATAL: $*" >&2; exit 1; }

# HTTP 调用封装：自动打印 code，非 2xx 写 warn 但不强制退出（除非调用方用 die）
http() {
  local method="$1" url="$2" out="$3"; shift 3
  local code
  code=$(curl -s -o "$out" -w "%{http_code}" -b "$COOKIE_FILE" -X "$method" "$url" "$@")
  echo "$code"
}

# ─── 0. 幂等检查 ─────────────────────────────────────────────────────────────
if [ -f "$INIT_MARKER" ]; then
  log "Already initialized at $(cat "$INIT_MARKER"), skipping."
  exit 0
fi

# ─── 1. 等待 OmniRoute 就绪 ──────────────────────────────────────────────────
# 锚定：API_REFERENCE.md → /api/monitoring/health → 200 = ready
log "Waiting for OmniRoute at $BASE_URL/api/monitoring/health ..."
READY=0
for i in $(seq 1 90); do
  CODE=$(curl -s -o /dev/null -w "%{http_code}" \
    --connect-timeout 2 --max-time 5 \
    "$BASE_URL/api/monitoring/health" 2>/dev/null || echo "000")
  if [ "$CODE" = "200" ]; then
    log "Ready after ${i}s"
    READY=1; break
  fi
  [ "$((i % 10))" = "0" ] && log "  still waiting... (${i}s, last=$CODE)"
  sleep 1
done
[ "$READY" = "0" ] && die "OmniRoute not ready after 90s"

# ─── 2. 登录拿 auth_token cookie ─────────────────────────────────────────────
# 锚定：openapi.yaml /api/auth/login → required: [password]，无 username/email
log "Logging in..."
LOGIN_CODE=$(curl -s -o "$RESP_DIR/login.json" -w "%{http_code}" \
  -c "$COOKIE_FILE" \
  -X POST "$BASE_URL/api/auth/login" \
  -H "Content-Type: application/json" \
  -d "{\"password\":\"${OMNIROUTE_PASSWORD}\"}")
[ "$LOGIN_CODE" != "200" ] && { cat "$RESP_DIR/login.json"; die "Login failed HTTP $LOGIN_CODE"; }
log "Login OK (cookie written to $COOKIE_FILE)"

# ─── 3. 全局 settings：开启 requestBodyLimit（v3.7.9 新字段）────────────────
# 锚定：CHANGELOG v3.7.9 feat(settings): add request body limit setting (#1968)
# 10MB = 10485760 bytes，足够容纳 62K token 的完整请求体（~250KB）
# 同时设置 requireLogin=false（保持 /v1/* 无需 bearer 的开发模式）
log "Patching global settings (requestBodyLimit + requireLogin)..."
SETTINGS_CODE=$(http PATCH "$BASE_URL/api/settings" "$RESP_DIR/settings.json" \
  -H "Content-Type: application/json" \
  -d '{
    "requestBodyLimit": 10485760,
    "requireLogin": false
  }')
log "Settings PATCH HTTP $SETTINGS_CODE"
[ "$SETTINGS_CODE" != "200" ] && warn "settings PATCH non-200, body: $(head -c 300 "$RESP_DIR/settings.json")"

# ─── 4. 创建 OmniRoute 自身 API key ─────────────────────────────────────────
# 锚定：openapi.yaml /api/keys POST → required: [label]
# 响应 201，包含完整 key（只返回一次）
if [ -f "$OR_KEY_FILE" ]; then
  log "Reusing existing OR API key from $OR_KEY_FILE"
  OR_KEY=$(cat "$OR_KEY_FILE")
else
  log "Creating OmniRoute API key..."
  KEY_CODE=$(http POST "$BASE_URL/api/keys" "$RESP_DIR/key.json" \
    -H "Content-Type: application/json" \
    -d '{"label":"claude-code-default"}')
  [ "$KEY_CODE" != "201" ] && [ "$KEY_CODE" != "200" ] && \
    { cat "$RESP_DIR/key.json"; die "Key creation failed HTTP $KEY_CODE"; }
  # 响应字段名未在 openapi 中明确，用三选一兜底
  OR_KEY=$(jq -r '.key // .apiKey // .value // empty' "$RESP_DIR/key.json" 2>/dev/null)
  [ -z "$OR_KEY" ] && { log "Response was:"; cat "$RESP_DIR/key.json"; die "Cannot extract key from response — check field name above"; }
  (umask 077; echo -n "$OR_KEY" > "$OR_KEY_FILE")
  log "OR API key saved to $OR_KEY_FILE"
fi

# ─── 5. 注册上游 provider connections ────────────────────────────────────────
# 锚定：openapi.yaml ProviderConnectionCreate → required: [provider, url]
# provider 字段值："openai-compatible"（通用兼容层）
# v3.7.9 fix: local OpenAI-compatible endpoints can be added without API key（NIM 有 key，不受影响）

register_provider() {
  local name="$1" url="$2" key="$3"
  [ -z "$key" ] && { log "Skipping $name (no key)"; return 0; }

  # 幂等：先查是否已存在同名 connection
  curl -s -b "$COOKIE_FILE" "$BASE_URL/api/providers" \
    -o "$RESP_DIR/providers_check.json" 2>/dev/null
  EXISTING=$(jq -r --arg n "$name" '.connections[]? | select(.name==$n) | .id' \
    "$RESP_DIR/providers_check.json" 2>/dev/null | head -1)
  if [ -n "$EXISTING" ] && [ "$EXISTING" != "null" ]; then
    log "Provider $name already exists (id=$EXISTING), skipping"
    return 0
  fi

  local body
  body=$(jq -n \
    --arg provider "openai-compatible" \
    --arg name "$name" \
    --arg url "$url" \
    --arg apiKey "$key" \
    '{provider:$provider, name:$name, url:$url, apiKey:$apiKey, isActive:true}')
  local code
  code=$(http POST "$BASE_URL/api/providers" "$RESP_DIR/prov_${name}.json" \
    -H "Content-Type: application/json" -d "$body")
  log "Provider $name → HTTP $code"
  [ "$code" != "201" ] && [ "$code" != "200" ] && \
    warn "provider $name non-2xx: $(head -c 300 "$RESP_DIR/prov_${name}.json")"
}

register_provider "nim-1" "$NIM_BASE_URL" "$NIM_KEY_1"
register_provider "nim-2" "$NIM_BASE_URL" "$NIM_KEY_2"
register_provider "nim-3" "$NIM_BASE_URL" "$NIM_KEY_3"
register_provider "qoder" "$QODER_BASE_URL" "$QODER_KEY"

# 拉最新 connection 列表，提取各 ID
curl -s -b "$COOKIE_FILE" "$BASE_URL/api/providers" \
  -o "$RESP_DIR/providers.json" 2>/dev/null
NIM1_ID=$(jq -r '.connections[]? | select(.name=="nim-1") | .id' "$RESP_DIR/providers.json" | head -1)
NIM2_ID=$(jq -r '.connections[]? | select(.name=="nim-2") | .id' "$RESP_DIR/providers.json" | head -1)
NIM3_ID=$(jq -r '.connections[]? | select(.name=="nim-3") | .id' "$RESP_DIR/providers.json" | head -1)
QODER_ID=$(jq -r '.connections[]? | select(.name=="qoder") | .id' "$RESP_DIR/providers.json" | head -1)
log "Provider IDs: nim1=$NIM1_ID nim2=$NIM2_ID nim3=$NIM3_ID qoder=$QODER_ID"

# ─── 6. 创建 routing combo "nim-pool" ───────────────────────────────────────
# 锚定：openapi.yaml ComboCreate → required: [name, model]
# strategy enum: priority|weighted|round-robin|random|least-used|cost-optimized
# v3.7.9 fix(combos): align strategy contracts (#1892) — round-robin 现在可靠
# 幂等：先查是否已存在

log "Checking existing combos..."
curl -s -b "$COOKIE_FILE" "$BASE_URL/api/combos" -o "$RESP_DIR/combos_check.json" 2>/dev/null
EXISTING_COMBO=$(jq -r '.combos[]? | select(.name=="nim-pool") | .id' \
  "$RESP_DIR/combos_check.json" 2>/dev/null | head -1)

if [ -n "$EXISTING_COMBO" ] && [ "$EXISTING_COMBO" != "null" ]; then
  log "Combo nim-pool already exists (id=$EXISTING_COMBO), skipping creation"
else
  log "Creating routing combo nim-pool..."
  # 只把有效 ID 的 node 加进去
  NODES_JSON=$(jq -n \
    --arg n1 "$NIM1_ID" --arg n2 "$NIM2_ID" \
    --arg n3 "$NIM3_ID" --arg qd "$QODER_ID" \
    '[
      ($n1 | select(. != "" and . != "null") | {connectionId:., priority:1, weight:1}),
      ($n2 | select(. != "" and . != "null") | {connectionId:., priority:2, weight:1}),
      ($n3 | select(. != "" and . != "null") | {connectionId:., priority:3, weight:1}),
      ($qd | select(. != "" and . != "null") | {connectionId:., priority:4, weight:1})
    ] | map(select(. != null))')

  NODE_COUNT=$(echo "$NODES_JSON" | jq 'length')
  [ "$NODE_COUNT" = "0" ] && die "No valid provider IDs found — cannot create combo"
  log "Combo will have $NODE_COUNT nodes"

  COMBO_BODY=$(jq -n \
    --arg model "$OMNIROUTE_COMBO_MODEL" \
    --argjson nodes "$NODES_JSON" \
    '{name:"nim-pool", model:$model, strategy:"round-robin", nodes:$nodes}')

  COMBO_CODE=$(http POST "$BASE_URL/api/combos" "$RESP_DIR/combo.json" \
    -H "Content-Type: application/json" -d "$COMBO_BODY")
  log "Combo create HTTP $COMBO_CODE"
  [ "$COMBO_CODE" != "201" ] && [ "$COMBO_CODE" != "200" ] && \
    warn "combo create non-2xx: $(head -c 400 "$RESP_DIR/combo.json")"
fi

# ─── 7. ★ 完整压缩配置（单次 PUT）────────────────────────────────────────────
# 锚定：
#   types.ts CavemanIntensity = "lite" | "full" | "ultra"
#   types.ts RtkIntensity = "minimal" | "standard" | "aggressive"
#   types.ts DEFAULT stackedPipeline = [{rtk standard},{caveman full}]
#   openapi.yaml PUT /api/settings/compression
#   CHANGELOG v3.7.9 fix(compression): align seeded standard savings combo with stacked default
log "★ Writing compression config (stacked: RTK aggressive + Caveman full)..."

COMPRESSION_CODE=$(http PUT "$BASE_URL/api/settings/compression" \
  "$RESP_DIR/compression.json" \
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
log "Compression PUT HTTP $COMPRESSION_CODE"
[ "$COMPRESSION_CODE" != "200" ] && [ "$COMPRESSION_CODE" != "204" ] && \
  warn "compression PUT non-2xx: $(head -c 400 "$RESP_DIR/compression.json")"

# ─── 8. Resilience 配置 ──────────────────────────────────────────────────────
# 锚定：RESILIENCE_GUIDE.md 默认值表格 + openapi.yaml PATCH /api/resilience
# 注意：resilience 的具体 JSON 字段名未在 openapi 中暴露（type: object）
# 先 GET 当前配置，打印字段名供调试；再 PATCH
log "Fetching current resilience config (for field name verification)..."
curl -s -b "$COOKIE_FILE" "$BASE_URL/api/resilience" \
  -o "$RESP_DIR/resilience_current.json" 2>/dev/null
log "Current resilience keys: $(jq -r 'keys | @csv' "$RESP_DIR/resilience_current.json" 2>/dev/null || echo 'parse-error')"

RESIL_CODE=$(http PATCH "$BASE_URL/api/resilience" "$RESP_DIR/resilience.json" \
  -H "Content-Type: application/json" \
  -d '{
    "queueSize": 30,
    "pacingMs": 250,
    "maxConcurrent": 3,
    "waitForCooldown": true,
    "circuitBreaker": {
      "failureThreshold": 5,
      "cooldownMs": 30000,
      "halfOpenProbeIntervalMs": 60000
    },
    "connectionCooldown": {
      "baseMs": 1000,
      "maxMs": 60000,
      "respectRetryAfter": true
    }
  }')
log "Resilience PATCH HTTP $RESIL_CODE"

# ─── 9. 重置 circuit breakers（确保所有 connection 从干净状态启动）────────────
# 锚定：openapi.yaml POST /api/resilience/reset → 无 body
log "Resetting circuit breakers..."
CB_CODE=$(http POST "$BASE_URL/api/resilience/reset" "$RESP_DIR/cb_reset.json")
log "CB reset HTTP $CB_CODE"

# ─── 10. 烟雾测试：compression preview ──────────────────────────────────────
# 锚定：openapi.yaml /api/compression/preview → required: [messages, mode]
# v3.7.9 fix(auth): require dashboard management auth for compression preview
# → 必须用 -b $COOKIE_FILE（ManagementSessionAuth cookie），不能只用 Bearer
log "Smoke test: compression preview (requires management cookie)..."
PREVIEW_CODE=$(http POST "$BASE_URL/api/compression/preview" \
  "$RESP_DIR/preview.json" \
  -H "Content-Type: application/json" \
  -d '{
    "mode": "stacked",
    "messages": [
      {
        "role": "user",
        "content": "Please basically I think we should obviously just run the test, you know what I mean, like it should be pretty straightforward."
      },
      {
        "role": "tool",
        "content": "FAIL tests/e2e/login.spec.ts:42:18\n  AssertionError: expected element to be visible\n    at Context.<anonymous> (/app/tests/e2e/login.spec.ts:42:18)\n    at processTicksAndRejections (node:internal/process/task_queues:95:5)\n  npm ERR! Test failed. See above.\n  npm ERR! A complete log of this run can be found in:\n  npm ERR!     /root/.npm/_logs/2026-05-08T12_00_00_000Z-debug-0.log"
      }
    ]
  }')
SAVINGS=$(jq -r '
  .stats.savingsPercent //
  .savingsPercent //
  (.stats | if type=="object" then .savingsPercent else null end) //
  "n/a"
' "$RESP_DIR/preview.json" 2>/dev/null || echo "parse-error")
log "Compression preview HTTP $PREVIEW_CODE — savings=$SAVINGS%"
if [ "$PREVIEW_CODE" != "200" ]; then
  warn "Preview non-200, response: $(head -c 500 "$RESP_DIR/preview.json")"
  warn "If 401/403: cookie may have expired — this is non-fatal, compression is still configured"
fi

# ─── 11. 最终验证：GET 回读压缩配置确认持久化 ────────────────────────────────
log "Verifying compression config persisted..."
VERIFY_CODE=$(http GET "$BASE_URL/api/settings/compression" \
  "$RESP_DIR/compression_verify.json")
ACTUAL_MODE=$(jq -r '.defaultMode // "unknown"' "$RESP_DIR/compression_verify.json" 2>/dev/null)
ACTUAL_RTK=$(jq -r '.rtkConfig.intensity // "unknown"' "$RESP_DIR/compression_verify.json" 2>/dev/null)
ACTUAL_CAV=$(jq -r '.cavemanConfig.intensity // "unknown"' "$RESP_DIR/compression_verify.json" 2>/dev/null)
log "Verified: mode=$ACTUAL_MODE rtk=$ACTUAL_RTK caveman=$ACTUAL_CAV"
[ "$ACTUAL_MODE" != "stacked" ] && warn "defaultMode is '$ACTUAL_MODE', expected 'stacked' — check compression PUT response"

# ─── 12. 写入完成标记 ────────────────────────────────────────────────────────
date -Iseconds > "$INIT_MARKER"
log "✅ Done v1.9.0 (OmniRoute v3.7.9) at $(cat "$INIT_MARKER")"
log ""
log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
log "  Endpoint : $BASE_URL/v1"
log "  API Key  : $(cat "$OR_KEY_FILE")"
log "  Combo    : nim-pool  (model: $OMNIROUTE_COMBO_MODEL)"
log "  Compress : stacked [RTK aggressive → Caveman full]"
log "  Target   : ~89% token savings on tool-heavy Claude Code sessions"
log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
