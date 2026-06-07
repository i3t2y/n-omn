FROM diegosouzapw/omniroute:latest

ENV OMNIROUTE_PORT=20128
ENV EXPOSED_PORT=7860
ENV DATA_DIR=/data

USER root

RUN apt-get update && apt-get install -y --no-install-recommends \
    curl \
    jq \
    python3 \
    sqlite3 \
    ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# ── 新增：安装 Litestream ──────────────────────────────────
ARG LITESTREAM_VERSION=0.3.13
RUN ARCH=$(uname -m | sed 's/x86_64/amd64/;s/aarch64/arm64/') && \
    curl -fsSL \
      "https://github.com/benbjohnson/litestream/releases/download/v${LITESTREAM_VERSION}/litestream-v${LITESTREAM_VERSION}-linux-${ARCH}.tar.gz" \
    | tar -xz -C /usr/local/bin litestream && \
    chmod +x /usr/local/bin/litestream
# ──────────────────────────────────────────────────────────

RUN mkdir -p /data && chmod 777 /data
RUN rm -rf /app/data && ln -sf /data /app/data

RUN mkdir -p /gate
COPY gate/package.json /gate/package.json
COPY gate/gate.js /gate/gate.js
RUN cd /gate && npm install --omit=dev --silent

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

COPY init-nim-keys.sh /entrypoint-init-nim.sh
RUN chmod +x /entrypoint-init-nim.sh

# ── 新增：Litestream 配置 ─────────────────────────────────
COPY litestream.yml /litestream.yml
# ──────────────────────────────────────────────────────────

EXPOSE 7860

ENTRYPOINT ["/entrypoint.sh"]
