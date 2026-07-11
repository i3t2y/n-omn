# TESTING — omniroute 太空舱 v4.3 candidate

> 候选内 tests/ 测试. 不访问真实 OmniRoute/NVIDIA/R2 实例. 所有测试在 `candidate-v4.3-reviewed/tests/`.
> 依赖仅在 candidate 目录内安装 (不全局, 不改根 lockfile). 见 §依赖处理.

## 环境

- Node v22.22.0, bash 5.x, python3 (yaml 解析), jq 1.6, sqlite3 (mock DB).
- candidate/tests/ 安装 express 至 node_modules/ (仅 candidate 目录).
- mock 上游用 Node 内置 `http.createServer` (127.0.0.1:随机端口), 不调真实.

## 执行命令

```bash
cd candidate-v4.3-reviewed/tests
# 依赖 (仅 candidate 内):
# 前置记录命令与来源: npm install express@^4.21.2 (源 npm registry, 根无 lockfile 不改)
npm install --omit=dev --prefix . --silent express 2>&1 | tail -3
# 全测:
node test-runner.js
# 单测矩阵:
node test-syntax.js && node test-gate-paths.js && node test-psk.js && \
node test-basic-auth.js && node test-sse.js && node test-signal.js && \
node test-litestream.js && node test-idempotent.js && node test-residual.js
bash test-shell.sh   # sh -n / bash -n / jq / yaml
```

## 测试矩阵 (10 类)

| # | 类 | 文件 | 覆盖 | 结果 |
|---|----|------|------|------|
| 1 | 静态语法 | test-syntax.js + test-shell.sh | `node --check` gate.js, `sh -n` entrypoint.sh, `bash -n` init, `jq` package.json, `yaml.safe_load` litestream.yml | PASS |
| 2 | 路径矩阵 | test-gate-paths.js | 默认仅 /healthz+/v1; 其余 404; 后台关时 /、/api/*、登录页 404 (即使有 OmniRoute Cookie); ENABLE_ADMIN_UI 残留扫描 | PASS |
| 3 | PSK | test-psk.js | 缺失/空/错误/长度不同/正确 INTERNAL_PSK via /v1; timing-safe 不退字符串比较 | PASS |
| 4 | query/路径保持 | test-gate-paths.js | query string 原样; /v1 不剥离; normalizePath 防 dot-seg/重复斜杠/尾斜杠; 大小写不绕过 | PASS |
| 5 | mock 上游状态 | test-upstream-status.js | 200/400/401/403/404/410/413/422/429/500/502/503/504/超时 (mock http) | PASS (mock 实跑; 无 NEEDS-MOCK-D-BLOCKED) |
| 6 | SSE 真流式 | test-sse.js | 首块流结束前到客户端; 多块顺序; 无整流缓冲; 客户端断开取消上游; 不 text/json 读流 | PASS |
| 7 | LiteStream | test-litestream.js (bash) | DB 不存在 / 0 字节 / 已存在非空(跳过) / restore=0 但无效(丢弃) / restore 失败 / 配置缺失 | PASS |
| 8 | 进程监督 | test-signal.js (bash) + test-shell.sh | SIGTERM / SIGINT / gate 异常退 / OmniRoute 异常退 / LiteStream 严格+非致命 / 无遗留子进程 | PASS |
| 9 | 幂等 | test-idempotent.js | init 连续两次运行无重复 Provider/Model/Combo (mock OmniRoute API GET 存量) | PASS |
| 10 | 残留扫描 | test-residual.js | Relay/cf-worker/context-relay/RELAY_URL_*/RELAY_TOKEN_*/x-relay-*/ENABLE_ADMIN_UI/contextLength 敏感明文 | PASS |

## GATE_ADMIN_TOKEN 测试 (见 TEST 2/3 + test-basic-auth.js)

| 子项 | 结果 |
|------|------|
| 未设置后台 token → /, /api/*, 登录页 404 | PASS |
| 空值/过短 → 后台关 404 + 不泄露 | PASS |
| 合法 administrator token → 后台开, 无 Basic Auth 401 | PASS |
| malformed Basic Auth / 错误用户名 / 错误 token / 长度不同 → 401 | PASS |
| 正确 Basic Auth → 白名单页 + 只读 /api/* 可达; 非白名单仍 404 | PASS |
| 权限隔离: INTERNAL_PSK 不能访问后台; GATE_ADMIN_TOKEN 不能访问 /v1; 两 token 相同也不回退混用 | PASS |
| 方法白名单: GET 白名单 POST/PATCH/DELETE → 405; URL 编码/dot-seg/重复斜杠/尾斜杠/大小写/query 不绕过 | PASS |
| 浏览器资源: 后台开且认证对 → 首页+/_next/* 可载; 后台关 → 静态 404; 不得因 _next 放行形成任意上游透传 | PASS |
| 上游认证: 通过 Basic Auth 后 OmniRoute 未登录仍返回其登录语义; Gate 不注入 Session/伪造 Cookie/删必要 Set-Cookie; 完成 delete Authorization 不转发 Basic 给上游 | PASS |

## 回归 (TEST 1-8 + 见上表)

- /healthz, /v1+PSK, SSE, 客户端断开, 上游超时, 非白名单 404, Gate 零额外限流 — 全 PASS.

## 未执行项 (NEEDS-*)

- **G1 NEEDS-INSTANCE-TEST**: NIM direct-cloud 分支与 `useUpstream429BreakerHints` 实例验证未执行 (无实例/凭据; 候选保守 false).
- **HF 代理拓扑未验证**: IP/CIDR 限制未默认实现.
- **后台完整白名单实测**: 高风险写操作 (POST/PATCH/DELETE `/api/provide` 等) 默认不开放, 列 KNOWN-UNVERIFIED; 完整后台 UI 依赖写操作路径待实例验证补.
- **自动 Context Override API PATCH 路径**: 启用路径写后值落定 (实例 `max_input_tokens` 写回) 未实例验证.
- 工具退化: shellcheck/yq 未装 (用 `bash -n` + `python yaml` 退; 已守不装原则).

## 依赖处理

- 候选 tests/ 装 express 至 candidate 内 `node_modules/` (不全局, 不改根 lockfile).
- 命令记录: `npm install --omit=dev --prefix . --silent express` (源 npm registry).
- 安装失败不伪造 PASS (测试 runner 检 node_modules 存在, 缺则 MARK + 退出非 0).
- 若 SSE 真测试环境/依赖阻断: 标 `NEEDS-MOCK-D-BLOCKED`, 不宣称完整通过, 不入 Stage E. (本次未阻断, SSE 实跑 PASS.)
