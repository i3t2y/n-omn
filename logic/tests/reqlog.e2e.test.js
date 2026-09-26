// 每请求摘要 (GATE_REQ_LOG) 端到端回归 —— 站外调用方归因的观测面
//
// 为什么要有这份测试: gate 曾对正常请求**零日志**, 上游也不记来源 ⇒ 站外流量在
//   n-omn 侧不可归因 (09-26 "谁在打 kimi-k3" 只能靠形状猜)。本件是那次补的观测面,
//   一旦被后续重构悄悄改坏 (字段改名/不打/打到 stdout), 归因能力会静默丧失 ⇒ 必须钉住。
//
// 边界: 只验"打了什么", 不验业务行为 —— 代理/熔断/账本语义归其它测试文件。
// 脱敏硬约束: 摘要行**不得**包含 body 原文 / Authorization / X-Gate-PSK / token。
const { test } = require('node:test');
const assert = require('node:assert');
const http = require('node:http');
const { spawn } = require('node:child_process');
const path = require('node:path');

const PSK = 'test-psk-0123456789abcdef';
const GATE = path.join(__dirname, '..', 'gate.js');

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

// 起真 gate.js 子进程 (e2e, 需 express)
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
      GATE_UPSTREAM_TIMEOUT_MS: '60000',
      ...env,
    },
    stdio: ['ignore', 'pipe', 'pipe'],
  });
  const logs = [];
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
    const { method = 'GET', p: reqPath = '/', headers = {}, body = null, noContentLength = false } = opts;
    // noContentLength=true → 走 chunked (不发 content-length), 用于复现/钉住
    //   "chunked POST 在 gate 挂到超时" 那个既有缺陷 (见 T5)。
    const hdrs = (body != null && !noContentLength)
      ? { 'content-length': String(Buffer.byteLength(body)), ...headers }
      : headers;
    let settled = false;
    const req = http.request({ host: '127.0.0.1', port, method, path: reqPath, headers: hdrs }, (res) => {
      const chunks = [];
      res.on('data', (c) => chunks.push(c));
      res.on('end', () => {
        if (settled) return;
        settled = true;
        resolve({ status: res.statusCode, body: Buffer.concat(chunks).toString() });
      });
    });
    req.on('error', (e) => { if (!settled) { settled = true; reject(e); } });
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
    throw new Error(`等不到匹配的 gate 日志 (${label}); 已收 ${logs.length} 行`);
  };

  return { port, request, waitLog, get logs() { return logs; }, stop: () => { try { child.kill('SIGKILL'); } catch { /* noop */ } } };
}

// 上游: 一律 200 空转 (本文件只关心 gate 侧打了什么)
function echoUpstream() {
  return (req, res) => {
    const chunks = [];
    req.on('data', (c) => chunks.push(c));
    req.on('end', () => {
      res.writeHead(200, { 'content-type': 'application/json' });
      res.end(JSON.stringify({ ok: true }));
    });
  };
}

const CHAT_BODY = JSON.stringify({
  model: 'nvidia/moonshotai/kimi-k3',
  messages: [{ role: 'system', content: 'you are x' }, { role: 'user', content: 'hi' }],
  tools: Array.from({ length: 22 }, (_, i) => ({ type: 'function', function: { name: `t${i}` } })),
  stream: true,
});

test('T1 默认开启: /v1 POST 打 request + request_body 两行, 含来源 IP/UA 与 body 形态', async () => {
  await withUpstream(echoUpstream(), async (orPort) => {
    const g = startGate(orPort);
    try {
      const gate = await g;
      const r = await gate.request({
        method: 'POST',
        p: '/v1/chat/completions',
        headers: {
          authorization: `Bearer ${PSK}`,
          'content-type': 'application/json',
          'cf-connecting-ip': '203.0.113.7',
          'x-forwarded-for': '203.0.113.7, 198.51.100.2',
          'user-agent': 'hermes-agent/0.21.3',
        },
        body: CHAT_BODY,
      });
      assert.strictEqual(r.status, 200, '上游 200 应透传');

      const l1 = await gate.waitLog((l) => l.stage === 'request', 8000, 'request 行');
      assert.strictEqual(l1.component, 'gate');
      assert.strictEqual(l1.level, 'info');
      assert.strictEqual(l1.method, 'POST');
      assert.strictEqual(l1.path, '/v1/chat/completions');
      assert.strictEqual(l1.ip, '203.0.113.7', 'cf-connecting-ip 优先');
      assert.strictEqual(l1.xff_hops, 2);
      assert.strictEqual(l1.ua, 'hermes-agent/0.21.3');
      assert.strictEqual(l1.ct, String(Buffer.byteLength(CHAT_BODY)));

      const l2 = await gate.waitLog((l) => l.stage === 'request_body', 8000, 'request_body 行');
      assert.strictEqual(l2.parsed, 1);
      assert.strictEqual(l2.model, 'nvidia/moonshotai/kimi-k3');
      assert.strictEqual(l2.msgs, 2);
      assert.strictEqual(l2.tools, 22, 'tools 数是"哪类客户端"的关键指纹');
      assert.strictEqual(l2.stream, 1);
      assert.strictEqual(l2.requestId, l1.requestId, '两行须同一 requestId 可对拍');
      assert.ok(l2.sess && typeof l2.sess === 'string', '会话指纹应落上');
    } finally { (await g).stop(); }
  });
});

test('T2 脱敏: 摘要行不得出现 PSK / Authorization / body 原文', async () => {
  await withUpstream(echoUpstream(), async (orPort) => {
    const g = startGate(orPort);
    try {
      const gate = await g;
      await gate.request({
        method: 'POST',
        p: '/v1/chat/completions',
        headers: {
          authorization: `Bearer ${PSK}`,
          'x-gate-psk': `Bearer ${PSK}`,
          'content-type': 'application/json',
          'user-agent': 'ua-x',
        },
        body: JSON.stringify({ model: 'kimi-k3', messages: [{ role: 'user', content: 'SECRET-BODY-MARKER' }] }),
      });
      await gate.waitLog((l) => l.stage === 'request_body', 8000, 'request_body 行');
      for (const l of gate.logs.filter((x) => x.stage === 'request' || x.stage === 'request_body')) {
        const s = JSON.stringify(l);
        assert.ok(!s.includes(PSK), `摘要行泄露 PSK: ${s}`);
        assert.ok(!s.includes('SECRET-BODY-MARKER'), `摘要行泄露 body 原文: ${s}`);
        assert.ok(!s.includes('Bearer '), `摘要行泄露 Authorization: ${s}`);
      }
    } finally { (await g).stop(); }
  });
});

test('T3 GATE_REQ_LOG=0 → 完全静默 (开关可关, 不留观测面)', async () => {
  await withUpstream(echoUpstream(), async (orPort) => {
    const g = startGate(orPort, { GATE_REQ_LOG: '0' });
    try {
      const gate = await g;
      const r = await gate.request({
        method: 'POST',
        p: '/v1/chat/completions',
        headers: { authorization: `Bearer ${PSK}`, 'content-type': 'application/json' },
        body: CHAT_BODY,
      });
      assert.strictEqual(r.status, 200);
      await new Promise((res) => setTimeout(res, 400));
      const hits = gate.logs.filter((l) => l.stage === 'request' || l.stage === 'request_body');
      assert.strictEqual(hits.length, 0, `GATE_REQ_LOG=0 时不应有摘要行, 实收 ${hits.length}`);
    } finally { (await g).stop(); }
  });
});

// T5 钉一个**既有缺陷的修复**: 无 content-length 的 chunked POST 曾挂到超时 (504)。
//   机理: readBodyPrefix 无 content-length 时 want 取 64KB 上限, 小 body 只能靠 req 的
//   'end' 收尾; 而替身 PassThrough 的 'end' 监听是在 finish() 里才挂的 —— 那时 'end'
//   事件**已经过去了**, 永不触发 ⇒ 替身流不 end ⇒ 上游一直等到 gate 超时。
//   修复: finish 由 onEnd 触发时 (sawEnd) 立即 replay.end()。
//   回归价值: 只要有人把 sawEnd 分支删掉/改回去, 本例立刻变红 (曾实测 504)。
test('T5 chunked POST (无 content-length) 不得挂到超时: 应 200 且摘要行齐全', async () => {
  await withUpstream(echoUpstream(), async (orPort) => {
    const g = startGate(orPort, { GATE_UPSTREAM_TIMEOUT_MS: '5000' });   // 超时压到 5s, 挂了就快红
    try {
      const gate = await g;
      const r = await gate.request({
        method: 'POST',
        p: '/v1/chat/completions',
        headers: {
          authorization: `Bearer ${PSK}`,
          'content-type': 'application/json',
          'user-agent': 'chunked-client/1.0',
        },
        body: JSON.stringify({ model: 'kimi-k3', messages: [{ role: 'user', content: 'hi' }] }),
        noContentLength: true,
      });
      assert.strictEqual(r.status, 200, 'chunked POST 不应挂到超时 (曾 504)');
      const l = await gate.waitLog((x) => x.stage === 'request_body', 8000, 'chunked request_body 行');
      assert.strictEqual(l.parsed, 1, 'chunked body 也应解析出形态');
      assert.strictEqual(l.model, 'kimi-k3');
      assert.strictEqual(l.msgs, 1);
    } finally { (await g).stop(); }
  });
});

test('T4 无 PSK 的 401 也要留痕 (归因"谁在敲门"), 且 /healthz 不打 (平台探活不淹信号)', async () => {
  await withUpstream(echoUpstream(), async (orPort) => {
    const g = startGate(orPort);
    try {
      const gate = await g;
      const bad = await gate.request({ method: 'GET', p: '/v1/models', headers: { 'user-agent': 'stranger/1.0' } });
      assert.strictEqual(bad.status, 401);
      const l = await gate.waitLog((x) => x.stage === 'request' && x.path === '/v1/models', 8000, '401 摘要行');
      assert.strictEqual(l.ua, 'stranger/1.0');

      await gate.request({ method: 'GET', p: '/healthz' });
      await new Promise((res) => setTimeout(res, 300));
      const healthz = gate.logs.filter((x) => x.stage === 'request' && x.path === '/healthz');
      assert.strictEqual(healthz.length, 0, '/healthz 探活不应打摘要 (否则淹没有效信号)');
    } finally { (await g).stop(); }
  });
});
