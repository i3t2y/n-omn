# 2026-08-01 · Bucket RW mount 热更/Restart 真机制实测勘察

**Zen令**: 2026-08-01 "实测钉 Bucket RW mount 热更/Restart 真机制"。本文档钉官方文档边界(空白处)+底层机制推断 + 现役架构影响面 + 待实测唯一未知数 + 实测方案。

**关联**: [[storage-bucket-dataset-结合堪察]] §11/§12 单择定局 + [[logic-dataset-to-bucket-intent]] (DECISIONS.md 2026-08-01 段迁意记号)。

---

## 1. 官方文档查证边界(三源, 热更语义空白)

**查源**:
- manage-spaces (huggingface_hub/guides/manage-spaces) — 挂载 API + 读写语义
- storage-buckets (docs/hub/storage-buckets) — Bucket 本质 + 用例
- storage-buckets-access (docs/hub/storage-buckets-access) — 访问模式 + mount 实现

### 1.1 三源钉死的(非空白)

| 维 | 钉死内容 | 源 |
|---|---|---|
| 读写 | "Only buckets support read-write mounts" / "Models, datasets, and Spaces are always mounted as read-only" | manage-spaces ⭐ |
| Bucket 本质 | "non-versioned and mutable, overwrite-in-place... deletions are immediate and permanent — no way to recover" | storage-buckets |
| 版控 | 无版控/git history/PR; "Bucket→Repo 回写 without reuploading is not yet available, but is on the roadmap" | storage-buckets |
| mount 实现 | "hf-mount... via NFS (recommended) or FUSE. Files are fetched lazily — only the bytes your code reads hit the network" | access-patterns ⭐ |
| Space volume = hf-mount | "Volume mounts in Jobs and Spaces are the same idea as hf-mount, managed for you by the platform" | access-patterns ⭐ |
| 替换式语义 | `set_space_volumes` "replaces all previously mounted volumes" (须先读 runtime.volumes 拼接) | manage-spaces |

### 1.2 钉空白的关键面(文档不论)

**两源均不述**: Bucket mount 内容何时对运行 Space 进程可见——是 snapshot 固化(boot 时), 还是 live-updated(外部改即见), 还是须 Restart。**此即待实测唯一的真未知数**。

---

## 2. 底层机制推断(基于 NFS 语义, 非臆测)

access-patterns 钉 Space volume mount = hf-mount 托管版, hf-mount 推荐 NFS。NFS 协议语义:

- 客户端 `open()` 文件 → 服务端返回**真实当前态**
- 非 snapshot: bucket 经 API/CI 外部改某件 → 下次客户端 `open()` 同件 → 拿新内容
- 进程**已打开并读入内存的句柄**不热更(已 read 的字节在用户态 buffer)
- 进程**已 mmap 的文件** 行为取决于 mmap 是否走服务端分页(could reflect writes, 取决于 mmap flags + NFS cache coherence)

**推断**: Bucket mount 非 snapshot 固化 → 机制上**支持**外部改后进程重 open 见新态。但是否须 Restart 取决于应用层是否重 open(omn node 一次性 require 不重 open)。

**⚠ 此推断须实测钉**: NFS cache coherence + hf-mount 实际可能加客户端缓存(access-patterns 提"caching"见 hf-mount repo full docs, 未钉语义)。

---

## 3. 现役架构影响面(start.sh 铁证)

### 3.1 现役装八件真路径(download→cp, 非 mount)

`start.sh` 定死现役 `/logic` = **ephemeral, boot 时 download+cp 固化**:

```
L52  [ -n "$LOGIC_BUCKET_REPO" ]   # 变量名含bucket字样, 语义实=Dataset nonoke/omn-logic (历史命名巧合)
L87  hf download "$LOGIC_BUCKET_REPO" --repo-type dataset --local-dir /tmp/logic
L100 mkdir -p /logic
L101 cp -a /tmp/logic/. /logic/    # ← copy 进 ephemeral /logic
L110 exec /logic/entrypoint.sh
```

**现役 Dataset 从未 mount**, boot `hf download`→`cp` 入 ephemeral。故"Dataset 改→须 Restart 生效"病根 = `cp` 固化 + node 一次性 require, 非 mount 冷依赖。

### 3.2 换 Bucket mount 对现役架构的改造面

若换 Bucket mount `/logic`(RW), `start.sh` §3 段(download→cp→rm)整段**删**, 改为依赖 mount 已就绪:

| 段 | 现役 | 换 mount 后 |
|---|---|---|
| L52 校验 | `LOGIC_BUCKET_REPO` | 改 ENV 名或保留复用 |
| §3 取 commit_id 锁 (L66-80) | K3 竞速根治靠此 | **废** — Bucket 无 commit_id, 竞速复活 ⚠ |
| §3 download (L82-96) | `hf download` | 删 |
| L100-103 cp | `cp -a /tmp/logic /logic` | 删, mount 已在 |
| L110 exec | `/logic/entrypoint.sh` | 不变(mount 路径同) |

**改造代价**: K3 竞速根治(commit_id 锁 atomic 同点拉)是现役四件武器之一(私库 n-omn 侧)— 但 commit_id 锁的是 **Dataset 拉取时点**, 换 Bucket 直接 mount **无此锁点**, 若 boot 时 CI 正在 push Bucket 中途, mount 见的是半推态(竞速复活)。

---

## 4. Bucket mount 热更对 omn init/gate 真痛点的实际收益(钉)

Zen真痛点: init/gate 改动现须 Restart 生效(非秒级)。换 Bucket RW mount 后收益逐文件核:

| 件 | 加载方式 | mount 热更后改件生效路径 | 真收益 |
|---|---|---|---|
| **gate.js** | `node /logic/gate.js` 启动 require 一次入内存 (entrypoint L363) | mount 见新态, 但 node 进程已在内存跑旧版 → **仍须重启 node** | ❌ 免 Restart 不成立(仅省 boot 拉件+cp 时延) |
| **init-nim-keys.sh** | `bash /logic/init-nim-keys.sh` boot 一次性 (L294) | mount 见新态, 但 init 只 boot 跑一次 → 须冷启重跑 | ❌ 同 gate, 仅省拉件时延 |
| **helper.sh** | `bash /logic/helper.sh` (L360) | 同 init 一次性 | ❌ |
| **omn_scheduler.py** | `python3 /logic/omn_scheduler.py` 启动加载 (L371) | 同 gate, 进程内存态 | ❌ |
| **litestream.yml** | boot 读 config (L302) | boot 一次性读 | ❌ |
| **package.json** | boot `npm install` (L335) | boot 一次性 | ❌ |
| **omn_redact.py** | scheduler import 运行态 | 进程内存态 | ❌ |
| **entrypoint.sh** | `exec /logic/entrypoint.sh` boot 一次 (L110) | 须冷启重跑整个 entrypoint | ❌ |

**钉死**: omn 八件**全 boot 一次性加载**, 无运行中重读文件逻辑。故 Bucket mount 热更对 omn **无运行中秒级热更收益** — 改任一件仍须 Restart(重启进程重读)。

**真收益只在**: 免 boot 时 `hf download` + `cp` 的时延(约30s-数min, 视 Dataset 大小+HF resolve缓存), 即**冷启加速**, 非运行态热更。

---

## 5. 实测落地范围(2026-08-01 真跑, 免费层封顶)

**Zen令实测 → 真跑到此封顶**。免费层 cpu-basic **无终端/SSH dev mode**(PRO/Team 付费才有) → 无法进 Space 容器硬验 mount 内真态 + 运行中热更性。能做的全做:

### 5.1 已钉死(铁证)

| 项 | 铁证 | 来源 |
|---|---|---|
| bucket 写权限通 | push probe.txt 18B + readback 内容对得上(`v1-test-readwrite-check`) | hf buckets cp 我亲跑 |
| space 配置层挂载真落 | `volumes -> [{'type':'bucket','source':'nonoke/data','mountPath':'/logic-bucket','readOnly':False}]` | get_space_runtime().raw.volumes |
| boot 后 Space RUNNING 无挂载报错 | init rc=0, 32key alive, Resilience 300/200/96/300000 一致, gate PID=188 | Zen贴 boot 日志 06:42:02 |
| hf库1.8→1.26升+set_space_volumes新API在 | pip install -U --user huggingface_hub>=1.26 通 | 我亲跑 |

### 5.2 未钉(免费层无终端封顶, 须 PRO/Team 升级 SSH 才能)

- **mount 内真态**: bucket 推的 probe.txt 是否真在 Space 内 `/logic-bucket/probe.txt` 见(配置层挂上≠Space内真挂通, 中间NFS握手可能失败静默)
- **运行中热更性**: 改 bucket 同件, Space 不重启, 进程重 open 是否拿新态(NFS attr caching / hf-mount caching 封装层未钉)

### 5.3 唯一能解剩下的路

- **PRO/Team 升级** → SSH dev mode (`hf spaces ssh nonoke/omn`) 进容器跑 `cat /logic-bucket/probe.txt` + 多轮改 bucket 测 open 新态
- **或**: 加临时 gate.js endpoint `GET /v1/_mountprobe` 读 `/logic-bucket/probe.txt` 返 = 改生产代码超实测范围(本次未采)
- **或**: 改 start.sh boot 段加 `cat /logic-bucket/probe.txt>&2` 经 omn scheduler 推 Dataset 看 = 改生产 + 1次 Restart(本次未采, Zen未准改代码)

---

## 5原. 待实测唯一真未知数(文档空白, 推断收声)

**问**: HF Bucket RW mount 进程已 `open()` 读取某文件后, 外部经 CI/API 改 bucket 同件, 进程**再次 `open()`** 是否拿新态? 还是 mount 层客户端缓存固化须 Restart?

**相关**: hf-mount repo 提 "caching"(access-patterns 转引 full docs 未钉语义)。NFS 客户端缓存 attr caching — 默认 AC(fully cached) + close-to-open consistency 可能影响下次 open 见新态的语义。

**推断收声(免费层无终端不能硬验)**: 基于官方钉底层 NFS fetched-lazily, 机制上支持外部改后重 open 见新态。但 **omn 八件全 boot 一次性加载**(勘察 §4 钉死: gate.js node require 入内存 / init bash 一次性 / scheduler python 启动), 无运行中重读逻辑 → **即使 mount 热更成立, 改任一件仍须 Restart 进程重读**。故此未知数(热更性)对 omn 的实际影响 = 有限(只影响"省 boot 拉件时延"一条, 不影响"运行中改件秒生效")。

---

## 6. 实测方案(Zen侧, dev 环境隔离)

### 6.1 前置(Zen手动)
1. 建 dev Private Bucket: `nonoke/omn-runtime-test`(或复用 §12 规划之名)
2. two-remote 拓扑: dev Space(nonoke/omn) 挂 RW `/logic-bucket`(test), 不碰 prod

### 6.2 实测步骤(钉 §5 未知数)

**步A — mount 热更基线测**:
1. Space boot, mount 就绪
2. Space 内 `cat /logic-bucket/probe.txt` 读初值 v1
3. **不 Restart**, 外部 `hf buckets cp` 推 probe.txt=v2 到 bucket
4. Space 内 `cat /logic-bucket/probe.txt` 再读 → v2 = mount 热更成立 ✅ / v1 = 客户端缓存固化 ❌

**步B — 进程已 open 句柄测**:
1. Space 内跑长驻进程持 `tail -f /logic-bucket/probe.txt`(保持 fd open)
2. 外部推 probe.txt=v2
3. tail 见 v2 = fd 级热更 / 不见 = fd 固化

**步C — 应用层模拟(node)**:
1. 改 probe 内值模拟 gate.js 改动
2. node 跑长驻 `setInterval(()=>require('./probe'),5000)`
3. 观察是否 require cache 命中(须 `delete require.cache`), 非 mount 层语义 — 此测分离 "mount 热更" 与 "node require cache" 两层混淆

### 6.3 实测后落账
- 结果回填本文档 §5
- 进 DECISIONS.md 2026-08-01 段 待证项消解
- 进 memory `logic-dataset-to-bucket-intent` 待证据消解

---

## 7. 结论(本勘察时点)

1. **官方文档两源空白** Bucket mount 热更/Restart 语义, 仅钉底层 NFS/FUSE + lazy fetch。
2. **底层推断**: 非 snapshot, 机制上支持外部改后重 open 见新态, 但 NFS 客户端缓存语义未钉须实测。
3. **现役架构铁证**: `/logic` 是 download→cp 入 ephemeral, 非 mount。换 Bucket mount 须删 `start.sh` §3 整段, 且**废 commit_id 锁 = 竞速复活**。
4. **真收益钉死**: omn 八件全 boot 一次性加载, 无运行中重读 → **Bucket mount 热更对 omn 无运行中秒级收益**, 改任一件仍须 Restart。唯一真收益 = 免 boot 拉件+cp 时延(冷启加速)。
5. **待Zen实测**: §6 步A/B/C 钉 §5 唯一未知数(mount 客户端缓存固化 vs 热更)。

**对 2026-08-01 迁意图的影响**: 若真痛点是"init/gate 改动须 Restart 非秒级" — Bucket mount 不解此痛(省的是 boot 拉件时延非运行态热更)。若痛在"boot 拉件+cp 时延" — Bucket mount 解。Zen真痛点须重新定位后再决迁不迁。

详文不入会话, 见 git 历史 recover。Zen确认后实测方案落地。
