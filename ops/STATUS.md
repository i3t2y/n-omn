# ops/STATUS.md · omn dev 部署态快照

> 每轮部署/验证后更新。SSOT = 本文件 + 对应 ops/incidents/ + audit/。生产态见 §1 禁触, 此处只记 dev。

## 2026-07-25 (本轮) · 切换 ② boot 前固化批 + CLAUDE.md v3 — 待圣上 Restart
### CLAUDE.md v3 (圣上签发, 工作宪法修订)
- §0 生命周期: 会话开始读 HANDOFF+STATUS+DECISIONS; 翻案须 Supreme 明令; 改码只 diff 禁整文件重写
- **§1 拓扑铁律修订: n-omn 私库=唯一血统; 根目录=生产血统; `dev/logic/`=dev逻辑层镜像; `dev/base/`=基镜像; ops/=运营层永不进 Space. ✅ 本轮 git mv omn-logic→dev/logic 收敛; Dataset repo 名 `nonoke/omn-logic` 不变. ⚠ omn-v2 第三个 Space 撤销(2026-07-25): HF 免费层关闭新建 Docker Space 通道, 复用现役 nomke/omn + nonoke/omn 两 Space, 全程不再新建; nonoke/omn 晋级生产仅变量切换+Restart 零净室首跑(详见 DECISIONS 新拓扑条)**
- §4 健康=九段+rc=0 入宪法; §6 gate 180000 入宪法

### 切换 ② boot 前固化批 (K3 令六项并②前三件, 本轮落地)
- **probe 000 重试小修**: dev/logic/init-nim-keys.sh `probe_nim_keys_real` 000 分支单发→重试一次 (-m 30); 二次 403→AUTH_DEAD / 200/429→alive / 仍000→fail-open alive; bash -n 过 + case 合验
- **push Dataset MATCH**: 远端 init = `a1640dd5` (probe 修源态入远端, byte-for-byte 验)
- **三样固化**: release-checklist B3 具体化 + M 段 (20129/双层盘点/24h风暴计数); DECISIONS 三行 (gate超时180000/阈值不动/20129迁移日); HANDOFF.md 新建 (watcher 风暴特征串)
- 本轮 commit: `1159de6` (probe 修源 + 三样固化合一)

### 待圣上 boot 时 (② 启动门 六项, 圣上手动)
1. Space Variable 加 `GATE_UPSTREAM_TIMEOUT_MS=180000` (Variable, 与换 key 同次 Restart 生效)
2. Secret `NIM_KEYS` 换 25 行; 3. `GATE_ADMIN_ENABLED`=0 (单布尔开关); 4. Restart dev Space
(注: probe 修源已 push Dataset = `a1640dd5`, bootstrap 拉新件即含重试态)

### boot 后验 (cg52 四项 + 裁决五第五项)
- **boot #1 (2026-07-25 11:02) 全绿**: 九段全执行 + init rc=0 + Resilience 读回 `300/200/96/300000` (32 key 触 cap 300 首次实证, concurrent=96=32×3 缩放验讫) + probe 32 活 0 死 + M7 180000/heap 4096 读回层面坐实 + 付费墙零触发
- **boot #2 (2026-07-25 11:22) 全绿 = 幂等复现 + admin 404 双验**: 九段全执行 + init rc=0 + Resilience 读回 `300/200/96/300000` 与 boot #1 一字不差 (写路径稳定非首 boot 偶中) + probe 32 活 0 死 + `[gate] admin UI: disabled` (GATE_ADMIN_ENABLED=0 裁决二坐实) + bootstrap 自愈补 python3/curl/jq/sqlite3/huggingface_hub 约 60s 复跑 (裁决四设计认账, 每次重跑不持久化) → 退出标准 [2 次干净 boot] ✅
- **key 池基线 = 32 (非预案 25, 圣上裁决 32 是地面真值照准)**: 见 DECISIONS "② key 池基线 32" 条 + incidents 32 偏差裁决节
- **✅ 长思考一笔 (B3 + GATE_UPSTREAM_TIMEOUT_MS=180000 生效铁证)**: glm-5.2 SSE 真流式 (首 token 2.1s, 全 4.2s, 34 chunks 真流增量) + gpt-oss-120b 3.8s 收 `: omniroute-keepalive` SSE 注释行 = gate 主动 keepalive 维持长连接 (若 gate socket 默 30s 切, 应在 ~30s 收 502/504 错包, 实测两发均 urllib 自超 TimeoutError 无错包 = 不在 30s 切). boot 日志无 GATE_UPSTREAM echo 行, 但行为证据闭环, 不再追究
- **✗ 请求矩阵四笔 (B4 裁决五第五项缺口)**: nim-pool 笔1 200 (2.2s, nemotron-3-super-120b) ✅ / nim-pool 笔2 超时 101s (p2c 命中挂模型) / nim-codex 笔1 超时 101s (priority 钉首模型挂则无 fallback)。直模型对照: glm-5.2 200 (2.1s) / deepseek-v4-flash 200 (11.6s) / gpt-oss-120b 超时 (90s/200s) / llama-3.3-70b 超时 (47s/120s)。**根因非 combo 路由病非网病非 gate 切, 是池成分病—gpt-oss-120b + llama-3.3-70b 上游挂/极慢, probe 探活只测 glm-5.2 无 init 期感知, pool p2c 25% 染慢 codex priority 100% 掉**。达成路径 = 圣上从 8 模型意向池剔除两挂模型 → cg52 复跑 matrix 到 double-green
- **429 基线改挂③ (裁决三不开后台不读库)**: 钉 3 纪律刚执行不为一条基线重开 admin。③ 变量切换 R2→生产 bucket 时 litestream 同一 storage.sqlite (含 dev 期 32 key 全 call_logs) 复制到 omniroute-data → 切换后从生产侧只读副本跑一次 status_code 分桶 = dev 期基线白捡, 一行 SQL 的事。原"生产限流档裁决"改挂: 429 基线 + ③ 后 24h 风暴特征串计数 = 0 两项齐后落 DECISIONS
- ② 加速版退出六绿: 2 次干净 boot ✅ + 长思考 ✅ + 矩阵全绿 (圣上剔挂模型后 ⏳) + 过夜一轮 ⏳ + 429 改挂③ + 池成分健康 (B4 第五项)

---

## 2026-07-25 07:09 · C2 闭环 + 九段终验 — dev 全绿
- **Space**: nonoke/omn (HF dev, v4.3.2 init, 3.8.43 基座, 7 NIM key)
- **远端 Dataset**: nonoke/omn-logic
  - init-nim-keys.sh: `2832f694` (本轮 C2 修源态)
  - entrypoint.sh: `05e0dc29`
  - gate.js: `c00a3aba`
  - litestream.yml: `1563c08d`
  - package.json: `5ed9981b`
- **本地 HEAD**: b662bd1 (C2 commit) — task5 五件 9d5f42e / #4 OOM 9e2319e 已并入
- **Boot 实证**: 7 registered → gc_stale(无待删) → Provider IDs 7 → Resilience 245/21/244/300000 读回一致 → combo upsert PUT 200 两件 → override 8 applied → hf_snapshot uploaded → **init rc=0**
- **R2**: ✓ 已从 R2 恢复 (副本健康, 非本轮关注)
- **M1 限流**: RPM=245 concurrent=21 interval=244ms (alive=7, per_key 35/3)
- **gate**: listening 0.0.0.0:7860 → 127.0.0.1:20128, CTX guard 1.5MB 阈就位

## 切换五步序列态 (C2 落地后)
- ① **清空** ✅ (本轮 C2 闭环即第一步清空)
- ② dev 换 32 key 稳态浸泡 — ★boot #1(11:02) + boot #2(11:22, 幂等+admin 404)双绿 + 长思考一笔✅ + 429 改挂③✅, 剩三件: ①圣上从 8 模型意向池剔 gpt-oss-120b/llama-3.3-70b → cg52 matrix 复跑四笔到双 combo 绿 ✅→ ②过夜观察(明早收: 无 OOM/重启循+litestream txid 推+成功率无塌) ③圣上手动链 HF_TOKEN_NONOKE→push→sync-logic-dev 首跑绿→BASE_IMAGE Variable 钉锚→dispatch 骨架→Rebuild FROM=9c9aecf
- ③ nonoke/omn 晋级生产: 变量切换 R2→生产 bucket omniroute-data + GATE_ADMIN 按生产纪律 + Restart, 零建新 Space 零 Rebuild
- ④ restore 生产副本验证数据连续
- ⑤ 金丝雀放量, 旧 nomke 冻结一周

## 待办
- [ ] ② 退出三件: 圣上剔 gpt-oss-120b/llama-3.3-70b → cg52 matrix 复跑四笔双 combo 绿 + 过夜观察一轮 + 圣上手动链 (HF_TOKEN_NONOKE/push/sync-logic-dev/BASE_IMAGE 钉锚/dispatch 骨架/Rebuild FROM=9c9aecf)
- [ ] CI 侧: fetch-space-logs.yml 首跑绿 (push 后圣上手动 dispatch run — 验: evidence 分支出快照 + secret-scan 闸已执行 + 内容确为 boot/run 日志); 与 P0-tee 互补 (P0-tee=容器内持久落盘战后, 本通道=HF 可见窗口仓内归档现), 走当前执行流非战后队列
- [ ] 战后建设队列: 每模型 probe (init 探活扩展到池内全模型, 与 P0-tee 同批) — 现 probe 只测 glm-5.2 单模型, 挂模型 init 期无感知 (② 行为暴露)
- [ ] ③ 后: 429 基线 (从生产 bucket omniroute-data 只读副本一行 SQL 分桶) + 24h 风暴特征串计数 = 0 → 落 DECISIONS "生产限流档裁决"
- [ ] 全文件排查同类 jq/grep 空输入 pipeline(痛点1根治)
- [ ] audit/2026-07-25-k3-架构调整总览.md + docs/k3* 三 untracked commit 入档待判
