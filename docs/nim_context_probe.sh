#!/bin/bash
# ─────────────────────────────────────────────────────────────
# nim_context_probe.sh —— NIM 真实上下文截断点实测（直连，绕过 gate）
# 目的：用事实定位每个模型返回"空流/504/报错"的首个 token 档位，
#       据此重新标定 real_context，而非沿用历史经验值 32K。
#
# 用法：
#   export NIM_KEY="nvapi-xxxx"                 # 单个 key 即可（探测量极小）
#   ./nim_context_probe.sh                      # 默认档位 16k~128k
#   STEPS="32000 48000 64000 96000" ./nim_context_probe.sh  # 自定义档位
#
# 风控说明：
#   - 每个 (模型 × 档位) 只发 1 次，档位间 sleep（默认 8s），远低于 40 RPM。
#   - max_tokens=16 输出极小，主要测"输入能否被吞下"，不烧额度。
#   - 命中截断点后自动跳过该模型更高档位（early-stop），进一步省请求。
# ─────────────────────────────────────────────────────────────
set -uo pipefail
NIM_KEY="${NIM_KEY:?需要 export NIM_KEY=nvapi-...}"
BASE="https://integrate.api.nvidia.com"
SLEEP_BETWEEN="${SLEEP_BETWEEN:-8}"     # 档位间隔（秒），控频防 429
MAX_OUT="${MAX_OUT:-16}"                # 输出 token，尽量小
TIMEOUT="${TIMEOUT:-90}"                # 单请求超时（秒）
# 待测模型（按需增删；用裸 vendor/model，不带 nvidia/ 前缀）
MODELS=(
  "z-ai/glm-5.2"
  "deepseek-ai/deepseek-v4-pro"
  "deepseek-ai/deepseek-v4-flash"
  "meta/llama-3.3-70b-instruct"
  "openai/gpt-oss-120b"
  "qwen/qwen3.5-397b-a17b"
)
# 递增档位（目标输入 token 数）。默认覆盖 16k~128k。
STEPS="${STEPS:-16000 32000 48000 64000 96000 128000}"
# ── 生成约 N 个 token 的填充文本 ─────────────────────────────
# 经验：英文约 0.75 词/token；用重复短语，1 token≈1 词更接近。
# 为求稳，用 "data " 重复 N 次（偏保守，实际 token 略少于 N，够用来找拐点）。
_make_prompt() {
  local target=$1
  # 每个 "data " 约 1~2 token，用 awk 快速拼接 target 个
  awk -v n="$target" 'BEGIN{ s=""; for(i=0;i<n;i++) s=s "data "; print s }'
}
# ── 用官方 count_tokens 精确回读真实 token 数（可选，失败不阻断）──
# 修复：大文本通过 stdin 传入 jq（-Rs 读为原始字符串 .），
#       JSON 体写入临时文件，curl 用 -d @file 读取，避免 ARG_MAX。
_count_tokens() {
  local model="$1" text="$2" resp tmpf
  tmpf=$(mktemp)
  printf '%s' "$text" | jq -Rs --arg m "$model" \
    '{model:$m, messages:[{role:"user",content:.}]}' > "$tmpf" 2>/dev/null
  resp=$(curl -s --max-time 20 "$BASE/v1/messages/count_tokens" \
    -H "Authorization: Bearer $NIM_KEY" -H "Content-Type: application/json" \
    -d @"$tmpf" 2>/dev/null)
  rm -f "$tmpf"
  printf '%s' "$resp" | jq -r '.input_tokens // .inputTokens // "?"' 2>/dev/null || echo "?"
}
# ── 单次探测：返回 "HTTP|真实token|是否有内容|耗时ms" ──────────
# 修复：同 _count_tokens，stdin 传文本、临时文件存 JSON、curl -d @file。
_probe_once() {
  local model="$1" target="$2" text real body code t0 t1 dt content_len tmpf
  text="$(_make_prompt "$target")"
  real="$(_count_tokens "$model" "$text")"
  tmpf=$(mktemp)
  printf '%s' "$text" | jq -Rs --arg m "$model" --argjson mx "$MAX_OUT" \
    '{model:$m, max_tokens:$mx, stream:false,
      messages:[{role:"user",content:.}]}' > "$tmpf" 2>/dev/null
  t0=$(date +%s%3N)
  body=$(curl -s --max-time "$TIMEOUT" -w $'\n%{http_code}' \
    "$BASE/v1/chat/completions" \
    -H "Authorization: Bearer $NIM_KEY" -H "Content-Type: application/json" \
    -d @"$tmpf" 2>/dev/null)
  t1=$(date +%s%3N); dt=$((t1 - t0))
  rm -f "$tmpf"
  code=$(printf '%s' "$body" | tail -n1)
  body=$(printf '%s' "$body" | sed '$d')
  # 判定是否真的出了字
  content_len=$(printf '%s' "$body" \
    | jq -r '.choices[0].message.content // "" | length' 2>/dev/null || echo 0)
  echo "${code}|${real}|${content_len}|${dt}"
}
# ── 主循环 ────────────────────────────────────────────────────
echo "═══════════════════════════════════════════════════════════════"
echo " NIM 上下文截断实测  |  $(date '+%Y-%m-%d %H:%M:%S')"
echo " 档位: $STEPS"
echo " 间隔: ${SLEEP_BETWEEN}s  超时: ${TIMEOUT}s  max_tokens: $MAX_OUT"
echo "═══════════════════════════════════════════════════════════════"
printf "%-38s %-9s %-6s %-8s %-7s %s\n" "MODEL" "TARGET" "HTTP" "TOKENS" "OUTLEN" "TIME/结论"
echo "───────────────────────────────────────────────────────────────"
RESULT_FILE="/tmp/nim_probe_result_$(date +%H%M%S).tsv"
echo -e "model\ttarget\thttp\treal_tokens\tout_len\tms\tverdict" > "$RESULT_FILE"
for m in "${MODELS[@]}"; do
  cutoff="未命中(全档通过)"
  for step in $STEPS; do
    r=$(_probe_once "$m" "$step")
    code="${r%%|*}"; rest="${r#*|}"
    real="${rest%%|*}"; rest="${rest#*|}"
    outlen="${rest%%|*}"; dt="${rest##*|}"
    # 判定
    verdict="ok"
    if [ "$code" = "200" ] && [ "${outlen:-0}" -gt 0 ] 2>/dev/null; then
      verdict="✅出字"
    elif [ "$code" = "200" ] && [ "${outlen:-0}" -eq 0 ] 2>/dev/null; then
      verdict="⚠️空流(截断)"
    elif [ "$code" = "504" ] || [ "$code" = "502" ]; then
      verdict="🔴${code}超时"
    elif [ "$code" = "400" ]; then
      verdict="🟠400超限(显式拒绝)"
    elif [ "$code" = "429" ]; then
      verdict="⏳429限频(建议加大SLEEP)"
    else
      verdict="❓HTTP${code}"
    fi
    printf "%-38s %-9s %-6s %-8s %-7s %sms %s\n" \
      "$m" "$step" "$code" "$real" "$outlen" "$dt" "$verdict"
    echo -e "${m}\t${step}\t${code}\t${real}\t${outlen}\t${dt}\t${verdict}" >> "$RESULT_FILE"
    # early-stop：一旦出现空流/超时/超限，记录拐点并跳过该模型更高档位
    if [ "$verdict" != "✅出字" ]; then
      cutoff="首个异常档位 target≈${step} (real≈${real}, ${verdict})"
      break
    fi
    sleep "$SLEEP_BETWEEN"
  done
  echo "  └─ [$m] 结论：$cutoff"
  echo "───────────────────────────────────────────────────────────────"
  sleep "$SLEEP_BETWEEN"
done
echo "明细已存：$RESULT_FILE"
echo "建议：real_context 取 [最后一个 ✅出字 档位的 real_tokens] × 0.9 作安全值。"
