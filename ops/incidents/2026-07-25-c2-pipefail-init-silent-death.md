# C2 · gc_stale_providers pipefail 静默杀 init — 闭环记录

## 执行摘要
init 每次 boot 在 "7 registered" 后静默终止, gc_stale/combo/Resilience/override
全段不执行, 池子实际从未建成。根因是 `_DEL_JSON` 赋值的 jq pipeline 中
`grep -v '^$'` 对空输入返 rc=1, 经 `set -eo pipefail` 杀进程。修复(抬门+兜底)
后 07:09 boot 九段全执行, init rc=0。暴露面: 约两轮 boot 池子空转(请求无
combo 可调, 影响面取决于 fallback 行为)。

## 时间线
- 前两 boot: 7 registered 后无下文, 误判为日志截断
- 诊断: Zen裁定为真崩 → 本地合成复现(场景1无待删 rc=1 杀 / 场景2僵尸+重复)
- 修复: set +eo pipefail 抬门 + ${_DEL_JSON:-[]} 兜底, 两场景合成验全绿
- 落地: dev/logic/init-nim-keys.sh 改源 → CI push Dataset(nonoke/omn-logic) → sha256 读回验 → Restart
- 2026-07-25 07:09 boot: 九段全执行 ✅

## 根因
`set -eo pipefail`(init:2) 与 jq/grep pipeline 组合的 bash 语义地雷:
无待删态(fresh R2, 7 连接全 nim-01..07 无僵尸无重复)时第一个 jq 输出空
→ `grep -v '^$'` 对空输入返 exit 1 → pipefail 致 pipeline rc=1
→ set -e 在赋值行杀 init, 后续 if 分支永不达, 无任何 traceback 或错误回显。

## 促成因素
- init 1046 行单体, 主执行段线性长流, pipeline 模式全文件散布(同类地雷可能潜伏)
- 验收信号失真: "7 registered" 曾被当健康信号, 实际其后段全崩
- dev push 即生效无 git 审查闸(本轮起已改为 PR + CI push 链路)

## 修复(已验证)
set +eo pipefail / _DEL_JSON 赋值 / set -eo pipefail 复原 / ${_DEL_JSON:-[]} 兜底
副作用半径: 仅该赋值行; 场景2(僵尸+重复正常删2)验证真工作半边无回归。

## 行动项
- [x] 修源 + 走新链路(PR→CI push→sha256验→Restart)首跑
- [x] 九段终验全绿
- [ ] 全文件排查同类 jq/grep 空输入 pipeline(痛点1根治, 排入后续)
- [ ] "boot 九段全执行" 写入 release-checklist.md 第一条(本记录同步)

## 经验教训
健康信号必须验证到"进程自然收尾 rc=0", 中间任何段位的成功回显都不构成健康证据。
