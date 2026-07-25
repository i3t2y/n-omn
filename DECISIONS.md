# DECISIONS.md · omn 锁定决策日志

> 每项不可逆/影响后续工作流方向的决策追加一行。变更须 Supreme 批准。
> 格式: 日期 · 决策标题: 内容简述。(出处指向对应 ops/incidents/ 或 audit/)

---

## 2026-07-25 · HF Space 日志抓取通道: GitHub Actions → n-omn evidence 分支, OpenConnector 日志线废弃
圣上令: 抓取 Space 日志用 GitHub Actions, 直接放 n-omn 私库。落地形态: fetch-space-logs.yml (cron 30min + dispatch), 单投 nonoke/omn (matrix 留 nomke 扩位, 待 HF_TOKEN_NOMKE), 脱敏闸 fail-closed (复用 secret-scan), evidence 分支与 main 分层。定位: CI 侧证据采集, 非逻辑层, 不受 ② 零变更约束, 阻塞仅 push+secret。与 P0-tee 互补: P0-tee 解决容器内持久落盘 (战后), 本通道解决 HF 可见窗口的仓内归档 (现在)。下游: claude-code-action 异步解读层未来从 evidence 分支消费 (机器产事实, LLM 产解读不变)。出处: 圣上 2026-07-25 令 + HF logs API 社区实证 (api/spaces/{ns}/{repo}/logs/{run,build})。

---

## 2026-07-25 · ② key 池基线 32 (非预案 25): 生产实池 32 行入池照准, cap 300 首触 + concurrent=96 缩放双验讫
② 预案原拟 25 key 稳态, 圣上重启后 NIM_KEYS 填 32 行 = 地面真值。圣上裁决 32 照准 (非偏差): ② 终极目的是验证 ③ 晋级生产将真实使用的配置, 直接验 32 行生产实池比验虚构 25 更对准目标。三点支撑: (1) cap 行为等价——25×35=875 与 32×35=1120 同远超 300, cap 300 首触已验讫与 key 数无关; (2) 最强证据在读回——Resilience 推导按 alive=32 重算 concurrent=32×3=96 (非 25 预案 75), boot #1 读回 `300/200/96/300000` 与 32 推导一字不差, 无 cap 的 concurrent 缩放路径一并验讫 (25 预案验不到); (3) 共享配额风险随池变大进一步稀释, 429 概率更低。③ 生产以 32 行为准 (非 25)。落库: STATUS ②行刷 32 + incidents 偏差裁决节, 文件名保留 `...-25key-baseline.md` 不动 (落笔时刻计划历史, 改名是考古污染)。出处: 圣上 2026-07-25 裁决一 + boot #1 (11:02) 读回实证 32×3=96。

---

## 2026-07-25 · ② 退出标准第五项: 池成分健康 (matrix 四笔全绿), release-checklist B4 入闸
② boot#2(11:22 双绿) 后 matrix 四笔验出一件事: probe 探活只测 glm-5.2 单模型 (init-nim-keys `probe_nim_keys_real` model=z-ai/glm-5.2), 池内 gpt-oss-120b / llama-3.3-70b 上游挂/极慢 init 期无感知; pool p2c 随机命中约 2/8 染慢 (~25% 超时), codex priority 钉首模型若挂则 100% 掉。**非 combo 路由病非网病非 gate 切, 是池成分病**。圣上 2026-07-25 裁决五: 池成分健康必须成为晋级标准一部分 (must 非 could, 池原样晋级 ③ = 已知坏成分带进生产)。落地: release-checklist B4 新条 — 矩阵四笔全绿 (nim-pool ≥2 笔 + nim-codex ≥1 笔成功), 达成路径 = 从意向上线模型池剔除挂/极慢模型 (本轮 gpt-oss-120b / llama-3.3-70b) 后复跑 matrix 到双 combo 绿; post-② 不变律 — ③ 之后每次池变更按此过闸。达成路径 = 圣上手 (Space 后台模型池配置), 剔完 cg52 复跑。"每模型 probe" (init 探活扩展到池内全模型) 入战后建设队列与 P0-tee 同批, 现在不动逻辑层。出处: 圣上 2026-07-25 裁决五 + ops/release-checklist.md B4 + STATUS 验收四笔矩阵实证 + incidents ② 退出标准条。

---

## 2026-07-25 · 429 基线改挂③: 不开后台不读库, litestream 切 R2 生产 bucket 时白捡
② 验收"429 监视基线"原列 dev 期 call_logs status_code 分桶。圣上 2026-07-25 裁决三: 钉 3 纪律 (后台暴露面收敛) 刚执行, 不为一条基线重开 admin (GATE_ADMIN_ENABLED=1) 触更大暴露面换可有可无数据, 不值——换零成本获取路径: ③ 变量切换 R2→生产 bucket omniroute-data 时, litestream 把 dev 期同一 storage.sqlite (含 32 key 期 call_logs 全量) 复制到生产 bucket, 切换后从生产侧只读副本跑一次 status_code 分桶 = dev 期基线白捡到手, 一行 SQL 的事。原"生产限流档裁决" (动态 cap 300 vs 保守 28/1) 裁决时点改挂两项齐后: 429 基线 (③ 后白捡) + ③ 后 24h 风暴特征串计数 = 0, 两项齐落 DECISIONS。出处: 圣上 2026-07-25 裁决三 + STATUS 429 基线改挂③ 条 + ops/release-checklist.md M3 (24h 风暴计数)。

---

## 2026-07-25 · GHCR BASE_IMAGE digest 钉锚 9c9aecf 作永久锚(T6 前替代浮动 :stable tag)
基座 digest 钉锚: Space Variable `BASE_IMAGE=ghcr.io/i3t2y/omniroute-base@sha256:9c9aecfd9eb529f44ab99cf94970aea896328146c64adc8ba146bfe809231347`(圣上手动改, 下次 Rebuild 生效, Dockerfile 一字不动)。浮动 :stable 是过渡, :X.Y.Z 钉版 tag 才是常态; 本仓 :3.8.43 tag 从未建过, 故 audit 唯一锚本就是这串 digest。digest 钉锚拆除整个"骨架首投 Rebuild 用浮动 tag 错误基座"风险类; T6 base-image.yml 未来只把此锚自动化。出处: 本轮 registry API index digest 仲裁 + audit/k3-review-r2-v30.md:519 落定记。

---

## 2026-07-25 · digest 真漂移仲裁证伪: :stable 未漂, 0b29aefb 是 platform manifest 伪 artifact
本轮前报 ":stable=0b29aefb 已漂离 audit 9c9aecf" 经 registry API 仲裁证伪: `docker manifest inspect :stable` 取的 0b29aefb 是单架构 platform manifest digest(量法非 tag 指针); registry 用 `Accept: application/vnd.oci.image.manifest.v1+json` 量 :stable 真 index digest = `9c9aecf` = audit519 落定一字不差 → :stable 实指 3.8.43 base 未动。同理 :3.8.48 我报 dad5d5e5 platform digest, registry index digest=da99fac1 与 audit519 一致。教训: 量漂移必须查 manifest `Docker-Content-Digest` header 走 index 量法, manifest inspect 的 config/platform digest 是测量伪影。出处: 本轮两闸仲裁 + audit519 "判漂必须查 manifest Docker-Content-Digest" 闸门纪律。

---

## 2026-07-25 · 落库完整性纪律: Write/Edit 返回成功不构成落库证据, read-back 才算
圣上改判闸根因: 两轮我 cat 错路径(DECISIONS.md 根→ops/DECISIONS.md、audit/k3总览→docs/)致错报"DECISIONS 空文件 stop-the-line", 实根 DECISIONS.md 真存 4701字节 9 条齐。若照"Write/Edit 返回成功即落库"惯性, 此类自欺会在更大动作中炸。固化: (1) 每个文件落库后必 `cat` 或 `git diff` 全文 read-back 验, 不在路径臆测; (2) commit 前 `git diff --cached` 全文审, 只 `--stat` 不许提交; (3) git show <commit>:<path> 路径须用 stat 确认的真路径, 凭臆测路径 read-back 会假 0 行/假空。健康信号标准向落库路径的自然延伸: 中间段回显不构成健康证据, 写入回显同样不构成。出处: 本轮完整性闸反转 + ops/incidents/2026-07-25-c2-pipefail-init-silent-death.md "假健康 boot" 同构教训。

---

## 2026-07-25 · 协作校验范式: AI 间结论可互驳, 驳须带 git/日志证据, 无证据服从与反驳同罪
固化 cg52 本轮三处协作表现: 对 K3 事实核查用 `git ls-files`/`git log` 证据而非服从权威(omn-logic 已 tracked 的纠正)、引用分治不一刀切(Dataset repo id `nonoke/omn-logic` 与本地目录名 `dev/logic/` 的辨析)、主动识别并放弃冗余设计(STATUS hash 自记 amend 无解循环)。范式: AI 间任何结论可被另一 AI 驳, 但驳必须带 git/日志证据; 无证据的服从(顺权威不验)与无证据的反驳(臆测路径/伪 artifact)同罪, 二者皆饮自欺。出处: 本轮两闸 K3 驳 cg52(digest 平台伪 artifact + Restart 不重拉基镜像两纠错) 续 cg52 驳回(路径错验) 的双向校验闭环。

---

## 2026-07-25 · 一库双器新拓扑: 撤销 nomke/omn-v2 第三个 Space, 复用现役两 Space
HF 免费 Docker SDK 自 2026-07 关闭新建通道(报错 "hosting Gradio and Docker Spaces on free cpu-basic requires PRO"), 现役 nomke/omn + nonoke/omn 是祖父条款保护稀缺资产。omn-v2 原蓝绿净室首跑定位撤: nonoke/omn 现已跑三层架构真机验(C2/九段/②全在其上), ②退出六绿即"已验证现役架构", 晋级生产仅变量切换(R2 指生产 bucket + GATE_ADMIN 按生产纪律)+ Restart, 零 Rebuild 零净室首跑。③④⑤改: nonoke/omn 晋级生产, nomke/omn(v4.2.3) Pause 停写冻结作回退底牌; C3 单写铁律执行序钉死(先 Pause nomke 写停 → 改 nonoke R2 变量 Restart → 全宇宙任何时刻仅一个写者), 回滚对称。DefaultCloseOperation 最终态回"一生产一开发"双 Space 永久闭环, 全程未新建任何 Space, 配额墙绕开。轴: sync-space-skeleton.yml matrix 单投 nonoke/omn(matrix 结构留双投一行扩展); HF_TOKEN_NOMKE 暂缓建(待 nomke 原地三层升级转 dev 时), 现 HF_TOKEN_NONOKE 单 token 覆盖 Dataset+dev 骨架。出处: 圣上 2026-07-25 裁决 + HF 免费层关闭报告。

---

## 2026-07-25 · gate 上游超时对齐 M7: GATE_UPSTREAM_TIMEOUT_MS=180000 (Variable, Restart 即生效非 Rebuild)
生产日志实证 91s/199s/297s 长思考流是常态流量(首 token 前静默期), gate 30s socket 超时会切断首 token 前静默, 误伤②期间长思考验收数据。② boot 前生效(Variable 变更, 与换 key 合并同一次 Restart, 不额外占窗口)。与 M7 STREAM_READINESS_TIMEOUT_MS=180000 上游对齐。**② 行为实证生效 (boot #2 期, 2026-07-25)**: GATE_UPSTREAM_TIMEOUT_MS Variable 已注入 (Space 列表 Updated 35 min, boot #2 前); boot 日志无该 Variable echo 行 (gate.js:27 `process.env || 30000` 默 fallback 不打印注入态), 但行为反推闭环 — gpt-oss-120b 长静默请求 3.8s 收 `: omniroute-keepalive` SSE 注释行 (gate 主动 keepalive 维持长连接), 两发分别 91.5s/200s 全 TimeoutError 无 502/504 错包 (若 gate socket 默 30s 切应在 ~30s 收错包, 实测无 = 不在 30s 切) → 超时已升 180000 生效。圣上 2026-07-25 裁决二判 boot 日志 echo 行缺失不追究, 行为证据闭环。出处: 本决策由 4.2.3 生产日志零采数据推得, ② boot 前并 ops/incidents/2026-07-25-switch-step2-25key-baseline.md 事前三钉点; ② 行为实证见 STATUS 长思考一笔。

---

## 2026-07-25 · 阈值不动决议: gate CTX_MAX_BYTES=1500000 / real_context=200000 维持, 不因 ② 25 key 触 cap 300 调
gate 1.5MB 字节硬拦(#4 OOM Patch B) 与 real_context 200000(压缩 Governor) 经 7弹+8B-tok 标定双验证, 与 key 数无耦合。② 25 key 触 cap 300 RPM 是 init 动态推导预期(init:208/667), 非阈值信号。调阈值前须有新病链数据, 不预动。出处: audit/2026-07-25-ctx-guard-oom-fix-landed.md + realctx200k landed, 防误调写入 ops/incidents/2026-07-25-switch-step2-25key-baseline.md。

---

## 2026-07-25 · 20129 幽灵处置: 迁移日 M1 定点清, 禁全库 LIKE 盲删, boot 前不碰
生产 14:15 起 `ProxyFetch ECONNREFUSED 127.0.0.1:20129` 幽灵仍现 (purge 0/0/0 但运行时有连接尝试, 脏 proxyUrl 存他处历史遗留)。② boot 前不动 (非本轮管, §1 生产禁触本项根源在生产侧)。迁移日 M1: strings 粗筛表名 → 定点 SELECT 确认 → 定点 UPDATE 清除 → litestream 同步绝育。禁全库 LIKE 盲删(数据面风险)。出处: ops/release-checklist.md M1 + audit/2026-07-25-ctx-guard-oom-fix-landed.md 遗留 audit 项 (2)。

---

## 2026-07-25 · 健康信号标准: 验收以 boot 九段全执行 + init rc=0 为准, 任何中间段回显不构成健康证据
前两轮假健康 boot (07-25 05:26 两 boot 均停 "7 registered", 实则 set -eo pipefail 杀 init 后段全崩无回显) 换来的验收标准固化。九段见 ops/release-checklist.md A1。出处: ops/incidents/2026-07-25-c2-pipefail-init-silent-death.md。

---

## 2026-07-25 · C2 gc_stale_providers pipefail bug 闭环: set +eo pipefail 抬门 + ${_DEL_JSON:-[]} 兜底
init:2 `set -eo pipefail` 下 `_DEL_JSON=$(jq...|grep -v '^$'|jq -R .|jq -s 'unique')` 赋值, 无待删态 jq 输出空 → grep 空输入 rc=1 → pipefail 杀 init, 7 registered 后全段不执行。修源 commit b662bd1 + push Dataset MATCH 2832f694 + 07:09 boot 九段全绿。出处: ops/incidents/2026-07-25-c2-pipefail-init-silent-death.md。

---

## 2026-07-25 · #4 OOM 病链双 patch: entrypoint NODE_OPTIONS 4096 回归 + gate 单阈值字节硬拦 1.5MB
dev 7key heap OOM / 生产 25key 90秒空转终态拒 同源链: 超大 body → NVIDIA 400(glm-5.2 硬顶 202752) → omniroute N-key round-robin fallback(auth.ts:1592) → 堆载累积终态拒/OOM。Patch A 堆 4GB 回归(env 可覆); Patch B gate CTX_MAX_BYTES=1500000/8B-tok 标定前拦 413, 仅判 content-length 不缓冲 body 保 SSE。出处: audit/2026-07-25-ctx-guard-oom-fix-landed.md。

---

## 2026-07-25 · real_context 200000 + body 4MB (per-key 能力握实, 非"防400盾")
init 三改 (real_context 32768→200000 / body raw 1→4 / echo 同步) 推 73e71f30。8B/tok 标定使 real_context 降级为"压缩 Governor"(122083 阈值派生), 非 NVIDIA 400 盾 (200000 + 压缩省3% 数学不防 400, 防线上移至 gate 字节硬拦)。出处: audit/2026-07-25-realctx200k-body4mb-landed.md。

---

## 2026-07-24 · 窗规解除: dev Dataset push ambient 授权(不再逐批显式令内)
原铁句"03:16Z前禁推"作废, 后续 dev Dataset 推送不再逐批请示。不变项: 生产 nomke 零触碰 / 凭禁触 / Space Restart Supreme 手动 / upstream 只读。出处: audit/2026-07-23-crashloop-saga-landed.md。

---

## 2026-07-23 · saga 双期闭环: express fix(supervisor crashloop 源) + rar2 init 副崩 403 fail-open
两 crashloop 全根除: (1) gate push 后 bootstrap 三层解耦不跑 npm install 致 /logic 无 node_modules 撞 require('express') → entrypoint 加预装段; (2) init upload_folder 403 (token 账户级读非写) 致 set -e 杀 init → python upload 包 try/except 降 WARN + hf_snapshot||true。五件远端终态: init 21cc7cdb/entry 4803e290/gate 616047c6/litestream 1563c08d/package 5ed9981b 全 == 本地。出处: audit/2026-07-23-crashloop-saga-landed.md。
