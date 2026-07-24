# Dockerfile 改动累积待办
**建**: 2026-07-24
**律**: 圣上令"累积5条需改Dockerfile时一起改"。未满5条前不触, 仅累积。
**命中范围**: 本仓 `omn-merge/Dockerfile`(Space 现役) + `~/omn-ops/ghcr/Dockerfile`(三层解耦环境层真源) + `omn-merge/ghcr-tracked-Dockerfile`(跟踪副本)。

---

## 第1条(2026-07-24 01:57 boot 观察)

**症**: boot log 出 `[bootstrap] 缺失基础工具: python3` → 走"镜像 A 模式"补全, apt+pip 装 42 包(13.6MB)耗时约 60s, 含 curl/jq/python3.13/sqlite3/huggingface_hub。

**非病**: A 模式自愈兜底成功(`bootstrap.sh:16-33`), boot 续跑成 → 真 稳态(见 2026-07-24 01:57:36 boot 全链通判读)。无 crashloop。

**真根**: Space 现役 `omn-merge/Dockerfile:7` 直 FROM 上游 `diegosouzapw/omniroute:3.8.43@sha256:517c1606...`(上游镜像**未装** python3/curl/jq/sqlite3/litestream)。
- 而三层解耦环境层 `~/omn-ops/ghcr/Dockerfile:37` **已预装** python3+pip+sqlite3+curl+jq(行41 pip huggingface_hub 已装) + litestream(行51 tar 预置解包)。
- 但 Space 未切 ghcr:stable, 仍跑上游直连镜像 → bootstrap 判缺 → A 模式兜底每 boot 临补 60s。

**改向候选(待圣上裁, 攒满5条一并改时再决)**:
- 候选A — **Space `omn-merge/Dockerfile` FROM 切 ghcr:stable**: `FROM diegosouzapw/omniroute:3.8.43@sha256:517c...` → `FROM ghcr.io/i3t2y/omniroute-base:stable`(或带 digest sha256:9c9aecf 钉版)。省每 boot 临补 60s。须验 ghcr:stable 镜像含 bootstrap.sh 三层链 + digest 读回。{memory `omn-ops-ghcr-prebuild-dockerfile-landed` 记 push 通 sha256:9c9aecf, BASE_IMAGE 仍 :stable, 生产无变化 — 即 ghcr:stable 已建但 Space 未切}
- 候选B — **留上游 FROM, 改 ghcr Dockerfile 补预装**: 不切, 仅保 A 模式兜底不变(现状)。但这样 ghcr:stable 永不被用, 三层解耦环境层空建。低价值。

**备注**: 此条本质非"补预装", 是"**切 FROM 到已建好的三层解耦环境层**"。若候选A采, 则 60s 临补消失, 且三层解耦真生效(环境层 giwa 仓, 逻辑层 Dataset, 数据层 R2)。

---

## 第2条(圣上指"npm 外科加脚本非 Dockerfile")

**圣上指示**: "之前那个 npm 最后加在哪个脚本里的, 也没改 Dockerfile, 攒满5条时从其他脚本删, 一并挪进 Dockerfile。"

**实证(外科段位置)**: `omn-logic/entrypoint.sh:236-252` 5.5 段 — 行242 `cd /logic && npm install --omit=dev --silent --no-audit --no-fund`。
- 缘起: 附录A推 gate.js express 版但 bootstrap 三层解耦不跑 npm install, `/logic/node_modules` 缺 → `require('express')` MODULE_NOT_FOUND crashloop → B2 外科补。memory `crashloop-express-fix-landed` 记: commit b5a7891a, 远端非诺/omn-logic换词1件 sha06178176→4803e290。

**逐 boot 临补痛点**: `/logic` 逐 boot 从 Dataset cp 重建 ephemeral(bootstrap.sh:62-64), `/logic/node_modules` 永空启动 → 5.5 段每 boot `npm install --omit=dev` 补装 express(网拉 + 解包 + 写 /logic)。耗 boot 时间 + 增网络依赖。

**挪进 Dockerfile 唯一可行路径 = 路径甲(全局预装)**:
- `~/omn-ops/ghcr/Dockerfile` 增一 RUN: `npm install -g express --omit=dev`(express 入 `/usr/local/lib/node_modules`, 镜像固化)。
- gate.js `require('express')` 行18 — Node 模块解析含全局 `/usr/local/lib/node_modules` 命中, 起时直读全局, 无须 /logic/node_modules。
- 删 `entrypoint.sh:236-252` 5.5 段(连同 `if [ -f /logic/package.json ]` 守护 + FATAL 分支)。
- **前置验(已查证)**: gate.js require 段仅 `express`(行18)+ `http`/`crypto`/`fs`(Node 内置, 行19-21, 无须 npm); package.json dependencies 仅 `express ^4.21.2`, devDependencies 空。即 gate 全 npm 依赖 = express 一个, 全局预装命中无遗漏, 无相对 require 隐患。

**路径乙(逻辑层 node_modules 入镜像)废**: `/logic` build 时不存在(逻辑层 boot 时 Dataset 注入), 无法 COPY node_modules 进 /logic。

**与第1条关系**: 第1条(FROM 切 ghcr:stable)是第2条前置 — 须先切 Space Dockerfile FROM → ghcr:stable, 则全局 express 在镜像里, entrypoint 5.5 删。两改并做 = 三层解耦真生效 + 零 boot 临装(python3 + express 双省)。

**注意**: ghcr Dockerfile 须验 npm 可用 — 上游 diegosouzapw/omniroute 含 node(Next.js 基座), 故 npm 应在; 但镜像 `USER root` (ghcr Dockerfile:33) 后 apt+pip 装时无触 npm, 新增 `npm install -g` 须确认 PATH 含 npm(`/usr/local/bin/npm` 或 `/usr/bin/npm`, 上游 node slim 镜像通常有)。build 后验 `docker run ghcr:stable npm -v` + `node -e "console.log(require.resolve('express'))"`。

---

(待续 第3-5条)
