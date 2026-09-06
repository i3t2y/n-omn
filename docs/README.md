# n-omn 文档入口

> 当前事实源（源头 SSOT）: [docs/HANDOFF.md](HANDOFF.md) *·* [docs/ops/STATUS.md](ops/STATUS.md) *·* [docs/ops/DECISIONS.md](ops/DECISIONS.md) *·* 宪法 [../CLAUDE.md](../CLAUDE.md)
>
> 不参照本月每 个文档里的描述；有冲突以他们更正为准。

---

## 生产（2026-09-05 时态）

```text
消费者                          部署                                数据
─────────────                  ────────────                       ──────────
hermes (nexus)                   space/xnexus/o → omn.360710.xyz
Claude Code / Codex    →─→─→─→─→─→ CF Pages (scripts/pages, ho-proxy)
                                → gate (logic/, Bearer PSK → 20128)
                                → OmniRoute 3.8.50 (BASE_IMAGE)
                                                │
                                       R2 litestream (omn-data bucket)
```

| 链接 | 路径/值 |
|------|---------|
| **生产 URL** | `https://omn.360710.xyz/v1` (PSK only) |
| **唯一 Space** | `xnexus/o` (私有 Space, 仅 zi 全家桶安全渡) |
| **上游基座** | `ghcr.io/i3t2y/omn-base:stable` (3.8.50 锁 tag+digest) |
| **数据桶** | R2 `omn-data` (litestream 副本) |
| **HEALTH** | `boot 9段 + init rc=0 + [heapwatch] 无 shed + chat_admission 无 queue_timeout` |
| **栈顶** | `NODE_OPTIONS=--max-old-space-size=4096` (Space Variables) |

## 现役文档地图

| 口述 | 用途 | 状态 |
|------|------|------|
| **[CLAUDE.md](../CLAUDE.md)** | 宪法 v4 (Zen) 会话生命周期/纪律/边界 | 唯一宪法 |
| **[HANDOFF.md](HANDOFF.md)** | 系统契约：架构不变量/排障入口/部署链路 | SSOT ① |
| **[DECISIONS.md](DECISIONS.md)** | （一句话）锁定日志 · 最新 2026-09-05 | SSOT ② |
| **[ops/DECISIONS.md](ops/DECISIONS.md)** | （账本）SSOT 全量决策 | SSOT ③ |
| **[ops/STATUS.md](ops/STATUS.md)** | 当前部署=commit/变量快照/取证命令 | 活跃 |
| **[layout.md](LAYOUT.md)** | 仓库目录布局 + 搬迁史 | 单页 |
| **[ops/incidents/](ops/incidents/)** | 事故记录（七段式） | 只增 |
| **[audit/](audit/)** | 事件日志档案 | **只增, 不删不整理** |
| **[archive/](archive/)** | 版本快照博物馆 (4.2.3-5.1 etc) | 只读 |

---

## 排障快速入口

| 症状 | 查询链接 |
|------|----------|
| Space 得起但收不到流量，封点击 | `tools/omn-log-query.py` |
| `queue_timeout / 503_waiting_in_queue` | chat_admission shed 已打开 `CHAT_QUEUE_TIMEOUT_MS` 看 STATUS |
| `not found OR_API_KEY` | `docs/HANDOFF.md` / 或在生产 Space Variables 回复 |
| Bucket 403 / 拉取失败 | start.sh L56 `LOGIC_BUCKET_REPO` 要看 xnexus/logic |
| 生产"反常降级" | docs/audit/ 前 56 件 = 历次决策取证链 |
| **收拾一切残余老名头** | docs/archive/ — 4.2.3-5.1 全部在 |

## 读写规矩

- **不删 audit 任何一页**（宪法 §3 明）；不"清理"docs/ops 事件日志
- 物理文档（HANDOFF/decisions/STATUS）只修不删空目录
- 未写入 CLAUDE.md 前，未来消费端不是终点站；空间有设计误解自己先出错
- **一句话**：查任何事实先开 HANDOFF, 没有 -> STATUS, 还没有 -> DECISIONS.md, 以上都没有>问

---

**旧版入口**: [archive/](archive/) 保留参考 · v4.2.3 时代快遗刻
*README 2026-09-05 重写 · 对应 Zen 5 租库体终态（commit 92d32e6 → 0cabffe → fafb005）*
