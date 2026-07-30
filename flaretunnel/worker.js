// ===== FlareTunnel 改造版 Worker：全量透传 + 鉴权 + 域名收敛 + SSE 友好 =====
// 部署: CF Dashboard → blue-bird-5cf0 → 编辑代码 → 全选删除 → 粘贴本文件 → 部署
// AUTH_KEY 须换成新钥 (圣上 `openssl rand -hex 24` 生成); 与 Space Secret RELAY_AUTH 同值
//   旧钥 OmniRouteFlareTunnelSecret2026 已在对话明文多次出现, 作废必换
const AUTH_KEY = "PASTE_NEW_RELAY_AUTH_HERE"; // ← 换圣上新钥 (openssl rand -hex 24)
const ALLOWED_HOSTS = new Set(["integrate.api.nvidia.com"]); // 只放行 NIM, 防被当开放代理

const DROP_REQ = new Set([
  "host", "connection", "content-length", "transfer-encoding",
  "x-relay-auth", "x-target-url",
  "proxy-authorization", "proxy-connection",
  "cf-connecting-ip", "cf-ray", "cf-visitor", "cf-ipcountry", "cdn-loop",
  "x-forwarded-for", "x-real-ip",
  "accept-encoding" // 强制上游回 identity, 全链路字节透明, SSE 不被压缩层干扰
]);

export default {
  async fetch(request) {
    // 1. 鉴权 (FlareTunnel 本地桥 Patch C 注入此头; 缺/不符 → 401 unauthorized, 堵裸奔开放代理洞)
    if (request.headers.get("x-relay-auth") !== AUTH_KEY) {
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
