# 验 candidate/root 跑通 + 四项验证计划 (Space 3t2y/a)

> 目标:25 NIM key 不出错不崩不被风控。HF 实验 Space 3t2y/a.
> 基线源:根目录三脚本(entrypoint flock 已修 + init 818行函数齐 + gate express版) + candidate 配套(Dockerfile/litestream/package 同 md5) + candidate README frontmatter(已加 sdk docker).
> secrets(用户手设):INTERNAL_PSK / OMNIROUTE_API_KEY / NIM_KEYS(25行) . R2 未设 = LOCAL-ONLY 无备份(OK).

## 待 Space 转 RUNNING 后验

### A. 起活/signal(前置)
- `curl https://3t2y-a.hf.space/healthz` → 上游 OR 健康透传 (gate.js D段)
- `curl -H "Authorization: Bearer $INTERNAL_PSK" https://.../v1/models` → 列 NIM 模型(combo + nvidia/*)
- 取 HF Space logs 确认:init 跑到 Step18(四 combo upsert)+ "Keys: 25 registered" + 无 line 498 command not found

### B. 风控限流(核心)
- 读 init 实生效的 RPM/并发:从日志 `alive_keys=N -> RPM=... concurrent=...` 抓
- 算每key RPM 分摊 = 全局RPM / 单调用按 sticky affinity 算;验证 ≤ 40
- 高频压 pulse:并发打 50 req 看是否 429 / WEDGED / ConnectionRecovery
- 对比 candidate 限流推算式 vs root 固定式

### C. 模型名歧义
- 裸模型名测:`curl -H PSK ... -d '{"model":"claude-opus-4-8"}'` → 期 404/ambiguous
- 带前缀:`-d '{"model":"nvidia/z-ai/glm-5.2"}'` → 期 200 流
- combo名:`-d '{"model":"nim-pool"}'` → 期 200 流(combo upsert 成功验证)
- hermes 路径:检查 hermes config 用 `nvidia/...` 还是裸 claude-*（hypercheck省:这是客户端侧，网关只收什么名决定）

### D. 超长截流
- 大 max_tokens 请求：发一 messages > 202752 tokens(HF CPU 内存可能限)→ 看网关/上游返回 400 还是 timeout 崩
- 看网关是否有 body size 限 → client 拒超长入口

## 注意
- HF Space 可能在 48h 因免费 hardware 里被 sleep；验证要快
- RUNTIME_ERROR 后取 errorCode + reason 进诊断
- candidate entrypoint flock bug 子壳开 fd 已证；现用 root entrypoint flock fix

## 历次推送
- `0c4a4e3` candidate 7 文件首次推 (CONFIG_ERROR 缺README frontmatter)
- `79425ff` README frontmatter加 (转 BUILDING 然后 APP_STARTING → RUNTIME_ERROR flock Bad fd)
- `6cfeae9`/`9762f070` root 三脚本推(entrypoint flock fix + init 818 + gate)
