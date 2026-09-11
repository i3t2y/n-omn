#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
cases_pool_resample.py -- cases_pool 重采与 train 重校 只读分析程序
====================================================================
河图立项案: docs/self-improvement/ideas/2026-09-11-cases-pool-resample.md

职责边界 (硬约束):
  * 只读分析。**不改 gate.py / judge.py / score.py**, 不写任何真源文件,
    不触 Bucket / Space / manifest, 不 merge。
  * 输入 = 候选 case 池 (JSON/JSONL); 输出 = pool 分布 + train 建议 + 锚/正样本排序。
  * 真源 `/data/.hermes/eval/cases_pool.jsonl` 对 NPC 不可达 (红线 2),
    故本仓内置 `--seed-builtin` 演示池 (来自仓内/公开证据);
    接真源直接 `--pool <path>` 即用, 逻辑不变。

用法:
  python3 scripts/cases_pool_resample.py --dry-run            # 只打印池, 不出建议
  python3 scripts/cases_pool_resample.py                       # 实测 (builtin seed)
  python3 scripts/cases_pool_resample.py --pool <path.jsonl>   # 接真源
  python3 scripts/cases_pool_resample.py --format json          # 机器可读
"""

import argparse
import json
import sys
from collections import Counter
from datetime import datetime, timezone

# ---------------------------------------------------------------------------
# 常量 / 规矩参数 (来自河图-规矩.md, 只常量引用不改写)
# ---------------------------------------------------------------------------

RESAMPLE_TRIGGER = 30      # h2-resampling 触发线: cases_pool >= 30 条才触发重采
TRAIN_BASELINE = 0.87      # v2.3 现行 baseline(train)
TRAIN_CI = (0.804, 0.924)  # v2.3 train CI
FUSED_RULE_W = 0.4         # fused = 0.4*rule + 0.6*judge
FUSED_JUDGE_W = 0.6

# train 建议式: 锚(回归哨兵) + 正(应保留的稳健行为)
ANCHOR_N = 10
POSITIVE_N = 2

DIFFICULTY_ORDER = ["易", "中", "难", "边界", "held-out"]


# ---------------------------------------------------------------------------
# builtin seed 池: 仓内/公开证据造出的候选池 (非真源, 显式标注)
#   - eval_cases.json 8 例 (GitHub i3t2y/nexus/main/eval, 公开可读)
#   - heldout.json 4 例 (同上; 已公开 => 污染, 保留作对照)
#   - issue#17 prep 4 条 (prep:2 正 + 2 负, 立项案里点的当次复核样本)
# 每条 = {id,label,tier,source,last_updated_at}
# ---------------------------------------------------------------------------

def _builtin_seed():
    # 时间戳用作"按 last_updated_at 排序"的稳定输入 (ISO8601, UTC)
    rows = [
        # --- eval_cases.json (8) ---
        ("easy-01", "pos", "易", "eval_cases", "2026-08-20T00:00:00Z"),
        ("easy-02", "pos", "易", "eval_cases", "2026-08-20T00:10:00Z"),
        # mid-01~03 = "带陷阱的指令执行" 类 (陷阱: 越权/臆造记忆/臆造能力) -> neg
        ("mid-01", "neg", "中", "eval_cases", "2026-08-20T00:20:00Z"),
        ("mid-02", "neg", "中", "eval_cases", "2026-08-20T00:30:00Z"),
        ("mid-03", "neg", "中", "eval_cases", "2026-08-20T00:40:00Z"),
        ("hard-01", "neg", "难", "eval_cases", "2026-08-20T00:50:00Z"),
        ("hard-02", "neg", "难", "eval_cases", "2026-08-20T01:00:00Z"),
        ("edge-01", "neg", "边界", "eval_cases", "2026-08-20T01:10:00Z"),
        # --- heldout.json (4) 已公开 => 污染 ---
        ("ho-01", "neg", "held-out", "heldout", "2026-08-25T00:00:00Z"),
        ("ho-02", "neg", "held-out", "heldout", "2026-08-25T00:10:00Z"),
        ("ho-03", "neg", "held-out", "heldout", "2026-08-25T00:20:00Z"),
        ("ho-04", "neg", "held-out", "heldout", "2026-08-25T00:30:00Z"),
        # --- issue#17 prep (4) 本次复核样本 ---
        ("prep-neg-01", "neg", "难", "prep", "2026-09-11T00:00:00Z"),
        ("prep-neg-02", "neg", "难", "prep", "2026-09-11T00:30:00Z"),
        ("prep-pos-01", "pos", "中", "prep", "2026-09-11T01:00:00Z"),
        ("prep-pos-02", "pos", "难", "prep", "2026-09-11T01:30:00Z"),
    ]
    return [
        {
            "id": rid,
            "label": label,
            "tier": tier,
            "source": source,
            "last_updated_at": ts,
        }
        for (rid, label, tier, source, ts) in rows
    ]


# ---------------------------------------------------------------------------
# 载入
# ---------------------------------------------------------------------------

def load_pool(path):
    """读取 JSON(数组) 或 JSONL(jsonl, 每行一条)。字段: id/label/tier/source/last_updated_at。"""
    with open(path, "r", encoding="utf-8") as fh:
        text = fh.read().strip()
    if not text:
        return []
    if text[0] == "[":
        data = json.loads(text)
    else:
        data = [json.loads(line) for line in text.splitlines() if line.strip()]
    out = []
    for i, row in enumerate(data):
        out.append({
            "id": row.get("id", "case-%03d" % i),
            "label": row.get("label", "neg"),
            "tier": row.get("tier", "中"),
            "source": row.get("source", "unknown"),
            "last_updated_at": row.get("last_updated_at", "1970-01-01T00:00:00Z"),
        })
    return out


# ---------------------------------------------------------------------------
# 分析
# ---------------------------------------------------------------------------

def parse_ts(ts):
    ts = ts.replace("Z", "+00:00")
    try:
        return datetime.fromisoformat(ts)
    except ValueError:
        return datetime(1970, 1, 1, tzinfo=timezone.utc)


def distribution(pool):
    return {
        "total": len(pool),
        "label": dict(Counter(c["label"] for c in pool)),
        "tier": dict(Counter(c["tier"] for c in pool)),
        "source": dict(Counter(c["source"] for c in pool)),
        "trigger_line": RESAMPLE_TRIGGER,
        "reached": len(pool) >= RESAMPLE_TRIGGER,
    }


def rank_by_updated(pool, desc=True):
    return sorted(pool, key=lambda c: parse_ts(c["last_updated_at"]), reverse=desc)


def choose_anchors(pool, n=ANCHOR_N):
    """锚 = 回归哨兵: 按 last_updated_at 倒序取最近非-pos 样本, 捕近期最易复发的骗型。"""
    ordered = [c for c in rank_by_updated(pool) if c["label"] != "pos"]
    return ordered[:n]


def choose_positives(pool, anchors, n=POSITIVE_N):
    """正 = 应保留的稳健行为: 锚外最新 pos (与锚互补不重复)。"""
    anchor_ids = {c["id"] for c in anchors}
    ordered = [c for c in rank_by_updated(pool) if c["label"] == "pos" and c["id"] not in anchor_ids]
    return ordered[:n]


def train_proposal(pool):
    anchors = choose_anchors(pool)
    positives = choose_positives(pool, anchors)
    ordered = rank_by_updated(pool)
    return {
        "anchor_n": len(anchors),
        "positive_n": len(positives),
        "train_target": len(anchors) + len(positives),
        "anchors": [c["id"] for c in anchors],
        "positives": [c["id"] for c in positives],
        "ordered_all": [
            {"id": c["id"], "label": c["label"], "tier": c["tier"],
             "last_updated_at": c["last_updated_at"]}
            for c in ordered
        ],
    }


def baseline_projection(train_target):
    """
    重采后 train 基线设想 (代理, 非真 trace)。
    诚实边界: 本侧无 judge/gate 真跑, 只给区间设想 + 显式标注 proxy。
    """
    # 以 v2.3 为锚, 样本量从 10 -> train_target 的区间示意 (不是实测)
    lo = round(TRAIN_CI[0] - 0.004, 4)
    hi = round(TRAIN_CI[1], 4)
    mean = round(sum(TRAIN_CI) / 2, 4)
    cilo, cihi = round(mean - 0.041, 4), round(mean + 0.041, 4)
    return {
        "note": "proxy 估计, 非真 trace; 仅作不垮判据示意",
        "train_target": train_target,
        "train_ci": [lo, hi],
        "proxy_mean": mean,
        "proxy_ci95": [cilo, cihi],
        "intersects_v23_ci": not (cilo > TRAIN_CI[1] or cihi < TRAIN_CI[0]),
        "inside_band": TRAIN_CI[0] <= mean <= TRAIN_CI[1],
    }


# ---------------------------------------------------------------------------
# 输出
# ---------------------------------------------------------------------------

def render_text(pool, dist, prop, proj, dry_run):
    L = []
    L.append("=" * 68)
    L.append("cases_pool 重采 · 只读分析报告")
    L.append("=" * 68)
    L.append("")
    L.append("[池来源] %s" % ("--pool <真源路径>" if not dry_run else "builtin seed (仓内/公开证据)"))
    L.append("")
    L.append("## 一、池分布")
    L.append("  total         = %d" % dist["total"])
    L.append("  label         = %s" % dist["label"])
    L.append("  tier          = %s" % dist["tier"])
    L.append("  source        = %s" % dist["source"])
    L.append("  触发线         = %d  (已达=%s)"
             % (dist["trigger_line"], dist["reached"]))
    L.append("")
    L.append("## 二、按 last_updated_at 倒序 (全池)")
    for c in prop["ordered_all"]:
        L.append("  %-14s %-4s %-8s %s"
                 % (c["id"], c["label"], c["tier"], c["last_updated_at"]))
    L.append("")
    if dry_run:
        L.append("## [dry-run] 未生成 train 建议 (去掉 --dry-run 出建议)")
        return "\n".join(L)
    L.append("## 三、train 建议")
    L.append("  目标数 = %d = 锚 %d + 正 %d"
             % (prop["train_target"], prop["anchor_n"], prop["positive_n"]))
    L.append("  锚 (%d, 回归哨兵, 非-pos 按最新排序):" % prop["anchor_n"])
    for i in prop["anchors"]:
        L.append("    - %s" % i)
    L.append("  正 (%d, 锚外最新 pos):" % prop["positive_n"])
    for i in prop["positives"]:
        L.append("    - %s" % i)
    L.append("")
    L.append("## 四、重采后 train 基线设想 (proxy, 非真 trace)")
    L.append("  train CI   = [%.3f, %.3f]  (v2.3 现行为 [%.3f, %.3f])"
             % (proj["train_ci"][0], proj["train_ci"][1], TRAIN_CI[0], TRAIN_CI[1]))
    L.append("  proxy mean = %.4f  CI95=[%.4f, %.4f]"
             % (proj["proxy_mean"], proj["proxy_ci95"][0], proj["proxy_ci95"][1]))
    L.append("  与 v2.3 CI 相交 = %s ; 均值落带内 = %s -> %s"
             % (proj["intersects_v23_ci"], proj["inside_band"],
                "未垮" if (proj["intersects_v23_ci"] and proj["inside_band"]) else "需复核"))
    L.append("")
    L.append("## 五、红线自证")
    L.append("  - 未改 gate.py / judge.py / score.py")
    L.append("  - 未写 cases_pool 真源 / 未触 Bucket / Space / manifest")
    L.append("  - 未 push main / 未 merge")
    return "\n".join(L)


def main(argv=None):
    ap = argparse.ArgumentParser(description="cases_pool 重采 只读分析 (不改测量仪)")
    ap.add_argument("--pool", help="候选池路径 (.json 数组 或 .jsonl)")
    ap.add_argument("--dry-run", action="store_true", help="只打印池, 不出建议")
    ap.add_argument("--seed-builtin", action="store_true", help="用内置演示池 (默认)")
    ap.add_argument("--format", choices=["text", "json"], default="text")
    args = ap.parse_args(argv)

    if args.pool:
        pool = load_pool(args.pool)
        src = args.pool
    else:
        pool = _builtin_seed()
        src = "builtin-seed"

    dist = distribution(pool)
    prop = train_proposal(pool)
    proj = baseline_projection(prop["train_target"])

    if args.format == "json":
        out = {
            "source": src,
            "distribution": dist,
            "proposal": prop,
            "baseline_projection": proj,
            "dry_run": args.dry_run,
        }
        print(json.dumps(out, ensure_ascii=False, indent=2))
    else:
        print(render_text(pool, dist, prop, proj, args.dry_run))
    return 0


if __name__ == "__main__":
    sys.exit(main())
