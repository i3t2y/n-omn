让我先读取这份文档的完整内容，以便做全面总结。

这份文档完整内容已读取。现在我对五个大模型的优化方案做全面总结。

### **结论：五个大模型对 v4.2.3 脚本的修正和优化，在六项核心问题上达成了普遍共识，在三项关键问题上存在分歧。共识部分可信度高（多模型交叉印证），分歧部分需要实测决断。最稳妥的落地路径是以 Claude-Sonnet-4.6 的完整四文件为骨架，吸收 GPT-5.6 的运行时正确性修正（前缀判断、进程监督、失败判定）和 GLM-5.2 的 Resilience 分层，同时对所有基于文档推断的 API 字段先行实测验证**

---

## 一、五个模型的定位与交付形态

文档汇集了五个大模型对同一份 v4.2.3 脚本的独立审查，每个模型的定位和交付形态差异显著：

| 模型 | 核心定位 | 交付形态 | 改动范围 |
|------|---------|---------|---------|
| Claude-Sonnet-5 | 验证既有判断成立，只做局部补丁 | 4 处针对性代码片段 | 最克制 |
| Claude-Opus-4.8 | 用官方 API 落地，"不猜数据库" | 片段 + 优先级表 | 中等，方向性修正 |
| Claude-Sonnet-4.6 | 全量重构升级 v4.3.0 | 完整可替换文件（4 个） | 最大 |
| GPT-5.6 Sol | 运行时可靠性优先 | 大量分点片段 | 广而深 |
| GLM-5.2 | Resilience 分层 + 原生路由 | 分点片段 + 优先级表 | 聚焦特定盲点 |

Sonnet-4.6 是唯一给出完整可直接替换的四个文件（init 脚本、entrypoint、gate.js、litestream.yml）加环境变量速查表的方案，落地性最强。GPT-5.6 覆盖面最广且最深入运行时正确性。GLM-5.2 抓住了 Resilience 分层这个别人都忽略的盲点。Opus 提出了"不直接 SQL 写 override、走官方 API"的方向性洞见。Sonnet-5 最克制，明确把"什么不用改"讲清楚。

---

## 二、六项普遍共识（交叉印证，可信度高）

### 共识一——废弃按 Key 数线性扩容，改保守固定整形

五个模型一致认为，当前 `25 key × 35 = 875 RPM` 的线性计算与 NIM 免费层定位严重不匹配。NVIDIA 官方论坛明确不受理个人免费账户提额，40 RPM 是社区公认基线。多 Key 线性放大在实践中反复导致频繁 429、连接冷却和无效重试，而非提升有效吞吐。

建议默认 `28 RPM / 1 并发 / 2200ms 间隔`，仅在 `NIM_SCALE_WITH_KEYS=1` 显式开启时才按 Key 数扩容（且有硬上限 60 RPM / 2 并发）。多 Key 在保守模式下仅做池内轮换，总入口固定限速。

### 共识二——增量模式漏掉新拆分的 nim-stable/nim-fast

当前增量门判断条件 `IN ('nim-pool','nim-codex')` 漏掉了拆分出的 `nim-stable` 和 `nim-fast`，导致它们在旧空间升级后被反复当作 first-init 处理。修正为检查全部四个 combo 名，或用 `LIKE 'nim-%'` 通配。

### 共识三——Gate 收紧为仅放行 /v1 + /healthz

当前 gate.js 的 `app.use('/', createProxyMiddleware(...))` 会将公网所有路径代理到 OmniRoute 内部，暴露 Dashboard、登录端点、配置界面和内部 API。修正为只放行 `/healthz` 和 `/v1/*`，其余一律 404。PSK 鉴权用 `crypto.timingSafeEqual` 做定时安全比较，代理层 `proxyTimeout: 0 / timeout: 0` 兼容 Agent 长连接 SSE。

### 共识四——entrypoint 健康等待改时间戳截止

当前计数器循环 `i=$((i+2))` 在容器调度暂停（cgroup throttle / 宿主机负载）时与真实墙钟时间脱节。改用 `$(date +%s)` 计算绝对截止时刻更可靠。

### 共识五——nim-codex 用 priority 而非 round-robin

编程主会话不适合每轮切换模型，`nim-codex` 应从 `round-robin` 改为 `priority`，保持模型风格和缓存命中的一致性。

### 共识六——Dockerfile 钉死 3.8.43 并保留 Turbopack 逃生阀

3.8.45+ 存在真实的 Turbopack 构建缺陷（Issue #6498、#6555），`/health` 正常但真实路由永久挂起。官方临时修复正是脚本已设的 `OMNIROUTE_USE_TURBOPACK=0`。`3.8.43@sha256:` digest 双写锁定是正确且必要的防御。

---

## 三、三项关键分歧（需实测决断）

### 分歧一——Context Override 的写入方式

这是最大的方向性分歧，三个模型给出了三种方案：

| 模型 | 方案 | 理由 |
|------|------|------|
| Claude-Opus-4.8 | 走 `/api/provider-models` PATCH | 直接 SQL 写表绕过官方写入路径，migration 调整表结构会静默失配 |
| Claude-Sonnet-4.6 / GLM-5.2 | 直接 SQL 写 `model_context_overrides` | 简单直接，已有验证 |
| Claude-Sonnet-5 | 观测回写但默认关闭（`NIM_ALLOW_MONITOR_OVERRIDE=0`） | 手动 case 分支值比 90% 安全裕量更优 |

Opus 的理由最有说服力——migration 结构漂移风险是真实的（脚本已为 migration 117 做过防御）。但 `/api/provider-models` 是否真接受 `contextLength` 字段、PATCH 语义如何，本轮查证未能拿到完整 Schema。最终方案综合了两者——优先走 API，读回验证失败时降级到 SQL 兜底。

### 分歧二——模型前缀判断逻辑

多数模型用 `case nvidia/*` 判断是否已带前缀，但 GPT-5.6 提出关键修正——NVIDIA 自家模型本身含命名空间（如 `nvidia/nemotron-3-super-120b-a12b`），简单 `nvidia/*` 会把它误当成"已加过路由前缀"，导致不再补前缀。真正的路由前缀形如 `nvidia/nvidia/nemotron-...`（第一个是 Provider 前缀，第二个是 catalog 命名空间）。

GPT-5.6 的判断更准确——应检查是否已是三段式 `nvidia/*/*`：

```bash
nim_route_model() {
  case "$1" in
    nvidia/*/*) printf '%s' "$1" ;;
    *)          printf 'nvidia/%s' "$1" ;;
  esac
}
```

### 分歧三——上下文长度是否统一 32768

Sonnet-4.6 对所有模型统一写 32768 硬编码，GPT-5.6 和 GLM-5.2 都指出应按模型分档——不同模型的实际上下文窗口差异很大，统一值既浪费大窗口模型的空间，又可能超出小窗口模型的真实限制。

---

## 四、各模型的独有价值贡献

### GPT-5.6 的五个独到发现

GPT-5.6 是覆盖面最广且最深入运行时正确性的方案，五个独到发现都是其他模型遗漏的：

**发现一——Litestream restore 日志语义误导**。`-if-replica-exists` 加上后，无论"本地库已存在"还是"远端无副本"都可能打印 `restore complete`，掩盖了实际未恢复的情况。应显式区分本地库存在、远端有副本恢复成功、远端无副本三种状态。

**发现二——Gate 成为 PID 1 后 OmniRoute 崩溃不会触发容器重启**。`exec node /gate/gate.js` 让 Gate 取代 shell 成为 PID 1，此后 OmniRoute 崩溃只会让 `/healthz` 返回 503，但容器不会退出。HF Space 没有 orchestrator 主动重启策略，需要增加后台看门狗，核心进程死亡时主动终止容器。

**发现三——前缀判断应为 `nvidia/*/*`**。这是对其他所有答案 `nim_route_model()` 的实质性修正，NVIDIA 命名空间自身模型会被简单 `nvidia/*` 判断误处理。

**发现四——探针不应把所有非 200 当坏模型**。`429`（限流）、`5xx`（上游临时异常）、`000`（网络超时）都不应标记为模型不可用，只有 `400/404/410/422` 这类模型级错误才记为候选。

**发现五——累积器把所有 5xx 当上下文失败不可靠**。5xx 可能是上游容量、冷启动、网关或网络故障，会污染 `first_failure_tokens` 并错误压低推荐值。应只把 `413`（以及带 context/token/length 错误文本的 400/422）计为上下文边界。

### GLM-5.2 的两个独有发现

**发现一——Resilience 只配了 requestQueue，遗漏 providerBreaker 和 connectionCooldown 两层**。OmniRoute 的 Resilience 是五层体系（Request Queue、Connection Cooldown、Provider Breaker、Wait For Cooldown、Rate-Limit Auto-Detection），脚本只 PATCH 了第一层。针对 NIM 免费 Key，`failureThreshold=3`（比默认 5 更快隔离失效 Key）、`resetTimeoutMs=15000`、开启 `useUpstreamRetryHints`（尊重 429 的 `Retry-After`）。

**发现二——context_accumulator_update 中的 SQL 注入面**。`_input_col` 列名直接拼接进 SQL，虽然来自 `PRAGMA table_info` 探测，但仍建议白名单校验，不做裸拼接。

### Claude-Opus-4.8 的方向性洞见

**不要直接 SQL 写 `model_context_overrides`，应走 `/api/provider-models` API**——理由是 migration 结构漂移会导致静默失配。此外还覆盖了其他模型较少涉及的角度：`/v1/search` 搜索能力落地、Wildcard 别名 + 全局 Fallback 链、Tool Search 缺陷（Issue #2766 / #3974 导致 400）。

### Claude-Sonnet-5 的克制价值

唯一明确把"查证确认了什么、因此不需要改什么"讲清楚——Turbopack 缺陷、Context Relay 仅限 Codex、combo 策略枚举三项此前判断均通过官方 Issue、Features 文档和 Docker Hub 页面交叉验证，方向不需要调整。`NIM_ALLOW_MONITOR_OVERRIDE` 默认关闭保持行为不变的设计很稳妥。

### Claude-Sonnet-4.6 的完整交付

唯一给出完整可直接替换的四个文件，变更概要 [A]–[J] 编号清晰，继承关系交代完整。虽然"查证"成分相对薄弱（更像工程落地而非验证），且保留了直接 SQL 写 override 和统一 32768 硬编码两个被其他模型指出的弱点，但作为落地骨架最为实用。

---

## 五、综合查证结论与三项仍需实测的验证点

### 七类需要落地的局部修补

文档最终收敛出七类不推翻既有架构决策的局部修补：

1. **恢复语义与进程监督**——Litestream restore 语义修正 + 进程看门狗
2. **Gate 暴露面**——白名单收紧 + 定时安全比较 + 流式友好
3. **限流/重试计算**——保守整形 + requestRetry 降为 1
4. **模型前缀识别**——`nvidia/*/*` 判断修正
5. **增量初始化短路**——消除过早退出 + 补齐四 combo 判断
6. **Resilience 多层配置**——补 providerBreaker + connectionCooldown
7. **上下文统计误判防护**——只认 413 + 复合游标 + 白名单校验

### 三项仍需实测验证

文档明确标注了三处"文档或社区讨论支持但未被官方结构化文档完全确认"的验证点，脚本已做防御性降级处理，但不能替代实际环境中的一次性验证：

**验证点一**——`/api/provider-models` 的 PATCH 是否真的接受 `contextLength` 字段并生效。脚本已内置读回校验和 SQL 降级，但需确认哪条路径实际生效。

**验证点二**——`nvidia/*/*` 的前缀判断逻辑。需对照实际启用的模型清单跑一遍 `nim_route_model` 输出，确认没有模型被错误处理。

**验证点三**——`apply_resilience` 中 `providerBreaker` 与 `connectionCooldown` 的字段名和 `/api/settings/resilience` 端点是否被 3.8.43 接受。脚本已内置 PUT 后读回打印，需核对返回体是否真的写入了这两层。

### 推荐的落地策略

最稳妥的做法是以 Sonnet-4.6 的完整文件为骨架，吸收 GPT-5.6 的正确性修正（前缀判断与进程监督）和 GLM 的 Resilience 分层，并对所有基于文档推断的 API 字段先行实测。这个策略的核心逻辑是——跨答案在这些 API 细节上并未完全一致，GPT-5.6 和 Opus 明确要求"PATCH 后读回验证、不要盲信文档猜测"的态度在准确性上最可取。

*内容由 AI 生成仅供参考*