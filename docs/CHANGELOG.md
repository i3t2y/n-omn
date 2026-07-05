# Changelog — OmniRoute Gateway (nog)

## 2026-04-30

### tt TLS 指纹伪装 (已完成)
- curl_cffi 替代 httpx，impersonate="chrome147" 匹配 Chrome TLS 指纹
- 新增 7 个浏览器 headers，修正 sec-ch-ua 顺序
- 防封措施全部到位：TLS + headers + 间隔 + 缓存 + 过滤 + 492 检测

### tt 私库 + HF token 鉴权 (已完成)
- HF Space wanglaisi1/tt 改为私库
- 代理代码支持 X-API-Key header
- Authorization 以 hf_ 开头时跳过代理 key 检查
- Hermes 配置改用 HF token，代理密钥通过 X-API-Key 传递

## 2026-04-30 — tt 图片支持已完成

### tt 图片支持探索 (已完成 — 记录在 tt 仓库)
- 逆向 Tabbit Web UI 图片上传流程：presigned-upload-url → PUT COS → complete-upload
- tt 代理已实现 OpenAI vision → Tabbit COS 上传 + references 构建
- COS bucket: `tab-sg-1300456063.cos.ap-singapore.myqcloud.com`（新加坡）
- **已解决: html_content 必须是顶层字段，可能是反自动化检测或缺少隐藏参数
- **经验：** Tabbit 用 `<tab-mention-node>` HTML 标签引用图片，不是纯文本 `@filename`

### [2132199] fix: PATCH-GATE-003 v3 - combo 删 stream_options，非 combo 设 stream=true
- **Combo**: 删除 `stream_options`，保持 `stream=false`（防 ALL_ACCOUNTS_INACTIVE）
- **非 Combo**: 设 `stream=true`，保留 `stream_options`（支持 usage tracking）
- 测试验证：直连模型 + stream_options → 200 SSE；Combo + stream_options → 200 JSON

### [65d945d] fix: PATCH-GATE-003 扩展到所有模型 - stream!=true 时删除 stream_options
- v2 中间版本，扩展到非 Combo 模型

### [f05c75d] fix: PATCH-GATE-003 - Combo stream=false 时同步删除 stream_options
- v1 初始修复，仅覆盖 Combo

### docs: 新增踩坑经验文档集
- **新增** `docs/EXPERIENCE.md` — 完整踩坑经验与维护指南（PATCH 补丁演进、HF Space 特性、认证链路、模型池管理、开发检查清单）
- **更新** `docs/TROUBLESHOOTING.md` — 新增 §11 `stream_options` 400 错误排查
- **更新** `docs/AI_HANDOFF.md` — 新增 §7.7 stream_options 坑、§7.8 KNOWN_COMBOS 更新规则、扩展"不允许做的事"清单

### [cde4a19] feat: 首次本地克隆并配置 GitHub 认证
- 克隆 i3t2y/nog 到 ~/nog
- 配置 GitHub remote token 认证
- 仓库已含完整架构：
  - cf-worker/ — Cloudflare Worker 入口网关
  - hf-space/ — HF Space 部署 (gate.js + Dockerfile)
  - docs/ — AI_HANDOFF、决策、排障、验证文档
- GitHub Actions 已配置：
  - deploy-cf-worker.yml — push cf-worker/ 自动部署 CF Worker
  - sync-to-hf-space.yml — push hf-space/ 自动同步到 HF Space (3t2y/a)
- 生产模型池 (nim-pool)：
  - nvidia/meta/llama-3.3-70b-instruct
  - nvidia/z-ai/glm-5.1
  - nvidia/qwen/qwen3-coder-480b-a35b-instruct
- 认证链路：Client → CF Worker (CLIENT_TOKEN) → gate.js (INTERNAL_PSK) → OmniRoute → NVIDIA NIM

### [1f30dee] docs: 推送 CHANGELOG.md 到 GitHub
- 提交并推送 CHANGELOG.md 到 origin/main

### feat: 测试 OmniRoute API 连通性
- 端点：`https://omn.360710.xyz/v1`
- Token 认证正常
- nim-pool combo 模型正常工作
- 直连模型正常工作

### feat: 配置 Hermes Agent 集成
- OmniRoute 配置为 Hermes fallback provider
- OmniRoute 配置为 Hermes delegation provider

### [91b2f07] docs: 全仓库源码深度分析
- 新增 docs/implementation-log.md（20 个文件 2,931 行完整分析）
- 覆盖架构全貌、认证三层链路、gate.js 特殊处理、init 10 步流水线
- 模型池配置、CI/CD 流程、已知限制、故障排查速查

### [PATCH-GATE-003] fix: Combo stream=false 时同步删除 stream_options
- **问题**: Hermes 发送 stream_options 字段用于获取 token 用量
- **冲突**: NIM API 要求 stream_options 只能与 stream=true 共存
- **根因**: gate.js 强制 stream=false 触发 400 错误
- **修复**: 强制 stream=false 时同步删除 stream_options 字段
- **测试**: 验证 nim-pool 和直连模型均正常工作
