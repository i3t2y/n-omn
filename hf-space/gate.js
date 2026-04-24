const express = require('express');
const { createProxyMiddleware } = require('http-proxy-middleware');

const app = express();
const INTERNAL_PSK = process.env.INTERNAL_PSK;
const OR_PORT = parseInt(process.env.OMNIROUTE_PORT || '20128', 10);
const GATE_PORT = parseInt(process.env.EXPOSED_PORT || '7860', 10);

if (!INTERNAL_PSK) {
  console.error('[gate] FATAL: INTERNAL_PSK is required');
  process.exit(1);
}

const CF_HEADERS = [
  'cf-connecting-ip','cf-ipcountry','cf-ray','cf-worker',
  'cf-visitor','x-forwarded-for','x-forwarded-proto',
  'x-real-ip','true-client-ip'
];

app.get('/healthz', async (req, res) => {
  try {
    const ctrl = new AbortController();
    const t = setTimeout(() => ctrl.abort(), 3000);
    const r = await fetch(`http://127.0.0.1:${OR_PORT}/api/monitoring/health`, {
      signal: ctrl.signal,
    });
    clearTimeout(t);
    if (r.ok) return res.status(200).json({ ok: true, ts: Date.now() });
    return res.status(503).json({ ok: false, upstream: r.status });
  } catch (e) {
    return res.status(503).json({ ok: false, error: e.message });
  }
});

app.use('/', (req, res, next) => {
  if (req.path.startsWith('/v1')) {
    const auth = req.headers['authorization'] || '';
    const bearer = auth.startsWith('Bearer ') ? auth.slice(7) : '';
    if (bearer !== INTERNAL_PSK) {
      return res.status(401).json({ error: 'unauthorized' });
    }
    CF_HEADERS.forEach(h => { if (req.headers[h]) delete req.headers[h]; });
    delete req.headers['authorization'];
  }
  next();
}, createProxyMiddleware({
  target: `http://127.0.0.1:${OR_PORT}`,
  changeOrigin: true,
}));

app.listen(GATE_PORT, '0.0.0.0', () => {
  console.log(`[gate] listening on :${GATE_PORT}, proxying to :${OR_PORT}`);
});
