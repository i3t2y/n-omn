// ===== ho-proxy (Page 版): sonoke → xnexus gate 入站反代 · Cloudflare Pages =====
// 拓扑: sonoke → proxy.360710.xyz (CF Pages 边缘, 前置 PSK 校验) → xnexus-o.hf.space
//   (CF 边缘公网出站, 不经 HF 容器出站 *.hf.space 基础设施层拦截, 解 space-to-space 429)
// 鉴权: 边缘前置校验 Authorization Bearer == INTERNAL_PSK (与 gate.js 同源常量值)
//       缺/错 → 401 fail-closed; INTERNAL_PSK 未注入 → 503; 对 → 原样透传 Bearer 给 gate
//       前置只验不改, 不新增第二把 key: 一把 PSK 走全链路, sonoke 零改动
// 安全: 目标 host 写死固定, 无 ?url= 开放代理洞; 应用鉴权在 gate, 此处仅边缘前置拦截
const TARGET = "https://xnexus-o.hf.space";

// 剔除控制头/逐跳头/压缩声明 (host 由 gate.js 丢弃重写, 不参与路由鉴权)
const DROP_REQ = new Set([
  "host", "connection", "content-length", "transfer-encoding",
  "cf-connecting-ip", "cf-ray", "cf-visitor", "cf-ipcountry", "cdn-loop",
  "x-forwarded-for", "x-real-ip",
  "accept-encoding" // 强制上游回 identity, 全链路字节透明, SSE 不被压缩层干扰
]);

// 常量时间比较 (与 gate.js safeEqual 对齐), 防时序侧信道 — 缺/错一律不等
function safeEqual(a, b) {
  a = String(a); b = String(b);
  if (a.length !== b.length) return false;
  let diff = 0;
  for (let i = 0; i < a.length; i++) diff |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return diff === 0;
}

export async function onRequest(context) {
  const { request, env } = context;

  // 前置鉴权 (fail-closed): 边缘拦截无效/未配请求, 不到 gate 外网链路
  const expected = env.INTERNAL_PSK || "";
  if (!expected) {
    return new Response(JSON.stringify({ error: "proxy not configured" }),
      { status: 503, headers: { "content-type": "application/json" } });
  }
  const auth = request.headers.get("authorization") || "";
  if (!safeEqual(auth, "Bearer " + expected)) {
    return new Response(JSON.stringify({ error: "unauthorized" }),
      { status: 401, headers: { "content-type": "application/json" } });
  }

  const url = new URL(request.url);
  const targetURL = new URL(TARGET);
  targetURL.pathname = url.pathname; // /v1/* 原样拼接
  targetURL.search = url.search;     // query 原样

  // 透传请求头 (剔除 DROP_REQ); authorization 未在剔除列, 原样转发给 gate
  const headers = new Headers();
  for (const [k, v] of request.headers) {
    if (!DROP_REQ.has(k.toLowerCase())) headers.set(k, v);
  }

  // 流式转发, SSE body 不缓冲
  const upstream = await fetch(targetURL.toString(), {
    method: request.method,
    headers,
    body: ["GET", "HEAD"].includes(request.method) ? undefined : request.body,
    redirect: "manual"
  });

  // 响应透传; 删 content-length/content-encoding (字节流可能与头不一致)
  const respHeaders = new Headers(upstream.headers);
  respHeaders.delete("content-length");
  respHeaders.delete("content-encoding");
  return new Response(upstream.body, {
    status: upstream.status,
    statusText: upstream.statusText,
    headers: respHeaders
  });
}