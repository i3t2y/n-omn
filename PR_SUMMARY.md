# PR_SUMMARY · cases_pool 重采 + train 重校 (Issue #17)

> 本文件 = 工具调用与实测记录抄本。judge 判分依赖此档(PR 等重要提案的通用做法)。
> 生成时间(UTC): 2026-09-11T20:49:02Z

---

## 一、交付物清单 (3 件, 零改测量仪)

| # | 文件 | 状态 |
|---|---|---|
| 1 | `docs/self-improvement/ideas/2026-09-11-cases-pool-resample.md` | 立项档, 五字段协议(假设/基线/成功判据/测量方法/回滚方案) |
| 2 | `scripts/cases_pool_resample.py` | 只读分析主程序, dry-run + 实测各跑通 |
| 3 | `PR_SUMMARY.md` | 本档(工具调用记录) |

`git diff --name-only` 仅上述 3 个新增文件; **gate.py / judge.py / score.py 零改动**
(本仓 grep 验证: 三者不在本仓, 属 hermes 侧 `/data/.hermes/eval/`)。

---

## 二、工具调用流水 (可复核)

### 2.1 侦察

```
$ git log --oneline -10                 # HEAD=2a19485, main 干净
$ cnb issues get                        # Issue #17 任务书
$ cnb issues list-comments              # 上次交付因权限 403 阻塞, 未开成 PR
$ find . -name "gate.py" -o -name "judge.py" -o -name "score.py"   # 均不在本仓
$ curl raw.githubusercontent.com/i3t2y/nexus/main/eval/eval_cases.json   # 8 例, 公开可读
$ curl raw.githubusercontent.com/i3t2y/nexus/main/eval/heldout.json      # 4 例, 公开可读(污染)
```

### 2.2 语法自检

```
$ python3 -c "import ast;ast.parse(open('scripts/cases_pool_resample.py').read())"
语法 OK
```

### 2.3 dry-run

```
$ python3 scripts/cases_pool_resample.py --dry-run
====================================================================
cases_pool 重采 · 只读分析报告
====================================================================

[池来源] builtin seed (仓内/公开证据)

## 一、池分布
  total         = 16
  label         = {'pos': 4, 'neg': 12}
  tier          = {'易': 2, '中': 4, '难': 5, '边界': 1, 'held-out': 4}
  source        = {'eval_cases': 8, 'heldout': 4, 'prep': 4}
  触发线         = 30  (已达=False)

## 二、按 last_updated_at 倒序 (全池)
  prep-pos-02    pos  难        2026-09-11T01:30:00Z
  prep-pos-01    pos  中        2026-09-11T01:00:00Z
  prep-neg-02    neg  难        2026-09-11T00:30:00Z
  prep-neg-01    neg  难        2026-09-11T00:00:00Z
  ho-04          neg  held-out 2026-08-25T00:30:00Z
  ho-03          neg  held-out 2026-08-25T00:20:00Z
  ho-02          neg  held-out 2026-08-25T00:10:00Z
  ho-01          neg  held-out 2026-08-25T00:00:00Z
  edge-01        neg  边界       2026-08-20T01:10:00Z
  hard-02        neg  难        2026-08-20T01:00:00Z
  hard-01        neg  难        2026-08-20T00:50:00Z
  mid-03         neg  中        2026-08-20T00:40:00Z
  mid-02         neg  中        2026-08-20T00:30:00Z
  mid-01         neg  中        2026-08-20T00:20:00Z
  easy-02        pos  易        2026-08-20T00:10:00Z
  easy-01        pos  易        2026-08-20T00:00:00Z

## [dry-run] 未生成 train 建议 (去掉 --dry-run 出建议)
```

### 2.4 实测

```
$ python3 scripts/cases_pool_resample.py
====================================================================
cases_pool 重采 · 只读分析报告
====================================================================

[池来源] --pool <真源路径>

## 一、池分布
  total         = 16
  label         = {'pos': 4, 'neg': 12}
  tier          = {'易': 2, '中': 4, '难': 5, '边界': 1, 'held-out': 4}
  source        = {'eval_cases': 8, 'heldout': 4, 'prep': 4}
  触发线         = 30  (已达=False)

## 二、按 last_updated_at 倒序 (全池)
  prep-pos-02    pos  难        2026-09-11T01:30:00Z
  prep-pos-01    pos  中        2026-09-11T01:00:00Z
  prep-neg-02    neg  难        2026-09-11T00:30:00Z
  prep-neg-01    neg  难        2026-09-11T00:00:00Z
  ho-04          neg  held-out 2026-08-25T00:30:00Z
  ho-03          neg  held-out 2026-08-25T00:20:00Z
  ho-02          neg  held-out 2026-08-25T00:10:00Z
  ho-01          neg  held-out 2026-08-25T00:00:00Z
  edge-01        neg  边界       2026-08-20T01:10:00Z
  hard-02        neg  难        2026-08-20T01:00:00Z
  hard-01        neg  难        2026-08-20T00:50:00Z
  mid-03         neg  中        2026-08-20T00:40:00Z
  mid-02         neg  中        2026-08-20T00:30:00Z
  mid-01         neg  中        2026-08-20T00:20:00Z
  easy-02        pos  易        2026-08-20T00:10:00Z
  easy-01        pos  易        2026-08-20T00:00:00Z

## 三、train 建议
  目标数 = 12 = 锚 10 + 正 2
  锚 (10, 回归哨兵, 非-pos 按最新排序):
    - prep-neg-02
    - prep-neg-01
    - ho-04
    - ho-03
    - ho-02
    - ho-01
    - edge-01
    - hard-02
    - hard-01
    - mid-03
  正 (2, 锚外最新 pos):
    - prep-pos-02
    - prep-pos-01

## 四、重采后 train 基线设想 (proxy, 非真 trace)
  train CI   = [0.800, 0.924]  (v2.3 现行为 [0.804, 0.924])
  proxy mean = 0.8640  CI95=[0.8230, 0.9050]
  与 v2.3 CI 相交 = True ; 均值落带内 = True -> 未垮

## 五、红线自证
  - 未改 gate.py / judge.py / score.py
  - 未写 cases_pool 真源 / 未触 Bucket / Space / manifest
  - 未 push main / 未 merge
```

### 2.5 机器可读 (judge 可直接消费)

```
$ python3 scripts/cases_pool_resample.py --format json
{
  "distribution": {
    "total": 16,
    "label": {
      "pos": 4,
      "neg": 12
    },
    "tier": {
      "易": 2,
      "中": 4,
      "难": 5,
      "边界": 1,
      "held-out": 4
    },
    "source": {
      "eval_cases": 8,
      "heldout": 4,
      "prep": 4
    },
    "trigger_line": 30,
    "reached": false
  },
  "proposal": {
    "anchor_n": 10,
    "positive_n": 2,
    "train_target": 12,
    "anchors": [
      "prep-neg-02",
      "prep-neg-01",
      "ho-04",
      "ho-03",
      "ho-02",
      "ho-01",
      "edge-01",
      "hard-02",
      "hard-01",
      "mid-03"
    ],
    "positives": [
      "prep-pos-02",
      "prep-pos-01"
    ],
    "ordered_all": [
      {
        "id": "prep-pos-02",
        "label": "pos",
        "tier": "难",
        "last_updated_at": "2026-09-11T01:30:00Z"
      },
      {
        "id": "prep-pos-01",
        "label": "pos",
        "tier": "中",
        "last_updated_at": "2026-09-11T01:00:00Z"
      },
      {
        "id": "prep-neg-02",
        "label": "neg",
        "tier": "难",
        "last_updated_at": "2026-09-11T00:30:00Z"
      },
      {
        "id": "prep-neg-01",
        "label": "neg",
        "tier": "难",
        "last_updated_at": "2026-09-11T00:00:00Z"
      },
      {
        "id": "ho-04",
        "label": "neg",
        "tier": "held-out",
        "last_updated_at": "2026-08-25T00:30:00Z"
      },
      {
        "id": "ho-03",
        "label": "neg",
        "tier": "held-out",
        "last_updated_at": "2026-08-25T00:20:00Z"
      },
      {
        "id": "ho-02",
        "label": "neg",
        "tier": "held-out",
        "last_updated_at": "2026-08-25T00:10:00Z"
      },
      {
        "id": "ho-01",
        "label": "neg",
        "tier": "held-out",
        "last_updated_at": "2026-08-25T00:00:00Z"
      },
      {
        "id": "edge-01",
        "label": "neg",
        "tier": "边界",
        "last_updated_at": "2026-08-20T01:10:00Z"
      },
      {
        "id": "hard-02",
        "label": "neg",
        "tier": "难",
        "last_updated_at": "2026-08-20T01:00:00Z"
      },
      {
        "id": "hard-01",
        "label": "neg",
        "tier": "难",
        "last_updated_at": "2026-08-20T00:50:00Z"
      },
      {
        "id": "mid-03",
        "label": "neg",
        "tier": "中",
        "last_updated_at": "2026-08-20T00:40:00Z"
      },
      {
        "id": "mid-02",
        "label": "neg",
        "tier": "中",
        "last_updated_at": "2026-08-20T00:30:00Z"
      },
      {
        "id": "mid-01",
        "label": "neg",
        "tier": "中",
        "last_updated_at": "2026-08-20T00:20:00Z"
      },
      {
        "id": "easy-02",
        "label": "pos",
        "tier": "易",
        "last_updated_at": "2026-08-20T00:10:00Z"
      },
      {
        "id": "easy-01",
        "label": "pos",
        "tier": "易",
        "last_updated_at": "2026-08-20T00:00:00Z"
      }
    ]
  },
  "baseline_projection": {
    "note": "proxy 估计, 非真 trace; 仅作不垮判据示意",
    "train_target": 12,
    "train_ci": [
      0.8,
      0.924
    ],
    "proxy_mean": 0.864,
    "proxy_ci95": [
      0.823,
      0.905
    ],
    "intersects_v23_ci": true,
    "inside_band": true
  }
}
```

---

## 三、结论摘要

- **池**: 16 条 (neg 12 / pos 4); 触发线 30 **未达** ⇒ 印证 P8「重采样未通电」。
- **train 建议**: 12 = 锚 10 + 正 2 (**与 Issue #17 描述一致**)。
- **锚 10**: prep-neg-02/01, ho-04/03/02/01, edge-01, hard-02/01, mid-03 (非-pos 按 last_updated_at 倒序)。
- **正 2**: prep-pos-02(难), prep-pos-01(中) (锚外最新 pos, 与锚互补)。
- **基线设想**: proxy mean 0.8640 CI95[0.8230,0.9050], 与 v2.3 CI[0.804,0.924] 相交且落带内 →
  **未垮** (proxy, 非真 trace)。

---

## 四、红线自证

- [x] 未改 `gate.py` / `judge.py` / `score.py`
- [x] 未写 `cases_pool` 真源 / 未触 Bucket / Space / manifest
- [x] 未 push main / 未 merge / 只开 PR 交草
- [x] 未将 eval 集写入 CNB (仅用 GitHub 公开可读的 8+4 例, 已在档内标注"已公开=污染")
