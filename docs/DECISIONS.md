
原因：GitHub 官方建议仓库必须有 README；README 应承担快速理解和导航职责，不承载全部踩坑细节。  
实测证据：`1.3.0.txt` Line 6001 显示 25 Key 注册、Resilience、Combo、gate 启动流程；Line 6024 显示核心启动验证项成功；Line 7593 显示 `nim-pool` 路由到 nvidia 成功。

---

#### **PATCH-MD-B**

文件：`docs/DECISIONS.md`  
操作：插入（新建文件）  
位置：文件起始处  
来源类型：实测 + 架构决策 + 官方文档  
实测证据：`1.3.0.txt` Line 6024、7593、8467、9163、9182；当前对话摘要确认生产 3 模型、实验 4 模型。

```markdown
# Architecture Decisions

本文档记录 `nim-omniroute-gateway` 的架构决策。这里不写操作教程，只写为什么这样做，防止后续迭代重复踩坑。

当前基线：GitHub `v1.0.0`

内部来源：`v1.3.0` 防吞噬版跑通方案

定稿日期：2026-04-25

## D001: GitHub 版本号从 v1.0.0 开始

虽然对话内部方案演进到 `v1.3.0`，但 GitHub 仓库以 `v1.0.0` 作为第一个正式稳定基线。

原因是 GitHub 版本面向外部可复现状态，而不是内部讨论轮次。当前基线已经完成部署、注册、保护、Combo、模型稳定性验证，因此适合作为 `v1.0.0` release。

## D002: 仓库必须私有

仓库包含部署结构、鉴权链路、环境变量名称、运维方法和故障处理路径。即使不提交真实 Secret，公开仓库也会暴露攻击面。

决策：仓库创建为 private。

## D003: 不提交任何真实 Secret

不得提交以下内容：

- NIM API Key
- INTERNAL_PSK
- CLIENT_TOKEN
- INITIAL_PASSWORD
- JWT_SECRET
- API_KEY_SECRET
- Cloudflare Worker Secret
- Hugging Face Space Secret
- Dashboard API Key

仓库只提交变量名、占位符和说明。

## D004: HF Space 存储视为临时存储

HF Space 上的 OmniRoute SQLite 状态不能作为唯一权威来源。容器重建后，provider、combo、model catalog、API key 状态都可能需要重新灌入。

决策：`init-nim-keys.sh` 必须承担幂等初始化职责，而不是依赖一次性手工配置。

## D005: 生产池和实验池分离

生产池 `nim-pool` 只放实测稳定模型：

- `nvidia/meta/llama-3.3-70b-instruct`
- `nvidia/z-ai/glm-5.1`
- `nvidia/qwen/qwen3-coder-480b-a35b-instruct`

实验池 `nim-pool-lab` 保留不稳定模型：

- `nvidia/deepseek-ai/deepseek-v4-pro`
- `nvidia/deepseek-ai/deepseek-v4-flash`
- `nvidia/minimaxai/minimax-m2.7`
- `nvidia/moonshotai/kimi-k2.5`

原因：round-robin 的生产可靠性由最弱模型决定。7 模型混入生产池会把 Kimi、DeepSeek、MiniMax 的 timeout、empty content、504 风险传播给默认入口。

## D006: `Provider returned empty content` 不等同于 Key 失效

Dashboard 中出现 `Provider returned empty content` 时，不直接判定为 NIM Key 无效。

判断顺序：

1. 看 provider 是否仍为 connected。
2. 看 provider 是否 protected。
3. 看限流倒计时是否会自然恢复。
4. 用生产 `nim-pool` 执行 `/v1/chat/completions` 验证是否返回 token。
5. 只有出现 invalid key、unauthorized、大面积 disconnected 时才进入 Key 故障排查。

## D007: `stream:false` 是必要兼容措施

生产请求推荐显式带上：

```json
{
  "stream": false
}
