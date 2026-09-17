// 后台 (admin) 路径端到端回归单测 —— 补 2026-09-18 评审发现的「admin 零自动化覆盖」缺口。
//
// 为什么单列一份: 既有 5 份测试**全部只打 /v1**。而 gate 的三类入口是分离的
//   (/healthz 免认证 | /v1 走 PSK | 其余全路径走后台透传), /v1 的绿**推不出**后台的绿。
//   2026-09-18 重构把 proxyAdmin 原本自有的 ~60 行生命周期代码换成了与 proxyV1 共用的
//   attachUpstreamLifecycle(), 后台路径从此**依赖共用件的 opts 分支** —— 这类"抽共用件"型
//   重构最典型的回归形态是: 测试全绿, 但被抽的那一路因 opts 传错而静默改行为。
//   本文件即为该风险的反向断言。
//
// 覆盖 (三项):
//   T1 后台冒烟  — 开关开: 登录页 + /api/auth/login 直透传 (body/host 保真, 零改写);
//                  开关关: 全路径 404 门藏; admin 开时 /v1 无 PSK 仍 401 (三类入口不串)
//   T2 后台超时  — 上游不响应 → 504 + 日志带 admin_ 前缀 + abortSource=timeout
//   T3 后台客户端断开 — 归因 client_close, 日志 msg=admin_client_disconnected_proxy_aborted,
//                  且 httpStatus=null (不对已断开的 client 写响应), gate 进程存活
//
// 跑法 (express 是 gate.js 的运行期依赖, 需 NODE_PATH 指向已装 express 的目录):
//   NODE_PATH=<node_workspace>/node_modules node --test logic/tests/admin.e2e.test.js
//   仅跑本文件; 全量: NODE_PATH=... node --test logic/tests/
// 端口随机取 (避免并行/残留冲突); 每个用例独立起一轮 gate, 结束 SIGKILL 回收。
'use strict';

const test = require('node:test');
const assert = require('node:assert');
const http = require('node:http');
const { spawn } = require('node:child_process');
const path = require('node:path');

const PSK = 'test-psk-0123456789abcdef';
const GATE = path.join(__dirname, '..', 'gate.js');

// ── 假上游 (顶替 127.0.0.1:$OR_PORT 的 OmniRoute) ────────────────────────────
async function withUpstream(handler, cb) {
  const srv = http.createServer((req, res) => handler(req, res));
  return new Promise((resolve, reject) => {
    srv.listen(0, '127.0.0.1', async () => {
      const orPort = srv.address().port;
      try { await cb(orPort, srv); } catch (e) { await new Promise((r) => srv.close(r)); return reject(e); }
      await new Promise((r) => srv.close(r));
      resolve();
    });
  });
}

// ── 起真 gate.js 子进程 ──────────────────────────────────────────────────────
// 返回: { port, request(), waitLog(), stdoutText, stop() }
//   waitLog(pred, timeoutMs): 轮询已解析的 stderr JSON 日志行 (gate 的 logGate 是单行 JSON)
async function startGate(orPort, env = {}) {
  const port = await new Promise((res) => {
    const t = http.createServer();
    t.listen(0, '127.0.0.1', () => { const p = t.address().port; t.close(() => res(p)); });
  });
  const child = spawn(process.execPath, [GATE], {
    env: {
      ...process.env,
      INTERNAL_PSK: PSK,
      OMNIROUTE_API_KEY: 'sk-test-key',
      OMNIROUTE_PORT: String(orPort),
      EXPOSED_PORT: String(port),
      // 默认给足: 只有 T2 显式压低, 避免"上游慢"被误判成超时
      GATE_UPSTREAM_TIMEOUT_MS: '60000',
      ...env,
    },
    stdio: ['ignore', 'pipe', 'pipe'],
  });

  const logs = [];          // 已解析的 logGate JSON 行
  let stdoutText = '';
  let errBuf = '';
  child.stdout.on('data', (b) => { stdoutText += String(b); });
  child.stderr.on('data', (b) => {
    errBuf += String(b);
    let i;
    while ((i = errBuf.indexOf('\n')) >= 0) {
      const line = errBuf.slice(0, i);
      errBuf = errBuf.slice(i + 1);
      if (!line.trim()) continue;
      try { logs.push(JSON.parse(line)); } catch { /* 非 JSON (堆栈等), 忽略 */ }
    }
  });
  let exited = null;
  child.on('exit', (code) => { exited = code; });

  await new Promise((resolve, reject) => {
    const to = setTimeout(() => reject(new Error('gate 未在 8s 内启动 (express 装了吗? NODE_PATH 设了吗?)')), 8000);
    const onData = () => {
      if (stdoutText.includes('listening')) { clearTimeout(to); child.stdout.off('data', onData); resolve(); }
    };
    child.stdout.on('data', onData);
    child.on('exit', (c) => { clearTimeout(to); reject(new Error(`gate 提前退出 rc=${c}`)); });
  });

  const request = (opts) => new Promise((resolve, reject) => {
    const { method = 'GET', path: p = '/', headers = {}, body = null, abortAfterMs = 0 } = opts;
    let settled = false;
    const req = http.request({ host: '127.0.0.1', port, method, path: p, headers }, (res) => {
      const chunks = [];
      res.on('data', (c) => chunks.push(c));
      res.on('end', () => {
        if (settled) return;
        settled = true;
        resolve({ status: res.statusCode, headers: res.headers, body: Buffer.concat(chunks).toString(), aborted: false });
      });
    });
    req.on('error', (e) => { if (!settled) { settled = true; resolve({ aborted: true, error: e }); } });
    if (abortAfterMs > 0) {
      setTimeout(() => {
        if (settled) return;
        settled = true;
        req.destroy(new Error('client abort'));
        resolve({ aborted: true });
      }, abortAfterMs);
    }
    if (body != null) req.write(body);
    req.end();
  });

  const waitLog = async (pred, timeoutMs = 8000, label = '') => {
    const t0 = Date.now();
    while (Date.now() - t0 < timeoutMs) {
      const hit = logs.find(pred);
      if (hit) return hit;
      if (exited !== null) throw new Error(`gate 进程已退出 rc=${exited}, 等不到日志 ${label}`);
      await new Promise((r) => setTimeout(r, 20));
    }
    throw new Error(`等不到匹配的 gate 日志 (${label}); 已收 ${logs.length} 行: ${JSON.stringify(logs.slice(-3))}`);
  };

  return {
    port,
    request,
    waitLog,
    get logs() { return logs; },
    get stdoutText() { return stdoutText; },
    stop: () => { try { child.kill('SIGKILL'); } catch { /* noop */ } },
  };
}

// ── 假上游: 后台页 + /api/auth/login 回显 (验透传保真) ────────────────────────
function adminUpstream() {
  return (req, res) => {
    if (req.url === '/' || req.url === '/admin') {
      res.writeHead(200, { 'content-type': 'text/html; charset=utf-8' });
      return res.end('<html><body>OR ADMIN</body></html>');
    }
    if (req.url.startsWith('/api/auth/login')) {
      const chunks = [];
      req.on('data', (c) => chunks.push(c));
      req.on('end', () => {
        res.writeHead(200, { 'content-type': 'application/json' });
        res.end(JSON.stringify({
          echoed: {
            method: req.method,
            path: req.url,
            host: req.headers.host || null,
            trace: req.headers['x-trace'] || null,
            authorization: req.headers.authorization || null,
            body: Buffer.concat(chunks).toString(),
          },
        }));
      });
      return;
    }
    res.writeHead(404, { 'content-type': 'application/json' });
    res.end('{"error":"mock_404"}');
  };
}

// ════════════════════════════════════════════════════════════════════════════
// T1 后台冒烟
// ════════════════════════════════════════════════════════════════════════════

test('T1a 后台开: 登录页 GET / 直透传 200, 内容原样到达', async () => {
  await withUpstream(adminUpstream(), async (orPort) => {
    const g = await startGate(orPort, { GATE_ADMIN_ENABLED: '1' });
    try {
      assert.match(g.stdoutText, /admin UI: enabled/, 'GATE_ADMIN_ENABLED=1 应打印 enabled');
      const r = await g.request({ path: '/' });
      assert.equal(r.status, 200, `后台首页应 200, 实际 ${r.status}`);
      assert.match(r.body, /OR ADMIN/);
      assert.match(r.headers['content-type'], /text\/html/);
      // 透传语义: 上游正常完成, gate 记 info 级 upstream_completed (注意: 后台路径该 msg **不带** admin_ 前缀)
      const line = await g.waitLog((l) => l.msg === 'upstream_completed', 5000, 'upstream_completed');
      assert.equal(line.level, 'info');
      assert.equal(line.httpStatus, 200);
    } finally { g.stop(); }
  });
});

test('T1b 后台开: /api/auth/login 原样上行 —— body 零改写 · host 重写为上游 · 不注入凭据', async () => {
  await withUpstream(adminUpstream(), async (orPort) => {
    const g = await startGate(orPort, { GATE_ADMIN_ENABLED: '1' });
    try {
      const payload = JSON.stringify({ username: 'admin', password: 'p@ss w0rd 中文' });
      const r = await g.request({
        method: 'POST',
        path: '/api/auth/login',
        headers: {
          'content-type': 'application/json',
          'content-length': Buffer.byteLength(payload),
          'x-trace': 't1b',
        },
        body: payload,
      });
      assert.equal(r.status, 200, `登录接口应透传 200, 实际 ${r.status}`);
      const echoed = JSON.parse(r.body).echoed;
      assert.equal(echoed.method, 'POST');
      assert.equal(echoed.path, '/api/auth/login');
      // 关键: gate 把 host 重写成上游自身 (否则 OmniRoute 的 Host 守卫会拒)
      assert.equal(echoed.host, `127.0.0.1:${orPort}`, `host 应被重写为上游, 实际 ${echoed.host}`);
      assert.equal(echoed.trace, 't1b', '自定义请求头应原样上行');
      assert.equal(echoed.authorization, null, 'gate 不得在后台路径注入任何凭据');
      // 关键: body 逐字节到达 (中文/特殊字符不得被截断或转义)
      assert.equal(echoed.body, payload, '登录 body 必须原样到达上游 (零改写)');
    } finally { g.stop(); }
  });
});

test('T1c 后台开时 /v1 仍走 PSK 闸: 无凭据 → 401 且不落到后台透传', async () => {
  let upstreamHits = 0;
  await withUpstream((req, res) => {
    upstreamHits += 1;
    res.writeHead(200, { 'content-type': 'application/json' });
    res.end('{"leaked":true}');
  }, async (orPort) => {
    const g = await startGate(orPort, { GATE_ADMIN_ENABLED: '1' });
    try {
      const r = await g.request({ path: '/v1/models' });
      assert.equal(r.status, 401, `admin 开启不得让 /v1 绕过 PSK, 实际 ${r.status}`);
      assert.match(r.body, /unauthorized/);
      assert.equal(upstreamHits, 0, '/v1 未过 PSK 时不该有任何上游流量');
    } finally { g.stop(); }
  });
});

test('T1d 后台关 (默认): 全路径 404 门藏, 不泄露后台存在', async () => {
  await withUpstream(adminUpstream(), async (orPort) => {
    const g = await startGate(orPort, {});   // 不设 GATE_ADMIN_ENABLED → fail-closed
    try {
      assert.match(g.stdoutText, /admin UI: disabled/, '未设开关应打印 disabled');
      for (const p of ['/', '/admin', '/api/auth/login']) {
        const r = await g.request({ path: p, method: p.startsWith('/api/') ? 'POST' : 'GET', body: p.startsWith('/api/') ? '{}' : null });
        assert.equal(r.status, 404, `后台关闭时 ${p} 应 404 门藏, 实际 ${r.status}`);
        assert.equal(r.body, '', `404 门藏应空体 (不回显任何后台特征), 实际 "${r.body}"`);
      }
    } finally { g.stop(); }
  });
});

// ════════════════════════════════════════════════════════════════════════════
// T2 后台超时 → 504 (共用状态机的 admin_ 前缀分支)
// ════════════════════════════════════════════════════════════════════════════

test('T2 后台超时: 上游不响应 → 504 gateway_timeout, 日志带 admin_ 前缀且归因 timeout', async () => {
  await withUpstream(() => { /* 永不响应: 模拟后台页/接口把上游卡死 */ }, async (orPort) => {
    const g = await startGate(orPort, { GATE_ADMIN_ENABLED: '1', GATE_UPSTREAM_TIMEOUT_MS: '800' });
    try {
      const r = await g.request({ path: '/api/settings/proxy' });
      assert.equal(r.status, 504, `后台超时应 504, 实际 ${r.status}`);
      assert.match(r.body, /gateway_timeout/);
      assert.match(r.body, /"abort_source":"timeout"/);

      const line = await g.waitLog((l) => l.msg === 'admin_upstream_request_timeout', 8000, 'admin_upstream_request_timeout');
      assert.equal(line.httpStatus, 504);
      assert.equal(line.errorCode, 'ETIMEDOUT');
      assert.equal(line.abortSource, 'timeout');
      assert.equal(line.destroyInitiator, 'gate_timeout');
      assert.equal(line.path, '/api/settings/proxy');
      assert.equal(line.upstream_target, `127.0.0.1:${orPort}`);
    } finally { g.stop(); }
  });
});

// ════════════════════════════════════════════════════════════════════════════
// T3 后台客户端断开 → 归因 client_close, 不写响应, gate 存活
// ════════════════════════════════════════════════════════════════════════════

test('T3 后台客户端断开: 归因 client_close (admin_ 前缀), httpStatus=null 不回写, gate 进程存活', async () => {
  let upstreamReqCount = 0;
  await withUpstream((req, res) => {
    upstreamReqCount += 1;
    // 慢响应: 让客户端有机会在响应头到达前断开 (此时 res.headersSent=false)
    setTimeout(() => {
      try {
        res.writeHead(200, { 'content-type': 'text/html' });
        res.end('<html>late</html>');
      } catch { /* client 已走, socket 报错忽略 */ }
    }, 3000);
  }, async (orPort) => {
    const g = await startGate(orPort, { GATE_ADMIN_ENABLED: '1', GATE_UPSTREAM_TIMEOUT_MS: '60000' });
    try {
      const r = await g.request({ path: '/api/slow', abortAfterMs: 150 });
      assert.equal(r.aborted, true, '本用例语义: 客户端主动断开');

      const line = await g.waitLog(
        (l) => l.msg === 'admin_client_disconnected_proxy_aborted',
        8000, 'admin_client_disconnected_proxy_aborted');
      assert.equal(line.abortSource, 'client_close', '断开必须归因客户端, 不能被误记成上游错');
      assert.equal(line.destroyInitiator, 'client');
      assert.equal(line.httpStatus, null, 'client 已不可达, gate 不该产生/回写一个 HTTP 状态');

      // 同 requestId 不得再出现"正常完成"日志 (否则等于给断开的请求记了一次成功)
      const rid = line.requestId;
      assert.equal(
        g.logs.filter((l) => l.requestId === rid && l.msg === 'upstream_completed').length, 0,
        '客户端断开的请求不得被记成 upstream_completed');
    } finally { g.stop(); }
  });
  assert.ok(upstreamReqCount >= 1, '上游应至少收到过一次请求');
});

test('T3b 后台客户端断开后 gate 仍能正常服务下一个请求 (进程级存活断言)', async () => {
  await withUpstream((req, res) => {
    if (req.url === '/slow') {
      setTimeout(() => { try { res.writeHead(200); res.end('late'); } catch { /* noop */ } }, 3000);
      return;
    }
    res.writeHead(200, { 'content-type': 'application/json' });
    res.end('{"ok":true}');
  }, async (orPort) => {
    const g = await startGate(orPort, { GATE_ADMIN_ENABLED: '1', GATE_UPSTREAM_TIMEOUT_MS: '60000' });
    try {
      const aborted = await g.request({ path: '/slow', abortAfterMs: 150 });
      assert.equal(aborted.aborted, true);
      await g.waitLog((l) => l.msg === 'admin_client_disconnected_proxy_aborted', 8000, 'abort log');
      const ok = await g.request({ path: '/ok' });
      assert.equal(ok.status, 200, `断开事件后 gate 应仍可服务, 实际 ${ok.status}`);
      assert.match(ok.body, /"ok":true/);
    } finally { g.stop(); }
  });
});
