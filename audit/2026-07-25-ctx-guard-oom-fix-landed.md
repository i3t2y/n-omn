# #4 OOM 病链闭环留证: gate 前置单阈值 ctx guard + entrypoint 4096 回归

**日期**: 2026-07-25 本地改(omn-logic) → 推推待(nonoke/omn-logic Dataset) → Restart + 三验证(待 Supreme 手)
**Space**: nonoke-omn.hf.space(永续 dev, bucket omn-data, cpu-basic 2vCPU/16GB)
**链**: HF Dataset `nonoke/omn-logic` 五件之 entrypoint.sh + gate.js 两件改推
**律**: §1 双空间铁律——nomke/omn 生产零触(4.2.3 日志只取证不引用支撑 dev 结论); §5 upstream/ 两棵树只读禁整树替换、禁直接运行、禁入生产(本改改 gate 自有代码非 upstream src, §5 零风险); §3 secret/token 值零入; §7 Space Restart Supreme 手动不变. **窗规已解除**(2026-07-23 Supreme"后续推送无需逐批"), dev Dataset push ambient 授权.

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

### 4.2.3 生产侧等效件(可选, 圣上手)

4.2.3 gate.js 是 http-proxy-middleware 版, 在 PSK 中间件之后、`app.use('/', createProxyMiddleware(...))` 之前插入与 B2 相同的中间件函数即可(该文件无 logGate, 日志换 `console.error(JSON.stringify({...}))` 或省略)。4.2.3 entrypoint 已有 4096 内联无需 Patch A。**§1 生产禁触, 等效件由 Supreme 手动**。

## 阈值推导(1500000B)

- 标定: dev+生产两起真实 400 的 NVIDIA 实测比率上界 = 8 bytes/token(弹H 3900147B→487511tok)。
- 1500000B @ 8B/tok ≈ 187500 token, 距 200000 软限留 12500 余量(给 tokenizer 波动 / 39-tools schema 口径差, 实测偏差 40% 的缓冲)。
- 灰区估算数学退化证据: est = bytes/8 > 195000 ⟺ bytes > 1560000, 灰区上界 1.5MB(1500000) < 1.56MB, 故灰区内按 8B/tok 永不触阈。

## KNOWN-LIMITATION

1. **无 content-length 的 chunked 上传不拦**: 现有客户端日志均带 content-length, chunked 流式输入超界由上游自拒兜底。
2. **比率 <8 的假想流量可能漏拦**: 实测最小 8.0 B/tok, 比率更小(同字节 token 更多)的假想流量可能漏过 1.5MB 阈。由 NODE_OPTIONS 4096 堆(Patch A)+ fallback exhaustion 终态兜底, (a) 上游 issue 落地后彻底闭合。

## 部署

两文件在 Dataset(nonoke/omn-logic), push 后 Restart 即生效零 Rebuild(逻辑层 bootstrap 运行时拉取)。§5 风险为零(改 gate 自有代码非 upstream src)。推推法: `huggingface_hub upload_file` 单件推, token 走 `~/.cache/huggingface/token` 库默认缓存读, 值零入推脚本零入会话零入 git, /tmp 临时推完即删。

## 三项验证标准(Restart 后 Supreme 跑)

1. **回归(无误伤)**: 重放一笔已证合法真实流量(约 1.08MB / 137K tokens, 低于 1.5MB 阈值)→ **必 200 流式返回**。证明单阈值没误伤正常流量。
2. **拦截(#4 闭合铁证)**: 发一笔 >1.6MB 合成 POST → **必收 413 context_length_exceeded**, 且 OmniRoute 侧日志**无任何对应 POST /v1/chat/completions 记录、无 fallback 序列**。证明请求没进 omniroute 堆, 病链首环被斩。
3. **堆上限**: 容器内 `ps -o args= -C node` 应见 `server.js` 进程带 `--max-old-space-size=4096`。

## 四遗留 audit 项(非本轮动, 记入候)

1. **qwen3.5-397b-a17b**: catalog 可查但 POST 探针 404。catalog 健康检查≠可服务, 池内可能注册了不可服务模型。
2. **生产 14:15 起 `ProxyFetch ECONNREFUSED 127.0.0.1:20129` 幽灵**: purge 显示 0/0/0 但运行时仍有连接尝试, 脏 proxyUrl 存于他处, 历史遗留。
3. **4.2.3 init 模型注册后 `jq: Cannot index array with string "name"` 报错**: 需确认 4.3.2 是否已修。
4. **(a) 上游 issue + 候选补丁**: 400 响应体含 `maximum context length` → exempt fallback, 排下基镜像周期, 灰区漏判兜底。

## 关联

- 前置三改: `audit/2026-07-24-realctx200k-body4mb-landed.md`(real_context 32K→200K + body 1→4MB, 7 弹实证)
- saga 基线: `audit/2026-07-23-crashloop-saga-landed.md`(两 crashloop 全根除, 五件远端最终态)
- 双部署拓扑: memory [[omn-merge-three-remote-topology]]
- §1 凭禁触: memory [[omn-env-is-prod-do-not-read]]

---

*#4 OOM 病链闭环留证 · 2026-07-25 · 两 patch 采纳 K3 两脚本分析终版裁决 · 待 Restart + 三验证*
