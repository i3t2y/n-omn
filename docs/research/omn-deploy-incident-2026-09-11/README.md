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
河图-查证与论证-2026-09-11.md                  ← 【新增】对上一份的查证与论证: P0–P16 问题清单 /
                                                 ✓11 条复核通过 / M1–M7 待补 (每条标证据强度 +
                                                 是否需人工复核)。⚠️ 含首次公开的河图内部运行
                                                 参数, 详见该文头部「归档说明」
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
      > **2026-09-11 晚补正 (查证报告 P4)**：危害面已精确化——CNB `nexus.zen/nexus`
      > **无 `eval/` 目录 (404)**，故 NPC 可见域内隔离**仍有效**，历史评分**可信**；
      > 泄漏面 = 公众可见答案，**非"NPC 偷看答案"**。
      > 但**顺序依然敏感**：整树 force push 会顺带删掉公开 `eval/` (歪打正着)，
      > 若先做成"正确 overlay 保留 eval/" 则**固化漏洞**。⇒ 本项必须先于镜像同步修复裁决。
- [ ] **3. heldout 轮换** — 已公开的 4 例视为已污染，是否重写？(建议重写)
- [ ] **4. 假绿** — `nexus/.cnb.yml` 镜像同步的软跳过是否改 `exit 1`？(建议改)
- [ ] **5. 河图第 6 字段** — 是否加「部署影响面」+ merge 分级表加一行？
      > **⚠️ 补正 (查证报告 P0)**：这条**对 omn 不生效**。河图规范在 nexus 仓，
      > 而 NPC 唯一被平台保证注入的约束是**各仓自己的 `.cnb/settings.yml` role prompt**，
      > 且 `CONSTRAINTS.md` 明载"限地：默认单仓、不跨仓"。
      > ⇒ 第 5 项只能改善**人的复核清单**，不改变 NPC 行为。要改 NPC 行为走第 6 项。

## 待拍板事项 (新增 · 源自查证报告 P0)

- [ ] **6. NPC 部署契约注入** 【最急】— 是否给 `n-omn/.cnb/settings.yml` 的
      `npc.roles[CodeBuddy].prompt` 加第 8 条："增删 `logic/` 文件时，必须同步三处部署清单
      (`space/start.sh`、`.github/workflows/sync-logic-xnexus.yml` 的上传与回读校验两段)"？
      成本 = 一行 yaml。**注**：部署清单文件本就在 omn 仓内、NPC 可见 (已实证)，
      缺的不是信息，是**没有人告诉它存在耦合**。
      障碍：该文件属 CI/权限类，需 Zen 裁决由谁改。
- [ ] **7. CONSTRAINTS 注入断层** — `nexus/.cnb/settings.yml` 的 prompt **从未引用
      `CONSTRAINTS.md`**，而后者自称"须注入 role prompt"。是否补上引用？
      (不补 ⇒ 河图规范与 NPC 约束之间始终没接线，后续任何"加字段"类建议效果都不可预期)
- [ ] **8. baseline 门闩语义** — 是否把 baseline 从"绝对放行门闩"降级为"相对 tripwire"？
      依据：项目自产的罪己诏已自证样本量不足以支撑 0.05 精度的门闩
      (误差半径是返工带宽的 3~4 倍；且存在事后按答案出题的选择性偏差)。
- [ ] **9. 河图文档腐烂** — 多份运行档未随版本更新、且内部数值自相矛盾。
      在"只增不改"规则下不会自动收敛。是否允许**回写修订历史档**？(需破例)

> ⚠️ 注意本仓为**公开仓**。本目录文档描述问题但不含 eval 标准答案正文、不含任何真实凭据
> (已逐项扫描: 命中的只有 `process.env.X` 读取、`<placeholder>`、`***` 脱敏与合成串)。
> `河图-查证与论证-2026-09-11.md` 会**首次公开**河图的部分内部运行参数 (无访问凭据)，
> 详见该文头部「归档说明」——该文位于非 main 分支，可整体删除回退。

关联: `docs/ops/incidents/2026-09-11-policy-guard-list-omission-restart-loop.md`
