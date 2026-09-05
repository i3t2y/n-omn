# n-omn 目录布局 (2026-09-05 Zen)

## 活链

| 路径 | 说明 | 别动 |
|------|------|------|
| `CLAUDE.md` | 宪法 v4 (Zen) | 红线 |
| `docs/` | SSOT 文档链 + archive 博物馆 | 不动 audit 外文档名 |
| `docs/audit/` | 审计事件档案 (只增) | 永不整理不删 |
| `ops/` | 决策账/状态/事故 | 只增不改 |
| `logic/` | gate/proxy 8 件套真源 | 改 logic 改生产 |
| `pages/` | h-proxy CF Pages 部署根 | 部署必须 cd pages/ 里跑 |
| `space/` | HF Space 骨架 Dockerfile/README.md/start.sh | sync-space-xnexus.yml 从这里 cp 到 xnexus/o |
| `scripts/` | push-ft-binary.py 手动轻推 ft 二进制 | 工具 |
| `tools/` | assemble/merge/k3/ho-proxy/flaretunnel | 组装用脚本 + 部署边界 |
| `tools/ho-proxy\｜worker ho-proxy 源码 (worker 版反代) | 部署走 `deploy-ft-workers.yml` |
| `tools/flaretunnel\｜FlareTunnel go 源码 + worker.js + wrangler.toml | 跨 `sync-logic-xnexus.yml` 编译推 |
| `tools/patches/` | k3 组装用 patches | 只读 |
| `GHCR-TRACKED-DOCKERFILE` | GHCR 环境层追踪副本 | 真源在 omn-ops/ghcr/Dockerfile |

## 已搬迁 (2026-09-05 Zen)

| 元素 | 原路径 | 去向 |
|------|--------|------|
| HANDOFF.md | 根 | `docs/HANDOFF.md` |
| DECISIONS.md | 根 | `docs/DECISIONS.md` (区分 ops/DECISIONS.md SSOT) |
| audit/ | 根 | `docs/audit/` |
| archive/ (仓库层版本快照) | 根 | `docs/archive/` 合并 (无冲突) |
| dev/logic | `dev/logic/` | `logic/` |
| workers/ho-proxy | `workers/ho-proxy/` | `tools/ho-proxy/` |
| flaretunnel | 根 | `tools/flaretunnel/` |
| patches | 根 | `tools/patches/` |
| upstream/* | 根空目录 (零文件) | 删除 |
| pages/ho-proxy | `pages/ho-proxy/functions/_middleware.js` | `pages/_middleware.js` 平铺 |
| package.json | 根影子副本 | 删除 (真源 logic/package.json) |

> 红线: CI/部署可能还因为老路径在工作 — 改动见 commit log
