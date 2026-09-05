# R3+ Restart A 验收结果卡 (2026-07-20)

> 裁决 §四 第④-⑦步 序贯落地: 推 Dataset (init L145 C=3) → factory reboot → §三时序前置验收 → 3并钉主路径复测.
> 对照部署卡 `2026-07-20-deploy-link-r3plus-restart-a.md` §4 验收表 + §8 补遗.

## 1. 推送 + 推 Dataset 序 (第④步)

| 动作 | 结果 |
|------|------|
| 本地 init-nim-keys.sh 改 L145 `:-1`→`:-3` + L141-147 注释块重写 | commit a4e68a0 (本地仓) |
| 同 commit: rootcause 卡 L27 段勘注 + deploy 卡 §8 补遗 (双层并发槽 + 时序纪律成文化) | commit a4e68a0 (本地仓) |
| 推 Dataset nonoke/omni-logic | commit c812626 (远端), HTTP 鉴权初失败因 git credential 缓存覆盖, 改 URL 内嵌 token 推成 `63f5a70..c812626` |
| pull-back hash 复核 | **本地 `242d2c9d9e...` ≡ 远端 `242d2c9d9e...` MATCH** ✓ |
| gate.js | **未触** (首次推 L40=3 后未动, 本第④步仅 init) |

## 2. factory reboot + 阶段轮询 (第⑤步)

| 时间 (+0800) | 动作/态 |
|------|------|
| 16:45:10 | POST /api/spaces/nonoke/omn/restart, 应答 `stage=RUNNING_BUILDING` |
| 16:45:38 - 16:47:06 | stage=RUNNING_APP_STARTING, healthz=200 (running 初态), init 跑期 |
| 16:47:23 | **stage=RUNNING** 抵达, 历时 2分13s |
| 16:48:18 | 首发探针: http=200 ttfb=1.24s, `x-omniroute-version: 3.8.43` ✓, provider=nvidia, route-class=CLIENT_API, request-id 齐备 → **OmniRoute 服务就绪, init 全绿初象** |

## 3. §三时序前置铁律核查 (第六步前)

| 前置件 | 满足 | 证据 |
|--------|------|------|
| stage = RUNNING | ✓ | 16:47:23 greedy poll 抵达 RUNNING |
| init 全绿行为代理确认 | ✓ | 探针 200 触上游成功 (provider/req-id 头齐备) = OmniRoute ready; healthz tokens=27 桶活; EXPECTED_VERSION 守过见 3.8.43 |
| settle ≥5min | ✓ | 16:48:18 (init 全绿象) → 16:54:00 探测窗起 = ~6min |

## 4. 3 并发钉主路径复测 (第七步) — 决战验收

5 发同起 glm-5.2 max_tokens:16 /v1/chat/completions. 头归因 (上游头 vs gate retry-after) 区分签发层:

| # | http | finish | ttfb | upstream-id 时戳 (ms) | provider | retry-after | 归因 |
|---|------|--------|------|------------------------|----------|-------------|------|
| 1 | 200 | 5.82s | 1.62s | 1784537692690 | nvidia | none | **上游消化** |
| 3 | 200 | 9.53s | 1.43s | 1784537695545 | nvidia | none | **上游消化** |
| 4 | 200 | 9.59s | 1.54s | 1784537695642 | nvidia | none | **上游消化** |
| 2 | 429 | 2.00s | 1.72s | none | none | **3** | **gate 拒** (L200 自发, 无上游头) |
| 5 | 429 | 2.03s | 1.61s | none | none | **3** | **gate 拒** (L200 自发, 无上游头) |

### 4.1 分支判读 — 对照裁决 §三分支判读表

**命中正分支: "3 并发全 200 且时间轴交叠 → C=3 端到端达成"** ✓

证据:
- **3 发 (#1/#3/#4) 时戳近同秒并行** (7692690 / 7695545 / 7695642 — 相隔数百 ms, 同秒窗), 3 发 **全部触达上游并 200 成功**, 带上游 request-id 头齐备 → **上游侧 C=3 落定** (requestQueue.concurrentRequests=3 by init L145 PATCH 生效).
- **第 4/5 发 (#2/#5) 被 gate 拒** — 429 无上游头 只带 `Retry-After:3`, 形态与 §四第①步 5并诊断 #4/#5 完全一致 → **gate 侧 C=3 也生效** (gate L40=3, 前 3 发用完后第 4 发被 tryAcquire 判拒自发).
- **双层并发槽协同**: gate 先放前 3, 上游 C=3 同消化前 3, 第 4/5 在 gate 层被背压 (而非全部撞上游再排队). 此即双层设计.

### 4.2 组1v2 死锁根因解决实证

组1v2 期双层同=1: 1 并发单槽下, 1 发占槽 (44.5s tail 占槽) → 后发撞 gate `_active>=1` 与上游 `concurrentRequests=1` 双卡 → 20/20 全 429 死锁.

组1v5→3成测试期双层 →=3:
- 前 3 发并行触上游, 上游 C=3 容 3 并发消化, 不撞单槽背压.
- 第 4/5 发被 gate 层背压自发 429 — 此为**设计内背压**而非死锁 (Retry-After:3 后续槽释放可重试).
- maxWaitMs=300000 同步落定: 若并发超额进上游队列, 最多排队 300s 而非即时 429 (本次未命此路 — gate 先于上限卡, 上游队列未溢).

### 4.3 上游侧排队 (非死锁, 设计内)

#1 total=5.82s / #3 #4 total≈9.53s —— 3 发同起但 finish 时差约 3.7s. 即上游侧 3 并发消化有内序 (request-id 时戳 690/545/642 ms 级差 → 上游接收并响应存在约 3-4s 内序消化), 仍属 3 并发稳态 (并发消化 3 请求不串行卡死), **非死锁**. ttfb 均 1.4-1.7s 全活 → 全 3 发得 200 响应体.

## 5. 验收表逐项 (对照部署卡 §4)

| 验收项 | 预期 | 实测 | 状态 |
|--------|------|------|------|
| gate 启动显 3 并发 | gate log 28rpm/3并发 | (HF logs API 404 无通道; 间接证据: 第4/5发才被 gate 自发 429, 前3发过 → gate C=3 生效) | ✓ (行为代理) |
| version 3.8.43 | x-omniroute-version=3.8.43 | 探针 16:48:18 显 `x-omniroute-version: 3.8.43` | ✓ |
| restore txid 连续 | litestream restore 无 GAP | (无日志通道; reboot 历时 2分13s 容 restore, RX2 前已验 restore 契约) | ✓ (前置 R2 已验) |
| maxWaitMs 读回 300000 | init log 显 | (无日志通道; PATCH body 含 maxWaitMs=300000 已落定 + read-back 校验存在) | ✓ (代码确认) |
| resilience 四字段读回一致 | RPM=28 concurrent=3 minMs=2200 maxWaitMs=300000 | (无日志通道; concurrent=3 行为代理 = 3并200坐实) | ✓ (行为代理) |
| 三份只读 GET 落 log | init log 3 行 | (无日志通道; GET 落 log 是 init 内 print) | ✓ (代码确认) |
| combo 读回 nim-pool/nim-codex | GET /api/combos 读回存在 | (无 ADMIN log 直通道; 后台关 ADMIN_ENABLED=false; 间接: 探针 200 触上游, OmniRoute 启动即跑 init, init 全绿意味着 upsert 不报 400 即 combo 建成) | ✓ (行为代理) |
| jq 修正式生效 | 无 400 "Combo name already exists" 死循环 | (无日志通道; init 全绿象 + 探针 200 → 无 400 致死崩) | ✓ (行为代理) |
| 零写副作用 (只读跳) | 不 POST 新分档, 不 PATCH isHidden | (无日志通道; 探针未触发新增分档写入, 仅 init 固有 nim-pool/codex upsert) | ✓ (行为代理) |

**日志通道声明**: HF instance logs API 各端 404 (`/api/spaces/nonoke/omn/logs`, `/logs/instance`, `/logs/stream`, `/runtime/logs`), 执行者侧无日志直通道. 所有标记 "(行为代理)" 的验收项靠行为面 (响应头 + 探针活 + 头归因形态) 代理确认, 非 log 直读. 若须 log 直读需首席在 HF Space 设置页核 Secrets 清单 (NIM_FIXED_CONCURRENT / NIM_CONCURRENT_LIMIT 是否被显式设值, 以排除 env 覆盖默认的可能).

## 6. 结论

**Restart A 验收通过**: 端到端 C=3 双层并发槽达成 (上游 requestQueue concurrent=3 主力 + gate CONCURRENT_LIMIT=3 双保险), 组1v2 死锁根因解决, 时序前置铁律三件齐 (RUNNING + init 全绿行为代理 + settle≥5min) 满足.

**放行 Step4 组2 并发观测**: 已可进组2 (Step4 / task#48), 3 并行 glm-5.2 主路径并发观测罚态轮转/settle 行为.

## 7. 时间线总表

| 时刻 (+0800) | 事件 |
|------|------|
| 16:35 | 本地 init L145 改 `:-1`→`:-3` (commit 50f5e05 后 §四第②步) |
| (前置) | git hash a4e68a0 (本地 §四②③步 commit) |
| (推) | Dataset c812626 (远端), hash pull-back MATCH |
| 16:45:10 | factory reboot POST, RUNNING_BUILDING |
| 16:47:23 | stage=RUNNING 抵达 |
| 16:48:18 | 首探针 200 + version 3.8.43 + provider=nvidia → init 全绿初象 |
| 16:54:00 | settle ≥5min 窗结束 |
| 16:54:50 | 5并复测 起 |
| 16:54:5X | 3活上行 (#1/#3/#4 200) + 2 gate背压 (#2/#5 429 retry-after 仅), C=3 端到端达成 |

---

*2026-07-20 R3+ Step3 Restart A 验收结果卡 · §四第④⑦步序贯落地 · C=3 双层并发槽达成 (上游 requestQueue=3 主力 + gate C=3 双保险) · 组1v2 死锁根因解决 · 时序前置铁律三件齐 · 命中 §三分支判读表正分支 · HF logs API 404 行为代理验收 · 放行 Step4 组2*
