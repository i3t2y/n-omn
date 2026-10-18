# n-omn 运维（2026-10-18 收口）

## 数据库错误怎么修

### 根因

活库 `storage.sqlite` 若在 **Bucket mount**（网络 FS）上跑，再叠加 **WAL / mmap**，会 SIGBUS、`SQLITE_CORRUPT`、`READONLY`。不是「换了 Bucket 名字」本身，是 **挂载上当在线盘**。

### 已有减损（每 boot）

`db_harden.sh`：完整性检查 → 健康快照恢复 → `journal_mode=DELETE` → 关 mmap → 清 `-wal/-shm`。

### 治本（本仓新增）

**双盘**：活库 `/opt/omn-data/storage.sqlite`（本地），Bucket 只留 `backups/` 与副本。

| 文件 | 作用 |
|------|------|
| `db_local_boot.sh` | Boot 时本地无/坏库 → 从 Bucket 健康源拉回；`export DATA_DIR` 到本地 |
| `entrypoint.sh`（git 固化，2026-10-18） | `export DATA_DIR` 后 source 上面脚本；快照池/挂载探针恒指 Bucket（`OMN_BUCKET_DATA`，双盘下 `DATA_DIR` 已切本地）；init-hold 加锁/清锁 |
| `patch_db_local.py` | 仅手动补打用（helper 不再调用）；写文件一律原子 rename，禁止原地截断运行中的脚本 |
| `helper.sh` | 起 gate 前只打 `gate.js` 补丁（init_hold 中间件）；init 锁只做存活校验（PID 文件 + `kill -0`），活锁绝不删 |

**生效**：同步 Bucket 后 **Restart 一次**（双盘与 init-hold 已固化进 git 的 `entrypoint.sh`；`/logic` 每 boot 从 Bucket 重拉，runtime 改动活不到下轮）。

关闭双盘：`OMN_DB_LOCAL=0`。

### 已坏库时（容器内救急）

```bash
# 1) 看是否坏
sqlite3 "$DATA_DIR/storage.sqlite" "PRAGMA integrity_check;"

# 2) 跑硬化/自愈（路径按实际）
bash /logic/db_harden.sh "$DATA_DIR/storage.sqlite"

# 3) 仍坏：从快照手搓
ls -lt "$DATA_DIR/backups"/db-snap.*.db | head
cp -f "$DATA_DIR/backups/db-snap.XXXX.db" /opt/omn-data/storage.sqlite
rm -f /opt/omn-data/storage.sqlite-wal /opt/omn-data/storage.sqlite-shm
sqlite3 /opt/omn-data/storage.sqlite "PRAGMA journal_mode=DELETE;"

# 4) Restart；看日志 [db-local] / [db-harden]
```

无健康快照时：隔离坏库让 init 空库重建（`db_harden` 会 `mv …corrupt-*`），再用 `hot_apply` / init 重灌 key。

### 验证

```bash
echo "$DATA_DIR"   # 期望 /opt/omn-data
mount | grep -E 'omn-data|fuse|xet' || true
sqlite3 "$DATA_DIR/storage.sqlite" "PRAGMA journal_mode; PRAGMA integrity_check;"
# journal_mode 期望 delete；integrity 期望 ok
```

---

## 开机 502 → 503 诚实等待

`helper` + `init_hold`：init 期间 `/v1` → 503，`/healthz` → 200。详见源码注释。`GATE_INIT_HOLD=0` 强制放行。

## 加 key / 模型 / 绑 FT（不重启）

```bash
export INITIAL_PASSWORD='...'
python3 /logic/hot_apply.py --spec /logic/hot-apply.example.json
```

## 部署

`logic/` → Bucket → Restart 一次。

---

## 2026-10-18 启动链修复记（验收通过，定为基线）

1. **禁止 runtime 改写运行中的 entrypoint.sh**：bash 按字节偏移增量读脚本，原地截断重写 → 解析错位 → `syntax error near unexpected token` exit 2（本地实证复现）。补丁脚本一律同目录 tmp + `os.replace` 原子写；entrypoint 侧改动直接进 git。
2. **被 source 的库脚本不得泄漏 shell 选项**：`db_local_boot.sh` 自带 `set -u`，被 source 后泄漏进 entrypoint 开启 nounset，致 `_ft_abandoned: unbound variable` exit 1。source 后立即 `set +u` 还原；裸变量一律写 `${v:-default}`。
3. **init 存活判定不用 pgrep**：精简镜像常无 procps，实测漏检运行中的 init 并误删 fresh lock（致 init-hold 失效）。entrypoint 起 init 时把 PID 写进 lock 文件，helper 用 `kill -0` 精确判活。
4. **`/logic` 每 boot 从 Bucket 重拉并 sha256 校验**：runtime patch 活不到下轮，「Restart 两次」作废；快照池与挂载探针必须恒指 Bucket（`OMN_BUCKET_DATA`），否则双盘下快照写本地盘、重启丢池丢 key。
