# FlareTunnel 健康感知轮转 — 算法论证与实现设计

> 圣上 2026-08-23 令"深入设计 FT 代理可优化空间 + 搜索论证最佳算法"。
> 对治慢根 ①（100 Worker round-robin 游标长 + 冷端握手 + 死 worker 照轮）。
> 状态: **设计评审稿**（未落码，默认关，待圣上批启用）。

---

## 一、问题背景

FT 桥（FlareTunnel.go）当前 `--workers 0-39`（40 Worker 池）走**纯 round-robin** 轮转：
`GetWorkerURL()` (L1377-1395) round-robin 分支顺序取 `ps.Workers[ps.CurrentWorkerIndex]` 后 +1，**完全不看 worker 健康**。

慢诊四根（HANDOFF §FT 慢诊，2026-08-13）里，**FT 侧唯一有真实空间的是根 ①**：
- 100 Worker round-robin 游标长 + **死 worker 照轮**（DNS 挂 / 被风控 / 被 NIM 拒的 worker 每次打冷端重握手）
- 另三根已定：② AbortError 已修（Patch B 删 30s 整体 Timeout）③ ft1 403 是 NIM key 维度 ④ HF 2vCPU 恒定

## 二、算法论证（外部搜索佐证，2026-08-23）

### 候选算法逐一证伪

| 算法 | 外部佐证（已搜实源） | 本场景适用性 |
|------|---------------------|-------------|
| **纯 Round Robin**（现状）| Facebook 等: "池内等权，不考量节点负载" | ⚠️ 等权分布对，但死节点照轮（最大短板）|
| **Least Connections** | FreeLoadMaster: "用于连接时长可变" / LinkedIn: "用于长会话 chat/流式" | ❌ **短转发请求无长会话** → 不适用 |
| **Weighted Round Robin** | JSCAPE: "按服务器容量加权" | ❌ 40 Worker 容量等价（都 CF 免费层出口）→ 加权无意义 |
| **Weighted Least Connections** | F5: Least + 权重结合 | ❌ 继承两个不适用前提 |
| **纯 Random** | Reddit ProxyEngineering: "随机选择会过度打击同一 proxy" | ❌ 打击同 IP 反风控 |

### 最优解 = Round Robin + 健康过滤（失败冷却跳过）

外部佐证（最强力）：
- **Reddit ProxyEngineering**（代理池社区共识）: `Add a cooldown per proxy. Don't reuse the same IP for like 10-15 minutes. Random selection can hammer the same proxies too often. Health checks...` — **每 proxy 冷却 + 健康检查**
- **LevelUp Coding (Circuit Breakers)**: `Set clear enforced timeouts first... Separate retries from circuit breakers` — **熔断/冷却与重试分离**
- **browserless/medium**: 代理池规模失效根 = 并发/池枯竭/重试 — 健康过滤治"池枯竭时死节点拖累"

**为什么最优**：
1. RR 保等权分布（40 池容量等价，RR 天然正确）
2. 健康过滤补 RR 唯一短板 = **死节点照轮**
3. 失败冷却（cooldown）符合代理池社区标准
4. 熔断与重试分离（LevelUp 最佳实践）— 健康过滤是降权/熔断，不碰重试逻辑
5. 默认关、可逐步启用、可回退，风险极低

## 三、实现设计（FlareTunnel.go）

### 核心思路

`GetWorkerURL()` round-robin 分支升级为"**顺序扫描 + 跳过不健康 + 保底回退**"：
优先选最近健康的 worker，失败/慢的临时降权（冷却），全不健康时回退纯顺序（避免空转 503）。

不推翻 round-robin，而是"在 RR 上叠加健康过滤"。健康数据已有（`WorkerStat` L203-211 含 Successes/Failures/LastStatus/LastUsed，`recordWorker` L1356 每次响应都记）。

### 改点 1 — `ProxyServer` struct (L1248) 新增 2 字段

```go
// 健康感知轮转: worker 失败冷却秒数 (LastStatus>=400 或 err 记 0 开始计). 0=关闭(纯 round-robin 行为不变).
HealthCoolDown int
// 健康感知轮转: 连续失败阈值 (超过则视为需冷却降权). 默认 3 次.
HealthFailThreshold int
```

### 改点 2 — `GetWorkerURL()` (L1377) round-robin 分支改写

```go
} else if ps.RotationMode == "round-robin" {
    n := len(ps.Workers)
    if ps.HealthCoolDown > 0 && n > 1 {
        // 健康感知: 从游标起顺序扫, 跳不健康, 保底回退纯顺序
        start := ps.CurrentWorkerIndex
        now := time.Now().Unix()
        for i := 0; i < n; i++ {
            idx := (start + i) % n
            w := ps.Workers[idx]
            if ps.isHealthy(w, now) {
                ps.CurrentWorkerIndex = (idx + 1) % n
                return w, w.URL
            }
        }
        // 全不健康: 回退纯顺序 (保底不空转 503)
    }
    worker := ps.Workers[ps.CurrentWorkerIndex]
    ps.CurrentWorkerIndex = (ps.CurrentWorkerIndex + 1) % n
    return worker, worker.URL
}
```

### 改点 3 — 新增 `isHealthy` helper

```go
// isHealthy: 基于 WorkerStat 判定 worker 是否可用.
// 规则: 无记录/从未用 = 健康放行 (新 worker 试水)
//       LastStatus>=400 或 0(err) 且 距 LastUsed < 冷却秒 = 不健康 (冷却降权)
//       冷却过 = 恢复放行试水
func (ps *ProxyServer) isHealthy(w *Worker, now int64) bool {
    stat, ok := ps.WorkerStats[w.Name]
    if !ok || stat.LastUsed == 0 {
        return true
    }
    if stat.LastStatus >= 400 || stat.LastStatus == 0 {
        if now-stat.LastUsed < int64(ps.HealthCoolDown) {
            return false // 冷却中降权
        }
    }
    return true
}
```

### 改点 4 — main() 加 `--health-cooldown` 参数 + 传入

`tunnel` 子命令 flag 区 (L2339 switch) 加：
```go
case "--health-cooldown":
    if i+1 < len(os.Args) {
        cooldown, _ = strconv.Atoi(os.Args[i+1]); i++
    }
```
传给 `NewProxyServer` 后设 `ps.HealthCoolDown = cooldown`。`--health-fail-threshold` 同理（默认 3）。

### 默认与启用方式

- `--health-cooldown 0` = **默认关**（纯 round-robin，行为不变，不破坏现有）
- 要启用：entrypoint.sh 的 FT 启桥段 `--workers 0-39` 加 `--health-cooldown 30`（30 秒冷却，失败 worker 30s 内降权）

## 四、验证方案（照 §4 健康信号）

- boot 后 `GET /v1/ft/metrics` 看 `flaretunnel_rotation_index` — 轮转仍递增但**跳过不健康 worker**
- 打一死 worker（手动 kill 某 worker 域名）看是否被跳过
- 全 worker 健康时 = 退化为纯 round-robin（无性能回退）
- 无 FT 侧活病时**不做风暴验证**（照 §4 判据：0% 错无活病，造风暴成本高）

## 五、风险与边界

- **不推翻 round-robin**：顺序 + 健康过滤，保底回退纯顺序，无空转 503 风险
- **不破坏 worker.js**：纯桥侧逻辑，Worker/域名/鉴权全不动
- **新参数默认关**：不启用 = 零行为变化，启用才生效
- **并发安全**：复用 ps.mutex（GetWorkerURL 已持锁）
- **§1 三件定态**（Dockerfile/README/start.sh）零触；改 FlareTunnel.go 属 dev 桥层，git 先行再 push Dataset

## 六、commit 链前置

- 改 FlareTunnel.go → `flaretunnel/build.sh` 编译 → sha256 校验 → push HF Dataset nonoke/omn-logic（走 dev 镜像链）
- SSOT: HANDOFF FT 待办 + DECISIONS 加裁决段（如圣上批启用）
- git add/commit/push 一律 ask 圣上（§5）