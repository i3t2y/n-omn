#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""omn 日志只读健康报告 (tools/ 层, 零仓内写入, 零 eval 栈耦合)

用法:
  python3 tools/omn_health_report.py                      # 自动探测日志目录
  python3 tools/omn_health_report.py --log-dir /path/to   # 指定 save/ 目录
  python3 tools/omn_health_report.py --model kimi-k3      # 只聚焦某模型面板
  python3 tools/omn_health_report.py --json               # 附机器可读摘要
  python3 tools/omn_health_report.py --selftest           # 用内置样本自证

日志来源 (自动按序探测, 写死只读):
  1. --log-dir 参数
  2. 环境变量 $OMN_LOG_DIR
  3. /data/backups/logs/save   (生产 Bucket 挂载终态)
  4. /data/logs/save
  5. <cwd>/logs/save
  期望结构: save/<gate|app|ft|init>/<北京时间>_<epoch>.log
  兼容早期平铺三段件 gate.log / app.log。

设计口径 (与 docs/ops/k3-故障诊断-2026-09-10.md 一致):
  - gate 行不带模型名, 模型名只在 app 源 → 归属走 app 路由行 + 时间窗 (±1.5min) 关联最近 gate 行,
    并做二级兜底 (窗口内唯一模型)。归属率与 approx 行数如实打在报告里, 不藏。
  - 假 200 = 语义缓存命中, 上游要求**显式 temperature=0** 才可命中/写入。
    判据只认确证: 行内确有 temperature 字段且 =0 且 200 且极短耗时 → 判假 200。
    **无 temperature 字段 → 判「无法判定」, 绝不按耗时猜** —— 真实 gate 日志 schema
    (ts/level/component/stage/requestId/method/path/upstream*/elapsedMs/httpStatus/msg)
    本就不含该字段, 按耗时近似会把**全部正常快 200** 误报成缓存假成功。
    确证的这批 200 不构成可用性证据。

只依赖 python3 stdlib。不写任何仓内文件, 不发任何网络请求。
找不到日志目录时给中文指引并 exit 2, 不抛 traceback。
"""
import argparse
import collections
import datetime
import glob
import json
import os
import re
import sys

# ── 时间/口径常量 ─────────────────────────────────────────────
BJ = datetime.timezone(datetime.timedelta(hours=8))
ATTRIB_WINDOW_MS = 90_000      # app 路由行 → gate 行 时间窗 ±1.5min
FALSE200_STRICT_MS = 1000      # 严格判据下的"极短耗时"上界 (temperature=0 且 200)
K3_DEFAULT = "kimi-k3"
CURVE_HOURS = 24               # k3 错误率曲线回看窗
CANDIDATE_DIRS = [
    "/data/backups/logs/save",
    "/data/logs/save",
    "logs/save",
]

# 网关判定为"超时类"的状态码 (与 upstream CONNECTION_LEVEL_ERROR_STATUSES 的口径对齐)
TIMEOUT_CODES = {408, 504, 524}
SERVER_ERR_CODES = {500, 502, 503, 504}
INFERENCE_HINTS = ("/v1/chat/completions", "/chat/completions", "/v1/messages", "/v1/responses")


# ══════════════════════════════════════════════════════════════════════
# 目录探测 & 读取 (纯只读)
# ══════════════════════════════════════════════════════════════════════
def resolve_log_dir(cli_dir):
    """按序探测日志目录, 返回 (path, source_desc) 或 (None, 指引文本)。"""
    tried = []
    cands = []
    if cli_dir:
        cands.append((cli_dir, "--log-dir 参数"))
    env = os.environ.get("OMN_LOG_DIR")
    if env:
        cands.append((env, "$OMN_LOG_DIR"))
    for d in CANDIDATE_DIRS:
        cands.append((d, "默认候选"))
    for path, src in cands:
        tried.append(f"  - {path}  ({src})")
        if os.path.isdir(path):
            return path, src
    guide = (
        "未找到 omn 日志目录。已尝试:\n" + "\n".join(tried) + "\n\n"
        "请确认:\n"
        "  1) 生产环境日志挂在 /data/backups/logs/save (Bucket 直写终态);\n"
        "  2) 或显式指定: --log-dir /实际/save 目录, 或导出 OMN_LOG_DIR=...;\n"
        "  3) 目录内应有子目录 gate/ app/ ft/ init/, 形如 <北京时戳>_<epoch>.log。"
    )
    return None, guide


def load_rows(log_dir):
    """读取 gate/ 与 app/ 子目录日志, 返回 (gate_rows, app_rows, files_info)。

    新格式: save/<sub>/<时戳>_<epoch>.log (JSONL)
    兼容旧平铺: 目录内直接 *.log
    """
    gate_rows, app_rows = [], []
    files_info = {"gate": 0, "app": 0}
    bad_lines = 0

    def _scan(sub, sink, kind):
        nonlocal bad_lines
        paths = []
        subdir = os.path.join(log_dir, sub)
        if os.path.isdir(subdir):
            paths = sorted(glob.glob(os.path.join(subdir, "*.log")))
        # 兼容根目录平铺
        paths += sorted(glob.glob(os.path.join(log_dir, f"{sub}*.log")))
        for p in paths:
            files_info[kind] += 1
            try:
                with open(p, "r", errors="replace") as f:
                    for ln in f:
                        ln = ln.strip()
                        if not ln:
                            continue
                        try:
                            sink.append(json.loads(ln))
                        except Exception:
                            bad_lines += 1
            except Exception:
                continue

    _scan("gate", gate_rows, "gate")
    _scan("app", app_rows, "app")
    files_info["bad_lines"] = bad_lines
    return gate_rows, app_rows, files_info


# ══════════════════════════════════════════════════════════════════════
# 行解析小工具
# ══════════════════════════════════════════════════════════════════════
def row_ts_ms(row):
    """行时间戳统一成 epoch ms: gate 行 ts=int, app 行 time/timestamp=ISO 字符串。"""
    ts = row.get("ts")
    if isinstance(ts, (int, float)):
        # gate ts 可能是秒或毫秒
        v = float(ts)
        return int(v * 1000) if v < 1e12 else int(v)
    for k in ("time", "timestamp", "ts_iso"):
        t = row.get(k)
        if isinstance(t, str) and t:
            try:
                return int(datetime.datetime.fromisoformat(
                    t.replace("Z", "+00:00")).timestamp() * 1000)
            except Exception:
                continue
    return None


def row_status(row):
    for k in ("httpStatus", "status", "statusCode"):
        v = row.get(k)
        if isinstance(v, int):
            return v
    return None


def row_elapsed(row):
    for k in ("elapsedMs", "elapsed_ms", "durationMs", "duration_ms", "latencyMs"):
        v = row.get(k)
        if isinstance(v, (int, float)):
            return float(v)
    return None


def row_model(row):
    """从 app 行抽取模型名 (字段名多形态)。"""
    for k in ("model", "modelName", "model_name", "requestedModel"):
        v = row.get(k)
        if isinstance(v, str) and v:
            return v
    for k in ("body", "request", "meta"):
        sub = row.get(k)
        if isinstance(sub, dict) and isinstance(sub.get("model"), str):
            return sub["model"]
    return None


def row_temperature(row):
    """抽 temperature (严格遵守: 没有就是 None, 不臆造)。"""
    v = row.get("temperature")
    if isinstance(v, (int, float)):
        return float(v)
    for k in ("body", "request", "meta", "params"):
        sub = row.get(k)
        if isinstance(sub, dict) and isinstance(sub.get("temperature"), (int, float)):
            return float(sub["temperature"])
    return None


def is_inference(row):
    blob = json.dumps(row, ensure_ascii=False).lower()
    return any(h in blob for h in INFERENCE_HINTS) or "/v1/" in blob


def is_false_200(row, strict_only=False):
    """判假 200 (语义缓存命中)。返回 (tri_state, exact)。

    tri_state 取值:
      True  = 判定为假 200 (语义缓存命中);
      False = 明确不是;
      None  = **无法判定** (证据不足), 与 False 严格区分, 不可计入分子或分母。

    exact 取值:
      True  = 有 `temperature` 字段, 判据严格 (可确证);
      False = 无 `temperature` 字段, 本行不具备判据。

    判据 (与 docs/ops/k3-故障诊断-2026-09-10.md L3 一致):
      上游 semanticCache.ts 要求**显式 `temperature: 0`** 才可命中/写入缓存,
      故假 200 的必要条件 = 行内确有 `temperature` 字段且值为 0。
      **缺失 `temperature` 字段 = 该请求未过缓存路径 = 明确不是假 200**,
      而不是"用耗时近似猜一个"。

    为什么不能按耗时近似判 (2026-09-10 修正):
      真实 gate 日志行 schema (docs/audit/2026-08-01-save-log-full-analysis.md L34)
      为 `ts/level/component/stage/requestId/method/path/upstream_path/
      upstream_target/elapsedMs/httpStatus/msg` —— **根本没有 `temperature` 字段**。
      原实现"无字段则按 `200 且 elapsedMs<=50ms 且推理端点` 近似判"会把这个
      对**全部**真实行成立的组合判成假 200: 实测同一批样本里 12ms / 45ms 的
      正常快 200 全被误判, 5/5 = "100% 假 200" 的假红旗。
      即"正常快回答"被系统性地污染成"缓存假成功", 与工具自身的立意
      (防被 1-5ms 的 200 糊住) 恰好相反 —— 它会**制造**该错觉。

    因此本函数不再产出耗时近似判; 无判据一律返回 `(None, False)`。
    `strict_only` 保留仅为向后兼容签名, 行为已统一。
    """
    if row_status(row) != 200:
        return False, False
    temp = row_temperature(row)
    if temp is None:
        # 无 temperature 字段 = 该行不具备假 200 判据 (真实 gate schema 即如此)。
        # 返回 None (无法判定), 既不冒认也不否认。
        return None, False
    el = row_elapsed(row)
    if temp == 0.0 and el is not None and el <= FALSE200_STRICT_MS:
        return True, True
    return False, True


# ══════════════════════════════════════════════════════════════════════
# 归属: app 路由行 → gate 行 (时间窗 ±1.5min)
# ══════════════════════════════════════════════════════════════════════
def attribute_models(app_rows, gate_rows):
    """返回 (per_model_gate, attribution_stats)。
    per_model_gate: {model: [gate_row,...]}
    归属策略:
      一级: app 行有 model + 时间戳 → 找窗口内最近 gate 行;
      二级兜底: 若窗口内 gate 行只有同一模型 (由其他 app 行确定) → 归该模型 (标 approx)。
    """
    gate_ts = []
    for g in gate_rows:
        t = row_ts_ms(g)
        gate_ts.append((t, g))
    gate_ts.sort(key=lambda x: (x[0] is None, x[0] or 0))

    # app 侧: 每个明确 model 行映射到最近 gate
    model_of_gate = {}          # id(gate_row) -> model (一级确定)
    app_with_model = []
    for a in app_rows:
        m = row_model(a)
        if not m:
            continue
        t = row_ts_ms(a)
        if t is None:
            continue
        app_with_model.append((t, m))

    attributed = 0
    approx = 0
    unattr = 0
    per_model = collections.defaultdict(list)

    # 用二分找窗口内最近 gate
    g_ts_only = [t for t, _ in gate_ts if t is not None]

    def nearest_gate(t, win):
        if not g_ts_only:
            return None
        import bisect
        i = bisect.bisect_left(g_ts_only, t)
        best = None
        for cand in (i, i - 1):
            if 0 <= cand < len(gate_ts):
                gt, grow = gate_ts[cand]
                if gt is None:
                    continue
                d = abs(gt - t)
                if d <= win and (best is None or d < best[0]):
                    best = (d, gt, grow)
        return best

    for t, m in app_with_model:
        hit = nearest_gate(t, ATTRIB_WINDOW_MS)
        if hit is None:
            unattr += 1
            continue
        _, gt, grow = hit
        if id(grow) in model_of_gate:
            # 已有归属, 冲突则取先到 (确定性)
            pass
        else:
            model_of_gate[id(grow)] = m
        if m in per_model or True:
            per_model[m].append(grow)
        attributed += 1

    # 二级兜底: 窗口内只对应单一模型的 gate 行, 归给该模型
    for grow in gate_rows:
        if id(grow) in model_of_gate:
            continue
        gt = row_ts_ms(grow)
        if gt is None:
            continue
        # 找距离最近的已归属 gate 的模型, 若在窗口内唯一则继承
        near_models = set()
        for t, m in app_with_model:
            if abs(t - gt) <= ATTRIB_WINDOW_MS:
                near_models.add(m)
        if len(near_models) == 1:
            m = next(iter(near_models))
            model_of_gate[id(grow)] = m
            per_model[m].append(grow)
            approx += 1

    stats = {
        "app_rows_with_model": len(app_with_model),
        "attributed_primary": attributed,
        "attributed_approx": approx,
        "unattributed_app_rows": unattr,
        "gate_rows_total": len(gate_rows),
        "gate_rows_attributed": len(model_of_gate),
    }
    return dict(per_model), stats


# ══════════════════════════════════════════════════════════════════════
# 统计
# ══════════════════════════════════════════════════════════════════════
def model_stats(rows):
    st = collections.defaultdict(int)
    total = 0
    for r in rows:
        code = row_status(r)
        el = row_elapsed(r)
        total += 1
        st["total"] += 1
        if code is None:
            st["unknown_status"] += 1
            continue
        if 200 <= code < 300:
            st["ok"] += 1
            fake, exact = is_false_200(r)
            if fake is True:
                st["false200"] += 1
            elif fake is None:
                # 无 temperature 字段 = 无法判定 (真实 gate schema 即如此)。
                # 单列计数, 不计入假 200 分子, 报告里如实说明。
                st["false200_undecidable"] += 1
            if el is not None:
                st["el_sum"] += el
                st["el_cnt"] += 1
        elif code == 502:
            st["e502"] += 1
        elif code == 503:
            st["e503"] += 1
        elif code == 504:
            st["e504"] += 1
        elif code in (408, 524):
            st["timeout"] += 1
        elif code == 400:
            st["e400"] += 1
        elif 400 <= code < 500:
            st["e4xx_other"] += 1
        elif code >= 500:
            st["e5xx_other"] += 1
        # 超时: 状态码超时类 或 耗时超 180s 视作等满窗
        if code in TIMEOUT_CODES or (el is not None and el >= 180_000):
            st["equiv_timeout"] += 1
    st["err"] = st["total"] - st["ok"] - st["unknown_status"]
    st["avg_el"] = (st["el_sum"] / st["el_cnt"]) if st["el_cnt"] else None
    st["succ_rate"] = (st["ok"] / (st["total"] - st["unknown_status"])
                       if (st["total"] - st["unknown_status"]) else None)
    return st


def is_combo_pool(name):
    return bool(re.search(r"(pool|combo|-pool$)", name or "", re.I))


def ascii_curve(points, width=48, height=8, label="错误率%"):
    """纯文本 ASCII 折线图。points: [(label, ratio)] ratio 0..1"""
    if not points:
        return ["(无样本)"]
    ratios = [r for _, r in points]
    mx = max(ratios) or 0.0
    mx = max(mx, 0.01)
    # 采样到 width 列
    if len(points) > width:
        step = len(points) / width
        sampled = []
        for i in range(width):
            a = int(i * step)
            b = max(a + 1, int((i + 1) * step))
            seg = ratios[a:b]
            sampled.append(sum(seg) / len(seg) if seg else 0.0)
        labels = [points[int(i * step)][0] for i in range(width)]
    else:
        sampled = ratios
        labels = [p[0] for p in points]
        width = len(sampled)
    rows = []
    for level in range(height, 0, -1):
        thr = mx * level / height
        line = "".join("█" if v >= thr - 1e-9 else " " for v in sampled)
        rows.append(f"{thr:5.1f}|{line}")
    rows.append("     +" + "-" * width)
    return rows


def k3_panel(per_model, focus):
    """k3 面板: 近 24h 错误率曲线 + 连续失败段 + 假 200 占比。"""
    out = []
    rows = per_model.get(focus, [])
    if not rows:
        out.append(f"**{focus}**: 窗口内无样本。")
        out.append("")
        out.append(f"> 若真实流量走 combo 池 (客户端不带模型名), 请改用 `--model {focus}-pool` "
                   f"或 `--model nim-pool` 观察池级行。此非 bug, 是日志归属口径所致。")
        return out

    now = datetime.datetime.now(datetime.timezone.utc)
    cutoff = now - datetime.timedelta(hours=CURVE_HOURS)
    recent = []
    for r in rows:
        t = row_ts_ms(r)
        if t is not None and datetime.datetime.fromtimestamp(t / 1000, datetime.timezone.utc) >= cutoff:
            recent.append((t, r))
    if not recent:
        out.append(f"**{focus}**: 近 {CURVE_HOURS}h 无样本 (历史样本 {len(rows)} 条)。")
        return out

    # 按小时分桶错误率
    buckets = collections.defaultdict(lambda: {"n": 0, "err": 0})
    for t, r in recent:
        dt = datetime.datetime.fromtimestamp(t / 1000, BJ)
        key = dt.strftime("%m-%d %H")
        buckets[key]["n"] += 1
        code = row_status(r)
        if code is not None and code >= 400:
            buckets[key]["err"] += 1
    keys = sorted(buckets.keys())
    points = [(k[-2:], (buckets[k]["err"] / buckets[k]["n"] if buckets[k]["n"] else 0))
              for k in keys]

    out.append(f"**{focus}** 近 {CURVE_HOURS}h 错误率曲线 (按小时, 北京时间):")
    out.append("```")
    out.append(f"错误率 (峰值 {max(r for _, r in points)*100:.0f}%), 横轴=时")
    out.extend(ascii_curve(points))
    out.append("时  " + " ".join(p[0] for p in points))
    out.append("```")

    # 连续失败段 (相邻失败请求按时间排序, 间隔 <= 5min 视作连续)
    fails = sorted([(t, r) for t, r in recent
                    if (row_status(r) or 0) >= 400], key=lambda x: x[0])
    segs = []
    cur = []
    for t, r in fails:
        if cur and t - cur[-1][0] > 300_000:
            segs.append(cur)
            cur = []
        cur.append((t, r))
    if cur:
        segs.append(cur)
    out.append("")
    out.append("连续失败段 (相邻 <=5min 归一段):")
    if not segs:
        out.append("- 无。")
    else:
        for seg in segs:
            span = (seg[-1][0] - seg[0][0]) / 1000.0
            codes = collections.Counter(row_status(r) for _, r in seg)
            els = [row_elapsed(r) for _, r in seg if row_elapsed(r) is not None]
            avg_el = sum(els) / len(els) if els else None
            verdict = ""
            if avg_el is not None and avg_el >= 180_000:
                verdict = "本侧等满窗 (上游沉默, fallback 逐 key 重放)"
            elif avg_el is not None and avg_el <= 1000:
                verdict = "上游快速拒 (非超时)"
            ts_start = datetime.datetime.fromtimestamp(seg[0][0] / 1000, BJ).strftime("%m-%d %H:%M:%S")
            out.append(f"- `{ts_start}` 起 {len(seg)} 次, 跨度 {span:.0f}s, "
                       f"码={dict(codes)}, avg={avg_el and f'{avg_el:.0f}ms'}"
                       + (f" → {verdict}" if verdict else ""))

    # 假 200 占比 (可确证口径)
    st = model_stats(rows)
    ok = st["ok"]
    fake = st["false200"]
    undec = st["false200_undecidable"]
    ratio = (fake / ok) if ok else 0.0
    out.append("")
    out.append(f"假 200 (语义缓存命中) 占成功比: {fake}/{ok} = {ratio*100:.1f}%")
    out.append(f"其中 {undec} 条成功响应**无 `temperature` 字段 = 无法判定**, "
               f"未计入分子 (真实 gate 日志 schema 本就不带该字段)。")
    out.append("")
    out.append("> **判定口径**: 上游 `semanticCache.ts` 要求显式 `temperature: 0` 才可命中/写入缓存, "
               "故「假 200」必须**行内确有 `temperature=0`** 才可确证。"
               "缺字段的行一律标「无法判定」, **不用耗时猜** —— 否则正常快回答会被误报成缓存假成功。")
    out.append("> 可确证的这批 200 由语义缓存直回, **不构成可用性证据**。")
    return out


# ══════════════════════════════════════════════════════════════════════
# 报告渲染
# ══════════════════════════════════════════════════════════════════════
def render_markdown(log_dir, src, per_model, attr_stats, all_gate, focus):
    L = []
    now = datetime.datetime.now(BJ).strftime("%Y-%m-%d %H:%M:%S")
    L.append("# omn 日志健康报告")
    L.append("")
    L.append(f"- 生成时间: {now} (北京时间)")
    L.append(f"- 日志目录: `{log_dir}` (来源: {src})")
    L.append(f"- gate 行总数: {attr_stats['gate_rows_total']}, 已归属: {attr_stats['gate_rows_attributed']}")
    L.append(f"- 归属: 一级(时间窗±1.5min) {attr_stats['attributed_primary']} 条, "
             f"二级兜底(窗口唯一模型) {attr_stats['attributed_approx']} 条, "
             f"未归属 app 行 {attr_stats['unattributed_app_rows']} 条")
    L.append("")
    L.append("> 口径: gate 行不带模型名, 模型名只在 app 源, 归属存在不确定性; "
             "上式如实给出归属率与 approx 行数, 不做隐藏。")
    L.append("")

    L.append("## 一、按模型分组统计")
    L.append("")
    if not per_model:
        L.append("(无可归属模型样本)")
    else:
        L.append("| 模型 | 请求 | 成功 | 成功率 | 平均时长 | 502 | 503 | 504 | 408/524 | 400 | 超时等效 | 假200 |")
        L.append("|---|---|---|---|---|---|---|---|---|---|---|---|")
        for m in sorted(per_model, key=lambda x: -model_stats(per_model[x])["total"]):
            st = model_stats(per_model[m])
            tag = " *(combo 池)*" if is_combo_pool(m) else ""
            avg = f"{st['avg_el']:.0f}ms" if st["avg_el"] is not None else "-"
            sr = f"{st['succ_rate']*100:.1f}%" if st["succ_rate"] is not None else "-"
            L.append(f"| {m}{tag} | {st['total']} | {st['ok']} | {sr} | {avg} | "
                     f"{st['e502']} | {st['e503']} | {st['e504']} | {st['timeout']} | "
                     f"{st['e400']} | {st['equiv_timeout']} | {st['false200']} |")
    L.append("")
    L.append("> 超时等效 = 408/504/524 状态码 或 单请求耗时 >=180s (fallback 等满窗特征)。")
    L.append("> 假 200 列即语义缓存命中数, 不计入可用性。")
    L.append("")

    L.append(f"## 二、{focus} 面板")
    L.append("")
    L.extend(k3_panel(per_model, focus))
    L.append("")

    # 全局一览 (含未归属)
    L.append("## 三、全局状态分布 (含无法归属模型的行)")
    L.append("")
    gst = collections.Counter(row_status(r) for r in all_gate)
    for code, c in gst.most_common():
        L.append(f"- HTTP {code}: {c}")
    L.append("")
    L.append(f"总请求 {len(all_gate)}, 4xx/5xx {sum(1 for r in all_gate if (row_status(r) or 0) >= 400)}。")
    L.append("")
    L.append("---")
    L.append("*本报告只读生成, 未写入任何文件, 未发起网络请求。*")
    return "\n".join(L)


def build_json_summary(log_dir, per_model, attr_stats, all_gate, focus):
    summary = {
        "log_dir": log_dir,
        "generated_at": datetime.datetime.now(BJ).isoformat(),
        "attribution": attr_stats,
        "models": {},
        "global": {},
        "focus": focus,
    }
    for m, rows in per_model.items():
        st = model_stats(rows)
        summary["models"][m] = {
            "requests": st["total"],
            "ok": st["ok"],
            "err": st["err"],
            "succ_rate": round(st["succ_rate"], 4) if st["succ_rate"] is not None else None,
            "avg_elapsed_ms": round(st["avg_el"], 1) if st["avg_el"] is not None else None,
            "e502": st["e502"], "e503": st["e503"], "e504": st["e504"],
            "e400": st["e400"], "timeout": st["timeout"],
            "false200": st["false200"],
            "false200_undecidable": st["false200_undecidable"],
            "is_combo_pool": is_combo_pool(m),
        }
    gst = collections.Counter(row_status(r) for r in all_gate)
    summary["global"] = {"total": len(all_gate),
                         "by_status": {str(k): v for k, v in sorted(gst.items(),
                                                                   key=lambda x: (x[0] is None, x[0]))}}
    return summary


# ══════════════════════════════════════════════════════════════════════
# 自测
# ══════════════════════════════════════════════════════════════════════
def selftest():
    """用内置样本自证核心口径。"""
    ok = True
    base = int(datetime.datetime(2026, 9, 9, 1, 0, 0, tzinfo=datetime.timezone.utc).timestamp() * 1000)
    gate, app = [], []
    # 8 次连续 502 等满窗 (241s)
    for i in range(8):
        gate.append({"ts": base + i * 60_000, "httpStatus": 502, "elapsedMs": 241_000,
                     "path": "/v1/chat/completions"})
        app.append({"time": datetime.datetime.fromtimestamp(
            (base + i * 60_000) / 1000, datetime.timezone.utc).isoformat(),
            "model": K3_DEFAULT, "component": "routing"})
    # 4 条假 200 (temperature=0, 5ms)
    for i in range(4):
        gate.append({"ts": base + (10 + i) * 60_000, "httpStatus": 200, "elapsedMs": 5,
                     "path": "/v1/chat/completions", "temperature": 0})
        app.append({"time": datetime.datetime.fromtimestamp(
            (base + (10 + i) * 60_000) / 1000, datetime.timezone.utc).isoformat(),
            "model": K3_DEFAULT, "component": "routing"})
    # 一条上游快速拒 400 (300ms)
    gate.append({"ts": base + 20 * 60_000, "httpStatus": 400, "elapsedMs": 300,
                 "path": "/v1/chat/completions"})
    app.append({"time": datetime.datetime.fromtimestamp(
        (base + 20 * 60_000) / 1000, datetime.timezone.utc).isoformat(),
        "model": K3_DEFAULT, "component": "routing"})

    # 2 条正常快 200 (**无 temperature 字段** = 真实 gate schema 形态, 12/45ms)
    # —— 回归用例: 旧实现会把这批误判成假 200 (5/5="100%"), 现必须落"无法判定"。
    for i in range(2):
        gate.append({"ts": base + (30 + i) * 60_000, "httpStatus": 200, "elapsedMs": 12 + i * 33,
                     "path": "/v1/chat/completions"})
        app.append({"time": datetime.datetime.fromtimestamp(
            (base + (30 + i) * 60_000) / 1000, datetime.timezone.utc).isoformat(),
            "model": K3_DEFAULT, "component": "routing"})

    per_model, attr = attribute_models(app, gate)
    st = model_stats(per_model.get(K3_DEFAULT, []))
    checks = [
        ("归属命中 k3", K3_DEFAULT in per_model),
        ("502 计数=8", st["e502"] == 8),
        ("假200 计数=4 (只认确证)", st["false200"] == 4),
        ("假200 不可判定=2 (无 temperature 不冒认)", st["false200_undecidable"] == 2),
        ("400 计数=1", st["e400"] == 1),
        ("等满窗等效超时=8", st["equiv_timeout"] >= 8),
        # ── 回归: 无 temperature 字段的普通快 200 不得判成假 200 ──
        ("回归: 12ms 无字段 → 不判假200", is_false_200(
            {"httpStatus": 200, "elapsedMs": 12, "path": "/v1/chat/completions"}) == (None, False)),
        ("回归: 45ms 无字段 → 不判假200", is_false_200(
            {"httpStatus": 200, "elapsedMs": 45, "path": "/v1/chat/completions"}) == (None, False)),
        # ── 确证路径仍然有效: temperature=0 极短耗时 ──
        ("确证: temperature=0/5ms → 判假200", is_false_200(
            {"httpStatus": 200, "elapsedMs": 5, "temperature": 0,
             "path": "/v1/chat/completions"}) == (True, True)),
        # ── temperature 非 0 = 明确不是 (缓存要求显式 0) ──
        ("明确否定: temperature=0.7 → 非假200", is_false_200(
            {"httpStatus": 200, "elapsedMs": 5, "temperature": 0.7,
             "path": "/v1/chat/completions"}) == (False, True)),
    ]
    print("== omn_health_report 自测 ==")
    for name, res in checks:
        print(f"  [{'PASS' if res else 'FAIL'}] {name}")
        ok = ok and res
    # 曲线渲染不崩
    try:
        _ = ascii_curve([("01", 0.5), ("02", 0.8), ("03", 0.2)])
        print("  [PASS] ascii_curve 渲染")
    except Exception as e:
        print(f"  [FAIL] ascii_curve: {e}")
        ok = False
    print("== 自测 " + ("全绿 exit 0" if ok else "有失败 exit 1") + " ==")
    return 0 if ok else 1


# ══════════════════════════════════════════════════════════════════════
# main
# ══════════════════════════════════════════════════════════════════════
def main(argv=None):
    ap = argparse.ArgumentParser(
        description="omn 日志只读健康报告 (不写文件, 不发网络请求)")
    ap.add_argument("--log-dir", help="save/ 日志目录 (缺省自动探测)")
    ap.add_argument("--model", default=K3_DEFAULT, help=f"聚焦模型面板 (默认 {K3_DEFAULT})")
    ap.add_argument("--json", action="store_true", help="额外输出机器可读摘要到 stderr")
    ap.add_argument("--selftest", action="store_true", help="内置样本自证")
    args = ap.parse_args(argv)

    if args.selftest:
        return selftest()

    log_dir, src = resolve_log_dir(args.log_dir)
    if log_dir is None:
        print("[omn-health-report] " + src, file=sys.stderr)
        return 2

    gate_rows, app_rows, files_info = load_rows(log_dir)
    if not gate_rows and not app_rows:
        print(f"[omn-health-report] 目录存在但无可解析样本: {log_dir}\n"
              f"  期望 save/<gate|app>/<时戳>_<epoch>.log, 内容为 JSONL。\n"
              f"  请确认日志是否已产生 / 是否被 redact 后落盘。", file=sys.stderr)
        return 2

    per_model, attr = attribute_models(app_rows, gate_rows)
    report = render_markdown(log_dir, src, per_model, attr, gate_rows, args.model)
    print(report)

    if args.json:
        summary = build_json_summary(log_dir, per_model, attr, gate_rows, args.model)
        summary["files"] = files_info
        print(json.dumps(summary, ensure_ascii=False, indent=2), file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
