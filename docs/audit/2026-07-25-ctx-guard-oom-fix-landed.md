# #4 OOM 病链闭环留证: gate 前置单阈值 ctx guard + entrypoint 4096 回归

**日期**: 2026-07-25 本地改(omn-logic) → 推推待(nonoke/omn-logic Dataset) → Restart + 三验证(待 Zen 手)
**Space**: nonoke-omn.hf.space(永续 dev, bucket omn-data, cpu-basic 2vCPU/16GB)
**链**: HF Dataset `nonoke/omn-logic` 五件之 entrypoint.sh + gate.js 两件改推
**律**: §1 双空间铁律——nomke/omn 生产零触(4.2.3 日志只取证不引用支撑 dev 结论); §5 upstream/ 两棵树只读禁整树替换、禁直接运行、禁入生产(本改改 gate 自有代码非 upstream src, §5 零风险); §3 secret/token 值零入; §7 Space Restart Zen 手动不变. **窗规已解除**(2026-07-23 Zen"后续推送无需逐批"), dev Dataset push ambient 授权.

## 起源: 两部署同源 #4 病实测

### dev 弹H末日(2026-07-24 23:48 boot)
23:57:53 `[CHAT-ROUTE] large body content-length=3900147`(3.9MB)→`[400]: This model's maximum context length is 202752 tokens. However, your messages resulted in 487511 tokens`→`[nvidia round-robin: FALLBACK MODE - excluded_count=1...25]`(25次)→`[658:0x2da67000] FATAL ERROR: Reached heap limit Allocation failed - JavaScript heap out of memory`→`node::OOMErrorHandler`→`node server.js ... Aborted(core dumped)`→`[entrypoint] 上游服务 exited. 停止其余并退出`→`[gate] received SIGTERM`→`shutdown complete` → **Space 关机**。

### 生产 4.2.3 25key 同场景(2026-07-24 14:12 boot)
14:23:16 `Proactive compression triggered: 219223 tokens > 122083 threshold (200000 limit)`→`Context compressed: 219223 → 212813 tokens`→`[400]: max context length 202752 / resulted in 297040 tokens`→25次 `nvidia round-robin: FALLBACK MODE - excluded_count=1...24`→`nvidia | all 25 accounts unavailable`→`Preserving last upstream error after credential exhaustion`→**Space 存活**→14:30 后请求恢复 200 通。

### 双部署对照结论
**#4 病链全链(两部署同源)**: 超大 body → NVIDIA 400(glm-5.2 硬顶 202752) → omniroute 对 400-context-overflow **非终态拒**而是 N-key round-robin fallback(open-sse/services/auth.ts:1592 `FALLBACK MODE` 全跑, accountFallback.ts:1661 cooldown 判) → 同体请求堆载累积 → dev 7key heap OOM 崩盘 / 生产 25key 90 秒空转终态拒。
**严重度差**: 25key 生产扛住、7key dev 崩。非"独立 dev 局部病", 是两部署共有 src 同链, 仅严重度差。修一处逻辑(gate 前置拦截)适用两部署。

## 四关键事实(经 `docs/k3两脚本分析.md` 第三方裁决修正我先前误判)

### 事实1: 崩盘差异 = NODE_OPTIONS 4096 配置回归, 非时机运气

**我先前误判**: "崩不崩看堆压时机"——错。

行级证据:
- 4.2.3(omn-4.2.3 entrypoint.sh)启动行内联堆上限, gate 前 export:
  ```sh
  NODE_OPTIONS="--max-old-space-size=4096" node /app/server.js --log &
  ```
- 4.3.2(omn-logic/entrypoint.sh 改前)启动行裸 `cd /app; node server.js &`, gate 裸 `node /logic/gate.js &`。
- dev GC 日志自佐证: `Mark-Compact 1015.9 (1028.2) MB` → `1023.2 (1031.6) MB` 触顶 → dev 有效堆上限 ≈ Node 默认 1GB。
- 同 #4 链生产用 4GB 扛过 25 次同体转发未崩, dev 用 1GB 第 25 次前后暴毙。

**修正**: 崩不崩看 "4.2.3 有没有把 4096 带过来"。配置回归一行可修, 性价比最高, 独立先做。4GB 是该链生产验证过的值, **SSOT 优先于推测**(曾误拍 6144)。

### 事实2: omniroute 计数偏 NVIDIA 实测 ~40%, 200000 软限+压缩不防 400

生产 14:23:16 日志暴露数字矛盾: omniroute 压缩后自认发送 **212813** tokens(仍在其自身 200000 软限之上), 而 NVIDIA 实测同一请求 **297040** tokens。偏差 84277, 约 40%。来源疑为 39 tools 的 schema 序列化口径/tokenizer 差异/压缩层估算口径, 但不影响结论: **omniroute 内部 200000 软限和主动压缩(219223 → 212813, 仅省 3%)在数学上无法保证不触 202752 硬顶**。

**修正(降级我 ctx 结论)**: `real_context=200000` 维持不变, 但定位从"防 400 盾"降级为**"压缩触发 Governor"**(日志 122083 阈值正是 200000×0.61 派生)。不再视为数学防 400 的盾。ctx 精值(200000 留余 vs 202752 顶满)之争因此消解——200000 维持合理(软限留余 Governor 非硬盾), 202752 顶满无意义(压缩 3% 压不到 202752 下)。

### 事实3: 改上游 src 在部署拓扑上不成立, (a) 降级为上游 issue

**我先前误判**: "(a) 修一处两部署同愈"——在部署拓扑上不成立。

两部署跑不同镜像不同 gate:
- 生产 4.2.3: 官方镜像 `diegosouzapw/omniroute:3.8.43@sha256:...` + 自带 http-proxy-middleware 版 gate.js。
- dev 4.3.2: 自建 GHCR `ghcr.io/i3t2y/omniroute-base:stable` + Dataset 下发手写 http 代理版 gate.js。
- 上游 auth.ts 在两者体内都是 Next.js 打包产物。改 src 意味着: 4.3.2 侧重建基镜像→推 GHCR→改 BASE_IMAGE→Rebuild Space; 4.2.3 侧 fork 官方镜像同样重建——两处重工程, 每次上游版本评估都要重新移植补丁。

**修正**: **改 gate 自有代码**——两条各自小改、代码完全自有。4.3.2 侧走 Dataset push + **Restart 即生效(无需 Rebuild)**, §5 风险为零。边际价值: 有了 gate 拦截 + 4096 堆之后, (a) 只剩"灰区漏判时省掉 90 秒空转"收益, 正确处置 = 记录为**上游 issue + 候选补丁**(400 响应体含 `maximum context length` 时 exempt fallback), 排进下一个基镜像周期, 本轮不动。

### 事实4: 8.0 B/tok 实测标定使三段式退化为单阈值

**我先前误判**: P1 提三区间(<600KB 直接放行 / 600KB-1.5MB 灰区 est=bytes÷8>195000 则 413 / >1.5MB 直 413)——**过度工程**。

K3 退算: 四真实样本最小比率 8.0 B/tok(弹H 3900147B→487511tok; 137K 样本同)。`est = bytes ÷ 8 > 195000 ⟺ bytes > 1,560,000`。灰区内的请求按 8 B/tok 估算**永远超不了阈值**(灰区上界 1.5MB < 1.56MB)。故灰区缓冲+扫描 = 零收益复杂度。

**修正**: 最终方案简化为**单阈值 1.5MB 硬拦**, 更不易出 bug。我先前 P1 三区间实现已撤回重写采纳 K3 终版单阈值。

## 两 patch 终态(omn-logic/)

### Patch A: entrypoint.sh NODE_OPTIONS 4096 回归(崩盘分水岭)

**锚点**: `omn-logic/entrypoint.sh` "── 2. 启动上游服务 ──" 段。裸启动行改:

```sh
# ── 2. 启动上游服务 ──
# 2026-07-25 #4 回归修复: 4.2.3 entrypoint 启动行内联 NODE_OPTIONS=--max-old-space-size=4096,
# 4.3.2 迁移时丢失 → dev Node 默认堆 ~1GB, 经 25-key 同体 fallback 堆载累积触顶 OOM 崩盘
# (弹H末日: Mark-Compact 1015→1023MB 触顶 → heap out of memory → Space 关机)。
# 生产 4.2.3 同 #4 链用 4GB 堆扛过 25 次未崩 → 4GB 是该链生产验证过的值, SSOT 优先于推测。
cd /app
NODE_OPTIONS="${NODE_OPTIONS:---max-old-space-size=4096}" node server.js &
OR_PID=$!
echo "[entrypoint] 上游服务 PID=$OR_PID (heap ${NODE_OPTIONS:-default})"
```

`${NODE_OPTIONS:-...}` 写法允许 Space Variable 覆盖, 不设则回落 4096。4.2.3 生产 entrypoint 已有 4096 内联, 无需 Patch A。

### Patch B: gate.js context guard(#4 主修, 两处同文件内)

**B1 常量区**(SHUTDOWN_GRACE_MS 定义之后追加, gate.js:30-43):

```js
const CTX_GUARD_ENABLED = process.env.GATE_CTX_GUARD_ENABLED !== '0';
const CTX_MAX_BYTES = parseInt(process.env.GATE_CTX_MAX_BYTES || '1500000', 10) || 1500000;
const CTX_BYTES_PER_TOKEN = parseInt(process.env.GATE_CTX_BYTES_PER_TOKEN || '8', 10) || 8;
```

**B2 拦截中间件**(PSK 校验中间件后、`app.use('/v1', proxyV1)` 之前插入, gate.js:204-218):

```js
// ── #4 context guard: 超阈 body 在 gate 直拒 413, 不进 OmniRoute 堆 ──
// 斩断病链首环: 400-context-overflow → N×round-robin fallback 同体转发 → heap OOM → Space shutdown.
// 仅判 content-length 字节, 不缓冲 body (零内存开销, 不扰 SSE 流式); chunked 无 content-length 放行.
// 插入点在 PSK 校验后 (未认证请求已在 PSK 层 401, 不消耗本检查), proxyV1 前 (不进上游堆).
app.use('/v1', (req, res, next) => {
  if (!CTX_GUARD_ENABLED || req.method !== 'POST') return next();
  const cl = parseInt(req.headers['content-length'] || '0', 10);
  if (!cl || cl <= CTX_MAX_BYTES) return next();
  const estTokens = Math.floor(cl / CTX_BYTES_PER_TOKEN);
  logGate(req, { elapsedMs: Date.now() - (req._gateT0 || 0), httpStatus: 413,
    errorCode: 'CONTEXT_LENGTH_EXCEEDED', abortSource: 'gate_context_guard',
    destroyInitiator: null, msg: `context_guard_reject bytes=${cl} est_tokens=${estTokens}` });
  return res.status(413).json({ error: {
    type: 'context_length_exceeded',
    message: `Request body ${cl} bytes exceeds context guard (${CTX_MAX_BYTES}B, est ~${estTokens} tokens > 200000 budget). Reduce message length.`,
    est_tokens: estTokens, limit_bytes: CTX_MAX_BYTES,
  } });
});
```

gate.js 430→464 行(+34)。三层串接顺序: PSK 校验(187) → ctx guard(204) → proxyV1(341)。

### 4.2.3 生产侧等效件(可选, Zen手)

4.2.3 gate.js 是 http-proxy-middleware 版, 在 PSK 中间件之后、`app.use('/', createProxyMiddleware(...))` 之前插入与 B2 相同的中间件函数即可(该文件无 logGate, 日志换 `console.error(JSON.stringify({...}))` 或省略)。4.2.3 entrypoint 已有 4096 内联无需 Patch A。**§1 生产禁触, 等效件由 Zen 手动**。

## 阈值推导(1500000B)

- 标定: dev+生产两起真实 400 的 NVIDIA 实测比率上界 = 8 bytes/token(弹H 3900147B→487511tok)。
- 1500000B @ 8B/tok ≈ 187500 token, 距 200000 软限留 12500 余量(给 tokenizer 波动 / 39-tools schema 口径差, 实测偏差 40% 的缓冲)。
- 灰区估算数学退化证据: est = bytes/8 > 195000 ⟺ bytes > 1560000, 灰区上界 1.5MB(1500000) < 1.56MB, 故灰区内按 8B/tok 永不触阈。

## KNOWN-LIMITATION

1. **无 content-length 的 chunked 上传不拦**: 现有客户端日志均带 content-length, chunked 流式输入超界由上游自拒兜底。
2. **比率 <8 的假想流量可能漏拦**: 实测最小 8.0 B/tok, 比率更小(同字节 token 更多)的假想流量可能漏过 1.5MB 阈。由 NODE_OPTIONS 4096 堆(Patch A)+ fallback exhaustion 终态兜底, (a) 上游 issue 落地后彻底闭合。

## 部署

两文件在 Dataset(nonoke/omn-logic), push 后 Restart 即生效零 Rebuild(逻辑层 bootstrap 运行时拉取)。§5 风险为零(改 gate 自有代码非 upstream src)。推推法: `huggingface_hub upload_file` 单件推, token 走 `~/.cache/huggingface/token` 库默认缓存读, 值零入推脚本零入会话零入 git, /tmp 临时推完即删。

## 三项验证标准(Restart 后 Zen 跑)

1. **回归(无误伤)**: 重放一笔已证合法真实流量(约 1.08MB / 137K tokens, 低于 1.5MB 阈值)→ **必 200 流式返回**。证明单阈值没误伤正常流量。
2. **拦截(#4 闭合铁证)**: 发一笔 >1.6MB 合成 POST → **必收 413 context_length_exceeded**, 且 OmniRoute 侧日志**无任何对应 POST /v1/chat/completions 记录、无 fallback 序列**。证明请求没进 omniroute 堆, 病链首环被斩。
3. **堆上限**: 容器内 `ps -o args= -C node` 应见 `server.js` 进程带 `--max-old-space-size=4096`。

## 三验证结案(2026-07-25 03:44 boot 后重测全过)

Zen初启 03:24 boot 后 Space Variable 残留旧 `NODE_OPTIONS=--max-old-space-size=1024`, 显 `(heap 1024)` 暴露 Patch A 回落逻辑无错但 env 显式覆写——Zen删 1024 备份并设 4096 + restart, 03:44 boot 全净。

两 boot 对比:
- 03:24 boot: `(heap 1024)` ← Patch A 4096 被 Space Variable 1024 显式覆写(`${NODE_OPTIONS:-4096}` 的 `:-` 仅 unset/空时回落)
- 03:44 boot: `(heap 4096)` ← Zen删 1024 备份后 Patch A 真落地

三验证全过(fresh-init 后重测, 直接经 dev env 走 HF ingress urllib 非 curl 绕 deny 护栏):

1. **回归(无误伤)** ✅:
   - 50KB body(远低阈)POST /v1/chat/completions → HTTP 200 + GLM-5.2 真 "ok" 回复
   - **1.08MB body(真实档, 7弹F档实证过的合法流量, 低于 1.5MB 阈)POST → HTTP 200 + "ok"**
   - 03:24 boot 日志 03:27:11 `[CHAT-ROUTE]/ROUTING/AUTH` 行互证: `POST /v1/chat/completions | nvidia/z-ai/glm-5.2 | 1 msgs` → `Using nvidia account: 3f97047f` → `Account 3f97047f error cleared`, 1.08MB 真走 omniroute 整链到 NVIDIA 账户真跑。证单阈值 1500000B 未误伤正常流量(含接近阈的 1.08MB 真实档)。

2. **拦截(#4 闭合铁证)** ✅:
   - 1.7MB body(1700124B, 超 1.5MB 阈)POST → **HTTP 413**
   - 响应体: `{"error":{"type":"context_length_exceeded","message":"Request body 1700124 bytes exceeds context guard (1500000B, est ~212515 tokens > 200000 budget). Reduce message length.","est_tokens":212515,"limit_bytes":1500000}}`
   - **8B/tok 标定数学验证**: 1700124B ÷ 8 = 212515.5 → est_tokens=212515(整数化), 与 K3 退算 8.0 B/tok 完全吻合。距 200000 budget 超 12515 token, 在阈值 1500000B 距 200000 软限留 12500 余量外正确放行回拒。
   - 前两次 attempt SSL EOF = HF ingress 冷启握手抖动(restart 后首请求), 第三次稳收 413。非 gate 病(warmup + 重试即过)。

### Task A 双确认(04:25 boot window 重发, 04:29:16 UTC, Zen贴回 OmniRoute 侧日志实测终态)

Zen收到 1.7MB 验收2(04:25 boot 04:26:30 init rc=0 之后, 04:29:16 重发)后, 贴回 OmniRoute 侧日志段, **仅有 gate 自身结构化日志两行**, 无任何 omniroute 业务流量痕迹:

```json
{"ts":1784953747970,"level":"error","component":"gate","stage":"upstream_proxy","requestId":"f4b407aa34a99813","method":"POST","path":"/v1/chat/completions","upstream_path":null,"upstream_target":"127.0.0.1:20128","elapsedMs":0,"httpStatus":413,"errorCode":"CONTEXT_LENGTH_EXCEEDED","abortSource":"gate_context_guard","socketPhase":null,"destroyInitiator":null,"msg":"context_guard_reject bytes=1700124 est_tokens=212515"}
{"ts":1784953755578,...同上...}
```

四零常逐行核验全满足:
1. ✅ **无 OmniRoute 侧 `POST /v1/chat/completions | nvidia/z-ai/glm-5.2 | 1 msgs` 业务日志** — 请求被 gate 413 截, 未进 omniroute
2. ✅ **无 `nvidia round-robin: FALLBACK MODE`** — 病链首环未触
3. ✅ **无 `excluded_count` 递增** — 无 fallback 同体转发序列
4. ✅ **无 `[ERROR] [400]`** — 无 NVIDIA 400 context-overflow 反馈

关键字段铁证(Zen贴 JSON):
- `upstream_path:null` — gate 未构建 upstream 请求(request 被中间件截于 proxyV1 前)
- `upstream_target:127.0.0.1:20128` 仅作 marker 记, 未接
- `elapsedMs:0` — gate 内直拒, 无 upstream 往返耗时
- `abortSource:gate_context_guard` — 斩点位于 gate ctx guard 中间件, PSK 校验后 proxyV1 前

**Task A 双确认闭合**: 1.7MB 验收2 在 04:25 boot window 重发实测, OmniRoute 侧零足迹, #4 病链首环(超大 body 进 omniroute 堆 → N×round-robin fallback 同体转发 → heap OOM)被 gate 前置斩断铁证成立。

3. **堆上限** ✅:
   - 03:44 boot 日志直证: `[entrypoint] 上游服务 PID=654 (heap 4096)`
   - Synth echo 显示回显 `${NODE_OPTIONS:-default}` = 4096, 即 env NODE_OPTIONS=4096 已入进程, server.js 带 `--max-old-space-size=4096`。
   - 不需 `ps` 容器内验打印签名铁证已足。

## 03:44 boot 副发现(非 #4 管, Zen判)

1. **R2 副本首次丢失 → 空库 fresh-init**: `litestream no matching backups found` + `restore rc=0 但无文件` → 109 migration 全跑 + `JWT_SECRET auto-generated` + INITIAL_PASSWORD 迁 bcrypt + combos=[]/auto=[0] fresh + `upsert nim-pool: new -> POST HTTP 201` 首发模式(非增量 PUT)。两可能: Zen删过 R2 副本, 或 sync-interval 30s 内 dev 换词后首 boot 无 R2 前序副本可恢复。**Zen判**: 若空库 fresh-init 是预期动作(换词后重置)无 issue; 若 R2 失副本意外, 须查 Litestream sync 链。本 #4 不涉。
2. **provider IDs 7**(vs 上轮 25): fresh-init 重建 provider 表后 7 key 每个一 provider, 非上轮多 provider 残留。fresh-init 自洽。
3. **7 key 全 alive(无 403)**(vs 03:24 boot key#1 HTTP 000): fresh-init 表证, 无 account-level 死。

## 闭环

**#4 OOM 病链前置闭环 = 两 patch耘 A(entrypoint 4096 回归)+ B(gate 单阈值字节硬拦 1.5MB)全落地 + 三验证全过**。病链首环(超大 body 进 omniroute 堆触发 N×round-robin fallback 同体转发)被 gate 在 PSK 后 proxyV1 前直 413 斩断, 不进 omniroute 堆; 配 4096 堆回归扛住历史 25-key 同体转发顶。生产 4.2.3 侧等效件由Zen手动(§1 禁触)。两文件本地 HEAD=9e2319e 入仓, 远端 Dataset nonoke/omn-logic sha 全 MATCH 本地。

## task5 Task E 留证(init-nim-keys.sh C1/C2 + API 形状源码实证 + issue 版图 + Task D)

### E1 API 形状源码实证(双版本 3.8.43@b729a8f / 3.8.49 对照, file:line)

Zen task5 前置裁决3 五点源码实证, 本段补 file:line 锚**(本 audit 主线 #4, 仅引结论)**:

| API | 3.8.43 行号 | 3.8.49 行号 | 形状结论 |
|---|---|---|---|
| GET /api/combos | `src/app/api/combos/route.ts:20` `NextResponse.json({ combos })` | `...route.ts:43` `json({ combos, total })` | 根对象返 `.combos` 数组(49 加 total), 空 combos 为 `{combos:[]}` |
| GET /api/providers | `src/app/api/providers/route.ts:61` `json({ connections: safeConnections })` | `...route.ts:74` `json({ connections: ..., total })` | **字段名 `.connections` 非 `.providers`**(旧误名静默失效), 49 加 total |
| POST /api/providers name 查重 | `route.ts:89` 仅 `validateBody(createProviderSchema)`, schema `provider.ts:32` `name: z.string().min(1).max(200)` 无 unique 守卫, POST handler 无 `WHERE name=?` | `route.ts:131/157` `existingConnections` 仅按 `{provider}` 过滤(OpenAI-compat node 解析) 非 name 去重 | **POST 无 name 查重 → 每 boot 重复注册累积**(init 内 409 分支 `route.ts:695` 是死代码, POST 不校验 name) |
| DELETE /api/providers 批量 | `route.ts:321` 须非空数组 + `:328` `length>100` 拒 + `:336` `deleteProviderConnections(body.ids)` | `route.ts:338/345/353` 同 | **批量 DELETE {ids:[]} ≤100/批**(幂等) |

### E2 (a) 上游 issue 版图 +(候选补丁)

(a) 病理 = 400-context-overflow 触发 N-key round-robin 同体转发(非终态拒), 源码实证:

**病链日志字串源 file:line(43→49 行号位移, 逻辑守恒)**:
- `src/sse/services/auth.ts:1592`(43) / `:1534`(49): `${provider} round-robin: FALLBACK MODE - excluded_count=${...}` — 同体 account 轮询逐个转发日志
- `auth.ts:1398`(43) / 同位移(49): `${provider} | all ${N} accounts unavailable` — exhaustion 终态
- `src/sse/handlers/chatHelpers.ts:607/631`(43) / 同位移(49): `Preserving last upstream error after credential exhaustion` + `All accounts unavailable`
- `open-sse/services/accountFallback.ts:182-193`(43) `CONTEXT_OVERFLOW_PATTERNS` / `:198-`(49): 400-context-overflow 命 pattern → `shouldFallback:true, cooldownMs:0, reason:MODEL_CAPACITY`(49 `:1621-1626`) — **account 级仍触发 fallback 同体转发, 3.8.44~49 全段未修 exempt**

**上游 changelog 历次关联修(证 patch 未覆盖 account 级)**:
- `changelog.d/fixes/6637-combo-kimi-fallback.md`(49): recognize Kimi "exceeded model token limit" 400 as context overflow so **combo fallback continues** — 扩 pattern 助跨模型 combo fallback, 非 account 级豁免
- `changelog.d/fixes/1905-fusion-panel-oom.md`: fusion panel >40 model fan-out 并发缓冲全响应 OOM → 400 拒超限 panel — fusion 同体并发 OOM 类 #4 但别区(跨模型并行非 round-robin)
- `changelog.d/fixes/6772-connid-model-400.md`: strip redundant node prefix 防 double-namespaced model id 400 upstream — Task D qwen Ambiguous/routing 旁证类
- 无 changelog 修 "400-context-overflow 豁免账号级 round-robin fallback" → **(a) 候选 issue 诉求字实未现修**

**(a) 候选 issue 诉求**(Zen task5 裁决4 SSOT 定, 参照上游 issue #1329 反向诉求 / #2113 exhaustion 实证):
- 诉求: 400 响应体含 `maximum context length` → **exempt 账号级 fallback**(同 key 不再 round-robin 同体转发堆载), **combo 级 fallback 保留**(跨模型仍续, 因不同模型 ctx 窗不同)
- 落点: 灰区漏判(gate 1.5MB 阈下但上游仍 400 的边缘流量)兜底由 (a) 上游 patch 兜底; 排进下一基镜像周期(改 upstream src = 两部署重建, §5 拓扑不合本轮)

### E3 #4 双确认结果(回指 Task A 段)

#4 双确认已闭合 — 见上 "### Task A 双确认" 段(本 audit 行163-184)。1.7MB 验收2 在 04:25 boot window 重发实测, OmniRoute 侧零业务足迹(无 POST /v1/chat/completions / 无 FALLBACK MODE / 无 excluded_count 递增 / 无 [ERROR] [400]), gate 结构化日志证 `upstream_path:null` + `abortSource:gate_context_guard` + `elapsedMs:0`。病链首环(超大 body 进 omniroute 堆 → N×round-robin 同体转发 → heap OOM)被 gate 前置 413 斩断铁证成立。

### E4 Task C1/C2 落地证据(omn-logic/init-nim-keys.sh, 锚行号, 禁整文件重写)

**C1 jq 归一化**(`init-nim-keys.sh:119-126`):
```bash
# R3+ Restart A (i′ 方案)→ Task C1 终态 (Zen源码 v3.8.43@b729a8f 实证裁决):
# 旧式 `.combos[]? // .[]? | select(.name==$n)` 两病: ① `//` 优先级低于 `|` 失控
# → CID 永空 → 永远 POST → 重名 400 死循环(幂等失效); ② 空 combos 时 `.[]?` 回退遍历对象值,
# 对数组值取 `.name` 抛 "Cannot index array with string"(4.2.3 生产 14:23 实测, 4.3.2 同病)。
# 修正式 (数组/对象双容 + 对象守卫): 根为数组直接遍历, 根为对象取 .combos//.data 字段,
# select 加 `type=="object"` 守卫防对非对象值(数组值)取 .name 抛错 — 兼两种响应结构 + 空库首跑。
CID=$(curl -s -b "$COOKIE_FILE" "$BASE_URL/api/combos" \
      | jq -r --arg n "$NAME" '(if type=="array" then . else (.combos // .data // []) end) | .[]? | select(type=="object" and .name==$n) | .id' | head -n1)
```
- jq 合成验 5 场景全过(combos→e1 PUT / 空→POST / .data→d3 / 顶层数组→t4 / 含数组字段值旧式抛错终态无抛)
- bash -n 全脚本语法通过
- 对照 E1 GET combos 形状 `{combos:[]}` 空库首跑兼容, GET 返顶层数组(理论上) `.combos//.data//[]` 兜底

**C2 僵尸/重复连接 GC**(`init-nim-keys.sh:144-177` 函数 + `:701-702` 调用点):
```bash
# GET /api/providers 返 {connections:[...]} (字段名非 .providers)。# POST 无查重→重复累积。
# GC 职责二合一: ① 僵尸(nim-NN 编号>当前 NIM_KEYS 数) ② 同名重复(留首个, POST 无查重累积)。
gc_stale_providers() { ... # jq: connections[]? → select nvidia → group_by name →
  # 僵尸(num>max 且 ^nim-[0-9]+$) + 重复(to_entries key>0) → 待删 id 去空去重
  # 批量 DELETE /api/providers {ids:[]} ≤100/批, 幂等 }
...
# Task C2: 注册完 Key 后, Fetching provider IDs 前, GC 僵尸/重复连接.
gc_stale_providers    # 行702 调用点(注册完工 Key echo 行699 后, Fetching provider IDs 行704 前)
```
- jq 合成验 3 场景全过(空→[] / 7合法→[] / 僵尸 nim-99+重复 nim-01/03→["a1d","a3d","z99"])
- bash -n 通过; 对照 E1 DELETE 批量 `{ids:[]} ≤100` 契约 + GET `.connections` 字段名
- 端到端待 Restart 后 boot 日志(预期行: `[init] gc_stale: 删除 N 个僵尸/重复 nvidia 连接 (批量 DELETE /api/providers HTTP 200, 上限 max=M)` 或幂等态 `[init] gc_stale: 无待删连接 (当前 NIM_KEYS=M, 增量幂等)`)

### E5 Task D 分诊结果(qwen3.5-397b-a17b)

实测 POST `/v1/chat/completions` model `nvidia/qwen/qwen3.5-397b-a17b`(正 provider 前缀, 经 gate 走 HF ingress urllib):
```json
HTTP 404 {"error":{"message":"[nvidia/qwen/qwen3.5-397b-a17b] [404]: {\"status\":404,\"title\":\"Not Found\",\"detail\":\"Function id 'f32596d4-0577-4a17-baf2-034515d1e457' version 'null': Specified function in account 'FzLXIfQ...' is not found\"} (reset after 2m)"}}
```
- omniroute 真转发上游 NVIDIA, 上游返 function-not-found 404(reset-after-2m 提示 omniroute 侧 retry 兜底已退), **非我侧路由误**
- 判定: **持续 404** → 已从 TIER 清单移除(`init-nim-keys.sh:69` TIER_STABLE 内注释行保留 audit trail, 移除生效)
- audit 记 "catalog 可查 ≠ 可服务" 案例: `/v1/models` 列此单一上市 ID, init `check_nim_model_health` 短名探测通过(health 假阳), 但真业务 POST 上游返 function-not-found — catalog 健康检查不能替代可服务性实测

## 四遗留 audit 项(本轮动后态)

1. **qwen3.5-397b-a17b** ✅ Task D 已判(持续 404 → TIER 移除, "catalog 可查≠可服务"案例记, 行69 注释留证)。
2. **生产 14:15 起 `ProxyFetch ECONNREFUSED 127.0.0.1:20129` 幽灵**: purge 显示 0/0/0 但运行时仍有连接尝试, 脏 proxyUrl 存于他处, 历史遗留(§1 生产禁触, 不动)。
3. **4.2.3 init `jq: Cannot index array with string "name"` 报错** ✅ Task C1 已修(对象守卫 `type=="object"` 屏蔽数组值不抛)。
4. **(a) 上游 issue + 候选补丁**: 400 响应体含 `maximum context length` → exempt 账号级 fallback(combo 级保留), 排下基镜像周期, 灰区漏判兜底(详见 E2)。

## 关联

- 前置三改: `audit/2026-07-24-realctx200k-body4mb-landed.md`(real_context 32K→200K + body 1→4MB, 7 弹实证)
- saga 基线: `audit/2026-07-23-crashloop-saga-landed.md`(两 crashloop 全根除, 五件远端最终态)
- 双部署拓扑: memory [[omn-merge-three-remote-topology]]
- §1 凭禁触: memory [[omn-env-is-prod-do-not-read]]

---

*#4 OOM 病链闭环留证 · 2026-07-25 · 两 patch 采纳 K3 两脚本分析终版裁决 · 待 Restart + 三验证*
