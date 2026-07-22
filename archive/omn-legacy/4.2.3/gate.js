const express = require('express');
const { createProxyMiddleware } = require('http-proxy-middleware');
const fs = require('fs');

const app = express();
const INTERNAL_PSK = process.env.INTERNAL_PSK;
const OR_PORT = parseInt(process.env.OMNIROUTE_PORT || '20128', 10);
const GATE_PORT = parseInt(process.env.EXPOSED_PORT || '7860', 10);

if (!INTERNAL_PSK) {
  console.error('[gate] FATAL: INTERNAL_PSK not set. HF Space Secret 必须配置。');
  process.exit(1);
}
let OR_API_KEY = (process.env.OMNIROUTE_API_KEY || '').trim();
if (!OR_API_KEY) {
  try { OR_API_KEY = fs.readFileSync('/data/.or-api-key', 'utf8').trim(); }
  catch (e) { if (e.code !== 'ENOENT') console.error('[gate] WARN read key failed:', e.message); }
}
if (!OR_API_KEY) {
  console.error('[gate] FATAL: No OR_API_KEY (env nor file).');
  process.exit(1);
}

app.get('/healthz', async (req, res) => {
  const r = await fetch(`http://127.0.0.1:${OR_PORT}/api/monitoring/health`).catch(() => null);
  r?.ok ? res.json({ ok: true }) : res.status(503).json({ ok: false });
});

app.use((req, res, next) => {
  if (!req.path.startsWith('/v1')) return next();
  const bearer = (req.headers.authorization || '').replace('Bearer ', '');
  if (bearer !== INTERNAL_PSK) return res.status(401).json({ error: 'unauthorized' });
  req.headers.authorization = `Bearer ${OR_API_KEY}`;
  next();
});

app.use('/', createProxyMiddleware({ target: `http://127.0.0.1:${OR_PORT}`, changeOrigin: true }));
app.listen(GATE_PORT, '0.0.0.0', () => {
  console.log(`[gate] listening on 0.0.0.0:${GATE_PORT} -> 127.0.0.1:${OR_PORT}`);
});