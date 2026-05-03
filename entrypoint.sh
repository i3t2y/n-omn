#!/bin/bash
# 启动 OmniRoute
omniroute &
OR_PID=$!

# 等待 OmniRoute 就绪
until curl -sf http://127.0.0.1:7860/api/monitoring/health > /dev/null 2>&1; do
  sleep 2
done

# 如果没有 init 标记，跑 init 脚本
if [ ! -f /data/.init-done ]; then
  bash /app/init-nim-keys.sh
fi

wait $OR_PID
