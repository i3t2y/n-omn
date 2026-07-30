#!/bin/bash
# FlareTunnel 静态二进制编译脚本 (nomn 私库 SSOT, 与上游 MorDavid/FlareTunnel 同哲学)
# 产物 flaretunnel 须 push HF Dataset nonoke/omn-logic 根 (Space 启动态资产).
# 卷 1: go build 静态二进制 (无 CGO 依赖, alpine 兼容)
# 卷 2: sha256 校验 (与已验证 digest fd010e60 比对前提)
# 编译环境须 Go 1.23+ (见 FlareTunnel.go go.mod 要求; alpine/容器内均可).
set -eo pipefail
cd "$(dirname "$0")"
GOOS=linux GOARCH=amd64 CGO_ENABLED=0 go build -ldflags="-s -w" -o flaretunnel FlareTunnel.go
echo "build ok: $(ls -la flaretunnel)"
sha256sum flaretunnel
