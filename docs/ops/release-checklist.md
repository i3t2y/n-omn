# Release Checklist · omn 切换/上线验收

> 每次部署变更后逐条打勾。任一不过 = 不上线。证据贴进对应 ops/incidents/ 或 boot 记录。

## A. Boot 健康(每次必过)
- [ ] A1. boot 九段全执行: 7 registered → gc_stale → Fetching provider IDs
        → Provider IDs → Resilience PATCH(读回一致) → combo upsert
        → model register(override applied) → hf_snapshot → init rc=0
- [ ] A2. R2 restore 正常("已从 R2 恢复" 或 首次部署有明确说明), 无 quick_check 失败
- [ ] A3. 版本比对 EXPECTED_VERSION 一致(或差异有预期说明)
- [ ] A4. gate listening + healthz 200

## B. 请求面(切换/大改必过)
- [ ] B1. 一笔正常 /v1 请求 200, call_logs 有记录
- [ ] B2. 一笔 >1.5MB body 请求被 gate 413 拦截, call_logs 零记录(零足迹), stdout 无 fallback
- [ ] B3. 一笔长思考请求(首 token 静默 >30s)完整走完, 不被 gate 切断
        (GATE_UPSTREAM_TIMEOUT_MS=180000 生效证据)
- [ ] B4. 池成分健康: 请求矩阵四笔全绿 = nim-pool ≥2 笔成功 + nim-codex ≥1 笔成功
        达成路径 = 从意向上线模型池剔除挂/极慢模型 (probe 探活只测 glm-5.2 单模型,
        挂模型 init 期无感知, 须 matrix 实测暴露; pool p2c 随机命中染慢, codex priority
        钉首模型若挂则 100% 掉)。2026-07-25 ② 验出: gpt-oss-120b / llama-3.3-70b 上游
        挂/极慢致 pool 25% 染慢 + codex 100% 超时, 剔除后复跑 matrix 到双 combo 绿。
        must 而非 could: 池成分原样晋级 ③ = 已知坏成分带进生产。
        post-② 不变律: ③ 之后每次池变更按此过闸 (Zen 2026-07-25 裁决五)。

## C. 持久化(切换必过)
- [ ] C1. litestream replicate 进程存活, 无静默停止
- [ ] C2. R2 副本 txid 推进(compaction/同步日志)
- [ ] C3. (切换场景) 新旧 Space 不同时在线写同一 bucket

## D. 收尾
- [ ] D1. ops/STATUS.md 更新(部署=commit, 验证时间)
- [ ] D2. 新锁定决策已追加 docs/DECISIONS.md
- [ ] D3. 旧环境冻结保留期明确(默认1周)再退役

## M. 迁移日(③④⑤ 专用)
- [ ] M1. 20129 幽灵: 只读定位(strings 粗筛表名→定点SELECT确认)→定点UPDATE清除
        → litestream 同步绝育; 禁全库 LIKE 盲删
- [ ] M2. 限流双层盘点: init Resilience(预期300/96, 32 key 基线 = 32×3) 与 requestQueue(28/1)
        是否都在生效、是否都有意为之, 结论写 HANDOFF
- [ ] M3. 上线首24h: 风暴特征串计数=0 (FALLBACK MODE / all accounts
        unavailable / Preserving last upstream error)
