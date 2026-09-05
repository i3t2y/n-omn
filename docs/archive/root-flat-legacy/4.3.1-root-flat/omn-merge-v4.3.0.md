# OmniRoute Project Merge - v4.3.0

## Dockerfile

```dockerfile
# 锁定生产验证过的 3.8.43 版本
FROM diegosouzapw/omniroute:3.8.43@sha256:517c160643c56ad72e3e305458d961c9a4c87f711393c13020450f9f088d1570

ENV OMNIROUTE_PORT=20128
ENV EXPOSED_PORT=7860
ENV DATA_DIR=/data

# 基础工具安装
USER root
RUN apt-get update && apt-get install -y --no-install-recommends \
    curl jq python3 python3-pip sqlite3 ca-certificates util-linux \
    && rm -rf /var/lib/apt/lists/*

RUN pip3 install --no-cache-dir --break-system-packages huggingface_hub

# Litestream v0.5.9 安装
ARG LITESTREAM_VERSION=0.5.9
RUN ARCH=$(uname -m | sed 's/aarch64/arm64/') && \
    curl -fsSL "https://github.com/benbjohnson/litestream/releases/download/v${LITESTREAM_VERSION}/litestream-${LITESTREAM_VERSION}-linux-${ARCH}.tar.gz" \
    | tar -xz -C /usr/local/bin litestream && \
    chmod +x /usr/local/bin/litestream

RUN mkdir -p /data && chmod 777 /data
RUN rm -rf /app/data && ln -sf /data /app/data

# 部署 gate.js (原生 HTTP 模块，零依赖)
RUN mkdir -p /gate
COPY gate.js /gate/gate.js

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh
COPY init-nim-keys.sh /entrypoint-init-nim.sh
RUN chmod +x /entrypoint-init-nim.sh
COPY litestream.yml /litestream.yml

EXPOSE 7860
ENTRYPOINT ["/entrypoint.sh"]

```

## entrypoint.sh

```sh
#!/bin/sh
set -e

DB="/data/storage.sqlite"
LOCK_FILE="/data/.entrypoint.lock"

_shutdown() {
  echo "[entrypoint] shutting down..."
  kill -TERM "$OR_PID" "$LS_PID" "$GATE_PID" 2>/dev/null || true
  exit 0
}
trap '_shutdown' TERM INT

exec 9>"$LOCK_FILE"
flock -n 9 || { echo "[entrypoint] FATAL: another instance running"; exit 1; }

# ── R2 配置完整性校验 (修复 bucket required 报错) ──
R2_READY=0
if [ -n "$R2_ACCOUNT_ID" ] && [ -n "$R2_BUCKET" ] \
   && [ -n "$R2_ACCESS_KEY_ID" ] && [ -n "$R2_SECRET_ACCESS_KEY" ]; then
  R2_READY=1
else
  echo "[entrypoint] WARN: R2 config incomplete -> running in LOCAL-ONLY mode (no backup/restore)."
fi

# ── R2 恢复 (仅在配置齐全且本地无库时) ──
if [ "$R2_READY" = 1 ] && [ ! -s "$DB" ]; then
  echo "[entrypoint] restoring from R2..."
  litestream restore -config /litestream.yml -if-replica-exists "$DB" || true
fi

# ═══════════════════════════════════════════════════════════════
# 【核心修复·已验证有效】启动前禁用代理生态 (根治 20129)
# ═══════════════════════════════════════════════════════════════
export ENABLE_SOCKS5_PROXY=false
export ONEPROXY_ENABLED=false
export NEXT_PUBLIC_ENABLE_SOCKS5_PROXY=false
unset OMNIROUTE_RELAY_BACKEND BIFROST_BASE_URL HTTP_PROXY HTTPS_PROXY ALL_PROXY 2>/dev/null || true

if [ -f "$DB" ]; then
  echo "[entrypoint] pre-purging proxy settings from DB..."
  sqlite3 "$DB" "UPDATE settings SET value='false' WHERE key='proxyEnabled';" 2>/dev/null || true
  sqlite3 "$DB" "UPDATE provider_connections SET proxy_enabled=0;" 2>/dev/null || true
  sqlite3 "$DB" "DELETE FROM proxy_registry;" 2>/dev/null || true
  sqlite3 "$DB" "PRAGMA wal_checkpoint(TRUNCATE);" 2>/dev/null || true
fi
# ═══════════════════════════════════════════════════════════════

# ── R2 复制 (仅在配置齐全时) ──
[ "$R2_READY" = 1 ] && { litestream replicate -config /litestream.yml & LS_PID=$!; }

echo "[entrypoint] starting OmniRoute..."
PORT="${OMNIROUTE_PORT:-20128}" DATA_DIR="/data" REQUIRE_API_KEY=true \
INITIAL_PASSWORD="$INITIAL_PASSWORD" NODE_OPTIONS="--max-old-space-size=3072" \
DISABLE_SQLITE_AUTO_BACKUP=true PROVIDER_LIMITS_SYNC_INTERVAL_MINUTES=1440 \
node /app/server.js --log &
OR_PID=$!

# ── 等待就绪 (拉长至 120s，日志实测冷启动含 109 迁移较慢) ──
i=0
while [ "$i" -lt 120 ]; do
  kill -0 "$OR_PID" 2>/dev/null || { echo "[entrypoint] FATAL: OR exited early"; _shutdown; }
  curl -sf "http://127.0.0.1:${OMNIROUTE_PORT:-20128}/api/monitoring/health" >/dev/null && break
  sleep 2; i=$((i+2))
done
echo "[entrypoint] OmniRoute ready (waited ${i}s)."

# ── NIM 注册 (现在会真正写入 connections) ──
bash /entrypoint-init-nim.sh &

node /gate/gate.js &
GATE_PID=$!

while sleep 5; do
  kill -0 "$OR_PID" "$GATE_PID" 2>/dev/null || _shutdown
done

```

## gate.js

```js
'use strict';
const http = require('http');
const crypto = require('crypto');
const fs = require('fs');

const INTERNAL_PSK = process.env.INTERNAL_PSK || '';
const OR_PORT = parseInt(process.env.OMNIROUTE_PORT || '20128', 10);
const GATE_PORT = parseInt(process.env.EXPOSED_PORT || '7860', 10);

if (!INTERNAL_PSK || INTERNAL_PSK.length < 16) {
  console.error('[gate] FATAL: INTERNAL_PSK missing or too short.');
  process.exit(1);
}

// 自动获取 OmniRoute 管理 Key
let OR_API_KEY = (process.env.OMNIROUTE_API_KEY || '').trim();
if (!OR_API_KEY) {
  try { OR_API_KEY = fs.readFileSync('/data/.or-api-key', 'utf8').trim(); }
  catch (e) { }
}

function safeEqual(a, b) {
  if (!a || !b) return false;
  const ba = Buffer.from(a), bb = Buffer.from(b);
  return ba.length === bb.length && crypto.timingSafeEqual(ba, bb);
}

const server = http.createServer((req, res) => {
  const url = req.url.split('?')[0];

  // 健康检查转发
  if (req.method === 'GET' && url === '/healthz') {
    const hc = http.request({ host: '127.0.0.1', port: OR_PORT, path: '/api/monitoring/health', timeout: 2000 }, (up) => {
      res.writeHead(up.statusCode === 200 ? 200 : 503, { 'Content-Type': 'application/json' });
      res.end('{"ok":true}');
      up.resume();
    });
    hc.on('error', () => { res.writeHead(503).end('{"ok":false}'); });
    hc.end(); return;
  }

  // OpenAI API 转发
  if (url.startsWith('/v1')) {
    const bearer = (req.headers['authorization'] || '').replace('Bearer ', '');
    if (!safeEqual(bearer, INTERNAL_PSK)) {
      res.writeHead(401).end('{"error":"unauthorized"}'); return;
    }
    
    const headers = { ...req.headers, host: `127.0.0.1:${OR_PORT}`, authorization: `Bearer ${OR_API_KEY}` };
    const proxyReq = http.request({ host: '127.0.0.1', port: OR_PORT, path: req.url, method: req.method, headers }, (up) => {
      res.writeHead(up.statusCode || 502, up.headers);
      up.pipe(res);
    });
    proxyReq.on('error', (err) => {
      if (!res.headersSent) res.writeHead(502).end('{"error":"bad_gateway"}');
    });
    req.pipe(proxyReq); return;
  }

  res.writeHead(404).end();
});

server.timeout = 0; // 支持长连接 SSE
server.listen(GATE_PORT, '0.0.0.0', () => console.log(`[gate] listening on ${GATE_PORT}`));

```

## init-nim-keys.sh

```sh
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

```

## litestream.yml

```yaml
# litestream.yml — Cloudflare R2 (S3-compatible, 需显式 endpoint)
dbs:
  - path: /data/storage.sqlite
    monitor-interval: 1s
    checkpoint-interval: 1m
    replicas:
      - type: s3
        bucket: ${R2_BUCKET}
        path: omniroute-v3
        endpoint: https://${R2_ACCOUNT_ID}.r2.cloudflarestorage.com
        region: auto
        access-key-id: ${R2_ACCESS_KEY_ID}
        secret-access-key: ${R2_SECRET_ACCESS_KEY}
        force-path-style: true

```

## package.json

```json
{
  "name": "omniroute-gate",
  "version": "4.3.0",
  "private": true,
  "description": "PSK (INTERNAL_PSK for /v1) + admin-token (GATE_ADMIN_TOKEN via Basic Auth for admin UI) gate in front of OmniRoute (HF Space :7860 -> :20128)",
  "main": "gate.js",
  "engines": {
    "node": ">=22.0.0"
  },
  "scripts": {
    "start": "node gate.js"
  },
  "dependencies": {
    "express": "^4.21.2"
  }
}

```

## README.md

```md
---
title: Omn
emoji: 🚀
colorFrom: blue
colorTo: indigo
sdk: docker
pinned: false
license: mit
app_port: 7860
---
```

