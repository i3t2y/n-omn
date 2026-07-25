# 切换 ② · dev 换 25 key 稳态 — 验证前提 + 退出标准

> 承接 DECISIONS.md 切换五步序列. ① 清空(C2 闭环)后 ② 启动. 本文是事前三钉点(预期参数/共享配额/后台暴露面), 事前钉死避免现场凭感觉判. K3 令三钉点逐条对应.

## 事前三钉点

### 钉 1: 预期参数先算死 (验证标尺)
init 按存活 key 数动态推导 (init-nim-keys.sh:206-211 主推导 + 652-683 M3 probe 后重算, 两段逐字对齐). 25 key 全活:

| 字段 | 推导 | 源码 |
|------|------|------|
| RPM | 25 × 35 = 875 → **cap 300** | init:206 推导 + init:208/667 `[ "$_RPM" -gt 300 ] && _RPM=300` |
| concurrent | 25 × 3 = **75** | init:209/669 |
| minIntervalMs | 60000 / 300 = **200ms** | init:211/671 |

probe 后 auth_dead=0 (全活) 走 elif `限流维持原值` — 故读回 = 推导值不经重算.

**② Resilience 读回预期 = `RPM=300 minMs=200 concurrent=75 maxWaitMs=300000`** (maxWaitMs 不随 key 数变, 固定 300000).

读回非此三数 → 推导链或 cap 逻辑有病 = 验证要抓的.
- 现 7key boot: RPM=245 (7×35=245 未触 cap), cap 路径**未验过**.
- 25key 期待: RPM=875 → 触 cap 300 — **cap 路径首次实证**. 若读回 875 未封顶 = cap 病.

### 钉 2: 双 Space 共享同批 NIM key 配额风险
dev 25key 期 与 nomke 生产 **同一批 25 NIM key**, 两边请求共耗每 key 的 NIM 侧限额.

- 推导 RPM = 限流配置上限, 非真实流量.
- 生产固定低位运行; dev 测试流量克制 (验证性请求, 不压测) → 合计撞 429 概率低.
- **② 期间 call_logs 若现 429 聚簇 → 第一怀疑对象 = 配额共享, 非池子行为本身.** 先查 NIM 侧每 key 429 时间窗是否与生产/dev 请求重叠, 再判池病.

### 钉 3: 后台暴露面临时收敛
dev 现 `GATE_ADMIN_ENABLED` 开态 (gate.js:24,159-165 布尔开关). 生产 25 key 敏感等级 > dev 7 测试 key → 暴露面应随敏感等级走.

- ② 期: **删 `GATE_ADMIN_TOKEN`** → 后台全 404, 纯 `/v1/*` API 模式. (此 Space Secret 变更 = 圣上手动, §2 Restart 不变, 我不触.)
- 验证期结束 / 确需后台 → 再临时配. 退场条件达成先收敛.

## 执行 (圣上手动 Secret 变更 + Restart)

1. Space Secret `NIM_KEYS` 换 25 行 (圣上手动, 值零入会话/零入 git)
2. (钉 3) 删 `GATE_ADMIN_TOKEN` 或确认后台已关 — 圣上判
3. Restart dev Space (§2 圣上手动不变) → bootstrap 拉现役五件 (init 2832f694 等) → 重跑 init
4. 按 release-checklist A 段过九段, **重点:**
   - A1 Resilience 读回 == `300/200/75/300000`
   - A1 probe 汇总 == `25 alive / 0 dead`
5. 之后 1~2 天稳态观察

## 退出标准 (避免"感觉稳了就切")

- [ ] 至少 2 次干净 boot (含 1 次主动 Restart 验 25key 下幂等路径)
- [ ] 九段每次全执行 (init rc=0)
- [ ] 真实请求覆盖 nim-pool + nim-codex 两 combo 各成功
- [ ] 无 OOM / 无重启循环
- [ ] litestream R2 副本 txid 正常推进 (checklist C2)
- [ ] call_logs 成功率无异常塌陷

## ② 采决策数据: 429 实测频率

待裁决问题: 统一后生产限流 — 沿用动态推导 (25key → cap 300 RPM) 还是保留生产保守档 (现 28/1 量级)?

② 结束 call_logs 429 出现频率 = 此裁决依据. 连同结果写进 DECISIONS.md (行名: 生产限流档裁决).

## 进度

- 事前三钉: ✅ (本文)
- Secret 换 25 key + Restart: ⏳ 待圣上手动
- 九段终验 + Resilience 300/200/75 核对: ⏳
- 1~2 天稳态: ⏳
- 退出标准达成: ⏳
- 429 频率采 + DECISIONS 裁决: ⏳
