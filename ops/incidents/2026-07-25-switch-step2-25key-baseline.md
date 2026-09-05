# 切换 ② · dev 换 25 key 稳态 — 验证前提 + 退出标准

> 承接 docs/DECISIONS.md 切换五步序列. ① 清空(C2 闭环)后 ② 启动. 本文是事前三钉点(预期参数/共享配额/后台暴露面), 事前钉死避免现场凭感觉判. K3 令三钉点逐条对应.

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
dev 现 `GATE_ADMIN_ENABLED` 开态 (gate.js:24 纯布尔开关 `=== '1'`, fail-closed; Token 机制已废于 82d6559 saga回填 "gate单开关" 改造). 生产 25 key 敏感等级 > dev 7 测试 key → 暴露面应随敏感等级走.

- ② 期: 设 `GATE_ADMIN_ENABLED=0` → 后台全 404, 纯 `/v1/*` API 模式. (此 Space Variable 变更 = Zen手动, §2 Restart 不变, 我不触.)
- 维护窗口(如剔模型)须后台 → 临时配 `=1`, 用后恢复 `0`. 不再涉及 Token 删除 (机制已废).
- 验证期结束 / 确需后台 → 再临时配 `=1`. 退场条件达成先收敛=恢复 `0`.

## 执行 (Zen手动 Secret 变更 + Restart)

1. Space Secret `NIM_KEYS` 换 25 行 (Zen手动, 值零入会话/零入 git)
2. (钉 3) 设 `GATE_ADMIN_ENABLED=0` 或确认后台已关 — Zen判
3. Restart dev Space (§2 Zen手动不变) → bootstrap 拉现役五件 (init 2832f694 等) → 重跑 init
4. 按 release-checklist A 段过九段, **重点:**
   - A1 Resilience 读回 == `300/200/75/300000`
   - A1 probe 汇总 == `25 alive / 0 dead`
5. 之后 1~2 天稳态观察

## 退出标准 (避免"感觉稳了就切") — 32 key 基线版 (Zen裁决一刷新)

- [x] 至少 2 次干净 boot (含 1 次主动 Restart 验 32 key 下幂等路径): ✅ boot #1 (11:02) + boot #2 (11:22) 双绿, 读回一字不差
- [x] 九段每次全执行 (init rc=0): ✅ 两次均 rc=0
- [ ] **池成分健康 (Zen裁决五第五项, release-checklist B4)**: matrix 四笔全绿 = nim-pool ≥2 笔成功 + nim-codex ≥1 笔成功。达成路径 = Zen从 8 模型意向池剔除挂/极慢模型 (gpt-oss-120b / llama-3.3-70b) → cg52 复跑 matrix 到双 combo 绿 (现 nim-pool 1 笔成功 / nim-codex 0 笔)
- [ ] 无 OOM / 无重启循环: ⏳ 过夜观察 (boot#2 起于 11:22, 明早收)
- [ ] litestream R2 副本 txid 正常推进 (checklist C2): ⏳ 过夜
- [ ] call_logs 成功率无异常塌陷: 429 基线改挂③ (见下裁决三) + 成功率观察 ⏳ 过夜
- [x] GATE_UPSTREAM_TIMEOUT_MS=180000 行为实证生效 (长思考一笔): ✅ glm-5.2 SSE 真流式 + gpt-oss-120b 3.8s keepalive 维持长连接无 30s 错包切

## ② 采决策数据: 429 实测频率 (裁决三改挂③)

原待裁决问题: 统一后生产限流 — 沿用动态推导 (32key → cap 300 RPM) 还是保留生产保守档 (现 28/1 量级)?

**Zen 2026-07-25 裁决三改挂**: 不为一条基线重开 admin 后台 (钉 3 纪律刚执行不破例), 换零成本路径 — ③ 变量切换 R2→生产 bucket omniroute-data 时 litestream 把 dev 期 32 key 同一 storage.sqlite (含 call_logs 全量) 复制到生产 bucket, 切换后从生产侧只读副本一行 SQL status_code 分桶 = dev 期基线白捡。原"生产限流档裁决"时点改挂两项齐后: 429 基线 (③ 后白捡) + ③ 后 24h 风暴特征串计数 = 0, 落 DECISIONS。出处: DECISIONS "429 基线改挂③" 条。

## 执行实录: 32 入池偏差及裁决出处

本文落笔时预案为 25 key (文件名 `-25key-baseline.md` 是落笔时刻计划的历史记录, 改文件名是考古污染, 永保)。Zen重启后 NIM_KEYS 填 32 行 = 地面真值, 与预案偏差 +7。Zen 2026-07-25 裁决一照准 32 (非退回 25):

- **32 是生产实池, 25 是预案假设**: ② 终极目的为验证 ③ 晋级生产真实配置, 直验 32 比验虚构 25 更对准目标。
- **cap 行为等价**: 25×35=875 与 32×35=1120 同远超 300, cap 300 首触已验讫与 key 数无关。
- **最强证据读回**: Resilience 推导按 alive=32 重算 concurrent=32×3=96 (非 25 预案 75), boot #1 (11:02) 读回 `300/200/96/300000` 与 32 推导一字不差, 无 cap 的 concurrent 缩放路径一并验讫 (25 预案验不到的部分)。
- **共享配额风险稀释**: 池变 32 后 429 概率较 25 更低。
- **落库刷新**: STATUS ②行刷 32 + boot #1 全绿; DECISIONS 追加 "② key 池基线 32" 条; 本文文件名保历史不动。**③ 生产以 32 行为准 (非 25)。**

boot #1 (2026-07-25 11:02) 全绿实证: 九段全执行 + init rc=0 + Resilience 读回 `300/200/96/300000` + probe 32 活 0 死 + M7(180000)/heap 4096 读回层面坐实 + 付费墙零触发。详见 DECISIONS 32 基线条。

## 进度

- 事前三钉: ✅ (本文)
- Secret 填 32 key (非预案 25, Zen裁决照准) + Restart: ✅ boot #1 全绿 (11:02)
- 九段终验 + Resilience 300/200/**96** (32×3 缩放, 非 75) 核对: ✅ 读回一致
- boot #2 (11:22) 双绿 = 幂等复现 + admin 404 双验: ✅ Read一刀不差 + `[gate] admin UI: disabled` (GATE_ADMIN_ENABLED=0 裁决二坐实) + bootstrap 自愈复跑 (裁决四设计认账)
- 验收四笔:
  - 长思考一笔 (B3 + GATE_UPSTREAM 180000 实证): ✅ glm-5.2 SSE 真流式 (首 token 2.1s) + gpt-oss-120b 3.8s `: omniroute-keepalive` 注入无 30s 错包切 → 行为闭环
  - 请求矩阵四笔 (B4 裁决五第五项缺口): ✗ nim-pool 笔1 200 (2.2s nemotron-3-super) ✅ / nim-pool 笔2 超时 101s (p2c 命中挂) / nim-codex 笔1 超时 101s (priority 挂无 fallback)。直模型对照: glm-5.2 200/deepseek-flash 200/gpt-oss 90s/200s 超时/llama-3.3-70b 47s/120s 超时。根因 = 池成分病 (gpt-oss-120b + llama-3.3-70b 上游挂/极慢, probe 只测 glm-5.2 无感知), 非 combo 路由非网非 gate
  - 429 基线: 改挂③ (裁决三, 不开后台不读库, 切 R2 生产 bucket 时白捡)
  - 过夜观察: ⏳ (boot#2 起于 11:22, 明早收: 无 OOM/重启循环 + litestream txid 推 + 成功率无塌)
- 退出标准达成: 2 boot ✅ / 九段 ✅ / 长思考 ✅ / 池成分 ⏳ / 过夜 ⏳ / 429 改挂 ✅ — 剩Zen剔挂模型 + 过夜 + Zen手动链三件
- 429 频率采: 改挂③ (上文"429 改挂③"段)

