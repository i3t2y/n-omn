// ============================================================
// alert.js (inlined)
// ============================================================
async function fireAlert(env, { level, title, body }) {
  const tasks = [sendWeCom(env, level, title, body)];
  if (level === 'CRITICAL' && env.RESEND_API_KEY) {
    tasks.push(sendResend(env, level, title, body));
  }
  await Promise.allSettled(tasks);
}

async function sendWeCom(env, level, title, body) {
  if (!env.WECOM_WEBHOOK) return;
  const colorMap = { CRITICAL: 'red', WARN: 'orange', RECOVERY: 'green', INFO: 'comment' };
  const color = colorMap[level] || 'comment';
  const content = `**​[${level}] ${title}​**\n\n${body}\n\n> <font color="${color}">Time: ${new Date().toISOString()}</font>`;
  try {
    await fetch(env.WECOM_WEBHOOK, {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ msgtype: 'markdown', markdown: { content } }),
    });
  } catch (e) {
    console.error('[alert] wecom failed:', e.message);
  }
}

async function sendResend(env, level, title, body) {
  if (!env.RESEND_API_KEY) return;
  try {
    const r = await fetch('https://api.resend.com/emails', {
      method: 'POST',
      headers: {
        'authorization': `Bearer ${env.RESEND_API_KEY}`,
        'content-type': 'application/json',
      },
      body: JSON.stringify({
        from: env.ALERT_EMAIL_FROM,
        to: [env.ALERT_EMAIL_TO],
        subject: `[${level}] ${title}`,
        text: `${title}\n\n${body}\n\nTime: ${new Date().toISOString()}`,
      }),
    });
    if (!r.ok) console.error('[alert] resend HTTP', r.status, await r.text());
  } catch (e) {
    console.error('[alert] resend failed:', e.message);
  }
}

// ============================================================
// index.js (main)
// ============================================================
const UA_POOL = [
  'OmniClient/1.3 (linux; x86_64) node/20.18',
  'OmniClient/1.3 (darwin; arm64) node/22.11',
  'OmniClient/1.3 (linux; x86_64) deno/1.46',
];

const WINDOW_MS            = 5 * 60 * 1000;
const CRITICAL_5XX_RATIO   = 0.5;
const CRITICAL_MIN_SAMPLES = 20;
const RECOVERY_STREAK      = 3;

export default {
  async fetch(request, env, ctx) {
    const url = new URL(request.url);

    // 1. Auth gate
    const auth  = request.headers.get('authorization') || '';
    const token = auth.startsWith('Bearer ') ? auth.slice(7) : '';
    if (token !== env.CLIENT_TOKEN) {
      return new Response(JSON.stringify({ error: 'unauthorized' }), {
        status: 401,
        headers: { 'content-type': 'application/json' },
      });
    }

    // 2. Build upstream request
    const upstreamUrl = `${env.UPSTREAM_BASE}${url.pathname}${url.search}`;
    const ua = UA_POOL[Math.floor(Math.random() * UA_POOL.length)];
    const upstreamHeaders = new Headers(request.headers);

    for (const h of [
      'cf-connecting-ip','cf-ipcountry','cf-ray','cf-worker',
      'cf-visitor','x-forwarded-for','x-forwarded-proto',
      'x-real-ip','true-client-ip',
    ]) { upstreamHeaders.delete(h); }

    upstreamHeaders.set('authorization', `Bearer ${env.INTERNAL_PSK}`);
    upstreamHeaders.set('user-agent', ua);

    const upstreamReq = new Request(upstreamUrl, {
      method:  request.method,
      headers: upstreamHeaders,
      body:    ['GET','HEAD'].includes(request.method) ? undefined : request.body,
    });

    // 3. Forward
    let response, errorMsg = null;
    const t0 = Date.now();
    try {
      response = await fetch(upstreamReq);
    } catch (e) {
      errorMsg = e.message;
      response = new Response(
        JSON.stringify({ error: 'upstream_unreachable', detail: e.message }),
        { status: 502, headers: { 'content-type': 'application/json' } }
      );
    }
    const latencyMs = Date.now() - t0;

    // 4. Async observability
    ctx.waitUntil(observeAndAlert(env, {
      status: response.status, errorMsg, latencyMs, path: url.pathname,
    }));

    return response;
  },
};

async function observeAndAlert(env, { status, errorMsg, latencyMs, path }) {
  const now       = Date.now();
  const bucketKey = `win:${Math.floor(now / WINDOW_MS)}`;
  const raw = (await env.STATE.get(bucketKey, 'json')) || {
    total: 0, fail5xx: 0, fail429: 0, lastUpdate: now,
  };
  raw.total += 1;
  if (status >= 500) raw.fail5xx += 1;
  if (status === 429) raw.fail429 += 1;
  raw.lastUpdate = now;
  await env.STATE.put(bucketKey, JSON.stringify(raw), { expirationTtl: 3600 });

  const lastLevel = await env.STATE.get('state:last-level');

  if (status < 500 && !errorMsg) {
    if (lastLevel === 'CRITICAL') {
      const streak = parseInt((await env.STATE.get('recovery:streak')) || '0', 10) + 1;
      if (streak >= RECOVERY_STREAK) {
        await env.STATE.put('state:last-level', 'OK');
        await env.STATE.delete('recovery:streak');
        await fireAlert(env, {
          level: 'RECOVERY',
          title: 'OmniRoute 主路已恢复',
          body: `连续 ${streak} 次成功请求，服务已恢复正常。延迟 ${latencyMs}ms。`,
        });
      } else {
        await env.STATE.put('recovery:streak', String(streak), { expirationTtl: 600 });
      }
    } else {
      await env.STATE.delete('recovery:streak');
    }
    return;
  }

  if (status === 429) {
    const wKey = `warn:429:${dayStamp()}:${path}`;
    const n = parseInt((await env.STATE.get(wKey)) || '0', 10) + 1;
    await env.STATE.put(wKey, String(n), { expirationTtl: 86400 });
    if (n === 3) {
      await fireAlertOnce(env, `warn-429-${dayStamp()}-${path}`, {
        level: 'WARN',
        title: '单路径 24h 内多次 429',
        body: `路径 ${path} 今日已触发 ${n} 次 429，可能存在密集调用或 CB 级联。`,
      }, 30 * 60);
    }
    return;
  }

  if (raw.total >= CRITICAL_MIN_SAMPLES && raw.fail5xx / raw.total > CRITICAL_5XX_RATIO) {
    await fireAlertOnce(env, `crit-5xx-${Math.floor(now / WINDOW_MS)}`, {
      level: 'CRITICAL',
      title: 'OmniRoute 主路 5xx 率告警',
      body: `5 分钟内 ${raw.fail5xx}/${raw.total} 次 5xx（${Math.round(raw.fail5xx/raw.total*100)}%）。建议立即检查 HF Space。`,
    }, 0);
    await env.STATE.put('state:last-level', 'CRITICAL');
  }
}

async function fireAlertOnce(env, dedupeKey, payload, cooldownSec) {
  const mark = `alerted:${dedupeKey}`;
  if (await env.STATE.get(mark)) return;
  await fireAlert(env, payload);
  await env.STATE.put(mark, '1', { expirationTtl: cooldownSec > 0 ? cooldownSec : 300 });
}

function dayStamp() {
  const d = new Date();
  return `${d.getUTCFullYear()}-${String(d.getUTCMonth()+1).padStart(2,'0')}-${String(d.getUTCDate()).padStart(2,'0')}`;
}
