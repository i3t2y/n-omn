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
| `patch_db_local.py` | 幂等改 `entrypoint.sh`，在 `export DATA_DIR` 后 source 上面脚本 |
| `helper.sh` | 起 gate 前自动跑两个 patch（含 init_hold） |

**生效**：同步 Bucket 后 **Restart 两次**（第一次 helper 打补丁；第二次 entrypoint 已带双盘）。或一次 Restart 后手动：

```bash
python3 /logic/patch_db_local.py --entrypoint /logic/entrypoint.sh
# 再 Restart
```

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

`logic/` → Bucket → Restart（库双盘建议两次或手动 patch_db_local 一次后再 Restart）。
