# Storage Buckets 升级堪察 — 逻辑层 Dataset→Bucket 拓扑变更可行性勘探
# 2026-07-28 · Zen裁"立 buildbook 勘察稿" · 纯文档勘探零代码零部署变更
# ─────────────────────────────────────────────
# 触发: Zen 2026-07-28 提 Storage Buckets 升级方向, 称胜 Dataset 解"循环依赖"
# (加 Key 须 Restart 致网关停摆) + 热更新 + 架构一致性。本稿堪察真伪非实施。
# 本稿结论非裁决, 不动 §1 铁律 (Dataset 仍现役逻辑层), 待 Zen 据稿判是否真迁。

## §0 摘要
Zen贴段核心命题 (Storage Bucket 挂载热更新真) **实证成立**。但有四点偏差须校准:
1. ✅ Bucket = XetHub 后端 S3 兼容非版本化可变存储 (官方义真)
2. ✅ 能原生挂载进 Space 容器内目录做 live mount 热更新 (官方义真, 与现 Dataset bootstrap 拉取模式本质区别)
3. ⚠️ "点 Restart 报 403 Quota Limit" 官方文档无证, 真痛点=Rebuild 触发非 Restart 按钮
4. ❌ "R2 迁入 Bucket 减少跨云" 与 §1 铁律冲突, R2 跨云容灾语义不可单点入 HF, 保留不变

## §1 命题1: Storage Buckets 本质 (真)
源头: https://huggingface.co/docs/hub/storage-buckets
原文: "Storage Buckets are a repo type on the Hugging Face Hub providing S3-like object storage,
powered by the Xet storage backend. Unlike Git-based repositories (models, datasets, Spaces),
buckets are non-versioned and mutable, designed for use cases where you need simple, fast storage
such as training checkpoints, logs, intermediate artifacts, or any large collection of files
that doesn't need version control."
- XetHub 后端 (2024 年底收购) 真
- 非版本化 (non-versioned) + 可变 (mutable), overwrite-in-place — 与 Dataset Git 版本化对立
- 设计场景: 训练 checkpoint/日志/中间产物/频繁变动文件 — Zen贴段"专为频繁变动 AI 产物设计"义真
- 访问协议: S3 API + hf://buckets/ 协议 + hf-mount (NFS/FUSE) + volume mounts (Jobs/Spaces)
  (Zen贴段"S3 / hf:// 协议 支持"真, "分片读取快"=Xet chunk-level dedup 真)

## §2 命题2: 容器内目录挂载 + 热更新 (真, 关键)
源头 1: https://huggingface.co/docs/hub/spaces-storage (Disk usage on Spaces)
原文: "If you need to persist data with a longer lifetime than the Space itself, you can attach
one or more Storage Buckets as volumes. Attached buckets are mounted into the Space container at
the path you specify, making their contents available as local files at runtime."
源头 2: https://huggingface.co/docs/hub/storage-buckets-access (Volume Mounts in Jobs and Spaces)
原文: "Volume mounts in Jobs and Spaces are the same idea as hf-mount, managed for you by the
platform — no extra setup needed. Buckets are mounted read-write by default."
关键铁证:
- 挂载配置在 Space 设置 UI 或 huggingface_hub Python API, 非容器内代码主动拉取
  → 本质区别于现 Dataset 的 bootstrap.sh `hf download` 主动拉取模式
- 读写都支持 (read-write by default) → 改 Bucket 文件容器内实时可见
- hf-mount NFS/FUSE 懒加载 (only bytes your code reads hit network) → 秒级生效无须 Restart
**热更新成立**: 改 Bucket 内 init-nim-keys.sh 或 Key 池 SQLite DB, 容器内 /logic 秒级生效,
无须点 Restart 触 Rebuild。Zen贴段"零重启迭代"义真。

## §3 命题3: Restart 403 痛点 (偏差, 须校准)
Zen贴段原文: "7 月下旬免费账号点 Restart 频繁报 403 Quota Limit... 为加个 Key 可能导致网关停摆几小时。"
查证: HF 官方文档 (spaces-overview, spaces-gpus, spaces-storage) **无 Restart 403 Quota 记录**。
现 Omniroute 真痛点审计:
- 现机制 (CLAUDE.md §1 + bootstrap.sh): 逻辑层=Dataset, init-nim-keys.sh 在 Dataset 内。
  加 Key 须 push Dataset → sync-space-nonoke.yml `push: paths: [Dockerfile]` 自动触 Rebuild
  (Dockerfile 变才触, 逻辑层 push 不触 Rebuild 但是须 hf download 拉取生效须重启应用逻辑)
- 真瓶颈: **Rebuild 触发** (非 Restart 按钮)。HF 7/16 后免费层密集推送冻 build (记忆
  hf-free-docker-build-blocked 已锁), 非 Restart 403 Quota。
- "网关停摆几小时" 风险实情: 冻 build 期间 Rebuild 卡死 → Space 旧版本续跑不停摆, 但新 Key
  不生效。若 Rebuild 半途崩 → crashloop 风险 (记忆 omn-v4.3.0-saga crashloop 链有先例)。
**校准**: Zen贴段"Restart 403"措辞失准, 真痛点="Rebuild 触发链 + build 冻风险"。
但 Storage Bucket 挂载解此真痛点成立 — 改 Bucket 文件秒级生效, 完全避开 Rebuild + build 冻,
无需 Dockerfile 或 Dataset commit。Zen贴段"避开 Restart 按钮 Quota 检查"结论方向对, 机制描述错。

## §4 命题4: R2 迁入 Bucket (不可行, §1 铁律冲突)
Zen贴段原文: "把 R2 的状态同步逻辑也迁入 Bucket 让 OmniRoute 变成纯 HF 生态系统。"
查证: 与 CLAUDE.md §1 铁律硬冲突:
- §1: "R2 bucket 永不双写 (新旧 Space 不得同时在线写同一 bucket)"
- 记忆 r2-token-权限-classa-100万限-余量60: "Storage Bucket 迁移永久拒绝(R2 跨云容灾+WAL语义)"
litestream 0.5.9 replicate 目标须 S3 兼容端点, Storage Bucket S3 API 理论可作 target。
但 §1 拓扑语义: R2 = 跨云灾备层 (Cloudflare 域 非 HF 域), 非 HF 单存。
存高频热 State 入 HF 单点 → 失跨云容灾 + 锁死 HF 域 (HF 凉则数据丢)。
**裁决**: R2 保留不变, Storage Bucket 不接 R2 位置。Bucket 升级范围仅限逻辑层 (init/entrypoint/gate
等脚本) + Key 池 SQLite 主存, 非接 R2 litestream 目标。litestream replicate 仍 R2, Bucket 不替代。

## §5 命题5: 配额与免费层高频写 (待验)
Zen贴段表: "免费配额 100 GB (Private)" — buckets 主文档未钉死 100GB,
原文仅"buckets have a free storage allowance", 配额须查 storage-limits 页 (本轮未拉)。
关键未验: 100GB Private 是否含 Class A (PUT) 100万次免费 (R2 已知限 Class A 100万/月)。
若 Bucket 免费层含高频 PUT 数限制 → litestream WAL flush 260万次/月估值 (记忆 r2-token 已算)
将触限。但本稿 §4 裁 R2 不迁, Bucket 不接 litestream, 故 Class A 高频写面**不适用** Bucket
(逻辑层脚本低频改 + Key 池低频写, 远低 100万/月), 配额风险低。

## §6 架构变更前提 (§1 拓扑铁律须 Zen 批)
现三层解耦 (CLAUDE.md §1): 环境层 (Dockerfile/GHCR base + bootstrap.sh) / 逻辑层 (Dataset nonoke+nomke)
/ 运营层 (ops/)。
Zen提 Bucket 升级 = **逻辑层从 Dataset 换 Bucket 挂载** = 重大拓扑变更, 触 §1 铁律须 Zen 批准
(CLAUDE.md §0 会话生命周期: "不凭记忆臆测, 不重复已锁定决策, 翻案须 Zen 明确指令")。
本稿结论非裁决, Dataset 现役逻辑层不变。真迁须另会话 Zen 显令 + 三层解耦稿重写 +
sync-space-nonoke.yml/sync-space-nomke.yml 工作流重构 (Dataset push 触 Rebuild → Bucket 挂载无须 Rebuild)
+ bootstrap.sh 拉取逻辑改挂载检测 (Zen贴段"通用挂载检测逻辑"义真但须重设计)。

## §7 升级路径 (若 Zen 批, 候选草图非实施)
非本轮实施, 仅记录供次轮 Zen 据稿判:
1. 建 Bucket (nonoke/omn-logic-bucket dev + nomke/omn-logic-bucket prod), 推现逻辑层 5 件入 Bucket
   (init/entrypoint/gate/litestream/package)
2. Space 设置 UI 挂载 Bucket 到 /logic (read-write), bootstrap.sh 删 hf download 段改挂载检测
3. 加 Key 路径改: hf bucket cp 推 init-nim-keys.sh 新版入 Bucket → 容器内秒级生效, 无 Rebuild 无 Restart
4. R2 保留 (§1 不动), litestream replicate 仍指 R2 不指 Bucket
5. sync workflow 简化: Dataset push 路径改 Bucket sync 路径, 无须 Dockerfile 触 Rebuild
6. dev 24h 验 → prod workflow_dispatch 切 (类比径 C 流程)
风险面: hf-mount NFS 懒加载首读延迟 (高频探活路径须测) / Bucket 配额 (storage-limits 须查钉) /
挂载故障 Space 起不来风险 (类比现 Dataset 拉取失败 FATAL 须有兜底) / Bootstrap 兜底逻辑重设计

## §8 与现役 24h 窗 + ARG 双轨关系
- 24h 窗 (2026-07-27T05:31:55Z 起算, 2026-07-28T05:31:55Z 出门) 现役监控优先级最高, 不受本稿影响
- ARG 双轨 commit 3e36a07 本地锁 (只 commit 不 push 等累积) 仍是待 push 件, 与 Bucket 升级正交
- Bucket 升级纯勘探, 任何真迁动留 24h 窗满 + prod 切完后 Zen 另会话裁

## §9 出典与查证方法
- 官方域拉取 4 页: huggingface.co/docs/hub/storage-buckets (本质) / spaces-overview (Docker Space 基础) /
  spaces-storage (持久盘+挂载) / storage-buckets-access (access patterns + volume mounts)
- 二手博客 (Zen贴段引 "Hugging Face Just Built the S3...") 未采信, 仅官方域作证
- 关键差距: storage-limits 页未拉 (配额 100GB 须此页钉死), Restart 403 官方无证 (社区帖未查)

## §10 待决项 (供 Zen 次轮裁)
1. ✅ 配额已查 (storage-limits 页拉取): Free user/org Private storage 100GB; Class A PUT 免费层硬数未钉
   (文档仅记存储 GB 限非操作次限). 但 §4 裁 R2 不迁 Bucket 不接 litestream, 故 Bucket 仅逻辑层
   低频写 (脚本改动周级非秒级 WAL), Class A 触限风险低. 此项降级为低优先.
2. Bucket 升级真迁否 (§1 拓扑铁律翻案须 Zen 显令) — 本稿非裁决
3. 若真迁: §7 单路草图 + §11 双路草图须 Zen 批准细化择一
4. Restart 403 真伪终判 — 官方无证, 现仓痛面 agent 实证 Key 是 Secret 走 Restart 非 Dataset, Restart 是
   设计正常热生效非痛点; 真痛点=Rebuild 触发 (骨架四件改动) + 7/16 冻 build 非 Restart 403

## §11 Bucket+Dataset 结合使用全维度裁决 (2026-07-28 Zen追问"结合使用可能性")
官方义 (多 volume 共挂铁证, manage-spaces §Mount volumes):
- 同 Space 可单次调多 Volume: `space_volumes=[Volume(type="bucket", mount_path="/logic-bucket"),
  Volume(type="dataset", mount_path="/logic", read_only=True)]` — Bucket read-write + Dataset read-only 共挂
- `set_space_volumes` 替换式但可先 `get_space_runtime().volumes` 读现态再拼接 (官方注 "first read the
  current volumes from the runtime and include them in the new list")
- 关键铁律: "Models, datasets, and Spaces are always mounted as read-only. Only storage buckets support
  read-write mounts." — Dataset 永远只读, Bucket 读写, 共挂天然契合双路 (Bucket 改热件 + Dataset 版本底牌)
- Bucket↔Repo server-side cp: `hf buckets cp hf://datasets/... hf://buckets/...` Xet content hash 迁移
  无重传, 仅 src→Bucket 方向 (Bucket→Repo roadmap 未现) — 双向不同步, 但 Dataset→Bucket 灌初版可用

现仓痛面 (5 轴 agent 深扫结论, 详见 §11.1):
- NIM Key 循环依赖痛点不成立 (Key 是 Space Secret 走 Restart 非 Dataset)
- 逻辑层 push 不触 Rebuild (sync-logic paths:dev/logic/** 与 sync-space paths:Dockerfile trigger 分离)
- hf download 竞速已根治 (K3 --revision 锁 atomic + dash 热修闭环)
- 唯真痛面: init/gate 件改动须 boot 拉新 Dataset 生效 (须 Restart), 非秒级

结合形态 (热件双路 + 稳态件单路):
| 件 | 行数 | 频率 | 归属 | 理由 |
|---|---|---|---|---|
| init-nim-keys.sh | 1069 | 高频热改 | Bucket 热更新 | 池策略/限流/探活秒级生效 |
| gate.js | 464 | 中频热改 | Bucket 热更新 | context guard/限流参调 |
| entrypoint.sh | 286 | 低频稳态 | Dataset 版本化 | PID1 编排+契约根不可移 Bucket |
| litestream.yml | 29 | 极低频稳态 | Dataset 版本化 | R2 红线三因子齐修不动 |
| package.json | 16 | 极低频稳态 | Dataset 版本化 | gate 依赖偶升 |

改造面 (中等):
- entrypoint.sh: +`_pick()` 谓词 ~15行 (查 /logic-bucket/$f 优先回退 /logic/$f) + 5处 /logic/ 引用改写
- bootstrap.sh: 不动 (Dataset 全量注入 /logic 是天然兜底, Bucket 挂载故障 Space 仍能起)
- workflow: 每侧 +2段 (bucket upload + bucket readback) × 2侧 = +4段约 +60行/侧
- Space UI: 每侧 +1 bucket 挂载到 /logic-bucket (read-write, 手动非 git) × 2侧 = 2处 UI 操作

§1 铁律保全:
- litestream 写 R2 域 (*.r2.cloudflarestorage.com), Bucket 挂 HF 域 (s3.hf.co), 两 S3 端点独立正交
- Bucket 仅逻辑层配置态, litestream 永远写 R2 不写任一 HF, R2 跨云容灾语义始封锁
- 2026-07-19 旧裁 "R2 迁 Bucket 永久拒" 针对 R2 位置迁 (litestream target), 本轮 Bucket 仅逻辑层不碰 R2, 正交

历史无先例:
- V3.0 R2 成功时纯 Dataset+R2 (archive/omn-legacy/k3-review-r2-v30.md:85,93,95 明 `--repo-type dataset`)
- 仓内 2110 bucket hit 全 R2/业务词非 HF Storage Bucket (upstream quota-account-buckets.test.ts 等)
- 变量名 LOGIC_BUCKET_REPO 历史命名巧合含 bucket 字样, 语义=Dataset nonoke/omni-logic

收益 vs 风险:
- 收益: init/gate 改动秒级 live mount 生效, 无须 Restart/Rebuild. 解 §10.4 真痛面 (boot 拉新须 Restart)
- 风险:①Bucket 挂载故障 Space 起不来 → bootstrap Dataset 注入 /logic 天然兜底 (_pick 回退)
  ②hf-mount NFS 懒加载首读延迟 → init 探活路径须测
  ③Bucket→Repo 方向 roadmap 未现 → 回滚须 Dataset 侧保底 (设计天然双保底)

总裁: Bucket+Dataset 结合使用部分可行 — 热件双路择优 (Bucket 热版 + Dataset 底牌回退) +
稳态件 Dataset 单路 + litestream 永远 R2. §1 铁律不破. 真迁须 Zen 另会话显令
(CLAUDE.md §0 翻案须明令 + §1 拓扑改须批), 本轮纯勘探非裁决.

§11.1 五轴深扫证据锚点 (agent 报告, 289s 19 工具调用):
- 轴1 频率判分: dev/logic/init-nim-keys.sh:1-1069 / gate.js:1-464 / entrypoint.sh:1-286 /
  litestream.yml:1-29 / package.json:1-16
- 轴2 执行链: entrypoint.sh:107,215,225,243,259 五处硬编码 /logic/ + bootstrap.sh:101 exec 契约根
- 轴3 litestream 正交: dev/logic/litestream.yml:5 bucket=${R2_BUCKET} :11 sync-interval 10s :14 auto-recover false
  (注: 记忆 omn-v30 称 30s 实为 compaction L1 阶梯非 sync-interval, 全 archive 一致 10s)
- 轴4 无先例: archive/omn-legacy/k3-review-r2-v30.md 纯 Dataset+R2; 2026-07-19-script-factcheck.md:126
  旧裁 R2 迁 Bucket 永久拒 (与本轮 Bucket 仅逻辑层正交)
- 轴5 workflow 改造: sync-logic-nonoke.yml:40-45 5件upload + :52-67 sha256 readback;
  sync-logic-nomke.yml:38-43,19 同构仅 dispatch; sync-space-nonoke.yml push paths:[Dockerfile] 触 Rebuild

关联: [[dev-3-8-48-24h-window-armed]] [[storage-bucket-dataset-结合堪察]]
      [[hf-free-docker-build-blocked]] [[r2-token-权限-classa-100万限-余量60]]
      [[omn-three-layer-c-step-landed]] [[omniroute-upstream-entrypoint-drift-v3.8.48]]

---

## §12 单择定局 — Dataset vs Bucket 永续架构 (2026-07-28 Zen已准方向)

Zen三连问后定新向"r2负责备份,dataset和bucket挑一个作为普通存储", 纠偏 omni不存 skills/插件后
定真问"dataset和bucket哪个更适合omniroute永续架构". 三 agent 并行深扫 (中立八维度/Bucket专攻/
Dataset专攻) + 自查官方域 + Zen前次 docs/OmniRoute永续节点方案v2.0.md §5第4步已框此形.

### 一句话裁决: R2 不动 / Dataset 留逻辑层五件 / Bucket 挂 `/data` RW 作运行态持久件层

非二选一取代, 乃各司其职三轴分层. Zen前次 v2.0 §5第4步已规划 Bucket 挂 `/data` RW 但未实施
(现役 /data 仍 ephemeral→litestream R2 仅 storage.sqlite 部分兜底). 本轮深查补全官方铁证落定.

### 三轴分层定局

| 轴 | 介质 | 用途 | RO/RW | 持久性 | 裁决 |
|---|---|---|---|---|---|
| 备份层 | R2 (`*.r2.cloudflarestorage.com`) | litestream target WAL/snapshot | RW(litestream写) | 跨云容灾 | 不动 (§1+旧裁双重锁) |
| 逻辑层五件 | Dataset `hf://datasets/` | init/entry/gate/litestream.yml/package源 | **RO** | git仓独立 | 保留 (版本化+PR+血缘+K3 commit_id锁点四件武器现役已用,迁Bucket全废) |
| 运行态RW件 | **Storage Bucket挂`/data`RW** | or-api-key/init-done/log/state | **RW** | longer than Space | 本轮核心补全 (官方唯一RW持久通道) |

### omniroute真痛点实证 (现役代码 ephemeral 锁)

现役 `/data`=ephemeral (官方铁义 spaces-storage: "lost if Space restarts or is stopped").
运行态写件四枚现役丢/重生成崩溃链:
- `OR_API_KEY_FILE=/data/.or-api-key` (init-nim-keys.sh:45,557,571) — gate.js:52 读此,无env时FATAL崩;
  重生成新key与基座combo key不符链崩
- `INIT_MARKER=/data/.init-done` (init-nim-keys.sh:44,1064) — 丢=增量门fail→重跑全量注册NIM combo触409
- `LOG_DIR=/data/omn-data/log` (init-nim-keys.sh:21) — 历史日志丢
- `_DB_PATH=/data/storage.sqlite` — litestream→R2部分兜底,首启须restore延迟

→ 运行态RW持久件层**只能Bucket** (manage-spaces铁锁: "Only storage buckets support read-write mounts",
  Dataset/Model/Space都RO). 非取向,是RW需求官方唯一通道.

### 与§11结合形关系

§11部分可行(热件双路Bucket+Dataset底牌)针对**逻辑层五件**高频热改 (init/gate改动须Restart);
§12单择定局针对**运行态RW持久件层** (/data子集) — 两问正交不冲突,介质职责分层即统一:
- 逻辑层五件=Dataset (Agent#1/#3裁勿迁,版本化四件武器价值刚性)
- 运行态RW件=Bucket挂`/data` (Agent#2裁条件可行,解ephemeral真痛点)
- 备份层=R2 (全保全不动)

§11热件双路方案仍留作未来若需"逻辑层init/gate秒级生效"时备选 (audit §11改造面草图),
但本轮§12裁决**不动逻辑层五件路径** (现Dataset满足+四件武器保留).

### 牺牲面 (须Zen知的代价)

| 代价 | 缓解 |
|---|---|
| Bucket非版本化(删即永久丢,无git revert) | 运行态件本就低版本化需求(marker/动态secret非源码);源码留Dataset保底 |
| 无PR审阅 | 运行态件非协作件 |
| Bucket→Repo回写未支持(roadmap未现) | 源在Dataset,Bucket是派生挂载,rollback重挂Dataset不须回写 |
| Class A PUT硬数docs未钉(storage-limits页无文字) | 运行态件低频写(boot几次)远低阈,须上线后监控 |
| hf-mount NFS首读延迟 | 须boot探活路径实测 |

### §1铁律全保全三铁证

1. R2不动 — litestream.yml一行不改,仍写`*.r2.cloudflarestorage.com`
2. §1"R2 bucket永不双写"锁R2端点litestream写面,不锁HF Bucket挂载;两S3端点独立正交
   (R2=cloudflarestorage.com域 / HF Bucket=s3.hf.co域,token独立,写者独立)
3. 旧裁"R2迁Bucket永久拒"(audit/2026-07-19-script-factcheck.md:126括号注"litestream R2跨云容灾红线")
   锁作用面=R2位置迁,本轮Bucket挂`/data`不碰R2 target,正交不波及

### 实施路径 (待Zen显令另会话启动)

1. Space UI建Private Bucket (`nonoke/omn-runtime` dev + `nomke/omn-runtime` prod,dev/prod隔离守§1)
2. Space UI挂Bucket→`/data` RW (manage-spaces Volume API或Settings页)
3. Dockerfile/bootstrap/init路径适 (`/data`由ephemeral→Bucket mount,路径不变零改业务逻辑)
4. litestream.yml不动 (仍写R2)
5. dev先验(nonoke/omn),24h绿后prod晋级(nomke/omn)守§1 dev→prod晋级律

### 三agent报出典锚

- 官方域: huggingface.co/docs/hub/spaces-storage (ephemeral+"Buckets are recommended way to persist")
  / storage-buckets (Buckets vs Repositories原表+"only buckets RW")
  / manage-spaces (Volume mount+"Only storage buckets support RW mounts"+set_space_volumes替换式)
  / storage-limits (Free 100GB Private适用所有repo types含buckets,Repo limitations不适用Buckets)
  / storage-buckets-s3 (s3.hf.co端点single-region+302 Limitations)
- 本仓: docs/OmniRoute永续节点方案v2.0.md §5第4步 (Zen前次规划Bucket挂`/data`RW推荐)
  / dev/logic/init-nim-keys.sh:44-45,557,571 / gate.js:52 / litestream.yml:5-15
  / audit本件§11 (结合使用形态已锁)

**Zen已准(2026-07-28本会令"准")§0一句话裁决方向. 真迁实施须Zen另会话显令**
**(CLAUDE.md §0翻案须明令+§1拓扑改须批). 本轮勘探裁决闭环, 非实施.**
**3 commit (3e36a07/cd09d6c/369ab61) 本地锁待Zen手动push (Zen明令"先保存待积累后我手动push").**
