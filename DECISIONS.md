# DECISIONS.md · omn 锁定决策日志

> 每项不可逆/影响后续工作流方向的决策追加一行。变更须 Supreme 批准。
> 格式: 日期 · 决策标题: 内容简述。(出处指向对应 ops/incidents/ 或 audit/)

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
生产日志实证 91s/199s/297s 长思考流是常态流量(首 token 前静默期), gate 30s socket 超时会切断首 token 前静默, 误伤②期间长思考验收数据。② boot 前生效(Variable 变更, 与换 key 合并同一次 Restart, 不额外占窗口)。与 M7 STREAM_READINESS_TIMEOUT_MS=180000 上游对齐。出处: 本决策由 4.2.3 生产日志零采数据推得, ② boot 前并 ops/incidents/2026-07-25-switch-step2-25key-baseline.md 事前三钉点。

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
