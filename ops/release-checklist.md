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

## C. 持久化(切换必过)
- [ ] C1. litestream replicate 进程存活, 无静默停止
- [ ] C2. R2 副本 txid 推进(compaction/同步日志)
- [ ] C3. (切换场景) 新旧 Space 不同时在线写同一 bucket

## D. 收尾
- [ ] D1. ops/STATUS.md 更新(部署=commit, 验证时间)
- [ ] D2. 新锁定决策已追加 DECISIONS.md
- [ ] D3. 旧环境冻结保留期明确(默认1周)再退役

## M. 迁移日(③④⑤ 专用)
- [ ] M1. 20129 幽灵: 只读定位(strings 粗筛表名→定点SELECT确认)→定点UPDATE清除
        → litestream 同步绝育; 禁全库 LIKE 盲删
- [ ] M2. 限流双层盘点: init Resilience(预期300/75) 与 requestQueue(28/1)
        是否都在生效、是否都有意为之, 结论写 HANDOFF
- [ ] M3. 上线首24h: 风暴特征串计数=0 (FALLBACK MODE / all accounts
        unavailable / Preserving last upstream error)
