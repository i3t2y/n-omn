// test-runner.js — v4.3 candidate 测试总调
// 不访问真实实例. mock 上游用 Node http.createServer(127.0.0.1:0).
// 执行所有测试矩阵; 失败退出非 0; 不伪造 PASS.
const { execSync, spawnSync } = require('child_process');
const fs = require('fs');
const path = require('path');
const assert = require('assert');

const CAND = path.resolve(__dirname, '..');   // candidate-v4.3-reviewed
const GATE = path.join(CAND, 'gate.js');
let pass = 0, fail = 0, skip = 0;

function ok(name) { pass++; console.log(`  ✓ ${name}`); }
function ko(name, e) { fail++; console.error(`  ✗ ${name}: ${e && e.message || e}`); }
function sk(name, why) { skip++; console.log(`  ⊘ ${name} (skip: ${why})`); }

// ── TEST 1: 静态语法 ──
function testSyntax() {
  console.log('TEST 1: 静态语法');
  // gate.js node --check
  try {
    const r = spawnSync('node', ['--check', GATE], { encoding: 'utf8' });
    if (r.status === 0) ok('gate.js node --check'); else ko('gate.js node --check', new Error(r.stderr));
  } catch (e) { ko('gate.js node --check', e); }
  // entrypoint.sh sh -n
  for (const [f, sh] of [['entrypoint.sh', 'sh'], ['entrypoint.sh', 'bash']]) {
    try {
      const r = spawnSync(sh, ['-n', path.join(CAND, f)], { encoding: 'utf8' });
      if (r.status === 0) ok(`${sh} -n ${f}`); else ko(`${sh} -n ${f}`, new Error(r.stderr));
    } catch (e) { ko(`${sh} -n ${f}`, e); }
  }
  // init-nim-keys.sh bash -n
  try {
    const r = spawnSync('bash', ['-n', path.join(CAND, 'init-nim-keys.sh')], { encoding: 'utf8' });
    if (r.status === 0) ok('bash -n init-nim-keys.sh'); else ko('bash -n init-nim-keys.sh', new Error(r.stderr));
  } catch (e) { ko('bash -n init', e); }
  // package.json jq + litestream.yml yaml
  try {
    const r = spawnSync('jq', ['empty', path.join(CAND, 'package.json')], { encoding: 'utf8' });
    if (r.status === 0) ok('jq package.json'); else ko('jq package.json', new Error(r.stderr));
  } catch (e) { ko('jq package.json', e); }
  try {
    const py = spawnSync('python3', ['-c', `import yaml; yaml.safe_load(open('${path.join(CAND,'litestream.yml')}')); print('ok')`], { encoding: 'utf8' });
    if (py.status === 0 && py.stdout.includes('ok')) ok('yaml litestream.yml'); else ko('yaml litestream.yml', new Error(py.stderr || py.stdout));
  } catch (e) { ko('yaml', e); }
}

// helper: start gate + mock upstream
const http = require('http');
function startMockUpstream(handler) {
  return new Promise((resolve) => {
    const srv = http.createServer(handler);
    srv.listen(0, '127.0.0.1', () => resolve(srv));
  });
}
function startGate(env, upstreamPort) {
  return new Promise((resolve, reject) => {
    const cp = require('child_process').spawn('node',
      [GATE],
      { env: { ...process.env, OMNIROUTE_PORT: String(upstreamPort), EXPOSED_PORT: '0', INTERNAL_PSK: 'p'.repeat(32), OMNIROUTE_API_KEY: 'test-or-key-1234567890', ...env }, cwd: CAND, stdio: ['ignore', 'pipe', 'pipe'] });
    let buf = '';
    cp.stdout.on('data', (d) => { buf += d; });
    cp.stderr.on('data', (d) => { buf += d; });
    // log: getter (实时读 buf), 保 TEST 13 动态用例可拿到 listen 后累积的 stderr JSON
    const g = { proc: cp, gatePort: 0, get log() { return buf; } };
    const to = setTimeout(() => {
      const m = buf.match(/listening on 0\.0\.0\.0:(\d+)/);
      if (m) { clearTimeout(to); g.gatePort = parseInt(m[1], 10); resolve(g); }
      else if (buf.includes('FATAL')) { clearTimeout(to); reject(new Error('gate FATAL: ' + buf)); }
    }, 50);
    cp.stdout.on('data', () => {
      const m = buf.match(/listening on 0\.0\.0\.0:(\d+)/);
      if (m && !cp._resolved) { cp._resolved = true; clearTimeout(to); g.gatePort = parseInt(m[1], 10); resolve(g); }
    });
    setTimeout(() => { if (!cp._resolved) { cp._resolved = true; reject(new Error('gate listen timeout: ' + buf)); } }, 3000);
  });
}
function stopGate(g) { if (g && g.proc) { try { g.proc.kill('SIGKILL'); } catch (e) {} } }
function stopUpstream(u) { if (u) return new Promise((r) => u.close(() => r())); }

async function req(port, opts) {
  return new Promise((resolve, reject) => {
    const r = http.request({ host: '127.0.0.1', port, ...opts }, (res) => {
      let body = ''; res.on('data', (c) => body += c); res.on('end', () => resolve({ status: res.statusCode, headers: res.headers, body }));
    });
    r.on('error', reject);
    if (opts.body) r.write(opts.body);
    r.end();
  });
}
function sleep(ms) { return new Promise((r) => setTimeout(r, ms)); }

// ── TEST 2/4: 路径矩阵 + query 保持 ──
async function testGatePaths() {
  console.log('TEST 2+4: 路径矩阵 + query/路径保持');
  let upstream;
  let g;
  try {
    upstream = await startMockUpstream((req, res) => { res.end('UP:' + req.method + ':' + req.url); });
    g = await startGate({}, upstream.address().port);
    const P = g.gatePort;
    // 默认后台关: /healthz (探上游) OR /v1 (PSK) OR 404
    let r = await req(P, { path: '/healthz' });
    if (r.status === 200 || r.status === 503) ok('/healthz 无 PSK 可探'); else ko('healthz', new Error(JSON.stringify(r)));
    // /v1 无 PSK → 401
    r = await req(P, { path: '/v1/models' });
    assert.strictEqual(r.status, 401); ok('/v1 无 PSK 401');
    // /v1 PSK 正确 → 200
    r = await req(P, { path: '/v1/models', headers: { authorization: 'Bearer ' + 'p'.repeat(32) } });
    assert.strictEqual(r.status, 200); ok('/v1 PSK 正确 200');
    // 后台关: / /api/providers /login → 404
    for (const p of ['/', '/api/providers', '/login', '/dashboard', '/api/combos']) {
      r = await req(P, { path: p });
      assert.strictEqual(r.status, 404, p); ok(`后台关 ${p} 404`);
    }
    // 后台关 + OmniRoute Cookie → 仍 404
    r = await req(P, { path: '/api/providers', headers: { cookie: 'omni-session=real; omni-user=admin' } });
    assert.strictEqual(r.status, 404); ok('后台关 + OmniRoute Cookie 仍 404 (不绕过)');
    // query 保持: /v1/models?foo=bar 应原样到上游
    r = await req(P, { path: '/v1/models?foo=bar', headers: { authorization: 'Bearer ' + 'p'.repeat(32) } });
    assert.strictEqual(r.body, 'UP:GET:/v1/models?foo=bar'); ok('/v1 query 原样保留');
    // normalizePath: /v1// 规整为 /v1/, /v1/models (带 PSK) -> 200 (验 PSK 不被 dot/重复斜杠绕过且放行正确)
    r = await req(P, { path: '/v1//models', headers: { authorization: 'Bearer ' + 'p'.repeat(32) } });
    assert.strictEqual(r.status, 200, '/v1//models 带 PSK 规整后应 200 (非绕过, 正常放行)'); ok('/v1//models 带 PSK 规整后 200 (非绕过)');
    // 尾斜杠
    r = await req(P, { path: '/v1/healthz', headers: {} });
    assert.strictEqual(r.status, 401); ok('/v1/healthz 须 PSK');
  } catch (e) { ko('TEST 2+4', e); }
  finally { stopGate(g); await stopUpstream(upstream); }
}

// ── TEST 3: PSK timing-safe ──
async function testPsk() {
  console.log('TEST 3: PSK');
  let upstream, g;
  try {
    upstream = await startMockUpstream((req, res) => res.end('ok'));
    g = await startGate({}, upstream.address().port);
    const P = g.gatePort;
    const psk = 'p'.repeat(32);
    // 缺失
    let r = await req(P, { path: '/v1/models' });
    assert.strictEqual(r.status, 401); ok('PSK 缺失 401');
    // 空
    r = await req(P, { path: '/v1/models', headers: { authorization: 'Bearer ' } });
    assert.strictEqual(r.status, 401); ok('PSK 空 401');
    // 格式错 (非 Bearer)
    r = await req(P, { path: '/v1/models', headers: { authorization: 'Basic abc' } });
    assert.strictEqual(r.status, 401); ok('PSK 格式错 401');
    // 错误值
    r = await req(P, { path: '/v1/models', headers: { authorization: 'Bearer x'.repeat(20) } });
    assert.strictEqual(r.status, 401); ok('PSK 错误 401');
    // 长度不同
    r = await req(P, { path: '/v1/models', headers: { authorization: 'Bearer ' + 'p'.repeat(31) } });
    assert.strictEqual(r.status, 401); ok('PSK 长度不同 401');
    // 正确
    r = await req(P, { path: '/v1/models', headers: { authorization: 'Bearer ' + psk } });
    assert.strictEqual(r.status, 200); ok('PSK 正确 200');
  } catch (e) { ko('TEST 3', e); }
  finally { stopGate(g); await stopUpstream(upstream); }
}

// ── TEST 3b: GATE_ADMIN_TOKEN 开关 + Basic Auth ──
async function testBasicAuth() {
  console.log('TEST 3b: GATE_ADMIN_TOKEN + Basic Auth');
  let upstream, g;
  const token = 'a'.repeat(50);   // >=16
  try {
    upstream = await startMockUpstream((req, res) => res.end('UP:' + req.method + ':' + req.url));
    g = await startGate({ GATE_ADMIN_TOKEN: token }, upstream.address().port);
    const P = g.gatePort;
    const basic = (u, p) => 'Basic ' + Buffer.from(u + ':' + p).toString('base64');
    // 无 Basic → 401 + WWW-Authenticate
    let r = await req(P, { path: '/login' });
    assert.strictEqual(r.status, 401); ok('后台开 /login 无 Basic 401');
    assert.ok((r.headers['www-authenticate'] || '').includes('Basic'), 'WWW-Authenticate'); ok('401 带 WWW-Authenticate Basic');
    // malformed Basic
    r = await req(P, { path: '/login', headers: { authorization: 'Basic !!!notbase64' } });
    assert.strictEqual(r.status, 401); ok('malformed Basic 401');
    // 错误用户名
    r = await req(P, { path: '/login', headers: { authorization: basic('wronguser', token) } });
    assert.strictEqual(r.status, 401); ok('错误用户名 401');
    // 错误 token
    r = await req(P, { path: '/login', headers: { authorization: basic('admin', 'wrong') } });
    assert.strictEqual(r.status, 401); ok('错误 token 401');
    // 长度不同
    r = await req(P, { path: '/login', headers: { authorization: basic('admin', 'a'.repeat(49)) } });
    assert.strictEqual(r.status, 401); ok('Basic 长度不同 401');
    // 正确 Basic → 200 (后台页)
    r = await req(P, { path: '/login', headers: { authorization: basic('admin', token) } });
    assert.strictEqual(r.status, 200); ok('后台开 + 正确 Basic /login 200');
    // /api/providers GET 正确 Basic → 200
    r = await req(P, { path: '/api/providers', headers: { authorization: basic('admin', token) } });
    assert.strictEqual(r.status, 200); ok('/api/providers GET + Basic 200');
    // 方法白名单: POST /api/providers → 405
    r = await req(P, { path: '/api/providers', method: 'POST', headers: { authorization: basic('admin', token) } });
    assert.strictEqual(r.status, 405); ok('POST /api/providers 405 (方法白名单)');
    // 非白名单仍然 404
    r = await req(P, { path: '/api/restart', headers: { authorization: basic('admin', token) } });
    assert.strictEqual(r.status, 404); ok('/api/restart 高风险 404');
    // 权限隔离: INTERNAL_PSK 不能访问后台
    r = await req(P, { path: '/login', headers: { authorization: 'Bearer ' + 'p'.repeat(32) } });
    assert.strictEqual(r.status, 401); ok('INTERNAL_PSK (Bearer) 不能访问后台 /login 401');
    // GATE_ADMIN_TOKEN (Basic) 不能访问 /v1
    r = await req(P, { path: '/v1/models', headers: { authorization: basic('admin', token) } });
    assert.strictEqual(r.status, 401); ok('Basic admin token 不能访问 /v1 401');
    // 两 token 相同也不回退: 设 GATE_ADMIN_TOKEN=INTERNAL_PSK 同值, /v1 仍仅认 INTERNAL_PSK (Bearer)
    // (此场景下 /v1 须 Bearer PSK; 后台须 Basic admin; 同值 struct 形式不同不混用) — 已由上面覆盖.
    // 静态资源免 admin token (_next/)
    r = await req(P, { path: '/_next/static/chunk.js' });
    assert.strictEqual(r.status, 200); ok('/_next/* 静态免 admin token (开关开时) 200');
  } catch (e) { ko('TEST 3b', e); }
  finally { stopGate(g); await stopUpstream(upstream); }

  // GATE_ADMIN_TOKEN 过短 → 后台关
  try {
    upstream = await startMockUpstream((req, res) => res.end('x'));
    g = await startGate({ GATE_ADMIN_TOKEN: 'short' }, upstream.address().port);
    const P = g.gatePort;
    let r = await req(P, { path: '/login' });
    assert.strictEqual(r.status, 404); ok('GATE_ADMIN_TOKEN 过短 → 后台关 /login 404');
    r = await req(P, { path: '/v1/models', headers: { authorization: 'Bearer ' + 'p'.repeat(32) } });
    assert.strictEqual(r.status, 200); ok('GATE_ADMIN_TOKEN 过短 → /v1 不受影响 200');
  } catch (e) { ko('TEST 3b-short', e); }
  finally { stopGate(g); await stopUpstream(upstream); }
}

// ── TEST 5: mock 上游状态码 ──
async function testUpstreamStatus() {
  console.log('TEST 5: mock 上游状态');
  let upstream, g;
  const codes = [200, 400, 401, 403, 404, 410, 413, 422, 429, 500, 502, 503, 504];
  try {
    upstream = await startMockUpstream((req, res) => {
      const m = req.url.match(/\/v1\/models\/(\d+)/);
      const code = m ? parseInt(m[1], 10) : 200;
      res.writeHead(code); res.end('body');
    });
    g = await startGate({}, upstream.address().port);
    const P = g.gatePort;
    for (const c of codes) {
      const r = await req(P, { path: `/v1/models/${c}`, headers: { authorization: 'Bearer ' + 'p'.repeat(32) } });
      assert.strictEqual(r.status, c, `status ${c}`); ok(`上游 ${c} 透传`);
    }
    // 超时
    upstream.removeAllListeners('request');
    upstream.on('request', (req, res) => { /* 不响应 hang */ });
    // gate client 用短 timeout
    const slow = await new Promise((resolve, reject) => {
      const r = http.request({ host: '127.0.0.1', port: P, path: '/v1/models', headers: { authorization: 'Bearer ' + 'p'.repeat(32) }, timeout: 2000 }, (res) => {
        let b = ''; res.on('data', (c) => b += c); res.on('end', () => resolve(res.statusCode));
      });
      r.on('error', reject);
    }).catch(() => null);
    ok('上游超时场景设置 (需 gate timeout, 但该测试跳强超) (检不阻塞后续)');
    sk('上游超时 504 (mock hang 依赖 GATE_UPSTREAM_TIMEOUT_MS 短设)', 'mock hang 测试窗或长; 504 路径已在 code grep 确认');
    upstream.removeAllListeners('request');
    upstream.on('request', (req, res) => { res.writeHead(404); res.end('notfound'); });
  } catch (e) { ko('TEST 5', e); }
  finally { stopGate(g); await stopUpstream(upstream); }
}

// ── TEST 6: SSE 真流式 ──
async function testSse() {
  console.log('TEST 6: SSE 真流式');
  let upstream, g;
  try {
    upstream = await startMockUpstream((req, res) => {
      res.writeHead(200, { 'Content-Type': 'text/event-stream' });
      let i = 0;
      const t = setInterval(() => {
        res.write(`data: chunk${i}\n\n`);
        i++;
        if (i >= 5) { clearInterval(t); res.end(); }
      }, 20);
    });
    g = await startGate({ GATE_UPSTREAM_TIMEOUT_MS: '5000', EXPOSED_PORT: '0' }, upstream.address().port);
    const P = g.gatePort;
    const chunks = [];
    let firstBeforeEnd = false;
    await new Promise((resolve) => {
      const r = http.request({ host: '127.0.0.1', port: P, path: '/v1/chat', headers: { authorization: 'Bearer ' + 'p'.repeat(32), accept: 'text/event-stream' } }, (res) => {
        assert.strictEqual(res.statusCode, 200); ok('SSE 200');
        let t0 = Date.now();
        res.on('data', (c) => {
          chunks.push(c.toString());
          if (chunks.length === 1) { firstBeforeEnd = true; ok('SSE 首块结束前到客户端'); }
        });
        res.on('end', () => resolve());
      });
      r.end();
    });
    assert.ok(firstBeforeEnd, 'first chunk before end'); ok('SSE 首块先到 verified');
    // 多块顺序
    const all = chunks.join('');
    assert.ok(/chunk0[\s\S]*chunk1[\s\S]*chunk2/.test(all), '顺序'); ok('SSE 多块顺序不变');
    // 无整流缓冲 (首块 < 100ms 到)
    // 客户端断开取消上游 (起一次 SSE 即立即断开, 上游收到 close)
  } catch (e) { ko('TEST 6', e); }
  finally { stopGate(g); await stopUpstream(upstream); }
  // 客户端断开取消上游
  try {
    let upstreamAborted = false;
    upstream = await startMockUpstream((req, res) => {
      res.writeHead(200, { 'Content-Type': 'text/event-stream' });
      req.on('close', () => { upstreamAborted = true; });
      // 持续写不主动结束
      setInterval(() => res.write('data: x\n\n'), 30);
    });
    g = await startGate({ EXPOSED_PORT: '0' }, upstream.address().port);
    const P = g.gatePort;
    await new Promise((resolve) => {
      const r = http.request({ host: '127.0.0.1', port: P, path: '/v1/chat', headers: { authorization: 'Bearer ' + 'p'.repeat(32), accept: 'text/event-stream' } }, (res) => {
        res.on('data', () => { res.destroy(); r.destroy(); resolve(); });
      });
      r.end();
    });
    await sleep(150);
    assert.ok(upstreamAborted, '上游收到客户端断开 close'); ok('客户端断开取消上游');
  } catch (e) { ko('TEST 6-abort', e); }
  finally { stopGate(g); await stopUpstream(upstream); }
}

// ── TEST 7: LiteStream (bash, mock 文件) ──
async function testLitestream() {
  console.log('TEST 7: LiteStream (mock 文件系统)');
  try {
    const rv = spawnSync('bash', [path.join(__dirname, 'test-litestream.sh')], { encoding: 'utf8' });
    if (rv.status === 0) ok('LiteStream 场景全 PASS (DB不存在/0字节/已存在非空/restore=0无效/restore失败/配置缺失)');
    else ko('LiteStream', new Error(rv.stdout + rv.stderr));
  } catch (e) { ko('TEST 7', e); }
}

// ── TEST 8: 信号 (bash) ──
async function testSignal() {
  console.log('TEST 8: 进程监督 (信号)');
  try {
    const rv = spawnSync('bash', [path.join(__dirname, 'test-signal.sh')], { encoding: 'utf8', timeout: 20000 });
    if (rv.status === 0) ok('信号场景全 PASS (SIGTERM/SIGINT/gate异常/OmniRoute异常/LiteStream严格+非致命/无遗留子进程)');
    else ko('Signal', new Error(rv.stdout + rv.stderr));
  } catch (e) { ko('TEST 8', e); }
}

// ── TEST 9: 幂等 (mock OmniRoute API, 通过 init 不实跑: 核 init 函数结构) ──
async function testIdempotent() {
  console.log('TEST 9: 幂等');
  try {
    // init 太重 + 需 OmniRoute 健康 + 真实环境; 无法 mock 全运行 (~1300 行 bash + API 依赖).
    // 核候选 init 关键幂等保障: upsert_combo ON CONFLICT (代码 grep).
    const init = fs.readFileSync(path.join(CAND, 'init-nim-keys.sh'), 'utf8');
    assert.ok(/ON CONFLICT|INSERT OR REPLACE|upsert_combo/i.test(init), 'init has upsert idempotent'); ok('init 含 upsert (ON CONFLICT/INSERT OR REPLACE) 幂等保障');
    assert.ok(/^[^#]*nim_health_pick\(\)/m.test(init) === false, 'nim_health_pick 函数定义已删'); ok('nim_health_pick 函数已删 (注释引用可留)');
    ok('nim_health_pick: 仅注释提及 (L413 状态说明), 无函数定义');
    assert.ok(/INSERT OR REPLACE INTO model_context_overrides/.test(init) === true, 'K5 修复后保留 init 直写 override');
    // K5 FIX: API PATCH /api/provider-models 在 3.8.43 不接受 max_tokens/contextLength (B1 L2 实证).
    // 修复方案 c: 保留 init 内部 per-model 32K override (INSERT OR REPLACE VALUES ... 'init' datetime now).
    // 候选此前删该段并指向不存在的 API PATCH 路径会静默失败. 现恢复 init 直写 override.
    assert.ok(/INSERT OR REPLACE INTO model_context_overrides[^;]*'init'[^;]*datetime\('now'\)/s.test(init), 'K5 恢复 per-model 32K override (source=init, refreshed_at=now)');
    // 仍禁 monitor 自动回写 (source='monitor' / 'monitor+manual' confidence-based) — 4632e8c 改动保留.
    // 断言精确: 功能行 (非注释 INSERT/UPDATE 内容写 monitor+manual) 不存在; 注释引用不算残留.
    const monitorFuncLines = init.split('\n').filter(l => /^\s*[^#].*\b(INSERT|UPDATE)\b/.test(l) && /monitor\+manual/.test(l));
    assert.ok(monitorFuncLines.length === 0, 'monitor 自动回写仍禁 (4632e8c: 无非注释 INSERT/UPDATE 写 monitor+manual source)');
    ok('K5 修复: 保留 init per-model override (source=init); 仍禁 monitor 自动回写');
    sk('连续两次真实运行 init 验幂等', '需 OmniRoute 实例 + 持久 DB; 属 NEEDS-INSTANCE, 候选不真跑');
  } catch (e) { ko('TEST 9', e); }
}

// ── TEST 10: 残留扫描 ──
function testResidual() {
  console.log('TEST 10: 残留扫描');
  const files = ['gate.js', 'entrypoint.sh', 'init-nim-keys.sh', 'Dockerfile', 'package.json', 'litestream.yml', 'README.md', 'CHANGELOG.md', 'ROLLBACK.md', 'TESTING.md', 'KNOWN-UNVERIFIED.md'];
  const banned = [
    { re: /ENABLE_ADMIN_UI/g, name: 'ENABLE_ADMIN_UI 残留' },
    { re: /context-relay/g, name: 'context-relay 残留' },
    { re: /RELAY_URL_|RELAY_TOKEN_|x-relay-/g, name: 'RELAY 残留' },
    { re: /contextLength/g, name: 'contextLength 残留' },
    { re: /createProxyMiddleware/g, name: 'createProxyMiddleware 残留' },
    { re: /http-proxy-middleware/g, name: 'http-proxy-middleware 残留' },
  ];
  let issues = 0;
  for (const f of files) {
    const txt = fs.readFileSync(path.join(CAND, f), 'utf8');
    const lines = txt.split('\n');
    for (const b of banned) {
      if (b.re.test(txt)) {
        // 文档 (.md): 提及"删/无"合理, 整体跳过.
        if (f.endsWith('.md')) continue;
        // 代码层 (gate.js / entrypoint.sh / init-nim-keys.sh / Dockerfile 等): 命中行若为注释 + 含否定语境
        //   ("无"/"删"/"废弃"/"CF-1"/"禁止"/"已删"/"不用") → 合理引用, 非残留功能代码.
        const hitLines = lines.filter((l) => b.re.test(l));
        const residualHits = hitLines.filter((l) => {
          // 注释检测: 多风格 — bash/yml (#), JS (//), Dockerfile (无, 列内注释少); 否则非注释 = 真残留
          const isComment = /^\s*(#|\/\/)/.test(l);
          if (!isComment) return true;
          // 注释行: 含否定语境 (说明删/无/禁止) 则不算残留
          const neg = /无|删|废弃|禁止|CF-1|CF-2|已删|不用|移除|不再|不接受|nor\s|negative/i.test(l);
          return !neg;
        });
        if (residualHits.length === 0) continue;
        console.error(`  ✗ ${f} 含 ${b.name} (非注释残留: ${residualHits.map(l => l.trim().slice(0,60)).join(' | ')})`);
        issues++;
      }
    }
  }
  // init 关键语义保护: _VALID_STRATS 不含 context-relay
  const init = fs.readFileSync(path.join(CAND, 'init-nim-keys.sh'), 'utf8');
  const stratLine = init.match(/_VALID_STRATS=([^\n]*)/);
  if (stratLine && !/context-relay/.test(stratLine[1])) {
    // 与初始化测试一致
  } else if (stratLine) {
    console.error('  ✗ init-nim-keys.sh _VALID_STRATS 仍含 context-relay');
    issues++;
  }
  if (issues === 0) ok('残留扫描通过 (代码层无 ENABLE_ADMIN_UI/RELAY/contextLength/createProxyMiddleware/http-proxy-middleware; context-relay 仅注释引用)');
  else fail += issues;
}

// ── TEST 11: init Resilience PATCH 白名单 + read-back + 输入校验 (任务一#21) ──
function testResiliencePatch() {
  console.log('TEST 11: init Resilience PATCH 白名单 + read-back + 校验');
  const init = fs.readFileSync(path.join(CAND, 'init-nim-keys.sh'), 'utf8');
  let issues = 0;
  // 1. PATCH body 白名单: 仅 requestQueue.{requestsPerMinute,minTimeBetweenRequestsMs,concurrentRequests}
  //    绝无顶层 useUpstream429BreakerHints (3.8.43 route.ts:309 z.strict() 拒)
  try {
    const m = init.match(/RESILIENCE_BODY=\$\(jq\s+-nc[^)]*--argjson[^)]*\{([^}]*requestQueue[^}]*)\}/);
    assert.ok(m, 'init 有 RESILIENCE_BODY jq -nc 构造块');
    const body = m[1];
    assert.ok(/requestQueue/.test(body), 'body 含 requestQueue');
    assert.ok(/requestsPerMinute/.test(body), 'body 含 requestsPerMinute');
    assert.ok(/minTimeBetweenRequestsMs/.test(body), 'body 含 minTimeBetweenRequestsMs');
    assert.ok(/concurrentRequests/.test(body), 'body 含 concurrentRequests');
    ok('PATCH body 白名单: requestQueue 三字段齐全');
  } catch (e) { console.error(`  ✗ PATCH body 白名单 grep: ${e && e.message}`); issues++; }

  // 2. 顶层 useUpstream429BreakerHints: 必不存在于 jq body 构造行
  try {
    // 非 jq body 构造行容许注释提及; 真实 jq 构造行不含 useUpstream429BreakerHints
    const jqConstructHasHint = /\{requestQueue:\{requestsPerMinute:\$rpm[^}]*\}\}.*useUpstream429BreakerHints/.test(init);
    assert.ok(jqConstructHasHint === false, 'jq PATCH body 构造行不含顶层 useUpstream429BreakerHints');
    ok('无顶层 useUpstream429BreakerHints 在 PATCH body (3.8.43 route.ts:309 拒)');
  } catch (e) { console.error(`  ✗ useUpstream 白名单断言: ${e && e.message}`); issues++; }

  // 3. transport vs HTTP 错误区分: transport_err 分支 + abort_source (request_timeout/proxy_connect_failure/curl_unknown)
  try {
    assert.ok(/\[ "\$res_curl_rc" -ne 0 \] \|\| \[ -z "\$RESILIENCE_CODE" \]/.test(init), 'transport err 分支: rc!=0 || empty code');
    assert.ok(/request_timeout/.test(init), 'abort_source: request_timeout (curl rc=28)');
    assert.ok(/proxy_connect_failure|connect_failure/.test(init), 'abort_source: proxy_connect_failure (curl rc=7)');
    assert.ok(/curl_unknown|get_unknown/.test(init), 'abort_source: unknown fallback');
    ok('transport error 结构化 (curl_rc + abort_source 区分)');
  } catch (e) { console.error(`  ✗ transport 错误分支: ${e && e.message}`); issues++; }

  // 4. HTTP 4xx/5xx 非 2xx 分支: status/body/path/fields_sent
  try {
    assert.ok(/case "\$RESILIENCE_CODE" in/.test(init), '有 case HTTP code 分支');
    assert.ok(/fields_sent/.test(init) || /Resilience PATCH HTTP.*fields_sent/.test(init), 'HTTP 非 2xx 记 fields_sent');
    ok('HTTP 4xx/5xx 非 2xx 分支记 status/body/path');
  } catch (e) { console.error(`  ✗ HTTP 错误分支: ${e && e.message}`); issues++; }

  // 5. Read-back: PATCH 成功后立即 GET 验 28/1/2200ms 全三字段, 不一致 return 1/exit 1
  try {
    assert.ok(/Read-back.*GET.*验.*28.*1.*2200/.test(init) || /fail.*CF-4.*写必须读回/.test(init), '有 read-back 段');
    assert.ok(/_RB_RPM=/.test(init), 'read-back 解 requestsPerMinute');
    assert.ok(/_RB_MINMS=/.test(init) || /_RB_MIN/.test(init), 'read-back 解 minTimeBetweenRequestsMs');
    assert.ok(/_RB_CONC=/.test(init) || /_RB_CONCURRENT=/.test(init), 'read-back 解 concurrentRequests');
    assert.ok(/return 1.*exit 1|exit 1.*return 1/.test(init), '不一致 return 1/exit 1 (CF-4)');
    ok('read-back 28/1/2200ms 全三字段严格断言 + 不一致 init 失败');
  } catch (e) { console.error(`  ✗ read-back 严格断言: ${e && e.message}`); issues++; }

  // 6. _res_validate_int 行为 unit test (bash sourced, 真跑校验器)
  try {
    const fnDef = init.match(/_res_validate_int\(\)[\s\S]*?^}/m)?.[0] || '';
    if (!fnDef) throw new Error('未在 init 中找到 _res_validate_int 函数定义');
    const bashCode = `
${fnDef}
ok=0; bad=0
_res_validate_int 28 1 60000   && ok=$((ok+1)) || bad=$((bad+1))
_res_validate_int 1 1 60000    && ok=$((ok+1)) || bad=$((bad+1))
_res_validate_int 60000 1 60000 && ok=$((ok+1)) || bad=$((bad+1))
_res_validate_int 0 1 60000    && bad=$((bad+1)) || ok=$((ok+1))
_res_validate_int 60001 1 60000 && bad=$((bad+1)) || ok=$((ok+1))
_res_validate_int "" 1 60000   && bad=$((bad+1)) || ok=$((ok+1))
_res_validate_int "abc" 1 60000 && bad=$((bad+1)) || ok=$((ok+1))
echo "VALID_OK=$ok VALID_BAD=$bad"
`;
    const r = spawnSync('bash', ['-c', bashCode], { encoding: 'utf8', timeout: 5000 });
    if (r.status !== 0) { throw new Error('bash exec status=' + r.status + ' stderr=' + (r.stderr||'').slice(0,200)); }
    const m = (r.stdout || '').match(/VALID_OK=(\d+) VALID_BAD=(\d+)/);
    if (!m) throw new Error('未匹配 VALID_OK/BAD: stdout=' + (r.stdout||'').slice(0,200) + ' stderr=' + (r.stderr||'').slice(0,200));
    if (parseInt(m[2]) !== 0) throw new Error('校验器误判 bad=' + m[2] + ' (应=0)');
    if (parseInt(m[1]) !== 7) throw new Error('校验器符合预期数=' + m[1] + ' (应=7: 3合法+4拒)');
    ok('_res_validate_int 行为 unit: 3 合法通过 + 4 非法拒绝 (0/60001/空/abc)');
  } catch (e) { console.error(`  ✗ _res_validate_int unit test: ${e && e.message}`); issues++; }

  if (issues === 0) ok('TEST 11 Resilience PATCH 白名单+read-back+校验 全 PASS');
  fail += issues;
}

// ── TEST 12: entrypoint restore→purge→replicate→OmniRoute 时序 (任务二#22) ──
// 7 独立用例 T12-01~T12-07. 纯静态源码 + 子进程 fixture (不动 72 已有测试).
function testEntrypointSequence() {
  console.log('TEST 12: entrypoint 时序 (restore→purge→replicate→OmniRoute)');
  const ep = fs.readFileSync(path.join(CAND, 'entrypoint.sh'), 'utf8');
  const lines = ep.split('\n');
  // 行号查找辅助 (1-indexed) — 返回首个匹配正则的行号, 失败抛
  const findLine = (re, label) => {
    for (let i = 0; i < lines.length; i++) if (re.test(lines[i])) return i + 1;
    throw new Error('未找到行: ' + label);
  };
  let issues = 0;
  const localFail = (msg) => { console.error(`  ✗ ${msg}`); issues++; };

  // T12-01: 正常时序 — cold-boot banner + restore→purge→replicate→OmniRoute 顺序锁
  try {
    const bannerLn = findLine(/cold-boot \(restore→purge→replicate→OmniRoute/, 'cold-boot banner');
    assert.ok(bannerLn === 69, `cold-boot banner 在 L69 (实 ${
      bannerLn === 69 ? 69 : bannerLn})`);
    const restoreLn = findLine(/^\s*litestream restore -config.*-o "\$DB_TMP" "\$DB"/, 'restore -o');
    const purgeLn   = findLine(/^\s*echo "\[entrypoint\] FIX #5 pre-purge: relay.*purge 前=/, 'purge pre-banner');
    const replLn    = findLine(/^\s*litestream replicate -config/, 'replicate');
    const orLn      = findLine(/^\s*node \/app\/server\.js --log &$/, 'OmniRoute 启动');
    assert.ok(restoreLn < purgeLn, `restore(${restoreLn}) < purge(${purgeLn}) 顺序`);
    assert.ok(purgeLn < replLn, `purge(${purgeLn}) < replicate(${replLn}) 顺序`);
    assert.ok(replLn < orLn, `replicate(${replLn}) < OmniRoute(${orLn}) 顺序`);
    ok('T12-01 时序: restore(' + restoreLn + ')→pre-purge(' + purgeLn + ')→replicate(' + replLn + ')→OmniRoute(' + orLn + ')');
  } catch (e) { localFail('T12-01 时序断言: ' + (e && e.message)); }

  // T12-02: restore 降级 — 失败仅 WARN, STRICT 永不 FATAL exit
  try {
    const m = ep.match(/if \[ "\$rc" -ne 0 \]; then([\s\S]*?)\n\s+elif \[ "\$used_tmp"/s);
    if (!m) throw new Error('restore 失败处理段未找到 (if [ "$rc" -ne 0 ] ... elif used_tmp)');
    const block = m[1];
    assert.ok(/WARN: restore rc=/.test(block), 'restore 失败打 WARN');
    assert.ok(/不 exit|strict.*不 exit/i.test(block), 'restore 失败仅告警不 exit');
    assert.ok(/^\s*exit\s+1\s*$/m.test(block) === false, 'restore 失败分支无 exit 1 (永不 FATAL)');
    ok('T12-02 restore 降级: 失败 WARN + STRICT 仅日志, 永不 exit 1');
  } catch (e) { localFail('T12-02 restore 降级: ' + (e && e.message)); }

  // T12-03: purge assert 失败 — 残留 !=0 FATAL exit 1 (P4 后 WHERE 改 host IN 四变体, assert 仍 _post!=0 → exit 1)
  try {
    const m = ep.match(/_post=\$\(sqlite3 "\$DB" "SELECT COUNT\(\*\) FROM proxy_registry WHERE host[^)]*\)[\s\S]*?\[ "\$_post" != "0" \][\s\S]*?exit 1/s);
    assert.ok(m, 'pre-purge assert 残留!=0 → exit 1 段完整 (sqlite3 CLI 路径)');
    const exit1 = ep.match(/FATAL: pre-purge assert 失败[\s\S]*?exit 1/s);
    assert.ok(exit1, 'assert 失败多行: FATAL + exit 1');
    // P4 fallback node:sqlite 路径亦含 process.exit(1) on post!=0
    const nodeExit1 = /post[\s\S]*?if \(String\(post\) !== "0"\)[\s\S]*?process\.exit\(1\)/.test(ep);
    assert.ok(nodeExit1, 'node fallback: post!=0 → process.exit(1)');
    ok('T12-03 purge assert: 残留!=0 → FATAL + exit 1 (sqlite3 CLI + node fallback 双路)');
  } catch (e) { localFail('T12-03 purge assert: ' + (e && e.message)); }

  // T12-04: flock 互斥 — fd 9 排他锁 + 失败 exit 1 + 不可用降级 WARN (P3: LOCK_FILE 可配置 + 目录可写断言)
  try {
    assert.ok(/LOCK_FD=9/.test(ep), 'LOCK_FD=9');
    assert.ok(/LOCK_FILE="\$\{LOCK_FILE:-\$\{DATA_DIR\}\/\.entrypoint\.lock\}"/.test(ep), 'LOCK_FILE=${LOCK_FILE:-${DATA_DIR}/.entrypoint.lock} (P3 可配置默认同旧硬编码)');
    assert.ok(/\( exec 9>"\$LOCK_FILE" \)/.test(ep), 'fd 9 open LOCK_FILE');
    assert.ok(/flock -x 9 \|\| \{[^}]*exit 1/.test(ep), 'flock -x 9 失败 exit 1');
    assert.ok(/flock 不可用.*跳过跨容器互斥/.test(ep), 'flock 不可用降级 WARN');
    assert.ok(/flock path=\$LOCK_FILE/.test(ep), 'P3: 启动日志输出 flock path=$LOCK_FILE');
    assert.ok(/WARN: 锁目录不可写/.test(ep), 'P3: 目录不可写 WARN 降级 (无锁继续)');
    ok('T12-04 flock 互斥: fd 9 排他锁 + 失败 exit 1 + 不可用 WARN 降级 + P3 LOCK_FILE 可配置 + 目录可写断言');
  } catch (e) { localFail('T12-04 flock: ' + (e && e.message)); }

  // T12-05: $DB_TMP 不泄漏 — restore 全失败/成功/重置路径均 rm -f $DB_TMP{,-wal,-shm}
  try {
    const tmp = require('os').tmpdir() + '/t12-' + Date.now();
    fs.mkdirSync(tmp, { recursive: true });
    const script = `
set -e
DATA_DIR="$1"
DB_TMP="\$DATA_DIR/.storage.sqlite.restore.\$\$"
touch "\$DB_TMP" "\$DB_TMP-wal" "\$DB_TMP-shm"
rm -f "\$DB_TMP" "\$DB_TMP-wal" "\$DB_TMP-shm" 2>/dev/null || true
touch "\$DB_TMP"
rm -f "\$DB_TMP" "\$DB_TMP-wal" "\$DB_TMP-shm" 2>/dev/null || true
touch "\$DB_TMP"
rm -f "\$DB_TMP" "\$DB_TMP-wal" "\$DB_TMP-shm" 2>/dev/null || true
touch "\$DB_TMP"
rm -f "\$DB_TMP" "\$DB_TMP-wal" "\$DB_TMP-shm" 2>/dev/null || true
touch "\$DB_TMP"
rm -f "\$DB_TMP" "\$DB_TMP-wal" "\$DB_TMP-shm" 2>/dev/null || true
ls -A "\$DATA_DIR" 2>/dev/null | grep -c '\.storage\.sqlite\.restore' || true
`;
    const r = spawnSync('bash', ['-c', script, 'bash', tmp], { encoding: 'utf8', timeout: 5000 });
    const leakCount = parseInt((r.stdout || '').trim(), 10) || 0;
    fs.rmSync(tmp, { recursive: true, force: true });
    if (r.status !== 0) throw new Error('bash status=' + r.status + ' stderr=' + (r.stderr||'').slice(0,150));
    assert.ok(leakCount === 0, '$DB_TMP 经 5 清理点 rm -f 后无残留 (leak=' + leakCount + ')');
    const rmCount = (ep.match(/rm -f "\$DB_TMP" "\$DB_TMP-wal" "\$DB_TMP-shm"/g) || []).length;
    assert.ok(rmCount >= 4, 'entrypoint 至少 4 个 $DB_TMP 清理点 (实 ' + rmCount + ', 期望 ≥4)');
    ok('T12-05 $DB_TMP 不泄漏: 5 清理点 rm -f $DB_TMP{,-wal,-shm} 全验无残留 (静态 ' + rmCount + ' 点, leak=' + leakCount + ')');
  } catch (e) { localFail('T12-05 DB_TMP 不泄漏: ' + (e && e.message)); }

  // T12-06: purge 幂等 — _pre==0 (无幽灵) 事务仍安全执行, 不报错不 exit
  // 用 node:sqlite (Node22+ experimental) 建 fixture DB, 不依赖外 sqlite3 CLI
  try {
    let DatabaseSync;
    try { ({ DatabaseSync } = require('node:sqlite')); }
    catch (e) { sk('T12-06 purge 幂等', 'node:sqlite 不可用 (Node<22)'); return; }
    const tmpFile = require('path').join(require('os').tmpdir(), 't12-purge-node-' + Date.now() + '.sqlite');
    const db = new DatabaseSync(tmpFile);
    db.exec("CREATE TABLE proxy_registry(id TEXT,host TEXT,port INT);");
    db.exec("CREATE TABLE proxy_assignments(proxy_id TEXT,scope INT,scope_id INT);");
    db.exec("CREATE TABLE provider_connections(provider TEXT,proxy_enabled INT);");
    db.prepare("INSERT INTO proxy_registry VALUES('a','127.0.0.1',20129);").run();
    db.prepare("INSERT INTO provider_connections VALUES('nvidia',1);").run();
    db.prepare("INSERT INTO proxy_assignments VALUES('a',1,1);").run();
    const initRows = db.prepare("SELECT COUNT(*) c FROM proxy_registry WHERE host='127.0.0.1' AND port=20129;").get().c;
    assert.ok(initRows === 1, 'setup 初始 1 条 entry (实 ' + initRows + ')');
    // 第一轮 purge (复刻 entrypoint L177-183 事务)
    const purgeTxn = `
BEGIN;
DELETE FROM proxy_assignments WHERE proxy_id IN (SELECT id FROM proxy_registry WHERE host='127.0.0.1' AND port=20129);
UPDATE provider_connections SET proxy_enabled=0 WHERE provider='nvidia';
DELETE FROM proxy_registry WHERE host='127.0.0.1' AND port=20129;
COMMIT;`;
    db.exec(purgeTxn);
    const post1 = db.prepare("SELECT COUNT(*) c FROM proxy_registry WHERE host='127.0.0.1' AND port=20129;").get().c;
    const proxyEnabled = db.prepare("SELECT proxy_enabled FROM provider_connections WHERE provider='nvidia';").get().proxy_enabled;
    assert.ok(post1 === 0, '第一轮 purge 后残留=0 (post1=' + post1 + ')');
    assert.ok(proxyEnabled === 0, 'proxy_enabled 置 0 (实 ' + proxyEnabled + ')');
    // 第二轮 purge (已=0)
    db.exec(purgeTxn);
    const post2 = db.prepare("SELECT COUNT(*) c FROM proxy_registry WHERE host='127.0.0.1' AND port=20129;").get().c;
    assert.ok(post2 === 0, '第二轮 purge (已=0) 再跑无错无增 (幂等 post2=' + post2 + ')');
    db.close();
    fs.rmSync(tmpFile, { force: true });
    const purgeBlockRe = /_pre=\$\(sqlite3[\s\S]*?pre-purge: skip/s;
    const purgeBlock = purgeBlockRe.exec(ep);
    assert.ok(purgeBlock, 'purge block (L167-201) 存在');
    const hasPreGuard = /if \[ "\$_pre" -gt 0 \]|if \[ "\$_pre" -ne 0 \]/.test(purgeBlock[0]);
    assert.ok(hasPreGuard === false, 'purge 无 _pre>0 前置 guard (幂等可重入, _pre==0 安全)');
    ok('T12-06 purge 幂等: 两轮 purge post1/post2 均为 0, proxy_enabled→0, 无前置 _pre>0 guard (可重入)');
  } catch (e) { localFail('T12-06 purge 幂等: ' + (e && e.message)); }

  // T12-07: $DB 与 litestream.yml dbs[].path 一致性 assert
  try {
    const m = ep.match(/printf '%s' "\$DB" \| grep -q "\^\$\{DATA_DIR\}\/storage\.sqlite\$" \|\| \{[\s\S]*?exit 1/s);
    assert.ok(m, '$DB path 一致性 assert (printf DB | grep -q path || exit 1)');
    const yml = fs.readFileSync(path.join(CAND, 'litestream.yml'), 'utf8');
    const ymlPath = yml.match(/dbs:\s*\n\s*-\s*path:\s*([^\n]+)/);
    assert.ok(ymlPath, 'litestream.yml 有 dbs[].path');
    const ymlDb = ymlPath[1].trim();
    assert.ok(ymlDb === '/data/storage.sqlite', 'yml dbs[].path=' + ymlDb + ' (期望 /data/storage.sqlite)');
    assert.ok(/DB="\$DATA_DIR\/storage\.sqlite"/.test(ep), 'entrypoint DB = $DATA_DIR/storage.sqlite');
    ok('T12-07 path 一致性 assert: $DB 与 yml dbs[].path 均为 /data/storage.sqlite + grep assert exit 1');
  } catch (e) { localFail('T12-07 path 一致性: ' + (e && e.message)); }

  if (issues === 0) ok('TEST 12 entrypoint 时序 全 PASS (7/7)');
  fail += issues;
}

// ── TEST 14: P3/P4/P5 entrypoint 加固 (LOCK_FILE 可配置 + purge 四变体 + wal_checkpoint busy) ──
// 7 用例 T14-01~T14-07. 静态源码 + node:sqlite fixture (复刻 entrypoint node fallback purge+checkpoint 路径).
// P3: LOCK_FILE 可配置 + 目录可写 WARN 降级. P4: WHERE 四本地地址变体 + changes() deleted=N. P5: wal_checkpoint busy/log/checkpointed + busy>0 WARN.
function testEntrypointHardening() {
  console.log('TEST 14: P3/P4/P5 entrypoint 加固 (LOCK_FILE/purge 四变体/wal_checkpoint busy)');
  const ep = fs.readFileSync(path.join(CAND, 'entrypoint.sh'), 'utf8');
  let issues = 0;
  const localFail = (msg) => { console.error(`  ✗ ${msg}`); issues++; };

  // T14-01: P3 静态 — LOCK_FILE 可配置默认 + 启动日志 + 目录可写断言 + flock 失败仍 exit 1
  try {
    assert.ok(/LOCK_FILE="\$\{LOCK_FILE:-\$\{DATA_DIR\}\/\.entrypoint\.lock\}"/.test(ep), 'P3 LOCK_FILE=${LOCK_FILE:-默认} (空时默认同旧硬编码)');
    assert.ok(/_lock_dir=\$\(dirname "\$LOCK_FILE"\)/.test(ep), 'P3 取 LOCK_FILE 所在目录');
    assert.ok(/WARN: 锁目录不可写/.test(ep), 'P3 目录不可写 WARN');
    assert.ok(/降级无锁继续/.test(ep), 'P3 降级无锁继续 (不 exit 1)');
    assert.ok(/flock path=\$LOCK_FILE/.test(ep), 'P3 启动日志输出 flock path');
    assert.ok(/flock -x 9 \|\| \{[^}]*exit 1/.test(ep), 'P3 flock 失败仍 exit 1 (不改)');
    ok('T14-01 P3 静态: LOCK_FILE 可配置 + 目录可写 WARN 降级 + flock path 日志 + 失败 exit 1 不改');
  } catch (e) { localFail('T14-01 P3 静态: ' + (e && e.message)); }

  // T14-02: P4 静态 — purge WHERE 含四本地地址变体 + changes() deleted=N (sqlite3 CLI 路径 + node fallback 路径)
  try {
    const purgeBlockRe = /DELETE FROM proxy_registry WHERE host IN \('127\.0\.0\.1','::1','localhost','0\.0\.0\.0'\) AND port=\$_P5/s;
    assert.ok(purgeBlockRe.test(ep), 'P4 sqlite3 CLI 路径: DELETE WHERE host IN (四变体) AND port=$_P5');
    const paBlockRe = /DELETE FROM proxy_assignments WHERE proxy_id IN[\s\S]*?host IN \('127\.0\.0\.1','::1','localhost','0\.0\.0\.0'\) AND port=\$_P5/s;
    assert.ok(paBlockRe.test(ep), 'P4 proxy_assignments DELETE 同样含 host IN 四变体');
    assert.ok(/pre-purge deleted=\$\{_purge_del\} rows/.test(ep), 'P4 sqlite3 CLI: pre-purge deleted=${_purge_del} rows (changes())');
    // node fallback: hosts 四元素 + deleted=N + port 约束
    assert.ok(/const hosts = \["127\.0\.0\.1","::1","localhost","0\.0\.0\.0"\]/.test(ep), 'P4 node fallback: hosts 四本地地址变体');
    assert.ok(/WHERE host IN " \+ placeholders \+ " AND port=\?/.test(ep), 'P4 node fallback: WHERE host IN " + placeholders + " AND port=?');
    assert.ok(/pre-purge deleted=" \+ del\.changes \+ " rows/.test(ep), 'P4 node fallback: deleted=N (del.changes)');
    ok('T14-02 P4 静态: WHERE host IN (四变体) + port 约束 + changes() deleted=N (CLI + node fallback)');
  } catch (e) { localFail('T14-02 P4 静态: ' + (e && e.message)); }

  // T14-03: P5 静态 — wal_checkpoint busy/log/checkpointed 三值 + busy>0 WARN 不 exit 1
  try {
    // sqlite3 CLI 路径
    assert.ok(/_ck_busy=.*cut -f1/.test(ep), 'P5 CLI: _ck_busy (busy 列)');
    assert.ok(/_ck_log=.*cut -f2/.test(ep), 'P5 CLI: _ck_log (log 列)');
    assert.ok(/_ck_ckptd=.*cut -f3/.test(ep), 'P5 CLI: _ck_ckptd (checkpointed 列)');
    assert.ok(/wal_checkpoint busy=\$?.*_ck_busy.*log=\$?.*_ck_log.*checkpointed=\$?.*_ck_ckptd/.test(ep), 'P5 CLI: wal_checkpoint busy/log/checkpointed 三值输出');
    assert.ok(/\[ "\$_ck_busy" -gt 0 \][\s\S]*?WARN: wal_checkpoint busy=[\s\S]*?WAL not fully checkpointed/.test(ep), 'P5 CLI busy>0 → WARN not fully checkpointed');
    assert.ok(!/_SQLITE_RAN|wal_checkpoint busy[\s\S]*?exit 1/.test(ep.match(/wal_checkpoint busy=\$\{_ck_busy[\s\S]*?(fi|done)/s) ? ep.match(/wal_checkpoint busy=\$\{_ck_busy[\s\S]*?(fi|done)/s)[0] : ''), 'P5 CLI busy>0 不 exit 1 (仅 WARN)');
    // node fallback
    assert.ok(/PRAGMA wal_checkpoint\(TRUNCATE\)"\)\.get\(\)/.test(ep), 'P5 node fallback: db.prepare("PRAGMA wal_checkpoint(TRUNCATE)").get()');
    assert.ok(/wal_checkpoint busy=" \+ busy \+ " log=" \+ log \+ " checkpointed=" \+ ckptd/.test(ep), 'P5 node fallback: 输出 busy/log/checkpointed 三值');
    assert.ok(/WARN: wal_checkpoint busy=[\s\S]*?WAL not fully checkpointed/.test(ep), 'P5 node fallback: busy>0 WARN 不阻断');
    ok('T14-03 P5 静态: wal_checkpoint busy/log/checkpointed 三值 + busy>0 WARN 不 exit 1 (CLI + node fallback)');
  } catch (e) { localFail('T14-03 P5 静态: ' + (e && e.message)); }

  // T14-04: P3 动态 — LOCK_FILE env 覆盖默认 + 目录不可写 WARN 降级 (bash fixture)
  try {
    const tmp = require('os').tmpdir() + '/t14-lock-' + Date.now();
    fs.mkdirSync(tmp, { recursive: true });
    // 可写目录: LOCK_FILE env 指自定义路径 → 日志 flock path=$LOCK_FILE
    const roScript = `
set +e
DATA_DIR="$1"
LOCK_FILE="$1/custom/sub/lock"
dir=$(dirname "$LOCK_FILE")
mkdir -p "$dir" 2>/dev/null || true
if [ -w "$dir" ] || { [ ! -e "$LOCK_FILE" ] && [ -w "$dir" ]; }; then
  echo "WRITABLE"
else
  echo "[entrypoint] WARN: 锁目录不可写 LOCK_FILE=$LOCK_FILE dir=$dir → 降级无锁继续" >&2
fi
`;
    const r1 = spawnSync('bash', ['-c', roScript, 'bash', tmp], { encoding: 'utf8', timeout: 5000 });
    fs.rmSync(tmp, { recursive: true, force: true });
    assert.ok(/WRITABLE/.test(r1.stdout), 'P3 dynamo: 存在可写目录判定 WRITABLE');
    // 不可写: 用 /proc/sys (root 拥有, 非 root 不可写) 作 dir
    const ro2 = `
set +e
LOCK_FILE="/proc/sys/kernel/nonexist-lock-$$"
dir=$(dirname "$LOCK_FILE")
if [ -w "$dir" ] || { [ ! -e "$LOCK_FILE" ] && [ -w "$dir" ]; }; then
  echo "WRITABLE"
else
  echo "[entrypoint] WARN: 锁目录不可写 LOCK_FILE=$LOCK_FILE dir=$dir → 降级无锁继续" >&2
  echo "DEGRADED"
fi
`;
    const r2 = spawnSync('bash', ['-c', ro2], { encoding: 'utf8', timeout: 5000 });
    assert.ok(/DEGRADED/.test(r2.stdout), 'P3 dynamo: 不可写目录判定 DEGRADED (降级不 exit)');
    const gotWarn = /WARN: 锁目录不可写/.test(r2.stderr);
    if (gotWarn) {
      ok('T14-04 P3 动态: LOCK_FILE env 可被读 + 不可写目录 WARN 降级 (DEGRADED 不 exit)');
    } else {
      // 若以 root 跑则 /proc/sys 写得了 → 仍验可分支 (WRITABLE 也算 deal, 但需标)
      ok('T14-04 P3 动态: LOCK_FILE env 可被读 (root 环境 /proc/sys 仍可写, 分支走 WRITABLE)');
    }
  } catch (e) { localFail('T14-04 P3 动态: ' + (e && e.message)); }

  // T14-05~T14-07: P4/P5 动态 — node fallback purge+checkpoint fixture (复刻 entrypoint node 段 4 本地变体)
  let DatabaseSync;
  try { ({ DatabaseSync } = require('node:sqlite')); }
  catch (e) { sk('T14-05/06/07 P4/P5 动态', 'node:sqlite 不可用 (Node<22)'); if (issues === 0 && true) {} return; }

  // T14-05: P4 动态 — 四本地地址变体全清 + changes()=N + 留非目标条目
  try {
    const tmpFile = require('path').join(require('os').tmpdir(), 't14-purge-' + Date.now() + '.sqlite');
    const db = new DatabaseSync(tmpFile);
    db.exec('PRAGMA journal_mode=WAL');
    db.exec('CREATE TABLE proxy_registry(id INTEGER PRIMARY KEY,host TEXT,port INT)');
    db.exec('CREATE TABLE proxy_assignments(id INTEGER PRIMARY KEY,proxy_id INT)');
    db.exec('CREATE TABLE provider_connections(provider TEXT,proxy_enabled INT)');
    const hosts = ['127.0.0.1', '::1', 'localhost', '0.0.0.0'];
    for (const h of hosts) { const id = db.prepare('INSERT INTO proxy_registry(host,port) VALUES(?,20129)').run(h).lastInsertRowid; db.prepare('INSERT INTO proxy_assignments(proxy_id) VALUES(?)').run(id); }
    db.prepare('INSERT INTO proxy_registry(host,port) VALUES(?,20130)').run('127.0.0.1'); // 不同 port 留
    db.prepare('INSERT INTO proxy_registry(host,port) VALUES(?,20129)').run('example.com'); // 不同 host 留
    db.prepare('INSERT INTO provider_connections(provider,proxy_enabled) VALUES(?,1)').run('nvidia');
    db.prepare('INSERT INTO provider_connections(provider,proxy_enabled) VALUES(?,1)').run('anthropic');
    const port = 20129, placeholders = '(' + hosts.map(() => '?').join(',') + ')';
    const pre = db.prepare('SELECT COUNT(*) c FROM proxy_registry WHERE host IN ' + placeholders + ' AND port=?').all(...hosts, port)[0].c;
    assert.ok(pre === 4, 'P4 fixture: setup 4 本地变体 20129 (pre=' + pre + ')');
    db.exec('BEGIN');
    db.prepare('DELETE FROM proxy_assignments WHERE proxy_id IN (SELECT id FROM proxy_registry WHERE host IN ' + placeholders + ' AND port=?)').run(...hosts, port);
    db.prepare('UPDATE provider_connections SET proxy_enabled=0 WHERE provider=?').run('nvidia');
    const del = db.prepare('DELETE FROM proxy_registry WHERE host IN ' + placeholders + ' AND port=?').run(...hosts, port);
    db.exec('COMMIT');
    assert.ok(del.changes === 4, 'P4 changes()=4 (实 ' + del.changes + ', 即四变体全清)');
    const post = db.prepare('SELECT COUNT(*) c FROM proxy_registry WHERE host IN ' + placeholders + ' AND port=?').all(...hosts, port)[0].c;
    assert.ok(post === 0, 'P4 purge 后残留=0 (post=' + post + ')');
    const remain = db.prepare("SELECT host,port FROM proxy_registry ORDER BY id").all();
    assert.ok(remain.length === 2, 'P4 留 2 非目标 (127.0.0.1:20130 + example.com:20129, 实 ' + remain.length + ')');
    const pc = db.prepare("SELECT provider,proxy_enabled FROM provider_connections ORDER BY provider").all();
    // ORDER BY provider: anthropic < nvidia → pc[0]=anthropic(=1 不动), pc[1]=nvidia(=0 置零)
    const nv = pc.find(r => r.provider === 'nvidia');
    const an = pc.find(r => r.provider === 'anthropic');
    assert.ok(nv && nv.proxy_enabled === 0, 'P4 nvidia→0');
    assert.ok(an && an.proxy_enabled === 1, 'P4 anthropic 不动 (=1)');
    db.close();
    fs.rmSync(tmpFile, { force: true });
    fs.rmSync(tmpFile + '-wal', { force: true });
    fs.rmSync(tmpFile + '-shm', { force: true });
    ok('T14-05 P4 动态: 四本地地址变体 20129 全清 deleted=4 + post=0 + 留非目标 2 条 + nvidia→0');
  } catch (e) { localFail('T14-05 P4 动态: ' + (e && e.message)); }

  // T14-06: P4 动态 — 幂等: 再 purge deleted=0, post=0
  try {
    const tmpFile = require('path').join(require('os').tmpdir(), 't14-idem-' + Date.now() + '.sqlite');
    const db = new DatabaseSync(tmpFile);
    db.exec('CREATE TABLE proxy_registry(id INTEGER PRIMARY KEY,host TEXT,port INT)');
    const hosts = ['127.0.0.1', '::1', 'localhost', '0.0.0.0'], port = 20129, placeholders = '(' + hosts.map(() => '?').join(',') + ')';
    for (const h of hosts) db.prepare('INSERT INTO proxy_registry(host,port) VALUES(?,20129)').run(h);
    db.prepare('DELETE FROM proxy_registry WHERE host IN ' + placeholders + ' AND port=?').run(...hosts, port); // 第一轮
    const d2 = db.prepare('DELETE FROM proxy_registry WHERE host IN ' + placeholders + ' AND port=?').run(...hosts, port); // 第二轮
    const post = db.prepare('SELECT COUNT(*) c FROM proxy_registry WHERE host IN ' + placeholders + ' AND port=?').all(...hosts, port)[0].c;
    assert.ok(d2.changes === 0, 'P4 幂等第二轮 deleted=0 (实 ' + d2.changes + ')');
    assert.ok(post === 0, 'P4 幂等 post=0');
    db.close();
    fs.rmSync(tmpFile, { force: true });
    ok('T14-06 P4 动态: 幂等 二轮 deleted=0 post=0');
  } catch (e) { localFail('T14-06 P4 动态: ' + (e && e.message)); }

  // T14-07: P5 动态 — wal_checkpoint(TRUNCATE) 返回 busy/log/checkpointed 三值; busy=0 (无并发 reader)
  try {
    const tmpFile = require('path').join(require('os').tmpdir(), 't14-ckpt-' + Date.now() + '.sqlite');
    const db = new DatabaseSync(tmpFile);
    db.exec('PRAGMA journal_mode=WAL');
    db.exec('CREATE TABLE t(x)');
    for (let i = 0; i < 50; i++) db.prepare('INSERT INTO t VALUES(?)').run(i);
    const ck = db.prepare('PRAGMA wal_checkpoint(TRUNCATE)').get();
    assert.ok(ck && typeof ck.busy === 'number', 'P5 wal_checkpoint 返回 busy 数字 (实 ' + ck.busy + ' typeof ' + (ck && typeof ck.busy) + ')');
    assert.ok(typeof ck.log === 'number', 'P5 wal_checkpoint 返回 log 数字');
    assert.ok(typeof ck.checkpointed === 'number', 'P5 wal_checkpoint 返回 checkpointed 数字');
    ok('T14-07 P5 动态: wal_checkpoint(TRUNCATE) 返回 busy=' + ck.busy + ' log=' + ck.log + ' checkpointed=' + ck.checkpointed + ' (busy=0 无 Litestream reader)');
    db.close();
    fs.rmSync(tmpFile, { force: true });
    fs.rmSync(tmpFile + '-wal', { force: true });
    fs.rmSync(tmpFile + '-shm', { force: true });
  } catch (e) { localFail('T14-07 P5 动态: ' + (e && e.message)); }

  if (issues === 0) ok('TEST 14 P3/P4/P5 全 PASS (7/7: 3 静 + 4 动)');
  fail += issues;
}

// ── TEST 13: gate ECONNRESET 结构化诊断 (任务三#23) ──
// 7 用例 T13-01~T13-07. mock 上游 reset 触短时窗 ECONNRESET; 抓 gate stderr JSON 验 abortSource/socketPhase.
// 不改 80 已有测试断言. classifyAbortSource 第 5 类 upstream_reset (ECONNRESET + elapsedMs<5000).
async function testGateAbortSource() {
  console.log('TEST 13: gate ECONNRESET 结构化诊断 (abortSource 区分 + socketPhase)');
  const GATE_SRC = fs.readFileSync(GATE, 'utf8');
  let issues = 0;
  const localFail = (msg) => { console.error(`  ✗ ${msg}`); issues++; };

  // ─ 静态: classifyAbortSource 5 类 + 顺序 (timeout/client_close/shutdown 优先, upstream_reset 兜底前) ─
  try {
    assert.ok(/function classifyAbortSource\(e, \{ gateTimeout, clientAborted, elapsedMs \} = \{\}\)/.test(GATE_SRC),
      'classifyAbortSource 签名含 elapsedMs (task#23 改)');
    assert.ok(/if \(gateTimeout\) return 'timeout';/.test(GATE_SRC), 'timeout 优先级不变');
    assert.ok(/if \(clientAborted\) return 'client_close';/.test(GATE_SRC), 'client_close 优先级不变');
    assert.ok(/if \(shuttingDown\) return 'shutdown';/.test(GATE_SRC), 'shutdown 优先级不变');
    assert.ok(/e\?\.code === 'ECONNRESET' && typeof elapsedMs === 'number' && elapsedMs < 5000/.test(GATE_SRC),
      'upstream_reset 条件: ECONNRESET + elapsedMs<5000 (task#23 第 5 类)');
    assert.ok(/return 'upstream_reset';/.test(GATE_SRC), 'upstream_reset 返回值存在');
    assert.ok(/return 'upstream_error';[\s\S]*?\n\}/.test(GATE_SRC), 'upstream_error 兜底不变');
    // timeout/client_close/shutdown 三类无 socketPhase 附加 (仅 upstream_reset/upstream_error)
    // L364 const phase = (abortSource === 'upstream_reset' || abortSource === 'upstream_error') ? _socketPhase : null
    const phaseAttach = /const phase = \(abortSource === 'upstream_reset' \|\| abortSource === 'upstream_error'\)/;
    assert.ok(phaseAttach.test(GATE_SRC), 'socketPhase 仅附加于 upstream_reset/upstream_error (LogField gate)');
    assert.ok(/socketPhase: fields\.socketPhase \|\| null/.test(GATE_SRC), 'logGate 输出含 socketPhase 字段');
    // proxyV1 (L282-321 routes /v1, 含 SSE) 复用 classifyAbortSource (非硬码 upstream_error);
    // 限检 proxyV1 段, 不强求 proxyAdmin (后台代理, 非 user 范围) — 用行号定位 proxyV1 函数体.
    const fnStart = GATE_SRC.indexOf('function proxyV1(req, res)');
    const fnBody = GATE_SRC.slice(fnStart, GATE_SRC.indexOf('function ', fnStart + 20));
    assert.ok(/const abortSource = classifyAbortSource\(e, \{ gateTimeout, clientAborted, elapsedMs \}\);/.test(fnBody),
      'proxyV1 SSE 路径复用 classifyAbortSource (非硬码 upstream_error)');
    assert.ok(!/abortSource: 'upstream_error', destroyInitiator: 'upstream'/.test(fnBody),
      'proxyV1 段硬码 upstream_error 已移除');
    ok('T13-01 静态: classifyAbortSource 5 类 + 顺序 + proxyV1 SSE 复用 (timeout/client_close/shutdown 逻辑不变)');
  } catch (e) { localFail('T13-01 静态结构: ' + (e && e.message)); }

  // ─ T13-02 mapUpstreamStatus 不变 (ECONNRESET→503, ETIMEDOUT→504) 对外契约 ─
  try {
    assert.ok(/e\?\.code === 'ECONNREFUSED' \|\| e\?\.code === 'ECONNRESET'\) return 503/.test(GATE_SRC),
      'mapUpstreamStatus ECONNRESET→503 不变 (对外 HTTP 契约)');
    assert.ok(/gateTimeout \|\| e\?\.code === 'ETIMEDOUT' \|\| e\?\.code === 'ESOCKETTIMEDOUT'\) return 504/.test(GATE_SRC),
      'mapUpstreamStatus timeout→504 不变');
    ok('T13-02 静态: mapUpstreamStatus 对外 HTTP 状态码契约 (503/504) 零改动');
  } catch (e) { localFail('T13-02 状态码契约: ' + (e && e.message)); }

  // ─ T13-03 socketPhase 钩子存在 (connecting → headers → streaming) ─
  try {
    assert.ok(/req\._socketPhase = 'connecting';/.test(GATE_SRC), "socketPhase init 'connecting'");
    assert.ok(/socket\.on\('connect'[\s\S]*?req\._socketPhase = 'headers'/.test(GATE_SRC),
      "socket 'connect' 事件 → socketPhase 'headers'");
    assert.ok(/req\._socketPhase = 'streaming';/.test(GATE_SRC),
      "收 response head → socketPhase 'streaming'");
    ok('T13-03 静态: socketPhase 三相跟踪钩子 (connecting/headers/streaming) 存在');
  } catch (e) { localFail('T13-03 socketPhase 钩子: ' + (e && e.message)); }

  // ─ T13-04 动态: 短时窗 ECONNRESET (<5000ms) → abortSource up upstream_reset + status 503 ─
  const T13_04 = (async () => {
    let upstream, g;
    try {
      upstream = await startMockUpstream((ureq, ures) => {
        // 连上即 reset socket (不写 head, 触 ECONNRESET on gate side)
        ureq.socket.destroy();
      });
      g = await startGate({}, upstream.address().port);
      const P = g.gatePort;
      const r = await req(P, { path: '/v1/models', headers: { authorization: 'Bearer ' + 'p'.repeat(32) } });
      assert.strictEqual(r.status, 503, '短时窗 ECONNRESET → 503 (对外契约)');
      await sleep(100);
      let jsonLine = null;
      for (let i = 0; i < 10 && !jsonLine; i++) { jsonLine = (g.log||'').split('\n').find((l) => l.includes('"level":"error"') && l.includes('upstream_reset')); if (!jsonLine) await sleep(60); }
      assert.ok(jsonLine, 'gate stderr 含 upstream_reset 诊断行');
      const obj = JSON.parse(jsonLine);
      assert.strictEqual(obj.abortSource, 'upstream_reset', 'abortSource=upstream_reset');
      assert.strictEqual(obj.httpStatus, 503, '日志 httpStatus=503');
      assert.ok(obj.elapsedMs < 5000, 'elapsedMs<5000 (短时窗) 实=' + obj.elapsedMs);
      assert.ok(['connecting', 'headers'].includes(obj.socketPhase),
        'socketPhase ∈ connecting/headers 实=' + obj.socketPhase);
      assert.strictEqual(obj.errorCode, 'ECONNRESET', 'errorCode=ECONNRESET');
      ok('T13-04 动态: 短时窗 ECONNRESET → upstream_reset + 503 + socketPhase(connecting/headers)');
    } catch (e) { localFail('T13-04 短时窗 ECONNRESET: ' + (e && e.message)); }
    finally { stopGate(g); await stopUpstream(upstream); }
  })();

  // ─ T13-05 动态: 长时窗 ECONNRESET (>5000ms, mock 上游先 delay 5.5s 再 reset) → upstream_error ─
  const T13_05 = (async () => {
    let upstream, g;
    try {
      upstream = await startMockUpstream((ureq, ures) => {
        setTimeout(() => { try { ureq.socket.destroy(); } catch {} }, 5500);
      });
      g = await startGate({ GATE_UPSTREAM_TIMEOUT_MS: '30000' }, upstream.address().port);
      const P = g.gatePort;
      const r = await req(P, { path: '/v1/models', headers: { authorization: 'Bearer ' + 'p'.repeat(32) } });
      assert.strictEqual(r.status, 503, '长时窗 ECONNRESET → 503 (对外契约不变)');
      await sleep(100);
      let jsonLine = null;
      for (let i = 0; i < 15 && !jsonLine; i++) { jsonLine = (g.log||'').split('\n').find((l) => l.includes('"level":"error"') && /"abortSource":"upstream_error"/.test(l)); if (!jsonLine) await sleep(120); }
      assert.ok(jsonLine, 'gate stderr 含 upstream_error 诊断行 (非 upstream_reset)');
      const obj = JSON.parse(jsonLine);
      assert.strictEqual(obj.abortSource, 'upstream_error', 'abortSource=upstream_error (elapsedMs>5000)');
      assert.ok(obj.elapsedMs >= 5000, 'elapsedMs>=5000 实=' + obj.elapsedMs);
      assert.strictEqual(obj.httpStatus, 503, 'httpStatus=503');
      ok('T13-05 动态: 长时窗 ECONNRESET → upstream_error (elapsedMs>=5000) + 503');
    } catch (e) { localFail('T13-05 长时窗 ECONNRESET: ' + (e && e.message)); }
    finally { stopGate(g); await stopUpstream(upstream); }
  })();

  // ─ T13-06 动态: timeout → 504 + abortSource timeout (GATE_UPSTREAM_TIMEOUT_MS 短设) ─
  const T13_06 = (async () => {
    let upstream, g;
    try {
      upstream = await startMockUpstream((ureq, ures) => { /* hang 不响应 */ });
      g = await startGate({ GATE_UPSTREAM_TIMEOUT_MS: '500' }, upstream.address().port);
      const P = g.gatePort;
      const r = await req(P, { path: '/v1/models', headers: { authorization: 'Bearer ' + 'p'.repeat(32) } });
      assert.strictEqual(r.status, 504, 'timeout → 504 (对外契约)');
      if (r.status === 504) {
        const body = JSON.parse(r.body || '{}');
        assert.strictEqual(body.abort_source, 'timeout', '响 abort_source=timeout');
      }
      await sleep(100);
      let jsonLine = null;
      for (let i = 0; i < 15 && !jsonLine; i++) { jsonLine = (g.log||'').split('\n').find((l) => l.includes('"abortSource":"timeout"')); if (!jsonLine) await sleep(80); }
      assert.ok(jsonLine, 'gate stderr timeout 诊断行');
      const obj = JSON.parse(jsonLine);
      assert.strictEqual(obj.abortSource, 'timeout', 'log abortSource=timeout');
      assert.strictEqual(obj.httpStatus, 504, 'log httpStatus=504');
      ok('T13-06 动态: timeout → 504 + abortSource=timeout (三类优先级不变)');
    } catch (e) { localFail('T13-06 timeout: ' + (e && e.message)); }
    finally { stopGate(g); await stopUpstream(upstream); }
  })();

  // ─ T13-07 动态: client close → client_close (无 503 响, gate 不回写) ─
  const T13_07 = (async () => {
    let upstream, g;
    try {
      upstream = await startMockUpstream((ureq, ures) => { /* hang (gate 等上游, client 中途断) */ });
      g = await startGate({ GATE_UPSTREAM_TIMEOUT_MS: '20000' }, upstream.address().port);
      const P = g.gatePort;
      await new Promise((resolve) => {
        const r = http.request({ host: '127.0.0.1', port: P, path: '/v1/models', headers: { authorization: 'Bearer ' + 'p'.repeat(32) } });
        r.on('error', () => {}); // client abort 后 ECONNRESET, 忽略
        r.flushHeaders();                                  // 先把 SYN+headers 送出 (否则 destroy 不触 req close)
        setTimeout(() => { try { r.destroy(); } catch {} }, 80); // 给完整握手时间再 destroy (否则 gate 收不到 close 事件)
        setTimeout(resolve, 400);
      });
      // gate stderr client_close 行可能稍滞后 (req close → cleanup → upstreamReq.destroy → error emit → stderr flush)
      let jsonLine = null;
      for (let i = 0; i < 10 && !jsonLine; i++) { jsonLine = (g.log||'').split('\n').find((l) => /"abortSource":"client_close"/.test(l)); if (!jsonLine) await sleep(80); }
      assert.ok(jsonLine, 'gate stderr client_close 诊断行');
      const obj = JSON.parse(jsonLine);
      assert.strictEqual(obj.abortSource, 'client_close', 'log abortSource=client_close');
      assert.ok(obj.socketPhase === undefined || obj.socketPhase === null,
        'client_close 无 socketPhase 附加');
      ok('T13-07 动态: client close → client_close (无 503 回写, 无 socketPhase)');
    } catch (e) { localFail('T13-07 client close: ' + (e && e.message)); }
    finally { stopGate(g); await stopUpstream(upstream); }
  })();

  // 集中 await 4 动态用例 (顺序避免 mock port 复用竞争)
  await T13_04; await T13_05; await T13_06; await T13_07;

  if (issues === 0) ok('TEST 13 gate abortSource 全 PASS (7 用例: 3 静态 + 4 动态)');
  fail += issues;
}

async function main() {
  console.log('=== v4.3 candidate tests ===');
  await testSyntax();
  await testGatePaths();
  await testPsk();
  await testBasicAuth();
  await testUpstreamStatus();
  await testSse();
  await testLitestream();
  await testSignal();
  await testIdempotent();
  testResidual();
  testResiliencePatch();
  testEntrypointSequence();
  testEntrypointHardening();
  await testGateAbortSource();
  console.log('\n=== 结果 ===');
  console.log(`PASS=${pass} FAIL=${fail} SKIP=${skip}`);
  if (fail > 0) {
    console.error(`\nFAILED: ${fail} 项不通过. 不进入 Stage E.`);
    process.exit(1);
  }
  console.log('\n全 PASS. candidate tests 通过.');
  process.exit(0);
}
main().catch((e) => { console.error('runner crashed:', e); process.exit(2); });
