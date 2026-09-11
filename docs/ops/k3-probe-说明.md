# k3 主动健康探针说明 (tools/k3_probe.py)

> 建档: 2026-09-10 · Issue #7 · 产出 `tools/k3_probe.py` (只读, stdlib-only)
> 设计依据: `docs/ops/k3-故障诊断-2026-09-10.md`
> 定位: 把"k3 出问题"从**事后读日志**变成**事前主动告警**。

---

## 1. 它解决什么

k3 故障诊断结论: 上游真实故障会被三类噪声掩盖 —

| 噪声 | 表现 | 危害 |
|---|---|---|
| 语义缓存假成功 | 固定 query + `temperature=0` → 1-5ms 200 | 监控误判"上游时好时坏" |
| 空 SSE 流 (EARLY_EOF) | HTTP 200 但无内容 | 被计为成功 |
| combo 逐 key 重放 | 单请求 30 次重放, 240s 级 502 | 观测面只有末端 502 |

本探针**单发小请求 + 不设 temperature**, 绕过缓存与重放, 只反映上游真实吐字能力。
连续失败即输出 `K3_DEGRADED`, 恢复即输出 `K3_RECOVERED` — 供外部 cron / 告警消费。

---

## 2. 输出协议

每行一条, 前缀 UTC ISO8601 时间戳, 全部走 **stdout** (零落盘 / 零通知)。

```
# 单次探测 (stream 与非 stream 各一条)
<UTC> PROBE mode=<stream|nostream> ok=<0|1> http=<code|-> ms=<int> verdict=<...> detail=<...>

# 状态信号
<UTC> SIGNAL K3_DEGRADED streak=<n> reason=<...>
<UTC> SIGNAL K3_RECOVERED streak=<n> reason=<...>

# 常驻模式汇总
<UTC> SUMMARY ok=<n>/<total> degraded=<bool>
```

`verdict` 取值: `ok` / `timeout` / `http_error` / `empty_stream` / `empty_content` /
`network_error` / `bad_json`。

**判失败口径** (对齐诊断报告):
- 超时 > 30s (`--timeout`, 默认 30)
- HTTP 5xx
- stream: 无任何非空 `content` delta (空 SSE 只收到 `[DONE]` 或 EOF 即 FAIL)
- 非 stream: `choices[0].message.content` 为空

**状态机**: 连续 3 次失败 → `K3_DEGRADED` (默认 `--degraded-after 3`);
降级后连续 2 次成功 → `K3_RECOVERED` (默认 `--recover-after 2`)。
一轮 = stream + 非 stream 各一发, 两者全成功才算本轮成功。

---

## 3. 用法

```bash
export K3_PSK='<真 PSK>'      # 或 --psk, 或 ~/.omn-secrets 首行
# 也兼容 $OMN_PSK / $K3_PSK_FILE

# 单次探测 (cron 推荐)
python3 tools/k3_probe.py --once

# 常驻轮询 (默认 60s 一轮)
python3 tools/k3_probe.py --interval 30

# 离线演示状态机全生命周期 (不触网, 无需 PSK)
python3 tools/k3_probe.py --dry-run
```

**cron 示例** (输出交采集器, 探针本身不通知):

```cron
* * * * * cd /path/to/omn && K3_PSK_FILE=/etc/omn/psk \
  python3 tools/k3_probe.py --once >> /var/log/k3-probe.log 2>&1
```

**阈值 env 覆盖**: `K3_PROBE_TIMEOUT` / `K3_DEGRADED_AFTER` / `K3_RECOVER_AFTER` /
`K3_PROBE_INTERVAL` / `K3_ENDPOINT` / `K3_MODEL`。

退出码: 健康 `0`; 处于 `DEGRADED` `2`; 参数/环境错误 (如缺 PSK) `3`。

---

## 4. 依赖与安全

- **仅标准库**: `argparse/json/os/socket/ssl/sys/time/urllib` — 零第三方依赖。
- **只读**: 只发 `POST /v1/chat/completions`, 不改任何状态、不写盘。
- **秘密纪律**: PSK 只在内存, 绝不回显 / 落盘 / 入日志; 错误体不回显。
  示例与验证一律用合成串。

---

## 5. 验证证据

本地以 mock 上游 (`http://127.0.0.1:PORT/{ok,slow,err,empty,switch}`) 跑通四场景 + 状态机全周期。

**一键重跑** (不触网 / 不需真 PSK / 零副作用):

```bash
bash tools/mock/repro_k3_probe.sh        # mock 起在 8790, 依次跑四场景 + dry-run + switch 全周期
```

- `tools/mock/mock_k3_upstream.py` — mock 上游本体 (stdlib-only), 含真 SSE 流与 `/switch` 故障转好端点
- `docs/ops/evidence/verify-transcript.txt` — 一轮完整 stdout 复现记录

**内嵌摘要** (完整输出见上文件):

```
$ python3 tools/k3_probe.py --once --endpoint <mock>/ok
... PROBE mode=stream   ok=1 http=200  ms=2      verdict=ok detail=stream_nonempty_delta
... PROBE mode=nostream ok=1 http=200  ms=0      verdict=ok detail=nonempty_content

$ python3 tools/k3_probe.py --once --endpoint <mock>/slow      # 上游长时间不吐字
... PROBE mode=stream   ok=0 http=-    ms=3004   verdict=timeout detail=socket_timeout
... PROBE mode=nostream ok=0 http=-    ms=3003   verdict=timeout detail=socket_timeout

$ python3 tools/k3_probe.py --once --endpoint <mock>/err       # 上游 503
... PROBE mode=stream   ok=0 http=503  ms=2      verdict=http_error detail=http_503
... PROBE mode=nostream ok=0 http=503  ms=0      verdict=http_error detail=http_503

$ python3 tools/k3_probe.py --once --endpoint <mock>/empty     # 200 但空流 / 空回复
... PROBE mode=stream   ok=0 http=200  ms=2      verdict=empty_stream detail=done_without_content
... PROBE mode=nostream ok=0 http=200  ms=0      verdict=empty_content detail=blank_message
```

**生命周期 (3 连败 → 降级, 2 连胜 → 恢复)**:

dry-run 离线演示 (状态机逻辑):

```
... SIGNAL K3_DEGRADED  streak=3 reason=empty_stream
... SIGNAL K3_RECOVERED streak=2 reason=consecutive_ok
... DRYRUN end final_degraded=False
```

真链路 (mock `/switch`: 前 3 轮坏 → 后转好, 走真实 HTTP 调用):

```
... SIGNAL K3_DEGRADED  streak=3 reason=empty_content
... SIGNAL K3_RECOVERED streak=2 reason=consecutive_ok
```

原始逐场景样例:
`sample_s1_healthy.txt` · `sample_s2_timeout.txt` · `sample_s3_http503.txt` ·
`sample_s4_empty.txt`

> 说明: 本轮执行环境无图形能力, 故以**原始 stdout 样例 + 可一键重跑的 mock 脚本**
> 替代截图; 证据为真实执行输出, `bash tools/mock/repro_k3_probe.sh` 可任意次复现。
> 注: `--timeout 3` 用于把">30s 超时"语义在本地压缩复现, 生产默认 30s。

---

## 6. 边界 / 非目标

- 探针**不通知**: 只产信号, 通知由外部 cron 消费 stdout 实现。
- 探针**不落盘**: 无日志文件, 无状态持久化 (状态机仅存内存, 常驻模式有效)。
- 探针**不改** `logic/` 任何代码, 不碰 combo/fallback 策略 (那属诊断报告第五节立项范围)。

## 7. 后续 (待 Zen 定夺)

- [ ] 接入生产 cron + 采集器 (消费 `SIGNAL` 行触发告警)
- [ ] 观测分层: 把 `1024` 缓存命中 / 真上游 200 / 空答 200 分开计数 (报告第五节方向 4)
- [ ] 与 `docs/ops/release-checklist.md` 探针段对齐口径

关联: docs/ops/k3-故障诊断-2026-09-10.md · Issue #7
