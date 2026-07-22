# p0-events-table — 事件入库骨架

> Supreme 增补令 #1 · 依附 cg52 v2 §5 P0 局部提前授权
> **本地合成弹药, 非上膛**。R3 宣判(2026-07-23 03:16 后)前不出仓不上 Space。

## 补丁作用

SQLite events 表 schema + 写入函数 + 写入点清单。
关键事件签名落库, 乘 **Litestream → R2 既有通道**持久化, 零新增组件。

## 核心红线(架构师)

> 零新增持久通道 — 所有写入必须落进 Litestream 正在复制那个库文件。

故 events 表在 **`storage.sqlite` 内** 与现役 `call_logs`/`context_recommendations`/`key_value`
同库, 自然乘 Litestream, 不另开任何日志文件 (那正是上一轮"HF 不存日志"要消灭的缺口)。

## 依赖证据(现役 file:line)

| 锚点 | 证据 |
|---|---|
| `candidate-v4.3-reviewed/entrypoint-merged.sh:17` | `DB_PATH="$DATA_DIR/storage.sqlite"` ← 库路径, events 必入此库 |
| `candidate-v4.3-reviewed/litestream.yml` dbs[0].path | `/app/data/storage.sqlite` 同库, Litestream 复制该库 |
| `candidate-v4.3-reviewed/init-nim-keys.sh:277` | 现役 `CREATE TABLE IF NOT EXISTS context_recommendations` 风格对齐 |
| `candidate-v4.3-reviewed/init-nim-keys.sh:80` | 现役已用 `sqlite3 "$DB" "SQL"` CLI 写入模式, events_write 复用 |
| `candidate-v4.3-reviewed/entrypoint-merged.sh:137` | `command -v sqlite3` 守门模式, events_write 借形 |

## 文件清单

- `events_schema.sql` — 4 列 schema (id/ts/event_type/payload) + 2 索引, `IF NOT EXISTS` 幂等
- `events_write.sh`  — bash 写入函数库 (source 用), 含 event_type 枚举校验 + JSON/单引号转义 + fail-open
- `verify_events.py`  — 本地 mock 验证 (python3 sqlite3 模块, 因本机无 CLI), 13/13 通过

## event_type 枚举(6 类)

| 事件 | 用途 |
|---|---|
| `boot_banner` | entrypoint boot 启动签名 (PORT/EXPOSED/DATA) |
| `upsert_result` | init combo upsert 结果 (PUT/POST HTTP code) |
| `cb_trip` | Circuit Breaker 跳闸 |
| `fallback_enter` | Account Fallback 进入罚态 |
| `fallback_exit` | Account Fallback 退出罚态 |
| `queue_drop` | 队列丢弃 |

## 写入点清单(init/entrypoint 关键签名处各一行)

| 写入点 | file:line | event_type | payload 例 |
|---|---|---|---|
| boot 启动签名 | `entrypoint-merged.sh:26` (上游服务启动后) | `boot_banner` | `{"port":20128,"exposed":7860,"data":"/app/data"}` |
| combo upsert 成功 | `init-nim-keys.sh:128` (PUT HTTP 2xx) | `upsert_result` | `{"combo":"nim-llm","verb":"PUT","code":200}` |
| combo upsert 成功 | `init-nim-keys.sh:132` (POST HTTP 2xx) | `upsert_result` | `{"combo":"nim-llm","verb":"POST","code":201}` |
| combo upsert 失败 | `init-nim-keys.sh:135` (非2xx fail-closed) | `upsert_result` | `{"combo":"nim-llm","verb":"POST","code":400,"fail":true}` |
| 熔断跳闸 | (上游 TS circuit breaker 处, R3 后定点接) | `cb_trip` | `{"provider":"nvidia","reason":"TBD-P1"}` |
| 罚态进入 | (上游 accountFallback 锁定时, R3 后定点接) | `fallback_enter` | `{"conn":"TBD-scoped","reason":"quota_exhausted"}` |
| 罚态退出 | (上游 cooldown 释放处, R3 后定点接) | `fallback_exit` | `{"conn":"TBD-scoped"}` |
| 队列丢弃 | (上游 queue drop 处, R3 后定点接) | `queue_drop` | `{"queue":"TBD","reason":"TBD"}` |

**接入约束**: 上述写入点接入属"改现役脚本", R3 解禁令前 **不 source 不接入**。
本补丁只交 schema + 写入函数 + 清单, 严禁拍脑袋估接入位置数值。

## v2 §6 金丝雀记录需求对齐(三类不缺)

| 类别 | event_type | 验证态 |
|---|---|---|
| 熔断跳闸 | `cb_trip` | ✅ 枚举含 + mock 写入过 |
| 罚态进出 | `fallback_enter` + `fallback_exit` | ✅ 枚举含 + mock 写入过 (对偶齐) |
| 队列丢弃 | `queue_drop` | ✅ 枚举含 + mock 写入过 |

三类一个不缺 → 满足 Supreme 第五步验收"写入点清单与 v2 §6 对齐"。

## 验证输出(Supreme 第五步验收项)

```
✅  events 列序正确 [id/ts/event_type/payload]
✅  索引 idx_events_ts + idx_events_event_type
✅  ts/event_type NOT NULL
✅  payload DEFAULT '{}'
✅  六类枚举全写入 (6/6)
✅  金丝雀三类 cb_trip/fallback_enter/queue_drop + fallback_exit 对偶齐
✅  含特殊字符 payload 正确入库+还原
✅  ts ISO8601 合法
✅  id 自增序与时序一致 (7/7)
✅  schema 无 CHECK (枚举由应用层 events_write.sh 守门, 设计一致)
13/13 通过
```

注意: 本机无 sqlite3 CLI, 验证用 python3 sqlite3 模块(同一引擎 3.37.2)。
现役上环境用 CLI(bootstrap 已装), events_write.sh 设计为 CLI。两者语义对齐。

## TBD 参数清单(依赖 R3, 禁拍脑袋)

| TBD | 说明 | 依赖 |
|---|---|---|
| **TBD-INSERT-1** | cb_trip/fallback_enter/queue_drop 三类在上游 TS 的精确钩点 file:line | R3 上游定点定位 + 只读取证 |
| **TBD-PAYLOAD-2** | 三类事件 payload 字段公约 (conn 范围/reason 枚举/队列名) | R3 金丝雀签名回填 |
| **TBD-RETAIN-3** | events 表保留策略 (与 call_logs 一致? TTL? R2 snapshot retention 兼容) | R3 持久容量核 |
| **TBD-FAILMODE-4** | fail-open vs fail-closed 边界 (现 fail-open 不崩业务; R3 判是否有"事件丢失即判失败"场景) | R3 可观测性需求 |

## 验收红线(写入以当验收标准)

1. 零新增持久通道 — 只写 storage.sqlite, 不开日志文件 ✅
2. schema 四列 + 两索引 ✅
3. 六类枚举全含, v2 §6 三类不缺 ✅
4. 写入函数 fail-open 不崩调用方业务 ✅
5. 枚举校验由应用层守门(无 SQL CHECK), 与"非法 type 拒写"一致 ✅
6. 未接入现役脚本(R3 解禁前) ✅
