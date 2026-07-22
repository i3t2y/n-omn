#!/usr/bin/env bash
# 组装 omn-v4.3.2-k3-review-20260722.md 的七段正文 (全文 fenced code block 逐字嵌入).
# 纪律: 逐字读 staging 文件, 不打字重抄, 防字节错配. 头部已写好(框架), 本脚本 append 七段 + 附录.
set -eo pipefail
cd ~/omn-merge/candidate-v4.3.2-staging
OUT=~/omn-merge/omn-v4.3.2-k3-review-20260722.md

N=0
bash -n init-nim-keys.sh && echo "[phase2] init 语法校OK" || { echo "init 语法失败, 终止"; exit 1; }
bash -n entrypoint-merged.sh && echo "[phase2] entrypoint 语法校OK" || { echo "entrypoint 语法失败, 终止"; exit 1; }
node --check gate.js && echo "[phase2] gate 语法校OK" || { echo "gate 语法失败, 终止"; exit 1; }

emit() {
  # emit <序> <文件> <语言> <变更点注记行(可空)>
  local idx="$1" f="$2" lang="$3" note="${4:-}"
  N=$((N+1))
  local sha ln
  sha=$(sha256sum "$f" | cut -d' ' -f1)
  ln=$(wc -l < "$f")
  {
    echo ""
    echo "## [${N}/7] ${f}"
    echo ""
    echo "**路径**: \`candidate-v4.3.2-staging/${f}\`  **行数**: ${ln}L  **sha256**: \`${sha}\`"
    [ -n "$note" ] && { echo ""; echo "**变更点**: ${note}"; }
    echo ""
    echo "\`\`\`${lang}"
    cat "$f"
    echo "\`\`\`"
  } >> "$OUT"
}

emit 1 init-nim-keys.sh bash "M1 行148-171 动态限流三式(逐字 baseline-4.2.3) / M2 行636-662 maxWait 四字段读回断言 / M3 行538-623 probe_nim_keys_real+auth_dead 跳注册 / M4 行688-694 压缩 enabled:false / M5 行5-8 顶注+行829 jq version v4.3.2"

emit 2 entrypoint-merged.sh bash "M7 行24-40 超时 env 注入 (DEFAULT_REQUEST_TIMEOUT_MS + REQUEST_TIMEOUT_MS 双注保守, gate 代码零 diff)"

emit 3 gate.js javascript "零改(现役). K3 审: GATE_UPSTREAM_TIMEOUT_MS 行30 默30000(30s) 语义+生效值(详见 K3 题5)."

emit 4 litestream.yml yaml "零改(现役). bucket omn-data, sync-interval 10s, auto-recover false, l0-retention 5m."

emit 5 parseRetryAfter.ts typescript "零改(P0弹药). Retry-After 两格式解析(秒数 + HTTP-date), NaN→null, 已过→0. mock 10/10."

emit 6 backoffAndDedup.ts typescript "零改(P0弹药). 指数退避+确定性伪抖动+DedupStore 去重接口. mock 10/10."

emit 7 events_schema.sql sql "零改(P0弹药). events 表四列(id/ts/event_type/payload)+两索引. 零新增持久通道(乘 Litestream). mock 13/13."

echo ""
echo "[phase2] 7段正文已 append, 因 $N=7"
echo "[phase2] 当前 OUT 行数: $(wc -l < "$OUT")"