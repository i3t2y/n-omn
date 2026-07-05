const express = require('express');
const { createProxyMiddleware } = require('http-proxy-middleware');
const fs = require('fs');

const app = express();
const INTERNAL_PSK = process.env.INTERNAL_PSK;
const OR_PORT = parseInt(process.env.OMNIROUTE_PORT || '20128', 10);
const GATE_PORT = parseInt(process.env.EXPOSED_PORT || '7860', 10);

// ── 鉴权凭证校验：缺失则启动即失败，避免静默 401 锁死网关 ──
// INTERNAL_PSK：HF Space Secret，客户端 /v1 请求需带 `Authorization: Bearer <PSK>`
if (!INTERNAL_PSK) {
  console.error('[gate] FATAL: INTERNAL_PSK not set. /v1 鉴权需此 PSK，HF Space Secret 必须配置 INTERNAL_PSK。');
  process.exit(1);
}
if (!fs.existsSync('/data/.or-api-key')) {
  console.error('[gate] FATAL: /data/.or-api-key 不存在。entrypoint 应先等 init 写入该文件再 exec gate。');
  process.exit(1);
}
const OR_API_KEY = fs.readFileSync('/data/.or-api-key', 'utf8').trim();

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
app.listen(GATE_PORT, '0.0.0.0');
