#!/bin/bash
set -e

# 后台启动 OmniRoute（它自己监听 7860）
/app/start.sh &

# 等 OmniRoute 就绪后跑 init 脚本
/init-nim-keys.sh

# 保持前台进程
wait
