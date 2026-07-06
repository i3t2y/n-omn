# Architecture Decisions

本文档记录 `nim-omniroute-gateway` 的架构决策。这里不写操作教程，只写为什么这样做，防止后续迭代重复踩坑。

> ⚠️ **本文档状态**：多数 D001-D015 是永恒性架构决策（库私有、不提交 Secret、raw body 原则、HF 临时存储、empty content 不等同 key 坏、model catalog 与 Combo 两件事等），仍成立。**部分含具体值已 drift**（D005 生产/实验池模型集、D012 RPM 28），见各节标注。当前真态以 [`docs/CURRENT_STATE_v3.8.md`](CURRENT_STATE_v3.8.md) 为准。

当前基线：GitHub `v1.0.0`

内部来源：`v1.3.0` 防吞噬版跑通方案

定稿日期：2026-04-25

## D001: GitHub 版本号从 v1.0.0 开始

虽然对话内部方案演进到 `v1.3.0`，但 GitHub 仓库以 `v1.0.0` 作为第一个正式稳定基线。

原因是 GitHub 版本面向外部可复现状态，而不是内部讨论轮次。当前基线已经完成部署、注册、保护、Combo、模型稳定性验证，因此适合作为 `v1.0.0` release。

## D002: 仓库必须私有

仓库包含部署结构、鉴权链路、环境变量名称、运维方法和故障处理路径。即使不提交真实 Secret，公开仓库也会暴露攻击面。

决策：仓库创建为 private。

## D003: 不提交任何真实 Secret

不得提交以下内容：

- NIM API Key
- INTERNAL_PSK
- CLIENT_TOKEN
- INITIAL_PASSWORD
- JWT_SECRET
- API_KEY_SECRET
- Cloudflare Worker Secret
- Hugging Face Space Secret
- Dashboard API Key

仓库只提交变量名、占位符和说明。

## D004: HF Space 存储视为临时存储

HF Space 上的 OmniRoute SQLite 状态不能作为唯一权威来源。容器重建后，provider、combo、model catalog、API key 状态都可能需要重新灌入。

决策：`init-nim-keys.sh` 必须承担幂等初始化职责，而不是依赖一次性手工配置。

## D005: 生产池和实验池分离

> ⚠️ 下列模型集是 v1.0.0 时代实测基线，当前已演进入 [`docs/CURRENT_STATE_v3.8.md`](CURRENT_STATE_v3.8.md) §4（nim-pool 9 模型、新增 nim-codex、无 nim-pool-lab）。决策原则（"round-robin 可靠性由最弱模型决定、生产/实验分离"）仍成立。

生产池 `nim-pool` 只放实测稳定模型：

- `nvidia/meta/llama-3.3-70b-instruct`
- `nvidia/z-ai/glm-5.1`
- `nvidia/qwen/qwen3-coder-480b-a35b-instruct`

实验池 `nim-pool-lab` 保留不稳定模型：

- `nvidia/deepseek-ai/deepseek-v4-pro`
- `nvidia/deepseek-ai/deepseek-v4-flash`
- `nvidia/minimaxai/minimax-m2.7`
- `nvidia/moonshotai/kimi-k2.5`

原因：round-robin 的生产可靠性由最弱模型决定。7 模型混入生产池会把 Kimi、DeepSeek、MiniMax 的 timeout、empty content、504 风险传播给默认入口。

## D006: `Provider returned empty content` 不等同于 Key 失效

Dashboard 中出现 `Provider returned empty content` 时，不直接判定为 NIM Key 无效。

判断顺序：

1. 看 provider 是否仍为 connected。
2. 看 provider 是否 protected。
3. 看限流倒计时是否会自然恢复。
4. 用生产 `nim-pool` 执行 `/v1/chat/completions` 验证是否返回 token。
5. 只有出现 invalid key、unauthorized、大面积 disconnected 时才进入 Key 故障排查。

## D007: `stream:false` 是必要兼容措施

生产请求推荐显式带上：

```json
{
  "stream": false
}
```

原因：Combo 或上游可能返回 SSE 形态，显式非流式可以减少客户端把 SSE 当 JSON 解析导致的格式错误风险。

## D008: gate.js 必须使用 raw body 转发

gate 层不能用会重写请求体的 JSON middleware 破坏原始请求。最终防吞噬版采用 raw body 手动读取和转发，减少模板变量、请求体和 SSE 解析被破坏的风险。

## D009: 禁止 JavaScript 模板字符串写关键日志和转发字符串

历史问题中出现过变量被吞，导致日志显示不完整，例如端口、target、authorization 注入位置被破坏。

决策：关键路径使用字符串拼接，避免模板字符串在文档渲染、复制、压缩或二次转写中被吞噬。

## D010: `nim-pool` Combo 必须使用 `models` 字段

错误写法：

```json
{
  "name": "nim-pool",
  "strategy": "round-robin",
  "providers": ["nvidia"]
}
```

正确方向：

```json
{
  "name": "nim-pool",
  "strategy": "round-robin",
  "models": [
    "nvidia/meta/llama-3.3-70b-instruct",
    "nvidia/z-ai/glm-5.1",
    "nvidia/qwen/qwen3-coder-480b-a35b-instruct"
  ]
}
```

原因：`providers` 会创建空壳 Combo，后续请求可能被解析到默认 provider，出现 `No credentials for provider: openai`。

## D011: 模型目录和 Combo 路由是两件事

Combo 能路由成功，不代表 Dashboard 卡片一定能显示模型名。Dashboard 的 Combo 卡片依赖 model catalog。

决策：必须通过 `/api/provider-models` 注册模型目录。

模型目录注册使用：

```json
{
  "provider": "nvidia",
  "modelId": "meta/llama-3.3-70b-instruct",
  "modelName": "Llama 3.3 70B Instruct (NIM)"
}
```

Combo 内使用完整路由键：

```json
"nvidia/meta/llama-3.3-70b-instruct"
```

## D012: `v1.0.0` Resilience 基线使用 28 RPM

> ⚠️ **RPM 28 已 drift**：v3.8.x 时代上调为 40（`init-nim-keys.sh:48 _RPM=${NIM_RPM:-40}`），见 [`docs/CURRENT_STATE_v3.8.md`](CURRENT_STATE_v3.8.md) §3。本决策"保守稳定优先于最大吞吐、阶梯压测再调"逻辑仍成立，基线值以 40 为准。

虽然理论上 35 RPM 更接近吞吐最优，但 `v1.0.0` 目标是稳定可复现，不是最大吞吐。

基线：

```json
{
  "defaults": {
    "requestsPerMinute": 28,
    "minTimeBetweenRequests": 1,
    "concurrentRequests": 5
  }
}
```

后续通过 Issue 单独测试：

- RPM 32
- RPM 35

不允许在未压测前直接把 `v1.0.0` 基线改成 35。

## D013: provider 被短暂限流是正常保护行为

Dashboard 显示几十秒级限流倒计时，不视为故障。连续测试 provider 或 round-robin 后，部分 provider 进入短暂冷却是 rate-limit protection 生效的表现。

## D014: GitHub 文档分层

文档职责如下：

| 文件 | 职责 |
|---|---|
| `README.md` | 快速理解和导航 |
| `docs/DECISIONS.md` | 架构决策，不写教程 |
| `docs/TROUBLESHOOTING.md` | 故障现象、根因、处理 |
| `docs/VALIDATION.md` | 实测记录和验收标准 |
| `docs/AI_HANDOFF.md` | 无上下文 AI 接手说明 |

## D015: Release 必须基于 tag

`v1.0.0` 需要通过 GitHub Release 固化。Release 内容对应一个 Git tag，代表仓库历史中的一个可恢复点。
```

原因：DECISIONS.md 用来保存“为什么”，避免 README 被踩坑细节污染，也避免未来 AI 重复推翻已验证结论。  
实测证据：`1.3.0.txt` Line 7593 证明 `nim-pool` 正确路由到 nvidia；Line 9163、9182 证明 `/api/provider-models` 是 Dashboard 模型显示问题的根因修复点。

---
