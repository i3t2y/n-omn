// #16 route-split 单元测试: 纯函数分流判定。
// 跑法: node --test logic/tests/route-split.test.js
'use strict';

const test = require('node:test');
const assert = require('node:assert');
const path = require('node:path');

const rs = require(path.join(__dirname, '..', 'route-split.js'));

test('probe: 无 body 的读热点 (models/providers/status/bucket 探针) → probe', () => {
  const probes = [
    ['GET', '/v1/models'],
    ['GET', '/v1/providers'],
    ['GET', '/v1/status'],
    ['GET', '/v1/health'],
    ['GET', '/v1/bucket/health'],
    ['GET', '/v1/bucket/manifest'],
    ['HEAD', '/v1/models'],
    ['OPTIONS', '/v1'],
    ['GET', '/healthz'],
  ];
  for (const [method, p] of probes) {
    const r = rs.classifyLane({ method, path: p });
    assert.equal(r.lane, 'probe', `${method} ${p} 应 probe, 实际 ${r.lane} (${r.reason})`);
    assert.equal(rs.isProbeFastPath({ method, path: p }), true);
  }
});

test('probe: query/重复斜杠/尾斜杠 归一化后仍命中', () => {
  const variants = [
    '/v1/models?limit=10',
    '/v1//models',
    '/v1/models/',
    '/v1/models#frag',
  ];
  for (const p of variants) {
    assert.equal(rs.classifyLane({ method: 'GET', path: p }).lane, 'probe', `${p} 应 probe`);
  }
});

test('probe: 带子路径的只读资源 → probe', () => {
  assert.equal(rs.classifyLane({ method: 'GET', path: '/v1/models/llama-3' }).lane, 'probe');
  assert.equal(rs.classifyLane({ method: 'GET', path: '/v1/bucket/info' }).lane, 'probe');
});

test('inference: POST 带 body 一律 inference (fail-safe)', () => {
  const cases = [
    ['POST', '/v1/chat/completions', true],
    ['POST', '/v1/messages', true],
    ['POST', '/v1/embeddings', true],
    ['POST', '/v1/models', true],          // 即便是探针路径, POST 也归 inference
    ['PUT', '/v1/foo', true],
  ];
  for (const [method, p, hasBody] of cases) {
    const r = rs.classifyLane({ method, path: p, hasBody });
    assert.equal(r.lane, 'inference', `${method} ${p} 应 inference, 实际 ${r.lane}`);
    assert.equal(rs.isProbeFastPath({ method, path: p, hasBody }), false);
  }
});

test('inference: 探针路径下含推理词 → 不判 probe (防误关护栏)', () => {
  const traps = [
    '/v1/models/x/completions',
    '/v1/models/kimi/messages',
    '/v1/providers/openai/embeddings',
    '/v1/status/generate',
  ];
  for (const p of traps) {
    const r = rs.classifyLane({ method: 'GET', path: p });
    assert.equal(r.lane, 'inference', `${p} 应 inference, 实际 ${r.lane} (${r.reason})`);
  }
});

test('other: 未知读路径 / 非读方法无 body → 常规路径 (非 probe 非 inference)', () => {
  assert.equal(rs.classifyLane({ method: 'GET', path: '/v1/unknown' }).lane, 'other');
  assert.equal(rs.classifyLane({ method: 'GET', path: '/api/admin' }).lane, 'other');
  assert.equal(rs.classifyLane({ method: 'DELETE', path: '/v1/x' }).lane, 'other');
});

test('fail-safe: 缺省输入不崩, 默认 GET + /', () => {
  const r = rs.classifyLane();
  assert.equal(r.method, 'GET');
  assert.equal(r.path, '/');
  assert.ok(['probe', 'inference', 'other'].includes(r.lane));
  const r2 = rs.classifyLane({});
  assert.equal(r2.lane, 'other');
});

test('纯函数: 同输入同输出 (无跨调用状态)', () => {
  const a = rs.classifyLane({ method: 'GET', path: '/v1/models' });
  const b = rs.classifyLane({ method: 'GET', path: '/v1/models' });
  assert.deepEqual(a, b);
});

test('归一化: normalizePath 去 query/hash/折叠斜杠/去尾斜杠', () => {
  assert.equal(rs.normalizePath('/v1//models/?a=1#x'), '/v1/models');
  assert.equal(rs.normalizePath('/'), '/');
  assert.equal(rs.normalizePath(''), '/');
  assert.equal(rs.normalizePath('/a/b/'), '/a/b');
});

test('大小写不敏感方法: post → inference, get → probe', () => {
  assert.equal(rs.classifyLane({ method: 'post', path: '/v1/chat/completions', hasBody: true }).lane, 'inference');
  assert.equal(rs.classifyLane({ method: 'get', path: '/v1/models' }).lane, 'probe');
});

test('hasBody 缺省由方法推断: POST 视作有 body', () => {
  assert.equal(rs.classifyLane({ method: 'POST', path: '/v1/models' }).lane, 'inference');
});
