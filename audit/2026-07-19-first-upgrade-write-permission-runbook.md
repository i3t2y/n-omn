# 3 首次 upgrade 写权限验证预案 (2026-07-19)

> K3 收口轮任务 3: restart_space / add_space_variable 写权限未经 dry-run 验证,
> 首次真 upgrade 即首验。预案文档化, **本轮不执行 upgrade/restart/factory_reboot**。

## 现状基线

- 本地 `~/.omn-secrets` 持 `HF_TOKEN` (fine-grained, Space scope `write` 名义)
- 历史已实证 **读权限三端点全通**: `get_space_runtime` / `get_space_variables` / `space_ctl.py status`
- 写权限 (`restart_space` / `add_space_variable`) **未实证** — 写接口命名上属 Space write scope, 但:
  - HF fine-grained token 实际授权面常比名义 scope 宽 (参见 audit 4 `HF_TOKEN_DATASET_WRITE` 实测可读 Space variables 一则)
  - 反向亦真: 名义 write 未必兑现写 (平台行为非设计依据)

## 首验触发时机

升级环第一次真 upgrade (3.8.49 等上游前滚批次触发的 Space 重启)。
该次须调 `restart_space(factory_reboot=False)` 普通 Restart (零 build 队列), 即写权限首验。

## 验证流程 (upgrade 中)

1. `space_ctl.py restart_space` 调用
2. 观 rc:
   - **rc=0 + 36s 内转 RUNNING** → 写权限实证 ✓, 升级环管理臂断肢修复, 闭环
   - **rc≠0 + 401 Unauthorized** → 写权限不兑现, 走下方 runbook
   - **rc≠0 + 其它错** → 非 auth 问题 (HF transient / Space 状态机), 单独排查,

## 401 处置 runbook

若 restart_space 返 401:

### 步骤 1: HF 网页新建 fine-grained token
- https://huggingface.co/settings/tokens/new
- Token type: **Fine-grained**
- Scope: **仅** `nonoke/omn` Space → `Write access to contents of the Space repo` + `Read access to settings`
- 不勾 Dataset / 不勾 user identity scope (审计 4 已证 whoami 无关, 不需)

### 步骤 2: 更新本地 `~/.omn-secrets` 的 `HF_TOKEN` 行
```bash
# 替换 HF_TOKEN= 旧行 (KEY=value 格式, 无 export)
nano ~/.omn-secrets
# 找 HF_TOKEN=... 行, 替值为新 token
```
验证: `grep '^HF_TOKEN=' ~/.omn-secrets` 显示新 token 头四位不重旧值。

### 步骤 3: 重跑 upgrade (即重试 restart_space)
```bash
export HF_TOKEN="$(sed -n 's/^HF_TOKEN=//p' ~/.omn-secrets)"
python3 ~/omn-ops/scripts/space_ctl.py restart_space --factory-reboot=False
```
观察: rc=0 + 36s RUNNING → 升级环闭合。

### 步骤 4 (可选): 写权限实证后归档
新 token 写权限实证后, 更本文件记 `restart_space rc=0 ✅` 并归入 audit 4 关键词暴露面归档。

## 调用契约 (沿用)

```bash
# .omn-secrets 为 KEY=value 无 export, source 无效, 须手动 export 注入:
export HF_TOKEN="$(sed -n 's/^HF_TOKEN=//p' ~/.omn-secrets)"
python3 ~/omn-ops/scripts/space_ctl.py <cmd>
```

## 禁区 (本轮 verbatim)

- ✗ 不实际跑 upgrade / restart / factory_reboot (本轮纯文档)
- ✗ 不轮换 HF_TOKEN (E1 轮换已取消 — 读权限三端点实证已尽, 写权限留首验时机自然验)
- ✗ 不为验写权限单独 Restart Space (占用一次普通 Restart 配额, 无收益)

## 风险面

1. **token scope 单点**: 若新 fine-grained 选错 scope (选 Dataset write 而非 Space write), restart 仍 401 → runbook 步骤 1 强调 "仅 nonoke/omn Space"。
2. **HF transient 401**: HF 平台偶发 401 非真 auth 失败 (rate limit / 平台抖动), 401 处置前先重试一次 (5s 后) 区分。
3. **HF_TOKEN_DATASET_WRITE 互不连动**: 本地另持 Dataset write token (用于 Dataset 源推), 升级环不动它, 两 token 不重叠 (audit 4 已证).

## K3 审阅验收点 (2026-07-20 补, 升级后按序验)

升级后观测序 (K3 出, 升级核心证明 = 第 3 条):

1. `wait_stage` 到 RUNNING; BUILD_ERROR 则拉 Build Logs (fetch_build_logs 路径已备)。
2. entrypoint 日志: 版本=3.8.48, 且 `EXPECTED_VERSION=3.8.48` 比对无告警 (EXPECTED_VERSION 机制首次真启用, 顺手验)。
3. **Litestream restore 找到 R2 既有副本** — 日志应见 restore 成功 + txid 从既有序列 (上次见 0x10) 续, 非 "no matching backups"。此 = "升级跨 R2 持久化" 首次实战, **整个三层架构存在意义即此**。若空库启动, keys 幂等重建兜底 (不崩), 但置 restore 路径失效须查。
4. Migration 计数 >109 (前滚新 schema, 幂等跳旧)。
5. init: 8 keys 0 失败。
6. R3 双通道重跑, version 读回应 = 3.8.48。

## ★ 回滚 DB schema 维度陷阱 (K3 新发现, 2026-07-20, runbook 必补)

回滚方案 "BASE_IMAGE 改回 :stable + factory_reboot" 有**此前无人言明的陷阱**:

- 升级后 DB 已被 3.8.48 迁移**前滚**, 回滚到 3.8.43 = **让旧代码读新 schema**。
- 补丁版迁移通常加列/加表 (additive), 旧代码大概率兼容, 但**这是运气非保证**。
- runbook 回滚策略**优先级须写明**: 首选 "**前滚到下一个可用版本**" 而非 "回退版本";
- 仅当**确认迁移集纯 additive** (升级报告 Dockerfile 段不含迁移信息, 须另查 release notes) 时才走版本回退。
- HF_TOKEN 写权限 401 走既定步骤 1-3 runbook。

## K3 问题 6 红线锚定注 (USER root ↔ check-permissions, 不动 Space Dockerfile)

**注**: 此条**不入 Space Dockerfile** (任何 Space repo push 触 rebuild, 为一条注释花 build 队列额度违反稀缺资源纪律)。锚定注仅落本 audit + 升级 runbook, 物理注释留给 "下一次被迫编辑 Dockerfile" 的契机 (按设计可能永远不来)。

- check-permissions.sh 缺失之所以无害, **完全建立 candidate `USER root` 决策上** (root 可写任何路径, 权限修正空转)。
- **红线**: 若未来出于安全加固将 candidate 改回 `USER node`, 此问题从空转变为阻塞, 届时**必在 bootstrap 末段补等价权限修正** (修 DATA_DIR 属主供 node 写)。
- 编辑 Space Dockerfile 的 `USER` 指令前, **先读 K3 问题 6** (本节)。两决策 (USER root + check-permissions 缺失) 须永久互相锚定。

## K3 问题 4 瓶颈换算备忘 (R5 输入, 2026-07-20)

- 1 并发 × 3.5s/请求 (R3 实测延迟) ≈ **17 请求/分钟有效吞吐上限**, **已低于 28rpm**。
- 即当前限制组合里, **28rpm 是冗余约束, 1 并发才是真实瓶颈** — 双重限制中实际生效恒为更严者。
- R5 决策: 若 25 key 扩容后要提吞吐, **第一杠杆是放宽并发数 (3~5)**, 非动 rpm; 放宽并发后 28rpm 才从冗余约束变生效约束, **届时才需 re-evaluate**。
- 排队延迟: 1 并发下第 N 请求等约 (N-1)×3.5s; 5 并发时末位等约 14s — 单用户串行无感, 批量调用可感知但不致命, 与 HF 免费层保护目标一致。

---

*2026-07-19 预案 · 本轮不执行 · 待首次 upgrade 时机首验 · 2026-07-20 补 K3 审阅验收点 (6 条) + 回滚 DB schema 陷阱 + 问题6 USER root 锚定注 + 问题4 瓶颈换算备忘*
