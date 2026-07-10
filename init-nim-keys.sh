#!/bin/bash
set -eo pipefail

# ─────────────────────────────────────────────────────────────
# NIM OmniRoute initializer  v4.2.3（基于 v4.2.2）
# 相对 v4.2.2 的变更：
#   【v4.2.3·⑨ 】DEBUG log 上传 Dataset（debug_<时间戳>.log，默认开启，
#              NIM_DEBUG_LOG_TO_DATASET=0 关闭）；本地仅留最近 NIM_DEBUG_LOG_KEEP(默认5) 个。
#              取代 v4.2.1 继承的 "DEBUG log 不入 Dataset" 旧策略。
# 继承 v4.2.2：⑦ 幂等 upsert_combo ⑧ 增量门放宽（任一 nim-* combo 或 INIT_MARKER）。
# 继承 v4.2.1：① 移除 quota-share/主池 p2c+白名单 ② nim-codex 响应体打印
#              ④ 可选探针 NIM_PROBE ⑤ 增量只清过期熔断 ⑥ nim_health_pick 分档推荐。
# ─────────────────────────────────────────────────────────────

# ══ 单变量调试 + 日志归档（stdout 实时 tee；DEBUG 时另上传 Dataset，见⑨）═══════
NIM_MODE="${NIM_MODE:-NORMAL}"
LOG_DIR="/data/omni-data/log"
if [ "$NIM_MODE" = "DEBUG" ]; then
  mkdir -p "$LOG_DIR" 2>/dev/null || true
  INIT_LOG="$LOG_DIR/init_$(date +%Y%m%d_%H%M%S).log"
  exec > >(tee -a "$INIT_LOG") 2>&1
  echo "[init] 🛠️ NIM_MODE=DEBUG：日志 tee -> $INIT_LOG（仅容器内，随 Space 日志可见，不入 Dataset）"
  export APP_LOG_TO_FILE=true
  export DISABLE_SQLITE_AUTO_BACKUP=true
else
  LOG_DIR="/tmp"
fi
_resp() { echo "$LOG_DIR/$1"; }

# ── 强制关闭代理生态 ──────────────────────────────────────────
export ONEPROXY_ENABLED=false
export ENABLE_SOCKS5_PROXY=false
export NEXT_PUBLIC_ENABLE_SOCKS5_PROXY=false
unset HTTP_PROXY HTTPS_PROXY ALL_PROXY http_proxy https_proxy all_proxy 2>/dev/null || true
unset OMNIROUTE_RELAY_BACKEND BIFROST_BASE_URL 2>/dev/null || true

# ── 端口配置 ──────────────────────────────────────────────────
[ -z "$OMNIROUTE_PORT" ] && OMNIROUTE_PORT=20128
BASE_URL="http://127.0.0.1:$OMNIROUTE_PORT"
INIT_MARKER="/data/.init-done"
OR_API_KEY_FILE="/data/.or-api-key"
COOKIE_FILE="/tmp/omniroute-cookie.txt"

LOGIN_RESP_FILE="$(_resp omniroute-login.json)"
KEY_RESP_FILE="$(_resp omniroute-key-response.json)"
PROVIDERS_FILE="$(_resp omniroute-providers.json)"
RESILIENCE_RESP_FILE="$(_resp omniroute-resilience.json)"
SETTINGS_RESP_FILE="$(_resp omniroute-settings.json)"
COMPRESS_RESP_FILE="$(_resp omniroute-compress.json)"
THINKING_RESP_FILE="$(_resp omniroute-thinking.json)"
MEMORY_LEGACY_RESP_FILE="$(_resp omniroute-memory-legacy.json)"
MEMORY_EXT_RESP_FILE="$(_resp omniroute-memory-ext.json)"
COMBO_RESP_FILE="$(_resp omniroute-combo.json)"
VERSION_FILE="$(_resp omniroute-version.json)"

REGISTERED=0; SKIPPED=0; FAILED=0

# ══ 模型分档 SSOT（对齐现行 NVIDIA 目录）═══════════════════════
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
  fast)     NIM_POOL_MODELS=("${TIER_FAST[@]}") ;;
  full)     NIM_POOL_MODELS=("${TIER_FAST[@]}" "${TIER_STABLE[@]}" "${TIER_RESTRICTED[@]}") ;;
  *)        _PROFILE="balanced"; NIM_POOL_MODELS=("${TIER_FAST[@]}" "${TIER_STABLE[@]}") ;;
esac
echo "[init] NIM_PROFILE=$_PROFILE -> pool 意向 ${#NIM_POOL_MODELS[@]} 个模型"

NIM_CODEX_MODELS=(
  "deepseek-ai/deepseek-v4-pro"
  "openai/gpt-oss-120b"
  "z-ai/glm-5.2"
)
NIM_FAST_MODELS=(
  "deepseek-ai/deepseek-v4-flash"
  "meta/llama-3.3-70b-instruct"
  "google/gemma-4-31b-it"
)
NIM_EXTRA_MODELS=( "deepseek-ai/deepseek-v4-flash" )

build_all_models() {
  printf '%s
' "${NIM_POOL_MODELS[@]}" "${NIM_CODEX_MODELS[@]}" "${NIM_EXTRA_MODELS[@]}" | awk '!seen[$0]++'
}
models_to_json() { printf '%s\n' "$@" | sed 's/^/nvidia\//' | jq -R '{model: .}' | jq -s -c .; }

# ══ combo 策略白名单（3.8.43 实测合法枚举，不含 quota-share）═════
_VALID_STRATS="priority weighted round-robin context-relay fill-first p2c random least-used cost-optimized reset-aware reset-window headroom strict-random auto lkgp context-optimized fusion"
_is_valid_strat() { printf '%s' "$_VALID_STRATS" | grep -qw -- "$1"; }

# ══ 【⑦ 】幂等 upsert：存在则 PUT，不存在才 POST ═══════════════
upsert_combo() {
  local NAME="$1" STRAT="$2"; shift 2; local MODELS=("$@")
  _is_valid_strat "$STRAT" || { echo "[init] upsert_combo: '$STRAT' 非法 -> round-robin"; STRAT="round-robin"; }
  [ "${#MODELS[@]}" -eq 0 ] && { echo "[init] upsert_combo: $NAME 无存活模型，跳过。"; return 0; }
  local BODY CID CODE F
  BODY=$(jq -n --arg name "$NAME" --arg strat "$STRAT" \
               --argjson models "$(models_to_json "${MODELS[@]}")" \
               '{name:$name, strategy:$strat, models:$models}')
  CID=$(curl -s -b "$COOKIE_FILE" "$BASE_URL/api/combos" \
        | jq -r --arg n "$NAME" '.combos[]? // .[]? | select(.name==$n) | .id' | head -n1)
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
  [ "$CODE" != "200" ] && [ "$CODE" != "201" ] && cat "$F" || true
}

# ══ 按存活 Key 数动态推导 RPM/并发 ═════════════════════════════
_count_alive_keys() { printf '%s
' "$NIM_KEYS" | sed '/^[[:space:]]*$/d' | wc -l; }
_ALIVE_KEYS=$(_count_alive_keys)
_PER_KEY_RPM=${NIM_PER_KEY_RPM:-35}
_RPM=$(( _ALIVE_KEYS * _PER_KEY_RPM ))
[ "$_RPM" -lt "$_PER_KEY_RPM" ] && _RPM=$_PER_KEY_RPM
[ "$_RPM" -gt 300 ] && _RPM=300
_CONCURRENT=$(( _ALIVE_KEYS * ${NIM_PER_KEY_CONCURRENT:-3} ))
[ "$_CONCURRENT" -lt 3 ] && _CONCURRENT=3
_MIN_INTERVAL_MS=$(( 60000 / (_RPM > 0 ? _RPM : 1) ))
echo "[init] alive_keys=$_ALIVE_KEYS -> RPM=$_RPM concurrent=$_CONCURRENT interval=${_MIN_INTERVAL_MS}ms"

if [ "$_ALIVE_KEYS" -gt 1 ]; then
  _POOL_STRATEGY="${NIM_POOL_STRATEGY:-p2c}"
else
  _POOL_STRATEGY="round-robin"
fi
_is_valid_strat "$_POOL_STRATEGY" || { echo "[init] WARN: pool strategy '$_POOL_STRATEGY' 非法，回退 round-robin"; _POOL_STRATEGY="round-robin"; }
_CODEX_STRATEGY="${NIM_CODEX_STRATEGY:-round-robin}"
_is_valid_strat "$_CODEX_STRATEGY" || { echo "[init] WARN: codex strategy '$_CODEX_STRATEGY' 非法，回退 round-robin"; _CODEX_STRATEGY="round-robin"; }
_FALLBACK_STRATEGY="round-robin"
_STICKY_LIMIT=1
_COMPRESS_THRESHOLD=${NIM_COMPRESS_THRESHOLD:-12000}
_COMPRESS_MODE="stacked"
_THINKING_MODE="adaptive"
_THINKING_BUDGET=8000
_NIM_REAL_CONTEXT=${CONTEXT_LENGTH_DEFAULT:-32768}
echo "[init] pool strategy=$_POOL_STRATEGY | codex strategy=$_CODEX_STRATEGY"

# ── body limit 归一 ───────────────────────────────────────────
_RAW_BODY_LIMIT=${NIM_REQUEST_BODY_LIMIT:-1}
if [ "$_RAW_BODY_LIMIT" -gt 500 ] 2>/dev/null; then
  _REQUEST_BODY_LIMIT_MB=$(( _RAW_BODY_LIMIT / 1048576 ))
  [ "$_REQUEST_BODY_LIMIT_MB" -lt 1 ] && _REQUEST_BODY_LIMIT_MB=1
elif [ "$_RAW_BODY_LIMIT" -lt 1 ] 2>/dev/null; then
  _REQUEST_BODY_LIMIT_MB=1
else
  _REQUEST_BODY_LIMIT_MB=$_RAW_BODY_LIMIT
fi
[ "$_REQUEST_BODY_LIMIT_MB" -gt 500 ] 2>/dev/null && _REQUEST_BODY_LIMIT_MB=500
echo "[init] body limit: raw=$_RAW_BODY_LIMIT -> maxBodySizeMb=$_REQUEST_BODY_LIMIT_MB"

_PURGE_PROXY=${NIM_PURGE_PROXY:-1}
_PROXY_RELAY_HOST=${NIM_PROXY_RELAY_HOST:-127.0.0.1}
_PROXY_RELAY_PORT=${NIM_PROXY_RELAY_PORT:-20129}
_DB_PATH="${DATA_DIR:-/data}/storage.sqlite"
sql_escape() { printf '%s' "$1" | sed "s/'/''/g"; }

check_dangerous_env() {
  echo "[init] check_dangerous_env: scanning relay/proxy env..."
  local _hit=0
  for v in OMNIROUTE_RELAY_BACKEND BIFROST_BASE_URL HTTP_PROXY HTTPS_PROXY ALL_PROXY http_proxy https_proxy all_proxy; do
    if [ -n "${!v}" ]; then echo "[init] ⚠️ DANGER: env $v=${!v} 已设置。"; _hit=1; fi
  done
  [ "$_hit" = "0" ] && echo "[init] check_dangerous_env: clean。"
}

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
    local _reg _asg _proxy_on
    _reg=$(sqlite3 "$_DB_PATH" "SELECT COUNT(*) FROM proxy_registry;" 2>/dev/null || echo "?")
    _asg=$(sqlite3 "$_DB_PATH" "SELECT COUNT(*) FROM proxy_assignments;" 2>/dev/null || echo "?")
    _proxy_on=$(sqlite3 "$_DB_PATH" "SELECT COUNT(*) FROM provider_connections WHERE provider='nvidia' AND proxy_enabled=1;" 2>/dev/null || echo "?")
    echo "[init] purge: registry=$_reg assignments=$_asg proxy_enabled=1剩余=$_proxy_on（期望 0/0/0）。"
  fi
}

check_nim_model_health() {
  echo "[init] check_nim_model_health..."
  > /tmp/nim-deprecated.txt
  local _first_key _models_json _model_count
  _first_key=$(printf '%s
' "$NIM_KEYS" | head -n1)
  _models_json=$(curl -s --max-time 10 -H "Authorization: Bearer ${_first_key}" \
    "https://integrate.api.nvidia.com/v1/models" 2>/dev/null || echo "")
  _model_count=$(printf '%s' "$_models_json" | jq -r '.data[]?.id' 2>/dev/null | wc -l)
  [ "${_model_count:-0}" -lt 5 ] && { echo "[init] only $_model_count models, skip 过滤"; return 0; }
  while IFS= read -r model; do
    [ -z "$model" ] && continue
    if ! printf '%s' "$_models_json" | jq -e --arg m "$model" 'any(.data[]?.id == $m; .)' >/dev/null 2>&1; then
      echo "[init]   $model — DEPRECATED（NVIDIA 目录无）"; echo "$model" >> /tmp/nim-deprecated.txt
    else
      [ "$NIM_MODE" = "DEBUG" ] && echo "[init]   $model — available"
    fi
  done < <(build_all_models)
  echo "[init] $(wc -l < /tmp/nim-deprecated.txt 2>/dev/null || echo 0) deprecated / $_model_count available"
}

filter_alive() {
  local out=() m
  for m in "$@"; do grep -Fxq "$m" /tmp/nim-deprecated.txt 2>/dev/null || out+=("$m"); done
  printf '%s
' "${out[@]}"
}

# ══ 【④ 】轻量探针：默认关闭；NIM_PROBE=1 才跑 ═══════════════════
nim_probe() {
  [ "${NIM_PROBE:-0}" != "1" ] && { echo "[init] nim_probe: disabled (set NIM_PROBE=1 to enable)."; return 0; }
  echo "[init] nim_probe: enabled — 每模型每小时限频 + 跨 key 轮换 (max_tokens=1)"
  local PROBE_DIR="/tmp/nim-probe"; mkdir -p "$PROBE_DIR"
  > /tmp/nim-probe-bad.txt
  mapfile -t _KEYS < <(printf '%s
' "$NIM_KEYS" | sed '/^[[:space:]]*$/d')
  local _nkeys=${#_KEYS[@]}; [ "$_nkeys" -eq 0 ] && return 0
  local _ki=0 m _stamp _now _last _key _code
  _now=$(date +%s)
  while IFS= read -r m; do
    [ -z "$m" ] && continue
    grep -Fxq "$m" /tmp/nim-deprecated.txt 2>/dev/null && continue
    _stamp="$PROBE_DIR/$(echo "$m" | tr '/' '-').ts"
    _last=$(cat "$_stamp" 2>/dev/null || echo 0)
    if [ $(( _now - _last )) -lt 3600 ]; then
      echo "[init]   probe skip $m（1h 内已探）"; continue
    fi
    _key="${_KEYS[$(( _ki % _nkeys ))]}"; _ki=$(( _ki + 1 ))
    _code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 15 \
      -H "Authorization: Bearer ${_key}" -H "Content-Type: application/json" \
      "https://integrate.api.nvidia.com/v1/chat/completions" \
      -d "$(jq -n --arg mid "$m" '{model:$mid, max_tokens:1, messages:[{role:"user",content:"hi"}]}')" 2>/dev/null || echo "000")
    echo "[init]   probe $m (key#$(( (_ki-1) % _nkeys ))) -> HTTP $_code"
    echo "$_now" > "$_stamp"
    [ "$_code" != "200" ] && echo "$m" >> /tmp/nim-probe-bad.txt
    sleep 1
  done < <(build_all_models)
}

# ══ 【⑥ 】启动健康打分选型：读本地 call_logs，分档输出推荐 ═══════
nim_health_pick() {
  echo "[init] nim_health_pick: 读近1h本地 call_logs 打分（零外部请求）..."
  [ ! -f "$_DB_PATH" ] && { echo "[init]   no DB, skip pick."; return 0; }
  local _has_tbl
  _has_tbl=$(sqlite3 "$_DB_PATH" "SELECT name FROM sqlite_master WHERE type='table' AND name='call_logs';" 2>/dev/null || echo "")
  [ -z "$_has_tbl" ] && echo "[init]   call_logs 表不存在（尚无流量），本次按默认分档推荐。"

  _score_model() {
    local mid="$1" row
    [ -z "$_has_tbl" ] && { echo "NA"; return; }
    row=$(sqlite3 -separator '|' "$_DB_PATH" "
      SELECT
        printf('%.0f', SUM(CASE WHEN status_code BETWEEN 200 AND 299 THEN 1 ELSE 0 END)*100.0/COUNT(*)),
        printf('%.0f', AVG(latency_ms)),
        COUNT(*)
      FROM call_logs
      WHERE provider='nvidia' AND model_id='nvidia/$(sql_escape "$mid")'
        AND created_at > datetime('now','-1 hour');" 2>/dev/null || echo "")
    [ -z "$row" ] || [ "${row%%|*}" = "" ] && { echo "NA"; return; }
    echo "$row"
  }

  _pick_from() {
    local best="" best_ok=-1 best_ms=999999 m sc ok ms n
    for m in "$@"; do
      grep -Fxq "$m" /tmp/nim-deprecated.txt 2>/dev/null && continue
      grep -Fxq "$m" /tmp/nim-probe-bad.txt 2>/dev/null && continue
      sc=$(_score_model "$m")
      if [ "$sc" = "NA" ]; then
        [ -z "$best" ] && best="$m (无历史数据, 默认档位首选)"
        continue
      fi
      ok="${sc%%|*}"; ms=$(echo "$sc" | cut -d'|' -f2); n=$(echo "$sc" | cut -d'|' -f3)
      if [ "${ok:-0}" -gt "$best_ok" ] 2>/dev/null || \
         { [ "${ok:-0}" -eq "$best_ok" ] 2>/dev/null && [ "${ms:-999999}" -lt "$best_ms" ] 2>/dev/null; }; then
        best_ok=$ok; best_ms=$ms; best="$m (ok ${ok}%, ${ms}ms, n=${n})"
      fi
    done
    [ -z "$best" ] && best="（无存活候选）"
    echo "$best"
  }

  local PICK_CODE PICK_FAST PICK_GEN
  PICK_CODE=$(_pick_from "${NIM_CODEX_MODELS[@]}")
  PICK_FAST=$(_pick_from "${NIM_FAST_MODELS[@]}")
  PICK_GEN=$(_pick_from "${NIM_POOL_MODELS[@]}")

  echo "[init] ══════════ 本次推荐主力（按分档）══════════"
  echo "[init]   🧑 💻 编程/复杂推理 : $PICK_CODE"
  echo "[init]   ⚡ 低延迟/日常快答 : $PICK_FAST"
  echo "[init]   🎯 综合均衡首选   : $PICK_GEN"
  echo "[init] ────────────────────────────────────────"
  echo "[init]   直调示例：model = nvidia/${PICK_CODE%% *}"
  echo "[init] ═════════════════════════════════════════"
}

# ══════════════════════════════════════════════════════════════
echo "[init] Starting NIM OmniRoute initializer v4.2.3 (profile=$_PROFILE, mode=$NIM_MODE)..."
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
  KEY=$(printf '%s' "$RAW_KEY" | tr -d '' | xargs)
  [ -z "$KEY" ] && continue
  NAME=$(printf "nim-%02d" "$INDEX")
  RESP_FILE="$(_resp omniroute-provider-$INDEX.json)"
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

purge_proxy_db

echo "[init] Resilience (RPM=$_RPM, concurrent=$_CONCURRENT, interval=${_MIN_INTERVAL_MS}ms)..."
RESILIENCE_CODE=$(curl -s -o "$RESILIENCE_RESP_FILE" -w "%{http_code}" -b "$COOKIE_FILE" \
  -X PATCH "$BASE_URL/api/resilience" -H "Content-Type: application/json" \
  -d "{\"requestQueue\":{\"requestsPerMinute\":$_RPM,\"minTimeBetweenRequestsMs\":$_MIN_INTERVAL_MS,\"concurrentRequests\":$_CONCURRENT}}")
echo "[init] Resilience HTTP $RESILIENCE_CODE"

echo "[init] Routing + maxBodySizeMb=$_REQUEST_BODY_LIMIT_MB..."
SETTINGS_CODE=$(curl -s -o "$SETTINGS_RESP_FILE" -w "%{http_code}" -b "$COOKIE_FILE" \
  -X PATCH "$BASE_URL/api/settings" -H "Content-Type: application/json" \
  -d "{\"fallbackStrategy\":\"$_FALLBACK_STRATEGY\",\"stickyRoundRobinLimit\":$_STICKY_LIMIT,\"requestRetry\":2,\"maxRetryIntervalSec\":5,\"maxBodySizeMb\":$_REQUEST_BODY_LIMIT_MB}")
echo "[init] Settings HTTP $SETTINGS_CODE"
[ "$SETTINGS_CODE" != "200" ] && [ "$SETTINGS_CODE" != "201" ] && { echo "[init] ⚠️ Settings 非 2xx："; cat "$SETTINGS_RESP_FILE" || true; }

echo "[init] Compression (threshold=$_COMPRESS_THRESHOLD)..."
curl -s -o "$COMPRESS_RESP_FILE" -w "%{http_code}
" -b "$COOKIE_FILE" \
  -X PUT "$BASE_URL/api/settings/compression" -H "Content-Type: application/json" \
  -d "{\"enabled\":true,\"defaultMode\":\"$_COMPRESS_MODE\",\"autoTriggerTokens\":$_COMPRESS_THRESHOLD}" | sed 's/^/[init] Compression HTTP /'

echo "[init] Thinking budget..."
curl -s -o "$THINKING_RESP_FILE" -w "%{http_code}
" -b "$COOKIE_FILE" \
  -X PUT "$BASE_URL/api/settings/thinking-budget" -H "Content-Type: application/json" \
  -d "{\"mode\":\"$_THINKING_MODE\",\"baseBudget\":$_THINKING_BUDGET}" | sed 's/^/[init] Thinking HTTP /'

echo "[init] Memory legacy + Skills..."
curl -s -o "$MEMORY_LEGACY_RESP_FILE" -w "%{http_code}
" -b "$COOKIE_FILE" \
  -X PATCH "$BASE_URL/api/settings" -H "Content-Type: application/json" \
  -d '{"memoryEnabled":true,"memoryStrategy":"hybrid","memoryMaxTokens":2000,"memoryRetentionDays":30,"skillsEnabled":true}' | sed 's/^/[init] Memory legacy HTTP /'

echo "[init] Memory extended (static)..."
curl -s -o "$MEMORY_EXT_RESP_FILE" -w "%{http_code}
" -b "$COOKIE_FILE" \
  -X PUT "$BASE_URL/api/settings/memory" -H "Content-Type: application/json" \
  -d '{"embeddingSource":"static","staticEnabled":true,"transformersEnabled":false}' | sed 's/^/[init] Memory extended HTTP /'

echo "[init] Resetting circuit breakers (first-init clean start)..."
curl -s -o /dev/null -w "[init] CB reset HTTP %{http_code}
" -b "$COOKIE_FILE" \
  -X POST "$BASE_URL/api/resilience/reset" -H "Content-Type: application/json"

echo "[init] per-model 32K override (real_context=$_NIM_REAL_CONTEXT)..."
OVERRIDE_APPLIED=0; OVERRIDE_SKIPPED=0
apply_context_override() {
  if sqlite3 "$_DB_PATH" \
    "INSERT OR REPLACE INTO model_context_overrides (provider, model_id, real_context, source, refreshed_at)
     VALUES ('nvidia', '$(sql_escape "$1")', $2, 'manual', datetime('now'));" 2>/dev/null; then
    OVERRIDE_APPLIED=$((OVERRIDE_APPLIED+1))
  else OVERRIDE_SKIPPED=$((OVERRIDE_SKIPPED+1)); echo "[init]   override FAILED: $1"; fi
}
while IFS= read -r _M; do [ -z "$_M" ] && continue; apply_context_override "$_M" "$_NIM_REAL_CONTEXT"; done < <(build_all_models)
echo "[init] override: $OVERRIDE_APPLIED applied, $OVERRIDE_SKIPPED failed."

echo "[init] ─────────────────────────────────────────────"
echo "[init]   PROFILE=$_PROFILE MODE=$NIM_MODE KEYS=$_ALIVE_KEYS RPM=$_RPM BODY=$_REQUEST_BODY_LIMIT_MB MB"
echo "[init]   POOL_STRATEGY=$_POOL_STRATEGY PROBE=${NIM_PROBE:-0} REAL_CONTEXT=$_NIM_REAL_CONTEXT"
echo "[init] ─────────────────────────────────────────────"

hf_snapshot() {
  [ -z "$HF_TOKEN" ] || [ -z "$HF_DATASET_REPO" ] && return 0
  echo "[init] HF Dataset snapshot（配置 + 可选 DEBUG log）..."
  local BACKUP_DIR="/tmp/omni-snapshot"; mkdir -p "$BACKUP_DIR"
  local OR_KEY; OR_KEY="$(resolve_or_key)"
  curl -sf "$BASE_URL/api/settings/export-json" -H "Authorization: Bearer $OR_KEY" \
    | jq 'del(.usageHistory, .domainCostHistory, .domainBudgets) |
          (if (.apiKeys|type)=="array" then .apiKeys |= map(del(.key)) else . end) |
          (if (.providerConnections|type)=="array" then .providerConnections |= map(del(.credentials)) else . end)' \
    > "$BACKUP_DIR/omni_config.json"
  jq '.apiKeys' "$BACKUP_DIR/omni_config.json" > "$BACKUP_DIR/keys.json"
  jq '.providerConnections' "$BACKUP_DIR/omni_config.json" > "$BACKUP_DIR/providerConnections.json"
  jq '.settings' "$BACKUP_DIR/omni_config.json" > "$BACKUP_DIR/settings.json"
  jq '.combos' "$BACKUP_DIR/omni_config.json" > "$BACKUP_DIR/combos.json"

  # ── 【v4.2.3·⑨ 】DEBUG log 上传到 Dataset（debug_<时间戳>.log）──
  #   仅 DEBUG 模式且 INIT_LOG 存在时；默认开启，可用 NIM_DEBUG_LOG_TO_DATASET=0 关闭。
  #   同时本地只保留最近 NIM_DEBUG_LOG_KEEP(默认5) 个，避免 /data 与 Dataset 无限堆积。
  if [ "$NIM_MODE" = "DEBUG" ] && [ "${NIM_DEBUG_LOG_TO_DATASET:-1}" = "1" ] && [ -n "$INIT_LOG" ] && [ -f "$INIT_LOG" ]; then
    local _keep=${NIM_DEBUG_LOG_KEEP:-5}
    # 落盘完成前先刷新一次（tee 是行缓冲，通常已写入；这里确保文件存在且非空）
    cp -f "$INIT_LOG" "$BACKUP_DIR/debug_$(basename "$INIT_LOG" | sed 's/^init_//')" 2>/dev/null \
      && echo "[init] snapshot: 附带 DEBUG log -> debug_$(basename "$INIT_LOG" | sed 's/^init_//')" \
      || echo "[init] snapshot: WARN 复制 DEBUG log 失败，跳过。"
    # 本地滚动清理：只保留最近 _keep 个 init_*.log
    if [ -d "$LOG_DIR" ]; then
      ls -1t "$LOG_DIR"/init_*.log 2>/dev/null | tail -n +$(( _keep + 1 )) | xargs -r rm -f 2>/dev/null || true
    fi
  else
    [ "$NIM_MODE" = "DEBUG" ] && echo "[init] snapshot: DEBUG log 上传已禁用（NIM_DEBUG_LOG_TO_DATASET=0）。"
  fi

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

# ── 增量模式（⑧ 增量门放宽：任一 nim-* combo 或 INIT_MARKER 存在）──
if [ -f "$_DB_PATH" ]; then
  COMBO_COUNT=$(sqlite3 "$_DB_PATH" "SELECT COUNT(*) FROM combos WHERE name IN ('nim-pool','nim-codex');" 2>/dev/null || echo 0)
  if [ "${COMBO_COUNT:-0}" -gt 0 ] || [ -f "$INIT_MARKER" ]; then
    echo "[init] Incremental mode."
    purge_proxy_db
    # ⑤ 只清"已过期"熔断，保留仍在冷却窗内的历史信号
    sqlite3 "$_DB_PATH" "DELETE FROM domain_circuit_breakers WHERE cooldown_until < datetime('now');" 2>/dev/null || true
    check_nim_model_health
    nim_probe
    # ⑦ 增量也走幂等 upsert（同时修复 deprecated 与撞名）
    mapfile -t POOL_ALIVE  < <(filter_alive "${NIM_POOL_MODELS[@]}")
    mapfile -t CODEX_ALIVE < <(filter_alive "${NIM_CODEX_MODELS[@]}")
    upsert_combo "nim-pool"  "$_POOL_STRATEGY"  "${POOL_ALIVE[@]}"
    upsert_combo "nim-codex" "$_CODEX_STRATEGY" "${CODEX_ALIVE[@]}"
    nim_health_pick
    hf_snapshot
    echo "[init] Done (incremental). v4.2.3"
    exit 0
  fi
else
  echo "[init] DB not present. First-time init."
fi

check_nim_model_health
nim_probe

echo "[init] Registering models..."
register_model() {
  local MODEL_ID="$1" F="$(_resp omniroute-model-$(echo "$1" | tr '/' '-').json)" C
  C=$(curl -s -o "$F" -w "%{http_code}" -b "$COOKIE_FILE" -X POST "$BASE_URL/api/provider-models" \
    -H "Content-Type: application/json" -d "$(jq -n --arg provider "nvidia" --arg modelId "$MODEL_ID" '{provider:$provider, modelId:$modelId}')")
  if [ "$C" = "200" ] || [ "$C" = "201" ]; then echo "[init] model $MODEL_ID OK"
  elif [ "$C" = "409" ]; then echo "[init] model $MODEL_ID exists"
  else echo "[init] model $MODEL_ID WARN $C"; cat "$F" || true; fi
}
while IFS= read -r _M; do [ -z "$_M" ] && continue; register_model "$_M"; done < <(build_all_models | { grep -Fxvf /tmp/nim-deprecated.txt || true; })
echo "[init] Model registration done."

mapfile -t POOL_ALIVE  < <(filter_alive "${NIM_POOL_MODELS[@]}")
mapfile -t CODEX_ALIVE < <(filter_alive "${NIM_CODEX_MODELS[@]}")

# ⑦ first-init 也走幂等 upsert（根治 R2 restore 后撞名）
upsert_combo "nim-pool"  "$_POOL_STRATEGY"  "${POOL_ALIVE[@]}"
upsert_combo "nim-codex" "$_CODEX_STRATEGY" "${CODEX_ALIVE[@]}"

nim_health_pick
hf_snapshot
purge_proxy_db

touch "$INIT_MARKER"
echo "[init] Final health check..."
HEALTH_FILE="$(_resp omniroute-final-health.json)"
HEALTH_HTTP=$(curl -s -o "$HEALTH_FILE" -w "%{http_code}" "$BASE_URL/api/monitoring/health" 2>/dev/null || echo "000")
[ "$HEALTH_HTTP" = "200" ] && echo "[init]   Status: $(jq -r '.status // "unknown"' "$HEALTH_FILE") / $(jq -r '.version // "unknown"' "$HEALTH_FILE")"
echo "[init] Done (first-init). v4.2.3"
