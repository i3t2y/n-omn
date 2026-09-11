#!/usr/bin/env bash
# repro_k3_probe.sh — 一键复现 docs/ops/evidence/ 下 k3_probe 全部样例
#
# 只跑本地 mock, 不触网、不需要真 PSK (用合成串), 不改生产任何状态。
# 用法: bash tools/mock/repro_k3_probe.sh [port]
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PORT="${1:-8790}"
PSK='synthetic-psk-not-real-0123456789'      # 合成串: 仅过 mock, 非真 PSK
TMO='3'                                      # 压缩复现 ">30s 超时" 语义
ENDPOINT="http://127.0.0.1:${PORT}"
LOG="$(mktemp)"

cleanup() { [ -n "${MOCK_PID:-}" ] && kill "$MOCK_PID" 2>/dev/null; rm -f "$LOG"; }
trap cleanup EXIT

echo "# mock 上游启动 port=${PORT}"
python3 "${ROOT}/tools/mock/mock_k3_upstream.py" --port "$PORT" >"$LOG" 2>&1 &
MOCK_PID=$!
for _ in $(seq 1 30); do
  grep -q "mock_k3_upstream on" "$LOG" 2>/dev/null && break
  sleep 0.1
done
if ! grep -q "mock_k3_upstream on" "$LOG"; then
  echo "mock 启动失败:" >&2; cat "$LOG" >&2; exit 1
fi

run_case() {
  local name="$1" path="$2"
  echo
  echo "\$ python3 tools/k3_probe.py --once --endpoint <mock>${path}"
  python3 "${ROOT}/tools/k3_probe.py" --once --psk "$PSK" --timeout "$TMO" \
      --endpoint "${ENDPOINT}${path}"
  echo "# exit=$?  (健康 0 / DEGRADED 2 / 参数环境错 3)"
}

run_case "S1 健康 200"     /ok
run_case "S2 超时"         /slow
run_case "S3 上游 503"     /err
run_case "S4 空流/空回复"  /empty

echo
echo "\$ python3 tools/k3_probe.py --dry-run   # 离线演示状态机 (不触网)"
python3 "${ROOT}/tools/k3_probe.py" --dry-run

echo
echo "\$ python3 tools/k3_probe.py --interval 1 --endpoint <mock>/switch  # 真链路全周期"
timeout 15 python3 "${ROOT}/tools/k3_probe.py" --interval 1 --psk "$PSK" \
    --timeout "$TMO" --endpoint "${ENDPOINT}/switch" \
  | grep -E "SIGNAL|SUMMARY|DRYRUN" || true
echo "# 期望: 3 连败 → SIGNAL K3_DEGRADED; 2 连胜 → SIGNAL K3_RECOVERED"
