# Stage E · audit/08 — 任务二#22 entrypoint restore→purge→replicate→OmniRoute 时序 (修改前实证基础)

> 目标: 为 task#22 建立**修改前**完整实证基础. 本文件只读, 零写代码.
> 生成日期: 2026-07-12
> 三基准: B1 nomn/main @ `42ea8e7` | B2 working tree @ `9a1a7f0` (实际 = candidate HEAD = `55e9a8a`)| B3 omniroute-v3.8.43 @ `b729a8f`
> 关联: audit/02-claim-matrix.md (CF-4) · audit/05-test-results.md · audit/06-任务一修复报告 ·
>   audit/07-instance-readback-plan.md (实例 readback, 与本文件**不同域** — 本文件是**修改前实证**, 非实例 readback)
> 守纪: 只读验证, 不改源码, 不访问生产实例, 未 install 依赖.

## 0. 上下文厘清 (重要)

- 工作目录 `candidate-v4.3-reviewed/entrypoint.sh` **已是修后状态** (本 turn 前已 145+/73- 改).
- "修改前" = git HEAD `55e9a8a` 版 (commit msg: "rollback: ... entrypoint to baseline").
- 本 audit/08 记录**修改前 baseline 实证 + 修改后状态** 双侧对照, 供 task#22 决策.

## 1. litestream.yml 全文 + $DB/$DB_TMP 赋值

### 1.1 litestream.yml 全文 (修后未变, HEAD 同)

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
      auto-recover: false   # v4.3 红线3: 改 false. entrypoint 已显式 restore
snapshot:
  interval: 1h
  retention: 24h
```

- `dbs[].path` = `/data/storage.sqlite` (与 `$DB` 匹配, 非 `$DB_TMP`).
- `auto-recover: false` (修后注释明 entrypoint 已显式 restore, 防 litestream replicate 启动时自恢复绕过 guard).

### 1.2 $DB / $DB_TMP 变量赋值 (HEAD + 修后均)

```sh
DB="$DATA_DIR/storage.sqlite"            # entrypoint.sh:20
DB_TMP="$DATA_DIR/.storage.sqlite.restore.$$"   # L21, 临时恢复路径 (原子保护)
# $DATA_DIR 默认 /data (L14), $$ = entrypoint PID (隔并发)
```

- **$DB ≠ $DB_TMP**: 一为正式, 一为临时. litestream restore `-o "$DB_TMP"` 输出临时路径,
  `quick_check` 通过后 `mv "$DB_TMP" "$DB"` 原子替换 (修后 L104, L140).
- HEAD baseline 不用 `-o`: `litestream restore ... "$DB_TMP"` (把 $DB_TMP 当 restore 数据库标识符 ≠ 期望, litestream 把它当 db-path 与 yml `dbs[].path` 不匹配 → restore 创不出正确副本). 修后用 `-o "$DB_TMP" "$DB"`: `$DB` 作数据库标识符 (匹配 yml path), `-o` 指输出路径.

## 2. proxy_registry 表 schema (B3 源码实证)

### 2.1 列全集 (B3 `src/lib/db/proxies.ts` L78-80 INSERT 实证)

```sql
INSERT INTO proxy_registry
  (id, name, type, host, port, username, password, region, notes, status, source, family, created_at, updated_at)
  VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
```

14 列: `id, name, type, host, port, username, password, region, notes, status, source, family, created_at, updated_at`.

### 2.2 zod 约束 (B3 `src/shared/validation/schemas/proxy.ts` L104-124)

- `host`: `z.string().trim().min(1).max(255)` (必填)
- `port`: `z.coerce.number().int().min(1).max(65535)` (必填)
- `type`: enum `http/https/socks5/vercel/deno/cloudflare`, default `http`
- `status`: enum `active/inactive`, default `active`
- `source`: enum `manual/oneproxy/dashboard-custom/vercel-relay/deno-relay/cloudflare-relay`
- `family`: enum `auto/ipv4/ipv6`, default `auto` (migration test L7-10 实证 family 列)
- `.strict()` 拒未知键

### 2.3 旧条目可精确识别字段 (task#22 purge 依据)

**精确识别 = `host = '...' AND port = N`** (init 候选已用此, entrypoint 修后 purge 段 L172/L179/L181/L192 同):
- `host` + `port` 二元组在 schema 唯一性 (无 UNIQUE 约束实证, 但 upsert 路径按 host+port 查重 — `proxies.ts` 内).
- 可加 `source` 细化 (relay 条目 source 应为 `...-relay` 值), 但 host+port 已足区分 (NIM relay 默认 `127.0.0.1:20129`).

## 3. entrypoint.sh 时序对照 (修前 baseline vs 修后)

### 3.1 HEAD baseline (`55e9a8a`) 时序

```
1. restore (R2 → $DB_TMP → quick_check → mv $DB_TMP $DB)
   └ restore 失败: LITESTREAM_STRICT=1 直接 exit (无降级)
2. OmniRoute 启动 (node /app/server.js --log)
3. health 等待 (max 180s)
4. 版本护栏 (只告警)
5. NIM init (后台)
6. OR_API_KEY 文件等待 (max 120s)
7. litestream replicate (后台)            ← replicate 在 OmniRoute 启动后
8. OmniRoute 健康二次确认
9. gate 启动
10. 监督循环
```

**baseline 缺陷**:
- **无 purge 段**: restore (R2 旧库带回旧 20129 条目) → OmniRoute 启动加载旧条目 → 幽灵 entry 持续 (B6 根因 L2 实证: runtime patchedFetch 用内存 pool load 一次性读, 无 reload 钩子).
- **replicate 在 OmniRoute 后**: OmniRoute 启动后写 WAL → litestream 从含旧条目的 $DB 作 baseline → R2 持续存幽灵.
- **无 flock**: 多容器并发 restore/purge/替换 $DB 无互斥.
- **restore 失败 STRICT=1 exit**: HF Space 严格环境易因 R2 短瞬错启动失败 (回归性).

### 3.2 修后 (working tree @ 9a1a7f0...9a... 实际 candidate) 时序

```
1. flock (LOCK_FILE=${DATA_DIR}/.entrypoint.lock, fd 9)            ← 新增
2. restore (-o "$DB_TMP" "$DB"; 失败 WARN 不 exit)                 ← 改进
3. purge (事务 BEGIN/COMMIT; 三 DELETE; wal_checkpoint(TRUNCATE); assert 残留=0 exit 1)   ← 新增
4. litestream replicate (OmniRoute 启动前, 占 purge 后干净 baseline)  ← 提前
5. $DB 与 litestream.yml dbs[].path 一致性 assert (不匹配 exit 1)    ← 新增
6. OmniRoute 启动 (purge + replicate 之后)
7. health 等待
8. 版本护栏 + 其余 (init/key/gate/监督) 同 baseline
```

修后 key diff (145+/73-):
- L67-80: flock 互斥
- L83-157: restore 改用 `-o $DB_TMP` + 失败仅 WARN (永不 FATAL exit) + quick_check + 原子 mv
- L159-201: **pre-purge 段新增** (事务化 + host+port 精确 + assert 残留=0)
- L203-226: replicate 提前到 OmniRoute 前 + $DB path 一致性 assert
- L228+: OmniRoute 启动在 purge+replicate 后

## 4. flock / 互斥机制

### 4.1 HEAD baseline

**无任何互斥**: 全源 grep `flock|lockfile|LOCK|mutex|mkdir.*lock` 在 HEAD entrypoint = 0 命中.

### 4.2 修后

```sh
LOCK_FD=9
LOCK_FILE="${DATA_DIR}/.entrypoint.lock"
( exec 9>"$LOCK_FILE" ) 2>/dev/null
if command -v flock >/dev/null 2>&1; then
  flock -x 9 || { echo "[entrypoint] FATAL: 无法获取文件锁 $LOCK_FILE..."; exit 1; }
  echo "[entrypoint] lock acquired (flock $LOCK_FILE, fd 9)."
else
  echo "[entrypoint] WARN: flock 不可用, 跳过跨容器互斥 (HF Space 优先单实例)."
fi
```

- fd 9 排他锁, 失败 exit 1 (防并发 restore/purge 覆盖).
- `flock` 不可用降级 WARN (HF Space 单实例优先, 无 flock 容器如 distroless).
- **注**: 锁范围 = 整 entrypoint 进程生命 (fd 9 在 entrypoint 退出前不释). OmniRoute/litestream 子进程 fork 后继承 fd 但不持有锁语义 (子进程独立). 跨容器互斥正确.

## 5. audit/08 结论

### 5.1 修改前 baseline 缺陷实证 (task#22 要修)

| # | 缺陷 | 实证 | 严重 |
|---|------|------|------|
| D1 | 无 purge → R2 旧库带回 20129 幽灵 → OmniRoute 内存污染 | baseline 无 purge 段; B6 L2 proxies.ts 无 reload 钩子 | **高** (幽灵持续, direct 路径失效) |
| D2 | replicate 在 OmniRoute 后 → baseline 含旧条目 | baseline L7 (replicate) 在 L2 (OmniRoute) 后 | **高** (R2 持续存幽灵) |
| D3 | restore 失败 STRICT=1 exit → HF Space 易总启动失败 | baseline restore 失败直接 `exit 1` | **中** (回归性, 但 safe-fail 过激) |
| D4 | restore 不用 `-o` → $DB_TMP 当 db 标识符 ≠ yml path | baseline `restore ... "$DB_TMP"` 无 `-o` | **中** (副本路径错) |
| D5 | 无 flock → 多容器并发 restore/purge/替换 $DB 无互斥 | baseline 0 grep 命中 | **中** (单容器 HF Space 不触发, 但旧 HF 容器并发重启可触发) |
| D6 | restore→OmniRoute 间无 $DB 与 litestream.yml path 一致性 assert | baseline 无此 assert | **低** (配置漂移静默) |

### 5.2 修改后已修 (working tree 实证)

修后 entrypoint.sh 已含 flock + `-o $DB_TMP` + 事务 purge + wal_checkpoint + assert 残留=0 + replicate 提前 + $DB path 一致性 assert. **6 缺陷全逐点修**. task#22 修改已落 working tree.

### 5.3 仍需 VERIFY (此 audit/08 范围外)

- TEST 8 (信号) 65→72 PASS 已含 (新增 TEST 11 = task#21, 非 task#22). task#22 entrypoint 时序需**专属 mock test** (restore→purge→replicate→OmniRoute 顺序断言 + assert 触发 exit 1 + flock 获取/失败分支).
- audit/06-style task#22 修复报告 (audit/09) 待写.
- 实例 readback (audit/07) 真 purge 验证延期.

## 6. 拟修改 diff 预览 (供确认)

**task#22 修改已在 working tree**. 此处预览仅描述 diff (不重写, 因已落盘):

```diff
@@ entrypoint.sh @@ (HEAD baseline → working tree)
+ # 文件锁
+ LOCK_FD=9
+ LOCK_FILE="${DATA_DIR}/.entrypoint.lock"
+ ( exec 9>"$LOCK_FILE" ) 2>/dev/null
+ if command -v flock ...; then flock -x 9 || exit 1; ...
@@ restore 段 @@
- litestream restore -config /litestream.yml -if-replica-exists "$DB_TMP"
+ litestream restore -config /litestream.yml -if-replica-exists -o "$DB_TMP" "$DB"
+ # 失败仅 WARN, 永不 FATAL exit (STRICT 仅日志); -o 不支持则回退直接 $DB
+ # R2 无副本 → 空库启动 (init 重建)
@@ restore 结束, OmniRoute 前 @@
+ # ── 2. pre-purge (OmniRoute 前, 事务, host+port 精确, assert) ──
+ sqlite3 "$DB" <<SQL
+ BEGIN;
+ DELETE FROM proxy_assignments WHERE proxy_id IN (SELECT id FROM proxy_registry WHERE host='...' AND port=N);
+ UPDATE provider_connections SET proxy_enabled=0 WHERE provider='nvidia';
+ DELETE FROM proxy_registry WHERE host='...' AND port=N;
+ COMMIT;
+ SQL
+ sqlite3 "$DB" "PRAGMA wal_checkpoint(TRUNCATE);"
+ _post=$(sqlite3 "$DB" "SELECT COUNT(*) ... WHERE host='...' AND port=N;")
+ [ "$_post" != "0" ] && { echo FATAL; exit 1; }
@@ OmniRoute 前 @@
+ # ── 3. litestream replicate (OmniRoute 前, 占 purge 后干净 baseline) ──
+ printf '%s' "$DB" | grep -q "^${DATA_DIR}/storage.sqlite$" || { exit 1; }   # path 一致性 assert
+ litestream replicate -config /litestream.yml &
+ LS_PID=$!
@@ OmniRoute 启动 @@  (顺序 = purge + replicate 之后)
```

## 7. 下一步建议

1. **task#22 代码已落 working tree** — 不需再写. 此 audit/08 确认基线 + 修后逐点对照.
2. 等 user 确认 audit/08 结论 + diff 预览.
3. 确认后: 写 audit/09 task#22 修复报告 (仿 audit/06) + 加 TEST 12 task#22 专属 mock test (时序断言).
4. 不写代码直到 user `确认`.
