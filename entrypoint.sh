#!/bin/bash
set -e

echo "[entrypoint] PORT=${PORT}"
echo "[entrypoint] DATA_DIR=${DATA_DIR}"

# 官方镜像工作目录是 /app，启动命令是 node run-standalone.mjs
# run-standalone.mjs 会调用 bootstrapEnv() 自动生成 secrets，再 spawn server.js
cd /app
node run-standalone.mjs &
OR_PID=$!

echo "[entrypoint] OmniRoute started (PID=${OR_PID}), running init script..."

# init 脚本内部有 until curl health 的等待循环，直接执行
/init-nim-keys.sh

echo "[entrypoint] Init complete. Keeping container alive..."
wait $OR_PID
