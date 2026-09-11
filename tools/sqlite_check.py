#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""omn storage.sqlite 健康巡检 (ops 层工具, 严格只读, 永不写库)

用途
    对 omn 网关的 storage.sqlite 做定期点检: 完整性 + 表/行/体积统计 + 异常告警,
    输出简洁中文报告。判据对齐 2026-09-07 事故档「字面量分界铁律」——
    只认 `ok` / `database disk image is malformed` 字面量, 不做语义推断。

只读保证 (硬约束)
    双保险: ① URI `file:<path>?mode=ro` (SQLite 层只读)
            ② `PRAGMA query_only=ON` (会话层禁写)
    全程只跑 PRAGMA 与 SELECT, 零 DDL/DML。
    实测: 巡检前后主库 sha256 + mtime + size 三项恒定。
    诚实说明: 若库处于 WAL 态, SQLite 以任意模式打开都会重写 `*.sqlite-shm`
    (派生共享内存索引, 与 WAL 内容无关) —— 这是 SQLite 固有行为, 非本工具写库。
    写库判据 = 主库与 `-wal` 字节不变; 二者实测恒不变。

路径解析优先级
    命令行位置参数 > $OMN_DB_PATH > $DB_PATH > 默认 (池内最新健康档)
    DATA_DIR 默认 /data.
    为何默认指向快照池: 活库 /data/storage.sqlite 在 HF Space ephemeral 盘,
    每 boot 重建, 点检它只反映「本 boot 瞬时态」; 持久真源在 Bucket 挂载
    $DATA_DIR/backups/ 下的快照池, 那才是跨 boot 的长期观察对象。
    传参可指向任意库 (含活库)。
    脚本会显式打印「实际检查的文件」, 不做静默回退。

路径与实态对齐 (2026-09-10 复核, 勿凭推断)
    · 快照池**扁平落点** = `$DATA_DIR/backups/db-snap.<epoch>.db` (滚动保最新
      SNAP_MAX=5 份) + 兼容召回档 `storage.last-good.sqlite`。
      非 `backups/db/` 子目录, 也非 `backups/db/db-snap.*.db`
      —— 出处: logic/entrypoint.sh `SNAP_DIR="$DATA_DIR/backups"` +
      `_snap_gen` 写 `$SNAP_DIR/db-snap.$_ts.db`。
    · 活库 = `$DATA_DIR/storage.sqlite` (entrypoint `DB_PATH="$DATA_DIR/storage.sqlite"`)。
    · 环境变量回退链 (`OMN_DB_PATH`/`DB_PATH`) 只是通用兼容开关, 现役拓扑
      **不设**这二者 (出处: space/start.sh 与 logic/entrypoint.sh 均未导出)。

默认对象 = 快照池 (跨 boot 有意义)
    默认取「池内最新一份健康档」: 优先 `db-snap.*.db` 按 mtime 新→旧择首份
    自校验通过者, 缺则退兼容档 `storage.last-good.sqlite`。
    池空/全坏 → 回退扫描活库 `$DATA_DIR/storage.sqlite`; 活库亦无 → 明确报
    「无目标库」(exit 2), 绝不静默返回「全绿」。

覆盖面 (报告里逐项出现, 缺项即告警)
    完整性 integrity_check / quick_check · 表数量 · 逐表行数 · 总行数 ·
    page_size/page_count/折算体积 · 主库+WAL+SHM 体积与 mtime ·
    核心表存在性与非空 · 单档超时看门狗 · 耗时。

退出码
    0 = 全绿 (无红旗无告警)
    1 = WARNING (异常: 核心表缺失 / 核心表 0 行 / 体积异常等, 非损坏)
    2 = 硬失败 (真损坏红旗 / 非 SQLite 文件 / 路径不存在 / 无法打开)

用法
    python3 tools/sqlite_check.py                          # 用默认/环境变量路径
    python3 tools/sqlite_check.py /data/storage.sqlite     # 指定活库
    python3 tools/sqlite_check.py --json                   # 机器可读 (巡检采集)

cron 示例 (每日 04:17, 失败邮件):
    17 4 * * * /usr/bin/python3 /app/tools/sqlite_check.py --json >/tmp/sqlite_check.json 2>&1 || \
        echo "sqlite_check exit=$?" | mail -s "omn sqlite 巡检告警" ops@example.com

环境变量
    OMN_DB_PATH / DB_PATH      目标库逃生口 (现役拓扑不设)
    DATA_DIR                   数据根 (默认 /data)
    SQLITE_CHECK_TIMEOUT       单档 PRAGMA 看门狗秒数 (默认 30; <=0 关闭)
"""

import argparse
import json
import os
import re
import shutil
import sqlite3
import subprocess
import sys
import time
from datetime import datetime, timezone

# ── 路径默认值 ────────────────────────────────────────────────────────
# 默认对象 = Bucket 挂载上的持久快照池 (跨 boot 长期观察面), 非 ephemeral 活库。
# 备注说明见模块 docstring「路径解析优先级」。
DEFAULT_DATA_DIR = "/data"
DEFAULT_REL = os.path.join("backups", "db", "storage.sqlite")

# ── 核心表 (omn 3.8.50 db/core.ts 实证) ───────────────────────────────
# 缺失 = WARNING。应非空的 (池/鉴权/配置落点) 0 行也告警; 其余空表仅观察。
CORE_TABLES_EXPECT_NONEMPTY = ("provider_connections", "api_keys", "key_value")
CORE_TABLES_OPTIONAL_EMPTY = ("provider_nodes", "combos", "db_meta")
CORE_TABLES = CORE_TABLES_EXPECT_NONEMPTY + CORE_TABLES_OPTIONAL_EMPTY

# 真损坏字面量红旗 (2026-09-07 事故档实态; 只认字面量, 不做语义推断)
#   ① "database disk image is malformed" = 事故档原文 (usage/callLogs 写路径)
#   ② "database corruption"             = SQLite 另一措辞 (整库级)
#   ③ "malformed database schema"       = schema 页损坏, 带独立后缀
#   ④ "malformed"                       = 兜底: 上述三者的**超集**包含匹配。
#      理由: ①②③ 都含 "malformed", 单靠 ④ 即可覆盖全族; 单列 ①②③ 仅作
#      可读性/追溯锚点 (对不上任一全串也仍被 ④ 拦), 防 "image is malformed"
#      之类错拼变体漏判成 other 而误判全绿。
#   判据顺序: corrupt 先于 notadb/benign, 因为损坏报告里也可能出现
#      "no such table" 字样 (损坏后才读不到表), 不能让它盖过真损坏。
CORRUPT_LITERALS = (
    "database disk image is malformed",
    "database corruption",
    "malformed database schema",
    "malformed",
)
# 非 SQLite / 加密库字面量: 同为硬失败, 但单独定性 (报「非 SQLite 文件」更贴切)
NOT_A_DB_LITERALS = (
    "file is not a database",
    "file is encrypted",
    "file is encrypted or is not a database",
)
# 良性字面量: 懒建表/幽灵表, 不算损坏 (「no such table」分界)
BENIGN_LITERALS = ("no such table", "no such column")

# ── 单档点检超时看门狗 (秒; 0/负数关) ────────────────────────────────
# 池内档如过 FUSE 撕裂, PRAGMA 可能极慢甚至卡死; 看门狗保证单档不拖死整次巡检。
# 缺 sqlite3 命令行时看门狗不可用 (退化为仅本进程内 sqlite3 调用), 报告会显式标注。
CHECK_TIMEOUT_S = float(os.environ.get("SQLITE_CHECK_TIMEOUT", "30") or 30)
PROBE_PY = os.path.abspath(__file__)   # 子进程用同一份逻辑, 判据不会漂移

EXIT_OK, EXIT_WARN, EXIT_FAIL = 0, 1, 2


def resolve_db_path(cli_path: str | None) -> tuple[str, str]:
    """按优先级解析目标库路径, 返回 (path, 来源说明)。"""
    if cli_path:
        return os.path.abspath(cli_path), "命令行参数"
    for env in ("OMN_DB_PATH", "DB_PATH"):
        if os.environ.get(env):
            return os.path.abspath(os.environ[env]), f"环境变量 ${env}"
    # 默认 = 池内最新健康档 (池空/全坏退活库; 全无 → 明确报无目标, 不静默全绿)
    path, source = resolve_default_target()
    if path is None:
        return os.path.abspath(
            os.path.join(os.environ.get("DATA_DIR", DEFAULT_DATA_DIR), DEFAULT_REL)
        ), source
    return path, source


def open_readonly(path: str) -> sqlite3.Connection:
    """只读打开: URI mode=ro + PRAGMA query_only=ON 双保险。"""
    uri = "file:" + path + "?mode=ro"
    conn = sqlite3.connect(uri, uri=True, timeout=10)
    conn.execute("PRAGMA query_only=ON")
    return conn


def parse_pragma_output(stdout: str, stderr: str, rc: int) -> dict:
    """把 PRAGMA 单档点检的输出映射成 {raw, verdict}; 大库多行结果不截断。"""
    text = (stdout or "").strip()
    err = (stderr or "").strip()
    if rc == 124:
        return {"raw": f"超时 (>{CHECK_TIMEOUT_S:.0f}s)", "verdict": "timeout"}
    if not text and err:
        # 进程非 0 且无 stdout: 多半是 SQLite 打库即报错 (损坏/非 SQLite)
        return {"raw": err, "verdict": classify_literal(err) or "other"}
    if not text:
        return {"raw": "", "verdict": "other"}
    first = text.splitlines()[0].strip()
    v = classify_literal(text)
    if v == "other":
        # 非单行 ok 即未过完整性检查: 逐行原样保留 (可能多行损坏报告)
        v = "ok" if (len(text.splitlines()) == 1 and first.lower() == "ok") else "other"
    return {"raw": text, "verdict": v}


def _run_pragma_child(path: str, kind: str) -> dict:
    """子进程单档点检 (看门狗). 缺 sqlite3 时返不可用标记。"""
    if CHECK_TIMEOUT_S <= 0 or not shutil.which("sqlite3"):
        return {"available": False}
    try:
        uri = "file:" + path + "?mode=ro"
        cp = subprocess.run(
            ["sqlite3", uri, f"PRAGMA {kind};"],
            capture_output=True, text=True,
            timeout=CHECK_TIMEOUT_S,
        )
    except subprocess.TimeoutExpired:
        return {"available": True, "raw": f"超时 (>{CHECK_TIMEOUT_S:.0f}s)", "verdict": "timeout"}
    except Exception as e:  # noqa: BLE001
        return {"available": True, "raw": str(e), "verdict": "other"}
    return dict(available=True, **parse_pragma_output(cp.stdout, cp.stderr, cp.returncode))


def pragma_check(path: str, kind: str) -> dict:
    """PRAGMA 点检单档: 有 sqlite3 走看门狗子进程, 否则本进程内只读连接。"""
    out = _run_pragma_child(path, kind)
    if out.get("available"):
        return out
    conn = open_readonly(path)
    try:
        rows = conn.execute(f"PRAGMA {kind};").fetchall()
        text = "\n".join(str(r[0]) for r in rows) if rows else ""
        return {"available": False, "raw": text, "verdict": classify_literal(text)}
    except sqlite3.DatabaseError as e:
        return {"available": False, "raw": str(e), "verdict": classify_literal(str(e)) or "corrupt"}
    finally:
        conn.close()


def snapshot_candidates(data_dir: str) -> list[tuple[str, str]]:
    """候选库清单 (扫描序 = 池内 mtime 新→旧, 再兼容档, 末位活库)。"""
    snap_dir = os.path.join(data_dir, "backups")
    out: list[tuple[str, str]] = []
    pool: list[str] = []
    try:
        for name in os.listdir(snap_dir):
            if name.startswith("db-snap.") and name.endswith(".db"):
                pool.append(os.path.join(snap_dir, name))
    except OSError:
        pool = []
    pool.sort(key=lambda p: (os.path.getmtime(p) if os.path.exists(p) else 0.0), reverse=True)
    for p in pool:
        out.append((p, "快照池 (最新健康档: 按 mtime 新→旧择首份 integrity_check 过者)"))
    legacy = os.path.join(snap_dir, "storage.last-good.sqlite")
    if os.path.isfile(legacy):
        out.append((legacy, "快照池兼容召回档 storage.last-good.sqlite"))
    live = os.path.join(data_dir, "storage.sqlite")
    if os.path.isfile(live):
        out.append((live, f"活库回退 $DATA_DIR/storage.sqlite (DATA_DIR={data_dir})"))
    return out


def resolve_default_target() -> tuple[str | None, str]:
    """默认目标解析: 池内最新健康档 > 兼容档 > 活库; 全无 → (None, 原因)。"""
    data_dir = os.environ.get("DATA_DIR", DEFAULT_DATA_DIR)
    cands = snapshot_candidates(data_dir)
    checked: list[str] = []
    for path, source in cands:
        checked.append(path)
        if pragma_check(path, "integrity_check").get("verdict") == "ok":
            return path, source
    if cands:
        return cands[0][0], (
            "无健康档: 已遍历 "
            + ", ".join(checked)
            + " (均未通过 integrity_check); 取最新一档照实报告"
        )
    return None, f"无目标库: {os.path.join(os.environ.get('DATA_DIR', DEFAULT_DATA_DIR), 'backups')} 池空, 且活库不存在"


def human(nbytes: int) -> str:
    units = ("B", "KB", "MB", "GB", "TB")
    val = float(nbytes)
    for u in units:
        if val < 1024 or u == units[-1]:
            return f"{val:.1f}{u}" if u != "B" else f"{int(val)}B"
        val /= 1024
    return f"{nbytes}B"


def classify_literal(text: str) -> str:
    """按字面量给 PRAGMA 结果定性: ok / corrupt / notadb / benign / other。

    判据顺序 (字面量铁律): 真损坏 > 非 SQLite > 良性 > 其他。
    `ok` 仅认**单行精确等于 ok** —— 多行输出 (逐页损坏报告) 一律不判 ok。
    """
    t = (text or "").strip().lower()
    if t == "ok":
        return "ok"
    for lit in CORRUPT_LITERALS:
        if lit in t:
            return "corrupt"
    for lit in NOT_A_DB_LITERALS:
        if lit in t:
            return "notadb"
    for lit in BENIGN_LITERALS:
        if lit in t:
            return "benign"
    return "other"


def run_checks(path: str) -> dict:
    """执行全部巡检, 返回结构化结果。"""
    _t0 = time.time()
    res: dict = {
        "path": path,
        "generated_at": datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M:%SZ"),
        "elapsed_s": None,
        "integrity_check": None,
        "quick_check": None,
        "verdict": "unknown",
        "warnings": [],
        "tables": [],
        "sizes": {},
        "error": None,
    }

    if not os.path.exists(path):
        res["verdict"] = "fail"
        res["error"] = f"路径不存在: {path}"
        return res
    if not os.path.isfile(path):
        res["verdict"] = "fail"
        res["error"] = f"不是普通文件: {path}"
        return res

    try:
        # 主库/WAL/SHM 体积 (os.stat, 不触库)
        for suffix, label in (("", "main"), ("-wal", "wal"), ("-shm", "shm")):
            p = path + suffix
            try:
                st = os.stat(p)
                res["sizes"][label] = {"bytes": st.st_size, "mtime": st.st_mtime}
            except OSError:
                res["sizes"][label] = None

        # 1) 完整性: 只认字面量; 走单档超时看门狗 (撕裂档不拖死整次巡检)
        for pragma, key in (("integrity_check", "integrity_check"),
                            ("quick_check", "quick_check")):
            res[key] = pragma_check(path, pragma)
        use_watchdog = bool(res["integrity_check"].get("available"))
        res["watchdog"] = {
            "enabled": CHECK_TIMEOUT_S > 0,
            "usable": use_watchdog,
            "timeout_s": CHECK_TIMEOUT_S,
        }

        conn = open_readonly(path)
        try:

            v_int = (res.get("integrity_check") or {}).get("verdict")
            v_qk = (res.get("quick_check") or {}).get("verdict")
            if "corrupt" in (v_int, v_qk):
                res["verdict"] = "fail"
                res["warnings"].append(
                    "真损坏红旗: PRAGMA 检出损坏字面量 "
                    "(database disk image is malformed / malformed database schema 等)"
                )
            elif "notadb" in (v_int, v_qk):
                res["verdict"] = "fail"
                res["error"] = "非 SQLite 文件 (或加密库): PRAGMA 报 file is not a database"
            elif "timeout" in (v_int, v_qk):
                # 看门狗兜住: 单档点检超时 = 未能证明健康 → 硬失败 (绝不判 ok)
                res["verdict"] = "fail"
                res["error"] = f"单档点检超时 (>{CHECK_TIMEOUT_S:.0f}s): 库可能卡死/极度撕裂, 未能证明健康"
                res["warnings"].append("真损坏嫌疑: PRAGMA 超时 (看门狗中止, 不判 ok)")
            elif "other" in (v_int, v_qk):
                # PRAGMA 返非 ok 多行 (如逐页损坏报告) = 完整性检查未过
                res["verdict"] = "fail"
                res["error"] = "PRAGMA 完整性检查未过 (非 ok 输出), 见 raw"
                res["warnings"].append("真损坏嫌疑: PRAGMA 输出非 ok")

            # 2) 表清单
            try:
                tables = [
                    r[0]
                    for r in conn.execute(
                        "SELECT name FROM sqlite_master WHERE type='table' "
                        "AND name NOT LIKE 'sqlite_%' ORDER BY name;"
                    ).fetchall()
                ]
            except sqlite3.DatabaseError as e:
                if classify_literal(str(e)) == "corrupt":
                    res["verdict"] = "fail"
                    res["error"] = f"读取表清单失败: {e}"
                    return res
                tables = []

            # 3) 逐表行数
            total_rows = 0
            for name in tables:
                try:
                    cnt = conn.execute(
                        f'SELECT COUNT(*) FROM "{name}";'
                    ).fetchone()[0]
                except sqlite3.DatabaseError as e:
                    kind = classify_literal(str(e))
                    entry = {"name": name, "rows": None, "note": str(e), "kind": kind}
                    res["tables"].append(entry)
                    if kind == "corrupt":
                        res["verdict"] = "fail"
                        res["warnings"].append(f"表 {name} 读取报损坏: {e}")
                    continue
                total_rows += cnt
                res["tables"].append({"name": name, "rows": cnt, "note": "", "kind": "ok"})

            res["table_count"] = len(tables)
            res["total_rows"] = total_rows

            # 4) 核心表校验
            existing = {t["name"]: t for t in res["tables"]}
            for core in CORE_TABLES_EXPECT_NONEMPTY:
                if core not in existing:
                    res["warnings"].append(f"核心表缺失: {core} (应存在且非空)")
                elif existing[core]["rows"] == 0:
                    res["warnings"].append(f"核心表 0 行: {core} (应非空)")
            for core in CORE_TABLES_OPTIONAL_EMPTY:
                if core not in existing:
                    res["warnings"].append(f"核心表缺失: {core}")

            # 5) 页大小 / 页数 (dbstat 不可用时退 page_count); 走同一看门狗, 撕裂档不卡
            pg = _run_pragma_child(path, "page_size") if use_watchdog else {"available": False}
            pc = _run_pragma_child(path, "page_count") if use_watchdog else {"available": False}
            try:
                if pg.get("available") and pg.get("verdict") != "timeout":
                    page_size = int(str(pg.get("raw", "")).strip().splitlines()[0])
                elif not use_watchdog:
                    page_size = conn.execute("PRAGMA page_size;").fetchone()[0]
                else:
                    page_size = None
                if pc.get("available") and pc.get("verdict") != "timeout":
                    page_count = int(str(pc.get("raw", "")).strip().splitlines()[0])
                elif not use_watchdog:
                    page_count = conn.execute("PRAGMA page_count;").fetchone()[0]
                else:
                    page_count = None
                if page_size is not None and page_count is not None:
                    res["page_size"] = page_size
                    res["page_count"] = page_count
                    res["page_bytes"] = page_size * page_count
            except (sqlite3.DatabaseError, ValueError, TypeError):
                pass

            # verdict 收敛
            if res["verdict"] != "fail":
                res["verdict"] = "warn" if res["warnings"] else "ok"

        finally:
            conn.close()

    except sqlite3.DatabaseError as e:
        kind = classify_literal(str(e))
        res["verdict"] = "fail"
        if kind == "corrupt":
            res["error"] = f"打库即报损坏: {e}"
            res["warnings"].append("真损坏红旗: 打开库即命中损坏字面量")
        elif kind == "notadb":
            res["error"] = f"非 SQLite 文件 (或加密库): {e}"
        elif kind == "benign":
            res["error"] = f"非 SQLite / 结构异常: {e}"
        else:
            res["error"] = f"SQLite 错误: {e}"
    except Exception as e:  # noqa: BLE001 - 兜底, 巡检不可因单点异常崩
        res["verdict"] = "fail"
        res["error"] = f"{type(e).__name__}: {e}"

    res["elapsed_s"] = round(time.time() - _t0, 3)
    return res


def render_text(res: dict, source: str) -> str:
    """渲染简洁中文报告。"""
    L = []
    L.append("═" * 56)
    L.append("omn storage.sqlite 健康巡检报告")
    L.append("═" * 56)
    L.append(f"检查文件: {res['path']}")
    L.append(f"路径来源: {source}")
    L.append(f"生成时间: {res['generated_at']}")
    L.append("")

    verdict_cn = {"ok": "✅ 全绿", "warn": "⚠️ 有告警", "fail": "❌ 硬失败/真损坏",
                  "unknown": "? 未知"}
    L.append(f"总判定: {verdict_cn.get(res['verdict'], res['verdict'])}")
    if res.get("error"):
        L.append(f"错误:   {res['error']}")
    L.append("")

    for label, key in (("完整性 integrity_check", "integrity_check"),
                       ("快速 quick_check", "quick_check")):
        block = res.get(key)
        if not block:
            L.append(f"[{label}] 未执行")
            continue
        v = block.get("verdict")
        # 多行输出只摘首行入报告头, 全量在 --json raw (大库逐页报告不糊屏)
        raw = (block.get("raw") or "").strip().splitlines()
        raw_brief = raw[0] if len(raw) == 1 else (f"{raw[0]} (+{len(raw) - 1} 行, 见 --json raw)" if raw else "")
        v_cn = {"ok": "ok ✅", "corrupt": "损坏字面量 ❌",
                "notadb": "非 SQLite 文件 ❌", "timeout": "超时 ❌ (未能证明健康)",
                "benign": f"良性 ({raw_brief})",
                "other": f"未过 (非 ok: {raw_brief})"}
        L.append(f"[{label}] {v_cn.get(v, v)}")
    wd = res.get("watchdog") or {}
    if wd:
        L.append(
            "[单档看门狗] "
            + (f"启用 {wd['timeout_s']:.0f}s" if wd.get("enabled") else "关闭 (SQLITE_CHECK_TIMEOUT<=0)")
            + (" · 可用 (sqlite3 CLI 在位)" if wd.get("usable") else " · 不可用 (缺 sqlite3 CLI, 退进程内调用)")
        )
    L.append("")

    if res.get("table_count") is not None:
        L.append(f"表数量: {res['table_count']}  总行数: {res.get('total_rows')}")
    if res.get("page_bytes") is not None:
        L.append(f"页大小: {res.get('page_size')}  页数: {res.get('page_count')}  "
                 f"折算体积: {human(res['page_bytes'])}")
    if res.get("elapsed_s") is not None:
        L.append(f"耗时: {res['elapsed_s']}s")
    sizes = res.get("sizes") or {}
    for label, cn in (("main", "主库"), ("wal", "WAL"), ("shm", "SHM")):
        s = sizes.get(label)
        L.append(f"  {cn}: {human(s['bytes']) if s else '—（无）'}")
    L.append("")

    tables = res.get("tables") or []
    if tables:
        L.append("─ 表清单 ─")
        for t in tables:
            rows = "?" if t["rows"] is None else t["rows"]
            mark = "  " if t.get("kind") == "ok" else "⚠ "
            note = f"  {t['note']}" if t.get("note") else ""
            L.append(f"{mark}{t['name']}: {rows} 行{note}")
        L.append("")

    warns = res.get("warnings") or []
    if warns:
        L.append("─ 告警 ─")
        for w in warns:
            L.append(f"⚠️ {w}")
    else:
        L.append("无告警。")
    L.append("═" * 56)
    return "\n".join(L)


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(
        description="omn storage.sqlite 健康巡检 (严格只读, 永不写库)"
    )
    ap.add_argument("db_path", nargs="?", default=None,
                    help="目标库路径; 缺省走 OMN_DB_PATH/DB_PATH/默认 Bucket 快照池落点")
    ap.add_argument("--json", action="store_true", help="输出 JSON (机器可读)")
    args = ap.parse_args(argv)

    path, source = resolve_db_path(args.db_path)
    res = run_checks(path)

    if args.json:
        out = dict(res)
        out["path_source"] = source
        out["exit_code"] = {"ok": EXIT_OK, "warn": EXIT_WARN}.get(res["verdict"], EXIT_FAIL)
        print(json.dumps(out, ensure_ascii=False, indent=2))
    else:
        print(render_text(res, source))

    return {"ok": EXIT_OK, "warn": EXIT_WARN}.get(res["verdict"], EXIT_FAIL)


if __name__ == "__main__":
    sys.exit(main())
