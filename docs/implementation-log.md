# NOG 源码实现记录

> 2026-04-30 整理，全仓库 20 个文件 2,931 行代码/文档深度分析。

## 1. 架构全貌

```
Client → [CLIENT_TOKEN] → Cloudflare Worker (index.js, 公网入口)
  → [INTERNAL_PSK] → gate.js (HF Space 内部守门层)
    → [OR_API_KEY] → OmniRoute (port 20128, 25-key 轮询)
      → NVIDIA NIM
```

**三层认证：每层只能看到自己的 token，客户端永远看不到 OR_API_KEY。**

## 2. 文件职责

| 文件 | 行数 | 职责 |
|------|-----:|------|
| cf-worker/index.js | 447 | CF Worker 主逻辑：鉴权、CORS、转发、告警 |
| cf-worker/wrangler.toml | 4 | Worker 部署配置 |
| hf-space/gate/gate.js | 191 | 内部守门：PSK 校验、Header 清理、Combo stream=false |
| hf-space/gate/package.json | 18 | 独立 CommonJS 作用域（防 ESM 污染） |
| hf-space/Dockerfile | 33 | 容器构建（基于 diegosouzapw/omniroute:latest） |
| hf-space/entrypoint.sh | 94 | 启动时序：OmniRoute → init → gate.js |
| hf-space/init-nim-keys.sh | 466 | NIM Key 初始化（最复杂，10 步流水线） |
| docs/AI_HANDOFF.md | 306 | AI 接手规范（只能增量 Patch） |
| docs/DECISIONS.md | 193 | 15 条架构决策 |
| docs/TROUBLESHOOTING.md | 246 | 10 个故障场景 |
| docs/VALIDATION.md | 208 | 实测验证记录 |
| README.md | 452 | 项目主文档 |

## 3. gate.js 关键逻辑

### 3.1 Combo stream=false 强制
```javascript
const KNOWN_COMBOS = new Set(['nim-pool', 'nim-pool-lab']);
const isCombo = KNOWN_COMBOS.has(model) || model.indexOf('/') === -1;
if (isCombo && bodyObj.stream !== false) {
    bodyObj.stream = false;  // 规避 ALL_ACCOUNTS_INACTIVE 误报
}
```

### 3.2 Header 双重清理
CF Worker 删一次，gate.js 再删一次（纵深防御）：
`cf-connecting-ip, cf-ipcountry, cf-ray, cf-worker, cf-visitor, x-forwarded-for, x-forwarded-proto, x-real-ip, true-client-ip`

### 3.3 Raw Body 转发
不用 Express body parser，手动收集 Buffer chunks → proxyReq 事件写入。
防止 JSON 精度丢失、编码改变、流式边界破坏。

### 3.4 防吞噬设计
关键路径用字符串拼接不用模板字符串（防变量被渲染/复制过程吞噬）。

## 4. init-nim-keys.sh 流水线

**每次启动都做（10 步）：**
1. 等待 OmniRoute 健康
2. 登录 Dashboard 获取 auth_token cookie
3. 创建/复用 OR_API_KEY → /data/.or-api-key
4. 批量注册 25 个 NIM Provider（nim-01 ~ nim-25）
5. 重新读取所有 Provider IDs（jq 过滤）
6. 应用 Resilience 配置（RPM=28, concurrent=5）
7. 设置路由策略（round-robin, stickyLimit=1）
8. 批量连接测试
9. 开启速率限制保护
10. 重置 Circuit Breaker

**首次额外做：**
- 注册 18 个模型到目录
- 创建 Combo nim-pool（10 模型 round-robin）
- 写入 /data/.init-done 标记

**幂等设计：** Provider 409=已存在跳过，OR_API_KEY 文件已存在跳过，init 标记控制首次逻辑。

## 5. 模型池

### nim-pool（生产，3 个稳定模型）
- nvidia/meta/llama-3.3-70b-instruct
- nvidia/z-ai/glm-5.1
- nvidia/qwen/qwen3-coder-480b-a35b-instruct

### nim-pool-lab（实验，4 个不稳定模型）
- nvidia/deepseek-ai/deepseek-v4-pro — 502/504
- nvidia/deepseek-ai/deepseek-v4-flash — 稳定性不足
- nvidia/minimaxai/minimax-m2.7 — 长时间无响应
- nvidia/moonshotai/kimi-k2.5 — 200 但 0 token

## 6. CI/CD

- **CF Worker：** push main + cf-worker/** → wrangler deploy（需 CLOUDFLARE_API_TOKEN）
- **HF Space：** push main + hf-space/** → rsync 到 HF Space（需 HF_TOKEN）
- 只同步 hf-space/ 目录，不镜像整个仓库

## 7. 关键约束

- Combo models 用 `nvidia/` 前缀，provider-models 的 modelId 不带
- RPM 28 不允许擅自改 35
- 仓库必须私有（暴露部署结构和鉴权链路）
- 不提交真实 Secret
- Dashboard 显示 ≠ 实际路由能力，需实测验证
- 不要连续 retest 25 个 provider（触发大规模限流）

## 8. 端口与网络

| 组件 | 端口 | 监听 |
|------|------|------|
| OmniRoute | 20128 | 127.0.0.1（仅内部） |
| gate.js | 7860 | 0.0.0.0（HF Space 暴露） |
| CF Worker | 443 | Cloudflare Edge |

## 9. 故障排查速查

| 症状 | 原因 | 处理 |
|------|------|------|
| ALL_ACCOUNTS_INACTIVE | Combo streaming 路径异常 | gate.js 已强制 stream=false |
| HTTP=000, 0 bytes | 上游模型超时/不可用 | 检查是否在 nim-pool-lab |
| 429 限流 | NIM key 用完配额 | 等待冷却或换 key |
| Circuit Breaker OPEN | 连续失败触发熔断 | /api/resilience/reset |
| Provider returned empty content | 不等于 key 坏 | 查具体模型和 provider |
| Dashboard 无模型 | 缺少 provider-models 注册 | 首次初始化未完成 |
