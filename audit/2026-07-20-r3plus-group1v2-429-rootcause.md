# R3+ 推理层负载验证 · 组1v2 429 根因卡 (2026-07-20)

> R3+ 升级前置负载验证 4 组的第 1 组 (3.8.43 基线)。
> 组1v2 跑出全 429, 本卡钉根因防漂 (K3 审 + Satz 三处精修)。

## 现象

- 组1v2: 20 发串行, `curl --max-time 30`, 间隔 7s, **20/20 全 429 或超时空体**, 0 发 200。
- 序2 手动单发 (`--max-time 60`): `http=200 t=44.5s size=1010`, 见 `reasoning_content` 思考链, 模型 `oc/big-pickle`。
- **序2 组1v3 (5 发串行, `--max-time 75`, 间隔 12s) 数据反转根因卡①**: **5/5 全 200, 0 个 429**, total `2.84~3.69s` (min2.84/median3.0/max3.69), ttfb `1.29~1.82s`,
  **`x-omniroute-latency-ms=2~5`** (上游真处理仅 2~5ms!), `finish_reason:"length"` (max_tokens=16 截断, 16 token 全是 reasoning 思考), `x-omniroute-version=3.8.43`。
- 冷却 90s 单发初判 401 `unauthorized` —— PSK 笔误伪装 (`OMN_PSK` vs gate `INTERNAL_PSK`), 与 429 无关。

## 根因 (三因子, 缺一不构成现象)

1. **opencode 上游侧延迟方差极大 (2ms~44.5s), 3s 常态 + 偶发长 tail**
   —— `oc/big-pickle` 走 **opencode/noauth**, **不经 8 NIM key 池** (日志 `Using opencode account: noauth`; NIM 仅服务 `nvidia/*`)。
   ★ 组1v3 反转根因卡①原写: **非"thinking 模型常态 44.5s"** —— 组1v3 `x-omniroute-latency-ms=2~5` (上游真处理 2~5ms), total 3s 几乎全是网络/流式传输, 非模型思考耗时。max_tokens=16 + `finish_reason:"length"` 表思考在 16 token 内已截断 (reasoning_tokens=16)。
   ★ **header 语义待考备查**: `x-omniroute-latency-ms=2~5` 若真是"上游处理耗时"则与 ttfb 1.3~1.8s 矛盾 (首字节 1.5s 才到, 上游不可能 2ms 处理完) —— 更可能 = 路由/决策耗时, 非上游驻留。**勿拿 2~5ms 反推"opencode 很快、慢全在网络"** —— 结论靠 60s 手动原始观测 (44.5s tail 硬证据), 不靠此 header 撑腰。
   ★ **44.5s = opencode 上游侧 transient 慢/排队 (免费层限流/调度)**, 非模型非 gate 非思考耗时。`max_tokens=16` 同条件下: 组1v3 5 发 2~5ms, 序2 手动 1 发 44.5s —— **方差来自 opencode 平台侧, 与 ping prompt 复杂度无关**。
   ★ 精修 (Satz 校正一): "auto 选 key 路由到 big-pickle" 表述错误。auto combo 经 **LKGP 钉死 opencode**, 与 NIM 池无关。
   ★ 精修 (Satz 校正二): 非"路由策略选错模型" —— 是**池坍缩后 LKGP 只剩唯一活口**: ddgw 全家 418 结构性死亡、nvidia 部分模型 410 EOL, 32 目标里能通的恰好是个 opencode 路径。**修复指向池卫生 (移除死目标、让快模型回池), 非调 auto 路由权重** —— 此区分决定下一步动作性质。

2. **gate `CONCURRENT_LIMIT=1`**: 单发占槽全程, 窗内后发 `tryAcquire` 判拒 `_active>=1` → 429 (设计内背压, 非死锁/非状态锁)。**组1v3 间隔 12s 全 200 证明 1 槽稳态下背压可避**; 组1v2 7s 间隔撞组1v2 时序内的 44.5s tail 占槽窗 → 20/20 全 429。

3. **`curl --max-time 30` < 44.5s tail**: 序2/组1v2 时序内撞 opencode 44.5s tail 时, 超时空体, 曾误判 "hang", 实为 opencode 上游 transient 慢 (非 thinking 模型常态行为)。组1v3 `--max-time 75` 覆 tail, 5/5 通。

## 佐证

- **401** = 测试脚本 PSK header 笔误: 脚本 sed 取 `OMN_PSK=` (空), gate 真取 `INTERNAL_PSK` (L31), 双通道校验 `safeCompare(空, 真)` false → 401 (gate.js L177/190 自拒, 上游未触)。已修 `INTERNAL_PSK`, 401 消。
- **8 NIM key 注册读回正常**, 非病 —— 与 big-pickle 走 opencode 旁证二次印证。

## 数学 (有效吞吐, 组1v3 实测校准)

- 组1v3 实测常态 total ≈ 3s (`x-omniroute-latency-ms=2~5` + 网络/流式传输)。
- `C=1` 常态: `60/3 ≈ 20rpm` (远低 28rpm 桶, 桶非瓶颈, 1 并发是)。
- `C=1` 最坏 (撞 44.5s tail): `60/44.5 ≈ 1.3rpm` —— tail 偶发, 非稳态。
- 尾延迟方差 (opencode 上游侧): 组1v3 p50~3s vs 序2 单发 44.5s —— **方差量级 15 倍**, 来自 opencode 平台排队/限流, 不可预测, 客户端须 75s 超时兜底。
- K3 Q4 估 `17rpm` 基于 `3.5s/req` —— 组1v3 实测 3s 量级接近, K3 Q4 估算**仍站得住** (常态); **但 tail 44.5s 是 K3 Q4 未覆盖维度**, 真实单用户 p95 受 opencode 平台支配。
- `C=3≈20rpm×3=60rpm`(被 28rpm 桶限→28rpm), `C=5≈100rpm`(被 28rpm 限); **提并发后 28rpm 令牌桶才从冗余变生效约束**, 届时才需 re-evaluate 桶。
- 衔接 K3 问题 4 备忘: R5 第一杠杆 = 放宽并发数 3~5, 非动 rpm; 但提并发后**必同步评估 28rpm 桶** (C=3 时桶成新瓶颈)。

## 遗留算术 (组1v3 rerun 钉死)

★ 精修 (Satz 校正三): 组1v2 7s 间隔 × 20 发 (跨度 ~133s) 且 20/20 全 429, **单个 44.5s 占槽窗盖不住全程** —— 因 opencode 延迟方差大, 时序内大概率**多次长 tail 占槽首尾相接** (44.5s tail + 期间又一长 tail), 每次长 tail 锁 1 槽期间 7s 间隔全后发撞 429。
**组1v3 钉死**: 5 发 start/end 戳 `12:24:00→12:25:04` (span ~63s), 每发 total ~3s + 间隔 12s, **5/5 全 200, 0 个 429** —— 间隔 12s 错开 + 未撞 opencode 44.5s tail, 占槽窗互锁未触发。**遗留算术闭合: 44.5s tail 占槽 + 间隔不足 = 组1v2 全 429; 间隔 12s 避开 + tail 未至 = 组1v3 全通**。

## 行动

1. ✓ 测试 `curl --max-time 75` (组1v3 验证, 5/5 通, 覆 3s 常态 + 44.5s tail 兜底)。
2. ✓ 组1v3 "before" 基线已建 (min2.84/med3.0/max3.69 + ttfb1.5s + 0 个 429), 池卫生 + C=3 动作后做 "after" 对比。
3. **序3 拆 3a 探针先行** (外部可行, /v1 推理路径, 零重启零风险, ~10min) → 据结果定 b/c 分支 (见下"序3 拆 3a 探针先行"段)。
4. `CONCURRENT_LIMIT 1→3` (gate 参数注入处改, 零 rebuild) 后补组2 并发观测。
   ⚠ **与 b 重启合并**: 3a 示做 b → b init 扩展 + C=3 同次 Dataset commit + 同次 Restart (重启次数硬约束); 3a 示走 c → C=3 单独 Restart (见下"序4 不阻塞")。
5. 客户端侧建议 (组1v3 TTFB 钉): SSE 流式消费 + 超时 ≥75s 兜底 opencode tail 偶发。

### 序3 拆 3a 探针先行 (Satz 裁决, 池卫生第一步非写, 是诊断池里剩甚么活)

★ 此前"受阻"是**假象** —— 它困住的是 3b (死目标移除, 写操作), 但**池卫生第一步非写, 是诊断池里还剩甚么活**, 此步走 `/v1/chat/completions` + PSK **完全外部可行, gate 白名单内**, 之前被漏掉。

**3a 探针 (零重启零风险 ~10min)**:

- **探活**: `POST /v1/chat/completions`, `model:"nvidia/<model>"` 逐模型直发 (**绕开 auto/LKGP**), `max_tokens:16`, 看哪些 200、哪些 410/418。
- **关键预期**: nvidia 池未必全死 —— 日志里确认 EOL 的只有 `z-ai/glm-5.1` 一个模型, 8 NIM key 下挂的其他模型可能活着; LKGP 钉死 oc 只因**首发恰好先试 glm-5.1 失败后落到 oc**。
- **key 轮转旁证**: 同一活模型连发 8+ 发, account 轮转在 Space 日志侧看 (`Using nvidia account: XXXX...` 轮换), 外部只看活/死。
- **模型清单来源**: 先跑 `/v1/models` 拿 nvidia 段作探针目标清单。

**3a 分支逻辑 (现定死, 免临场犹豫)**:

| 3a 结果 | 含义 | 动作 |
|---------|------|------|
| nvidia ≥1 活模型且响应快 (秒级) | 池卫生有真实收益: 剪掉死目标后 auto 可分散到 nvidia 快模型, p95 脱离 opencode 单方差支配 | **走 b**: init 脚本扩展 combo/provider 管理 (启动时 Cookie 直连上游, 禁 ddgw、剪 EOL 模型); **与序4 C=3 合并一次 Dataset 提交 + 一次 Restart** |
| nvidia 全死或同样高方差 | 池里实际只有 oc/big-pickle 一个活口, 池卫生只剩去噪价值 (首发 fallback 链 2.4s) | **走 c**: 死目标清单记 audit 备查, b 不做, 序4 单独推进 |

**a 方向 (开 ADMIN_ENABLED 拍照) 排除**: 白名单只读 GET 改不了池, 诊断信息又已从 SSE 日志里拿全 (Trying 序列 + 418/410 逐目标错误即现成池态快照), 为它付一次生产重启 + 后台暴露面收益为零。

**b 若做, 纪律照旧**: `/api/combos` schema 未文档化, 先在 init 里 GET 读回结构、log 出来, 下一跳再写 —— fail-closed 分两跳走, 不盲写 (init 脚本当初立下的规矩, 池卫生不值得破坏)。

### 序4 不阻塞 + 重启合并硬约束

- 序4 (C=1→3) 与池卫生无依赖, 本并行推进; 真正要管的是**生产重启次数**: 无论 b 还是 C=3, 都是改 Dataset 逻辑层 + Space Restart, 每次 Restart = 一次 restore 实战 (已验安全但没必要多做)。
- **3a 示做 b → b 的 init 扩展 + C=3 的 gate 参数改动同一次 Dataset commit、同一次 Restart, 一次烘焙两变更**。
- **3a 示走 c → C=3 单独一次 Restart**。

### C=3 落地后组2 设计微调

- 3 并发同发, 预期从 "3×44.5s 串行 + 2 发 429" 变 "3 发并行各自约 3s (常态)"。
- 同盯 opencode 的 per-IP 限流是否被 3 并发触发 (noauth 匿名通道对并发敏感, 若触发则说明 C=3 的上限被平台侧锁死, C=5 不必试)。
- 28rpm 桶在实测流量 (~1rpm) 下不触达, 数学段 "C=3 后桶成新约束" 保留为理论注记, 实操不阻塞。

## 接入建议决策点 (组1v3 TTFB 钉死)

组1v3 实测: **ttfb=1.29~1.82s, total=2.84~3.69s** → ttfb≈**不是 40s 而是 ~1.5s**。

- `x-omniroute-latency-ms=2~5` + body 见 `data:` SSE chunks (reasoning_content 流式下发) → **reasoning 是流式下发, 连接一直活着**。
- 即 opencode 平台侧延迟方差 (2ms~44.5s), 流式响应**始终先发首字节** (非"思考完才吐")。
- **下游接入建议 = SSE 流式消费** (首字节快, 1.5s 得反应, 后续思考流式增量); **超时兜底 ≥75s** (保留 opencode 44.5s tail 偶发窗口, gate 180s 内)。
- 即**两条建议都用**: SSE 消费 (常态体验) + 75s 超时兜底 (tail 偶发)。

## 组1v3 测量结果 (修正版基线, 2026-07-20 12:24 CST)

- **5 发串行**, `--max-time 75`, 间隔 12s —— **5/5 全 200, 0 个 429**。
- total: `min=2.84s (#4) / median=3.0s (#2) / max=3.69s (#1)`。
- ttfb: `min=1.29s (#2) / median=1.40s (#3) / max=1.82s (#1)`。
- 上游 `x-omniroute-latency-ms=2~5`, `x-omniroute-version=3.8.43`, `x-omniroute-model=big-pickle`, `x-omniroute-provider=oc`, `finish_reason:"length"` (max_tokens=16 截断, 16 token 全 reasoning)。
- model: **big-pickle 5/5** (得证: 池坍缩 LKGP 钉死 opencode/big-pickle, 无分散)。
- start/end 戳: `12:24:00.875 → 12:25:04.704` (span ~63s), 每发 ~3s + 间隔 ~12s, 时序见 `/tmp/r3plus-g1v3.log`。
- 闭合遗留算术: 间隔 12s 错开 + tail 未至 → 全通; 组1v2 7s 间隔撞 44.5s tail 占槽 → 全 429。
- 产出: **池卫生 + C=3 两步动作的 "before" 对照组已建**, ~6min 成本兑现。

---

## 修订后总序列 (Satz 出, gate 侧全调优在 3.8.43 烘焙稳后再升版)

排序原则: 一次只动一层, 3.8.48 验收时若有差异归因无歧义。组2 放第 5 序而非现在 —— 1 槽下只复现 429 风暴, 提并发后才有"放行面"可测。

| 序 | 动作 | 层 / 成本 | 产出 |
|----|------|-----------|------|
| 1 | audit 根因卡落档 | 10min | 根因防漂 |
| 2 | 组1v3: 5 发串行修正版 | ~6min | "before" 延迟基线 |
| 3a | 池卫生探针: /v1 逐 nvidia 模型直发 (绕 auto/LKGP) 探活 | /v1 推理路径 零重启 | 活/死清单 + 时延, b/c 分支依据 |
| 3b/c | 据 3a: b (init 扩展剪死目标) 或 c (死目标记 audit 备查不写) | Dataset + Restart | b 与序4 合并同次 重启 |
| 4 | `CONCURRENT_LIMIT 1→3` | gate 参数注入处改 零 rebuild | R5 第一杠杆落地 (与 b 合并重启) |
| 5 | 组2: 3 并发 | ~2min | 放行面: 3 并行完成 vs 串行 3×44.5s; 盯 opencode per-IP 限流 |
| 6 | 组3 长上下文 + 组4 错误注入 | ~10min | 180s 窗口余量 + 终态错误格式 |
| 7 | 冻结 gate 全变更, 烘焙后 upgrade 3.8.48 | 六条验收照旧 | 升级归因干净 |

---

*2026-07-20 R3+ 组1v2 429 根因卡 · K3 审认可 + Satz 三处精修 (big-pickle 走 opencode 非 NIM 池 / 池坍缩 LKGP 非路由误选 / 占槽相接遗留算术经组1v3 钉死) · 序2 组1v3 反转根因卡①(44.5s 是 opencode 上游 tail 非 thinking 常态, 3s 常态) · header 语义待考备查 (latency-ms=2~5 疑路由耗时非上游驻留, 勿反推 opencode 快) · TTFB 钉 SSE 流式消费 + 75s 兜底 · 升级前置 · 序3 拆 3a 探针先行 (/v1 推理路径外部可行零重启, 之前被漏; 据 nvidia 活死清单定 b/c, b 与序4 C=3 合并同次 Dataset+Restart) · 数学: C=3 后 28rpm 桶成新瓶颈理论注记实操不阻塞*
