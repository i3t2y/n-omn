# 踩坑经验与维护指南

> 2026-04-30 整理。记录从零搭建到生产可用过程中遇到的所有关键问题、根因分析和解决方案。面向未来的维护者（人类或 AI）。

---

## 1. PATCH-GATE 补丁演进史

### PATCH-GATE-001：Combo 列表扩展

**问题：** 原始 gate.js 只识别 `nim-pool`，新增的 `nim-pool-lab` 不受 `stream=false` 保护。

**修复：** 将 `KNOWN_COMBOS` 从单字符串改为 `Set`，包含 `nim-pool` 和 `nim-pool-lab`。

**教训：** 每次新增 Combo 都要更新 `KNOWN_COMBOS`，否则新 Combo 会走直连路径，触发 `ALL_ACCOUNTS_INACTIVE`。

---

### PATCH-GATE-002：Combo stream=false 覆盖范围

**问题：** 原逻辑只对 `/v1/chat/completions` 强制 `stream=false`，但 `/v1/messages`（Claude-compatible）也会走 Combo，同样会触发 streaming 路径错误。

**修复：** 扩展条件判断，同时覆盖 `/v1/chat/completions` 和 `/v1/messages`。

**教训：** OmniRoute 的 Claude-compatible 端点也需要 stream 保护。新增 API 端点时要检查 gate.js 的条件覆盖。

---

### PATCH-GATE-003：stream_options 与 stream 的 NIM 约束 ⭐

**这是最隐蔽、耗时最长的问题。**

**现象：** Hermes Agent（OpenAI SDK）发送请求时默认携带 `stream_options` 字段（用于获取 token 用量统计），但不设 `stream: true`。NIM API 要求 `stream_options` 只能与 `stream: true` 共存，否则返回 400 错误。

**错误信息：**
```
[400]: Validation: The 'stream_options' field is only allowed when 'stream' is set to true.
```

**根因链路：**
1. Hermes/OpenAI SDK 发送 `{ "stream_options": {"include_usage": true}, "stream": false }`
2. gate.js 对 Combo 强制 `stream = false`（PATCH-GATE-001/002 的正确行为）
3. 但 `stream_options` 残留，NIM 拒绝 `stream_options + stream:false` 的组合

**修复方案（v3，最终版）：**
```javascript
// gate.js 第 150-161 行
if (bodyObj.stream_options !== undefined) {
    if (isCombo) {
        // Combo: 删除 stream_options（保持 stream=false 防 ALL_ACCOUNTS_INACTIVE）
        delete bodyObj.stream_options;
    } else {
        // 非 Combo: 设 stream=true（保留 stream_options 用于 usage tracking）
        bodyObj.stream = true;
    }
}
```

**关键测试结果：**
- ✅ 不带 `stream_options` 的直连模型 → 正常
- ✅ 带 `stream_options` 的直连模型 → gate.js 自动设 `stream=true` → 正常
- ✅ Combo 模型 → gate.js 删除 `stream_options`，保持 `stream=false` → 正常

**教训：**
1. **NIM 的 stream 约束比 OpenAI 更严格**：`stream_options` 必须与 `stream: true` 共存
2. **OpenAI SDK 的隐式行为**：SDK 可能在用户不显式设置的情况下添加 `stream_options`
3. **gate.js 必须做"防御性 body 处理"**：不能假设上游发来的 body 是干净的
4. **v1→v2→v3 的迭代**：v1 只处理 Combo，v2 扩展到所有模型（直接删 stream_options），v3 区分 Combo/非 Combo（非 Combo 保留 usage tracking 能力）

---

## 2. HF Space 文件系统特性

### 重启丢文件

**关键事实：** HF Space 每次重启后，容器文件系统重置为 Docker 镜像的内容。运行期间写入的文件（如 `/data/.or-api-key`）会丢失。

**影响：**
- `init-nim-keys.sh` 每次启动都要重新执行（注册 provider、创建 Combo 等）
- `/data/.or-api-key` 每次重启后重新生成
- 但 `/data/.init-done` 标记也会丢失，所以首次初始化逻辑每次都会重新执行

**设计应对：**
- init 脚本是**幂等**的：Provider 409=已存在跳过，OR_API_KEY 文件已存在跳过
- 利用 `/data/.init-done` 标记控制首次逻辑（注册模型目录、创建 Combo）
- 但标记在重启后丢失，首次逻辑会重复执行（这是预期行为，不会造成副作用）

### /data/ 目录是持久化例外？

**注意：** HF Space 的 `/data/` 在某些 Space 类型下是持久化的，但在 Docker Space 中可能不是。当前设计假设不持久化，每次启动都重新初始化。

---

## 3. gate.js 工程设计原则

### 3.1 Raw Body 转发（防 JSON 篡改）

```javascript
// 不用 Express body parser
// 手动收集 Buffer chunks → proxyReq 事件写入
const rawBuf = await readRawBody(req);
```

**原因：**
- Express body parser 会将 JSON 解析再序列化，可能改变精度、编码、格式
- 流式请求的边界可能被破坏
- PATCH-GATE-003 需要在 body 内容中做修改，修改后必须重新序列化

### 3.2 防模板字符串吞噬

**问题：** 在某些文档渲染或复制过程中，JavaScript 模板字符串变量可能被吞噬：
```javascript
// 可能被吞噬：
console.log(`listening on 0.0.0.0:${GATE_PORT}`);
// 实际输出：listening on :7860  （变量被吞掉）
```

**解决：** 关键路径使用字符串拼接：
```javascript
console.log('[gate] listening on 0.0.0.0:' + GATE_PORT);
```

### 3.3 双重 Header 清理

CF Worker 删一次，gate.js 再删一次（纵深防御）。删除的 Header：
```
cf-connecting-ip, cf-ipcountry, cf-ray, cf-worker, cf-visitor,
x-forwarded-for, x-forwarded-proto, x-real-ip, true-client-ip
```

**原因：** 防止上游服务通过 Header 识别真实来源。

### 3.4 package.json 隔离

`hf-space/gate/package.json` 将 gate.js 隔离在独立 CommonJS 作用域，防止被 OmniRoute `/app/package.json` 的 ESM 设置污染。

---

## 4. 认证三层链路

```
Client → [CLIENT_TOKEN] → CF Worker → [INTERNAL_PSK] → gate.js → [OR_API_KEY] → OmniRoute → NIM
```

**每层只能看到自己的 token，客户端永远看不到 OR_API_KEY。**

### 各层 Token 说明

| 层 | Token | 存储位置 | 获取方式 |
|---|---|---|---|
| CF Worker | `CLIENT_TOKEN` | CF Worker 环境变量 | 手动配置 |
| gate.js | `INTERNAL_PSK` | HF Space 环境变量 | HF Space Settings |
| OmniRoute | `OR_API_KEY` | `/data/.or-api-key`（运行时） | init 脚本登录 Dashboard 创建 |

### 调试认证问题

1. **401 from gate.js** → 检查 `INTERNAL_PSK` 是否匹配
2. **401 from OmniRoute** → 检查 `/data/.or-api-key` 是否存在且有效
3. **CF Worker 502** → 检查 CF Worker 能否访问 HF Space 端口

---

## 5. 模型池管理经验

### 5.1 生产池 vs 实验池

| 池 | 名称 | 模型数 | 策略 |
|---|---|---|---|
| 生产 | `nim-pool` | 3 | round-robin，只放已验证模型 |
| 实验 | `nim-pool-lab` | 4+ | 观察，允许失败 |

### 5.2 模型验证标准

进入生产池必须满足：
- 连续 6 次返回 200 + 非空 token
- 无 502/504 超时
- 无 0 token 成功响应（success-shaped failure）

### 5.3 已验证不稳定的模型

| 模型 | 症状 | 处理 |
|---|---|---|
| deepseek-v4-pro | 502/504 超时 | 留在 lab |
| deepseek-v4-flash | 稳定性不足 | 留在 lab |
| minimax-m2.7 | 长时间无响应 | 留在 lab |
| kimi-k2.5 | 200 但 0 token | 留在 lab |

### 5.4 Combo 创建坑

**错误：**
```json
{ "name": "nim-pool", "providers": ["nvidia"] }
```
→ 创建空壳 Combo，可能触发默认 provider 路由（落到 openai）

**正确：**
```json
{
  "name": "nim-pool",
  "strategy": "round-robin",
  "models": ["nvidia/meta/llama-3.3-70b-instruct", ...]
}
```

### 5.5 模型 ID 前缀规则

| 场景 | 前缀 | 示例 |
|---|---|---|
| `/api/provider-models` 的 `modelId` | 不带 `nvidia/` | `meta/llama-3.3-70b-instruct` |
| Combo 的 `models` | 带 `nvidia/` | `nvidia/meta/llama-3.3-70b-instruct` |

---

## 6. init-nim-keys.sh 流水线

### 启动时序

```
OmniRoute 启动 → 等待健康 → 登录 Dashboard → 创建 OR_API_KEY
→ 注册 25 个 Provider → 连接测试 → 应用 Resilience → 设置路由策略
→ 速率限制保护 → 重置 Circuit Breaker → 启动 gate.js
```

### 首次 vs 后续启动

- **每次启动都做：** Provider 注册（409=跳过）、Resilience 配置、路由策略、Circuit Breaker
- **首次额外做：** 模型目录注册、Combo 创建（通过 `/data/.init-done` 标记控制）
- **注意：** HF Space 重启后标记丢失，首次逻辑会重新执行（幂等，无副作用）

### 25 个 NIM Key

每个 NIM Key 是独立的 API Key，注册为 `nim-01` 到 `nim-25` 的 Provider。OmniRoute 负责轮询和故障转移。

---

## 7. Resilience 配置

```json
{
  "defaults": {
    "requestsPerMinute": 28,
    "minTimeBetweenRequests": 1,
    "concurrentRequests": 5
  }
}
```

**不要擅自改 RPM。** 28 是保守但稳定的基线。提升到 32/35 需要阶梯压测证据。

---

## 8. 部署流程

### 代码更新流程

```
修改文件 → git commit → git push origin main
→ GitHub Actions 自动：
   - cf-worker/** 变更 → wrangler deploy
   - hf-space/** 变更 → rsync 到 HF Space
```

### 所需 GitHub Secrets

- `HF_TOKEN` — HuggingFace write token（用于 HF Space 同步）
- `CLOUDFLARE_API_TOKEN` — Cloudflare Worker 部署

### 手动部署（无 CI）

```bash
# CF Worker
cd cf-worker && npx wrangler deploy

# HF Space（需要 huggingface-cli）
huggingface-cli upload 3t2y/a hf-space/ --repo-type space
```

---

## 9. 常见故障速查表

| 症状 | 原因 | 处理 |
|---|---|---|
| `stream_options` 400 错误 | NIM 要求 stream_options + stream:true 共存 | gate.js PATCH-GATE-003 已处理 |
| `ALL_ACCOUNTS_INACTIVE` | Combo 走了 streaming 路径 | 确认 gate.js 强制 stream=false |
| `Provider returned empty content` | 不等于 Key 坏 | 等冷却，测生产请求 |
| HTTP 000, 0 bytes | 上游模型超时/不可用 | 检查是否在 nim-pool-lab |
| 429 限流 | NIM key 配额用完 | 等待冷却或换 key |
| Circuit Breaker OPEN | 连续失败触发熔断 | `/api/resilience/reset` |
| Dashboard 显示"没有模型" | 缺少 provider-models 注册 | 注册模型到 `/api/provider-models` |
| gate.js 日志端口不完整 | 模板字符串被吞噬 | 改用字符串拼接 |
| HF Space 重启后异常 | 文件系统重置 | 等待 init 脚本重新执行 |

---

## 10. 与外部系统集成的注意事项

### 10.1 Hermes Agent 集成

- Hermes 使用 OpenAI SDK，会自动发送 `stream_options`
- PATCH-GATE-003 已处理此问题
- Hermes 配置：`provider=tt, fallback=openrouter, delegation=nog`

### 10.2 OpenAI SDK 兼容性

- NIM API 是 OpenAI 兼容的，但有额外约束
- `stream_options` 必须与 `stream: true` 共存
- Combo 模型不支持 streaming

---

## 11. 开发注意事项清单

- [ ] 新增 Combo → 更新 `KNOWN_COMBOS` in gate.js
- [ ] 新增 API 端点 → 检查 gate.js stream 条件覆盖
- [ ] 修改 Resilience → 先做阶梯压测
- [ ] 修改模型池 → 先在 lab 验证
- [ ] 部署前 → 确认 CHANGELOG.md 已更新
- [ ] 涉及认证 → 不要在文档/代码中写真实 Secret
- [ ] gate.js 修改 → 使用字符串拼接，不用模板字符串
- [ ] init 脚本修改 → 确保幂等性（409=跳过，文件存在=跳过）
