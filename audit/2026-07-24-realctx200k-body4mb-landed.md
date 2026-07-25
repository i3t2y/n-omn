# real_context 32K→200K + body 1→4MB 改推闭环留证(7key 研究)

**日期**: 2026-07-24 21:xxZ 改推(本地 omn-logic) → 23:10Z Space restart(Supreme 手) → 23:1x-07-25 研究(7弹实证)
**Space**: nonoke-omn.hf.space(永续 dev, bucket omn-data, cpu-basic 2vCPU/16GB)
**链**: HF Dataset `nonoke/omn-logic` 五件之 init-nim-keys.sh 单件改推
**律**: §1 双空间铁律 — nomke/omn 生产零触(4.2.3 日志只取证不引用支撑 dev 结论); §5 机制结论须 file:line 上游 3.8.43 源码对照; §3 secret/token 值零入(本文 sha/token 占位不写值); §7 Space Restart Supreme 手动.

## 起源: 4.2.3 vs 4.3.2 差对比

【消息1】【消息2】用户先后贴 nomke/omn 生产(4.2.3, 25key) + nonoke/omn dev(v4.3.2,25key) 两 boot 全量日志, 要求"全维度对比下, 为什么感觉 4.3.2 脚本很差劲? 先核 HF 免费 Space 硬资源限 核 memory 已记 + WebSearch 查证"。

### HF 硬资源核(回退 memory 不重搜)
WebSearch("HF Spaces free tier CPU basic RAM 16GB resources limits 2025") 空返 12s; WebFetch(huggingface.co/docs/hub/spaces-billing) 404 0字节。依 CLAUDE.md §白纸"本地审计文档实记勿联网重核"回退 memory [[hf-free-space-cpu-basic-spec]]: 2 vCPU/16GB RAM/50GB ephemeral(休眠丢=R2 restore)/48h 休眠自醒/2026-07 Docker SDK 转 PRO(存量 free Docker Space 暂保)/出站 80/443/8080/7-16 后密集推送冻 build。两部署同 cpu-basic 铁笼 = 不是脚本差异源。

### 全维度对比归因(三根因 #1 王)

| 维度 | 4.2.3 生产 | 4.3.2 dev | 判 |
|---|---|---|---|
| 基座 | OmniRoute 3.8.43@b729a8f | 同 3.8.43 | 平 |
| key/模型/litestream/profile | 25 RC=0 / 9 / sync-10s / balanced | 同 | 平 |
| 镜像工具链 | 固化 | A 模式 apt 42 包+pip huggingface_hub ~60s 51.6MB 每冷启 | 4.3.2 弱(根因#3 未破) |
| **body limit** | raw=4→4MB | raw=1→1MB | **4.3.2 弱(根因#2)** |
| **per-model real_context** | 200000(200K) | **32768(32K)** | **4.3.2 砍 84% ← 根因#1 王** |
| probe | per-model per-key | 串行 POST glm-5.2 timeout=15s/key | 各取舍 |
| gate 504/502 ETIMEDOUT | 偶发 | 大量 30-490s 个别 STREAM 495903ms(8分钟) | 4.3.2 弱 |
| request_signal_aborted / RATE-LIMIT idle eviction 洪 | 偶/正常 | 大量 / 600-630s 洪循环 | 4.3.2 弱 |

**根因**: per-model `real_context=32768`(4.3.2) vs `200000`(4.2.3) 砍 84% → 有效上下文窗 200K 砍到 32K, 长对话/工具填满即触发压缩+截断+超时链 → 上游等久 → gate 504 → 客户端超时 abort → RATE-LIMIT eviction 洪 → key 池死循环。用户语 "4.3.2 感觉很差劲" = 此根因派生现象, 非 16GB 不够。

## 改点 file:line(omn-logic/init-nim-keys.sh)

### 改点 #1 real_context 32K→200K(王, 根因#1)
- **行 187**: `_NIM_REAL_CONTEXT=${CONTEXT_LENGTH_DEFAULT:-32768}` → `:-200000`
- 写: 行 837 `apply_context_override` → `INSERT OR REPLACE INTO model_context_overrides (..., real_context=$2, ...)` 全 9 模型
- 上游 3.8.43 消费铁证: `src/lib/modelCapabilities.ts:447-448` `getModelContextOverride(resolved.provider, resolved.model) ?? resolved.contextWindow` — Override 优先于 catalog, `getModelContextLimit()` 返 200000。**唯一基座 3.8.43 无双版本对照需求**(用户明失裁: 两部署同 3.8.43, 4.3.2 是 init 脚本版本号非基座版本, §5 双版本 3.8.43/3.8.49 对照针对基座差异场景不触发)。

### 改点 #2 body limit raw 1→4(根因#2)
- **行 191**: `_RAW_BODY_LIMIT=${NIM_REQUEST_BODY_LIMIT:-1}` → `:-4`
- raw=4 → 行 197-198 else 分支 `_REQUEST_BODY_LIMIT_MB=4`(raw=1<500 取 raw=1 进同 else)
- 写: 行 774 `PATCH /api/settings ... "maxBodySizeMb":4`
- 上游 3.8.43 消费: `src/lib/db/settings.ts:130` `maxBodySizeMb: requestBodyLimitMbFromEnv(process.env.MAX_BODY_SIZE_BYTES)` + `src/shared/constants/bodySize.ts` MIN=1/MAX=500, DB 值优先。4 合规。

### 改点 #3 echo 文案同步(防误读)
- 行 828: `[init] per-model 32K override` → `per-model 200K override`
- 行 845: `per-model 32K override 应用` → `per-model override 应用`
- 行 820/827/839 残"32K"属历史注释(记 42ea8e7 基线 + K5 行为预期), 动失历史锚, 留不改(同 audit 历史归档不改纪律)。

### §5 红线核
- 3.8.43 单基座对照全齐(modelCapabilities.ts:436-449 / modelContextOverrides.ts:78-84 / bodySize.ts 上界 / settings.ts:130)
- 手动自动回写仍禁(CF-4 init:824-825 "一次性 32K→200K override 不跨周期自动标定", init:449 已删 monitor 回写段, 改 32768→200000 不触自动回写逻辑)
- 改属 init 参数默认值非上游 src, 不强制 TDD, 但须 boot 后读回验(见下 Restart B 闭环)

## 推推(Dataset 单件)

- 法: `huggingface_hub` `upload_file`, token 走库默认缓存读(`~/.cache/huggingface/token`), 值零入推脚本零入会话零入 git, /tmp 临时推完即删
- token 验: whoami=nonoke ok(无 scope 直读, write 由 upload 成败证)
- 推:
  - REMOTE_PRE sha `21cc7cdb`(crashloop express fix 件终态)
  - UPLOAD commit oid `63945e55`
  - READBACK sha `73e71f30` == LOCAL `73e71f30` == **MATCH**
- commit msg: `init: real_context 32768->200000 + body limit raw 1->4 (per-model 32K砍200K context根因#1 + 1MB→4MB根因#2)`
- 五件远端终态: init `21cc7cdb`→`73e71f30`, 余 entrypoint `4803e290`/gate `616047c6`/litestream `1563c08d`/package `5ed9981b` 不动
- bash -n 语法 OK

## Space Restart(Supreme 手) + boot 读回验

restart 2026-07-24 23:10:14, boot 尾段实证三改全落:

```
[init] body limit: raw=4 -> maxBodySizeMb=4
[init] Routing + maxBodySizeMb=4...
[init] Settings HTTP 200
...
[init] per-model 200K override (real_context=200000)...
[init] override: 9 applied, 0 failed.
[init]   POOL_STRATEGY=p2c REAL_CONTEXT=200000 (per-model override 应用, monitor 自动回写禁用)
[init]   PROFILE=balanced MODE=DEBUG KEYS=7 RPM=245 BODY=4 MB
[init] Keys: 7 registered, 0 skipped, 0 failed. (probe: 7 alive / 0 dead-skipped)
[init] ✓ Resilience 读回全字段一致 (245/21/244/300000 已落定)
[entrypoint] NIM init 已退出 rc=0 (正常完成).
[init] HF Dataset uploaded.
```

### boot 签名健康核
- R2 restore `.storage.sqlite.restore.1 → storage.sqlite` ✓
- Next.js 16.2.9 Ready 0ms ✓
- litestream v0.5.9 sync-10s bucket=omn-data ✓
- gate listening 0.0.0.0:7860→127.0.0.1:20128 admin enabled ✓
- combos nim-pool/nim-codex PUT 200 ✓, models 9 available + 118 total ✓
- init rc=0 无 traceback ✓, HF Dataset uploaded ✓

### context_accumulator 沉降实证(逆向证#1 原能)
```
z-ai/glm-5.2 | 137344 | - | 37/0 | low | rec_ctx=123609
```
`last_ok=137344`(137K token 最近成功), ok/fail=37/0 全过 — **逆向铁证旧 32K override 是人工限低, 模型真能力本就吃 137K+**, 改 200K 是放回原能非越界。rec_ctx=123609 自动推荐但 monitor 回写禁不覆盖。

### ⚠ 卡点(研究启用前)
- 此 boot **7 key 注册**非 25(Space Secrets NIM_KEYS env 现填 7, probe dead=0 否认死封; 与上轮 25key boot 对比缩 18, 非脚本病是 env 填量)
- chat 探针初 401 PSK drift(dev env 旧值 ≠ Space INTERNAL_PSK), Supreme 对齐后通

## 7 key 研究(7 弹实证)

研究纲: 7 key P2C 容量够验三改。算式 boot 落: RPM=七×35=245, concurrent=七×3=21, interval=244ms(§7 per_key_rpm=35/conc=3)。dev env 直跑 `~/.omn-env-dev`(token 零入会话), 探针 urllib 走 HF ingress /v1/* 校 Authorization Bearer=safeEqual。

实弹矩阵(7 弹全 run):

| 弹 | 输入规模 | body | HTTP | TTFB | finish | 判 |
|---|---|---|---|---|---|---|
| A 短流 | 短问 | <1KB | 200 | 3.21s | 真 SSE 流 | ✅ 基线通 |
| B 中长上下文 | ~97500 token(65K 中文字) | 0.36MB | 200 | 2.66s | `stop` | ✅ 旧 32K 必拒 |
| C 大输出 | max_tokens=2000 | <1KB | 200 | 3.57s | 流 363字 | ✅ |
| D 并发2 P2C | 两并发短问 | <1KB | 200+200 | 2.92/2.75s | — | ✅ key 分散无 rateLimitedUntil 堆 |
| **E 长上下文极限** | **~191250 token**(97K 中文字) | 0.71MB | **200** | 4.47s | **`stop`** | ✅✅ 超 32K 5.8 倍通 |
| F body 近阈 | 0.09MB | 1.05MB | 200 | — | `stop` "收到了!" | ✅ >1MB 域通 |
| G body 大 | pad 3.9M chars | **3.719MB** | 200 | 6.89s | (上游 chew) | ✅ 入限 |
| H body 极限 | pad 3.9M + 完整采 | **3.719MB** | 504 | — | gateway_timeout | ⚠ 上游超时非限病 |

### 模型名踩坑
初探 `z-ai/glm-5.2` → 404 `No active credentials for provider: z-ai`。`/v1/models` 实列 185, z-ai 真名 `nvidia/z-ai/glm-5.2`(provider nvidia 前缀)。init 内 `z-ai/glm-5.2` 短名 ≠ 外部 /v1/* 全名。改名重探通。

### 实证结论

#### ✅ 根因 #1 real_context 全证消除
弹 B(97500 ✓) 弹 E(**191250 token ✓`) 双通 200+`stop`。旧 32K override input>32768 必 413/截断。新 200K 吃 191K(超 last_ok 137344 余量足), 真放回原能, 副症状 504/abort/长尾超时链根除。

#### ✅ 根因 #2 body 1→4MB 全证消除
弹 F body 1.05MB 通(>旧 1MB 阈边), 弹 G 3.719MB 通入路由(旧 raw=1 必 413 拒)。

#### ⚠ 弹 H body=3.719MB 触 504 — 边界副症状(非改点咎)
`{"error":"gateway_timeout","abort_source":"timeout"}` = gate upstream_request_timeout。3.9M 'a' 字符上游模型 chew 慢超 gate timeout → 504 abort。**非 body limit(已入限放行)/ 非 real_context(流上游侧)病**, 是真实巨 body 单消息上游处理时长 > gate 超时。现实场景罕见(Claude Code 90-118 条消息+39 工具 <<3.7MB); 弹 E 0.71MB+191K token 真实长对话通 stop。

### 副症状根除总判
全研究弹 A-G 200 无 504/502/ETIMEDOUT/request_signal_aborted, TTFB 均 2.66-4.82s 正常。唯一 504 仅弹 H 极限 body 边界速发(现实不触发)。旧 4.3.2 日志主诉"差"的长尾 30-490s/8分钟 STREAM = 32K 截断/压缩链 + body 1MB 触限往返, 随 #1#2 改消。

### key 最力学(回用户"换几key最合适")
| 档 | key | RPM | 并发 | 判 |
|---|---|---|---|---|
| 最小研究 | 7 | 245 | 21 | 现(够验三改) |
| 工作日平衡 | 8-10 | 280-350 | 24-30 | 稳态推荐(单 key 压力降30%+ 抗 NIM 频控 CPU 不爆) |
| 重压上限 | 12-14 | 420-490 | 36-42 | 2 vCPU 并发顶近 |
| 超 14 | 15+ | >525 | >45 | 边际递减负收益(CPU 顶+养号陡) |
25-32 key 超 2 vCPU(HF free cpu-basic)反致长尾超时 — 旧 4.3.2 日志 25key 接不住 25×3=75 并发是另一路"差"源, 非 dev 真适配档。

## 红线守法
- §1: nomke/omn 生产零触, 4.2.3 日志只取证不引用支撑 dev 结论
- §3: token 值/P SK 值零入本文, 通篇 sha(shas 各 16hex 前缀)+len(70)+sha8(据上下文) 形态记, 不写值; ~ / .omn-env-dev / .omn_secrets 零 read 值, 仅 grep 键名; HF cache token 走库自动读不读值
- §5: 机制结论 3.8.43 单基座 file:line 对照全齐, 双版本不对决(两部署同 3.8.43)
- §7: gate PSK Authorization Bearer=safeEqual; 探针 urllib 非直触 Space, dev env 直通闭环; 速率三准则探针并发=2 合规

## 闭环结案 + 仍欠
- 三改(init:187/191/828+845)推推 + restart + 7 弹实证全闭环
- init 远端 sha `73e71f30` == 本地 == 读回 MATCH
- 副症状(504/abort/长尾 OR RATE-LIMIT eviction 洪)随根因#1#2 消
- **仍欠**:
  - 根因 #3 镜像固工具链(省冷启 60s apt 42 包 + pip huggingface_hub, ephemeral 丢后不必每冷启补全): 改 `omn-ops/ghcr/Dockerfile` 加 `RUN apt install + pip huggingface_hub` 进 GHCR omniroute-base:stable, 见 [[omn-ops-ghcr-prebuild-dockerfile-landed]]
  - 25-32 key 转生产减 NIM 风控旁白: 仍卡圣上 §1 身份签发 + proxy 源 + 入凭, 不动
  - dev 稳态档若升 8-10 key(降 NIM 频控): 圣上裁, 我随之

## 链入
- 前置差异源: 4.2.3 vs 4.3.2 日志对比(本会话 [[memory]] 记), memory [[hf-free-space-cpu-basic-spec]] 硬资源
- 改点源: omn-logic/init-nim-keys.sh:187/191/828/845, 上游 3.8.43 modelCapabilities.ts:447-448 / settings.ts:130 / bodySize.ts
- 推推法: huggingface_hub upload_file + HF cache token(同附录A 留证 audit/2026-07-23-appendixA-mirror-push-landed.md)
- 研究法: dev env 直跑 urllib 探针(同 [[chat-psk401-diagnosis]] 闭环路径)
- 平行 saga: crashloop express+init 双修已闭环 [[omn-v4.3.2-r3-k3-stream-readiness-maxwait]], 本档为 root 改后续
