#!/bin/bash
set -eo pipefail

# ─────────────────────────────────────────────────────────────
# NIM OmniRoute initializer
# v3.8.0
# 修复历史（节选）：
#   v3.4.0  统一 SSOT；override 覆盖 pool∪codex∪extra；Memory static
#   v3.6.0  purge 重写为注册表模型 + 环境自检（20129 是 API_PORT/LIVE_WS_PORT，非代理）
#   v3.7.0  context-relay 查证；变量名对齐（NIM_REQUEST_BODY_LIMIT / CONTEXT_LENGTH_DEFAULT）；nim-codex 改 round-robin
#   v3.8.0  【本次·回归修复 + 根因收紧】
#     【修复G·关键】NIM_REQUEST_BODY_LIMIT 若为字节值（>500）自动换算为 MB 并 clamp[1,500]，
#                  根治 v3.7.0 引入的 Settings HTTP 400（524288 被当 524288MB 超出 schema 上限）。
#                  400 会连带 fallbackStrategy/requestRetry/maxRetryIntervalSec 全部失效 → cq3n 502 风暴。
#     【修复F·强化】DEGRADED 根因 = provider_connections.proxy_enabled DEFAULT 1（core.ts:228），
#                  注册 key 时代理自动启用 → 请求走 proxy_registry → 20129 无服务 → ECONNREFUSED
#                  → 部分 function（cg52）无 direct fallback → DEGRADED。
#                  purge_proxy_db 中 UPDATE ...SET proxy_enabled=0 并加回读校验，注册后必覆盖。
#     【修复H】还原 .txt 转换丢失的 CRLF/换行转义（tr -d '\r'、printf '%s\n'）。
#     【说明】proxy_enabled（连接级，DEFAULT 1）≠ per_key_proxy_enabled（DEFAULT 0），勿混淆。
# ─────────────────────────────────────────────────────────────

# ── 防未来版本漂移：强制关闭代理生态（防御层，非根因修复）──────
export ONEPROXY_ENABLED=false
export ENABLE_SOCKS5_PROXY=false
export NEXT_PUBLIC_ENABLE_SOCKS5_PROXY=false
export NO_PROXY="127.0.0.1,localhost,integrate.api.nvidia.com"
unset HTTP_PROXY HTTPS_PROXY ALL_PROXY http_proxy https_proxy all_proxy 2>/dev/null || true
unset OMNIROUTE_RELAY_BACKEND BIFROST_BASE_URL 2>/dev/null || true

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
# 模型 SSOT
# ═════════════════════════════════════════════════════════════
NIM_POOL_MODELS=(
  "minimaxai/minimax-m2.7"
  "moonshotai/kimi-k2.6"
  "z-ai/glm-5.2"
  "nvidia/nemotron-3-super-120b-a12b"
  "qwen/qwen3-next-80b-a3b-instruct"
  "mistralai/mistral-small-4-119b-2603"
  "mistralai/mistral-medium-3.5-128b"
  "meta/llama-3.2-90b-vision-instruct"
  "openai/gpt-oss-120b"
  "nvidia/nemotron-3-ultra-550b-a55b"
  "mistralai/mistral-large-3-675b-instruct-2512"
)
NIM_CODEX_MODELS=(
  "openai/gpt-oss-120b"
  "qwen/qwen3-next-80b-a3b-instruct"
  "deepseek-ai/deepseek-v4-pro"
  "mistralai/mistral-medium-3.5-128b"
)
NIM_EXTRA_MODELS=(
  "deepseek-ai/deepseek-v4-pro"
  "deepseek-ai/deepseek-v4-flash"
)

build_all_models() {
  printf '%s\n' "${NIM_POOL_MODELS[@]}" "${NIM_CODEX_MODELS[@]}" "${NIM_EXTRA_MODELS[@]}" | awk '!seen[$0]++'
}
models_to_json() { printf '%s\n' "$@" | jq -R . | jq -s -c .; }

# ── 动态参数（★已对齐 HF 面板实际变量名）────────────────────────
_RPM=${NIM_RPM:-28}
_CONCURRENT=${NIM_CONCURRENT:-5}
_MIN_INTERVAL_MS=${NIM_MIN_INTERVAL_MS:-500}
_COMPRESS_THRESHOLD=${NIM_COMPRESS_THRESHOLD:-12000}
_FALLBACK_STRATEGY="round-robin"
_STICKY_LIMIT=1
_COMPRESS_MODE="stacked"
_THINKING_MODE="adaptive"
_THINKING_BUDGET=8000
_NIM_REAL_CONTEXT=${CONTEXT_LENGTH_DEFAULT:-32768}           # 修复D：读 CONTEXT_LENGTH_DEFAULT
_CODEX_STRATEGY=${NIM_CODEX_STRATEGY:-round-robin}           # 修复E：默认 round-robin

# ── 修复G：请求体上限单位归一（字节→MB，clamp[1,500]）──────────
# HF Secret 常填字节（如 524288=512KB）；maxBodySizeMb 单位是 MB，schema 范围 [1,500]。
# 规则：>500 视为字节，除以 1048576 转 MB；<1 归 1；否则原样（视为已是 MB）。
_RAW_BODY_LIMIT=${NIM_REQUEST_BODY_LIMIT:-1}
if [ "$_RAW_BODY_LIMIT" -gt 500 ] 2>/dev/null; then
  _REQUEST_BODY_LIMIT_MB=$(( _RAW_BODY_LIMIT / 1048576 ))
  [ "$_REQUEST_BODY_LIMIT_MB" -lt 1 ] && _REQUEST_BODY_LIMIT_MB=1
elif [ "$_RAW_BODY_LIMIT" -lt 1 ] 2>/dev/null; then
  _REQUEST_BODY_LIMIT_MB=1
else
  _REQUEST_BODY_LIMIT_MB=$_RAW_BODY_LIMIT
fi
# 最终再兜底 clamp 上限
[ "$_REQUEST_BODY_LIMIT_MB" -gt 500 ] 2>/dev/null && _REQUEST_BODY_LIMIT_MB=500
echo "[init] body limit: raw=$_RAW_BODY_LIMIT -> maxBodySizeMb=$_REQUEST_BODY_LIMIT_MB (clamp [1,500])"

_PURGE_PROXY=${NIM_PURGE_PROXY:-1}
_PROXY_RELAY_HOST=${NIM_PROXY_RELAY_HOST:-127.0.0.1}
_PROXY_RELAY_PORT=${NIM_PROXY_RELAY_PORT:-20129}

_DB_PATH="${DATA_DIR:-/data}/storage.sqlite"
sql_escape() { printf '%s' "$1" | sed "s/'/''/g"; }

# ── 环境自检 ──────────────────────────────────────────────────
check_dangerous_env() {
  echo "[init] check_dangerous_env: scanning relay/proxy env..."
  local _hit=0
  for v in OMNIROUTE_RELAY_BACKEND BIFROST_BASE_URL HTTP_PROXY HTTPS_PROXY ALL_PROXY http_proxy https_proxy all_proxy; do
    if [ -n "${!v}" ]; then echo "[init] ⚠️ DANGER: env $v=${!v} 已设置，建议删除。"; _hit=1; fi
  done
  [ "$_hit" = "0" ] && echo "[init] check_dangerous_env: clean。"
}

# ── purge：注册表清理 + 【修复F】proxy_enabled 根因修复（幂等）──
purge_proxy_db() {
  [ "$_PURGE_PROXY" != "1" ] && { echo "[init] purge_proxy_db: skipped."; return 0; }
  local LIST_JSON
  LIST_JSON=$(curl -s -b "$COOKIE_FILE" "$BASE_URL/api/v1/management/proxies" 2>/dev/null || echo "")
  if [ -n "$LIST_JSON" ] && printf '%s' "$LIST_JSON" | jq -e . >/dev/null 2>&1; then
    local BAD_IDS
    BAD_IDS=$(printf '%s' "$LIST_JSON" | jq -r --arg h "$_PROXY_RELAY_HOST" --argjson p "$_PROXY_RELAY_PORT" \
      '(.proxies // .data // .) | (if type=="array" then . else [] end)
       | .[] | select((.host==$h) and ((.port|tonumber?)==$p)) | .id' 2>/dev/null)
    if [ -n "$BAD_IDS" ]; then
      local _id _c
      while IFS= read -r _id; do
        [ -z "$_id" ] && continue
        _c=$(curl -s -o /dev/null -w "%{http_code}" -b "$COOKIE_FILE" \
          -X DELETE "$BASE_URL/api/v1/management/proxies?id=${_id}&force=1" 2>/dev/null || echo "000")
        echo "[init] purge: API force-delete $_id -> HTTP $_c"
      done <<< "$BAD_IDS"
    else
      echo "[init] purge: 注册表无 ${_PROXY_RELAY_HOST}:${_PROXY_RELAY_PORT}（新库预期为空）。"
    fi
  else
    echo "[init] purge: 管理 API 暂不可用，走 SQL 兜底。"
  fi
  if [ -f "$_DB_PATH" ]; then
    sqlite3 "$_DB_PATH" "DELETE FROM proxy_assignments WHERE proxy_id IN
      (SELECT id FROM proxy_registry WHERE host='$(sql_escape "$_PROXY_RELAY_HOST")' AND port=$_PROXY_RELAY_PORT);" 2>/dev/null || true
    # 【修复F·根因】关闭连接级 proxy_enabled（core.ts:228 DEFAULT 1，注册即启用代理）
    # 注意：是 proxy_enabled，不是 per_key_proxy_enabled（后者 DEFAULT 0，本就关闭）。
    sqlite3 "$_DB_PATH" "UPDATE provider_connections SET proxy_enabled=0 WHERE provider='nvidia';" 2>/dev/null || true
    sqlite3 "$_DB_PATH" "DELETE FROM proxy_registry WHERE host='$(sql_escape "$_PROXY_RELAY_HOST")' AND port=$_PROXY_RELAY_PORT;" 2>/dev/null || true
    local _reg _asg _proxy_on
    _reg=$(sqlite3 "$_DB_PATH" "SELECT COUNT(*) FROM proxy_registry;" 2>/dev/null || echo "?")
    _asg=$(sqlite3 "$_DB_PATH" "SELECT COUNT(*) FROM proxy_assignments;" 2>/dev/null || echo "?")
    _proxy_on=$(sqlite3 "$_DB_PATH" "SELECT COUNT(*) FROM provider_connections WHERE provider='nvidia' AND proxy_enabled=1;" 2>/dev/null || echo "?")
    echo "[init] purge: SQL 后 registry=$_reg assignments=$_asg（新库预期 0/0）。"
    echo "[init] purge: nvidia proxy_enabled=1 剩余 $_proxy_on 个（期望 0）。"
  fi
}

echo "[init] Starting NIM OmniRoute initializer v3.8.0..."
echo "[init] BASE_URL=$BASE_URL"
check_dangerous_env

[ -z "$INITIAL_PASSWORD" ] && { echo "[init] ERROR: INITIAL_PASSWORD required"; exit 1; }
[ -z "$NIM_KEYS" ] && { echo "[init] ERROR: NIM_KEYS required"; exit 1; }

echo "[init] Waiting for OmniRoute..."
HWAIT=0
until curl -sf "$BASE_URL/api/monitoring/health" > /dev/null 2>&1; do
  sleep 3; HWAIT=$((HWAIT + 3))
  [ "$HWAIT" -ge 180 ] && { echo "[init] FATAL: not ready within 180s"; exit 1; }
done
echo "[init] OmniRoute up (after ${HWAIT}s)."

VERSION_HTTP=$(curl -s -o "$VERSION_FILE" -w "%{http_code}" "$BASE_URL/api/monitoring/health" 2>/dev/null || echo "000")
[ "$VERSION_HTTP" = "200" ] && echo "[init] version: $(jq -r '.version // "unknown"' "$VERSION_FILE" 2>/dev/null)"

echo "[init] Logging in..."
LOGIN_BODY=$(jq -n --arg password "$INITIAL_PASSWORD" '{password: $password}')
LOGIN_HTTP=$(curl -s -o "$LOGIN_RESP_FILE" -w "%{http_code}" -c "$COOKIE_FILE" \
  -X POST "$BASE_URL/api/auth/login" -H "Content-Type: application/json" -d "$LOGIN_BODY")
[ "$LOGIN_HTTP" != "200" ] && [ "$LOGIN_HTTP" != "201" ] && { echo "[init] ERROR login HTTP $LOGIN_HTTP"; cat "$LOGIN_RESP_FILE" || true; exit 1; }
grep -q "auth_token" "$COOKIE_FILE" 2>/dev/null || { echo "[init] ERROR no auth_token"; exit 1; }
echo "[init] Logged in."

purge_proxy_db

resolve_or_key() {
  printf '%s' "${OMNIROUTE_API_KEY:-$(cat "$OR_API_KEY_FILE" 2>/dev/null)}" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//'
}

if [ -n "$OMNIROUTE_API_KEY" ]; then
  OR_KEY="$(printf '%s' "$OMNIROUTE_API_KEY" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
  [ -z "$OR_KEY" ] && { echo "[init] FATAL: OMNIROUTE_API_KEY blank"; exit 1; }
  echo "$OR_KEY" > "$OR_API_KEY_FILE" 2>/dev/null || echo "[init] WARN write $OR_API_KEY_FILE failed"
  chmod 600 "$OR_API_KEY_FILE" 2>/dev/null || true
  echo "[init] OMNIROUTE_API_KEY env set, skip /api/keys."
elif [ -f "$OR_API_KEY_FILE" ] && [ -s "$OR_API_KEY_FILE" ]; then
  OR_KEY="$(cat "$OR_API_KEY_FILE" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
  echo "[init] OR_API_KEY file exists."
else
  echo "[init] Creating OmniRoute API Key..."
  KEY_BODY=$(jq -n --arg name "gate-internal" '{name: $name, expiresAt: null}')
  KEY_HTTP=$(curl -s -o "$KEY_RESP_FILE" -w "%{http_code}" -b "$COOKIE_FILE" \
    -X POST "$BASE_URL/api/keys" -H "Content-Type: application/json" -d "$KEY_BODY")
  if [ "$KEY_HTTP" = "200" ] || [ "$KEY_HTTP" = "201" ]; then
    OR_API_KEY_VALUE=$(jq -r '.key // empty' "$KEY_RESP_FILE")
    [ -z "$OR_API_KEY_VALUE" ] && { echo "[init] ERROR parse key"; exit 1; }
    echo "$OR_API_KEY_VALUE" > "$OR_API_KEY_FILE"; chmod 600 "$OR_API_KEY_FILE"; OR_KEY="$OR_API_KEY_VALUE"
    echo "[init] OR_API_KEY written."
  else
    echo "[init] ERROR /api/keys HTTP $KEY_HTTP"; exit 1
  fi
fi

echo "[init] Registering NIM keys..."
INDEX=1
while IFS= read -r RAW_KEY; do
  KEY=$(printf '%s' "$RAW_KEY" | tr -d '\r' | xargs)
  [ -z "$KEY" ] && continue
  NAME=$(printf "nim-%02d" "$INDEX")
  RESP_FILE="/tmp/omniroute-provider-$INDEX.json"
  BODY=$(jq -n --arg provider "nvidia" --arg apiKey "$KEY" --arg name "$NAME" \
    '{provider:$provider, apiKey:$apiKey, name:$name, priority:1, testStatus:"unknown"}')
  HTTP_CODE=$(curl -s -o "$RESP_FILE" -w "%{http_code}" -b "$COOKIE_FILE" \
    -X POST "$BASE_URL/api/providers" -H "Content-Type: application/json" -d "$BODY")
  if [ "$HTTP_CODE" = "201" ] || [ "$HTTP_CODE" = "200" ]; then echo "[init] $NAME OK"; REGISTERED=$((REGISTERED+1))
  elif [ "$HTTP_CODE" = "409" ]; then echo "[init] $NAME exists"; SKIPPED=$((SKIPPED+1))
  else echo "[init] $NAME HTTP $HTTP_CODE"; cat "$RESP_FILE" || true; FAILED=$((FAILED+1)); fi
  INDEX=$((INDEX+1))
done <<< "$NIM_KEYS"
echo "[init] Keys: $REGISTERED registered, $SKIPPED skipped, $FAILED failed."

echo "[init] Fetching provider IDs..."
PROVIDERS_HTTP=$(curl -s -o "$PROVIDERS_FILE" -w "%{http_code}" -b "$COOKIE_FILE" "$BASE_URL/api/providers")
if [ "$PROVIDERS_HTTP" = "200" ]; then
  mapfile -t PROVIDER_IDS < <(jq -r '[.. | objects | select((.provider? // "")=="nvidia") | select((.id? // "")!="") | .id] | unique | .[]' "$PROVIDERS_FILE" 2>/dev/null)
fi
echo "[init] Provider IDs: ${#PROVIDER_IDS[@]}"

# 注册完成后再次 purge —— 此处 UPDATE proxy_enabled=0 必然覆盖已注册的 nvidia 连接（根因修复关键点）
purge_proxy_db

echo "[init] Resilience (RPM=$_RPM)..."
RESILIENCE_CODE=$(curl -s -o "$RESILIENCE_RESP_FILE" -w "%{http_code}" -b "$COOKIE_FILE" \
  -X PATCH "$BASE_URL/api/resilience" -H "Content-Type: application/json" \
  -d "{\"requestQueue\":{\"requestsPerMinute\":$_RPM,\"minTimeBetweenRequestsMs\":$_MIN_INTERVAL_MS,\"concurrentRequests\":$_CONCURRENT}}")
echo "[init] Resilience HTTP $RESILIENCE_CODE"

echo "[init] Routing + maxBodySizeMb=$_REQUEST_BODY_LIMIT_MB..."
SETTINGS_CODE=$(curl -s -o "$SETTINGS_RESP_FILE" -w "%{http_code}" -b "$COOKIE_FILE" \
  -X PATCH "$BASE_URL/api/settings" -H "Content-Type: application/json" \
  -d "{\"fallbackStrategy\":\"$_FALLBACK_STRATEGY\",\"stickyRoundRobinLimit\":$_STICKY_LIMIT,\"requestRetry\":2,\"maxRetryIntervalSec\":5,\"maxBodySizeMb\":$_REQUEST_BODY_LIMIT_MB}")
echo "[init] Settings HTTP $SETTINGS_CODE"
[ "$SETTINGS_CODE" != "200" ] && [ "$SETTINGS_CODE" != "201" ] && { echo "[init] ⚠️ Settings 非 2xx，检查 maxBodySizeMb($_REQUEST_BODY_LIMIT_MB) 是否在 [1,500]："; cat "$SETTINGS_RESP_FILE" || true; }

echo "[init] Compression (threshold=$_COMPRESS_THRESHOLD)..."
COMPRESS_CODE=$(curl -s -o "$COMPRESS_RESP_FILE" -w "%{http_code}" -b "$COOKIE_FILE" \
  -X PUT "$BASE_URL/api/settings/compression" -H "Content-Type: application/json" \
  -d "{\"enabled\":true,\"defaultMode\":\"$_COMPRESS_MODE\",\"autoTriggerTokens\":$_COMPRESS_THRESHOLD}")
echo "[init] Compression HTTP $COMPRESS_CODE"

echo "[init] Thinking budget..."
THINKING_CODE=$(curl -s -o "$THINKING_RESP_FILE" -w "%{http_code}" -b "$COOKIE_FILE" \
  -X PUT "$BASE_URL/api/settings/thinking-budget" -H "Content-Type: application/json" \
  -d "{\"mode\":\"$_THINKING_MODE\",\"baseBudget\":$_THINKING_BUDGET}")
echo "[init] Thinking HTTP $THINKING_CODE"

echo "[init] Memory legacy + Skills..."
MEMORY_LEGACY_CODE=$(curl -s -o "$MEMORY_LEGACY_RESP_FILE" -w "%{http_code}" -b "$COOKIE_FILE" \
  -X PATCH "$BASE_URL/api/settings" -H "Content-Type: application/json" \
  -d '{"memoryEnabled":true,"memoryStrategy":"hybrid","memoryMaxTokens":2000,"memoryRetentionDays":30,"skillsEnabled":true}')
echo "[init] Memory legacy HTTP $MEMORY_LEGACY_CODE"

echo "[init] Memory extended (static)..."
MEMORY_EXT_CODE=$(curl -s -o "$MEMORY_EXT_RESP_FILE" -w "%{http_code}" -b "$COOKIE_FILE" \
  -X PUT "$BASE_URL/api/settings/memory" -H "Content-Type: application/json" \
  -d '{"embeddingSource":"static","staticEnabled":true,"transformersEnabled":false}')
echo "[init] Memory extended HTTP $MEMORY_EXT_CODE"

echo "[init] Resetting circuit breakers..."
CB_RESET_CODE=$(curl -s -o /dev/null -w "%{http_code}" -b "$COOKIE_FILE" \
  -X POST "$BASE_URL/api/resilience/reset" -H "Content-Type: application/json")
echo "[init] CB reset HTTP $CB_RESET_CODE"
# 卫生措施：清空熔断表，防止合法 DEGRADED 状态跨重建存活（非 DEGRADED 根因修复）
sqlite3 "$_DB_PATH" "DELETE FROM domain_circuit_breakers;" 2>/dev/null || true

echo "[init] per-model 32K override (real_context=$_NIM_REAL_CONTEXT)..."
OVERRIDE_APPLIED=0; OVERRIDE_SKIPPED=0
apply_context_override() {
  if sqlite3 "$_DB_PATH" \
    "INSERT OR REPLACE INTO model_context_overrides (provider, model_id, real_context, source, refreshed_at)
     VALUES ('nvidia', '$(sql_escape "$1")', $2, 'manual', datetime('now'));" 2>/dev/null; then
    OVERRIDE_APPLIED=$((OVERRIDE_APPLIED+1))
  else
    OVERRIDE_SKIPPED=$((OVERRIDE_SKIPPED+1)); echo "[init]   override FAILED: $1"
  fi
}
while IFS= read -r _M; do [ -z "$_M" ] && continue; apply_context_override "$_M" "$_NIM_REAL_CONTEXT"; done < <(build_all_models)
echo "[init] override: $OVERRIDE_APPLIED applied, $OVERRIDE_SKIPPED failed."
echo "[init] Verify: $(sqlite3 "$_DB_PATH" "SELECT COUNT(*) FROM model_context_overrides WHERE provider='nvidia' AND source='manual';" 2>/dev/null || echo 0) overrides."

echo "[init] ─────────────────────────────────────────────"
echo "[init]   RPM=$_RPM  BODY_LIMIT=$_REQUEST_BODY_LIMIT_MB MB  COMPRESS@$_COMPRESS_THRESHOLD"
echo "[init]   REAL_CONTEXT=$_NIM_REAL_CONTEXT (from CONTEXT_LENGTH_DEFAULT)"
echo "[init]   CODEX_STRATEGY=$_CODEX_STRATEGY  PURGE_PROXY=$_PURGE_PROXY"
echo "[init] ─────────────────────────────────────────────"

check_nim_model_health() {
  echo "[init] check_nim_model_health..."
  > /tmp/nim-deprecated.txt
  local _first_key _models_json _model_count
  _first_key=$(printf '%s\n' "$NIM_KEYS" | head -n1)
  _models_json=$(curl -s --max-time 10 -H "Authorization: Bearer ${_first_key}" \
    "https://integrate.api.nvidia.com/v1/models" 2>/dev/null || echo "")
  _model_count=$(printf '%s' "$_models_json" | jq -r '.data[]?.id' 2>/dev/null | wc -l)
  [ "${_model_count:-0}" -lt 5 ] && { echo "[init] only $_model_count models, skip"; return 0; }
  while IFS= read -r model; do
    [ -z "$model" ] && continue
    if ! printf '%s' "$_models_json" | jq -e --arg m "$model" 'any(.data[]?.id == $m; .)' >/dev/null 2>&1; then
      echo "[init]   $model — DEPRECATED"; echo "$model" >> /tmp/nim-deprecated.txt
    else echo "[init]   $model — available"; fi
  done < <(build_all_models)
  echo "[init] $(wc -l < /tmp/nim-deprecated.txt 2>/dev/null || echo 0) deprecated, $_model_count available"
}

hf_snapshot() {
  [ -z "$HF_TOKEN" ] || [ -z "$HF_DATASET_REPO" ] && return 0
  echo "[init] HF Dataset snapshot..."
  local BACKUP_DIR="/tmp/omni-snapshot"; mkdir -p "$BACKUP_DIR"
  local OR_KEY; OR_KEY="$(resolve_or_key)"
  curl -sf "$BASE_URL/api/settings/export-json" -H "Authorization: Bearer $OR_KEY" \
    | jq 'del(.usageHistory, .domainCostHistory, .domainBudgets) |
          (if (.apiKeys|type)=="array" then .apiKeys |= map(del(.key)) else . end) |
          (if (.providerConnections|type)=="array" then .providerConnections |= map(del(.credentials)) else . end)' \
    > "$BACKUP_DIR/omni_config.json"
  jq '.apiKeys'             "$BACKUP_DIR/omni_config.json" > "$BACKUP_DIR/keys.json"
  jq '.providerConnections' "$BACKUP_DIR/omni_config.json" > "$BACKUP_DIR/providerConnections.json"
  jq '.settings'            "$BACKUP_DIR/omni_config.json" > "$BACKUP_DIR/settings.json"
  jq '.combos'              "$BACKUP_DIR/omni_config.json" > "$BACKUP_DIR/combos.json"
  python3 - <<'PYEOF'
import os
from datetime import datetime, timezone
from huggingface_hub import HfApi
api = HfApi(token=os.environ["HF_TOKEN"])
api.upload_folder(folder_path="/tmp/omni-snapshot", path_in_repo="omni_data",
    repo_id=os.environ["HF_DATASET_REPO"], repo_type="dataset",
    commit_message=f"Sync omni_data - {datetime.now(timezone.utc).isoformat()}")
print("[init] HF Dataset uploaded.")
PYEOF
}

repair_combo() {
  local COMBO_NAME="$1"; shift; local STRAT="$1"; shift; local ALL_MODELS=("$@")
  local COMBOS_JSON CID
  COMBOS_JSON=$(curl -s -b "$COOKIE_FILE" "$BASE_URL/api/combos" || true)
  CID=$(printf '%s' "$COMBOS_JSON" | jq -r --arg n "$COMBO_NAME" '.combos[]? // .[]? | select(.name==$n) | .id' | head -n1)
  [ -z "$CID" ] && { echo "[init] Incremental: $COMBO_NAME not found."; return 0; }
  local KEEP=() m
  for m in "${ALL_MODELS[@]}"; do grep -Fxq "$m" /tmp/nim-deprecated.txt 2>/dev/null || KEEP+=("$m"); done
  [ "${#KEEP[@]}" -eq 0 ] && { echo "[init] WARN: $COMBO_NAME all deprecated."; return 0; }
  local PUT_BODY PUT_CODE
  PUT_BODY=$(jq -n --arg name "$COMBO_NAME" --arg strat "$STRAT" --argjson models "$(models_to_json "${KEEP[@]}")" \
    '{name:$name, strategy:$strat, models:$models}')
  PUT_CODE=$(curl -s -o /dev/null -w "%{http_code}" -b "$COOKIE_FILE" -X PUT "$BASE_URL/api/combos/$CID" \
    -H "Content-Type: application/json" -d "$PUT_BODY" || true)
  echo "[init] Incremental: PUT combos/$CID ($COMBO_NAME) HTTP $PUT_CODE"
}

if [ -f "$_DB_PATH" ]; then
  COMBO_COUNT=$(sqlite3 "$_DB_PATH" "SELECT COUNT(*) FROM combos WHERE name='$(sql_escape "nim-pool")';" 2>/dev/null || echo 0)
  if [ "${COMBO_COUNT:-0}" -gt 0 ]; then
    echo "[init] Incremental mode."
    purge_proxy_db
    sqlite3 "$_DB_PATH" "DELETE FROM domain_circuit_breakers;" 2>/dev/null || true
    check_nim_model_health
    if [ -s /tmp/nim-deprecated.txt ]; then
      repair_combo "nim-pool"  "round-robin"      "${NIM_POOL_MODELS[@]}"
      repair_combo "nim-codex" "$_CODEX_STRATEGY" "${NIM_CODEX_MODELS[@]}"
    else echo "[init] Incremental: no deprecated."; fi
    hf_snapshot
    echo "[init] Done (incremental). v3.8.0"
    exit 0
  fi
else
  echo "[init] DB not present. First-time init."
fi

echo "[init] Registering models..."
register_model() {
  local MODEL_ID="$1" F="/tmp/omniroute-model-$(echo "$1" | tr '/' '-').json" C
  C=$(curl -s -o "$F" -w "%{http_code}" -b "$COOKIE_FILE" -X POST "$BASE_URL/api/provider-models" \
    -H "Content-Type: application/json" -d "$(jq -n --arg provider "nvidia" --arg modelId "$MODEL_ID" '{provider:$provider, modelId:$modelId}')")
  if [ "$C" = "200" ] || [ "$C" = "201" ]; then echo "[init] model $MODEL_ID OK"
  elif [ "$C" = "409" ]; then echo "[init] model $MODEL_ID exists"
  else echo "[init] model $MODEL_ID WARN $C"; cat "$F" || true; fi
}
while IFS= read -r _M; do [ -z "$_M" ] && continue; register_model "$_M"; done < <(build_all_models)
echo "[init] Model registration done."

echo "[init] Creating nim-pool (round-robin)..."
COMBO_CODE=$(curl -s -o "$COMBO_RESP_FILE" -w "%{http_code}" -b "$COOKIE_FILE" -X POST "$BASE_URL/api/combos" \
  -H "Content-Type: application/json" -d "$(jq -n --argjson models "$(models_to_json "${NIM_POOL_MODELS[@]}")" '{name:"nim-pool", strategy:"round-robin", models:$models}')")
echo "[init] nim-pool HTTP $COMBO_CODE"

echo "[init] Creating nim-codex ($_CODEX_STRATEGY)..."
CODEX_COMBO_RESP_FILE="/tmp/omniroute-codex-combo-response.json"
CODEX_COMBO_CODE=$(curl -s -o "$CODEX_COMBO_RESP_FILE" -w "%{http_code}" -b "$COOKIE_FILE" -X POST "$BASE_URL/api/combos" \
  -H "Content-Type: application/json" -d "$(jq -n --arg strat "$_CODEX_STRATEGY" --argjson models "$(models_to_json "${NIM_CODEX_MODELS[@]}")" '{name:"nim-codex", strategy:$strat, models:$models}')")
echo "[init] nim-codex HTTP $CODEX_COMBO_CODE"

hf_snapshot
purge_proxy_db

touch "$INIT_MARKER"
echo "[init] Final health check..."
HEALTH_FILE="/tmp/omniroute-final-health.json"
HEALTH_HTTP=$(curl -s -o "$HEALTH_FILE" -w "%{http_code}" "$BASE_URL/api/monitoring/health" 2>/dev/null || echo "000")
[ "$HEALTH_HTTP" = "200" ] && echo "[init]   Status: $(jq -r '.status // "unknown"' "$HEALTH_FILE" 2>/dev/null) / $(jq -r '.version // "unknown"' "$HEALTH_FILE" 2>/dev/null)"
echo "[init] Done (first-init). v3.8.0"
