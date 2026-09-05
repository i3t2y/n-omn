#!/bin/sh
# helper.sh · omn 补包统一入口 (Zen令泛化统管各种依赖/环境/插件/文件包)
# 2026-07-29 Zen令"全构入3.8.48": runtime 装件全堆 GHCR base 镜像, helper runtime 装段退场.
#   boto3 已入 omn-ops/ghcr Dockerfile (build push :stable), helper 无须 runtime 重装.
# 框架留存: ensure_pip/ensure_apt/ensure_npm_binary/ensure_release_tar 扩展位,
#   未来加包复用结构 (校验已装 → 装 → WARN 不停), 不改 start.sh/Dockerfile (三件红线).
# 不改 start.sh/Dockerfile 免触三件定态红线 + 免 sync-space Rebuild; 由 entrypoint.sh 调.
#
# Zen 2026-07-29 裁砍七成: 路2加密降级, cryptography 不再需 (路2不实例化).
#   omn_encrypt.py/_try_import 仍 import 尝试但 _try_import except -> OMN_ENCRYPT=None 无害.
#   留 cryptography 代码 archive 不删, 将来多人/开路2 再加回此列表.
set -u

log() { echo "[helper] $*"; }

# ── 扩展位: 未来环境包(apt)/插件包(npm binary)/文件包(curl release tar) 入口留此 ──
#   ensure_apt() / ensure_npm_binary() / ensure_release_tar() / ensure_pip() 同模式
#   (校验已装 → 装 → WARN 不停)。本轮全件已入 base, helper 空跑留框架。
#   Zen后续另令加包再实装此处 (改此脚本 + 重推 sync-logic, Restart 即效零 Rebuild)。

log "补包完成 (全件已入 base, helper 留框架)"
