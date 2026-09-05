# probe 子 shell 退出码 exit1 经裸 wait 触 set-e 杀 init — 闭环记录

> 同源病族 (init `set -eo pipefail` + pipeline/子shell 退出码地雷) 继 2026-07-25
> C2 pipefail 静默杀 init (§历史闭环) 后第三轮复发。本档记本轮诊断弯路 + 真根 + 治法 +
> 三轮 boot 对照定谳。

## 执行摘要

`probe_nim_keys_real` 并发探活路 (X2 落地后), `_probe_one` 子 shell 最后一条
`[ "$_pverbose" = "1" ] && [...] && printf ... | sed ... > file` 在非 verbose 模
(`_pverbose=0`, HF Space ENV `NIM_PROBE_VERBOSE` 未开) 时, 首项 test `[ "0" = "1" ]`
返 exit 1 → 整 `&&` 链短路退出码 1 → **子 shell 退出码 = 1**。主循环收批
`wait "$_p"` (裸, 无 `|| true` 兜底) 收子 shell 退出码 1 → `set -eo pipefail` (init 行 2)
杀主进程 init → container `exit 1`, 日志断在 probe 起 `probe_nim_keys_real:` 行后
无收判行无 `Done` 无 `rc=0`。

诊断弯路: 首推 "HF Space supervisor 健康 probe 静默期杀 container" (外因臆测), Zen
驳回 "不是被杀就是代码有问题" → 退回查源坐实真根 = 代码 bug 非 HF 外杀。

治本 (commit `ef16b46`): L675 末补 `|| true` 兜子 shell 恒 exit 0。`_pverbose=0` test
fail → `|| true` 强制 exit 0; `_pverbose=1` printf 写满 exit 0 覆盖 `|| true` 不损
功能。子 shell 退出码恒 0 → `wait` 收 0 → `set -e` 不杀 → init 正常透。

暴露面: 两 boot (2026-07-31 05:24 / 05:25) 卡死, init 来不及产收判行。第三 boot 05:47
走 X4 ENV 闸 `NIM_PROBE_ENABLED=0` 整跳 probe 绕过 (ENV 绕治标, 未触子 shell 故未崩)。
06:14 配 `NIM_PROBE_ENABLED=1` 真路验真根根除 (`|| true` 修后透 rc=0)。

## 时间线

- 2026-07-31 02:50 boot (前序 X2+X4 commit `16c70dc` 落地首验): verbose 模 (`NIM_PROBE_VERBOSE=1`)
  跑通, init rc=0。**但降耗时失败 3 分 40 秒** (vs 旧 4 分 34 秒), 且 verbose 模 `curl -v 2>&1`
  明文回显 7 个 nvapi key 触 §2 红线。→ 推 X2.1 重试闸 + verbose 脱敏 (commit `e935ec2`)。
- 2026-07-31 05:24 boot (`e935ec2` push 后首验): container `exit 1`, 日志断 `probe_nim_keys_real:`
  起行后无收判无 rc=0。误归日志截断。
- 2026-07-31 05:25 boot: 同崩 exit 1, 同断点。
- 诊断轮 1: 我首推 "HF Space supervisor 健康 probe 静默期杀 container" (外因臆测)。
  推治法 = X4 ENV `NIM_PROBE_ENABLED=0` 整跳 probe 绕过 (= 我说 ENV 绕非真治)。
- Zen驳回 "不是被杀就是代码有问题" → 退回查源。
- 诊断轮 2 (本地复现): 剥离出子 shell + `wait` + `set -e` 最小复现, `bash -c 'set -eo pipefail; _pverbose=0; p(){ [ "$_pverbose" = "1" ] && echo x; }; (p)& w=$!; wait $w; echo OK'` → **EXIT 1, 无 "OK"**。精确复现 05:24/05:25 崩。真根坐实 = `[ "0" = "1" ]` test exit1 → 子 shell 退出码 1 → 裸 `wait` 收 1 → `set -e` 杀。
- 2026-07-31 05:47 boot (Zen配 X4 ENV `NIM_PROBE_ENABLED=0`): 跳 probe, 16 秒透 rc=0
  (ENV 绕治标, 未触子 shell 故未崩, 但非真根根除)。
- 2026-07-31 06:14 boot (commit `ef16b46` 修后, Zen配回 `NIM_PROBE_ENABLED=1` 真路):
  probe 7 key 全 HTTP 200 → alive, `Done (first-init). v4.3.2` + `NIM init 已退出 rc=0`
  06:15:31。~78 秒全程 (probe ~40 秒 3 批并发3)。**真根根除铁证**。

## 根因

`set -eo pipefail` (init-nim-keys.sh 行 2) + 子 shell 退出码语义地雷:

`_probe_one` 子 shell (L686 `( _probe_one ... ) &`) 在主循环并发收批。子 shell 退出码 =
其最后一条命令的退出码。L675 (本轮 verbose 脱敏 commit `e935ec2` 新增):

```sh
[ "$_pverbose" = "1" ] && [ -n "$_pv_out" ] && printf '%s' "$_pv_out" | sed -E '...' > "$_pdir/${_pidx}.verbose"
```

非 verbose 模 (`_pverbose=0`):
- `[ "0" = "1" ]` → test 失败 **exit 1**
- `&&` 短路, 整链退出码 = 首项 exit 1
- 子 shell 退出码 = 1

主循环 L692:
```sh
for _p in "${_batch_pids[@]}"; do wait "$_p"; done
```
`wait "$_p"` 返子 shell 退出码 1。`set -e` 下 `wait` 非零退出杀主进程 init → container exit 1。

为何 02:50 透 05:24/25 崩 (同源 `e935ec2`, 唯一变量 verbose 开关):
- 02:50 boot: `NIM_PROBE_VERBOSE=1` (verbose 模) → printf 写满 exit 0 覆盖 `||` 短路 → 子 shell
  退出码 0 → `wait` 收 0 → 透 (但 3 分 40 秒慢 + §2 明文 key 泄露)
- 05:24/05:25 boot: `NIM_PROBE_VERBOSE` 未开 (非 verbose 模 默认) → 子 shell exit 1 → `wait` 1 → 崩
- 05:47 boot: `NIM_PROBE_ENABLED=0` X4 ENV 闸跳 probe → 未触子 shell → 透 (ENV 绕)
- 06:14 boot: `NIM_PROBE_ENABLED=1` + commit `ef16b46` `|| true` 修 → 子 shell 恒 exit 0 → 透

## 促成因素

- X2 并发路 (commit `16c70dc`) 引子 shell `( ) &` + 容器内 `wait` 模式, 旧串行 probe 无此
  地雷 (无子 shell 退出码传播问题)。X2 + 后续 verbose 脱敏 `&&` 链尾添加未兜退出码。
- `set -e` 对 `wait` 收子 shell 非零退出杀主进程的行为非直觉, 易漏判 (本地 curl 403 秒返
  不复现需 timeout 000 路或 test fail 路才触)。
- 诊断弯路: 崩点断在 probe 静默期 (curl 15s timeout 000 跑中), 日志天然无 traceback 无
  收判行 → 易误判 "被外力 kill" 而非 "代码自崩于 wait 后"。
- 本地隔离测用 fake key curl NVIDIA 全 403 秒返无 timeout, 复现不出 000 路依赖 ENV 配置
  (变量 `_pverbose` 才是 key), 首次本地复现未覆盖 verbose=0 差异。

## 修复 (已验证)

L675 末补 `|| true` (commit `ef16b46`, `dev/logic/init-nim-keys.sh` +4/-1):

```sh
[ "$_pverbose" = "1" ] && [ -n "$_pv_out" ] && printf '%s' "$_pv_out" | sed -E 's/(Authorization:[[:space:]]*Bearer[[:space:]]+)[A-Za-z0-9._\-]+/\1<REDACTED>/gi' > "$_pdir/${_pidx}.verbose" || true
```

两态覆盖:
- `_pverbose=0`: test fail exit 1 → `|| true` 强制 exit 0
- `_pverbose=1`: printf 写满 exit 0 覆盖 `|| true` (短路), 功能不损

子 shell 退出码恒 0 → 裸 `wait` 收 0 → `set -e` 不杀 → init 透。

副作用半径: 仅 L675 一行, 子 shell 内其他命令均已有 `|| printf` 或 pipeline 兜底。无回归。

前置验全绿:
- `bash -n dev/logic/init-nim-keys.sh` SYNTAX OK
- `python3 .claude/hooks/secret-scan.py` exit 0 无命中
- 隔离测非 verbose 模 rc 0 透 (旧复现 exit 1 现修)
- 隔离测 verbose 模 rc 0 + sed 真脱敏 `<REDACTED>` 仍写 (功能不损)

boot 真验 (06:14, commit `ef16b46` push `e935ec2..ef16b46` 后Zen配 `NIM_PROBE_ENABLED=1`
Restart): probe 7 key 全 HTTP 200 → alive + 汇总 + Done rc=0 + 全 boot 78 秒。真根根除。

## 三轮 boot 对照定谳

| boot | ENV PROBE | ENV VERBOSE | L675 态 | 结局 |
|---|---|---|---|---|
| 02:50 | =1 跑 | =1 开 | 旧无 `\|\| true` | 透 rc=0 (printf exit0 覆盖) 但 3 分 40 秒慢 + §2 明文 key 泄露 |
| 05:24 | =1 跑 | 未开 (非 verbose) | 旧无 `\|\| true` | **崩 exit 1** (子 shell exit1 → wait1 → set-e 杀) |
| 05:25 | =1 跑 | 未开 | 旧无 `\|\| true` | **崩 exit 1** (同) |
| 05:47 | =0 跳 | 未开 | 旧无 `\|\| true` | 透 rc=0 (ENV 绕, 未触子 shell, 非真治) |
| 06:14 | =1 跑 | 未开 | **修 `\|\| true`** | **透 rc=0 + 40 秒** (真根根除) |

05:25 崩 ↔ 06:14 透 唯一变量 = L675 `|| true`。带病环境 (PROBE=1 非 verbose) 修后透 =
真根坐实非外因臆测。X4 ENV 闸 (`NIM_PROBE_ENABLED=0`) 是 ENV 绕治标, `|| true` 是代码
治本, 两者非互斥 (ENV 闸省 probe 时间, 代码修保证 probe 路不崩)。

## §2 secrets 历史泄露挂账 (本事故副生)

02:50 boot verbose 模 (`NIM_PROBE_VERBOSE=1`) `curl -s -v ... 2>&1` 明文回显 7 个 nvapi key
进 `init_20260731_025003.log` → 推 HF Dataset `nonoke/omn-logic` 公开存储 = 极敏感泄露。
commit `e935ec2` 已修代码 (sed `gi` 脱明文 → `<REDACTED>`), 02:50 VERBOSE 段铁证全
`<REDACTED>`。但**历史已推 Dataset 的 init log 含明文**须Zen判清理:

- 待办 (Zen裁决, 仅记位置零值入档):
  - HF Space `NIM_PROBE_VERBOSE` ENV 若仍开则关 (防未来 verbose 段再产明文, 关后
    verbose 段整不产 — 治标)
  - Dataset `nonoke/omn-logic` 历史 `init_*.log` / `debug_*.log` 含明文 key 件 (02:50
    verbose boot 期) Zen判删 / 重写剥明文版重推 (历史泄露清理)
  - Zen贴回本会话的 02:50 boot 文本含 7 明文 nvapi key (Zen持有的真凭) — Zen侧
    善后, 我侧只记位置不存值 (§2 红线)
- 责任与本轮代码改无关: `e935ec2` 脱敏治本已落, 本挂账仅清历史已泄露存量。

## 行动项

- [x] commit `ef16b46` 修 L675 `|| true` 兜 → push `e935ec2..ef16b46` nomn 通
- [x] 06:14 boot `NIM_PROBE_ENABLED=1` 真路验真根根除 (rc=0 + 40 秒)
- [x] 记忆 [[probe-x2x4-slow-start-landed]] 补真根 + 三轮对照表 + 臆测证伪教训
- [ ] SSOT (STATUS/HANDOFF/DECISIONS) 补本会话三真根 (本档同批)
- [ ] §2 历史泄露清理 (Zen侧, 见上挂账段)

## 经验教训

1. **排障先穷尽代码 bug 再归外因**: 本轮首推 "HF supervisor 杀" 外因臆测被Zen驳回,
   退回查源方坐实代码 exit1 地雷。崩点日志断在静默期天然无 traceback ≠ 外力 kill,
   应先验代码退出码传播链 (子 shell + `wait` + `set -e` 三元组)。
2. **`set -e` + 子 shell + `wait` 三元组是地雷**: `wait "$pid"` 返子 shell 退出码,
   子 shell 最后一条命令若 test 失败 exit 1 → 主进程被 `set -e` 杀。子 shell 最后命令
   是 `&&` 链时尤其 (首项 test fail 短路 exit1)。治 = 末尾 `|| true` 兜恒 exit 0。
3. **本地复现须覆盖 ENV 变量差异**: 首次本地复现 fake key 403 秒返不复现, 因未覆盖
   `_pverbose=0` 差异 (`[ "0" = "1" ]` test fail 才触)。变量定位须从 02:50 透↔05:24 崩
   的唯一差异倒推, 非从 curl 行为推。
4. **同源病族复发**: 2026-07-25 C2 (`jq` + `grep -v '^$'` 空输入 rc1 + pipefail 杀) 与
   本轮 (子 shell exit1 + 裸 wait + set-e 杀) 同属 `set -eo pipefail` 退出码地雷族。
   init-nim-keys.sh 行 2 `set -eo pipefail` 全程生效, 历史多轮修单点兜底, 未根治该模式
   风险面。建议 = `wait` 收子 shell 一律 `|| true` 兜 (主循环 L692), 子 shell 退出码
   不应能杀主进程 (子 shell 是探活 fail-open 兜底语义, 失败不应阻 init)。

关联: [[probe-x2x4-slow-start-landed]] [[flaretunnel-metrics-endpoint-lu3-landed]]
[[flaretunnel-impl-built-verified]] + 旧同族 ops/incidents/2026-07-25-c2-pipefail-init-silent-death.md
