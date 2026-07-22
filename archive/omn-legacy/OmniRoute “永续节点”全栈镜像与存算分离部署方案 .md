### **OmniRoute “永续节点”全栈镜像与存算分离部署方案 (v4.5.0-Final)**

针对 Hugging Face (HF) 2026 年 7 月实施的免费层级资源封锁与构建队列限制，本方案通过“环境预装化”与“逻辑动态化”的深度解耦，旨在构建一个规避平台审计、实现秒级更新且环境绝对稳定的 AI 网关节点。

---

### **第一步：方案架构设计 (Architecture Design)**

本方案将系统拆分为三个物理隔离的层级，以确保在 HF 严苛的政策下实现“零构建”运行：

1.  **环境底座层 (Base Environment)**：利用自建镜像仓库（如 Docker Hub / 阿里云 ACR）托管预装了所有系统依赖（Node.js, Python, SQLite, FFmpeg 等）的全栈镜像。该层解决“版本漂移”与“构建排队”问题。
2.  **逻辑注入层 (Logic Injection)**：将业务核心脚本（`gate.js`, `entrypoint.sh`）存放于 HF Private Dataset。该层解决“更新繁琐”问题，实现无需重构镜像的快速迭代。
3.  **运行载体层 (Space Runtime)**：在 HF Space 中仅保留一个极简的“指针”Dockerfile，其唯一职能是拉取自建镜像并启动引导程序。

---

### **第二步：自建全栈镜像构建 (Local Image Preparation)**

在本地开发环境或私有 CI/CD 流水线中完成环境的封装。

#### **1. 编写全栈环境 Dockerfile (Dockerfile.base)**
```dockerfile
# 锁定底层操作系统与 Node 版本
FROM node:22-bullseye-slim

# 预装所有改装工具与系统依赖，确保运行时无需连接外部 apt 源
USER root
RUN apt-get update && apt-get install -y --no-install-recommends \
    curl jq python3 python3-pip sqlite3 ca-certificates git \
    && rm -rf /var/lib/apt/lists/*

# 预装 Hugging Face 命令行工具，用于后续动态拉取逻辑
RUN pip3 install --no-cache-dir --break-system-packages huggingface_hub

# 预装 Litestream (数据库同步工具)
ARG LITESTREAM_VERSION=0.5.9
RUN curl -fsSL "https://github.com/benbjohnson/litestream/releases/download/v${LITESTREAM_VERSION}/litestream-${LITESTREAM_VERSION}-linux-$(uname -m | sed 's/aarch64/arm64/').tar.gz" \
    | tar -xz -C /usr/local/bin

# 初始化目录结构
RUN mkdir -p /data /gate /app /tmp/logic && chmod -R 777 /data /gate /app /tmp/logic
WORKDIR /app

# 注入通用引导脚本
COPY bootstrap.sh /bootstrap.sh
RUN chmod +x /bootstrap.sh

ENTRYPOINT ["/bootstrap.sh"]
```

#### **2. 构建并推送至私有仓库**
执行以下命令，建议使用具体的版本号进行标记：
```bash
docker build -t your-registry/omniroute-fullstack:v4.5.0 .
docker push your-registry/omniroute-fullstack:v4.5.0
```

---

### **第三步：逻辑层配置 (Dataset Side)**

在您的 **Private Dataset**（如 `your-name/omni-logic`）中上传以下核心业务文件。这些文件可以随时在网页端修改，无需重新构建 Docker。

1.  **`entrypoint.sh`**：负责进程编排（启动 Node 服务与数据库备份）。
2.  **`gate.js`**：负责 PSK 鉴权与流式转发逻辑。
3.  **`package.json`**：定义 `gate.js` 的 Node 依赖。
4.  **`litestream.yml`**：数据库 R2 备份配置。

---

### **第四步：Hugging Face Space 部署 (Space Side)**

在 HF Space 仓库中，仅需保留两个文件，实现“指针式”部署。

#### **1. Dockerfile (指针引导)**
```dockerfile
# 绝对锁定自建镜像，避免任何构建逻辑
FROM your-registry/omniroute-fullstack:v4.5.0
```

#### **2. README.md (元数据声明)**
```yaml
---
title: OmniRoute Node
sdk: docker
app_port: 7860
---
```

---

### **第五步：自动化引导流程 (Execution Flow)**

当 Space 启动时，容器内预装的 `/bootstrap.sh` 将执行以下自动化逻辑：

1.  **鉴权与拉取**：利用环境变量中的 `HF_TOKEN`，通过 `huggingface-cli` 从 Dataset 秒级同步业务脚本至 `/tmp/logic`。
2.  **逻辑注入**：将 `/tmp/logic` 中的文件分发至运行目录 `/gate`。
3.  **依赖对齐**：在容器内执行 `npm install --omit=dev`。由于 Node 环境已预装，此过程极快。
4.  **控制权移交**：执行 `exec /entrypoint.sh`，启动业务进程。

---

### **方案优势总结与风险规避**

*   **规避构建陷阱**：由于 Space 的 Dockerfile 内容恒定，它在初次部署后将永远处于 HF 的缓存中。后续所有更新均不触发“Building”状态，完美避开 2026 年 7 月的构建资源封锁。 [Docker SDK now marked as "Paid"](https://discuss.huggingface.co/t/docker-sdk-now-marked-as-paid-when-creating-a-new-space/177580)
*   **版本绝对锁定**：通过自建镜像的 SHA256 摘要，您可以确保生产环境与本地测试环境 100% 一致。
*   **极致更新效率**：
    *   **日常代码修改**：修改 Dataset 文件 $\rightarrow$ 点击 Space 的 **Restart**（约 5-10 秒生效）。
    *   **环境工具增加**：在本地重构全栈镜像 $\rightarrow$ 推送覆盖标签 $\rightarrow$ 点击 Space 的 **Restart**。

**提示**：请确保在 Space 的 **Settings -> Variables and Secrets** 中正确配置 `HF_TOKEN` 与 `LOGIC_BUCKET_REPO`，以保证引导脚本具备拉取私有数据集的权限。 [Hugging Face Spaces Docs](https://huggingface.co/docs/hub/en/spaces-sdks-docker)

*内容由 AI 生成仅供参考*