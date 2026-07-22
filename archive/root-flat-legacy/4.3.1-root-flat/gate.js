'use strict';
const http = require('http');
const crypto = require('crypto');
const fs = require('fs');

const INTERNAL_PSK = process.env.INTERNAL_PSK || '';
const OR_PORT = parseInt(process.env.OMNIROUTE_PORT || '20128', 10);
const GATE_PORT = parseInt(process.env.EXPOSED_PORT || '7860', 10);

if (!INTERNAL_PSK || INTERNAL_PSK.length < 16) {
  console.error('[gate] FATAL: INTERNAL_PSK missing or too short.');
  process.exit(1);
}

// 自动获取 OmniRoute 管理 Key
let OR_API_KEY = (process.env.OMNIROUTE_API_KEY || '').trim();
if (!OR_API_KEY) {
  try { OR_API_KEY = fs.readFileSync('/data/.or-api-key', 'utf8').trim(); }
  catch (e) { }
}

function safeEqual(a, b) {
  if (!a || !b) return false;
  const ba = Buffer.from(a), bb = Buffer.from(b);
  return ba.length === bb.length && crypto.timingSafeEqual(ba, bb);
}

const server = http.createServer((req, res) => {
  const url = req.url.split('?')[0];

  // 健康检查转发
  if (req.method === 'GET' && url === '/healthz') {
    const hc = http.request({ host: '127.0.0.1', port: OR_PORT, path: '/api/monitoring/health', timeout: 2000 }, (up) => {
      res.writeHead(up.statusCode === 200 ? 200 : 503, { 'Content-Type': 'application/json' });
      res.end('{"ok":true}');
      up.resume();
    });
    hc.on('error', () => { res.writeHead(503).end('{"ok":false}'); });
    hc.end(); return;
  }

  // OpenAI API 转发
  if (url.startsWith('/v1')) {
    const bearer = (req.headers['authorization'] || '').replace('Bearer ', '');
    if (!safeEqual(bearer, INTERNAL_PSK)) {
      res.writeHead(401).end('{"error":"unauthorized"}'); return;
    }
    
    const headers = { ...req.headers, host: `127.0.0.1:${OR_PORT}`, authorization: `Bearer ${OR_API_KEY}` };
    const proxyReq = http.request({ host: '127.0.0.1', port: OR_PORT, path: req.url, method: req.method, headers }, (up) => {
      res.writeHead(up.statusCode || 502, up.headers);
      up.pipe(res);
    });
    proxyReq.on('error', (err) => {
      if (!res.headersSent) res.writeHead(502).end('{"error":"bad_gateway"}');
    });
    req.pipe(proxyReq); return;
  }

  res.writeHead(404).end();
});

server.timeout = 0; // 支持长连接 SSE
server.listen(GATE_PORT, '0.0.0.0', () => console.log(`[gate] listening on ${GATE_PORT}`));
