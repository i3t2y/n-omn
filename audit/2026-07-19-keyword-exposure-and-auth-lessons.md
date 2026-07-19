# 4 audit 三则归档 (2026-07-19)

> K3 收口轮任务 4: 三则审计归档 —
> (a) whoami 教训: fine-grained token 无身份基座 scope, 单点 whoami 失败 ≠ token 失效
> (b) HF_TOKEN_DATASET_WRITE 实测可读 Space variables: fine-grained 实际授权面比名义 scope 宽
> (c) 关键词暴露面表 + 任务 1a/1b 处置结果

---

## (a) whoami 教训

### 事件

K3 收口前轮一度误判 `HF_TOKEN` (fine-grained, Space scope) **失效**, 基于 `curl /api/whoami-v2` 单点返 403。
推论走偏: 误以为升级环管理臂断肢, 欲启 E1 token 轮换。

### 根因

`/api/whoami-v2` 端点需 **user identity scope** (fine-grained token 不暴露身份基座端点)。
fine-grained token 默认只授权**资源级** scope (Space/Dataset/Repo 视选勾), **不暴露账户级** identity 端点。
单点 whoami 403 是**权限范围设计意图**, 非 token 失效信号。

### 教训提炼: 判活三原则

1. **三端点实证**: token 判活须 ≥3 个独立资源级端点实证 (e.g. `get_space_runtime` + `get_space_variables` + `space_ctl.py status`), 单点 != 失效
2. **API 方法链核查**: 每端点须核对应调 HTTP 方法 + scope (GET 不耗 write quota, POST/PUT 才验 write scope)
3. **平台行为 vs 设计依据**: 平台对 fine-grained 的实际授权面可能与名义 scope 不对应 (见(b)), **平台行为不可作设计依据** — 设计依据须按名义 scope + 文档保守取

### 处置

- E1 token 轮换**取消** (用户裁决 verbatim): "HF_TOKEN（fine-grained, Space scope）存活：whoami 失效是权限范围设计, E1 轮换已取消, 禁止再提轮换."
- 实证: `get_space_runtime` 返 RUNNING + hardware cpu-basic ✓
- 实证: `get_space_variables` 返 13 个 Space Variables ✓
- 实证: `space_ctl.py status` rc=0 ✓

---

## (b) HF_TOKEN_DATASET_WRITE 实测可读 Space variables

### 事件

验收 K3 任务 1b (中性化 Deployment commit 8be683d 后 Space 普通 Restart + 拉启动日志验中性化生效) 时,
用 `HF_TOKEN_DATASET_WRITE` (fine-grained, 仅 Dataset write scope 名义) 拉 `logs/run` 流成。
旁证: 后续多次调 `get_space_runtime` / `get_space_variables` 全通, 用同 token。

### 观察

fine-grained token 名义 scope "Dataset write" 实际 **能读 Space variables + Space runtime + logs/run**。
实际授权面比名义 scope 宽 — **疑带账户级 read 基座** (fine-grained 不暴露 whoami 但仍允许跨资源 read)。

### 钉死原则 (设计依据)

平台行为**不可作设计依据**. 两 token 仍坚持**不重叠**原则:
- `HF_TOKEN` (本地 ~/.omn-secrets): Space write — 升级环管理臂 (`restart_space` / `add_space_variable`)
- `HF_TOKEN_DATASET_WRITE` (本地 ~/.omn-secrets): Dataset write — Dataset 源推送 (`upload_folder` 逻辑层 5 文件)

两 token 互不借用互不替代, 各按名义 scope 部署, 即使实测某 token 侥幸跨通, 设计层仍按名义 scope 用。

### 教训

**规避 "DATASET_WRITE 恰好也能读 Space" 写成指引**: 偶然性平台行为不固化成 SOP, 否则平台收紧时跨通断了, 依赖跨通的流程同时崩。

---

## (c) 关键词暴露面表 + 任务 1a/1b 处置结果

### 暴露面五点 (基础)

| 点位 | 当前暴露 | 命名属 | 处置 |
|------|---------|--------|------|
| 1. Dataset 源码 (nonoke/omni-logic) | `OmniRoute` / `omniroute` 字样出现 | 品牌展示 | **1b 中性化** (commit 8be683d) |
| 2. 运行日志 (Space logs/run) | `OmniRoute` 进程名 / 启动字串 | 品牌展示 | **1b 中性化** (entrypoint-merged.sh / init / gate / package.json 4 文件) |
| 3. Dockerfile ARG 行 (Space repo) | `BASE_IMAGE = ghcr.io/i3t2y/omniroute-base:stable` | 镜像名, 非 Dataset 源 | **1c 归档候选** (待 3.8.49 便车改) |
| 4. GHCR 包页 | `ghcr.io/i3t2y/omniroute-base` | 镜像名 | **1c 归档候选** (GHCR 包注册名, 须新包 push) |
| 5. gate fail-closed 404 | 后台关 + 404 兜底 / API 路径 | 不暴露 | 无须处置 (fail-closed 设计已隐) |

### 任务 1a 处置结果: Dataset 可见性

- **核查方法**: HF API `curl /api/datasets/nonoke/omni-logic` 读 `private` 字段
- **结果**: 返 `private: True` — 已 private, 跳过改
- **bootstrap _dl() 验**: Space 普通 Restart (任务 1b 步) 后 R2 恢复成 + entrypoint 启动成 → bootstrap _dl() 拉 Dataset 通, private 不影响内部读
- **结论**: 1a 已闭环 (已 private 无须动)

### 任务 1b 处置结果: 日志字符串中性化

#### 改前 → 改后 (品牌字样 → 中性词)

| 文件 | 行 | 改前 | 改后 |
|------|----|------|------|
| entrypoint-merged.sh | L2 | `# OmniRoute 进程编排总控` | `# 进程编排总控` |
| entrypoint-merged.sh | L26 | `echo "[entrypoint] OmniRoute 启动"` | `echo "[entrypoint] 上游服务启动"` |
| entrypoint-merged.sh | L167 | `# ── 2. 启动 OmniRoute ──` | `# ── 2. 启动上游服务 ──` |
| entrypoint-merged.sh | L178 | `✗ OmniRoute 已退出` | `✗ 上游服务已退出` |
| init-nim-keys-v2.sh | L2 | `# OmniRoute NIM 初始化 · 完整自包含版` | `# NIM 初始化 · 完整自包含版` |
| init-nim-keys-v2.sh | L37 | `log "✓ OmniRoute 健康"` | `log "✓ 上游服务健康"` |
| gate.v43-merged.js | L1 | `// OmniRoute Gate · 零依赖版` | `// Gate · 零依赖版` |
| gate.v43-merged.js | L46 | `const ADMIN_REALM = 'OmniRoute Admin';` | `const ADMIN_REALM = 'Admin';` |
| package.json | L2 | `"name": "omniroute-gate"` | `"name": "gate"` |
| package.json | L5 | `前置于 OmniRoute (HF Space :7860 -> :20128)` | `前置于上游服务 (HF Space :7860 -> :20128)` |
| litestream.yml | - | (审计前已无字样) | 不动 |

#### 红线保留 (功能性字符串不改, 审计前已列)

| 类 | 实例 | 留因 |
|----|------|------|
| env 键名 | `OMNIROUTE_PORT` / `OMNIROUTE_API_KEY` | env 键是 Space Secrets 契约, 改名须同改 Space Settings, 不属本轮收口 |
| API 路径 | `/api/auth/login` / `/api/monitoring/health` / `/api/providers` | 上游路由功能性, 改了 init/gate 调不通 |
| litestream.yml 字段 | `dbs[].path` / `sync-interval` / `auto-recover` | litestream v0.5.9 schema 字段名, 不属源码可控 |
| 版本探测 | `EXPECTED_VERSION` 比对来源 | 改了 entrypoint 版本校验逻辑崩 |
| flock 文件名 | `$DATA_DIR/.omniroute.lock` | 文件名非品牌展示用 (运行时锁, 日志中只 1 次出现), 改了须保证与旧实例锁不冲突, 保守留 |
| URL 上游仓 | `github.com/diegosouzapw/OmniRoute/wiki` | URL 路由功能性 (注释中加 "注: 上游仓库名保留不改") |

#### 推送

- **方法**: `huggingface_hub.upload_folder` 单 commit (HF 7/16 build freeze 规避: <8 次/h)
- **commit**: `8be683d27c960f64c2d7cdc4902a256cde5ec1e8` 推 nonoke/omni-logic
- **同源验**: HF remote 5 文件 md5 与本地一致; 残留扫匹配本地 (entrypoint 5 / init 2 / gate 2 / package 0 全功能红线项)
- **Space 普通 Restart**: `restart_space(factory_reboot=False)` → 36s 转 RUNNING (零 build 队列触感, 零 factory rebuild)

### 启动日志验收 (task 1b 终态实证, logs/run 关键行)

| 验收项 | 证据 | 结果 |
|--------|------|------|
| 新启动日志无 OmniRoute 品牌字样 | grep `omniroute` 仅 1 hit = `.omniroute.lock` (flock 文件名, 非品牌展示) | ✓ |
| 四子进程全绿 | `[entrypoint] 上游服务 PID=657` + `✓就绪` / `Init PID=695` nim-01~08 ✓ / `Litestream PID=696 replicating` / `gate PID=697 :7860` | ✓ |
| 8 NIM keys 注册通 | `Keys: 8 注册 / 0 跳过 / 0 失败` + `nvidia 连接数 (读回): 8` | ✓ |
| litestream snapshot 正常 | `replicating to type=s3 sync-interval=10s bucket=omn-data` + `compaction complete level=1/2` | ✓ |

### 旁证发现

litestream v0.5.9 监控间隔**实跑非 audit 估** — 7.5h 长跑文档假设 L1=30s 单级,
实跑 logs/run 显多级:
- L0 retention monitor: `interval=15s retention=5m0s`
- compaction monitor level=1: `interval=30s`
- compaction monitor level=2: `interval=5m0s` ← **未知曾估**
- compaction monitor level=3: `interval=1h0m0s`
- compaction monitor level=9: `interval=1h0m0s` ← **未知曾估**

详见 `audit/2026-07-19-litestream-monitor-intervals.md` task 2 核查 (注意该文档估算表需以此实跑多级数据二次校准).

---

## 闭环状态

| 任务 | 状态 | 产物 |
|------|------|------|
| 1a Dataset private | ✅ 已 private, 跳过 | (audit 此则记) |
| 1b 中性化 | ✅ commit 8be683d + Restart 36s RUNNING + 日志验收全绿 | (audit 此则记) |
| 1c 镜像改名候选 | ✅ 归档 | `audit/2026-07-19-image-rename-candidate.md` |
| 2 litestream 核查 | ✅ 只读核查 | `audit/2026-07-19-litestream-monitor-intervals.md` |
| 3 upgrade 写权限预案 | ✅ 文档化不执行 | `audit/2026-07-19-first-upgrade-write-permission-runbook.md` |
| 4 三则归档 | ✅ 此则 | 本文件 |

---

*2026-07-19 收口轮 · task 4 归档完毕*
