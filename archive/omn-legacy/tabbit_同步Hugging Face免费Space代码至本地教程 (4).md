### **结论：通过 Docker tag 覆盖实现不改代码切换——HF Dockerfile 永远写死 `FROM ghcr.io/your/omniroute:3.8.43`，切换时只需在本地用 `docker tag + docker push` 覆盖自有仓库中 `3.8.43` 这个 tag 指向的镜像内容。核心难点是 bootstrap.sh 必须自适应两种镜像：方案 A 镜像（官方纯副本）不含工具，方案 B 镜像（全栈自建）预装工具。解法是 bootstrap.sh 运行时检测工具是否存在，缺失则自动安装。**

---

### 一、不改代码切换的技术原理

Docker registry 允许同一个 tag 被覆盖——push 新镜像到已存在的 tag 会替换旧镜像。HF Space 的 Dockerfile 中 `FROM ghcr.io/your/omniroute:3.8.43` 引用的是 tag，不是 digest（不能加 `@sha256:`，HF 构建器报错已验证）。tag 是可变的，digest 是不可变的。利用 tag 的可变性：

```
平时（方案 A）：
  ghcr.io/your/omniroute:3.8.43  →  指向官方镜像 diegosouzapw/omniroute:3.8.43 的纯副本

应急（方案 B）：
  ghcr.io/your/omniroute:3.8.43  →  指向本地构建的全栈镜像（含工具层）

切换操作：
  本地 docker build / docker tag → docker push 覆盖同一个 tag → HF Space Restart
  HF Dockerfile 零改动
```

HF Space Restart 时容器重建，会重新 pull `ghcr.io/your/omniroute:3.8.43`——此时 pull 到的是最新 push 的镜像内容。如果在此之前用全栈镜像覆盖了这个 tag，Restart 后运行的就是方案 B。

### 二、两种镜像的构建与推送

#### 方案 A 镜像——官方镜像纯副本

```bash
# 拉取官方镜像
docker pull diegosouzapw/omniroute:3.8.43

# 重新 tag 到自有仓库的同一地址
docker tag diegosouzapw/omniroute:3.8.43 ghcr.io/your-username/omniroute:3.8.43

# 推送覆盖
docker push ghcr.io/your-username/omniroute:3.8.43
```

这个镜像 = 官方 OmniRoute 3.8.43 原封不动，不含 jq/sqlite3/python3/pip/huggingface-cli/litestream。优点是获取最简单、与官方 100% 一致；缺点是缺工具，bootstrap.sh 需要运行时安装。

#### 方案 B 镜像——自建全栈镜像

本地编写 `Dockerfile.fullstack`：

```dockerfile
FROM diegosouzapw/omniroute:3.8.43

USER root
RUN apt-get update && apt-get install -y --no-install-recommends \
    curl jq python3 python3-pip sqlite3 ca-certificates \
    && rm -rf /var/lib/apt/lists/*

RUN pip3 install --no-cache-dir --break-system-packages huggingface_hub

ARG LITESTREAM_VERSION=0.5.9
RUN ARCH=$(uname -m | sed 's/aarch64/arm64/') && \
    curl -fsSL "https://github.com/benbjohnson/litestream/releases/download/v${LITESTREAM_VERSION}/litestream-${LITESTREAM_VERSION}-linux-${ARCH}.tar.gz" \
    | tar -xz -C /usr/local/bin litestream && chmod +x /usr/local/bin/litestream

RUN mkdir -p /data /gate /tmp/logic && chmod 777 /data /gate /tmp/logic
RUN rm -rf /app/data && ln -sf /data /app/data
```

构建并推送到同一个 tag：

```bash
docker build -f Dockerfile.fullstack -t ghcr.io/your-username/omniroute:3.8.43 .
docker push ghcr.io/your-username/omniroute:3.8.43
```

这个镜像 = 官方镜像 + 工具层，工具已固化在镜像层中，启动时无需安装。

### 三、自适应 bootstrap.sh——兼容两种镜像的关键

bootstrap.sh 必须能同时跑在"有工具"和"无工具"两种镜像上。核心逻辑是运行时检测 + 按需安装：

```bash
#!/bin/sh
set -e

echo "[bootstrap] 启动逻辑注入流程..."

# ═══ 自适应工具层 ═══
# 方案 A 镜像（官方副本）：工具缺失，运行时安装（约 60 秒）
# 方案 B 镜像（全栈自建）：工具已存在，跳过安装（秒级）

_need_install=0

# 逐个检测关键工具
for _tool in jq sqlite3 python3 huggingface-cli litestream; do
  if ! command -v "$_tool" >/dev/null 2>&1; then
    echo "[bootstrap] 缺失: $_tool"
    _need_install=1
  fi
done

if [ "$_need_install" = "1" ]; then
  echo "[bootstrap] 方案 A 模式（官方镜像），运行时安装工具..."
  apt-get update && apt-get install -y --no-install-recommends \
    curl jq python3 python3-pip sqlite3 ca-certificates
  rm -rf /var/lib/apt/lists/*
  
  pip3 install --no-cache-dir --break-system-packages huggingface_hub
  
  if ! command -v litestream >/dev/null 2>&1; then
    _arch=$(uname -m | sed 's/aarch64/arm64/')
    curl -fsSL "https://github.com/benbjohnson/litestream/releases/download/v0.5.9/litestream-0.5.9-linux-${_arch}.tar.gz" \
      | tar -xz -C /usr/local/bin litestream
    chmod +x /usr/local/bin/litestream
  fi
  echo "[bootstrap] 工具安装完成"
else
  echo "[bootstrap] 方案 B 模式（全栈镜像），工具已就绪"
fi

# ═══ 业务逻辑层（A/B 完全共用）═══

if [ -z "$HF_TOKEN" ] || [ -z "$LOGIC_BUCKET_REPO" ]; then
  echo "[bootstrap] FATAL: 必须配置 HF_TOKEN 和 LOGIC_BUCKET_REPO"
  exit 1
fi

# 备份当前版本（回滚用）
if [ -f /entrypoint.sh ]; then
  cp /entrypoint.sh /entrypoint.sh.bak
  [ -f /gate/gate.js ] && cp /gate/gate.js /gate/gate.js.bak
  [ -f /entrypoint-init-nim.sh ] && cp /entrypoint-init-nim.sh /entrypoint-init-nim.sh.bak
  [ -f /litestream.yml ] && cp /litestream.yml /litestream.yml.bak
fi

# 拉取最新逻辑
echo "[bootstrap] 同步存储桶: $LOGIC_BUCKET_REPO ..."
if huggingface-cli download --repo-type dataset "$LOGIC_BUCKET_REPO" \
    --local-dir /tmp/logic --token "$HF_TOKEN" --quiet; then
  cp /tmp/logic/entrypoint.sh /entrypoint.sh
  cp /tmp/logic/gate.js /gate/gate.js
  cp /tmp/logic/init-nim-keys.sh /entrypoint-init-nim.sh
  cp /tmp/logic/litestream.yml /litestream.yml
  [ -f "/tmp/logic/package.json" ] && cp /tmp/logic/package.json /gate/package.json
  echo "[bootstrap] 逻辑注入完成"
else
  echo "[bootstrap] ⚠ 拉取失败，使用备份版本"
  [ -f /entrypoint.sh.bak ] && cp /entrypoint.sh.bak /entrypoint.sh
  [ -f /gate/gate.js.bak ] && cp /gate/gate.js.bak /gate/gate.js
  [ -f /entrypoint-init-nim.sh.bak ] && cp /entrypoint-init-nim.sh.bak /entrypoint-init-nim.sh
  [ -f /litestream.yml.bak ] && cp /litestream.yml.bak /litestream.yml
fi

chmod +x /entrypoint.sh /entrypoint-init-nim.sh 2>/dev/null || true
rm -rf /tmp/logic

exec /entrypoint.sh
```

### 四、HF Dockerfile——永远不变

```dockerfile
FROM ghcr.io/your-username/omniroute:3.8.43

COPY bootstrap.sh /bootstrap.sh
RUN chmod +x /bootstrap.sh

EXPOSE 7860
HEALTHCHECK --interval=30s --timeout=10s --start-period=180s --retries=3 \
    CMD curl -sf http://127.0.0.1:7860/healthz || exit 1

ENTRYPOINT ["/bootstrap.sh"]
```

注意：方案 A 镜像（官方副本）不含 curl，HEALTHCHECK 的 `curl` 会失败。但 HEALTHCHECK 失败不影响容器启动，只是 HF 界面显示 unhealthy。如果在意，可以用 `wget` 或在 bootstrap.sh 中安装 curl 后由 entrypoint 接管健康检查。或更简单——HEALTHCHECK 用 `node -e "require('http').get(...)"`，Node.js 是官方镜像一定有的。

修正后的 HEALTHCHECK：

```dockerfile
HEALTHCHECK --interval=30s --timeout=10s --start-period=180s --retries=3 \
    CMD node -e "require('http').get('http://127.0.0.1:7860/healthz',r=>{process.exit(r.statusCode===200?0:1)}).on('error',()=>process.exit(1))" || exit 1
```

### 五、完整切换流程

#### 从方案 A 切换到方案 B

```bash
# 1. 本地构建全栈镜像
docker build -f Dockerfile.fullstack -t ghcr.io/your-username/omniroute:3.8.43 .

# 2. 推送覆盖同一个 tag
docker push ghcr.io/your-username/omniroute:3.8.43

# 3. HF Space Settings → Restart
#    （不改任何代码，bootstrap.sh 和 Dockerfile 都不变）
```

Restart 后，HF 容器重新 pull `ghcr.io/your-username/omniroute:3.8.43`，拿到的是全栈镜像。bootstrap.sh 检测到工具已存在，跳过安装，秒级进入业务逻辑。

#### 从方案 B 切回方案 A

```bash
# 1. 拉取官方镜像
docker pull diegosouzapw/omniroute:3.8.43

# 2. tag 到自有仓库同一地址
docker tag diegosouzapw/omniroute:3.8.43 ghcr.io/your-username/omniroute:3.8.43

# 3. 推送覆盖
docker push ghcr.io/your-username/omniroute:3.8.43

# 4. HF Space Settings → Restart
```

Restart 后拿到官方纯副本镜像，bootstrap.sh 检测到工具缺失，运行时安装（约 60 秒），然后进入业务逻辑。

### 六、两种模式的运行时表现差异

| 维度 | 方案 A（官方副本） | 方案 B（全栈自建） |
|------|------------------|------------------|
| 镜像获取 | pull + tag + push（1 分钟） | 本地 build + push（5-10 分钟） |
| 每次 Restart 启动时间 | 约 60 秒（运行时装工具） | 约 5 秒（跳过安装） |
| 镜像内容 | 与官方 100% 一致 | 官方 + 工具层 |
| 构建失败风险 | 零（不构建） | 低（本地构建，可控） |
| 适用场景 | 常态运行 | 风控收紧时应急 |

方案 A 每次 Restart 多花 60 秒装工具，这是"不改代码切换"的代价。如果觉得 60 秒不可接受，可以平时就用方案 B——但那就失去了"镜像与官方保持同步"的保真优势。权衡取舍由你决定。

*内容由 AI 生成仅供参考*