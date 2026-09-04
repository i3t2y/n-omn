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

## §1 拓扑铁律(2026-08-19 修订: 单源单Space, 圣上令撤 nomke; 2026-08-29 增: xnexus 改名 o + nonoke 恢复)
- n-omn 私库 = 唯一血统。根目录=生产血统; dev/logic/=dev逻辑层镜像
  (实物在 xnexus/logic Bucket, 改动须 git 先行再 push);
  dev/base/=基镜像血缘; ops/=运营层(永不进Space, 不同步)。
- **xnexus/o = 唯一 Space**(2026-08-24 圣上令迁 xnexus 单 Space; 2026-08-29 圣上令 Space 名 omn→o 去指纹, HF 已改)。
  nonoke/omn 废弃(旧生产 Space, 已删内容; **账号 2026-08-28 恢复**, 圣上承诺不跑代理仅个人用途, 不再承载生产);
  nomke/omn 废弃(旧生产 Space, 不动不写); omn-v2 第三 Space 撤销。
  全程不新建任何 Space。
- R2 bucket = **omn-data**(单 Space 单桶; omniroute-data 旧生产桶不动存历史)。
  单 Space 无双写问题, 旧"R2 bucket 永不双写"双 Space 铁律随 nomke 撤失效。
- upstream/ 两树只读; 机制结论须 file:line 双版本对照;
  基座 3.8.43 + 4.2.3 行为参数 + 3.8.49 定点移植。
- **🔴 omn 命名红线 (2026-08-24 圣上令, 去网关指纹防 HF 风控; 2026-08-29 延伸: Space 名含 omn 已入官方视野; 2026-08-29 再延伸: 上游仓库名亦删, 一律通用描述)**: 代码/注释/文件/包名/评论一律用 `omn`, **禁用 `omniroute`/`nomke`/`nonoke`/`diegosouzapw` 字样 (含注释, 2026-08-29 圣上令)**。落点 dev/logic 源码 + 骨架件(Dockerfile/start.sh/README.md) + workflows (进 HF/Bucket 的一切)。例外保留: 旧 R2 桶名 `omniroute-data`(历史资源, fetch-*.yml 守卫正则) + upstream/ 两树只读 + ops/DECISIONS 等历史决策(只增不改, 不回改) + **dev/logic 现役 `OMNIROUTE_API_KEY`/`OMNIROUTE_PORT`/`OMNIROUTE_RELAY_BACKEND`(历史品牌遗留 env 键; `OMNIROUTE_RELAY_BACKEND` 为上游 unset 契约变量, 2026-09-05 Supreme 裁定保留, 不触发红线)**. 违反 = 红线, 一律拒。

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
