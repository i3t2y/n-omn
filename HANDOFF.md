# HANDOFF.md · omn 交接 / watcher 模式清单

> 会话/班次交接 + 长跑 watcher 哨兵串。每次交接补"交接时刻状态"行; watcher 串清单是 in_progress 长跑探活/巡的命中表。
> SSOT 角色与 ops/STATUS.md 互补: STATUS 记部署态硬指标, HANDOFF 记"此刻谁在跑/盯什么/等什么信号"。

## 交接时刻状态

### 2026-07-25 (本轮末) · 切换 ② boot 前固化批落地完毕 — 待圣上 Restart (执行人: cg52 侧, Claude Code 侧落引导前修源/固化)
- 本地 HEAD: `dbedbed` (动态见 `git log --oneline -1`)
- 本轮四 commit: `5ee3778`(K3三件) `e76ccf3`(②三钉点) `1159de6`(probe修源+三样固化) `dbedbed`(STATUS)
- 远端 Dataset: init=`a1640dd5` (probe 修态 push 闭环 byte-for-byte), 余4件见 ops/STATUS.md
- ⚠ CLAUDE.md v3 圣上签改未 commit (留圣上自 commit / 明令)
- ✅ 拓扑漂移已收敛: v3 §1 `dev/logic/` 路径落地本轮 (git mv omn-logic→dev/logic, 五件 history 保留); Dataset repo 名 `nonoke/omn-logic` 保持不变 (Dataset 名≠仓内目录, bootstrap 契约 Dataset 根平铺一字不动)
- n-omn GitHub 远端 ahead 38 commit 未推 (§3 禁 push 待圣上判)

### ② 启动门 四项 (已全落地 ✅)
1. ✅ Space Variable `GATE_UPSTREAM_TIMEOUT_MS=180000` (已注入, boot#2 行为实证生效)
2. ✅ Secret `NIM_KEYS` 填 32 行 (非预案 25, 圣上裁决一照准 32 是地面真值)
3. ✅ `GATE_ADMIN_ENABLED=0` (非删 token, 布尔开关关 — 钉 3 后台收敛, boot#2 `[gate] admin UI: disabled`)
4. ✅ Restart dev Space (§2 圣上手动) → boot#1 11:02 + boot#2 11:22

### boot 后验 (验收四笔 + 裁决五第五项)
- ✅ 2 次干净 boot (boot#1 11:02 + boot#2 11:22 主动 Restart 验 32 key 幂等, 读回 `300/200/96/300000` 一字不差)
- ⏳ **池成分健康 (裁决五第五项, release-checklist B4)**: matrix 四笔缺口 — nim-pool 笔1 200 (2.2s nemotron-3-super) / nim-pool 笔2 超时 101s (p2c 命中挂) / nim-codex 笔1 超时 101s (priority 挂无 fallback). 根因 = **池成分病非 combo 路由病**: gpt-oss-120b + llama-3.3-70b 上游挂/极慢, probe 只测 glm-5.2 无 init 期感知, pool p2c 25% 染慢 codex priority 100% 掉. 达成路径 = 圣上从 8 模型意向池剔两挂模型 → cg52 复跑 matrix 到双 combo 绿
- ✅ 长思考一笔 (B3 + GATE_UPSTREAM 180000 实证): glm-5.2 SSE 真流式 (首 token 2.1s) + gpt-oss-120b 3.8s `: omniroute-keepalive` (gate 主动 keepalive 维持长连接无 30s 错包切 → 行为闭环, boot 日志无 echo 不追究)
- ✅ 429 基线改挂③ (裁决三): 不重开 admin, 切 R2 生产 bucket omniroute-data 时 litestream 同一 storage.sqlite (含 dev 期 call_logs 全量) 复制到生产侧, 一行 SQL status_code 分桶白捡; 原"生产限流档裁决"时点改挂 429 基线 + ③ 后 24h 风暴串计数 = 0 两项齐后落 DECISIONS
- ② 加速版退出六绿: 2 boot ✅ / 长思考 ✅ / 429 改挂 ✅ / 池成分 ⏳ / 过夜 ⏳ — 剩圣上剔挂模型 + 过夜 + 圣上手动链 (HF_TOKEN_NONOKE→push→sync-logic-dev 首跑绿→BASE_IMAGE 钉锚→dispatch 骨架→Rebuild FROM=9c9aecf) 三件

## watcher 模式: 风暴特征串 (命中即告警)

> #4 OOM 链 + 账户级 fallback 的运行时签名。任一命中 → 不是池行为本身, 是病链尾部征兆, 第一排查 #4 / 配额共享 / 真 dead key。

| 串 | 出现场景 | 含义 | 首排查 |
|----|----------|------|--------|
| `FALLBACK MODE - excluded_count` | omniroute 对超大 body / 400-context-overflow 走 N-key round-robin | #4 病链中段, 非 400 终态拒而走全 fallback | gate 前 1.5MB 拦是否漏 (chunked / 比率<8), body 是否超阈该被 413 拦 |
| `all .* accounts unavailable` | 25-key fallback 跑完全空转 | #4 病链尾段终态拒 (生产 90秒空转签名) | 同上源头 + 此 key 批是否全死 (NIM 账户级封) |
| `Preserving last upstream error` | fallback 跑完保留上游错 | 终态拒回显, 前探 `Excluded`/`FALLBACK MODE` 追链 | 追 `FALLBACK MODE - excluded_count` 递增计数, 定 400 主体 |
| `ECONNREFUSED 127.0.0.1:20129` | `ProxyFetch` 运行时探 20129 | 20129 幽灵 (purge 0/0/0 但脏 proxyUrl 存他处) | 迁移日 M1 定点清, 非紧急不碰, §1 历史遗留 |
| `Excluded due to decommission` | 25-key round-robin 跳过死 key | 正常淘汰(死 key 跳), 非 #4 | 配 `FALLBACK MODE` 同看: 单 `Excluded` 计 = 常规, 配 `excluded_count` 递增 + `all unavailable` = #4 |

## watch 命令(本地合成探, 不触生产 / 不含真 key)

```bash
# boot 日志尾段抓风暴串 (仅本地可读 / HF Space 日志圣上贴回后我侧 grep)
tail -f /tmp/dev-boot.log | grep --line-buffered -E 'FALLBACK MODE|all .* accounts unavailable|Preserving last upstream error|ECONNREFUSED 127.0.0.1:20129|Excluded due to decommission'
```

## 历史 watcher 闭环 (已除病, 留作特征参考)

- express `MODULE_NOT_FOUND` crashloop → saga express fix 闭环 (audit/2026-07-23-crashloop-express-fix-landed.md)
- init upload_folder 403 crashloop → C1 token 加 write 权 + C2 upload try/except 闭环 (audit saga)
- `jq: Cannot index array` → C1 jq 归一化闭环 (task5)
- `7 registered` 静默终断 → C2 pipefail 闭环 (ops/incidents/2026-07-25-c2-pipefail-init-silent-death.md)
