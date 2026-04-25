const express = require('express');
const { createProxyMiddleware } = require('http-proxy-middleware');
const fs = require('fs');

const app = express();

const INTERNAL_PSK = process.env.INTERNAL_PSK;
const OR_PORT = parseInt(process.env.OMNIROUTE_PORT || '20128', 10);
const GATE_PORT = parseInt(process.env.EXPOSED_PORT || '7860', 10);
const OR_API_KEY_FILE = '/data/.or-api-key';

if (!INTERNAL_PSK) {
  console.error('[gate] FATAL: INTERNAL_PSK is required');
  process.exit(1);
}

let OR_API_KEY = '';

try {
  OR_API_KEY = fs.readFileSync(OR_API_KEY_FILE, 'utf8').trim();

  if (!OR_API_KEY) {
    throw new Error('empty OR_API_KEY file');
  }

  console.log('[gate] OR_API_KEY loaded from file.');
} catch (e) {
  console.error('[gate] FATAL: Cannot read OR_API_KEY from ' + OR_API_KEY_FILE + ': ' + e.message);
  process.exit(1);
}

const CF_HEADERS = [
  'cf-connecting-ip',
  'cf-ipcountry',
  'cf-ray',
  'cf-worker',
  'cf-visitor',
  'x-forwarded-for',
  'x-forwarded-proto',
  'x-real-ip',
  'true-client-ip'
];

const KNOWN_COMBOS = new Set([
  'nim-pool'
]);

function readRawBody(req) {
  return new Promise(function(resolve) {
    const chunks = [];

    req.on('data', function(chunk) {
      chunks.push(chunk);
    });

    req.on('end', function() {
      resolve(Buffer.concat(chunks));
    });

    req.on('error', function() {
      resolve(Buffer.alloc(0));
    });
  });
}

app.get('/healthz', async function(req, res) {
  try {
    const ctrl = new AbortController();
    const timer = setTimeout(function() {
      ctrl.abort();
    }, 3000);

    const upstreamUrl = 'http://127.0.0.1:' + OR_PORT + '/api/monitoring/health';

    const r = await fetch(upstreamUrl, {
      signal: ctrl.signal
    });

    clearTimeout(timer);

    if (r.ok) {
      return res.status(200).json({
        ok: true,
        ts: Date.now()
      });
    }

    return res.status(503).json({
      ok: false,
      upstream: r.status
    });
  } catch (e) {
    return res.status(503).json({
      ok: false,
      error: e.message
    });
  }
});

app.use(async function(req, res, next) {
  if (!req.path.startsWith('/v1')) {
    return next();
  }

  const auth = req.headers.authorization || '';
  const prefix = 'Bearer ';
  const bearer = auth.startsWith(prefix) ? auth.slice(prefix.length) : '';

  if (bearer !== INTERNAL_PSK) {
    return res.status(401).json({
      error: 'unauthorized'
    });
  }

  CF_HEADERS.forEach(function(headerName) {
    if (req.headers[headerName]) {
      delete req.headers[headerName];
    }
  });

  req.headers.authorization = 'Bearer ' + OR_API_KEY;

  const rawBuf = await readRawBody(req);
  let bodyBuf = rawBuf;

  if (req.path === '/v1/chat/completions' && rawBuf.length > 0) {
    try {
      const bodyObj = JSON.parse(rawBuf.toString('utf8'));
      const model = bodyObj.model || '';
      const isCombo = KNOWN_COMBOS.has(model) || model.indexOf('/') === -1;

      if (isCombo && bodyObj.stream !== false) {
        bodyObj.stream = false;
        console.log('[gate] Combo "' + model + '" forced stream=false');
        bodyBuf = Buffer.from(JSON.stringify(bodyObj));
      }
    } catch (e) {
      console.warn('[gate] WARN: failed to parse JSON body, forwarding raw body: ' + e.message);
    }
  }

  req._rawBody = bodyBuf;
  req.headers['content-length'] = String(bodyBuf.length);

  next();
});

app.use('/', createProxyMiddleware({
  target: 'http://127.0.0.1:' + OR_PORT,
  changeOrigin: true,
  selfHandleResponse: false,
  on: {
    proxyReq: function(proxyReq, req) {
      if (req._rawBody !== undefined) {
        proxyReq.setHeader('content-length', req._rawBody.length);
        proxyReq.write(req._rawBody);
        proxyReq.end();
      }
    },
    error: function(err, req, res) {
      console.error('[gate] proxy error: ' + err.message);

      if (!res.headersSent) {
        res.writeHead(502, {
          'Content-Type': 'application/json'
        });
      }

      res.end(JSON.stringify({
        error: 'bad_gateway'
      }));
    }
  }
}));

app.listen(GATE_PORT, '0.0.0.0', function() {
  console.log('[gate] listening on 0.0.0.0:' + GATE_PORT + ', proxying to 127.0.0.1:' + OR_PORT);
});
