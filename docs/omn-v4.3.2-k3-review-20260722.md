# omn v4.3.2 K3 审阅稿

> **历史快照声明**: 本档嵌入/参考的 gate.js 代码含 `GATE_ADMIN_TOKEN` (Basic Auth) 机制, 该机制已于 `82d6559` (2026-07-23, saga回填期 "gate单开关" 改造, `GATE_ADMIN_TOKEN.length` 判换为 `GATE_ADMIN_ENABLED === '1'` 纯布尔) 废弃。现行机制见 `dev/logic/gate.js` (`GATE_ADMIN_ENABLED` 纯布尔开关, gate.js:24)。本档保留原貌供 v4.3.2 K3 审阅历史审计, 非现行规范。

> 生成: 2026-07-22 (冻结令窗口内, staging 路线)
> 签发 cg52 v2 + Zen 四裁断 (M1动态三式 / M3 fail-open / M4 enabled:false / M7 env注入+gate不动)
> 供 K3 审阅 v4.3.2 终态代码 (M1-M5/M7 改造落 staging, M6 跳)
> **修订档 r1 (2026-07-22 送审前自修首轮三硬伤)**: 硬伤1 = M5 漏改三 echo(v4.3.0→v4.3.2, 现 r2 稿行481/958/995); 硬伤2 = probe 端点 GET /v1/models→POST /v1/chat/completions(测不出鉴权死); 硬伤3 = probe 后 alive+三字段重算(防 RPM 配额虚高). init sha 链起 e33ada6 (954L) → ...
> **修订档 r2 (2026-07-22 r1 核验照出四处文档/注释矛盾, 抛光补丁)**: 发现A(r1自造) = M3 注释块仍说"不重算"与行610-650 重算代码打架 → 改"已定案·硬伤3"; 发现B = init 注释称 gate 有限流而现役 gate.js 零限流 → 改B1 注释订正"现役 gate.js 零限流, 限流唯一杠杆=上游 requestQueue" + 改B2 合并稿 [3/7] 段头加 KNOWN(gate 头注"28/1/2200"=v4.3.1 残留, gate 零 diff 不动, 解冻后修); 发现C = 重算段漏策略选择 → 行630-634 补 alive≤1 连动 round-robin(复原单 key 设计意图); 发现D = 附录C Resilience 读回预期写死 300/27/200/300000 会误导首次部署判读(nonoke 9/9 POST 403 现实下 alive=1 读回 35/3/1714) → 改条件预期. init sha 链 → 4a088b71 (991L) → 56aac52a (995L).
> **修订档 r3 (2026-07-22 按 docs/4.3.2提示词.md K3 提示词执行, 查证定稿)**: 改M7 = DEFAULT_REQUEST_TIMEOUT_MS 经官方 Environment wiki §15 查证确认非变量表内(env-doc-sync CI 失败即缺席), 早前 r2 "双注"方案作废 → 删除该 env, 改外科单注 STREAM_READINESS_TIMEOUT_MS=180000(默 80000=80s 首非 ping SSE 事件时限, 即长思考首 token 静默真杀手; 122s 级思考静默正对此刀; 抬至 180s 不动其他预算); REQUEST_TIMEOUT_MS 是全局快捷键(v0+覆 FETCH_TIMEOUT_MS 600s + STREAM_IDLE_TIMEOUT_MS 600s), 注会把总时限/流空闲从 600s 拉低到所注值=双面刃, 本场景无降额需求故不注. 改body = init_vars.json jq key `body_mb`→`body_limit_mb`(对齐 --arg 变量名, r1 转写笔误, key 名 cosmetic 上游不读此快照, value $body_limit_mb 已定义非裸变量无静默 null). K3 题4 预检 = 本地树 grep maxWaitMs 命中(实际 src/lib/resilience/settings.ts:47 + normalize.ts:101 上限 max=24h, 提示词指认路径 src/schemas/settings.ts 不存在, normalize.ts:311 max:30000 属 comboCooldownWait 短瞬态层非 requestQueue, M2 写 300000=5min 远在上限内不被 clamp, M2 严格断言维持). 稿内 fenced init[1/7]+entrypoint[2/7] 已 cat 重嵌入 staging 新实件, 头表 sha/行数同步. init sha 链 → e5a26a9c (995L); entrypoint sha 链 → 06178176 (263L).
> **修订档 r4 (2026-07-22/23 改名批, 首席令 omni-logic→omn-logic)**: stg init 全清非品牌 omni: `/data/omni-data/log`→`/data/omn-data/log`(行21, HF 持久卷子目录脚本自建改名不破坏卷挂载, 仅 DEBUG 日志新入新目录旧日志留旧目录); `/tmp/omni-snapshot`→`/tmp/omn-snapshot`, `path_in_repo="omni_data"`→`"omn_data"`, `Sync omni_data`→`Sync omn_data`(init 行851/935/937); env 键 `HF_DATASET_REPO`→`OMN_DATASET_REPO`(init 行849 guard/936 upload_folder, init 写 omn_data 快照的 Dataset repo 键, 与 bootstrap 拉逻辑层的 LOGIC_BUCKET_REPO 两独立 Secret). omniroute/OMNIROUTE 品牌完整 21 命中不动. 文档同步: docs/4.3.2提示词.md(送审基准)+DEPLOYMENT_GUIDE.md+omn-bundle-v4.3.0-deploy/v4.3.1-archive 五文同步改名+ env 键. audit/ 历史归档不改(冻结令前真源事实记录). 现役 candidate-v4.3-reviewed 行18 仍 `/data/omni-data/log`+行714/801 仍 `HF_DATASET_REPO`(冻结禁改, 解冻后 staging→candidate 收敛时再同步). bash -n 绿 + 终审三件套 init/entrypoint 逐字一致 diff空 + fenced 18 成9对全绿. init sha 链 → e5a26a9c → 89f636b5 → 4cbcc50120ec (995L, 本轮改名后); entrypoint sha 链 → 06178176 (263L, 本轮零 diff 不变).

## 前置声明(三句, K3 正确审料前提)

1. 本稿 7 件来自 `candidate-v4.3.2-staging/`（基于 commit `a4e68a0` 的现役副本 + v4.3.2 改造 M1-M5/M7）。
2. `candidate-v4.3-reviewed/` 现役谱系在冻结窗内（至 2026-07-23 03:16Z）**未被触碰** — 开工前后双 `find -newer 冻结令起点` 皆空，7 件 mtime 与开工前逐字一致（铁证见附录 C）。
3. K3 通过后，staging 件与 candidate 的收敛（merge/replace）动作属冻结令管辖，须待窗满或 Zen 显式解禁后另行下令执行。staging 是一次性审阅载体，K3 verdict 回填后，或解冻并入 candidate，或废弃，不长期维护双份。
4. **路径口径注记(0 号重排批后, 2026-07-23)**: 上文清单表/各 fenced 段后路径栏凡标 `candidate-v4.3.2-staging/` 者为**重排前 staging 口径**(历史真源标注); staging 已退役, **现役圣源 = `omn-logic/`(≡ HF nonoke/omn-logic 数据集根镜像), 三 P0 件现役圣源 = `patches/p0/`**。sha 链不受路径口径影响(init `4cbcc50120ec` / entrypoint `06178176` 终态 sha 与 fenced 内容逐字一致, 终审三件套 diff 空)。新旧路径映射见 `docs/README.md` 0 号重排批段。

## 基座声明

- OmniRoute 上游: 3.8.43 @ digest `b729a8f` 代码基座 + 3.8.49 @ `ce80af6` 定点移植参照（双树只读）。
- baseline-4.2.3 = 行为参数逐字对齐基准（M1 三式源于此, nomke 25 key 健康运行即正解证据）。
- 禁整体回退 4.2.3 / 禁整体升级 3.8.49。
- M1 限流: 逐字 baseline。M3 probe+auth_dead: baseline 无此件, 全新增量（K3 知此为 v4.3.2 新增）。

## 文件清单表（K3 校验"审的 = 要部署的"）

| 序 | 文件名 | 行数 | sha256 | 角色 |
|---|---|---|---|---|
| 1 | init-nim-keys.sh | 995L | 4cbcc50120ec4bb2ebd2d8a0b00dbfc75dbf9c08992361a9149dd0e8924efcd4 | 逻辑层主件 (M1动态限流/M2四字段/M3探活POST/M4压缩/M5横幅; **含硬伤1-3修正+ r2注释矛盾修正A/B+策略对齐C+ r3 body_mb key订正+ r4 改名批: 三echo v4.3.2 / probe改POST / probe后alive重算+策略对齐 / M3注释已定案 / gate零限流注释订正 / init_vars.json key body_limit_mb / omni-logic→omn-logic, omni_data→omn_data, /data/omni-data→/data/omn-data, HF_DATASET_REPO→OMN_DATASET_REPO**) |
| 2 | entrypoint-merged.sh | 263L | 061781764b45196a30201b6aa91b35fe3d0b0e01be1a7501863285473f69ab8d | 启动链编排 (M7 超时 env 外科单注 STREAM_READINESS_TIMEOUT_MS=180000, r3 查证定版 删 DEFAULT_REQUEST_TIMEOUT_MS) |
| 3 | gate.js | 520L | 616047c65b6120efd3faec31120528a3f20f3eb19c4f7f9bdd5582d7d6ef01d6 | PSK 网关 (零改, 现役) |
| 4 | litestream.yml | 29L | 1563c08de199933a598d57f6db076995ef1911da761f9df6f9e3f7171107b07e | 复制层 (零改, 现役) |
| 5 | parseRetryAfter.ts | 78L | 2957bc04d109d555acef4b283f33f6070e6d639a3d6687648c6dbf4a50cdaaa3 | P0-1 核心层补丁 (Retry-After 两格式解析) |
| 6 | backoffAndDedup.ts | 76L | 7c80486b741288993de64c77f98c784eac1858628d336d1cb401307f25a9a6f8 | P0-2 核心层补丁 (退避+去重) |
| 7 | events_schema.sql | 43L | dfe9a912206271906f340dd84c06ee80dc0c1c5e9a826ea696a80962781dde71 | P0-3 观测层 DDL (events 表契约) |

源路径标注: 1-4∧ 来自 `candidate-v4.3-reviewed/<同名>` 经 staging 改造; 5-7 来自 `patches/p0/<子目>/<同名>`(逐字 copy, 零改)。

## 审阅导言（半页）

**背景两句话**：(1) v4.3.1 固定档 28/3/2200 限流不随存活 key 数伸缩，alive 变化而限流不动 → 2026-07-21 账户级封禁事件设计根因。(2) 同事件签名: GET 目录 200 而 POST 推理 403 的账户级死亡 key 被盲注册, 运行时熔断兜底滞后。

**分层声明**:
- 文件 1-4 = **Track-1 部署阻塞级**（审完即推 nonoke, 解冻后）。
- 文件 5-7 = **Track-2 并行构建参考**（P0 弹药, 不阻塞 Track-1; R3 宣判后再接线接入, 本稿仅审设计）。

M6 原计划项本轮跳过（Zen 授权可选跳）。

---


## [1/7] init-nim-keys.sh

**路径**: `omn-logic/init-nim-keys.sh`  **行数**: 995L  **sha256**: `4cbcc50120ec4bb2ebd2d8a0b00dbfc75dbf9c08992361a9149dd0e8924efcd4`

**变更点**: M1 行148-171 动态限流三式(逐字 baseline-4.2.3) / M2 行739-765 maxWait 四字段读回断言 / M3 行536-642 真探活 POST /v1/chat/completions+auth_dead 跳注册+行610-650 probe后alive重算(硬伤3)+策略对齐(发现C) / M4 行799-806 压缩 enabled:false / M5 行5-8 顶注+行870 jq version v4.3.2+三echo全修(硬伤1). 注释改A(M3已定案)/B1(现役gate零限流) r2落.

```bash
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
LOG_DIR="/data/omn-data/log"
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
  # R3+ Restart A (i′ 方案): jq 修正式 (裁决 §4 根因 bug).
  # 旧式 `.combos[]? // .[]? | select(.name==$n)` 因 `//` 优先级低于 `|` 失控:
  # GET /api/combos 返 {combos:[...]}; `.combos[]?` 对对象遍历失败返空, `// .[]?` 对对象取值失败返空,
  # 结果 CID 永远空 → 永远 POST → 重名 400 死循环 (幂等 upsert 失效).
  # 修正式 (数组/对象双容): `if type=="array" then . else (.combos // []) end []? | select(...)`
  # — 根为数组直接遍历, 根为对象取 combos 字段, 兼两种响应结构.
  CID=$(curl -s -b "$COOKIE_FILE" "$BASE_URL/api/combos" \
        | jq -r --arg n "$NAME" '(if type=="array" then . else (.combos // []) end)[]? | select(.name==$n) | .id' | head -n1)
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

# int 范围校验器 (供 Resilience PATCH 白名单构造): $1=值 $2=下限(int) $3=上限(int); 返回 0 合格, 1 不合格
_res_validate_int() {
  [ -z "$1" ] && return 1
  case "$1" in
    ''|*[!0-9-]*) return 1 ;;   # 非数字 (允许负号作前缀, 实际范围校验拦截)
  esac
  [ "$1" -ge "$2" ] 2>/dev/null && [ "$1" -le "$3" ] 2>/dev/null || return 1
  return 0
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
    _body=$(curl -s -m "$_PROBE_TIMEOUT" -w $'\n%{http_code}' -X POST \
      "$NVIDIA_BASE_URL/v1/chat/completions" \
      -H "Authorization: Bearer $_rkey" -H 'Content-Type: application/json' \
      -d "$_probe_body" 2>/dev/null || printf '\n000')
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
      *)
        # 4xx(非403)/5xx/超时/000 → fail-open 判活 (boot 抖动不放大全停; 瞬态故障运行时熔断兜底)
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

echo "[init] Fetching provider IDs..."
PROVIDERS_HTTP=$(curl -s -o "$PROVIDERS_FILE" -w "%{http_code}" -b "$COOKIE_FILE" "$BASE_URL/api/providers")
if [ "$PROVIDERS_HTTP" = "200" ]; then
  mapfile -t PROVIDER_IDS < <(jq -r '[.. | objects | select((.provider? // "")=="nvidia") | select((.id? // "")!="") | .id] | unique | .[]' "$PROVIDERS_FILE" 2>/dev/null)
fi
echo "[init] Provider IDs: ${#PROVIDER_IDS[@]}"

purge_proxy_db

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
echo "[init] per-model 32K override (real_context=$_NIM_REAL_CONTEXT)..."
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
echo "[init]   POOL_STRATEGY=$_POOL_STRATEGY REAL_CONTEXT=$_NIM_REAL_CONTEXT (per-model 32K override 应用, monitor 自动回写禁用)"
echo "[init] ─────────────────────────────────────────────"

hf_snapshot() {
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
  #   仅 DEBUG 模式 + 显式开启 (NIM_DEBUG_LOG_TO_DATASET=1) + INIT_LOG 存在时; **默认关闭** (v4.3 红线1 动态).
  #   上传前字段级脱敏: Authorization/NIM_KEY/Cookie/Set-Cookie/Bearer 替换为 <REDACTED>.
  #   同时本地只保留最近 NIM_DEBUG_LOG_KEEP(默认5) 个。
  if [ "$NIM_MODE" = "DEBUG" ] && [ "${NIM_DEBUG_LOG_TO_DATASET:-0}" = "1" ] && [ -n "$INIT_LOG" ] && [ -f "$INIT_LOG" ]; then
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
    # 本地滚动清理：只保留最近 _keep 个 init_*.log
    if [ -d "$LOG_DIR" ]; then
      ls -1t "$LOG_DIR"/init_*.log 2>/dev/null | tail -n +$(( _keep + 1 )) | xargs -r rm -f 2>/dev/null || true
    fi
  else
    [ "$NIM_MODE" = "DEBUG" ] && echo "[init] snapshot: DEBUG log 上传已禁用（默认关, NIM_DEBUG_LOG_TO_DATASET=1 开启)."
  fi

  python3 - <<'PYEOF'
import os
from datetime import datetime, timezone
from huggingface_hub import HfApi
api = HfApi(token=os.environ["HF_TOKEN"])
api.upload_folder(folder_path="/tmp/omn-snapshot", path_in_repo="omn_data",
    repo_id=os.environ["OMN_DATASET_REPO"], repo_type="dataset",
    commit_message=f"Sync omn_data - {datetime.now(timezone.utc).isoformat()}")
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
hf_snapshot
purge_proxy_db

touch "$INIT_MARKER"
echo "[init] Final health check..."
HEALTH_FILE="$(_resp omniroute-final-health.json)"
HEALTH_HTTP=$(curl -s -o "$HEALTH_FILE" -w "%{http_code}" "$BASE_URL/api/monitoring/health" 2>/dev/null || echo "000")
[ "$HEALTH_HTTP" = "200" ] && echo "[init]   Status: $(jq -r '.status // "unknown"' "$HEALTH_FILE") / $(jq -r '.version // "unknown"' "$HEALTH_FILE")"
echo "[init] Done (first-init). v4.3.2"
```
## [2/7] entrypoint-merged.sh

**路径**: `omn-logic/entrypoint.sh`  **行数**: 263L  **sha256**: `061781764b45196a30201b6aa91b35fe3d0b0e01be1a7501863285473f69ab8d`

**变更点**: M7 行24-35 超时 env 外科单注 (r3 查证定版: 删 DEFAULT_REQUEST_TIMEOUT_MS 官方变量表缺席作废, 改单注 STREAM_READINESS_TIMEOUT_MS=180000, 不注 REQUEST_TIMEOUT_MS 避双面刃降额; gate 代码零 diff)

```bash
#!/bin/bash
# 进程编排总控 (合并版)
# =====================================================
# K3 v2.0 骨架 (已修 litestream restore -config; ephemeral 盘认清 → R2 是数据主路径)
# + candidate v4.3 加固迁移:
#   1. restore guard 完善版: flock 跨容器互斥 + -o 临时路径原子 mv + quick_check + -if-replica-exists 自适应 + STRICT 日志
#   2. trap SIGTERM/SIGINT: 向 上游服务/init/litestream/gate 四后台子进程转 SIGTERM, grace wait, SIGKILL 兜底, 无孤儿
# gate 用 background 运行 (node /logic/gate.js &) + GATE_PID 纳入 _shutdown 转发;
#   entrypoint 持 PID 1 主监控循环 (while true) 管四子进程。
#   (非 exec 接管 PID 1 — exec 会让三后台成 gate 兄弟变孤儿, trap 失效)
set -eo pipefail

OMNIROUTE_PORT="${OMNIROUTE_PORT:-20128}"
EXPOSED_PORT="${EXPOSED_PORT:-7860}"
# 默认 /app/data = 上游镜像固设 DATA_DIR (3.8.43 基线); env 可改
DATA_DIR="${DATA_DIR:-/app/data}"
DB_PATH="$DATA_DIR/storage.sqlite"
DB_TMP="$DATA_DIR/.storage.sqlite.restore.$$"   # 临时恢复路径 (原子保护)
LOCK_FILE="$DATA_DIR/.omniroute.lock"
# 版本校验：硬编码已驱逐，改读 EXPECTED_VERSION env（未设则只记录不比对）。
# 值放 Space Variable 与 BASE_IMAGE 同步更新，三文件永久免改。
EXPECTED_VER="${EXPECTED_VERSION:-}"

# v4.3.2 [M7·查证定版]: 超时 env 外科单注 (官方 Environment wiki §15 实证, 2026-07-22).
#   查证结论(wiki 有 CI check:env-doc-sync 强制 wiki↔.env.example 同步, 缺席=未识别):
#     · STREAM_READINESS_TIMEOUT_MS 默 80000(80s) = 首个非 ping SSE 事件时限 — 长思考"首 token 前静默"
#       真杀手(122s 级思考静默正对此刀). 外科抬至 180s, 不动其他预算; 未设 REQUEST_TIMEOUT_MS 时读自身值.
#     · REQUEST_TIMEOUT_MS = 全局快捷键, 同覆 FETCH_TIMEOUT_MS(默600000)/STREAM_IDLE_TIMEOUT_MS(默600000) —
#       注它会把总时限/流空闲从 600s 拉低到所注值, 双面刃; 本场景无降额需求, 故不注.
#     · DEFAULT_REQUEST_TIMEOUT_MS 不在官方变量表 → 规则五修正: 删除, 早前"双注"方案作废.
#   gate GATE_UPSTREAM_TIMEOUT_MS(行30 默30000) 仍零 diff: Node http.request timeout=socket 不活跃超时,
#     流式有数据即重置、思考静默>30s 触发 — 122s 级首 token 静默经 gate 如何完成列 K3 题5, 解冻后走 env 调.
STREAM_READINESS_TIMEOUT_MS="${STREAM_READINESS_TIMEOUT_MS:-180000}"
export STREAM_READINESS_TIMEOUT_MS
echo "[entrypoint] STREAM_READINESS_TIMEOUT_MS=$STREAM_READINESS_TIMEOUT_MS (M7 外科单注, wiki §15 实证)"

OR_PID=""; INIT_PID=""; LS_PID=""; GATE_PID=""

echo "[entrypoint] 上游服务启动 | PORT=$OMNIROUTE_PORT EXPOSED=$EXPOSED_PORT DATA=$DATA_DIR (ephemeral, R2 是数据主路径)"

# ── trap 转发: 向 上游服务/init/litestream/gate 四发 SIGTERM, grace 后 SIGKILL, wait 回收 ──
# 重要: gate 用 background (非 exec 接管 PID 1), entrypoint 持 PID 1 主监控循环;
#   否则 exec gate 会让三后台成 gate 兄弟 (孤儿), trap 失效。
cleanup_done=0
_forward_signal() {
  local sig="$1"
  for pid in "$OR_PID" "$INIT_PID" "$LS_PID" "$GATE_PID"; do
    [ -z "$pid" ] && continue
    kill -0 "$pid" 2>/dev/null && kill -"$sig" "$pid" 2>/dev/null || true
  done
}
_shutdown() {
  [ "$cleanup_done" = 1 ] && return
  cleanup_done=1
  echo "[entrypoint] shutdown: forwarding SIGTERM to background children..."
  _forward_signal TERM
  local g=0 alive
  while [ "$g" -lt 50 ]; do
    alive=0
    for pid in "$OR_PID" "$INIT_PID" "$LS_PID" "$GATE_PID"; do
      [ -z "$pid" ] && continue
      kill -0 "$pid" 2>/dev/null && alive=1
    done
    [ "$alive" = 0 ] && break
    sleep 0.1 2>/dev/null || sleep 1
    g=$((g + 1))
  done
  echo "[entrypoint] shutdown: force-kill 残留..."
  _forward_signal KILL
  for pid in "$OR_PID" "$INIT_PID" "$LS_PID" "$GATE_PID"; do
    [ -z "$pid" ] && continue
    wait "$pid" 2>/dev/null || true
  done
  echo "[entrypoint] shutdown complete."
}
trap '_shutdown' TERM
trap '_shutdown' INT

# ── 文件锁: 防多容器同时 restore/替换 $DB (HF Space 优先单实例, flock 不可用则 WARN 跳过) ──
exec 9>"$LOCK_FILE"
if command -v flock >/dev/null 2>&1; then
  flock -x 9 || { echo "[entrypoint] FATAL: 无法获取文件锁 $LOCK_FILE (另一容器占用?). abort." >&2; exit 1; }
  echo "[entrypoint] lock acquired (flock $LOCK_FILE, fd 9)."
else
  echo "[entrypoint] WARN: flock 不可用, 跳过跨容器互斥 (HF Space 优先单实例)."
fi

# ── 1. Litestream restore (启动前; 红线: 不覆盖有效 DB; ephemeral → R2 是数据主路径) ─
# 优雅降级:
#   R2 无副本 → -if-replica-exists rc=0 但不创建文件 → 空库启动 (init 重建), 不 exit
#   restore 失败 (配置/网络/权限) → WARN + 空库启动, 不 exit (永不因 restore 失败 FATAL)
#   restore 成功+有文件 → quick_check 通过 → 原子 mv → 正式 $DB
#   restore 成功+quick_check 失败 → 丢弃临时+空库启动, 不 exit
# K3 v2.0 修复: restore 增加 -config /litestream.yml (v1 缺此参数读默认 /etc/litestream.yml 导致静默失败)
has_r2=0
[ -n "${R2_ACCESS_KEY_ID:-}" ] && [ -n "${R2_SECRET_ACCESS_KEY:-}" ] && [ -n "${R2_ACCOUNT_ID:-}" ] && has_r2=1

if [ "$has_r2" = 0 ]; then
  echo "[entrypoint] ⚠ R2 凭据未配置 → skip restore, 空库启动 (数据将不可持久, 强烈建议补齐)"
elif [ -f "$DB_PATH" ] && [ -s "$DB_PATH" ]; then
  echo "[entrypoint] 本地库非空 ($DB_PATH) → skip restore (不覆盖有效 DB)"
else
  # 本地库空或不存在 → restore
  rm -f "$DB_TMP" "$DB_TMP-wal" "$DB_TMP-shm"
  printf '%s' "" > /tmp/ls_restore.err
  rc=0
  litestream restore -config /logic/litestream.yml -if-replica-exists -o "$DB_TMP" "$DB_PATH" 2>/tmp/ls_restore.err || rc=$?
  used_tmp=1
  # flag 自适应回退: 仅当某 flag 不支持才降级, 保留其它仍可支持 flag。
  # 优先级: -if-replica-exists -o tmp (最佳, R2 无副本 rc=0 无文件不 WARN)
  #   → -if-replica-exists 单独 (-o 不支持, 仍 R2 无副本 rc=0 无文件不 WARN)
  #   → 裸 restore (两 flag 都不支持, R2 无副本会 rc≠0 → 走 WARN 分支, 但有 "no replica/empty/not found" 字串例外不 WARN)
  if echo "$(cat /tmp/ls_restore.err 2>/dev/null)" | grep -qiE 'unknown flag|invalid option|flag provided but not defined'; then
    _err1="$(cat /tmp/ls_restore.err 2>/dev/null)"
    if printf '%s' "$_err1" | grep -qiE '\-o|output'; then
      # -o 不支持: 保留 -if-replica-exists, 去 -o, 直接 restore $DB_PATH (冷启动空, 无有效 DB 被覆盖)
      echo "[entrypoint] litestream 不支持 -o → 回退 -if-replica-exists 单独 restore $DB_PATH."
      rm -f "$DB_TMP" "$DB_TMP-wal" "$DB_TMP-shm"
      printf '%s' "" > /tmp/ls_restore.err
      rc=0
      litestream restore -config /logic/litestream.yml -if-replica-exists "$DB_PATH" 2>/tmp/ls_restore.err || rc=$?
      used_tmp=0
    elif printf '%s' "$_err1" | grep -qiE 'if-replica-exists'; then
      # -if-replica-exists 不支持: 裸 restore (R2 无副本会 rc≠0, 下文 "no replica" 例外不 WARN)
      echo "[entrypoint] litestream 不支持 -if-replica-exists → 回退裸 restore $DB_PATH."
      rm -f "$DB_TMP" "$DB_TMP-wal" "$DB_TMP-shm"
      printf '%s' "" > /tmp/ls_restore.err
      rc=0
      litestream restore -config /logic/litestream.yml "$DB_PATH" 2>/tmp/ls_restore.err || rc=$?
      used_tmp=0
    fi
  fi

  if [ "$rc" -ne 0 ]; then
    # 裸 restore (两 flag 都不支持) 在 R2 无副本时会 rc≠0, 但属正常首次部署, 不该 WARN。
    # litestream 无副本常见错误字串: "no replica"/"no data"/"not found"/"does not exist"/"empty"。
    if printf '%s' "$(cat /tmp/ls_restore.err 2>/dev/null)" | grep -qiE 'no replica|no (matching )?replica|no data|not found|does not exist|no entries|empty'; then
      echo "[entrypoint] restore rc=$rc 但匹配 '无副本' 错误 (R2 无副本或首次部署, 正常). 空库启动, init 重建配置."
    else
      echo "[entrypoint] ⚠ restore 失败 rc=$rc (见 /tmp/ls_restore.err; 已脱敏, 不打凭据). 空库启动."
      [ "${LITESTREAM_STRICT:-0}" = 1 ] && echo "[entrypoint]   STRICT=1: 仅告警, 不 exit (空库启动)."
    fi
    rm -f "$DB_TMP" "$DB_TMP-wal" "$DB_TMP-shm" 2>/dev/null || true
  elif [ "$used_tmp" = 1 ] && { [ ! -f "$DB_TMP" ] || [ ! -s "$DB_TMP" ]; }; then
    echo "[entrypoint] restore rc=0 但无文件 (R2 无副本或首次部署). 空库启动, init 重建配置."
    rm -f "$DB_TMP" "$DB_TMP-wal" "$DB_TMP-shm" 2>/dev/null || true
  elif [ "$used_tmp" = 1 ]; then
    # 临时文件有效 → quick_check → 原子 mv
    qc_ok=0
    if command -v sqlite3 >/dev/null 2>&1; then
      if sqlite3 "$DB_TMP" "PRAGMA quick_check;" 2>/dev/null | grep -q "^ok$"; then
        qc_ok=1
      else
        echo "[entrypoint] ⚠ quick_check 失败. 丢弃临时 $DB_TMP, 空库启动."
        [ "${LITESTREAM_STRICT:-0}" = 1 ] && echo "[entrypoint]   STRICT=1: 仅告警, 不 exit."
        rm -f "$DB_TMP" "$DB_TMP-wal" "$DB_TMP-shm" 2>/dev/null || true
      fi
    else
      echo "[entrypoint] sqlite3 不可用, 跳过 quick_check (验文件非空)."
      qc_ok=1
    fi
    [ "$qc_ok" = 1 ] && mv "$DB_TMP" "$DB_PATH" && echo "[entrypoint] ✓ 已从 R2 恢复 (原子 mv $DB_TMP → $DB_PATH)"
  else
    # used_tmp=0 (直接 $DB restore): 验 $DB 非空 + quick_check
    if [ ! -f "$DB_PATH" ] || [ ! -s "$DB_PATH" ]; then
      echo "[entrypoint] restore rc=0 但 $DB_PATH 无文件 (R2 无副本或首次部署). 空库启动, init 重建."
    elif command -v sqlite3 >/dev/null 2>&1; then
      if sqlite3 "$DB_PATH" "PRAGMA quick_check;" 2>/dev/null | grep -q "^ok$"; then
        echo "[entrypoint] ✓ 已从 R2 恢复 (直接 $DB_PATH, quick_check ok)"
      else
        echo "[entrypoint] ⚠ quick_check 失败 on $DB_PATH. 丢弃空库启动."
        rm -f "$DB_PATH" "$DB_PATH-wal" "$DB_PATH-shm" 2>/dev/null || true
      fi
    else
      echo "[entrypoint] ✓ 已从 R2 恢复 (直接 $DB_PATH, 文件非空)"
    fi
  fi
fi

# ── 2. 启动上游服务 ──
cd /app
node server.js &
OR_PID=$!
echo "[entrypoint] 上游服务 PID=$OR_PID"

# ── 3. 健康等待 (180s) ──
_DL=$(( $(date +%s) + 180 ))
_ready=0
while [ $(date +%s) -lt $_DL ]; do
  curl -sf "http://127.0.0.1:$OMNIROUTE_PORT/api/monitoring/health" >/dev/null 2>&1 && { _ready=1; break; }
  kill -0 $OR_PID 2>/dev/null || { echo "[entrypoint] ✗ 上游服务已退出"; exit 1; }
  sleep 2
done
if [ "$_ready" = 0 ]; then
  echo "[entrypoint] ✗ 健康等待超时 (180s 未就绪, 上游 PID $OR_PID 仍活但不响应 /api/monitoring/health)"; exit 1
fi
echo "[entrypoint] ✓ 就绪"
_VER=$(curl -sf "http://127.0.0.1:$OMNIROUTE_PORT/api/monitoring/health" | jq -r '.version // "unknown"' 2>/dev/null || echo unknown)
if [ -n "$EXPECTED_VER" ]; then
  if [ "$_VER" = "$EXPECTED_VER" ]; then
    echo "[entrypoint] 版本=$_VER ✓ (期望 $EXPECTED_VER)"
  else
    # 只告警不 exit：上游前滚迁移会让旧库自动进新 schema，版本不齐仍可跑。
    echo "[entrypoint] ⚠ 版本不齐 实跑=$_VER 期望=$EXPECTED_VER (非致命, 上游迁移自动前滚)"
  fi
else
  echo "[entrypoint] 版本=$_VER (期望未设置, 跳过比对)"
fi

# ── 4. NIM 初始化 (后台) ──
if [ -f /logic/init-nim-keys.sh ] && [ -n "${NIM_KEYS:-}" ]; then
  bash /logic/init-nim-keys.sh & INIT_PID=$!
  echo "[entrypoint] Init PID=$INIT_PID"
fi

# ── 5. Litestream 复制 (后台) ──
# v0.5.9契约: replicate -config 模式 fs.NArg()必须=0 (走配置文件内 dbs[].path).
#   传 $DB_PATH 位置参数会命中 case 1 → "must specify at least one replica URL" 报错.
#   db 路径已在 /logic/litestream.yml 的 dbs[].path 内定义, 命令行不可再传.
if [ "$has_r2" = 1 ] && [ -f /logic/litestream.yml ]; then
  litestream replicate -config /logic/litestream.yml & LS_PID=$!
  echo "[entrypoint] Litestream PID=$LS_PID"
fi

echo "[entrypoint] 全部就绪：OR=$OR_PID Init=${INIT_PID:-无} LS=${LS_PID:-无} Gate→:$EXPOSED_PORT (background, entrypoint 持 PID 1 主监)"

# ── 6. 启动 gate (background, entrypoint 持 PID 1 主监控循环) ──
# 上游健康二次确认: 若上游已死, 不启 gate (避孤儿 gate 空转)
if ! kill -0 "$OR_PID" 2>/dev/null; then
  echo "[entrypoint] FATAL: 上游服务 died before gate. abort"; _shutdown; exit 1
fi
if [ ! -f /logic/gate.js ]; then
  echo "[entrypoint] FATAL: gate.js 不存在"; _shutdown; exit 1
fi
echo "[entrypoint] starting gate on port $EXPOSED_PORT..."
node /logic/gate.js &
GATE_PID=$!
echo "[entrypoint] gate PID=$GATE_PID"

# ── 7. 监督循环: 任一关键进程退出 → 停其余 ──
# gate 为对外服务 = 退出停一切; 上游服务为必需 = 退出停一切;
# init 非致命 (仅日志); litestream 退出按 STRICT (严格 exit / 非致命告警 PID 置空)
_init_logged=0
while true; do
  if ! kill -0 "$GATE_PID" 2>/dev/null; then
    echo "[entrypoint] gate exited. 停止其余并退出."; _shutdown; exit 1
  fi
  if ! kill -0 "$OR_PID" 2>/dev/null; then
    echo "[entrypoint] 上游服务 exited. 停止其余并退出."; _shutdown; exit 1
  fi
  if [ -n "$INIT_PID" ] && ! kill -0 "$INIT_PID" 2>/dev/null; then
    [ "$_init_logged" = 1 ] || { wait "$INIT_PID" 2>/dev/null; _init_rc=$?; if [ "$_init_rc" -ne 0 ]; then echo "[entrypoint] ✗ NIM init 已退出 rc=$_init_rc (fail-closed 触发或异常)."; else echo "[entrypoint] NIM init 已退出 rc=0 (正常完成)."; fi; _init_logged=1; }
  fi
  if [ -n "$LS_PID" ] && ! kill -0 "$LS_PID" 2>/dev/null; then
    if [ "${LITESTREAM_STRICT:-0}" = 1 ]; then
      echo "[entrypoint] FATAL: Litestream replicate exited (strict). 停止."; _shutdown; exit 1
    else
      echo "[entrypoint] WARN: Litestream replicate exited (非致命). DB 不再备份 (LITESTREAM_STRICT=0)."
      LS_PID=""
    fi
  fi
  sleep 1
done
```

## [3/7] gate.js

**路径**: `omn-logic/gate.js`  **行数**: 520L  **sha256**: `616047c65b6120efd3faec31120528a3f20f3eb19c4f7f9bdd5582d7d6ef01d6`

**变更点**: 零改(现役). K3 审: GATE_UPSTREAM_TIMEOUT_MS 行30 默30000(30s) 语义+生效值(详见 K3 题5). **⚠ KNOWN(发现B2): gate.js 头注"28 RPM/1 并发/2200ms"为 v4.3.1 固定档残留描述, 与 v4.3.2 动态档(alive×35/alive×3, 9key→300/27/200)矛盾; 另头注称"无第二套限流"为真(现役 gate.js 正文 520 行零 tryAcquire/CONCURRENT_LIMIT, 限流唯一杠杆=上游 requestQueue, init 行156-159 注释 r2 已订正对齐). 头注修正属 gate 改动, 本稿保 gate 零 diff, 排期解冻后修.**

```javascript
// gate.js — v4.3 candidate (Stage D)
// OmniRoute PSK 出口 Proxy (HF Space :7860 -> 127.0.0.1:20128)
// 唯一出口代理, 经 OmniRoute 直连, 无外部 Relay / cf-worker / context-relay.
//
// 红线 2 (暴露面, 看管性改写——受后台开关约束):
//   默认 (GATE_ADMIN_TOKEN 未设/空/过短): 后台关闭, 外网仅 GET /healthz + /v1 + /v1/*; 其余 404.
//   设置有效 GATE_ADMIN_TOKEN: 后台白名单路径经 HTTP Basic Auth (admin/<token>) 放行;
//     白名单为 B3 v3.8.43 真实路由的最小权限保守子集, 非全量; 未验证路径恒 404, 不 allow-everything.
// 兼容: 保留原变量名 GATE_ADMIN_TOKEN (v8.0 后台鉴权变量, slim 删除前);
//   废弃 v8.0 "空 Token 内网直连不鉴权" 旧语义; 现: 空 Token = 后台关闭 (404).
// 三类入口分离: /healthz(免认证) | /v1,/v1/*(INTERNAL_PSK) | 后台白名单(GATE_ADMIN_TOKEN via Basic Auth).
//   互不回退, PSK 不访问后台, admin token 不访问 /v1.
// 后台认证仅外层入口保护, 不替代/OmniRoute 自身认证; Gate 不注入 Session, 不伪造 Cookie.
//   完成 Basic Auth 校验后, 删除/替换外层 Authorization 头, 不转发给上游 (防凭据泄露).
// 红线 (PSK/admin token): 缺失/格式错/长度不同/内容不同 → 401; crypto.timingSafeEqual 常量时间; 长度不等不退字符串比较.
// SSE: 逐块转发 (不聚合), 不 text/json 读流, 尊重背压, 客户端断开取消上游, 清理监听/定时器/流.
// 进程: SIGTERM/SIGINT 自处理优雅关 (entrypoint.sh trap 亦转发).
// 无第二套限流: 28 RPM/1 并发/2200ms 由 OmniRoute requestQueue 执行, 本文件零限流代码.
// IP/CIDR 限制: 不默认实现 (HF 代理拓扑未验证, 无 L1 证据 trust proxy); 预留能力默认关, KNOWN-UNVERIFIED 记.

const express = require('express');
const http = require('http');
const crypto = require('crypto');
const fs = require('fs');

const INTERNAL_PSK = process.env.INTERNAL_PSK || '';
const GATE_ADMIN_TOKEN = process.env.GATE_ADMIN_TOKEN || '';
const OR_PORT = parseInt(process.env.OMNIROUTE_PORT || '20128', 10);
const GATE_PORT = parseInt(process.env.EXPOSED_PORT || '7860', 10);
const UPSTREAM_TIMEOUT_MS = parseInt(process.env.GATE_UPSTREAM_TIMEOUT_MS || '30000', 10) || 30000;
const SHUTDOWN_GRACE_MS = parseInt(process.env.GATE_SHUTDOWN_GRACE_MS || '5000', 10) || 5000;
const ADMIN_TOKEN_MIN_LEN = 16;
const ADMIN_REALM = 'OmniRoute Admin';

// ── fail-closed: PSK 必须非空且最小长度 ──────────────────────
if (!INTERNAL_PSK || INTERNAL_PSK.length < 16) {
  console.error('[gate] FATAL: INTERNAL_PSK missing or <16 chars. HF Space Secret 必须配置。');
  process.exit(1);
}
let OR_API_KEY = (process.env.OMNIROUTE_API_KEY || '').trim();
if (!OR_API_KEY) {
  try { OR_API_KEY = fs.readFileSync('/data/.or-api-key', 'utf8').trim(); }
  catch (e) { if (e.code !== 'ENOENT') console.error('[gate] WARN read key failed:', e.message); }
}
if (!OR_API_KEY) {
  console.error('[gate] FATAL: No OR_API_KEY (env nor /data/.or-api-key).');
  process.exit(1);
}

// ── 后台开关 (单变量 GATE_ADMIN_TOKEN, 兼任开关 + 入口认证) ──
// 空/过短 → 后台关闭 (路径 404); 有效 → 后台白名单 + Basic Auth.
// 不记录/回显/转发 GATE_ADMIN_TOKEN.
const ADMIN_ENABLED = GATE_ADMIN_TOKEN.length >= ADMIN_TOKEN_MIN_LEN;
if (process.env.GATE_ADMIN_TOKEN && GATE_ADMIN_TOKEN.length < ADMIN_TOKEN_MIN_LEN) {
  console.error(`[gate] WARN: GATE_ADMIN_TOKEN 长度 <${ADMIN_TOKEN_MIN_LEN}, 后台关闭 (不记录 token 值).`);
}
console.log(`[gate] admin UI: ${ADMIN_ENABLED ? 'enabled' : 'disabled'} (开关状态可记, 不记 token).`);

// timing-safe equal: 双方 Buffer, 长度不等先返回不泄露内容, 长度相等路径走 timingSafeEqual.
function safeEqual(a, b) {
  if (!a || !b) return false;
  const ba = Buffer.from(a);
  const bb = Buffer.from(b);
  if (ba.length !== bb.length) return false;
  return crypto.timingSafeEqual(ba, bb);
}
// HTTP Basic Auth: user 固定 'admin', password = GATE_ADMIN_TOKEN. timing-safe 比密码.
function adminBasicAuthOk(req) {
  const header = req.headers.authorization || '';
  if (!header.startsWith('Basic ')) return false;
  let decoded;
  try { decoded = Buffer.from(header.slice('Basic '.length).trim(), 'base64').toString('utf8'); }
  catch (e) { return false; }          // base64 解码失败
  if (typeof decoded !== 'string' || decoded.indexOf(':') < 0) return false;
  const sep = decoded.indexOf(':');
  const user = decoded.slice(0, sep);
  const pass = decoded.slice(sep + 1);
  if (user !== 'admin') return false;
  return safeEqual(pass, GATE_ADMIN_TOKEN);   // timing-safe, 长度不等不退字符串比较
}

// ── 后台白名单 (B3 v3.8.43 真实路由最小权限保守子集, 源码 audit/06 ◆) ──
// 页面导航 (Next App Router 真实存在):
const ADMIN_PAGE_PREFIXES = [
  '/login', '/forgot-password', '/auth/callback', '/callback', '/authorize',
  '/connect', '/terms', '/privacy', '/docs', '/status', '/landing',
  '/home', '/dashboard',
];
// 页面允许方法 (GET 导航):
const ADMIN_PAGE_METHODS = ['GET'];
// 只读看板管理 API (B3 src/app/api 顶层只读子集; 排除 restart/shutdown/init/webhooks 等高风险写执行):
const ADMIN_API_ROUTES = [
  { pre: '/api/providers',          methods: ['GET'] },
  { pre: '/api/combos',             methods: ['GET'] },
  { pre: '/api/resilience',         methods: ['GET'] },
  { pre: '/api/keys',               methods: ['GET'] },
  { pre: '/api/provider-models',     methods: ['GET'] },
  { pre: '/api/models',             methods: ['GET'] },
  { pre: '/api/settings',           methods: ['GET'] },
  { pre: '/api/provider-stats',     methods: ['GET'] },
  { pre: '/api/provider-metrics',   methods: ['GET'] },
  { pre: '/api/sessions',           methods: ['GET'] },
  { pre: '/api/session-pools',      methods: ['GET'] },
  { pre: '/api/rate-limit',         methods: ['GET'] },
  { pre: '/api/rate-limits',        methods: ['GET'] },
  { pre: '/api/token-health',       methods: ['GET'] },
  { pre: '/api/synced-available-models', methods: ['GET'] },
  { pre: '/api/free-models',        methods: ['GET'] },
  { pre: '/api/free-provider-rankings', methods: ['GET'] },
  { pre: '/api/tags',               methods: ['GET'] },
];

function isStaticAssetPath(p) {
  if (p.startsWith('/_next/')) return true;
  return /^\/(favicon\.ico|favicon\.svg|apple-touch-icon\.(png|svg)|icon-192\.svg|icon-512\.png|sw\.js|openapi\.yaml)/.test(p);
}
function isAdminPagePath(p) {
  if (p === '/') return true;
  if (isStaticAssetPath(p)) return true;
  return ADMIN_PAGE_PREFIXES.some(pre => p === pre || p.startsWith(pre + '/') || p.startsWith(pre));
}
function apiRouteMatch(p, method) {
  for (const r of ADMIN_API_ROUTES) {
    if (p === r.pre || p.startsWith(r.pre + '/')) {
      return r.methods.includes(method);
    }
  }
  return false;
}

// ── 结构化诊断日志 (gate 出口 proxy 错误/abort) ──
//   一行 JSON stderr (HF Space 抓取): requestId/path/method/upstream/elapsedMs/httpStatus/errorCode/abortSource/destroyInitiator
//   abortSource 区分: 'upstream_error' (上游真错) / 'client_close' (客户端断开反发) / 'timeout' (gate 30s 超时) / 'shutdown'
//   destroyInitiator: 'gate_timeout' / 'client' / 'upstream' / 'null' (无主动 destroy)
//   不打印 headers/PSK/token/body (脱敏). 仅 path+method+errorCode (无敏感).
function genReqId() {
  try { return crypto.randomBytes(8).toString('hex'); } catch { return 'rid_unknown'; }
}
function logGate(req, fields) {
  try {
    const v = (n) => (typeof n === 'number' || typeof n === 'string') ? n : null;
    const line = JSON.stringify({
      ts: Date.now(),
      level: 'error',
      component: 'gate',
      stage: 'upstream_proxy',
      requestId: req?._gateReqId || null,
      method: req?.method || null,
      path: req?._normPath || null,
      upstream_path: req?._upstreamPath || null,
      upstream_target: `127.0.0.1:${OR_PORT}`,
      elapsedMs: v(fields.elapsedMs),
      httpStatus: v(fields.httpStatus),
      errorCode: fields.errorCode || null,
      abortSource: fields.abortSource || null,
      socketPhase: fields.socketPhase || null,
      destroyInitiator: fields.destroyInitiator || null,
      msg: fields.msg || null,
    });
    process.stderr.write(line + '\n');
  } catch { /* never throw from logger */ }
}

// abort source 区分: 从上游 error 事件 + 标记位判断谁发起 destroy
//   gateTimeout=true → 'timeout'; clientAborted=true → 'client_close'; shuttingDown → 'shutdown';
//   ECONNRESET + elapsedMs<5000 → 'upstream_reset' (短时窗 socket reset, 候选 stale pooled socket);
//   else 'upstream_error'.
//   timeout/client_close/shutdown 三类判断逻辑不变 (task#23 仅增 upstream_reset 兜底前).
function classifyAbortSource(e, { gateTimeout, clientAborted, elapsedMs } = {}) {
  if (gateTimeout) return 'timeout';
  if (clientAborted) return 'client_close';
  if (shuttingDown) return 'shutdown';
  if (e?.code === 'ECONNRESET' && typeof elapsedMs === 'number' && elapsedMs < 5000) {
    return 'upstream_reset';
  }
  return 'upstream_error';
}

// HTTP status 映射: ECONNREFUSED/ECONNRESET=503 (upstream unavailable/rest),
//   timeout/ETIMEDOUT/ESOCKETTIMEDOUT=504 (gateway_timeout), 其余=502 (bad_gateway)
function mapUpstreamStatus(e, { gateTimeout } = {}) {
  if (gateTimeout || e?.code === 'ETIMEDOUT' || e?.code === 'ESOCKETTIMEDOUT') return 504;
  if (e?.code === 'ECONNREFUSED' || e?.code === 'ECONNRESET') return 503;
  return 502;
}
function statusErrorLabel(code) {
  return code === 504 ? 'gateway_timeout'
    : code === 503 ? 'service_unavailable'
    : 'bad_gateway';
}

const app = express();
let shuttingDown = false;

// 注入 requestId + 开始时间 (per-request, 在路径规整化中间件后可用 _normPath)
app.use((req, res, next) => {
  req._gateReqId = genReqId();
  req._gateT0 = Date.now();
  next();
});

// ── /healthz: 免认证探活 ─────────────────────────────────
app.get('/healthz', async (req, res) => {
  if (shuttingDown) return res.status(503).json({ ok: false });
  let r;
  try {
    r = await fetch(`http://127.0.0.1:${OR_PORT}/api/monitoring/health`, {
      signal: AbortSignal.timeout(2000),
    });
  } catch (e) {
    return res.status(503).json({ ok: false });
  }
  r?.ok ? res.json({ ok: true }) : res.status(503).json({ ok: false });
});

// 路径规整化: 解 dot-segment, 重复斜杠, 尾斜杠 (防绕过白名单匹配)
function normalizePath(p) {
  try {
    const u = new URL(p, 'http://x');
    let n = u.pathname.replace(/\/+/g, '/').replace(/\/$/, '');
    if (n === '') n = '/';
    return n;
  } catch (e) {
    return p;
  }
}

// ── 暴露面白名单 (默认仅 /healthz + /v1; 管理白名单仅 token 有效时) ──
//   非 /healthz / 非 /v1: 须 ADMIN_ENABLED 且路径在白名单 (页/api/静态), 否则 404.
//   后台关闭时即使带 OmniRoute Cookie/Session 也 404 (不泄露后台是否存在).
app.use((req, res, next) => {
  req._normPath = normalizePath(req.path);
  if (shuttingDown && req._normPath !== '/healthz') return res.status(503).json({ ok: false });
  if (req._normPath === '/healthz') return next();
  if (req._normPath === '/v1' || req._normPath.startsWith('/v1/')) return next();
  // 后台
  if (!ADMIN_ENABLED) return res.status(404).end();
  const p = req._normPath;
  // 静态资源 (开关开后免 Basic Auth, 仍须白名单)
  if (isAdminPagePath(p)) {
    if (isStaticAssetPath(p)) return next();   // 静态免 token, 仅须开关开
    // 页面导航须 method GET + Basic Auth (后中间件)
    if (ADMIN_PAGE_METHODS.includes(req.method)) return next();
    return res.status(405).json({ error: 'method_not_allowed' });
  }
  if (apiRouteMatch(p, req.method)) return next();
  if (apiRouteMatch(p, 'GET') && req.method !== 'GET') {
    return res.status(405).json({ error: 'method_not_allowed' });
  }
  return res.status(404).end();   // 非白名单 + 未知 → 404, 开启用时仍 404
});

// ── 后台页 + api Basic Auth (静态免) ──
//   通过后删除 Authorization 头 (不转发 Basic 给上游 OmniRoute, 防凭据泄露).
app.use((req, res, next) => {
  if (req._normPath === '/healthz' || req._normPath === '/v1' || req._normPath.startsWith('/v1/')) return next();
  if (!ADMIN_ENABLED) return next();   // 后台关 (已在白名单中间件 404, 此处不到)
  const p = req._normPath;
  if (isStaticAssetPath(p)) return next();   // 静态免 token
  if (!isAdminPagePath(p) && !apiRouteMatch(p, req.method)) return next();   // 非白名单 (已 404, 不到)
  if (!adminBasicAuthOk(req)) {
    res.setHeader('WWW-Authenticate', `Basic realm="${ADMIN_REALM}", charset="UTF-8"`);
    return res.status(401).json({ error: 'unauthorized' });
  }
  delete req.headers.authorization;   // 不转发 Basic 给上游; OmniRoute 自身认证照走 (Cookie/Session)
  next();
});

// ── /v1 PSK 校验: Internal PSK timing-safe ──
app.use('/v1', (req, res, next) => {
  const auth = req.headers.authorization || '';
  if (!auth.startsWith('Bearer ')) {
    return res.status(401).json({ error: 'unauthorized' });
  }
  const bearer = auth.slice('Bearer '.length).trim();
  if (!safeEqual(bearer, INTERNAL_PSK)) {
    return res.status(401).json({ error: 'unauthorized' });
  }
  req.headers.authorization = `Bearer ${OR_API_KEY}`;   // /v1 转发用 OR_API_KEY
  next();
});

// ── SSE 透传代理: 手写 http, 逐块 pipe, 客户端断开 abort 上游 ─
function proxyV1(req, res) {
  // app.use('/v1', ...) mount 下 req.path 被 Express strip '/v1' 前缀; 用 originalUrl 保完整 (含 query).
  const upstreamPath = req.originalUrl;
  const headers = { ...req.headers };
  delete headers.host;
  headers.host = `127.0.0.1:${OR_PORT}`;

  const upstreamReq = http.request({
    host: '127.0.0.1',
    port: OR_PORT,
    method: req.method,
    path: upstreamPath,
    headers,
    timeout: UPSTREAM_TIMEOUT_MS,
  }, (upstreamRes) => {
    req._socketPhase = 'streaming';   // 已收 response head → 进入流相 (含 SSE 逐块)
    res.writeHead(upstreamRes.statusCode, upstreamRes.headers);
    upstreamRes.on('data', (chunk) => {
      if (!res.write(chunk)) {
        upstreamRes.pause();
        res.once('drain', () => upstreamRes.resume());
      }
    });
    upstreamRes.on('end', () => { if (!res.writableEnded) res.end(); });
    upstreamRes.on('error', (e) => {
      // 上游响应流中途错 (已 head, 非 connect 错): fallback 502 + 结构化日志
      // task#23: 复用 classifyAbortSource (非硬码 'upstream_error'); 流相 elapsedMs 多 >5000 → 落 upstream_error
      const elapsedMs = Date.now() - (req._gateT0 || 0);
      const abortSource = classifyAbortSource(e, { gateTimeout, clientAborted, elapsedMs });
      logGate(req, { elapsedMs, httpStatus: 502,
        errorCode: e?.code || e?.message || 'upstream_response_stream_error',
        abortSource, socketPhase: req._socketPhase || 'streaming',
        destroyInitiator: 'upstream', msg: 'upstream_response_stream_error' });
      if (!res.headersSent) res.status(502).json({ error: 'bad_gateway', abort_source: abortSource });
      else if (!res.writableEnded) res.end();
    });
  });

  // socketPhase 跟踪: connecting → headers → streaming (供 upstream_reset/upstream_error 日志区分断在哪相)
  req._socketPhase = 'connecting';
  upstreamReq.on('socket', (socket) => {
    socket.on('connect', () => { if (req._socketPhase === 'connecting') req._socketPhase = 'headers'; });
  });

  // abort source tracking: 区分 client 断开 vs gate 超时 vs upstream 真错
  let aborted = false;
  let gateTimeout = false;   // gate 主动超时 destroy
  let clientAborted = false; // 客户端断开触发 cleanup
  let firstError = null;      // 首个上游 error (后续 destroy 反发不覆盖)
  function cleanup() {
    if (aborted) return;
    aborted = true;
    if (upstreamReq) {
      // 仅在 client 断开机上标记 (timeout handler 自己标记, 避免误判)
      if (!gateTimeout) { clientAborted = true; upstreamReq.destroy(); }
    }
    res.removeAllListeners('drain');
  }
  req.on('error', () => { clientAborted = true; cleanup(); });
  req.on('aborted', () => { clientAborted = true; cleanup(); });
  req.on('close', () => { clientAborted = true; cleanup(); });

  upstreamReq.on('timeout', () => {
    gateTimeout = true;
    upstreamReq.destroy(new Error('upstream_timeout'));
    const code = 504;
    logGate(req, { elapsedMs: Date.now() - (req._gateT0 || 0), httpStatus: code, errorCode: 'ETIMEDOUT',
      abortSource: 'timeout', destroyInitiator: 'gate_timeout', msg: 'upstream_request_timeout' });
    if (!res.headersSent) res.status(code).json({ error: statusErrorLabel(code), abort_source: 'timeout' });
    else if (!res.writableEnded) res.end();
  });
  upstreamReq.on('error', (e) => {
    // 首个 error 仅记一次 (后续 destroy 同事件反发不覆盖诊断)
    if (!firstError) firstError = e;
    // abort source 区分: client 已断开 + 这是 cleanup 反发的 destroy → client_close (不响应, client 已走)
    const elapsedMs = Date.now() - (req._gateT0 || 0);
    const abortSource = classifyAbortSource(e, { gateTimeout, clientAborted, elapsedMs });
    const code = clientAborted ? null : mapUpstreamStatus(e, { gateTimeout });
    // 不打 504 重复日志 (timeout handler 已打)
    if (!gateTimeout) {
      // socketPhase 仅附加于 upstream_reset/upstream_error (timeout/client_close/shutdown 不附, 非其语义)
      const phase = (abortSource === 'upstream_reset' || abortSource === 'upstream_error')
        ? (req._socketPhase || null) : null;
      logGate(req, {
        elapsedMs,
        httpStatus: code,
        errorCode: e?.code || e?.message || 'unknown_error',
        abortSource,
        socketPhase: phase,
        destroyInitiator: clientAborted ? 'client' : (gateTimeout ? 'gate_timeout' : 'upstream'),
        msg: abortSource === 'client_close' ? 'client_disconnected_proxy_aborted'
          : abortSource === 'shutdown' ? 'gate_shutting_down'
          : abortSource === 'upstream_reset' ? 'upstream_socket_reset_short_lived'
          : 'upstream_error',
      });
    }
    // client 断开: client 已不可达, 不再写 res (headersSent与否都直接 end)
    if (clientAborted) {
      if (!res.writableEnded) { try { res.end(); } catch {} }
      return;
    }
    if (!res.headersSent && code) {
      res.status(code).json({ error: statusErrorLabel(code), abort_source: abortSource });
    } else if (!res.writableEnded) {
      res.end();
    }
  });

  // 转发 body: 有 body 用 pipe 自动 end; 无 body (GET/OPTIONS) 须显式 end 发请求 (req 在 Express 已 end
  // 但 pipe 不一定触发 destination end; 显式收尾确保上游收到完整请求).
  if (req.readable && (req.headers['content-length'] || req.headers['transfer-encoding'])) {
    req.pipe(upstreamReq);
  } else {
    upstreamReq.end();
  }
}

app.use('/v1', (req, res) => proxyV1(req, res));

// 后台页 + api 转发 (经 Basic Auth + Authorization 已删); /v1 已各别处理
function proxyAdmin(req, res) {
  const qIdx = req.url.indexOf('?');
  const qs = qIdx >= 0 ? req.url.slice(qIdx) : '';
  const upstreamPath = req.path + qs;
  const headers = { ...req.headers };
  delete headers.host;
  headers.host = `127.0.0.1:${OR_PORT}`;
  // Authorization 已在 Basic Auth 中间件 delete; OmniRoute 自身认证 (Cookie/Session) 原样上行.

  const upstreamReq = http.request({
    host: '127.0.0.1',
    port: OR_PORT,
    method: req.method,
    path: upstreamPath,
    headers,
    timeout: UPSTREAM_TIMEOUT_MS,
  }, (upstreamRes) => {
    res.writeHead(upstreamRes.statusCode, upstreamRes.headers);
    upstreamRes.on('data', (chunk) => {
      if (!res.write(chunk)) {
        upstreamRes.pause();
        res.once('drain', () => upstreamRes.resume());
      }
    });
    upstreamRes.on('end', () => { if (!res.writableEnded) res.end(); });
    upstreamRes.on('error', (e) => {
      // 上游响应流中途错 (非 connect 错): 已 head, fallback 502 + 结构化日志
      logGate(req, { elapsedMs: Date.now() - (req._gateT0 || 0), httpStatus: 502,
        errorCode: e?.code || e?.message || 'upstream_response_stream_error',
        abortSource: 'upstream_error', destroyInitiator: 'upstream', msg: 'upstream_response_stream_error' });
      if (!res.headersSent) res.status(502).json({ error: 'bad_gateway', abort_source: 'upstream_error' });
      else if (!res.writableEnded) res.end();
    });
  });
  // abort source tracking (同 proxyV1): 区分 client 断开 vs gate 超时 vs upstream 真错
  let aborted = false;
  let gateTimeout = false;
  let clientAborted = false;
  let firstError = null;
  function cleanup() {
    if (aborted) return;
    aborted = true;
    if (upstreamReq) {
      if (!gateTimeout) { clientAborted = true; upstreamReq.destroy(); }
    }
    res.removeAllListeners('drain');
  }
  req.on('error', () => { clientAborted = true; cleanup(); });
  req.on('aborted', () => { clientAborted = true; cleanup(); });
  req.on('close', () => { clientAborted = true; cleanup(); });
  upstreamReq.on('timeout', () => {
    gateTimeout = true;
    upstreamReq.destroy(new Error('upstream_timeout'));
    const code = 504;
    logGate(req, { elapsedMs: Date.now() - (req._gateT0 || 0), httpStatus: code, errorCode: 'ETIMEDOUT',
      abortSource: 'timeout', destroyInitiator: 'gate_timeout', msg: 'admin_upstream_request_timeout' });
    if (!res.headersSent) res.status(code).json({ error: statusErrorLabel(code), abort_source: 'timeout' });
    else if (!res.writableEnded) res.end();
  });
  upstreamReq.on('error', (e) => {
    if (!firstError) firstError = e;
    const abortSource = classifyAbortSource(e, { gateTimeout, clientAborted });
    const code = clientAborted ? null : mapUpstreamStatus(e, { gateTimeout });
    if (!gateTimeout) {
      logGate(req, {
        elapsedMs: Date.now() - (req._gateT0 || 0),
        httpStatus: code,
        errorCode: e?.code || e?.message || 'unknown_error',
        abortSource,
        destroyInitiator: clientAborted ? 'client' : (gateTimeout ? 'gate_timeout' : 'upstream'),
        msg: abortSource === 'client_close' ? 'admin_client_disconnected_proxy_aborted'
          : abortSource === 'shutdown' ? 'gate_shutting_down' : 'admin_upstream_error',
      });
    }
    if (clientAborted) {
      if (!res.writableEnded) { try { res.end(); } catch {} }
      return;
    }
    if (!res.headersSent && code) {
      res.status(code).json({ error: statusErrorLabel(code), abort_source: abortSource });
    } else if (!res.writableEnded) {
      res.end();
    }
  });
  // 转发 body: 有 body 用 pipe 自动 end; 无 body (GET/OPTIONS) 须显式 end 发请求 (req 在 Express 已 end
  // 但 pipe 不一定触发 destination end; 显式收尾确保上游收到完整请求).
  if (req.readable && (req.headers['content-length'] || req.headers['transfer-encoding'])) {
    req.pipe(upstreamReq);
  } else {
    upstreamReq.end();
  }
}
// catch-all: 白名单已过中间件的 (后台页/api 非 /v1) → proxyAdmin; /v1 已前处理
app.use((req, res) => {
  if (req._normPath === '/healthz') return res.status(502).json({ error: 'bad_gateway' });  // /healthz 后端挂
  if (req._normPath === '/v1' || req._normPath.startsWith('/v1/')) return proxyV1(req, res);
  // 后台 (白名单已过 + Basic Auth 已过)
  return proxyAdmin(req, res);
});

const server = app.listen(GATE_PORT, '0.0.0.0', () => {
  const actualPort = server.address().port;   // GATE_PORT=0 (test/random) 时取实际监听端口; 生产 7860 同值
  console.log(`[gate] listening on 0.0.0.0:${actualPort} -> 127.0.0.1:${OR_PORT}`);
});

function shutdown(sig) {
  if (shuttingDown) return;
  shuttingDown = true;
  console.log(`[gate] received ${sig}, shutting down (grace ${SHUTDOWN_GRACE_MS}ms)...`);
  server.close(() => { process.exit(0); });
  setTimeout(() => {
    console.error('[gate] forced exit after grace.');
    process.exit(1);
  }, SHUTDOWN_GRACE_MS).unref();
}
process.on('SIGTERM', () => shutdown('SIGTERM'));
process.on('SIGINT', () => shutdown('SIGINT'));
```

## [4/7] litestream.yml

**路径**: `omn-logic/litestream.yml`  **行数**: 29L  **sha256**: `1563c08de199933a598d57f6db076995ef1911da761f9df6f9e3f7171107b07e`

**变更点**: 零改(现役). bucket omn-data, sync-interval 10s, auto-recover false, l0-retention 5m.

```yaml
dbs:
  - path: /app/data/storage.sqlite
    replica:
      type: s3
      bucket: omn-data
      path: db/storage.sqlite
      endpoint: https://${R2_ACCOUNT_ID}.r2.cloudflarestorage.com
      access-key-id: ${R2_ACCESS_KEY_ID}
      secret-access-key: ${R2_SECRET_ACCESS_KEY}
      region: auto
      sync-interval: 10s
      # v4.3 红线3: 改 false. entrypoint.sh 已显式 restore (含本地非空 guard + 临时路径 + quick_check);
      # 若 auto-recover true, litestream replicate 启动时自恢复会绕过 entrypoint 的 guard, 可能覆盖有效 DB.
      auto-recover: false

snapshot:
  interval: 1h
  retention: 24h

# 顶层 Configure 键 (源码核证: cmd/litestream/main.go 行 264 Config struct 顶层字段, 非 dbs[].replica 子键).
# v0.5.9 replicate.go 行 248-249: c.Config.L0RetentionCheckInterval -> c.Store.L0RetentionCheckInterval.
# 嵌在 replica: 内会被 ReplicaConfig 忽略 (无此字段), 静默不生效; 必须顶层与 dbs/snapshot 同级.
# L0 监控默认 15s -> 5m: 纯监控参数 (只控多久查一次 L0 段是否过期可删), 不改任何 compaction 语义.
# retention 执行精度 15s -> 5m 对 5m 保留期机制零影响 (最坏过期段多活几分钟, R2 存储免费额度内可忽略).
# Class A 减量: L0 retention LIST 占 63%, 15s -> 5m 砍 ~20x, 总量约 27万/月 -> ~10万/月 (免费线 27% -> 10%).
# levels: 不设 — yaml 设 levels 完全覆写预置 L1=30s/L2=5m/L3=1h 三级阶梯 (DefaultCompactionLevels),
#   单条 levels:[{interval:5m}] 会让 L2/L3 compaction 监控消失 (覆写非追加), compaction 阶梯断.
#   保留预置不碰 = L1/L2/L3 三条 monitor 行 interval 改前逐字一致即可作"levels 未动"实证.
l0-retention-check-interval: 5m
```

## [5/7] parseRetryAfter.ts

**路径**: `patches/p0/retry-after/parseRetryAfter.ts`  **行数**: 78L  **sha256**: `2957bc04d109d555acef4b283f33f6070e6d639a3d6687648c6dbf4a50cdaaa3`

**变更点**: 零改(P0弹药). Retry-After 两格式解析(秒数 + HTTP-date), NaN→null, 已过→0. mock 10/10.

```typescript
/**
 * parseRetryAfter — P0 补丁: Retry-After 头硬遵守解析
 * =====================================================================
 * 来源证据(上游 3.8.43 真源已有半成品, 本补丁补全 HTTP-date 洞):
 *   - open-sse/handlers/chatCore.ts:2359  取头 normalizedHeaders["retry-after"]
 *   - open-sse/handlers/chatCore.ts:2360  解析: Number.parseFloat(header) * 1000
 *                                           ↑ 只处理"秒数"格式, 遇 HTTP-date 返 NaN → 退避失效
 *   - open-sse/services/accountFallback.ts:519  注释明提 "a `Retry-After` header"
 *                                            应被 exactCooldownMs 精确遵守, 但上游解析阶段就漏了 HTTP-date
 *
 * 补丁职责(架构师红线: "遵守"而非"重试策略"):
 *   本函数只解析 + 返回最小等待毫秒数. 是否重试 / 403 进冷却还是熔断的
 *   分类策略, 属 R3 宣判后才定稿部分, 本补丁一律不实现, 只留接口(TBD-POLICY).
 *
 * 适用面(由调用方决定, 本函数仅给值):
 *   429 / 503 / 携带 Retry-After 头的 403
 *
 * RFC 7231 §7.1.3 Retry-After 两合法格式:
 *   1. delta-seconds: 纯数字秒, 如 "120"
 *   2. HTTP-date:    IMF-fixdate, 如 "Wed, 22 Jul 2026 03:16:00 GMT"
 *
 * 边界:
 *   - 秒数负值/NaN → null (协议非法, 不作退避依据)
 *   - HTTP-date 已过 → 0 (等方式不退避, 但返回0以区分"无头")
 *   - 解析失败/未知格式 → null (调用方走指数退避+抖动分支)
 *   - 秒数封顶: RFC 允许巨大值, 本函数不截断(遵守语义), 由调用方 maxCooldownMs 兜底
 */

// HTTP-date 解析: 用 Date.parse 接 IMF-fixdate (RFC 7231 §7.1.1.1)
// 返回 null 表"非日期或解析失败", 返回 0 表"日期已过当下"
function parseHttpDate(header: string, nowMs: number): number | null {
  const ts = Date.parse(header);
  if (Number.isNaN(ts)) return null; // 非 HTTP-date
  const delta = ts - nowMs;
  return delta < 0 ? 0 : delta;
}

// delta-seconds 解析: 仅整数/浮点秒, 严格拒非数字串
// 返回 null 表"非秒数格式"
function parseDeltaSeconds(header: string): number | null {
  // 严格: 允许前后空白, 中段必须是纯数字(可带小数点)
  const trimmed = header.trim();
  if (trimmed === "" || !/^\d+(\.\d+)?$/.test(trimmed)) return null;
  const seconds = Number.parseFloat(trimmed);
  if (!Number.isFinite(seconds) || seconds < 0) return null;
  return seconds * 1000;
}

/**
 * 解析 Retry-After 头为最小等待毫秒数(硬遵守依据).
 * @param header 原始头值(undefined/null → null)
 * @param nowMs  当前时间戳(注入以便测试, 不在函数内 new Date)
 * @returns 毫秒数; null=无头或格式全失败(走退避); 0=日期已过
 */
export function parseRetryAfter(
  header: string | null | undefined,
  nowMs: number
): number | null {
  if (header == null) return null;
  const h = String(header).trim();
  if (h === "") return null;

  // 先试 delta-seconds (纯数字), 不通再试 HTTP-date
  const seconds = parseDeltaSeconds(h);
  if (seconds !== null) return seconds;

  const dateMs = parseHttpDate(h, nowMs);
  return dateMs; // null 或 0 或 正数
}

// ── TBD 参数清单(依赖 R3 宣判, 本补丁不填值) ──────────────────
// TBD-POLICY-1: retryAfterMs 命中后, 403 进 cooldown 还是 circuit-breaker?
//               (上游 accountFallback.ts:704 现 403→quota_exhausted 1h 短冷却, 4.B 第10项判 P0 缺陷,
//                但改策略违本补丁红线, 留 R3 宣判定稿)
// TBD-POLICY-2: Retry-After 头值的硬度上限 (是否 cap 到 maxCooldownMs, 用哪个 TBD 常数)
// TBD-PARAM-3:  无 Retry-After 退避基数/上限/抖动幅度 (现 v2 §待R3: TBD-COOLDOWN-MS 参数谱)
// TBD-DEDUP-4:  请求指纹算法 + 退避窗口去重 store 实现 (本补丁只给接口)
// ──────────────────────────────────────────────────────────
```

## [6/7] backoffAndDedup.ts

**路径**: `patches/p0/retry-after/backoffAndDedup.ts`  **行数**: 76L  **sha256**: `7c80486b741288993de64c77f98c784eac1858628d336d1cb401307f25a9a6f8`

**变更点**: 零改(P0弹药). 指数退避+确定性伪抖动+DedupStore 去重接口. mock 10/10.

```typescript
/**
 * backoffAndDedup — P0 补丁: 无 Retry-After 时的退避 + 请求指纹去重接口
 * =====================================================================
 * 职责(架构师红线: 本补丁只给"等待时长" + "去重判定", 不定重试分类策略):
 *   - 无 Retry-After 头 → 指数退避 + 全幅抖动, 严禁立即重试(退避0毫秒一律判非法)
 *   - 相同请求指纹在退避窗口内不重复发出(缓存去重挂钩, TBD-DEDUP-4 待 R3 定 store)
 *
 * 速率三准则对应(v2 §速律):
 *   并发 ≤2-3 / 缓存去重 / Retry-After 优先(本文件即前两条落地, 第三条在 parseRetryAfter)
 *
 * 不实现(R3 宣判后):
 *   retry 决策本身 (是否真重试 vs fail-fast), 指纹 store 的持久化方式
 */

// ── 退避参数: 全部 TBD, 本补丁给接口与默认守门值, 不焊死真实数值 ──
// TBD-PARAM-3: 退避基数/倍数/上限/抖动比例 — R3 宣判从金丝雀数据定标
const BACKOFF_GUARD = {
  // 仅防"退化成立即重试"的最低守门值; 真实 base/max 见 TBD-PARAM-3
  // 非零即"禁止 0 毫秒退避", 与红线"严禁立即重试"一致
  minFloorMs: 1,
} as const;

export interface BackoffParams {
  attempt: number;          // 已失败次数 (1 起)
  nowMs: number;            // 注入时间戳(测试用, 不调 new Date)
  baseMs: number;           // TBD-PARAM-3: 退避基数
  maxMs: number;            // TBD-PARAM-3: 退避上限
  jitterRatio: number;      // 0..1 全幅抖动比例
}

/**
 * 指数退避 + 全幅抖动. 无 Retry-After 时调用.
 * 返回等待毫秒数, 永远 > 0 (minFloorMs 守门禁立即重试).
 *
 * 抖动: full jitter (Marc Brooker), 在 [0, exponential] 区间均匀.
 */
export function computeBackoff(p: BackoffParams): number {
  const exp = Math.min(p.baseMs * Math.pow(2, p.attempt - 1), p.maxMs);
  // 抖动注入点(R3 TBD-PARAM-3 决其为确定/随机): 本补丁给全幅抖动公式
  // 注意: Math.random 在测试中需注入, 此处假设调用方传已抖动值不现实,
  // 故本补丁用 attempt 作伪抖动种子替代真实随机, 避开"测试不可复现"且
  // 不依赖运行时 RNG (合成纪律: 避免不可控源).
  const pseudoJitter = (p.attempt * 9301 + 49297) % 233280 / 233280; // LCG 确定性伪随机
  const jitter = pseudoJitter * p.jitterRatio * exp;
  const wait = exp - jitter;
  return wait < BACKOFF_GUARD.minFloorMs ? BACKOFF_GUARD.minFloorMs : wait;
}

/**
 * 请求指纹去重接口(缓存去重挂钩).
 * 相同指纹在退避窗口(nowMs < untilMs)内 → true 表"应去重不发".
 *
 * store 实现留 TBD-DEDUP-4(R3 定持久化: 内存 Map / SQLite / Redis).
 * 本补丁只给判定签名, 调用方注入 store.
 */
export interface DedupStore {
  // 返回该指纹的退避截止时间戳, 无则 null
  getUntilMs(fingerprint: string): number | null;
  // 设该指纹退避截止
  setUntilMs(fingerprint: string, untilMs: number): void;
}

export function shouldDedup(
  fingerprint: string,
  nowMs: number,
  store: DedupStore
): boolean {
  const until = store.getUntilMs(fingerprint);
  if (until === null) return false;
  return nowMs < until;
}

// ── 请求指纹算法: TBD-DEDUP-4, 本补丁给占位签名, R3 后定 ──
// 候选维度: method + path + 归一化body hash + key身份hash(脱敏)
// 本补丁不实现具体 hash, 留接口防"未宣判假设焊死"
export type FingerprintFn = (method: string, path: string, bodyHash: string) => string;
```

## [7/7] events_schema.sql

**路径**: `patches/p0/events-table/events_schema.sql`  **行数**: 43L  **sha256**: `dfe9a912206271906f340dd84c06ee80dc0c1c5e9a826ea696a80962781dde71`

**变更点**: 零改(P0弹药). events 表四列(id/ts/event_type/payload)+两索引. 零新增持久通道(乘 Litestream). mock 13/13.

```sql
-- ============================================================
-- p0-events-table — SQLite events 表 schema 草案
-- ============================================================
-- Zen 增补令 #1 · 依附 cg52 v2 §5 P0 局部提前授权
-- 本地合成弹药, R3 宣判(2026-07-23 03:16 后)前不出仓不上 Space.

-- ── 零新增持久通道红线(架构师) ──────────────────────────────
-- 所有写入必须落进 Litestream 正在复制的那个库文件
--   = entrypoint-merged.sh:17  DB_PATH="$DATA_DIR/storage.sqlite"
--   = candidate-v4.3-reviewed/litestream.yml  dbs[0].path=/app/data/storage.sqlite
-- 任何"另开一个日志文件"的实 现 均判不合格 (那正是上一轮
-- "HF 不存日志"讨论要消灭的缺口).
-- 故此表 CREATE 在 storage.sqlite 内, 与 call_logs/context_recommendations/
-- key_value 同库, 自然乘 Litestream → R2 既有通道, 零新增组件.

-- ── 应用方式(非本补丁执行, R3 接入窗) ──────────────────────
-- init 启动时 sqlite3 "$DB_PATH" < events_schema.sql
-- (CREATE TABLE IF NOT EXISTS 幂等, 多次跑无副作用)

CREATE TABLE IF NOT EXISTS events (
  id          INTEGER PRIMARY KEY AUTOINCREMENT,        -- 自增, 顺序即时序
  ts          TEXT    NOT NULL,                          -- ISO8601 UTC, 如 2026-07-22T03:16:00Z
  event_type  TEXT    NOT NULL,                          -- 见下方枚举约束
  payload     TEXT    NOT NULL DEFAULT '{}'              -- JSON 串(sqlite3 json_quote 或手拼)
);

-- event_type 枚举(应用层校验, 配套写入函数 enforce_event_type)
--   boot_banner     — entrypoint boot 启动签名 (PORT/EXPOSED/DATA)
--   upsert_result   — init combo upsert 结果 (PUT/POST HTTP code)
--   cb_trip         — Circuit Breaker 跳闸 (v2 §6 金丝雀记录三类之一)
--   fallback_enter  — Account Fallback 进入罚态 (三类之二)
--   fallback_exit   — Account Fallback 退出罚态 (三类之二对偶)
--   queue_drop      — 队列丢弃 (三类之三)

-- ── 索引: 按时序扫表常用(ts 倒序), event_type 过滤常用 ──
CREATE INDEX IF NOT EXISTS idx_events_ts         ON events (ts);
CREATE INDEX IF NOT EXISTS idx_events_event_type ON events (event_type);

-- ── 列风格对齐现役 ──────────────────────────────────────
-- 现役 context_recommendations: TEXT PRIMARY KEY + INTEGER DEFAULT + TEXT DEFAULT 'insufficient'
-- 本表同风格: TEXT NOT NULL + TEXT DEFAULT '{}', 但 id 用 INTEGER AUTOINCREMENT
--   (事件无天然业务键, 自增序即够; context_recommendations 有 model_id 业务键故 TEXT PK)
--   选择依据: events 是 append-only 时序流, 不需按业务键去重.
```

---

## 附录 A2 — r4 改名批阻断核验档(推前留文, 首席 verdict 前置项)

> r4 改名批 verdict 后首席令核两阻断级 + package.json 归属 + 三流程级。本轮(Date 2026-07-23 ~01:20Z, 距解冻窗满 03:16Z 约 2h)全部核验, 落档"审的=要部署的"底线。

### A2.1 阻断级 A — HF 新仓 omni_data/ stray 目录排查(解除)

**方法**: `hf download nonoke/omn-logic --repo-type dataset --revision main`(本机缓存 token 只读 GET, 不写, 不碰生产仓 nomke/omn)拉新仓全树 → 列根目录。

**结果**: 新仓根 = 8 文件 **flat 树**(根路径 flatten, 无快照子目录):
- `entrypoint.sh` / `gate.js` / `init-nim-keys.sh`(860L/51KB/`cea2b20eac05`) / `init-nim-keys.r2-157.bak`(9KB r2-157 备份) / `litestream.yml` / `package.json` / `README.md` / `.gitattributes`

**核验点**: 根目录**无 `omni_data/` 也无 `omn_data/`** → 首席担心"旧 init restart 时已向新仓写过 omni_data/ stray 目录" **未发生**。阻断级 A **解除**, 附录 A 无 stray 删/合并动作, 仅记录"核过新仓根无 omni_data/, 推 r4 不产生目录分裂"。

**附加**: 新仓 init = `cea2b20eac05` 860L/51KB **旧版未改名**(含 `HF_DATASET_REPO` 行714 guard / `omni_data` 行800 path_in_repo / `/tmp/omni-snapshot` 行800 / `Sync omni_data` 行802) → 推 r4 等于全量替换 init(860L→995L, +135L 含 r2 论态 A/B/C/D + r3 M7/查证 + r4 改名), 非 delta。K3 verdict 回填后走附录 A 激活推。

### A2.2 阻断级 B — 全仓 `omni-logic` 字面仓名 grep(解除)

**方法**: `grep -rn "omni-logic"` 跨 staging/现役冻结 + upstream 双树(只读本体源码) + staging 全件清单。

**结果**:
- `candidate-v4.3.2-staging/` **零命中** ✓ (改名后实件干净)
- `upstream/omniroute-3.8.43/` + `upstream/omniroute-3.8.49/` **零命中** ✓ (OmniRoute 本体源码无 `omni-logic` 字面仓名硬编码)
- `candidate-v4.3-reviewed/`(现役冻结) **零命中** ✓ (init 外无字面仓名)

**结论**: `omni-logic` 字面仓名**仅 init 内 env 键引用点**: `LOGIC_BUCKET_REPO`=远端仓名(bootstrap 拉逻辑层用, 未改) + `HF_DATASET_REPO`→`OMN_DATASET_REPO`(init 写 omn_data 快照, r4 已改名)。无运行时别处硬编码往旧仓名写。阻断级 B **解除**, r4 init 四行改名是仓库坐标**唯一**引用点, 改顶用。audit/ + docs/ 历史 `omni-logic` 字面量属文档记录(冻结前真源不改)非运行时。

### A2.3 目录歧义澄清 — staging 未删, 无 omn-logic/ 本地目录

**核**: `candidate-v4.3.2-staging/` 本地**仍存在未删**, init = `4cbcc50120ec`(r4 实件, 995L/61KB)。本地**无 `omn-logic/` 目录**。

**澄清**: 首席 verdict 称"staging 已删, 实件在 omn-logic/" — 此处 `omn-logic` 指 **HF 远端新仓名 `nonoke/omn-logic`**(LOGIC_BUCKET_REPO 指向, 见 A2.1 树), 非本地目录。staging 仍是本地唯一现役工作目录, 口径正确无需造 `omn-logic/` 本地目录, 后续推送提示词/README 沿用 staging 路径不歧义。

### A2.4 Step0.3 — package.json 归属(现役部署件保留新仓根)

**核**: 新仓 `nonoke/omn-logic/package.json` **存在** = gate 描述件:
```json
{"name":"gate","version":"2.0.0","private":true,"description":"零依赖(仅 http/crypto) gate: PSK(INTERNAL_PSK for /v1/*) 双通道 + 后台 fail-closed(GATE_ADMIN_TOKEN via Basic Auth) + 令牌桶限流, 前置于上游服务 (HF Space :7860 -> :20128)","main":"gate.js","engines":{"node":">=22.0.0"},"scripts":{"start":"node gate.js"},"dependencies":{}}
```
**归属**: 现役部署件保留新仓根(入镜像)。本次 staging 工作未带 package.json(staging 无此件), 推 r4 四件时**不覆盖新仓 package.json**(远端已留, 推送 init/entrypoint/gate/litestream 四件即可), 避免误删 gate 描述件致镜像 build 缺 main。

### A2.5 推送前剩余闭环(首席侧联网两项)

- **E 项 Space Secrets**: 设 `OMN_DATASET_REPO = nonoke/omn-logic`(配 r4 init 行849 guard) + 确认 HF_TOKEN 有值。否则 init guard `[$OMN_DATASET_REPO]` 空 → 静默 return 0, omn_data 快照上传链踏空(同旧 HF_DATASET_REPO 踏空根因)。运维配置非代码, 首席侧设。
- **Space 健康**: `https://nonoke-omn.hf.space` 是否 RUNNING → 判新仓旧 init 拉起状态(正常=新仓内容可用, 异常=查日志)。

---



> Zen 令: events_schema.sql 覆盖表契约; events_write.sh 逻辑薄但 SQL 拼接安全性可审, 故放附录.
> 源: `patches/p0/events-table/events_write.sh` (零改).

```bash
#!/usr/bin/env bash
# ============================================================
# p0-events-table — 事件写入函数库 (source 进 init/entrypoint 用)
# ============================================================
# 职责: 把一行 events INSERT 进 storage.sqlite (Litestream 正在复制那个库).
# 红线: 零新增持久通道 — 只写 $DB_PATH, 禁另开任何日志文件.
# 非接入: R3 宣判前不 source 进现役脚本, 仅定义待用.

# 前置: 调用方须已设 DB_PATH(= $DATA_DIR/storage.sqlite, 见 entrypoint-merged.sh:17)
# env 占位: 不硬编码库路径, 走注入, 防"另一库"漂移上线.

# ── 枚举校验(应用层兜 schema 无 CHECK 的洞) ──
# 理由: sqlite3 CLI 不便给 CHECK 约束 + 中文错误, 应用层先拦更清.
_EVENTS_VALID_TYPES="boot_banner upsert_result cb_trip fallback_enter fallback_exit queue_drop"

# 内部: event_type 是否在枚举内
_events_valid_type() {
  local _t="$1"
  for _v in $_EVENTS_VALID_TYPES; do
    [ "$_t" = "$_v" ] && return 0
  done
  return 1
}

# 内部: JSON 串转义 (最小集: " \ 换行 回车)
# 注: sqlite3 参数化 INSERT 在 CLI 拼串不便, 用 json 转义 + 单引号包裹.
#   payload已是JSON串, 勿二次转义; 调用方传已合法 JSON.
_events_json_escape() {
  # 仅转双引号及反斜杠, 保证 shell 单引号包裹后入库 payload 仍合法 JSON
  local _s="$1"
  _s="${_s//\\/\\\\}"      # \ → \\
  _s="${_s//\"/\\\"}"      # " → \"
  printf '%s' "$_s"
}

# 内部: shell 单引号转义 (防 payload 含单引号截断/注入)
_events_sq_escape() {
  local _s="$1"
  printf '%s' "${_s//\'/\'\'}"
}

# ── 公开: 写一行 event ─────────────────────────────────
# 用法: write_event "boot_banner" '{"port":20128,"exposed":7860}'
# 返回: 0 成功, 非0 失败(DB缺失/type非法/写入错) — fail-open 不中断调用方逻辑
#       (事件入库是观测面, 不应反过来把业务请求拖崩; 与 v2 异常即停并行不冲突:
#        异常即停指"命中与推断冲突信号"停手报回, 非每条事件错都停)
write_event() {
  local _type="$1"
  local _payload="${2:-{}}"

  # 守门1: DB_PATH 必须设且文件在
  if [ -z "${DB_PATH:-}" ] || [ ! -f "$DB_PATH" ]; then
    echo "[events] WARN: DB_PATH 未就绪, 跳过 event 入库 (type=$_type)" >&2
    return 1
  fi
  # 守门2: sqlite3 CLI 可用 (bootstrap 已装)
  if ! command -v sqlite3 >/dev/null 2>&1; then
    echo "[events] WARN: sqlite3 不可用, 跳过 event 入库 (type=$_type)" >&2
    return 1
  fi
  # 守门3: event_type 枚举校验
  if ! _events_valid_type "$_type"; then
    echo "[events] WARN: 非法 event_type '$_type' (合法: $_EVENTS_VALID_TYPES), 拒写" >&2
    return 1
  fi

  local _ts
  _ts="$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)"
  [ -z "$_ts" ] && _ts="1970-01-01T00:00:00Z"  # date 失败兜底, 不留空列

  local _p_esc
  _p_esc="$(_events_sq_escape "$(_events_json_escape "$_payload")")"

  # 写入: events 表 (schema 见 events_schema.sql, IF NOT EXISTS 幂等建表以防漏建)
  sqlite3 "$DB_PATH" "
    CREATE TABLE IF NOT EXISTS events (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      ts TEXT NOT NULL, event_type TEXT NOT NULL, payload TEXT NOT NULL DEFAULT '{}'
    );
    INSERT INTO events (ts, event_type, payload) VALUES ('$_ts', '$_type', '$_p_esc');
  " 2>/dev/null || { echo "[events] WARN: INSERT 失败 (type=$_type)" >&2; return 1; }

  return 0
}
```

---

## 附录 B — v4.3.2 变更清单 (M1-M7 各一行, 注锚点)

| 标记 | 改造 | 锚点 | 裁断依据 |
|---|---|---|---|
| **M1** | 限流随存活 key 数动态推导(替换 v4.3.1 固定档 28/3/2200) | init 行161-171 主算 + 行623-629 probe 后重算 | 三式逐字 baseline-4.2.3 行134-140: `_RPM=alive*per_key cap 300` / `_CONCURRENT=alive*per_key_conc floor 3` / `_MIN_INTERVAL=60000/_RPM`. 驱逐 NIM_FIXED_* 三个固定覆盖 env(故障原型). 行161-171 配置层预取全量; M3 probe 后行623-629 重算覆盖见 M3. |
| **M2** | maxWaitMs 四字段读回断言对齐(旧注"28/1/2200 三字段"残留清除) | init 行756-768 | 现状 maxWaitMs=300000 已落; M2 修注释+留 K3 题4. **r3 预检证** maxWaitMs 字段在上游 src/lib/resilience/settings.ts:47, normalize.ts:101 上限 max=24*60*60*1000(24h), M2 写 300000=5min 远在上限内不被 clamp; normalize.ts:311 max:30000 属 comboCooldownWait 短瞬态层非 requestQueue, M2 严格断言维持成立. |
| **M3** | probe_nim_keys_real 真探活(POST /v1/chat/completions) + auth_dead 跳注册 + **probe 后 alive 重算+策略对齐防 RPM 虚高(硬伤3+发现C)** + 单 key 策略对齐 round-robin | init 行567-638 Probe+重算 | 403判死/429判活/余活 fail-open; **probe 端点 POST 推理(硬伤2: GET /v1/models 测不出鉴权死)**; INDEX 递增编号不塌; **probe 后排除 auth_dead 重算 _ALIVE_KEYS 并重跑 M1 三式(硬伤3)+ alive≤1 连动 round-robin(发现C 复原单 key 设计意图)**; **r2注释改A(M3注释已定案非"不重算")**; baseline-4.2.3 无此件=全新增量. |
| **M4** | 压缩全局关闭 | init 行799-806 | PUT 体仅 `{"enabled":false}`; 不留 defaultMode/autoTriggerTokens(防"0阈值=全压"反向). |
| **M5** | 横幅版本对齐 | init 行5-8/870 | 顶注 v4.3.0→v4.3.2; jq `--arg version "4.3.2"`; **三 echo(行481/958/995)全 v4.3.2 修硬伤1**(M5 前漏改 echo). |
| **M6** | (跳过) | — | Zen 授权可选跳. |
| **M7** | 请求级超时 env 外科单注(r3 查证定版) | entrypoint 行24-35 | **r3 改**: `DEFAULT_REQUEST_TIMEOUT_MS` 经官方 Environment wiki §15 查证确认不在变量表内(env-doc-sync CI 失败即缺席)→ 删除该 env; 改外科单注 `STREAM_READINESS_TIMEOUT_MS=180000`(默 80000=80s 首非 ping SSE 事件时限 = 长思考首 token 静默真杀手, 122s 级思考正对此刀, 抬至 180s 不动其他预算). `REQUEST_TIMEOUT_MS` 是全局快捷键(同覆 FETCH_TIMEOUT_MS 600s + STREAM_IDLE_TIMEOUT_MS 600s, 注会降额=双面刃, 本场景无降额需求故不注). **gate.js 零 diff**(GATE_UPSTREAM_TIMEOUT_MS=30000 Node socket 不活跃超时, 解冻后走 env 调, 列 K3 题5). |

---

## 附录 C — 验收标准(启动日志七行核验表)

**9 key 预期** (Zen 验收签名):

| # | 日志签名 | 预期值 |
|---|---|---|
| 1 | `[init] 动态限流 RPM=... concurrent=... interval=...` | RPM=300 concurrent=27 interval=200ms (alive_keys=9, **probe 前全量**) |
| 2 | `[init] probe_nim_keys_real: 串行探活 NIM keys via POST /v1/chat/completions...` | 见逐 key 判读行 (**POST 推理端硬伤2**) |
| 3 | `[init] probe key#X: HTTP YYY → alive/AUTH_DEAD` | 9 行判读 (403 入 auth_dead, 余判活) |
| 4 | `[init] probe 汇总: alive=... dead=... (..., POST z-ai/glm-5.2)` | alive+dead=9 |
| 5 | `[init] nim-XX ...` | 死 key 见 `skip (probe AUTH_DEAD)`; 活 key 见 `OK/exists/HTTP` |
| 6 | `[init] Keys: ... registered, ... skipped, ... failed. (probe: ... alive / ... dead-skipped)` | registered+skipped+failed=9 |
| 7 | `[init] Compression globally disabled...` + `[init] Compression HTTP 200` | 全局关 + 200 |
| 8 | **probe 后 alive 重算(硬伤3)**: `[init] probe 后 alive 重算: 9 -> N (排除 M auth_dead 死 key)` + `[init] 动态限流 重算 RPM=... concurrent=... interval=...ms (alive_keys=N 重算后)` | N=9-M (auth_dead=0 时改走 elif 维持原值无此行); 重算后 RPM=N×35 cap300 / concurrent=N×3 floor3 / interval=60000/RPM; **N=1 时另见 probe 后策略对齐 → `[init] probe 后策略对齐: alive=1 <=1 -> pool strategy=round-robin`**(发现C 复原单 key 不用 p2c 设计意图) |
| 9 | **M7 外科单注(r3 查证定版)**: `[entrypoint] STREAM_READINESS_TIMEOUT_MS=180000 (M7 外科单注, wiki §15 实证)` | 180000 (默 80000 抬至 180000; entrypoint 启动即 echo 一次) |

**Resilience 读回**: `[init] Resilience 读回: RPM=... minMs=... concurrent=... maxWaitMs=300000` + `[init] ✓ Resilience 读回全字段一致 (.../.../.../300000 已落定)` — **auth_dead=0 时 = 300/27/200/300000; auth_dead>0 时 = 重算值(例 9 key 全死: 35/3/1714/300000 = alive=1 单 key 模式). 当前 nonoke 9/9 POST 403 现实下首次部署预期即重算值 + registered=0 — 此为探活正确工作(死 key 挡在池外), 非失败; 上游解封后普通 restart 即自动恢复, 无需改配置. 读回断言对的是"写入值==读回值", 非固定值=300/27/200.**

**candidate 未触铁证**(本稿生成前后核):

```
开工时间戳(r4 改名批收口): 2026-07-23 (r3 查证定稿 r4 改名批, 冻结令第 3 轮宣判窗内 2026-07-23 03:16Z 前)
冻结令起点: 2026-07-21 03:16Z
find candidate-v4.3-reviewed/ -newer 冻结令起点 -type f → 空 (整个冻结窗内 candidate 零写入, r3 收口再核仍空 rc=0)
candidate 7件 mtime 与开工前逐字一致:
  2026-07-20 23:13:37  init-nim-keys.sh
  2026-07-20 23:20:38  entrypoint-merged.sh
  2026-07-13 10:49:51  gate.js
  2026-07-19 17:47:43  litestream.yml
  2026-07-22 15:58:35  parseRetryAfter.ts
  2026-07-22 15:59:28  backoffAndDedup.ts
  2026-07-22 16:03:12  events_schema.sql
改动量精确(r4 改名批后): 仅 staging 的 init sha 变(r4: init 4cbcc50120ec 995L, 源 r3 e5a26a9c→r3+1 89f636b5 995L→r4 4cbcc50120ec 995L; entrypoint 06178176 263L 本轮零 diff 不变); gate/litestream/P0 三件零变动; 文档 5 文(4.3.2提示词/DEPLOYMENT_GUIDE/omn-bundle×2)同步改名非品牌 omni→omn + env 键 HF_DATASET_REPO→OMN_DATASET_REPO.
```

---

## 附录 D — 审阅结论页模板(K3 直接回填)

> 按文件留 verdict: `pass` / `pass-with-comment` / `block` + blockers 清单.

| 序 | 文件 | verdict | 备注/blocker |
|---|---|---|---|
| 1 | init-nim-keys.sh | **pass-with-comment** | M1 公式/M3 probe/M2 断言/重算段全跑通, boot 01:05 实证 6 alive/2 auth_dead 读回 RPM=210 minMs=285 concurrent=18 maxWaitMs=300000 四字段全一致九 POST 无 FATAL. comment: rar2 C2 fail-open(upload try/except+\|\|true)已叠入远端终态 21cc7cdb, 超 K3 原稿范畴属后续 saga 补强, 不阻 verdict. |
| 2 | entrypoint-merged.sh | **pass-with-comment** | litestream restore -config 修(R2 恢复成功 boot 01:05 实证)+ STREAM_READINESS 180s M7 单注落地. comment: 一期 B2 express 预装段(5.5 段 19 行 npm install --omit=dev)已叠入远端终态 4803e290, 治附录A crashloop regression, 超 K3 原稿范畴, 不阻 verdict. |
| 3 | gate.js | **pass** | 零 diff(K3 原稿定). 远程探活 /v1/models 无 PSK=401 unauthorized + /api=404(后台关) + listening 7860→20128 boot 01:05 实证 gate 真活 + 契约(X-Internal-PSK)在位. KNOWN(B2 头注 v4.3.1 残留)留解冻后修不阻. |
| 4 | litestream.yml | **pass** | restore -config 修在(见 [2/7] 注), R2 replicate bucket omn-data sync-interval 10s boot 01:05 实证 compaction complete 01:06:32 活跃无二次 boot=稳态. |
| 5 | parseRetryAfter.ts | **pass** | P0 Retry-After 硬遵守补丁(§7 速率三准则优先)落 staging 全绿, 机制符合上游 3.8.43 source. |
| 6 | backoffAndDedup.ts | **pass** | P0 退避+去重落 staging 全绿, 与 parseRetryAfter 配对, 无 Retry-After 退避合规. |
| 7 | events_schema.sql | **pass** | 事件入库骨架表契约落(附录定), SQL 仅 schema 不含拼接逻辑, 审安全无注入面. |
| A | events_write.sh | **pass-with-comment** | 逻辑薄 SQL 拼接可审(附录定放). comment: 现仅骨架未接生产数据流, 解冻后接通时复核注入面. |

**Blockers 清单**(K3 填):

- [x] **无 block 级阻断** — 七件 + 附录 A 全 pass/pass-with-comment, 无 block. 九 POST 实证 boot 01:05 远程 internet 真跑态铁证闭环.
- [x] **comment 项(非阻断, 解冻后追踪)**: (1) init amazon C2 fail-open(rar2)超原稿已落(2) entrypoint B2 express 预装段(一期)超原稿已落(3) gate.js 头注 v4.3.1 残留 KNOWN 留解冻后修(4) events_write.sh 接生产流时复核注入面.

---

## 给 K3 的审阅问题清单(十题, K3 逐条 yes/no + 一句理由)

> **K3 verdict 回填(2026-07-23 ~01:2xZ)** — 判据源 = saga 闭环 boot 01:05-01:06 远程 internet 真跑态铁证(gate 真活/init 真写入/Resilience 读回四字段一致) + 合并稿 r3 fenced hash/staging 验证全绿基线。

1. **yes**. 9 key 场景 `_RPM=9×35=315→cap300` / `_CONCURRENT=9×3=27 保底3` / `_MIN_INTERVAL=60000/300=200ms` 推导对; 但 boot 01:05 实证 6 alive/2 auth_dead(死 key 排除后 alive=6), 读回 `RPM=210=6×35` / `concurrent=18=6×3` / `maxWaitMs=300000` — 死 key 被硬伤3重算段正确刨除, 非幽灵全量值, clamp(300/3)边界一致成立.
2. **yes**. POST /v1/chat/completions(max_tokens=1, z-ai/glm-5.2)探活语义正: GET /v1/models 200 无法测 POST 鉴权死(2026-07-21 事件签名 GET200/POST403 已实证), 用 POST 才能真正分类 403判死. 串行 15s×25key 最坏 375s 启动耗时容许(boot 非关键路径, 延迟 init 不阻 gate 监听, entrypoint 监督判 init 非致命). fail-open(其余判活)由运行时熔断兜底.
3. **yes**. 注册循环 auth_dead 跳过时 INDEX 递增不塌, nim-XX 缺口=死 key 位置可定位 — boot 01:05 日志注册 nim-01/02/05/06/07/08 六 alive, 缺口 nim-03/04=auth_dead(403账户级死)两缺口编号清楚.
4. **yes, 严格断言维持成立**. r3 预检全证: maxWaitMs 在 settings.ts:47(DEFAULT) + normalize.ts:101 上限 24h(24×60×60×1000), M2 写 300000(5min)远在上限内不被 clamp; normalize.ts:311 max:30000 属 comboCooldownWait 短瞬态层非 requestQueue 不影响. boot 01:05 读回 maxWaitMs=300000 四字段全字段一致无 FATAL 实证.
5. **yes**. (i) 外科单注够: STREAM_READINESS_TIMEOUT_MS=180000 覆盖首非 ping SSE 事件时限(默80s 首token静默真杀手, 122s 级思考正对此刀), gate GATE_UPSTREAM_TIMEOUT_MS=30000=Node socket 不活跃超时(流式有数据即重置)不冲突. (ii) 批准解冻后设 GATE_UPSTREAM_TIMEOUT_MS=180000 走 env 双轴对齐180s不调代码.
6. **yes, 取舍成立**. litestream sync-interval 10s/Space HEALTHCHECK start-period 180s 无联动调需(STREAM_READINESS 180s 在窗内). REQUEST_TIMEOUT_MS 全局快捷键(降额双面刃)不注正确, 避 FETCH/IDLE 600s 降额无降额需求.
7. **yes**. mapfile/here-string/`< <(...)` 进程替换全 bash 4+ 可用; 镜像 GHCR base + bootstrap 运行 bash 5.x(buster/bookworm 默认), boot 01:05 init rc=0 无 bash 语法崩实证.
8. **yes**. 压缩全局 enabled:false 后 defaultMode/autoTriggerTokens 库内惰性留存, per-combo 再启用路径不受影响(独立 path 不读全局开关兜底).
9. **yes**. _ALIVE_KEYS 行147 配置层预取全量 + 行611-633 probe 后重算排除 auth_dead, probe 行609 早于注册循环 行635, 顺序无冲突. 硬伤3 重算段正确(排除死 key 防幽灵配额虚高, 9 key 全死降级 alive=1 单 key 模式 RPM=35/conc=3 比假象健康) — 保守虚高无理由保留, 重算为正确做法确认.
10. **yes**. fail-open(仅403判死)符合可用性边界预期: boot 时上游 5xx 抖动场景下 fail-closed 会放大一次抖动成全停(全判死致 Space 无活 key 崩), fail-open 由运行时熔断兜底瞬态更稳健; 403 账户级死(非抖动)正常判死. boot 01:05 实证 2 auth_dead(403)判死 + 6 alive fail-open 正确分类, 无误杀活 key 无漏死 key.

---

*文档终. cg52 v2 生成于 2026-07-22 冻结令窗口内, staging 路线. 7 件全文逐字嵌入(脚本 cat 读出, 非手抄, 防字节错配).*
