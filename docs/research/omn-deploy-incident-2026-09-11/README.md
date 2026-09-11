# omn 部署清单漏件事故 — 完整材料 (2026-09-11)

> 本目录是 2026-09-11「`policy-guard.js` 三处部署清单同漏 → HF Space 重启循环」事故的
> **完整工作材料归档**：调研 → 归因 → 建议 → 补丁 → 证据日志。
>
> 正式事故记录 (结论版) 见 `docs/ops/incidents/2026-09-11-policy-guard-list-omission-restart-loop.md`。
> 本目录保留**过程与原始证据**，供追溯；正式记录只保留结论。

## 事故一句话

`logic/` 有 8 件业务文件，但三处硬编码部署清单全都只列了 7 件 + `flaretunnel`，
同漏第 8 件 `policy-guard.js`；而 `gate.js:22` 顶层 `require('./policy-guard.js')`
→ gate 启动即死 → entrypoint 视 gate 死为致命 (STRICT) → 全停 → **HF 无限重启循环**。
CI 之所以长期假绿：回读校验只验「自己清单内」的文件，清单漏件时校验范围同漏。

## 修复与验证

| 项 | 值 |
|---|---|
| 修复 commit | `dc66978a` (sync-logic 两处清单 8→9) + `6e551e8d` (start.sh boot 清单 8→9) |
| 上线路径 | CNB PR #14 / #15 → fast-forward 同步 GitHub main (两侧 SHA 一致) |
| CI | Actions run #60 (sync-logic, 含逐字节 sha256 读回) 绿; run #15 (sync-space) 绿 |
| HF | 自动 Rebuild `11:10:17 → 11:10:53`; boot `11:11:51` |
| 铁证 | `[start] Bucket 校验通过 (n-omn@dc66978 9 件 sha256 全对)` |
| 结果 | boot 日志 664 行 **0 条 FATAL/崩溃**; gate 起于 7860; FT 30/30 Worker; NIM init rc=0 |

## 目录内容

```
README.md                                    ← 本文件
调研报告-nexus与omn全链路现状-2026-09-11.md    ← 起手调研: omn/nexus 全链路实读 (部署链 4 段 /
                                                CNB↔GitHub 凭证现实 / 镜像同步现状)
河图hetu机制梳理与omn事故归因-2026-09-11.md    ← 河图(自我改进闭环)机制梳理 + 本次事故归因
建议书-三线处置与待决事项-2026-09-11.md        ← 三线处置建议 (P0/P0.5/P1/P2) + 5 项待拍板
待你执行-omn修复合并步骤-2026-09-11.md         ← 修复合并的手工步骤 (含顺序约束)
patch/
  A-sync-logic-xnexus.yml                    ← 补丁: 修复后完整 workflow (两处清单 9 项)
  B-start.sh                                 ← 补丁: 修复后完整 start.sh (boot 清单 9 项)
  PR-A-body.md / PR-B-body.md                ← 两个 PR 的描述正文 (含合并顺序警告)
evidence/
  ev-run.log                                 ← 恢复后 boot 运行时日志 (evidence 分支
                                               logs/xnexus--o/20260911-1114-run.log 本地副本)
  ev-build.log                               ← HF Rebuild 日志 (20260911-1114-build.log)
tools/
  fetch.sh / get.py                          ← 经 CNB CLI 取仓内文件内容的助手 (材料来源可复现)
```

## 需要知道的两件事

### 1. 合并顺序有硬约束

**必须先合 sync-logic 清单修复 (`dc66978a`)，等桶内 manifest 含 `policy-guard.js`
之后再合 start.sh (`6e551e8d`)。** 顺序反了，boot 会因「manifest 缺
`policy-guard.js`」再报一轮 FATAL (下个 boot 自愈，但会多几次失败)。本次按正确顺序执行。

### 2. manifest 记 `dc66978` 而非 main 的 `6e551e8d` — 是预期，不是陈旧

`sync-logic-xnexus.yml` 触发路径是 `logic/**`；`space/start.sh` 属 `space/**`，不触发它。
manifest 语义是「逻辑层内容来自哪个提交」，而 `6e551e8d` 只改骨架侧 start.sh，不动逻辑层
字节。故二者不矛盾。

## 待拍板事项 (源自建议书 §五)

- [x] **1. omn 三处清单** — 已由我执行并验证上线
- [ ] **2. eval 公开泄漏** — `i3t2y/nexus` (公开) 下 `eval/heldout.json` 4 例标准答案 +
      `eval_cases.json` 8 例可匿名读取 → 河图"防过拟合"前提失效。选项：
      ① 仓库转 private ② 迁私有载体 ③ 暂缓。**与 P1 修复强耦合** (见建议书 §事实 1)
- [ ] **3. heldout 轮换** — 已公开的 4 例视为已污染，是否重写？(建议重写)
- [ ] **4. 假绿** — `nexus/.cnb.yml` 镜像同步的软跳过是否改 `exit 1`？(建议改)
- [ ] **5. 河图** — 是否加第 6 字段「部署影响面」+ merge 分级表加一行？

> ⚠️ 注意本仓为**公开仓**。本目录文档描述问题但不含 eval 标准答案正文、不含任何真实凭据
> (已逐项扫描: 命中的只有 `process.env.X` 读取、`<placeholder>`、`***` 脱敏与合成串)。

关联: `docs/ops/incidents/2026-09-11-policy-guard-list-omission-restart-loop.md`
