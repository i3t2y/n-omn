## Dockerfile

```Dockerfile
# 鈹€鈹€ 鍩虹闀滃儚锛氶拤姝?3.8.43 + digest 鍙屽啓锛岀姝㈡诞鍔?latest 鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€
# 鏍瑰洜锛歭atest 浼氭紓鍒版柊鐗堬紙Turbopack 鏋勫缓 + migration 琛ㄩ噸寤猴級锛?
#       瀵艰嚧 Next 鏈嶅姟闈欓粯鏃犳硶 ready锛宔ntrypoint 鍋ュ悍绛夊緟绌鸿浆鍗?starting銆?
FROM diegosouzapw/omniroute:3.8.43@sha256:517c160643c56ad72e3e305458d961c9a4c87f711393c13020450f9f088d1570

ENV OMNIROUTE_PORT=20128
ENV EXPOSED_PORT=7860
ENV DATA_DIR=/data

# 鈹€鈹€ 璺ㄧ増鏈槻寰?env锛?.8.43 鏃犲锛涢槻璇紓鍒版柊鐗堥潤榛?hang锛夆攢鈹€
ENV OMNIROUTE_USE_TURBOPACK=0
ENV OMNIROUTE_MAX_PENDING_MIGRATIONS=0

USER root

RUN apt-get update && apt-get install -y --no-install-recommends \
    curl jq python3 python3-pip sqlite3 ca-certificates \
    && rm -rf /var/lib/apt/lists/*

RUN pip3 install --no-cache-dir --break-system-packages huggingface_hub

ARG LITESTREAM_VERSION=0.5.9
RUN ARCH=$(uname -m | sed 's/aarch64/arm64/') && \
    curl -fsSL \
      "https://github.com/benbjohnson/litestream/releases/download/v${LITESTREAM_VERSION}/litestream-${LITESTREAM_VERSION}-linux-${ARCH}.tar.gz" \
    | tar -xz -C /usr/local/bin litestream && \
    chmod +x /usr/local/bin/litestream && \
    litestream version

RUN mkdir -p /data && chmod 777 /data
RUN rm -rf /app/data && ln -sf /data /app/data

RUN mkdir -p /gate
COPY package.json /gate/package.json
COPY gate.js /gate/gate.js
RUN cd /gate && npm install --omit=dev --silent

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

COPY init-nim-keys.sh /entrypoint-init-nim.sh
RUN chmod +x /entrypoint-init-nim.sh

COPY litestream.yml /litestream.yml

EXPOSE 7860

HEALTHCHECK --interval=30s --timeout=10s --start-period=180s --retries=3 \
    CMD curl -sf http://127.0.0.1:7860/healthz || exit 1

ENTRYPOINT ["/entrypoint.sh"]

```


## entrypoint.sh

```sh
#!/bin/sh
set -e

[ -z "$OMNIROUTE_PORT" ] && OMNIROUTE_PORT=20128
[ -z "$EXPOSED_PORT" ] && EXPOSED_PORT=7860
[ -z "$DATA_DIR" ] && DATA_DIR=/data
[ -z "$CALL_LOGS_TABLE_MAX_ROWS" ] && CALL_LOGS_TABLE_MAX_ROWS=100000
[ -z "$PROXY_LOGS_TABLE_MAX_ROWS" ] && PROXY_LOGS_TABLE_MAX_ROWS=100000

echo "[entrypoint] starting OmniRoute via /app/server.js..."
echo "[entrypoint] OMNIROUTE_PORT=$OMNIROUTE_PORT EXPOSED_PORT=$EXPOSED_PORT DATA_DIR=$DATA_DIR"

# 鈹€鈹€ Litestream restore锛堝惎鍔ㄥ墠鎭㈠ DB锛夆攢鈹€
if [ -n "$R2_ACCESS_KEY_ID" ] && [ -n "$R2_SECRET_ACCESS_KEY" ] && [ -n "$R2_ACCOUNT_ID" ]; then
  echo "[entrypoint] R2 creds found. Litestream restore..."
  litestream restore -config /litestream.yml -if-replica-exists "$DATA_DIR/storage.sqlite" \
    && echo "[entrypoint] restore complete." \
    || echo "[entrypoint] WARN: restore failed or no replica. Continuing."
else
  echo "[entrypoint] WARN: R2 creds not set. Skip restore."
fi

PORT="$OMNIROUTE_PORT" \
DATA_DIR="$DATA_DIR" \
REQUIRE_API_KEY=true \
HOSTNAME=127.0.0.1 \
NIM_MODE="$NIM_MODE" \
NODE_OPTIONS="--max-old-space-size=4096" \
DISABLE_SQLITE_AUTO_BACKUP=true \
PROVIDER_LIMITS_SYNC_INTERVAL_MINUTES=1440 \
CALL_LOGS_TABLE_MAX_ROWS="$CALL_LOGS_TABLE_MAX_ROWS" \
PROXY_LOGS_TABLE_MAX_ROWS="$PROXY_LOGS_TABLE_MAX_ROWS" \
JWT_SECRET="$JWT_SECRET" \
API_KEY_SECRET="$API_KEY_SECRET" \
OMNIROUTE_API_KEY="$OMNIROUTE_API_KEY" \
INITIAL_PASSWORD="$INITIAL_PASSWORD" \
node /app/server.js --log &
OR_PID=$!
echo "[entrypoint] OmniRoute PID=$OR_PID"

echo "[entrypoint] waiting for health (max 180s)..."
i=0
while [ "$i" -lt 180 ]; do
  kill -0 "$OR_PID" 2>/dev/null || { echo "[entrypoint] FATAL: OmniRoute exited early"; exit 1; }
  curl -sf "http://127.0.0.1:$OMNIROUTE_PORT/api/monitoring/health" >/dev/null 2>&1 && { echo "[entrypoint] ready after ${i}s"; break; }
  sleep 2; i=$((i + 2))
done
[ "$i" -ge 180 ] && { echo "[entrypoint] FATAL: not ready within timeout"; exit 1; }

# 鈹€鈹€ 鐗堟湰鎶ゆ爮锛堝彧鍛婅涓嶄腑鏂級鈹€鈹€
EXPECTED_OR_VERSION="${EXPECTED_OR_VERSION:-3.8.43}"
_OR_VER=$(curl -sf "http://127.0.0.1:$OMNIROUTE_PORT/api/monitoring/health" 2>/dev/null | jq -r '.version // "unknown"' 2>/dev/null || echo "unknown")
echo "[entrypoint] base version: $_OR_VER (expected $EXPECTED_OR_VERSION)"
if [ "$_OR_VER" != "$EXPECTED_OR_VERSION" ] && [ "$_OR_VER" != "unknown" ]; then
  echo "[entrypoint] 鈿狅笍 WARN: 鐗堟湰($_OR_VER)涓庢湡鏈?$EXPECTED_OR_VERSION)涓嶄竴鑷粹€斺€旂枒浼?FROM 婕傜Щ銆?
fi

echo "[entrypoint] running NIM init in background..."
bash /entrypoint-init-nim.sh &

if [ -n "$OMNIROUTE_API_KEY" ]; then
  echo "[entrypoint] OMNIROUTE_API_KEY set, env-bypass 妯″紡锛岃烦杩囩瓑寰?.or-api-key銆?
else
  echo "[entrypoint] waiting for OR_API_KEY (max 120s)..."
  j=0
  while [ "$j" -lt 120 ]; do
    [ -f "/data/.or-api-key" ] && [ -s "/data/.or-api-key" ] && { echo "[entrypoint] OR_API_KEY ready"; break; }
    kill -0 "$OR_PID" 2>/dev/null || { echo "[entrypoint] FATAL: OmniRoute exited waiting key"; exit 1; }
    sleep 2; j=$((j + 2))
  done
  [ ! -s "/data/.or-api-key" ] && { echo "[entrypoint] FATAL: OR_API_KEY not created"; exit 1; }
fi

export NODE_OPTIONS="--max-old-space-size=4096"
if [ -n "$R2_ACCESS_KEY_ID" ] && [ -n "$R2_SECRET_ACCESS_KEY" ] && [ -n "$R2_ACCOUNT_ID" ]; then
  echo "[entrypoint] Starting Litestream replication..."
  litestream replicate -config /litestream.yml &
  echo "[entrypoint] Litestream PID=$!"
else
  echo "[entrypoint] WARN: Litestream replication disabled (no R2 creds)."
fi

echo "[entrypoint] starting gate on port $EXPOSED_PORT..."
exec node /gate/gate.js

```


## gate.js

```js
const express = require('express');
const { createProxyMiddleware } = require('http-proxy-middleware');
const fs = require('fs');

const app = express();
const INTERNAL_PSK = process.env.INTERNAL_PSK;
const OR_PORT = parseInt(process.env.OMNIROUTE_PORT || '20128', 10);
const GATE_PORT = parseInt(process.env.EXPOSED_PORT || '7860', 10);

if (!INTERNAL_PSK) {
  console.error('[gate] FATAL: INTERNAL_PSK not set. HF Space Secret 蹇呴』閰嶇疆銆?);
  process.exit(1);
}
let OR_API_KEY = (process.env.OMNIROUTE_API_KEY || '').trim();
if (!OR_API_KEY) {
  try { OR_API_KEY = fs.readFileSync('/data/.or-api-key', 'utf8').trim(); }
  catch (e) { if (e.code !== 'ENOENT') console.error('[gate] WARN read key failed:', e.message); }
}
if (!OR_API_KEY) {
  console.error('[gate] FATAL: No OR_API_KEY (env nor file).');
  process.exit(1);
}

app.get('/healthz', async (req, res) => {
  const r = await fetch(`http://127.0.0.1:${OR_PORT}/api/monitoring/health`).catch(() => null);
  r?.ok ? res.json({ ok: true }) : res.status(503).json({ ok: false });
});

app.use((req, res, next) => {
  if (!req.path.startsWith('/v1')) return next();
  const bearer = (req.headers.authorization || '').replace('Bearer ', '');
  if (bearer !== INTERNAL_PSK) return res.status(401).json({ error: 'unauthorized' });
  req.headers.authorization = `Bearer ${OR_API_KEY}`;
  next();
});

app.use('/', createProxyMiddleware({ target: `http://127.0.0.1:${OR_PORT}`, changeOrigin: true }));
app.listen(GATE_PORT, '0.0.0.0', () => {
  console.log(`[gate] listening on 0.0.0.0:${GATE_PORT} -> 127.0.0.1:${OR_PORT}`);
});

```


## init-nim-keys.sh

```sh
#!/bin/bash
set -eo pipefail

# 鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€
# NIM OmniRoute initializer  v4.2.2锛堝熀浜?v4.2.1锛?# 鐩稿 v4.2.1 鐨勫彉鏇达細
#   銆恦4.2.2路鈶?銆慶ombo 鍒涘缓鏀逛负骞傜瓑 upsert_combo锛堝瓨鍦ㄥ垯 PUT锛屼笉瀛樺湪鎵?POST锛?#              鏍规不 R2 restore 鍚?first-init 瑁?POST 鎾?"Combo name already exists"銆?#   銆恦4.2.2路鈶?銆戝閲忛棬鏀惧锛氫换涓€ nim-* combo 瀛樺湪鎴?INIT_MARKER 瀛樺湪鍗宠蛋澧為噺锛?#              涓嶅啀浠呭嚟 nim-pool锛岄伩鍏嶅崐鎴愬搧鐘舵€佸弽澶嶈蛋 first-init銆?#   缁ф壙 v4.2.1锛氣憼 绉婚櫎 quota-share/涓绘睜 p2c+鐧藉悕鍗?鈶?nim-codex 鍝嶅簲浣撴墦鍗?#              鈶?DEBUG log 涓嶅叆 Dataset 鈶?鍙€夋帰閽?NIM_PROBE
#              鈶?澧為噺鍙竻杩囨湡鐔旀柇 鈶?nim_health_pick 鍒嗘。鎺ㄨ崘銆?# 鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€

# 鈺愨晲 鍗曞彉閲忚皟璇?+ 鏃ュ織褰掓。锛堝彧璧?stdout锛屼笉鎸佷箙鍖栧埌 Dataset锛夆晲鈺愨晲鈺愨晲鈺愨晲
NIM_MODE="${NIM_MODE:-NORMAL}"
LOG_DIR="/data/omni-data/log"
if [ "$NIM_MODE" = "DEBUG" ]; then
  mkdir -p "$LOG_DIR" 2>/dev/null || true
  INIT_LOG="$LOG_DIR/init_$(date +%Y%m%d_%H%M%S).log"
  exec > >(tee -a "$INIT_LOG") 2>&1
  echo "[init] 馃洜锔?NIM_MODE=DEBUG锛氭棩蹇?tee -> $INIT_LOG锛堜粎瀹瑰櫒鍐咃紝闅?Space 鏃ュ織鍙锛屼笉鍏?Dataset锛?
  export APP_LOG_TO_FILE=true
  export DISABLE_SQLITE_AUTO_BACKUP=true
else
  LOG_DIR="/tmp"
fi
_resp() { echo "$LOG_DIR/$1"; }

# 鈹€鈹€ 寮哄埗鍏抽棴浠ｇ悊鐢熸€?鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€
export ONEPROXY_ENABLED=false
export ENABLE_SOCKS5_PROXY=false
export NEXT_PUBLIC_ENABLE_SOCKS5_PROXY=false
unset HTTP_PROXY HTTPS_PROXY ALL_PROXY http_proxy https_proxy all_proxy 2>/dev/null || true
unset OMNIROUTE_RELAY_BACKEND BIFROST_BASE_URL 2>/dev/null || true

# 鈹€鈹€ 绔彛閰嶇疆 鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€
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

# 鈺愨晲 妯″瀷鍒嗘。 SSOT锛堝榻愮幇琛?NVIDIA 鐩綍锛夆晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲
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
echo "[init] NIM_PROFILE=$_PROFILE -> pool 鎰忓悜 ${#NIM_POOL_MODELS[@]} 涓ā鍨?

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
models_to_json() { printf '%s' "$@" | sed 's/^/nvidia\//' | jq -R '{model: .}' | jq -s -c .; }

# 鈺愨晲 combo 绛栫暐鐧藉悕鍗曪紙3.8.43 瀹炴祴鍚堟硶鏋氫妇锛屼笉鍚?quota-share锛夆晲鈺愨晲鈺愨晲
_VALID_STRATS="priority weighted round-robin context-relay fill-first p2c random least-used cost-optimized reset-aware reset-window headroom strict-random auto lkgp context-optimized fusion"
_is_valid_strat() { printf '%s' "$_VALID_STRATS" | grep -qw -- "$1"; }

# 鈺愨晲 銆愨懄 銆戝箓绛?upsert锛氬瓨鍦ㄥ垯 PUT锛屼笉瀛樺湪鎵?POST 鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺?upsert_combo() {
  local NAME="$1" STRAT="$2"; shift 2; local MODELS=("$@")
  _is_valid_strat "$STRAT" || { echo "[init] upsert_combo: '$STRAT' 闈炴硶 -> round-robin"; STRAT="round-robin"; }
  [ "${#MODELS[@]}" -eq 0 ] && { echo "[init] upsert_combo: $NAME 鏃犲瓨娲绘ā鍨嬶紝璺宠繃銆?; return 0; }
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

# 鈺愨晲 鎸夊瓨娲?Key 鏁板姩鎬佹帹瀵?RPM/骞跺彂 鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺?_count_alive_keys() { printf '%s
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
_is_valid_strat "$_POOL_STRATEGY" || { echo "[init] WARN: pool strategy '$_POOL_STRATEGY' 闈炴硶锛屽洖閫€ round-robin"; _POOL_STRATEGY="round-robin"; }
_CODEX_STRATEGY="${NIM_CODEX_STRATEGY:-round-robin}"
_is_valid_strat "$_CODEX_STRATEGY" || { echo "[init] WARN: codex strategy '$_CODEX_STRATEGY' 闈炴硶锛屽洖閫€ round-robin"; _CODEX_STRATEGY="round-robin"; }
_FALLBACK_STRATEGY="round-robin"
_STICKY_LIMIT=1
_COMPRESS_THRESHOLD=${NIM_COMPRESS_THRESHOLD:-12000}
_COMPRESS_MODE="stacked"
_THINKING_MODE="adaptive"
_THINKING_BUDGET=8000
_NIM_REAL_CONTEXT=${CONTEXT_LENGTH_DEFAULT:-32768}
echo "[init] pool strategy=$_POOL_STRATEGY | codex strategy=$_CODEX_STRATEGY"

# 鈹€鈹€ body limit 褰掍竴 鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€
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
    if [ -n "${!v}" ]; then echo "[init] 鈿狅笍 DANGER: env $v=${!v} 宸茶缃€?; _hit=1; fi
  done
  [ "$_hit" = "0" ] && echo "[init] check_dangerous_env: clean銆?
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
      echo "[init] purge: 娉ㄥ唽琛ㄦ棤 ${_PROXY_RELAY_HOST}:${_PROXY_RELAY_PORT}銆?
    fi
  else
    echo "[init] purge: 绠＄悊 API 鏆備笉鍙敤锛岃蛋 SQL 鍏滃簳銆?
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
    echo "[init] purge: registry=$_reg assignments=$_asg proxy_enabled=1鍓╀綑=$_proxy_on锛堟湡鏈?0/0/0锛夈€?
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
  [ "${_model_count:-0}" -lt 5 ] && { echo "[init] only $_model_count models, skip 杩囨护"; return 0; }
  while IFS= read -r model; do
    [ -z "$model" ] && continue
    if ! printf '%s' "$_models_json" | jq -e --arg m "$model" 'any(.data[]?.id == $m; .)' >/dev/null 2>&1; then
      echo "[init]   $model 鈥?DEPRECATED锛圢VIDIA 鐩綍鏃狅級"; echo "$model" >> /tmp/nim-deprecated.txt
    else
      [ "$NIM_MODE" = "DEBUG" ] && echo "[init]   $model 鈥?available"
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

# 鈺愨晲 銆愨懀 銆戣交閲忔帰閽堬細榛樿鍏抽棴锛汵IM_PROBE=1 鎵嶈窇 鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺?nim_probe() {
  [ "${NIM_PROBE:-0}" != "1" ] && { echo "[init] nim_probe: disabled (set NIM_PROBE=1 to enable)."; return 0; }
  echo "[init] nim_probe: enabled 鈥?姣忔ā鍨嬫瘡灏忔椂闄愰 + 璺?key 杞崲 (max_tokens=1)"
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
      echo "[init]   probe skip $m锛?h 鍐呭凡鎺級"; continue
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

# 鈺愨晲 銆愨懃 銆戝惎鍔ㄥ仴搴锋墦鍒嗛€夊瀷锛氳鏈湴 call_logs锛屽垎妗ｈ緭鍑烘帹鑽?鈺愨晲鈺愨晲鈺愨晲鈺?nim_health_pick() {
  echo "[init] nim_health_pick: 璇昏繎1h鏈湴 call_logs 鎵撳垎锛堥浂澶栭儴璇锋眰锛?.."
  [ ! -f "$_DB_PATH" ] && { echo "[init]   no DB, skip pick."; return 0; }
  local _has_tbl
  _has_tbl=$(sqlite3 "$_DB_PATH" "SELECT name FROM sqlite_master WHERE type='table' AND name='call_logs';" 2>/dev/null || echo "")
  [ -z "$_has_tbl" ] && echo "[init]   call_logs 琛ㄤ笉瀛樺湪锛堝皻鏃犳祦閲忥級锛屾湰娆℃寜榛樿鍒嗘。鎺ㄨ崘銆?

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
        [ -z "$best" ] && best="$m (鏃犲巻鍙叉暟鎹? 榛樿妗ｄ綅棣栭€?"
        continue
      fi
      ok="${sc%%|*}"; ms=$(echo "$sc" | cut -d'|' -f2); n=$(echo "$sc" | cut -d'|' -f3)
      if [ "${ok:-0}" -gt "$best_ok" ] 2>/dev/null || \
         { [ "${ok:-0}" -eq "$best_ok" ] 2>/dev/null && [ "${ms:-999999}" -lt "$best_ms" ] 2>/dev/null; }; then
        best_ok=$ok; best_ms=$ms; best="$m (ok ${ok}%, ${ms}ms, n=${n})"
      fi
    done
    [ -z "$best" ] && best="锛堟棤瀛樻椿鍊欓€夛級"
    echo "$best"
  }

  local PICK_CODE PICK_FAST PICK_GEN
  PICK_CODE=$(_pick_from "${NIM_CODEX_MODELS[@]}")
  PICK_FAST=$(_pick_from "${NIM_FAST_MODELS[@]}")
  PICK_GEN=$(_pick_from "${NIM_POOL_MODELS[@]}")

  echo "[init] 鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲 鏈鎺ㄨ崘涓诲姏锛堟寜鍒嗘。锛夆晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺?
  echo "[init]   馃 馃捇 缂栫▼/澶嶆潅鎺ㄧ悊 : $PICK_CODE"
  echo "[init]   鈿?浣庡欢杩?鏃ュ父蹇瓟 : $PICK_FAST"
  echo "[init]   馃幆 缁煎悎鍧囪　棣栭€?  : $PICK_GEN"
  echo "[init] 鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€"
  echo "[init]   鐩磋皟绀轰緥锛歮odel = nvidia/${PICK_CODE%% *}"
  echo "[init] 鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺?
}

# 鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲
echo "[init] Starting NIM OmniRoute initializer v4.2.2 (profile=$_PROFILE, mode=$NIM_MODE)..."
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
[ "$SETTINGS_CODE" != "200" ] && [ "$SETTINGS_CODE" != "201" ] && { echo "[init] 鈿狅笍 Settings 闈?2xx锛?; cat "$SETTINGS_RESP_FILE" || true; }

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

echo "[init] 鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€"
echo "[init]   PROFILE=$_PROFILE MODE=$NIM_MODE KEYS=$_ALIVE_KEYS RPM=$_RPM BODY=$_REQUEST_BODY_LIMIT_MB MB"
echo "[init]   POOL_STRATEGY=$_POOL_STRATEGY PROBE=${NIM_PROBE:-0} REAL_CONTEXT=$_NIM_REAL_CONTEXT"
echo "[init] 鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€"

hf_snapshot() {
  [ -z "$HF_TOKEN" ] || [ -z "$HF_DATASET_REPO" ] && return 0
  echo "[init] HF Dataset snapshot锛堥厤缃?+ 鍙€?DEBUG log锛?.."
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

  # 鈹€鈹€ 銆恦4.2.3路鈶?銆慏EBUG log 涓婁紶鍒?Dataset锛坉ebug_<鏃堕棿鎴?.log锛夆攢鈹€
  #   浠?DEBUG 妯″紡涓?INIT_LOG 瀛樺湪鏃讹紱榛樿寮€鍚紝鍙敤 NIM_DEBUG_LOG_TO_DATASET=0 鍏抽棴銆?  #   鍚屾椂鏈湴鍙繚鐣欐渶杩?NIM_DEBUG_LOG_KEEP(榛樿5) 涓紝閬垮厤 /data 涓?Dataset 鏃犻檺鍫嗙Н銆?  if [ "$NIM_MODE" = "DEBUG" ] && [ "${NIM_DEBUG_LOG_TO_DATASET:-1}" = "1" ] && [ -n "$INIT_LOG" ] && [ -f "$INIT_LOG" ]; then
    local _keep=${NIM_DEBUG_LOG_KEEP:-5}
    # 钀界洏瀹屾垚鍓嶅厛鍒锋柊涓€娆★紙tee 鏄缂撳啿锛岄€氬父宸插啓鍏ワ紱杩欓噷纭繚鏂囦欢瀛樺湪涓旈潪绌猴級
    cp -f "$INIT_LOG" "$BACKUP_DIR/debug_$(basename "$INIT_LOG" | sed 's/^init_//')" 2>/dev/null \
      && echo "[init] snapshot: 闄勫甫 DEBUG log -> debug_$(basename "$INIT_LOG" | sed 's/^init_//')" \
      || echo "[init] snapshot: WARN 澶嶅埗 DEBUG log 澶辫触锛岃烦杩囥€?
    # 鏈湴婊氬姩娓呯悊锛氬彧淇濈暀鏈€杩?_keep 涓?init_*.log
    if [ -d "$LOG_DIR" ]; then
      ls -1t "$LOG_DIR"/init_*.log 2>/dev/null | tail -n +$(( _keep + 1 )) | xargs -r rm -f 2>/dev/null || true
    fi
  else
    [ "$NIM_MODE" = "DEBUG" ] && echo "[init] snapshot: DEBUG log 涓婁紶宸茬鐢紙NIM_DEBUG_LOG_TO_DATASET=0锛夈€?
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

# 鈹€鈹€ 澧為噺妯″紡锛堚懅 澧為噺闂ㄦ斁瀹斤細浠讳竴 nim-* combo 鎴?INIT_MARKER 瀛樺湪锛夆攢鈹€
if [ -f "$_DB_PATH" ]; then
  COMBO_COUNT=$(sqlite3 "$_DB_PATH" "SELECT COUNT(*) FROM combos WHERE name IN ('nim-pool','nim-codex');" 2>/dev/null || echo 0)
  if [ "${COMBO_COUNT:-0}" -gt 0 ] || [ -f "$INIT_MARKER" ]; then
    echo "[init] Incremental mode."
    purge_proxy_db
    # 鈶?鍙竻"宸茶繃鏈?鐔旀柇锛屼繚鐣欎粛鍦ㄥ喎鍗寸獥鍐呯殑鍘嗗彶淇″彿
    sqlite3 "$_DB_PATH" "DELETE FROM domain_circuit_breakers WHERE cooldown_until < datetime('now');" 2>/dev/null || true
    check_nim_model_health
    nim_probe
    # 鈶?澧為噺涔熻蛋骞傜瓑 upsert锛堝悓鏃朵慨澶?deprecated 涓庢挒鍚嶏級
    mapfile -t POOL_ALIVE  < <(filter_alive "${NIM_POOL_MODELS[@]}")
    mapfile -t CODEX_ALIVE < <(filter_alive "${NIM_CODEX_MODELS[@]}")
    upsert_combo "nim-pool"  "$_POOL_STRATEGY"  "${POOL_ALIVE[@]}"
    upsert_combo "nim-codex" "$_CODEX_STRATEGY" "${CODEX_ALIVE[@]}"
    nim_health_pick
    hf_snapshot
    echo "[init] Done (incremental). v4.2.2"
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

# 鈶?first-init 涔熻蛋骞傜瓑 upsert锛堟牴娌?R2 restore 鍚庢挒鍚嶏級
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
echo "[init] Done (first-init). v4.2.2"

```


## litestream.yml

```yml
dbs:
  - path: /data/storage.sqlite
    replica:
      type: s3
      bucket: omniroute-data
      path: db/storage.sqlite
      endpoint: https://${R2_ACCOUNT_ID}.r2.cloudflarestorage.com
      access-key-id: ${R2_ACCESS_KEY_ID}
      secret-access-key: ${R2_SECRET_ACCESS_KEY}
      region: auto
      sync-interval: 10s
      auto-recover: true

snapshot:
  interval: 1h
  retention: 24h

```


## package.json

```json
{
  "name": "omniroute-gate",
  "version": "4.2.0",
  "private": true,
  "description": "PSK auth gate in front of OmniRoute (HF Space :7860 -> :20128)",
  "main": "gate.js",
  "engines": {
    "node": ">=22.0.0"
  },
  "scripts": {
    "start": "node gate.js"
  },
  "dependencies": {
    "express": "^4.21.2",
    "http-proxy-middleware": "^3.0.3"
  }
}

```


