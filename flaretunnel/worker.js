// ===== FlareTunnel 改造版 Worker：全量透传 + 鉴权 + 域名收敛 + SSE 友好 =====
// 部署: GitHub Actions → .github/workflows/deploy-ft-workers.yml → wrangler-action 一键 deploy.
//   (旧手搓法: CF Dashboard → 编辑代码 → 全选删除 → 粘贴本文件 → 部署; 已退役自动化取代)
// AUTH_KEY = env.RELAY_AUTH (wrangler secret put 注入, §2 零入 git/会话);
//   须与 HF Space Secret RELAY_AUTH 同值 (Worker 鉴权 ↔ 桥 RELAY_AUTH 铁律).
//   旧钥 OmniRouteFlareTunnelSecret2026 已在对话明文多次出现, 作废必换.
//   fail-closed: env.RELAY_AUTH 缺 (undefined/null/空串) 必在 fetch 入口硬拒, 不裸奔开放代理.
const ALLOWED_HOSTS = new Set([
  "integrate.api.nvidia.com",   // NVIDIA NIM (主)
  "token.sensenova.cn",         // SenseNova Token Plan (sensenova 内置走 FT 出口, 2026-08-28 圣上令方案B)
  "api.sensenova.cn",           // SenseNova 传统 API (3.8.4x registry 可能沿用, 一并放行防 host 拒)
]); // 只放行白名单 host, 防被当开放代理

const DROP_REQ = new Set([
  "host", "connection", "content-length", "transfer-encoding",
  "x-relay-auth", "x-target-url",
  "proxy-authorization", "proxy-connection",
  "cf-connecting-ip", "cf-ray", "cf-visitor", "cf-ipcountry", "cdn-loop",
  "x-forwarded-for", "x-real-ip",
  "accept-encoding" // 强制上游回 identity, 全链路字节透明, SSE 不被压缩层干扰
]);

export default {
  async fetch(request, env) {
    // 1. 鉴权 (FlareTunnel 本地桥 Patch C 注入 x-relay-auth 头; 缺/不符 → 401 unauthorized).
    //    fail-closed: env.RELAY_AUTH 缺 (undefined/null/空串) → 鉴权钥为空, 任何真值头都不匹配 → 硬拒.
    //    防 undefined !== 真 string 误 pass 裸奔开放代理洞.
    const AUTH_KEY = env.RELAY_AUTH || null;
    if (!AUTH_KEY || request.headers.get("x-relay-auth") !== AUTH_KEY) {
      return new Response(JSON.stringify({ error: "unauthorized" }),
        { status: 401, headers: { "content-type": "application/json" } });
    }

    // 2. 取目标 (FlareTunnel 桥用 ?url= 传完整目标 URL)
    const url = new URL(request.url);
    const target = url.searchParams.get("url");
    if (!target) return new Response(JSON.stringify({ error: "missing ?url=" }), { status: 400 });

    let targetURL;
    try { targetURL = new URL(target); }
    catch { return new Response(JSON.stringify({ error: "invalid url" }), { status: 400 }); }

    if (!ALLOWED_HOSTS.has(targetURL.hostname)) {
      return new Response(JSON.stringify({ error: "host not allowed" }), { status: 403 });
    }

    // 3. 全量请求头透传 (剔除控制头/逐跳头/压缩声明)
    const headers = new Headers();
    for (const [k, v] of request.headers) {
      if (!DROP_REQ.has(k.toLowerCase())) headers.set(k, v);
    }
    const rip = Array.from({ length: 4 }, () => 1 + Math.floor(Math.random() * 254)).join(".");
    headers.set("X-Forwarded-For", rip);

    // 4. 流式转发, SSE body 不缓冲
    const upstream = await fetch(targetURL.toString(), {
      method: request.method,
      headers,
      body: ["GET", "HEAD"].includes(request.method) ? undefined : request.body,
      redirect: "manual"
    });

    // 5. 响应透传; 删 content-length/content-encoding (字节流可能与头不一致)
    const respHeaders = new Headers(upstream.headers);
    respHeaders.delete("content-length");
    respHeaders.delete("content-encoding");
    return new Response(upstream.body, {
      status: upstream.status,
      statusText: upstream.statusText,
      headers: respHeaders
    });
  }
};
