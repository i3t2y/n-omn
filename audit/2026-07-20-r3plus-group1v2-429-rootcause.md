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
   ★ **header 语义备查 (序3a 3 项 latency-ms 对照修)** — 原写"语义存疑"需细化: `x-omniroute-latency-ms` **语义随路径而变**:
     · nvidia 路径: 此 header = **真上游生成耗时** (3a 实证: llama-3.1-8b `latency-ms=89~111` + versions/tokens-out=16; glm-5.2 `900ms`; minimax-m3 `128ms`; deepseek-v4-flash 偶 `14949ms` tail — 数量级随模型/调用变, 非路由决策值)。
     · opencode/big-pickle 路径: `2~5ms` (组1v3) —— 此值与 nvidia 真生成同 header 但量级异常小, 大概率 = opencode 边缘缓存命中路 / 决策耗时, **非模型生成驻留**。
     · **故勿拿 opencode 路径下的 2~5ms 反推"opencode 全快、慢全在网络"** —— nvidia 路径下此 header 才显真生成耗时。结论 (44.5s tail 硬证据靠 era2 60s 手动观测) 不靠此 header 撑腰。
   ★ **44.5s = opencode 上游侧 transient 慢/排队 (免费层限流/调度)**, 非模型非 gate 非思考耗时。`max_tokens=16` 同条件下: 组1v3 5 发 2~5ms, 序2 手动 1 发 44.5s —— **方差来自 opencode 平台侧, 与 ping prompt 复杂度无关**。
   ★ 精修 (Satz 校正一): "auto 选 key 路由到 big-pickle" 表述错误。auto combo 经 **LKGP 钉死 opencode**, 与 NIM 池无关。
   ★ 精修 (Satz 校正二): 非"路由策略选错模型" —— 是**池坍缩后 LKGP 只剩唯一活口**: ddgw 全家 418 结构性死亡、nvidia 部分模型 410 EOL, 32 目标里能通的恰好是个 opencode 路径。**修复指向池卫生 (移除死目标、让快模型回池), 非调 auto 路由权重** —— 此区分决定下一步动作性质。

2. **gate `CONCURRENT_LIMIT=1`**: 单发占槽全程, 窗内后发 `tryAcquire` 判拒 `_active>=1` → 429 (设计内背压, 非死锁/非状态锁)。**组1v3 间隔 12s 全 200 证明 1 槽稳态下背压可避**; 组1v2 7s 间隔撞组1v2 时序内的 44.5s tail 占槽窗 → 20/20 全 429。

   **R3+ §四第①步勘注 (双层并发槽 + gate 限流实存)**: 原卡归因 "gate `CONCURRENT_LIMIT=1`" 单独为第一杠杆 **欠定**。只读核 gate.v43-merged.js: `tryAcquire` 确在 /v1 推理路径 L199-201 被调, 判拒自发 429 `Retry-After:3` **无上游头** (`x-omniroute-request-id`/`provider` 缺) — §四第①步 5并诊断实证 #4/#5 = 此形态; 而 #2/#3 早期态 429 **带上游头** = 上游 requestQueue 签发。**双层并发槽同=1 期任一可签 429, 单独归因 gate 欠定**。C=3 实现层位补正: **上游 `requestQueue.concurrentRequests` (init L145 PATCH /api/resilience 落定) 为主, gate L40=3 保留双保险**。init L142 原注释 "gate.js 零限流代码" 不实, 已勘误 (见 init-nim-keys.sh L141-147 注释块)。

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

## 序3a 探针结果 (2026-07-20 12:47 CST, b/c 分支定 b)

`/v1/models` GET 200 拿 52KB 全清单: **nvidia 124** / combo 29 / opencode 8 / theoldllm 8 / veoaifree 6 / duckduckgo 6 / mimocode 1 / chipotle 1。nvidia 124 含大量非 chat (embed/rerank/ASR/translate/vision-detector/reward), 探针圈 12 chat 候选 × 2 发 = 24 发, `--max-time 30`, 间隔 4s。

| 模型 | 判 | #1 | #2 | 死因 |
|------|----|----|----|------|
| **meta/llama-3.1-8b-instruct** | **活 2/2** | 200/2.36s | 200/2.16s | latency-ms=89/111, tokens-out=16, finish=length |
| **z-ai/glm-5.2** | **活 1/2** | 403/9.07s | 200/4.84s | latency-ms=900, tokens=14, finish=stop |
| **deepseek-ai/deepseek-v4-flash** | **活 1/2** | 400/1.54s(空体) | 200/20.74s | latency-ms=14949 (tail), tokens=640 reasoning |
| **minimaxai/minimax-m3** | **活 1/2** | 400/1.46s(空体) | 200/5.85s | latency-ms=128, tokens=7, finish=stop |
| meta/llama-3.3-70b-instruct | 死 0/2 | 400/2.64s(空体) | TOUT/30s | 70b 超时 |
| mistralai/mistral-7b-v0.3 | 死 0/2 | 403/26.1s | 403/7.64s | `[403]: Authorization failed (reset after 1s)` |
| google/gemma-3-4b-it | 死 0/2 | 403 | 403 | 同上 403 |
| google/gemma-3-12b-it | 死 0/2 | 403 | 403 | 同上 403 |
| qwen/qwen3-next-80b-a3b-instruct | 死 0/2 | 403 | 403 | 同上 403 |
| moonshotai/kimi-k2.6 | 死 0/2 | 400(空体) | 403 | 400+403 |
| openai/gpt-oss-20b | 死 0/2 | 403 | 403 | 同上 403 |
| stepfun-ai/step-3.7-flash | 死 0/2 | 403 | 403 | 同上 403 |

**4 活 / 8 死 → 走 b** (nvidia ≥1 活, 池卫生有收益, init 扩展剪死目标 + 序4 C=3 合并 Restart)。

### 3a 修正此前判读 (必报)

★ **403 ≠ 418/410 EOL** (此前根因卡②引说"nvidia 部分模型 410 EOL"需改): 403 body 实为 `[nvidia/<m>] [403]: {"status":403,"title":"Forbidden","detail":"Authorization failed"} (reset after 1s)` —— **nvidia 侧该 NIM key 无此模型 entitlement (Authorization failed) + opencode breaker 罚该 key 1s 后 reset**。即 403 = **key entitlement 缺/被 breaker 暂罚**, 非模型 permanent EOL。判死依据: 死 8 中持续 403 = 该模型在该部署的 8 NIM key 集合内 entitlement 池小或被持续罚 → **对该部署实效"活不下来"**, 等效死 (剪除对该生产部署收益明确)。
★ **400 空体首发** (deepseek-v4-flash #1, minimax-m3 #1, llama-3.3-70b #1, kimi-k2.6 #1): body **0 字节空体** = 上游 400 无 SSE chunks。**机制待考**, 但第二发 200 (reset 后命活 key) 与 403 reset-after-1s 同机制 —— 大概率 key 罚态/无 entitlement 命中后空拒, 1s reset 后第二发命中活 key 通。
★ **latency-ms 在 nvidia 路径下证为真上游生成**:   - llama-3.1-8b `89/111ms` tokens=16 finish=length (max_tokens=16 截满 = 模型真生成 16 token);
   - glm-5.2 `900ms` tokens=14 finish=stop (自然停, reasoning 走完);
   - deepseek-v4-flash 偶 `14949ms` tokens=640 (**reasoning model 自思 640 token 后 stop**, max_tokens=16 是输出 token 上限非 reasoning 上限)。
   ★ 此修正组1v3 原读"big-pickle 16 token 全 reasoning 是 length 截断" —— glm-5.2/deepseek 中 max_tokens=16 是**输出 token 上限**, reasoning_content 不计入, 故 deepseek 自思 640 然后输出 stop, glm 走 reasoning 后 14 输出 stop, big-pickle 走 16 输出 length 截。**big-pickle latency-ms=2~5 与本组 nvidia 真生成数 89~14949ms 对比反差大** → 重证 opencode/big-pickle 路径下 latency-ms 异常小 (见上 header 语义备查 opencode 段)。
★ **deepseek-v4-flash tail 14.9s = nvidia 路径也有 tail** (非 opencode 模型独占) —— 修正根因卡① tail 仅归 opencode 平台。**tail 是 reasoning model 自思长时不计 max_tokens 上限** 的产物, 非平台独占维度。

### b 分支落定 + 并入序4 C=3 合并重启

- **进 b**: init 脚本扩展 combo/provider 管理 (启动时 Cookie 直连上游 OmniRoute):
  1. 先 GET `/api/combos` `/api/providers` 读结构 + log (fail-closed 第一跳, 不盲写);
  2. 下一跳据结构写: 8 死模型 (403/400 持续实效活不下来) 做"压底/禁用", 4 活模型保活 + 优先 nvidia 快模型 (llama-3.1-8b 89ms) 走池;
  3. nvidia 定向探针续校 8 key 轮转 (活模型连 8+ 发 Space 日志侧看 `Using nvidia account: XXXX` 轮换)。
- **与序4 C=3 合并同次 Dataset commit + 同次 Space Restart** (重启次数硬约束)。
- **c 退路**: 若 b 写 GET 读回显死模型本就不可该部署写改 (如 combos 表无 priority 字段 init 不可控), 则回 c 把死模型清单记 audit 备查 + 序4 C=3 单独 Restart。



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

## 组1v5: glm-5.2 主路径 before 基线 (R3+ Step2, Restart A 前)

序2/组1v3 走的是 auto 路径 (LKGP 钉 opencode/big-pickle)。R3+ 任务包首裁主路径 = **nvidia/z-ai/glm-5.2 单钉直发** (保 Claude Code 上下文一致), 组1v5 为 Restart A 前主路径 before 基线。

- 脚本 `/tmp/r3plus_v5_glm52_baseline.sh`, 5 发串行 `--max-time 75` 间隔 2s, `/v1/chat/completions` PSK 直发, log `/tmp/r3plus-v5-glm52-baseline.log` (2026-07-20 15:25)

| # | http | ttfb | total | lat-ms | tokens | 判 |
|---|------|------|-------|--------|--------|----|
| 1 | 200 | 2.21s | 6.18s | NA | NA | 活 |
| 2 | 400 | 1.44s | 1.70s | NA | NA | 罚态 |
| 3 | 200 | 1.27s | 3.39s | NA | 6 stop | 活 |
| 4 | 400 | 1.27s | 1.53s | NA | NA | 罚态 |
| 5 | 200 | 1.33s | 2.40s | NA | NA | 活 |

**汇总**: 活 **3/5**, 400 罚态 2/5。**200/400 严格交替** = breaker reset-after-1s 罚态轮转 (首发被罚 → 下一发轮到活 key), 与 3a/3a-2 罚态模式同构。

**主路径基线观察**:
- ttfb 1.27~2.21s 窄带, total 1.53~6.18s — **无 44.5s tail** (组1v3 备查: opencode 路径 tail 是上游 transient, 非 glm-5.2 模型行为)。glm-5.2 非 reasoning 模型, 主路径不 tail。
- lat-ms 全 NA — /v1 直发绕 auto 不注入 `x-omniroute-latency-ms` (nvidia 直发无路由层, 跟 3a/3a-2 同), 符 header 语义备查 "nvidia 路径=真生成" 注: nvidia 直发无 gate 头注入, 仅 auto/LKGP 路径带。
- tokens 仅 #3 捕 6 — 非流式单发 unfinished 多, finish 捕不全; 活 3 发中仅 #3 finish_reason:"stop"。
- **before 基线健康**: 串行 glm-5.2 主路径无 tail 异常, 罚态轮转存在但不阻塞 (3/5 通), 可作 Restart A 后对照 (改 CONCURRENT_LIMIT=1→3 + maxWaitMs 后并发观测是否缓解罚态排队)。

**裁决纪律校验**: 200=活/400=罚态轮转(非持续403)/无TOUT — 4 灯中 2 灯亮 (活 + 罚态), 无死灯。glm-5.2 主路径活, 可作 codex priority 主力 (裁决 §1 主路径)。

---

*2026-07-20 R3+ 组1v2 429 根因卡 · K3 审认可 + Satz 三处精修 · 序2 组1v3 反转根因卡①(44.5s 是 opencode 上游 tail 非 thinking 常态, 3s 常态) · header 语义备查 (latency-ms 随路径变, nvidia 路径=真生成 89~14949ms, opencode/big-pickle 路径 2~5ms 疑边缘缓存/路由, 勿反推平台快慢) · TTFB 钉 SSE 流式消费 + 75s 兜底 · 升级前置 · 序3 拆 3a 探针先行 (/v1 推理路径外部可行零重启, 之前被漏) · **序3a 结果: 4 活 8 死 走 b** (403≠EOL 实是 key entitlement+breaker reset-after-1s 效效死, 剪除对该生产收益明确) · b 与序4 C=3 合并同次 Dataset+Restart · tail 非 opencode 独占 (deepseek-v4-flash nvidia 路径 14.9s = reasoning model 自思长) · 数学: C=3 后 28rpm 桶成新瓶颈理论注记实操不阻塞*
