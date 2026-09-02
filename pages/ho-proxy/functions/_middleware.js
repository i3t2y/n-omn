// ===== ho-proxy (Page 版): sonoke → xnexus gate 入站反代 · Cloudflare Pages =====
// 文件名必须 _middleware.js (根级中间件, 拦截全路径含无路由的 404 路径):
//   wrangler 4.128 把 functions/[[path]].js 的 [[path]] 当 glob 匹配空集 → 整个函数目录被判空
//   (pages dev 显示 "No Functions") → 部署上去全站 404。改 _middleware.js 后解析正常,
//   中间件直接 return Response 不调 next(), 即等价全路径 catch-all 反代。
// 拓扑: sonoke → proxy.360710.xyz (CF Pages 边缘, 前置 PSK 校验) → xnexus-o.hf.space
//   (CF 边缘公网出站, 不经 HF 容器出站 *.hf.space 基础设施层拦截, 解 space-to-space 429)
// 鉴权(双层, 两个不同头, 互不冲突):
//   sonoke 带的  Authorization: Bearer <PSK>  → 边缘前置 safeEqual 校验 + 原样透传给 gate 应用层
//   CF 注入的     X-Api-Key: <HF_TOKEN>          → HF 平台层 (xnexus-o 私有 Space 门票)
//   INTERNAL_PSK 未注入 → 503; Bearer 缺/错 → 401 fail-closed; HF_TOKEN 未注入 → 不注(公开 Space 兼容)
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
  // 注入 HF 平台层 token (私有 Space 门票, 只存 CF env 不落 git):
  // X-Api-Key 与 Authorization 是两个不同头, 与 gate 的 PSK 共存互不冲突
  if (env.HF_TOKEN) headers.set("x-api-key", env.HF_TOKEN);

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