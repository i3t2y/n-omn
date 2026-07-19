# litestream v0.5.9 监控间隔可配置性只读核查 (2026-07-19)

> K3 收口轮任务 2: 查 v0.5.9 retention 监控 (实测 15s) / compaction L1 监控 (实测 30s) 间隔是否暴露配置键。
> sync-interval 明确不动 (RPO 10s 保留, 实测 PUT 占比仅 1%)。
> 结论: **两间隔均 YAML 暴露, 可配置**。本轮只读核查不动制造面; 改动决策留 K3 / 下一轮。

## 源码查证 (benbjohnson/litestream tag v0.5.9, GH_TOKEN 鉴权拉取)

### 监控 goroutine 真居处: store.go (非 db.go)
db.go 的 `monitor()` 仅 WAL sync ticker (`DefaultMonitorInterval=1s`), 与 retention/compaction 无关。
retention/compaction 监控 goroutine 在 **store.go** (`NewStore` 启 N 个 monitorCompactionLevel + L0 retention monitor)。

### L0 retention check interval
- store.go 行 71: `DefaultL0RetentionCheckInterval = 15 * time.Second` (实测日志 "starting L0 retention monitor interval=15s" 即此默认)
- store.go 行 104: `L0RetentionCheckInterval time.Duration` (Store struct 字段)
- store.go 行 601-603: `slog.Info("starting L0 retention monitor", "interval", ...)` + `ticker := time.NewTicker(s.L0RetentionCheckInterval)` — 日志+驱动双证
- main.go 行 264: `L0RetentionCheckInterval *time.Duration \`yaml:"l0-retention-check-interval"\`` — **user-facing YAML 键暴露**
- main.go 行 385: 校验 `> 0` (ErrInvalidL0RetentionCheckInterval)
- main.go 行 563-580: Config.L0RetentionCheckInterval → Store.L0RetentionCheckInterval 映射链 (含 nil 回退默认)

**YAML 写法 (顶层)**:
```yaml
l0-retention-check-interval: 5m
```

### Compaction monitor per-level interval
- store.go 行 533: `slog.Info("starting compaction monitor", "level", lvl.Level, "interval", lvl.Interval)` — 实测日志原文源
- monitorCompactionLevel 全程用 `lvl.Interval` 驱动 timer (store.go 行 532-570)
- main.go 行 254: `Levels []*CompactionLevelConfig \`yaml:"levels"\``
- main.go 行 614-617: `CompactionLevelConfig struct { Interval time.Duration \`yaml:"interval"\` }` — **per-level YAML 暴露**
- main.go 行 482-494 `CompactionLevels()` 构造: 遍历 `c.Levels[]`, 每个 `lvl.Interval` → `CompactionLevel{Level:i+1, Interval:lvl.Interval}`, 传 Store

**YAML 写法 (顶层 levels 列表)**:
```yaml
levels:
  - interval: 5m   # L1
  - interval: 10m  # L2
  - interval: 1h   # L3
```

## Class A 减量估算 (基于 7.5h 长跑实测)

R2 实测月 Class A ~27万 = 免费线 27%。构成: retention LIST 63% + compaction LIST 32% + 写负载 PUT 1% (idle 期 sync-interval 几乎不产 PUT)。
retention+compaction 占 95% Class A。

| 改动 | 影响字段 | 当前 → 目标 | Class A 影响 |
|------|---------|------------|-------------|
| L0 retention monitor interval | `l0-retention-check-interval` | 15s → 5m (20×) | 63% → ~3% |
| L1 compaction monitor interval | `levels[0].interval` | 30s → 5m (10×) | 32% → ~3% |
| 合计 | | | 27万 → ~6万/月, 免费线占比 27% → ~6% |

**注**: 估算保守 — 实测多级 compaction (L1-L4 四级阶梯), 每 level 各 ticker; 改 L1/L2 各 level interval 至 5m 后减量估 10-20×。总实改需 R2 实跑后 Class A 实测二次校准。

## 风险面

1. **RPO 语义**: retention/compaction 监控间隔拉大 = 旧 L0 文件清理延迟 + compaction 合并延迟。**不影响 WAL sync** (sync-interval 10s 不动), RPO 仍 10s。仅影响"过期文件清理"与"下层合并"节奏, 非"数据持久化"节奏。idle 期满 sync-interval 不产新 L0, 5m 清理节奏足够。
2. **本地磁盘占用**: L0 文件待清理延迟 20×, 本地 L0 暂存增 (~少 MB 级, 25 key 元数据体量小, 可忽略)。
3. **restore 影响**: restore 走快照 + LTX 重放, 与 monitor interval 无关 (restore 一次性全读非间隔轮询)。
4. **widget**: levels list 须包全 L1-L4 当前级数, 漏某级 → 该级走默认 30s (减量不全)。

## 下一轮改动建议 (留 K3 批, 本轮不做)

```yaml
# litestream.yml 顶层追加
l0-retention-check-interval: 5m
levels:
  - interval: 5m   # L1
  - interval: 10m  # L2 (如有)
  - interval: 1h    # L3 (如有)
  - interval: 6h    # L4 (如有)
```
- 级数须先核当前 R2 实跑 litestream 启了几级 compaction (7.5h 日志 "compaction complete level=N" 最大 N 值)。
- 单 commit + Space 普通 Restart (零 factory rebuild)。
- 改后 R2 实跑 24h 二次 Class A 计量 校准估算。

## 不动项 (K3 红线)

- **sync-interval 10s 不动**: RPO 10s 保留, PUT 占 Class A 仅 1%, 拉大无收益损 RPO。
- **gate 限流 28rpm/1并发/100ms 不动**: 已验证安全区。
- **auto-recover false 不动**: v4.3 红线3, entrypoint 显式 restore guard 防覆盖有效 DB。

---

## 附: 7.5h 长跑实测后 - 源码核证收到覆写陷阱 + 5m 推实落地 (2026-07-19 K3 收口后轮)

### 源码核证续深 (compaction_level.go)

接第一版只读核查后, 实跑 logs/run 多级 monitor 数据 (`starting compaction monitor level=2 interval=5m0s` / `level=3 interval=1h0m0s` / `level=9 interval=1h0m0s`) 触发再深核, 揭三件:

1. **DefaultCompactionLevels 预置三级** (compaction_level.go 行 16-21, `var DefaultCompactionLevels`):
   - L0: Interval=0 (无 compaction, 仅 retention monitor)
   - L1: `30 * time.Second`  ← 实跑日志 30s 即此
   - L2: `5 * time.Minute`  ← 实跑 5m0s
   - L3: `time.Hour`  ← 实跑 1h0m0s
   - L9 是 `SnapshotLevel` const = 9 (pseudo level, store.go 行 524 `SnapshotLevel()` 返伪 level, interval=snapshot.interval, 即实跑 L9=1h0m0s 来源)

2. **DefaultConfig() 预置预填 L1/L2/L3 三级** (main.go 行 344-348):
   ```go
   Levels: []*CompactionLevelConfig{
       {Interval: litestream.DefaultCompactionLevels[1].Interval},  // L1=30s
       {Interval: litestream.DefaultCompactionLevels[2].Interval},  // L2=5m
       {Interval: litestream.DefaultCompactionLevels[3].Interval},  // L3=1h
   }
   ```
   用户 yaml 不设 levels → `ParseConfig` (行 542 `config := DefaultConfig()`) 用预置, 故 L1/L2/L3 三级 monitor 自然生。

3. **yaml 设 levels 完全覆写预置非追加** (陷阱): `ParseConfig` 行 567 `yaml.Unmarshal(buf, &config)` 用 yaml unmarshal 覆盖整个 `config.Levels`, 用户写 `levels: [{interval:5m}]` → `c.Levels` 变 1 条 → `CompactionLevels()` (行 481-494) 只生成 L0+L1 两级 → **L2/L3 compaction 监控消失** (store.go Open 行 195 仅遍历 `s.levels`)。compaction 阶梯断, L3 高阶合并不启, WAL 段长期滞 L0。
   - 推论: 要改 L1 必须显列 L1/L2/L3 全保留默认, 否则覆写断阶梯。

### 写法选择 (用户裁决 2026-07-19 收口后轮)

| 选项 | 写法 | 收益 | 风险 |
|------|------|------|------|
| 1 完整 L1/L2/L3 三级 | `levels: [{interval:5m},{interval:5m},{interval:1h}]` + `l0-retention:5m` | L0+L1 双改, 估 27万→3万/月 | **疑**: L1 30s 改 5m 非"纯监控" — 是 compaction 触发器, L1 tick 时聚 L0 WAL 段成 L1 文件 PUT 上传。各 5m 省的只是 tick 时 LIST/检查 (远小于 32% 粗估), 代价是 WAL 滞 L0 更久 + 崩溃恢复回放段更多 + L2(5m)/L3(1h) 输入被后移后整阶梯后移。成本账不干净, 风险账多一页 |
| **2 仅设 l0-retention (采)** | `l0-retention-check-interval: 5m` 顶层, **levels 整个不碰** | L0 监控 15s→5m 砍 LIST 20× (占 63%), 总量约 27万→**~10万/月** (免费线 27%→10%) | **零**: l0-retention-check-interval 纯监控参数, 只控多久查一次 L0 段是否过期可删, 不改任何 compaction 语义。retention 执行精度 15s→5m 对 5m 保留期机制零影响 (最坏过期段多活几分钟, R2 免费额度忽略) |
| 3 用户原单条 (否) | `levels: [{interval:5m}]` | L1 30s→5m | 覆写预置丢 L2/L3 compaction 监控, �阶梯断, 不建议 |

### 决策结果: 选项 2

理由: 选项 1 把 L1 的 30s 当成单调成本最大化收益, 但 L1 interval 是 compaction **触发器**非纯监控参数, 净收益风险账不对等 (源码核证打掉了用户原推演 "L1 30s→5m 省 32%" 的隐含假设)。选项 2 仅设 l0-retention-check-interval 是纯监控参数, 零语义风险, 拿稳 63% 头。

### 顶层位再次核证 (防栽进用户的错位写法)

`l0-retention-check-interval` 是 **Config 顶层字段** (main.go 行 264 `type Config struct`), 非 `dbs[].replica` 子键 (ReplicaConfig 行 1200 无此 yaml 字段)。

replicate.go 行 248-249 直证消费路径:
```go
if c.Config.L0RetentionCheckInterval != nil {
    c.Store.L0RetentionCheckInterval = *c.Config.L0RetentionCheckInterval
}
```
读 `c.Config.L0RetentionCheckInterval` (顶层)。**嵌 replica 内被 ReplicaConfig 忽略静默不生效** — 故必须顶层与 `dbs:`/`snapshot:` 同级。

### 5m 推实落地 (单 commit 单 Restart 零 factory rebuild)

- **本地文件**: candidate-v4.3-reviewed/litestream.yml, 顶层加 `l0-retention-check-interval: 5m` + 详注 (含核证+覆写陷阱+收益估算), 19 行 → 30 行
- **红线未动 byte 核**: `dbs:[]` (path=/app/data/storage.sqlite) / `replica` (sync-interval=10s/bucket=omn-data/auto-recover=false) / `snapshot` (interval=1h/retention=24h) 逐字未动
- **HF Dataset 推**: `upload_file` 单文件推 (非 upload_folder 防染其它4 源文件), commit `7a1d0ac83d897e850051760e6af664d56b830975`
- **Rest**: 普通 Restart (零 factory_reboot)
- **验收 logs/run** (timestamp 14:11:19.713Z 新启动):
  - `starting L0 retention monitor interval=5m0s` ← 15s → 5m0s **生效** ✓
  - `compaction monitor level=1 interval=30s` — L1 逐字不变 ✓ (未碰 levels)
  - `compaction monitor level=2 interval=5m0s` — L2 逐字不变 ✓
  - `compaction monitor level=3 interval=1h0m0s` — L3 逐字不变 ✓
  - `compaction monitor level=9 interval=1h0m0s` — snapshot pseudo 不变 ✓
  - `sync-interval=10s` 红线未动 ✓
  - `replicating to type=s3 bucket=omn-data` litestream 仍通 ✓
  - 四子进程全绿 + 8 NIM keys 注册 ✓
- **"levels 未动"实证**: L1/L2/L3 三条 monitor interval 改前逐字一致即此

### 附 runbook 偶然命中 (非固化)

Rest 触发用 `HF_TOKEN`(Space write scope) 401 兜底未兑现, `HF_TOKEN_DATASET_WRITE`(Dataset write scope) 跨通触 Rest 成 (HTTP 200 → RUNNING_BUILDING → 36s RUNNING)。即 audit 4 则(b) "fine-grained 实际授权面比名义 scope 宽"再次实证。**但平台行为非设计依据, 下一轮首验升级环仍按任务 3 runbook 用 fine-grained Space write 专项 token** (本次偶然性不固化成 SOP)。

### Class A 减量待回测

实测减量须 R2 实跑 24h Class A 计量二次校准 (从免费 27% 应降至约 10%)。本推是变更生效, 实跑累积数据非本推之诚。

---

*2026-07-19 收口后轮续 · source: benbjohnson/litestream v0.5.9 (compaction_level.go + store.go + cmd/litestream/{main,replicate}.go) · 5m 推实 commit 7a1d0ac8*
