# audit/2026-09-01 · k3 上游 bug 查证 + claudecode 自动停诊断 (memory 快照入血统)

> 本文件 = 会话记忆 (kimi-k3-upstream-bug-verification-2026-09-01 + k3-autostop-agent-loop-unfit-2026-09-01) 的合并快照, 按圣上令"保存所有进私库 nomn"落血统。SSOT 决策见 ops/DECISIONS.md 2026-09-01 条。

---

## 一、omniroute 官方 kimi-k3 调用 bug 查证 (三档)

GitHub Search API + 本地 upstream/omniroute-3.8.50 树 (git HEAD 5458026, **浅克隆仅 1 commit, 不能 git log -S**, 用 CHANGELOG + 代码双证)。

**✅ 已修复且已含** (CHANGELOG [3.8.50] 段 L92-1625 + 代码实证):
- #9496 (08-11) 保留 K3 Responses reasoning → `open-sse/executors/kimi.ts:151 backfillKimiReasoningContent` + `translator/helpers/schemaCoercion.ts:463`
- #9053 (08-07) K3 拒 `xhigh` 400 → 透传 literal max → `executors/base/reasoningEffort.ts:169 isMoonshotK3=/^kimi-k3$/` + L399 supportsMax; 单测 `tests/unit/moonshot-k3.test.ts`
- #9005 stroven BYOK 缺 tool message 名回填 (CHANGELOG L551)
- #9000 reasoning.encrypted_content 保留+日志脱敏 (CHANGELOG L121-122)
- #9338 (08-05) kimi-web K3 场景码 K2D5 (只涉 kimi-web, 与我们 NIM 无涉)

**⚠️ 上游未结 (我们 NIM 路径不触发, 无风险)**:
- #9771 (open needs-info) reasoning replay 跨 provider 验证 — MoonshotExecutor 只绑 provider=`moonshot|kimi`, 我们走 nvidia|openai-compatible → DefaultExecutor 不经此
- #11875 (open PR deferred 3.8.52) 原生 max effort 按模型钳制 — 未含, 但 K3 isMoonshotK3:169 已达标不阻塞

**🟢 结构确认 (为何 NIM 路径恰好覆盖)**: `nvidia/moonshotai/kimi-k3` 经 `getGlobalModel` (`open-sse/config/providerModels.ts:114/120` 剥前缀+子串匹配) 解析到全局 `kimi-k3` (modelSpecs.ts:438 1M ctx/thinking) → `isMoonshotK3` 命中 → 与裸 kimi-k3 同 effort-sanitize 路径, xhigh→max 修复生效。专属 MoonshotExecutor (强制max/固定max_completion_tokens) 仅官方 moonshot provider, NIM 走 DefaultExecutor 由 base.ts:886 sanitizer 兜底。

**落点**: 生产再遇 K3 400 `invalid reasoning value: 'xhigh'` → 三档上游 bug 已排除, 判我们自身层 (gate 透传出处 / NIM 端 modelSeg), 直接查 sanitizer `reasoningEffort.ts:169/399`。

---

## 二、claudecode 用 k3 总自动停 (Thought for 2m 9s) 诊断

**现象**: 后台 k3 调用两条均 200 (17-20s, input 58K, output 46/334 token, `reasoning: 不适用`); UI 每轮 "Thought for 2m 9s" 后停, 大量空消息。本会话即跑在 k3 上复现此模式。

**核心诊断**:
- **200 OK ≠ 正常轮次**: 两条 200 是"成功但退化"轮次 — k3 处理 58K 后只吐 46-token 短答即 `finish_stop`, **无 tool_use**、**无 reasoning** (后台 `reasoning: 不适用`)。agent 循环靠 tool_use 推进, finish 短答断链 → "自动停"。
- **"Thought for 2m 9s" 是每轮思考计时, 非单次调用** (单次 17-20s)。同 round 内 agent 等待/重试累计。
- **`reasoning: 不适用` = k3 思考被剥/未触发**: 请求未带 thinking/effort 字段, 或翻译层没把 Claude thinking 转 K3 原生 reasoning → k3 只浅答不深思考。非 omniroute 透传错 (200 正常)。
- **不自动切模型**: claudecode 失败只重试同一模型 → 每轮卡死直至人工干预。

**2m9s 正常还是异常**: 对 k3 单轮深思考 17-20s 正常; 用在 agent 循环里异常 — 它把 agent 需要的迭代思考误判为单发问答, 每次产出短答断链。

---

## 三、k3 使用建议

1. k3 定位 = **单轮深思考问答** (文档/长文/单点难题); **别当长时 agent loop 主力** (本地编码/多步 shell), 那类换 `deepseek-v4-flash`/`glm-5.2` 等 flash 类。
2. 本会话即 k3 → 切回 flash 模型跑长期 agent 任务。
3. 确认 `STREAM_READINESS_TIMEOUT_MS` 180s 是否被 dev/prod Space env 的 r3 80s 覆盖 (致长思考首 token 竞态超时, 对上"2m 卡死")。
4. 要 k3 真思考: 查 gateway 是否透传 thinking/effort → K3 `X-Kimi-Effort`/max_effort_tokens。

---

关联记忆: `kimi-k3-upstream-bug-verification-2026-09-01`, `k3-autostop-agent-loop-unfit-2026-09-01`。关联决策: ops/DECISIONS.md 2026-09-01 条。关联既有: [[kimi-k3-qwen3.8-max-added-2026-08-02]] [[settings-deny-classifier-stall-fixed]] [[nim-model-pool-7-probe-disable-landed]]。