#!/usr/bin/env python3
"""verify_events.py — P0 events-table 本地 mock 验证.
本机无 sqlite3 CLI, 用 python3 sqlite3 模块验 schema + 写入语义
(模块底层即同一 SQLite 引擎, 验 schema/列/约束有效; 现役上环境用 CLI,
 events_write.sh 设计为 CLI, 本验证只验 schema 与写入结果合法性).

纪律: 禁真实端点. 临时库 mktemp, 测完删, 不碰现役 $DB_PATH.
"""
import os, sqlite3, sys, tempfile, json

HERE = os.path.dirname(os.path.abspath(__file__))
SCHEMA = os.path.join(HERE, "events_schema.sql")

VALID_TYPES = ["boot_banner", "upsert_result", "cb_trip",
               "fallback_enter", "fallback_exit", "queue_drop"]
KEEP3 = ["cb_trip", "fallback_enter", "queue_drop"]  # v2 §6 三类必具

fails = 0
def ok(msg): print(f"✅  {msg}")
def bad(msg):
    global fails
    fails += 1
    print(f"❌  {msg}")

# 临时库
fd, tmpdb = tempfile.mkstemp(suffix=".db", prefix="p0ev_")
os.close(fd)
try:
    con = sqlite3.connect(tmpdb)
    cur = con.cursor()

    # 1. schema 建表(完整读 events_schema.sql 执行)
    with open(SCHEMA, encoding="utf-8") as f:
        cur.executescript(f.read())
    con.commit()
    cols = [r[1] for r in cur.execute("PRAGMA table_info(events)").fetchall()]
    if cols == ["id", "ts", "event_type", "payload"]:
        ok(f"events 列序正确 {cols}")
    else:
        bad(f"events 列序错: {cols}")

    # 2. schema 两个索引在
    idx_rows = cur.execute(
        "SELECT name FROM sqlite_master WHERE type='index' AND tbl_name='events' AND name NOT LIKE 'sqlite_%'"
    ).fetchall()
    idx = sorted(r[0] for r in idx_rows)
    ok(f"索引: {idx}") if "idx_events_ts" in idx and "idx_events_event_type" in idx else\
        bad(f"索引缺失: {idx}")

    # 3. ts NOT NULL / event_type NOT NULL / payload NOT NULL DEFAULT '{}'
    nulls = {r[1]: r[3] for r in cur.execute("PRAGMA table_info(events)").fetchall()}
    if nulls.get("ts") == 1 and nulls.get("event_type") == 1:
        ok("ts/event_type NOT NULL")
    else:
        bad(f"NOT NULL 漏: {nulls}")
    dflt = {r[1]: r[4] for r in cur.execute("PRAGMA table_info(events)").fetchall()}
    if dflt.get("payload") == "'{}'":
        ok("payload DEFAULT '{}'")
    else:
        bad(f"payload DEFAULT 漏: {dflt}")

    # 4. 六类枚举各写一条 (合法 JSON payload)
    for t in VALID_TYPES:
        cur.execute("INSERT INTO events (ts, event_type, payload) VALUES (?,?,?)",
                    ("2026-07-22T03:16:00Z", t, json.dumps({"k": t})))
    con.commit()
    cnt = cur.execute("SELECT COUNT(DISTINCT event_type) FROM events").fetchone()[0]
    ok(f"六类枚举全写入 ({cnt}/6)") if cnt == 6 else bad(f"六类缺 {cnt}/6")

    # 5. v2 §6 三类金丝雀事件齐 + fallback_exit 对偶
    for need in KEEP3 + ["fallback_exit"]:
        c = cur.execute("SELECT COUNT(*) FROM events WHERE event_type=?", (need,)).fetchone()[0]
        (ok if c >= 1 else bad)(f"金丝雀事件 {need} {'存在' if c else '缺失'} ({c})")

    # 6. payload 含特殊字符 (双引号/反斜杠/单引号经 python 参数化原样入库 — 等价验 CLI 转义目标)
    nasty = json.dumps({"port": 20128, "note": "it's a \"test\" \\path"})
    cur.execute("INSERT INTO events (ts, event_type, payload) VALUES (?,?,?)",
                ("2026-07-22T03:17:00Z", "boot_banner", nasty))
    got = cur.execute(
        "SELECT payload FROM events WHERE event_type='boot_banner' ORDER BY id DESC LIMIT 1"
    ).fetchone()[0]
    parsed = json.loads(got)
    if parsed.get("port") == 20128 and "test" in parsed.get("note", ""):
        ok("含特殊字符 payload 正确入库+还原")
    else:
        bad(f"payload 损坏: {got!r}")

    # 7. ts ISO8601 格式校
    ts = cur.execute("SELECT ts FROM events LIMIT 1").fetchone()[0]
    import re
    if re.match(r"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$", ts):
        ok(f"ts ISO8601 合法 ({ts})")
    else:
        bad(f"ts 非法: {ts!r}")

    # 8. id 自增序与时序一致
    n, maxid = cur.execute("SELECT COUNT(*), MAX(id) FROM events").fetchone()
    ok(f"总行数/MAX(id): {n}/{maxid}") if n == maxid else bad(f"id 序乱 {n}/{maxid}")

    # 9. event_type 枚举在 SQL 层无 CHECK 约束(应用层events_write.sh守门) — 验证设计意图
    #    (故"非法 type 拒写"由 sh 函数守门, 不在 SQL 层; 这里只确认 schema 故意无 CHECK)
    create_sql = cur.execute("SELECT sql FROM sqlite_master WHERE name='events'").fetchone()[0]
    if "CHECK" in create_sql.upper():
        bad(f"schema 含 CHECK, 与'应用层枚举守门'设计冲突: {create_sql}")
    else:
        ok("schema 无 CHECK (枚举由应用层 events_write.sh 守门, 设计一致)")

    con.close()
    print()
    if fails == 0:
        print("✅  events-table 本地 mock 验证全过")
    else:
        print(f"❌  {fails} 项失败")
    sys.exit(1 if fails else 0)
finally:
    try: os.unlink(tmpdb)
    except OSError: pass
    for ext in ("-wal", "-shm"):
        try: os.unlink(tmpdb + ext)
        except OSError: pass
