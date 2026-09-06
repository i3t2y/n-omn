# CLAUDE.md — omn-merge 工作宪法
# v4 · 2026-09-05 · Zen 签发 · 改动须 Zen 批准
# v3 (2026-07-25) 以来变更: 上游基座升 3.8.50; xnexus/o 私有化 + Pages 反代进生产; 消费端扩至 hermes/nexus

## §0 会话生命周期协议(最高优先级)
- 读 docs/HANDOFF.md + docs/ops/STATUS.md + docs/ops/DECISIONS.md 最近10条,
  不凭记忆臆测, 不重复已锁定决策(翻案须 Zen 明确指令)。
- 任务范围: 一次会话一件事, 结束即交接。
- 会话结束/里程碑: 输出交接块(完成/锁定决策/文件变更/未决/下一步),
  供 Zen 归档进 docs/ops/。
- 输出纪律: 改代码只输出 diff 或定点替换, 禁整文件重写; 全量文件由
  git 出货, 不经会话即兴生成。

## §1 拓扑铁律 (2026-09-05 重整: 全部现状均已落地, 以下为运行描述, 非历史决策)
- n-omn 私库 = 唯一血统。根目录=生产血统; dev/logic/=dev逻辑层镜像
  (实物在 xnexus/logic Bucket, 改动须 git 先行再 push);
  dev/base/=基镜像血缘; docs/ops/=运营层(永不进Space, 不同步)。
- **xnexus/o = 唯一 Space** (私有化, 2026-09-02 完成): 匿名直连 404,
  仅经反代入口可达。生产 URL = `https://omn.360710.xyz/v1`
  (Cloudflare Pages 反代, 出站注入 HF Bearer 门票; PSK 走 X-Gate-PSK 头)。
  不新建任何 Space。
- **2026-09-05 备份链废弃**: R2/litestream/Dataset snapshot 三链全砍 (首席架构师裁); R2 bucket 与 Dataset repo `nonoke/omn-logic` 退役 (HF 侧实物任存, 代码零引用); Secrets 可删 R2_*/OMN_DATASET_REPO. 持久化收编: GitHub = 代码/配置真源; Bucket 挂载 = logic/ 部署通道 + 运行日志 capture_loop 直写 `/data/omn-logs/save/`; SQLite 无备份 (空库启动 + init-nim-keys.sh 幂等重建)。
- upstream/ 只读对照树: **现役基座 = 3.8.50** (2026-08-30 生产切换,
  BASE_IMAGE 钉 digest)。3.8.43/3.8.49 目录为历史对照, 机制结论
  仍以 file:line 对照现行 3.8.50 树为准。
- **🔴 omn 命名红线**: 进 HF/Bucket 的一切 (dev/logic 源码 + Dockerfile/
  start.sh/README.md + workflows) 禁用 `omniroute`/`nomke`/`nonoke`/
  `diegosouzapw` 字样。例外: 旧 R2 桶名 + ops 历史文档 (只增不改) +
  dev/logic 现役 `OMNIROUTE_API_KEY`/`OMNIROUTE_PORT`/`OMNIROUTE_RELAY_BACKEND`
  环境变量键名 (上游契约, 2026-09-05 Zen 裁定保留)。违反 = 红线, 一律拒。

## §2 Secrets 纪律
- secret/token 值零入会话、零入文档、零入 git; 记录只写位置。
- 一律 env 占位; 测试用合成串(chr 拼接), 禁真 key 或类真 PSK 入会话。
- GitHub 令牌按最小 scope; HF Dataset 令牌仅写权限于目标 repo。

## §3 文档链(SSOT)
- 系统契约: docs/HANDOFF.md(架构/不变量/排障入口)。
- 状态: docs/ops/STATUS.md(当前部署=commit, 待办)。
- 决策: docs/DECISIONS.md(锁定一句话日志) + docs/ops/DECISIONS.md(SSOT 账本), 均只增不改。
- 事故: docs/ops/incidents/(七段式)。验收: docs/ops/release-checklist.md。
- 历史: audit/ (只增, 不整理不删)。冲突以 docs/HANDOFF.md 为准, 其次 docs/ops/DECISIONS.md。

## §4 验证与健康信号
- 健康 = boot 九段全执行 + init rc=0; 任何中间段回显不构成证据。
- 内部状态: GitHub = 代码/配置真源; Bucket 挂载 = logic 部署通道 + 日志直写 (`/data/omn-logs/save/`) + boot 快照 (`/data/backups/storage.last-good.sqlite`, quick_check 过才更新); init 幂等重建兜底; 探针只做最终确认, 顺序不可反.
- 切流量前过 docs/ops/release-checklist.md A/B/C/M 全段。
- 堆健康 (2026-09-05 实录): 生效配置 `NODE_OPTIONS=--max-old-space-size=4096`
  (Space Variables, 覆盖上游 Dockerfile 镜像层 1024; 删除无效)。
  boot 须有 `[heapwatch]` 行, 峰值 pressure <0.75 为准。

## §5 护栏段
- PreToolUse hook(secret-scan.py) + pre-commit 扫描, 命中即拒。
- git add/commit 一律 ask 人工裁决; deny/ask 清单见
  .claude/settings.json(不入 git)。
- 速率三准则: 并发 ≤2-3; 缓存去重; Retry-After 优先, 无则退避,
  严禁立即重试。

## §6 网关接线段 (2026-09-05 对生产实测更新)
- 客户端一律指向反代入口 `https://omn.360710.xyz/v1`, 认证头
  `X-Gate-PSK: <真PSK>` (优先) 或 `Authorization: Bearer <真PSK>` (兼容回退)。
  禁裸连上游供应商端点。
- gate.js 仍接受旧 Bearer 契约 (safeEqual 常量时比; 缺/<16 fail-closed);
  CF Pages 出站将 HF Bearer 换成 Space 门票, 两层密钥不混。
- GATE_ADMIN_ENABLED: 维护窗口临时 '1', 用后恢复 '0' (布尔开关, 无 Token 认证)。
- 长思考流: GATE_UPSTREAM_TIMEOUT_MS=180000。
- 消费端 (2026-09-05): Claude Code / Codex / hermes(nexus sonoke/h, aux+cron) —
  全部共用同一反代入口, 无旁路。
- HF 免费层不存日志: boot 后 30min 内抓取归档, 有意 reboot 前先抓尾段。
