#!/bin/bash
set -eo pipefail

# ─────────────────────────────────────────────────────────────
# NIM 上游 initializer  v4.3.2（基于 v4.2.3；v4.3.1 固定档限流故障后修正）
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
# DEBUG init.log → logs/raw 临时区, capture_init 尾追+omn_redact 后写 save (类 C 脱敏)
# (DATA_DIR 由 entrypoint export, 与 scheduler RAW_DIR 对齐; 缺省回 /data 兼容)
LOG_DIR="${DATA_DIR:-/data}/logs/raw"
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
COOKIE_FILE="/tmp/omn-cookie.txt"

LOGIN_RESP_FILE="$(_resp omn-login.json)"
KEY_RESP_FILE="$(_resp omn-key-response.json)"
PROVIDERS_FILE="$(_resp omn-providers.json)"
RESILIENCE_RESP_FILE="$(_resp omn-resilience.json)"
SETTINGS_RESP_FILE="$(_resp omn-settings.json)"
COMPRESS_RESP_FILE="$(_resp omn-compress.json)"
COMBO_RESP_FILE="$(_resp omn-combo.json)"
VERSION_FILE="$(_resp omn-version.json)"

REGISTERED=0; SKIPPED=0; FAILED=0

# ══ 通用多 provider 配置表（NIM_KEYS 多 key 模式推广到免费提供商）═══════
#   id|node_name|prefix|base_url|env_keys_var|max_models|model_prefix
#   id          = 上游 连接 provider 值 (须 isOpenAICompatibleProvider 识别, 走 openai-compatible 节点路)
#   node_name   = provider-node 名称 (POST /api/provider-nodes {name})
#   prefix      = 模型名前缀 (combo 引用名 = ${prefix}/${modelId}; executor 用它拼请求)
#   base_url    = OpenAI 兼容端点 (探活 + 动态枚举 /v1/models + executor 上游 URL)
#   env_keys_var= 该 provider 的多 key env 变量名 (每行一个 key, NIM_KEYS 式; 空则跳过该 provider)
#   max_models  = 动态枚举模型数上限 (防 OpenRouter 上千模型撑爆 combo)
#   model_prefix= 枚举模型名前缀 (给裸模型 ID 加前缀; 空=枚举原样, 非空=provider/裸名).
#                 实测 (2026-08-27 Zen直连上游铁证): 两家都认**裸名** (枚举原样), 不认双层前缀.
#                 sensenova: 认自带前缀裸名 (sensenova-u1.5-lite→200), 不认双层 (sensenova/sensenova-u1.5-lite→404);
#                 amd: 认裸名 (DeepSeek-V4-Flash→200), 不认双层 (amd/DeepSeek-V4-Flash→404 "Provider amd not found").
#                 → 双层前缀理论**证伪**, sensenova/amd model_prefix 空 = 枚举原样.
#                 mistral 认裸名 devstral-2512, openrouter 枚举即 org/model. 全 provider 枚举原样即可.
# 每 provider 建 1 个 openai-compatible 节点定 base_url, 再按 key 建 N 个连接指同节点
# (providers/route.ts:125-143 建连接时自动 providerSpecificData.baseUrl=node.baseUrl,
#  executor default.ts:150-155 读 providerSpecificData.baseUrl 覆盖每连接上游 URL).
# NVIDIA 保留现役 NIM_KEYS/nim-pool/nim-codex 专属路径不动, 仅额外走通用表再挂 FT 族.
declare -a PROVIDERS=(
  "nvidia|nvidia-node|nvidia|${NVIDIA_BASE_URL:-https://integrate.api.nvidia.com}|NIM_KEYS|20|"
  # gemini: 2026-09-01 Zen令 — 内置 provider (frontier-labs.ts:58 id:"gemini" + registry baseUrl 现成).
  #   format:"gemini" 原生 generateContent 协议 (buildGeminiGenerateContentUrl, 非 openai 兼容端点).
  #   registry 内置 8 模型: gemini-3.7-flash / 3.1-pro-preview / 3.1-flash-lite / 3-flash-preview /
  #   3.1-flash-tts-preview / 2.5-pro / 2.5-flash / 2.5-flash-lite.
  #   第 9 字段 static_models = registry 7 个 chat 模型 (方案A, 排除 3.1-flash-tts-preview 防 TTS 污染,
  #   同 sensenova 排除 u1-fast 图片模型/mistral 排除 embed 逻辑).
  #   历史: 2026-08-26 曾因 google 免费层对数据中心出站 IP 地理风控 "User location is not supported"
  #   注释停用 (HF 容器/FT Worker 数据中心 IP 直接拒, 本机家宽 IP 才通). 2026-09-01 恢复为内置轨
  #   统一分类 (双轨归位), 地理风控未解 — 仅分类统一, 路由仍受出站 IP 限制.
  #   内置 baseUrl (registry) = https://generativelanguage.googleapis.com/v1beta/models (原生协议,
  #   provider=gemini 连接注册后 executor 直接用它, 与旧 google-node 的 .../v1beta/openai 端点不同).
  "gemini|gemini-node|gemini|https://generativelanguage.googleapis.com/v1beta/models|GEMINI_KEYS|20||builtin|gemini-3.7-flash gemini-3.1-pro-preview gemini-3.1-flash-lite gemini-3-flash-preview gemini-2.5-pro gemini-2.5-flash gemini-2.5-flash-lite"
  # openrouter: 2026-08-31 Zen令 — 内置 provider (gateways.ts:89 id:"openrouter" + registry baseUrl 现成),
  #   第 8 字段 builtin 同 sensenova. 保持动态枚举 (passthroughModels:true, 全模型透传, max=100 不变);
  #   第 9 字段 static_models 留空 → 走默认枚举, 与改内置前 node 套件行为一致 (仅换短名前缀).
  "openrouter|openrouter-node|openrouter|https://openrouter.ai/api/v1|OPENROUTER_KEYS|100||builtin|"
  # sensenova: 第 8 字段 = builtin → 走内置 provider (不建 provider-node, 连接/模型/combo/dpv4 全挂
  #   provider=sensenova 内置名, 短名通, 与 nvidia 同模式). 内置 baseUrl 现成
  #   (config/providers/registry/sensenova/index.ts: https://token.sensenova.cn/v1/chat/completions),
  #   executor 直接用它当上游不拼 path. 2026-08-28 Zen令: sensenova 全部走内置.
  #   字段序 = id|node_name|prefix|base_url|env_keys_var|max_models|model_prefix(空)|mode|static_models
  #   (第 7 字段 model_prefix 须保留空位, builtin 须放第 8 字段, 否则 _mpre 错位吞掉 mode.)
  #   第 9 字段 static_models = 静态模型白名单 (空格分隔). 非空 → 跳过动态枚举上游 /models,
  #   直接用白名单注册 (方案A: sensenova 模型少且明确, 避免上游 /models 带回 u1-fast 图片模型误入 chat).
  #   2026-08-28 Zen令方案A: 白名单 = 内置 registry 3 个 chat 模型 (sensenova-6.7-flash-lite/deepseek-v4-flash/glm-5.2).
  "sensenova|sensenova-node|sensenova|https://token.sensenova.cn/v1|SENSENOVA_KEYS|20||builtin|sensenova-6.7-flash-lite deepseek-v4-flash glm-5.2"
  # mistral: 2026-08-31 Zen令 — 内置 provider (frontier-labs.ts:117 id:"mistral" + registry baseUrl 现成).
  #   第 8 字段 builtin 同 sensenova; 第 9 字段 static_models = registry 5 个 chat 模型 (方案A,
  #   模型少且明确, 避免上游 /models 带回 mistral-embed/codestral-embed 嵌入模型误入 chat).
  "mistral|mistral-node|mistral|https://api.mistral.ai/v1|MISTRAL_KEYS|20||builtin|mistral-large-latest mistral-medium-3-5 mistral-small-latest devstral-latest codestral-latest"
  # amd: 写死 /v1 (sensenova 模式). 勿用 ${AMD_BASE_URL:-...} env 覆盖 — Secret 若配无 /v1 旧值会覆盖默认值致 404 (boot 2026-08-26 实测 base 无 /v1).
  "amd|amd-node|amd|https://developer.amd.com.cn/radeon/api/v1|AMD_KEYS|20|"
)
# ── 死 provider 轨 disabled 标记 (2026-09-03 Zen令: 标记 disabled 保留代码, 可逆) ──
# openrouter/mistral/gemini 三条内置轨 key 无效空转 (09-02 审计 CredentialHealth 全 Invalid API key,
# 完整注册机制每 boot 都跑但交付零请求 = 纯噪音). 但 08-31/09-01 刚下令内置化 → 不删行不砍分支,
# 仅跳过注册 + FT 绑族; key 复活后从本数组删名即恢复 (可逆, 不推翻内置化令).
declare -a DISABLED_PROVIDERS=("gemini" "openrouter" "mistral")
# 复核期: Zen令(2026-09-03)后 2 周 = 2026-09-17 前复核 key 是否复活; 复活即从本数组删名,
# 勿让 dead 轨永久空转 (方案#3). 过期仅印 INFO 提醒, 不阻断 boot (fail-open).
DISABLED_REVIEW_BY="2026-09-17"
if [ "$(date +%Y%m%d 2>/dev/null)" -gt "${DISABLED_REVIEW_BY//-/}" ] 2>/dev/null; then
  echo "[init] WARNING: DISABLED_PROVIDERS (gemini/openrouter/mistral) 已过复核期 $DISABLED_REVIEW_BY, 请确认 key 是否复活"
fi

# 判定 provider id 是否被禁用 (ALL_FT_FAMILIES 绑族收集 + _register_multi_provider 注册 共用)
_is_provider_disabled() {
  local _pid="$1" _d
  for _d in "${DISABLED_PROVIDERS[@]}"; do
    [ "$_d" = "$_pid" ] && return 0
  done
  return 1
}

# 全部 provider 族 (含 nvidia, 排除 disabled), 供 FT 桥 bulk-assign 绑族与单桥回退遍历.
declare -a ALL_FT_FAMILIES=()
for _pcfg in "${PROVIDERS[@]}"; do
  IFS='|' read -r _pid _pnode _ppre _pburl _penvv _pmax _mpre <<< "$_pcfg"
  if _is_provider_disabled "$_pid"; then
    echo "[init]   $_pid: DISABLED (key 无效空转), 跳过 FT 绑族"
    continue
  fi
  ALL_FT_FAMILIES+=("$_ppre")
done

# ══ 模型分档 SSOT（对齐现行 NVIDIA 目录）═══════════════════════
TIER_FAST=(
  "deepseek-ai/deepseek-v4-flash-0731"  # 2026-08-27 Zen清单: 编码/Agent 高吞吐首选 (17M 调用/月)
  "nvidia/nemotron-3.5-lightning-30b-a3b"  # 2026-08-27 Zen清单: 速度/成本效率之王 (8/11 新增)
  "minimaxai/minimax-m3"  # 2026-08-27 Zen清单: 多模态 MoE
  # 移除(下架/非最出色, 2026-08-27): z-ai/glm-5.2 / qwen/qwen3.8-max-preview / nvidia/llama-3.1-nemotron-nano-8b-v1 / nvidia/nemotron-3-nano-30b-a3b
)
TIER_STABLE=(
  "deepseek-ai/deepseek-v4-pro-0813"  # 2026-08-27 Zen清单: 智能上限最高 (~56 分, 1.6T MoE)
  "nvidia/nemotron-3-ultra-550b-a55b"  # 2026-08-27 Zen清单: 综合最强可靠 (Frontier 级, 52M 调用/月, 1M 上下文)
  "moonshotai/kimi-k3"  # 2026-08-27 Zen清单: 新上架 404 不稳定, 待观察潜在新王
  "zhipuai/glm-5.3"  # 2026-08-27 Zen清单: 等待中 (权重 8/28 开放未上架, filter_alive 探目录无会剔出 combo)
  # 移除(下架/非最出色, 2026-08-27): nvidia/nemotron-3-super-120b-a12b / google/gemma-4-31b-it
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
  "deepseek-ai/deepseek-v4-pro-0813"  # 2026-08-27 Zen清单: codex 用最强 pro
  "deepseek-ai/deepseek-v4-flash-0731"  # 2026-08-27 Zen清单: 编码高吞吐首选
  "nvidia/nemotron-3-ultra-550b-a55b"  # 2026-08-27 Zen清单: 综合最强可靠
  "nvidia/nemotron-3.5-lightning-30b-a3b"  # 2026-08-27 Zen清单: 速度/成本之王
)
NIM_FAST_MODELS=(
  "deepseek-ai/deepseek-v4-flash-0731"  # 2026-08-27 Zen清单: 编码高吞吐
  "nvidia/nemotron-3.5-lightning-30b-a3b"  # 2026-08-27 Zen清单: 速度之王
  "minimaxai/minimax-m3"  # 2026-08-27 Zen清单: 多模态 MoE
)
NIM_EXTRA_MODELS=()  # 2026-08-27 Zen清单: 原 kimi-k3/qwen3.8-max/nano-8b-v1/nemotron-3-nano-30b 全入 TIER 或下架, 清空

build_all_models() {
  printf '%s
' "${NIM_POOL_MODELS[@]}" "${NIM_CODEX_MODELS[@]}" "${NIM_EXTRA_MODELS[@]}" | awk '!seen[$0]++'
}
# 强加 provider 前缀 (默认 nvidia 兼容 NVIDIA 主路径; 多 provider 传 node.id 路由到 openai-compatible 连接).
# 模型名保留 (含自身前缀, 如 moonshotai/kimi-k3): 只加 provider 前缀做连接路由.
models_to_json() { local _pre="${1:-nvidia}"; shift; printf '%s\n' "$@" | sed "s|^|${_pre}/|" | jq -R '{model: .}' | jq -s -c .; }

# ══ combo 策略白名单（3.8.43 实测合法枚举，不含 quota-share）═════
_VALID_STRATS="priority weighted round-robin fill-first p2c random least-used cost-optimized reset-aware reset-window headroom strict-random auto lkgp context-optimized fusion"
# v4.3: 删 context-relay (CF-1/红线: NIM 永不用 context-relay; cf-worker 已删, 无外部 Relay 层); 保留 fusion (Codex 池可用).
_is_valid_strat() { printf '%s' "$_VALID_STRATS" | grep -qw -- "$1"; }

# ══ 【⑦ 】幂等 upsert：存在则 PUT，不存在才 POST ═══════════════
upsert_combo() {
  local NAME="$1" STRAT="$2" PREFIX="${3:-nvidia}"; shift 3; local MODELS=("$@")
  _is_valid_strat "$STRAT" || { echo "[init] upsert_combo: '$STRAT' 非法 -> round-robin"; STRAT="round-robin"; }
  [ "${#MODELS[@]}" -eq 0 ] && { echo "[init] upsert_combo: $NAME 无存活模型，跳过。"; return 0; }
  local BODY CID CODE F
  BODY=$(jq -n --arg name "$NAME" --arg strat "$STRAT" \
               --argjson models "$(models_to_json "$PREFIX" "${MODELS[@]}")" \
               '{name:$name, strategy:$strat, models:$models}')
  # R3+ Restart A (i′ 方案)→ Task C1 终态 (Zen源码 v3.8.43@b729a8f 实证裁决):
  # 旧式 `.combos[]? // .[]? | select(.name==$n)` 两病: ① `//` 优先级低于 `|` 失控
  # → CID 永空 → 永远 POST → 重名 400 死循环(幂等失效); ② 空 combos 时 `.[]?` 回退遍历对象值,
  # 对数组值取 `.name` 抛 "Cannot index array with string"(4.2.3 生产 14:23 实测, 4.3.2 同病)。
  # 修正式 (数组/对象双容 + 对象守卫): 根为数组直接遍历, 根为对象取 .combos//.data 字段,
  # select 加 `type=="object"` 守卫防对非对象值(数组值)取 .name 抛错 — 兼两种响应结构 + 空库首跑。
  # ⚠ 2026-09-05 暂缓: 本处判码修复会让 GET 失败时由"盲目 POST"改为 fail-closed return 1,
  #   属可感知行为变更 (原本侥幸可成功的场景将明确失败). Zen 裁定本轮只推无行为变更项,
  #   故此处保持原样, 待 staging 回归后再单独处理.
  CID=$(curl -s -b "$COOKIE_FILE" "$BASE_URL/api/combos" \
        | jq -r --arg n "$NAME" '(if type=="array" then . else (.combos // .data // []) end) | .[]? | select(type=="object" and .name==$n) | .id' | head -n1)
  F="$(_resp omn-combo-$NAME.json)"
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

# ══ Task C2: 僵尸/重复 nvidia 连接 GC (Zen源码 v3.8.43@b729a8f 实证裁决) ══
# GET /api/providers 返 {connections:[...]} (字段名非 .providers, 旧误名会静默失效)。
# POST /api/providers 无 name 查重 → 每 boot 重复注册累积; init 内 409 分支是死代码 (POST 不校验 name)。
# GC 职责二合一: ① 僵尸(name nim-NN 编号 > 当前 NIM_KEYS 总数的连接删)
#                ② 同名重复(留首个 idx=0, 余删)
# 删除走批量 DELETE /api/providers {ids:[]} 一次调用 (≤100/批)。幂等(再跑无待删)。
gc_stale_providers() {
  local _GC_FILE _GC_HTTP _NIM_TOTAL _DEL_JSON _DEL_COUNT _CLEAN_IDS
  _GC_FILE="$(_resp omn-providers-gc.json)"
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
  _DEL_BODY="$(_resp omn-providers-del.json)"
  _DEL_HTTP=$(curl -s -o "$_DEL_BODY" -w "%{http_code}" -b "$COOKIE_FILE" \
    -X DELETE "$BASE_URL/api/providers" -H "Content-Type: application/json" -d "$_CLEAN_IDS")
  echo "[init] gc_stale: 删除 $_DEL_COUNT 个僵尸/重复 nvidia 连接 (批量 DELETE /api/providers HTTP $_DEL_HTTP, 上限 max=$_NIM_TOTAL)"
}

# ══ Task C3: 清 上游 Health Autopilot 陈旧错态 (clear_stale_connection_error) ══
# 病: 上游 冷却(60s)过期回活后 lastError/testStatus 不自动清 → Autopilot 检 stale_connection_error
#      → 回活 account 被路由偏置绕开。dev Space ephemeral (R2 无副本每 boot 空库) → external
#      manage key 不持久, 无法走 dev/scripts/clear-stale-nim-errors.sh; 故 init boot 自清 (cookie 鉴权)。
# 源: 3.8.48 src/app/api/providers/health-autopilot/{route.ts GET, actions/route.ts POST}
#      + src/lib/monitoring/providerHealthAutopilot.ts executeProviderHealthAutopilotAction
#      actionSchema: {type:"clear_stale_connection_error", target:{provider,connectionId}, preconditionsHash, confirm}
# 闸: OMN_CLEAR_STALE 默1开 =0 跳整段 (仿 OMN_LOG_TO_DATASET 闸)。fail-open: 清失败不杀 boot。
# 终态连接 (banned/expired/credits_exhausted) 源 409 拒不清 (isTerminalConnection) → 印 INFO 跳, 非 cooldown 本身。
clear_stale_nim_errors() {
  if [ "${OMN_CLEAR_STALE:-1}" != "1" ]; then
    echo "[init] clear_stale: OMN_CLEAR_STALE!=1 跳过清陈旧错态"; return 0
  fi
  local _AP_FILE _AP_HTTP
  _AP_FILE="$(_resp omn-autopilot.json)"
  _AP_HTTP=$(curl -s -o "$_AP_FILE" -w "%{http_code}" -b "$COOKIE_FILE" \
    "$BASE_URL/api/providers/health-autopilot?provider=nvidia&includeHealthy=false&includeActions=true")
  if [ "$_AP_HTTP" != "200" ]; then
    echo "[init] clear_stale: GET /api/providers/health-autopilot HTTP $_AP_HTTP 跳过 (fail-open)"; return 0
  fi
  # 提 issues[].actions[] 里 type=clear_stale_connection_error 的 (connectionId, preconditionsHash)
  # set +eo pipefail 抬门防空 stale 态 pipefail 杀 init (照 gc_stale 范式 line 174)
  set +eo pipefail
  local _STALE_JSON
  _STALE_JSON=$(python3 -c '
import json, sys
try:
    r = json.load(open(sys.argv[1]))
except Exception as e:
    print("[]", end=""); sys.exit(0)
if isinstance(r, dict) and r.get("error"):
    print("[]", end=""); sys.exit(0)
out = []
for iss in (r.get("issues", []) if isinstance(r, dict) else []):
    for a in (iss.get("actions", []) if isinstance(iss, dict) else []):
        if a.get("type") == "clear_stale_connection_error":
            tgt = a.get("target", {}) if isinstance(a, dict) else {}
            cid = tgt.get("connectionId", "")
            h = a.get("preconditionsHash", "")
            if cid and h:
                out.append({"connectionId": cid, "preconditionsHash": h})
print(json.dumps(out))
' "$_AP_FILE" 2>/dev/null)
  set -eo pipefail
  _STALE_JSON="${_STALE_JSON:-[]}"
  local _STALE_COUNT
  _STALE_COUNT=$(printf '%s' "$_STALE_JSON" | python3 -c 'import json,sys; print(len(json.load(sys.stdin)))' 2>/dev/null || printf '0')
  if [ "$_STALE_COUNT" -le 0 ]; then
    echo "[init] clear_stale: 无陈旧错态 (Autopilot issues=0 stale_connection_error)"; return 0
  fi
  echo "[init] clear_stale: 检出 $_STALE_COUNT 个 stale_connection_error, 逐清..."
  local _OK=0 _SKIP=0 _CID _HASH _ACT_CODE
  while IFS=$'\t' read -r _CID _HASH; do
    [ -z "$_CID" ] && continue
    _ACT_CODE=$(curl -s -o /tmp/omn_clear_act.json -w "%{http_code}" -b "$COOKIE_FILE" \
      -X POST "$BASE_URL/api/providers/health-autopilot/actions" \
      -H "Content-Type: application/json" \
      -H "Origin: $BASE_URL" \
      -d "$(python3 -c '
import json, sys
print(json.dumps({
  "type": "clear_stale_connection_error",
  "target": {"provider": "nvidia", "connectionId": sys.argv[1]},
  "preconditionsHash": sys.argv[2],
  "confirm": True
}))
' "$_CID" "$_HASH")")
    if [ "$_ACT_CODE" = "200" ] || [ "$_ACT_CODE" = "201" ]; then
      _OK=$((_OK+1))
    elif [ "$_ACT_CODE" = "409" ]; then
      _SKIP=$((_SKIP+1))   # 终态连接 (banned/expired) 源拒不清, 正常跳
    else
      echo "[init] clear_stale:    WARN connectionId=$(printf %.12s "$_CID") HTTP $_ACT_CODE (跳过, fail-open)"
      _SKIP=$((_SKIP+1))
    fi
  done < <(printf '%s' "$_STALE_JSON" | python3 -c '
import json,sys
for a in json.load(sys.stdin):
    print(f"{a[\"connectionId\"]}\t{a[\"preconditionsHash\"]}")
')
  echo "[init] clear_stale: 清完 (OK=$_OK skip/terminal=$_SKIP total=$_STALE_COUNT)"
}

# ══ 按存活 Key 数动态推导 RPM/并发 ═════════════════════════════
_count_alive_keys() { printf '%s
' "$NIM_KEYS" | sed '/^[[:space:]]*$/d' | wc -l; }
_ALIVE_KEYS=$(_count_alive_keys)
# v4.3.2 [M1]: 限流随存活 Key 数动态推导(替换 v4.3.1 固定档 28/3/2200 — 故障原型根因).
#   固定档不随 alive 伸缩 = 2026-07-21 事件设计根因: alive 变而限流不随动.
#   三式逐字对齐 baseline-4.2.3 (旧生产 25 key 健康运行即正解证据):
#     _RPM            = alive * NIM_PER_KEY_RPM(默35)      封顶 300 (硬上限, 防超 API 限)
#     _CONCURRENT     = alive * NIM_PER_KEY_CONCURRENT(默3) 保底 3  (单 key 也有并发槽)
#     _MIN_INTERVAL_MS = 60000 / _RPM                      (整数截断; _RPM>0 守卫, 下界 200ms)
#   双层并发槽澄清(承 v4.3 注释):
# (A) 上游: 上游 requestQueue.concurrentRequests (本 init PATCH /api/resilience 落定) — 上述 _CONCURRENT 主力杠杆.
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
#   上游 表中只须注册一行代理(host=127.0.0.1 port=8080), 全 nvidia provider 走桥 → 桥内轮换 8 Worker.
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
  # 桥未启(entrypoint §1.5 fail-open 降级) → 不注册, 免 nvidia 指死桥反停业务.
  # 单桥判 FT_PID (现役回退); 多桥判 FT_PIDS (entrypoint export).
  if [ -z "${FT_PID:-}" ] && [ -z "${FT_PIDS:-}" ]; then
    echo "[init] FT proxy: skip (FT 桥未启/降级, 不注册死代理)."; return 0
  fi
  local _HOST="${FT_PROXY_HOST:-127.0.0.1}"
  local _BRIDGES_JSON="/logic/flaretunnel_bridges.json"
  # 全局导出当前 FT proxy id: _register_multi_provider 的 node 模式段用它补绑 UUID (2026-09-03).
  _FT_PROXY_ID=""

  # 内联: 单桥 proxy 注册 (POST 建 + PUT bulk-assign 绑族).
  #   $1=proxy 名, $2=port, $3..=family 数组 (provider 家族名常量串, 如 "nvidia"/"github-models").
  _ft_one() {
    local _nm="$1" _pt="$2"; shift 2
    local _fams=("$@")
    # 无 providers 族: 只建裸 proxy 不绑 (L312 if 守卫跳过 bulk-assign), 留桥待指派.
    [ "${#_fams[@]}" -eq 0 ] && echo "[init] FT proxy ${_nm}: 提示 无 providers 族, 只建裸 proxy 不绑."
    local _BODY _RESP _HTTP
    _BODY=$(jq -n --arg h "$_HOST" --argjson p "$_pt" --arg n "$_nm" \
      '{name:$n, type:"http", host:$h, port:$p}')
    _RESP=$(_resp "ft_proxy_${_nm}.json")
    _HTTP=$(curl -s -o "$_RESP" -w "%{http_code}" -b "$COOKIE_FILE" \
      -X POST "$BASE_URL/api/v1/management/proxies" \
      -H "Content-Type: application/json" -d "$_BODY" 2>/dev/null || echo "000")
    case "$_HTTP" in
      200|201) : ;;
      409)     echo "[init] FT proxy ${_nm}: WARN HTTP 409 (已存在; POST 无查重, 罕见. 继续试绑). " ;;
      *)       echo "[init] FT proxy ${_nm}: WARN 注册 HTTP $_HTTP ($(head -c 200 "$_RESP" 2>/dev/null)). 跳此桥."; return 1 ;;
    esac
    local _pid=""; _pid=$(jq -r '.id // empty' "$_RESP" 2>/dev/null)
    [ -z "$_pid" ] && { echo "[init] FT proxy ${_nm}: WARN POST body 无 id 字段, 无法绑族. 跳此桥."; return 1; }
    echo "[init] FT proxy ${_nm}: 建 ✓ (host=${_HOST}:${_pt} → id=${_pid}, HTTP $_HTTP)"
    _FT_PROXY_ID="$_pid"
    if [ "${#_fams[@]}" -gt 0 ]; then
      local _ids_json; _ids_json=$(printf '%s\n' "${_fams[@]}" | jq -R . | jq -s .)
      local _BA _BAR _BAC
      _BA=$(jq -n --arg s "provider" --argjson ids "$_ids_json" --arg p "$_pid" \
        '{scope:$s, scopeIds:$ids, proxyId:$p}')
      _BAR=$(_resp "ft_bulkassign_${_nm}.json")
      _BAC=$(curl -s -o "$_BAR" -w "%{http_code}" -b "$COOKIE_FILE" \
        -X PUT "$BASE_URL/api/v1/management/proxies/bulk-assign" \
        -H "Content-Type: application/json" -d "$_BA" 2>/dev/null || echo "000")
      local _upd=""
      _upd=$(jq -r '.updated // "?"' "$_BAR" 2>/dev/null)
      case "$_BAC" in
        200|201) echo "[init] FT proxy ${_nm}: 绑族 ✓ (provider scope, scopeIds=[${_fams[*]}], updated=${_upd})" ;;
        *)       echo "[init] FT proxy ${_nm}: WARN bulk-assign HTTP $_BAC ($(head -c 200 "$_BAR" 2>/dev/null)). 族未绑." ;;
      esac
    fi
  }

  if [ -f "$_BRIDGES_JSON" ] && jq -e '. | type=="array" and length>0 and all(.[]; has("port") and has("workers"))' "$_BRIDGES_JSON" >/dev/null 2>&1; then
    local _nb
    _nb=$(jq 'length' "$_BRIDGES_JSON" 2>/dev/null || echo 0)
    [ "$_nb" -gt 30 ] && _nb=30
    local _i=0
    echo "[init] FT proxy: 多桥模式, 读 $_BRIDGES_JSON 绑 $_nb 桥."
    while [ "$_i" -lt "$_nb" ]; do
      local _b_name _b_port
      _b_name=$(jq -r ".[$_i].name // \"bridge-$_i\"" "$_BRIDGES_JSON" 2>/dev/null)
      _b_port=$(jq -r ".[$_i].port" "$_BRIDGES_JSON" 2>/dev/null)
      local _fams=()
      mapfile -t _fams < <(jq -r ".[$_i].providers[]?" "$_BRIDGES_JSON" 2>/dev/null)
      _ft_one "$_b_name" "$_b_port" "${_fams[@]}" || true
      _i=$((_i+1))
    done
    # 多桥 healthz 读首桥 (entrypoint 首桥代整体).
    local _p0
    _p0=$(jq -r '.[0].port' "$_BRIDGES_JSON" 2>/dev/null)
    [ -n "$_p0" ] && echo "[init] FT bridge healthz: $(curl -s -m 3 "http://${_HOST}:${_p0}/healthz" 2>/dev/null || echo '{}')"
    return
  fi

  # 回退单桥 (JSON 缺/空/非法): 现役逻辑. scopeId 修为家族名 (修连接 ID 哑路径 Bug).
  # 泛化: 绑 ALL_FT_FAMILIES (nvidia+google+openrouter+sensenova+mistral+amd), 各 provider 出口都走 FT 轮换 IP.
  local _PORT="${FT_PROXY_PORT:-8080}"
  local _fams=()
  for _f in "${ALL_FT_FAMILIES[@]}"; do [ -n "$_f" ] && _fams+=("$_f"); done
  [ "${#_fams[@]}" -gt 0 ] && _ft_one "flaretunnel-8080" "$_PORT" "${_fams[@]}" || true
  echo "[init] FT bridge healthz: $(curl -s -m 3 "http://${_HOST}:${_PORT}/healthz" 2>/dev/null || echo '{}')"
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
echo "[init] Starting NIM 上游 initializer v4.3.2 (profile=$_PROFILE, mode=$NIM_MODE) on node $(node -v 2>/dev/null || echo unknown)..."
echo "[init] BASE_URL=$BASE_URL"

[ -z "$INITIAL_PASSWORD" ] && { echo "[init] ERROR: INITIAL_PASSWORD required"; exit 1; }
[ -z "$NIM_KEYS" ] && { echo "[init] ERROR: NIM_KEYS required"; exit 1; }

echo "[init] Waiting for 上游..."
HWAIT=0
until curl -sf "$BASE_URL/api/monitoring/health" > /dev/null 2>&1; do
  sleep 3; HWAIT=$((HWAIT + 3))
  [ "$HWAIT" -ge 180 ] && { echo "[init] FATAL: not ready within 180s"; exit 1; }
done
echo "[init] 上游 up (after ${HWAIT}s)."

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
  echo "[init] Creating 上游 API Key..."
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
#   POST 鉴权死, 会把死 key 全判 alive 放进池, M3 设计前提会塌. 探活模型默认 deepseek-v4-flash-0731
#   (在架快模型, NIM_PROBE_ENABLED=1 临时排障时用; env NIM_PROBE_MODEL 可换).
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
  local _probe_model="${NIM_PROBE_MODEL:-deepseek-ai/deepseek-v4-flash-0731}"
  # X2 (2026-07-31): 并发探活. 串行 7key×30s 重试慢启 5 分钟; 改并发 ≤3 分批 (速率准则 §5,防风控).
  #   32 key 最坏 (全 000 重试 30s) = 11 批 × 30s ≈ 5.5 分钟 (vs 串行 16 分钟). 活 key 200 则主动秒返不占满超时.
  #   临时结果经隔离文件传 idx+http+verbose 段, 主循环串行收判 case (避并发竞写 AUTH_DEAD_KEYS 数组).
  local _probe_concurrency="${NIM_PROBE_CONCURRENCY:-3}"
  [ "$_probe_concurrency" -lt 1 ] 2>/dev/null && _probe_concurrency=1
  [ "$_probe_concurrency" -gt 3 ] 2>/dev/null && _probe_concurrency=3
  # X2.1 重试闸 (2026-07-31 boot 真根①): 000 重试主进程串行 30s×N 卡死慢启(~2.5分). 默 0 跳重试
  #   (首发 000 直接 fail-open alive, NVCF 冷启热身非 key 死, runtime LocalHealthCheck 60s tick 兜底真死 key).
  #   =1 保留旧重试 (二次 30s 宽超时判 403 真死 / 余 alive, 但 30s×重试数串行慢).
  local _retry_enabled="${NIM_PROBE_RETRY_ENABLED:-0}"
  local _retry_tag="重试闸${_retry_enabled}"; [ "$_retry_enabled" = "1" ] && _retry_tag="重试开(000→30s二次)" || _retry_tag="重试关(000→alive)"
  echo "[init] probe_nim_keys_real: 并发$_probe_concurrency 探活 NIM keys via POST /v1/chat/completions (model=$_probe_model, timeout=${_PROBE_TIMEOUT}s/key, 403→dead, 余→alive fail-open, $_retry_tag)..."
  # POST 探活体 (max_tokens=1 最小推理, jq 安全拼参防注入): 2026-07-21 事件签名 = POST 推理 403, 故必须打推理端.
  local _probe_body
  _probe_body=$(jq -nc --arg m "$_probe_model" '{model:$m, messages:[{role:"user", content:"hi"}], max_tokens:1}')
  # keys 入数组 (去空行), 分批并发:
  local _keys=() _rkey
  while IFS= read -r _rkey; do
    _rkey=$(printf '%s' "$_rkey" | tr -d '' | xargs)
    [ -z "$_rkey" ] && continue
    _keys+=("$_rkey")
  done <<< "$NIM_KEYS"
  local _total=${#_keys[@]}
  [ "$_total" -eq 0 ] && { echo "[init] probe: 无 keys, skip"; _PROBE_DONE=1; return 0; }
  # 临时结果目录 (隔离每 key, 避并发竞写; mktemp -d 自动清由 trap)
  local _pr_dir
  _pr_dir=$(mktemp -d -t omn-probe.XXXXXX) || { echo "[init] probe: mktemp fail, 降级串行"; }
  local _use_parallel=1
  [ -z "$_pr_dir" ] && _use_parallel=0
  # F 路证根 (2026-07-31): NIM_PROBE_VERBOSE=1 时 verbose 段写入 _pr_dir/<idx>.verbose (子shell 2>&1 隔离, 主循环串行 cat 入此 log, 保 * Trying/TLS/Connected 定 000 真因).
  local _verbose_mode=0; [ "${NIM_PROBE_VERBOSE:-0}" = "1" ] && _verbose_mode=1
  # 内联单 key 探活子函数 (并发子 shell 调): 结果写 _pr_dir/<idx>.result (单行 http 码) + <idx>.verbose
  _probe_one() {
    local _pidx="$1" _pkey="$2" _pbody="$3" _ptmo="$4" _pverbose="$5" _pdir="$6" _purl="$7"
    local _pb _ph _pv_out=""
    if [ "$_pverbose" = "1" ]; then
      _pb=$(curl -s -v -m "$_ptmo" -w $'\n%{http_code}' -X POST \
        "$_purl/v1/chat/completions" \
        -H "Authorization: Bearer $_pkey" -H 'Content-Type: application/json' \
        -d "$_pbody" 2>&1 || printf '\n000')
      _pv_out=$_pb   # verbose 模 2>&1 已并入 stderr
      _ph=$(printf '%s' "$_pb" | tail -n1)
    else
      _pb=$(curl -s -m "$_ptmo" -w $'\n%{http_code}' -X POST \
        "$_purl/v1/chat/completions" \
        -H "Authorization: Bearer $_pkey" -H 'Content-Type: application/json' \
        -d "$_pbody" 2>/dev/null || printf '\n000')
      _ph=$(printf '%s' "$_pb" | tail -n1)
    fi
    [ -z "$_ph" ] && _ph="000"
    printf '%s' "$_ph" > "$_pdir/${_pidx}.result"
    # §2 secrets: verbose 段含 Authorization: Bearer <key> 明文回显 (curl -v 2>&1), 推 Dataset 前剥明文 (boot 02:50 暴露病根②).
    #   sed 剥全 key → <REDACTED>, 保前缀供排障 (鉴权头存在性可见, 值不可见). 同 omn_redact 类C Bearer 正则.
    # verbose 段写可选; || true 兜子shell最后退出码: _pverbose=0 时 [...] test 返 exit 1 → 子shell退出码 1
    #   → 主循环 L692 裸 wait "$_p" 收 1 → set -e 杀 init → container exit 1 (boot 05:24/05:25 崩真根).
    #   || true 强制 exit 0 覆盖 test 失败/printf 满足两态均不阻.
    [ "$_pverbose" = "1" ] && [ -n "$_pv_out" ] && printf '%s' "$_pv_out" | sed -E 's/(Authorization:[[:space:]]*Bearer[[:space:]]+)[A-Za-z0-9._\-]+/\1<REDACTED>/gi' > "$_pdir/${_pidx}.verbose" || true
  }
  # 分批并发:
  local _i=0
  while [ "$_i" -lt "$_total" ]; do
    local _batch_pids=() _j
    for _j in $(seq 0 $((_probe_concurrency - 1))); do
      local _bi=$((_i + _j))
      [ "$_bi" -ge "$_total" ] && break
      local _bk="${_keys[$_bi]}"
      if [ "$_use_parallel" = "1" ]; then
        ( _probe_one "$((_bi+1))" "$_bk" "$_probe_body" "$_PROBE_TIMEOUT" "$_verbose_mode" "$_pr_dir" "$NVIDIA_BASE_URL" ) &
        _batch_pids+=($!)
      else
        _probe_one "$((_bi+1))" "$_bk" "$_probe_body" "$_PROBE_TIMEOUT" "$_verbose_mode" "$_pr_dir" "$NVIDIA_BASE_URL"
      fi
    done
    [ "$_use_parallel" = "1" ] && [ "${#_batch_pids[@]}" -gt 0 ] && { for _p in "${_batch_pids[@]}"; do wait "$_p"; done; }
    # 串行收判本批结果 (重遍历 _bi 范围, 兼串行/并行两路):
    local _ci _idx
    for _ci in $(seq $_i $((_i + _probe_concurrency - 1))); do
      [ "$_ci" -ge "$_total" ] && break
      _idx=$((_ci+1))
      _rkey="${_keys[$_ci]}"
      local _http_file="$_pr_dir/${_idx}.result" _http="000"
      [ -f "$_http_file" ] && _http=$(printf '%s' "$(<"$_http_file")" | tail -n1)
      [ -z "$_http" ] && _http="000"
      [ "$_verbose_mode" = "1" ] && [ -f "$_pr_dir/${_idx}.verbose" ] && { echo "[init] probe key#${_idx} VERBOSE 诊断 (-v, stderr 入此 log): " >&2; cat "$_pr_dir/${_idx}.verbose" >&2; }
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
          #   限 000 一类 (403/429/2xx 已是有效响应, 不重试). 重试亦并发挂本批最后槽 (占用已空槽, 不增总并发).
          # X2.1 (2026-07-31 boot 真根①): NIM_PROBE_RETRY_ENABLED 默 0 跳重试 — 主进程串行 30s×N 慢启病根根除,
          #   首发 000 = NVCF 冷启热身非 key 死 (verbose 坐实), fail-open alive 入池, runtime LocalHealthCheck 兜底真死.
          if [ "$_retry_enabled" = "1" ]; then
            echo "[init] probe key#${_idx}: HTTP 000 → 重试 (30s 宽超时, NIM_PROBE_RETRY_ENABLED=1)"
            local _rb _rh
            if [ "$_verbose_mode" = "1" ]; then
              _rb=$(curl -s -v -m 30 -w $'\n%{http_code}' -X POST \
                "$NVIDIA_BASE_URL/v1/chat/completions" \
                -H "Authorization: Bearer $_rkey" -H 'Content-Type: application/json' \
                -d "$_probe_body" 2>&1 || printf '\n000')
              echo "[init] probe key#${_idx} 重试 VERBOSE: " >&2; printf '%s' "$_rb" | sed -E 's/(Authorization:[[:space:]]*Bearer[[:space:]]+)[A-Za-z0-9._\-]+/\1<REDACTED>/gi' >&2
            else
              _rb=$(curl -s -m 30 -w $'\n%{http_code}' -X POST \
                "$NVIDIA_BASE_URL/v1/chat/completions" \
                -H "Authorization: Bearer $_rkey" -H 'Content-Type: application/json' \
                -d "$_probe_body" 2>/dev/null || printf '\n000')
            fi
            _rh=$(printf '%s' "$_rb" | tail -n1); [ -z "$_rh" ] && _rh="000"
            case "$_rh" in
              403) echo "[init] probe key#${_idx}: 重试 HTTP 403 → AUTH_DEAD (账户级死, 入 auth_dead)"; AUTH_DEAD_KEYS+=("$_rkey"); _PROBE_DEAD=$((_PROBE_DEAD+1)) ;;
              000) echo "[init] probe key#${_idx}: 重试仍 000 → alive (fail-open, 瞬态抖动不放大)"; _PROBE_ALIVE=$((_PROBE_ALIVE+1)) ;;
              *) echo "[init] probe key#${_idx}: 重试 HTTP $_rh → alive (fail-open, 非账户级死)"; _PROBE_ALIVE=$((_PROBE_ALIVE+1)) ;;
            esac
          else
            echo "[init] probe key#${_idx}: HTTP 000 → alive (fail-open, 重试闸关; NVCF 冷启热身非 key 死)"
            _PROBE_ALIVE=$((_PROBE_ALIVE+1))
          fi
          ;;
        *)
          # 4xx(非403)/5xx/超时 → fail-open 判活 (boot 抖动不放大全停; 瞬态故障运行时熔断兜底)
          echo "[init] probe key#${_idx}: HTTP $_http → alive (fail-open, 非账户级死)"
          _PROBE_ALIVE=$((_PROBE_ALIVE+1))
          ;;
      esac
    done
    _i=$((_i + _probe_concurrency))
  done
  [ -n "$_pr_dir" ] && [ "$_pr_dir" != "/" ] && rm -f "$_pr_dir"/*.result "$_pr_dir"/*.verbose 2>/dev/null; rmdir "$_pr_dir" 2>/dev/null || true
  _PROBE_DONE=1
  echo "[init] probe 汇总: alive=$_PROBE_ALIVE dead=$_PROBE_DEAD (auth_dead 跳 ${#AUTH_DEAD_KEYS[@]} 个注册, POST $_probe_model, 并发$_probe_concurrency)"
}

# X4 (2026-07-31): NIM_PROBE_ENABLED 总闸. 2026-08-28 改默认 0=关探活, 对齐 miztertea/nim-proxy + 上游
#   惰性检测哲学: NIM 免费层唯一硬限 = RPM 40/换, 无限额, 最怕 key 被官方风控标记. boot 主动探活既不解决
#   风控(反而增加请求频率暴露), 也不省额度(无限), 只占 boot 时间. 两个参考系统默认都不探活 key:
#   - miztertea/nim-proxy: key 只在 first-run 验一次, 之后靠运行时 failover(429/5xx 换 key) + 模型压力自适应退避
#   - 上游: LocalHealthCheck 60s 心跳只查 node /models 连通(res.ok||401), 不判 key 死; key 死靠 executor
#     请求 401/403 惰性 failover + combo 404 熔断
#   register-and-go: 死 key 入池, runtime 惰性兜底. 保留 ENV=1 排障临时开.
_PROBE_SKIP=0
if [ "${NIM_PROBE_ENABLED:-0}" != "1" ]; then
  echo "[init] NIM_PROBE_ENABLED=${NIM_PROBE_ENABLED:-0} → 跳 probe (register-and-go; 对齐 miztertea 惰性检测, runtime LocalHealthCheck+executor failover 兜底死 key)"
  _PROBE_SKIP=1
else
  probe_nim_keys_real
fi

# ── v4.3.2 [M3 补丁·硬伤3修正]: probe 后按实际 alive 重算限流三字段 (防 RPM 配额虚高) ──
# 病灶: M1 公式(行165-171)在 probe(行609)之前跑过, _ALIVE_KEYS 当时=NIM_KEYS 全量(含死 key).
#        probe 判死 auth_dead 后, 若不重算 → 死 key 的 per_key 配额被幽灵占用, 实际 alive key
#        拿不到应有配额上限, 限流虚高 → 上游 按原 RPM 节奏往活 key 上压, 单 key 负载超设计 → 触发 429.
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
  RESP_FILE="$(_resp omn-provider-$INDEX.json)"
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

# Task C3: GC 后清 上游 Health Autopilot 陈旧错态 (冷却回活后残留 lastError, 致回活 account 被路由偏置绕开).
clear_stale_nim_errors

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
  # 判码 (2026-09-05 补): 旧式只取 $? 不取 HTTP 码 — 上游 5xx 时 curl_rc=0 且响应体非空,
  #   会绕过本段 transport 检查, 直到下游四字段断言才以 "读回不一致 RPM(null!=X)" 形式暴露,
  #   诊断被误导为"配置未落定"而非"读回请求本身失败". 现先 -w 取码, 非 200 直接在此拦下.
  #   ⚠ set -e 陷阱 (本段根病原): `VAR=$(cmd)` 退出码取 cmd — curl 失败会在"赋值这一行"即被
  #     errexit 秒杀, 导致下行 `res_get_rc=$?` 与整个 if 分支成为不可达死代码,
  #     即原有优雅报错从未真正生效过 (失败表现为无声中止, 无 abort_source 诊断).
  #     故抬门 set +e 包住 curl + $? 捕获, 再 set -e 恢复, 使错误处理首次真实可达.
  #     注意: 不能改用 `|| echo "000"`, 那会把 $? 冲成 0 丢掉 curl_rc (供下行 abort_source 判因).
  _RES_GET_FILE="$(_resp omn-resilience-get.json)"
  set +eo pipefail
  _RES_GET_HTTP=$(curl -s -o "$_RES_GET_FILE" -w "%{http_code}" --connect-timeout 5 --max-time 20 -b "$COOKIE_FILE" "$BASE_URL/api/resilience" 2>/tmp/res_get.err)
  res_get_rc=$?
  set -eo pipefail
  if [ "$res_get_rc" -ne 0 ]; then _RES_GET_HTTP="000"; fi
  _res_get_err=$(cat /tmp/res_get.err 2>/dev/null | head -c 300 || true)
  _RB=$(cat "$_RES_GET_FILE" 2>/dev/null || true)
  if [ "$res_get_rc" -ne 0 ] || [ "$_RES_GET_HTTP" != "200" ] || [ -z "$_RB" ]; then
    echo "[init] ✗ Resilience GET 读回失败: curl_rc=$res_get_rc HTTP=${_RES_GET_HTTP:-<empty>} err=${_res_get_err:-<empty>}"
    head -c 300 "$_RES_GET_FILE" 2>/dev/null || true
    echo "[init]   abort_source: $( [ "$res_get_rc" = 28 ] && echo 'request_timeout' || ([ "$res_get_rc" = 7 ] && echo 'get_connect_failure' || echo 'get_unknown') )"
    echo "[init]   CF-4 约束: 写必须读回. 读回失败 → init 失败 (上游 resilience 未确认达预期限流)."
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
  # 2026-09-05 首席架构师裁: HF Dataset 快照废弃 → 直写 Bucket 挂载点
  #   /data/backups/config/ = HF Bucket 挂载 (FUSE, 写即持久, 重启保留)
  #   闸门沿用 OMN_LOG_TO_DATASET (默 1 开; =0 跳整段省 IO)— 历史名, 语义现为 "snapshot 开"
  [ "${OMN_LOG_TO_DATASET:-1}" = "1" ] || { echo "[init] snapshot: OMN_LOG_TO_DATASET=0 跳过."; return 0; }
  local BACKUP_DIR="/data/backups/config"
  mkdir -p "$BACKUP_DIR" 2>/dev/null || { echo "[init] snapshot: WARN /data 挂载未就绪, 跳过"; return 0; }
  echo "[init] snapshot → $BACKUP_DIR (Bucket 挂载直写, 无 HF API)"
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

  # ── DB 表快照 (链②) 已删 (2026-07-29 Zen裁砍七成): litestream 已复制整个 storage.sqlite ──
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
  #   与 scheduler capture_init 双路并行不冲突: Bucket 挂载直写真终态兜底 (capture_loop 60s 一轮可能漏 init exit 后尾段).
  #   本地滚动清理：只保留最近 NIM_DEBUG_LOG_KEEP(默认5) 个。
  if [ "$NIM_MODE" = "DEBUG" ] && [ -n "$INIT_LOG" ] && [ -f "$INIT_LOG" ]; then
    local _keep=${NIM_DEBUG_LOG_KEEP:-5}
    # debug 件入 save/debug/ 子目录 (2026-09-05 裁: upload_folder 已删, 直写 Bucket)
    #   save/debug/<stamp>.log parts=3 进 omn_scheduler _do_archive 归档流 (Zen 2026-08-01 准 debug 入归档).
    #   原根平铺 save/debug_*.log parts=2 被归档结构闸跳 = 永不归档; 改子目录后与其他六源同构可归档可删.
    mkdir -p "$BACKUP_DIR/debug" 2>/dev/null || true
    local _dbg="$BACKUP_DIR/debug/debug_$(basename "$INIT_LOG" | sed 's/^init_//')"
    cp -f "$INIT_LOG" "$_dbg" 2>/dev/null \
      && echo "[init] snapshot: 附带 DEBUG log -> debug/debug_$(basename "$INIT_LOG" | sed 's/^init_//')" \
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

  echo "[init] snapshot 完成: $(ls -1 "$BACKUP_DIR" 2>/dev/null | wc -l) 件于 $BACKUP_DIR"

  # ── omn 插件静态包推公开 Bucket (路③可选件) 已移出 ──
  #   omn_bucket_sync.py + 本调用段 2026-07-31 移除 (Zen裁插件包可选件状态, 非现役链).
  #   恢复路径: git 历史检出 + Dataset 根回推. 见 docs/ops/DECISIONS.md 2026-07-31 移除决策条.
}

# ── 通用多 provider 注册函数 (NIM_KEYS 多 key 模式推广: gemini/openrouter/sensenova/mistral/amd) ──
# 2026-08-26 提升: 原仅 first-init 跑 (L1349 内联), 增量 boot 直接 exit 0 跳过 → 免费 provider 永不再注册.
#   改成函数后 **增量+first-init 都跑**, 幂等 (node 已存在复用 id, 连接 POST 409 跳过, 模型 409 幂等)。
# 每 provider:
#   1) 建 openai-compatible 节点定 base_url (POST /api/provider-nodes, 幂等: 已存在则复用 id)
#   2) 遍历 ${env_keys_var} 每 key 建连接 (POST /api/providers, provider=<node.id> → 路由自动 providerSpecificData.baseUrl=node.baseUrl)
#   3) GET {base_url}/models 动态枚举模型 → 过滤 embedding → 截 max_models → 前缀 prefix/ 注册
#   4) upsert_combo "${prefix}-pool" 含该 provider 全部存活模型
#   5) FT 桥绑定 (ALL_FT_FAMILIES 已含本 provider 族, _ft_register_proxy 单桥/多桥都会绑)
# 向后兼容: env 变量空 → 跳过该 provider, 不影响 NVIDIA 现役路径。
# 注: 本函数在脚本顶层 (非函数内函数), 变量不用 local (同 NVIDIA 循环); set -e 下顶层 local 会非零退出崩 init。
_register_multi_provider() {
  echo "[init] General multi-provider registration..."
  # 跨 provider 同模型 (dp4f) 聚合池收集: 循环内每 provider 枚举命中 deepseek+flash 变体时,
  # 把 "${_nid}/${模型名}" (_nid = builtin 短名 / node 节点 UUID) 追加进 _DPV4_ENTRIES, 末尾建 dp4f-pool.
  #   (注: "node.id 前缀绕 §8.1 遮蔽" 注释过时于 2026-08-28 内置化 — builtin 下 _nid=内置短名, 与 nvidia 同构)
  _DPV4_ENTRIES=()
  for _pcfg in "${PROVIDERS[@]}"; do
    IFS='|' read -r _pid _pnode _ppre _pburl _penvv _pmax _mpre _mode _static_models <<< "$_pcfg"
    # disabled 死轨: 跳过整段 (建节点/连接/枚举/pool), 保留代码待 key 复活 (可逆).
    if _is_provider_disabled "$_pid"; then
      echo "[init]   $_pid: DISABLED, 跳过注册 (key 无效空转, 保留代码待复活)"
      continue
    fi
    # mode=builtin → 走内置 provider 名 (sensenova). 连接/模型/combo 前缀/dpv4 前缀全用 _pid 内置名,
    # 与 nvidia 同模式 (nvidia 内置名下有连接 → 短名通; §8.1 遮蔽只影响自定义节点, 不影响内置名挂连接).
    _is_builtin=0; [ "$_mode" = "builtin" ] && _is_builtin=1
    # 第 9 字段 static_models = 静态白名单 (空格分隔). 非空 → 方案A: 跳过动态枚举, 直接注册白名单.
    _static_models=$(printf '%s' "$_static_models" | tr -s '[:space:]' ' ' | sed 's/^ //; s/ $//')
    # 取该 provider 的多行 keys (间接引用 env 变量名), 空则跳过
    _keys=""
    _keys=$(eval "printf '%s' \"\${$_penvv}\"" 2>/dev/null || true)
    [ -z "$(printf '%s' "$_keys" | tr -d '[:space:]')" ] && { echo "[init]   $_pid: env $_penvv 空, 跳过."; continue; }
    # nvidia: legacy NIM_KEYS 内置轨独占 (nim-01..32@provider=nvidia + nim-pool/nim-codex/dp4f
    # 全锚其上, FT 绑 provider=nvidia 字段), 通用表跳过 — 不建 node 套件, 防双轨.
    # 禁把 mode 改 builtin: 那会让本循环以 provider=nvidia 再注册 nvidia-01..32, 与 nim-01..32
    # 同 provider 撞成 64 条 (2026-08-31 Zen令第一性: 分两路 内置/自定义, 每 provider 只走一条).
    # PROVIDERS 表 nvidia 行保留, 仅供 ALL_FT_FAMILIES 收前缀绑 FT 族.
    [ "$_pid" = "nvidia" ] && { echo "[init]   nvidia: legacy 内置轨独占, 通用表跳过 (双轨收敛单轨)"; continue; }
    echo "[init]   $_pid: 建节点+连接+枚举模型 (base=${_pburl}, max=${_pmax}, mode=$([ "$_is_builtin" = 1 ] && echo builtin || echo node))..."

    # ── 1) 建 provider-node (幂等: 存在则查复用) — builtin 模式跳过 (走内置 provider 名) ──
    _nid=""
    if [ "$_is_builtin" = 1 ]; then
      _nid="$_pid"
      echo "[init]     $_pid: builtin 模式, 不建 node, _nid=$_nid (短名)"
    else
    # 先查现有节点, 命中则取 id (避免重名 POST 400). GET /api/provider-nodes?type= 或按 name 查.
    _nodes_resp="$(_resp omn-provider-nodes-${_pid}.json)"
    # 判码 (2026-09-05 补): 旧式无 -w + `|| true` 双吞 — 传输失败与上游 5xx 全静默,
    #   → 空体/错误体喂 jq → _nid 空 → 误判"不存在" → 转 POST → 重名 400 → 该 provider 被跳过.
    #   非 200 即跳过本 provider, 不再据不可信响应体决策.
    _nodes_http=$(curl -s -o "$_nodes_resp" -w "%{http_code}" -b "$COOKIE_FILE" \
      "$BASE_URL/api/provider-nodes?type=openai-compatible" 2>/dev/null || echo "000")
    if [ "$_nodes_http" != "200" ]; then
      echo "[init]     $_pid: ✗ GET /provider-nodes HTTP $_nodes_http — 无法判定节点存在性, 跳过 (避免误建重名/误取错 id)"
      head -c 200 "$_nodes_resp" 2>/dev/null || true
      continue
    fi
    # 按 name 匹配现有节点 (name 唯一每 provider)
    _nid=$(jq -r --arg n "$_pnode" '.. | objects | select(.name? == $n) | .id // empty' "$_nodes_resp" 2>/dev/null | head -n1)
    if [ -z "$_nid" ]; then
      _nbody=$(jq -n --arg name "$_pnode" --arg prefix "$_ppre" --arg baseUrl "$_pburl" \
        '{name:$name, prefix:$prefix, apiType:"chat", type:"openai-compatible", baseUrl:$baseUrl}')
      _nresp="$(_resp omn-provider-node-${_pid}.json)"
      _nhttp=$(curl -s -o "$_nresp" -w "%{http_code}" -b "$COOKIE_FILE" -X POST "$BASE_URL/api/provider-nodes" \
        -H "Content-Type: application/json" -d "$_nbody" 2>/dev/null || echo "000")
      # 创建响应是 {node:{id,...}} (providers/route.ts POST 包装) — 取 .node.id 而非顶层 .id
      _nid=$(jq -r '.node.id // empty' "$_nresp" 2>/dev/null)
      case "$_nhttp" in
        200|201) [ -n "$_nid" ] && echo "[init]     $_pid: node $_pnode 建 ✓ (id=$_nid)" || echo "[init]     $_pid: node POST 成功但无 id, WARN" ;;
        *) echo "[init]     $_pid: node POST HTTP $_nhttp ($(head -c 200 "$_nresp" 2>/dev/null)); 跳此 provider."; continue ;;
      esac
    else
      # 复用旧 node 时 PUT 刷新 baseUrl. 早期 boot (base_url 缺 /v1 时) 建的 node 存了无 /v1 旧值,
      # 枚举走表值(带 /v1)能通但推理走 node.baseUrl(旧值) → executor 发无 /v1 URL → 上游 404.
      # PUT 同步 baseUrl/prefix/apiType 为当前表值, 消除枚举/推理 split-brain. (PUT route 对
      # openai-compatible 节点强制 apiType ∈ validApiTypes, 故 body 必带 apiType:"chat".)
      _nbody=$(jq -n --arg name "$_pnode" --arg prefix "$_ppre" --arg apiType "chat" --arg baseUrl "$_pburl" \
        '{name:$name, prefix:$prefix, apiType:$apiType, baseUrl:$baseUrl}')
      _nuresp="$(_resp omn-provider-node-up-${_pid}.json)"
      _nhttp=$(curl -s -o "$_nuresp" -w "%{http_code}" -b "$COOKIE_FILE" -X PUT "$BASE_URL/api/provider-nodes/$_nid" \
        -H "Content-Type: application/json" -d "$_nbody" 2>/dev/null || echo "000")
      case "$_nhttp" in
        200) echo "[init]     $_pid: node $_pnode 复用 id=$_nid (baseUrl 已刷新=$_pburl)" ;;
        *) echo "[init]     $_pid: node $_pnode 复用 id=$_nid (PUT 刷 baseUrl HTTP $_nhttp, 忽略)" ;;
      esac
    fi
    fi   # builtin else (node 建立段)

    # ── 1.5) node 模式补绑 FT 桥 — 真实 provider 名 = 节点 UUID (2026-09-03, amd 封号防御) ──
    # 根因: _ft_register_proxy 绑族用字的短名 (scopeIds=[... amd]), 但 node 模式连接挂
    # provider=<UUID>, 短名匹配不上 → model 直连共享 HF 容器单出口 IP (多 key 同 IP 触风控=封号).
    # builtin 名 (sensenova 等) 短名即 provider 名, 绑族已覆盖, 本段只处理 node 模式.
    # 时机: FT 桥注册早于本函数 (全局 var _FT_PROXY_ID 已导出), 节点刚建/复用得真实 _nid.
    if [ "$_is_builtin" = "0" ] && [ -n "${_FT_PROXY_ID:-}" ] && [ -n "$_nid" ]; then
      local _nd_ids_json _nd_BA _nd_BAR _nd_BAC _nd_upd
      _nd_ids_json=$(printf '%s\n' "$_nid" | jq -R . | jq -s .)
      _nd_BA=$(jq -n --arg s "provider" --argjson ids "$_nd_ids_json" --arg p "$_FT_PROXY_ID" \
        '{scope:$s, scopeIds:$ids, proxyId:$p}')
      _nd_BAR="$(_resp ft_bindnode_${_pid}.json)"
      _nd_BAC=$(curl -s -o "$_nd_BAR" -w "%{http_code}" -b "$COOKIE_FILE" \
        -X PUT "$BASE_URL/api/v1/management/proxies/bulk-assign" \
        -H "Content-Type: application/json" -d "$_nd_BA" 2>/dev/null || echo "000")
      _nd_upd=$(jq -r '.updated // "?"' "$_nd_BAR" 2>/dev/null)
      case "$_nd_BAC" in
        200|201) echo "[init]     $_pid: node $_nid 补绑 FT 桥 ✓ (provider scope, updated=${_nd_upd})" ;;
        *)       echo "[init]     $_pid: node $_nid 补绑 FT 桥 WARN HTTP $_nd_BAC ($(head -c 200 "$_nd_BAR" 2>/dev/null)). 该 provider 将直连." ;;
      esac
    fi

    # ── 2) 逐 key 建连接 (POST /api/providers, provider=<node.id> 走 openai-compatible 路由) ──
    # builtin 模式: provider=<sensenova> 挂内置名下, 与 nvidia 同模式 (短名通).
    _kc=0 _reg=0 _skip=0 _fail=0
    while IFS= read -r _rawk; do
      _k=$(printf '%s' "$_rawk" | tr -d '[:space:]')
      [ -z "$_k" ] && continue
      _kc=$((_kc+1))
      _cname=$(printf '%s-%02d' "$_ppre" "$_kc")
      # auth_dead (NVIDIA probe 已收集) 跳注册: 编号缺口即死 key 位置
      if _is_auth_dead "$_k"; then echo "[init]     $_pid/$_cname skip (probe AUTH_DEAD, 不注册)"; _skip=$((_skip+1)); continue; fi
      _cbody=$(jq -n --arg provider "$_nid" --arg apiKey "$_k" --arg name "$_cname" \
        '{provider:$provider, apiKey:$apiKey, name:$name, priority:1, testStatus:"unknown"}')
      _cresp="$(_resp omn-provider-${_pid}-${_kc}.json)"
      _chttp=$(curl -s -o "$_cresp" -w "%{http_code}" -b "$COOKIE_FILE" -X POST "$BASE_URL/api/providers" \
        -H "Content-Type: application/json" -d "$_cbody" 2>/dev/null || echo "000")
      case "$_chttp" in
        201|200) echo "[init]     $_pid/$_cname OK"; _reg=$((_reg+1)) ;;
        409) echo "[init]     $_pid/$_cname exists"; _skip=$((_skip+1)) ;;
        *) echo "[init]     $_pid/$_cname HTTP $_chttp ($(head -c 120 "$_cresp" 2>/dev/null))"; _fail=$((_fail+1)) ;;
      esac
    done <<< "$_keys"
    echo "[init]     $_pid: $_kc keys → $_reg registered, $_skip skipped, $_fail failed"

    # ── 3) 模型注册来源: 静态白名单 (方案A) 或 动态枚举上游 /models ──
    # 方案A (2026-08-28 Zen令): 第 9 字段 static_models 非空 → 跳过动态枚举, 直接用白名单注册.
    #   目的: sensenova 模型少且明确 (内置 registry 3 个 chat 模型), 避免上游 /models 带回
    #   u1-fast 图片模型 (上游不标 supportedEndpoints → catalog 默认按 chat, 误入 chat 列表).
    # 默认: 动态枚举 (GET {base_url}/models, 过滤 embedding, 截 max) — 对模型数大/需自动发现上游的
    #   provider (openrouter/mistral/amd/nvidia) 保留. 遍历 keys 找第一个能返回列表的 key; 全部失败
    #   fail-open 降级. 双路: 先裸 curl 直连公网; 空则走 FT 桥 + 信任 FT MITM CA (须 --cacert).
    if [ -n "$_static_models" ]; then
      # 方案A: 静态白名单, 每行一个模型 (原样, 不 grep 不过滤 — 白名单本身已筛好 chat 模型)
      _model_ids=$(printf '%s\n' $_static_models | sed '/^$/d')
      # 命令替换剥尾随换行 → wc -l 按换行符计数会少 1 (2026-08-28 实证 3 模型误显示 2).
      # 补 printf '%s\n' 给末行补换行再数, 空串经 sed '/^$/d' 归 0.
      _mcount=$(printf '%s\n' "$_model_ids" | sed '/^$/d' | wc -l)
      echo "[init]     $_pid: 静态白名单 $_mcount 个模型 (方案A, 不枚举上游)"
    else
      _models_json=""
      _models_key=""
      while IFS= read -r _rk; do
        _rk=$(printf '%s' "$_rk" | tr -d '[:space:]')
        [ -z "$_rk" ] && continue
        _mj=$(curl -s --max-time 20 -H "Authorization: Bearer ${_rk}" "${_pburl}/models" 2>/dev/null || echo "")
        if [ -n "$(printf '%s' "$_mj" | jq -r '.data[]?.id // empty' 2>/dev/null | head -n1)" ]; then
          _models_json="$_mj"; _models_key="$_rk"; break
        fi
      done <<< "$_keys"
      if [ -z "$_models_key" ] && [ -f "/tmp/ft-ca/flaretunnel_ca.crt" ]; then
        # 裸 curl 未取到有效模型列表 (_models_key 空) → 回退 FT 桥. 判 _models_key 而非 _models_json:
        #   google/amd 裸 curl 失败返回非空错误 body (28B, 无 data[].id), _models_json 非空但 _models_key 空,
        #   若判 body 空则错误 body 会跳过 FT 回退 (boot 2026-08-26 实证 google 卡此). (复用第一个非空 key, 无则首 key)
        _px="${FT_PROXY_PORT:-8080}"
        _fk=$(printf '%s\n' "$_keys" | head -n1 | tr -d '[:space:]')
        _models_json=$(curl -s --max-time 25 -x "http://127.0.0.1:${_px}" \
          --cacert /tmp/ft-ca/flaretunnel_ca.crt \
          -H "Authorization: Bearer ${_fk}" "${_pburl}/models" 2>/dev/null || echo "")
      fi
      # 兼容 {data:[{id}]} 与 OpenAI 直列两种返回; 过滤 embedding/非 chat 防污染 combo
      _model_ids=$(printf '%s' "$_models_json" | jq -r '.data[]?.id // empty' 2>/dev/null \
        | grep -viE 'embed|embedding|davinci|audio|image|video|rerank|moderation|whisper|tts' \
        | head -n "$_pmax" || true)
      _mcount=$(printf '%s\n' "$_model_ids" | sed '/^$/d' | wc -l)
      echo "[init]     $_pid: 枚举 $_mcount 个模型 (截 $_pmax) (body $(printf '%s' "$_models_json" | wc -c)B, key=$([ -n "$_models_key" ] && echo ok || echo none))"
    fi
    # 建 combo (每 provider 自己的 ${prefix}-pool, 幂等 upsert).
    # combo 条目 = <node.id>/<模型名>: 前缀用 node.id 匹配连接 provider 字段
    # (getRawProviderConnections EXACT match; node name 前缀匹配不到 → "无 active credentials").
    # 模型名 = ${_mpre:+${_mpre}/}${裸模型ID}: 实测 (2026-08-27) 双层前缀理论彻底证伪 — 两家都认裸名:
    #   sensenova 认自带前缀裸名 (sensenova-u1.5-lite→200) 或裸名 (deepseek-v4-flash), 不认双层 (→404);
    #   amd 认裸名 (DeepSeek-V4-Flash→200, used_provider=radeon-deepseek), 不认双层 (amd/→404 "Provider amd not found").
    #   → 全 provider _mpre 空 = 枚举原样. mistral/openrouter 枚举即调用格式同样空.
    # 模型注册 modelId 同 combo 模型名 (带 _mpre 前缀, provider=<node.id>).
    if [ "$_mcount" -gt 0 ]; then
      _modids=()
      while IFS= read -r _mm; do
        [ -z "$_mm" ] && continue
        _modids+=("${_mpre:+${_mpre}/}${_mm}")
        # 跨 provider 同模型 (dp4f) 收集: 枚举模型名匹配 [Dd]eep[Ss]eek+[Ff]lash 变体 →
        # 追加 "${_nid}/${_mm}" 进全局 _DPV4_ENTRIES (combo 条目: builtin 模式 _nid=内置短名, node 模式=节点 UUID).
        # 2026-08-28 Zen令: 严格三提供商 (nvidia+sensenova+amd), 排除 openrouter
        # (boot 02:45 实证 openrouter 枚举含 3 个 deepseek/deepseek-v4-flash-* 变体, 误收进池).
        case "$_mm" in
          *[Dd]eep[Ss]eek*[Ff]lash*) [ "$_pid" = "openrouter" ] || _DPV4_ENTRIES+=("${_nid}/${_mm}") ;;
        esac
      done <<< "$_model_ids"
      _strat="${_POOL_STRATEGY:-weighted}"
      _is_valid_strat "$_strat" || _strat="round-robin"
      # 逐一注册模型到 provider 节点 (modelId 带 _mpre 前缀, provider=<node.id>)
      for _regm in "${_modids[@]}"; do
        _mresp="$(_resp omn-model-${_pid}-$(echo "$_regm" | tr '/' '-').json)"
        _mhttp=$(curl -s -o "$_mresp" -w "%{http_code}" -b "$COOKIE_FILE" -X POST "$BASE_URL/api/provider-models" \
          -H "Content-Type: application/json" -d "$(jq -n --arg provider "$_nid" --arg modelId "$_regm" '{provider:$provider, modelId:$modelId}')" 2>/dev/null || echo "000")
        case "$_mhttp" in
          200|201|409) : ;;
          *) echo "[init]     $_pid model $_regm WARN $_mhttp"; cat "$_mresp" 2>/dev/null || true ;;
        esac
      done
      upsert_combo "${_ppre}-pool" "$_strat" "$_nid" "${_modids[@]}"
      # 方案A: 静态白名单模式下, 清该 provider 下白名单之外的旧枚举残留 (幂等).
      # 历史 boot 动态枚举注册的模型 (如 sensenova-u1-fast 图片模型误入) 不在白名单内,
      # 换成白名单后旧残留仍挂 /v1/models, 须显式删. 只删白名单外, 不动白名单内 (combo 引用).
      # modelId 可能带 provider 前缀 (如 sensenova/sensenova-6.7-flash-lite) 或裸名, 剥前缀后比对白名单.
      if [ -n "$_static_models" ]; then
        local _prf _prid _prlist _pm _pmbase
        _prf="$(_resp omn-provider-models-prune-${_pid}.json)"
        # 判码 (2026-09-05 补): 旧式无 -w + `|| true` 双吞. _prlist 直接喂 DELETE —
        #   查询失败时若错误体含 models[] 结构, 会据不可信 id 误删白名单内模型 (不可逆).
        #   非 200 则置空 _prlist, 走下方"无残留跳过"分支, 只清理被跳过而非误删.
        _prh=$(curl -s -o "$_prf" -w "%{http_code}" -b "$COOKIE_FILE" \
          "$BASE_URL/api/provider-models?provider=$_nid" 2>/dev/null || echo "000")
        if [ "$_prh" != "200" ]; then
          echo "[init]     $_pid: ✗ GET /provider-models HTTP $_prh — 跳过白名单外清理 (避免据错误体误删)"
          head -c 200 "$_prf" 2>/dev/null || true
          _prlist=""
        else
        _prlist=$(jq -r '.models[]? | .id // empty' "$_prf" 2>/dev/null \
          | awk -v wl="$_static_models" '{ n=$0; sub(/^[^/]*\//,"",n); if ((" " wl " ") !~ (" " n " ")) print }' \
          || true)
        fi
        if [ -n "$_prlist" ]; then
          while IFS= read -r _pm; do
            [ -z "$_pm" ] && continue
            _ph=$(curl -s -o /dev/null -w "%{http_code}" -b "$COOKIE_FILE" \
              -X DELETE "$BASE_URL/api/provider-models?provider=$_nid&model=$_pm" 2>/dev/null || echo "000")
            echo "[init]     $_pid: 清白名单外残留模型 $_pm HTTP $_ph"
          done <<< "$_prlist"
        else
          echo "[init]     $_pid: 无白名单外残留, 跳过"
        fi
      fi
    else
      echo "[init]     $_pid: 无模型可注册, combo ${_ppre}-pool 跳过."
    fi
  done
  upsert_dp4f_pool
  # 内置化后清旧自定义节点残留 (幂等; 无残留则 no-op). 2026-08-31 四家全内置化:
  #   sensenova(08-28) + nvidia/openrouter/mistral(08-31). 顺序: 先注册新内置路径 (循环内), 后清旧 node.
  _cleanup_legacy_node "sensenova-node" "sensenova"
  _cleanup_sensenova_double_prefix
  _cleanup_legacy_node "nvidia-node" "nvidia"
  _cleanup_legacy_node "openrouter-node" "openrouter"
  _cleanup_legacy_node "mistral-node" "mistral"
  # 2026-09-01 Zen令: gemini 内置化, 清旧 google-node 自定义节点 (UUID 轨) + 其下连接/模型.
  _cleanup_legacy_node "google-node" "google"
  echo "[init] General multi-provider registration done."
}

# ── dp4f 跨 provider 同模型聚合池 (nvidia + sensenova + amd → dp4f-pool) ──
# 2026-08-28 Zen令: 把 deepseek-v4-flash 在 nvidia/sensenova/amd 三家的实现合并进一个跨 provider 池,
# 调用 dp4f-pool 时 executor 按 p2c 逐条路由 (A 家挂 → fallback B → C).
# combo 的 models 字段原生支持混合前缀条目 (每条 "前缀/模型" 独立路由到对应 provider):
#   nvidia 条目  = nvidia/<完整模型名>        (内置 provider id 即前缀, 天然对)
#   sensenova    = sensenova/<裸模型名>       (builtin 内置名即前缀, 与 nvidia 同构短名通; 旧"绕 §8.1 遮蔽"注释过时于 08-28 内置化)
#   amd          = <node.id>/<裸模型名>
# 模型名不硬编码: sensenova/amd 枚举时已在循环内按 [Dd]eep[Ss]eek+[Ff]lash 匹配收集进 _DPV4_ENTRIES,
# 本函数只补 nvidia 条目 (nvidia 通用枚举失败, 条目须从 POOL_ALIVE/filter_alive 取).
upsert_dp4f_pool() {
  local _al _strat="${_POOL_STRATEGY:-p2c}"
  _is_valid_strat "$_strat" || _strat="round-robin"
  # nvidia 条目: 从 NIM_POOL_MODELS 存活结果 (filter_alive) grep dpv4 变体 → "nvidia/<完整模型名>"
  while IFS= read -r _al; do
    case "$_al" in
      *[Dd]eep[Ss]eek*[Ff]lash*) _DPV4_ENTRIES+=("nvidia/${_al}") ; break ;;
    esac
  done < <(filter_alive "${NIM_POOL_MODELS[@]}")
  # 去重 (同一模型名可能被多 provider 收集或 nvidia 条目撞)
  mapfile -t _DPV4_ENTRIES < <(printf '%s\n' "${_DPV4_ENTRIES[@]}" | awk '!seen[$0]++')
  if [ "${#_DPV4_ENTRIES[@]}" -lt 2 ]; then
    echo "[init] dp4f-pool: 命中 ${#_DPV4_ENTRIES[@]} 家 (<2), 跳过 (无跨 provider 轮询意义)."
    return 0
  fi
  # 混合前缀 body (models_to_json 单前缀不适用, 手动构造 models 数组)
  local _jmodels _body _CID _CODE _F
  _jmodels=$(printf '%s\n' "${_DPV4_ENTRIES[@]}" | jq -R '{model:.}' | jq -s -c . 2>/dev/null || echo "[]")
  _body=$(jq -n --arg name "dp4f-pool" --arg strat "$_strat" --argjson models "$_jmodels" \
    '{name:$name, strategy:$strat, models:$models}')
  echo "[init] dp4f-pool: 跨 provider 条目 ${#_DPV4_ENTRIES[@]} 条 → ${_DPV4_ENTRIES[*]}"
  # 幂等: CID 查询 + PUT(存在)/POST(新建) — 同 upsert_combo 修正式裁决 (§7)
  # ⚠ 2026-09-05 暂缓 (同 upsert_combo): 本处判码修复含行为变更 — GET 失败时由"盲目 POST"
  #   改为 fail-closed return 1. 另注意 _OLD 直喂 DELETE /api/combos/$_OLD, 查询失败且错误体
  #   含同名 name 时存在误删 combo 风险 (不可逆), 待 staging 回归后与 _CID 判码一并处理.
  _CID=$(curl -s -b "$COOKIE_FILE" "$BASE_URL/api/combos" \
        | jq -r --arg n "dp4f-pool" '(if type=="array" then . else (.combos // .data // []) end) | .[]? | select(type=="object" and .name==$n) | .id' | head -n1)
  # 旧名清理: dp4f-pool 前身 dpv4flash-pool (R2 DB 持久化残留, 改名后旧 combo 变孤儿). 幂等, 无则跳过.
  _OLD=$(curl -s -b "$COOKIE_FILE" "$BASE_URL/api/combos" \
        | jq -r --arg n "dpv4flash-pool" '(if type=="array" then . else (.combos // .data // []) end) | .[]? | select(type=="object" and .name==$n) | .id' | head -n1)
  if [ -n "$_OLD" ]; then
    _OC=$(curl -s -o /dev/null -w "%{http_code}" -b "$COOKIE_FILE" \
      -X DELETE "$BASE_URL/api/combos/$_OLD")
    echo "[init] dp4f-pool: 旧名 dpv4flash-pool 清理 → DELETE combos/$_OLD HTTP $_OC"
  else
    echo "[init] dp4f-pool: 无旧名 dpv4flash-pool 残留, 跳过"
  fi
  _F="$(_resp omn-combo-dp4f-pool.json)"
  if [ -n "$_CID" ]; then
    _CODE=$(curl -s -o "$_F" -w "%{http_code}" -b "$COOKIE_FILE" \
      -X PUT "$BASE_URL/api/combos/$_CID" -H "Content-Type: application/json" -d "$_body")
    echo "[init] upsert dp4f-pool: existed -> PUT combos/$_CID HTTP $_CODE"
  else
    _CODE=$(curl -s -o "$_F" -w "%{http_code}" -b "$COOKIE_FILE" \
      -X POST "$BASE_URL/api/combos" -H "Content-Type: application/json" -d "$_body")
    echo "[init] upsert dp4f-pool: new -> POST HTTP $_CODE"
  fi
  if [ "$_CODE" != "200" ] && [ "$_CODE" != "201" ]; then
    echo "[init] ✗ upsert dp4f-pool: 非 2xx (HTTP $_CODE) — fail-closed."
    cat "$_F" 2>/dev/null || true
    return 1
  fi
}

# ── sensenova 改内置后, 清理旧自定义节点 (sensenova-node) 及其残留 ──
# 2026-08-28: sensenova 已改走内置 provider (provider=sensenova, 短名通). 旧的自定义
# provider-node (name=sensenova-node, id=openai-compatible-chat-<UUID>) 及挂其下的连接/模型
# 注册成为孤儿残留 (无 combo 引用, 但污染 /v1/models 与 providers 列表). 本函数幂等清理:
#   1) 删 provider-node name=sensenova-node (DELETE /api/provider-nodes/<id> 级联删连接+别名)
#   2) 删该 node 下模型注册 (DELETE /api/provider-models?provider=<nodeid>&all=true, 兜底)
#   3) 删 provider=sensenova 下双重前缀残留 modelId (sensenova/sensenova/... 历史叠加)
# 幂等: 无旧节点/无残留则 no-op. 只删精确匹配, 不动正确短名 (sensenova/<模型>).
# ── 内置化后清理旧自定义节点 (通用, 幂等) ──
# 2026-08-28~31: sensenova/nvidia/openrouter/mistral 全部改走内置 provider (provider=<短名>, 短名通).
# 旧的自定义 provider-node (name=<节点名>, id=openai-compatible-chat-<UUID>) 及挂其下的连接/模型
# 注册成为孤儿残留 (无 combo 消费/无 FT 绑定/provider 字段 UUID 匹配不到 proxy_assignments scope_id=<短名>).
# 本函数幂等清理 (参数: 节点名 + 日志标签):
#   1) 删 provider-node name=<节点名> (DELETE /api/provider-nodes/<id> 级联删连接+别名)
#   2) 删该 node 下模型注册 (DELETE /api/provider-models?provider=<nodeid>&all=true, 兜底)
# 幂等: 无旧节点/无残留则 no-op. 只删精确匹配, 不动内置名下连接 (provider=<短名>).
_cleanup_legacy_node() {
  local _node="$1" _label="$2" _ONF _ONID _ONHTTP _ONGET_HTTP
  _ONF="$(_resp omn-provider-nodes-legacy-${_label}.json)"
  # 判码 (2026-09-05 补): 旧式无 -w + `|| true` 双吞. 此处为 DELETE 前的查存, 失败方向不对称 —
  #   查失败时 _ONID 空只会"跳过清理"(幂等, 无害); 但若错误体里恰含同名 name 字段, jq 会取到
  #   错误 id 去执行 DELETE (级联删连接+别名), 属不可逆破坏. 故非 200 明确跳过, 不据不可信体决策.
  _ONGET_HTTP=$(curl -s -o "$_ONF" -w "%{http_code}" -b "$COOKIE_FILE" \
    "$BASE_URL/api/provider-nodes?type=openai-compatible" 2>/dev/null || echo "000")
  if [ "$_ONGET_HTTP" != "200" ]; then
    echo "[init] cleanup $_label: GET /provider-nodes HTTP $_ONGET_HTTP — 无法判定旧节点存在性, 跳过清理 (避免据错误体误删)"
    head -c 200 "$_ONF" 2>/dev/null || true
    return 0
  fi
  _ONID=$(jq -r --arg n "$_node" '.. | objects | select(.name? == $n) | .id // empty' "$_ONF" 2>/dev/null | head -n1)
  if [ -n "$_ONID" ]; then
    _ONHTTP=$(curl -s -o /dev/null -w "%{http_code}" -b "$COOKIE_FILE" \
      -X DELETE "$BASE_URL/api/provider-nodes/$_ONID" 2>/dev/null || echo "000")
    echo "[init] cleanup $_label: 删旧 provider-node $_node (id=$_ONID) HTTP $_ONHTTP (级联删连接+别名)"
    # 删 node 后其下模型注册可能残留 (provider-models 表独立), 显式清
    _ONHTTP=$(curl -s -o /dev/null -w "%{http_code}" -b "$COOKIE_FILE" \
      -X DELETE "$BASE_URL/api/provider-models?provider=$_ONID&all=true" 2>/dev/null || echo "000")
    echo "[init] cleanup $_label: 清旧 node 下模型注册 (provider=$_ONID) HTTP $_ONHTTP"
  else
    echo "[init] cleanup $_label: 无旧 provider-node $_node, 跳过节点清理"
  fi
}

# ── sensenova 专有: 删 provider=sensenova 下双重前缀残留 (modelId 以 sensenova/sensenova/ 开头) ──
# 历史 boot (自定义节点时代前缀叠加) 注册的错误 modelId, 挂在 provider=sensenova 下污染列表.
# 只删双重及以上前缀, 不动正确短名 (sensenova/<裸模型名>). openrouter/mistral/nvidia 无此叠加史.
_cleanup_sensenova_double_prefix() {
  local _MMF _MMH _MMLIST _mm _ONHTTP
  _MMF="$(_resp omn-provider-models-sensenova.json)"
  # 判码 (2026-09-05 补): 旧式无 -w + `|| true` 双吞. _MMLIST 喂 DELETE; 查询失败时应明确报
  #   "跳过清理" 而非 "无双重前缀残留" — 后者会让人误以为已确认过. (本段另有 grep '^sensenova/sensenova/'
  #   精确前缀过滤, 误删风险本身已较低, 此处主要为诊断准确性与不可逆操作的显式守卫.)
  _MMH=$(curl -s -o "$_MMF" -w "%{http_code}" -b "$COOKIE_FILE" \
    "$BASE_URL/api/provider-models?provider=sensenova" 2>/dev/null || echo "000")
  if [ "$_MMH" != "200" ]; then
    echo "[init] cleanup sensenova: GET /provider-models HTTP $_MMH — 无法判定残留, 跳过清理"
    head -c 200 "$_MMF" 2>/dev/null || true
    return 0
  fi
  # GET 响应结构 = {models:[{id,...}], modelCompatOverrides:[...]} (3.8.49 route.ts).
  _MMLIST=$(jq -r '.models[]? | .id // empty' "$_MMF" 2>/dev/null \
    | grep -E '^sensenova/sensenova/' || true)
  if [ -n "$_MMLIST" ]; then
    while IFS= read -r _mm; do
      [ -z "$_mm" ] && continue
      _ONHTTP=$(curl -s -o /dev/null -w "%{http_code}" -b "$COOKIE_FILE" \
        -X DELETE "$BASE_URL/api/provider-models?provider=sensenova&model=$_mm" 2>/dev/null || echo "000")
      echo "[init] cleanup sensenova: 删双重前缀模型 $_mm HTTP $_ONHTTP"
    done <<< "$_MMLIST"
  else
    echo "[init] cleanup sensenova: 无双重前缀残留, 跳过"
  fi
}

# nvidia 清理已并入 _cleanup_legacy_node 泛化 (2026-08-31): 调用点见 _register_multi_provider 末尾.

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
    upsert_combo "nim-pool"  "$_POOL_STRATEGY" "nvidia" "${POOL_ALIVE[@]}"
    upsert_combo "nim-codex" "$_CODEX_STRATEGY" "nvidia" "${CODEX_ALIVE[@]}"
    context_accumulator_update
    # 增量也跑通用多 provider 注册 (幂等, 2026-08-26 提升: 原仅 first-init 跑跳增量)
    _register_multi_provider
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
  local MODEL_ID="$1" F="$(_resp omn-model-$(echo "$1" | tr '/' '-').json)" C
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

# ⑦ first-init 也走幂等 upsert（防重启撞名, 2026-09-05 裁: R2 链已删, 语义保底一致）
upsert_combo "nim-pool"  "$_POOL_STRATEGY" "nvidia" "${POOL_ALIVE[@]}"
upsert_combo "nim-codex" "$_CODEX_STRATEGY" "nvidia" "${CODEX_ALIVE[@]}"

# ══ 通用多 provider 注册（NIM_KEYS 多 key 模式推广: gemini/openrouter/sensenova/mistral/amd）═══
# 已抽为函数 _register_multi_provider() 定义于增量模式段前 — 增量+first-init 都调 (2026-08-26).
_register_multi_provider

context_accumulator_update
# C2 fail-open 双保险: hf_snapshot 内 python upload 异常已 try/except 降级 WARN exit 0;
#   此处 ||true 兜底函数级 (curl/jq 等非 python 段若异常), 防 set -e 触发 init 整进程 exit 1 致 Space crashloop。
#   2026-09-05 裁: R2 链已删; snapshot 仅 Bucket 挂载一份, 失败不致命 (空库 init 幂等重建)。
hf_snapshot || true

touch "$INIT_MARKER"
echo "[init] Final health check..."
HEALTH_FILE="$(_resp omn-final-health.json)"
HEALTH_HTTP=$(curl -s -o "$HEALTH_FILE" -w "%{http_code}" "$BASE_URL/api/monitoring/health" 2>/dev/null || echo "000")
[ "$HEALTH_HTTP" = "200" ] && echo "[init]   Status: $(jq -r '.status // "unknown"' "$HEALTH_FILE") / $(jq -r '.version // "unknown"' "$HEALTH_FILE")"
echo "[init] Done (first-init). v4.3.2"
