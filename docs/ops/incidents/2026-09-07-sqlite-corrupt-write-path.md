# SQLite 写路径真损坏 (SQLITE_CORRUPT) — usage/callLogs 持续写失败 — 红旗待定谳

> 2026-09-07 boot (09:22) 起, 活库 `/data/storage.sqlite` usage 写路径抛出
> 真损坏字面量 `database disk image is malformed`, 与既有良性 ghost-table
> (`compression_run_telemetry no such table`) 并存但**两码事**。本档按七段式记录
> 证据、定性分界、影响面与待办。**先记红旗, 不臆断根因。**

## 一、病历 (观察到的行为)

2026-09-07 09:22 自觉重启后 boot 全程, 反复出现两组 SQLite 写失败 (非偶发, 贯穿
09:23→09:52, 每次对应一次 chat 完成或一次 callLogs prune):

```
Failed to save usage stats: SqliteError: database disk image is malformed
    at Object.run (.build/next/server/chunks/src_02l7t6d._.js:1:5170)
    at <unknown> (.build/next/server/chunks/src_lib_usage_1u13rm3._.js:15:10)
    at _ (.build/next/server/chunks/src_lib_usage_1u13rm3._.js:15:590)
    ... {
  code: 'SQLITE_CORRUPT'
}
```

```
[callLogs] Failed to prune overflow request artifacts: database disk image is malformed
```

次数: `save usage stats` 与 `callLogs prune` 均反复出现 (≥10 次/条)。启动段另有
`[Cleanup] Error cleaning compression_run_telemetry: no such table` (幽灵表, 良性)。

## 二、时间线

- 2026-09-07 09:22:51 boot 起, `[DB] SQLite database ready: /data/storage.sqlite`
  + `boot 快照已更新 (quick_check ok)`。
- 09:23:11 首个 chat 请求 (nvidia deepseek) → 伴随首条 `save usage stats SQLITE_CORRUPT`。
- 09:23–09:52 全程: 每次 STREAM complete (kimi-k3 / deepseek) 后必跟一条
  `save usage stats SQLITE_CORRUPT`; `callLogs prune` 周期性失败。
- **同批 chat 请求全部成功**: `ProxyEgress nvidia/sensenova status=success` +
  `[STREAM] complete` 200。写失败不阻服务。
- 09:48–09:52 sensenova lite 请求 (6.7/6.8-flash-lite) 另现 404 (见 §同 boot 并存观测)。

## 三、定性 (红旗 vs 噪声分界)

**判定基准 (沿用 [[sqlite-corrupt-ghost-table-2026-09-05]] 教训)**:
- `no such table: compression_run_telemetry` = 上游懒建表 + Cleanup 盲删 = **良性**, 非损坏。
- **`database disk image is malformed` (code: SQLITE_CORRUPT)** = **真损坏字面量**。判据只认
  字面量 → 本次为**真红旗**, 非幽灵表。

**影响面**:
- **受损对象**: 活库 `/data/storage.sqlite` 的 `usage_history` / `call_logs` (写) 路径。
- **服务面零影响**: chat 照常 200, 池/路由/鉴权全绿。损坏仅卡遥测/调用账落库。
- **持久化未受威胁**: §1 持久化, 真源 = Bucket 挂载 `/data/backups` 的
  `storage.last-good.sqlite` (quick_check 过才更新); 活库 = HF ephemeral 盘, 每 boot 由
  Bucket 快照恢复。损坏落在活库侧, 真源独立无碍。
- **后果**: Dashboard 用量/调用账漏记 (usage/call_logs 丢), 监控审计数据不全。

## 四、根因域 (假设, 未定谳)

对象挂载 (Bucket FUSE) 上 SQLite 的文件锁/fsync 语义不保, 或上次非正常停机 (tear) 残留
脏页, 或恢复源带损。**去 OBJECT-PACKAGE**: 须 `PRAGMA integrity_check` 验证 true 判定 +
确认恢复源 (Bucket last-good) 是否带损 (若带损则拷 back 非对象, 是恢复链问题)。

## 五、修复与验证 (待办, 未执行)

- [ ] `PRAGMA integrity_check` 对活库 + Bucket 快照源双验, 定位损坏面 (usage 表 vs call_logs 表 vs 全库)。
- [ ] 确认快照源带损与否 → 若源无损则活库损坏为 boot 期/上次停机 tear, 清活库由源重建即可。
- [ ] 若确认 object-mount 写语义不保: 评估活库 WAL 落 ephemeral 本地盘 vs 挂载层的取舍
      (现状活库即 /data ephemeral, 挂载仅备份 — 若活库确在 ephemeral 本地, 则源非 mount 语义,
      损坏近似上次停机, 与 mount 无关 — 待实测 DATA_DIR 落点定论)。
- [ ] 每次 chat 不调起 usage save 失败探测 (是否 error 可吞)。

## 六、同 boot 并存观测 (sensenova lite 404)

本次 boot 另观测到 sensenova lite 模型静态白名单注册成功但不可调用:
```
POST /v1/chat/completions | sensenova/sensenova-6.7-flash-lite | 1 msgs
ROUTING Provider: sensenova, Model: sensenova-6.7-flash-lite
[provider] Node 46ccbd27... model not found (404) for sensenova-6.7-flash-lite
[ERROR] [404]: model route not found
sensenova | all 3 active accounts cooling down for model sensenova-6.7-flash-lite
```
3 key + 3 nodes + `sensenova-pool` 真建、round-robin/fallback 真跑 (`excluded_count=1→2→3`),
全 404 → **上游不认白名单模型名** (可能带 org 前缀/版本号, 需上游 /v1/models 枚举定真实 id),
非本层配错。6.8-flash-lite 09:51:25 同理。**与 SQLITE_CORRUPT 两独立事件, 勿混**。

## 四·补 根因域修正 (entrypoint 源码铁证, 推翻 object-mount 假设)

L26/L50: `DB_PATH="$DATA_DIR/storage.sqlite"` + `DATA=/data (ephemeral, Bucket 挂载是持久真源)`
→ **活库在 ephemeral 本地盘, 不在对象挂载**。故 §四 原假设「对象挂载 (Bucket FUSE)
文件锁/fsync 语义不保」**注销**。域收窄: (a) 上次非正常停机 tear 残留致本 boot 恢复源
(`backups/storage.last-good.sqlite`) 带损, 或 (b) 本 boot 活库运行中 write/tear。
boot 快照 L125-126 quick_check ok 当时真; 损坏从 09:23 运行中现 → (b) 更贴近, 仍待
integrity_check 双验定谳 (活库 vs 快照源)。

## 七、行动项 & 教训

- [ ] 本档 + STATUS 红旗段 commit (待 Zen §5 批) — 记档不臆断。
- [ ] 跟进 integrity_check 真验定谳 (见 §五), 关闭或升级本档。
- [ ] 教训预记: **字面量分界铁律** — `no such table` 良性 vs `database disk image is
      malformed` 真局, 判据只认字面量/integrity_check; 本次为首次真红旗, 与历史幽灵表
      误判 (09-05) 严格区分。

关联: [[sqlite-corrupt-ghost-table-2026-09-05]] [[omn-log-query-tool-landed]]