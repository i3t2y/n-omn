// #16 route-split 端到端测试: 起真 gate.js + 假上游, 走 HTTP 验分流行为。
// 跑法: node --test logic/tests/route-split.e2e.test.js
// 覆盖: probe 快路径 (GET /v1/models, 上游真收到完整请求) ·
//        probe 不进 fallback 账本 (同路径多次 GET 不被 502) ·
//        inference (POST) 仍正常受保护 · 开关 '0' 回退不破 ·
//        探针审计日志含 lane=/route_reason=。
'use strict';

const test = require('node:test');
const assert = require('node:assert');
const http = require('node:http');
const { spawn } = require('node:child_process');
const path = require('node:path');

const PSK = 'test-psk-0123456789abcdef';
const GATE = path.join(__dirname, '..', 'gate.js');

function withServer(handler, cb) {
  const srv = http.createServer((req, res) => handler(req, res));
  return new Promise((resolve) => {
    srv.listen(0, '127.0.0.1', async () => {
      const orPort = srv.address().port;
      try { await cb(orPort, srv); } finally { await new Promise((r) => srv.close(r)); }
      resolve();
    });
  });
}

async function runGate(orPort, env) {
  const gp = await new Promise((res) => {
    const t = http.createServer();
    t.listen(0, '127.0.0.1', () => { const p = t.address().port; t.close(() => res(p)); });
  });
  const child = spawn(process.execPath, [GATE], {
    env: {
      ...process.env,
      INTERNAL_PSK: PSK,
      OMNIROUTE_API_KEY: 'sk-test-key',
      OMNIROUTE_PORT: String(orPort),
      EXPOSED_PORT: String(gp),
      GATE_UPSTREAM_TIMEOUT_MS: '60000',
      ...env,
    },
    stdio: ['ignore', 'pipe', 'pipe'],
  });
  let stderr = '';
  child.stderr.on('data', (b) => { stderr += String(b); });
  await new Promise((resolve, reject) => {
    const to = setTimeout(() => reject(new Error('gate 未在 8s 内启动')), 8000);
    const onData = (b) => {
      if (String(b).includes('listening')) { clearTimeout(to); child.stdout.off('data', onData); resolve(); }
    };
    child.stdout.on('data', onData);
    child.on('exit', (c) => { clearTimeout(to); reject(new Error(`gate 提前退出 rc=${c}`)); });
  });
  const req = (method, p, body) => new Promise((resolve, reject) => {
    const payload = body === undefined ? null : JSON.stringify(body);
    const headers = { authorization: `Bearer ${PSK}` };
    if (payload !== null) {
      headers['content-type'] = 'application/json';
      headers['content-length'] = Buffer.byteLength(payload);
    }
    const r = http.request({ host: '127.0.0.1', port: gp, method, path: p, headers }, (res) => {
      const chunks = [];
      res.on('data', (c) => chunks.push(c));
      res.on('end', () => resolve({ status: res.statusCode, body: Buffer.concat(chunks).toString() }));
    });
    r.setTimeout(20000, () => r.destroy(new Error('client timeout')));
    r.on('error', reject);
    if (payload !== null) r.end(payload); else r.end();
  });
  const stop = () => { try { child.kill('SIGKILL'); } catch { /* noop */ } };
  return { get: (p) => req('GET', p), post: (p, b) => req('POST', p, b), stop, stderr: () => stderr };
}

test('probe 快路径: GET /v1/models 通, 上游收到完整请求 (路径原样)', async () => {
  let seen = null;
  await withServer((req, res) => {
    seen = { method: req.method, url: req.url, auth: req.headers.authorization };
    res.writeHead(200, { 'content-type': 'application/json' });
    res.end(JSON.stringify({ data: [{ id: 'm1' }] }));
  }, async (orPort) => {
    const g = await runGate(orPort, {});
    try {
      const r = await g.get('/v1/models');
      assert.equal(r.status, 200);
      assert.match(r.body, /m1/);
      assert.equal(seen.method, 'GET');
      assert.equal(seen.url, '/v1/models');
      assert.equal(seen.auth, 'Bearer sk-test-key');   // 上游换 OR_API_KEY, 非 PSK
    } finally { g.stop(); }
  });
});

test('probe 不进 fallback 账本: 同探针路径连打 6 次仍 200 (不被治暴误伤)', async () => {
  await withServer((req, res) => {
    res.writeHead(200, { 'content-type': 'application/json' });
    res.end(JSON.stringify({ ok: true }));
  }, async (orPort) => {
    // FALLBACK_MAX_ATTEMPTS=1 → 若 probe 误进账本, 第 2 次就会被 502
    const g = await runGate(orPort, { GATE_FALLBACK_MAX_ATTEMPTS: '1' });
    try {
      for (let i = 0; i < 6; i++) {
        const r = await g.get('/v1/models');
        assert.equal(r.status, 200, `第 ${i + 1} 次 GET /v1/models 应 200, 实际 ${r.status}`);
      }
      // 同样 6 次 POST 失败在该预算下应被拦 (对照: 账本只对 inference 生效)
    } finally { g.stop(); }
  });
});

test('inference 仍受保护: POST 失败达上限 → 502 (分流未削弱治暴)', async () => {
  await withServer((req, res) => {
    res.writeHead(502, { 'content-type': 'application/json' });
    res.end(JSON.stringify({ error: 'upstream down' }));
  }, async (orPort) => {
    const g = await runGate(orPort, { GATE_FALLBACK_MAX_ATTEMPTS: '2' });
    try {
      const body = { model: 'k3', conversation_id: 'conv-rs-1', messages: [{ role: 'user', content: 'x' }] };
      const a = await g.post('/v1/chat/completions', body);
      assert.equal(a.status, 502);
      const b = await g.post('/v1/chat/completions', body);
      assert.equal(b.status, 502);
      const c = await g.post('/v1/chat/completions', body);
      assert.equal(c.status, 502);
      assert.match(c.body, /fallback|budget|exhausted/i, `第 3 次应是账本拒放行, 实际体: ${c.body.slice(0, 160)}`);
    } finally { g.stop(); }
  });
});

test('开关回退: GATE_ROUTE_SPLIT_ENABLED=0 时行为不变 (probe 路径照常通)', async () => {
  await withServer((req, res) => {
    res.writeHead(200, { 'content-type': 'application/json' });
    res.end(JSON.stringify({ data: [] }));
  }, async (orPort) => {
    const g = await runGate(orPort, { GATE_ROUTE_SPLIT_ENABLED: '0' });
    try {
      const r = await g.get('/v1/models');
      assert.equal(r.status, 200);
    } finally { g.stop(); }
  });
});

test('审计: probe 命中打一行 lane=probe route_reason= (B 通道证据形态)', async () => {
  await withServer((req, res) => {
    res.writeHead(200, { 'content-type': 'application/json' });
    res.end('{}');
  }, async (orPort) => {
    const g = await runGate(orPort, {});
    try {
      await g.get('/v1/models');
      await new Promise((r) => setTimeout(r, 200));
      const log = g.stderr();
      assert.match(log, /lane=probe route_reason=probe_exact/, `缺 probe 审计行; stderr 尾部: ${log.slice(-300)}`);
    } finally { g.stop(); }
  });
});
