#!/usr/bin/env bash
# clear-stale-nim-errors.sh — 批量清 OmniRoute provider health autopilot 陈旧错态
#
# 病: NIM account 风暴期冷却 (60s) 过期回活后 lastError/testStatus 不自动清
#      → Health Autopilot 检 "stale_connection_error" → 路由偏置或绕开本已回活 account
# 治: 批量调 POST /api/providers/health-autopilot/actions type=clear_stale_connection_error
#      清 lastError/rateLimitedUntil/testStatus 回 eligible
# 源: executeProviderHealthAutopilotAction() providerHealthAutopilot.ts:670
#      updateProviderConnection(id, buildConnectionClearPatch())
#
# === 圣上侧跑 (§1 nomke/omn 生产无 Supreme 令不动, §2 secret 真值零入脚本) ===
#   1. export OMN_MANAGE_TOKEN="<manage-scope API key 或 oma_ access token>"  # §2 圣上侧填, 禁入 git
#   2. export OMN_BASE_URL="https://<dev 或 prod Space>.hf.space"             # 候圣上定 dev(nonoke-omn) / prod(nomke/omn)
#   3. bash dev/scripts/clear-stale-nim-errors.sh
#   4. bash dev/scripts/clear-stale-nim-errors.sh --dry-run  # 先空跑看会清哪些 (不改)
#
# 鉴权三路 (requireManagementAuth): Dashboard session / CLI loopback token / manage-scope API key
# 此脚本走 manage-scope API key (Bearer 头), 须该 key 开 manage scope (Dashboard API Keys 页)
# Origin 头: validateBrowserMutationOrigin 防 CSRF, 须带 Origin: <base_url> (同源) 否则 403
#
# 不变量: 只清 stale_connection_error (非终态), 终态连接 source 409 拒 (isTerminalConnection)
#         不触 cooldown (cooldown 过期本 lazy 回活, 此清的是残留错误字段非 cooldown 本身)
#         nomn 私库纯查证血统, 此脚本参考实现非血统 (圣上侧跑不进 git 逻辑镜像)

set -euo pipefail

DRY_RUN=0
[[ "${1:-}" == "--dry-run" ]] && DRY_RUN=1

: "${OMN_MANAGE_TOKEN:?§2 须圣上侧 export OMN_MANAGE_TOKEN (manage-scope API key / oma_ token), 禁入 git}"
: "${OMN_BASE_URL:?须 export OMN_BASE_URL (Space URL, 例 https://nonoke-omn.hf.space dev / prod 候圣上定)}"

PROVIDER="nvidia"
API="/api/providers/health-autopilot"
ACT_API="/api/providers/health-autopilot/actions"

echo "==> 取 autopilot 报告 (provider=${PROVIDER}, includeHealthy=false, includeActions=true)..."
# -w 取 HTTP 状态码, fail-loud: 非 200 直接报错退出 (防 403/401 静默吞当 COUNT=0 正常)
HTTP_CODE=$(curl -sS -o /tmp/omn_autopilot_report.json -w "%{http_code}" \
  -H "Authorization: Bearer ${OMN_MANAGE_TOKEN}" \
  "${OMN_BASE_URL}${API}?provider=${PROVIDER}&includeHealthy=false&includeActions=true")

if [[ "${HTTP_CODE}" != "200" ]]; then
  echo "✗ GET autopilot 失败 HTTP ${HTTP_CODE} (非 200), fail-loud 退出. body 前 300 字:"
  head -c 300 /tmp/omn_autopilot_report.json 2>/dev/null
  echo ""
  echo "常见: 403/401=token 错或无 manage scope (须 Dashboard API Keys 页建 manage-scope key, 非 OpenRouter sk-or- key); 404=provider 名错; 5xx=Space 挂."
  exit 1
fi
REPORT=$(cat /tmp/omn_autopilot_report.json)

# 提取 stale_connection_error 动作 (connectionId + preconditionsHash)
# 用 python3 解 JSON 免 jq 依赖
ACTIONS=$(python3 -c '
import json, sys
try:
    r = json.loads(sys.stdin.read())
except Exception as e:
    print(f"JSON 解析失败: {e}", file=sys.stderr); print("[]", end=""); sys.exit(1)
# 若上游返 error 字段报错退出 (非 200 但 curl 未抓到的兜底)
if isinstance(r, dict) and r.get("error"):
    print(f"上游 error: {r[\"error\"]}", file=sys.stderr); print("[]", end=""); sys.exit(1)
# 找 issues[].actions[] 里 type=clear_stale_connection_error 的
out = []
for iss in r.get("issues", []):
    for a in iss.get("actions", []):
        if a.get("type") == "clear_stale_connection_error":
            tgt = a.get("target", {})
            out.append({
                "connectionId": tgt.get("connectionId", ""),
                "preconditionsHash": a.get("preconditionsHash", "")
            })
print(json.dumps(out))
' <<< "${REPORT}")

COUNT=$(python3 -c 'import json,sys; print(len(json.loads(sys.stdin.read())))' <<< "${ACTIONS}")
echo "==> 待清 stale_connection_error 动作数: ${COUNT}"

if [[ "${COUNT}" -eq 0 ]]; then
    echo "无陈旧错态, 退出."
    exit 0
fi

if [[ "${DRY_RUN}" -eq 1 ]]; then
    echo "==> --dry-run 空跑, 下列连接会被清 (不实际改):"
    python3 -c 'import json,sys
for a in json.loads(sys.stdin.read()):
    print(f"  connectionId={a[\"connectionId\"]}  hash={a[\"preconditionsHash\"][:16]}...")
' <<< "${ACTIONS}"
    exit 0
fi

OK=0; FAIL=0
python3 -c 'import json,sys
for a in json.loads(sys.stdin.read()):
    print(f"{a[\"connectionId\"]}\t{a[\"preconditionsHash\"]}")
' <<< "${ACTIONS}" | while IFS=$'\t' read -r CID HASH; do
  echo "==> 清 connectionId=${CID} ..."
  RES=$(curl -sS -o /tmp/clear_res.json -w "%{http_code}" \
    -X POST "${OMN_BASE_URL}${ACT_API}" \
    -H "Authorization: Bearer ${OMN_MANAGE_TOKEN}" \
    -H "Content-Type: application/json" \
    -H "Origin: ${OMN_BASE_URL}" \
    -d "$(python3 -c '
import json
print(json.dumps({
  "type": "clear_stale_connection_error",
  "target": {"provider": "nvidia", "connectionId": "'"$CID"'"},
  "preconditionsHash": "'"$HASH"'",
  "confirm": True
}))')")
  echo "    HTTP ${RES}: $(cat /tmp/clear_res.json 2>/dev/null | head -c 200)"
done

echo "==> 完成. 候圣上回 Health 仪表盘看 22 issues 清否 (Autopilot Status 降 warning→healthy)."
