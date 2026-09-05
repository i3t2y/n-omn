---
name: handoff
description: omn 会话收尾时生成交接块 + 提议 ops/STATUS.md 与 ops/docs/DECISIONS.md 更新 diff。固化 CLAUDE.md §0 生命周期(结束输出交接块供 Zen 归档), 避免交接块格式每轮漂移。triggers: "会话结束" "交接" "收尾" "归档摘要" "STATUS 更新" "DECISIONS 追加" "下一步" "未决问题"
---

# handoff · omn 会话交接块生成

> 用途: 会话结束/里程碑输出交接块 (CLAUDE.md §0 强制), 格式统一防漂移。供 Zen 归档进 ops/。
> SSOT: docs/HANDOFF.md(契约) > DECISIONS > audit。本 skill 只生成不改 SSOT 定义。

## 何时触发
- 会话收尾 / 里程碑节点
- 切换/上线前后状态固化
- 多轮任务间 handoff

## 交接块格式 (≤10 段, 每段精简)

```
## 交接块 — <日期>

### 完成 (本轮)
- <动作 + commit hash + src/ops 路径>
- ...

### 锁定决策 (新增入 DECISIONS, 含理由)
- <日期 · 决策标题: 一句话> → <理由> 
- ...

### 文件变更 (路径 + 要点)
- <path>: <要点>
- ...

### 未决/悬 (待 Zen 判)
- <悬题 + 为何悬 + 我建议选项>
- ...

### 下一步
- <下一动作 + 触发条件 + 谁执行(Zen手动/我可动)>
- ...

### 远端态 (push/部署)
- Dataset: <件 sha256>
- GitHub nomn: <本地 ahead N commit 未推 - §3 禁 push 待Zen>
- 工作树: <剩什么 unstaged>
```

## 提议 diff (STATUS + DECISIONS 生成)

### STATUS.md 更新 diff (新态前置段)
- 新段标题: `## <日期> · <本轮主题>`
- 字段: 本地 HEAD / 本轮 commit / 远端 Dataset sha / 待Zen手动 / boot 后验 (如有)
- 旧段保留 (历史态叠加)

### docs/DECISIONS.md 追加 diff (倒序, 最新顶上)
- 格式: `## <日期> · <决策标题>: <一句话>`
- 次行: <理由 + 出处 (ops/incidents 或 audit path)>
- 与已有 DECISIONS 冲突: 行头显式标 `[翻案]` + 给翻案理由 (Zen 明令乙翻案者)
- 倒序置顶, `---` 分隔

## 守门纪律
- 交接块 ≤10 段, 精简 (长内容引 SSOT 路径不重抄)
- "已验证/已修复"类断言必须给可复核方法 (不得空断)
- 未决标注 must/should/could (可选)
- "下一步"明确执行人: Zen手动 / 我可动 — 不把本我触项写成我可动
- 与 DECISIONS 冲突显式 [翻案] + 理由 (§0 翻案须 Zen 明令)
- 全程不触 Space/生产/凭; commit ask Zen裁决 (§5)
- 留余: 必要时 PushNotification 告知Zen关键落地 (批量动作不用)

## 产物去向
- 交接块输出给 Zen (归档进 ops/)
- STATUS/DECISIONS diff 以提议给 Zen (实际 commit 须Zen批, §5)
- docs/HANDOFF.md 交接时刻状态行同步更新 (本 skill 触发时可一并修 HANDOFF 交接块)
