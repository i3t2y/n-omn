# Storage Buckets 升级堪察 — 逻辑层 Dataset→Bucket 拓扑变更可行性勘探
# 2026-07-28 · 圣上裁"立 buildbook 勘察稿" · 纯文档勘探零代码零部署变更
# ─────────────────────────────────────────────
# 触发: 圣上 2026-07-28 提 Storage Buckets 升级方向, 称胜 Dataset 解"循环依赖"
# (加 Key 须 Restart 致网关停摆) + 热更新 + 架构一致性。本稿堪察真伪非实施。
# 本稿结论非裁决, 不动 §1 铁律 (Dataset 仍现役逻辑层), 待 Supreme 据稿判是否真迁。

## §0 摘要
圣上贴段核心命题 (Storage Bucket 挂载热更新真) **实证成立**。但有四点偏差须校准:
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
- 设计场景: 训练 checkpoint/日志/中间产物/频繁变动文件 — 圣上贴段"专为频繁变动 AI 产物设计"义真
- 访问协议: S3 API + hf://buckets/ 协议 + hf-mount (NFS/FUSE) + volume mounts (Jobs/Spaces)
  (圣上贴段"S3 / hf:// 协议 支持"真, "分片读取快"=Xet chunk-level dedup 真)

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
无须点 Restart 触 Rebuild。圣上贴段"零重启迭代"义真。

## §3 命题3: Restart 403 痛点 (偏差, 须校准)
圣上贴段原文: "7 月下旬免费账号点 Restart 频繁报 403 Quota Limit... 为加个 Key 可能导致网关停摆几小时。"
查证: HF 官方文档 (spaces-overview, spaces-gpus, spaces-storage) **无 Restart 403 Quota 记录**。
现 Omniroute 真痛点审计:
- 现机制 (CLAUDE.md §1 + bootstrap.sh): 逻辑层=Dataset, init-nim-keys.sh 在 Dataset 内。
  加 Key 须 push Dataset → sync-space-nonoke.yml `push: paths: [Dockerfile]` 自动触 Rebuild
  (Dockerfile 变才触, 逻辑层 push 不触 Rebuild 但是须 hf download 拉取生效须重启应用逻辑)
- 真瓶颈: **Rebuild 触发** (非 Restart 按钮)。HF 7/16 后免费层密集推送冻 build (记忆
  hf-free-docker-build-blocked 已锁), 非 Restart 403 Quota。
- "网关停摆几小时" 风险实情: 冻 build 期间 Rebuild 卡死 → Space 旧版本续跑不停摆, 但新 Key
  不生效。若 Rebuild 半途崩 → crashloop 风险 (记忆 omn-v4.3.0-saga crashloop 链有先例)。
**校准**: 圣上贴段"Restart 403"措辞失准, 真痛点="Rebuild 触发链 + build 冻风险"。
但 Storage Bucket 挂载解此真痛点成立 — 改 Bucket 文件秒级生效, 完全避开 Rebuild + build 冻,
无需 Dockerfile 或 Dataset commit。圣上贴段"避开 Restart 按钮 Quota 检查"结论方向对, 机制描述错。

## §4 命题4: R2 迁入 Bucket (不可行, §1 铁律冲突)
圣上贴段原文: "把 R2 的状态同步逻辑也迁入 Bucket 让 OmniRoute 变成纯 HF 生态系统。"
查证: 与 CLAUDE.md §1 铁律硬冲突:
- §1: "R2 bucket 永不双写 (新旧 Space 不得同时在线写同一 bucket)"
- 记忆 r2-token-权限-classa-100万限-余量60: "Storage Bucket 迁移永久拒绝(R2 跨云容灾+WAL语义)"
litestream 0.5.9 replicate 目标须 S3 兼容端点, Storage Bucket S3 API 理论可作 target。
但 §1 拓扑语义: R2 = 跨云灾备层 (Cloudflare 域 非 HF 域), 非 HF 单存。
存高频热 State 入 HF 单点 → 失跨云容灾 + 锁死 HF 域 (HF 凉则数据丢)。
**裁决**: R2 保留不变, Storage Bucket 不接 R2 位置。Bucket 升级范围仅限逻辑层 (init/entrypoint/gate
等脚本) + Key 池 SQLite 主存, 非接 R2 litestream 目标。litestream replicate 仍 R2, Bucket 不替代。

## §5 命题5: 配额与免费层高频写 (待验)
圣上贴段表: "免费配额 100 GB (Private)" — buckets 主文档未钉死 100GB,
原文仅"buckets have a free storage allowance", 配额须查 storage-limits 页 (本轮未拉)。
关键未验: 100GB Private 是否含 Class A (PUT) 100万次免费 (R2 已知限 Class A 100万/月)。
若 Bucket 免费层含高频 PUT 数限制 → litestream WAL flush 260万次/月估值 (记忆 r2-token 已算)
将触限。但本稿 §4 裁 R2 不迁, Bucket 不接 litestream, 故 Class A 高频写面**不适用** Bucket
(逻辑层脚本低频改 + Key 池低频写, 远低 100万/月), 配额风险低。

## §6 架构变更前提 (§1 拓扑铁律须 Supreme 批)
现三层解耦 (CLAUDE.md §1): 环境层 (Dockerfile/GHCR base + bootstrap.sh) / 逻辑层 (Dataset nonoke+nomke)
/ 运营层 (ops/)。
圣上提 Bucket 升级 = **逻辑层从 Dataset 换 Bucket 挂载** = 重大拓扑变更, 触 §1 铁律须 Supreme 批准
(CLAUDE.md §0 会话生命周期: "不凭记忆臆测, 不重复已锁定决策, 翻案须 Supreme 明确指令")。
本稿结论非裁决, Dataset 现役逻辑层不变。真迁须另会话 Supreme 显令 + 三层解耦稿重写 +
sync-space-nonoke.yml/sync-space-nomke.yml 工作流重构 (Dataset push 触 Rebuild → Bucket 挂载无须 Rebuild)
+ bootstrap.sh 拉取逻辑改挂载检测 (圣上贴段"通用挂载检测逻辑"义真但须重设计)。

## §7 升级路径 (若 Supreme 批, 候选草图非实施)
非本轮实施, 仅记录供次轮 Supreme 据稿判:
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
- Bucket 升级纯勘探, 任何真迁动留 24h 窗满 + prod 切完后 Supreme 另会话裁

## §9 出典与查证方法
- 官方域拉取 4 页: huggingface.co/docs/hub/storage-buckets (本质) / spaces-overview (Docker Space 基础) /
  spaces-storage (持久盘+挂载) / storage-buckets-access (access patterns + volume mounts)
- 二手博客 (圣上贴段引 "Hugging Face Just Built the S3...") 未采信, 仅官方域作证
- 关键差距: storage-limits 页未拉 (配额 100GB 须此页钉死), Restart 403 官方无证 (社区帖未查)

## §10 待决项 (供 Supreme 次轮裁)
1. 配额查 storage-limits 页钉 100GB + Class A PUT 免费层限 — 本轮未拉
2. Bucket 升级真迁否 (§1 拓扑铁律翻案须 Supreme 显令) — 本稿非裁决
3. 若真迁: sync workflow + bootstrap.sh 重设计稿 (§7 草图须 Supreme 批准细化)
4. Restart 403 真伪终判 — 官方无证, 若圣上有社区帖铁证可补; 现判真痛点=Rebuild 非 Restart

关联: [[dev-3-8-48-24h-window-armed]] [[hf-free-docker-build-blocked]]
      [[r2-token-权限-classa-100万限-余量60]] [[omn-three-layer-c-step-landed]]
