# R3+ 推理层负载验证 · 组1v2 429 根因卡 (2026-07-20)

> R3+ 升级前置负载验证 4 组的第 1 组 (3.8.43 基线)。
> 组1v2 跑出全 429, 本卡钉根因防漂 (K3 审 + Satz 三处精修)。

## 现象

- 组1v2: 5 发/20 发串行, `curl --max-time 30`, 间隔 7s, **20/20 全 429 或超时空体**, 0 发 200。
- 手动直发 (PSK 修正后, `--max-time 60`): `http=200 t=44.5s size=1010`,
  body 头见 `delta.reasoning_content:"Thinking. 1. **Analyze the Request**..."` —— **reasoning 思考链**, 模型 `oc/big-pickle`。
- 冷却 90s 单发初判 401 `unauthorized` —— PSK 笔误伪装, 非 429 复发。

## 根因 (三因子, 缺一不构成现象)

1. **`oc/big-pickle` 为 thinking 模型, 单 req ≈ 44.5s (观测簇 24~89s)**
   —— 走 **opencode/noauth 账号**, **不经 8 NIM key 池** (NIM key 仅服务 `nvidia/*`; 日志 `Using opencode account: noauth` 旁证)。
   ★ 精修 (Satz 校正一): "auto 选 key 路由到 big-pickle" 表述错误。auto combo 经 **LKGP 钉死 opencode**, 与 NIM 池无关。
   ★ 精修 (Satz 校正二): 非"路由策略选错模型" —— 是**池坍缩后 LKGP 只剩唯一活口**: ddgw 全家 418 结构性死亡、nvidia 部分模型 410 EOL, 32 目标里能通的恰好是个 thinking 模型。**修复指向池卫生 (移除死目标、让快模型回池), 非调 auto 路由权重** —— 此区分决定下一步动作性质。

2. **gate `CONCURRENT_LIMIT=1`**: 单发占槽全程, 窗内后发 `tryAcquire` 判拒 `_active>=1` → 429 (设计内背压, 非死锁/非状态锁)。

3. **`curl --max-time 30` < 44.5s**: 超时空体, 曾误判 "hang", 实为真慢 (thinking 模型正常行为)。

## 佐证

- **401** = 测试脚本 PSK header 笔误: 脚本 sed 取 `OMN_PSK=` (空), gate 真取 `INTERNAL_PSK` (L31), 双通道校验 `safeCompare(空, 真)` false → 401 (gate.js L177/190 自拒, 上游未触)。已修 `INTERNAL_PSK`, 401 消。
- **8 NIM key 注册读回正常**, 非病 —— 与 big-pickle 走 opencode 旁证二次印证。

## 数学 (有效吞吐)

- `C=1`: `60/44.5 ≈ 1.3rpm`。
- K3 Q4 估 `17rpm` 基于 `3.5s/req` 小模型假设; **thinking 模型下不成立 (实测 13 倍差)**。
- `C=3 ≈ 4rpm`, `C=5 ≈ 6.7rpm`; **28rpm 令牌桶始终非瓶颈** (1 并发 + thinking 单 req 才是真实瓶颈)。
- 衔接 K3 问题 4 备忘: R5 第一杠杆 = 放宽并发数 3~5, 非动 rpm。

## 遗留算术 (待组1v3 rerun 钉死)

★ 精修 (Satz 校正三): 组1v2 若为 7s 间隔 × 20 发 (跨度 ~133s) 且 20/20 全 429, **单个 44.5s 占槽窗盖不住全程** —— 大概率**两个占槽首尾相接** (手动那发 44.5s + 脚本期间又一发漏网成功后继续占)。
组1v3 rerun **每发记录 start/end/status 时间戳**, 即可把互锁算术彻底闭合。

## 行动

1. 测试 `curl --max-time ≥75` (gate 180s 内, 覆 44.5s 主簇; ~89s 尾部可能裁 1-2 发记截尾样本)。
2. 池卫生: ddgw 移除/压底, nvidia EOL 模型修剪 (410), autoSync 决策, nvidia 定向探针验 8 key 轮转。
3. `CONCURRENT_LIMIT 1→3` (gate 参数注入处改, 零 rebuild) 后补组2 并发观测。
4. 客户端侧建议: SSE 流式消费 + 超时 ≥75s (TTFB 观测见组1v3 决定写"调大超时"还是"改 SSE 消费"哪条)。

## 接入建议决策点 (组1v3 TTFB 观测决定)

组1v3 加 `-w 'ttfb=%{time_starttransfer} total=%{time_total} http=%{http_code}'`:

- **若 ttfb≈40s, total≈44.5s**: opencode 全程无字节、思考完才一次性吐 → 客户端干等 → 建议调大超时。
- **若 ttfb≈2s, total≈44.5s**: reasoning 在流式下发 → 连接一直活着 → 建议客户端改 SSE 消费。

此区分直接决定下游接入建议写哪条。

## 组1v3 测量设计 (修正版)

- **5 发串行**替代 20 发 (节省 HF + 时间), `--max-time 75`, 间隔 12s。
- 补 TTFB 观测 (上)。
- **n=5 不报 p95** —— 报 `min/median/max + 429 计数`。
- 池坍缩现状下 5 发大概率全中 `oc/big-pickle`, 无分散可验 —— 组1v3 的真实产出是**延迟分布 + 429 复发率的 "before" 快照**, 即**池卫生 + 提并发两步动作的对照组**, 值得跑, ~6min。
- 每发记 start/end/status 时间戳 (闭合遗留算术)。

---

## 修订后总序列 (Satz 出, gate 侧全调优在 3.8.43 烘焙稳后再升版)

排序原则: 一次只动一层, 3.8.48 验收时若有差异归因无歧义。组2 放第 5 序而非现在 —— 1 槽下只复现 429 风暴, 提并发后才有"放行面"可测。

| 序 | 动作 | 层 / 成本 | 产出 |
|----|------|-----------|------|
| 1 | audit 根因卡落档 | 10min | 根因防漂 |
| 2 | 组1v3: 5 发串行修正版 | ~6min | "before" 延迟基线 |
| 3 | 池卫生: ddgw 移除、nvidia 修剪、autoSync、nvidia 探针验 8 key 轮转 | runtime API/Dataset 零 rebuild | 池深 1→N, 分散性回归 |
| 4 | `CONCURRENT_LIMIT 1→3` | gate 参数注入处改 零 rebuild | R5 第一杠杆落地 |
| 5 | 组2: 3 并发 | ~2min | 放行面: 3 并行完成 vs 串行 3×44.5s; 盯 opencode per-IP 限流 |
| 6 | 组3 长上下文 + 组4 错误注入 | ~10min | 180s 窗口余量 + 终态错误格式 |
| 7 | 冻结 gate 全变更, 烘焙后 upgrade 3.8.48 | 六条验收照旧 | 升级归因干净 |

---

*2026-07-20 R3+ 组1v2 429 根因卡 · K3 审认可 + Satz 三处精修 (big-pickle 走 opencode 非 NIM 池 / 池坍缩 LKGP 非路由误选 / 占槽相接遗留算术待 rerun 钉) · 升级前置 · 下一步组1v3*
