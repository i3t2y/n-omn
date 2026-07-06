FROM diegosouzapw/omniroute:3.8.43

ENV OMNIROUTE_PORT=20128
ENV EXPOSED_PORT=7860
ENV DATA_DIR=/data

USER root

RUN apt-get update && apt-get install -y --no-install-recommends \
    curl \
    jq \
    python3 \
    python3-pip \
    sqlite3 \
    ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# ── 新增：huggingface_hub（HF Dataset 配置快照上传）─────────
RUN pip3 install --no-cache-dir --break-system-packages huggingface_hub
# ──────────────────────────────────────────────────────────

# ── 新增：安装 Litestream ──────────────────────────────────
# 使用 v0.5.9（非 v0.3.13）：修复 R2 InvalidContentEncoding 编码 bug + 支持 auto-recover
# v0.5.x asset 命名规则：litestream-{VER}-linux-{ARCH}.tar.gz（无 v 前缀，x86_64 非 amd64）
ARG LITESTREAM_VERSION=0.5.9
RUN ARCH=$(uname -m | sed 's/aarch64/arm64/') && \
    curl -fsSL \
      "https://github.com/benbjohnson/litestream/releases/download/v${LITESTREAM_VERSION}/litestream-${LITESTREAM_VERSION}-linux-${ARCH}.tar.gz" \
    | tar -xz -C /usr/local/bin litestream && \
    chmod +x /usr/local/bin/litestream && \
    litestream version
# ──────────────────────────────────────────────────────────

RUN mkdir -p /data && chmod 777 /data
RUN rm -rf /app/data && ln -sf /data /app/data

RUN mkdir -p /gate
COPY package.json /gate/package.json
COPY gate.js /gate/gate.js
RUN cd /gate && npm install --omit=dev --silent

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

COPY init-nim-keys.sh /entrypoint-init-nim.sh
RUN chmod +x /entrypoint-init-nim.sh

# ── 新增：Litestream 配置 ─────────────────────────────────
COPY litestream.yml /litestream.yml
# ──────────────────────────────────────────────────────────

EXPOSE 7860

# ── 新增：容器级健康检查 ─────────────────────────────────
HEALTHCHECK --interval=30s --timeout=10s --start-period=60s --retries=3 \
    CMD curl -sf http://127.0.0.1:7860/healthz || exit 1

ENTRYPOINT ["/entrypoint.sh"]
