# n-omn 目录布局 (2026-09-05 Zen)

## 活链

| 路径 | 说明 | 别动 |
|------|------|------|
| `CLAUDE.md` | 宪法 v4 (Zen) | 红线 (immutable-after-approval) |
| `docs/` | SSOT 文档链 (HANDOFF/DECISIONS/LAYOUT) + docs/ops + docs/audit + docs/archive | 不动 audit 外文档名 |
| `docs/ops/` | 决策账/状态/事故/工具 (原 root ops/) | 只增不改 |
| `docs/audit/` | 审计事件档案 (只增) | 永不整理不删 |
| `space/` | HF Space 骨架四件 (Dockerfile/README.md/start.sh/.gitattributes) | sync-space-xnexus.yml 白名单 cp 这4件 |
| `logic/` | gate/proxy 8 件套真源 | 改 logic 改生产 |
| `scripts/` | push-ft-binary.py + scripts/pages/ | 手动轻推 ft 二进制 + CF Pages |
| `scripts/pages/` | ho-proxy Pages 版反代根 (_middleware.js 平铺) | 部署根, cd scripts/pages 再 wrangler pages deploy . |
| `tools/` | assemble/merge/k3/ho-proxy(worker)/flaretunnel/patches | 组装用脚本 + 部署边界 |

## 已搬迁 (2026-09-05 Zen)

| 元素 | 原路径 | 去向 |
|------|--------|------|
| HANDOFF.md | 根 | `docs/HANDOFF.md` |
| DECISIONS.md | 根 | `docs/DECISIONS.md` |
| audit/ | 根 | `docs/audit/` |
| archive/ | 根 | `docs/archive/` (合并旧 docs/archive, 无冲突) |
| ops/ | 根 | `docs/ops/` |
| dev/logic | `dev/logic/` | `logic/` |
| workers/ho-proxy | `workers/ho-proxy/` | `tools/ho-proxy/` |
| flaretunnel | 根 | `tools/flaretunnel/` |
| patches | 根 | `tools/patches/` |
| pages/ho-proxy | `pages/ho-proxy/functions/_middleware.js` | `scripts/pages/_middleware.js` |
| upstream/* | 根空目录 (零文件) | 删除 |
| package.json (根影子副本) | 根 | 删除 (真源 logic/package.json) |
| ghcr-tracked-Dockerfile | 根 | 删除 (真源 ~/omn-ops/ghcr/Dockerfile, 跟进漂移过) |
| .gitattributes | 根 | `space/.gitattributes` |

> 红线: CLAUDE.md 不许移动 (机器友好态) · 物理文件全库只增不改原则在 docs/ops 和 docs/audit 内生效; 仓库布局纪律只在这片页设 amend。

