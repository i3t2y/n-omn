# OmniRoute 永续节点 · 环境层（版本无关设计）
# ─────────────────────────────────────────────
# 升级 OmniRoute 的完整流程【不需要修改本文件】：
#   1. GHCR 侧以新版本上游镜像构建并推送  i3t2y/omniroute-base:X.Y.Z
#   2. Space Settings → Variables → BASE_IMAGE 改为新标签
#   3. Settings → Rebuild（构建变量变更需重建，非 Restart）
# 默认值 :stable 仅用于首次部署；浮动标签在缓存面前不具有确定性。
ARG BASE_IMAGE=ghcr.io/i3t2y/omniroute-base:stable
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
