# omn 日志健康报告脚本 — 使用说明

> 建档: CodeBuddy @ nexus.zen/omn · 2026-09-10
> 脚本: `tools/omn_health_report.py`
> 关联: `docs/ops/k3-故障诊断-2026-09-10.md` · Issue #6

## 1. 它是干什么的

一个**只读**日志分析工具, 扫 omn 网关运行日志, 按模型给出健康报告:

- 按模型分组: 请求数 / 成功率 / 平均时长 / 502·503·504 / 400 / 超时 / 假 200 分布;
- 聚焦某模型 (默认 `kimi-k3`) 面板: 近 24h 错误率 **纯文本 ASCII 曲线** + 连续失败段 + 假 200 占比;
- 输出中文 Markdown 到 stdout, 由调用方决定怎么用 (不推任何外部)。

## 2. 只读纪律 (为什么可以放心跑)

- **不写任何仓内文件**: 全程只 `open(..., 'r')`, 无写盘、无临时文件;
- **零 eval 栈耦合**: 只用 python3 stdlib (`argparse/collections/datetime/glob/json/os/re/sys/bisect`),
  不 import 仓内任何模块, 不碰 `logic/`、不碰上游 eval 栈;
- **零网络请求**: 不发 HTTP, 不读密钥。

> 生产环境日志挂在 `/data/backups/logs/save` (Bucket 直写终态), 脚本只读它。

## 3. 怎么跑

```bash
# 自动探测日志目录
python3 tools/omn_health_report.py

# 指定日志目录 (自动探测失败时)
python3 tools/omn_health_report.py --log-dir /data/backups/logs/save

# 聚焦某模型
python3 tools/omn_health_report.py --model kimi-k3

# 额外输出机器可读摘要到 stderr (便于接监控/管道)
python3 tools/omn_health_report.py --json

# 用内置样本自证口径 (不需要真实日志)
python3 tools/omn_health_report.py --selftest
```

参数:

| 参数 | 说明 |
|---|---|
| `--log-dir PATH` | 指定 save/ 日志目录, 缺省自动探测 |
| `--model NAME` | 聚焦面板的模型名, 默认 `kimi-k3` |
| `--json` | 额外把摘要以 JSON 打到 stderr |
| `--selftest` | 内置样本自测, 全绿 exit 0 |

## 4. 日志目录探测顺序

1. `--log-dir` 参数
2. 环境变量 `$OMN_LOG_DIR`
3. `/data/backups/logs/save` (生产 Bucket 挂载终态)
4. `/data/logs/save`
5. `<cwd>/logs/save`

期望结构:

```
save/<gate|app|ft|init>/<北京时间>_<epoch>.log    # JSONL, 新格式
save/gate.log  save/app.log                       # 早期平铺三段件 (兼容)
```

找不到目录 / 目录为空 / 全是非 JSON 文本时: 打印中文指引后 `exit 2`, **不抛 traceback**。

## 5. 两个关键口径 (报告里都写明了)

### 5.1 模型归属: gate 行不带模型名

gate 请求日志里没有模型字段, 模型名只出现在 **app 源** 的路由行。所以:

- 一级归属: app 路由行 → 按时间窗 **±1.5min** 关联最近 gate 行;
- 二级兜底: 窗口内只对应单一模型的 gate 行 → 继承该模型 (标 `approx`)。

报告**如实打出归属率与 approx 行数**, 不隐藏不确定性。

### 5.2 假 200 = 语义缓存命中, 不算可用性

上游 `semanticCache.ts` 要求**显式 `temperature: 0`** 才能命中/写入缓存。
所以 "1-5ms 的 200" 是探活/健康检查流命中缓存的假象。

**判据 (只认确证, 不用耗时猜)**:

- 行内**确有** `temperature` 字段且 `=0` 且 200 且极短耗时 → 判**假 200** (可确证);
- 行内**有** `temperature` 但 `!=0` → 明确**不是**假 200 (缓存要求显式 0);
- 行内**无** `temperature` 字段 → 判**"无法判定"**, 单列计数 `false200_undecidable`,
  **不计入假 200 分子**。

> ⚠️ **为什么不能按耗时近似判 (2026-09-10 修正)**
> 真实 gate 日志行 schema (`docs/audit/2026-08-01-save-log-full-analysis.md` L34) 为
> `ts/level/component/stage/requestId/method/path/upstream_path/upstream_target/`
> `elapsedMs/httpStatus/msg` —— **本就不含 `temperature` 字段**。
> 早期实现"无字段则按 `200 且 elapsedMs<=50ms 且推理端点` 近似判"会把这个对
> **全部**真实行都成立的组合判成假 200: 实测同一批样本里 12ms / 45ms 的**正常快 200**
> 全被误判 → 5/5 = "100% 假 200" 的假红旗。
> 即"正常快回答"被系统性污染成"缓存假成功", 与工具立意 (防被 1-5ms 的 200 糊住) 恰好相反 ——
> 它会**制造**该错觉。故近似路径已移除。

报告固定提示: 可确证的这批 200 由缓存直回, **不构成可用性证据**; 并如实打出"无法判定"条数。
口径同 `k3-故障诊断-2026-09-10.md` 的 L3。

## 6. 关于 combo 池

`kimi-k3` 在 `nim-pool` combo 池内 (`logic/init-nim-keys.sh` TIER_STABLE)。
客户端若**不带模型名**直打 combo, 真实流量会落在池级行, k3 面板抓不到样本 ——
此时报告会直接提示改用 `--model nim-pool`。这是归属口径所致, 不是 bug。

## 7. 输出样例 (节选)

```
| 模型 | 请求 | 成功 | 成功率 | 平均时长 | 502 | ... | 超时等效 | 假200 |
|---|---|---|---|---|---|---|---|---|
| kimi-k3 | 12 | 4 | 33.3% | 5ms | 8 | ... | 8 | 4 |

**kimi-k3** 近 24h 错误率曲线 (按小时, 北京时间):
  0.8|                █
  0.6|               █████
  ...
连续失败段: `09-10 15:14:12` 起 8 次, 跨度 540s, 码={502: 8}, avg=241000ms → 本侧等满窗
假 200 占成功比: 1/5 = 20.0%
其中 4 条成功响应无 `temperature` 字段 = 无法判定, 未计入分子 (不构成可用性证据)
```

## 8. 验证

- `--selftest`: 造样本自证, **11 项全 PASS, exit 0** —— 含回归用例
  「无 `temperature` 字段的 12ms / 45ms 正常快 200 **不得**被判成假 200」;
- 六种输入形态实测: 新子目录格式 ✅ / 旧平铺三段件 ✅ / 空目录 exit 2 ✅ /
  仅非 JSON 文本 exit 2 ✅ / 不存在目录 exit 2 ✅ / 无参数无候选 exit 2 ✅。

## 9. 修订记录

- **2026-09-10 · 修正假 200 判据 (本版)**: 移除"无 `temperature` 字段则按耗时近似判"路径。
  真实 gate 日志 schema 不含 `temperature` 字段 → 旧近似判会把全部正常快 200 误报成
  缓存假成功 (实测 5/5="100%")。改为**只认确证** (`temperature=0`), 无字段标"无法判定"单列计数。
  自测扩到 11 项并含回归用例。
