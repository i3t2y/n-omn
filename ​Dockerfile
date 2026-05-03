FROM diegosouzapw/omniroute:latest

# HF Space 以 uid=1000 运行，确保 /app/data 可写
RUN chown -R 1000:1000 /app/data

# 覆盖默认端口 20128 → 7860（HF Space 要求）
ENV PORT=7860
# DATA_DIR 保持官方默认 /app/data，无需修改
# NEXT_PUBLIC_BASE_URL 在 HF Space Variables 里设置，不硬编码（每个 Space URL 不同）

COPY entrypoint.sh /entrypoint.sh
COPY init-nim-keys.sh /init-nim-keys.sh

RUN chmod +x /entrypoint.sh /init-nim-keys.sh

EXPOSE 7860

ENTRYPOINT ["/entrypoint.sh"]
