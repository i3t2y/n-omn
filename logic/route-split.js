// route-split.js — 调用前缀/路径分流 (Issue #16, 2026-09-11)
// ════════════════════════════════════════════════════════════════════════════
// 目标: 把「重访问热点」(健康探针 / 模型清单 / 依赖探针) 与「推理类 payload」分流,
//   让轻请求走 probe 快路径 —— 少做两件重活 —— 但不引入第二套限流。
//
// 显式不做的事 (范围铁律, 见 Issue #16 「只择路不限流」):
//   · 不改并发/速率 —— 28 RPM / 1 并发 / 2200ms 仍由上游 requestQueue 执行 (gate.js:15 契约)。
//   · 不解析 body —— 判据只读 method + 归一化 path (+ 有无 body 标记), 零 content 分析。
//   · 不做缓存/不存状态 —— 纯函数, 每次调用同输入同输出 (无跨请求记忆)。
//   · 不新增依赖 —— 只用 path 字符串运算。
//
// 三 lane:
//   probe     = 无 payload 的轻读 (GET/HEAD/OPTIONS 的健康/清单/探针类路径)
//   inference = 有推理语义的请求 (POST body、/v1/chat/completions、/v1/messages、embeddings ...)
//   other     = 落不进 probe 也不像推理的 (未知前缀 / 未知方法)
//
// fail-safe (保守优先):
//   拿不准一律归 inference。probe 只在「方法无 body 且路径命中白名单前缀」时成立。
//   理由: probe 快路径会跳过失效应护栏; 误把推理请求判成 probe = 该保护失效。
//   反向误判 (probe 判成 inference) 只损失一点性能, 无正确性风险 → 宁可多归 inference。
// ════════════════════════════════════════════════════════════════════════════
'use strict';

// ── probe 白名单 (两级) ──────────────────────────────────────────────
// 均为「读型、无 payload、可频繁重放」的端点; 命中即走快路径。
// 第一级: 全等命中 (最精确, 零误伤面)
//   /healthz            gate 免认证探活 (gate.js:274, 不经 proxyV1, 此处仅登记语义)
//   /v1                 /v1 根探测 (消费端连通性试探)
//   /v1/models          模型清单 (消费端/discovery 高频拉)
//   /v1/providers       provider 清单只读
//   /v1/status          状态只读
const PROBE_EXACT = new Set(['/healthz', '/v1', '/v1/models', '/v1/providers', '/v1/status', '/v1/health']);

// 第二级: 允许带子路径的族 (只读子资源)。
//   注意: 不能直接裸前缀匹配, 否则 `/v1/models/x/completions` 会被判 probe
//   (推理流量误入快路径 → 护栏失效)。故子路径须过 INFERENCE_WORDS 闸。
//   /v1/health        经 PSK 的探活变体 (+ /v1/health/<probe-name>)
//   /v1/models        模型子资源只读 (排除含推理词的子路径)
//   /v1/bucket        bucket/manifest 校验探针 (start.sh §3 / sync-logic 读回链路)
//   /v1/providers     provider 子资源只读
//   /v1/status        status 子资源只读
const PROBE_SUBPATH_FAMILIES = ['/v1/health', '/v1/models', '/v1/bucket', '/v1/providers', '/v1/status'];

// 子路径里出现这些词 = 推理语义 (即便父路径像探针), 归 inference 不归 probe。
const INFERENCE_WORDS = /\b(completions?|messages?|responses?|embeddings?|rerank|generat\w*|images?|audio|speech|translat\w*)\b/i;

// probe 允许的方法: 无 body 语义的读方法。POST 永不算 probe (即使路径像探针),
//   因为 POST 可能带推理 payload, 且 fallback 护栏只对 POST 生效 (gate.js:501)。
const PROBE_METHODS = new Set(['GET', 'HEAD', 'OPTIONS']);

// inference 显式特征: 命中即归 inference (即便万一是 GET, 也不放快路径)。
const INFERENCE_PREFIXES = [
  '/v1/chat/',        // /v1/chat/completions
  '/v1/completions',  // 老接口
  '/v1/messages',     // Anthropic 风格
  '/v1/responses',    // Responses API
  '/v1/embeddings',   // 嵌入
  '/v1/images/',      // 图像生成
  '/v1/audio/',       // 语音
  '/v1/rerank',       // 重排
];

/**
 * 归一化 path: 去 query/hash, 折叠重复斜杠, 去尾斜杠; 空 → '/'。
 * 本地实现 (不 require gate.js 的 normalizePath, 保持本文件零依赖 / 可独立单测)。
 */
function normalizePath(p) {
  if (typeof p !== 'string' || p.length === 0) return '/';
  let s = p;
  const q = s.search(/[?#]/);
  if (q >= 0) s = s.slice(0, q);
  s = s.replace(/\/+/g, '/');
  if (s.length > 1 && s.endsWith('/')) s = s.replace(/\/+$/, '');
  if (s === '') s = '/';
  return s;
}

/**
 * 判定 lane。纯函数, 零副作用。
 * @param {{method?:string, path?:string, hasBody?:boolean}} input
 *   method  —— HTTP 方法 (大小写不敏感; 缺省视为 'GET')
 *   path    —— 原始路径 (可含 query, 函数内归一化)
 *   hasBody —— 是否带 body (content-length>0 / transfer-encoding)。默认由 method 推断。
 * @returns {{lane:'probe'|'inference'|'other', reason:string, path:string, method:string}}
 */
function classifyLane(input) {
  const method = String((input && input.method) || 'GET').toUpperCase();
  const path = normalizePath(input && input.path);
  const hasBody = input && typeof input.hasBody === 'boolean'
    ? input.hasBody
    : (method === 'POST' || method === 'PUT' || method === 'PATCH');

  // 1) 非无-body 方法 → 绝不 probe。带 body 的一律按推理处理 (fail-safe)。
  if (!PROBE_METHODS.has(method)) {
    if (hasBody) return { lane: 'inference', reason: 'method_with_body', path, method };
    // DELETE 等无 body 的非读方法: 既非 probe 也非推理, 归 other (仍走常规代理路径)。
    return { lane: 'other', reason: 'method_unsupported_for_probe', path, method };
  }

  // 2) 无体读方法: 显式推理前缀优先判 inference (防御性: 万一推理端点是 GET)
  for (const pre of INFERENCE_PREFIXES) {
    if (path === pre || path.startsWith(pre)) {
      return { lane: 'inference', reason: 'inference_prefix', path, method };
    }
  }

  // 3) probe 白名单: 全等优先
  if (PROBE_EXACT.has(path)) {
    return { lane: 'probe', reason: 'probe_exact', path, method };
  }
  // 3b) 前缀族: 只放行明确可带子路径的探针 (health/models/providers/status 的只读子资源)。
  //     收紧理由: `/v1/models/x/completions` 形似模型子路径的推理端点, 若按裸前缀放行
  //     就会把推理流量判成 probe → 误关护栏。故要求子路径不含推理词 (见 INFERENCE_WORDS)。
  for (const fam of PROBE_SUBPATH_FAMILIES) {
    if (path.startsWith(fam + '/')) {
      const rest = path.slice(fam.length + 1);
      if (INFERENCE_WORDS.test(rest)) {
        return { lane: 'inference', reason: 'inference_subword', path, method };
      }
      return { lane: 'probe', reason: 'probe_prefix', path, method };
    }
  }

  // 4) 其余无体读: 未知前缀 → other (常规代理, 不快不慢)。
  return { lane: 'other', reason: 'unknown_read_path', path, method };
}

/**
 * 便捷判定: 是否走 probe 快路径。probe 快路径 = 关掉两处重活:
 *   · readBodyPrefix (无需读会话指纹 —— 探针无 body, 不记账)
 *   · fallback 会话账本 (仅 POST 语义, 见 gate.js fgGuardApplies)
 * @returns {boolean}
 */
function isProbeFastPath(input) {
  return classifyLane(input).lane === 'probe';
}

module.exports = {
  classifyLane,
  isProbeFastPath,
  normalizePath,
  PROBE_EXACT,
  PROBE_SUBPATH_FAMILIES,
  INFERENCE_PREFIXES,
};
