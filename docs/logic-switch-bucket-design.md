# 逻辑层换源 Bucket — 完整设计文档 (nonoke/omn-logic → xnexus/logic)

> 圣上 2026-08-24 令"换 Bucket 深挖"，**2026-08-25 批走 (B) 换 Bucket 源**。
> 背景: nonoke HF 账号 ToS 违规锁 → boot 拉 nonoke/omni-logic Dataset 403 FATAL。
> 状态: **✅ 已批准实施**（破 §1 三件定态已获圣上显令）。实施顺序见 §七。

---

## 一、问题背景

nonoke 账号锁 → `hf download nonoke/omni-logic` 403 → boot FATAL（start.sh L105）。
逻辑层八件源失效。需换源：非oke 锁后, 从 nonoke 挪到 xnexus。

**关键认知（本会话圣上点破）**: 四件武器（版控/PR/血缘/K3 commit_id 锁/git show 历史）**全绑私库 n-omn, 不绑 Dataset**。换源不丢四件。唯一真成本 = 丢 Dataset 白送的 `--revision` atomic 快照锁。

## 二、现役链路（已核实 start.sh L50-110 + sync-logic-nonoke.yml）

| 段 | 现役 (Dataset) | 详情 |
|----|---------------|------|
| 源 | `dev/logic/` 八件 | entrypoint.sh gate.js init-nim-keys.sh litestream.yml package.json helper.sh omn_redact.py omn_scheduler.py → n-omn 私库 git |
| 推送 | CI `hf upload` 逐文件 | 每文件一 commit, 带 n-omn@SHA 血缘; readback sha256 逐字节验证 |
| boot 拉 | start.sh L87 `hf download --revision <cid>` | 先 `list_repo_commits` 取 HEAD commit_id → `--revision` 锁 atomic 同 commit 全件 |
| 执行 | `/tmp/logic` → `cp -a` `/logic` → exec | **ephemeral 固化, 不 mount** |

**xnexus/logic 不存在**（RepositoryNotFound 404）— 换必须先建。

## 三、为什么 atomic 锁必须手工补（manifest）

现役 push 逐文件（8 文件 = 8 commit 窗口），boot 若在窗口内拉 → 半新半旧错配。**这就是现役必须锁 commit_id 的原因**。

Bucket 非版本化、无 commit_id/revision → **无 atomic 快照**。若也逐文件 PUT，竞速同样复活。

`batch_bucket_files` 可一次传多文件但**仍非真原子**（S3 逐个对象, 中途崩仍半新半旧）。S3 无"一次传 8 文件"原子操作。

**结论: manifest 版本钉是唯一可靠路径**——把 Dataset 白送的 atomic 锁手工搬回来。

## 四、设计

### manifest.json（Bucket 根）
```json
{
  "n-omn": "a1b2c3d",
  "files": {
    "entrypoint.sh": "sha256:...",
    "gate.js": "sha256:...",
    "...": "..."
  },
  "ts": "2026-08-24T00:00:00Z"
}
```
- `n-omn` = 私库 git SHA（血缘锚点）
- `files` = 每文件内容 sha256（一致性校验）
- manifest 是"提交点"，文件哈希是"校验"，半新半旧被哈希抓住

### 推送流程（CI sync-logic）
1. 逐文件 PUT 到 Bucket（先更新业务文件）
2. **最后** PUT `manifest.json`（记 n-omn SHA + 每文件 sha256）
3. readback 校验文件哈希与 manifest 一致（复用现役 sha256 血缘验证逻辑）

### boot 拉取（start.sh §3 改写）
1. 先拉 `manifest.json`
2. 按 manifest 逐文件拉 + **校验每文件 sha256 与 manifest 一致**
3. 不匹配 → 撞到 push 窗口（manifest 旧但文件新）→ **fail 重试**（等 push 完成 manifest 更新后再拉）
4. 全对 → `cp -a` 到 `/logic`

## 五、改动清单（三块 + FT 端点 = 四块）

| 层 | 现役 (Dataset) | 换成 (Bucket) | 改动点 |
|----|--------------|--------------|-------|
| 推送 | CI `hf upload` 逐文件 | CI `batch_bucket_files` + manifest + readback | 新建 sync-logic-xnexus.yml（替代 nonoke 版）|
| boot 拉 | start.sh `hf download --revision` | start.sh S3 拉 + manifest 校验 + 另拉 flaretunnel_endpoints.json | **改 start.sh §3（破 §1 铁律）** |
| 执行 | `/logic` cp 固化 | 同左 | 零改 |
| **FT 端点** | deploy-ft-workers.yml publish-endpoints 推 `nonoke/omn-logic` (Dataset) | **推 xnexus/logic Bucket** | **改 deploy-ft-workers.yml publish-endpoints（2026-08-25 新发现依赖）** |

> ⚠️ **FT 端点是隐藏第 3 改动点**: entrypoint.sh L216/231 读 `/logic/flaretunnel_endpoints.json`
> (start.sh 拉 Bucket 得), 但 deploy-ft-workers.yml L657 原推 `nonoke/omn-logic` (Dataset, 已 403 锁).
> 若只迁 sync-logic + start.sh, FT 桥拿不到 Worker 端点 → FT 全断. 必须一并迁 Bucket.
> 此文件由 deploy-ft-workers 独立写入 (非 sync-logic 8 件), start.sh §3.2 单独拉 (不进 manifest).

## 六、代价清单（诚实）

| 代价 | 等级 | 说明 |
|------|------|------|
| **改 start.sh §3** | **高（破 §1 三件定态铁律）** | 须圣上显令批准; start.sh 是 Dockerfile/README/start.sh 三件之一 |
| **改 sync CI** | 中 | 上传逻辑 + manifest + readback 重写 |
| **建 xnexus/logic Bucket** | 手动 | 须 xnexus 账号 UI 或 `hf buckets create` |
| **丢 HF atomic 快照** | 已补 | manifest 钉回, 但多一套自研机制要维护 |
| **HF_TOKEN 换 xnexus 的** | 配置 | LOGIC_BUCKET_REPO=xnexus/logic + HF_TOKEN 换 |
| **S3 读一致性** | 低 | hf-mount/S3 覆盖读可能 eventual（低写频可忽略）|

## 七、执行序（已批准 2026-08-25, 代码侧已落）

1. 建 xnexus/logic Bucket（圣上, UI 或 `hf buckets create`）⏳ 阻塞
2. ✅ 改 sync-logic CI（新建 sync-logic-xnexus.yml: 上传→bucket + manifest + readback）
3. ✅ 改 start.sh §3（S3 拉 + manifest 校验 + 另拉 flaretunnel_endpoints.json）
4. ✅ 改 deploy-ft-workers.yml publish-endpoints（FT 端点推 xnexus/logic Bucket）
5. ⏳ 首次手动推 8 件 + manifest 到 xnexus/logic（须 xnexus HF_TOKEN）
6. ⏳ 验证: 本地 mock 测 manifest 校验五态(已过) + boot 真验(须 xnexus Space 在线)
7. SSOT 文档落（HANDOFF 待办 + DECISIONS 加段）
8. 圣上批准 commit → push → 切 xnexus/o Space

> 代码侧 2/3/4 已落本会话. 阻塞项 1/5/6 全在 xnexus 写凭据 + xnexus/o 在线确认.

## 八、不变量/护栏

- §1 拓扑: nonoke/omn 仍是唯一 Space; xnexus/logic 是**新 Bucket 源（非 Space）** — **不新建 Space** ✅
- §2 秘钥: xnexus HF_TOKEN 值零入会话/git/文档
- §5 git: add/commit/push 一律 ask 圣上
- start.sh 改动最小化: 只改 §3 拉取段, 不碰 boot 其余

## 九、备选轻路（对比）

| 路 | 改 start.sh? | 建新源? | atomic 锁 | 适用 |
|----|------------|--------|----------|------|
| A 换 Dataset 源 | 不改（只改 env） | 建 Dataset（比 Bucket 简单） | 保留（白送） | 只要解 nonoke 锁 |
| **B 换 Bucket 源** | **改 §3（破铁律）** | 建 Bucket | 需 manifest 钉回 | 要免拉时延 + RW mount |
| C 不换 | 不改 | 不建 | 不动 | nonoke 锁未卡 boot 时 |

若真痛点只是 nonoke 锁拉不到 → **A 明显更轻**（start.sh 一个字节不动）。B 只在要 Bucket 专属能力时值得。