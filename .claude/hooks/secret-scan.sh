#!/bin/bash
# PreToolUse 钩子: 检出 secret 明文模式则阻断 (exit 2)
# 来源版本: omn-merge v2 任务书第二步
# 生成日期: 2026-07-21
# 生成器: cg52
# 状态: active
#
# 拦截三类:
#   1. nvapi- NIM key 明文 (实测长度 30+ 字符)
#   2. X-Internal-PSK 头明文
#   3. R2 凭证 access key 明文 (omniroute-data.*access)
# 输入: stdin = Claude Code PreToolUse JSON (含 tool_input.command / content)
# 命中: exit 2 (Claude Code 视为阻断, 不执行工具)
# 未命中: exit 0 (放行)

input=$(cat)

# 提取命令/文件内容字段 (粗扫全输入, 不解析 JSON)
# nvapi- 后跟 20+ 字符 (实测 key 长度远超 20, 用 20 防误伤短串)
if echo "$input" | grep -qE 'nvapi-[A-Za-z0-9_\-]{20,}'; then
  echo "BLOCK: 命中 nvapi- NIM key 明文模式, 操作已拦截。改用 env 引用或脱敏后重试。" >&2
  exit 2
fi

# X-Internal-PSK 明文 (非 ${PSK} 占位)
if echo "$input" | grep -qE 'X-Internal-PSK:\s*[A-Za-z0-9]{8,}'; then
  echo "BLOCK: 命中 X-Internal-PSK 明文模式, 操作已拦截。改用 env 引用或脱敏后重试。" >&2
  exit 2
fi

# R2 access key 明文
if echo "$input" | grep -qiE 'omniroute-data.*[Aa]ccess'; then
  echo "BLOCK: 命中 R2 access key 明文模式, 操作已拦截。改用 env 引用或脱敏后重试。" >&2
  exit 2
fi

exit 0
