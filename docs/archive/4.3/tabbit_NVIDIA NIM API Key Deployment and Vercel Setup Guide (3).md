### **重新研读三份长文件后，最强方案应以“锁定 3.8.43、原生 NIM 直连、彻底移除 Relay、保守共享限流、严格 Gate、进程监督、幂等收敛”为主线；搜索和部分管理 API 因 3.8.43 精确写入契约未完全确认，应采用“检测与验证优先”，不能再凭主分支文档写死。**

我重新读取了三个文件的相关后半部分、跨模型比较、最终方案和完整脚本段落。它们不是完全一致的提案，而是多轮迭代材料，其中既有已形成共识的修正，也有互相冲突、尚未实测的推断。最合理的做法不是照抄最后出现的代码，而是按证据强弱重新合并。

### **一、重新确定脚本边界**

新脚本不再承担外部 Vercel、Deno、Cloudflare Relay 的部署或接入。三份材料中真正稳定的 v4.3 主线已经明确执行了：

```bash
export ONEPROXY_ENABLED=false
export ENABLE_SOCKS5_PROXY=false
export NEXT_PUBLIC_ENABLE_SOCKS5_PROXY=false
unset HTTP_PROXY HTTPS_PROXY ALL_PROXY
unset OMNIROUTE_RELAY_BACKEND BIFROST_BASE_URL
```

同时还包含删除历史 `127.0.0.1:20129` 代理注册和 NVIDIA 连接代理分配的清理逻辑。这说明稳定架构的目标不是“接入三个 Relay”，而是：

```text
Agent
  → Gate
  → OmniRoute 3.8.43
  → 原生 NVIDIA Provider
  → NVIDIA NIM 官方端点
```

因此，最终脚本应明确删除：

- `RELAY_URL_VERCEL`、`RELAY_URL_DENO`、`RELAY_URL_CF`；
- `RELAY_AUTH_SECRET`；
- OpenAI-Compatible 身份替换；
- `x-relay-target`、`x-relay-path`、`x-relay-auth` 注入；
- 三节点 Relay Combo；
- OmniRoute 后台的一键 Relay 部署；
- 任何“3 × 25 节点矩阵”的说法。

原有 25 个 `nvapi-*` Key 继续注册在原生 NVIDIA Provider 下。多 Key 只用于连接健康回退和池内轮换，不再被描述为可线性扩容的吞吐资源。

### **二、版本锁定策略**

三份文件对锁定 **3.8.43** 基本达成一致。最终应继续采用镜像标签和 Digest 双锁：

```dockerfile
FROM diegosouzapw/omniroute:3.8.43@sha256:517c160643c56ad72e3e305458d961c9a4c87f711393c13020450f9f088d1570
```

并保留：

```dockerfile
ENV OMNIROUTE_USE_TURBOPACK=0
```

这里需要修正措辞：可以说 3.8.43 是你已经验证的部署基线，也有后续版本真实路由挂起的相关报告；但不应把“所有 3.8.45+ 必然损坏”写成绝对事实。版本护栏应支持两种模式：

- 默认发现版本不符时记录严重错误；
- `STRICT_VERSION_LOCK=1` 时直接退出，阻止静默漂移。

仅依赖健康接口返回 200 不够。启动验证应至少检查：

1. 进程还活着；
2. `/api/monitoring/health` 可用；
3. `/v1/models` 能在限定时间内响应；
4. 返回版本与 3.8.43 一致。

这样能捕获“健康接口正常，但真实路由挂起”的情况。

### **三、25 个 Key 的正确治理方式**

多模型答案中最稳定的共识，是废弃：

```bash
RPM = Key 数 × 每 Key RPM
并发 = Key 数 × 每 Key并发
```

因为多个 Key 是否拥有完全独立额度并未被可靠证明，免费 NIM 也不应被当作横向扩容集群。最终默认值应采用共享安全预算：

| 参数 | 建议默认值 | 目的 |
|---|---:|---|
| 总 RPM | 28 | 为重试、探测和波动预留余量 |
| 最大并发 | 1 | 防止流式请求叠加触发 429 |
| 最小间隔 | 2200 ms | 对总入口平滑整形 |
| 请求重试 | 1 | 避免 Combo 回退与内部重试乘法放大 |
| 按 Key 扩容 | 默认关闭 | 仅适用于已确认的商业或自托管额度 |

即：

```bash
NIM_SCALE_WITH_KEYS=0
NIM_RPM_CAP=28
NIM_CONCURRENCY_CAP=1
NIM_MIN_INTERVAL_MS=2200
REQUEST_RETRY=1
```

即使将来允许显式扩容，也必须有硬上限，例如 60 RPM、并发 2，而不是此前某些草案中的 300 RPM、每 Key 并发 3。

Key 输入还应先规范化：

- 删除 CRLF；
- 去掉首尾空白；
- 删除空行；
- 去重；
- 只在内存或受限临时文件中处理；
- 日志只显示序号和掩码；
- 不能进入 HF Dataset 快照；
- 同名连接存在时执行更新，而非只把 409 当作成功。

### **四、模型 ID 前缀的关键修正**

这是多模型比较中最有价值的纠错之一。

NIM Catalog 裸模型名可能是：

```text
deepseek-ai/deepseek-v4-pro
nvidia/nemotron-3-super-120b-a12b
```

第二个名字中的 `nvidia/` 是模型发布者命名空间，不是 OmniRoute Provider 路由前缀。真正路由后的名称分别是：

```text
nvidia/deepseek-ai/deepseek-v4-pro
nvidia/nvidia/nemotron-3-super-120b-a12b
```

所以不能使用简单的：

```bash
case "$model" in nvidia/*) ...
```

否则会把 NVIDIA 自家模型误判成已带路由前缀。最终函数应按三段结构识别：

```bash
nim_route_model() {
  case "$1" in
    nvidia/*/*) printf '%s' "$1" ;;
    *)          printf 'nvidia/%s' "$1" ;;
  esac
}
```

同时需要保持一个明确的单一事实源：

- 模型数组始终保存 **NIM Catalog 原始 ID**；
- 只有生成 Combo、调用 OmniRoute 模型接口和建立映射时才调用 `nim_route_model`；
- Catalog 查询继续使用原始 ID；
- Provider 模型元数据所需键名先从实际接口读回，不凭猜测决定使用原始 ID 还是路由 ID。

此前部分完整脚本中复杂的“计算斜杠数量”实现可用，但可读性较差；上述三段式判断更直接。

### **五、模型池不应追求“大而全”**

三份材料中列出的部分 2026 模型名称属于快速变化信息。最终脚本不应把它们全部视为长期可靠常量，更不应默认注册重型或受限模型。

建议保留四个逻辑入口，但每组都必须先经过 Catalog 存活过滤：

| Combo | 策略 | 定位 |
|---|---|---|
| `nim-stable` | `priority` | 主 Agent、长会话、复杂任务 |
| `nim-fast` | `priority` 或小规模 `round-robin` | 查询改写、分类、短摘要 |
| `nim-pool` | `p2c` | 无状态短任务 |
| `nim-codex` | `priority` | 代码生成及工具调用 |

这里我建议比旧方案再保守一步：

- `nim-stable` 默认只放 2～3 个已验证模型；
- `nim-fast` 默认也只放 2～3 个；
- `balanced` 不加入 `TIER_RESTRICTED`；
- `full` 仅用于人工评测；
- 不使用 `fusion` 作为日常策略；
- 不使用内部 `quota-share`；
- `nim-codex` 不使用 `context-relay`，也不使用每轮换模型的 `round-robin`。

必须明确：**Context Relay 目前文档确认的是 Codex 账号轮换支持，不能据此推导 NIM API Key 池具有无缝上下文接力。** 因此 NIM 池一律按无状态上游处理；长期记忆由 Agent 或记忆层显式保存。

### **六、Catalog 检测与探针**

稳定脚本应该保留 Catalog 检测，但必须改成多 Key 回退和 fail-open：

1. 按顺序尝试经过规范化的 Key；
2. 每次请求设置连接和总超时；
3. 只有拿到结构正确且模型数量达到可信阈值的响应，才用于过滤；
4. 所有 Key 都失败时，跳过过滤，不能把全部模型标为废弃；
5. Catalog 只证明模型出现在目录中，不证明当前模型一定可调用。

模型探针应默认关闭：

```bash
NIM_PROBE=0
NIM_PROBE_MAX_MODELS=2
NIM_PROBE_MIN_INTERVAL_SECONDS=21600
```

即使手动启用，也只探测实际池里的少数模型，并区分错误类别：

- `400/404/410/422` 且响应明确表示模型无效：候选不可用；
- `401/403`：Key 或权限问题，不能判模型下线；
- `429`：限速，不判模型坏；
- `5xx`、网络错误、超时：临时故障，不判模型坏；
- 只有用户请求和多轮健康统计都指向同一问题时，才持久化为不可用。

旧方案把探针结果写入 `/tmp`，重启即失效；新方案如需冷却时间，应将“最后探测时间”放到 `/data`，但不要长期保存瞬时故障为永久黑名单。

### **七、Resilience：方向正确，但不能猜 v3.8.43 Schema**

多模型意见中，补齐 Request Queue、Connection Cooldown、Provider Breaker、Wait For Cooldown 的方向是正确的。不过三份材料对接口路径和请求体并不一致：

```text
/api/resilience
/api/settings/resilience
PUT
PATCH
不同字段名
```

这说明不能把任何一个草案直接称为 3.8.43 稳定契约。

最终脚本应采用“能力发现 + 写入 + 读回 + 降级”：

1. 先 GET 候选端点；
2. 只对返回 2xx 且结构符合预期的端点写入；
3. 写入后再次 GET；
4. 检查目标字段实际出现且数值正确；
5. 不支持的层只记录 `unsupported`，不直接操作 SQLite；
6. Request Queue 若已在你的 3.8.43 实例实测成功，可继续应用；
7. 未经实测的 Breaker/Cooldown 配置放在显式开关后。

建议状态：

```bash
NIM_ENABLE_EXTENDED_RESILIENCE=0
```

在确认实例契约后才设为 `1`。这比把推断字段硬写进所谓“最强脚本”更可靠。

### **八、首次与增量初始化必须改为同一套幂等收敛流程**

旧脚本一个重要缺陷是增量分支过早 `exit 0`，导致后续修改的限流、Combo、Provider、Context 配置无法重新应用。

最终应拆成两个阶段。

#### **每次启动都执行**

- 输入校验与 Key 规范化；
- 登录并获取管理会话；
- 版本和 API 契约检测；
- 原生 NVIDIA 连接 upsert；
- Catalog 多 Key 回退检测；
- Resilience/Settings 写入及读回；
- 四个 Combo upsert；
- 模型映射 upsert（仅在契约已确认时）；
- 搜索就绪检测；
- 清理过期冷却状态；
- 输出脱敏诊断。

#### **仅首次执行**

- 建立内部 API Key；
- 必要的初始全量模型注册；
- 初始化标记；
- 需要一次执行的数据迁移。

增量判断不应只检查 `nim-pool` 和 `nim-codex`。优先信任 `/data/.init-done`，数据库检查使用：

```sql
SELECT COUNT(*) FROM combos WHERE name LIKE 'nim-%';
```

但即使进入增量模式，也不能跳过 upsert 收敛流程。

### **九、Context 管理应默认只观测，不自动回写**

这是三份材料分歧最大的部分：

- 一种意见直接写 `model_context_overrides`；
- 一种意见调用 `/api/provider-models`；
- 一种意见高置信度后自动应用；
- 还有草案在 API 失败后自动回退 SQL。

最安全的结论是：**稳定版默认不自动写 Context Override。**

原因有三：

1. `/api/provider-models` 的 `PATCH` 请求体和 `contextLength` 字段在材料中未获得完整 3.8.43 Schema；
2. 直接 SQL 会耦合内部表结构和 migration；
3. Context 观测容易被 429、5xx、流式统计缺失和客户端断连污染。

最终建议：

```bash
NIM_CONTEXT_OBSERVE=1
NIM_CONTEXT_AUTO_APPLY=0
```

观测规则只接受：

- 2xx 且有可靠输入 Token 统计：更新最大成功值；
- HTTP 413：可作为明确失败边界；
- 400/422 且错误文本明确包含 context/token/length exceeded：可作为失败边界；
- 429、401、403、5xx、网络失败、输出为 0：不用于推导上下文边界。

输出推荐值和置信度，但不自动写库。等你在 3.8.43 实例捕获并确认 `/api/provider-models` 的真实契约后，再增加显式开关启用 API 写回；不提供自动 SQL 降级。

### **十、Gate 是最高优先级安全修正**

三个文件对这一点高度一致：外网只能看到 `/healthz`、`/v1` 和 `/v1/*`，其余一律 404。

最终 Gate 应包括：

- `INTERNAL_PSK` 必填；
- 使用 `crypto.timingSafeEqual` 比较密钥；
- 外部 PSK 替换为内部 OmniRoute API Key；
- `/healthz` 对内部 OmniRoute 健康接口设置 2～3 秒超时；
- `proxyTimeout: 0` 和 `timeout: 0` 支持长时间流式响应；
- `xfwd: false`，减少不必要的转发信息；
- 请求体上限；
- 非 `/v1` 路径拒绝；
- `/v1/search/analytics` 可选单独拒绝；
- 不开放 Dashboard、登录端点、管理 API、MCP 管理路径。

路径判断必须写成：

```js
req.path === '/v1' || req.path.startsWith('/v1/')
```

不能只写 `startsWith('/v1')`，否则 `/v123` 也会通过。

反向代理建议挂载在 `/`，保留原始路径；不要依赖不同版本中 `app.use('/v1', ...)` 是否剥离前缀，再用 `pathRewrite` 猜测补回。这样可以消除 `/v1/v1` 风险。

### **十一、entrypoint 必须成为真正的 Supervisor**

旧设计让 Gate `exec` 成 PID 1，而 OmniRoute 在后台运行；后端崩溃后 Gate 仍可能存活，容器不会自然退出。最终 entrypoint 应监督：

- OmniRoute：核心，退出即容器失败；
- Gate：核心，退出即容器失败；
- 初始化任务：首次初始化失败应影响启动；增量维护失败可告警；
- Litestream：重要但非核心，退出时告警并可有限重启。

首次初始化建议同步执行，不应后台启动后马上对外宣布可用。合理顺序是：

```text
恢复数据库
→ 启动 OmniRoute
→ 等待真实健康
→ 校验版本及 /v1/models
→ 同步完成首次初始化
→ 获得内部 API Key
→ 启动 Gate
→ 启动 Litestream replicate
→ 进入监督循环
```

增量初始化可以在 Gate 启动前同步运行；若担心启动延迟，可提供：

```bash
INIT_FAILURE_MODE=strict|warn
```

默认 `strict` 更适合当前“配置正确优先”的目标。

### **十二、Litestream 的最终策略**

应保留 R2 备份，但修复恢复语义：

- 本地数据库存在且非空：不恢复；
- 本地数据库不存在时才执行 `restore -if-replica-exists`；
- 恢复后检查文件是否存在、非空；
- 可用 `sqlite3 PRAGMA quick_check` 验证；
- 恢复失败是否继续启动由显式策略控制；
- Litestream 复制启动后纳入监督；
- 定期做独立目录恢复演练，而不是只看“replica sync”日志。

`auto-recover` 不是无风险功能。开启它意味着可用性优先，但可能牺牲重置前的时间点恢复历史。最终可默认关闭，或保留为：

```bash
LITESTREAM_AUTO_RECOVER=0
```

脱敏 HF Dataset 快照只能用于审计和配置参考，不能替代 SQLite/R2 灾备；绝不能包含 NIM Key、内部 API Key、Cookie、Authorization、搜索凭据和调试响应体中的秘密。

### **十三、搜索应纳入“检测”，暂不纳入“猜测式自动配置”**

三份材料一致认为 3.8.43 具备 `/v1/search`、`/v1/rerank`、`/v1/embeddings`；但对于搜索 Provider 的配置接口却出现至少三种互相冲突的写法：

```text
PATCH /api/settings
POST /api/providers
POST /api/search/providers
```

Provider ID 也有：

```text
tavily
tavily-search
brave
brave-search
```

因此最终稳定脚本不能自动猜测。第一版应做到：

- Gate 保留 `/v1/search`、`/v1/rerank`、`/v1/embeddings`；
- `GET /v1/search` 做就绪检测；
- 若无 Provider，明确打印待配置警告；
- `ENABLE_TOOL_SEARCH=false` 默认关闭透明工具搜索；
- Agent 使用显式 `/v1/search`，不要依赖模型原生 `tool_search` 转译；
- 搜索凭据只存在平台 Secret；
- 不直接写 SQLite；
- 待你从 3.8.43 Dashboard 捕获一次真实网络请求，确认接口和请求体后，再加入幂等自动配置模块。

这比先前直接写 `PATCH /api/settings` 或 `POST /api/search/providers` 更稳健。

### **十四、最终要交付的不是一个文件，而是五个协同文件**

你认可方案后，完整版本应包含：

| 文件 | 责任 |
|---|---|
| `Dockerfile` | 3.8.43 Digest 锁定、依赖安装、健康检查 |
| `entrypoint.sh` | 恢复、启动、初始化、进程监督 |
| `init-nim-keys.sh` | Key/Provider/Combo/限流幂等收敛 |
| `gate.js` | 最小暴露面、PSK、流式代理 |
| `litestream.yml` | SQLite 到 R2 的复制与保留策略 |

此外还应附：

- `.env.example`，只列变量名和说明，不含值；
- `verify.sh`，执行部署后验收；
- 迁移前备份与回滚步骤；
- 变更日志；
- “已验证契约”和“默认关闭的实验能力”清单。

### **建议采用的最终默认值**

| 能力 | 默认决策 |
|---|---|
| 外部 Relay | 完全禁用并清理历史配置 |
| OmniRoute 版本 | 锁死 3.8.43 Tag + Digest |
| NIM 总 RPM | 28 |
| NIM 总并发 | 1 |
| 最小间隔 | 2200 ms |
| 请求重试 | 1 |
| 按 Key 扩容 | 关闭 |
| Combo | stable / fast / pool / codex |
| Context Relay 用于 NIM | 不使用 |
| Context 自动回写 | 关闭，只观测 |
| 模型探针 | 默认关闭 |
| Extended Resilience | 默认关闭，契约确认后开启 |
| Search 自动配置 | 暂不写入，只检测 |
| Tool Search 透明转换 | 关闭 |
| Gate | 仅 `/healthz` 与 `/v1[/...]` |
| 首次初始化 | 同步、失败即退出 |
| Litestream | 本地库缺失时才恢复 |
| Debug 日志上传 | 默认关闭 |

这份论述与此前错误的“Relay 三节点版”有根本区别：它只吸收三个长文件中被多模型交叉确认的内容；对存在冲突的 API 契约不强行裁决，而是通过默认关闭、能力探测和读回验证控制风险。

I'll read the sync tutorial and verify a few still-open technical facts before finalizing.

I found the official Resilience guide — let me fetch it to lock down the exact field names, which was one of the open verification points.

### **本轮查证有一个决定性发现,会直接推翻此前脚本里对 Resilience 的字段假设:官方 `RESILIENCE_GUIDE.md`(v3.8.40,与 3.8.43 同族)证明 OmniRoute 的韧性体系不是此前草案假设的 `requestQueue / providerBreaker / connectionCooldown` 三个可 PATCH 字段,而是「Provider 熔断 + Connection 冷却 + Model Lockout + Quota-Share 并发」四套机制,其中熔断和冷却的默认阈值是内置常量、按 OAuth/API-key/Local 分档,且明确不对 429 熔断。因此\"补全 providerBreaker/connectionCooldown 两层\"这个 GLM-5.2 的建议方向虽对,但字段名是错的,应改为按官方真实 Schema 配置,并把大部分韧性逻辑交回 OmniRoute 内置默认值。**

我已重新读取三份长文件的关键区段、五模型综述教程,并抓取了官方 Resilience 文档原文核对。下面把**必须修正的部分**与**维持不变的共识**分开说明,最后给出可直接替换的关键脚本段。

### **一、颠覆性修正:Resilience 的真实契约(必须改)**

官方文档明确了三层机制的真实实现,与此前 `apply_resilience()` 里 `jq -n '{requestQueue:..., providerBreaker:..., connectionCooldown:...}'` 的猜测结构**完全不同**:

| 机制 | 真实作用域 | 真实默认值(内置常量) | 触发码 |
|---|---|---|---|
| Provider Circuit Breaker | 整个 provider | API-key 档:7 次降级 / 12 次熔断 / 30s 重置 | **仅** `[408,500,502,503,504]`,**不含 429** |
| Connection Cooldown | 单个连接/Key | API-key base 3s;429 优先读 `Retry-After`;退避 `base × 2^failureIndex` | 账号级错误(含 429) |
| Model Lockout | provider+连接+模型 | 默认 `enabled:false`;`errorCodes:[403,404,429,502,503,504]`;`baseCooldownMs:120000`;`maxCooldownMs:1800000`;`maxBackoffSteps:10` | 模型级失败 |
| Quota-Share 并发 | 共享账号 | `max_concurrent` 每连接申明;`comboCooldownWait{maxWaitMs:5000,maxAttempts:2,budgetMs:8000}` | 并发超限 |

这带来四个直接结论,替换掉之前的错误设计:

首先,**熔断与冷却的阈值是内置常量,通过 Dashboard → Settings → Resilience 暴露,并非一个你可以随意 PATCH 任意字段的开放端点**。此前脚本里 `PUT /api/settings/resilience` 传 `providerBreaker:{failureThreshold:3,...}` 很可能被忽略或报错。真正稳妥的做法是:**默认完全依赖 OmniRoute 内置的 API-key 档阈值(7/12/30s),不再自造字段**;只有 `POST /api/resilience/reset` 和 `GET/DELETE /api/resilience/model-cooldowns` 是文档确认的稳定管理端点。

其次,官方熔断**明确不对 401/403/429 触发**,这从上游反向验证了此前\"把 429 排除出失败统计\"的决策是对的——但同时说明,想靠\"`failureThreshold=3` 快速隔离失效 Key\"来处理 429 是**南辕北辙**:429 归 Connection Cooldown 管,不归熔断管。因此 GLM-5.2 那段 `providerBreaker:{failureThreshold:3}` 应删除。

第三,真正能对齐\"NIM 免费 Key 易 429\"场景的官方旋钮其实是 **`max_concurrent`(每连接并发上限)+ Model Lockout 的 `enabled:true`**。对 25 个共享账号语义的 NIM Key,应在连接上申明 `max_concurrent`(保守取 1),让 Quota-Share 的 per-connection 信号量去串行化,而不是自己在脚本里堆一套熔断参数。

第四,**Model Lockout 状态是 in-memory、重启即丢**,只有 settings 持久化。所以不能依赖它跨重启记忆坏模型——这与你脚本里\"探针结果写 `/tmp` 重启失效\"的老问题同源,进一步印证探针默认关闭、以真实请求成功率为准的方向。

### **二、维持不变的六项共识(已交叉验证,无需再改)**

以下经官方文档与三文件交叉印证,保持此前结论:锁定 `3.8.43@sha256` 双写 + `OMNIROUTE_USE_TURBOPACK=0`;废弃 Key 线性扩容、默认 `28 RPM / 1 并发 / 2200ms`;Gate 白名单仅放行 `/healthz` 与 `/v1[/...]`、PSK 用 `timingSafeEqual`;健康等待改时间戳截止;`nim-codex` 用 `priority`;彻底移除所有 Relay 逻辑。路由策略枚举也更新为 **18 种**(新增 `pipeline`),你脚本白名单可补上它。

### **三、三项仍需实测项的最新状态**

`/api/provider-models` 的 `contextLength` 字段仍未在官方结构化文档中确认(npm 已到 3.8.46,但 wiki 未给 PATCH body),**维持\"优先 API、读回验证、失败不自动降级 SQL、默认 `NIM_CONTEXT_AUTO_APPLY=0`\"**。`nvidia/*/*` 三段式前缀判断逻辑正确,保留。Resilience 字段现在**从\"待实测\"升级为\"已证伪\"**——不要再 PATCH 自造字段,改用下方修正版。

### **四、修正后的关键脚本段(替换 `apply_resilience` 与限流)**

```bash
# ══ 【修正·Resilience】不再 PATCH 自造字段;对齐官方真实机制 ══
# 依据 RESILIENCE_GUIDE.md(v3.8.40):熔断/冷却阈值为内置常量,按 API-key 档
# (7 降级 / 12 熔断 / 30s 重置)自动生效,熔断不对 429 触发。
# NIM 多 Key 的 429 由 Connection Cooldown(base 3s,尊重 Retry-After)+ 
# Quota-Share 并发信号量(max_concurrent)处理,而非自造 providerBreaker 字段。
apply_resilience() {
  echo "[init] resilience: 采用 OmniRoute 内置 API-key 档默认值,不 PATCH 自造字段。"

  # (1) 仅在连接上申明 max_concurrent,交给 Quota-Share 信号量串行化(唯一真实有效的并发闸)
  #     NIM 免费账号保守取 1;需先确认你的实例 provider_connections 是否暴露该字段。
  local _mc="${NIM_MAX_CONCURRENT:-1}"

  # (2) 可选启用 Model Lockout(官方默认 enabled:false),用官方真实字段名
  if [ "${NIM_ENABLE_MODEL_LOCKOUT:-0}" = "1" ]; then
    local _body _code F
    _body=$(jq -n '{
      enabled:true,
      errorCodes:[403,404,429,502,503,504],
      baseCooldownMs:120000,
      maxCooldownMs:1800000,
      maxBackoffSteps:10,
      useExponentialBackoff:true
    }')
    F="$(_resp omniroute-model-lockout.json)"
    # 端点/schema 需在你的 3.8.43 实例读回确认;失败仅告警,不写库
    _code=$(curl -s -o "$F" -w "%{http_code}" -b "$COOKIE_FILE" \
      -X PATCH "$BASE_URL/api/settings" \
      -H "Content-Type: application/json" \
      -d "$(jq -n --argjson ml "$_body" '{modelLockout:$ml}')" 2>/dev/null || echo "000")
    echo "[init]   model-lockout PATCH HTTP $_code (需读回验证字段被接受)"
    curl -s -b "$COOKIE_FILE" "$BASE_URL/api/settings" \
      | jq -c '.modelLockout // "unsupported"' 2>/dev/null || true
  fi

  # (3) 请求整形:沿用共识的保守总入口限速(此项在你实例已实测可用则保留)
  local RQ CODE F2
  RQ=$(jq -n --argjson rpm "$_RPM" --argjson conc "$_CONCURRENT" --argjson iv "$_MIN_INTERVAL_MS" \
        '{requestsPerMinute:$rpm, concurrentRequests:$conc, minTimeBetweenRequestsMs:$iv}')
  F2="$(_resp omniroute-reqqueue.json)"
  CODE=$(curl -s -o "$F2" -w "%{http_code}" -b "$COOKIE_FILE" \
    -X PATCH "$BASE_URL/api/resilience" -H "Content-Type: application/json" \
    -d "$(jq -n --argjson rq "$RQ" '{requestQueue:$rq}')" 2>/dev/null || echo "000")
  echo "[init]   requestQueue PATCH HTTP $CODE (PATCH 后必须 GET 读回)"
  curl -s -b "$COOKIE_FILE" "$BASE_URL/api/resilience" | jq -c '.requestQueue // "unsupported"' 2>/dev/null || true
}
```

对应新增环境变量:

| 变量 | 默认值 | 说明 |
|---|---|---|
| `NIM_MAX_CONCURRENT` | `1` | 连接级并发上限,交给 Quota-Share 信号量串行化 |
| `NIM_ENABLE_MODEL_LOCKOUT` | `0` | 是否启用官方 Model Lockout(默认关,与官方一致) |
| ~~`NIM_ENABLE_EXTENDED_RESILIENCE`~~ | 删除 | 原假设的 providerBreaker/connectionCooldown 字段已证伪 |

### **五、下一步**

其余四个文件(`Dockerfile`、`entrypoint.sh`、`gate.js`、`litestream.yml`)的逻辑在本轮查证中**未被推翻**,维持上一版设计(时间戳健康等待、进程看门狗、白名单 Gate、本地库存在才 restore + `PRAGMA quick_check`)。真正需要改的只有 `init-nim-keys.sh` 里的 Resilience 段(上方已给)和策略白名单补 `pipeline`。

由于你最终要的是**可直接替换、可下载的完整五文件脚本集**(涉及文件生成与导出),这类操作我会切换到 Agent 模式来完成,把上述修正整合进完整文件并打包。你确认后我就开始生成——或者你也可以先在 3.8.43 实例上用 `curl` 核对 `/api/resilience` 与 `/api/settings` 对 `requestQueue`、`modelLockout` 的实际接受情况,把读回结果发我,我据此把\"需实测\"标注收敛为\"已确认\"再出最终版。

### **可以在对话模式下完成审查、查证和代码输出；但由于完整脚本约数千行，为避免截断和把未经实例验证的 API 猜测写进生产环境，最新版本应采用“保守稳定核”：彻底移除 Relay、锁死 OmniRoute 3.8.43、固定共享限流、依赖内置 Resilience、关闭自动 Context 回写，并强化 Gate、进程监督和 Litestream 恢复。**

本轮结合已有三份资料、五模型交叉审查及最新官方文档后，最重要的修正是：**不能再使用先前猜测的 `providerBreaker`、`connectionCooldown` JSON 结构，也不应自动调用未经 3.8.43 实例验证的 Context PATCH 接口。**

### **一、最终采用的稳定基线**

| 项目 | 最新决定 | 默认值 |
|---|---|---|
| OmniRoute | Tag 与 Digest 双锁 | `3.8.43` |
| Relay | 完全删除 | 不配置 |
| NIM 总入口预算 | 不按 Key 数线性放大 | 28 RPM |
| 并发 | 单并发 | 1 |
| 请求间隔 | 固定保守间隔 | 2200 ms |
| Key 用途 | 冗余与健康轮换 | 不作为吞吐倍增器 |
| Context Override | 只观察，不自动写 | 关闭 |
| 扩展 Resilience PATCH | 删除猜测字段 | 依赖内置机制 |
| Model Lockout | 不猜 API 写法 | 默认关闭 |
| Gate | `/healthz`、`/v1`、`/v1/*` | 其他路径 404 |
| 探针 | 默认关闭 | 仅诊断使用 |
| Combo | stable/codex 用 priority | 避免会话漂移 |
| Litestream | 本地无库才恢复 | 恢复后 `quick_check` |
| 进程监督 | shell 保持 PID 1 | 任一核心进程退出则容器退出 |

OmniRoute 官方文档将 Provider Circuit Breaker、Connection Cooldown 和 Model Lockout 明确区分。API-key Provider 的熔断默认是 7 次失败进入降级、12 次失败打开、30 秒后尝试恢复；只有 `408/500/502/503/504` 计入 Provider 熔断，`429` 由连接冷却处理。NIM 的多 Key 场景因此应依赖内置连接冷却和 `Retry-After` 处理，而不是在初始化脚本中自造低阈值熔断配置。[OmniRoute Resilience Guide](https://github.com/diegosouzapw/OmniRoute/blob/main/docs/architecture/RESILIENCE_GUIDE.md)

### **二、必须从旧脚本删除的内容**

删除以下全部逻辑：

```text
RELAY_URL_*
RELAY_TOKEN_*
x-relay-*
context-relay 作为 NIM Combo 策略
NIM_ENABLE_EXTENDED_RESILIENCE
providerBreaker JSON
connectionCooldown JSON
按 Key 数自动计算 RPM
自动 SQL 写 model_context_overrides
未经读回验证的 /api/provider-models PATCH
所有模型统一写死 32768 context
```

旧稿中的这类结构不能进入最新脚本：

```bash
{
  requestQueue: ...,
  providerBreaker: ...,
  connectionCooldown: ...
}
```

原因不是 OmniRoute 没有这些机制，而是**现有资料没有证明 3.8.43 接受这套 JSON 契约**。机制存在不代表字段结构和管理端点可以凭名称推断。

同理，也不要使用下面这种“API 失败就自动 SQL 写库”的策略：

```bash
PATCH /api/provider-models || sqlite3 ... INSERT INTO model_context_overrides ...
```

API Schema 与数据库 Migration 都没有在目标实例得到确认。生产脚本应默认只生成 Context 建议报告，不自动改配置。

### **三、限流计算的最终修正版**

```bash
# 固定共享预算。多 Key 默认只提高可用性，不叠加吞吐。
NIM_SHARED_RPM="${NIM_SHARED_RPM:-28}"
NIM_MAX_CONCURRENT="${NIM_MAX_CONCURRENT:-1}"
NIM_MIN_INTERVAL_MS="${NIM_MIN_INTERVAL_MS:-2200}"

validate_positive_int() {
  case "$2" in
    ''|*[!0-9]*|0)
      printf '[init] invalid %s=%s\n' "$1" "$2" >&2
      return 1
      ;;
  esac
}

validate_positive_int NIM_SHARED_RPM "$NIM_SHARED_RPM"
validate_positive_int NIM_MAX_CONCURRENT "$NIM_MAX_CONCURRENT"
validate_positive_int NIM_MIN_INTERVAL_MS "$NIM_MIN_INTERVAL_MS"

_RPM="$NIM_SHARED_RPM"
_CONCURRENT="$NIM_MAX_CONCURRENT"
_MIN_INTERVAL_MS="$NIM_MIN_INTERVAL_MS"

echo "[init] shared NIM budget: ${_RPM} RPM, ${_CONCURRENT} concurrent, ${_MIN_INTERVAL_MS}ms interval"
```

不再保留 `NIM_SCALE_WITH_KEYS`。即使把它默认设为 0，它仍会给以后维护者留下“Key 可线性扩容”的错误暗示。若以后确实需要扩容，应通过隔离环境实测后手动提高固定预算，而不是用 Key 数推导。

### **四、模型 ID 规范化**

应把 Catalog ID 和路由 ID 分开：

- 内部模型清单保存 Catalog ID，例如 `nvidia/nemotron-...`。
- 发给 OmniRoute 时增加 Provider 前缀，变成 `nvidia/nvidia/nemotron-...`。
- 已经是三段式路由 ID 时保持不变。

```bash
nim_route_model() {
  case "$1" in
    nvidia/*/*)
      printf '%s' "$1"
      ;;
    *)
      printf 'nvidia/%s' "$1"
      ;;
  esac
}

models_to_json() {
  local model routed
  for model in "$@"; do
    [ -n "$model" ] || continue
    routed="$(nim_route_model "$model")"
    jq -cn --arg model "$routed" '{model:$model}'
  done | jq -sc '.'
}
```

建议同时加入一次无网络的自检，任何错误都终止初始化：

```bash
assert_model_routing() {
  local got

  got="$(nim_route_model 'meta/llama-3.3-70b-instruct')"
  [ "$got" = 'nvidia/meta/llama-3.3-70b-instruct' ] || return 1

  got="$(nim_route_model 'nvidia/nemotron-3-super-120b-a12b')"
  [ "$got" = 'nvidia/nvidia/nemotron-3-super-120b-a12b' ] || return 1

  got="$(nim_route_model 'nvidia/nvidia/nemotron-3-super-120b-a12b')"
  [ "$got" = 'nvidia/nvidia/nemotron-3-super-120b-a12b' ] || return 1
}

assert_model_routing || {
  echo '[init] FATAL: model routing self-test failed.' >&2
  exit 1
}
```

### **五、Context Override 改成纯观测模式**

最新脚本不应再包含自动 SQL 兜底。建议只输出推荐文件：

```bash
NIM_CONTEXT_AUTO_APPLY="${NIM_CONTEXT_AUTO_APPLY:-0}"

write_context_recommendation() {
  local model="$1"
  local observed="$2"
  local recommended="$3"

  jq -cn \
    --arg model "$model" \
    --argjson observed "$observed" \
    --argjson recommended "$recommended" \
    --arg generated_at "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" \
    '{
      model: $model,
      observedBoundary: $observed,
      recommendedContext: $recommended,
      generatedAt: $generated_at,
      applied: false
    }' >> "$DATA_DIR/context-recommendations.ndjson"
}

if [ "$NIM_CONTEXT_AUTO_APPLY" = "1" ]; then
  echo '[init] WARN: automatic context application is intentionally unavailable in the stable build.'
  echo '[init] Verify the 3.8.43 provider-models API schema before implementing it.'
fi
```

统计上下文失败时，只接受明确证据：

```bash
is_context_boundary_failure() {
  local status="$1"
  local body="$2"

  [ "$status" = "413" ] && return 0

  case "$status" in
    400|422)
      printf '%s' "$body" |
        grep -Eiq '(context|token|sequence|prompt).*(length|limit|maximum|exceed|too[[:space:]-]*long)' &&
        return 0
      ;;
  esac

  return 1
}
```

以下响应均不得压低 Context 推荐值：

- `401/403`：凭据或权限问题；
- `404/410`：模型不存在或下线；
- `429`：速率限制；
- `5xx`：上游容量或服务异常；
- `000`：网络或超时。

### **六、Resilience 最终处理方式**

最新稳定版应删除整段 `apply_resilience()` 猜测性写入，替换为只读诊断：

```bash
report_resilience() {
  local output http_code

  output="$DATA_DIR/resilience-status.json"
  http_code="$(
    curl -sS \
      --connect-timeout 3 \
      --max-time 10 \
      -o "$output" \
      -w '%{http_code}' \
      -b "$COOKIE_FILE" \
      "$BASE_URL/api/monitoring/health" 2>/dev/null ||
      printf '000'
  )"

  case "$http_code" in
    200)
      echo '[init] OmniRoute resilience health is readable.'
      jq -c '.' "$output" 2>/dev/null |
        sed 's/^/[init] resilience: /' || true
      ;;
    *)
      echo "[init] WARN: resilience health read failed, HTTP $http_code."
      ;;
  esac
}
```

Request Queue 如果已经在你的 3.8.43 实例上验证过准确端点和字段，可以保留；如果没有实测，也应采用相同原则：**只读、不猜、不写**。入口固定预算可由 Gate 自己强制执行，这样不依赖内部管理 API。

### **七、Gate 应自行执行共享预算**

仅配置 OmniRoute 内部 Request Queue 不够稳妥，因为其 Schema 未完全锁定。安全代理可直接实施全局节流。下面是 Gate 的关键结构：

```js
'use strict';

const crypto = require('crypto');
const express = require('express');
const { createProxyMiddleware } = require('http-proxy-middleware');

const app = express();

const exposedPort = positiveInt(process.env.EXPOSED_PORT, 7860);
const omniPort = positiveInt(process.env.OMNIROUTE_PORT, 20128);
const rpm = positiveInt(process.env.NIM_SHARED_RPM, 28);
const maxConcurrent = positiveInt(process.env.NIM_MAX_CONCURRENT, 1);
const minIntervalMs = positiveInt(process.env.NIM_MIN_INTERVAL_MS, 2200);

const expectedPSK = process.env.GATE_PSK || '';
const target = `http://127.0.0.1:${omniPort}`;

let active = 0;
let lastStartedAt = 0;
const starts = [];

function positiveInt(value, fallback) {
  const parsed = Number.parseInt(String(value ?? ''), 10);
  return Number.isSafeInteger(parsed) && parsed > 0 ? parsed : fallback;
}

function secureEqual(left, right) {
  const a = Buffer.from(String(left || ''), 'utf8');
  const b = Buffer.from(String(right || ''), 'utf8');

  if (a.length !== b.length || a.length === 0) return false;
  return crypto.timingSafeEqual(a, b);
}

function suppliedKey(req) {
  const authorization = req.get('authorization') || '';
  if (/^Bearer\s+/i.test(authorization)) {
    return authorization.replace(/^Bearer\s+/i, '').trim();
  }
  return (req.get('x-api-key') || '').trim();
}

function authenticate(req, res, next) {
  if (!expectedPSK) {
    return res.status(503).json({ error: 'gateway_not_configured' });
  }

  if (!secureEqual(suppliedKey(req), expectedPSK)) {
    return res.status(401).json({ error: 'unauthorized' });
  }

  next();
}

function admit(req, res, next) {
  const now = Date.now();
  const minuteAgo = now - 60_000;

  while (starts.length && starts[0] <= minuteAgo) starts.shift();

  if (active >= maxConcurrent) {
    res.set('Retry-After', '2');
    return res.status(429).json({ error: 'gateway_concurrency_limit' });
  }

  if (starts.length >= rpm) {
    const retrySeconds = Math.max(
      1,
      Math.ceil((starts[0] + 60_000 - now) / 1000)
    );
    res.set('Retry-After', String(retrySeconds));
    return res.status(429).json({ error: 'gateway_rpm_limit' });
  }

  const elapsed = now - lastStartedAt;
  if (elapsed < minIntervalMs) {
    const retrySeconds = Math.max(
      1,
      Math.ceil((minIntervalMs - elapsed) / 1000)
    );
    res.set('Retry-After', String(retrySeconds));
    return res.status(429).json({ error: 'gateway_pacing_limit' });
  }

  active += 1;
  lastStartedAt = now;
  starts.push(now);

  let released = false;
  const release = () => {
    if (released) return;
    released = true;
    active = Math.max(0, active - 1);
  };

  res.once('finish', release);
  res.once('close', release);
  next();
}

app.disable('x-powered-by');

app.get('/healthz', async (_req, res) => {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), 4000);

  try {
    const upstream = await fetch(
      `${target}/api/monitoring/health`,
      { signal: controller.signal }
    );

    if (!upstream.ok) {
      return res.status(503).json({ status: 'upstream_unhealthy' });
    }

    return res.status(200).json({ status: 'ok' });
  } catch {
    return res.status(503).json({ status: 'upstream_unreachable' });
  } finally {
    clearTimeout(timer);
  }
});

const proxy = createProxyMiddleware({
  target,
  changeOrigin: false,
  xfwd: false,
  ws: false,
  timeout: 0,
  proxyTimeout: 0,
  on: {
    error(_error, _req, res) {
      if (!res.headersSent) {
        res.writeHead(502, { 'content-type': 'application/json' });
      }
      res.end(JSON.stringify({ error: 'upstream_unavailable' }));
    }
  }
});

app.use(/^\/v1(?:\/|$)/, authenticate, admit, proxy);

app.use((_req, res) => {
  res.status(404).json({ error: 'not_found' });
});

app.listen(exposedPort, '0.0.0.0', () => {
  console.log(
    `[gate] listening on ${exposedPort}; target=${target}; ` +
    `rpm=${rpm}; concurrent=${maxConcurrent}; interval=${minIntervalMs}ms`
  );
});
```

这里刻意没有使用 `app.use('/v1', proxy)` 后再做不透明的 `pathRewrite`，从而避免代理库版本差异造成 `/v1` 被剥离或重复。正则挂载的实际转发路径仍应在部署后用 `/v1/models` 验证一次。

需要注意：当前内存限流适合 HF 单容器、单 Gate 进程；若将来改成多实例，它不会在实例间共享计数。

### **八、Entrypoint 的稳定监督结构**

Entrypoint 应保持为 PID 1，显式管理三个子进程，而不是 `exec node gate.js`：

```sh
#!/bin/sh
set -eu

DATA_DIR="${DATA_DIR:-/data}"
DB_PATH="$DATA_DIR/storage.sqlite"
OMNIROUTE_PORT="${OMNIROUTE_PORT:-20128}"
READY_TIMEOUT_SECONDS="${READY_TIMEOUT_SECONDS:-180}"

OR_PID=
GATE_PID=
LS_PID=

mkdir -p "$DATA_DIR"
chmod 700 "$DATA_DIR" 2>/dev/null || true

has_r2_credentials() {
  [ -n "${R2_ACCESS_KEY_ID:-}" ] &&
  [ -n "${R2_SECRET_ACCESS_KEY:-}" ] &&
  [ -n "${R2_ACCOUNT_ID:-}" ] &&
  [ -n "${R2_BUCKET:-}" ]
}

shutdown() {
  trap - INT TERM EXIT

  for pid in "$GATE_PID" "$OR_PID" "$LS_PID"; do
    [ -n "$pid" ] || continue
    kill -TERM "$pid" 2>/dev/null || true
  done

  sleep 3

  for pid in "$GATE_PID" "$OR_PID" "$LS_PID"; do
    [ -n "$pid" ] || continue
    kill -KILL "$pid" 2>/dev/null || true
  done

  wait 2>/dev/null || true
}

trap shutdown INT TERM EXIT

if [ -s "$DB_PATH" ]; then
  echo '[entrypoint] local database exists; restore skipped.'
elif has_r2_credentials; then
  echo '[entrypoint] local database absent; attempting restore.'

  rm -f "$DB_PATH-wal" "$DB_PATH-shm" "$DB_PATH-journal"

  if litestream restore \
      -config /litestream.yml \
      -if-replica-exists \
      "$DB_PATH"; then
    if [ -s "$DB_PATH" ]; then
      check="$(sqlite3 "$DB_PATH" 'PRAGMA quick_check;' 2>/dev/null || true)"
      if [ "$check" != 'ok' ]; then
        echo '[entrypoint] FATAL: restored database failed quick_check.' >&2
        exit 1
      fi
      echo '[entrypoint] database restored and verified.'
    else
      echo '[entrypoint] no remote replica found; OmniRoute will initialize a new database.'
    fi
  else
    echo '[entrypoint] FATAL: Litestream restore failed.' >&2
    exit 1
  fi
else
  echo '[entrypoint] no local database and no complete R2 configuration.'
fi

# 保持与已验证基础镜像相同的实际启动命令。
/usr/local/bin/docker-entrypoint.sh &
OR_PID=$!
echo "[entrypoint] OmniRoute PID=$OR_PID"

deadline=$(( $(date +%s) + READY_TIMEOUT_SECONDS ))

while :; do
  if ! kill -0 "$OR_PID" 2>/dev/null; then
    echo '[entrypoint] FATAL: OmniRoute exited during startup.' >&2
    wait "$OR_PID" || true
    exit 1
  fi

  if curl -fsS \
      --connect-timeout 2 \
      --max-time 5 \
      "http://127.0.0.1:${OMNIROUTE_PORT}/api/monitoring/health" \
      >/dev/null 2>&1; then
    echo '[entrypoint] OmniRoute is ready.'
    break
  fi

  if [ "$(date +%s)" -ge "$deadline" ]; then
    echo '[entrypoint] FATAL: OmniRoute readiness timeout.' >&2
    exit 1
  fi

  sleep 2
done

if [ -x /entrypoint-init-nim.sh ]; then
  if ! /entrypoint-init-nim.sh; then
    if [ "${INIT_FAILURE_FATAL:-0}" = "1" ]; then
      echo '[entrypoint] FATAL: NIM initialization failed.' >&2
      exit 1
    fi
    echo '[entrypoint] WARN: NIM initialization failed; continuing with persisted configuration.'
  fi
fi

if has_r2_credentials; then
  litestream replicate -config /litestream.yml &
  LS_PID=$!
  echo "[entrypoint] Litestream PID=$LS_PID"
fi

node /gate/gate.js &
GATE_PID=$!
echo "[entrypoint] Gate PID=$GATE_PID"

while :; do
  if ! kill -0 "$OR_PID" 2>/dev/null; then
    echo '[entrypoint] FATAL: OmniRoute exited.' >&2
    wait "$OR_PID" || true
    exit 1
  fi

  if ! kill -0 "$GATE_PID" 2>/dev/null; then
    echo '[entrypoint] FATAL: Gate exited.' >&2
    wait "$GATE_PID" || true
    exit 1
  fi

  if [ -n "$LS_PID" ] && ! kill -0 "$LS_PID" 2>/dev/null; then
    if [ "${LITESTREAM_REQUIRED:-0}" = "1" ]; then
      echo '[entrypoint] FATAL: Litestream exited.' >&2
      wait "$LS_PID" || true
      exit 1
    fi

    echo '[entrypoint] WARN: Litestream exited; replication disabled until restart.'
    wait "$LS_PID" || true
    LS_PID=
  fi

  sleep 5
done
```

有一个必须保留的部署检查：`/usr/local/bin/docker-entrypoint.sh` 必须替换为 **3.8.43 基础镜像中已经确认的原始启动命令**。不能凭空假设镜像内部入口路径。现有旧脚本如果已有可运行命令，应原样保留，只替换它周围的恢复、等待和监督逻辑。

### **九、Litestream 配置原则**

根据 Litestream 官方说明，`-if-replica-exists` 在没有副本时会返回成功，因此成功退出不能等价于“恢复成功”；必须随后检查数据库是否真实生成。官方还说明恢复默认不会覆盖已有非空数据库或带 sidecar 文件的数据库，这与“本地有库就跳过恢复”的策略一致。[Litestream Restore](https://litestream.io/reference/restore)

`litestream.yml` 保持简单，不加入未经当前固定版本验证的字段：

```yaml
dbs:
  - path: /data/storage.sqlite
    replica:
      type: s3
      bucket: ${R2_BUCKET}
      path: ${R2_PREFIX}
      endpoint: https://${R2_ACCOUNT_ID}.r2.cloudflarestorage.com
      region: auto
      access-key-id: ${R2_ACCESS_KEY_ID}
      secret-access-key: ${R2_SECRET_ACCESS_KEY}
      force-path-style: true
```

不要把 `auto-recover`、`validation`、`force-wal` 等从不同 Litestream 版本文档中拼接到一起。当前资料显示 v0.5 系列配置格式和恢复语义仍在演进，必须以 Dockerfile 中实际锁定的 Litestream 版本为准。最新官方文档还显示，强制覆盖参数是 v0.5.12 才加入的，因此若当前镜像仍装 v0.5.9，不应使用新参数。[Litestream Migration Guide](https://litestream.io/docs/migration)

### **十、Dockerfile 的关键修正版**

```dockerfile
FROM diegosouzapw/omniroute:3.8.43@sha256:517c160643c56ad72e3e305458d961c9a4c87f711393c13020450f9f088d1570

ENV OMNIROUTE_PORT=20128 \
    EXPOSED_PORT=7860 \
    DATA_DIR=/data \
    OMNIROUTE_USE_TURBOPACK=0 \
    NIM_SHARED_RPM=28 \
    NIM_MAX_CONCURRENT=1 \
    NIM_MIN_INTERVAL_MS=2200 \
    NIM_CONTEXT_AUTO_APPLY=0 \
    NIM_ENABLE_PROBE=0 \
    NODE_OPTIONS=--max-old-space-size=4096

USER root

RUN mkdir -p /data /gate \
 && chmod 700 /data

COPY package.json /gate/package.json
COPY gate.js /gate/gate.js

RUN cd /gate \
 && npm install --omit=dev --ignore-scripts \
 && npm cache clean --force

COPY entrypoint.sh /entrypoint.sh
COPY init-nim-keys.sh /entrypoint-init-nim.sh
COPY litestream.yml /litestream.yml

RUN chmod 0755 /entrypoint.sh /entrypoint-init-nim.sh \
 && chmod 0644 /litestream.yml /gate/gate.js

EXPOSE 7860

HEALTHCHECK --interval=30s --timeout=8s --start-period=180s --retries=3 \
  CMD curl -fsS --connect-timeout 2 --max-time 5 \
      http://127.0.0.1:7860/healthz >/dev/null || exit 1

ENTRYPOINT ["/entrypoint.sh"]
```

Digest 应在构建前用镜像仓库再次核对。Tag 与 Digest 不匹配时 Docker 会拒绝或拉取非预期内容，因此不要仅复制文档中的历史 Digest 而不验证。

### **十一、初始化脚本还需保留的修正**

完整 `init-nim-keys.sh` 应遵循以下硬规则：

1. 增量门同时检查 `nim-stable`、`nim-fast`、`nim-pool`、`nim-codex`，不能只看两个旧 Combo。
2. `nim-stable` 与 `nim-codex` 使用 `priority`。
3. `nim-fast` 可使用 `round-robin`，`nim-pool` 使用 `p2c`。
4. 不使用 `context-relay` 或 `fusion`。
5. Catalog 查询不能只尝试第一把 Key，应依次尝试少量 Key，并在获得结构有效、模型数达到阈值的响应后停止。
6. Catalog 查询的 `401/403/429/5xx/000` 不能直接把全部模型标成不可用。
7. 模型探针默认关闭；开启后最多探测少数模型，并设置请求间隔。
8. 只有 `400/404/410/422` 且错误内容明确指向模型时，才列为弃用候选。
9. 所有动态 SQL 值必须通过参数化或严格转义；动态列名只接受固定白名单。
10. 初始化失败时优先保留上一份持久化配置，不删除健康的旧 Combo。
11. 不自动配置 Search、Context Override 或 Resilience 管理字段，除非在目标 3.8.43 实例上记录了完整请求与读回结果。
12. 所有日志和快照必须脱敏，禁止写出 NIM Key、Gate PSK、Cookie、R2 Secret。

这轮对脚本的核心优化不是继续增加功能，而是删除所有未经目标版本证实的“聪明自动化”。最终稳定版本应以 Gate 强制共享预算、OmniRoute 内置冷却与熔断、只读 Context 观测、严格进程监督为中心；这比把多个推测 API 拼进启动脚本更可靠。

*内容由 AI 生成仅供参考*