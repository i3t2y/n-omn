// test-chain.mjs · FlareTunnel × 上游 × NIM 全链最小验 (1:1 模拟 上游 undici 路径)
// 验三件事 (Step4 真装门):
//   1. undici ProxyAgent proxyTunnel 经 FT 桥 CONNECT 隧道 — 同 上游 实跑路径
//   2. NODE_EXTRA_CA_CERTS 注 FT 自签 CA 进 Node 根 CA → undici buildConnector 默认可信 (机制真, 非臆测)
//   3. 桥按请求 hostname 签 host 证 + SAN 匹配 (ERR_TLS_CERT_ALTNAME_INVALID 不出现)
//
// 前置: 桥已起 (./flaretunnel tunnel --port 8080 --endpoints endpoints.json --ca-dir . --relay-auth "$RELAY_AUTH")
//       Worker 已部署改造版 (Worker AUTH_KEY == RELAY_AUTH)
//
// 跑法:
//   npm i undici            # 或用 Space 内上游自带 undici
//   export NIM_KEY=nvapi-xxx
//   export RELAY_AUTH=<与 Worker AUTH_KEY 同值>
//   NODE_EXTRA_CA_CERTS=./flaretunnel_ca.crt node test-chain.mjs
//
// 判定:
//   status: 200 + 模型列表 JSON  → 三环全通, 上游 侧必然能通, 最大风险消化, 可进 Step5
//   自签证书错 (self-signed/ALTNAME)  → CA 链断, 停, 不带雷进 Space (回头核两前提: 启动前导出/勿显式传 ca)
//   无 Worker 错 (Worker 401/超时)     → 桥+CA 三环已通, Worker 端未就绪 (本脚本仍证 TLS 链真)

import { ProxyAgent, fetch as uFetch } from "undici";
import { readFileSync } from "node:fs";

const PROXY = process.env.FT_PROXY || "http://127.0.0.1:8080";
const NIM_KEY = process.env.NIM_KEY || "";
const RELAY_AUTH = process.env.RELAY_AUTH || "";
const TARGET = "https://integrate.api.nvidia.com/v1/models";

if (!NIM_KEY) {
  console.error("[test-chain] 缺 NIM_KEY 环境变量 (export NIM_KEY=nvapi-...)");
  process.exit(2);
}
if (!process.env.NODE_EXTRA_CA_CERTS) {
  // 对照二分: 不设 CA 仍发请求, 故意触发 self-signed 错 (证机制非空, 非"本来就过")
  console.error("[test-chain] ⚠ 缺 NODE_EXTRA_CA_CERTS — 仍发请求, 预期挂 self-signed (对照 CA 真生效)");
}

// 1:1 模拟 上游: ProxyAgent + proxyTunnel (CONNECT 隧道), 不显式传 requestTls.ca
// (显式 ca 触发 builtin+extra 全旁路 → 公网 HTTPS 崩; 空 NODE_EXTRA_CA_CERTS 走标准 ENV 路才正解)
const dispatcher = new ProxyAgent({ uri: PROXY, proxyTunnel: true, bodyTimeout: 0, headersTimeout: 0 });

console.log("[test-chain] proxy:", PROXY);
console.log("[test-chain] target:", TARGET);
console.log("[test-chain] NODE_EXTRA_CA_CERTS:", process.env.NODE_EXTRA_CA_CERTS);

try {
  const r = await uFetch(TARGET, {
    dispatcher,
    headers: {
      Authorization: `Bearer ${NIM_KEY}`,
      // FT 桥 Patch C 自动注入 X-Relay-Auth (用 ps.RelayAuth), 客户端不传
      // 这里不重传 → 验桥端真注入; 若桥没注入, Worker 端会 401 unauthorized
    },
  });
  const text = await r.text();
  console.log("[test-chain] ✓ status:", r.status);
  console.log("[test-chain] body (前 300 字符):", text.slice(0, 300));
  if (r.status === 200) {
    console.log("\n[test-chain] ★ ZERO-RISK-PASSED: 三环全通 (CA信任+SAN匹配+签发者链), 上游 侧必通, 可进 Step5");
    process.exit(0);
  } else {
    console.log(`\n[test-chain] 非 200 (${r.status}): 看 body 区分 — unauthorized=桥没注入/Worker AUTH_KEY 不匹配; NVIDIA 格式=链通但鉴权/参数错`);
    process.exit(1);
  }
} catch (e) {
  const msg = String(e.message || e);
  console.error("[test-chain] ✗ 异常:", msg);
  // 展开 undici cause 链 (fetch failed 的真因在 cause 里)
  let c = e.cause;
  let depth = 0;
  while (c && depth < 6) {
    console.error(`[test-chain]   cause[${depth}]:`, c.code || c.name || "", "-", String(c.message || c).slice(0, 160));
    c = c.cause;
    depth++;
  }
  if (msg.includes("self-signed") || msg.includes("UNABLE_TO_VERIFY") || msg.includes("CERT_ALTNAME") || msg.includes("certificate")) {
    console.error("[test-chain] → CA 链断 (三环其一挂). 停. 核: ① NODE_EXTRA_CA_CERTS 启动前导出? ② 桥在跑且 CA 文件同份? ③ 桥按 hostname 签 SAN?");
    process.exit(3);
  }
  if (msg.includes("ECONNREFUSED") || msg.includes("fetch failed") || msg.includes("tunnel")) {
    console.error("[test-chain] → 桥/Worker 连通错 (非 CA 链病). 核桥在跑? Worker 已部署? RELAY_AUTH 对?");
    process.exit(4);
  }
  process.exit(1);
}
