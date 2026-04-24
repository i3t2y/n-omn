#!/bin/bash
set -uo pipefail

INIT_MARKER="/data/.init-done"

echo "[init] Waiting for OmniRoute to start..."
until curl -sf "http://localhost:20128/api/monitoring/health" > /dev/null 2>&1; do
  sleep 3
done
echo "[init] OmniRoute is up."

echo "[init] Logging in..."
LOGIN_BODY='{"password":"'"${INITIAL_PASSWORD}"'"}'
AUTH_TOKEN=$(curl -s -i -X POST "http://localhost:20128/api/auth/login" \
  -H "Content-Type: application/json" \
  -d "${LOGIN_BODY}" \
  | grep -i "set-cookie" \
  | grep -o "auth_token=[^;]*" \
  | head -1 \
  | cut -d= -f2 \
  | tr -d '\r\n')

if [ -z "${AUTH_TOKEN}" ]; then
  echo "[init] ERROR: Login failed, no token received."
  exit 1
fi
echo "[init] Logged in, token acquired."

REGISTERED=0
SKIPPED=0
INDEX=1
while IFS= read -r KEY; do
  [ -z "${KEY}" ] && continue
  NAME="nim-$(printf '%02d' ${INDEX})"
  BODY='{"provider":"nvidia","apiKey":"'"${KEY}"'","name":"'"${NAME}"'"}'
  HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" \
    -X POST "http://localhost:20128/api/providers" \
    -H "Content-Type: application/json" \
    -H "Cookie: auth_token=${AUTH_TOKEN}" \
    -d "${BODY}")
  if [ "${HTTP_CODE}" = "201" ]; then
    echo "[init] ${NAME} registered OK"
    REGISTERED=$((REGISTERED + 1))
  elif [ "${HTTP_CODE}" = "409" ]; then
    SKIPPED=$((SKIPPED + 1))
  else
    echo "[init] ${NAME} unexpected HTTP ${HTTP_CODE}"
  fi
  INDEX=$((INDEX + 1))
done <<< "${NIM_KEYS}"
echo "[init] Keys: ${REGISTERED} registered, ${SKIPPED} skipped."

echo "[init] Applying Resilience config..."
RESILIENCE_CODE=$(curl -s -o /tmp/resilience_resp.json -w "%{http_code}" \
  -X PATCH "http://localhost:20128/api/resilience" \
  -H "Content-Type: application/json" \
  -H "Cookie: auth_token=${AUTH_TOKEN}" \
  -d '{"profiles":{"apikey":{"transientCooldown":90000,"rateLimitCooldown":60000,"maxBackoffLevel":3,"circuitBreakerThreshold":3,"circuitBreakerReset":600000},"oauth":{"transientCooldown":5000,"rateLimitCooldown":60000,"maxBackoffLevel":8,"circuitBreakerThreshold":3,"circuitBreakerReset":60000}},"defaults":{"requestsPerMinute":28,"minTimeBetweenRequests":1,"concurrentRequests":5}}')
echo "[init] Resilience HTTP ${RESILIENCE_CODE}"

if [ -f "${INIT_MARKER}" ]; then
  echo "[init] Already initialized (marker exists). Skipping Combo creation."
  echo "[init] Done (incremental mode)."
  exit 0
fi

echo "[init] First-time init: creating Combo nim-pool..."
COMBO_CODE=$(curl -s -o /dev/null -w "%{http_code}" \
  -X POST "http://localhost:20128/api/combos" \
  -H "Content-Type: application/json" \
  -H "Cookie: auth_token=${AUTH_TOKEN}" \
  -d '{"name":"nim-pool","strategy":"round-robin","providers":["nvidia"]}')
echo "[init] Combo HTTP ${COMBO_CODE}"

touch "${INIT_MARKER}"
echo "[init] Marker written: ${INIT_MARKER}"
echo "[init] Done (first-init mode)."
