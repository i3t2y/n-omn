#!/bin/bash
# OmniRoute NIM 初始化 · 完整自包含版 (K3 v2.0)
# API 路径全部对照官方 Wiki 修正 (https://github.com/diegosouzapw/OmniRoute/wiki/API-Reference)
# 所有管理 API 均经 Cookie 鉴权 (POST /api/auth/login → auth_token)
# 设计: 所有可选配置 (compression/thinking/combos) 先 GET 读结构, 再按读回写; 失败不阻断 Key 注册和推理
set -uo pipefail   # 不用 -e: 单步失败不阻断整体

BASE="http://127.0.0.1:${OMNIROUTE_PORT:-20128}"
COOKIE="/tmp/omni_cookie.txt"
DATA_DIR="${DATA_DIR:-/data}"
DB="$DATA_DIR/storage.sqlite"
REG=0; SKIP=0; FAIL=0

log() { echo "[init] $*"; }

# ── Step 0: 输入校验 ──
[ -n "${NIM_KEYS:-}" ] || { log "FATAL: NIM_KEYS 为空"; exit 1; }
[ -n "${INITIAL_PASSWORD:-}" ] || { log "FATAL: INITIAL_PASSWORD 为空"; exit 1; }

# ── Step 1: 危险环境变量扫描 (代理类变量会劫持出站; 仅打名不打值, http_proxy 常含 user:pass) ──
_proxy_names="$(env | grep -oE '^[a-zA-Z_]+(_proxy|_PROXY)\b' | sort -u)"
if [ -n "$_proxy_names" ]; then
  log "⚠ 检测到代理环境变量 (仅列名字, 值脱敏): $(printf '%s' "$_proxy_names" | tr '\n' ' ')"
  log "  如非预期请从 Secrets 中移除"
else
  log "✓ 无代理环境变量"
fi

# ── Step 2: 等待健康 (entrypoint 已等过, 这里兜底 120s) ──
_DL=$(( $(date +%s) + 120 ))
until curl -sf "$BASE/api/monitoring/health" >/dev/null 2>&1; do
  [ $(date +%s) -ge $_DL ] && { log "FATAL: 健康等待超时"; exit 1; }
  sleep 2
done
log "✓ OmniRoute 健康"

# ── Step 3: 登录 (官方确认: 密码哈希优先, 回退 INITIAL_PASSWORD) ──
_ok=0
for i in 1 2 3; do
  _code=$(curl -s -o /tmp/login.json -w "%{http_code}" -c "$COOKIE" \
    -X POST "$BASE/api/auth/login" -H "Content-Type: application/json" \
    -d "$(jq -n --arg p "$INITIAL_PASSWORD" '{password:$p}')" 2>/dev/null || echo 000)
  if [ "$_code" = "200" ] || [ "$_code" = "201" ]; then
    grep -q auth_token "$COOKIE" 2>/dev/null && { _ok=1; break; }
  fi
  log "登录尝试 $i: HTTP $_code, 3s 后重试"; sleep 3
done
[ "$_ok" = "1" ] || { log "FATAL: 登录失败"; exit 1; }
log "✓ 已登录"

# ── Step 4: 注册 NIM Keys (幂等; 路径与 body 已按官方 Wiki 确认) ──
log "注册 NIM Keys..."
_i=0
while IFS= read -r _key; do
  _key="$(printf '%s' "$_key" | tr -d '[:space:]')"
  [ -z "$_key" ] && continue
  _i=$((_i+1))
  _name="nim-$(printf '%02d' $_i)"
  _code=$(curl -s -o "/tmp/key_$_i.json" -w "%{http_code}" -b "$COOKIE" \
    -X POST "$BASE/api/providers" -H "Content-Type: application/json" \
    -d "$(jq -n --arg provider "nvidia" --arg apiKey "$_key" --arg name "$_name" \
      '{provider:$provider, apiKey:$apiKey, name:$name, priority:1, testStatus:"unknown"}')" 2>/dev/null || echo 000)
  case "$_code" in
    200|201) log "  $_name ✓"; REG=$((REG+1));;
    409)     log "  $_name 已存在, 跳过"; SKIP=$((SKIP+1));;
    *)       log "  $_name ✗ HTTP $_code: $(cat /tmp/key_$_i.json 2>/dev/null | head -c 200)"; FAIL=$((FAIL+1));;
  esac
done <<< "$NIM_KEYS"
log "Keys: $REG 注册 / $SKIP 跳过 / $FAIL 失败"

# ── Step 5: 读回 Provider 列表核对 ──
_cnt=$(curl -sf -b "$COOKIE" "$BASE/api/providers" 2>/dev/null \
  | jq '[.. | objects | select(.provider? == "nvidia")] | length' 2>/dev/null || echo "?")
log "✓ nvidia 连接数 (读回): $_cnt"

# ── Step 6: 清除代理残留 (SQL 兜底, 表名自动探测) ──
if command -v sqlite3 >/dev/null 2>&1 && [ -f "$DB" ]; then
  for _t in $(sqlite3 "$DB" "SELECT name FROM sqlite_master WHERE type='table' AND (name LIKE '%setting%' OR name LIKE '%prox%');" 2>/dev/null); do
    sqlite3 "$DB" "UPDATE \"$_t\" SET value='null' WHERE key LIKE '%prox%';" 2>/dev/null \
      && log "  SQL 代理清除: $_t" || true
  done
fi

# ── Step 7: 代理配置清除 (官方专用端点 GET/PUT /api/settings/proxy) ──
_cur=$(curl -sf -b "$COOKIE" "$BASE/api/settings/proxy" 2>/dev/null || echo "{}")
log "  当前 proxy 配置: $(printf '%s' "$_cur" | head -c 200)"
curl -s -o /dev/null -w "[init]   proxy disable: HTTP %{http_code}\n" -b "$COOKIE" \
  -X PUT "$BASE/api/settings/proxy" -H "Content-Type: application/json" \
  -d '{"enabled":false}' 2>/dev/null || log "  ⚠ proxy PUT 失败 (非阻断, Step 6 已兜底)"

# ── Step 8: Resilience (官方确认 PATCH 结构: providerBreaker.{oauth,apikey}) ──
_body=$(jq -n '{providerBreaker:{apikey:{degradationThreshold:3,failureThreshold:5,resetTimeoutMs:60000},oauth:{degradationThreshold:3,failureThreshold:5,resetTimeoutMs:60000}}}')
curl -s -o /dev/null -w "[init]   resilience PATCH: HTTP %{http_code}\n" -b "$COOKIE" \
  -X PATCH "$BASE/api/resilience" -H "Content-Type: application/json" -d "$_body" 2>/dev/null
curl -sf -b "$COOKIE" "$BASE/api/resilience" 2>/dev/null | jq -c '.providerBreaker // .' 2>/dev/null \
  | head -c 300 | xargs -I{} log "  resilience 读回: {}"

# ── Step 9: Compression (官方路径 /api/settings/compression; schema 未文档化 → 先读后写) ──
curl -sf -b "$COOKIE" "$BASE/api/settings/compression" 2>/dev/null \
  | head -c 300 | xargs -I{} log "  compression 当前: {}"
# 按需启用: 取消下行注释并按读回的结构补全字段
# curl -s -b "$COOKIE" -X PUT "$BASE/api/settings/compression" -H "Content-Type: application/json" -d '{"mode":"lite"}' -o /dev/null -w "[init]   compression PUT: HTTP %{http_code}\n"

# ── Step 10: Thinking Budget (官方路径 /api/settings/thinking-budget) ──
curl -sf -b "$COOKIE" "$BASE/api/settings/thinking-budget" 2>/dev/null \
  | head -c 300 | xargs -I{} log "  thinking-budget 当前: {}"

# ── Step 11: Memory — 官方确认 v3.8.30+ 默认关闭, 无需任何操作 ──
log "✓ Memory 默认关闭 (v3.8.30+), 跳过"

# ── Step 12: 熔断器重置 (官方路径 /api/resilience/reset, 需管理端鉴权) ──
curl -s -o /dev/null -w "[init]   breaker reset: HTTP %{http_code}\n" -b "$COOKIE" \
  -X POST "$BASE/api/resilience/reset" 2>/dev/null

# ── Step 13: NIM Key 探针 (可选, NIM_PROBE=1 时启用; 走 443, HF 出站允许) ──
if [ "${NIM_PROBE:-0}" = "1" ]; then
  _j=0
  while IFS= read -r _key; do
    _key="$(printf '%s' "$_key" | tr -d '[:space:]')"
    [ -z "$_key" ] && continue
    _j=$((_j+1))
    _n=$(curl -sf -H "Authorization: Bearer $_key" \
      "https://integrate.api.nvidia.com/v1/models" 2>/dev/null | jq '.data | length' 2>/dev/null || echo "FAIL")
    log "  探针 nim-$(printf '%02d' $_j): 模型数=$_n"
  done <<< "$NIM_KEYS"
fi

# ── Step 14: Combo 管理 (官方 auto-combo 优先路径; /api/combos 持久化 optional) ──
# 首次部署无需创建任何 combo: 官方支持 model:"auto" (及 auto/coding, auto/fast 前缀) 虚拟 combo,
#   createVirtualAutoCombo 直接从已注册活跃 NIM 连接建池路由, 零预创建。
# 客户端直接用 model:"auto" 即可路由全部已注册 NIM 连接。
# 持久化 combo 仅 optional 优化 (固定模型池/别名), 待管理通道 (manage-scope key) 就绪后创建;
#   当前 fail-closed 后台关, 脚本不盲写 POST /api/combos (schema 未文档化)。
curl -sf -b "$COOKIE" "$BASE/api/combos" 2>/dev/null \
  | head -c 500 | xargs -I{} log "  combos 当前: {}" || log "  combos 读取失败 (非阻断, auto combo 仍可用)"

log "════════ 初始化完成：Keys $REG+$SKIP/$((REG+SKIP+FAIL)) ════════"
exit 0
