# Stage E · audit/12 — 方向 B 加固 P3/P4/P5 启动逻辑安全性修复报告

> 目标: 实证方向 B 三加固 (P3 LOCK_FILE 可配置目录可写降级 + P4 purge 四本地地址变体 deleted=N + P5 wal_checkpoint busy/log/checkpointed 监控) **已落 working tree** 且 **mock 验全 PASS**.
> 生成日期: 2026-07-12
> 三基准: B1 nomn/main @ `42ea8e7` | B2 working tree @ `16549ea` (= candidate HEAD) | B3 omniroute-v3.8.43 @ `b729a8f`
> 关联: audit/02-claim-matrix.md · audit/05-test-results.md · audit/06-任务一 · audit/09-任务二 · audit/11-任务三 · candidate-v4.3-reviewed/entrypoint.sh · tests/test-runner.js
> 守纪: 仅改 candidate-v4.3-reviewed (working tree), 未访问生产实例, 未 install 依赖, 未改源码 B3.
> 测试结论: **PASS=96 FAIL=0 SKIP=2** (TEST 14 全 PASS 7/7; TEST 12 旧 7 用例随 P3/P4 升正则零回归; 80 旧测试 + TEST 11/13 不动).

## 0. 缺陷根因 (audit/02 CF-4 旁系 + audit/08 方向 B 现状)

任务二 (audit/09) 修了 entrypoint restore→purge→replicate→OmniRoute 时序六缺陷 D1-D6. 审时发现
三类启动逻辑安全性残留:

- **P3 (LOCK_FILE 硬编码)**: `LOCK_FILE="${DATA_DIR}/.entrypoint.lock"` 写死, 多容器部署置共享卷路径
  获跨容器互斥无 env 覆盖; 且 flock 获锁前不验锁目录可写 — 若 DATA_DIR 只读挂载 (read-only volume),
  `( exec 9>"$LOCK_FILE" )` 创建锁文件失败, 走 `flock 不可用` WARN 降级, 实为目录不可写根因被吞.

- **P4 (purge 单 host)**: pre-purge `WHERE host='127.0.0.1' AND port=$_P5` 仅清单一 IPv4 localhost.
  保留下游若 binding `::1`/`localhost`/`0.0.0.0` 三其余本地地址变体的幽灵 proxy_registry 条目 (>0).
  这些覆盖进 OmniRoute 内存后仍可 relay 进已关中继, 违 audit/02 CF-4 "中继关停无残留" 红线. 且
  purge 后无 changes() 行数日志 — 残留清空实证缺口.

- **P5 (wal_checkpoint 无 busy 监控)**: `PRAGMA wal_checkpoint(TRUNCATE)` 单跑, 不读 busy/log/checkpointed
  三值. Litestream 长连 reader 持有 WAL → checkpoint 返回 busy=1 (WAL 未全 checkpoint), 实为正常;
  但无日志则无法诊断 "purge 后 WAL 是否真 checkpointed", 运维盲区.

CF-4 旁系红线: **残条目清空实证 + WAL checkpoint 可诊断性缺失**.

## 1. 修复内容 (entrypoint.sh, 三处加固 + 一处 bug fix)

### 1.1 P3 — LOCK_FILE 可配置 + 目录可写 WARN 降级 (entrypoint.sh L72-83)

```bash
# P3: LOCK_FILE 可配置 (多容器部署置共享卷路径获跨容器互斥; 默认 $DATA_DIR/.entrypoint.lock 同旧硬编码).
#   获锁前断言 LOCK_FILE 所在目录可写: 不可写 → WARN 降级无锁继续 (不 exit 1), 记原因 + 实际锁路径.
#   flock 获取逻辑/失败行为不改 (flock 不可用仍 WARN 跳过; flock 失败仍 exit 1).
LOCK_FILE="${LOCK_FILE:-${DATA_DIR}/.entrypoint.lock}"
_lock_dir=$(dirname "$LOCK_FILE")
if [ -w "$_lock_dir" ] || [ ! -e "$LOCK_FILE" -a -w "$_lock_dir" ]; then
  :
else
  echo "[entrypoint] WARN: 锁目录不可写 LOCK_FILE=$LOCK_FILE dir=$_lock_dir → 降级无锁继续 (单容器内仍可获锁, 跨容器无互斥). 原因: dir 不可写或父级缺权限." >&2
fi
echo "[entrypoint] flock path=$LOCK_FILE"
```

- env `LOCK_FILE` 空时默认 `${DATA_DIR}/.entrypoint.lock` (与旧硬编码等位, 零行为差).
- 取 `dirname` 验可写: 不可写 WARN 降级无锁继续 **不 exit 1** (单容器内 flock 仍可获, 跨容器互斥失效).
- flock 获取 + 失败 exit 1 行为不改.

### 1.2 P4 — purge WHERE 四本地地址变体 + deleted=N (entrypoint.sh L186-245 sqlite3 CLI + node fallback 双路)

**sqlite3 CLI 路径**:

```bash
_pre=$(sqlite3 "$DB" "SELECT COUNT(*) FROM proxy_registry WHERE host IN ('127.0.0.1','::1','localhost','0.0.0.0') AND port=$_P5;" 2>/dev/null || echo "?")
echo "[entrypoint] FIX #5 pre-purge: relay ${_H5}:${_P5} purge 前=$_pre 条 (host IN 四本地地址变体 + port 约束)."
# 事务化 purge (BEGIN...COMMIT):
DELETE FROM proxy_assignments WHERE proxy_id IN
  (SELECT id FROM proxy_registry WHERE host IN ('127.0.0.1','::1','localhost','0.0.0.0') AND port=$_P5);
UPDATE provider_connections SET proxy_enabled=0 WHERE provider='nvidia';
DELETE FROM proxy_registry WHERE host IN ('127.0.0.1','::1','localhost','0.0.0.0') AND port=$_P5;
# P4: purge 事务提交后用 changes() 取实际删除行数 (proxy_registry DELETE 行数).
_purge_del=$(sqlite3 "$DB" "SELECT changes();" 2>/dev/null || echo "?")
echo "[entrypoint] pre-purge deleted=${_purge_del} rows"
```

**node:sqlite fallback 路** (原 bug: `placeholders` 缺左 `(`, 仅 `?,?,?,?)` → SQL 语法错):

```javascript
const hosts = ["127.0.0.1","::1","localhost","0.0.0.0"];
const placeholders = "(" + hosts.map(()=>"?").join(",") + ")";   // BUG fix: 旧 ph="(" 备而不用, 漏拼左括号
const pre = db.prepare("SELECT COUNT(*) AS c FROM proxy_registry WHERE host IN " + placeholders + " AND port=?").all(...hosts, port)[0].c;
db.exec("BEGIN");
db.prepare("DELETE FROM proxy_assignments WHERE proxy_id IN (SELECT id FROM proxy_registry WHERE host IN " + placeholders + " AND port=?)").run(...hosts, port);
db.prepare("UPDATE provider_connections SET proxy_enabled=0 WHERE provider=?").run("nvidia");
const del = db.prepare("DELETE FROM proxy_registry WHERE host IN " + placeholders + " AND port=?").run(...hosts, port);
db.exec("COMMIT");
console.log("[entrypoint] pre-purge deleted=" + del.changes + " rows");
```

- WHERE 扩 `host IN ('127.0.0.1','::1','localhost','0.0.0.0')` 四变体, 保留 `AND port=$_P5` 约束.
- 三条事务 (proxy_assignments DELETE + provider_connections UPDATE + proxy_registry DELETE) BEGIN...COMMIT 原子.
- **bug fix**: node fallback 旧 `const ph = "(", placeholders = hosts.map(()=>"?").join(",") + ")"` — `ph` 备而不用,
  `placeholders` 实拼 `?,?,?,?)` 缺左 `(` → SQL syntax error. P4 改为 `"(" + hosts.map(...).join(",") + ")"`.

### 1.3 P5 — wal_checkpoint busy/log/checkpointed 监控 + busy>0 WARN 不 exit 1 (entrypoint.sh L247-263)

**node:sqlite fallback 路**:

```javascript
const ck = db.prepare("PRAGMA wal_checkpoint(TRUNCATE)").get();
const busy = String(ck && ck.busy != null ? ck.busy : "?");
const log = String(ck && ck.log != null ? ck.log : "?");
const ckptd = String(ck && ck.checkpointed != null ? ck.checkpointed : "?");
console.log("[entrypoint] wal_checkpoint busy=" + busy + " log=" + log + " checkpointed=" + ckptd);
if (!isNaN(Number(busy)) && Number(busy) > 0) {
  console.log("[entrypoint] WARN: wal_checkpoint busy=" + busy + " (Litestream reader 占 WAL → WAL not fully checkpointed, 无需手动). 不阻断启动.");
}
```

**sqlite3 CLI 路** (cut -f1/2/3 读三列):

```bash
_ckpt=$(sqlite3 "$DB" "PRAGMA wal_checkpoint(TRUNCATE);" 2>/dev/null | tr '\t' '\n' || true)
_ck_busy=$(echo "$_ckpt" | sed -n '1p' | cut -f1)
_ck_log=$(echo "$_ckpt" | sed -n '2p' | cut -f2)
_ck_ckptd=$(echo "$_ckpt" | sed -n '3p' | cut -f3)
echo "[entrypoint] wal_checkpoint busy=$_ck_busy log=$_ck_log checkpointed=$_ck_ckptd"
if [ "$_ck_busy" -gt 0 ] 2>/dev/null; then
  echo "[entrypoint] WARN: wal_checkpoint busy=$_ck_busy (Litestream reader 占 WAL → WAL not fully checkpointed, 无需手动). 不阻断启动." >&2
fi
```

- `wal_checkpoint(TRUNCATE)` 读 busy/log/checkpointed 三值.
- busy>0 (Litestream 长连 reader 持 WAL) → WARN "not fully checkpointed" **不 exit 1** (非阻断, 非错).
- busy=0 → 静默全 checkpointed.

## 2. 红线验证 — CF-4 旁系闭环

| CF-4 旁系红线 | 旧缺 | P3/P4/P5 修 | 验位 |
|---|---|---|---|
| 中继关停无残留 (四本地地址变体) | P4 单 host 清不全 | WHO 扩四变体 + changes() 行数日志 | TEST 14 T14-05 动态 deleted=4 post=0; T12-06 旧幂等仍 PASS |
| purge 删除实证 | 无 deleted=N 日志 | changes()/del.changes 行数输出 | TEST 14 T14-02 静 + T14-05/06 动 deleted=N |
| WAL checkpoint 可诊断 | 无 busy log | busy/log/checkpointed 三值 + busy>0 WARN 不阻断 | TEST 14 T14-03 静 + T14-07 动 busy=0 log=0 ckptd=0 |
| (P3) 锁目录可写 | 硬编码 + 无就绪 | LOCK_FILE env + 目录可写 WARN 降级不 exit | TEST 14 T14-01 静 + T14-04 动 DEGRADED |

## 3. 测试矩阵 (TEST 14, 7 用例 3 静 4 动)

| 用例 | 类 | 断言 | 结果 |
|---|---|---|---|
| T14-01 | P3 静 | LOCK_FILE 可配置 + 目录可写 WARN 降级 + flock path 日志 + 失败 exit 1 不改 | ✓ |
| T14-02 | P4 静 | WHERE host IN (四变体) + port 约束 + changes() deleted=N (CLI + node fallback) | ✓ |
| T14-03 | P5 静 | wal_checkpoint busy/log/checkpointed 三值 + busy>0 WARN 不 exit 1 (CLI + node fallback) | ✓ |
| T14-04 | P3 动 | LOCK_FILE env 可读 + 不可写目录 WARN 降级 DEGRADED 不 exit | ✓ |
| T14-05 | P4 动 | 四本地地址变体 20129 全清 deleted=4 + post=0 + 留非目标 2 条 (127.0.0.1:20130 + example.com:20129) + nvidia→0 anthropic 不动 | ✓ |
| T14-06 | P4 动 | 幂等 二轮 deleted=0 post=0 | ✓ |
| T14-07 | P5 动 | wal_checkpoint(TRUNCATE) 返回 busy=0 log=0 checkpointed=0 (无 Litestream reader) | ✓ |

加 TEST 12 旧 7 用例随 P3/P4 升正则零回归 (T12-03/T12-04 regex 改 `host IN` + `${LOCK_FILE:-默认}` + node fallback `process.exit(1)` + 目录可写 WARN).

## 4. 一致性结论

- **B2 ← B1**: candidate-v4.3-reviewed @ `16549ea` working tree 加 P3/P4/P5 + bug fix + TEST 14;
  入口/PSK/path matrix/上游 status/SSE/ab basic-auth/signal/idempotent/litestream/residual/TEST 11/13 零改动.
- **B3 未触**: 全程仅改 candidate-v4.3-reviewed (working tree), 未 install 依赖, 未访问生产实例.
- **红线下垂**: CF-4 旁系三红线 (中继关停无残留 / purge 删除实证 / WAL 可诊断) + P3 锁目录可写全 PASS.

## 5. 接续

- audit/06 (任务一 Resilience PATCH) · audit/09 (任务二 entrypoint 时序) · audit/11 (任务三 gate ECONNRESET) · **本文件 audit/12 (方向 B P3/P4/P5)**: Stage E 四轮修毕.
- 后续可驱 root sync (candidate v4.3-reviewed → /) + instance readback (audit/07) 实生验.
- TEST 14 全 PASS 7/7; 全套 **96 PASS / 0 FAIL / 2 SKIP** (SKIP = TEST 8/9 实跑须 R2 真 Litestream, 老 SKIP).
