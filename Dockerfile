# OmniRoute 永续节点 · 环境层（版本无关设计）
# ─────────────────────────────────────────────
# 升级 OmniRoute 的完整流程【改本文件 ARG 默认值】：
#   1. GHCR 侧以新版本上游镜像构建并推送  i3t2y/omniroute-base:X.Y.Z
#   2. 改本文件 `ARG BASE_IMAGE=` 默认值为 <新标签>@sha256:<全 64 位 digest>
#   3. git commit + push 到 main → sync-space-nonoke.yml 自动同步 dev nonoke/omn + 触 Rebuild
#   4. dev 验收 24h 全绿 → 圣上 workflow_dispatch 触 sync-space-nomke.yml 同步 prod nomke/omn
#
# 机制修正 (2026-07-27 实证): HF Space Variables 只注入运行时 env, 不透传 docker build --build-arg
# 通道。旧注释 "改 Variable → Rebuild 切换" 从未被真实演练过, 切换路径首演即现形: ARG 用默认值 :stable
# 拉镜像, Variable 改值不生效。故切换权威开关 = ARG 默认值 (git 管理, commit 历史可查), 非 Space Variable。
# dev/prod 隔离靠 sync-space-nomke.yml 仅 workflow_dispatch (圣上显令点火), 非 push 自动触发。
ARG BASE_IMAGE=ghcr.io/i3t2y/omniroute-base:3.8.48@sha256:da99fac1a697022a0529805294c58a10923fc1c758616f4f0b2ea8428b0f408f
FROM ${BASE_IMAGE}

# root 是永久需求而非过渡：上游 runner 永远 USER node 且永远缺工具，
# bootstrap 的运行时自愈需要写权限。同时保证 BASE_IMAGE 可直接指向上游
# 官方标签（diegosouzapw/omniroute:X.Y.Z）也能起——不依赖自建镜像。
USER root

# --chmod=755 属 buildkit 标准能力（HF 文档的 build secrets 同为 buildkit 语法，
# 可证构建器支持），替代 RUN chmod，消灭对文件属主的前提假设。
COPY --chmod=755 bootstrap.sh /bootstrap.sh

EXPOSE 7860

# 探活契约：node 二进制由上游镜像保证（engines: >=22 <27，Next.js 应用），
# 7860 由 HF app_port 固定，/healthz 由逻辑层 gate.js 提供。
HEALTHCHECK --interval=30s --timeout=10s --start-period=180s --retries=3 \
  CMD node -e "require('http').get('http://127.0.0.1:7860/healthz',r=>{process.exit(r.statusCode===200?0:1)}).on('error',()=>process.exit(1))" || exit 1

ENTRYPOINT ["/bootstrap.sh"]
