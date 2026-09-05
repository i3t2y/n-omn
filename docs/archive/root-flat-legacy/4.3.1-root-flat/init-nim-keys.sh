#!/bin/bash
set -eo pipefail

# ══════════════════════════════════════════════════════════════
# 0. 基础配置
# ══════════════════════════════════════════════════════════════
OR_BASE="http://127.0.0.1:${OMNIROUTE_PORT:-20128}"
NIM_UPSTREAM="https://integrate.api.nvidia.com/v1"
COOKIE_JAR="$(mktemp)"
trap 'rm -f "$COOKIE_JAR"' EXIT

# 限流决策：默认保守 (28 RPM / 1 并发)，防止 NIM 429
_ALIVE_KEYS=$(printf '%s\n' "$NIM_KEYS" | sed '/^[[:space:]]*$/d' | wc -l | tr -d ' ')
if [ "$_ALIVE_KEYS" -eq 0 ]; then
  echo "[init] FATAL: NIM_KEYS is empty. Set it in Space Secrets (newline-separated)."
  exit 0   # 不阻塞主进程，仅跳过注册
fi
if [ "${NIM_SCALE_WITH_KEYS:-0}" = "1" ]; then
  _RPM=$(( _ALIVE_KEYS * 35 )); [ "$_RPM" -gt 300 ] && _RPM=300
  _CONCURRENT=$(( _ALIVE_KEYS * 3 ))
else
  _RPM=${NIM_FREE_RPM:-28}
  _CONCURRENT=${NIM_FREE_CONCURRENT:-1}
fi
echo "[init] keys=$_ALIVE_KEYS mode=$([ "${NIM_SCALE_WITH_KEYS:-0}" = 1 ] && echo SCALE || echo CONSERVATIVE) RPM=$_RPM concurrent=$_CONCURRENT"

# ══════════════════════════════════════════════════════════════
# 1. 登录获取会话 (使用 INITIAL_PASSWORD)
# ══════════════════════════════════════════════════════════════
echo "[init] authenticating to OmniRoute admin..."
_login_code=$(curl -s -o /dev/null -w "%{http_code}" -c "$COOKIE_JAR" \
  -X POST "$OR_BASE/api/auth/login" \
  -H "Content-Type: application/json" \
  -d "{\"password\":\"${INITIAL_PASSWORD}\"}" || echo "000")

if [ "$_login_code" != "200" ]; then
  echo "[init] WARN: login returned HTTP $_login_code (trying cookie-less mode)"
fi

# 统一的认证请求封装 (带 cookie)
or_api() {
  local method="$1" path="$2" body="$3"
  if [ -n "$body" ]; then
    curl -s -b "$COOKIE_JAR" -X "$method" "$OR_BASE$path" \
      -H "Content-Type: application/json" -d "$body"
  else
    curl -s -b "$COOKIE_JAR" -X "$method" "$OR_BASE$path"
  fi
}

# ══════════════════════════════════════════════════════════════
# 2. 定位或创建 NVIDIA NIM provider
# ══════════════════════════════════════════════════════════════
echo "[init] resolving nvidia provider id..."
_providers=$(or_api GET "/api/providers" "")
_nvidia_id=$(printf '%s' "$_providers" | jq -r '
  (.providers // .data // .)[]?
  | select((.type//.slug//.name|ascii_downcase) | test("nvidia|nim"))
  | .id' 2>/dev/null | head -n1)

if [ -z "$_nvidia_id" ] || [ "$_nvidia_id" = "null" ]; then
  echo "[init] nvidia provider not found, creating..."
  _create=$(or_api POST "/api/providers" \
    "{\"type\":\"nvidia\",\"name\":\"NVIDIA NIM\",\"baseUrl\":\"$NIM_UPSTREAM\",\"enabled\":true}")
  _nvidia_id=$(printf '%s' "$_create" | jq -r '.id // .provider.id // empty')
fi

if [ -z "$_nvidia_id" ]; then
  echo "[init] FATAL: could not resolve nvidia provider id. Response was:"
  printf '%s\n' "$_providers" | head -c 500
  exit 0
fi
echo "[init] nvidia provider id = $_nvidia_id"

# ══════════════════════════════════════════════════════════════
# 3. 逐个注册 Key 为独立 connection (含限流整形)
# ══════════════════════════════════════════════════════════════
_idx=0
_MIN_INTERVAL_MS=$(( 60000 / (_RPM > 0 ? _RPM : 1) ))
printf '%s\n' "$NIM_KEYS" | sed '/^[[:space:]]*$/d' | while IFS= read -r _key; do
  _idx=$((_idx+1))
  _key_trim=$(printf '%s' "$_key" | xargs)
  [ -z "$_key_trim" ] && continue

  _payload=$(jq -n \
    --arg name "nim-key-$_idx" \
    --arg apiKey "$_key_trim" \
    --argjson rpm "$_RPM" \
    --argjson conc "$_CONCURRENT" \
    --argjson interval "$_MIN_INTERVAL_MS" \
    '{
       name: $name,
       apiKey: $apiKey,
       enabled: true,
       maxConcurrent: $conc,
       rateLimit: { rpm: $rpm, minIntervalMs: $interval }
     }')

  _resp_code=$(curl -s -o /dev/null -w "%{http_code}" -b "$COOKIE_JAR" \
    -X POST "$OR_BASE/api/providers/$_nvidia_id/connections" \
    -H "Content-Type: application/json" -d "$_payload" || echo "000")

  # 兼容旧路由：部分版本 connection 挂在 provider-nodes 下
  if [ "$_resp_code" != "200" ] && [ "$_resp_code" != "201" ]; then
    _resp_code=$(curl -s -o /dev/null -w "%{http_code}" -b "$COOKIE_JAR" \
      -X POST "$OR_BASE/api/provider-nodes" \
      -H "Content-Type: application/json" \
      -d "$(printf '%s' "$_payload" | jq --arg pid "$_nvidia_id" '. + {providerId:$pid}')" || echo "000")
  fi
  echo "[init] register nim-key-$_idx -> HTTP $_resp_code"
done

# ══════════════════════════════════════════════════════════════
# 4. FIX-3 探针：忽略 000/5xx，仅 4xx 判坏 (仅诊断，不影响注册)
# ══════════════════════════════════════════════════════════════
_first_key=$(printf '%s\n' "$NIM_KEYS" | sed '/^[[:space:]]*$/d' | head -n1 | xargs)
_probe_code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 20 \
  -H "Authorization: Bearer $_first_key" "$NIM_UPSTREAM/chat/completions" \
  -d '{"model":"z-ai/glm-5.2","messages":[{"role":"user","content":"hi"}],"max_tokens":1}' 2>/dev/null || echo "000")
if [ "$_probe_code" -ge 400 ] 2>/dev/null && [ "$_probe_code" -lt 500 ] 2>/dev/null; then
  echo "[init] WARN: NIM upstream probe -> HTTP $_probe_code (key may be invalid/banned)"
else
  echo "[init] NIM upstream probe -> HTTP $_probe_code (ok/ignored)"
fi

# ══════════════════════════════════════════════════════════════
# 5. Resilience 配置 (移除 v4.2.3 曾误用的 useUpstream429BreakerHints)
# ══════════════════════════════════════════════════════════════
or_api PATCH "/api/resilience" \
  '{"requestQueue":{"enabled":true,"maxConcurrent":'"$_CONCURRENT"',"maxQueueSize":100}}' >/dev/null 2>&1 || true

echo "[init] NIM configuration completed: $_ALIVE_KEYS connection(s) registered, RPM=$_RPM."
