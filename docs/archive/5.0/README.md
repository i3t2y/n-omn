---
title: OmniRoute Ultimate v5.0
emoji: 🚀
colorFrom: blue
colorTo: indigo
sdk: docker
pinned: false
license: mit
app_port: 7860
---

# OmniRoute 3.8.43 终极优化版 v5.0

> 基于 130 条核心优点提炼 + 生产日志实证的最终部署方案

## 架构概览

```
客户端 → Gate.js (7860) → OmniRoute 3.8.43 (20128) → NVIDIA NIM 官方端点
         ↓ PSK 认证        ↓ 内部 API Key 替换    ↑ 直连（无 Relay）
```

## 核心特性

### 安全网关 (gate.js)
- **零依赖架构**：纯 Node.js `http`/`fs`/`crypto` 内置模块，无 express/better-sqlite3
- **timing-safe PSK 比较**：常量时间比较，防时序侧信道攻击
- **PSK fail-closed**：长度 < 16 直接 FATAL exit
- **白名单暴露面**：仅 `/healthz` + `/v1/*`，其余 404
- **SSE 流式全禁超时**：大上下文压缩期间不被掐断
- **共享预算限流**：RPM 滑动窗口 + 并发计数 + 间隔 pacing

### NIM 初始化 (init-nim-keys.sh)
- **Cookie login 三重安全网**：接受 200/201 + exit 1 硬失败 + grep auth_token 验证
- **Key 幂等注册**：409 跳过已存在 key，可安全重复执行
- **Resilience 白名单投影**：仅含 requestQueue 字段，无猜测字段
- **FIX-1 Settings 清除**：proxyUrl=null/proxyEnabled=false/relayBackend=null
- **ProxyFetch 三重防御**：R2 路径切换 + FIX-1 + purge_proxy_db SQL 兜底
- **模型分档 SSOT**：TIER_FAST/STABLE/RESTRICTED 三档 + NIM_PROFILE 控制

### 基础设施 (Dockerfile / entrypoint.sh)
- **镜像 Tag+Digest 双写锁定**：3.8.43@sha256:517c... 禁止浮动 latest
- **Litestream v0.5.9**：R2 路径切换 omniroute-v3（根源消除 ProxyFetch）
- **原子 restore**：先恢复到临时路径，quick_check 后原子 mv
- **PID 1 进程监督**：监控 OmniRoute/Gate/Litestream 三进程
- **绝对时间戳截止**：健康等待用 deadline 而非计数器

## 环境变量配置

### 必需
| 变量 | 说明 | 示例 |
|------|------|------|
| `INTERNAL_PSK` | Gate PSK（≥16 字符） | `your-psk-at-least-16-chars` |
| `NIM_KEYS` | NIM API Key（换行分隔） | `nvapi-...\nnvapi-...` |
| `INITIAL_PASSWORD` | OmniRoute 初始密码 | `your-password` |

### 可选（推荐）
| 变量 | 默认值 | 说明 |
|------|--------|------|
| `OMNIROUTE_API_KEY` | - | env-bypass 模式（跳过 .or-api-key 等待） |
| `NIM_PROFILE` | balanced | fast/balanced/full |
| `NIM_RPM_LIMIT` | 28 | 保守 RPM（NIM 免费层最优） |
| `NIM_CONCURRENT_LIMIT` | 1 | 并发数 |
| `NIM_MIN_INTERVAL_MS` | 2200 | 请求间隔 ms |
| `NIM_PROBE` | 0 | 模型探针（1=启用） |
| `CONTEXT_LENGTH_DEFAULT` | 128000 | 模型上下文长度 |
| `NIM_MODE` | NORMAL | DEBUG 时 tee 日志到文件 |
| `STRICT_VERSION_LOCK` | 0 | 版本不一致时是否 FATAL |

### R2 备份（可选）
| 变量 | 说明 |
|------|------|
| `R2_ACCESS_KEY_ID` | Cloudflare R2 Access Key |
| `R2_SECRET_ACCESS_KEY` | Cloudflare R2 Secret Key |
| `R2_ACCOUNT_ID` | Cloudflare Account ID |
| `R2_BUCKET` | R2 Bucket 名称 |

### HF Dataset 快照（可选）
| 变量 | 说明 |
|------|------|
| `HF_DATASET_REPO` | HF Dataset 仓库（如 user/repo-name） |
| `HF_TOKEN` | HF Token（用于 API commit） |

## 生产验证

v4.3.1 存档版经 New 10.txt 生产验证：
- ✅ 25 Key 注册 0 failed
- ✅ 请求 100% 成功（零 503/abort）
- ✅ ProxyFetch 噪声存在但不影响功能（direct fallback 正常）

## 文件清单

| 文件 | 行数 | 职责 |
|------|------|------|
| `Dockerfile` | ~55 | 镜像构建，pin 3.8.43 |
| `entrypoint.sh` | ~170 | PID 监督 + Litestream + Gate 启动 |
| `gate.js` | ~280 | 零依赖安全网关 |
| `init-nim-keys.sh` | ~580 | NIM 初始化主脚本 |
| `litestream.yml` | ~16 | SQLite→R2 配置 |
| `package.json` | ~12 | 元数据（gate.js 零依赖） |
| `README.md` | - | 本文档 |

## 版本历史

- **v5.0** (当前) - 终极优化版：整合 130 条优点 + 全部生产验证
- **v4.3.1** - 存档版：New 10.txt 验证 100% 成功
- **v4.3.0** - 候选版：Resilience 白名单 + 读回验证
- **v4.2.3** - 基线版：27h 生产运行实证
