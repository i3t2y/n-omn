# Stage E · audit/10 — task#23 gate ECONNRESET 结构化诊断

> 目标: 基于 task#22 (entrypoint 时序修复后) 重新分析 gate.js ECONNRESET → 503 触发路径, 产出 abort source 分类与 27–187ms abort 根因候选.
> 生成日期: 2026-07-12
> 三基准: B1 nomn/main @ `42ea8e7` | B2 working tree (= candidate HEAD `55e9a8a` + task#21/22 增量) | B3 omniroute-v3.8.43 @ `b729a8f`
> 关联: audit/06 (gate.js SSE/普通代理错误映射评估) · audit/09 (entrypoint 时序修复) · task#20 (New3213 3.txt abort 时间线分析, 上 session 完成)
> 守纪: 本 audit/10 仅 4 项读取 + 现状分析, **0 改代码**; 待 user 确认后行 TEST 13 + 代码修改.
> 试 SEARCH-BOUND: New3213 3.txt 源文件在本机未留存 (仅上 session task#20 分析结论在记忆任务), §3 根因候选部分标"需生产日志确认".

## §1 gate.js ECONNRESET → 503 触发路径实证

### 1.1 已实现的结构化诊断日志 (gate.js L131-161, 即 task#23 主体已落 working tree)

gate.js 已含 **per-request 单行 JSON stderr 日志**, 字段:
```
ts | level=error | component=gate | stage=upstream_proxy | requestId |
method | path | upstream_path | upstream_target=127.0.0.1:20128 |
elapsedMs | httpStatus | errorCode | abortSource | destroyInitiator | msg
```
- L154 `errorCode: fields.errorCode || null` ← `e.code` (ECONNRESET / ETIMEDOUT / UND_ERR_*)
- L155 `abortSource: fields.abortSource || null` ← `classifyAbortSource()` 返回值
- L156 `destroyInitiator: 'gate_timeout' / 'client' / 'upstream' / null`

### 1.2 ECONNRESET → 503 映射 (gate.js L172-177, 已知锚点)

```js
// L174-177
function mapUpstreamStatus(e, { gateTimeout } = {}) {
  if (gateTimeout || e?.code === 'ETIMEDOUT' || e?.code === 'ESOCKETTIMEDOUT') return 504;
  if (e?.code === 'ECONNREFUSED' || e?.code === 'ECONNRESET') return 503;   // ← L176
  return 502;
}
```
- **ECONNRESET → 503** (service_unavailable): 语义 = "上游 socket 被重置, 非网关超时".
- ECONNREFUSED → 503 (同语义: 上游未启): task#22 修复前 OmniRoute 启动时序乱 + 旧条目进内存时, gate 首请求遇 OmniRoute socket 尚未 listen → ECONNREFUSED → 503.
- task#22 修复后 OmniRoute 在 purge + replicate 之后才启 → gate 首请求时 OmniRoute 已 listen → ECONNREFUSED 减, **ECONNRESET 成主要 503 诱因** (空闲连接被上游单方关 reset).

### 1.3 触发路径 (proxyV1 普通代理, gate.js L310-365)

```
client → gate:7860 → http.request(127.0.0.1:20128) [upstreamReq]
  upstreamReq.on('error', e) {                     // L337
    firstError = e;                                // L339 (首 error 不被后续 destroy 覆盖)
    abortSource = classifyAbortSource(e, { gateTimeout, clientAborted });  // L341
    code = clientAborted ? null : mapUpstreamStatus(e, { gateTimeout });    // L342
    if (!gateTimeout) logGate(...);                // L344-354 (单行 JSON stderr)
    if (clientAborted) { res.end(); return; }     // L356-358 (client 已走, 不写响应)
    res.status(code).json({ error, abort_source: abortSource });  // L360-361
  }
```
- ECONNRESET 来源链: upstreamReq 发出 → 上游 (OmniRoute `127.0.0.1:20128`) socket 被 reset (主动 close 空闲 keep-alive, 或 OmniRoute 进程 hot-restart) → Node 错 `code=ECONNRESET` → L337 error handler → L342 `mapUpstreamStatus` ECONNRESET→503 → L361 响 `{abort_source: 'upstream_error'}`.

## §2 abort source 分类现状 (是否已区分)

### 2.1 gate.js 已实现 4 类 (classifyAbortSource L163-170)

```js
function classifyAbortSource(e, { gateTimeout, clientAborted } = {}) {
  if (gateTimeout) return 'timeout';        // gate 30s 主动超时
  if (clientAborted) return 'client_close'; // client 断开 (L324-326 req.on error/aborted/close 标记)
  if (shuttingDown) return 'shutdown';       // gate 优雅关中 (L186 + SIGTERM/SIGINT)
  return 'upstream_error';                    // 其余 (含 ECONNRESET/ECONNREFUSED/上游真错)
}
```

| 类别 | 触发条件 | 标记位 | 502/503/504 |
|------|----------|--------|-------------|
| `timeout` | gate `GATE_UPSTREAM_TIMEOUT_MS` (30s) | L312 `gateTimeout=true` (L329 timeout handler) | 504 |
| `client_close` | client `req` error/aborted/close | L313 `clientAborted=true` (L324-326) | null (不响应 client 已走) |
| `shutdown` | gate SIGTERM/SIGINT 收到 | L186 `shuttingDown=true` | 503 (mapUpstreamStatus 不特殊处理, 落 502/503 按码) |
| `upstream_error` | 其余上游错 (ECONNRESET/ECONNREFUSED/UND_ERR) | 兜底 | ECONNRESET/ECONNREFUSED→503, 余→502 |

### 2.2 缺失: `proxy_connect_failure` (本 task#23 目标第 5 类)

**当前 4 类无单列 `proxy_connect_failure`**:
- gate → OmniRoute 是 `http.request(127.0.0.1:20128)`, **非经 proxy**(无 SOCKS5/HTTP CONNECT). 故 `proxy_connect_failure` 语义对 gate 较弱 (本架构无外 proxy).
- 但 OmniRoute 内部 (proxyFetch.ts) 经 dispatcher 连上游真 provider 时遇 dispatcher/init failure → OmniRoute 抛错 → gate 见的是 OmniRoute 响应 (可能 502/超时), 非直接 ECONNRESET. 故 gate 层 `proxy_connect_failure` 概念 = **"OmniRoute 起不来 / socket 被 reset"**, 当前归 `upstream_error`.

### 2.3 统一抛 AbortError? — 否

gate.js **未用 AbortController 抛 AbortError**; 用 `upstreamReq.destroy()` + 事件钩 (`error`/`timeout`/`close`). client 断开走 `req.on('error'/'aborted'/'close')` 标 `clientAborted` → 不写响应直接 end. **已按 source 区分**, 非统一 AbortError.
- 注: OmniRoute 内部 proxyFetch.ts (B3) 用 undici dispatcher + AbortController (B3 L447 `signal: options.signal`), 但那是 OmniRoute 出站到真 provider 层, gate 转发的是 OmniRoute 响应.

## §3 27–187ms abort 最高概率根因候选 (≤3)

> 源文件 New3213 3.txt 本机未留存 (仅上 session task#20 时间线结论: 27–187ms abort 集中于 v4.3 启动后首请求窗口). 以下基于 proxyFetch.ts (B3) 源码 + gate.js (B2) + 上 session 分析结论. **每项标注实证等级.**

### 候选 A: stale pooled keep-alive socket (undici dispatcher #4252, attempt 0)

- **机制**: B3 `proxyFetch.ts` L483 `dispatcher: attempt === 0 ? getDefaultDispatcher() : getRetryDispatcher()`. attempt 0 用 **pooled keep-alive dispatcher**; 若该 pool 内 socket 已被上游 provider 空闲单方 close (server-side keep-alive timeout 短于 client pool TTL), 取出复用即首字节 ECONNRESET.
- **27–187ms 区间**: TTL 失效 socket 取出 → 发请求 → 等 RST/连接 reset → 约 1×RTT 级 (27-187ms 与 TCP RST + gate 30s timeout 远小于), **符**.
- **v4.2.3 vs v4.3 差异**: v4.2.3 native fetch (无 undici v8 dispatcher) pool 行为/keep-alive 管理由 Node http.Agent (默认 `keepAlive=true`, `keepAliveMsecs=1000`); v4.3 用 undici `getDefaultDispatcher()` (Pool, keep-alive 默认开 + 连接复用激进). **v4.3 pool 复用率高 → 命中 stale socket 概率高**. ← 已由源码确认 (proxyFetch.ts L458-519 dispatcher 逻辑).
- **v4.3 retry 漏 ECONNRESET**: L500-506 retry 条件 `msg.includes("fetch failed") || errCode === "ECONNREFUSED" || errCode.startsWith("UND_ERR")`, **不含 `ECONNRESET`** (L504 仅 ECONNREFUSED). 故 ECONNRESET 不触发 retry → 直接 throw 上抛 → gate 见 503. ← 已由源码确认.

**实证等级: 已由源码确认 (proxyFetch.ts + gate.js)**. 生产日志需看的: `errorCode=ECONNRESET` + `abortSource=upstream_error` + `elapsedMs 27-187` 区间集中.

### 候选 B: OmniRoute 启动时序残留幽灵 (task#22 D1 修复前原状)

- **机制**: entrypoint 旧时序 (task#22 修复前) 下 OmniRoute 在 purge/replicate 前启动 → 内存含 R2 旧库带回的幽灵 `proxy_registry` 条目 (host/port 失效) → proxyFetch 用 dispatcher 连失效幽灵 → connect 失败/超时/RESET.
- **区间**: 命中失效 endpoint → TCP connect timeout 27-187ms 不符 (connect 失败应 ECONNREFUSED 或更长 timeout). 部分 retry path 可能落此区间.
- **v4.3 vs v4.2.3 差异**: v4.3 加 litestream R2 + 启动时序变更 (旧时序缺陷 D1-D6), v4.2.3 阶段无 R2/无幽灵回带 → 此问题 v4.3 独有.
- **现状 (task#22 后)**: D1 修复 (pre-purge 事务 + assert 残留=0) → 启动后 OmniRoute 内存无幽灵 → **候选 B 在 task#22 修复后应消失**.

**实证等级: 需生产日志确认** (task#22 后需复验生产是否有 27-187ms ECONNRESET, 若无 → 候选 B 被 D1 修掉; 若仍有 → 候选 A 为主).

### 候选 C: undici dispatcher 与 native fetch 版本不匹配 (onRequestStart, #1054)

- **机制**: B3 L490-494 `msg.includes("onRequestStart")` → FATAL version mismatch ( Dispatcher v8 vs Fetch v6 ). Node 22 built-in fetch (undici v6) 与 undici v8 dispatcher 不兼容 → onRequestStart 未触发 → 请求挂起后被 abort/reset.
- **区间**: dispatcher init fail → 退 native fetch (L460 注) 或 throw → 27-187ms 不符 manifest (mismatch 多为瞬时失败或长挂起).
- **v4.3 vs v4.2.3 差异**: v4.2.3 用相同 undici 版本路径, 此为版本环境问题, **非 v4.3 时序特有**.

**实证等级: 需生产日志确认** (日志 `msg=FATAL version mismatch` 会显式打, 易识别; 若 New3213 无此串排除).

### 3.x 根因排序 (概率高→低)

1. **候选 A (stale pooled socket + retry 漏 ECONNRESET)** — 最高概率, 已由源码确认机制, 与 27-187ms 区间符.
2. ~~候选 B (幽灵条目)~~ — task#22 D1 修复后应消失, 待生产复验.
3. **候选 C (dispatcher 版本不匹配)** — 低概率 (会 FATAL 显式打日志), 待排除.

## §4 拟修改 diff 预览 (不写入代码)

### 4.1 第 5 类 abort source: `proxy_connect_failure` (语义重定义为 "upstream socket reset on connect/first-byte")

gate 层无外 proxy, 但为区分"上游刚连上即被 reset"(候选 A stale socket) vs"上游真业务 5xx 错"(upstream_error 内的 HTTP 5xx), 拟增第 5 类:

**gate.js `classifyAbortSource` (L165-170) 拟改:**
```js
function classifyAbortSource(e, { gateTimeout, clientAborted, elapsedMs } = {}) {
  if (gateTimeout) return 'timeout';
  if (clientAborted) return 'client_close';
  if (shuttingDown) return 'shutdown';
  // 新增: 上游 connect/first-byte 阶段被 reset (ECONNRESET 短时窗) → proxy_connect_failure
  // 区分于 upstream_error (上游已响应 5xx 后流中断)
  if (e?.code === 'ECONNRESET' && typeof elapsedMs === 'number' && elapsedMs < 5000) {
    return 'proxy_connect_failure';
  }
  return 'upstream_error';
}
```
- 调用点 L341 加传 elapsedMs: `classifyAbortSource(e, { gateTimeout, clientAborted, elapsedMs: Date.now() - (req._gateT0 || 0) })`.
- `mapUpstreamStatus` 不改 (ECONNRESET 仍 503), 仅 abortSource 区分更细供诊断.

### 4.2 error 日志补 client→upstream 方向 (gate.js L143-159 JSON 缺方向)

拟补字段 `socketPhase: 'connecting' | 'headers' | 'streaming' | null` (从 upstreamReq 状态钩子取), 用于判 27-187ms ECONNRESET 落哪相:
- `connecting` → 候选 A (stale socket, 连上即 reset)
- `headers`/`streaming` → 上游已响应后续断

```js
const line = JSON.stringify({
  ...,
  socketPhase: fields.socketPhase || null,    // 新增
  ...
});
```
upstreamReq 关联钩 (`socket`/`connect`/`response` 事件) 更新 `req._socketPhase`.

### 4.3 SSE 路径同步结构化 (gate.js L296-305 当前 SSE error 用固定 'upstream_error')

SSE 路径 L303-305 当前硬码 `abortSource: 'upstream_error'`, 拟复用 `classifyAbortSource`:
```js
// L304 拟改
const abortSource = classifyAbortSource(e, { gateTimeout, clientAborted, elapsedMs: Date.now() - (req._gateT0||0) });
logGate(req, { ..., abortSource, ... });
```

### 4.4 TEST 13 拟新增 (不写入, 待确认后)

| 用例 | 验证 |
|------|------|
| TEST 13-01 | ECONNRESET + elapsedMs<5000 → `abortSource: 'proxy_connect_failure'`, status 503 |
| TEST 13-02 | ECONNRESET + elapsedMs>5000 (流中断) → `abortSource: 'upstream_error'`, status 503 |
| TEST 13-03 | timeout → 504 `abortSource: 'timeout'` (复验已存) |
| TEST 13-04 | client close → `abortSource: 'client_close'`, 无响应 (已存) |
| TEST 13-05 | socketPhase tracking: mock 上游 emit 'socket'/'connect'/'response' → 日志含 socketPhase |
| TEST 13-06 | SSE 路径 ECONNRESET → classifyAbortSource 复用 (非硬码 'upstream_error') |
| TEST 13-07 | 现有 80 PASS 零改动断言回归 (TEST 1-12 仍 PASS=80 FAIL=0) |

## §5 待确认 + 守纪

### 5.1 需 user 确认

1. §4.1 第 5 类 `proxy_connect_failure` 语义 (gate 无外 proxy, 此命名是否妥? 或重命名 `upstream_reset_short_lived`?)
2. §4.2 `socketPhase` 字段增 + upstreamReq 钩子开销是否接受
3. §4.4 TEST 13 7 用例是否全列 + 是否需 P1-P6 对照 NEEDS-INSTANCE 标

### 5.2 守纪

- 本 audit/10 仅读 (gate.js 全文 + proxyFetch.ts L413-560 + §3 上 session task#20 记忆结论 + 无 New3213 原文件), 0 改代码, 0 install, 0 访生产.
- §3 项 A 源码层已确认机制, 项 B/C 需生产日志; 不擅自断言生产状态.
- 待 user 确认后行 §4 diff 落 + TEST 13 + 回归 (期 PASS=87 FAIL=0 SKIP=2).
