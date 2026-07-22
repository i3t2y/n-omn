### **结论：以下是从五份文档中提炼的全部版本优点，按功能类别组织，已跨版本去重合并。这些优点覆盖了从基础设施编排、安全网关、NIM Key 管理、限流策略、搜索能力到运维监督的完整技术栈。**

---

### 一、基础设施与编排

**镜像版本锁定**——Tag + Digest 双写（`diegosouzapw/omniroute:3.8.43@sha256:517c...`），digest 保证不可变，tag 便于人读，禁止浮动 `latest` 导致 Turbopack 构建漂移

**跨版本防御环境变量**——`OMNIROUTE_USE_TURBOPACK=0` 强制走 webpack 绕开 3.8.45+ 的 Docker Turbopack 缓存 mmap 失败；`OMNIROUTE_MAX_PENDING_MIGRATIONS=0` 防止旧库补 migration 时 abort 刷屏中断

**Litestream v0.5.9 集成**——修复 R2 `InvalidContentEncoding`，`auto-recover: false` 防止 replicate 启动时自恢复绕过 entrypoint guard 覆盖有效 DB

**entrypoint 优雅降级 restore**——`litestream restore ... && echo complete || echo WARN: Continuing`，restore 失败不阻断，空库继续启动

**entrypoint 原子 restore（v4.3 candidate）**——临时路径 restore + `PRAGMA quick_check` 验证 + 原子 mv，防止 restore 中断损坏正式 DB

**entrypoint 进程监督循环（in4.3）**——保持 PID 1，显式监督 OmniRoute、Gate、Litestream 三进程；任一核心进程退出则容器退出交由编排层重启；Litestream 退出可配置为告警不拖垮容器

**entrypoint trap 信号转发**——`trap shutdown INT TERM EXIT`，向所有子进程发 SIGTERM，3 秒 grace 后 SIGKILL，wait 回收，无孤儿进程

**entrypoint 健康等待绝对时间戳截止（in4.3）**——用 `deadline=$(( $(date +%s) + 180 ))` 替代计数器循环，避免调度暂停导致计数失准

**entrypoint 版本护栏**——`EXPECTED_OR_VERSION` 检查，版本不一致只告警不中断；`STRICT_VERSION_LOCK=1` 时直接退出阻止静默漂移

**entrypoint 启动验证四步法（omn.md）**——进程存活 + `/api/monitoring/health` 可用 + `/v1/models` 限时响应 + 版本一致，捕获"健康接口正常但真实路由挂起"

**entrypoint init 同步执行（in4.3）**——首次初始化同步阻塞执行，确保所有数据库写入完成后再启动 Gate，消除 init 与 Litestream 的竞争窗口；`INIT_FAILURE_FATAL` 控制失败是否终止

**entrypoint `|| INIT_EXIT=$?` 捕获（v7 继承）**——捕获非零退出码而不触发 `set -e`，避免非致命错误导致容器崩溃

**Dockerfile HEALTHCHECK 对齐**——`start-period=180s` 与 entrypoint 内部 180s 等待对齐，`retries=3` 容忍瞬时抖动

**Dockerfile 精简依赖**——仅安装 curl/jq/python3/python3-pip/sqlite3/ca-certificates + huggingface_hub，`--no-install-recommends` 减小镜像体积

---

### 二、安全网关（gate.js）

**gate.js 零依赖架构（v5/v4.3.1）**——纯 Node.js `http`/`fs`/`crypto` 内置模块，移除 express 和 http-proxy-middleware，彻底解决 better-sqlite3 和 node-gyp 在 Node 24 下的 C++20 编译冲突

**gate.js timing-safe PSK 比较（v4.3 candidate/in4.3）**——`crypto.timingSafeEqual` 常量时间比较，长度不等先返回不泄露内容，长度相等走常量时间比较

**gate.js PSK 最小长度 16 fail-closed**——缺失或过短即 FATAL exit，防止弱 PSK 配置

**gate.js 白名单暴露面控制（omn.md/in4.3）**——默认仅放行 `/healthz` 和 `/v1` + `/v1/*`，其余一律 404；路径判断用 `req.path === '/v1' || req.path.startsWith('/v1/')` 而非 `startsWith('/v1')`，防 `/v123` 绕过

**gate.js admin 白名单 + Basic Auth（v4.3 candidate）**——`GATE_ADMIN_TOKEN` 有效时白名单路径经 Basic Auth 放行，非白名单恒 404，不 allow-everything

**gate.js 路径规整化（v4.3 candidate）**——`normalizePath` 解 dot-segment / 重复斜杠 / 尾斜杠，防绕过白名单匹配

**gate.js PSK → OR_API_KEY 替换**——`/v1` 路径 PSK 校验通过后，`Authorization` 头替换为真实 `OR_API_KEY`，客户端只需知道 PSK

**gate.js OR_API_KEY 双源**——env `OMNIROUTE_API_KEY` 优先，fallback `/data/.or-api-key` 文件

**gate.js Authorization 删除（v4.3 candidate）**——Basic Auth 完成后 `delete req.headers.authorization`，不转发 Basic 凭据给上游

**gate.js SSE 流式超时全禁用**——`server.timeout = 0` / `requestTimeout = 0` / `headersTimeout = 0` 或 `proxyTimeout: 0`，避免大上下文压缩期间被网关掐断

**gate.js 流式超时感知（v5）**——SSE 请求（`text/event-stream` 或 GET `/v1/`）不设硬超时，非流式使用 `UPSTREAM_TIMEOUT_MS`

**gate.js 连接生命周期管理（v5）**——客户端断开时 `req.on('close')` 清理上游连接 `proxy.destroy()`，防 socket 句柄泄漏

**gate.js SSE 逐块转发（v4.3 candidate）**——不聚合不 text/json 读流，尊重背压（`res.write` 返回 false 时 pause + drain resume）

**gate.js HTTP 方法限制（v4.3 candidate）**——admin 页面仅 GET，admin API 按白名单允许方法，非允许方法 405

**gate.js 共享预算限流（in4.3）**——Gate 自行执行内存令牌桶：RPM 滑动窗口 + 并发计数 + 间隔 pacing 三层整形，不依赖 OmniRoute 内部 Request Queue API（其 Schema 未完全锁定）

**gate.js 限流响应含 Retry-After**——并发超限返回 `429 + Retry-After: 2`；RPM 超限计算剩余秒数；间隔未到计算等待秒数

**gate.js `/v1/search/analytics` 单独 404（4.3.txt/in4.3）**——防止 PSK 持有者看到搜索分析数据

**gate.js 诊断端点（v5）**——`/gate/diagnostics` 返回错误统计（502/503/504 计数）、最近 20 条请求日志和配置快照

**gate.js 结构化请求日志（v5）**——每个请求记录为 JSON 对象（含 ts/method/path/statusCode/latencyMs/contentLength/userAgent），错误请求 `console.warn` 级别

**gate.js 正则挂载代理（in4.3）**——`app.use(/^\/v1(?:\/|$)/, ...)` 避免 `pathRewrite` 版本差异和 `/v1/v1` 风险

**gate.js `xfwd: false`（in4.3）**——不添加 `x-forwarded-*` 头，减少不必要的转发信息

**gate.js Host header 删除（v6）**——转发前删除 host header 防冲突

**gate.js SIGTERM 优雅退出（v6）**——容器关闭时优雅关闭 HTTP 服务器，防连接泄漏

**gate.js ANSI 颜色日志（v6）**——`log_info`/`log_success`/`log_warn`/`log_error` 函数区分日志级别

---

### 三、NIM Key 管理与初始化

**Cookie login 三重安全网（v4.3.1）**——接受 200 或 201 + `exit 1` 硬失败 + `grep -q "auth_token"` 验证 cookie 有效，防 `set -eo pipefail` 在 jq 解析 401 响应时静默退出

**Cookie login 请求体用 jq 构造（v4.3.1）**——`jq -n --arg password "$INITIAL_PASSWORD" '{password:$password}'` 替代内联 JSON 字符串，避免引号转义错误

**NIM Keys 幂等注册**——409 状态码跳过已存在的 key，脚本可安全重复执行

**NIM Keys 规范化处理（omn.md）**——删除 CRLF、去首尾空白、删空行、去重、只在内存处理、日志只显示序号和掩码、不进 HF Dataset 快照

**Key 输入校验**——`NIM_KEYS` 为空时 FATAL 但不阻塞主进程（`exit 0` 仅跳过注册），`INITIAL_PASSWORD` 为空时 `exit 1`

**init 双模式认证（v4.3.1）**——cookie login 用于 admin API + `OMNIROUTE_API_KEY` env-bypass 用于 Gate /v1 替换，两层独立

**init 同名连接更新而非仅 409 跳过（omn.md）**——存在时执行更新，而非只把 409 当作成功

**provider-nodes API fallback（新精简版）**——`/api/providers/{id}/connections` 失败时 fallback `/api/provider-nodes`，版本兼容

**多端点兼容注册（v4.3.7）**——同时尝试 `connections` 和 `provider-nodes` 两个 API 端点，解决 3.8.x 子版本间 API 路径不一致

**connection 级限流参数（新精简版）**——`rateLimit: {rpm, minIntervalMs}` 在 connection payload 中设置，与 Resilience requestQueue 双层限流

---

### 四、限流策略

**线性扩容公式（v4.2.3）**——`ALIVE*35` → 300 RPM / `ALIVE*3` → 75 并发 / `60000/RPM` → 200ms，25 Key 下高并发容差充足

**保守整形策略（v4.3/in4.3）**——默认固定 28 RPM / 1 并发 / 2200ms，通过"整形"而非"扩容"显著降低 429 熔断率；NIM 免费层对瞬时并发极其敏感

**CONSERVATIVE / SCALE 限流可切换（新精简版）**——`NIM_SCALE_WITH_KEYS=1` 切换线性扩容，默认保守模式，环境变量控制无需改代码

**删除 NIM_SCALE_WITH_KEYS（in4.3）**——即便默认设为 0，仍会给维护者留下"Key 可线性扩容"的错误暗示；多 Key 仅作冗余与健康轮换

**Resilience 白名单投影（v4.3.1）**——请求体只含 `requestQueue`（`requestsPerMinute` / `minTimeBetweenRequestsMs` / `concurrentRequests`），不含 `useUpstream429BreakerHints`，从根源修复 400 错误

**Resilience 传输错误区分（v4.3.1）**——`curl_rc != 0` 或空 CODE 判定为 transport-error（非 HTTP 错误），区分"无响应异常"与"HTTP 非 2xx"

**Resilience 读回逐字段核对（v4.3.1）**——PATCH 后 GET 读回 RPM / minMs / concurrent，逐字段与预期比对，不一致 `exit 1`（CF-4 失败不覆盖的强化版）

**Resilience 输入校验（v4.3.1）**——`_res_validate_int` 在 PATCH 前校验 RPM(1-60000) / minMs(0-600000) / concurrent(1-1000) 范围

**Resilience 能力发现模式（omn.md）**——先 GET 候选端点，只对返回 2xx 且结构符合预期的端点写入，写入后再次 GET 读回验证，不支持的层记录 `unsupported` 不操作 SQLite

**删除 Resilience 猜测字段（in4.3）**——彻底删除 `providerBreaker` / `connectionCooldown` 猜测字段；官方文档证实熔断仅对 408/500/502/503/504 触发不含 429——429 归 Connection Cooldown 管

**jq 引号 BUG 修复（v4.3.1）**——变量预取替代 `'"'"'` 堆叠，消除 jq 引号转义错误

**Gate 内存令牌桶不依赖 OmniRoute API（in4.3）**——Gate 自行强制执行共享预算，不依赖 OmniRoute 内部 Request Queue API（其 Schema 未完全锁定）

---

### 五、模型管理与 Combo 系统

**模型分档 SSOT（v4.1.0）**——TIER_FAST / TIER_STABLE / TIER_RESTRICTED 三档，通过 `NIM_PROFILE=fast|balanced|full` 控制入池范围

**nim_route_model 幂等前缀函数（4.3.txt）**——`case "$1" in nvidia/*/*) printf '%s' "$1" ;; *) printf 'nvidia/%s' "$1" ;; esac`，按三段结构识别，防止 `nvidia/nvidia/...` 双前缀

**combo 对象数组格式修正（v4.1.0）**——从字符串数组 `["x"]` 改为对象数组 `[{"model":"x"}]`，combo 创建从 400 变为 201

**combo 策略白名单**——`_VALID_STRATS` 显式列出合法策略，context-relay 排除（CF-1 红线），非法策略回退 round-robin

**幂等 upsert_combo**——存在则 PUT，不存在才 POST，可安全重复执行

**四组 Combo 系统（4.3.txt）**——`nim-stable`(priority) / `nim-fast`(round-robin) / `nim-pool`(p2c) / `nim-codex`(priority)，按场景分工

**Combo modelFallbackChain 显式三级回退（v5）**——GLM-5.1 → GLM-4.7 → Llama-3.3-70B，自动切换防 502

**model_combo_mappings 路由规则（4.3.txt）**——Pattern 通配符映射到 combo，客户端直接用模型名透明切换

**Wildcard 别名 + 全局 Fallback 链（4.3.txt）**——`gpt-* → auto:nim-stable`，`claude-* → auto:nim-stable`，减少硬编码组合

**增量模式无条件 repair_combo（v4.1.1）**——从仅 deprecated 非空时执行改为每次增量重启无条件执行，确保模型列表和路由前缀格式始终与 SSOT 同步

**增量检测交叉验证（v5）**——同时检查 `combos` 表和 `api_keys` 表，防单表误判

**增量门扩展（v4.3.0）**——四组 nim-* combo 任一存在即视为增量

**check_nim_model_health 多 Key 轮转取目录（4.3.txt）**——按顺序尝试多个 Key 获取 NVIDIA `/v1/models` 目录，失败时保守跳过过滤而非误删

**check_nim_model_health 首次也执行（v4.1.0）**——从仅增量模式扩展到首次初始化也执行，实时查询目录过滤下架模型

**nim_probe 抗抖动（v4.3.1 FIX-3）**——`--retry 2 --retry-delay 1` + HTTP 000（传输失败/超时）不判死，避免 compaction 磁盘 I/O 抖动误杀模型

**nim_probe 单 key 单次探针（新精简版）**——只对第一个 key 做一次探针，000/5xx 忽略，仅 4xx 判坏 key

**nim_probe 限频与冷却（4.3.txt）**——`NIM_PROBE_MAX_MODELS` 上限 + `NIM_PROBE_MIN_INTERVAL_SECONDS` 冷却，默认关闭

**nim_probe 错误分类（omn.md）**——`400/404/410/422` 明确模型无效；`401/403` Key 问题不判模型下线；`429` 限速不判坏；`5xx`/网络错误临时故障不判坏

**自动化 Combo 固化（v4.3.7）**——脚本末尾自动创建 `nim-pool` Combo，客户端无需关心底层是哪个 Key

**模型池保守策略（omn.md）**——`nim-stable` 默认只放 2-3 个已验证模型；`balanced` 不加入 RESTRICTED；`full` 仅人工评测；不用 `fusion` 日常策略

---

### 六、#5 ProxyFetch 修复体系

**B6 全链路源码根因分析**——`proxyFetch.ts:637 globalThis.fetch=patchedFetch` → `resolveProxyForRequest:273-296` 用 `proxyContext.getStore()` 内存 account.proxy → `proxies.ts:806` pool load 一次性读取 → 不查 SQLite `proxy_enabled` → 无 reload 钩子

**R2 副本路径切换 `omniroute-v3`（新精简版）**——从根源消除 #5，不需 pre-purge、不需改 entrypoint 时序、不需删旧备份，切换路径一劳永逸

**启动前状态锁定 Pre-startup Purge（v4.3.3）**——在 `entrypoint.sh` 中提前 `export` 环境变量并直接修改 SQLite `settings` 表，从根源杜绝 20129 报错

**FIX-1 Settings 代理清除（v4.3.1）**——PATCH `/api/settings` 补 `proxyUrl=null / proxyEnabled=false / relayBackend=null`，触发 HOT_RELOAD 重建内存 dispatcher

**FIX-1 Settings 读回验证**——PATCH 后 GET 读回确认 `proxyUrl=null`

**FIX-1 SQL 兜底清 settings 表**——`UPDATE settings SET value=json_set(...)` 清除内存 dispatcher 的配置源

**环境隔离保护（v4.3.3）**——启动前 `unset` 掉所有可能触发 Relay 逻辑的系统代理变量

**purge_proxy_db 注册表模型（v3.6.0）**——API 层（`/api/v1/management/proxies`）+ SQL 层双管齐下清理 `proxy_registry`

**purge_proxy_db 收窄清理范围（v5）**——仅清理脚本管理的 relay（`source IN ('vercel-relay','deno-relay','cloudflare-relay')`），保留用户手动添加的

**proxy_enabled 强制覆盖（v3.8.0 修复 F）**——`UPDATE provider_connections SET proxy_enabled=0` + 回读校验，注册 key 后必定再次执行覆盖

**三重 #5 防御（最强新版）**——R2 路径切换（根源）+ FIX-1 Settings 清除（API 层）+ purge_proxy_db SQL（DB 层），纵深防御

**check_dangerous_env 扫描**——检测 HTTP_PROXY / HTTPS_PROXY / ALL_PROXY / OMNIROUTE_RELAY_BACKEND / BIFROST_BASE_URL 等遗留环境变量

**彻底移除 Relay 三节点架构（in4.3）**——回归原生 NIM 直连：`Agent → Gate → OmniRoute 3.8.43 → NVIDIA 官方端点`

---

### 七、Context 管理

**apply_context_override 恢复（K5 修复）**——从 42ea8e7 基线恢复 `INSERT OR REPLACE INTO model_context_overrides ... source='init'`，弃用不存在的 API PATCH 路径

**4632e8c 禁用 monitor 自动回写**——source='monitor+manual' 的 confidence-based 回写禁用，防止 real_context 运行时被篡改

**Context 纯观测不自动回写（in4.3/omn.md）**——默认 `NIM_CONTEXT_AUTO_APPLY=0`，只输出 `context-recommendations.ndjson` 报告，不自动 SQL 兜底、不自动 PATCH

**Context 观测失败判定规则（omn.md）**——只认 `413` 及带 context/token/length 文本的 `400/422`；`429/401/403/5xx/网络失败/输出为 0` 不用于推导上下文边界

**Context Override 改用官方 API（4.3.txt）**——通过 `/api/provider-models` PATCH 而非直接 SQL 写表，避免 migration 结构漂移导致静默失配

**三层防护体系**——L1 `CONTEXT_LENGTH` 内部截断 + L2 Combo `modelFallbackChain` 自动切换 + L3 客户端 `maxContextTokens` 源头阻止

**CTX_WARN_BYTES 上下文长度警告（v5）**——请求体超 128KB 时告警，帮助识别可能触发 502 的大型请求

**GLM-5.1 502 根因分析**——确认 NIM 免费层隐藏的 ~32K input token 限制（非标称 198K），超限时返回 502 而非 4xx

---

### 八、搜索能力

**OmniRoute 原生 `/v1/search` 统一入口**——内置 5-9 家 Provider（Serper/Brave/Perplexity/Exa/Tavily/SearXNG 等），自带 auto-failover 和 cache（request coalescing + TTL）

**搜索提供商优先级配置**——P1 主力 Brave（独立索引、benchmark 最优、延迟最低）+ Tavily（AI 优化、内容提取）；P2 备用 Serper；P3 保底 SearXNG

**搜索与抓取分离**——search 阶段用 Tavily/Brave 保证结果质量，extract/scrape 阶段改用自托管 Firecrawl，避免 Tavily 免费额度被抽取快速吃光

**搜索缓存配置**——`searchCache: {enabled:true, ttlSeconds:300, coalescing:true}`，减少重复消耗

**搜索就绪自检（4.3.txt）**——`check_search_ready()` GET `/api/v1/search` 检测已配置提供商数量，未配置时 WARN 提示

**搜索凭据脱敏**——搜索提供商 API Key 不进 HF Dataset 快照，与 NIM Key 同等保护

**Rerank + Embeddings 管线**——`/v1/rerank` 重排 + `/v1/embeddings` 向量化，直接对接 NVIDIA NeMo Retriever 模型

**Hybrid Search（BM25 + 向量 RRF 融合）**——BM25 擅长版本号/错误码等精确 token，向量检索擅长语义，用 RRF（Reciprocal Rank Fusion）融合

**查询改写三路策略**——直接查询 + 官方查询（加产品名/文档/版本）+ 反证查询（搜 bug/限制/deprecated）

**两阶段检索**——候选发现（搜索 URL）与正文取证（定向抓取）分开，搜索接口擅长发现 URL 但摘要常被截断

**MCP `omniroute_web_search` 工具**——Agent 可直接调用，需 `execute:search` scope

**Tool Search 兼容性风险记录**——`#2766`（tool_search 在 Codex 路径不支持）和 `#3974`（tool-search beta flag 被丢弃导致 400），建议默认 `ENABLE_TOOL_SEARCH=false`

---

### 九、数据持久化与备份

**Litestream 基础集成**——解决 HF Space 容器重启即丢数据痛点

**R2 自动降级守卫（v4.3.6）**——entrypoint 中增加对 R2 四个核心变量的完整性校验，配置不齐时自动切回 LOCAL-ONLY 模式

**R2 Endpoint 显式化（v4.3.6）**——改用 `bucket + endpoint` 拆分模式，解决 v0.5.9 的 `bucket required` 报错

**本地非空跳过 restore（红线 3）**——本地 DB 已存在且非空时跳过 restore，绝不覆盖有效 DB

**HF Dataset 快照（HF Hub API commit）**——原子操作 + base64 编码，无需 git 依赖，提供配置版本历史

**HF Dataset 字段级脱敏**——Authorization / NIM_KEY / Cookie / Set-Cookie / Bearer → `<REDACTED>`；`del(.apiKeys[].key)` + `del(.providerConnections[].credentials)`

**`_hf_snapshot || true` 防护**——快照失败不阻塞部署流程

**移除 Litestream 根除数据库覆盖崩溃（v7）**——compaction 每 30 秒替换主数据库文件导致 SQLite 连接失效，v7 彻底移除

**数据库确定性启动（v7）**——每次从零创建 + 全部 109 个迁移，状态完全可预测

---

### 十、运维与调试

**单变量调试 NIM_MODE=DEBUG**——单一变量联动三项行为：日志 tee 落盘 + APP_LOG_TO_FILE + DISABLE_SQLITE_AUTO_BACKUP 防写锁冲突

**DEBUG 日志保留最近 N 份**——`NIM_DEBUG_LOG_KEEP` 控制保留数量，自动清理旧日志

**密码通过环境变量直接传递（v7）**——由 OmniRoute 自身处理明文到 bcrypt 迁移，消除 SQL 引号错误

**SQL 注入防护 `sql_escape()`**——所有用户可控变量嵌入 SQL 前经过 `sed "s/'/''/g"` 转义

**RELAY_AUTH_KEY 外部化**——从硬编码改为环境变量读取，消除凭证泄露风险

**项目结构扁平化（v7）**——6 个核心文件全部位于根目录，无子目录嵌套

**sync-to-hf.yml 健壮性增强**——`git rm --ignore-unmatch || true` + `DEPLOY_COMMIT` 改用 `${{ github.sha }}`

**README.md HF 元数据合规**——移除字符串格式 `datasets` 字段（HF 要求数组），消除 pre-receive 验证失败

**`.env.example` 完整文档**——56 个环境变量 + 中文注释，按功能分区，是接手者的配置参考手册

**b64() 函数 BusyBox 回退**——优先 GNU coreutils `-w 0`，回退 `tr -d` 方式，确保跨发行版兼容

---

### 十一、跨版本系统性优点

**幂等设计贯穿全局**——Key 注册 409 跳过、模型注册 409 跳过、Relay `INSERT OR REPLACE`、API Key 先查后建、Combo 先查后建

**外部化配置策略**——所有环境相关信息通过 HF Secrets 传入，脚本不含硬编码凭证，可安全公开在 GitHub

**空库冷启动设计**——init 脚本每个步骤不假设 SQLite 已有数据，从零重建所有核心配置

**优雅降级原则**——任何非关键依赖不可用时降级到可工作最小状态继续运行，不直接崩溃

**强模型白名单投影原则**——不"删字段"而"挑字段"，显式构造只含 API 接受字段的请求体

**强模型启动时序图**——restore → validate → purge → checkpoint → start litestream → start OmniRoute，明确依赖顺序

**强模型阶段标记法**——request_received → auth_passed → account_loaded → ... → nim_dispatch_started，精确定位 abort 发生阶段

**L5 跨重启交叉验证**——两份生产日志对比确认缺陷跨重启复现

**provider_limits_sync 有意偏离默认**——`1440` 分钟（官方默认 70min），NIM 免费层限额稳定，降低同步频率以省请求

**PROVIDER_LIMITS_SYNC_INTERVAL_MINUTES 加注释标注**——避免未来误以为是笔误

**body limit 归一**——raw bytes → MB 转换 + clamp [1, 500]，处理不同单位输入

**压缩 + 思维预算自动配置**——stacked 模式 / threshold 12000 + adaptive / 8000，每次启动自动应用

**完整 API 配置链**——Resilience / Settings / Compression / Thinking budget / Memory legacy / Memory extended / Circuit breaker reset，全量配置

**密码同步改用 jq（v5）**——从脆弱的 `node -e` 改为 `jq -Rs '.'`，并提供 `sed` 手动转义回退

*内容由 AI 生成仅供参考*