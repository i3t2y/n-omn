---
name: boot-verify
description: 当贴入或读取 HF Space boot 日志时, 按 omn 引导九段清单逐项核对并输出验收表 + Resilience 读回预期 + 证据行, 用于切换/上线前 Boot 健康验收。triggers: "boot 日志" "九段" "init rc" "引导" "Resilience 读回" "probe 汇总" "切换②验收"
---

# boot-verify · omn 引导九段终验

> 用途: 贴入/读取 HF Space boot 日志后, 按九段清单逐项核对, 输出验收表。固化"九段全执行缺一不可 + init rc=0"健康标准 (CLAUDE.md §4), 避免每轮凭会话记忆漏判中间段假健康 (C2 病链教训前两 boot 误判的根)。
> SSOT 九段定义以 ops/release-checklist.md A1 为准 (本 skill 只验不改)。

## 何时触发
- 贴入新 boot 日志 / 读 boot 日志尾段
- 圣上 Restart 后贴回引导日志
- 切换 / 上线 / 大改前 Boot 健康验收

## 九段清单 (逐项核日志实证, 缺一即不健康)

| # | 段 | 日志实证关键词 | 判 |
|---|---|------------|----|
| 1 | 7 registered | `Keys: N registered, ... failed.` | 全键注册到位 |
| 2 | gc_stale | `gc_stale:` 行 (无待删/删N 均可) | pipeline 真跑不静默终断 |
| 3 | Fetching provider IDs | `Fetching provider IDs...` | 进连取段 |
| 4 | Provider IDs | `Provider IDs: N` | 取成功 |
| 5 | Resilience PATCH | `Resilience PATCH HTTP 200` + 读回全字段一致 | 限流三式落定 |
| 6 | combo upsert | `upsert <name>` HTTP 200 或 201 | ★首次建成标 (前病态 boot 从未达) |
| 7 | model register | `check_nim_model_health` 列表 + `override: N applied` | 模型注册 + 基线覆写 |
| 8 | hf_snapshot | `HF Dataset uploaded.` | 副本入 Dataset |
| 9 | init rc=0 | `NIM init 已退出 rc=0` 或等价 | ★无静默终断, 进程自然收尾 |

**关键两标**: combo upsert 真建 (前 C2 病态 boot 从未达) + init rc=0 无静默态 (中间任何段成功不构成健康证据, 必须验到自然收尾)。

## Resilience 读回预期 (按存活 key 数动态推导)

读回字段须与预期一致, 不一致 = 推导链/cap 逻辑有病。源码 `dev/logic/init-nim-keys.sh:206-211` 主推导 + `652-683` M3 probe 后重算 (两段逐字对齐)。

| alive key | RPM | concurrent | minMs | maxWaitMs |
|-----------|-----|------------|-------|-----------|
| 7 (现 dev) | 245 (7×35, 未触 cap) | 21 | 244 | 300000 |
| 25 (切换②预期) | 300 (25×35=875→cap 300, ★首次触 cap) | 75 | 200 | 300000 |

注: RPM=alive×NIM_PER_KEY_RPM(默35), 封顶 300 (`[ $_RPM -gt 300 ] && _RPM=300`); concurrent=alive×3; minMs=60000/RPM 整数截断; maxWaitMs 固定 300000 不随 key 数变。probe 后 auth_dead=0 (全活) 走 elif `维持原值`, 不重算。

## 输出格式 (验收表)

```
## 九段终验 — <boot 时间戳>

| # | 段 | 日志实证行 | 判 |
|---|---|----------|----|
| 1 | 7 registered | <贴实日志行> | ✅/❌ |
...(九段)

九段全执行 ✅/有缺 ❌
关键标: combo upsert <建/未> ; init rc=0 <收尾/静默终断>
Resilience 读回 <实际值> (预期 <预期值>) = <一致/偏差>
```

副发现 (非本轮管灰噪): R2 restore / Next dev 资源探测 / Model alias seed skip 等, 单列不混淆主验收。

## 守门纪律
- 只验日志实证, 不臆测未出现的段
- 读回非预期值 = 病, 必须标出 (尤其 cap 路径首次触时 RPM 必须封顶 300)
- 中间段回显不构成健康证据 (§4), 须验到 init rc=0
- 副发现不归健康判 (单列), 避免掩病
- 全程不触 Space/生产/凭; 只读日志列判
