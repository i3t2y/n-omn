# omniroute 太空舱 · v4.3 candidate (Stage D)

> 候选版仅评审. 来自 `candidate-v4.3-reviewed/`, 不在生产实例部署. 已通过 candidate 内 tests/.
> 基线: B1 `nomn/main@42ea8e7` (生产行为) + B2 `working tree@9a1a7f0` (已验证保守修正) + B3 `omniroute-v3.8.43@b729a8f` (OmniRoute 契约).
> 详细差异见 audit/06-candidate-review.md, 未决见 KNOWN-UNVERIFIED.md.

## 架构

```
公网 :7860  ─►  gate.js (PSK + admin Basic Auth + SSE 透传)  ─►  127.0.0.1:20128  OmniRoute (Next.js)
                     │                                                  │
                     │ /healthz 免认证                                    │ SQLite /data/storage.sqlite
                     │ /v1,/v1/* PSK (INTERNAL_PSK) → 替 OR_API_KEY      │
                     │ 后台白名单 Basic Auth (GATE_ADMIN_TOKEN)            │
                     └ 无第二套限流 (28/1/2200ms 在 OmniRoute requestQueue)  └─ Litestream → R2
```

唯一出口代理直连 OmniRoute, **无外部 Relay / cf-worker / context-relay**

## 配置 (HF Space Secrets)

| Secret | 必需 | 用途 | 默认 |
|--------|------|------|------|
| `INTERNAL_PSK` | 是 (≥16 chars) | /v1 推理请求鉴权 (Gate 入口, Bearer PSK) | fail-closed |
| `JWT_SECRET`, `API_KEY_SECRET`, `INITIAL_PASSWORD`, `OMNIROUTE_API_KEY` | 是 (OmniRoute 内部) | OmniRoute 自身认证 | — |
| `NIM_KEYS` | 是 | NVIDIA NIM API keys (换行分隔) | — |
| `R2_ACCESS_KEY_ID`, `R2_SECRET_ACCESS_KEY`, `R2_ACCOUNT_ID` | 否 | R2 备份; 缺失则复制非致命降级 | 跳过 |
| `GATE_ADMIN_TOKEN` | 否 (≥16 chars) | **后台访问开关兼 Basic Auth 密码**; 留空/过短 → 后台关闭 (全 404) | 不设=关 |
| `LITESTREAM_STRICT` | 否 (默认 1) | 复制失败严格(exit)/非致命(warn)| 1 (严格) |
| `HF_TOKEN`, `HF_DATASET_REPO` | 否 | 配置快照上传 Dataset | 跳过 |
| `GATE_UPSTREAM_TIMEOUT_MS` | 否 (30000) | 上游超时 | 30000 |

## 默认值与 fail-closed 行为

- **PSK 缺失/过短 (<16)**: gate.js 启动 `process.exit(1)` (fail-closed).
- **OR_API_KEY 缺失** (env 和 `/data/.or-api-key` 均无): gate.js `exit(1)`.
- **GATE_ADMIN_TOKEN 未设/空/过短**: **后台关闭**, 后台路径全 404 (不泄露后台存在); 有 OmniRoute Cookie/Session 仍 404.
- **GATE_ADMIN_TOKEN 设有效值 (≥16)**: **后台开启**, 白名单路径经 HTTP Basic Auth (用户名 `admin`, 密码=token) 放行; 非白名单仍 404; `/_next/*`, public 静态资源免 admin token (仅须开关开).
- **LiteStream restore**: 本地 DB 存在且非空 → 跳过 (绝不覆盖); 临时路径恢复 + post `PRAGMA quick_check`; 失败按 `LITESTREAM_STRICT` 严格 exit / 非致命 warn.
- **Debug Dataset 日志上传**: **默认关闭** (`NIM_DEBUG_LOG_TO_DATASET=1` 开启); 开启时上传前字段级脱敏 Authorization/NIM_KEY/Cookie/Bearer → `<REDACTED>`.
- **限流**: 固定 28 RPM / 1 并发 / 2200ms, 仅写 OmniRoute `requestQueue`; Gate 不重复限流 (零限流代码).
- **Resilience `useUpstream429BreakerHints=false`** (保守默认; NIM direct-cloud 分支实例未证).
- **自动 Context Override**: **默认关闭**; 启用须经 API `PATCH /api/provider-models` 的 `max_input_tokens`/`max_output_tokens` + 读回 (见 KNOWN-UNVERIFIED).

## 后台访问 (GATE_ADMIN_TOKEN) — 扩大公网暴露面

**默认关闭** (不设 `GATE_ADMIN_TOKEN`). **设置该变量会扩大公网暴露面**:
- 开启后, 后台白名单页面 (登录、看板、文档、静态资源) + 只读管理 API 可经 Basic Auth 访问.
- 后台仍**受 OmniRoute 自身认证约束** (登录/Session/Cookie 保留), Gate 仅控可达性, 不替代/OmniRoute 鉴权.
- **无 IP/CIDR 限制**: HF 平台代理拓扑未验证, 暂不实现 (见 KNOWN-UNVERIFIED); 不得声称有 IP 防护.
- **建议**: 仅在维护窗口临时配置强随机 token (≥16 chars), 使用后删除该 Secret 即恢复仅 API 暴露模式.
- 禁止能力: restart/shutdown/任意执行/插件安装/通配 `/api/*` 默认不开放; 写操作 (POST/PATCH/PUT/DELETE) 默认不在白名单 (见 KNOWN-UNVERIFIED).

## 三类入口分离

| 路径 | 方法 | 认证 |
|------|------|------|
| `/healthz` | GET | 免认证 |
| `/v1`, `/v1/*` | 任意 (SSE 透传) | `INTERNAL_PSK` (Bearer) |
| 后台白名单页面/静态 | GET | `GATE_ADMIN_TOKEN` (Basic Auth; 静态免) |
| 只读 `/api/*` 白名单 | GET | `GATE_ADMIN_TOKEN` (Basic Auth) |
| 其他 | 任意 | 404 |

`INTERNAL_PSK` 与 `GATE_ADMIN_TOKEN` **用途隔离**, 不得互相回退.

## 测试

见 TESTING.md. candidate 内 tests/ 完整 (路径矩阵、PSK、Basic Auth、SSE 真流式、信号、LiteStream、幂等、残留扫描).

## 回退

见 ROLLBACK.md. 删除 `GATE_ADMIN_TOKEN` + 重启即关闭后台 (仅 API 暴露).
