> ⚠️ **本文件为 candidate-v4.3.2 时代快照，已过期。** 生产事实以 `HANDOFF.md`（架构/不变量/排障入口）与 `ops/STATUS.md`（当前部署=commit、Space）为准。
> 现役唯一生产 Space = **`xnexus/o`**（非 `nomke/omn` / `nonoke/omn`）；基础镜像现役为 `ghcr.io/i3t2y/omn-base:stable`（下文第 5 行所述 `diegosouzapw/omniroute:3.8.43` 仅对候选版准确）。env 键 `OMNIROUTE_*` 经 CLAUDE.md §1 例外保留，详见该条。
>
# OmniRoute × NVIDIA NIM 网关 — 文档入口

## 候选版说明

> 候选版部署实例。基础镜像 `diegosouzapw/omniroute:3.8.43` 钉死。
> 生产：HF Space [`nomke/omn`](https://huggingface.co/spaces/nomke/omn)（`https://nomke-omn.hf.space`）。
> 部署链路：本地 → `nomn/main`(github.com/i3t2y/n-omn) → Actions `sync-to-hf-space.yml` → `git push --force` 到 HF `nomke/omn` → 重建上线。

仓库根 `README.md` 仅保留 HF Space frontmatter（title/emoji/sdk/app_port=7860 等），正文技术内容（架构、配置 Secrets、默认值与 fail-closed、后台访问、三类入口、测试、回退）集中在本文档。

---

## 活跃文档

| 文档 | 用途 |
|------|------|
| [readme4.2.3.md](readme4.2.3.md) | **快速部署**：核心事实、环境变量、三 combo 分工、客户端接入、运维排查（v4.2.3 收拢版） |
| [DEPLOYMENT_GUIDE.md](DEPLOYMENT_GUIDE.md) | **深度部署**：三段式架构、三大技术坑位（含 v4.2.3 粘名 bug）、完整 env 清单、combo 架构、升级路径 |
| [CHANGELOG.md](CHANGELOG.md) | **变更日志**：v4.1.0 → v4.2.3 全部版本演进 |
| [nim_context_probe.sh](nim_context_probe.sh) | **工具**：NIM 真实上下文截断点实测（直连绕过 gate），用于标定 `real_context` |

## r4 改名批勘注（2026-07-22/23, 首席令 omni-logic→omn-logic）

> 非品牌 `omni-*` 全清为 `omn-*`；**OMNIROUTE 品牌 env 键经 CLAUDE.md §1 例外保留, 不动**(现役 dev/logic 共 16 处: `OMNIROUTE_API_KEY`×6 / `OMNIROUTE_PORT`×9 / `OMNIROUTE_RELAY_BACKEND`×1, 后者为上游 unset 契约)。candidate-v4.3.2-staging/init-nim-keys.sh 曾按此规则处理(sha `4cbcc50120ec` 995L)。

| 改名前 → 后 | 位置 | 风险 |
|------|------|------|
| `/data/omni-data/log` → `/data/omn-data/log` | init 行21 | HF 持久卷子目录 mkdir 自建, 不动卷挂载; DEBUG 日志新入新目录, 旧留旧目录不丢 |
| `/tmp/omni-snapshot` → `/tmp/omn-snapshot` | init 行851 | 会话临时目录, 改名零风险 |
| `path_in_repo="omni_data"` → `"omn_data"` | init 行935 | HF 新仓 path_in_repo 坐标 |
| `Sync omni_data` → `Sync omn_data` | init 行937 | commit message 文本 |
| env 键 `HF_DATASET_REPO` → `OMN_DATASET_REPO` | init 行849 guard/936 upload_folder | 主动改键干净切断隐性 Secret 依赖, 比留旧键改值可靠; = init 写 omn_data 快照的 Dataset repo 键, 与 bootstrap 拉逻辑层 `LOGIC_BUCKET_REPO` 两独立 Secret |

**推送前剩余闭环（首席侧联网两项）**:
- **Space Secrets 设 `OMN_DATASET_REPO = nonoke/omn-logic`** + 确认 HF_TOKEN 有值（否则 init 行849 guard 空 → 静默 return 0, omn_data 快照上传链踏空, 同旧 HF_DATASET_REPO 踏空根因）。运维配置非代码。
- **Space 健康**：`https://nonoke-omn.hf.space` 是否 RUNNING → 判新仓旧 init 拉起状态。

**阻断核验已闭环（详见合并稿附录 A2）**:
- **A 阻断（HF 新仓 omni_data/ stray）解除**：`hf download nonoke/omn-logic` 拉新仓全树 → 根目录 8 文件 flat 树，**无 omni_data/ 也无 omn_data/ 目录** → 旧 init restart 未向新仓写 stray 目录, 无删/合并动作。
- **B 阻断（全仓 `omni-logic` 字面仓名）解除**：staging/ + upstream 双树 + candidate-v4.3-reviewed 三处全零命中, `omni-logic` 仅 init 内 env 键引用点（r4 已改名）, 无运行时别处硬编码。
- **package.json 归属（Step0.3）**：新仓 `nonoke/omn-logic/package.json` 存在 = gate 描述件（name:gate v2.0.0 零依赖 PSK 双通道），现役部署件保留新仓根入镜像, 推 r4 四件**不覆盖** package.json（远端已留）。

**不改（冻结纪律守住）**: audit/ 历史归档（冻结令前真源事实记录）+ 现役 `candidate-v4.3-reviewed/`（行18 `/data/omni-data/log`+行714/801 `HF_DATASET_REPO` 冻结禁改, 解冻后 staging→candidate 收敛时同步）。

## 7 个核心文件（仓库根目录）

`init-nim-keys.sh` · `Dockerfile` · `entrypoint.sh` · `gate.js` · `litestream.yml` · `package.json` · `README.md`
（`.github/workflows/sync-to-hf-space.yml` 白名单同步此 7 个文件到 HF，**其余文件不部署**）

---

## 架构

```
公网 :7860  ─►  gate.js (PSK + admin Basic Auth + SSE 透传)  ─►  127.0.0.1:20128  OmniRoute (Next.js)
                     │                                                  │
                     │ /healthz 免认证                                    │ SQLite /data/storage.sqlite
                     │ /v1,/v1/* PSK (INTERNAL_PSK) → 替 OR_API_KEY      │
                     │ 后台白名单 Basic Auth (GATE_ADMIN_TOKEN)            │
                     └ 无第二套限流 (28/1/2200ms 在 OmniRoute requestQueue)  └─ Litestream → R2
```

唯一出口代理直连 OmniRoute, **无外部 Relay / cf-worker / context-relay**

## 配置 (HF Space Secrets)

| Secret | 必需 | 用途 | 默认 |
|--------|------|------|------|
| `INTERNAL_PSK` | 是 (≥16 chars) | /v1 推理请求鉴权 (Gate 入口, Bearer PSK) | fail-closed |
| `JWT_SECRET`, `API_KEY_SECRET`, `INITIAL_PASSWORD`, `OMNIROUTE_API_KEY` | 是 (OmniRoute 内部) | OmniRoute 自身认证 | — |
| `NIM_KEYS` | 是 | NVIDIA NIM API keys (换行分隔) | — |
| `R2_ACCESS_KEY_ID`, `R2_SECRET_ACCESS_KEY`, `R2_ACCOUNT_ID` | 否 | R2 备份; 缺失则复制非致命降级 | 跳过 |
| `GATE_ADMIN_TOKEN` | 否 (≥16 chars) | **后台访问开关兼 Basic Auth 密码**; 留空/过短 → 后台关闭 (全 404) | 不设=关 |
| `LITESTREAM_STRICT` | 否 (默认 1) | 复制失败严格(exit)/非致命(warn)| 1 (严格) |
| `HF_TOKEN`, `HF_DATASET_REPO` | 否 | 配置快照上传 Dataset | 跳过 |
| `GATE_UPSTREAM_TIMEOUT_MS` | 否 (30000) | 上游超时 | 30000 |

## 默认值与 fail-closed 行为

- **PSK 缺失/过短 (<16)**: gate.js 启动 `process.exit(1)` (fail-closed).
- **OR_API_KEY 缺失** (env 和 `/data/.or-api-key` 均无): gate.js `exit(1)`.
- **GATE_ADMIN_TOKEN 未设/空/过短**: **后台关闭**, 后台路径全 404 (不泄露后台存在); 有 OmniRoute Cookie/Session 仍 404.
- **GATE_ADMIN_TOKEN 设有效值 (≥16)**: **后台开启**, 白名单路径经 HTTP Basic Auth (用户名 `admin`, 密码=token) 放行; 非白名单仍 404; `/_next/*`, public 静态资源免 admin token (仅须开关开).
- **LiteStream restore**: 本地 DB 存在且非空 → 跳过 (绝不覆盖); 临时路径恢复 + post `PRAGMA quick_check`; 失败按 `LITESTREAM_STRICT` 严格 exit / 非致命 warn.
- **Debug Dataset 日志上传**: **默认关闭** (`NIM_DEBUG_LOG_TO_DATASET=1` 开启); 开启时上传前字段级脱敏 Authorization/NIM_KEY/Cookie/Bearer → `<REDACTED>`.
- **限流**: 固定 28 RPM / 1 并发 / 2200ms, 仅写 OmniRoute `requestQueue`; Gate 不重复限流 (零限流代码).
- **Resilience `useUpstream429BreakerHints=false`** (保守默认; NIM direct-cloud 分支实例未证).
- **自动 Context Override**: **默认关闭**; 启用须经 API `PATCH /api/provider-models` 的 `max_input_tokens`/`max_output_tokens` + 读回 (见 KNOWN-UNVERIFIED).

## 后台访问 (GATE_ADMIN_TOKEN) — 扩大公网暴露面

**默认关闭** (不设 `GATE_ADMIN_TOKEN`). **设置该变量会扩大公网暴露面**:
- 开启后, 后台白名单页面 (登录、看板、文档、静态资源) + 只读管理 API 可经 Basic Auth 访问.
- 后台仍**受 OmniRoute 自身认证约束** (登录/Session/Cookie 保留), Gate 仅控可达性, 不替代/OmniRoute 鉴权.
- **无 IP/CIDR 限制**: HF 平台代理拓扑未验证, 暂不实现 (见 KNOWN-UNVERIFIED); 不得声称有 IP 防护.
- **建议**: 仅在维护窗口临时配置强随机 token (≥16 chars), 使用后删除该 Secret 即恢复仅 API 暴露模式.
- 禁止能力: restart/shutdown/任意执行/插件安装/通配 `/api/*` 默认不开放; 写操作 (POST/PATCH/PUT/DELETE) 默认不在白名单 (见 KNOWN-UNVERIFIED).

## 三类入口分离

| 路径 | 方法 | 认证 |
|------|------|------|
| `/healthz` | GET | 免认证 |
| `/v1`, `/v1/*` | 任意 (SSE 透传) | `INTERNAL_PSK` (Bearer) |
| 后台白名单页面/静态 | GET | `GATE_ADMIN_TOKEN` (Basic Auth; 静态免) |
| 只读 `/api/*` 白名单 | GET | `GATE_ADMIN_TOKEN` (Basic Auth) |
| 其他 | 任意 | 404 |

`INTERNAL_PSK` 与 `GATE_ADMIN_TOKEN` **用途隔离**, 不得互相回退.

## 测试

见 TESTING.md. candidate 内 tests/ 完整 (路径矩阵、PSK、Basic Auth、SSE 真流式、信号、LiteStream、幂等、残留扫描).

## 回退

见 ROLLBACK.md. 删除 `GATE_ADMIN_TOKEN` + 重启即关闭后台 (仅 API 暴露).

---

## v4.2.3 核心改动（vs v4.2.2 生产，历史留存）

1. **`models_to_json` 粘名 bug 修复**：`printf '%s'` → `'%s\n'`。旧版多模型参数粘成单串（如 3 模型 → 一个 `nvidia/a/b/c` 垃圾对象），combo 建成 201 但调用全 400。修复后 nim-pool/nim-codex 多模型 round-robin 复活。
2. **DEBUG log 上传 Dataset（·⑨）**：`NIM_DEBUG_LOG_TO_DATASET`(默认 1) + `NIM_DEBUG_LOG_KEEP`(默认 5)，DEBUG 模式 `init_*.log` 拷为 `debug_*.log` 随 `hf_snapshot` 上传 HF Dataset。

---

## 归档（`archive/`）

旧版本设计稿、历史快照、`nog` 项目（另一远端线 `i3t2y/nog`）文档已归档，仅作历史参考，**不再维护**：

- 旧版本研究：`4.1.0.md`、`n-omn-4.2.md`、`3.8.0.txt`
- 历史快照：`CURRENT_STATE_v3.8.md`、`RELEASE_NOTES_v1.0.0.md`、`VALIDATION.md`、`audit-report.md`、`implementation-log.md`
- nog 项目文档：`CHANGELOG.md`、`AI_HANDOFF.md`、`DECISIONS.md`、`EXPERIENCE.md`、`TROUBLESHOOTING.md`
- 事件复盘：`DEGRADED_POSTMORTEM.md`、`DEGRADED分析.md`、`Deep Research OmniRoute.md`
- 规划稿：`superpowers/plans/`、`superpowers/specs/`
- 旧工具：`check_restricted.sh`

详见 [`archive/`](archive/).

---

## 0 号重排批（2026-07-23, Supreme 四项拍板）

> 0 号批 = 仓目录重排, 窗内纯本地 (mkdir/mv/cp + commit), 严禁任何 HF/Space 网络操作, 严禁 push。所有移动零内容改写, sha 前后复验为证; 唯一新增文件 = 无。Supreme 四项拍板 (2026-07-23 00:30Z 签发): ①本地镜像目录定名 `omn-logic/` ≡ HF `nonoke/omn-logic` 数据集根; ②`patches/p0/` 保留至 R3; ③`omn-logic/` 内用部署名 `entrypoint.sh`; ④立即执行。

### 部署契约重申

- **`omn-logic/` ≡ 数据集根镜像**: 本地 `omn-logic/` 五件 = 推送时镜像覆写 HF `nonoke/omn-logic` 数据集根原位的目标件。推送激活条件三全(附录 A): 窗满 03:16Z + K3 verdict 回填 + Supreme 显式下令。
- **`entrypoint-merged.sh` → `entrypoint.sh` 命名由来**: staging 原 `entrypoint-merged.sh` (合并多段编排名) 落位 `omn-logic/` 时改用部署名 `entrypoint.sh` (与上游镜像 ENTRYPOINT 名对齐), sha 不变 (mv 改名零内容改写, `06178176`)。
- **HF 新仓现状**: flat 8 文件根 (entrypoint.sh/gate.js/init-nim-keys.sh cea2b20eac05 旧版/init-nim-keys.r2-157.bak/litestream.yml/package.json/README.md/.gitattributes), 无 omni_data/ 也无 omn_data/ 快照子目录; 现役 init = 旧版未改名 (含 HF_DATASET_REPO/omni_data), 推 r4 = 全量替换 860L→995L。package.json 已定性为部署件 (gate 描述件), 属镜像第五件, 新仓已留。
- **staging 退役处置**: `init/entrypoint` 迁入 `omn-logic/`, 五件冗余副本 (backoffAndDedup.ts/parseRetryAfter.ts/events_schema.sql = patches/p0 同 sha; gate.js/litestream.yml = omn-logic 同 sha) 经 sha/cmp 双重验证为同 sha 副本后清除, 无内容损失 (留证 `/tmp/staging-residuals-sha.txt` + 五对 cmp 全绿; r4 合并稿 fenced 全文第三重内容备份)。

### 最终目录树

```
omn-merge/
├── CLAUDE.md / README.md / .gitignore / .gitattributes / Dockerfile / ghcr-tracked-Dockerfile
├── bootstrap.sh          (cp 提根自 archive/candidate-v4.3-reviewed/d-step-staging/, 原件保留)
├── package.json          (根原件留位; omn-logic/ 副本作镜像)
├── omn-logic/            ★ 镜像源 (≡ HF nonoke/omn-logic 数据集根), 五件:
│   ├── init-nim-keys.sh
│   ├── entrypoint.sh     (← entrypoint-merged.sh 改名)
│   ├── gate.js
│   ├── litestream.yml
│   └── package.json
├── patches/p0/           (events-table + retry-after, 保留至 R3)
├── docs/                 (含 omn-v4.3.2-k3-review-20260722.md K3 审阅稿, omn-bundle, DEPLOYMENT_GUIDE)
├── audit/                (审计链 00-13 + 时序/归因)
├── upstream/             (omniroute-3.8.43 + omniroute-3.8.49 只读双树, gitlink mode 160000 — ⚠本地裸锚, .gitmodules 无 URL 配套)
├── .github/workflows/    (sync-to-hf-space.yml 部署链)
├── tools/                (merge_files.py + assemble_k3_*.sh)
└── archive/              (历史归档, 冻结; 内一切文件不准改)
    ├── root-flat-legacy/   (根旧批 + 根4.3.1/5.0/5.1 避撞名版)
    ├── candidate-v4.3-reviewed/ / baseline-4.2.3/ / 4.2.3/ / 4.3.1/ / 5.0/ / 5.1/ / cf-worker/
    └── omn-legacy/         (← 根 omn/ 整体归档: tabbit 教程 + 版本副 + n-omn-main.zip)
```

**upstream/ gitlink 已知状态(2026-07-23, 尾注补记)**: `upstream/omniroute-3.8.43`+`upstream/omniroute-3.8.49` 在本仓以 **gitlink mode 160000** 记录(commit 5c546af), `.gitmodules` **无对应 URL 配套**(`git submodule status` 报 `fatal: no submodule mapping found`)。本地审计仓只读引用无碍 — 工作树有完整上游树实体可 grep/取证; 但**若此仓日后需 push 且要他处 clone 复原上游树, gitlink 需配套 submodule URL** 或改上游树为 vendored 实体入仓。当前定性: 本地审计仓, 无 push 场景, gitlink 裸锚状态已知可接受。上游真源另存 `~/omniroute-v3.8.43@b729a8f`(本地完整 clone, 0 号批前已有)。

### omn-logic/ 五件清单与 sha

| 文件 | sha256 (前12) | 来源 |
|------|---------------|------|
| `omn-logic/init-nim-keys.sh` | `4cbcc50120ec` | mv ← `candidate-v4.3.2-staging/` (r4 改名批终版, 链 e5a26a9c→89f636b5→4cbcc50120ec, 995L) |
| `omn-logic/entrypoint.sh` | `061781764b45` | mv 改名 ← `candidate-v4.3.2-staging/entrypoint-merged.sh` (sha 不变, 263L) |
| `omn-logic/gate.js` | `616047c65b61` | cp ← `candidate-v4.3-reviewed/` (原件留位; = 根旧批 gate.js 同 sha 副本) |
| `omn-logic/litestream.yml` | `1563c08de199` | cp ← `candidate-v4.3-reviewed/` (原件留位) |
| `omn-logic/package.json` | `5ed9981bf8c3` | cp ← 根 `package.json` (根原件留位, COPY 非移动; gate 描述件 v2.0.0 零依赖 PSK) |

### 新旧路径映射表 (Step 2/3 全量 mv 记录)

| 原路径 | 新路径 | 操作 | sha |
|--------|--------|------|-----|
| `candidate-v4.3.2-staging/init-nim-keys.sh` | `omn-logic/init-nim-keys.sh` | mv | `4cbcc50120ec` |
| `candidate-v4.3.2-staging/entrypoint-merged.sh` | `omn-logic/entrypoint.sh` | mv 改名 | `061781764b45` |
| `candidate-v4.3-reviewed/gate.js` | `omn-logic/gate.js` | cp (原件留位) | `616047c65b61` |
| `candidate-v4.3-reviewed/litestream.yml` | `omn-logic/litestream.yml` | cp (原件留位) | `1563c08de199` |
| 根 `package.json` | `omn-logic/package.json` | cp (原件留位) | `5ed9981bf8c3` |
| `candidate-v4.3.2-staging/` 五件冗余副本 | (清除) | rm (同 sha 经 cmp 双验, `[ -d archive/ ]` 验证后) | 无损 |
| `candidate-v4.3-reviewed/` | `archive/candidate-v4.3-reviewed/` | mv | 冻结 |
| `baseline-4.2.3/` `4.2.3/` `cf-worker/` | `archive/{同名}/` | mv | 冻结 |
| 根 `4.3.1/` `5.0/` `5.1/` (内容异 archive 既有) | `archive/root-flat-legacy/{v}-root-flat/` | mv 避撞名 | 冻结 |
| 根 `omn/` (64 .md + 版本副 + zip) | `archive/omn-legacy/` | mv | 冻结 |
| 根 `entrypoint.sh` `init-nim-keys.sh` `gate.js` `litestream.yml` (旧批 7/12–7/14) | `archive/root-flat-legacy/` | mv | 冻结 |
| 根 `omn-merge-v4.3.0.md` `omn-v4.3.2-k3-review-20260722.md` | `docs/` | mv | — |
| 根 `merge_files.py` `assemble_k3_*.sh` | `tools/` | mv | — |
| `archive/candidate-v4.3-reviewed/d-step-staging/bootstrap.sh` | 根 `bootstrap.sh` | cp (原件保留) | `c39d98a4fea2` |

> 验证闸 G1–G5 全绿: G1 五件 sha 全等基线 ✓ / G2 bash -n + node --check ✓ / G3 reviewed mtime mv 保 mtime 一致 ✓ / G4 patches/p0 三件 sha 不变 ✓ / G5 根树无遗漏散件 ✓。终审三件套 (合并稿 fenced init[1/7]+entrypoint[2/7] 抽出 diff omn-logic/ 实件) 逐字一致 diff空 + fenced 20 成对全绿 (路径同步 docs/+ omn-logic/ 后重跑通过)。

---

*Base image: OmniRoute 3.8.43 · Candidate: v4.3 · Updated: 2026-07-14*
