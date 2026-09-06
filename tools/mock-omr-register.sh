#!/usr/bin/env bash
# 隔离 mock 测试: _register_multi_provider 分支逻辑 (2026-08-31 Zen令 openrouter/mistral 纳入内置轨)
# 用法: bash tools/mock-omr-register.sh
# 断言:
#   1) nvidia 被 skip (无 provider=nvidia 连接 POST)
#   2) openrouter: 连接 provider=openrouter (短名非 UUID), 无 node POST, 动态枚举跑, combo openrouter-pool
#   3) mistral:   连接 provider=mistral, 无 node POST, 静态白名单 5 模型不枚举上游, combo mistral-pool
#   4) amd:       走 node 分支 (有 name=amd-node POST), 连接 provider= 空 (mock node 无 id)
#   5) dp4f:      收集含 sensenova/deepseek-v4-flash, 不含 openrouter/ (2026-08-28 Zen令排除)
#   6) cleanup:   5 家旧节点清理调用 (sensenova/nvidia/openrouter/mistral/google)
#   7) gemini:    连接 provider=gemini, 无 node POST, 静态白名单 7 模型不枚举上游, combo gemini-pool
# 说明: 只测循环控制流, 内部 helper 全 mock (helper 本身已 boot 验证). 从 init-nim-keys.sh 原样提取函数定义。
set -u
SRC=/home/laisi/omn-merge/dev/logic/init-nim-keys.sh

# ── 顶层变量 (与 init-nim-keys.sh 一致) ──
LOG_DIR=/tmp/mock-omr
rm -rf "$LOG_DIR"; mkdir -p "$LOG_DIR"
COOKIE_FILE="$LOG_DIR/cookie.txt"; touch "$COOKIE_FILE"
BASE_URL=http://127.0.0.1:20128
declare -a PROVIDERS=(
  "nvidia|nvidia-node|nvidia|https://integrate.api.nvidia.com|NIM_KEYS|20|"
  "openrouter|openrouter-node|openrouter|https://openrouter.ai/api/v1|OPENROUTER_KEYS|100||builtin|"
  "sensenova|sensenova-node|sensenova|https://token.sensenova.cn/v1|SENSENOVA_KEYS|20||builtin|sensenova-6.7-flash-lite deepseek-v4-flash glm-5.2"
  "mistral|mistral-node|mistral|https://api.mistral.ai/v1|MISTRAL_KEYS|20||builtin|mistral-large-latest mistral-medium-3-5 mistral-small-latest devstral-latest codestral-latest"
  "gemini|gemini-node|gemini|https://generativelanguage.googleapis.com/v1beta/models|GEMINI_KEYS|20||builtin|gemini-3.7-flash gemini-3.1-pro-preview gemini-3.1-flash-lite gemini-3-flash-preview gemini-2.5-pro gemini-2.5-flash gemini-2.5-flash-lite"
  "amd|amd-node|amd|https://developer.amd.com.cn/radeon/api/v1|AMD_KEYS|20|"
)
# 合成 keys (§2 Secrets 纪律: 测试用合成串, $'...' 保证真换行 = 多 key)
NIM_KEYS=$'nvisyn0001\nnvisyn0002'
OPENROUTER_KEYS=$'orsyn0001\norsyn0002'
SENSENOVA_KEYS=$'sssyn0001'
MISTRAL_KEYS=$'misyyn0001'
GEMINI_KEYS=$'gmsyn0001'
AMD_KEYS=$'amdsyn0001'
_VALID_STRATS="fill-first round-robin random priority weighted p2c least-used cost-optimized reset-aware reset-window headroom strict-random auto lkgp context-optimized cache-optimized context-relay fusion pipeline"
_POOL_STRATEGY="p2c"
_DPV4_ENTRIES=()

# ── mock 依赖 (helper 真定义被替换为记录型) ──
_resp() { echo "$LOG_DIR/$1"; }
_is_valid_strat() { printf '%s' "$_VALID_STRATS" | grep -qw -- "$1"; }
_is_auth_dead() { return 1; }   # 不模拟 probe 死 key
CALLS="$LOG_DIR/calls.txt"; : > "$CALLS"
# mock curl: 记录调用 (apiKey 脱敏) + 按 URL 返回预设 JSON/http_code
#   有 -o → 写文件; 有 -w → stdout 出 http_code; 无 -o 无 -w → stdout 出 JSON (动态枚举 L1438)
curl() {
  local url="" out="" has_w=0 has_o=0
  local -a args=("$@")
  for ((i=0;i<${#args[@]};i++)); do
    case "${args[$i]}" in
      http://*|https://*) url="${args[$i]}";;
      -o) has_o=1; out="${args[$((i+1))]}";;
      -w) has_w=1;;
    esac
  done
  echo "curl ${args[*]}" | sed 's/"apiKey":"[^"]*"/"apiKey":"REDACTED"/g; s/Authorization: Bearer [^ ]*/Authorization: Bearer REDACTED/g' >> "$CALLS"
  local code=200 json='{}'
  case "$url" in
    *"/api/providers"*)     code=201; json='{"ok":true}';;
    *"/api/provider-models"*) code=201; json='{}';;
    *"/api/provider-nodes"*) code=200; json='{}';;
    *"/v1/models"*|*"/api/v1/models"*) json='{"data":[{"id":"deepseek-v4-flash"},{"id":"openrouter/grok-3"},{"id":"mistral-embed"}]}';;
    *) code=200; json='{}';;
  esac
  if [ "$has_o" = 1 ] && [ "$out" != "/dev/null" ]; then printf '%s' "$json" > "$out"; fi
  if [ "$has_w" = 1 ]; then printf '%s' "$code"; return 0; fi
  if [ "$has_o" = 0 ]; then printf '%s' "$json"; fi
  return 0
}
# mock 空实现: 这些 helper 已 boot 验证, 循环测试只关心调用序列
upsert_combo() { echo "MOCK upsert_combo name=$1 strat=$2 prefix=$3 models=${*:4}" >> "$CALLS"; }
filter_alive() { printf '%s\n' "$@"; }
upsert_dp4f_pool() { echo "MOCK upsert_dp4f_pool entries=${_DPV4_ENTRIES[*]:-}" >> "$CALLS"; }
_cleanup_legacy_node() { echo "MOCK cleanup node=$1 label=$2" >> "$CALLS"; }
_cleanup_sensenova_double_prefix() { echo "MOCK cleanup sensenova double-prefix" >> "$CALLS"; }

# ── 提取 _register_multi_provider 完整函数定义 (原样, 大括号计数到匹配外层) → source 后调用 ──
awk 'BEGIN{d=0;started=0}
  /^_register_multi_provider\(\) \{/{started=1; d=1; print; next}
  started && d>0 {
    n=gsub(/\{/,"{"); m=gsub(/\}/,"}");
    d += n - m; print
  }' "$SRC" > "$LOG_DIR/regfn.sh"
# 确认提取完整 (末行应为函数尾 '}')
tail -1 "$LOG_DIR/regfn.sh" | grep -q '^}' || { echo "FAIL: 函数体提取不完整"; exit 1; }
. "$LOG_DIR/regfn.sh"
# 捕获函数真实 stdout (boot 会看到的 [init] 签名) 供断言
OUT=$(_register_multi_provider 2>&1)

# ── 断言: 基于函数 stdout ([init] 日志) + 单行 MOCK 记录 (helper 已 boot 验证) ──
#   curl/jq 美化 JSON 跨行, 逐行 grep JSON 不可靠 → 用函数日志断言行为, MOCK 行断言调用序列.
fail=0
chk_out() { local desc="$1" pat="$2" want="$3"
  local got; got=$(printf '%s\n' "$OUT" | grep -c -- "$pat")
  if [ "$got" = "$want" ]; then echo "PASS: $desc ($got/$want)"; else echo "FAIL: $desc 期望 $want 实得 $got"; fail=1; fi; }
chk_calls() { local desc="$1" pat="$2" want="$3"
  local got; got=$(grep -c -- "$pat" "$CALLS")
  if [ "$got" = "$want" ]; then echo "PASS: $desc ($got/$want)"; else echo "FAIL: $desc 期望 $want 实得 $got"; fail=1; fi; }

# 1) nvidia skip (legacy 内置轨独占, 通用表不重复注册)
chk_out "nvidia skip (legacy 内置轨独占)" 'nvidia: legacy 内置轨独占' 1
# 2) openrouter: builtin 短名, 2 keys 连接, 动态枚举, 无 node 建立
chk_out "openrouter builtin 短名 (不建 node)" 'openrouter: builtin 模式, 不建 node, _nid=openrouter' 1
chk_out "openrouter 2 连接全 OK" 'openrouter/openrouter-0[12] OK' 2
chk_out "openrouter 动态枚举上游" 'openrouter: 枚举 2 个模型' 1
# 3) sensenova (既有 builtin, 回归确认)
chk_out "sensenova builtin 短名 (不建 node)" 'sensenova: builtin 模式, 不建 node, _nid=sensenova' 1
chk_out "sensenova 静态白名单 3 模型" 'sensenova: 静态白名单 3 个模型' 1
# 4) mistral: builtin 短名, 静态白名单 5 模型, 不枚举上游
chk_out "mistral builtin 短名 (不建 node)" 'mistral: builtin 模式, 不建 node, _nid=mistral' 1
chk_out "mistral 静态白名单 5 模型" 'mistral: 静态白名单 5 个模型' 1
chk_out "mistral 不枚举上游 (方案A)" 'mistral: 枚举' 0
# 4b) gemini: builtin 短名, 静态白名单 7 模型, 不枚举上游, 旧 google-node 清理
chk_out "gemini builtin 短名 (不建 node)" 'gemini: builtin 模式, 不建 node, _nid=gemini' 1
chk_out "gemini 静态白名单 7 模型" 'gemini: 静态白名单 7 个模型' 1
chk_out "gemini 不枚举上游 (方案A)" 'gemini: 枚举' 0
# 5) amd: 自定义轨 node 分支 (mode=node)
chk_out "amd 走 node 分支 (mode=node)" 'amd: 建节点+连接+枚举模型 (base=.*mode=node)' 1
chk_out "amd 建 node POST" 'amd: node POST 成功但无 id, WARN' 1
# 6) combo 池: 各 provider 短名前缀
chk_calls "openrouter-pool combo (prefix=openrouter)" 'MOCK upsert_combo name=openrouter-pool strat=p2c prefix=openrouter' 1
chk_calls "mistral-pool combo (prefix=mistral)" 'MOCK upsert_combo name=mistral-pool strat=p2c prefix=mistral' 1
chk_calls "sensenova-pool combo (prefix=sensenova)" 'MOCK upsert_combo name=sensenova-pool strat=p2c prefix=sensenova' 1
chk_calls "gemini-pool combo (prefix=gemini)" 'MOCK upsert_combo name=gemini-pool strat=p2c prefix=gemini' 1
chk_calls "amd-pool combo 建" 'MOCK upsert_combo name=amd-pool' 1
# 7) dp4f: 含 sensenova/deepseek-v4-flash, 不含 openrouter/ (2026-08-28 Zen令严格三提供商)
#    注意: 全文件含 openrouter/grok-3 模型名 (openrouter-pool 模型注册), 断言须限定 dp4f 行.
chk_calls "dp4f 池建 (upsert_dp4f_pool 调)" 'MOCK upsert_dp4f_pool entries=' 1
_dp4f_line=$(grep 'MOCK upsert_dp4f_pool' "$CALLS")
printf '%s\n' "$_dp4f_line" | grep -q 'sensenova/deepseek-v4-flash' && echo "PASS: dp4f 含 sensenova/deepseek-v4-flash" || { echo "FAIL: dp4f 缺 sensenova/deepseek-v4-flash"; fail=1; }
printf '%s\n' "$_dp4f_line" | grep -q 'openrouter/' && { echo "FAIL: dp4f 误含 openrouter/"; fail=1; } || echo "PASS: dp4f 排除 openrouter/ (2026-08-28 Zen令)"
# 8) cleanup: 5 家旧节点清理 + sensenova double-prefix
chk_calls "5 家旧节点 cleanup" 'MOCK cleanup node=' 5
chk_calls "sensenova double-prefix 清理" 'MOCK cleanup sensenova double-prefix' 1
# 9) 连接注册 provider 字段 = 内置短名 (JSON 独立行存在性确认, 非精确计数)
for p in openrouter sensenova mistral gemini; do
  grep -q "^  \"provider\": \"$p\"," "$CALLS" && echo "PASS: 连接 body provider=$p (短名, 非 UUID)" || { echo "FAIL: 连接 body 缺 provider=$p"; fail=1; }
done

echo "--- 调用序列 (apiKey 脱敏, 截断) ---"
grep -E 'MOCK|"provider"|name=amd-node|openrouter.ai/api/v1/models|mistral.*models|provider-models' "$CALLS" | head -40
[ "$fail" = "0" ] && { echo "=== ALL MOCK PASS ==="; exit 0; } || { echo "=== MOCK FAIL ==="; exit 1; }