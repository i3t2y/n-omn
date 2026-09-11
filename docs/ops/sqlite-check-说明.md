# storage.sqlite 健康巡检工具 (tools/sqlite_check.py)

> 建档: 2026-09-10 · Issue #8 · CodeBuddy(deepseek-v4.1-flash)
> 归属: ops 层 (docs/ops 永不进 Space, 不同步)
> 关联: [[2026-09-07-sqlite-corrupt-write-path]] (字面量分界铁律出处)

## 1. 用途

对 omn 网关的 `storage.sqlite` 做**定期可点检** (cron / 人工 / CI 皆可):

1. 完整性: `PRAGMA integrity_check` + `PRAGMA quick_check`
2. 统计: 表数量 / 总行数 / 逐表行数 / 页大小 / 折算体积 / 主库·WAL·SHM 体积
3. 异常告警: 核心表缺失、核心表 0 行、体积异常
4. 输出: 简洁中文报告到 stdout; `--json` 机器可读

**使命**: 做存储层的安全网 —— 在 09-07 事故 (活库 usage 写路径命中
`database disk image is malformed`) 之后, 把「定期验库」固化成一个可重复、
可编排、零副作用的动作。

## 2. 只读保证 (硬约束)

| 层 | 手段 |
|---|---|
| SQLite 连接层 | URI `file:<path>?mode=ro` |
| 会话层 | `PRAGMA query_only=ON` |

全程只跑 `PRAGMA` 与 `SELECT`, **零 DDL/DML**。实测 (见 §6): 巡检前后主库的
`sha256` + `mtime` + `size` 三项恒定, 非 WAL 库不生成任何 `-wal`/`-shm`。

> 诚实说明: 若库处于 WAL 态, SQLite 以**任意模式**打开都会创建/重写
> `*.sqlite-shm` (派生共享内存索引, 与 WAL 内容无关), 这是 SQLite 固有行为,
> 非本工具写库。**写库判据 = 主库与 `-wal` 字节不变** —— 二者实测恒不变
> (含非空 WAL 态, 见 §6)。

## 3. 路径解析

优先级: **命令行位置参数** > `$OMN_DB_PATH` > `$DB_PATH` >
默认 `$DATA_DIR/backups/db/storage.sqlite` (`DATA_DIR` 默认 `/data`)。

脚本**始终显式打印实际检查的文件与来源**, 不做静默回退 (避免「以为查了 A, 其实
查了 B」)。

### 为何默认指向快照池而非活库

- 活库 `/data/storage.sqlite` 在 HF Space **ephemeral 盘**, 每 boot 由快照池
  重建 —— 点检它只反映「本 boot 瞬时态」。
- 持久真源在 Bucket 挂载 `$DATA_DIR/backups/` 下的**快照池**, 由
  `logic/entrypoint.sh` 的 `_snap_gen` 事务一致生成 (`sqlite3 .backup`, 非裸
  `cp`) + 严格 `integrity_check` 门禁入池 (`_snap_verify` 只认字面量 `^ok$`)。
- → 长期观察对象应是快照池 (跨 boot 有意义); 需要看瞬时活库时显式传参即可:
  `python3 tools/sqlite_check.py /data/storage.sqlite`。

### 快照池实际落点 (2026-09-10 复核 entrypoint 实态, **非推断**)

| 对象 | 实际路径 | 出处 |
|---|---|---|
| 滚动池档 | `$DATA_DIR/backups/db-snap.<epoch>.db` (扁平, 无 `db/` 子目录) | `SNAP_DIR="$DATA_DIR/backups"` + `_snap_gen` 写 `$SNAP_DIR/db-snap.$_ts.db` |
| 兼容召回档 | `$DATA_DIR/backups/storage.last-good.sqlite` | `_snap_restore` 末位兜底 |
| 活库 | `$DATA_DIR/storage.sqlite` | `DB_PATH="$DATA_DIR/storage.sqlite"` |

滚动 GC 保最新 `SNAP_MAX=5` 份。**注意**: 首版默认常量写成
`backups/db/storage.sqlite` (子目录 `db/`), 与实际落点不符 —— 默认对象命中不了
任何真文件。本版已改为**扫描池目录择最新健康档**, 不再依赖硬编码单文件路径。

### 默认目标解析 (新版, 拒绝静默空转)

```
池内 db-snap.*.db 按 mtime 新→旧择首份 integrity_check 过者
  ↓ 全不过 / 池空
兼容档 storage.last-good.sqlite (体检过才用)
  ↓ 无 / 不过
活库 $DATA_DIR/storage.sqlite
  ↓ 也无
明确报「无目标库」+ exit 2 (绝不静默返回「全绿」)
```

报告始终打印**实际检查的文件**与**来源说明**, 并把"遍历过哪些档"写进来源行。
环境变量 `OMN_DB_PATH` / `DB_PATH` 只是通用兼容开关, **现役拓扑不设**
(`space/start.sh` 与 `logic/entrypoint.sh` 均未导出) —— 保留为逃生口, 不作主路径。

## 4. 判据: 字面量分界铁律

沿用 09-07 事故档的教训 —— **判据只认字面量, 不做语义推断**:

| 字面量 | 定性 | 判据 |
|---|---|---|
| `ok` | 健康 | **仅认单行精确等于 `ok`** (对齐 entrypoint `_snap_verify` 的 `^ok$`); 多行输出一律不判 ok |
| `database disk image is malformed` | **真损坏红旗** (09-07 事故档原文) | 硬失败 |
| `database corruption` | 真损坏红旗 (整库级措辞) | 硬失败 |
| `malformed database schema` | 真损坏红旗 (schema 页损坏, 带独立后缀) | 硬失败 |
| `malformed` | **兜底超集**: 上列三者皆含此子串; 独立成条防错拼/变体漏判成 `other` 而误判全绿 | 硬失败 |
| `file is not a database` / `file is encrypted` | 非 SQLite / 加密库 | 硬失败 (单独定性) |
| `PRAGMA` **超时** (看门狗中止) | 真损坏嫌疑, **未能证明健康** | 硬失败 (绝不判 ok) |
| `no such table` / `no such column` | **良性** (懒建表/幽灵表) | 不计损坏 |

**判据顺序**: 真损坏 > 非 SQLite > 良性 > 其他。损坏档上也可能出现
`no such table` (损坏后才读不到表) —— 不能让它盖过真损坏。

「`no such table` 良性 vs `malformed` 真局」严格区分, 与 09-05 幽灵表误判划清界限。

## 5. 输出与退出码

**退出码** (供 cron / CI 判读):

| 码 | 含义 | 触发 |
|---|---|---|
| `0` | 全绿 | 无红旗无告警 |
| `1` | WARNING | 核心表缺失 / 核心表 0 行 / 其他非损坏异常 |
| `2` | 硬失败 | 真损坏红旗 / 非 SQLite 文件 / PRAGMA 超时 / 路径不存在或非普通文件 / 无目标库 |

**核心表** (omn 3.8.50 `src/lib/db/core.ts` 实证):

- 应非空 (§0 铁律): `provider_connections` / `api_keys` / `key_value`
- 应存在 (可空): `provider_nodes` / `combos` / `db_meta`

缺失或应非空而 0 行 → WARNING; 非核心空表降为观察项 (免噪音)。

**`--json`** 输出结构: `path` / `path_source` / `generated_at` / `elapsed_s` /
`integrity_check`{raw,verdict,available} / `quick_check`{...} /
`watchdog`{enabled,usable,timeout_s} / `verdict` / `warnings[]` /
`tables[]` / `sizes{}` / `page_*` / `exit_code`。

> `raw` 保留**完整多行** PRAGMA 输出 (大库逐页损坏报告逐行留存, 不截断);
> 文本报告里只摘首行 + `(+N 行)` 提示, 免糊屏。取证走 `--json`。

### 单档点检超时看门狗

快照池档若被 FUSE 撕出坏页, `PRAGMA` 可能**极慢甚至卡死** —— 首版无超时,
一个卡死档就能拖死整次巡检 (cron 静默挂住, 反而失去告警能力)。

本版每个 `PRAGMA` 单档点检走**独立子进程 + 超时** (`SQLITE_CHECK_TIMEOUT`,
默认 30s, `<=0` 关闭):

- 超时 → 该项判 `timeout` = **未能证明健康** → 整次 `exit 2`, 绝不判 ok。
- 有 `sqlite3` CLI 时看门狗可用 (子进程独立, 卡死可杀); 缺 CLI 时退化为
  进程内调用, 报告会显式标注 `不可用` (不假装有保护)。

## 6. 验证记录 (2026-09-10, 合成 fixture)

**核心场景**:

| 场景 | 结果 |
|---|---|
| 正常库 (核心表齐全非空) | 全绿 exit 0 |
| 核心表 0 行 | 逐表告警 exit 1 |
| 核心表缺失 (仅 1 表) | 6 条告警 exit 1 |
| 真损坏 (页破坏, `malformed`) | 报红旗 exit 2 |
| 随机字节非 SQLite | `file is not a database` exit 2 |
| 0 字节 (空库) | 核心表全缺告警 exit 1 (空库=合法, 非损坏) |
| 路径不存在 / 目录 | exit 2 / exit 2 |
| `--json` 输出 | 合法 JSON, 字段齐全 (含 `watchdog`/`elapsed_s`) |
| `$OMN_DB_PATH` / `$DB_PATH` / CLI 优先级 | OMN > DB_PATH, CLI > 两者, 全部生效 |

**只读不改库**:

| 场景 | 结果 |
|---|---|
| DELETE 库 5 连跑 | 主库 sha256+size+mtime 恒定, 无 `-wal`/`-shm` 生成 |
| WAL 非空态 (24.7KB `-wal`) | 主库与 `-wal` 字节均恒定 (`-shm` 为 SQLite 固有派生物) |

**默认目标解析 (池)**:

| 场景 | 结果 |
|---|---|
| 池内 = 坏档(最新) + 健康档(较旧) | 跳过坏档, 命中较旧健康档, exit 0 |
| 池内全坏 + 活库健康 | 退活库, 来源行标 `活库回退`, exit 0 |
| 池空 + 无活库 | 明确报 `无目标库` + exit 2 (**不静默全绿**) |

**看门狗**:

| 场景 | 结果 |
|---|---|
| 假 `sqlite3` CLI (正常应答) | 报告标 `可用`, 判据与进程内路径一致 (ok/损坏/非 SQLite 三态对齐) |
| 假 `sqlite3` CLI (永久挂起) + `SQLITE_CHECK_TIMEOUT=3` | 12s 内收口 (4 项 × 3s), 判 `超时` + exit 2, **不挂死** |

## 7. 用法

```bash
# 默认 (Bucket 快照池: 自动择最新健康档 → 兼容档 → 活库)
python3 tools/sqlite_check.py

# 指定活库 / 指定某一份池档
python3 tools/sqlite_check.py /data/storage.sqlite
python3 tools/sqlite_check.py /data/backups/db-snap.<epoch>.db

# 机器可读 (取证/采集)
python3 tools/sqlite_check.py --json

# 环境变量逃生口 (现役拓扑不设)
OMN_DB_PATH=/data/backups/storage.last-good.sqlite python3 tools/sqlite_check.py

# 调看门狗超时 (默认 30s; <=0 关闭, 不推荐)
SQLITE_CHECK_TIMEOUT=10 python3 tools/sqlite_check.py
```

cron 示例 (每日 04:17, 非 0 退出即告警):

```cron
17 4 * * * /usr/bin/python3 /app/tools/sqlite_check.py --json \
  >/tmp/sqlite_check.json 2>&1 || echo "sqlite_check exit=$?" | \
  mail -s "omn sqlite 巡检告警" ops@example.com
```

## 8. 边界

- 纯 stdlib (`sqlite3`/`argparse`/`json`/`os`/`re`/`shutil`/`subprocess`/
  `sys`/`time`/`datetime`), 无第三方依赖。
- 只读, 无写操作, 无网络, 无 key。
- 不建后台常驻; 定时触发须外部编排 (cron / CI), 本工具只做单次点检。
- `dbstat` 未启用时页统计退化为 `PRAGMA page_size/page_count`。
- 看门狗需 `sqlite3` CLI 在位 (`shutil.which`), 缺则自动退化并**显式标注**。
- 默认目标解析需读池目录 (`os.listdir`), 目录不可读时按「池空」处理并继续
  下降 (兼容档 → 活库 → 明确报无目标)。

## 9. 与 entrypoint 快照池的分工

| 件 | 角色 | 触发 |
|---|---|---|
| `logic/entrypoint.sh` `_snap_gen` | **生成**事务一致快照 + 严格门禁入池 + 滚动 GC | boot 一次 + 每 `SNAP_INTERVAL`(6h) |
| `logic/entrypoint.sh` `_snap_restore` | **消费**池档种活库 | boot |
| 本工具 `tools/sqlite_check.py` | **只读点检**池档/活库健康 | 外部编排 (cron/CI), 本工具不生成、不改池 |

三者互不覆盖: 本工具**从不写入**池 (只读 `mode=ro` + `query_only`), 池的增删
仍只由 entrypoint 负责。巡检与生成解耦, 可独立编排、独立告警。
