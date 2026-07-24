# CLAUDE.md — omn-merge 工作宪法
# v2 · 2026-07-21 · Supreme 签发 · 改动须 Supreme 批准

## §1 双空间铁律
- nomke/omn = 生产, 4.2.3, 25 key, bucket omniroute-data: 零触碰。
  不探针、不配置、不试验、不引用其日志支撑 dev 结论。
- nonoke/omn = 永续 dev, v4.3.0, 8+1 key, bucket omn-data: 全部工作在此。
- 探针只打 nonoke-omn.hf.space。
- 两空间日志分开取证, 禁止交叉引用结论(第二轮误判根因的教训)。

## §2 冻结令(T+48h 宣判前, 即 2026-07-23 03:16 前)
- 禁 Dataset push。禁 Space restart / factory reboot。禁改现役脚本与 gate 配置。
- 金丝雀时序(授权已含, 到点执行, 不再请示):
  R1 07-22 03:16 后 双 key 单发; R2 07-22 15:16 后 同档;
  R3 07-23 03:16 后 全量 9 key → 宣判。
- 异常即停: 非预期信号 → 停, 不抢修, 报回会话。

## §3 Secrets 纪律
- secret/token 值零入会话、零入文档、零入 git。记录只写位置不写值。
- 一律使用 env 占位(${NIM_KEY} 等)。
- GitHub 令牌仅只读克隆, 禁 push; 上游公开仓库克隆不需要令牌。
- 已登记例外: ~/.claude/settings.json:26 vision key(env 迁移处理中)。

## §4 文档链入口(SSOT)
- 主文档: audit/2026-07-21-nim-403-账户级封禁-归因与改造立项.md
- 交接包: 2026-07-21-step5-验收交接包-cg52.md v1(③④⑤⑥ 暂停, ②由金丝雀吸收)
- 时序总表: audit/2026-07-21-cg52-五步归档执行时序总表.md
- 任务书: cg52 新方向任务书 v2。冲突以主文档为准。

## §5 生成与取证纪律
- 不人工翻更新记录; 机制结论必须 file:line 双版本(3.8.43/3.8.49)对照。
- 内部状态只认日志签名与持久通道(Litestream→R2、Dataset git);
  探针只做最终确认, 顺序不可反。
- upstream/ 两棵树只读: 禁整树替换、禁直接运行、禁入生产。
- 基座裁决: 3.8.43@b729a8f 代码基座 + 4.2.3 行为参数 + 3.8.49 定点移植;
  禁整体回退 4.2.3, 禁整体升级 3.8.49。

## §6 护栏段
- PreToolUse hook(secret-scan.py): 扫 Bash/Write/Edit 载荷, 命中密钥形态 exit 2 拦截。
- deny 16 条 / ask 2 条见 .claude/settings.json; settings.json 不入 git。
- 自验纪律: 测试一律用合成串(chr 拼接构造), 严禁真 key 或类真 PSK 入会话。
- pre-commit: 扫暂存区, 命中即拒; git add/commit 一律 ask 人工裁决。

## §7 网关接线段
- gate 契约: /v1/* 用 Authorization Bearer 头; Bearer 值须 = INTERNAL_PSK(非 OMNIROUTE_API_KEY); safeEqual crypto.timingSafeEqual 常量时比(gate.js:173-178)。启动 fail-closed: INTERNAL_PSK 缺/<16 → FATAL exit(gate.js:31)。
- gate 后台开关: GATE_ADMIN_ENABLED==='1' 则 /api/* 及其余全路径后台直透传(无闸), 否则 404; 纯布尔非 TOKEN(gate.js:24,159-165)。经 gate 读 combos 不可行, 读 Dataset hf_snapshot 代替。
- 速率三准则(一切对外请求默认档): 并发 ≤2-3; 缓存去重; Retry-After 优先,
  无则退避, 严禁立即重试。
- 日志纪律: HF 免费层不存日志; boot 后 30min 内抓取归档(会话+快照各一份);
  任何有意 reboot 前先抓当前日志尾段。
