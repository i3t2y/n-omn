#!/bin/bash
# test-signal.sh — v4.3 candidate 进程监督 (trap + SIGTERM/SIGINT 转发)
# 1) grep entrypoint.sh trap/pid/wait 关键逻辑
# 2) 真跑: 启一个 mock entrypoint (简化复制 entrypoint trap 块) + node gate, 发 SIGTERM, 验清理
set -uo pipefail
D=$(cd "$(dirname "$0")/.." && pwd)
ENT="$D/entrypoint.sh"
PASS=0; FAIL=0
chk() { if grep -qE "$1" "$ENT"; then echo "  ✓ $2"; PASS=$((PASS+1)); else echo "  ✗ $2 (pat: $1)"; FAIL=$((FAIL+1)); fi; }
chk 'trap .*TERM.*INT|trap .*INT.*TERM' 'trap SIGTERM/SIGINT 注册'
chk 'kill -"\$sig"|kill -TERM|kill -INT' '转发信号到子进程'
chk 'wait \$|wait\b' 'wait 回收子进程'
# 子 PID 保存 (POSIX sh 变量, 不用 bash 数组)
chk 'GATE_PID=|OR_PID=|LITESTREAM_PID=|_PID=' '子进程 PID 保存'
# /healthz fetch --max-time
chk 'max-time 3|--max-time 3' '/healthz fetch 超时'
# OmniRoute 启动等待 (180s 内 ready)
chk 'ready| READY |180' 'OmniRoute ready 等待'

# 真跑: node gate 优雅关
TMP=$(mktemp -d)
cat > "$TMP/mock-entry.sh" <<'SH'
#!/bin/bash
# 简化 trap: 启门, SIGTERM 后 KILL 门
cd "$1"
trap 'echo "[mock-entry] SIGTERM received, killing gate"; kill -TERM $GATE_PID 2>/dev/null; wait $GATE_PID 2>/dev/null; exit 0' TERM INT
node gate.js &
GATE_PID=$!
wait $GATE_PID
SH
chmod +x "$TMP/mock-entry.sh"
OMNIROUTE_PORT=9999 EXPOSED_PORT=0 INTERNAL_PSK=$(printf 'p%.0s' {1..32}) OMNIROUTE_API_KEY=test bash "$TMP/mock-entry.sh" "$D" &> "$TMP/out.log" &
EPID=$!
sleep 1.0
kill -TERM $EPID 2>/dev/null
sleep 1.0
# 验日志: expected "SIGTERM received, killing gate"
if grep -q "SIGTERM received, killing gate" "$TMP/out.log"; then echo "  ✓ 真跑 trap SIGTERM 转发到 gate"; PASS=$((PASS+1))
else echo "  ✗ 真跑 trap 未触发 (尾部日志):"; tail -5 "$TMP/out.log" >&2; FAIL=$((FAIL+1)); fi
# 验无遗留 (EPID 确已退)
if ! kill -0 $EPID 2>/dev/null; then echo "  ✓ entrypoint 进程已退出 (无遗留)"; PASS=$((PASS+1))
else echo "  ✗ entrypoint 进程仍存活"; FAIL=$((FAIL+1)); kill -9 $EPID 2>/dev/null; fi
rm -rf "$TMP"

echo "[signal-test] PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
