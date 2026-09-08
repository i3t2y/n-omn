# 持久化安全拷贝路径改造 — 方案设计 (v0, 待 Zen 审)

> 2026-09-07 · 承接 DECISIONS「持久化精简架构审查 — 分层结论」及「修正②」。
> 治疗点已定 = **改掉 09-05 引入的"裸 cp-过-FUSE + quick_check 浅检"不安全拷贝路径**。
> 本文给落地设计, 供 Zen 拍板; 不写生产码直到批准。

## 一、要解决什么 (现状缺陷, 已证)

entrypoint L119-137 现做 boot 快照兜底, 三处缺陷叠加, 即 SQLITE_CORRUPT 反复的放大器:

| # | 缺陷 | 影响 |
|---|---|---|
| ① | **裸 `cp` 生成的快照非事务一致** — 对上次非正常停机留下的撕裂活库, `cp` 把撕裂原样搬进"快照" | 坏页被固化进真源 |
| ② | **快照过 FUSE (Network Bucket) 写入不崩溃安全** — 大文件异步 flush 读回可撕裂, 与活库是否坏无关 | 快照文件本体可能被 FUSE 撕坏 |
| ③ | **门禁只用 `PRAGMA quick_check` (浅检)** — 漏检局部坏页 | 坏快照被当"健康"入库 |

三者闭环: 坏活库(或 FUSE 撕坏的快照) → quick_check 放行 → 每 boot 从同一份污染源种活库 → 永续复现, 自愈不掉。

## 二、设计目标

1. **快照必须是事务一致的 SQLite 备份** (不是裸 cp)。
2. **门禁用严格校验** (`PRAGMA integrity_check`, 非 quick_check), 坏库**当场 fail 作硬门禁**, 不入池。
3. **多版本滚动** (N 份), 一二份被污染仍退到更早健康版, 破除"单版本必覆盖"。
4. **恢复时优选健康版**, 而非"最近一份就种"。
5. 全在 **Bucket 框架内** (不重上 R2 / litestream, 避 Class A 月配额成本)。
6. 失败兜底链不变: 全池坏 → 空库启动 init 幂等重建 (设计内建路径)。

## 三、方案 (事务一致生成 + 本地暂存 + 严格门禁 + 多版本池)

### 生成 (boot 或周期, 取代当前快照块的 `cp`)

```
1. sqlite3 "$DB" ".backup '<本地暂存>/tmp-snap.db'"      # 或 VACUUM INTO 暂存; 事务一致, 坏库当场抛错
   诚实注: 这步写本地 /data (ephemeral), 不过 FUSE → 源侧一致性 + 坏库 fail 双保证 (消缺陷①③)
2. sqlite3 "$tmp" "PRAGMA integrity_check" | grep -q '^ok$' || 丢弃/标记         # 严格门禁, 消缺陷③
3. 校验通过 → cp "$tmp" → "backups/db-snap.N.db"        # 进池 (cp 过 FUSE 仍在, 但源是已验证健康副本)
4. 滚动 GC: 保最近 N (默 5), 删最旧 (min/max 滑窗), 崩绝不删健康新档
5. 删本地暂存
```

- 用 `sqlite3 .backup` 而非 VACUUM INTO 的原因: `.backup` 目标不存在即建, 语义更直接; 两者都事务一致, 实现可二选一, 取决于目标容器 sqlite3 版本 (工程取其更稳者)。
- 时点: 保留 boot 前那份(防"上次停机撕裂"固化), **另加周期快照**(如每 6h, 借已有 `Cleanup 6h`/`_db_health_loop` 调度面) → 崩溃窗口从"整 boot 周期"缩到"≤快照间隔"。

### 恢复 (boot, 取代当前兜底块的单向 `cp`)

```
候选 = backups/db-snap.0..4.db (加 .last-good 兼容召回)
对每候选: sqlite3 "$cand" "PRAGMA integrity_check"|grep ok → 记入"健康候池"
若健康候池非空 → 取最新健康版, sqlite3-derived 拷贝种活库 (cp 即可, 源已校验)
若健康候池空   → 全池坏 → 空库启动, init 重建 (设计兜底, 不 FATAL)
```

- 全池坏空库重建 = 系统性"全坏"时回归最朴兜底, 不循环污染。
- 活库在一次运行中被写坏时: 下一 boot 生成快照会因该库 quick/integrity 坏而 fail → **不污染池**, 且恢复从池里更早健康版拉回 → 正是 09-05 前 litestream 世代回退的语义, 搬到 Bucket 单池内。

### 关键落地点

- `logic/entrypoint.sh` L119-137 快照/兜底块整体改写为"生成+入池+恢复优选"。
- 一个辅助函数 (sh) 或独立 `sqlite` 封装: `snap_verify <path>` = integrity_check gate; `snap_gen` = .backup 到暂存+verify+入池。
- 周期触发: 挂到已有调度面 (omn_scheduler 或 entrypoint 后台), 不新增守护进程面。

## 四、诚实权衡与残留

- **FUSE 缺陷②不能根除**(Bucket 挂载自身不崩溃安全), 只能缓解: 快照源已本地校验 + 多版本让"单份 FUSE 撕裂"只废该版、退其他。**彻底消②只能回到事务一致流式链路(R2/litestream)**, 即 09-05 砍掉的成本面 —— 不在本方案内。
- `cp` 到 FUSE 仍是最后一段, 若 FUSE flush 极端失败可能偶发坏一档; 靠多版本 + 每次恢复 integrity_check gate 兜住, 不再"唯一快照撕裂=全损"。
- 快照粒度 = 快照间隔(≤6h), 与 litestream 10s 相比恢复点粗; 对本场景(遥测/调用账表, 可重建)可接受。
- 存储成本: Bucket 多 ~N 份库文件; N=5 默认, Zen 可调。

## 五、验证方案 (审批同意后)

1. `bash -n logic/entrypoint.sh` 语法 + `secret-scan.py` 无命中。
2. staging 式构造: 本地造干净库 + 撕裂库, 跑快照/恢复函数, 验"干净入场、撕裂拒收、健康版回退、全坏空库重建"四态 (分离验证, 不碰生产)。
3. 生产 boot: 确认—— ① 快照池多档生成 ② 现存坏库被拒、从健康档恢复 ③ SQLITE_CORRUPT 消失 ④ init rc=0。
4. 观察一个完整周期 (≥1 快照间隔), 确认无回归。

## 六、待 Zen 决 (决策点)

1. **方案采用?** (改 entrypoint 安全性 —— 架构变更, 须批)
2. **快照粒度**: ~~boot 前一份即可, 还是 + 周期 6h?~~ → **已决 2026-09-08: 周期 6h** (监督循环内分支, `SNAP_INTERVAL` 默 21600s, 可注入覆盖; boot 一份 + 每 6h 对活库 `.backup` 入池, 崩窗=整 boot 期→≤6h).
3. **多版本 N**: 默 5? 
4. **生成元语**: `.backup` vs `VACUUM INTO`, 工程据容器 sqlite3 版定, 是否接受?
5. 遗留 FUSE 缺陷②是否接受"缓解不根除"的边界?

关联: DECISIONS「分层结论」+「修正②」, 2026-09-07-sqlite-corrupt-write-path.md, e7b16b3, CLAUDE.md §1.