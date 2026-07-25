# CLAUDE.md — omn-merge 工作宪法
# v3 · 2026-07-25 · Supreme 签发 · 改动须 Supreme 批准

## §0 会话生命周期协议(最高优先级)
- 会话开始: 读 HANDOFF.md + ops/STATUS.md + ops/DECISIONS.md 最近10条,
  不凭记忆臆测, 不重复已锁定决策(翻案须 Supreme 明确指令)。
- 任务范围: 一次会话一件事, 结束即交接。
- 会话结束/里程碑: 输出交接块(完成/锁定决策/文件变更/未决/下一步),
  供 Supreme 归档进 ops/。
- 输出纪律: 改代码只输出 diff 或定点替换, 禁整文件重写; 全量文件由
  git 出货, 不经会话即兴生成。

## §1 拓扑铁律(2026-07-25 修订: 单源双Space)
- n-omn 私库 = 唯一血统。根目录=生产血统; dev/logic/=dev逻辑层镜像
  (实物在 Dataset nonoke/omn-logic, 改动须 git 先行再 push);
  dev/base/=基镜像血缘; ops/=运营层(永不进Space, 不同步)。
- nomke/omn = 现役生产(v4.2.3, 无 Supreme 令不动); ③时 Pause 停写转冻结回退底牌。
  nonoke/omn = dev 金丝雀; ②六绿后于 ③ 晋级生产(变量切换 R2→生产 bucket + Restart, 零 Rebuild)。
  omn-v2 第三 Space 撤销(HF 免费层 2026-07 关闭新建 Docker Space 通道), 全程不新建任何 Space。
- 两 Space 日志分开取证, 禁止交叉引用结论; R2 bucket 永不双写
  (新旧 Space 不得同时在线写同一 bucket)。
- upstream/ 两树只读; 机制结论须 file:line 双版本对照;
  基座 3.8.43 + 4.2.3 行为参数 + 3.8.49 定点移植。

## §2 Secrets 纪律
- secret/token 值零入会话、零入文档、零入 git; 记录只写位置。
- 一律 env 占位; 测试用合成串(chr 拼接), 禁真 key 或类真 PSK 入会话。
- GitHub 令牌按最小 scope; HF Dataset 令牌仅写权限于目标 repo。

## §3 文档链(SSOT)
- 系统契约: HANDOFF.md(架构/不变量/排障入口)。
- 状态: ops/STATUS.md(当前部署=commit, 切换五步态, 待办)。
- 决策: ops/DECISIONS.md(只增不改)。
- 事故: ops/incidents/(七段式)。验收: ops/release-checklist.md。
- 历史: audit/。冲突以 HANDOFF.md 为准, 其次 DECISIONS.md。

## §4 验证与健康信号
- 健康 = boot 九段全执行 + init rc=0; 任何中间段回显不构成证据。
- 内部状态只认日志签名与持久通道(Litestream→R2、Dataset);
  探针只做最终确认, 顺序不可反。
- 切流量前过 ops/release-checklist.md A/B/C/M 全段。

## §5 护栏段
- PreToolUse hook(secret-scan.py) + pre-commit 扫描, 命中即拒。
- git add/commit 一律 ask 人工裁决; deny/ask 清单见
  .claude/settings.json(不入 git)。
- 速率三准则: 并发 ≤2-3; 缓存去重; Retry-After 优先, 无则退避,
  严禁立即重试。

## §6 网关接线段
- /v1/* Bearer = INTERNAL_PSK(safeEqual 常量时比); 缺/<16 fail-closed。
- GATE_ADMIN_ENABLED: 维护窗口临时配 '1'(布尔开关, gate.js:24), 用后恢复 '0'/删除仅 API 模式。
  (GATE_ADMIN_TOKEN 机制已废于 82d6559 saga回填期 "gate单开关" 改造, 现 gate.js 无 Token 认证, 纯布尔开关)
- 工具接入(Codex/Claude Code/任何客户端): base_url 一律指 gate /v1,
  禁裸连 integrate.api.nvidia.com 单 key。
- 长思考流: GATE_UPSTREAM_TIMEOUT_MS=180000(对齐上游 M7)。
- HF 免费层不存日志: boot 后 30min 内抓取归档, 有意 reboot 前先抓尾段。
