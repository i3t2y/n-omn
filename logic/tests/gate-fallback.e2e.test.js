// #4b gate 护栏 端到端单测: 起真 gate.js + 假上游, 走 HTTP 断行为。
// 跑法: node --test logic/tests/gate-fallback.e2e.test.js
// 覆盖: 次数/墙钟护栏 502 · 退化空响应 Deferred-head 502 · 正常流不误伤 (200)
// 注意: 端口随机取 (避免并行/残留冲突); 每个用例独立上一轮 boot, 结束 SIGKILL 回收。
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
  // 随机 gate 端口: 让 gate 自选 (EXPOSED_PORT=0) 不好取回, 故用临时探针拿一个空闲端口
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
  await new Promise((resolve, reject) => {
    const to = setTimeout(() => reject(new Error('gate 未在 8s 内启动')), 8000);
    const onData = (b) => {
      if (String(b).includes('listening')) { clearTimeout(to); child.stdout.off('data', onData); resolve(); }
    };
    child.stdout.on('data', onData);
    child.on('exit', (c) => { clearTimeout(to); reject(new Error(`gate 提前退出 rc=${c}`)); });
  });
  const post = (body) => new Promise((resolve, reject) => {
    const payload = JSON.stringify(body);
    const req = http.request({
      host: '127.0.0.1', port: gp, method: 'POST', path: '/v1/chat/completions',
      headers: {
        'content-type': 'application/json',
        'content-length': Buffer.byteLength(payload),
        authorization: `Bearer ${PSK}`,
      },
    }, (res) => {
      const chunks = [];
      res.on('data', (c) => chunks.push(c));
      res.on('end', () => resolve({ status: res.statusCode, body: Buffer.concat(chunks).toString() }));
    });
    req.setTimeout(20000, () => { req.destroy(new Error('client timeout')); });
    req.on('error', reject);
    req.end(payload);
  });
  const stop = () => { try { child.kill('SIGKILL'); } catch { /* noop */ } };
  return { post, stop };
}

test('正常流: 真内容 → 200 且内容原样到达 (不误伤)', async () => {
  await withServer((req, res) => {
    res.writeHead(200, { 'content-type': 'text/event-stream' });
    res.write('data: {"choices":[{"delta":{"content":"你"}}]}\n');
    res.write('data: {"choices":[{"delta":{"content":"好"}}]}\n');
    res.end('data: [DONE]\n');
  }, async (orPort) => {
    const g = await runGate(orPort, { GATE_FALLBACK_GUARD_ENABLED: '0' });
    try {
      const r = await g.post({ model: 'x', messages: [{ role: 'user', content: 'hi' }] });
      assert.equal(r.status, 200);
      assert.match(r.body, /你/);
      assert.match(r.body, /好/);
    } finally { g.stop(); }
  });
});

test('退化空响应: 同会话首次退化后, 再次进入 → 明确 502 (不静默空 200)', async () => {
  await withServer((req, res) => {
    res.writeHead(200, { 'content-type': 'text/event-stream' });
    res.write('data: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"a","function":{"name":"f","arguments":"{}"}}]}}]}\n');
    res.write('data: {"choices":[{"delta":{},"finish_reason":"tool_calls"}]}\n');
    res.end('data: [DONE]\n');
  }, async (orPort) => {
    const g = await runGate(orPort, {
      GATE_EMPTY_RESPONSE_RETRY: '1',
      GATE_EMPTY_RESPONSE_MAX_RETRIES: '0',
      GATE_EMPTY_HEAD_HOLD_MS: '1500',
    });
    try {
      const body = { model: 'kimi-k3', conversation_id: 'conv-degenerate-1', messages: [{ role: 'user', content: 'x' }] };
      const first = await g.post(body);
      // 第 1 次: 允许一次同组合重试 (EMPTY_RESPONSE_MAX_RETRIES=0 时即视为已用尽) → 该轮先记退化;
      //   若第一轮就判退化且配额已用尽, gate 会直接用 Deferred-head 收口成 502。
      assert.ok(first.status === 200 || first.status === 502, `首轮应为 200(记退化) 或 502(直接收口), 实际 ${first.status}`);
      const second = await g.post(body);
      assert.equal(second.status, 502, `同会话再次进入应明确 502, 实际 ${second.status}`);
      assert.match(second.body, /degenerate_empty_response|empty_response/);
    } finally { g.stop(); }
  });
});

test('尝试次数上限: 同会话连续 3 次失败后, 第 4 次直接 502 (不再等下一个 key)', async () => {
  let hits = 0;
  await withServer((req, res) => {
    hits += 1;
    res.writeHead(502, { 'content-type': 'application/json' });
    res.end('{"error":"bad_gateway"}');
  }, async (orPort) => {
    const g = await runGate(orPort, { GATE_FALLBACK_MAX_ATTEMPTS: '3', GATE_FALLBACK_TOTAL_TIMEOUT_MS: '0' });
    try {
      const body = { model: 'kimi-k3', conversation_id: 'conv-attempts-1', messages: [{ role: 'user', content: 'x' }] };
      for (let i = 0; i < 3; i++) await g.post(body);
      const hitsBefore = hits;
      const r = await g.post(body);
      assert.equal(r.status, 502);
      assert.match(r.body, /fallback_attempt_limit/);
      const hitsAfter = hits;
      assert.equal(hitsAfter, hitsBefore, '第 4 次不应再打上游 (被 gate 拦住)');
    } finally { g.stop(); }
  });
});

test('总墙钟墙: 同会话首次失败起累计超 90s (测试压到 1.2s) → 直接 502', async () => {
  await withServer((req, res) => {
    res.writeHead(502, { 'content-type': 'application/json' });
    res.end('{"error":"bad_gateway"}');
  }, async (orPort) => {
    const g = await runGate(orPort, { GATE_FALLBACK_MAX_ATTEMPTS: '99', GATE_FALLBACK_TOTAL_TIMEOUT_MS: '1200' });
    try {
      const body = { model: 'kimi-k3', conversation_id: 'conv-wallclock-1', messages: [{ role: 'user', content: 'x' }] };
      const r1 = await g.post(body);
      assert.equal(r1.status, 502);   // 上游自己的 502
      await new Promise((r) => setTimeout(r, 1300));
      const r2 = await g.post(body);
      assert.equal(r2.status, 502);
      assert.match(r2.body, /fallback_total_timeout/);
    } finally { g.stop(); }
  });
});

test('配额已用尽后 Deferred-head 只对有真内容的流放行 (真回复不丢字节)', async () => {
  await withServer((req, res) => {
    res.writeHead(200, { 'content-type': 'text/event-stream' });
    res.write('data: {"choices":[{"delta":{"reasoning_content":"想"}}]}\n');
    res.write('data: {"choices":[{"delta":{"content":"答案"}}]}\n');
    res.end('data: [DONE]\n');
  }, async (orPort) => {
    const g = await runGate(orPort, {
      GATE_EMPTY_RESPONSE_MAX_RETRIES: '0',
      GATE_EMPTY_HEAD_HOLD_MS: '1500',
    });
    try {
      const r = await g.post({ model: 'kimi-k3', messages: [{ role: 'user', content: 'x' }] });
      assert.equal(r.status, 200);
      assert.match(r.body, /答案/);
    } finally { g.stop(); }
  });
});

test('Deferred-head: 会话已知退化 + 再次 200 空响应 → 该次请求本身被收成 502', async () => {
  await withServer((req, res) => {
    res.writeHead(200, { 'content-type': 'text/event-stream' });
    res.write('data: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"a","function":{"name":"f","arguments":"{}"}}]}}]}\n');
    res.write('data: {"choices":[{"delta":{},"finish_reason":"tool_calls"}]}\n');
    res.end('data: [DONE]\n');
  }, async (orPort) => {
    const g = await runGate(orPort, {
      GATE_EMPTY_RESPONSE_RETRY: '1',
      GATE_EMPTY_RESPONSE_MAX_RETRIES: '1',
      GATE_EMPTY_HEAD_HOLD_MS: '1200',
    });
    try {
      const body = { model: 'kimi-k3', conversation_id: 'conv-defer-1', messages: [{ role: 'user', content: 'x' }] };
      const first = await g.post(body);   // 第 1 次: 消耗掉重试配额
      assert.ok(first.status === 200 || first.status === 502, `首轮 ${first.status}`);
      const second = await g.post(body);  // 第 2 次: 会话已退化 → Deferred-head 收口
      assert.equal(second.status, 502, `应收成 502, 实际 ${second.status} body=${second.body.slice(0, 160)}`);
      assert.match(second.body, /degenerate_empty_response|empty_response/);
    } finally { g.stop(); }
  });
});
