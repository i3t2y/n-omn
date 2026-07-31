#!/bin/bash
set -eo pipefail

# ─────────────────────────────────────────────────────────────
# NIM OmniRoute initializer  v4.3.2（基于 v4.2.3；v4.3.1 固定档限流故障后修正）
# v4.3.2 [M1-M5 改造]: M1 限流随存活数动态推导(逐字对齐 baseline-4.2.3) / M2 maxWait 四字段读回断言 /
#                      M3 probe_nim_keys_real 真探活 + auth_dead 跳注册 / M4 压缩全局关闭 / M5 横幅版本对齐.
#   v4.3.1 固定档 28/3/2200 不随 alive 伸缩 = 2026-07-21 账户级封根因; v4.3.2 驱逐之.
# 相对 v4.2.2 的变更：
#   【v4.3.0·⑨ 】DEBUG log 上传 Dataset: 默认**关闭** (NIM_DEBUG_LOG_TO_DATASET=1 开启);
#              开启时上传前字段级脱敏 Authorization/NIM_KEY/Cookie/Set-Cookie (红线1 动态);
#              本地仅留最近 NIM_DEBUG_LOG_KEEP(默认5) 个.
#              v4.3 改: 默认关 (原 v4.2.3 默认开违红线1 动态; B2 9a1a7f0 精简方向降写 Dataset).
# 继承 v4.2.2：⑦ 幂等 upsert_combo ⑧ 增量门放宽（任一 nim-* combo 或 INIT_MARKER）。
# 继承 v4.2.1：① 移除 quota-share/主池 p2c+白名单 ② nim-codex 响应体打印
#              ⑤ 增量只清过期熔断 ⑥ context_recommendations 累积推荐（被动观测）。
# ─────────────────────────────────────────────────────────────

# ══ 单变量调试 + 日志归档（stdout 实时 tee；DEBUG 时另上传 Dataset，见⑨）═══════
NIM_MODE="${NIM_MODE:-NORMAL}"
# DEBUG init.log → omn-raw 临时区, capture_init 尾追+omn_redact 后写 staging 推 save (类 C 脱敏)
# omn-raw 须在 scheduler folder 外 (STAGING/omn-sched): CommitScheduler 整目录 upload, _raw 在其下 → 明文混入 save = 脱敏漏泄.
# (DATA_DIR 由 entrypoint export, 与 scheduler RAW_DIR 对齐; 缺省回 /data 兼容)
LOG_DIR="${DATA_DIR:-/data}/omn-raw"
if [ "$NIM_MODE" = "DEBUG" ]; then
  mkdir -p "$LOG_DIR" 2>/dev/null || true
  INIT_LOG="$LOG_DIR/init_$(date +%Y%m%d_%H%M%S).log"
  exec > >(tee -a "$INIT_LOG") 2>&1
  echo "[init] 🛠️ NIM_MODE=DEBUG：日志 tee -> $INIT_LOG（_raw → capture_init 脱敏推 save）"
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
COMBO_RESP_FILE="$(_resp omniroute-combo.json)"
VERSION_FILE="$(_resp omniroute-version.json)"

REGISTERED=0; SKIPPED=0; FAILED=0

# ══ 模型分档 SSOT（对齐现行 NVIDIA 目录）═══════════════════════
TIER_FAST=(
  "z-ai/glm-5.2"
  "deepseek-ai/deepseek-v4-flash"
  "deepseek-ai/deepseek-v4-pro"
  # "meta/llama-3.3-70b-instruct"  # 2026-07-25 Task E 移除: route-slow (boot#3 matrix nim-pool 笔2 101s 超时 gpt-oss-120b + llama-3.3-70b 路由慢挂, check_nim_model_health 探 NVIDIA 目录有=available 不标 deprecated, filter_alive 不剔, 每 boot combo PUT 回冲; 落源不落库方能切除). 圣上裁决矛盾二取 ii (主池+codex 同步删 gpt-oss-120b)
)
TIER_STABLE=(
  "nvidia/nemotron-3-super-120b-a12b"
  # "openai/gpt-oss-120b"  # 2026-07-25 Task E 移除: route-slow (boot#3 matrix nim-codex 笔1 101s 超时 priority 命中 gpt-oss-120b 挂无 fallback; 亦在 NIM_CODEX_MODELS 行89 同步删). 圣上裁决矛盾二取 ii
  # "qwen/qwen3.5-397b-a17b"  # 2026-07-25 Task D 移除: catalog 可查≠可服务, POST /v1/chat/completions 上游返 function-not-found 404 (omniroute 真转发 NVIDIA 后被上游拒)
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
  # "openai/gpt-oss-120b"  # 2026-07-25 Task E 移除: route-slow (boot#3 matrix nim-codex 笔1 priority 命中此模型 101s 超时挂; 与 TIER_STABLE 行68 同步删以复 matrix 双 combo 绿路径). 圣上裁决矛盾二取 ii. strategy维持 priority (codex 2 model priority 可走, 矛盾三维持裁决)
  "z-ai/glm-5.2"
)
NIM_FAST_MODELS=(
  "deepseek-ai/deepseek-v4-flash"
  # "meta/llama-3.3-70b-instruct"  # 2026-07-25 Task E 漏网补剔 (snapshot 档): NIM_FAST_MODELS 不进 combo (无 upsert 1023/1024 链), 仅入 init_vars.json 快照 (行939 _arr_json fast_models); Task E 主剔三处 (TIER_FAST 行64 / TIER_STABLE 行68 / NIM_CODEX_MODELS 行89) 已落 — 此处漏网致快照说谎, boot 取证读 init_vars 见 llama 在册误导未来判案. 圣上裁"行94 同样注释化"顺势成全闸复验, 一 push 自动再触 sync-logic-dev 充活体探针.
  "google/gemma-4-31b-it"
)
NIM_EXTRA_MODELS=( "deepseek-ai/deepseek-v4-flash" )

build_all_models() {
  printf '%s
' "${NIM_POOL_MODELS[@]}" "${NIM_CODEX_MODELS[@]}" "${NIM_EXTRA_MODELS[@]}" | awk '!seen[$0]++'
}
models_to_json() { printf '%s\n' "$@" | sed 's/^/nvidia\//' | jq -R '{model: .}' | jq -s -c .; }

# ══ combo 策略白名单（3.8.43 实测合法枚举，不含 quota-share）═════
_VALID_STRATS="priority weighted round-robin fill-first p2c random least-used cost-optimized reset-aware reset-window headroom strict-random auto lkgp context-optimized fusion"
# v4.3: 删 context-relay (CF-1/红线: NIM 永不用 context-relay; cf-worker 已删, 无外部 Relay 层); 保留 fusion (Codex 池可用).
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
  # R3+ Restart A (i′ 方案)→ Task C1 终态 (圣上源码 v3.8.43@b729a8f 实证裁决):
  # 旧式 `.combos[]? // .[]? | select(.name==$n)` 两病: ① `//` 优先级低于 `|` 失控
  # → CID 永空 → 永远 POST → 重名 400 死循环(幂等失效); ② 空 combos 时 `.[]?` 回退遍历对象值,
  # 对数组值取 `.name` 抛 "Cannot index array with string"(4.2.3 生产 14:23 实测, 4.3.2 同病)。
  # 修正式 (数组/对象双容 + 对象守卫): 根为数组直接遍历, 根为对象取 .combos//.data 字段,
  # select 加 `type=="object"` 守卫防对非对象值(数组值)取 .name 抛错 — 兼两种响应结构 + 空库首跑。
  CID=$(curl -s -b "$COOKIE_FILE" "$BASE_URL/api/combos" \
        | jq -r --arg n "$NAME" '(if type=="array" then . else (.combos // .data // []) end) | .[]? | select(type=="object" and .name==$n) | .id' | head -n1)
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
  if [ "$CODE" != "200" ] && [ "$CODE" != "201" ]; then
    echo "[init] ✗ upsert $NAME: 非 2xx (HTTP $CODE) — fail-closed, init 将非零退出."
    cat "$F" 2>/dev/null || true
    return 1
  fi
}

# ══ Task C2: 僵尸/重复 nvidia 连接 GC (圣上源码 v3.8.43@b729a8f 实证裁决) ══
# GET /api/providers 返 {connections:[...]} (字段名非 .providers, 旧误名会静默失效)。
# POST /api/providers 无 name 查重 → 每 boot 重复注册累积; init 内 409 分支是死代码 (POST 不校验 name)。
# GC 职责二合一: ① 僵尸(name nim-NN 编号 > 当前 NIM_KEYS 总数的连接删)
#                ② 同名重复(留首个 idx=0, 余删)
# 删除走批量 DELETE /api/providers {ids:[]} 一次调用 (≤100/批)。幂等(再跑无待删)。
gc_stale_providers() {
  local _GC_FILE _GC_HTTP _NIM_TOTAL _DEL_JSON _DEL_COUNT _CLEAN_IDS
  _GC_FILE="$(_resp omniroute-providers-gc.json)"
  _GC_HTTP=$(curl -s -o "$_GC_FILE" -w "%{http_code}" -b "$COOKIE_FILE" "$BASE_URL/api/providers")
  if [ "$_GC_HTTP" != "200" ]; then
    echo "[init] gc_stale: GET /api/providers HTTP $_GC_HTTP 跳过 GC"; return 0
  fi
  _NIM_TOTAL=$(printf '%s' "$NIM_KEYS" | grep -c '' 2>/dev/null || printf '0')
  # 提 (name,id) 对; 按 name 分组, 留首个, 判僵尸(nim-NN 编号>总数)+重复(idx>0) → 待删 id 列表去空去重
  # 修法(2026-07-25 bug): _DEL_JSON 赋值包 set +eo pipefail 抬门防 pipefail 杀 init.
  #   根因: set -eo pipefail(行2)下, 无待删态 jq 输出空 → grep -v '^$' 空输入返 rc=1(无匹配)
  #   → pipefail 致 pipeline rc=1 → set -e 杀 init, 致 7 registered 后全段不执行(combo/Resilience 永不建).
  #   抬门严格包 _DEL_JSON 前后, 不波及函数其余段; ${_DEL_JSON:-[]} 兜底极端空态等价无待删.
  set +eo pipefail
  _DEL_JSON=$(jq -r --argjson max "$_NIM_TOTAL" '
    [(.connections[]? // empty) | select((.provider? // "") == "nvidia")
       | {name: (.name? // ""), id: (.id? // "")} | select(.id != "")]
    | group_by(.name) | .[] | . as $g | ($g[0].name) as $nm
    | ($nm | test("^nim-[0-9]+$")) as $isnim
    | (if $isnim then ($nm | ltrimstr("nim-") | tonumber) else -1 end) as $num
    | ($g | to_entries | map(select((($num > $max) and $isnim) or (.key > 0)) | .value.id))[]
  ' "$_GC_FILE" 2>/dev/null | grep -v '^$' | jq -R . | jq -s 'unique')
  set -eo pipefail
  _DEL_JSON="${_DEL_JSON:-[]}"
  _DEL_COUNT=$(printf '%s' "$_DEL_JSON" | jq 'length' 2>/dev/null || printf '0')
  if [ "$_DEL_COUNT" -le 0 ] || [ -z "$_DEL_JSON" ]; then
    echo "[init] gc_stale: 无待删连接 (当前 NIM_KEYS=$_NIM_TOTAL, 增量幂等)"; return 0
  fi
  _CLEAN_IDS=$(printf '%s' "$_DEL_JSON" | jq -c '{ids: .}')
  local _DEL_HTTP _DEL_BODY
  _DEL_BODY="$(_resp omniroute-providers-del.json)"
  _DEL_HTTP=$(curl -s -o "$_DEL_BODY" -w "%{http_code}" -b "$COOKIE_FILE" \
    -X DELETE "$BASE_URL/api/providers" -H "Content-Type: application/json" -d "$_CLEAN_IDS")
  echo "[init] gc_stale: 删除 $_DEL_COUNT 个僵尸/重复 nvidia 连接 (批量 DELETE /api/providers HTTP $_DEL_HTTP, 上限 max=$_NIM_TOTAL)"
}

# ══ 按存活 Key 数动态推导 RPM/并发 ═════════════════════════════
_count_alive_keys() { printf '%s
' "$NIM_KEYS" | sed '/^[[:space:]]*$/d' | wc -l; }
_ALIVE_KEYS=$(_count_alive_keys)
# v4.3.2 [M1]: 限流随存活 Key 数动态推导(替换 v4.3.1 固定档 28/3/2200 — 故障原型根因).
#   固定档不随 alive 伸缩 = 2026-07-21 事件设计根因: alive 变而限流不随动.
#   三式逐字对齐 baseline-4.2.3 (nomke 25 key 健康运行即正解证据):
#     _RPM            = alive * NIM_PER_KEY_RPM(默35)      封顶 300 (硬上限, 防超 API 限)
#     _CONCURRENT     = alive * NIM_PER_KEY_CONCURRENT(默3) 保底 3  (单 key 也有并发槽)
#     _MIN_INTERVAL_MS = 60000 / _RPM                      (整数截断; _RPM>0 守卫, 下界 200ms)
#   双层并发槽澄清(承 v4.3 注释):
# (A) 上游: OmniRoute requestQueue.concurrentRequests (本 init PATCH /api/resilience 落定) — 上述 _CONCURRENT 主力杠杆.
# (B) gate 本地: 现役 gate.js(本稿 [3/7], 520L)零限流代码 — 头注"无第二套限流"为真, 限流唯一杠杆=上游 requestQueue.
#   (谱系注: 旧变体 gate.v43-merged.js 曾有 tryAcquire 判拒自发 429 retry-after:3, §四第①步 5并诊断实证出自该旧变体;
#    现役 gate.js 无此路径, 端到端限流=上游单杠杆.)
# v4.3.2 [M1 故障原型驱逐]: NIM_FIXED_RPM/NIM_FIXED_CONCURRENT/NIM_FIXED_MIN_INTERVAL_MS 三个固定覆盖 env
#   全数移除 — 以"调试便利"名义请回固定档 = 重新打开本次事故设计根因口子. 调试用 NIM_PER_KEY_RPM/NIM_PER_KEY_CONCURRENT 旋钮.
_PER_KEY_RPM=${NIM_PER_KEY_RPM:-35}              # 单 Key RPM 上限 (动态算式基, 同时诊断用)
_PER_KEY_CONCURRENT=${NIM_PER_KEY_CONCURRENT:-3} # 单 Key 并发槽 (动态算式基)
# ── 动态推导 (随 _ALIVE_KEYS 伸缩; baseline-4.2.3 三式逐字对齐: 行134-140) ──
_RPM=$(( _ALIVE_KEYS * _PER_KEY_RPM ))
[ "$_RPM" -lt "$_PER_KEY_RPM" ] && _RPM=$_PER_KEY_RPM   # baseline行135: 保底=单 key 上限(非固定1)
[ "$_RPM" -gt 300 ] && _RPM=300                          # baseline行136: 封顶 300 (硬上限)
_CONCURRENT=$(( _ALIVE_KEYS * _PER_KEY_CONCURRENT ))
[ "$_CONCURRENT" -lt 3 ] && _CONCURRENT=3               # baseline行138: 保底 3
_MIN_INTERVAL_MS=$(( 60000 / (_RPM > 0 ? _RPM : 1) ))   # baseline行139: 三元守卫防除零
echo "[init] 动态限流 RPM=$_RPM concurrent=$_CONCURRENT interval=${_MIN_INTERVAL_MS}ms (alive_keys=$_ALIVE_KEYS, per_key_rpm=$_PER_KEY_RPM per_key_conc=$_PER_KEY_CONCURRENT)"

if [ "$_ALIVE_KEYS" -gt 1 ]; then
  _POOL_STRATEGY="${NIM_POOL_STRATEGY:-p2c}"
else
  _POOL_STRATEGY="round-robin"
fi
_is_valid_strat "$_POOL_STRATEGY" || { echo "[init] WARN: pool strategy '$_POOL_STRATEGY' 非法，回退 round-robin"; _POOL_STRATEGY="round-robin"; }
# FIX #4: codex strategy=priority for code generation scenarios.
# round-robin rotates model each turn — unsuitable for coding (上下文连续性丢失).
# 改默认 :-priority; env NIM_CODEX_STRATEGY 可覆盖 (如需 round-robin 传 NIM_CODEX_STRATEGY=round-robin).
_CODEX_STRATEGY="${NIM_CODEX_STRATEGY:-priority}"
_is_valid_strat "$_CODEX_STRATEGY" || { echo "[init] WARN: codex strategy '$_CODEX_STRATEGY' 非法，回退 priority"; _CODEX_STRATEGY="priority"; }
_FALLBACK_STRATEGY="round-robin"
_STICKY_LIMIT=1
_COMPRESS_THRESHOLD=${NIM_COMPRESS_THRESHOLD:-12000}
_COMPRESS_MODE="stacked"
_NIM_REAL_CONTEXT=${CONTEXT_LENGTH_DEFAULT:-200000}
echo "[init] pool strategy=$_POOL_STRATEGY | codex strategy=$_CODEX_STRATEGY"

# ── body limit 归一 ───────────────────────────────────────────
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

_DB_PATH="${DATA_DIR:-/data}/storage.sqlite"
sql_escape() { printf '%s' "$1" | sed "s/'/''/g"; }

# int 范围校验器 (供 Resilience PATCH 白名单构造): $1=值 $2=下限(int) $3=上限(int); 返回 0 合格, 1 不合格
_res_validate_int() {
  [ -z "$1" ] && return 1
  case "$1" in
    ''|*[!0-9-]*) return 1 ;;   # 非数字 (允许负号作前缀, 实际范围校验拦截)
  esac
  [ "$1" -ge "$2" ] 2>/dev/null && [ "$1" -le "$3" ] 2>/dev/null || return 1
  return 0
}

# FlareTunnel 档位A: 一本地桥(127.0.0.1:8080) + N Worker round-robin 出口.
#   OmniRoute 表中只须注册一行代理(host=127.0.0.1 port=8080), 全 nvidia provider 走桥 → 桥内轮换 8 Worker.
#   指派 scope='provider' scopeId=<任一 nvidia PROVIDER_ID> (upstream resolveProxyForConnection 按 scope 解析,
#   nvidia 全 provider 连接共享一行代理 = 全瑾 Worker 轮换; 非 32 桥×N 方案需 32 行注册).
# 测活时序决策(2026-07-30 查证官方): 注册时 NOT 探活, status='active' 默认, 交上游 runtime 接管:
#   ① isProxyReachable (lib/proxyHealth.ts) 用前 TCP <2s fast-fail + 30s/2s in-mem cache
#   ② validateProxyPool (lib/proxyEgress.ts) 探真出口 IP 标 status=active|error → DB 持久
#   ③ PROXY_ALIVE_PREDICATE (lib/db/proxies.ts:507) resolution SQL 自动跳 status=error/inactive/dead/down
#   → 桥死即时跳轮(无影响 init 绕, 运行时自愈, 本函数无需重造探活).
# 幂等: POST /api/v1/management/proxies 返回 409/exists → skip, 注册满 HTTP 200/201 → 建.
_ft_register_proxy() {
  [ "${FLARETUNNEL_ENABLED:-0}" != "1" ] && return 0
  # 桥未启(entrypoint §1.5 fail-open 降级) → 不注册, 免 nvidia 指死桥反停业务
  [ -z "${FT_PID:-}" ] && { echo "[init] FT proxy: skip (FT 桥未启/降级, 不注册死代理)."; return 0; }
  # nvidia provider ID 须取到 (指派 scopeId 必需)
  local _pid="${PROVIDER_IDS:-}"
  # PROVIDER_IDS 是数组; 取首元素 (nvidia 同 provider 全共享一行 proxy)
  local _first_pid=""
  while IFS= read -r _first_pid; do [ -n "$_first_pid" ] && break; done <<< "$(printf '%s\n' "${PROVIDER_IDS[@]}")" 2>/dev/null
  [ -z "$_first_pid" ] && { echo "[init] FT proxy: skip (无 nvidia PROVIDER_ID, 无法指派)."; return 0; }
  local _HOST="${FT_PROXY_HOST:-127.0.0.1}" _PORT="${FT_PROXY_PORT:-8080}"
  local _BODY
  _BODY=$(jq -n --arg h "$_HOST" --argjson p "$_PORT" --arg sid "$_first_pid" \
    '{name:"flaretunnel-8080", type:"http", host:$h, port:$p,
      assignment:{scope:"provider", scopeId:$sid}}')
  local _HTTP _RESP
  _RESP=$(_resp ft_proxy_register.json)
  _HTTP=$(curl -s -o "$_RESP" -w "%{http_code}" -b "$COOKIE_FILE" \
    -X POST "$BASE_URL/api/v1/management/proxies" \
    -H "Content-Type: application/json" -d "$_BODY" 2>/dev/null || echo "000")
  case "$_HTTP" in
    200|201) echo "[init] FT proxy: 注册 ✓ (host=${_HOST}:${_PORT} → nvidia provider $_first_pid, HTTP $_HTTP)" ;;
    409)     echo "[init] FT proxy: 跳过 (已存在 409, 幂等保健康)" ;;
    *)       echo "[init] FT proxy: WARN 注册 HTTP $_HTTP ($(head -c 200 "$_RESP" 2>/dev/null)"; return 0 ;;
  esac
  # 官方 register-and-go 哲学: 不探活, 交 runtime isProxyReachable/validateProxyPool 自理.
  # _ft_workers_health (82a93d4 WIP) 已撤: 它 paste|nl|while 并行 16 curl@HF sandbox 网络层
  #   + set -eo pipefail 致 init 卡死静默退 (三轮 boot 无 331/Resilience/Done 实证). 档位A
  #   体检表需圣上定方案 (serialization/timeout 硬护栏/桥侧 metrics 端点 任一) 后重装, 见
  #   [[ft-workers-health-diffa-wip]] 习: 进程活/鉴权/穿透三层非出口IP.
  #
  # 路3 轻 local 体检 (2026-07-31 圣准): 读桥自报 /healthz 替叛 WIP 函数.
  #   本地 127.0.0.1 HTTP <50ms 不经 Worker 不经 sandbox, 3s timeout 硬断, set -e 兜底 `|| echo {}` fail-open 不阻 init.
  #   JSON 含 Workers 数/round-robin 游标/per-Worker 计数 (boot 瞬 0, 跑业务后累加), 给圣上日后读 save 反推健康无卡死.
  local _sh
  _sh=$(curl -s -m 3 "http://${_HOST}:${_PORT}/healthz" 2>/dev/null || echo '{}')
  echo "[init] FT bridge healthz: $_sh"
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

# ══ 【⑥+ 上下文累积判读】跨 call_logs 淘汰周期保留每模型成功/失败口径 ═══
# 背景：call_logs 表有 ~10 万行上限（trimCallLogsToMaxRows），旧日志被淘汰后
#       历史划定信号丢失。本节把"曾经跑通的最大 input"与"首次报错的最小 input"
#       沉降到 context_recommendations 表，跨淘汰周期保留，供自动标定 real_context。
# 约束：只读不写外部服务；checkpoint 存 key_value(namespace='monitor')；
#       ON CONFLICT DO UPDATE 保证 last_success_tokens 只增不减。
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

# 探测 call_logs 的 input/output token 列名。3.8.43 实测 tokens_in/tokens_out；
# 兼容 input_tokens/in_tokens/total_input_tokens 等（探测命中即用）。
# 单次 PRAGMA（#4 合一：旧版 _detect_input_col/_detect_output_col 各跑一次，
# 对同一 call_logs 表重复打两次 PRAGMA table_info，合一省一次磁盘扫）。
# PRAGMA table_info 列序 cid|name|type|notnull|dflt|pk → 列名在 $2。
# 输出两行：第1行 input 列名、第2行 output 列名；未命中留空行。用两行而非 \t 分隔，
# 避免 IFS tab 空白折叠致列错位（Bug A 同类回归：仅 output 命中时前导 tab 被 read 剥离，
# output 列名错位落入 input 字段）。调用方按行读两变量。
_detect_io_cols() {
  sqlite3 "$_DB_PATH" "PRAGMA table_info(call_logs);" 2>/dev/null \
    | awk -F'|' '
        $2~/^tokens_in$|^input_tokens$|^in_tokens$|^total_input_tokens$/ {if(!ic) ic=$2}
        $2~/^tokens_out$|^output_tokens$|^out_tokens$|^total_output_tokens$/ {if(!oc) oc=$2}
        END{print ic; print oc}'
}

# 增量更新：读 checkpoint -> 查 id>checkpoint 新日志 -> 累积 -> 落表 -> 推 checkpoint
context_accumulator_update() {
  echo "[init] context_accumulator_update: 增量累积每模型成功/失败口径..."
  [ ! -f "$_DB_PATH" ] && { echo "[init]   no DB, skip."; return 0; }
  _context_acc_init_table || { echo "[init]   建表失败，skip。"; return 0; }

  local _has_tbl
  _has_tbl=$(sqlite3 "$_DB_PATH" "SELECT name FROM sqlite_master WHERE type='table' AND name='call_logs';" 2>/dev/null || echo "")
  [ -z "$_has_tbl" ] && { echo "[init]   call_logs 不存在（无流量），预约表就绪。"; return 0; }

  # 列名探测（单次 PRAGMA 两行输出，失败则兜默认/跳过）
  local _input_col _output_col _io
  _io=$(_detect_io_cols)
  _input_col=$(printf '%s' "$_io" | sed -n '1p')
  _output_col=$(printf '%s' "$_io" | sed -n '2p')
  [ -z "$_input_col" ] && { echo "[init]   WARN: call_logs 无已知 input token 列，skip。"; return 0; }
  [ -z "$_output_col" ] && _output_col="tokens_out"
  echo "[init]   列探测 input=$_input_col output=$_output_col"

  # checkpoint：call_logs.id 是 TEXT(UUID) 无数值序，改用 timestamp 串比较
  # ISO-8601 字典序 == 时间序；checkpoint str 存 key_value(monitor/ctx_last_log_ts)
  local _ckpt_key="ctx_last_log_ts" _last_ts _new_max_ts
  _last_ts=$(sqlite3 "$_DB_PATH" "SELECT value FROM key_value WHERE namespace='monitor' AND key='$(sql_escape "$_ckpt_key")';" 2>/dev/null || echo "")
  [ -z "$_last_ts" ] && _last_ts="1970-01-01T00:00:00.000Z"
  echo "[init]   checkpoint last_ts=$_last_ts"

  # 成功：status 2xx 且 output>0；
  # 失败：status>=500、status=413（context/body 过大，上游 chatBodyAdmission 对 oversized 发 413）、
  #       或 (2xx 且 output=0)。
  # 不纳 401/403/429：鉴权/限频信号会污染 first_failure_tokens。
  # 按模型分桶累积 MAX(成功 input) / MIN(失败 input)，并累计 samples
  local _q
  _q="
    SELECT
      model                                                   AS mid,
      MAX(CASE WHEN status BETWEEN 200 AND 299 AND ${_output_col}>0
               THEN ${_input_col} END)                        AS suc_max,
      MIN(CASE WHEN (status>=500) OR (status=413) OR (status BETWEEN 200 AND 299 AND ${_output_col}=0)
               THEN ${_input_col} END)                        AS fail_min,
      SUM(CASE WHEN status BETWEEN 200 AND 299 AND ${_output_col}>0 THEN 1 ELSE 0 END) AS suc_n,
      SUM(CASE WHEN (status>=500) OR (status=413) OR (status BETWEEN 200 AND 299 AND ${_output_col}=0) THEN 1 ELSE 0 END) AS fail_n,
      MAX(timestamp)                                          AS max_ts
    FROM call_logs
    WHERE provider='nvidia' AND timestamp > '$(sql_escape "$_last_ts")'
      AND model LIKE '%/%' AND model != 'model-sync'
    GROUP BY model;"

  local _rows _cnt=0
  _rows=$(sqlite3 -separator $'\t' "$_DB_PATH" "$_q" 2>/dev/null || echo "")
  if [ -z "$_rows" ]; then echo "[init]   本轮无新日志（timestamp > checkpoint）。"; return 0; fi

  # #1 根因：IFS=$'\t' read 把 tab 当 IFS 空白类——折叠加空字段、剥离前导 tab，
  # 一旦某列（model 或中间 suc_max/fail_min）NULL→空串，6 列被折叠成 <6 段，
  # max_ts 串错位落入 _fail_n，进 $(( )) 触发八进制解析（error token "09T22"）。
  # 修复：改用 mapfile -t -d $'\t' 数组逐字段拆行，保留空字段、不折叠不剥离首，
  # 6 索引严格对齐 SQL 列序；数字列空时兜 0。
  local _line _mid _suc_max _fail_min _suc_n _fail_n _max_ts
  while IFS= read -r _line; do
    local _acc=(); mapfile -t -d $'\t' _acc <<<"$_line"
    _mid=${_acc[0]}; _suc_max=${_acc[1]}; _fail_min=${_acc[2]}
    _suc_n=${_acc[3]}; _fail_n=${_acc[4]}; _max_ts=${_acc[5]}
    [ -z "$_mid" ] && continue
    # ON CONFLICT DO UPDATE：last_success 只增不减（取 MAX(旧,新)），
    # first_failure 只减不增（取 COALESCE(MIN,旧)）。samples 累加。
    local _rec_real _conf _new_total
    _new_total=$(( (${_suc_n:-0} + ${_fail_n:-0}) ))
    sqlite3 "$_DB_PATH" "
      INSERT INTO context_recommendations (model_id, last_success_tokens, first_failure_tokens,
                                           success_samples, failure_samples, confidence,
                                           recommended_real_context, last_updated)
      VALUES ('$(sql_escape "$_mid")',
              $([ -n "$_suc_max" ] && echo "$_suc_max" || echo 'NULL'),
              $([ -n "$_fail_min" ] && echo "$_fail_min" || echo 'NULL'),
              ${_suc_n:-0}, ${_fail_n:-0},
              'insufficient', NULL, datetime('now'))
      ON CONFLICT(model_id) DO UPDATE SET
        last_success_tokens = MAX(COALESCE(excluded.last_success_tokens, 0),
                                  COALESCE(context_recommendations.last_success_tokens, 0)),
        first_failure_tokens = CASE
          WHEN context_recommendations.first_failure_tokens IS NULL THEN excluded.first_failure_tokens
          WHEN excluded.first_failure_tokens IS NULL THEN context_recommendations.first_failure_tokens
          ELSE MIN(excluded.first_failure_tokens, context_recommendations.first_failure_tokens)
        END,
        success_samples  = context_recommendations.success_samples  + excluded.success_samples,
        failure_samples  = context_recommendations.failure_samples  + excluded.failure_samples,
        last_updated     = datetime('now');" 2>/dev/null || continue

    # 推荐值 + 置信度：需历史累计样本，读回
    local _hist_suc_n _hist_fail_n _hist_suc _hist_fail
    _hist_suc_n=$(sqlite3 "$_DB_PATH" "SELECT success_samples FROM context_recommendations WHERE model_id='$(sql_escape "$_mid")';" 2>/dev/null || echo 0)
    _hist_fail_n=$(sqlite3 "$_DB_PATH" "SELECT failure_samples FROM context_recommendations WHERE model_id='$(sql_escape "$_mid")';" 2>/dev/null || echo 0)
    _hist_suc=$(sqlite3 "$_DB_PATH" "SELECT last_success_tokens FROM context_recommendations WHERE model_id='$(sql_escape "$_mid")';" 2>/dev/null || echo "")
    _hist_fail=$(sqlite3 "$_DB_PATH" "SELECT first_failure_tokens FROM context_recommendations WHERE model_id='$(sql_escape "$_mid")';" 2>/dev/null || echo "")

    local _total=$((_hist_suc_n + _hist_fail_n))
    if [ "$_total" -lt 10 ]; then _conf="insufficient"
    elif [ "$_total" -lt 50 ]; then _conf="low"
    elif [ "$_total" -lt 200 ]; then _conf="medium"
    else _conf="high"; fi

    # 推荐口径：有失败边界 → first_failure*0.85；否则 last_success*0.9
    if [ -n "$_hist_fail" ] && [ "$_hist_fail" -gt 0 ] 2>/dev/null; then
      _rec_real=$(( _hist_fail * 85 / 100 ))
    elif [ -n "$_hist_suc" ] && [ "$_hist_suc" -gt 0 ] 2>/dev/null; then
      _rec_real=$(( _hist_suc * 90 / 100 ))
    else
      _rec_real=""
    fi

    # ⚠️ confidence='$_conf' 必须用变量展开；早期 '$(_conf)' 是命令替换误用——
    # bash 执行命令 _conf → "command not found" → confidence 写空 → 下游 #2 回写
    # WHERE confidence IN ('medium','high') 不命中 → monitor+manual 行数恒 0。
    sqlite3 "$_DB_PATH" "
      UPDATE context_recommendations
      SET confidence='$_conf',
          recommended_real_context=$([ -n "$_rec_real" ] && echo "$_rec_real" || echo 'NULL')
      WHERE model_id='$(sql_escape "$_mid")';" 2>/dev/null || true
    _cnt=$((_cnt+1))
  done <<< "$_rows"

  # token 成功 only 增不减已由 ON CONFLICT 保证；checkpoint 推到本轮 max_ts
  _new_max_ts=$(printf '%s\n' "$_rows" | awk -F'\t' -v OFS='\t' '{print $6}' | sort | tail -n1)
  [ -n "$_new_max_ts" ] && sqlite3 "$_DB_PATH" "
    INSERT INTO key_value (namespace, key, value) VALUES ('monitor', '$(sql_escape "$_ckpt_key")', '$(sql_escape "$_new_max_ts")')
    ON CONFLICT(namespace, key) DO UPDATE SET value = excluded.value;" 2>/dev/null \
    && echo "[init]   checkpoint -> ctx_last_log_ts=$_new_max_ts"
  echo "[init]   累积更新 ${_cnt} 个模型。"

  # v4.3: 自动回写 context_recommendations → model_context_overrides 整段删除 (CF-2 + M30 REJECT).
  # 原实现 (B1 enabled, B2 注释禁) 直写 model_context_overrides 绕过 API/校验 → 违红线; 整段删 (非注释保留).
  # 自动 Context Override 默认关闭 (CF-4); 启用路径见 KNOWN-UNVERIFIED (API PATCH max_input_tokens + 读回).

  # 【⑥+ 】累积推荐表输出（跨 call_logs 淘汰周期保留的口径）。
  # 表输出与聚合同函数：context_accumulator_update 每轮增量/first-init 结束即打印当前推荐全表，
  # 属被动观测（不触发任何写入）；原 nim_health_pick 仅"本次推荐主力(按分档)"部分已移除。
  local _acc_rows
  _acc_rows=$(sqlite3 -separator '|' "$_DB_PATH" "
    SELECT model_id,
           COALESCE(last_success_tokens,'-'),
           COALESCE(first_failure_tokens,'-'),
           (success_samples||'/'||failure_samples),
           confidence,
           COALESCE(recommended_real_context,'-')
    FROM context_recommendations
    ORDER BY CASE confidence WHEN 'high' THEN 0 WHEN 'medium' THEN 1
             WHEN 'low' THEN 2 ELSE 3 END, model_id;" 2>/dev/null || echo "")
  if [ -z "$_acc_rows" ]; then
    echo "[init] （累积推荐表为空：尚无成功/失败样本）"
  else
    echo "[init] ═══累积 real_context 推荐（跨淘汰周期保留）═══"
    echo "[init]   model | last_ok | first_fail | ok/fail_n | conf | rec_ctx"
    while IFS='|' read -r _m _ok _fail _n _c _r; do
      [ -z "$_m" ] && continue
      printf '[init]   %s | %s | %s | %s | %s | %s\n' "$_m" "$_ok" "$_fail" "$_n" "$_c" "$_r"
    done <<< "$_acc_rows"
    echo "[init] ═════════════════════════════════════════"
  fi
}

# ══════════════════════════════════════════════════════════════
echo "[init] Starting NIM OmniRoute initializer v4.3.2 (profile=$_PROFILE, mode=$NIM_MODE) on node $(node -v 2>/dev/null || echo unknown)..."
echo "[init] BASE_URL=$BASE_URL"

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

# v4.3.2 [M3]: 真探活 probe_nim_keys_real + auth_dead 跳注册.
#   病灶切除(2026-07-21 事件签名): GET /v1/models 目录 200 而 POST /v1/chat/completions 推理 403 的
#   账户级死亡 key, 旧版盲注册全 key → 运行时熔断兜底发现死 key = 滞后 + 浪费槽位.
#   probe 必须打 POST 推理端(非 GET 目录), 否则测不出鉴权链断在推理层的死 key(见端点选择硬律).
#   probe 是手术刀非全科医生: 只切账户级死(403); 瞬态故障(429/5xx/超时)由运行时 domain_circuit_breakers 负责.
# 判活分类(fail-open — 精确划定 probe 职责边界):
#   403 → 判死 → 入 auth_dead (账户级封; 鉴权链通到推理层后被拒, 本次 POST 被断)
#   429 → 判活 (速率临时顶格; 鉴权链通 = 通未到限流层, 路径健康)
#   2xx → 判活
#   其余(4xx其他/5xx/超时/000) → 判活 (fail-open: boot 时上游抖动不放大成全停)
# probe 端点: NVIDIA 集成 API /v1/chat/completions (POST max_tokens=1, 串行单发, 不并发).
#   端点选择硬律: 必须 POST 推理端, 不能 GET /v1/models — 2026-07-21 事件签名正是
#   "GET 目录 200 而 POST 推理 403"(账户级死亡 key 鉴权链断在推理层). GET /v1/models 测不出
#   POST 鉴权死, 会把死 key 全判 alive 放进池, M3 设计前提会塌. 探活模型默认 z-ai/glm-5.2
#   (与 v4.2.3 nim_probe 同款, 池内已知稳定; env NIM_PROBE_MODEL 可换).
#   最坏启动耗时 = 15s × 最多 25 key = 375s (POST 推理冷启动偏慢, 与 health wait 同量级).
#   K3 题9(已定案·硬伤3): _ALIVE_KEYS 初值=行147 配置层预取(NIM_KEYS 全量); probe(在此函数后调)早于注册循环;
#            probe 判死后行611-633 重算段排除 auth_dead 重算 _ALIVE_KEYS 并重跑 M1 三式+策略对齐 —
#            防死 key 幽灵配额致 RPM 虚高. guard: auth_dead>0 才重算, =0 走 elif 维持原值.
#            本段为已定案实现(非待裁项), K3 确认题见附录题9.
#   K3 题10: 核验 fail-open 分类在 boot 时上游 5xx 抖动场景下是否符合可用性边界预期.
#   ⚠ baseline-4.2.3 无此 probe 机制(M3 全新增量, 非基线还原) — K3 审时知此为 v4.3.2 新增.
NVIDIA_BASE_URL="${NVIDIA_BASE_URL:-https://integrate.api.nvidia.com}"
_PROBE_TIMEOUT=${NIM_PROBE_TIMEOUT_S:-15}
declare -a AUTH_DEAD_KEYS=()
_PROBE_DEAD=0; _PROBE_ALIVE=0; _PROBE_DONE=0
_is_auth_dead() {
  local _k="$1"
  for _d in "${AUTH_DEAD_KEYS[@]}"; do [ "$_d" = "$_k" ] && return 0; done
  return 1
}
probe_nim_keys_real() {
  local _probe_model="${NIM_PROBE_MODEL:-z-ai/glm-5.2}"
  echo "[init] probe_nim_keys_real: 串行探活 NIM keys via POST /v1/chat/completions (model=$_probe_model, timeout=${_PROBE_TIMEOUT}s/key, 403→dead, 余→alive fail-open)..."
  local _idx=0 _http _t_total=0 _body
  # POST 探活体 (max_tokens=1 最小推理, jq 安全拼参防注入): 2026-07-21 事件签名 = POST 推理 403, 故必须打推理端.
  local _probe_body
  _probe_body=$(jq -nc --arg m "$_probe_model" '{model:$m, messages:[{role:"user", content:"hi"}], max_tokens:1}')
  while IFS= read -r _rkey; do
    _rkey=$(printf '%s' "$_rkey" | tr -d '' | xargs)
    [ -z "$_rkey" ] && continue
    _idx=$((_idx+1))
    # 串行单发: 速率准则并发≤2-3, 串行天然满足. -X POST 打推理端测鉴权链(stratacthing → trailback)
    # F 路证根 (2026-07-31): NIM_PROBE_VERBOSE=1 时首 curl 加 -v + 留 stderr 入 init log (并行 stderr 不混 stdout; boot 看 * Trying/TLS/Connected 定 000 真因). 默0 时 stderr 仍弃, 行为零变.
    if [ "${NIM_PROBE_VERBOSE:-0}" = "1" ]; then
      echo "[init] probe key#${_idx} VERBOSE 诊断 (-v, stderr 入此 log): " >&2
      _body=$(curl -s -v -m "$_PROBE_TIMEOUT" -w $'\n%{http_code}' -X POST \
        "$NVIDIA_BASE_URL/v1/chat/completions" \
        -H "Authorization: Bearer $_rkey" -H 'Content-Type: application/json' \
        -d "$_probe_body" 2>&1 || printf '\n000')
    else
      _body=$(curl -s -m "$_PROBE_TIMEOUT" -w $'\n%{http_code}' -X POST \
        "$NVIDIA_BASE_URL/v1/chat/completions" \
        -H "Authorization: Bearer $_rkey" -H 'Content-Type: application/json' \
        -d "$_probe_body" 2>/dev/null || printf '\n000')
    fi
    _http=$(printf '%s' "$_body" | tail -n1)
    [ -z "$_http" ] && _http="000"
    case "$_http" in
      403)
        echo "[init] probe key#${_idx}: HTTP 403 → AUTH_DEAD (账户级死亡, 入 auth_dead 跳注册)"
        AUTH_DEAD_KEYS+=("$_rkey"); _PROBE_DEAD=$((_PROBE_DEAD+1))
        ;;
      429)
        echo "[init] probe key#${_idx}: HTTP 429 → alive (速率顶格, 鉴权链通)"
        _PROBE_ALIVE=$((_PROBE_ALIVE+1))
        ;;
      200|201|202)
        echo "[init] probe key#${_idx}: HTTP $_http → alive"
        _PROBE_ALIVE=$((_PROBE_ALIVE+1))
        ;;
      000)
        # 000 = transport error/超时/HF ingress 冷启抖. 单次易误判, 补一次 30s 宽超时重试 (K3 2026-07-25 ②钉点2):
        #   二次 403 → 真 AUTH_DEAD; 二次 200/429/4xx5xx → fail-open alive; 二次仍 000 → fail-open alive (boot 抖动不放大全停).
        #   限 000 一类 (403/429/2xx 已是有效响应, 不重试). 25 key 期 000 抖动不污染验收.
        echo "[init] probe key#${_idx}: HTTP 000 → 重试 (30s 宽超时)"
        _rb=$(curl -s -m 30 -w $'\n%{http_code}' -X POST \
          "$NVIDIA_BASE_URL/v1/chat/completions" \
          -H "Authorization: Bearer $_rkey" -H 'Content-Type: application/json' \
          -d "$_probe_body" 2>/dev/null || printf '\n000')
        _rh=$(printf '%s' "$_rb" | tail -n1); [ -z "$_rh" ] && _rh="000"
        case "$_rh" in
          403) echo "[init] probe key#${_idx}: 重试 HTTP 403 → AUTH_DEAD (账户级死, 入 auth_dead)"; AUTH_DEAD_KEYS+=("$_rkey"); _PROBE_DEAD=$((_PROBE_DEAD+1)) ;;
          000) echo "[init] probe key#${_idx}: 重试仍 000 → alive (fail-open, 瞬态抖动不放大)"; _PROBE_ALIVE=$((_PROBE_ALIVE+1)) ;;
          *) echo "[init] probe key#${_idx}: 重试 HTTP $_rh → alive (fail-open, 非账户级死)"; _PROBE_ALIVE=$((_PROBE_ALIVE+1)) ;;
        esac
        ;;
      *)
        # 4xx(非403)/5xx/超时 → fail-open 判活 (boot 抖动不放大全停; 瞬态故障运行时熔断兜底)
        echo "[init] probe key#${_idx}: HTTP $_http → alive (fail-open, 非账户级死)"
        _PROBE_ALIVE=$((_PROBE_ALIVE+1))
        ;;
    esac
  done <<< "$NIM_KEYS"
  _PROBE_DONE=1
  echo "[init] probe 汇总: alive=$_PROBE_ALIVE dead=$_PROBE_DEAD (auth_dead 跳 ${#AUTH_DEAD_KEYS[@]} 个注册, POST $_probe_model)"
}
probe_nim_keys_real

# ── v4.3.2 [M3 补丁·硬伤3修正]: probe 后按实际 alive 重算限流三字段 (防 RPM 配额虚高) ──
# 病灶: M1 公式(行165-171)在 probe(行609)之前跑过, _ALIVE_KEYS 当时=NIM_KEYS 全量(含死 key).
#        probe 判死 auth_dead 后, 若不重算 → 死 key 的 per_key 配额被幽灵占用, 实际 alive key
#        拿不到应有配额上限, 限流虚高 → OmniRoute 按原 RPM 节奏往活 key 上压, 单 key 负载超设计 → 触发 429.
#        例: 25 key 死 9, 真实 alive=16, 然 RPM 仍按 25×35=875→cap300 算; 死 key 9×35=315 配额被占.
# 修正: probe 完成后排除 auth_dead 重算 _ALIVE_KEYS, 并重跑 M1 三式(与行165-170 逐字同款),
#        下界守卫(单 key 保底)防 alive=0 时除零. 9 key 全死场景降级 alive=1 单 key 模式, 比假象健康.
if [ "${_PROBE_DONE:-0}" = "1" ] && [ "${#AUTH_DEAD_KEYS[@]}" -gt 0 ]; then
  _ALIVE_KEYS_PREV=$_ALIVE_KEYS
  _ALIVE_KEYS=$(( _ALIVE_KEYS - ${#AUTH_DEAD_KEYS[@]} ))
  [ "$_ALIVE_KEYS" -lt 1 ] && _ALIVE_KEYS=1
  echo "[init] probe 后 alive 重算: $_ALIVE_KEYS_PREV -> $_ALIVE_KEYS (排除 ${#AUTH_DEAD_KEYS[@]} auth_dead 死 key)"
  # M1 三式重跑 (与行165-170 逐字对齐 baseline-4.2.3 行134-140)
  _RPM=$(( _ALIVE_KEYS * _PER_KEY_RPM ))
  [ "$_RPM" -lt "$_PER_KEY_RPM" ] && _RPM=$_PER_KEY_RPM
  [ "$_RPM" -gt 300 ] && _RPM=300
  _CONCURRENT=$(( _ALIVE_KEYS * _PER_KEY_CONCURRENT ))
  [ "$_CONCURRENT" -lt 3 ] && _CONCURRENT=3
  _MIN_INTERVAL_MS=$(( 60000 / (_RPM > 0 ? _RPM : 1) ))
  echo "[init] 动态限流 重算 RPM=$_RPM concurrent=$_CONCURRENT interval=${_MIN_INTERVAL_MS}ms (alive_keys=$_ALIVE_KEYS 重算后)"
  # r2[硬伤3·发现C补全]: 策略对齐 — _ALIVE_KEYS 重算后连动策略(复原行173-177 设计意图: 单 key 不用 p2c)
  if [ "$_ALIVE_KEYS" -le 1 ] && [ -z "${NIM_POOL_STRATEGY:-}" ]; then
    _POOL_STRATEGY="round-robin"
    echo "[init] probe 后策略对齐: alive=$_ALIVE_KEYS <=1 -> pool strategy=round-robin (p2c 单 key 无意义)"
  fi
elif [ "${_PROBE_DONE:-0}" = "1" ]; then
  echo "[init] probe 后 alive 无变化 (auth_dead=0), 限流维持原值 RPM=$_RPM concurrent=$_CONCURRENT interval=${_MIN_INTERVAL_MS}ms"
fi

echo "[init] Registering NIM keys (auth_dead skip, INDEX 递增编号不塌)..."
INDEX=1
while IFS= read -r RAW_KEY; do
  KEY=$(printf '%s' "$RAW_KEY" | tr -d '' | xargs)
  [ -z "$KEY" ] && continue
  NAME=$(printf "nim-%02d" "$INDEX")
  RESP_FILE="$(_resp omniroute-provider-$INDEX.json)"
  # auth_dead 跳注册: INDEX 照常递增编号不塌 (nim-XX 编号缺口=死 key 位置, K3 可定位)
  if _is_auth_dead "$KEY"; then
    echo "[init] $NAME skip (probe AUTH_DEAD, 不注册)"
    # 留 placeholder 占编号: 不发 POST, 编号 nim-XX 缺口即死 key 位置
    echo "{\"probe_status\":\"auth_dead\"}" > "$RESP_FILE"
    SKIPPED=$((SKIPPED+1))
    INDEX=$((INDEX+1))
    continue
  fi
  BODY=$(jq -n --arg provider "nvidia" --arg apiKey "$KEY" --arg name "$NAME" \
    '{provider:$provider, apiKey:$apiKey, name:$name, priority:1, testStatus:"unknown"}')
  HTTP_CODE=$(curl -s -o "$RESP_FILE" -w "%{http_code}" -b "$COOKIE_FILE" \
    -X POST "$BASE_URL/api/providers" -H "Content-Type: application/json" -d "$BODY")
  if [ "$HTTP_CODE" = "201" ] || [ "$HTTP_CODE" = "200" ]; then echo "[init] $NAME OK"; REGISTERED=$((REGISTERED+1))
  elif [ "$HTTP_CODE" = "409" ]; then echo "[init] $NAME exists"; SKIPPED=$((SKIPPED+1))
  else echo "[init] $NAME HTTP $HTTP_CODE"; cat "$RESP_FILE" || true; FAILED=$((FAILED+1)); fi
  INDEX=$((INDEX+1))
done <<< "$NIM_KEYS"
echo "[init] Keys: $REGISTERED registered, $SKIPPED skipped, $FAILED failed. (probe: $_PROBE_ALIVE alive / $_PROBE_DEAD dead-skipped)"

# Task C2: 注册完 Key 后, Fetching provider IDs 前, GC 僵尸(编号>NIM_KEYS 数)/重复(POST 无查重累积)连接.
gc_stale_providers

echo "[init] Fetching provider IDs..."
PROVIDERS_HTTP=$(curl -s -o "$PROVIDERS_FILE" -w "%{http_code}" -b "$COOKIE_FILE" "$BASE_URL/api/providers")
if [ "$PROVIDERS_HTTP" = "200" ]; then
  mapfile -t PROVIDER_IDS < <(jq -r '[.. | objects | select((.provider? // "")=="nvidia") | select((.id? // "")!="") | .id] | unique | .[]' "$PROVIDERS_FILE" 2>/dev/null)
fi
echo "[init] Provider IDs: ${#PROVIDER_IDS[@]}"

_ft_register_proxy

echo "[init] Resilience (RPM=$_RPM, concurrent=$_CONCURRENT, interval=${_MIN_INTERVAL_MS}ms)..."

# ── 3.8.43 PATCH 白名单 (SSOT: src/app/api/resilience/route.ts:153 + schemas/settings.ts:131-180) ──
# updateResilienceSchema z.strict(): 顶层仅 requestQueue/connectionCooldown/providerBreaker/
#   waitForCooldown/comboCooldownWait/quotaShareConcurrencyLimit/providerCooldown/profiles/defaults.
# requestQueueSettingsSchema z.strict(): {requestsPerMinute int>=1, minTimeBetweenRequestsMs int>=0 (毫秒!),
#   concurrentRequests int>=1, autoEnableApiKeyProviders boolean, maxWaitMs int>=1}.
# useUpstream429BreakerHints 仅在 connectionCooldown.{oauth,apikey}.useUpstream429BreakerHints (boolean|null),
#   顶层该字段 → z.strict() 拒绝 → HTTP 400 (根因 #1 已证).
# _RPM(动态) → requestQueue.requestsPerMinute (int, 单位 RPM, = alive×per_key_rpm 封顶 300)
# _CONCURRENT(动态) → requestQueue.concurrentRequests (int, 单位=并发槽位数, 个, = alive×per_key_conc 保底 3)
# _MIN_INTERVAL_MS(动态) → requestQueue.minTimeBetweenRequestsMs (int, 单位=ms, = 60000/_RPM)
# _MAX_WAIT_MS → requestQueue.maxWaitMs (int, ms, 默 300000=5min 容 thinking 长思)
# PATCH = 部分更新 (mergeResilienceSettings), 非完整对象; 未传字段保留旧值.

# 显式白名单构造: 从空对象只复制 route.ts:309 接受字段, 禁 ...透传, 不发 undefined, 不发顶层 useUpstream429BreakerHints.
# 输入校验 (类型/范围) — 28∈[1,60000] RPM, 2200∈[0,600000] ms, 1∈[1,1000] 并发, maxWaitMs∈[1,600000] ms;
#   非法 init 失败 (不静默 SKIP)
# R3+ Restart A (i′ 方案): maxWaitMs=300000ms (5min 容 thinking 模型长思; 现默认 0/未设→队列满即 429).
#   requestQueueSettingsSchema z.strict(): maxWaitMs int>=1 可写 (schemas/settings.ts:131-180 L540 注).
_MAX_WAIT_MS=${NIM_MAX_WAIT_MS:-300000}
if ! _res_validate_int "$_RPM" 1 60000 || ! _res_validate_int "$_MIN_INTERVAL_MS" 0 600000 || ! _res_validate_int "$_CONCURRENT" 1 1000 || ! _res_validate_int "$_MAX_WAIT_MS" 1 600000; then
  echo "[init] ✗ Resilience 输入非法 (_RPM=$_RPM / _MIN_INTERVAL_MS=$_MIN_INTERVAL_MS / _CONCURRENT=$_CONCURRENT / _MAX_WAIT_MS=$_MAX_WAIT_MS). init 失败."
  return 1 2>/dev/null || exit 1
fi
RESILIENCE_BODY=$(jq -nc \
  --argjson rpm "$_RPM" \
  --argjson minMs "$_MIN_INTERVAL_MS" \
  --argjson conc "$_CONCURRENT" \
  --argjson maxWait "$_MAX_WAIT_MS" \
  '{requestQueue:{requestsPerMinute:$rpm, minTimeBetweenRequestsMs:$minMs, concurrentRequests:$conc, maxWaitMs:$maxWait}}')
echo "[init] Resilience PATCH body keys=[$(echo "$RESILIENCE_BODY" | jq -rc 'keys|join(",")')] requestQueue.keys=[$(echo "$RESILIENCE_BODY" | jq -rc '.requestQueue|keys|join(",")')] (无顶层 useUpstream429BreakerHints)"

# 错误处理区分 HTTP 4xx/5xx vs transport error (根因 #2: status 空无原始异常 → 必留底层 error 信息)
_t0=$(date +%s%N 2>/dev/null || date +%s)
RESILIENCE_CODE=$(curl -s -o "$RESILIENCE_RESP_FILE" -w "%{http_code}" --connect-timeout 5 --max-time 20 \
  -b "$COOKIE_FILE" -X PATCH "$BASE_URL/api/resilience" -H "Content-Type: application/json" \
  -d "$RESILIENCE_BODY" 2>/tmp/res_patch.err)
res_curl_rc=$?
_t1=$(date +%s%N 2>/dev/null || date +%s)
_res_dur_ms=$(( (_t1 - _t0) / 1000000 ))
_res_dur_ms=$(( _res_dur_ms < 0 ? 0 : _res_dur_ms ))
_res_err=$(cat /tmp/res_patch.err 2>/dev/null | head -c 300)

if [ "$res_curl_rc" -ne 0 ] || [ -z "$RESILIENCE_CODE" ]; then
  # 没收到 HTTP 响应 (transport error / timeout / abort / DNS) — 保留底层异常信息
  echo "[init] ⚠️ Resilience PATCH transport-error: curl_rc=$res_curl_rc dur=${_res_dur_ms}ms"
  echo "[init]   curl_err: ${_res_err:-<empty>}"
  echo "[init]   abort_source: $( [ "$res_curl_rc" = 28 ] && echo 'request_timeout' || ([ "$res_curl_rc" = 7 ] && echo 'proxy_connect_failure' || echo 'curl_unknown') )"
  echo "[init]   不伪装成 HTTP 错误. 保留旧配置 (CF-4). PATCH 失败 → init 仍可继续其他步, 但 readiness 不得报告 resilience 健康."
  RESILIENCE_CODE="transport_err"
else
  echo "[init] Resilience PATCH HTTP $RESILIENCE_CODE (dur=${_res_dur_ms}ms)"
  case "$RESILIENCE_CODE" in
    200|201) : ;;   # 2xx ok
    *)
      # 收到 HTTP 响应但非 2xx — 记 status/body/path/字段名
      echo "[init] ⚠️ Resilience PATCH HTTP $RESILIENCE_CODE (收到响应): body=[$(head -c 500 "$RESILIENCE_RESP_FILE" 2>/dev/null)] path=/api/resilience"
      echo "[init]   fields_sent: $(echo "$RESILIENCE_BODY" | jq -rc '.requestQueue|keys|join(",")' 2>/dev/null)"
      ;;
  esac
fi

# Read-back: PATCH 2xx 后立即 GET 验四字段 (RPM/minMs/concurrent/maxWaitMs) — 任一不一致 init 失败 (CF-4: 写必须读回)
# v4.3.2 [M2 对齐]: 旧注"28/1/2200ms 全三字段"= v4.3.1 残留, 现四字段(含 maxWaitMs). 读回即断言四值, 不再有"仅 WARN"口子.
#   ⚠ K3 审点(K3题4): 若上游 /api/resilience PATCH 静默丢弃未知字段(如某些版本 maxWaitMs 不落库),
#      本段严格断言会误 FATAL 卡死部署. 此为有意识 fail-closed — 限流未达预期不放 ready.
#      K3 裁: maxWaitMs 断言合保留严格(推荐) / 降级 WARN(若 API 字段保真性存疑).
if [ "$RESILIENCE_CODE" = "200" ] || [ "$RESILIENCE_CODE" = "201" ]; then
  _RB=$(curl -s --connect-timeout 5 --max-time 20 -b "$COOKIE_FILE" "$BASE_URL/api/resilience" 2>/tmp/res_get.err)
  res_get_rc=$?
  _res_get_err=$(cat /tmp/res_get.err 2>/dev/null | head -c 300)
  if [ "$res_get_rc" -ne 0 ] || [ -z "$_RB" ]; then
    echo "[init] ✗ Resilience GET 读回 transport-error: curl_rc=$res_get_rc err=${_res_get_err:-<empty>}"
    echo "[init]   abort_source: $( [ "$res_get_rc" = 28 ] && echo 'request_timeout' || ([ "$res_get_rc" = 7 ] && echo 'get_connect_failure' || echo 'get_unknown') )"
    echo "[init]   CF-4 约束: 写必须读回. 读回失败 → init 失败 (OmniRoute resilience 未确认达预期限流)."
    return 1 2>/dev/null || exit 1
  fi
  _RB_RPM=$(echo "$_RB" | jq -r '.requestQueue.requestsPerMinute // "null"' 2>/dev/null || echo "jq_fail")
  _RB_MINMS=$(echo "$_RB" | jq -r '.requestQueue.minTimeBetweenRequestsMs // "null"' 2>/dev/null || echo "jq_fail")
  _RB_CONC=$(echo "$_RB" | jq -r '.requestQueue.concurrentRequests // "null"' 2>/dev/null || echo "jq_fail")
  _RB_MAXWAIT=$(echo "$_RB" | jq -r '.requestQueue.maxWaitMs // "null"' 2>/dev/null || echo "jq_fail")
  echo "[init] Resilience 读回: RPM=$_RB_RPM minMs=$_RB_MINMS concurrent=$_RB_CONC maxWaitMs=$_RB_MAXWAIT (预期 $_RPM/$_MIN_INTERVAL_MS/$_CONCURRENT/$_MAX_WAIT_MS)"
  # 严格逐字段验证四目标值; 任一不符 → init 失败 (不再仅 WARN)
  _mismatch=""
  [ "$_RB_RPM" != "$_RPM" ] && _mismatch="$_mismatch RPM($_RB_RPM!=$_RPM)"
  [ "$_RB_MINMS" != "$_MIN_INTERVAL_MS" ] && _mismatch="$_mismatch minTimeMs($_RB_MINMS!=$_MIN_INTERVAL_MS)"
  [ "$_RB_CONC" != "$_CONCURRENT" ] && _mismatch="$_mismatch concurrent($_RB_CONC!=$_CONCURRENT)"
  [ "$_RB_MAXWAIT" != "$_MAX_WAIT_MS" ] && _mismatch="$_mismatch maxWaitMs($_RB_MAXWAIT!=$_MAX_WAIT_MS)"
  if [ -n "$_mismatch" ]; then
    echo "[init] ✗ Resilience 读回不一致:$_mismatch → init 失败 (CF-4: 限流配置未落定, 不能报告 ready)"
    return 1 2>/dev/null || exit 1
  fi
  echo "[init] ✓ Resilience 读回全字段一致 ($_RPM/$_CONCURRENT/$_MIN_INTERVAL_MS/$_MAX_WAIT_MS 已落定)"
fi

echo "[init] Routing + maxBodySizeMb=$_REQUEST_BODY_LIMIT_MB..."
SETTINGS_CODE=$(curl -s -o "$SETTINGS_RESP_FILE" -w "%{http_code}" -b "$COOKIE_FILE" \
  -X PATCH "$BASE_URL/api/settings" -H "Content-Type: application/json" \
  -d "{\"fallbackStrategy\":\"$_FALLBACK_STRATEGY\",\"stickyRoundRobinLimit\":$_STICKY_LIMIT,\"requestRetry\":2,\"maxRetryIntervalSec\":5,\"maxBodySizeMb\":$_REQUEST_BODY_LIMIT_MB}")
echo "[init] Settings HTTP $SETTINGS_CODE"
[ "$SETTINGS_CODE" != "200" ] && [ "$SETTINGS_CODE" != "201" ] && { echo "[init] ⚠️ Settings 非 2xx："; cat "$SETTINGS_RESP_FILE" || true; }

# ── R3+ Restart A (i′ 方案 A): 只读跳 fail-closed 三份 GET (不写, 诊断铺 Restart B 写跳) ──
#   GET /api/combos /api/combos/auto /api/providers — 记 http + id 列表 (jq 修正式裁决 §4).
#   fail-closed: 三份 GET 任一 2xx 通即继续 (不阻塞 init); 全 5xx/transport-err 记 audit 不盲写.
#   此段不改任何状态 — Restart B (写跳分档) 据此三份结构 POST/PUT/PATCH.
{
  _RO_COMBO_CODE=$(curl -s --connect-timeout 5 --max-time 20 -o /tmp/omn_ro_combos.json -w "%{http_code}" -b "$COOKIE_FILE" "$BASE_URL/api/combos" 2>/tmp/omn_ro_combos.err || echo "000")
  _RO_COMBO_IDS=$(jq -r '(if type=="array" then . else (.combos // []) end)[]? | [.id, .name, .strategy] | @tsv' /tmp/omn_ro_combos.json 2>/dev/null | tr '\n' ';' || true)
  echo "[init] [readonly] GET /api/combos HTTP $_RO_COMBO_CODE :: combos=[${_RO_COMBO_IDS}]"

  _RO_AUTO_CODE=$(curl -s --connect-timeout 5 --max-time 20 -o /tmp/omn_ro_auto.json -w "%{http_code}" -b "$COOKIE_FILE" "$BASE_URL/api/combos/auto" 2>/tmp/omn_ro_auto.err || echo "000")
  # ROOTFIX v4.3.0: @tsv 只接受数组, 旧式 `{id,name,...} | @tsv` 喂对象必报 jq 错;
  #   set -eo pipefail 下命令替换非零退出使赋值非零 → 整脚本静默退出 (combo 400 真因). 改数组形式 + || true 护栏.
  _RO_AUTO_SUMMARY=$(jq -r '[.id, .name, .strategy, (.models // [] | length)] | @tsv' /tmp/omn_ro_auto.json 2>/dev/null || true)
  echo "[init] [readonly] GET /api/combos/auto HTTP $_RO_AUTO_CODE :: auto=[${_RO_AUTO_SUMMARY}]"

  _RO_PROV_CODE=$(curl -s --connect-timeout 5 --max-time 20 -o /tmp/omn_ro_providers.json -w "%{http_code}" -b "$COOKIE_FILE" "$BASE_URL/api/providers" 2>/tmp/omn_ro_providers.err || echo "000")
  _RO_PROV_IDS=$(jq -r '[.. | objects | select((.provider? // "")!="") | select(.enabled? // true) | [.id, .provider] | @tsv] | unique | .[]' /tmp/omn_ro_providers.json 2>/dev/null | tr '\n' ';' || true)
  echo "[init] [readonly] GET /api/providers HTTP $_RO_PROV_CODE :: providers=${_RO_PROV_IDS}"
  echo "[init] [readonly] 三份 GET 完 — Restart B 写跳据此结构 (POST/PUT/PATCH), Restart A 仅读不写."
}

# v4.3.2 [M4]: 压缩全局关闭. PUT 体仅 {"enabled":false} — 不带 defaultMode/autoTriggerTokens (不猜其惰性安全值, 避免"0 阈值=全压"反向事故).
#   决策: 默认全局关闭, 需时按 per-combo 单独启用 ultra. stacked 模式 0.02% 节省 + 上游 #4268 不可靠证据链 → 不保留.
#   原值 (defaultMode/threshold) 留库惰性, 未来 per-combo 启用路径不受影响.
echo "[init] Compression globally disabled (enabled=false; per-combo 启用路径不受影响)..."
curl -s -o "$COMPRESS_RESP_FILE" -w "%{http_code}
" -b "$COOKIE_FILE" \
  -X PUT "$BASE_URL/api/settings/compression" -H "Content-Type: application/json" \
  -d '{"enabled":false}' | sed 's/^/[init] Compression HTTP /'

echo "[init] Resetting circuit breakers (first-init clean start)..."
curl -s -o /dev/null -w "[init] CB reset HTTP %{http_code}
" -b "$COOKIE_FILE" \
  -X POST "$BASE_URL/api/resilience/reset" -H "Content-Type: application/json"

# K5 FIX (审查裁定推荐选项 c):
# API PATCH /api/provider-models 在 3.8.43 源码中仅接受 isHidden 字段,
# 不接受 contextLength / max_input_tokens / max_output_tokens (B1 L2 源码实证:
# route.ts:309 强制 isHidden boolean; updateCustomModel models.ts:591 不处理
# max_tokens; 仅 POST add route.ts:109 接受 max_input/output_tokens).
# 候选此前删除 init 内部 per-model override 逻辑并指向 API PATCH 替代路径 →
# 该路径在源码层不存在, 候选 context override 会静默失败.
# 修复: 保留 init 内部的 per-model 32K override (apply_context_override, 42ea8e7
# 基线原态), 不删; 保留 4632e8c 的"禁用 monitor 自动回写"改动 (L407-409 已删
# monitor 回写段不动). API PATCH 路径在文档中标注为"3.8.43 不支持, 待源码新增
# PATCH 字段支持"——不作为候选 context override 配置路径.
# 自动回写 (confidence-based monitor → model_context_overrides) 仍保持禁用
# (CF-4): init 仅应用一次性 per-model 32768 override, 不跨周期自动标定.

# per-model 32K override (real_context=$_NIM_REAL_CONTEXT) — 42ea8e7 基线原态恢复.
echo "[init] per-model 200K override (real_context=$_NIM_REAL_CONTEXT)..."
OVERRIDE_APPLIED=0; OVERRIDE_SKIPPED=0
apply_context_override() {
  if sqlite3 "$_DB_PATH" \
    "INSERT OR REPLACE INTO model_context_overrides (provider, model_id, real_context, source, refreshed_at)
     VALUES ('nvidia', '$(sql_escape "$1")', $2, 'init', datetime('now'));" 2>/dev/null; then
    OVERRIDE_APPLIED=$((OVERRIDE_APPLIED+1))
  else OVERRIDE_SKIPPED=$((OVERRIDE_SKIPPED+1)); echo "[init]   override FAILED: $1"; fi
}
while IFS= read -r _M; do [ -z "$_M" ] && continue; apply_context_override "$_M" "$_NIM_REAL_CONTEXT"; done < <(build_all_models)
echo "[init] override: $OVERRIDE_APPLIED applied, $OVERRIDE_SKIPPED failed."
# K5 行为预期: init 启动时一次性应用 32K override (real_context=32768) 经 SQLite 直写
# model_context_overrides (source='init'), 不自动回写, 不调 API PATCH. 3.8.43 源码层
# 该直写路径与运行时 loadCustomModels 一致 (models.ts:591 读路径同表), 唯一可用.

echo "[init] ─────────────────────────────────────────────"
echo "[init]   PROFILE=$_PROFILE MODE=$NIM_MODE KEYS=$_ALIVE_KEYS RPM=$_RPM BODY=$_REQUEST_BODY_LIMIT_MB MB"
echo "[init]   POOL_STRATEGY=$_POOL_STRATEGY REAL_CONTEXT=$_NIM_REAL_CONTEXT (per-model override 应用, monitor 自动回写禁用)"
echo "[init] ─────────────────────────────────────────────"

hf_snapshot() {
  # D 总闸: OMN_LOG_TO_DATASET=0 时整段 snapshot 跳过 (稳定后让性能, config+log 皆数据收集层)
  [ "${OMN_LOG_TO_DATASET:-1}" = "1" ] || { echo "[init] snapshot: OMN_LOG_TO_DATASET=0 跳过 (稳定后让性能)."; return 0; }
  [ -z "$HF_TOKEN" ] || [ -z "$OMN_DATASET_REPO" ] && return 0
  echo "[init] HF Dataset snapshot（配置 + 可选 DEBUG log）..."
  local BACKUP_DIR="/tmp/omn-snapshot"; mkdir -p "$BACKUP_DIR"
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

  # ── DB 表快照 (链②) 已删 (2026-07-29 圣上裁砍七成): litestream 已复制整个 storage.sqlite ──
  #   scheduler/init 重复表 JSON = 企业级排场. 真 db 仅 litestream R2 一路 (恢复即全表).
  #   留此注释标撤销点, 将来多人/需直读 db 表 JSON 再启.

  # ── 【⑥+ 】init_vars.json：把脚本运行时变量（profile/TIER/RPM/策略/口径）随快照上传 ──
  #   目的：HF Dataset 侧可回溯本空间的真实初始化参数，无需翻容器日志。
  _arr_json() { # bash 数组 -> JSON 字符串数组（jq 正规转义，防 \"/\\ 破坏 JSON）
    [ "$#" -eq 0 ] && { printf '[]'; return; }
    printf '%s\n' "$@" | jq -R . | jq -s -c .
  }
  { jq -n \
      --arg version "4.3.2" \
      --arg profile "$_PROFILE" \
      --arg mode "$NIM_MODE" \
      --argjson tier_fast "$(_arr_json "${TIER_FAST[@]}")" \
      --argjson tier_stable "$(_arr_json "${TIER_STABLE[@]}")" \
      --argjson tier_restricted "$(_arr_json "${TIER_RESTRICTED[@]}")" \
      --argjson pool_models "$(_arr_json "${NIM_POOL_MODELS[@]}")" \
      --argjson codex_models "$(_arr_json "${NIM_CODEX_MODELS[@]}")" \
      --argjson fast_models "$(_arr_json "${NIM_FAST_MODELS[@]}")" \
      --arg alive_keys "$_ALIVE_KEYS" \
      --arg rpm "$_RPM" \
      --arg concurrent "$_CONCURRENT" \
      --arg min_interval_ms "$_MIN_INTERVAL_MS" \
      --arg pool_strategy "$_POOL_STRATEGY" \
      --arg codex_strategy "$_CODEX_STRATEGY" \
      --arg fallback_strategy "$_FALLBACK_STRATEGY" \
      --arg real_context "$_NIM_REAL_CONTEXT" \
      --arg body_limit_mb "$_REQUEST_BODY_LIMIT_MB" \
      --arg compress_threshold "$_COMPRESS_THRESHOLD" \
      --arg per_key_rpm "${_PER_KEY_RPM}" \
      '{version:$version, profile:$profile, mode:$mode,
        tiers:{fast:$tier_fast, stable:$tier_stable, restricted:$tier_restricted},
        pools:{pool:$pool_models, codex:$codex_models, fast:$fast_models},
        dynamic_rpm:{alive_keys:($alive_keys|tonumber), rpm:($rpm|tonumber),
                     concurrent:($concurrent|tonumber), min_interval_ms:($min_interval_ms|tonumber),
                     per_key_rpm:($per_key_rpm|tonumber)},
        strategies:{pool:$pool_strategy, codex:$codex_strategy, fallback:$fallback_strategy},
        context:{real_context:($real_context|tonumber)},
        limits:{body_limit_mb:($body_limit_mb|tonumber), compress_threshold:($compress_threshold|tonumber)}}'; } > "$BACKUP_DIR/init_vars.json" \
    && echo "[init] snapshot: init_vars.json written" \
    || echo "[init] snapshot: WARN init_vars.json 写入失败"

  # ── 【v4.2.3·⑨ 】DEBUG log 上传到 Dataset（debug_<时间戳>.log）──
  #   仅 DEBUG 模式 + INIT_LOG 存在即启 (D 闸 OMN_LOG_TO_DATASET 已在 hf_snapshot 首统管, 旧 NIM_DEBUG_LOG_TO_DATASET 冗闸已去, 圣旨令2).
  #   上传前字段级脱敏: Authorization/NIM_KEY/Cookie/Set-Cookie/Bearer 替换为 <REDACTED> (sed 5 = omn_redact 默1-5 同源).
  #   与 scheduler capture_init 双路并行不冲突: 一次性 upload_folder 真终态兜底 (capture_loop 60s 一轮可能漏 init exit 后尾段).
  #   本地滚动清理：只保留最近 NIM_DEBUG_LOG_KEEP(默认5) 个。
  if [ "$NIM_MODE" = "DEBUG" ] && [ -n "$INIT_LOG" ] && [ -f "$INIT_LOG" ]; then
    local _keep=${NIM_DEBUG_LOG_KEEP:-5}
    local _dbg="$BACKUP_DIR/debug_$(basename "$INIT_LOG" | sed 's/^init_//')"
    cp -f "$INIT_LOG" "$_dbg" 2>/dev/null \
      && echo "[init] snapshot: 附带 DEBUG log -> debug_$(basename "$INIT_LOG" | sed 's/^init_//')" \
      || echo "[init] snapshot: WARN 复制 DEBUG log 失败，跳过。"
    # 字段级脱敏 (红线1 动态: 不上传凭据明文)
    if [ -f "$_dbg" ]; then
      sed -i -E \
        -e 's/(Authorization:[[:space:]]*Bearer[[:space:]]+)[A-Za-z0-9._\-]+/\1<REDACTED>/gI' \
        -e 's/(NIM_KEY=|nvapi-)[A-Za-z0-9._\-]+/\1<REDACTED>/gI' \
        -e 's/(Cookie:[[:space:]]+)[^[:space:]]+/\1<REDACTED>/gI' \
        -e 's/(Set-Cookie:[[:space:]]+)[^[:space:]]+/\1<REDACTED>/gI' \
        -e 's/(Bearer )[A-Za-z0-9._\-]+/\1<REDACTED>/g' \
        "$_dbg" 2>/dev/null || true
    fi
    # 本地滚动清理：只保留最近 _keep 个 init_*.log (LOG_DIR=_raw, capture_init 读完不再清, 故此清防 _raw 爆)
    if [ -d "$LOG_DIR" ]; then
      ls -1t "$LOG_DIR"/init_*.log 2>/dev/null | tail -n +$(( _keep + 1 )) | xargs -r rm -f 2>/dev/null || true
    fi
  fi

  python3 - <<'PYEOF'
import os
from datetime import datetime, timezone
from huggingface_hub import HfApi
from huggingface_hub.utils import HfHubHTTPError
try:
    api = HfApi(token=os.environ["HF_TOKEN"])
    api.upload_folder(folder_path="/tmp/omn-snapshot", path_in_repo="save",
        repo_id=os.environ["OMN_DATASET_REPO"], repo_type="dataset",
        commit_message=f"Sync save - {datetime.now(timezone.utc).isoformat()}")
    print("[init] HF Dataset uploaded.")
except Exception as e:
    # C2 fail-open: HF_TOKEN 权限不足(403/Write 权限缺)或网络异常 → 不让 init 整进程 exit 1
    #   (set -e 下 python traceback exit 1 会触发 init rc=1 → Space supervisor 误判不健康重启 → crashloop)。
    #   数据主路径是 R2 Litestream, 快照仅为冗余; 此处静默告警跳过, 保 gate/上游/init 主体不崩。
    msg = str(e).replace(os.environ.get("HF_TOKEN", "") or "x", "<REDACTED>")
    print(f"[init] snapshot: WARN HF Dataset 上传失败 (fail-open 跳过, 数据主路径 R2 不受影响): {type(e).__name__}")
    if isinstance(e, HfHubHTTPError) and "403" in msg:
        print("[init] snapshot: WARN 403 Forbidden — HF_TOKEN 缺 write 权限, 检查 Space Secret E 项 HF_TOKEN scope (需 dataset-write)")
PYEOF

  # ── omniroute 插件静态包推公开 Bucket (圣上令扩三链 ③) ──
  #   OMN_BUCKET_SYNC=1 触发 omn_bucket_sync.py 一次性 walk 插件包推公开 S3 Bucket.
  #   init-nim-keys.sh 调用方已 set -e, 故 bucket-sync 失败须降级 skip 不阻主 init.
  if [ "${OMN_BUCKET_SYNC:-0}" = "1" ] && [ -x /logic/omn_bucket_sync.py ]; then
    echo "[init] omniroute 插件包推公开 Bucket (OMN_BUCKET_SYNC=1)..."
    python3 /logic/omn_bucket_sync.py >/dev/null 2>&1 \
      && echo "[init] 插件包 Bucket 同步完成" \
      || echo "[init] snapshot: WARN 插件包 Bucket 同步失败 (降级 skip, 主 init 不阻)"
  fi
}

# ── 增量模式（⑧ 增量门放宽：任一 nim-* combo 或 INIT_MARKER 存在）──
if [ -f "$_DB_PATH" ]; then
  COMBO_COUNT=$(sqlite3 "$_DB_PATH" "SELECT COUNT(*) FROM combos WHERE name IN ('nim-pool','nim-codex');" 2>/dev/null || echo 0)
  if [ "${COMBO_COUNT:-0}" -gt 0 ] || [ -f "$INIT_MARKER" ]; then
    echo "[init] Incremental mode."
    # ⑤ 只清"已过期"熔断，保留仍在冷却窗内的历史信号
    sqlite3 "$_DB_PATH" "DELETE FROM domain_circuit_breakers WHERE cooldown_until < datetime('now');" 2>/dev/null || true
    check_nim_model_health
    # ⑦ 增量也走幂等 upsert（同时修复 deprecated 与撞名）
    mapfile -t POOL_ALIVE  < <(filter_alive "${NIM_POOL_MODELS[@]}")
    mapfile -t CODEX_ALIVE < <(filter_alive "${NIM_CODEX_MODELS[@]}")
    upsert_combo "nim-pool"  "$_POOL_STRATEGY"  "${POOL_ALIVE[@]}"
    upsert_combo "nim-codex" "$_CODEX_STRATEGY" "${CODEX_ALIVE[@]}"
    context_accumulator_update
    hf_snapshot
    echo "[init] Done (incremental). v4.3.2"
    exit 0
  fi
else
  echo "[init] DB not present. First-time init."
fi

check_nim_model_health

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

context_accumulator_update
# C2 fail-open 双保险: hf_snapshot 内 python upload 异常已 try/except 降级 WARN exit 0;
#   此处 ||true 兜底函数级 (curl/jq 等非 python 段若异常), 防 set -e 触发 init 整进程 exit 1 致 Space crashloop。
#   snapshot 仅冗余备份, R2 是数据主路径, 失败不致命。
hf_snapshot || true

touch "$INIT_MARKER"
echo "[init] Final health check..."
HEALTH_FILE="$(_resp omniroute-final-health.json)"
HEALTH_HTTP=$(curl -s -o "$HEALTH_FILE" -w "%{http_code}" "$BASE_URL/api/monitoring/health" 2>/dev/null || echo "000")
[ "$HEALTH_HTTP" = "200" ] && echo "[init]   Status: $(jq -r '.status // "unknown"' "$HEALTH_FILE") / $(jq -r '.version // "unknown"' "$HEALTH_FILE")"
echo "[init] Done (first-init). v4.3.2"
