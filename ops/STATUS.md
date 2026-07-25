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
2. Secret `NIM_KEYS` 换 25 行; 3. 删 `GATE_ADMIN_TOKEN`; 4. Restart dev Space
(注: probe 修源已 push Dataset = `a1640dd5`, bootstrap 拉新件即含重试态)

### boot 后验 (cg52 四项 + 两新增)
- 九段终验 + Resilience 读回 = `300/200/75/300000` (25 key 触 cap 300 首次实证)
- probe 汇总 = 25 活 / 0 死
- 长思考一笔 (首 token 静默 >30s 完整走完不被 gate 切 — 修正实证)
- 429 监视基线 (首小时 call_logs 按 status_code 分桶 — 共享配额判断零点)
- ② 加速版退出: 2 次干净 boot (含 1 次主动 Restart 验幂等) + 请求矩阵四笔 + 过夜一轮即可进③

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
- ② dev 换 25 key 跑 1~2 天稳态 — ★下一步待排
- ③ nonoke/omn 晋级生产: 变量切换 R2→生产 bucket omniroute-data + GATE_ADMIN 按生产纪律 + Restart, 零建新 Space 零 Rebuild
- ④ restore 生产副本验证数据连续
- ⑤ 金丝雀放量, 旧 nomke 冻结一周

## 待办
- [ ] 切换 ② dev 换 25 key 稳态 1~2 天
- [ ] 全文件排查同类 jq/grep 空输入 pipeline(痛点1根治)
- [ ] audit/2026-07-25-k3-架构调整总览.md + docs/k3* 三 untracked commit 入档待判
