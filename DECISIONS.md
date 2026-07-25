# DECISIONS.md · omn 锁定决策日志

> 每项不可逆/影响后续工作流方向的决策追加一行。变更须 Supreme 批准。
> 格式: 日期 · 决策标题: 内容简述。(出处指向对应 ops/incidents/ 或 audit/)

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
