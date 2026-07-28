# OmniRoute 永续节点 · 环境层（版本无关设计）
# ─────────────────────────────────────────────
# 双轨切换机制 (2026-07-28 圣上调, 回应官方文档语义):
#   - ARG BASE_IMAGE = 文档占位符 + 默认值兜底 (HF 不注入 Variable 时退回 :stable 也能构建)
#   - 日常升级走 GHCR `:stable` 浮动标签覆盖: 新 release 推新版镜像到 `:stable` tag,
#     ARG 不动 prod 自动 rebuild 即拉新版 (版本无关设计真义)
#   - ARG 变量仅"某次恰须重建时顺手切": 改 ARG 默认值钉 digest 是备选路径 (非日常)
#
# HF 官方文档语义 (https://huggingface.co/docs/hub/spaces-sdks-docker Variables §Buildtime):
#   Variables are passed as build-args when building your Docker Space. 故 Space 设置
#   BASE_IMAGE Variable 可覆盖 ARG 默认值 (要求 Variable 名与 ARG 名字字一致)。前轮
#   径 C 实证"Variable 未透"的病根 (2026-07-27) 须重新验真: 或是当时 Rebuild 缓存命中,
#   或是改 Variable 值未真 Rebuild, 非官方语义为假。本双轨方案默认值改回 :stable 占位,
#   dev/prod 各设 BASE_IMAGE Variable 覆盖 ARG 升级路径 (待圣上手动设置两 Space)。
#
# 升级 OmniRoute 的两种路径 (2026-07-28 双轨):
#   A. 日常路径 (推荐): GHCR 侧推新版镜像到 `:stable` tag → dev/prod Space Rebuild 即拉新版,
#      ARG 默认值不动, Dashboard 看 Space Variable 也不动 (零 git 变更)
#   B. 钉 digest 路径 (备选): 改 ARG 默认值钉 <新标签>@sha256:<digest> → git commit + push
#      → sync-space-nonoke.yml 自动同步 dev + 触 Rebuild → dev 24h 绿 → 圣上 workflow_dispatch
#      触 sync-space-nomke.yml 同步 prod
#   回滚: 路径 A `:stable` 重推旧 digest 即回; 路径 B `git revert` + push + Rebuild
#
# dev/prod 隔离: sync-space-nonoke.yml (dev) push paths[Dockerfile] 自动触;
#   sync-space-nomke.yml (prod) 仅 workflow_dispatch (圣上显令点火) 非 push 自动触发。
ARG BASE_IMAGE=ghcr.io/i3t2y/omniroute-base:stable
FROM ${BASE_IMAGE}

# root 是永久需求而非过渡：上游 runner 永远 USER node 且永远缺工具，
# start 的运行时自愈需要写权限。同时保证 BASE_IMAGE 可直接指向上游
# 官方标签（diegosouzapw/omniroute:X.Y.Z）也能起——不依赖自建镜像。
USER root

# 作用域硬规则 (2026-07-28 首席架构师裁 + 官方文档 docs.docker.com/reference/dockerfile/#scope):
#   全局 ARG (FROM 前) 仅 FROM 可读, FROM 后指令须重声明 ARG 才可见。
#   重声明不带值 = 自动继承全局同名 ARG 当前值 (build-arg 覆盖 默认值-兜底 :stable 三层优先级)。
#   ENV 转存 = build 期 ${BASE_IMAGE} 展开入 runtime env, start.sh 可 `echo $BASE_IMAGE`
#   打印当前运行镜像版本 (dev/prod 鉴别+排障), 防御性编程不动 start 现行逻辑亦可用。
ARG BASE_IMAGE
ENV BASE_IMAGE=${BASE_IMAGE}

# litestream 版本驱逐 (2026-07-28 圣上令, 版本号不残留三件内):
#   ARG LITESTREAM_VERSION = build 期值 + ENV 转存 runtime; start.sh 镜像 A 路径补全
#   分支 (BASE_IMAGE 直指裸上游 diegosouzapw/omniroute 无 litestream 时触发) 读此 env
#   curl 拉取。日常路径走 GHCR base (本地 tar COPY 预装) 不触发此分支。
#   升 litestream: 改此 ARG 默认值 + GHCR base (omn-ops/ghcr/Dockerfile:43) 同步 + push
#   Rebuild, 或 HF Variable "LITESTREAM_VERSION" buildtime 覆盖 (官方义 build-arg 透传)。
#   资产命名 litestream-{ver}-linux-{arch}.tar.gz v0.5.x 全程稳定 (v0.5.7→v0.5.15 实证)。
ARG LITESTREAM_VERSION=0.5.9
ENV LITESTREAM_VERSION=${LITESTREAM_VERSION}

# --chmod=755 属 buildkit 标准能力（HF 文档的 build secrets 同为 buildkit 语法，
# 可证构建器支持），替代 RUN chmod，消灭对文件属主的前提假设。
COPY --chmod=755 start.sh /start.sh

EXPOSE 7860

# 探活契约：node 二进制由上游镜像保证（engines: >=22 <27，Next.js 应用），
# 7860 由 HF app_port 固定，/healthz 由逻辑层 gate.js 提供。
HEALTHCHECK --interval=30s --timeout=10s --start-period=180s --retries=3 \
  CMD node -e "require('http').get('http://127.0.0.1:7860/healthz',r=>{process.exit(r.statusCode===200?0:1)}).on('error',()=>process.exit(1))" || exit 1

ENTRYPOINT ["/start.sh"]
