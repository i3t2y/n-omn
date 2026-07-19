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

---

*2026-07-19 预案 · 本轮不执行 · 待首次 upgrade 时机首验*
