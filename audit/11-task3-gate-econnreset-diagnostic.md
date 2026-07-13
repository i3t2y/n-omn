# Stage E · audit/11 — 任务三#23 gate ECONNRESET 结构化诊断 + abort source 区分修复报告

> 目标: 实证 task#23 (gate ECONNRESET 结构化诊断 + abort source 区分) **已落 working tree** 且 **mock 验全 PASS**.
> 生成日期: 2026-07-12
> 三基准: B1 nomn/main @ `42ea8e7` | B2 working tree @ `9a1a7f0` (= candidate HEAD = `55e9a8a`) | B3 omniroute-v3.8.43 @ `b729a8f`
> 关联: audit/02-claim-matrix.md (CF-4) · audit/05-test-results.md ·
>   audit/06-任务一修复报告 · audit/09-任务二修复报告 ·
>   candidate-v4.3-reviewed/gate.js (classifyAbortSource / mapUpstreamStatus / proxyV1)
> 守纪: 仅改 candidate-v4.3-reviewed (working tree), 未访问生产实例, 未 install 依赖, 未改源码 B3.
> 测试结论: **PASS=88 FAIL=0 SKIP=2** (TEST 13 全 PASS, 80 旧测试零改动; 对比任务二 80 PASS → 88 PASS, +8 = TEST 13).

## 0. 缺陷根因 (audit/02 CF-4 + audit/05 实证背景)

候选此前 gate proxyV1 上游 error handler **硬码** AbortSource 归类: 凡收上游 error 即
`abort_source='upstream_error'`, 不区分三类真实起因:
- gate 主动超时 destroy (timeout handler 已先 504 回写 + 计 `timeout`, 但 global error handler 仍触发反发 destroy, 重复打日志且误写 `upstream_error`)
- 客户端先断 (gate cleanup 反发 destroy upstreamReq)
- 上游真错 / 短时窗 stale pooled socket reset (ECONNRESET, 短 elapsedMs)

调查证据 (New3213 3.txt 失败请求 abort 时间线, task#20 实证): gate 多条
`upstream_reset` 候选但 ECONNRESET 短时窗 (<5000ms) 与长时窗 (>5000ms 同 SSE/流相) 不可区分,
诊断标记错配 → 触发误判条件 (误把 stale pooled socket reset 当 transport_err 触发上 retry). CF-4
红线: **abort source 区分缺失, 结构化诊断信息不足**.

## 1. 修复内容 (gate.js, 三处合 + 一处 log field)

### 1.1 classifyAbortSource — 5 类优先级判定 (L169-177)

```js
// abort source 区分: 上游 error 事件 + 标记位判断谁发起 destroy
//   gateTimeout=true → 'timeout'; clientAborted=true → 'client_close'; shuttingDown → 'shutdown';
//   ECONNRESET + elapsedMs<5000 → 'upstream_reset' (短时窗 socket reset, 候选 stale pooled socket);
//   else 'upstream_error'.
//   timeout/client_close/shutdown 三类判断逻辑不变 (task#23 仅增 upstream_reset 兜底前).
function classifyAbortSource(e, { gateTimeout, clientAborted, elapsedMs } = {}) {
  if (gateTimeout) return 'timeout';
  if (clientAborted) return 'client_close';
  if (shuttingDown) return 'shutdown';
  if (e?.code === 'ECONNRESET' && typeof elapsedMs === 'number' && elapsedMs < 5000) {
    return 'upstream_reset';
  }
  return 'upstream_error';
}
```

优先级: timeout > client_close > shutdown > upstream_reset (ECONNRESET+短时窗) > upstream_error.
三类前两类 (timeout/client_close) 判断逻辑与修前一致 (task#23 仅在 **三之后** 增 upstream_reset
兜底, 即不打 504 重复日志 + 不改 timeout handler 已 504 回写路径). shutdown 优先于 ECONNRESET
判定 (进程关闭期 destroy 不归类 reset).

### 1.2 mapUpstreamStatus — 对外 HTTP 状态码契约零改动 (L181-189)

```js
// ECONNREFUSED/ECONNRESET=503, timeout/ETIMEDOUT/ESOCKETTIMEDOUT=504, 其余=502
function mapUpstreamStatus(e, { gateTimeout } = {}) {
  if (gateTimeout || e?.code === 'ETIMEDOUT' || e?.code === 'ESOCKETTIMEDOUT') return 504;
  if (e?.code === 'ECONNREFUSED' || e?.code === 'ECONNRESET') return 503;
  return 502;
}
```

对外 HTTP 契约 (503/504/502) **零改动**. abortSource 仅作结构化日志 + 响应 body
`abort_source` 字段附加诊断, 不改 status 码. TEST 13-02 静态实证 mapUpstreamStatus 状态码契约不变.

### 1.3 socketPhase 三相跟踪钩子 (L299, L322-325)

```js
// entry: http.request 后同步设 connecting
req._socketPhase = 'connecting';
upstreamReq.on('socket', (socket) => {
  socket.on('connect', () => { if (req._socketPhase === 'connecting') req._socketPhase = 'headers'; });
});
// response head 收到 (callback 块入口): streaming
req._socketPhase = 'streaming';
```

三相: connecting (http.request 构造 → 尚未 connect) → headers (socket.on('connect') 真握手) →
streaming (upstreamRes callback 收响应头, 含 SSE 逐块). 供 upstream_reset/upstream_error 日志
区分断在哪相 (ECONNRESET 在 connecting=stale pooled socket, streaming=SSE 流断).

### 1.4 proxyV1 上游 error handler 复用 classifyAbortSource + socketPhase 附加 (L355-375)

```js
upstreamReq.on('error', (e) => {
  if (!firstError) firstError = e;
  const elapsedMs = Date.now() - (req._gateT0 || 0);
  const abortSource = classifyAbortSource(e, { gateTimeout, clientAborted, elapsedMs });
  const code = clientAborted ? null : mapUpstreamStatus(e, { gateTimeout });
  if (!gateTimeout) {
    // socketPhase 仅附加于 upstream_reset/upstream_error (timeout/client_close/shutdown 不附, 非其语义)
    const phase = (abortSource === 'upstream_reset' || abortSource === 'upstream_error')
      ? (req._socketPhase || null) : null;
    logGate(req, { elapsedMs, httpStatus: code, errorCode: e?.code || null,
      abortSource, socketPhase: phase,
      destroyInitiator: clientAborted ? 'client' : 'upstream',
      msg: clientAborted ? 'client_disconnected_proxy_aborted'
        : (abortSource === 'upstream_reset' ? 'upstream_socket_reset_short_lived' : 'upstream_error') });
    if (!res.headersSent && code) {
      res.status(code).json({ error: statusErrorLabel(code), abort_source: abortSource });
    } else if (!res.writableEnded && !clientAborted) {
      res.end();
    }
  }
});
```

要点:
- `firstError` 守门: 首个 error 仅记一次, 后续 destroy 同事件反发不覆盖诊断 (timeout handler
  destroy → global error 反发再用 firstError 比对 attneded 流程).
- `clientAborted` → code=null (不回写, client 已走) + destroyInitiator='client' + msg
  `client_disconnected_proxy_aborted`.
- gateTimeout 已由 timeout handler 自己打 504 日志, global error handler `if (!gateTimeout)` 跳
  (不打 504 重复日志).
- `socketPhase` 仅附 upstream_reset/upstream_error; 三类语义外 (timeout/client_close/shutdown) 不附.

### 1.5 upstreamRes (响应流中途错) handler 同样复用 classifyAbortSource (L308-319)

```js
upstreamRes.on('error', (e) => {
  const elapsedMs = Date.now() - (req._gateT0 || 0);
  const abortSource = classifyAbortSource(e, { gateTimeout, clientAborted, elapsedMs });
  logGate(req, { elapsedMs, httpStatus: 502,
    errorCode: e?.code || e?.message || 'upstream_response_stream_error',
    abortSource, socketPhase: req._socketPhase || 'streaming',
    destroyInitiator: 'upstream', msg: 'upstream_response_stream_error' });
  if (!res.headersSent) res.status(502).json({ error: 'bad_gateway', abort_source: abortSource });
  else if (!res.writableEnded) res.end();
});
```

响应流中途错 (已 head, 非 connect 错): 502 + socketPhase 默认 streaming (流相内中断).

### 1.6 logGate 输出字段增 socketPhase (L154-158)

```js
errorCode: fields.errorCode || null,
abortSource: fields.abortSource || null,
socketPhase: fields.socketPhase || null,
destroyInitiator: fields.destroyInitiator || null,
msg: fields.msg || null,
```

修前 logGate 不输出 socketPhase 字段 → proxyV1 L366 虽传 phase 但 JSON.stringify 丢 undefined.
**关键 bug**: 第一次跑 T13-04 实证 stderr JSON **缺 socketPhase 字段** (因为 logGate L154-158
serialize 不到 socketPhase 项), 修即在 logGate 加 `socketPhase: fields.socketPhase || null` 输出项.

## 2. 测试矩阵 (TEST 13, tests/test-runner.js)

7 项 (T13-01..07), mock 上游 Node http.createServer (127.0.0.1:0), 不访真实实例.

| 用例 | 类型 | mock 场景 | 断言 |
|------|------|----------|------|
| T13-01 | 静态 | classifyAbortSource 5 类 + 顺序 + proxyV1 SSE 复用 | timeout>client_close>shutdown>upstream_reset>upstream_error; phase attach 正则 `const phase = (abortSource === 'upstream_reset' \|\| abortSource === 'upstream_error')`; logGate 输出 socketPhase |
| T13-02 | 静态 | mapUpstreamStatus 对外 503/504/502 零改动 | ECONNRESET→503, ETIMEDOUT→504, gateTimeout→504, 其余→502 |
| T13-03 | 静态 | socketPhase 三相钩子 exist | L299 `streaming` + L323 `connecting` + L325 `connect→headers` 三行 |
| T13-04 | 动态 | 短时窗 ECONNRESET (mock 上游立即 socket.destroy) | 503 + abortSource=upstream_reset + elapsedMs<5000 + socketPhase ∈ connecting/headers |
| T13-05 | 动态 | 长时窗 ECONNRESET (>5000ms, mock 上游 delay 5.5s 后 reset) | 503 + abortSource=upstream_error (非 upstream_reset) + elapsedMs>=5000 |
| T13-06 | 动态 | timeout (mock 上游 hang, gate 5s 超时) | 504 + abortSource=timeout + destroyInitiator=gate_timeout |
| T13-07 | 动态 | client close (client flushHeaders 后 80ms 主动 destroy) | abortSource=client_close + 无 503 回写 + socketPhase null + destroyInitiator=client |

T13-01 各 phaseAttach 正则位点 (实证 gate.js):
- classifyAbortSource 5 类判定 (L169-176)
- proxyV1 L364 `const phase = (abortSource === 'upstream_reset' || abortSource === 'upstream_error') ? (req._socketPhase || null) : null;`
- logGate L155 `socketPhase: fields.socketPhase || null`

## 3. 测试结果

跑命令: `cd candidate-v4.3-reviewed && node tests/test-runner.js`
退出码: 0
结果: **PASS=88 FAIL=0 SKIP=2**

TEST 13 段输出 (relative to TEST 13 print):
```
TEST 13: gate ECONNRESET 结构化诊断 (abortSource 区分 + socketPhase)
  ✓ T13-01 静态: classifyAbortSource 5 类 + 顺序 + proxyV1 SSE 复用 (timeout/client_close/shutdown 逻辑不变)
  ✓ T13-02 静态: mapUpstreamStatus 对外 HTTP 状态码契约 (503/504) 零改动
  ✓ T13-03 静态: socketPhase 三相跟踪钩子 (connecting/headers/streaming) 存在
  ✓ T13-04 动态: 短时窗 ECONNRESET → upstream_reset + 503 + socketPhase(connecting/headers)
  ✓ T13-07 动态: client close → client_close (无 503 回写, 无 socketPhase)
  ✓ T13-06 动态: timeout → 504 + abortSource=timeout (三类优先级不变)
  ✓ T13-05 动态: 长时窗 ECONNRESET → upstream_error (elapsedMs>=5000) + 503
PASS=88 FAIL=0 SKIP=2
```

SKIP=2 同前两任务报告 (instance-test deferred to post-deploy; 不在 mock 覆盖范围).

## 4. 调试过程关键发现 (T13-07 渡关记录)

### 4.1 socketPhase 字段缺失 (T13-04 首跑)

首跑 T13-04 stderr JSON 不含 socketPhase 字段, 原因: proxyV1 L366 虽传 phase 但 logGate L154-158
serialize 输出对象无 socketPhase 项 → JSON.stringify 丢 undefined. 修在 logGate 加
`socketPhase: fields.socketPhase || null` 输出项 (§1.6). T13-01 #8 第二断言实证该行存在
(`/socketPhase: fields\.socketPhase \|\| null/.test(GATE_SRC)`).

### 4.2 T13-07 client close 触不出 req close (T13-05/06 PASS 后 11 次挂)

bg4 真实场景 PASS, test 环境挂 (loglen 99 仅 gate boot 行). root:
test req `http.request` 后调 `r.flushHeaders()` **缺** + 改用 `setTimeout(80, destroy)` 掉了
setImmediate flushHeaders 路径 → req SYN **从未送出** → gate 不见 req close → 无 client_close log.
dbg6 单独 spawn 同样挂因缺 flush. dbg4/dbg7 raw spawn **有** `r.flushHeaders()` 即 PASS.
修: test T13-07 req **先** `r.flushHeaders()` 主动推 SYN+headers, 再 setTimeout 80ms 给完整握手,
再 destroy (gate 收 req close 事件触发 cleanup → upstreamReq.destroy → error emit client_close).
gate stderr emit 异步 (req close → cleanup → upstreamReq.destroy → error emit → stderr flush) 滞后,
加 10×80ms retry loop 抓 JSON 行 (见 §2 测试代码).

## 5. 守纪与边界

- 仅改 candidate-v4.3-reviewed/gate.js + tests/test-runner.js, 未改源码 B3 (omniroute-v3.8.43) —
  gate.js 是候选自有层 (CF-3 候选 gate 修补, 非 OmniRoute 源码).
- 未 install 依赖, 未访问生产实例, 未切换分支.
- 三类前类 (timeout/client_close/shutdown) 判断逻辑零改动 (task#23 仅增 upstream_reset 兜底前不动三类).
- 对外 HTTP 状态码契约 (503/504/502) 零改动 (mapUpstreamStatus 不变).

## 6. 后续 (post-deploy)

- 实例端 readback: 真实 ECONNRESET 场景 (stale pooled socket reset / SSE 流断) 触发后,
  gate stderr 应含 `abort_source='upstream_reset'` 或 `'upstream_error'` 结构化行,
  socketPhase 字段实 ∈ connecting/headers/streaming. 见 audit/07 R5.K2.1 实例 readback 计划.
- 与 init/entrypoint 诊断 (任务二 §3 audit/09) 对照: gate upstream error 日志 `abort_source`
  字段供 entrypoint 启动期 litestream restore / resilience PATCH 解读活路径层诊断,
  非误判 transport_err (CF-4 修).
