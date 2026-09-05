#!/usr/bin/env bash
# append 附录 A-D 到 omn-v4.3.2-k3-review-20260722.md
set -eo pipefail
cd ~/omn-merge
OUT=omn-v4.3.2-k3-review-20260722.md

# 附录 A: events_write.sh 全文 (Zen 令: 写入件 SQL 拼接安全性 K3 可审时放附录, 不计入 7 正文)
cat >> "$OUT" <<'APPA_EOF'

---

## 附录 A — events_write.sh（写入执行件, 不计入 7 正文, 供 K3 审 SQL 拼接安全性）

> Zen 令: events_schema.sql 覆盖表契约; events_write.sh 逻辑薄但 SQL 拼接安全性可审, 故放附录.
> 源: `tools/patches/p0/events-table/events_write.sh` (零改).

```bash
APPA_EOF
cat tools/patches/p0/events-table/events_write.sh >> "$OUT"
cat >> "$OUT" <<'APPA_EOF'
```

---

## 附录 B — v4.3.2 变更清单 (M1-M7 各一行, 注锚点)

| 标记 | 改造 | 锚点 | 裁断依据 |
|---|---|---|---|
| **M1** | 限流随存活 key 数动态推导(替换 v4.3.1 固定档 28/3/2200) | init 行148-171 | 三式逐字 baseline-4.2.3 行134-140: `_RPM=alive*per_key cap 300` / `_CONCURRENT=alive*per_key_conc floor 3` / `_MIN_INTERVAL=60000/_RPM`. 驱逐 NIM_FIXED_* 三个固定覆盖 env(故障原型). |
| **M2** | maxWaitMs 四字段读回断言对齐(旧注"28/1/2200 三字段"残留清除) | init 行636-662 | 现状 maxWaitMs=300000 已落; M2 修注释+留 K3 题4(若 API 静默丢字段严格断言误 FATAL). |
| **M3** | probe_nim_keys_real 真探活 + auth_dead 跳注册 | init 行538-623 | 403判死/429判活/余活 fail-open; INDEX 递增编号不塌; baseline-4.2.3 无此件=全新增量. |
| **M4** | 压缩全局关闭 | init 行688-694 | PUT 体仅 `{"enabled":false}`; 不留 defaultMode/autoTriggerTokens(防"0阈值=全压"反向). |
| **M5** | 横幅版本对齐 | init 行5-8/829 | 顶注 v4.3.0→v4.3.2; jq `--arg version "4.3.2"`. |
| **M6** | (跳过) | — | Zen 授权可选跳. |
| **M7** | 请求级超时 env 注入 | entrypoint 行24-40 | `DEFAULT_REQUEST_TIMEOUT_MS=${:-180000}`(Zen 签名)+ `REQUEST_TIMEOUT_MS`(上游真识别变量名 runtimeTimeouts.ts:75)双注. **gate.js 零 diff**(GATE_UPSTREAM_TIMEOUT_MS=30000 解冻后走 env 调, 列 K3 题5). |

---

## 附录 C — 验收标准(启动日志七行核验表)

**9 key 预期** (Zen 验收签名):

| # | 日志签名 | 预期值 |
|---|---|---|
| 1 | `[init] 动态限流 RPM=... concurrent=... interval=...` | RPM=300 concurrent=27 interval=200ms (alive_keys=9) |
| 2 | `[init] probe_nim_keys_real: 串行探活...` | 见逐 key 判读行 |
| 3 | `[init] probe key#X: HTTP YYY → alive/AUTH_DEAD` | 9 行判读 (403 入 auth_dead, 余判活) |
| 4 | `[init] probe 汇总: alive=... dead=...` | alive+dead=9 |
| 5 | `[init] nim-XX ...` | 死 key 见 `skip (probe AUTH_DEAD)`; 活 key 见 `OK/exists/HTTP` |
| 6 | `[init] Keys: ... registered, ... skipped, ... failed. (probe: ... alive / ... dead-skipped)` | registered+skipped+failed=9 |
| 7 | `[init] Compression globally disabled...` + `[init] Compression HTTP 200` | 全局关 + 200 |

**Resilience 读回**: `[init] Resilience 读回: RPM=300 minMs=200 concurrent=27 maxWaitMs=300000` + `[init] ✓ Resilience 读回全字段一致 (300/27/200/300000 已落定)`.

**candidate 未触铁证**(本稿生成前后核):

```
开工时间戳: 2026-07-22T13:03:23Z
冻结令起点: 2026-07-21 03:16Z
find candidate-v4.3-reviewed/ -newer 冻结令起点 -type f → 空 (整个冻结窗内 candidate 零写入)
candidate 7件 mtime 与开工前逐字一致:
  2026-07-20 23:13:37  init-nim-keys.sh
  2026-07-20 23:20:38  entrypoint-merged.sh
  2026-07-13 10:49:51  gate.js
  2026-07-19 17:47:43  litestream.yml
  2026-07-22 15:58:35  parseRetryAfter.ts
  2026-07-22 15:59:28  backoffAndDedup.ts
  2026-07-22 16:03:12  events_schema.sql
改动量精确: 仅 staging 的 init+entrypoint sha 变(fcea7168/e0ca1ec源 cea2b20/bc27627); gate/litestream/P0 三件零变动.
```

---

## 附录 D — 审阅结论页模板(K3 直接回填)

> 按文件留 verdict: `pass` / `pass-with-comment` / `block` + blockers 清单.

| 序 | 文件 | verdict | 备注/blocker |
|---|---|---|---|
| 1 | init-nim-keys.sh | __________________ | |
| 2 | entrypoint-merged.sh | __________________ | |
| 3 | gate.js | __________________ | |
| 4 | litestream.yml | __________________ | |
| 5 | parseRetryAfter.ts | __________________ | |
| 6 | backoffAndDedup.ts | __________________ | |
| 7 | events_schema.sql | __________________ | |
| A | events_write.sh | __________________ | |

**Blockers 清单**(K3 填):

- [ ] ___________________________________________________________________
- [ ] ___________________________________________________________________

---

## 给 K3 的审阅问题清单(十题, K3 逐条 yes/no + 一句理由)

1. 动态限流公式(`_RPM=alive×35 封顶300` / `_CONCURRENT=alive×3 保底3` / `_MIN_INTERVAL=60000/_RPM`)在 9 key 场景读出 300/27/200, 推导与 clamp 边界是否正确?(对照 baseline-4.2.3 行134-140 逐字)
2. probe_nim_keys_real 分类表(403判死/429判活/其余判活 fail-open)是否有误杀或漏杀场景?串行 5s × 最多 25 key 最坏启动耗时 125s 是否可接受?
3. 注册循环 auth_dead 跳过的 INDEX 递增与编号空洞处理(nim-XX 缺口=死 key 位置)是否正确?
4. 3.8.43 的 `/api/resilience` PATCH 是否确实持久化并回显 maxWaitMs?若 API 静默丢弃未知字段, M2 四字段读回断言会误 FATAL 卡死部署 — 请确认, 若不确定建议该字段断言降级为 warn.
5. **DEFAULT_REQUEST_TIMEOUT_MS=180000 注入后, 请确认 gate GATE_UPSTREAM_TIMEOUT_MS(行30 默30000)的运行时生效值(env 覆盖与否)及其映射语义(proxyTimeout 响应总时限 vs socket 不活跃超时) — 若确为 30s 响应硬超时, 122s 级长思考请求经 gate 如何完成?**(注: 上游真识别变量名为 REQUEST_TIMEOUT_MS 见 runtimeTimeouts.ts:75, 本稿双注, gate 零 diff 留解冻后 env 调)
6. DEFAULT_REQUEST_TIMEOUT_MS=180000 与 gate 上游超时对齐后, 是否还需联动调其他超时(litestream/Space 健康窗)?
7. init 中 mapfile / here-string / 进程替换 `< <(...)` 在镜像实际 bash 版本下是否全部可用?
8. 压缩全局关闭(enabled:false)后, 既有会话与 per-combo 再启用路径是否无回归?(defaultMode/autoTriggerTokens 库内惰性留存, per-combo 启用路径不受影响是否成立)
9. **新增两段(M1 公式行148-171 / M3 probe+跳过行538-623)与既有段落变量命名与执行顺序无冲突?特别是 `_ALIVE_KEYS` 唯一定义点(行144 配置层预取)、probe 调用(行596)早于注册循环(行600)。probe 判死 key 后 `_ALIVE_KEYS` 不重算 — M1 RPM 仍含死 key 的 per_key 配额(配额虚高+处置率低), 此有意保守是否可接受?或需 probe 后 redefine 重算 RPM?**
10. **M3 的 fail-open 分类(仅 403 判死)在 boot 时上游 5xx 抖动场景下是否符合你对可用性边界的预期?**(fail-closed 会放大一次抖动成全停; fail-open 由运行时熔断兜底瞬态)

---

*文档终. cg52 v2 生成于 2026-07-22 冻结令窗口内, staging 路线. 7 件全文逐字嵌入(脚本 cat 读出, 非手抄, 防字节错配).*
APPA_EOF

echo "[phase3] 附录 A-D 已 append"
echo "[phase3] OUT 终行数: $(wc -l < "$OUT")"
echo "[phase3] OUT 字节数: $(wc -c < "$OUT")"