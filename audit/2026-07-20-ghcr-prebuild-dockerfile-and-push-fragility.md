# GHCR 预构建实装 + push 大 layer 续传护理 (2026-07-20)

> K3 收口后轮 task #36: GHCR 预构建实装 (升级前置, 非执行升级本身)。
> 三层解耦环境层依赖 GHCR `ghcr.io/i3t2y/omniroute-base:${version}`; HF Space repo Dockerfile `FROM ${BASE_IMAGE}` 走该镜像。
> 半自动契约: 检测/构建/告警全自动 (零 HF build 队列接触), factory rebuild 永远人工触发 (task #3 runbook)。

## 关键事实 (本任务不动生产)

- **生产无变化**: 任务安全。HF Space `nonoke/omn` runtime 仍 `stage: RUNNING` + `cpu-basic`, BASE_IMAGE 仍指 `:stable` (= 上游 3.8.43 base 9c9aecf, 未动)。
- **GHCR 现 tag 列表**: `["stable", "3.8.48"]` — `:stable` 原, `:3.8.48` 本轮新推。
- **首次 upgrade 触发须人工**: 升级 = 改 SPACE Variable `BASE_IMAGE` 至 `:3.8.48` + factory_reboot=True (走 task #3 runbook), 非本任务。

## 实装产物 (审计前未实现, 审计后实装通)

### 1. 新建 `~/omn-ops/ghcr/Dockerfile` (环境层预构建镜像 — 之前不存在)

`upstream_check.sh` 预构建段原全注释 (`prebuilt="未实现"`); 取消注释直接跑 → build 找 Dockerfile 死 → 必先建。

**职责边界** (三层解耦):
- 环境层 (本镜像): 仅装 "上游镜像 + 运行前置依赖 + 跨版防御 env + /data 软链 + HEALTHCHECK"。
- **不 COPY** gate.js / entrypoint.sh / init / litestream.yml / bootstrap.sh (逻辑层, 走 HF repo build 时 COPY)。
- HF Space repo Dockerfile `FROM ${BASE_IMAGE}` + `COPY bootstrap.sh` — bootstrap 是逻辑层, build 时 COPY, 不进环境层镜像。

**上游 stuffing 关键 (规避 ENTRYPOINT 漂移损坏)**:
- 上游 Dockerfile (3.8.43 / 3.8.48 逐字一致) 自带 `ENTRYPOINT ["/tmp/check-permissions.sh"]` + `CMD ["node","dev/run-standalone.mjs"]`。
- 本镜像**不写** ENTRYPOINT/CMD — 留上游 ENTRYPOINT 应急 (若 BASE_IMAGE 直指上游官方 tag 也能起, 不依赖自建镜像)。
- 实际覆盖动作交给 HF repo Dockerfile `ENTRYPOINT ["/bootstrap.sh"]` (那句在 build 时盖掉上游 ENTRYPOINT)。

**build args 透传 (buildx linter 陷阱)**:
- 初写双 ARG `UPSTREAM_TAG=${tag}` + `UPSTREAM_DIGEST=${digest}` + `FROM image:${UPSTREAM_TAG}@${UPSTREAM_DIGEST}`。
- buildx linter 报 `ERROR: failed to parse stage name ...: invalid checksum digest length` (双 ARG 透传 FROM 预解析空)。
- 改合一 ARG `UPSTREAM_REF=tag@digest` + `FROM image:${UPSTREAM_REF}` — 同 `candidate-v4.3/Dockerfile L7` inline 写法, linter 接受 (warning InvalidDefaultArgInFrom 不阻断, 仅 lint口水)。

### 2. litestream asset 拉取死锁 — COPY 替 runtime curl

初 Dockerfile step 7:
```dockerfile
RUN curl -fsSL "https://github.com/benbjohnson/litestream/releases/download/v0.5.9/litestream-0.5.9-linux-x86_64.tar.gz" | tar -xz ...
```

**死锁实情**:
- buildkit 容器内 curl 拉 github release assets → 302 重定向至 `release-assets.githubusercontent.com` CDN。
- buildkit 容器内 DNS/路由该 CDN 慢或断 → curl `/proc/<pid>/io` **无 io 进度** 但进程活 (僵尸态占表)。
- release SAS token (URL `se=` 参数) 短期过期 (今日 UTC 17:13:38) → curl 无超时 → 永久阻塞。
- 实测 20min 仍卡 step 7; host 直拉同 URL 仅 7.3s。

**修法 (绕 buildkit 容器内 CDN DNS 死锁)**:
1. host 端预拉 tar (本 Dockerfile build 时间窗内, SAS 未过) 落 `~/omn-ops/ghcr/litestream-0.5.9-linux-x86_64.tar.gz` (13MB)。
2. Dockerfile `COPY litestream-{ver}-linux-x86_64.tar.gz /tmp/litestream.tar.gz` + RUN 解包 + `litestream version` 自验。
- buildkit 仅做层解 tar, 隔离网络依赖, 消除 runtime curl 死锁。
- 重跑 build → 秒过 (3.3s export manifest, 用本地 build cache + COPY)。

### 3. push 大 layer TLS closed connection 续传护理

**实测痛点**:
- `docker push ghcr.io/i3t2y/omniroute-base:3.8.48` 大 layer (上游 base layer + apt/pip/litestream 新 layer, 总 CONTENT 518MB, 解压前各 layer 数百 MB) 上传至 `ghcr.io` (路由 `enp2s0 192.168.123.13→20.27.177.117:443`, 物理网卡非 Tailscale)。
- 间隔数十秒 TLS `write tcp ...:->20.27.177.117:443: use of closed network connection` 断。
- 网络 NAT timeout 切 TCP 长连接 hold; 大 blob 上传未完。
- **docker push 单次无内置 retry flag** → 单次 fail 非 push 终态, registry 续传协议复用已推 layer, 循环 push 必推完。

**实测 push 续传序列**:
- attempt 1: 4 layer (d8662235355d / fba79423b311 / f926ea657df1 / c78a14b89b67) push 成, 65ebb89785e1 断。
- attempt 2: 65ebb89785e1 断 (新连接)。
- attempt 3: 65ebb89785e1 push 成 (剩上轮已推层 `Layer already exists`), 26e094877892 断。
- attempt 4: 65ebb89785e1 已 `Layer already exists`, 26e094877892 push 成 + 末 layer → manifest 上传 `digest: sha256:da99fac1a697022a0529805294c58a10923fc1c758616f4f0b2ea8428b0f408f` 全成。

**脚本修法 (循环 push + 双保险验 manifest)**:
```bash
push_ok=0
for i in $(seq 1 8); do
  if docker push "${GHCR_IMAGE}:${latest}" >/dev/null 2>&1; then
    push_ok=1; break   # docker push exit 0 ≈ 全 layer 推完 + manifest 成
  fi
  sleep 3              # 单次 fail 非 0 — 部分 layer 已推 (TLS 断半), 续传重试
done
# 尾查 manifest 真 HTTP 200 (双保险: push exit 0 亦不可见 manifest 已寄存)
for i in $(seq 1 3); do
  ... /v2/${repo}/manifests/${latest} HTTP 200 → manifest_ok=1; break
done
[ "$push_ok" = "1" ] || [ "$manifest_ok" = "1" ] → prebuilt="✓ 已就绪"
```

## 实测终态 (2026-07-20)

| 项 | 值 |
|----|----|
| GHCR 镜像 | `ghcr.io/i3t2y/omniroute-base:3.8.48` |
| digest | `sha256:da99fac1a697022a0529805294c58a10923fc1c758616f4f0b2ea8428b0f408f` |
| 镜像 CONTENT | 518MB |
| 镜像 DISK (解压) | 2.63GB |
| manifests HTTP | **200** |
| tags list | `["stable", "3.8.48"]` |
| build 耗时 | ~3s 本地 cache hit (COPY litestream tar, 无 runtime curl) |
| push 耗时 | 4 attempt (实测网络限速) |
| 上游 tag→digest 双锁 | `UPSTREAM_REF=3.8.48@sha256:badb560971fdc23c2fb84b3e8695116239ff215b4cca4b07076201a8efae7f0d` (上游 Docker Hub manifest digest) |
| 上游 3.8.43 vs 3.8.48 Dockerfile 契约 | 逐字一致 (FROM/ENV/ENTRYPOINT/USER 全同), 三层无契约漂移 |
| 审批报告路径 | `~/omn-ops/exchange/upgrade-3.8.48-20260719.txt` 已推 Win11 |

## 上游 Dockerfile 契约 (3.8.43/48 逐字一致, 漂移检测零触发)

```
FROM node:24-trixie-slim AS base
FROM base AS builder
FROM base AS runner-base
ENV PORT=20128
ENV HOSTNAME=0.0.0.0
ENV DATA_DIR=/app/data
USER node
ENTRYPOINT ["/tmp/check-permissions.sh"]
CMD ["node", "dev/run-standalone.mjs"]
FROM runner-base AS runner-web
USER root
USER node
FROM runner-base AS runner-cli
USER root
USER node
```

## 不动项 (K3 红线延续)

- **BASE_IMAGE Space Variable**: 仍 `:stable` (= 3.8.43 base 9c9aecf), 改 `:3.8.48` 是首次 upgrade 人工动作 (task #3 runbook), 非本任务。
- **factory_reboot**: 永远人工触发, 脚本不触 HF build 队列 (7/16 HF 免费层 build 冻教训)。
- **逻辑层 5 文件** (entrypoint / gate / init / litestream.yml / package.json): 不动, 走 Dataset loading, 不进环境层镜像。
- **sync-interval / gate 限流 / auto-recover**: litestream.yml 红线延续未动 (task #34 l0-retention 5m 单推, levels 未碰)。

## 下一步 (非本任务)

1. **3.8.48/49 合并升级**: GHCR :3.8.48 预构建就绪 → 待 K3 意见回收后人工跑 `space_ctl.py upgrade 3.8.48 ghcr.io/i3t2y/omniroute-base:3.8.48` (factory_reboot=True, 首次 upgrade 实操, 验 task #3 runbook HF_TOKEN Space write scope 真兑现, 替 litestream task #34 偶然跨通的 DATASET_WRITE scope 非固化)。
2. **Class A 24h 回测**: litestream l0-retention 5m 推后跑 24h R2 Class A 计量二次校准 (task #34 待回测)。

---

*2026-07-20 · task #36 GHCR 预构建实装 · source: ~/omn-ops/ghcr/Dockerfile (新) + upstream_check.sh push retry 段改写 · push 4 attempt 实测续传成 · 生产无变化零触 HF 队列*
