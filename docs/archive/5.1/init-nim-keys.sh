# === ARCHIVED init-nim-keys.sh ===
# 来源版本: 5.1 旁支(删函数致combo不建)
# 生成日期: 2026-07-16 (mtime)
# 状态: DEPRECATED — 永久禁止作为任何新生成的起点, 仅作指纹比对素材
# === END META ===

#!/bin/bash
# ── OmniRoute 3.8.43 · NIM 初始化脚本 v5.1（完整无占位）─────────────
# 相对 v5.0 的修正（全部经生产日志实证）：
#   [E1] Compression: /api/compression → /api/settings/compression，GET→合并→PUT（不注入未知键）
#   [E2] Thinking:    /api/thinking-budget → /api/settings/thinking-budget，同上
#   [E3] CB reset:    /api/circuit-breakers/reset → /api/resilience/reset
#   [E4] Memory:      移除 405/400 的 PATCH/PUT，改为 GET /api/memory/health 探测
#   [E5] 限流默认:    28/1/2200ms → 28/6/0ms（多工具突发不再被间隔 pacing 掐断）
#   [E6] jq 类型安全: 模型目录结构归一化，修 "Cannot index array with string"
# 保留 v5.0 全部能力：模型三档 SSOT / 4 combo upsert / nim_probe / context override / HF 快照

set -eo pipefail

# ════════════════════════════════════════════════════════════════
# §0 单变量调试 + 日志归档
# ════════════════════════════════════════════════════════════════
NIM_MODE="${NIM_MODE:-NORMAL}"
LOG_DIR="/data/omni-data/log"
if [ "$NIM_MODE" = "DEBUG" ]; then
  mkdir -p "$LOG_DIR" 2>/dev/null || true
  INIT_LOG="$LOG_DIR/init_$(date +%Y%m%d_%H%M%S).log"
  exec > >(tee -a "$INIT_LOG") 2>&1
  echo "[init] 🛠️ NIM_MODE=DEBUG：日志 tee -> $INIT_LOG"
  export APP_LOG_TO_FILE=true
  export DISABLE_SQLITE_AUTO_BACKUP=true
else
  LOG_DIR="/tmp"
fi
_resp() { echo "$LOG_DIR/$1"; }

echo "=============================================================="
echo "[init] OmniRoute 3.8.43 · NIM 初始化 v5.1"
echo "[init] $(date '+%Y-%m-%d %H:%M:%S')"
echo "=============================================================="

# ── §0.1 强制关闭代理生态 ──
export ONEPROXY_ENABLED=false
export ENABLE_SOCKS5_PROXY=false
export NEXT_PUBLIC_ENABLE_SOCKS5_PROXY=false
unset HTTP_PROXY HTTPS_PROXY ALL_PROXY http_proxy https_proxy all_proxy 2>/dev/null || true
unset OMNIROUTE_RELAY_BACKEND BIFROST_BASE_URL 2>/dev/null || true

# ── §0.2 端口 ──
[ -z "$OMNIROUTE_PORT" ] && OMNIROUTE_PORT=20128
BASE_URL="http://127.0.0.1:$OMNIROUTE_PORT"
OR_API_KEY_FILE="/data/.or-api-key"
COOKIE_FILE="/tmp/omniroute-cookie.txt"

LOGIN_RESP_FILE="$(_resp omniroute-login.json)"
RESILIENCE_RESP_FILE="$(_resp omniroute-resilience.json)"
SETTINGS_RESP_FILE="$(_resp omniroute-settings.json)"
COMPRESS_RESP_FILE="$(_resp omniroute-compress.json)"
THINKING_RESP_FILE="$(_resp omniroute-thinking.json)"

REGISTERED=0; SKIPPED=0; FAILED=0

# ════════════════════════════════════════════════════════════════
# §1 模型分档 SSOT（对齐现行 NVIDIA 目录）
# ════════════════════════════════════════════════════════════════
TIER_FAST=(
  "z-ai/glm-5.2"
  "deepseek-ai/deepseek-v4-flash"
  "deepseek-ai/deepseek-v4-pro"
  "meta/llama-3.3-70b-instruct"
)
TIER_STABLE=(
  "nvidia/nemotron-3-super-120b-a12b"
  "openai/gpt-oss-120b"
  "qwen/qwen3.5-397b-a17b"
  "mistralai/mistral-small-4-119b-2603"
  "google/gemma-4-31b-it"
)
TIER_RESTRICTED=(
  "moonshotai/kimi-k2.6"
  "minimaxai/minimax-m2.7"
  "mistralai/mistral-large-3-675b-instruct-2512"
)

_PROFILE="${NIM_PROFILE:-balanced}"
case "$_PROFILE" in
  fast)  NIM_POOL_MODELS=("${TIER_FAST[@]}") ;;
  full)  NIM_POOL_MODELS=("${TIER_FAST[@]}" "${TIER_STABLE[@]}" "${TIER_RESTRICTED[@]}") ;;
  *)     _PROFILE="balanced"; NIM_POOL_MODELS=("${TIER_FAST[@]}" "${TIER_STABLE[@]}") ;;
esac
echo "[init] NIM_PROFILE=$_PROFILE -> pool 意向 ${#NIM_POOL_MODELS[@]} 个模型"

NIM_CODEX_MODELS=( "deepseek-ai/deepseek-v4-pro" "openai/gpt-oss-120b" "z-ai/glm-5.2" )
NIM_FAST_MODELS=(  "deepseek-ai/deepseek-v4-flash" "meta/llama-3.3-70b-instruct" "google/gemma-4-31b-it" )
NIM_EXTRA_MODELS=( "deepseek-ai/deepseek-v4-flash" )

build_all_models() {
  printf '%s\n' "${NIM_POOL_MODELS[@]}" "${NIM_CODEX_MODELS[@]}" "${NIM_EXTRA_MODELS[@]}" | awk '!seen[$0]++'
}
models_to_json() { printf '%s\n' "$@" | sed 's/^/nvidia\//' | jq -R '{model: .}' | jq -s -c .; }

# ════════════════════════════════════════════════════════════════
# §2 combo 策略白名单（删 context-relay）
# ════════════════════════════════════════════════════════════════
_VALID_STRATS="priority weighted round-robin fill-first p2c random least-used cost-optimized reset-aware reset-window headroom strict-random auto lkgp context-optimized fusion pipeline"
_is_valid_strat() { printf '%s' "$_VALID_STRATS" | grep -qw -- "$1"; }

upsert_combo() {
  local NAME="$1" STRAT="$2"; shift 2; local MODELS=("$@")
  _is_valid_strat "$STRAT" || { echo "[init] upsert_combo: '$STRAT' 非法 -> round-robin"; STRAT="round-robin"; }
  [ "${#MODELS[@]}" -eq 0 ] && { echo "[init] upsert_combo: $NAME 无存活模型，跳过。"; return 0; }
  local BODY CID CODE F
  BODY=$(jq -n --arg name "$NAME" --arg strat "$STRAT" \
               --argjson models "$(models_to_json "${MODELS[@]}")" \
               '{name:$name, strategy:$strat, models:$models}')
  CID=$(curl -s -b "$COOKIE_FILE" "$BASE_URL/api/combos" \
        | jq -r --arg n "$NAME" '(.combos // .)[]? | select(.name==$n) | .id' 2>/dev/null | head -n1)
  F="$(_resp omniroute-combo-$NAME.json)"
  if [ -n "$CID" ]; then
    CODE=$(curl -s -o "$F" -w "%{http_code}" -b "$COOKIE_FILE" \
      -X PUT "$BASE_URL/api/combos/$CID" -H "Content-Type: application/json" -d "$BODY")
    echo "[init] upsert $NAME: existed -> PUT combos/$CID HTTP $CODE"
  else
    CODE=$(curl -s -o "$F" -w "%{http_code}" -b "$COOKIE_FILE" \
      -X POST "$BASE_URL/api/combos" -H "Content-Type: application/json" -d "$BODY")
    echo "[init] upsert $NAME: new -> POST HTTP $CODE"
  fi
  [ "$CODE" != "200" ] && [ "$CODE" != "201" ] && cat "$F" 2>/dev/null || true
}

# ════════════════════════════════════════════════════════════════
# §3 动态限流（[E5] 默认 28/6/0ms：靠 RPM 滑窗控速，允许突发）
# ════════════════════════════════════════════════════════════════
_count_alive_keys() { printf '%s\n' "$NIM_KEYS" | sed '/^[[:space:]]*$/d' | wc -l; }
_ALIVE_KEYS=$(_count_alive_keys)

_RPM=${NIM_RPM_LIMIT:-28}
_CONCURRENT=${NIM_CONCURRENT_LIMIT:-6}       # [E5] 1 → 6
_MIN_INTERVAL_MS=${NIM_MIN_INTERVAL_MS:-0}   # [E5] 2200 → 0

[ "$_CONCURRENT" -lt 1 ] && _CONCURRENT=1
[ "$_MIN_INTERVAL_MS" -lt 0 ] && _MIN_INTERVAL_MS=0
[ "$_RPM" -gt 300 ] && _RPM=300
echo "[init] alive_keys=$_ALIVE_KEYS -> RPM=$_RPM concurrent=$_CONCURRENT interval=${_MIN_INTERVAL_MS}ms"

if [ "$_ALIVE_KEYS" -gt 1 ]; then _POOL_STRATEGY="${NIM_POOL_STRATEGY:-p2c}"; else _POOL_STRATEGY="round-robin"; fi
_is_valid_strat "$_POOL_STRATEGY" || { echo "[init] WARN: pool strategy 非法，回退 round-robin"; _POOL_STRATEGY="round-robin"; }
_CODEX_STRATEGY="${NIM_CODEX_STRATEGY:-round-robin}"
_is_valid_strat "$_CODEX_STRATEGY" || { echo "[init] WARN: codex strategy 非法，回退 round-robin"; _CODEX_STRATEGY="round-robin"; }
_NIM_REAL_CONTEXT=${CONTEXT_LENGTH_DEFAULT:-128000}
echo "[init] pool strategy=$_POOL_STRATEGY | codex strategy=$_CODEX_STRATEGY"

# ── §4 body limit 归一 ──
_RAW_BODY_LIMIT=${NIM_REQUEST_BODY_LIMIT:-4}
if [ "$_RAW_BODY_LIMIT" -gt 500 ] 2>/dev/null; then
  _REQUEST_BODY_LIMIT_MB=$(( _RAW_BODY_LIMIT / 1048576 )); [ "$_REQUEST_BODY_LIMIT_MB" -lt 1 ] && _REQUEST_BODY_LIMIT_MB=1
elif [ "$_RAW_BODY_LIMIT" -lt 1 ] 2>/dev/null; then _REQUEST_BODY_LIMIT_MB=1
else _REQUEST_BODY_LIMIT_MB=$_RAW_BODY_LIMIT; fi
[ "$_REQUEST_BODY_LIMIT_MB" -gt 500 ] 2>/dev/null && _REQUEST_BODY_LIMIT_MB=500
echo "[init] body limit: raw=$_RAW_BODY_LIMIT -> maxBodySizeMb=$_REQUEST_BODY_LIMIT_MB"

_PURGE_PROXY=${NIM_PURGE_PROXY:-1}
_PROXY_RELAY_HOST=${NIM_PROXY_RELAY_HOST:-127.0.0.1}
_PROXY_RELAY_PORT=${NIM_PROXY_RELAY_PORT:-20129}
_DB_PATH="${DATA_DIR:-/data}/storage.sqlite"

# ── §5 工具函数 ──
sql_escape() { printf '%s' "$1" | sed "s/'/''/g"; }
_res_validate_int() {
  [ -z "$1" ] && return 1
  case "$1" in ''|*[!0-9-]*) return 1 ;; esac
  [ "$1" -ge "$2" ] 2>/dev/null && [ "$1" -le "$3" ] 2>/dev/null || return 1
  return 0
}
check_dangerous_env() {
  echo "[init] check_dangerous_env: scanning relay/proxy env..."
  local _hit=0
  for v in OMNIROUTE_RELAY_BACKEND BIFROST_BASE_URL HTTP_PROXY HTTPS_PROXY ALL_PROXY http_proxy https_proxy all_proxy; do
    [ -n "${!v}" ] && { echo "[init] ⚠️ DANGER: env $v=${!v} 已设置。"; _hit=1; }
  done
  [ "$_hit" = "0" ] && echo "[init] check_dangerous_env: clean。"
}

# [E6] 类型安全的模型目录归一化 + 存在性判断
_models_rows() {
  jq '
    if type=="array" then .
    elif type=="object" and (.data|type)=="array"   then .data
    elif type=="object" and (.models|type)=="array" then .models
    else [] end' 2>/dev/null
}
model_in_catalog() {
  # $1=catalog json  $2=model id（不含 nvidia/ 前缀）
  jq -e --arg m "$2" '
    ( if type=="array" then .
      elif type=="object" and (.data|type)=="array"   then .data
      elif type=="object" and (.models|type)=="array" then .models
      else [] end )
    | any(.[]; ((.id? // .name? // .model? // "")|tostring)
               | (.==$m or .==("nvidia/"+$m)))' >/dev/null 2>&1
}

# ── §6 purge_proxy_db（三重防御）──
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
      echo "[init] purge: 注册表无 ${_PROXY_RELAY_HOST}:${_PROXY_RELAY_PORT}。"
    fi
  else
    echo "[init] purge: 管理 API 暂不可用，走 SQL 兜底。"
  fi
  if [ -f "$_DB_PATH" ]; then
    sqlite3 "$_DB_PATH" "DELETE FROM proxy_assignments WHERE proxy_id IN
      (SELECT id FROM proxy_registry WHERE host='$(sql_escape "$_PROXY_RELAY_HOST")' AND port=$_PROXY_RELAY_PORT);" 2>/dev/null || true
    sqlite3 "$_DB_PATH" "UPDATE provider_connections SET proxy_enabled=0 WHERE provider='nvidia';" 2>/dev/null || true
    sqlite3 "$_DB_PATH" "DELETE FROM proxy_registry WHERE host='$(sql_escape "$_PROXY_RELAY_HOST")' AND port=$_PROXY_RELAY_PORT;" 2>/dev/null || true
    sqlite3 "$_DB_PATH" "UPDATE settings SET value=json_set(value,'\$.proxyUrl',null,'\$.proxyEnabled',json('false')) WHERE key='runtime' AND json_valid(value) AND json_extract(value,'\$.proxyUrl') IS NOT NULL;" 2>/dev/null || true
    sqlite3 "$_DB_PATH" "UPDATE settings SET value=json_set(value,'\$.relayBackend',null) WHERE key='runtime' AND json_valid(value) AND json_extract(value,'\$.relayBackend') IS NOT NULL;" 2>/dev/null || true
    local _reg _asg _proxy_on
    _reg=$(sqlite3 "$_DB_PATH" "SELECT COUNT(*) FROM proxy_registry;" 2>/dev/null || echo "?")
    _asg=$(sqlite3 "$_DB_PATH" "SELECT COUNT(*) FROM proxy_assignments;" 2>/dev/null || echo "?")
    _proxy_on=$(sqlite3 "$_DB_PATH" "SELECT COUNT(*) FROM provider_connections WHERE provider='nvidia' AND proxy_enabled=1;" 2>/dev/null || echo "?")
    echo "[init] purge: registry=$_reg assignments=$_asg proxy_enabled=1剩余=$_proxy_on（期望 0/0/0）。"
  fi
}

# ── Step 7: Resilience（v5.2 修正：增加 400-不烧穿 + CB 阈值保护）──
echo "[init] Resilience (RPM=$_RPM, concurrent=$_CONCURRENT, interval=${_MIN_INTERVAL_MS}ms)..."
_res_validate_int "$_RPM" 1 60000            || { echo "[init] ✗ RPM 越界"; exit 1; }
_res_validate_int "$_MIN_INTERVAL_MS" 0 600000 || { echo "[init] ✗ minMs 越界"; exit 1; }
_res_validate_int "$_CONCURRENT" 1 1000      || { echo "[init] ✗ concurrent 越界"; exit 1; }

_RESILIENCE_BODY=$(jq -n \
  --argjson rpm "$_RPM" \
  --argjson minMs "$_MIN_INTERVAL_MS" \
  --argjson conc "$_CONCURRENT" \
  '{
    requestQueue: {
      requestsPerMinute: $rpm,
      minTimeBetweenRequestsMs: $minMs,
      concurrentRequests: $conc
    },
    connectionCooldown: {
      apikey: {
        useUpstreamRetryHints: true,
        useUpstream429BreakerHints: true
      }
    },
    providerBreaker: {
      apikey: {
        failureThreshold: 5,
        resetTimeoutMs: 30000
      }
    },
    waitForCooldown: {
      enabled: false
    }
  }')

# ── §8 nim_probe（--retry 2 抗抖动；仅 4xx 判坏，000/5xx 不判）──
nim_probe() {
  [ "${NIM_PROBE:-0}" != "1" ] && { echo "[init] nim_probe: disabled (set NIM_PROBE=1 to enable)."; return 0; }
  echo "[init] nim_probe: enabled — 单 key 单次探针 + HTTP 000 忽略"
  local PROBE_DIR="/tmp/nim-probe"; mkdir -p "$PROBE_DIR"; > /tmp/nim-probe-bad.txt
  local _first_key m _stamp _now _last _code
  _first_key=$(printf '%s\n' "$NIM_KEYS" | head -n1); _now=$(date +%s)

  while IFS= read -r m; do
    [ -z "$m" ] && continue
    grep -Fxq "$m" /tmp/nim-deprecated.txt 2>/dev/null && continue
    _stamp="$PROBE_DIR/$(echo "$m" | tr '/' '-').ts"; _last=$(cat "$_stamp" 2>/dev/null || echo 0)
    [ $(( _now - _last )) -lt 3600 ] && { echo "[init]   probe skip $m（1h 内已探）"; continue; }
    _code=$(curl -s -o /dev/null -w "%{http_code}" --retry 2 --retry-delay 1 --max-time 15 \
      -H "Authorization: Bearer ${_first_key}" -H "Content-Type: application/json" \
      "https://integrate.api.nvidia.com/v1/chat/completions" \
      -d "$(jq -n --arg mid "$m" '{model:$mid, max_tokens:1, messages:[{role:"user",content:"hi"}]}')" 2>/dev/null || echo "000")
    echo "[init]   probe $m -> HTTP $_code"; echo "$_now" > "$_stamp"
    case "$_code" in 4[0-9][0-9]) echo "$m" >> /tmp/nim-probe-bad.txt ;; esac
    sleep 1
  done < <(build_all_models)
}

# ── §9 Context 累积表与观测（纯本地 SQLite，只读推荐不回写）──
_context_acc_init_table() {
  [ ! -f "$_DB_PATH" ] && return 1
  sqlite3 "$_DB_PATH" "
    CREATE TABLE IF NOT EXISTS context_recommendations (
      model_id TEXT PRIMARY KEY,
      last_success_tokens INTEGER DEFAULT NULL,
      first_failure_tokens INTEGER DEFAULT NULL,
      success_samples INTEGER DEFAULT 0,
      failure_samples INTEGER DEFAULT 0,
      confidence TEXT DEFAULT 'insufficient',
      recommended_real_context INTEGER DEFAULT NULL,
      last_updated TEXT DEFAULT NULL
    );" 2>/dev/null || return 1
  return 0
}
context_accumulator_update() {
  echo "[init] context_accumulator_update: 增量累积每模型成功/失败口径..."
  _context_acc_init_table || return 0
  local _checkpoint_ts _ctx_last_log_ts
  _checkpoint_ts=$(sqlite3 "$_DB_PATH" "SELECT value FROM key_value WHERE namespace='monitor' AND key='context_checkpoint_ts';" 2>/dev/null || echo "")
  _ctx_last_log_ts=$(sqlite3 "$_DB_PATH" "SELECT MAX(created_at) FROM call_logs WHERE created_at > '$_checkpoint_ts';" 2>/dev/null || echo "")
  [ -z "$_ctx_last_log_ts" ] && { echo "[init]   无新 call_logs 数据，跳过累积"; return 0; }
  echo "[init]   checkpoint last_ts=${_checkpoint_ts:-none} -> ctx_last_log_ts=$_ctx_last_log_ts"
  sqlite3 "$_DB_PATH" "INSERT OR REPLACE INTO key_value(namespace,key,value) VALUES('monitor','context_checkpoint_ts','$_ctx_last_log_ts');" 2>/dev/null || true
  echo "[init] ═══累积 real_context 推荐═══"
  local _row
  while read -r _row; do [ -n "$_row" ] && echo "[init]   $_row"; done < <(sqlite3 "$_DB_PATH" "SELECT model_id || ' | ' ||
    COALESCE(CAST(last_success_tokens AS TEXT),'-') || ' | ' ||
    COALESCE(CAST(first_failure_tokens AS TEXT),'-') || ' | ' ||
    (success_samples||'/'||failure_samples) || ' | ' ||
    COALESCE(confidence,'-') || ' | ' ||
    COALESCE(CAST(recommended_real_context AS TEXT),'-')
    FROM context_recommendations ORDER BY success_samples DESC LIMIT 20;" 2>/dev/null)
  echo "[init] ═══════════════════════════"
}

# ════════════════════════════════════════════════════════════════
#  ★★★ 主流程 ★★★
# ════════════════════════════════════════════════════════════════

# ── Step 0: 输入校验 ──
[ -z "$NIM_KEYS" ]         && { echo "[init] ✗ NIM_KEYS 为空，跳过注册但继续启动。"; exit 0; }
[ -z "$INITIAL_PASSWORD" ] && { echo "[init] ✗ FATAL: INITIAL_PASSWORD 为空。"; exit 1; }

# ── Step 1: 危险环境扫描 ──
check_dangerous_env

# ── Step 2: 等待 OmniRoute 就绪 ──
echo "[init] 等待 OmniRoute..."
_wait=0
while [ $_wait -lt 60 ]; do
  curl -sf "$BASE_URL/api/monitoring/health" >/dev/null 2>&1 && { echo "[init] OmniRoute up (after ${_wait}s)."; break; }
  sleep 2; _wait=$((_wait+2))
done
[ $_wait -ge 60 ] && { echo "[init] ✗ OmniRoute 未在 60s 内就绪"; exit 1; }
_OR_VER=$(curl -sf "$BASE_URL/api/monitoring/health" | jq -r '.version // "unknown"' 2>/dev/null || echo "unknown")
echo "[init] version: $_OR_VER"

# ── Step 3: Cookie Login（三重安全网）──
echo "[init] Logging in..."
LOGIN_HTTP=$(curl -s -o "$LOGIN_RESP_FILE" -w "%{http_code}" -c "$COOKIE_FILE" \
  -X POST "$BASE_URL/api/auth/login" -H "Content-Type: application/json" \
  -d "$(jq -n --arg password "$INITIAL_PASSWORD" '{password:$password}')" 2>/dev/null || echo "000")
if [ "$LOGIN_HTTP" != "200" ] && [ "$LOGIN_HTTP" != "201" ]; then
  echo "[init] ✗ Cookie login 失败: HTTP $LOGIN_HTTP"; cat "$LOGIN_RESP_FILE" 2>/dev/null || true; exit 1
fi
grep -q "auth_token" "$COOKIE_FILE" 2>/dev/null || { echo "[init] ✗ cookie 中无 auth_token"; exit 1; }
echo "[init] Logged in (HTTP $LOGIN_HTTP)."

# ── Step 4: 注册 NIM Keys（幂等，409 跳过）──
echo "[init] Registering NIM keys..."
mapfile -t _KEYS < <(printf '%s\n' "$NIM_KEYS" | sed '/^[[:space:]]*$/d')
_ki=0
for _key in "${_KEYS[@]}"; do
  [ -z "$_key" ] && continue
  _ki=$((_ki+1)); _masked="nim-$(printf '%02d' $_ki)"
  _kresp="$(_resp omniroute-provider-${_ki}.json)"
  _khttp=$(curl -s -o "$_kresp" -w "%{http_code}" -b "$COOKIE_FILE" \
    -X POST "$BASE_URL/api/providers" -H "Content-Type: application/json" \
    -d "$(jq -n --arg provider "nvidia" --arg apiKey "$_key" --arg name "$_masked" '{provider:$provider, apiKey:$apiKey, name:$name, priority:1, testStatus:"unknown"}')" 2>/dev/null || echo "000")
  case "$_khttp" in
    200|201) echo "[init] $_masked OK";   REGISTERED=$((REGISTERED+1)) ;;
    409)     echo "[init] $_masked exists"; SKIPPED=$((SKIPPED+1)) ;;
    *)       echo "[init] $_masked FAIL HTTP $_khttp"; FAILED=$((FAILED+1)); cat "$_kresp" 2>/dev/null || true ;;
  esac
done
echo "[init] Keys: $REGISTERED registered, $SKIPPED skipped, $FAILED failed."

# ── Step 5: Provider IDs ──
_prov_json=$(curl -s -b "$COOKIE_FILE" "$BASE_URL/api/providers" 2>/dev/null || echo "")
_prov_count=$(printf '%s' "$_prov_json" | jq -r '[ (.providers // .)[]? | select(.type=="nim" or .provider=="nvidia") ] | length' 2>/dev/null || echo "0")
echo "[init] Provider IDs: $_prov_count"

# ── Step 6: ProxyFetch 三重防御 ──
purge_proxy_db

# ── Step 7: Resilience（真实路径 /api/resilience，PATCH，读回校验）──
echo "[init] Resilience (RPM=$_RPM, concurrent=$_CONCURRENT, interval=${_MIN_INTERVAL_MS}ms)..."
_res_validate_int "$_RPM" 1 60000            || { echo "[init] ✗ RPM 越界"; exit 1; }
_res_validate_int "$_MIN_INTERVAL_MS" 0 600000 || { echo "[init] ✗ minMs 越界"; exit 1; }
_res_validate_int "$_CONCURRENT" 1 1000      || { echo "[init] ✗ concurrent 越界"; exit 1; }
_RESILIENCE_BODY=$(jq -n --argjson rpm "$_RPM" --argjson minMs "$_MIN_INTERVAL_MS" --argjson conc "$_CONCURRENT" \
  '{requestQueue:{requestsPerMinute:$rpm, minTimeBetweenRequestsMs:$minMs, concurrentRequests:$conc}}')
_RESILIENCE_CODE=$(curl -s -o "$RESILIENCE_RESP_FILE" -w "%{http_code}" -b "$COOKIE_FILE" \
  -X PATCH "$BASE_URL/api/resilience" -H "Content-Type: application/json" -d "$_RESILIENCE_BODY" 2>/dev/null || echo "000")
if [ "$_RESILIENCE_CODE" = "200" ] || [ "$_RESILIENCE_CODE" = "204" ]; then
  _RB=$(curl -s -b "$COOKIE_FILE" "$BASE_URL/api/resilience" 2>/dev/null || echo "{}")
  _rr=$(printf '%s' "$_RB" | jq -r '.requestQueue.requestsPerMinute // empty')
  _rm=$(printf '%s' "$_RB" | jq -r '.requestQueue.minTimeBetweenRequestsMs // empty')
  _rc=$(printf '%s' "$_RB" | jq -r '.requestQueue.concurrentRequests // empty')
  if [ "$_rr" = "$_RPM" ] && [ "$_rm" = "$_MIN_INTERVAL_MS" ] && [ "$_rc" = "$_CONCURRENT" ]; then
    echo "[init] ✓ Resilience: HTTP $_RESILIENCE_CODE 读回一致"
  else
    echo "[init] ⚠ Resilience 读回不一致: rpm=$_rr minMs=$_rm conc=$_rc"
  fi
else
  echo "[init] ⚠ Resilience PATCH HTTP $_RESILIENCE_CODE"; cat "$RESILIENCE_RESP_FILE" 2>/dev/null || true
fi

# ── Step 8: Settings 清代理 + body limit（真实路径 /api/settings）──
_SETTINGS_BODY=$(jq -n --argjson mb "$_REQUEST_BODY_LIMIT_MB" \
  '{routing:{maxBodySizeMb:$mb}, proxyUrl:null, proxyEnabled:false, relayBackend:null}')
_SETTINGS_CODE=$(curl -s -o "$SETTINGS_RESP_FILE" -w "%{http_code}" -b "$COOKIE_FILE" \
  -X PATCH "$BASE_URL/api/settings" -H "Content-Type: application/json" -d "$_SETTINGS_BODY" 2>/dev/null || echo "000")
echo "[init] Settings HTTP $_SETTINGS_CODE"

# ── Step 9: Compression（GET→精确字段清洗→PUT /api/settings/compression）──
echo "[init] Compression (GET→合并→PUT /api/settings/compression)..."
_COMPRESS_CUR=$(curl -s -b "$COOKIE_FILE" \
  "$BASE_URL/api/settings/compression" 2>/dev/null || echo "")

if ! printf '%s' "$_COMPRESS_CUR" | jq -e . >/dev/null 2>&1; then
  echo "[init] ⚠ Compression GET 返回空或非 JSON，跳过 PUT"
else
  # PUT schema 用 defaultMode 而非 mode；rtkConfig.enableRenderers 是 DB 残留的废弃字段
  # 两者均被 .strict() 拒绝 → 必须在 PUT 前剔除
  _COMPRESS_BODY=$(printf '%s' "$_COMPRESS_CUR" | jq -c '
    del(.mode)
    | del(.rtkConfig.enableRenderers)
    | .defaultMode = "stacked"
  ')
  _COMPRESS_CODE=$(curl -s -o "$COMPRESS_RESP_FILE" -w "%{http_code}" \
    -b "$COOKIE_FILE" \
    -X PUT "$BASE_URL/api/settings/compression" \
    -H "Content-Type: application/json" \
    -d "$_COMPRESS_BODY" 2>/dev/null || echo "000")
  case "$_COMPRESS_CODE" in
    2??) echo "[init] ✓ Compression: HTTP $_COMPRESS_CODE (defaultMode=stacked)" ;;
    *)   echo "[init] ⚠ Compression PUT HTTP $_COMPRESS_CODE（非致命）"
         head -c 300 "$COMPRESS_RESP_FILE" 2>/dev/null || true ;;
  esac
fi

# ── Step 10: Thinking budget（[E2] GET→合并→PUT /api/settings/thinking-budget）──
echo "[init] Thinking budget (GET→合并→PUT /api/settings/thinking-budget)..."
_cur=$(curl -s -b "$COOKIE_FILE" "$BASE_URL/api/settings/thinking-budget" 2>/dev/null || echo "")
if printf '%s' "$_cur" | jq -e . >/dev/null 2>&1; then
  _body=$(printf '%s' "$_cur" | jq -c \
    --argjson bud "${NIM_THINKING_BUDGET:-8000}" '
      . as $c
      | (if ($c|has("mode"))             then .mode="adaptive"        else . end)
      | (if ($c|has("budgetTokens"))     then .budgetTokens=$bud      else . end)
      | (if ($c|has("maxThinkingTokens"))then .maxThinkingTokens=$bud else . end)')
  _code=$(curl -s -o "$THINKING_RESP_FILE" -w "%{http_code}" -b "$COOKIE_FILE" \
    -X PUT "$BASE_URL/api/settings/thinking-budget" -H "Content-Type: application/json" -d "$_body" 2>/dev/null || echo "000")
  case "$_code" in 2??) echo "[init] ✓ Thinking budget: HTTP $_code";; *) echo "[init] ⚠ Thinking PUT HTTP $_code: $(head -c 200 "$THINKING_RESP_FILE")";; esac
else
  echo "[init] ⚠ Thinking GET 读回失败,跳过写入(不猜字段)"
fi

# ── Step 11: Memory 健康探测（[E4] GET /api/memory/health）──
_mh=$(curl -s -o /dev/null -w "%{http_code}" -b "$COOKIE_FILE" "$BASE_URL/api/memory/health" 2>/dev/null || echo "000")
echo "[init] ✓ Memory health: HTTP $_mh"

# ── Step 12: 断路器重置（[E3] POST /api/resilience/reset）──
_CB_CODE=$(curl -s -o /dev/null -w "%{http_code}" -b "$COOKIE_FILE" \
  -X POST "$BASE_URL/api/resilience/reset" 2>/dev/null || echo "000")
echo "[init] ✓ CB reset: HTTP $_CB_CODE"

# ── Step 13: Context 策略（文档核实：无 catalog 模型 context 写入端点）──
# 结论：不在 init 写 real_context。理由——
#   · /api/provider-models 仅管"自定义模型"，不覆盖 NVIDIA catalog 模型（API Ref 原文）
#   · 无任何 REST 端点可给 catalog 模型写 per-model real_context
#   · 直接 SQL 写 model_context_overrides 有 migration schema 漂移风险
# 因此 context 交由 §9 的 context_recommendations 被动观测；模型用 registry 默认 context。
echo "[init] context: 跳过主动写入（无文档端点）；由 context_recommendations 被动标定。"
_context_acc_init_table && echo "[init] context_recommendations 表就绪（观测模式）。" \
                        || echo "[init] ⚠ context_recommendations 表初始化跳过（DB 未就绪）。"

# ── Step 14: 增量模式判断 ──
echo "[init] --------------------------------------------------------"
echo "[init]   PROFILE=$_PROFILE MODE=$NIM_MODE KEYS=$_ALIVE_KEYS RPM=$_RPM CONCURRENT=$_CONCURRENT INTERVAL=${_MIN_INTERVAL_MS}ms"
echo "[init]   POOL_STRATEGY=$_POOL_STRATEGY PROBE=${NIM_PROBE:-0} REAL_CONTEXT=$_NIM_REAL_CONTEXT"
echo "[init] --------------------------------------------------------"
_IS_INCREMENTAL=0
if [ -f "$_DB_PATH" ]; then
  _combo_count=$(sqlite3 "$_DB_PATH" "SELECT COUNT(*) FROM combos WHERE name IN ('nim-pool','nim-stable','nim-fast','nim-codex');" 2>/dev/null || echo "0")
  [ "$_combo_count" -gt 0 ] && _IS_INCREMENTAL=1
fi
[ "$_IS_INCREMENTAL" = "1" ] && echo "[init] Incremental mode." || echo "[init] First-init mode."

# ── Step 15: 再次 purge（注册后 proxy_enabled 可能被隐式启用）──
purge_proxy_db

# ── Step 16-17: 模型健康 + 探针 ──
check_nim_model_health
nim_probe

# ── Step 18: 创建/更新 4 个 Combos ──
# 修复：build_all_models 输出转为数组后再传 filter_alive，避免单参数陷阱
mapfile -t _all_models < <(build_all_models)
_pool_models=$(filter_alive "${_all_models[@]}")
_codex_models=$(filter_alive "${NIM_CODEX_MODELS[@]}")
_fast_models=$(filter_alive "${NIM_FAST_MODELS[@]}")
upsert_combo "nim-pool"   "$_POOL_STRATEGY"  $_pool_models    # 主力池
upsert_combo "nim-codex"  "$_CODEX_STRATEGY" $_codex_models   # 代码生成
upsert_combo "nim-fast"   "round-robin"      $_fast_models    # 快速响应
upsert_combo "nim-stable" "priority"         $_pool_models    # 稳定长会话

# ── Step 19: Context 累积观测 ──
context_accumulator_update

# ── Step 20: HF Dataset 快照（best-effort）──
_hf_snapshot() {
  [ -z "${HF_DATASET_REPO:-}" ] && { echo "[init] HF_DATASET_REPO 未设置，跳过快照。"; return 0; }
  [ -z "${HF_TOKEN:-}" ]        && { echo "[init] HF_TOKEN 未设置，跳过快照。"; return 0; }
  echo "[init] HF Dataset snapshot..."
  local _dir="/tmp/hf-snapshot-$(date +%s)"; mkdir -p "$_dir"
  jq -n --arg profile "$_PROFILE" --argjson rpm "$_RPM" --argjson concurrent "$_CONCURRENT" \
    --argjson interval "$_MIN_INTERVAL_MS" --argjson body_mb "$_REQUEST_BODY_LIMIT_MB" \
    --argjson probe "${NIM_PROBE:-0}" --arg ctx "$_NIM_REAL_CONTEXT" --arg mode "$NIM_MODE" \
    --arg keys "$_ALIVE_KEYS" --arg registered "$REGISTERED" --arg skipped "$SKIPPED" \
    --arg failed "$FAILED" --arg version "$_OR_VER" --arg ts "$(date -Iseconds)" \
    '{profile:$profile,rpm:$rpm,concurrent:$concurrent,intervalMs:$interval,maxBodySizeMb:$body_mb,probe:$probe,realContext:$ctx,mode:$mode,totalKeys:$keys,registered:$registered,skipped:$skipped,failed:$failed,omnirouteVersion:$version,snapshotTs:$ts}' \
    > "$_dir/init_vars.json"
  local _msg="init v5.1 | $_OR_VER | keys=$_ALIVE_KEYS rpm=$_RPM | $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  local _code
  _code=$(curl -s -o /dev/null -w "%{http_code}" \
    -X POST "https://huggingface.co/api/datasets/$HF_DATASET_REPO/commit/main" \
    -H "Authorization: Bearer $HF_TOKEN" -F "message=$_msg" -F "file=@$_dir/init_vars.json" 2>/dev/null || echo "000")
  rm -rf "$_dir"
  case "$_code" in 200|201) echo "[init] HF Dataset uploaded.";; *) echo "[init] ⚠ HF 上传失败 HTTP $_code（非致命）";; esac
}
_hf_snapshot || true

# ── Step 21: 搜索提供商就绪自检（GET /v1/search 需 Bearer API key，非 cookie）──
check_search_ready() {
  local _key _body _count
  _key="${OMNIROUTE_API_KEY:-}"
  [ -z "$_key" ] && _key=$(cat "$OR_API_KEY_FILE" 2>/dev/null || echo "")
  [ -z "$_key" ] && { echo "[init] search 自检跳过：无 OR_API_KEY（Bearer）。"; return 0; }
  _body=$(curl -s -H "Authorization: Bearer $_key" "$BASE_URL/v1/search" 2>/dev/null || echo "")
  _count=$(printf '%s' "$_body" | jq '[ (.providers // .)[]? ] | length' 2>/dev/null || echo 0)
  if [ "${_count:-0}" -ge 1 ]; then
    echo "[init] ✓ search providers ready: $_count"
  else
    echo "[init] ⚠ 未检测到搜索提供商，请在 Dashboard → Search Tools 配置 Tavily/SearXNG 等。"
  fi
}
check_search_ready

# ── 完成 ──
echo "[init] ============================================================"
[ "$_IS_INCREMENTAL" = "1" ] && echo "[init] Done (incremental). v5.1" || echo "[init] Done (first-init). v5.1"
echo "[init] ============================================================"