# Stage A · 只读盘点 (audit/00-inventory.md)

> 第六独立审查者 · Stage A 产出 · 仅只读, 未改任何生产文件
> 生成日期: 2026-07-11 (上下文内绝对化)
> CAVEMAN MODE 下技术实质完整保留

本文件记录仓库树、候选清单、基线确认、文件哈希、源码版本身份、初步争议点。
敏感与 Relay 扫描单列 `audit/01-secret-and-relay-scan.md`。

---

## 0. 审查者角色与红线回顾

- 角色: 第六独立审查者。提炼共识 / 解决冲突 / 删幻觉, 产出可审可回滚可测候选。
- 三条硬红线:
  1. 凭据不进 HF Dataset 快照或日志明文。
  2. Gate 暴露面 ≤ `/healthz` + `/v1[/...]`; PSK 用 timing-safe equal; 无 PSK fail closed。
  3. 本地 SQLite 已存在且非空时 Litestream 不得覆盖恢复。
- 用户覆盖修正(优先于残缺文字):
  - HF Docker Space, ~2 vCPU / 16 GB; OmniRoute **锁定 v3.8.43**。
  - 默认预算 **28 RPM / 1 并发 / 2200ms**。
  - 多 Key 仅冗余/健康轮换/故障转移, **不按 Key 数线性放大吞吐, 不提高默认并发**。
  - 公网暴露面严格 `/healthz`、`/v1`、`/v1/*`, 其他 404。
  - 先挑战背景结论 #2(Resilience), 后 #4(模型 ID 前缀)。
  - Stage A 只写 `audit/00` 与 `audit/01`; 可创建 audit/ 目录, 不写他路径。
  - 哈希只读, 不改时间戳; 源码 checkout 非 3.8.43 不切分支/reset/pull。

## 0.A 三层严格区分 (用户纠正 #3)

本次审查涉及三层, **不得混为一谈**:

| 层 | 路径 | 用途 | 证据等级含义 |
|----|------|------|-------------|
| L-DEPLOY | `/home/laisi/omn-merge/` | 部署仓库: 脚本/Git 历史/自动化工作流/本次整合工程仓 | 文件+本地静测 = **L1**; Git 历史 = 证明何时/如何变更/部署, 但**不能单独证 OmniRoute 内部 API 契约** |
| L-SOURCE | 上游 OmniRoute v3.8.43 | 验证内部 API/Resilience/DB 结构/默认行为 | 精确对应 v3.8.43 = **L2**; 未锁定 3.8.43 官方文档 = L3 |
| L-IMAGE | Docker 基础镜像 `diegosouzapw/omniroute:3.8.43@sha256:517c...` | 验证镜像 ENTRYPOINT/CMD/文件布局/捆绑版本 | 实际镜像内行为 = **L1** (镜像级) |

- 审查者曾生成/提交/推送 v4.2.3, **此历史熟悉度不自动构成 L1/L2**, 仍须从当前文件/Git/工作流/测试重验。
- Stage A 根目录 = `L-DEPLOY` = `/home/laisi/omn-merge/`。
- **GAP-L2-SOURCE-001 (已闭合)**: 背景称的 `/home/laisi/omniroute/` 不存在 (路径信息错误); 初期本地仅 `/home/laisi/OmniRoute/` checkout **v3.8.44 ≠ 基线 3.8.43**, L2 缺口存在。**用户审查中补真源** `/home/laisi/omniroute-v3.8.43` @ `b729a8f27364f072c87082e03bb8e122f3d76251` (与 `git ls-remote` v3.8.43 tag sha 逐位一致, package version 3.8.43, 干净工作区), 缺口**闭合**。详见 §1.A.0。此缺口不阻断 L-DEPLOY 盘点。

---

## 1. 源码版本身份(关键, 关系 L2 有效性)

背景称 `/home/laisi/omniroute/` 是 v3.8.43 源码。**实际路径大小写不同, 且 checkout 非 3.8.43**:

- 实际源码目录: `/home/laisi/OmniRoute/` (大写 O, R)
- `git status --short`: 空 (干净)
- `git rev-parse HEAD`: `1bda6c15dc885b645243f6cc198688ba6bb7480c`
- `git describe --tags --always --dirty`: `v3.8.44`
- `git remote -v`: `https://github.com/diegosouzapw/OmniRoute.git` (无凭据 URL, 无需脱敏)
- `package.json` version: **3.8.44**
- 本地 tag: 仅 `v3.8.44`; `v3.8.43` tag **本地未知**。
- 未提交修改: 0

**结论 / 版本身份风险**:
- 本地 checkout = **v3.8.44**, 部署基线 Dockerfile pin = **v3.8.43** (`diegosouzapw/omniroute:3.8.43@sha256:517c1606...`).
- 两版相邻, 但 schema/行为可能有差异 (3.8.43→3.8.44 可能含 migration 或 breaker 行为微调)。
- 严格起见: 本地 3.8.44 源码结论**仅作旁证**, 标注"版本身份未完全确认 (本地 3.8.44 ≠ 基线 3.8.43)"。
- L2 优先取自 GitHub `diegosouzapw/OmniRoute` 的 **v3.8.43 tag raw 文件** (raw.githubusercontent.com), 已对关键争议点取实证 (见 §6)。
- 本阶段未 `git fetch` v3.8.43 tag (避免任何可能改写 checkout 状态的操作); 初期用 GitHub raw 只读取 v3.8.43 源, 后用户放置真源 (见下)。
- 注: `/home/laisi/omniroute/` 路径缺失**不阻断** L-DEPLOY (omn-merge) 盘点; 曾为 L2 源码缺口 GAP-L2-SOURCE-001 (见 §0.A)。

### 1.A.0 L-SOURCE v3.8.43 真源身份 (用户补源, GAP 闭合)

用户在审查中放置真 v3.8.43 源码: `/home/laisi/omniroute-v3.8.43`。只读验证 (未装依赖/未改源/未切分支/未访问生产实例):
- `git status --short`: 空 (干净工作区)
- `git rev-parse HEAD`: `b729a8f27364f072c87082e03bb8e122f3d76251`
- `git describe --tags --always --dirty`: `v3.8.43` (无 `-dirty`)
- `git remote -v`: `https://github.com/diegosouzapw/OmniRoute.git` (无凭据 URL)
- `package.json` version: **3.8.43**, name `omniroute`
- 与 `git ls-remote` 取 v3.8.43 peeled tag sha == 本地 HEAD: `b729a8f` **逐位一致** ✓
- main HEAD (远端) = `9cd18bf` (≠ v3.8.43 tag, 确证 tag 非 main 别名)

**GAP-L2-SOURCE-001 → 闭合**: 真 v3.8.43 源码可确认, OmniRoute 内部 API/Resilience/DB/默认行为的 L2 验证不再有缺口。先前 GitHub raw 取证的 schema 经真源码逐符号核对**实质成立但措辞有偏差** (字段名是 camel `providerBreaker`/`connectionCooldown`/`useUpstream429BreakerHints`, 而非 Pascal; Pascal 是 interface/type 名)。详见 §6.1 校准台账。

---

## 1.A L-DEPLOY Git 链路与部署路径 (用户纠正 #5/#6)

只读查证, 仪用 `git log/show/diff/branch/remote`; 未执行 commit/push/fetch/pull/checkout/switch/reset/clean/merge/rebase。

### 1.A.1 Git 仓库身份

- 仓库根: `/home/laisi/omn-merge` (`git rev-parse --show-toplevel`)
- 当前分支: **`feature/slim-monitor`** (独立特性分支)
- HEAD: `9a1a7f0f` ("refactor(context-monitor): 第二轮精简——删除 4 个无价值功能块")
- 工作区 (脱敏, 自然无凭据): 仅 3 个未追踪 `?? audit/`、`?? docs/archive/4.3/`、`?? omn-merge-bundle.md`; 生产 6 文件 0 改动。

### 1.A.2 三远端 (脱敏: remote 名+主机, URL owner 已 [REDACTED])

| remote | 主机 (脱敏) | 角色 |
|--------|-----------|------|
| `hf` | `/home/laisi/omn-hf-clone` (本地路径 = HF Space git clone) | HF Space 部署镜像 remote |
| `nog` | `github.com/[REDACTED-OWNER]/nog.git` | 历史材料/分叉源 |
| `nomn` | `github.com/[REDACTED-OWNER]/n-omn.git` | **部署源** (GitHub main) → Action → HF Space |

### 1.A.3 各远端 main HEAD 与同步状态

| ref | HEAD | 与本地 main 关系 |
|-----|------|------------------|
| 本地 `main` | `42ea8e7` ("fix(context-monitor): #4 双PRAGMA合一...") | — |
| `nomn/main` | `42ea8e7` | **0 差异 = 与本地 main 完全同步** |
| `hf/main` | `23c2feb` ("Update init-nim-keys.sh", 旧) | 落后本地 main 多个 commit (HF clone 旧版) |
| `nog/main` | `aff253b` ("Rename README.md...") | 分叉, 历史材料源 |
| 本地 `feature/slim-monitor` | `9a1a7f0` | 领先本地 main **2 commit** (9a1a7f0, 4632e8c), **未追踪任何远端** |

注: 本地尚有 `fusion-main`/`fusion-main-backup`/`nomn-main-snapshot`/`stage1-nog`/`stage2-hf`/`stage3-nomn`/`worktree-nim-pool-rebuild` 等历史/快照分支, 与当前审查不直接相关。

### 1.A.4 部署链路 (只读记录, 未触发任何 workflow)

```
本地 omn-merge  ──push(预期)──>  nomn/main (GitHub 仓库)
                                        │ push to main + 改指定 paths 触发
                                        ▼
                            .github/workflows/sync-to-hf-space.yml
                            (白名单仅复制: Dockerfile/entrypoint.sh/init-nim-keys.sh
                             /litestream.yml/gate.js/package.json/README.md
                             /sync-to-hf-space.yml → /tmp/hf-space-sync)
                                        ▼
                                   HF Space git repo
                                        ▼
                          HF Space 构建 Docker (FROM omniroute:3.8.43@sha256:517c...)
                                        ▼
                                   HF Space 运行实例
```

并行工作流 `.github/workflows/deploy-cf-worker.yml`: push to `main` + 改 `cf-worker/**` → `wrangler@4` 部署到 Cloudflare Worker (用 `CLOUDFLARE_API_TOKEN`/`ACCOUNT_ID` secrets)。两个工作流独立触发, 互不依赖。

### 1.A.5 工作流触发条件

- **sync-to-hf-space**: `push` to branch `main` 且 paths ∈ {Dockerfile, entrypoint.sh, init-nim-keys.sh, litestream.yml, gate.js, package.json, README.md, .github/workflows/sync-to-hf-space.yml}; 或 `workflow_dispatch` 手动。
- **deploy-cf-worker**: `push` to branch `main` 且 paths ∈ {cf-worker/**, .github/workflows/deploy-cf-worker.yml}; 或 `workflow_dispatch` 手动。
- 二者均**只对 `main` 分支 push 生效**; 推其他分支 (如 feature/slim-monitor) 不触发任何部署。

---

## 2. 仓库根目录树 (生产文件清单)

`/home/laisi/omn-merge/`:

| 文件/目录 | 行 | 字节 | 角色 |
|-----------|----|------|------|
| Dockerfile | 67 | 2902 | 镜像构建, pin 3.8.43 |
| entrypoint.sh | 84 | 3616 | PID/supervisor + Litestream + 启 gate |
| gate.js | 40 | 1587 | HF Space 内层 Gate (本项目外层代理) |
| init-nim-keys.sh | 723 | 40072 | NIM 初始化(限流/Combo/Context观测/探针) |
| litestream.yml | 16 | 391 | SQLite→R2 复制配置 |
| package.json | 17 | 356 | gate.js 依赖 (express/http-proxy-middleware) |
| cf-worker/index.js | 432? | 10495 | **外层 Cloudflare Worker 网关** (见 §5) |
| cf-worker/readme.md | 12 | 693 | Worker 告警/Secret 说明 |
| cf-worker/wrangler.toml | — | 84 | `name="omn"`, `workers_dev=true` |
| omn-merge-bundle.md | — | 52641 | 未追踪大文档 (?? 状态) |
| docs/ | — | — | 文档与候选材料 |
| .github/workflows/ | — | — | sync-to-hf-space.yml + deploy-cf-worker.yml |
| .gitignore | — | — | 排除 .env/.env.*/.db/audit-report.md/.claude/ |

注: `audit/` 目录**未在 .gitignore** → 我写入的 audit/ 文件会进 git 暂存。
本阶段只写两类文件且只含脱敏摘要, 避免凭据进库。已向用户提示此点 (见 §8 风险)。

---

## 2.A 上游源码副本 / Submodule / Vendor / 快照 / 镜像检查记录探测 (用户纠正 #9)

只读识别 omn-merge 内是否含 OmniRoute 上游源码副本/版本锁定快照/镜像检查记录。**不得仅凭目录名认作 3.8.43**, 须验来源与版本。

| 探测项 | 命令 | 结果 |
|--------|------|------|
| Git submodule | `[ -f .gitmodules ]` | **无** `.gitmodules` |
| vendor/src/apps/packages 副本目录 | `find . -maxdepth 3 -type d -iname ...` | **0** (仅 cf-worker, 非 Omniroute 源) |
| 上游源码片段引用 | `grep -rlE 'createServer\|next-server\|@omniroute' --include='*.sh/js/yml/md'` | **0** 命中 (排除 .git/audit) |
| Dockerfile COPY 上游源码 | `grep COPY\|ADD Dockerfile` | 仅 COPY 5 自有文件 (package.json/gate.js/entrypoint.sh/init-nim-keys.sh/litestream.yml), **不 COPY 上游源码** |
| 锁文件/版本锁定快照 | `find ... *lock* *digest* *mirror* package-lock pnpm-lock renovate` | 仅 `cf-worker/wrangler.toml` (Worker 配置, 非 OmniRoute 锁); **无** package-lock.json/pnpm-lock/renovate/.tool-versions |
| 镜像检查记录文件 | `find ... *image*inspect* *digest* *mirror*` | **0** 落盘记录文件; Dockerfile L4-5 注释含取 digest 命令说明 (`docker inspect --format='{{index .RepoDigests 0}}' diegosouzapw/omniroute:3.8.43`), 但无产物文件 |
| .gitattributes LFS 锁源 | `cat .gitattributes` | 仅 `*.sh/*.js/*.yml text eol=lf` 归一, 非 LFS |
| node_modules | find | **0** (.gitignore 已排除) |

**结论**: omn-merge **不含** OmniRoute 上游源码副本、submodule、vendor、源码归档、版本锁定快照、镜像检查记录文件。上游 OmniRoute 完全经 Docker `FROM diegosouzapw/omniroute:3.8.43@sha256:517c160643c56ad72e3e305458d961c9a4c87f711393c13020450f9f088d1570` 镜像内提供, **不在本仓库内**。
→ 无任何在仓副本可被误认作 3.8.43。L2 验证原缺口 GAP-L2-SOURCE-001 **已闭合** (用户补真源 `/home/laisi/omniroute-v3.8.43` @ `b729a8f`, 见 §1.A.0)。

### 2.A.1 docs/archive/4.3/4.2.3.md 与根生产文件关系

- `4.2.3.md` (1054 行/52641B) 是 **v4.2.3 完整脚本的 Markdown 归档镜像**: 内嵌 Dockerfile/entrypoint.sh/gate.js/init-nim-keys.sh/litestream.yml/package.json 五文件内容, 含 "NIM OmniRoute initializer v4.2.3 (基于 v4.2.2)" 注释、版本护栏 "expected 3.8.43"、DEBUG log 入 Dataset⑨ 等。
- **关系**: 4.2.3.md = 归档时点 v4.2.3 完整栈快照; 根生产文件 = 工作树真实运行版。归档同步时二者一致, 根文件后续演进 (如 feature/slim-monitor 精简 init-nim-keys.sh 192 行) 则归档停滞。
- 当前根 init-nim-keys.sh (working tree @ 9a1a7f0) **已领先** 4.2.3.md 归档 (归档仍含 42ea8e7 基线的自动回写 enabled)。4.2.3.md 是**审查材料** (L4 历史归档), 不作 L1 真源; L1 真源 = 根生产文件 + git 历史。

---

## 3. 候选文档清单区分 (审查文档 vs 候选脚本)

`docs/archive/4.3/`:

| 文件 | 行/字节 | 性质 |
|------|---------|------|
| 4.2.3.md | 1054 / 52641 | **基线** (含全部五文件当前已运行版本) |
| 4.3.txt | 4573 / 211916 | 审查/讨论文档 |
| in4.3.txt | 5564 / 236426 | 审查/讨论文档 (提及 Resilience 证伪 + 完整脚本) |
| hf轻模型部署.txt | 2172 / 155107 | 审查/讨论 (搜索能力 + 模型栈) |
| hf+omniroute+轻量模型.md | 1743 / 85373 | 审查/讨论 (完整模型栈设计) |
| tabbit_NVIDIA...Guide (2).md | 161 / 7130 | **候选脚本 v4.3.0** (初始化逻辑) |
| tabbit_NVIDIA...Guide (3).md | 1211 / 46853 | **候选脚本** (五文件骨架) |
| tabbit_同步...教程.md | 153 / 11538 | 五模型总结共识/分歧 |

`docs/` 其他相关:
- `docs/nim_context_probe.sh` — 独立 Context 探针脚本 (Stage C 维度11 高危审查点)
- `docs/DEPLOYMENT_GUIDE.md` / `docs/changeLELOG.md` / `docs/README.md` / `docs/readme4.2.3.md`
- `docs/archive/audit-report.md` (5665+ 行) — 上一轮审计工作产物
- `docs/archive/n-omn-4.2.md` / `3.8.0.txt` 等历史材料

Stage D 处理重点抬取: 候选脚本 `(2).md` 与 `(3).md`; 审查文档作为主张矩阵输入但非直接代码来源。

---

## 4. 生产文件 SHA256 哈希 (只读, mtime 未改)

```
0c188854fbedbbc79b51d8292a1dc1e573e7a3bb2b35e5079dc978bf180d2423  Dockerfile
7d3c1b31af9b2600cef09e907d707c68425b6adae6f576a2bba79a2dc9a0f805  entrypoint.sh
d65afab53c11c2972e184251796c0f0da852347d655249b333dbae846b182ad4  gate.js
b72539097338a6e8bb98f7c787a5ce2210e585f513879d657decfbf0f85ca903  init-nim-keys.sh
4bcb67b6a4484952270a4318e60df988d650b63ac3b2325a24dc8efd318ac816  litestream.yml
3724179a7d2acb0d7b21d0fb3ad1ce1aa6b65fe018121098e991d73c298098cd  package.json
```

mtime (stat --format, 未改): Dockerfile/entrypoint/gate/litestream/package = 2026-07-10 12:39-12:41; init-nim-keys.sh = 2026-07-10 20:35。

---

## 5. 关键架构发现: 双层网关 (cf-worker + gate.js)

背景/覆盖修正称 "gate.js 是本项目外层代理, 不假设上游有同一 Gate"。
**实际栈为双层网关**:

```
Client → [Cloudflare Worker: cf-worker/index.js v1.3.0] → [HF Space: gate.js] → [OmniRoute :20128]
```

- `cf-worker/` 由 `.github/workflows/deploy-cf-worker.yml` 在 cf-worker 变更时用 `wrangler@4` 部署 (`CLOUDFLARE_API_TOKEN`/`ACCOUNT_ID` secrets)。
- cf-worker 含**白名单路由** `/`、`/healthz`、`/__health`、`/v1*` (他 404)、CLIENT_TOKEN 校验、INTERNAL_PSK 转发、告警 (Resend email / 企微 webhook)、429/5xx 分桶统计。
- `gate.js` 是内层 (HF Space 内): `/healthz` 探后端、/v1 比对 INTERNAL_PSK 换 OR_API_KEY、createProxyMiddleware 透传。

**Stage B 主张矩阵须裁决的关键争议**:
1. cf-worker 是否属"外部 Relay (禁)" 还是"另一层 Gate (同构白名单+PSK)"? —— 红线写"禁任何外部 Relay (Cloudflare)", 但 cf-worker 是白名单 Gate 而非流量转发 relay。语义边界冲突。
2. cf-worker `CLIENT_TOKEN` 比较 `===` (line 181) **非 timing-safe** → 若 cf-worker 被认定为合规 Gate, 此比较须改 timing-safe。
3. cf-worker 暴露 `/__health` 额外路径 → 超出覆盖修正的 `/healthz`+`/v1` 清单, 须裁决是否算暴露面扩大。

---

## 6. 初步争议点与证据等级 (Stage A 已可直接验证的)

下列在 Stage A 已通过只读取得 L1/L2/L4 证据, Stage B 正式入主张矩阵:

### 6.1 [挑战背景 #2] Resilience schema — 证据台账与精确符号校准 (L2 真源)

背景结论 #2 (待审): "Resilience 的 providerBreaker/connectionCooldown 字段假设被官方文档证伪 (阈值是内置常量, 仅对 408/500/502/503/504 触发, 不对 429 触发)"。

校准背景: 初版 §6.1 基于 GitHub raw 取证, 字段名措辞为 Pascal (`ProviderBreaker`/`ConnectionCooldown`/`UseUpstream429BreakerHints`), 存在 raw 缓存/重定向疑虑且与 GAP-L2-SOURCE-001 自相矛盾。用户补真源后 (`/home/laisi/omniroute-v3.8.43` @ `b729a8f`), 逐符号 case-sensitive 复核, **修正字段名大小写 + 写证据台账**。

#### 证据台账 (按用户证据校准请求 9 要素)

| 主张# | 精确主张 | 证据来源类别 | 文件路径:行 | 符号名 (case-sensitive) | 来源标识 | 当前等级 | 足以推翻 #2? |
|-------|---------|------------|------------|------------------------|---------|---------|------------|
| A | `providerBreaker` 是顶层 ResilienceSettings 真实可配 schema 字段 (camel) | 已确认 3.8.43 源码 | `src/lib/resilience/settings/types.ts:163` | `providerBreaker` (字段名 camel); `ProviderBreakerProfileSettings` (interface 名 Pascal) L39-43 | tag v3.8.43 commit `b729a8f` | **L2** | 推翻 #2"字段被证伪" ✓ |
| B | `connectionCooldown` 是顶层真实可配 schema 字段 (camel) | 已确认 3.8.43 源码 | `src/lib/resilience/settings/types.ts:162` | `connectionCooldown` (字段 camel); `ConnectionCooldownProfileSettings` (interface Pascal) L22-37 | tag `b729a8f` | **L2** | 推翻 #2"字段被证伪" ✓ |
| C | providerBreaker/connectionCooldown 阈值**非纯内置常量**, 可 per-auth-category 写入 | 已确认 3.8.43 源码 | `types.ts:162-163` (Record<AuthCategory, ...>); `settings.ts:273,277` (normalizeProviderBreakerProfile by oauth/apikey) | `Record<AuthCategory, ProviderBreakerProfileSettings>` | `b729a8f` | **L2** | 推翻 #2"阈值是内置常量"(部分: FailureThreshold 等有 normalize 默认 + 可 PATCH 覆盖) ✓ |
| D | API 契约: `GET/PATCH /api/resilience` body 用 camel 字段 | 已确认 3.8.43 源码 | `src/app/api/resilience/route.ts:122(GET)`, `:153(PATCH)`, `:127-130/235-238 (响应字段 connectionCooldown/providerBreaker camel)`, `:182-189 (body 字段)` | `connectionCooldown`, `providerBreaker` (camel, HTTP body) | `b729a8f` | **L2** | 旁证字段真实 API 可读写 ✓ |
| E | `useUpstream429BreakerHints` 真实存在 (camel 全小写) 属 ConnectionCooldownProfileSettings | 已确认 3.8.43 源码 | `types.ts:35`; `route.ts:227-230`; `normalize.ts:135-136`; UI `ResilienceTab.tsx:406` (i18n key `resilienceUseUpstream429BreakerHints`) | `useUpstream429BreakerHints` (camel 字段); `resolveUseUpstream429BreakerHints` (函数) | `b729a8f` | **L2** | 推翻 #2"不对 429 触发"的绝对断言 ✓ |
| F | 429 可计入 breaker cooldown (opt-in 语义) | 已确认 3.8.43 源码 | `types.ts:26-35` 注释 "upstream 429 hint trust at circuit-breaker cooldown layer"; `src/sse/handlers/chat.ts:1026` + `chatHelpers.ts:325` 运行时调用 | `resolveUseUpstream429BreakerHints()`, 429 多处 `status === 429` (assessor.ts:78 等) | `b729a8f` | **L2** | 推翻 #2"不对 429 绝对" ✓ |
| G | NIM (direct cloud provider) `useUpstream429BreakerHints` **默认 true** (非关) | 已确认 3.8.43 源码 | `src/shared/utils/providerHints.ts:21-23, 43-56` (defaultUseUpstream429BreakerHints: proxy/self-hosted/CLI=false, 其余 direct cloud=true@L56) | `defaultUseUpstream429BreakerHints()` | `b729a8f` | **L2** (默认值推断 NIM 归 direct cloud); **L3 待验** (NIM 是否真落 direct-cloud 分支, 未见显式 nvidia 白名单) | 部分: 若 NIM 属 direct cloud 则默认 trust 429 → 进一步推翻 #2; 标 NEEDS-INSTANCE-TEST 确认 NIM provider 分类 |

#### 符号大小写最终裁定 (case-sensitive, v3.8.43 b729a8f 实存)

| 符号 | **真实大小写** | 用途 | 文件:行 | 之前 (raw/记忆) 措辞 | 偏差 |
|-----|---------------|------|--------|---------------------|------|
| 顶层 schema 字段 | `providerBreaker` (camel 小写) | ResilienceSettings 字段 | types.ts:163 | 误写 Pascal `ProviderBreaker` | **修正: camel** |
| 顶层 schema 字段 | `connectionCooldown` (camel 小写) | ResilienceSettings 字段 | types.ts:162 | 误写 Pascal `ConnectionCooldown` | **修正: camel** |
| interface 名 | `ProviderBreakerProfileSettings` (Pascal) | 类型 | types.ts:39 | 一致 | ✓ |
| interface 名 | `ConnectionCooldownProfileSettings` (Pascal) | 类型 | types.ts:22 | 一致 | ✓ |
| 可选字段 | `useUpstream429BreakerHints` (camel 全小写) | ConnectionCooldownProfileSettings?: | types.ts:35 | 误写 Pascal `UseUpstream429BreakerHints` | **修正: camel** |
| API body 字段 | `connectionCooldown`, `providerBreaker` (camel) | GET/PATCH /api/resilience | route.ts:127-130, 182-189, 235-238 | ✓ camel 一致 | ✓ |
| HTTP 方法 | `GET`, `PATCH` | /api/resilience | route.ts:122, 153 | ✓ | ✓ |

#### 本校准结论

- **主张 A/B/C/D/E/F 有 L2 充分证据, 足以推翻背景 #2 的"字段被证伪 / 不存在真实可配 schema"与"不对 429 触发"两个绝对断言** → 撤回措辞瑕疵 (Pascal→camel), 保留并强化"部分推翻 #2"。
- **主张 G (NIM 默认 true)**: 真源有 `defaultUseUpstream429BreakerHints()` 逻辑, 但 NIM 是否落 direct-cloud 分支未见显式白名单 (providerHints.ts 仅见 proxy/self-hosted/CLI 显式 false, 其余兜底 true)。故 NIM 默认值推断为 **L3 待验**, 单列 `NEEDS-INSTANCE-TEST-G1` (Stage C 须追 NIM provider 分类或 read-back `/api/resilience` 当前值脱敏确认)。
- **背景 #2"阈值是内置常量"**: 部分推翻 — 字段可 PATCH 写入 (route.ts:153 PATCH + body), 但 FailureThreshold 等有 normalize 默认值 (settings.ts:273,277), 即"有默认 + 可覆盖", 非纯不可配置常量。
- **背景 #2"仅对 408/500/502/503/504 触发"**: 本校准**未验证**触发码全集 — `domain/modelAvailability.ts` 已定位但 429/breaker 触发码全集未在本轮逐行确认。该部分标 **NEEDS-SOURCE-G2** (Stage C 须读 `src/domain/modelAvailability.ts` + assessor.ts 逐码确认)。
- 证据等级赋给**具体主张** (A=独立字段 L2, G=默认值 L3 待验, 触发码全集=未验), 不整体赋文件。

#### 待验项汇总 (NEEDS-*)

- `NEEDS-INSTANCE-TEST-G1`: NIM provider 是否归 direct-cloud (决定 429 hint 默认 true/false); 需脱敏 read-back `/api/resilience` 任一 None。
- `NEEDS-SOURCE-G2`: 触发码全集 (408/500/502/503/504 + 429 是否全计 cooldown); 待 Stage C 读 `src/domain/modelAvailability.ts`、`assessor.ts`、`providerExpiration.ts:232` 等。

#### 三基准区分 (用户证据原则修正)

§6.2 修正涉及"自动回写" 在三份基准的差异, 本 §6.1 仅涉 L-SOURCE (omniroute-v3.8.43) 一基准, 不与 L-DEPLOY working tree / nomn 部署 commit 混。三基准另见 §1.A + §6.2 + §8.A Q3:
- **B1 部署基线** = `nomn/main @ 42ea8e7` (已部署 HF Space)
- **B2 working tree** = `feature/slim-monitor @ 9a1a7f0` (当前审查工作树)
- **B3 L-SOURCE** = `omniroute-v3.8.43 @ b729a8f` (上游契约)
三者互不替代; §6.1 证据全来自 B3。

### 6.2 [部分修正] Context Override 自动回写: working tree vs 已部署基线分歧 (L1, 关键)

**精确区分**:
- **已部署基线 `nomn/main` @ 42ea8e7**: context-monitor **自动回写 enabled** — `INSERT INTO model_context_overrides ... recommended_real_context, source='monitor+manual'`, 高置信时直接覆盖 real_context。这与背景结论 #7 "自动应用默认关闭"不符。
- **working tree `feature/slim-monitor` HEAD @ 9a1a7f0**: 自动回写**已注释禁用** (commit 4632e8c "禁用自动回写"), 仅保留手动 case 分支 + `context_recommendations` 被动观测。

**共同点 (两版一致, L1 实读 init-nim-keys.sh working tree)**:
- `context_recommendations` 表默认 `confidence='insufficient'`
- 失败口径只纳 `status>=500`、`status=413`、`(2xx 且 output=0)`, 排除 401/403/429 ("鉴权/限频信号会污染")
- → 仍守红线 "401/403/429 不算 Context 上限"

**结论**: 背景 #7 在 **working tree** (本地特性分支) 已落实"只观测不自动回写", 但 **已部署基线 42ea8e7 仍自动回写**。candidate v4.3 须以**禁用自动回写**为默认 (对齐背景 #7), 且须确认 nomn/main 在 candidate 部署时一并采纳。**读回验证必带** (确认 model_context_overrides 不被非授权写入)。
证据等级: **L1** (working tree + nomn/main diff 实读)。
注: 我之前"基线已守只观测"论断是基于 working tree 读, 现已纠正 — 这是用 Git 历史(变更验证)与本地文件(当前实现)分离出 L1 精确事实的体现 (用户纠正 #4/#6)。

### 6.3 [冲突, 待 Stage B 裁决] 限流推导 vs 用户修正 #2 (#L1 vs 用户指令)

`init-nim-keys.sh` L129-140 实际限流推导:
- `_PER_KEY_RPM=35`, `_RPM = _ALIVE_KEYS * 35` (封顶 300)
- `_CONCURRENT = _ALIVE_KEYS * 3` (下限 3)
- `_MIN_INTERVAL_MS = 60000/_RPM`

**与用户覆盖修正 #2 (28 RPM / 1 并发 / 2200ms)** 直接冲突; 且 `_RPM = _ALIVE_KEYS*35`、`_CONCURRENT = _ALIVE_KEYS*3` **按 Key 数线性放大吞吐**, 违反用户修正 #3 "多 Key 不线性扩容"。
证据等级: **L1** (基线实读)。决策倾向 REJECT 现行推导、ACCEPT-WITH-GUARD 改成固定 28RPM/1并发/2200ms 可审计预算 (但需确认限流执行点: Gate vs OmniRoute, 维度4 — Stage C 查证)。

### 6.4 [冲突] gate.js 非 /v1 路径透传 (L1, 红线 2)

`gate.js` L29-37: 无 /v1 前缀路径仅 `return next()` → 进 `createProxyMiddleware` 透传到 OmniRoute, 未 404。
→ 违反覆盖修正 #4 "其他路径一律 404" 与红线 2 "其余 404"。/api、/admin 等可经 Gate 穿透。
证据等级: **L1**。决策倾向 REJECT 现行、[必须修复] 候选改为白名单 (仅 /healthz 直应 + /v1 代理, 其余 404)。

### 6.5 [冲突] gate.js PSK 非 timing-safe (L1, 红线 2)

`gate.js` L32 `bearer !== INTERNAL_PSK` 用裸 `!==`。cf-worker L181 `token === env.CLIENT_TOKEN`。
→ 两处均违反红线 2 "PSK 比较必须 timing-safe equal"。
证据等级: **L1**。决策倾向 [必须修复] 候选改用 `crypto.timingSafeEqual` (Node) / Web Crypto constant-time (Worker)。

### 6.6 [冲突] entrypoint.sh Litestream restore 无非空保护 (L1, 红线 3)

`entrypoint.sh` L16 `litestream restore -if-replica-exists "$DATA_DIR/storage.sqlite"`:
- 未检查本地文件是否已存在且非空。
- `-if-replica-exists` 成功≠恢复成功, 无文件非空校验 / 无 `PRAGMA quick_check` (维度 9)。
→ 违反红线 3 "本地 SQLite 已存在且非空时不得覆盖恢复"。
证据等级: **L1**。决策倾向 [必须修复] 候选加 pre-restore 非空 guard + post-restore 非空校验与 `PRAGMA quick_check`。

### 6.7 [冲突] entrypoint.sh 进程监督 / 信号转发 (L1, 维度 8)

`entrypoint.sh` L37 `node /app/server.js --log &` (后台), L59 `bash /entrypoint-init-nim.sh &` (后台), L77 `litestream replicate &` (后台), L84 `exec node /gate/gate.js` (前台)。
→ gate.js 成 PID 1 前台, OmniRoute/litestream/init 为孤儿后台进程, 不收 SIGTERM/SIGINT → 僵尸 / 不优雅退出 / init 崩溃静默。
readiness 墙钟 180s + `kill -0` 探进程 ✓ 基本 OK, 但 L45 `curl -sf` 无 `--max-time`, 慢响应卡死单轮。
证据等级: **L1**。决策倾向 [必须修复] 候选加 trap SIGTERM/SIGINT 转发 + wait + curl `--max-time`。

### 6.8 [同意背景 #1] Relay 清除 (L1)

`init-nim-keys.sh` L30-35: `ONEPROXY_ENABLED=false`、`ENABLE_SOCKS5_PROXY=false`、unset `OMNIROUTE_RELAY_BACKEND`/`BIFROST_BASE_URL`/`HTTP_PROXY` 等。**强制关闭代理生态**。
`init-nim-keys.sh` L176-210 `purge_proxy_db`: 删除 `proxy_registry` 中 host=127.0.0.1:20129 的旧 proxy 登记 (注: 这里 `_PROXY_RELAY_HOST=127.0.0.1` 是**本地 proxy registry 清理名**, 非外部 Relay)。
→ 内部 Relay 后端 (`OMNIROUTE_RELAY_BACKEND`/`BIFROST_BASE_URL`) 已 unset; 外部 Relay URL/TOKEN 全仓 0 命中 (见 audit/01)。
证据等级: **L1**。决策 ACCEPT。

### 6.9 [观察] DEBUG 日志入 Dataset 默认开 (L1, 红线 1 高危)

`init-nim-keys.sh` L7-9, L18-27: `NIM_MODE=DEBUG` 时 `tee` 日志到 `LOG_DIR` 且 v4.2.3⑨ "DEBUG log 上传 Dataset (默认开启, `NIM_DEBUG_LOG_TO_DATASET=0` 关)"。
→ DEBUG 日志若含 Authorization Bearer / NIM_KEY / Cookie 会被上传到 HF Dataset 明文。违反红线 1。
证据等级: **L1** (基线注释+逻辑实读; 实际日志内容是否脱敏属 Stage C 动态验证)。
决策倾向 [必须修复] 候选: DEBUG Dataset 上传默认关, 上传前字段级脱敏 Authorization/NIM_KEY/Cookie/Set-Cookie。

### 6.10 [同意背景 #4 待确] 模型前缀 nvidia/*/* (待 Stage B/C)

`init-nim-keys.sh` L99 `models_to_json() ... sed 's/^/nvidia\//'` 给所有模型统一加 `nvidia/` 前缀。
但 catalog ID 内部存储形式、路由按需加前缀、以及是否覆盖 `meta/*`/`nvidia/*`/`nvidia/nvidia/*` 三种输入 — 未在 init 层完全体现 (属 OmniRoute 服务端路由层)。
证据等级: **L1** (init 给前缀) + **L4** (路由层判定, 待 Stage C 查 3.8.43 源 + 写不联网单测)。
Stage A 已识别将作为用户指定第二挑战点 (#4) 处理。

---

## 7. 初步候选必修项清单 (Stage D 雏形, 待 Stage B/C 定证据等级后定稿)

> 编号对应 §6 争议点。仅标定向, 最终决策记于 audit/02 主张矩阵。

| # | 争议 | 候选定向 | 优先级 |
|---|------|----------|--------|
| C1 | gate.js 非 /v1 透传 | 白名单 404 | 必须修复 |
| C2 | gate.js/cf-worker PSK 非 timing-safe | timing-safe equal | 必须修复 |
| C3 | Litestream restore 无非空保护 | pre/post guard + quick_check | 必须修复 (红线 3) |
| C4 | 信号/进程监督孤儿 | trap+wait+curl --max-time | 必须修复 |
| C5 | 限流按 Key 线性扩 | 固定 28RPM/1并发/2200ms 可审计 | 必须修复 (用户修正 #2/#3) |
| C6 | DEBUG 日志入 Dataset 默认开 | 默认关 + 脱敏 | 必须修复 (红线 1) |
| C7 | cf-worker 角色裁决 (Gate vs Relay) | 主张矩阵定 | 待 Stage B |
| C8 | cf-worker /__health 路径 | 暴露面裁决 | 待 Stage B |
| C9 | Resilience 字段 schema | 推翻背景 #2, 按真实 schema 文档化 | Stage B (已 L2) |
| C10 | 模型前缀三输入覆盖 | 不联网单测 | Stage C |

---

## 8. Stage A 风险与提示 (供用户决策)

- **R1 (中)**: `audit/` 未在 .gitignore, 本报告会进 git 暂存。已守只写脱敏摘要, 未含凭据值。Stage A 不改 .gitignore。若需排除, 待授权。
- **R2 (高)**: 源码本地 checkout 是 v3.8.44, 非 v3.8.43。已用 GitHub v3.8.43 tag raw 取 L2 证据, 不裸信本地 3.8.44。后续 L2 一律优先 GitHub v3.8.43 raw + 镜像内实际行为。
- **R3 (待量)**: cf-worker 双层网关角色需用户裁决——是否保留为合规 Gate, 还是按"外部 Cloudflare"红线删除。
- **R4 (提醒)**: 本阶段未调用任何真实 NVIDIA API; **未输出、复制、持久化或报告任何 Secret 值** (扫描仅做模式匹配与脱敏元数据记录); 未改任何生产文件与 SQLite, 未生成候选脚本。符合 Stage A 约束。

---

## 8.A 用户额外 6 问回答 (Stage A 收尾必答)

### Q1: 根目录当前文件是否与已部署 4.2.3 完全一致?

**不一致。** 仅 `init-nim-keys.sh` 存在 192 行差异 (32 增 / 160 删), 其余 5 文件 (Dockerfile/entrypoint.sh/gate.js/litestream.yml/package.json) **0 差异 = 与已部署完全一致**。
对比基准: 已部署 = `nomn/main` @ `42ea8e7` (经 sync-to-hf-space 工作流白名单复制到 HF Space 构建)。

### Q2: 不一致差异来自未提交修改 / 后续提交 / 文档归档?

**来自后续提交。**`git status` 显示 `init-nim-keys.sh` 未被改 (非未提交修改); 差异来自 `feature/slim-monitor` 分支领先本地 main 的 **2 个 commit**:
- `4632e8c` "refactor(context-monitor): 精简——禁用自动回写 + 移除 nim_health_pick"
- `9a1a7f0` "refactor(context-monitor): 第二轮精简——删除 4 个无价值功能块"

二者均**未推送 nomn/main, 故未部署**。`docs/archive/4.3/` 是另一项独立差异 (未追踪, git 不入库), 属本次审查材料归档, 非生产文件改动。

### Q3: 哪个 commit 最可能对应当前 HF Space 部署?

**`42ea8e7`** ("fix(context-monitor): #4 双PRAGMA合一 + #7 _arr_json jq化 + 过滤model-sync")。
依据: nomn/main HEAD = 42ea8e7, 0 差异同步本地 main; nomn/main 是 sync-to-hf-space 工作流的触发源。`nomn/main:init-nim-keys.sh` 注释含 `v4.2.3`。本地 feature/slim-monitor 的 2 个领先 commit 尚未进入 nomn/main, 故 HF Space 仍未承接其 (禁自动回写/nim_health_pick 移除/4 块删减) 变化。

### Q4: 自动化工作流的触发条件?

- **sync-to-hf-space**: `push` 到分支 `main` 且改 paths ∈ {Dockerfile, entrypoint.sh, init-nim-keys.sh, litestream.yml, gate.js, package.json, README.md, .github/workflows/sync-to-hf-space.yml}; 或 `workflow_dispatch` 手动。
- **deploy-cf-worker**: `push` 到分支 `main` 且改 paths ∈ {cf-worker/**, .github/workflows/deploy-cf-worker.yml}; 或 `workflow_dispatch` 手动。
- **关键**: 二者均**仅对 `main` 分支 push 生效**; push 到 `feature/slim-monitor` 等其他分支不触发任何部署。
- sync-to-hf-space 第 25 行白名单: "仅复制 HF Space 部署所需文件, 避免黑名单遗漏泄漏" → audit/、docs/、cf-worker/、omn-merge-bundle.md 等均**不同步 HF Space**。

### Q5: 本次整合工作是否处于安全的独立分支?

**是。** 当前在 `feature/slim-monitor` (未追踪任何远端, 本地独占), 领先本地 main 2 commit。未推送 nomn/main, 未进 nomn, 未触发任何 sync-to-hf/deploy-cf-worker 工作流。审计产物仅写入 `audit/00` 与 `audit/01` (新增未追踪, 不在任何工作流白名单 paths 内), candidate-v4.3-reviewed/ 留待 Stage D 且亦不在部署白名单。

### Q6: 是否存在误推送到生产分支的风险?

**存在但可控。** 剩余风险路径:
1. 误执行 `git push nomn feature/slim-monitor:main` (或 merge feature→main 后 push) → 改 nomn/main → 触发 sync-to-hf-space + (若改 cf-worker) deploy-cf-worker → HF Space 与 Worker 双双更换。
2. 误 `git checkout main` 并 discard working untracked 写入。
3. `git push nomn main --force` 历史改写导致 HF clone 与 nomn 分叉 (hf/main 已落后, 非空本地库可能触发 Litestream 红线 3 风险)。

防护: 整合全程**禁止 push/merge 到 main / nomn-main**; 仅在 feature/slim-monitor 与 candidate-v4.3-reviewed/ 写文; 任何推送须显式用户授权。本次 Stage A 至 Stage E 全程在本地只读/写非生产路径, 不触发 main push。

---

## 9. 下一步 (等用户授权 Stage B)

Stage B (结构化对比):
- 建"主张矩阵" (主张 | 来源 | 影响文件 | 证据等级 | 正确性 | 风险 | 决策), 决策仅 ACCEPT / ACCEPT-WITH-GUARD / REJECT / NEEDS-INSTANCE-TEST。
- 产出 `audit/02-claim-matrix.md`、`audit/03-conflicts.md`。
- 重点裁决: 背景 #2 (已部分推翻) 正式定级; cf-worker 角色 (C7/C8); 限流方案 (C5); 推翻项与保留项。
- 不改生产文件, 不调真实 API。

---

## 附录 A · GitHub v3.8.43 tag raw 取证位置

- 定义 schema: `src/lib/resilience/settings/types.ts` (已取, L2)
- 即将取 (Stage B/C): `src/lib/resilience/settings.ts` (normalize 默认值), `src/app/api/provider-models/route.ts` (背景 #7 Schema), `src/app/api/v1/search/route.ts` (背景 #8), 路由前缀判定层 (背景 #4), `domain/modelAvailability` (429 触发码全集, 挑战 #2 第二面)。

