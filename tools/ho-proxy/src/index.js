// ===== ho-proxy: sonoke → xnexus gate 入站反代 =====
// 拓扑: sonoke 容器 → h-o.cc.cd (本 Worker) → xnexus-o.hf.space
//   (CF 边缘公网入站, 不经 HF 容器出站 *.hf.space 基础设施层拦截, 解 space-to-space 429)
// 参考: flaretunnel/worker.js 透传/SSE 风格 + nexus gateway worker 骨架
// 鉴权: 目标 Space 私有化后, Authorization 覆盖为 Bearer <HF_TOKEN> 门票 (2026-09-02 实测 HF 私有
//   Space 只认此头); PSK 改走 X-Gate-PSK 独立头透传给 gate.js 应用层校验 (gate 回退 authorization).
// 安全: 目标 host 写死固定, 无 ?url= 开放代理洞; 本 Worker 不做应用鉴权 (鉴权在 gate)
const TARGET = "https://xnexus-o.hf.space";

// 剔除控制头/逐跳头/压缩声明 (host 由 gate.js 丢弃重写, 不参与路由鉴权)
const DROP_REQ = new Set([
  "host", "connection", "content-length", "transfer-encoding",
  "cf-connecting-ip", "cf-ray", "cf-visitor", "cf-ipcountry", "cdn-loop",
  "x-forwarded-for", "x-real-ip",
  "accept-encoding" // 强制上游回 identity, 全链路字节透明, SSE 不被压缩层干扰
]);

export default {
  async fetch(request, env) {
    // 反代总开关 (fail-closed): 非显式 "1" 一律拒 → 503. 值经 wrangler.toml [vars] HO_PROXY_ENABLED.
    // 启用 = "1"; 关闭/缺省 = 拒 (防止未配好被 sonoke 误打, 排查期可整体停反代)
    if (env.HO_PROXY_ENABLED !== "1") {
      return new Response(JSON.stringify({ error: "proxy disabled" }),
        { status: 503, headers: { "content-type": "application/json" } });
    }

    const url = new URL(request.url);

    // 目标 host 写死固定, 不开放任意转发
    const targetURL = new URL(TARGET);
    targetURL.pathname = url.pathname; // /v1/* 原样拼接
    targetURL.search = url.search;     // query 原样

    // 透传请求头 (剔除 DROP_REQ); authorization 未在剔除列, 先透传再覆盖
    const headers = new Headers();
    for (const [k, v] of request.headers) {
      if (!DROP_REQ.has(k.toLowerCase())) headers.set(k, v);
    }
    // 私有 Space 门票: authorization 覆盖为 Bearer <HF_TOKEN> (2026-09-02 实测只认这头, X-Api-Key 无效).
    // PSK 改放 X-Gate-PSK 独立头透传给 gate 应用层校验 (authorization 已占位). 与 pages/ho-proxy 版对齐.
    if (env.HF_TOKEN) {
      headers.set("authorization", "Bearer " + env.HF_TOKEN);
      headers.set("x-gate-psk", "Bearer " + env.INTERNAL_PSK);
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
};
