# #16 短链分流 (route-split) 验收证据 — 2026-09-11

> 对应 Issue #16 / PR「feat(gate): 调用前缀/路径分流」。
> 取证方法沿用 `docs/research/omn-deploy-incident-2026-09-11/tools/README.md` 的三通道约定。

## 交付物

| 文件 | 变更 |
|---|---|
| `logic/route-split.js` | 新增 (纯函数, 零依赖, 零 I/O) |
| `logic/gate.js` | 接线 (require + 配置常量 + proxyV1 lane 判定 + logGate 增量字段) |
| `logic/entrypoint.sh` | 显式导出 `GATE_ROUTE_SPLIT_ENABLED` / `GATE_ROUTE_SPLIT_STRICT` |
| `logic/tests/route-split.test.js` | 新增 11 例 (纯函数) |
| `logic/tests/route-split.e2e.test.js` | 新增 5 例 (起真 gate + 假上游) |
| `.github/workflows/sync-logic-xnexus.yml` | 清单 9→10 (上传段 + 回读校验段) |
| `space/start.sh` | 清单 9→10 (boot 拉取段) |
| `docs/ops/DECISIONS.md` / `docs/ops/STATUS.md` | 决策条 + env 表 |

## 证据清单

| 文件 | 通道 | 内容 |
|---|---|---|
| `ev-selftest-route-split.txt` | 自检 | route-split 16 例 (11 单测 + 5 e2e) 全绿 |
| `ev-selftest-full.txt` | 自检 | 全量 48 例 (32 既有 + 16 新增) 全绿 |
| `ev-probe-audit-log.txt` | **B** | 起真 gate, 三次 probe 请求 → 审计行 `lane=probe` 逐字 |
| `ev-manifests-readback.txt` | **C** | 三处清单实读 + 文件集互 diff 一致 (10 件) |

## B 通道要点 (审计行形态, 可直接 grep Space 日志)

```json
{"level":"info","component":"gate","abortSource":"gate_route_split",
 "method":"GET","path":"/v1/models","lane":"probe","route_reason":"probe_exact",
 "msg":"lane=probe route_reason=probe_exact"}
```

Space 日志核对命令 (boot 后): `grep -c 'lane=probe' <run.log>`。

## C 通道要点

三处清单 (sync-logic 上传段 + 回读校验段 + start.sh boot 段) 文件集**逐字同集**,
`route-split.js` 三处齐在; 互 diff 为空。事故 (漏件) 的根因面已被同一校验法覆盖。

## 验收对照 (Issue #16)

- **rule ≥ 0.82 / judge ≥ 0.82**: 交河图评测 (合并后 CI 触发; 本 NPC 不自评)。
- **gate regression 不破**: `GATE_FALLBACK_*` env 行零改; `gate-fallback.e2e.test.js` 6 例全绿;
  新增 e2e 专门断言「inference 仍受保护 (POST 失败达上限 → 502)」。
- **合并后 GHA + bucket 校验**: 留待合并后观察 `[start] Bucket 校验通过 (n-omn@… 10 件 sha256 全对)`。
