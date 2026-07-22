# ── OmniRoute 3.8.43 终极优化版 · 部署镜像 ──────────────────────
# 镜像锁定：tag+digest 双写，禁止浮动 latest
# 根因：latest 会漂到新版（Turbopack 构建 + migration 表重建），
#       导致 Next 服务静默无法 ready，entrypoint 健康等待空转卡 starting。
FROM diegosouzapw/omniroute:3.8.43@sha256:517c160643c56ad72e3e305458d9619a4c87f711393c13020450f9f088d1570

ENV OMNIROUTE_PORT=20128
ENV EXPOSED_PORT=7860
ENV DATA_DIR=/data

# ── 跨版本防御 env（3.8.43 无害；防误漂到新版静默 hang）──
ENV OMNIROUTE_USE_TURBOPACK=0
ENV OMNIROUTE_MAX_PENDING_MIGRATIONS=0

USER root

# ── 精简依赖：仅安装运行必需包，--no-install-recommends 减小体积 ──
RUN apt-get update && apt-get install -y --no-install-recommends \
    curl jq python3 python3-pip sqlite3 ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# ── huggingface_hub（HF Dataset 配置快照上传）──────────────────────
RUN pip3 install --no-cache-dir --break-system-packages huggingface_hub

# ── Litestream v0.5.9（修复 R2 InvalidContentEncoding）──
# asset 命名：litestream-{VER}-linux-{ARCH}.tar.gz（无 v 前缀，x86_64 非 amd64）
ARG LITESTREAM_VERSION=0.5.9
RUN ARCH=$(uname -m | sed 's/aarch64/arm64/') && \
    curl -fsSL \
      "https://github.com/benbjohnson/litestream/releases/download/v${LITESTREAM_VERSION}/litestream-${LITESTREAM_VERSION}-linux-${ARCH}.tar.gz" \
    | tar -xz -C /usr/local/bin litestream && \
    chmod +x /usr/local/bin/litestream && \
    litestream version

# ── 数据目录符号链接：/data 持久化 ────────────────────────────────
RUN mkdir -p /data && chmod 777 /data
RUN rm -rf /app/data && ln -sf /data /app/data

# ── Gate.js（零依赖纯 Node.js 内置模块，无需 npm install）──────────
RUN mkdir -p /gate
COPY gate.js /gate/gate.js

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

COPY init-nim-keys.sh /entrypoint-init-nim.sh
RUN chmod +x /entrypoint-init-nim.sh

COPY litestream.yml /litestream.yml

EXPOSE 7860

# ── 容器级健康检查：start-period 与 entrypoint 内部 180s 等待对齐 ──
HEALTHCHECK --interval=30s --timeout=10s --start-period=180s --retries=3 \
    CMD curl -sf http://127.0.0.1:7860/healthz || exit 1

ENTRYPOINT ["/entrypoint.sh"]
