# Stage E · audit/09 — 任务二#22 entrypoint restore→purge→replicate→OmniRoute 时序修复报告

> 目标: 实证 task#22 six 缺陷 (audit/08 §5.1 D1-D6) **已落 working tree** 且 **mock 验全 PASS**.
> 生成日期: 2026-07-12
> 三基准: B1 nomn/main @ `42ea8e7` | B2 working tree @ `9a1a7f0` (= candidate HEAD = `55e9a8a`)| B3 omniroute-v3.8.43 @ `b729a8f`
> 关联: audit/02-claim-matrix.md (CF-4) · audit/05-test-results.md · audit/06-任务一修复报告 ·
>   audit/07-instance-readback-plan.md · audit/08-task2-entrypoint-sequence-baseline.md (修改前实证)
> 守纪: 仅改 candidate-v4.3-review (working tree), 未访问生产实例, 未 install 依赖, 未改源码 B3.
> 测试结论: **PASS=80 FAIL=0 SKIP=2** (TEST 11 + TEST 12 全 PASS, 72 旧测试零改动).

## 1. litestream.yml 全文 + $DB/$DB_TMP 赋值

### 1.1 litestream.yml (HEAD+修后一致, 关键 `auto-recover: false`)

```yaml
dbs:
  - path: /data/storage.sqlite
    replica:
      type: s3
      bucket: omniroute-data
      path: db/storage.sqlite
      endpoint: https://${R2_ACCOUNT_ID}.r2.cloudflarestorage.com
      access-key-id: ${R2_ACCESS_KEY_ID}
      secret-access-key: ${R2_SECRET_ACCESS_KEY}
      region: auto
      sync-interval: 10s
      auto-recover: false   # v4.3 红线3 防 replicate 启动时自恢复绕 guard
snapshot:
  interval: 1h
  retention: 24h
```

### 1.2 $DB / $DB_TMP (entrypoint.sh L20-21)

```sh
DB="$DATA_DIR/storage.sqlite"            # L20 ($DATA_DIR 默认 /data, L14)
DB_TMP="$DATA_DIR/.storage.sqlite.restore.$$"  # L21 (临时恢复路径, 原子保护)
```

- `$DB` = `/data/storage.sqlite` (litestream.yml `dbs[].path` 匹配, T12-07 已验).
- `$DB_TMP` ≠ `$DB`, restore 输出临时路径 quick_check 通过后 `mv` 原子替换 (T12-05 验无泄漏).

## 2. proxy_registry 表 schema (B3 源码实证 + task#22 purge 依据)

### 2.1 列全集 (B3 `src/lib/db/proxies.ts` L78-80 INSERT 实证)

```sql
INSERT INTO proxy_registry
  (id, name, type, host, port, username, password, region, notes, status, source, family, created_at, updated_at)
  VALUES (?, ?, ..., ?)   -- 14 列
```

### 2.2 旧条目精确识别 (task#22 purge SQL 锚)

**`host='127.0.0.1' AND port=20129`** — entrypoint.sh L172 / L176 / L192 同用此二元组
(init 候选 + B3 zod 无 UNIQUE 约束, 但 upsert 路径按 host+port 查重).

## 3. entrypoint.sh 时序对照 (修前 baseline vs 修后)

### 3.1 HEAD baseline (`55e9a8a`) 时序 — 6 缺陷 D1-D6 (见 audit/08 §5.1)

```
1. restore (无 -o; 失败 STRICT=1 exit)             → D3,D4
2. OmniRoute 启动 (purge 缺失致幽灵进内存)         → D1
3. health 等待 → 版本护栏 → NIM init → OR_API_KEY 等
4. litestream replicate (OmniRoute 启动后)         → D2
5. gate 启动 → 监督循环
[无 flock; 无 $DB path 一致性 assert]               → D5,D6
```

### 3.2 修后时序 (working tree @ candidate)

```
L69   echo "[entrypoint] cold-boot (restore→purge→replicate→OmniRoute, 严格时序)..."
L73-80 flock (fd 9 排他锁 + 失败 exit 1 + 不可用 WARN)   → D5 修复
L101-157 restore (-o $DB_TMP; 失败 WARN 不 exit)         → D3,D4 修复
L159-201 pre-purge (事务 + host+port + assert 残留=0)    → D1 修复
L203-226 replicate (OmniRoute 前) + $DB path 一致性 assert → D2,D6 修复
L228+  OmniRoute 启动 (purge + replicate 之后)
L244   node /app/server.js --log &
```

## 4. flock / 互斥机制 (D5 修复实证)

### 4.1 HEAD baseline — 无互斥 (0 grep 命中)

### 4.2 修后 (entrypoint.sh L67-80)

```sh
L73  LOCK_FD=9
L74  LOCK_FILE="${DATA_DIR}/.entrypoint.lock"
L76  ( exec 9>"$LOCK_FILE" ) 2>/dev/null
L77  if command -v flock >/dev/null 2>&1; then
L77    flock -x 9 || { echo "[entrypoint] FATAL: 无法获取文件锁 $LOCK_FILE (另一容器占用?). abort." >&2; exit 1; }
L80  else echo "[entrypoint] WARN: flock 不可用, 跳过跨容器互斥 (HF Space 优先单实例)."; fi
```

- fd 9 排他锁跨容器互斥; flock 不可用降级 WARN (distroless 等无 flock 容器兼容).
- 锁范围 = 整 entrypoint 进程生命 (fd 9 在 entrypoint 退出前不释); 子进程 fork 继承 fd 但不持锁语义.

## 5. 修复代码定位 (D1-D6 逐对应行号)

| 缺陷 | 缺陷实证 (baseline) | 修复定位 (修后 entrypoint.sh) | 验测试 |
|------|---------------------|-------------------------------|--------|
| **D1** 无 purge → R2 旧库带回 20129 幽灵 → OmniRoute 内存污染 (B6 L2 proxies.ts 无 reload 钩子) | baseline 0 grep `pre-purge` 命中 | L159 `# ── 2. FIX #5 pre-purge` 段起; L173 `purge 前=$_pre`; L179-184 事务 BEGIN/COMMIT 三 DELETE; L185 `事务失败...exit 1`; L189 `wal_checkpoint(TRUNCATE)`; L192-197 `_post` COUNT assert + `exit 1` | T12-01, T12-03, T12-06 |
| **D2** replicate 在 OmniRoute 启动后 → baseline 含旧条目 → R2 持续存幽灵 | baseline L7 replicate 在 L2 OmniRoute 之后 | L215 `litestream replicate -config /litestream.yml &` (在 L244 OmniRoute 启动前); L213 `$DB path 一致性 assert` 先验 | T12-01 (时序断言 replicate(215) < OmniRoute(244)) |
| **D3** restore 失败 STRICT=1 直接 exit → HF Space 易总启动失败 | baseline restore 失败直接 `exit 1` | L117 `WARN: restore rc=$rc`; L118 `STRICT=1: 仅告警, 不 exit (空库启动)`; L132 同 (quick_check fail 路径); restore 失败分支无 exit 1 | T12-02 (静态实证失败分支无 exit 1) |
| **D4** restore 不用 `-o` → `$DB_TMP` 当 db 标识符 ≠ yml `dbs[].path` | baseline `restore ... "$DB_TMP"` 无 `-o` | L104 `litestream restore -config /litestream.yml -if-replica-exists -o "$DB_TMP" "$DB" 2>/tmp/ls_restore.err`; L107 fallback litestream 0.5.9 不支持 -o 直恢 | T12-01 (restore -o 行在 L104), T12-05 ($DB_TMP 清理) |
| **D5** 无 flock → 多容器并发 restore/purge/替换 $DB 无互斥 | baseline 0 grep `flock\|LOCK\|mutex` 命中 | L73 `LOCK_FD=9`; L74 `LOCK_FILE`; L76 `exec 9>"$LOCK_FILE"`; L77 `flock -x 9 \|\| { ...exit 1 }`; L80 `flock 不可用...WARN` | T12-04 |
| **D6** restore→OmniRoute 间无 `$DB` 与 litestream.yml `dbs[].path` 一致性 assert | baseline 0 grep `path 不一致\|一致性` 命中 | L213 `printf '%s' "$DB" \| grep -q "^${DATA_DIR}/storage.sqlite$" \|\| { ...exit 1 }`; L214 `FATAL: \$DB=$DB 与 litestream.yml dbs[].path 不一致` | T12-07 ([T12-07 测试](test-runner.js:626)): entrypoint `DB="$DATA_DIR/storage.sqlite"` + yml `dbs[].path=/data/storage.sqlite` + grep assert exit 1 |

## 6. mock 已验证 vs 仍需生产确认

### 6.1 已由 mock (TEST 12, T12-01~T12-07) 验证 — PASS=7/7

| TEST | 验证项 | 验证方式 | 结果 |
|------|--------|----------|------|
| T12-01 | 时序锁: restore(104)<pre-purge(173)<replicate(215)<OmniRoute(244) | 静态行号 findLine + assert ok 顺序 | ✓ PASS |
| T12-02 | restore 降级: rc!ne 0 分支仅 WARN, 0 exit 1 | 静态 regex `if [ "$rc" -ne 0 ]...elif` + 无 `exit 1` 实证 | ✓ PASS |
| T12-03 | purge assert 失败: `_post != "0"` → `FATAL` + `exit 1` | 静态 regex `_post=...` `FATAL: pre-purge assert 失败[\s\S]*?exit 1` | ✓ PASS |
| T12-04 | flock 互斥: LOCK_FD=9 + path + exec 9 + flock -x 9 失败 exit 1 + 不可用 WARN | 静态 5 regex 全 ok | ✓ PASS |
| T12-05 | $DB_TMP 不泄漏: 5 清理点 `rm -f $DB_TMP{,-wal,-shm}` 后无残留 | 进程 fixture (mkdir tmp + touch + 5×rm + grep -c) + 静态计数 ≥4 | ✓ PASS |
| T12-06 | purge 幂等: 两轮 purge post1/post2 均为 0, proxy_enabled→0, 无前置 _pre>0 guard | node:sqlite (Node22+) 真 fixture (建表+插+两轮事务 purge+COUNT); 静态 purge block 无 _pre>0 guard | ✓ PASS |
| T12-07 | path 一致性 assert: $DB 与 yml `dbs[].path` 均为 /data/storage.sqlite + grep assert exit 1 | 静态 regex `printf'%s' $DB \| grep -q ... \|\| exit 1` + yml 读 dbs[].path 比较 | ✓ PASS |

**TEST 12 总: 7 用例 + 1 汇总 = 8 ok (全 PASS). 72 旧测试零改动 (TEST 1-10 + TEST 11 同前).**

### 6.2 仍需生产确认 (mock 不可达, 属 NEEDS-INSTANCE)

| # | 待确认项 | 原因 | 建议 |
|---|----------|------|------|
| P1 | 真 R2 restore 命中幽灵 `proxy_registry` 条目 + 精确识别 `host+port` =  `20129` 于生产 | mock 用 `node:sqlite` 内存/临时 fixture, 无真 R2 副本; R2 历史副本可能含 `host` 非纯 `127.0.0.1` (如改过 IP) 或 `port` 变更 | 部署后 `sqlite3 /data/storage.sqlite "SELECT * FROM proxy_registry WHERE port=20129;"` 实例 readback (audit/07 plan) |
| P2 | litestream `replicate` 真 OmniRoute 拉起前 `baseline=` 已无幽灵 (T2 模拟的提前仅在静态时序已验, 真行为非 mock) | replicate 进程行为需 litestream + R2 + OmniRoute 三者联动; v4.3 `litestream verify`/`litestream snapshots` 命令需生产 | 部署后 `litestream snapshots -replica-path db/storage.sqlite -config /litestream.yml` 验 baseline + 时间戳 |
| P3 | flock 跨容器真互斥 | HF Space 单实例 + `flock` 行为对 fd 9 fork 子进程持锁语义在 production `distroless` 容器未测 | HF Space 多容器重启 (如部署滚动) 验 `LOCK_FILE` 互斥 / log `lock acquired` |
| P4 | `$DB path 一致性 assert` 真 `exit 1` 触发 (配置漂移场景) | T12-07 仅静态验断言存在, 未构造路径不匹配 fixture 触发 `exit 1` (因 OmniRoute 启动前 fork 真 entrypoint 隔离复杂) | 集成测试: `DATA_DIR=/tmp/wrong` 跑 entrypoint, 期 FATAL exit 1 |
| P5 | `wal_checkpoint(TRUNCATE)` 真 litestream replicate 后 WAL 不回生幽灵条目 (mock 仅验 `wal_checkpoint` 命令存在, 真持久性需 R2) | mock fixture 无 litestream + 真 WAL; `purgeTxn.delete` 已验但 `wal_checkpoint(TRUNCATE)` 后续 litestream 不写幽灵未端到端 | 部署后 `litestream snapshots` 历史 + 新基线不含幽灵 |
| P6 | restore 降级: R2 短瞬 fail (网络抖) 真 WARN 不 exit 后 OmniRoute 仍正常 serve | T12-02 静态验分支无 `exit 1`, 但真 R2 unreachable 后空库正常迁移 init 重建路径需生产 | HF Space 用 R2 模拟断网 (env override R2 endpoint 错) 验 WARN + OmniRoute 启动 |

## 7. 下一步 / 守纪声明

### 7.1 守纪边界 (本 audit/09 触守)

- 仅改 `candidate-v4.3-reviewed/tests/test-runner.js` (新增 TEST 12 7 用例 + main 调度, 0 改 72 旧测试断言).
- entrypoint.sh/gate.js/init-nim-keys.sh/Dockerfile/litestream.yml/package.json **未本 turn 改** (task#22 代码已于前数 turn 落 working tree, 仅 audit/09 实证).
- 0 访生产实例, 0 install 依赖, 0 改源码 B3 (`/home/laisi/omniroute-v3.8.43`).

### 7.2 task#22 状态

✅ **done** — D1-D6 六缺陷逐点修 (行号见 §5), TEST 12 + 7 用例全 PASS (mock 层全验); 仍需生产确认项 P1-P6 见 §6.2 (属 NEEDS-INSTANCE, 不阻断 mock 签名).

### 7.3 后续

1. **task#22 commit 准备** (待 user 同步指令): gate.js + entrypoint.sh + init-nim-keys.sh + test-runner.js (TEST 11+12 增量) working tree → 单 commit.
2. **audit/07 实例 readback plan** (P1-P6) 仅在生产部署后展开.
3.task#23 gate ECONNRESET 结构化诊断 (任务三) — 与本文件正交, 待启.
