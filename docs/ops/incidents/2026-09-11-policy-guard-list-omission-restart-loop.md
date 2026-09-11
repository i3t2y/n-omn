# policy-guard.js 三处部署清单同漏 — gate 启动即崩 → entrypoint STRICT 全停 → HF 重启循环 — 闭环记录

> 同源病族 (「部署清单硬编码 + 校验范围自限」) 首次发作。三处清单各自手写同一文件集,
> 三处同漏 `logic/` 第 8 件业务文件 `policy-guard.js`; 而 CI 回读校验只校验「清单内」
> 文件 → 清单漏件时校验范围同漏 → **一直假绿**。本档记真根、四处落点、修复顺序约束与
> boot 铁证定谳。

## 执行摘要

`gate.js:22` 顶层 `require('./policy-guard.js')`。该文件属 `logic/` 的 8 件业务文件之一,
但**三处硬编码部署清单全都只列了 7 件业务文件 + `flaretunnel` 二进制 (共 8 项)**:

| # | 落点 | 作用 | 漏件后果 |
|---|---|---|---|
| ① | `space/start.sh` boot 拉取清单 | boot 从 Bucket 拉逻辑层到 `/tmp/logic` | 桶内虽有件, boot 仍不拉 → `/logic` 缺件 |
| ② | `.github/workflows/sync-logic-xnexus.yml` 上传清单 | CI 上传逻辑层到 Bucket | 桶内**根本没有**该件 |
| ③ | 同文件回读校验清单 | 上传后读回比 sha256 | 校验范围同漏 → **CI 假绿** |

① 与 ②③ 叠加 = 桶内无件 **且** boot 不拉 → `gate.js` 顶层 require 抛
`MODULE_NOT_FOUND` → gate 进程起即死。entrypoint 视 gate 死为**致命 (STRICT)** → 全停
→ container exit → HF 拉起新容器 → 同因再崩 = **无限重启循环**。

治本 = 补全清单 (两件): `dc66978a` (sync-logic 两处清单 8→9) + `6e551e8d` (start.sh
boot 清单 8→9)。已上线并 boot 实证根除 (见 §验证铁证)。

**关键佐证 = 注释对、代码漏**: `space/start.sh` 第 52 行注释早就写着
`boot 先拉 manifest + 9 件 (8 业务+flaretunnel)`, 而紧随其后的 python 清单只有 8 项。
注释是上一轮迁 Bucket 时改对的, 清单没跟着改 —— 属**漏改**, 非设计如此。

## 时间线

- 三处清单各自于不同轮次成形 (迁 Bucket 时 ① 手写; ②③ 于 `sync-logic-xnexus.yml`
  新建时手写), 同一文件集被抄了三遍, 无单一真相源。
- 事故期: gate 起即崩 → STRICT 全停 → HF 反复拉起容器。因**每次 boot 覆盖上一轮日志**,
  无 HF token 时无法直接取证 → 排障期一度只能凭「容器反复重启」的外部观测推断。
- 诊断: 由 `logic/` 实际文件集 (8 件 + `tests/` 目录) 与三处清单 (8 项) 逐项对齐定谳 —
  差别唯一项 = `policy-guard.js`。回查 `gate.js:22` 顶层 require 坐实因果链。
- 修复: CNB PR #14 → `dc66978a`; CNB PR #15 → `6e551e8d`。均以 fast-forward 同步到
  GitHub main (两侧 SHA 保持一致, 不产生分叉 merge commit)。
- 上线: Actions run #60 (sync-logic) 绿 (含逐字节 sha256 读回) → run #15 (sync-space) 绿
  → HF 自动 Rebuild `11:10:17 → 11:10:53` → boot `11:11:51`。
- 验证: evidence 分支 `logs/xnexus--o/20260911-1114-run.log` 定谳 (见下)。

## 根因

**直接因**: 三处清单同漏 `policy-guard.js`, 且三处后果叠加 (桶内无件 + boot 不拉)。

**因果链**:

```
三处清单同漏 policy-guard.js
  → (①) boot 不拉该件, (②) 桶内本就没有该件
  → /tmp/logic 下无 policy-guard.js
  → gate.js:22 顶层 require('./policy-guard.js') 抛 MODULE_NOT_FOUND
  → gate 进程启动即死
  → entrypoint 视 gate 死为致命 (STRICT) → 不再拉起后续
  → container exit → HF 拉起新容器 → 同因再崩
  = 重启循环 (非偶发, 每轮必现)
```

**为何 CI 一直绿 (自证偏误)**: `sync-logic-xnexus.yml` 的上传后回读校验, 校验的是
**它自己清单里的那批文件** (`for f in files: ... manifest[files]`, 见 105-117 行)。
清单漏件时, 校验集合同漏 → 校验的恰好是「桶里有的 ∩ 清单里的」= 永远自洽 → **恒绿**。
CI 从未对「`logic/` 目录实际文件集 ⊆ 清单」做过断言, 故对本类漏件完全无感。

**为何 start.sh 注释是对的**: 上一轮迁 Bucket 时把注释更新为「9 件」, 但紧随的 python
清单未同步 —— 属漏改。这正好说明「同一事实写三遍」的结构性风险: 改一处 ≠ 三处一致。

## 促成因素

- **无单一真相源**: 同一文件集被硬编码三遍 (三个不同语言/位置: shell 内嵌 python ×1 +
  workflow 内嵌 python ×2)。任何一次增删 logic 文件都要求三处同步, 漏一处即复发。
- **CI 校验范围自限**: 校验集合由清单自身派生, 形成闭环自证, 无法发现「清单少了件」。
  这是本次能长期假绿的**结构性**原因, 不是偶发疏忽。
- **STRICT 语义放大影响面**: entrypoint 把「gate 启动失败」判为致命 (合理 —— gate 是对外
  唯一入口), 于是单文件缺失直接升格为**整机全停**, 而非降级运行。
- **取证通道缺位**: HF Space 每次 boot 覆盖日志, 重启循环恰好抹掉上一轮证据。缺口由
  `fetch-xnexus-logs.yml` (workflow_dispatch → evidence 分支归档) 填补。
- **回读校验给了虚假信心**: 逐字节 sha256 读回校验本是强保证, 但作用域错了 → 强保证只
  覆盖「清单内」, 反而更令人放心。**强校验 + 错作用域 = 更危险的假绿**。

## 修复 (已验证)

| commit | 文件 | 改动 |
|---|---|---|
| `dc66978a` | `.github/workflows/sync-logic-xnexus.yml` | 两处清单 (上传 58-60 行 / 回读校验 105-107 行) 8 → 9 项, 补 `policy-guard.js` |
| `6e551e8d` | `space/start.sh` | boot 拉取清单 8 → 9 项, 补 `policy-guard.js`; 第 52 行注释对齐 |

两处清单的**文件集与顺序完全一致** (逐字节相同), 保证 boot 拉取路径与 CI 上传/校验路径
看到同一份。

### 合并顺序约束 (重要)

**必须 ②③ (sync-logic) 先生效, 再合 ① (start.sh)**。理由: 若 boot 清单先改成 9 项, 而
桶内 manifest 仍只记 8 件, boot 会因「manifest 缺 policy-guard.js」报 FATAL。此序列下
**下个 boot 会自愈** (sync-logic 跑完后 manifest 补齐), 但会多几次失败 boot。本次按正确顺序
执行。

### 治标 vs 治本

- 治标: 无 (本类事故无 ENV 绕过面 —— 清单漏件是硬缺件, 绕不过 gate 的顶层 require)。
- 治本 (本次): 补全三处清单。
- 治本 (未做, 见 §行动项): 三处清单收敛为**单一来源** (目录枚举或 manifest 派生), 从结构上
  消灭「改一处漏两处」。

## 验证铁证

通道: `fetch-xnexus-logs.yml` (`workflow_dispatch`) → evidence 分支
`logs/xnexus--o/20260911-1114-run.log` (运行时) + `20260911-1114-build.log` (重建)。

**重建段** (`build.log`): `Build Queued at 2026-09-11 11:10:17` → 基础镜像按 digest 钉锚
(`ghcr.io/i3t2y/omn-base@sha256:db9037a7...`, 非浮动 tag) → `COPY --chmod=755 start.sh
/start.sh` → Pushing image → `11:10:53` 完成 (~36 秒)。

**boot 段** (`run.log`, 全 664 行, **0 条 FATAL / 崩溃行**):

| 时刻 | 关键行 |
|---|---|
| 11:11:51 | `[start] >>> 启动 2026-09-11 11:11:51 <<<` |
| 11:11:52 | `[start] Bucket 校验通过 (n-omn@dc66978 9 件 sha256 全对)` ← **真根根除铁证** |
| 11:11:57 | `[entrypoint] FT: 单桥回退 PID=76 (127.0.0.1:8080, 30/30 Worker round-robin)` |
| 11:12:04 | `[entrypoint] starting gate on port 7860...` ← **gate 活** |
| 11:12:04 | `[gate] listening on 0.0.0.0:7860 -> 127.0.0.1:20128` |
| 11:12:19 | `[init] FT bridge healthz: {... "worker_stats":30,"workers":30,"status":"ok"}` |
| 11:12:30 | `[entrypoint] NIM init 已退出 rc=0 (正常完成).` |

判读:
- **「9 件 sha256 全对」= 三处清单已同源**: boot 侧按 9 项拉到且全部哈希匹配。
- **gate 起于 7860 且再无重启** = 因果链末端被切断 (gate 不再因缺件即死)。
- **NIM init rc=0 + FT 30/30** = 后续启动段全透, 非「勉强起来」而是完全恢复。
- 664 行日志内 0 条 FATAL/崩溃行, 与事故期「每轮必崩」形成对照。

**注 (manifest 记的 SHA 为何是 `dc66978` 而非 main 的 `6e551e8d`)**: `sync-logic-xnexus.yml`
的触发路径是 `logic/**`; `space/start.sh` 属 `space/**`, 不触发 sync-logic → manifest 的
`n-omn@SHA` 停留在 `dc66978` (最后一次 `logic/**` 变更点)。**这是预期行为, 非陈旧** ——
manifest 语义是「逻辑层内容来自哪个提交」, 而 `6e551e8d` 只改了骨架侧 start.sh, 不影响
逻辑层字节。故「Bucket 校验通过 (n-omn@dc66978 9 件)」与 main = `6e551e8d` 并不矛盾。

## 行动项

- [x] 补全三处清单 `dc66978a` + `6e551e8d`, ff 同步 GitHub main (两侧 SHA 一致)
- [x] Actions run #60 (sync-logic) 绿 + 逐字节 sha256 读回通过
- [x] Actions run #15 (sync-space) 绿 → HF Rebuild → boot 实证根除
- [x] evidence 分支归档 boot/build 日志 (`20260911-1114-run.log` / `-build.log`)
- [ ] **治本 G5**: 三处硬编码清单收敛为**单一来源** (候选: 由 `logic/` 目录枚举派生清单,
      或由 manifest 反向校验目录实际文件集), 消灭「同一文件集写三遍」
- [ ] **CI 补断言**: 回读校验增加「`logic/` 实际文件集 ⊆ 清单」一项, 破自证偏误
- [ ] 可选: 本档登记入 `docs/ops/STATUS.md` 索引

## 经验教训

1. **同一事实写三遍 = 定时炸弹**。三处清单横跨 shell 内嵌 python 与 workflow 内嵌 python,
   语言不同、位置不同、无任何机制保证一致。任何一次 logic 文件增删都可能复发本事故。
   治本只有一条路: **单一来源**。
2. **校验集合必须独立于被校验对象**。本次 CI 的 sha256 逐字节读回是强校验, 但校验集合由
   清单自身派生 → 清单漏件时校验范围同漏 → **越强的校验给出越有害的假绿**(它让人相信
   「逐字节都验过了」)。凡「校验者从被校验者派生」的校验, 都必须补一条**来自外部**的
   断言 (此处 = 目录枚举)。
3. **注释与代码背离是漏改的信号, 不是文档问题**。`start.sh:52` 注释早已是「9 件」而清单是
   8 项 —— 排障时应把「注释与代码不一致」当作**高优先级线索**直接对齐, 而非跳过。
4. **顶层 require 是硬依赖, 不在依赖清单里却在部署清单里**。`gate.js` 的业务依赖未被任何
   机制表达, 只能靠人记得同步三处清单。新增 logic 文件时须同时问: 「gate/entrypoint 会
   require 它吗?」
5. **STRICT 语义下, 单点缺件 = 整机全停**。这是设计选择 (gate 是唯一入口), 但它把「一个
   文件的部署遗漏」放大成「全站不可用」。清单类遗漏因此值得按**最高等级**防护。
6. **重启循环会吃掉自己的证据**。HF Space 每次 boot 覆盖日志 → 循环期无历史可查。应在
   架构里预置外部归档通道 (本例 = `fetch-xnexus-logs.yml` → evidence 分支), 而非事后找。

关联: [[omn-bucket-logic-switch-landed]] [[xnexus-single-space-topology]] [[flaretunnel-impl-built-verified]]
+ 本事故完整材料见 `docs/research/omn-deploy-incident-2026-09-11/`
