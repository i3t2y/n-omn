const VERSION = 'nim-worker-v1.3.0-final';

const CORS_HEADERS = {
  'access-control-allow-origin': '*',
  'access-control-allow-methods': 'GET,POST,OPTIONS',
  'access-control-allow-headers': 'authorization,content-type,x-request-id',
  'access-control-max-age': '86400'
};

const WARN_429_THRESHOLD = 5;
const CRITICAL_MIN_SAMPLES = 20;
const CRITICAL_5XX_RATIO = 0.5;
const WINDOW_TTL_SECONDS = 180;
const ALERT_TTL_SECONDS = 86400;

export default {
  async fetch(request, env, ctx) {
    if (request.method === 'OPTIONS') {
      return new Response(null, {
        status: 204,
        headers: CORS_HEADERS
      });
    }

    const url = new URL(request.url);
    const path = url.pathname;

    if (path === '/' || path === '/healthz' || path === '/__health') {
      return handleHealth(request, env, ctx);
    }

    if (!path.startsWith('/v1')) {
      return jsonResponse({
        error: 'not_found',
        version: VERSION
      }, 404);
    }

    const authResult = checkClientAuth(request, env);
    if (!authResult.ok) {
      return jsonResponse({
        error: 'unauthorized'
      }, 401);
    }

    let response = new Response(JSON.stringify({
      error: 'bad_gateway'
    }), {
      status: 502,
      headers: {
        'content-type': 'application/json'
      }
    });

    const startedAt = Date.now();

    try {
      const upstreamBase = normalizeBase(env.UPSTREAM_BASE);
      if (!upstreamBase) {
        return jsonResponse({
          error: 'missing_upstream_base'
        }, 500);
      }

      if (!env.INTERNAL_PSK) {
        return jsonResponse({
          error: 'missing_internal_psk'
        }, 500);
      }

      const target = upstreamBase + path + url.search;
      const headers = new Headers(request.headers);

      headers.set('authorization', 'Bearer ' + env.INTERNAL_PSK);
      headers.set('x-worker-version', VERSION);

      headers.delete('cf-connecting-ip');
      headers.delete('cf-ipcountry');
      headers.delete('cf-ray');
      headers.delete('cf-worker');
      headers.delete('cf-visitor');
      headers.delete('x-forwarded-for');
      headers.delete('x-forwarded-proto');
      headers.delete('x-real-ip');
      headers.delete('true-client-ip');

      const init = {
        method: request.method,
        headers,
        redirect: 'manual'
      };

      if (request.method !== 'GET' && request.method !== 'HEAD') {
        init.body = request.body;
      }

      response = await fetch(target, init);

      const latencyMs = Date.now() - startedAt;

      ctx.waitUntil(recordAndMaybeAlert(env, {
        path,
        status: response.status,
        latencyMs
      }));

      return withCors(response);
    } catch (err) {
      const latencyMs = Date.now() - startedAt;

      ctx.waitUntil(recordAndMaybeAlert(env, {
        path,
        status: 502,
        latencyMs,
        error: safeMessage(err)
      }));

      return jsonResponse({
        error: 'bad_gateway'
      }, 502);
    }
  }
};

async function handleHealth(request, env, ctx) {
  const upstreamBase = normalizeBase(env.UPSTREAM_BASE);

  if (!upstreamBase) {
    return jsonResponse({
      ok: false,
      error: 'missing_upstream_base',
      version: VERSION
    }, 500);
  }

  try {
    const r = await fetch(upstreamBase + '/healthz', {
      method: 'GET',
      headers: {
        'x-worker-version': VERSION
      }
    });

    return jsonResponse({
      ok: r.ok,
      upstream_status: r.status,
      version: VERSION,
      ts: Date.now()
    }, r.ok ? 200 : 503);
  } catch (err) {
    return jsonResponse({
      ok: false,
      error: safeMessage(err),
      version: VERSION,
      ts: Date.now()
    }, 503);
  }
}

function checkClientAuth(request, env) {
  if (!env.CLIENT_TOKEN) {
    return {
      ok: false,
      reason: 'missing_client_token'
    };
  }

  const auth = request.headers.get('authorization') || '';
  const prefix = 'Bearer ';

  if (!auth.startsWith(prefix)) {
    return {
      ok: false,
      reason: 'missing_bearer'
    };
  }

  const token = auth.slice(prefix.length);

  return {
    ok: token === env.CLIENT_TOKEN
  };
}

function normalizeBase(value) {
  if (!value) return '';

  let base = String(value).trim();

  while (base.endsWith('/')) {
    base = base.slice(0, -1);
  }

  return base;
}

function withCors(response) {
  const headers = new Headers(response.headers);

  for (const key of Object.keys(CORS_HEADERS)) {
    headers.set(key, CORS_HEADERS[key]);
  }

  return new Response(response.body, {
    status: response.status,
    statusText: response.statusText,
    headers
  });
}

function jsonResponse(obj, status) {
  const headers = new Headers({
    'content-type': 'application/json'
  });

  for (const key of Object.keys(CORS_HEADERS)) {
    headers.set(key, CORS_HEADERS[key]);
  }

  return new Response(JSON.stringify(obj), {
    status,
    headers
  });
}

async function recordAndMaybeAlert(env, event) {
  if (!env.STATE) {
    return;
  }

  const now = new Date();
  const minuteKey = now.toISOString().slice(0, 16);
  const dayKey = now.toISOString().slice(0, 10);
  const safePath = sanitizeKeyPart(event.path || 'unknown');

  const statKey = 'stat:' + dayKey + ':' + minuteKey + ':' + safePath;

  const raw = await readStat(env, statKey);

  raw.total += 1;
  raw.fail429 += event.status === 429 ? 1 : 0;
  raw.fail5xx += event.status >= 500 ? 1 : 0;
  raw.lastStatus = event.status;
  raw.lastLatencyMs = event.latencyMs || 0;
  raw.updatedAt = Date.now();

  await env.STATE.put(statKey, JSON.stringify(raw), {
    expirationTtl: WINDOW_TTL_SECONDS
  });

  if (raw.fail429 >= WARN_429_THRESHOLD) {
    const dedupeKey = 'alerted:warn-429:' + dayKey + ':' + safePath;

    await fireAlertOnce(env, dedupeKey, {
      level: 'WARN',
      title: 'NIM Worker 429 warning',
      path: event.path,
      total: raw.total,
      fail429: raw.fail429,
      fail5xx: raw.fail5xx,
      status: event.status,
      latencyMs: event.latencyMs
    });
  }

  const effectiveTotal = raw.total - raw.fail429;

  if (effectiveTotal >= CRITICAL_MIN_SAMPLES) {
    const ratio = raw.fail5xx / effectiveTotal;

    if (ratio > CRITICAL_5XX_RATIO) {
      const dedupeKey = 'alerted:critical-5xx:' + dayKey + ':' + safePath;

      await env.STATE.put('state:last-level', 'CRITICAL');

      await fireAlertOnce(env, dedupeKey, {
        level: 'CRITICAL',
        title: 'NIM Worker 5xx critical',
        path: event.path,
        total: raw.total,
        effectiveTotal,
        fail429: raw.fail429,
        fail5xx: raw.fail5xx,
        ratio,
        status: event.status,
        latencyMs: event.latencyMs,
        error: event.error || ''
      });
    }
  }
}

async function readStat(env, key) {
  const empty = {
    total: 0,
    fail429: 0,
    fail5xx: 0,
    lastStatus: 0,
    lastLatencyMs: 0,
    updatedAt: 0
  };

  try {
    const text = await env.STATE.get(key);

    if (!text) {
      return empty;
    }

    const obj = JSON.parse(text);

    return {
      total: Number(obj.total || 0),
      fail429: Number(obj.fail429 || 0),
      fail5xx: Number(obj.fail5xx || 0),
      lastStatus: Number(obj.lastStatus || 0),
      lastLatencyMs: Number(obj.lastLatencyMs || 0),
      updatedAt: Number(obj.updatedAt || 0)
    };
  } catch (err) {
    return empty;
  }
}

async function fireAlertOnce(env, dedupeKey, payload) {
  if (!env.STATE) {
    return;
  }

  const existed = await env.STATE.get(dedupeKey);

  if (existed) {
    return;
  }

  await env.STATE.put(dedupeKey, '1', {
    expirationTtl: ALERT_TTL_SECONDS
  });

  await Promise.all([
    sendWecomAlert(env, payload),
    sendEmailAlert(env, payload)
  ]);
}

async function sendWecomAlert(env, payload) {
  if (!env.WECOM_WEBHOOK) {
    return;
  }

  const content = buildAlertText(payload);

  try {
    await fetch(env.WECOM_WEBHOOK, {
      method: 'POST',
      headers: {
        'content-type': 'application/json'
      },
      body: JSON.stringify({
        msgtype: 'markdown',
        markdown: {
          content
        }
      })
    });
  } catch (err) {
  }
}

async function sendEmailAlert(env, payload) {
  if (!env.RESEND_API_KEY || !env.ALERT_EMAIL_FROM || !env.ALERT_EMAIL_TO) {
    return;
  }

  const content = buildAlertText(payload);

  try {
    await fetch('https://' + 'api.resend.com' + '/emails', {
      method: 'POST',
      headers: {
        'authorization': 'Bearer ' + env.RESEND_API_KEY,
        'content-type': 'application/json'
      },
      body: JSON.stringify({
        from: env.ALERT_EMAIL_FROM,
        to: env.ALERT_EMAIL_TO,
        subject: payload.title || 'NIM Worker alert',
        text: content
      })
    });
  } catch (err) {
  }
}

function buildAlertText(payload) {
  const lines = [];

  lines.push('Level: ' + safeText(payload.level));
  lines.push('Title: ' + safeText(payload.title));
  lines.push('Path: ' + safeText(payload.path));
  lines.push('Status: ' + safeText(payload.status));
  lines.push('Total: ' + safeText(payload.total));
  lines.push('EffectiveTotal: ' + safeText(payload.effectiveTotal));
  lines.push('429: ' + safeText(payload.fail429));
  lines.push('5xx: ' + safeText(payload.fail5xx));
  lines.push('Ratio: ' + safeText(payload.ratio));
  lines.push('LatencyMs: ' + safeText(payload.latencyMs));

  if (payload.error) {
    lines.push('Error: ' + safeText(payload.error));
  }

  lines.push('Version: ' + VERSION);
  lines.push('Time: ' + new Date().toISOString());

  return lines.join('\n');
}

function sanitizeKeyPart(value) {
  return String(value || 'unknown')
    .replaceAll('/', '_')
    .replaceAll(':', '_')
    .replaceAll('?', '_')
    .replaceAll('&', '_')
    .replaceAll('=', '_')
    .slice(0, 120);
}

function safeText(value) {
  if (value === undefined || value === null) {
    return '';
  }

  return String(value);
}

function safeMessage(err) {
  if (!err) {
    return '';
  }

  if (err.message) {
    return String(err.message).slice(0, 300);
  }

  return String(err).slice(0, 300);
}
