# ── 基础镜像：钉死到验证过健康的 3.8.43，禁止浮动 latest ──────────
# 根因：latest 会漂到 3.8.46（默认 Turbopack 构建 + migration 117 表重建），
#       导致 Next 服务进程静默无法 ready，entrypoint 健康等待空转卡在 starting。
# 拿 digest：docker pull diegosouzapw/omniroute:3.8.43
#           docker inspect --format='{{index .RepoDigests 0}}' diegosouzapw/omniroute:3.8.43
# 用 tag+digest 双写：digest 保证不可变，tag 便于人读。
# FROM diegosouzapw/omniroute:3.8.43@sha256:517c160643c56ad72e3e305458d961c9a4c87f711393c13020450f9f088d1570
# FROM diegosouzapw/omniroute:3.8.46@sha256:3e254b91fffa9aa20e244b3bce89c1390fa32b1d35efa4e5b3823eec10450bd4
FROM diegosouzapw/omniroute:latest

ENV OMNIROUTE_PORT=20128
ENV EXPOSED_PORT=7860
ENV DATA_DIR=/data

# ── 跨版本防御 env（3.8.43 无害；若将来误漂到新版可避免静默 hang）──
# Turbopack 逃生阀：强制走 webpack，绕开 3.8.45+ 的 Docker Turbopack 缓存 mmap 失败
ENV OMNIROUTE_USE_TURBOPACK=0
# 迁移安全阀：从旧库补多个 migration（含 117 表重建）时不触发 abort 刷屏中断
ENV OMNIROUTE_MAX_PENDING_MIGRATIONS=0

USER root

RUN apt-get update && apt-get install -y --no-install-recommends \
    curl \
    jq \
    python3 \
    python3-pip \
    sqlite3 \
    ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# ── huggingface_hub（HF Dataset 配置快照上传）──────────────────────
RUN pip3 install --no-cache-dir --break-system-packages huggingface_hub

# ── Litestream v0.5.9（修复 R2 InvalidContentEncoding + auto-recover）──
# asset 命名：litestream-{VER}-linux-{ARCH}.tar.gz（无 v 前缀，x86_64 非 amd64）
ARG LITESTREAM_VERSION=0.5.9
RUN ARCH=$(uname -m | sed 's/aarch64/arm64/') && \
    curl -fsSL \
      "https://github.com/benbjohnson/litestream/releases/download/v${LITESTREAM_VERSION}/litestream-${LITESTREAM_VERSION}-linux-${ARCH}.tar.gz" \
    | tar -xz -C /usr/local/bin litestream && \
    chmod +x /usr/local/bin/litestream && \
    litestream version

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

COPY litestream.yml /litestream.yml

EXPOSE 7860

# ── 容器级健康检查：start-period 与 entrypoint 内部 180s 等待对齐 ──
HEALTHCHECK --interval=30s --timeout=10s --start-period=180s --retries=3 \
    CMD curl -sf http://127.0.0.1:7860/healthz || exit 1

ENTRYPOINT ["/entrypoint.sh"]
