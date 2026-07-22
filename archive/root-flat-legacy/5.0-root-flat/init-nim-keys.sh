#!/bin/bash
# ── OmniRoute 3.8.43 终极优化版 · NIM 初始化脚本 v5.0 ───────────────
# 整合 130 条核心优点的最终版本：
#   §1  Cookie login 三重安全网（200/201 + exit 1 + grep auth_token）
#   §2  NIM Keys 幂等注册（409 跳过 + 规范化处理）
#   §3  Resilience 白名单投影（仅 requestQueue，无猜测字段）+ 读回验证
#   §4  FIX-1 Settings 清除（proxyUrl=null/proxyEnabled=false/relayBackend=null）
#   §5  purge_proxy_db 三层清理（API + SQL proxy_registry + SQL settings）
#   §6  模型分档 SSOT（TIER_FAST/STABLE/RESTRICTED + NIM_PROFILE 控制）
#   §7  Combo 幂等 upsert（先查后建/更新 + 策略白名单不含 context-relay）
#   §8  ProxyFetch 三重防御（R2 路径切换 + FIX-1 + purge_proxy_db）
#   §9  Context 管理（apply_context_override + 纯观测不自动回写）
#   §10 保守限流（默认 28/1/2200ms，可切换线性扩容 NIM_SCALE_WITH_KEYS=1）
#   §11 nim_probe 抗抖动（--retry 2 + HTTP 000 不判坏）
#   §12 完整 API 配置链（Resilience → Settings → Compression → Thinking → Memory → CB reset）
#   §13 HF Dataset 快照（字段级脱敏 + best-effort || true 防护）
#   §14 单变量调试 NIM_MODE=DEBUG（tee 日志 + 保留最近 N 份）
#   §15 密码通过环境变量传递（OmniRoute 自处理明文到 bcrypt 迁移）

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
echo "[init] OmniRoute 3.8.43 终极优化版 · NIM 初始化 v5.0"
echo "[init] $(date '+%Y-%m-%d %H:%M:%S')"
echo "=============================================================="

# ════════════════════════════════════════════════════════════════
# §0.1 强制关闭代理生态（undici fetch 不读这些 env，仅防御 http 模块）
# ════════════════════════════════════════════════════════════════
export ONEPROXY_ENABLED=false
export ENABLE_SOCKS5_PROXY=false
export NEXT_PUBLIC_ENABLE_SOCKS5_PROXY=false
unset HTTP_PROXY HTTPS_PROXY ALL_PROXY http_proxy https_proxy all_proxy 2>/dev/null || true
unset OMNIROUTE_RELAY_BACKEND BIFROST_BASE_URL 2>/dev/null || true

# ════════════════════════════════════════════════════════════════
# §0.2 端口配置
# ════════════════════════════════════════════════════════════════
[ -z "$OMNIROUTE_PORT" ] && OMNIROUTE_PORT=20128
BASE_URL="http://127.0.0.1:$OMNIROUTE_PORT"

INIT_MARKER="/data/.init-done"
OR_API_KEY_FILE="/data/.or-api-key"
COOKIE_FILE="/tmp/omniroute-cookie.txt"

# 响应文件
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
  printf '%s\n' "${NIM_POOL_MODELS[@]}" "${NIM_CODEX_MODELS[@]}" "${NIM_EXTRA_MODELS[@]}" | awk '!seen[$0]++'
}

models_to_json() { printf '%s\n' "$@" | sed 's/^/nvidia\//' | jq -R '{model: .}' | jq -s -c .; }

# ════════════════════════════════════════════════════════════════
# §2 combo 策略白名单（删 context-relay：CF-1 红线）
# ════════════════════════════════════════════════════════════════
_VALID_STRATS="priority weighted round-robin fill-first p2c random least-used cost-optimized reset-aware reset-window headroom strict-random auto lkgp context-optimized fusion"
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

# ════════════════════════════════════════════════════════════════
# §3 动态限流（保守默认 28/1/2200ms；可切换线性扩容）
# ════════════════════════════════════════════════════════════════
_count_alive_keys() { printf '%s\n' "$NIM_KEYS" | sed '/^[[:space:]]*$/d' | wc -l; }
_ALIVE_KEYS=$(_count_alive_keys)

if [ "${NIM_SCALE_WITH_KEYS:-0}" = "1" ]; then
  # 线性扩容模式（已弃用，保留兼容）
  _PER_KEY_RPM=${NIM_PER_KEY_RPM:-35}
  _RPM=$(( _ALIVE_KEYS * _PER_KEY_RPM ))
  [ "$_RPM" -lt "$_PER_KEY_RPM" ] && _RPM=$_PER_KEY_RPM
  [ "$_RPM" -gt 300 ] && _RPM=300
  _CONCURRENT=$(( _ALIVE_KEYS * ${NIM_PER_KEY_CONCURRENT:-3} ))
  echo "[init] ⚠ 线性扩容模式（已弃用）：RPM=$_RPM concurrent=$_CONCURRENT"
else
  # 保守整形模式（推荐）
  _RPM=${NIM_RPM_LIMIT:-28}
  _CONCURRENT=${NIM_CONCURRENT_LIMIT:-1}
  _MIN_INTERVAL_MS=${NIM_MIN_INTERVAL_MS:-2200}
fi

[ "$_CONCURRENT" -lt 1 ] && _CONCURRENT=1
[ "$_MIN_INTERVAL_MS" -lt 100 ] && _MIN_INTERVAL_MS=100
[ "$_RPM" -gt 300 ] && _RPM=300

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
_NIM_REAL_CONTEXT=${CONTEXT_LENGTH_DEFAULT:-128000}
echo "[init] pool strategy=$_POOL_STRATEGY | codex strategy=$_CODEX_STRATEGY"

# ════════════════════════════════════════════════════════════════
# §4 body limit 归一
# ════════════════════════════════════════════════════════════════
_RAW_BODY_LIMIT=${NIM_REQUEST_BODY_LIMIT:-4}
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

# ════════════════════════════════════════════════════════════════
# §5 工具函数
# ════════════════════════════════════════════════════════════════
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
    if [ -n "${!v}" ]; then echo "[init] ⚠️ DANGER: env $v=${!v} 已设置。"; _hit=1; fi
  done
  [ "$_hit" = "0" ] && echo "[init] check_dangerous_env: clean。"
}

# ════════════════════════════════════════════════════════════════
# §6 purge_proxy_db（三重防御：API + SQL proxy_registry + SQL settings）
# ════════════════════════════════════════════════════════════════
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
    # SQL 层第一层：清理 proxy_assignments + proxy_registry
    sqlite3 "$_DB_PATH" "DELETE FROM proxy_assignments WHERE proxy_id IN
      (SELECT id FROM proxy_registry WHERE host='$(sql_escape "$_PROXY_RELAY_HOST")' AND port=$_PROXY_RELAY_PORT);" 2>/dev/null || true
    sqlite3 "$_DB_PATH" "UPDATE provider_connections SET proxy_enabled=0 WHERE provider='nvidia';" 2>/dev/null || true
    sqlite3 "$_DB_PATH" "DELETE FROM proxy_registry WHERE host='$(sql_escape "$_PROXY_RELAY_HOST")' AND port=$_PROXY_RELAY_PORT;" 2>/dev/null || true
    # 【FIX-1】SQL 层第二层：清 settings 表全局 proxy/relay（内存 dispatcher 的配置源）
    sqlite3 "$_DB_PATH" "UPDATE settings SET value=json_set(value,'\$.proxyUrl',null,'\$.proxyEnabled',json('false')) WHERE key='runtime' AND json_valid(value) AND json_extract(value,'\$.proxyUrl') IS NOT NULL;" 2>/dev/null || true
    sqlite3 "$_DB_PATH" "UPDATE settings SET value=json_set(value,'\$.relayBackend',null) WHERE key='runtime' AND json_valid(value) AND json_extract(value,'\$.relayBackend') IS NOT NULL;" 2>/dev/null || true
    local _reg _asg _proxy_on
    _reg=$(sqlite3 "$_DB_PATH" "SELECT COUNT(*) FROM proxy_registry;" 2>/dev/null || echo "?")
    _asg=$(sqlite3 "$_DB_PATH" "SELECT COUNT(*) FROM proxy_assignments;" 2>/dev/null || echo "?")
    _proxy_on=$(sqlite3 "$_DB_PATH" "SELECT COUNT(*) FROM provider_connections WHERE provider='nvidia' AND proxy_enabled=1;" 2>/dev/null || echo "?")
    echo "[init] purge: registry=$_reg assignments=$_asg proxy_enabled=1剩余=$_proxy_on（期望 0/0/0）。"
  fi
}

# ════════════════════════════════════════════════════════════════
# §7 check_nim_model_health（查询 NVIDIA 目录过滤已下架模型）
# ════════════════════════════════════════════════════════════════
check_nim_model_health() {
  echo "[init] check_nim_model_health..."
  > /tmp/nim-deprecated.txt
  local _first_key _models_json _model_count
  _first_key=$(printf '%s\n' "$NIM_KEYS" | head -n1)
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
  printf '%s\n' "${out[@]}"
}

# ════════════════════════════════════════════════════════════════
# §8 nim_probe（轻量探针：--retry 2 抗抖动 + HTTP 000 不判坏）
# ════════════════════════════════════════════════════════════════
nim_probe() {
  [ "${NIM_PROBE:-0}" != "1" ] && { echo "[init] nim_probe: disabled (set NIM_PROBE=1 to enable)."; return 0; }
  echo "[init] nim_probe: enabled — 单 key 单次探针 + HTTP 000 忽略"
  local PROBE_DIR="/tmp/nim-probe"; mkdir -p "$PROBE_DIR"
  > /tmp/nim-probe-bad.txt
  local _first_key m _stamp _now _last _code
  _first_key=$(printf '%s\n' "$NIM_KEYS" | head -n1)
  _now=$(date +%s)
  while IFS= read -r m; do
    [ -z "$m" ] && continue
    grep -Fxq "$m" /tmp/nim-deprecated.txt 2>/dev/null && continue
    _stamp="$PROBE_DIR/$(echo "$m" | tr '/' '-').ts"
    _last=$(cat "$_stamp" 2>/dev/null || echo 0)
    if [ $(( _now - _last )) -lt 3600 ]; then
      echo "[init]   probe skip $m（1h 内已探）"; continue
    fi
    _code=$(curl -s -o /dev/null -w "%{http_code}" --retry 2 --retry-delay 1 --max-time 15 \
      -H "Authorization: Bearer ${_first_key}" -H "Content-Type: application/json" \
      "https://integrate.api.nvidia.com/v1/chat/completions" \
      -d "$(jq -n --arg mid "$m" '{model:$mid, max_tokens:1, messages:[{role:"user",content:"hi"}]}')" 2>/dev/null || echo "000")
    echo "[init]   probe $m -> HTTP $_code"
    echo "$_now" > "$_stamp"
    # 仅 4xx 判坏；000/5xx 是临时故障不判
    case "$_code" in
      4[0-9][0-9]) echo "$m" >> /tmp/nim-probe-bad.txt ;;
    esac
    sleep 1
  done < <(build_all_models)
}

# ════════════════════════════════════════════════════════════════
# §9 Context 累积表与观测
# ════════════════════════════════════════════════════════════════
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
  # 从 call_logs 统计最近数据（纯本地 SQLite 查询，零外部请求）
  local _checkpoint_ts _ctx_last_log_ts
  _checkpoint_ts=$(sqlite3 "$_DB_PATH" "SELECT value FROM key_value WHERE namespace='monitor' AND key='context_checkpoint_ts';" 2>/dev/null || echo "")
  _ctx_last_log_ts=$(sqlite3 "$_DB_PATH" "SELECT MAX(created_at) FROM call_logs WHERE created_at > '$_checkpoint_ts';" 2>/dev/null || echo "")

  if [ -z "$_ctx_last_log_ts" ]; then
    echo "[init]   无新 call_logs 数据，跳过累积"
    return 0
  fi

  echo "[init]   checkpoint last_ts=${_checkpoint_ts:-none} -> ctx_last_log_ts=$_ctx_last_log_ts"

  # 更新 checkpoint
  sqlite3 "$_DB_PATH" "INSERT OR REPLACE INTO key_value(namespace,key,value) VALUES('monitor','context_checkpoint_ts','$_ctx_last_log_ts');" 2>/dev/null || true

  # 输出当前推荐（只读不写 model_context_overrides）
  echo "[init] ═══累积 real_context 推荐═══"
  echo "[init]   model | last_ok | first_fail | ok/fail_n | conf | rec_ctx"
  local _row
  while read -r _row; do
    [ -n "$_row" ] && echo "[init]   $_row"
  done < <(sqlite3 "$_DB_PATH" "SELECT model_id || ' | ' ||
    COALESCE(CAST(last_success_tokens AS TEXT),'-') || ' | ' ||
    COALESCE(CAST(first_failure_tokens AS TEXT),'-') || ' | ' ||
    (success_samples||'/'||failure_samples) || ' | ' ||
    COALESCE(confidence,'-') || ' | ' ||
    COALESCE(CAST(recommended_real_context AS TEXT),'-')
    FROM context_recommendations ORDER BY success_samples DESC LIMIT 20;" 2>/dev/null)
  echo "[init] ═══════════════════════════"
}

# ════════════════════════════════════════════════════════════════
# ════════════════════════════════════════════════════════════════
#  ★★★ 主流程开始 ★★★
# ════════════════════════════════════════════════════════════════
# ════════════════════════════════════════════════════════════════

# ── Step 0: 输入校验 ──────────────────────────────────────────
if [ -z "$NIM_KEYS" ]; then
  echo "[init] ✗ FATAL: NIM_KEYS 为空。跳过注册但继续启动（Key 注册是必需的）。"
  exit 0
fi

if [ -z "$INITIAL_PASSWORD" ]; then
  echo "[init] ✗ FATAL: INITIAL_PASSWORD 为空（后续所有 API 调用都需要认证）。"
  exit 1
fi

# ── Step 1: 危险环境变量扫描 ─────────────────────────────────
check_dangerous_env

# ── Step 2: 等待 OmniRoute 就绪 ──────────────────────────────
echo "[init] Waiting for OmniRoute..."
_wait=0
while [ $_wait -lt 60 ]; do
  if curl -sf "$BASE_URL/api/monitoring/health" >/dev/null 2>&1; then
    echo "[init] OmniRoute up (after ${_wait}s)."
    break
  fi
  sleep 2; _wait=$((_wait+2))
done
[ $_wait -ge 60 ] && { echo "[init] ✗ OmniRoute 未在 60s 内就绪"; exit 1; }

# 版本确认
_OR_VER=$(curl -sf "$BASE_URL/api/monitoring/health" | jq -r '.version // "unknown"' 2>/dev/null || echo "unknown")
echo "[init] version: $_OR_VER"

# ── Step 3: Cookie Login（三重安全网）─────────────────────────
# 安全网 ①：接受 HTTP 200 或 201（OmniRoute 可能返回任一）
# 安全网 ②：login 失败时 exit 1 硬失败（防 set -eo pipefail 在 jq 解析 401 时静默退出）
# 安全网 ③：grep -q "auth_token" 验证 cookie 有效
echo "[init] Logging in..."
LOGIN_HTTP=""
LOGIN_HTTP=$(curl -s -o "$LOGIN_RESP_FILE" -w "%{http_code}" -c "$COOKIE_FILE" \
  -X POST "$BASE_URL/api/auth/login" \
  -H "Content-Type: application/json" \
  -d "$(jq -n --arg password "$INITIAL_PASSWORD" '{password:$password}')" 2>/dev/null || echo "000")

if [ "$LOGIN_HTTP" != "200" ] && [ "$LOGIN_HTTP" != "201" ]; then
  echo "[init] ✗ Cookie login 失败: HTTP $LOGIN_HTTP"
  cat "$LOGIN_RESP_FILE" 2>/dev/null || true
  exit 1
fi

if ! grep -q "auth_token" "$COOKIE_FILE" 2>/dev/null; then
  echo "[init] ✗ Cookie login 响应中未找到 auth_token"
  cat "$LOGIN_RESP_FILE" 2>/dev/null || true
  exit 1
fi
echo "[init] Logged in (HTTP $LOGIN_HTTP)."

# ── Step 4: 注册 NIM Keys（幂等，409 跳过）────────────────────
echo "[init] Registering NIM keys..."
mapfile -t _KEYS < <(printf '%s\n' "$NIM_KEYS" | sed '/^[[:space:]]*$/d')
_ki=0 _key= _masked= _kresp= _khttp=
for _key in "${_KEYS[@]}"; do
  [ -z "$_key" ] && continue
  _ki=$((_ki+1))
  _masked="nim-$(printf '%02d' $_ki)"
  _kresp="$(_resp omniroute-provider-${_ki}.json)"
  _khttp=$(curl -s -o "$_kresp" -w "%{http_code}" -b "$COOKIE_FILE" \
    -X POST "$BASE_URL/api/providers" \
    -H "Content-Type: application/json" \
    -d "$(jq -n --arg provider "nvidia" --arg apiKey "$_key" --arg name "$_masked" '{provider:$provider, apiKey:$apiKey, name:$name, priority:1, testStatus:"unknown"}')" 2>/dev/null || echo "000")

  case "$_khttp" in
    200|201) echo "[init] $_masked OK"; REGISTERED=$((REGISTERED+1)) ;;
    409)    echo "[init] $_masked exists"; SKIPPED=$((SKIPPED+1)) ;;
    *)       echo "[init] $_masked FAIL HTTP $_khttp"; FAILED=$((FAILED+1)); cat "$_kresp" 2>/dev/null || true ;;
  esac
done
echo "[init] Keys: $REGISTERED registered, $SKIPPED skipped, $FAILED failed."
[ "$FAILED" -gt 0 ] && { echo "[init] ✗ 有 $FAILED 个 Key 注册失败"; }

# ── Step 5: 获取 Provider IDs ─────────────────────────────────
echo "[init] Fetching provider IDs..."
_prov_json= _prov_count=
_prov_json=$(curl -s -b "$COOKIE_FILE" "$BASE_URL/api/providers" 2>/dev/null || echo "")
_prov_count=$(printf '%s' "$_prov_json" | jq -r '[.providers[]? // .[]? | select(.type=="nim" or .provider=="nvidia")] | length' 2>/dev/null || echo "0")
echo "[init] Provider IDs: $_prov_count"

# ── Step 6: ProxyFetch 三重防御 ───────────────────────────────
purge_proxy_db

# ── Step 7: Resilience 配置（白名单投影 + 读回验证）───────────
echo "[init] Resilience (RPM=$_RPM, concurrent=$_CONCURRENT, interval=${_MIN_INTERVAL_MS}ms)..."

# 输入校验
_res_validate_int "$_RPM" 1 60000 || { echo "[init] ✗ RPM=$_RPM 超出范围 [1,60000]"; exit 1; }
_res_validate_int "$_MIN_INTERVAL_MS" 0 600000 || { echo "[init] ✗ minMs=$_MIN_INTERVAL_MS 超出范围 [0,600000]"; exit 1; }
_res_validate_int "$_CONCURRENT" 1 1000 || { echo "[init] ✗ concurrent=$_CONCURRENT 超出范围 [1,1000]"; exit 1; }

# 白名单投影：仅含 requestQueue 字段（OmniRoute 3.8.43 实测合法）
_RESILIENCE_BODY=$(jq -n \
  --argjson rpm "$_RPM" \
  --argjson minMs "$_MIN_INTERVAL_MS" \
  --argjson conc "$_CONCURRENT" \
  '{requestQueue:{requestsPerMinute:$rpm, minTimeBetweenRequestsMs:$minMs, concurrentRequests:$conc}}')

echo "[init] Resilience PATCH body keys=[requestQueue] (无顶层 useUpstream429BreakerHints)"

_RESILIENCE_CODE=$(curl -s -o "$RESILIENCE_RESP_FILE" -w "%{http_code}" -b "$COOKIE_FILE" \
  -X PATCH "$BASE_URL/api/resilience" \
  -H "Content-Type: application/json" \
  -d "$_RESILIENCE_BODY" 2>/dev/null || echo "000")

if [ "$_RESILIENCE_CODE" != "200" ] && [ "$_RESILIENCE_CODE" != "204" ]; then
  echo "[init] ✗ Resilience PATCH 失败: HTTP $_RESILIENCE_CODE"
  cat "$RESILIENCE_RESP_FILE" 2>/dev/null || true
  # 区分传输错误和 HTTP 错误
  if [ -z "$_RESILIENCE_CODE" ] || [ "$_RESILIENCE_CODE" = "000" ]; then
    echo "[init]   → 传输错误（连接拒绝/超时），非 HTTP 错误"
  else
    echo "[init]   → HTTP 非 2xx 错误"
  fi
else
  echo "[init] Resilience PATCH HTTP $_RESILIENCE_CODE (dur=$(date +%s%3N))"
  # 读回逐字段核对
  _RB_BODY= _RB_RPM= _RB_MINMS= _RB_CONC= _mismatch=
  _RB_BODY=$(curl -s -b "$COOKIE_FILE" "$BASE_URL/api/resilience" 2>/dev/null || echo "{}")
  _RB_RPM=$(printf '%s' "$_RB_BODY" | jq -r '.requestQueue.requestsPerMinute // empty' 2>/dev/null || echo "")
  _RB_MINMS=$(printf '%s' "$_RB_BODY" | jq -r '.requestQueue.minTimeBetweenRequestsMs // empty' 2>/dev/null || echo "")
  _RB_CONC=$(printf '%s' "$_RB_BODY" | jq -r '.requestQueue.concurrentRequests // empty' 2>/dev/null || echo "")
  _mismatch=""
  [ "$_RB_RPM" != "$_RPM" ] && _mismatch="${_mismatch}RPM($_RB_RPM!=${_RPM}) "
  [ "$_RB_MINMS" != "$_MIN_INTERVAL_MS" ] && _mismatch="${_mismatch}minMs($_RB_MINMS!=${_MIN_INTERVAL_MS}) "
  [ "$_RB_CONC" != "$_CONCURRENT" ] && _mismatch="${_mismatch}concurrent($_RB_CONC!=${_CONCURRENT})"
  if [ -n "$_mismatch" ]; then
    echo "[init] ✗ Resilience 读回不一致: $_mismatch"
    exit 1
  else
    echo "[init] ✓ Resilience 读回全字段一致: RPM=$_RPM minMs=$_MIN_INTERVAL_MS concurrent=$_CONCURRENT"
  fi
fi

# ── Step 8: FIX-1 Settings 清除代理 + Routing body limit ─────
echo "[init] Routing + maxBodySizeMb=$_REQUEST_BODY_LIMIT_MB (v5: 清 settings 代理，重置内存 dispatcher)..."

_SETTINGS_BODY=$(jq -n \
  --argjson mb "$_REQUEST_BODY_LIMIT_MB" \
  '{routing:{maxBodySizeMb:$mb}, proxyUrl:null, proxyEnabled:false, relayBackend:null}')

_SETTINGS_CODE=$(curl -s -o "$SETTINGS_RESP_FILE" -w "%{http_code}" -b "$COOKIE_FILE" \
  -X PATCH "$BASE_URL/api/settings" \
  -H "Content-Type: application/json" \
  -d "$_SETTINGS_BODY" 2>/dev/null || echo "000")

if [ "$_SETTINGS_CODE" = "200" ] || [ "$_SETTINGS_CODE" = "204" ]; then
  echo "[init] Settings HTTP $_SETTINGS_CODE"
  # 读回确认 proxyUrl=null
  _settings_rb= _proxy_url_rb=
  _settings_rb=$(curl -s -b "$COOKIE_FILE" "$BASE_URL/api/settings" 2>/dev/null || echo "{}")
  _proxy_url_rb=$(printf '%s' "$_settings_rb" | jq -r '.proxyUrl // "<NOT_SET>"' 2>/dev/null)
  if [ "$_proxy_url_rb" = "null" ] || [ -z "$_proxy_url_rb" ]; then
    echo "[init] ✓ settings 读回: proxyUrl=null（期望 null）"
  else
    echo "[init] ⚠ settings 读回: proxyUrl=$_proxy_url_rb（期望 null，内存 dispatcher 可能仍指向旧代理）"
  fi
else
  echo "[init] ⚠ Settings PATCH HTTP $_SETTINGS_CODE（非致命，purge_proxy_db 已执行 SQL 兜底）"
fi

# ── Step 9: Compression 配置 ──────────────────────────────────
echo "[init] Compression (threshold=$_COMPRESS_THRESHOLD)..."
_COMPRESS_CODE=$(curl -s -o "$COMPRESS_RESP_FILE" -w "%{http_code}" -b "$COOKIE_FILE" \
  -X PUT "$BASE_URL/api/compression" \
  -H "Content-Type: application/json" \
  -d "$(jq -n --arg mode "$_COMPRESS_MODE" --argjson thresh "$_COMPRESS_THRESHOLD" '{mode:$mode, thresholdTokens:$thresh}')" 2>/dev/null || echo "000")
echo "[init] Compression HTTP $_COMPRESS_CODE"

# ── Step 10: Thinking Budget ──────────────────────────────────
echo "[init] Thinking budget..."
_THINK_CODE=$(curl -s -o "$THINKING_RESP_FILE" -w "%{http_code}" -b "$COOKIE_FILE" \
  -X PUT "$BASE_URL/api/thinking-budget" \
  -H "Content-Type: application/json" \
  -d "$(jq -n --arg mode "$_THINKING_MODE" --argjson budget "$_THINKING_BUDGET" '{mode:$mode,budgetTokens:$budget}')" 2>/dev/null || echo "000")
echo "[init] Thinking HTTP $_THINK_CODE"

# ── Step 11: Memory 配置（legacy + extended）───────────────────
echo "[init] Memory legacy + Skills..."
_ML_CODE=$(curl -s -o "$MEMORY_LEGACY_RESP_FILE" -w "%{http_code}" -b "$COOKIE_FILE" \
  -X PATCH "$BASE_URL/api/memory" \
  -H "Content-Type: application/json" \
  -d '{"enabled":true,"mode":"skills"}' 2>/dev/null || echo "000")
echo "[init] Memory legacy HTTP $_ML_CODE"

echo "[init] Memory extended (static)..."
_ME_CODE=$(curl -s -o "$MEMORY_EXT_RESP_FILE" -w "%{http_code}" -b "$COOKIE_FILE" \
  -X PUT "$BASE_URL/api/memory/extended" \
  -H "Content-Type: application/json" \
  -d '{"enabled":true,"mode":"static","staticLimitMb":256}' 2>/dev/null || echo "000")
echo "[init] Memory extended HTTP $_ME_CODE"

# ── Step 12: Circuit Breaker Reset ─────────────────────────────
echo "[init] Resetting circuit breakers..."
_CB_CODE=$(curl -s -o /dev/null -w "%{http_code}" -b "$COOKIE_FILE" \
  -X POST "$BASE_URL/api/circuit-breakers/reset" 2>/dev/null || echo "000")
echo "[init] CB reset HTTP $_CB_CODE"

# ── Step 13: per-model Context Override ─────────────────────────
echo "[init] per-model override (real_context=$_NIM_REAL_CONTEXT)..."
_alive_models= _ov_applied=0 _ov_failed=0 _count=0
_alive_models=$(filter_alive "$(build_all_models)")
_ov_applied=0; _ov_failed=0
_count=0
for _m in $_alive_models; do
  [ -z "$_m" ] && continue
  _count=$((_count+1))
  # 使用 apply_context_override（K5 修复：直接 SQL INSERT OR REPLACE）
  if [ -f "$_DB_PATH" ]; then
    sqlite3 "$_DB_PATH" "INSERT OR REPLACE INTO model_context_overrides (provider, model_id, real_context, source, refreshed_at) VALUES ('nvidia', '$(sql_escape "$_m")', $_NIM_REAL_CONTEXT, 'init', datetime('now'));" 2>/dev/null && _ov_applied=$((_ov_applied+1)) || _ov_failed=$((_ov_failed+1))
  fi
done
echo "[init] override: $_ov_applied applied, $_ov_failed failed."

# ── Step 14: 增量检测 ─────────────────────────────────────────
echo "[init] --------------------------------------------------------"
echo "[init]   PROFILE=$_PROFILE MODE=$NIM_MODE KEYS=$_ALIVE_KEYS RPM=$_RPM BODY=$_REQUEST_BODY_LIMIT_MB MB"
echo "[init]   POOL_STRATEGY=$_POOL_STRATEGY PROBE=${NIM_PROBE:-0} REAL_CONTEXT=$_NIM_REAL_CONTEXT"
echo "[init] --------------------------------------------------------"

# 增量模式判断（SQLite 查询式，摒弃文件标记方案）
_IS_INCREMENTAL=0
if [ -f "$_DB_PATH" ]; then
  _combo_count=
  _combo_count=$(sqlite3 "$_DB_PATH" "SELECT COUNT(*) FROM combos WHERE name IN ('nim-pool','nim-stable','nim-fast','nim-codex');" 2>/dev/null || echo "0")
  [ "$_combo_count" -gt 0 ] && _IS_INCREMENTAL=1
fi

if [ "$_IS_INCREMENTAL" = "1" ]; then
  echo "[init] Incremental mode."
else
  echo "[init] First-init mode."
fi

# ── Step 15: 再次 purge（注册 key 后 proxy_enabled 可能被隐式启用）──
purge_proxy_db

# ── Step 16: 模型健康检查 ─────────────────────────────────────
check_nim_model_health

# ── Step 17: nim_probe（可选探针）────────────────────────────────
nim_probe

# ── Step 18: 创建/更新 Combos ──────────────────────────────────
_pool_models= _codex_models= _fast_models=
_pool_models=$(filter_alive "$(build_all_models)")
_codex_models=$(filter_alive "${NIM_CODEX_MODELS[@]}")
_fast_models=$(filter_alive "${NIM_FAST_MODELS[@]}")

# nim-pool（主力池）
upsert_combo "nim-pool" "$_POOL_STRATEGY" $_pool_models

# nim-codex（代码生成）
upsert_combo "nim-codex" "$_CODEX_STRATEGY" $_codex_models

# nim-fast（快速响应）
upsert_combo "nim-fast" "round-robin" $_fast_models

# nim-stable（稳定长会话）
upsert_combo "nim-stable" "priority" $_pool_models

# ── Step 19: Context 累积观测 ──────────────────────────────────
context_accumulator_update

# ── Step 20: HF Dataset 快照（best-effort，|| true 防护）─────────
_hf_snapshot() {
  [ -z "${HF_DATASET_REPO:-}" ] && { echo "[init] HF_DATASET_REPO 未设置，跳过快照。"; return 0; }
  [ -z "${HF_TOKEN:-}" ] && { echo "[init] HF_TOKEN 未设置，跳过快照。"; return 0; }

  echo "[init] HF Dataset snapshot（配置 + 可选 DEBUG log）..."

  # 导出配置变量（脱敏：不含 API Key 明文、凭据、使用历史）
  local _snapshot_dir _vars_file _commit_msg
  _snapshot_dir="/tmp/hf-snapshot-$(date +%s)"
  mkdir -p "$_snapshot_dir"

  # init_vars.json（环境变量快照，脱敏）
  jq -n \
    --arg profile "$_PROFILE" \
    --argjson rpm "$_RPM" \
    --argjson concurrent "$_CONCURRENT" \
    --argjson interval "$_MIN_INTERVAL_MS" \
    --argjson body_mb "$_REQUEST_BODY_LIMIT_MB" \
    --argjson probe "${NIM_PROBE:-0}" \
    --arg ctx "$_NIM_REAL_CONTEXT" \
    --arg mode "$NIM_MODE" \
    --arg keys "$_ALIVE_KEYS" \
    --arg registered "$REGISTERED" \
    --arg skipped "$SKIPPED" \
    --arg failed "$FAILED" \
    --arg version "$_OR_VER" \
    --arg ts "$(date -Iseconds)" \
    '{profile:$profile,rpm:$rpm,concurrent:$concurrent,intervalMs:$interval,maxBodySizeMb:$body_mb,probe:$probe,realContext:$ctx,mode:$mode,totalKeys:$keys,registered:$registered,skipped:$skipped,failed:$failed,omnirouteVersion:$version,snapshotTs:$ts}' \
    > "$_snapshot_dir/init_vars.json"

  # 可选：上传 DEBUG log（默认关闭）
  if [ "${NIM_DEBUG_LOG_TO_DATASET:-0}" = "1" ] && [ -n "${INIT_LOG:-}" ] && [ -f "$INIT_LOG" ]; then
    cp "$INIT_LOG" "$_snapshot_dir/debug_$(basename "$INIT_LOG")"
    echo "[init] snapshot: 附带 DEBUG log -> debug_$(basename "$INIT_LOG")"
  else
    echo "[init] snapshot: DEBUG log 上传已禁用（默认关, NIM_DEBUG_LOG_TO_DATASET=1 开启）"
  fi

  # 使用 HF Hub API commit（原子操作，无需 git）
  _commit_msg="init v5.0 | $_OR_VER | keys=$_ALIVE_KEYS rpm=$_RPM | $(date -u +%Y-%m-%dT%H:%M:%SZ)"

  local _snap_code
  _snap_code=$(curl -s -o /dev/null -w "%{http_code}" \
    -X POST "https://huggingface.co/api/datasets/$HF_DATASET_REPO/commit/main" \
    -H "Authorization: Bearer $HF_TOKEN" \
    -F "message=$_commit_msg" \
    -F "file=@$_snapshot_dir/init_vars.json" \
    $( [ -f "$_snapshot_dir"/debug_* ] && printf -- '-F "file=@%s"' "$_snapshot_dir"/debug_* ) \
    2>/dev/null || echo "000")

  rm -rf "$_snapshot_dir"

  if [ "$_snap_code" = "200" ] || [ "$_snap_code" = "201" ]; then
    echo "[init] HF Dataset uploaded."
  else
    echo "[init] ⚠ HF Dataset 上传失败: HTTP $_snap_code（非致命）"
  fi
}
_hf_snapshot || true

# ── 完成 ────────────────────────────────────────────────────────
echo "[init] ============================================================"
if [ "$_IS_INCREMENTAL" = "1" ]; then
  echo "[init] Done (incremental). v5.0"
else
  echo "[init] Done (first-init). v5.0"
fi
echo "[init] ============================================================"
