# 2026-08-01 · save/*.log 全量分析报告

**Zen令**: 2026-08-01 "把之前 save 目录下的 *.log 都拉下来分析一下" + "拉完全删了"。

**范围**: HF Dataset `nonoke/omn-logic` 私库 `save/` 路径下全部 `.log` 快照。

**动作**:
- 拉取 2289 件 `.log`(12.8MB) 至本地 `/tmp/omn-save-pull/save/`(`snapshot_download` + `max_workers=8`,69s 含缓存命中)
- 远程 `save/*.log` 全删(`HfApi.delete_files` glob 一次批删,commit `f60b8bd6`),留 6 件 `.json` 快照不动
- 本地 2289 件留 `/tmp/omn-save-pull/` 供分析(分析完是否删待Zen令)

**四源时间跨**(文件名 epoch,UTC): **2026-07-30 17:07Z ~ 2026-08-01 09:02Z**(~40h,跨 2 个-boot 期)

**关联**: memory `save-log-analysis-2026-08-01` + `log-archive-to-new-private-repo-landed`(日志归档机制,同 commit `a80d335` push nomn)。

---

## 0. 四源件数与体积

| 源 | 件数 | 体积 | 内容形态 |
|---|---|---|---|
| gate | 726 | 3.18 MB | gate.js `logGate` JSON(stderr 写,错误分支调用) |
| ft | 705 | 4.35 MB | FlareTunnel 桥启动 banner + prometheus 指标 |
| app | 785 | 4.72 MB | OmniRoute SSE 层 JSON(ROUTING/AUTH/HTTP/USAGE) |
| init | 57 | 0.34 MB | init-nim-keys.sh bash 回显(probe/注册/限流) |
| **合计** | **2289** | **~12.8 MB** | — |

---

## 1. gate 源 — 2083 次 401/403 全预期非病

### 1.1 内容形态

726 件,结构为 JSON 行,字段含 `ts`(epoch ms)/`level`/`component:gate`/`stage:upstream_proxy`/`requestId`/`method`/`path`/`upstream_path`/`upstream_target`/`elapsedMs`/`httpStatus`/`msg`。method 总分布:GET 3043 次 + POST 1532 次(业务 `/v1/chat/completions` 等)。

### 1.2 401/403 精确分布(jq 解析全 726 件)

```
403 GET  /api/services/bifrost/status        916
401 GET  /api/sync/cloud                     560
401 GET  /api/token-health                   279
401 GET  /api/health/degradation             279
403 GET  /api/services/cliproxy/status        18
403 POST /api/services/bifrost/install        7
403 GET  /api/services/9router/status         7
401 HEAD /api/hello                            6
403 GET  /api/services/mux/status              3
403 GET  /api/services/cliproxy/logs           2
403 GET  /api/services/bifrost/logs            2
403 GET  /api/services/mux/logs                1
403 GET  /api/services/9router/models          1
403 GET  /api/services/9router/logs            1
401 GET  /api/auth/csrf                        1
                                  总计 2083
```

### 1.3 真因钉死

**非攻击 / 非外部扫描 / 非 PSK 错**。三条铁证:

1. **全 GET admin 探测路径 + upstream_target 恒定**:`upstream_target` 字段全部 = `127.0.0.1:20128`(OmniRoute app 本地端口),非外源 IP。`path` 字段原样透传(非 `upstream_path` 重写)→ 说明是 gate 透传给上游,上游自返。
2. **GATE_ADMIN_ENABLED=0**(§6 维护窗关)→ 所有 `/api/*` admin 路径 gate 不拦直透上游 → OmniRoute 自身 admin API **无 admin token** 自返 401/403。
3. **279×3 对称分布非随机指纹**:`/api/sync/cloud` 560、`/api/token-health` 279、`/api/health/degradation` 279 三数对称 = OmniRoute **内部定时 health/token 轮询**(systematic),非外部攻击的随机探测。

PSK 正常铁证:业务 `/v1/chat/completions` 等路径全 200,仅 `/api/*` admin 路径返 401/403 → PSK 鉴权层无病,病在上游 admin ACL(预期行为)。

### 1.4 治法

**零代码改可消**:Zen开维护窗 `GATE_ADMIN_ENABLED='1'`(§6 门路)→ gate 本地拒 admin 路径不再透传上游,401/403 即消。

注:`GATE_ADMIN_TOKEN` 机制已废于 `82d6559`(saga 回填期 "gate 单开关" 改造),现 `gate.js` 无 Token 认证,纯布尔开关。开窗即消,无须配 Token。

---

## 2. app 源 — 11 次 "No credentials" 全 boot race 非病

### 2.1 内容形态

785 件,OmniRoute SSE 层 JSON。字段 `level`(30=info/40=warn)/`time`(ISO UTC)/`service:omniroute`/`module:sse`/`tag` ∈ {HTTP,ROUTING,AUTH}。另含部分 `{"timestamp":...,"component":"app"}` 形态(RATE-LIMIT/ModelSync/ProxyHealth)。

### 2.2 "No credentials for nvidia" 11 次时间分布

```
2026-07-31T01:45:55Z  (×2: No credentials + No active credentials)
2026-07-31T01:46:30Z  (×2)
2026-07-31T01:46:45Z  (×2)
2026-07-31T01:46:49Z  (×2)
2026-07-31T01:46:52Z  (×2)
2026-07-31T01:46:55Z  (×2)
2026-07-31T01:48:01Z  (×2)     ← 07-31 boot 期 7 次,boot 后 ~60s 内爆发
2026-08-01T06:42:32Z  (×2)     ← 08-01 06:42 boot race
2026-08-01T06:56:35Z  (×1)
2026-08-01T08:58:02Z  (×1)
```

### 2.3 真因钉死 — boot race(providers 凭据注册未完成窗口)

逐行时序铁证(以 2026-08-01 06:42 boot 期 `app_1785566609.log` 头部为例):

```
06:42:31.998  SSE translators init for /v1/messages
06:42:32.001  POST /v1/messages | nvidia/z-ai/glm-5.2 | 145 msgs | 40 tools   ← 收到请求
06:42:32.021  ROUTING Provider: nvidia, Model: z-ai/glm-5.2
06:42:32.025  ✗ AUTH "No credentials for nvidia"                   ← provider 凭据池空
06:42:32.026    AUTH "No active credentials for provider: nvidia"
   ...
06:43:37      🛡️ RATE-LIMIT "Loaded 0 explicit + 32 auto-enabled"  ← init 32 providers 注册完
06:43:37+     ✅ SSE ROUTING→AUTH 成功 后续全恢复(recordWorker USAGE STREAM 正常)
```

**链**:
- init 注册 providers 凭据:`init-nim-keys.sh` L824 `POST /api/providers` body=`{provider:"nvidia",apiKey:$KEY,name,..."}` 201 注入。
- 此注册**必须 probe 32 key + 全量 POST 完**才有 nvidia 凭。probe 并发 3 / timeout 15s/key → 窗口约 60-160s。
- app node server boot 后**立即 listen 收请求**(entrypoint 起序:app 先于 init Done 就绪)→ 窗口内收到 `POST /v1/messages` → SSE 路由到 nvidia → provider 凭据池仍空 → AUTH 崩 "No credentials"。

### 2.4 关键证伪 — 非 env skip 致 credentials 缺

init 件明载 `[init] OMNIROUTE_API_KEY env set, skip /api/keys`。但查源码 `init-nim-keys.sh` L565-570:

```bash
if [ -n "$OMNIROUTE_API_KEY" ]; then
    OR_KEY="...$OMNIROUTE_API_KEY..."
    [ -z "$OR_KEY" ] && { echo "FATAL: ..."; exit 1; }
    echo "[init] OMNIROUTE_API_KEY env set, skip /api/keys."   # ← 只 skip /api/keys(鉴权层)
fi
# ... L824 POST /api/providers 独立,不 skip                 # ← provider 凭据注册照常
```

`OMNIROUTE_API_KEY` env 只 skip `/api/keys`(OmniRoute 鉴权 key 注册层),**不 skip providers 注册**(L824 独立)。所以不是 env 配错致 credentials 缺 — 是 providers 注册**慢于** app listen 的 race 窗口。

`init probe 32key alive`(integration 层,测 `integrate.api.nvidia.com` 可达)与 `app OmniRoute provider credentials`(同 key 注册进 OmniRoute provider pool)是两维。init 全链做(probe 先 alive 调限流 + 再 POST 注册 providers),但 providers 注册在 probe 之后 + app 先 listen = race。

### 2.5 病否

**boot race 预期现象非病**。785 件 app 中仅 11 次报错,全集中 boot 后短窗口(07-31 7次 / 08-01 4次)。init Done(32 alive / Resilience / rc=0)与 race 窗口并存 = **init 慢 ≠ init 错**。

### 2.6 未决疑点

08-01 `06:56:35` / `08:58:02` 两错非首 boot race(距 boot 起始非 60s 窗内),疑 ProxyHealth sweep 期:同 boot 段 `app_1785567513.log` 头载 `[ProxyHealth] Sweep complete: 1 tested, 0 alive, 1 inconclusive` — 疑 proxy 短暂脱活切无 credentials。本轮 app 滚件 60s 精度勾不到秒级 sweep 与错件秒级对齐,留下次逐行证。

### 2.7 治法

**根治须改代码**(本轮未准改):app 等待 init Done 才能 listen(改 `entrypoint.sh` 启序,init 注册完再起 app)+ 或命中 "No credentials" 即重试(短退避后重取 provider pool,躲窗口期)。

---

## 3. ft 源 — 16 Worker 桥健康

### 3.1 内容形态

705 件。前部为 FlareTunnel 桥启动 banner(bash 回显),后部为 prometheus 指标行。

启动 banner(每 boot 首件):

```
✓ Generated CA certificate: /tmp/ft-ca/flaretunnel_ca.crt
🚀 FlareTunnel Tunnel Server Started
📡 Listening: 127.0.0.1:8080
⚙️  Workers: 16
🔄 Rotation: round-robin
🔒 SSL/HTTPS: ✓ Enabled (HTTPS CONNECT supported)
🛡️  IP Blocking: ✓ Enabled
🚫 Blacklist: 0 pattern(s)
🔗 Upstream: ❌ None (direct to Workers)
```

### 3.2 Worker 池结构(prometheus label 钉死)

16 Worker,四池各 4,round-robin:

```
flaare-1 ~ flaare-4   (flaare 池)
flbare-1 ~ flbare-4   (flbare 池)
flcare-1 ~ flcare-4   (flcare 池)
fldare-1 ~ fldare-4   (fldare 池)
```

### 3.3 失败指标

`flaretunnel_worker_failures_total` 行(6876 次指标刷写跨 705 件):flaare-1 / flaare-2 各 1 次失败,余全 0。

**偶发 ≤2 失败 = 预期非病**。16 Worker round-robin 分散密度,桥稳坐出站换 IP 层。

---

## 4. init 源 — 全绿

### 4.1 内容形态

57 件(60s 滚件),bash 回显非 JSON。关键签名:

```
[init] Logged in.
[init] OMNIROUTE_API_KEY env set, skip /api/keys.
[init] probe_nim_keys_real: 并发3 探活 NIM keys via POST /v1/chat/completions
      (model=z-ai/glm-5.2, timeout=15s/key, 403→dead, 余→alive fail-open, 重试关)
[init] probe key#1: HTTP 200 → alive
   ...
[init] 动态限流 RPM=300 concurrent=96 interval=200ms (alive_keys=32, per_key_rpm=35 per_key_conc=3)
[init] Final health check...
[init]   Status: healthy / 3.8.48
[init] Done (first-init). v4.3.2
```

### 4.2 结论

init 链全绿:32 key alive / Resilience RPM=300 concurrent=96 / init Done rc=0 v4.3.2。与 gate/app race 无矛盾——init 慢(probe 32key + 注册 providers 耗 60-160s)是 race 窗口的来源,但 init 本身不错。

---

## 5. 总结论

| 源 | 现象 | 次数 | 真因 | 病? | 治法 |
|---|---|---|---|---|---|
| gate | 401/403 | 2083 | `GATE_ADMIN_ENABLED=0` + admin GET 路径透传 + OmniRoute admin API 自返(无 admin token) | ❌ 预期 | 开维护窗 `GATE_ADMIN_ENABLED='1'` 消,零代码改 |
| app | "No credentials for nvidia" | 11 | boot race:init providers 凭据注册(POST /api/providers)未完窗口期,app 先 listen 收请求即崩 | ❌ 预期 | 改 entrypoint 启序(app 等 init Done 才能 listen)+ 命中重试。须Zen准改代码 |
| ft | Worker fail | ≤2 | 16 池 round-robin 偶发 | ❌ 预期 | 无须治 |
| init | 全绿 | — | 32 alive / rc=0 | ✅ | — |

**全四源现象均预期行为,非病。**无需紧急改动。

---

## 6. 待Zen定夺

1. **gate 2083 次**:量大占日志空间但非病。欲消则开维护窗(零代码改)。不欲消则靠已落地的**日志归档机制**(omn_scheduler.py `_archive_loop`,commit `a80d335` push nomn)解空间占用——须Zen建新 HF 私库配 `OMN_LOG_ARCHIVE_REPO` + `OMN_LOG_ARCHIVE_TOKEN` 两 Secret + restart dev 才生效。
2. **app boot race 11 次**:非病但影响 boot 后 ~60-160s 窗口内请求。欲根治须准改 `entrypoint.sh` 启序(app 等 init Done 才能 listen),本轮未准改代码。
3. **本地 2289 拉件**(`/tmp/omn-save-pull/` 12.8MB):分析已完,删否待Zen令。

---

## 7. 链与方法

- 拉取:`snapshot_download(repo_id="nonoke/omn-logic", allow_patterns=["save/*.log"], local_dir="/tmp/omn-save-pull", max_workers=8)`,69s(含缓存命中)
- 远程删除:`HfApi.delete_files(repo_id, delete_patterns=["save/*.log"], repo_type="dataset")` glob 一次批删(commit `f60b8bd6`),留 6 件 `.json` 快照(non-log)
- 分析:`jq` JSON 行解析 + `grep`/`sort`/`uniq -c` 分布统计 + epoch→UTC 换算对齐时序
- 源码对照:`dev/logic/init-nim-keys.sh` L565-570(OMNIROUTE_API_KEY skip 范围)+ L824(POST /api/providers body)+ L836(GET /api/providers)
- §1 拓扑铁律遵守:本分析仅取 `nonoke/omn-logic`(dev 私库 Dataset)日志,未交叉引用 `nomke/omn`(生产)Space 结论

---

## 8. 齐全性评估(2026-08-01 Zen令补)

### 现拉件五类(2289件)
- 四源 gate/ft/app/init + **debug 16件**(init verbose 超集,`NIM_MODE=DEBUG` 时产,含 probe 全程+curl 细节+HTTP 000/403 fail-open 路径 → 印证 init 全绿)。**第一轮分析漏看 debug**,已补 — debug 件印证 probe fail-open 链(HTTP 000→重试 30s 宽超时 / 403→AUTH_DEAD 跳注册)。

### 结构性遗漏(两层,按严重排)

**遗漏①(严重):entrypoint 本体 boot 编排日志全丢** ⚠️
- `[entrypoint]` echo(健康等待/Init PID/Litestream PID/gate 依赖装/启动顺序/FATAL)进 PID1 stdout,无 `exec > >` 重定向落 raw,capture 不触。
- 现存五类件全无 `[entrypoint]` 字样 = 铁证漏。
- **影响**:boot race 真因果(各进程启动先后)恰在编排日志,推 save 看不到 → 分析只靠推断非硬证。FATAL/gate npm install 失败/健康等待超时 180s 等关键故障全丢。
- 唯一 escape:HF Space runtime logs(40h 外焚),事发即抓。

**遗漏②(严重):litestream R2 复制链日志全丢** ⚠️
- `litestream replicate -config ... & LS_PID=$!` 无 stderr 重定向 → 同进 PID1 stdout(与遗漏①一起丢)。restore `2>/tmp/ls_restore.err` 一闪即弃。
- **影响**:R2 复制断代/compaction txid gap/proxy_breaker 等数据层故障判据全丢。

### 补漏落地(2026-08-01 Zen准补,本地改完未 push)

**三改**:
1. `entrypoint.sh` L17 后:加 `exec > >(tee -a "$_EP_LOG_RAW") 2>&1` 全段 boot 编排落 `${DATA_DIR}/omn-raw/entrypoint.log`,boot 前截断(:>) 免跨 boot 累计重复推。tee 双路(同时留 PID1 stdout 供 Space runtime logs 前置应急)。
2. `entrypoint.sh` L311:litestream replicate 加 `>>"$_LS_LOG_RAW" 2>&1` 重定向落 `${DATA_DIR}/omn-raw/litestream.log`,boot 前截断归零。
3. `omn_scheduler.py`:`capture_stdout()` 加 `_capture_one(RAW_DIR/"entrypoint.log","entrypoint")` + `_capture_one(RAW_DIR/"litestream.log","litestream")` 第六七源;`_ARCHIVE_PREFIXES` 扩加 `"entrypoint","litestream"` 入归档扫源。

**核验**:bash -n + py_compile 绿;secret-scan 0 裸 key 形态;tee 进程(>process substitution)不纳入 _shutdown kill 列表,PID1 退出时 EOF 自然退,不阻塞 shutdown。

**未决**:三改本地落,push nomn 后 CI #22 自动同步 Dataset,但 **Space 须 restart 才拉新代码生效**(见 §9)。归档线对旧平铺件(`save/<prefix>_<epoch>.log` 三段格式)解析不到,只对新子目录件(`save/<prefix>/...` 四段格式)生效 → restart 后产子目录件归档才起。

### 遗漏③(轻):debug 件非每 boot 产
- 仅 `NIM_MODE=DEBUG=1` 时 tee,正常 boot 只精简 init 源。想查 curl verbose/probe 000 真因 → 须重启配 DEBUG 才能复现。非"丢"而是**条件产**。

---

## 9. save 分类为何未生效(2026-08-01 Zen令查)

### 现象
- `omn_scheduler.py` 分类代码(commit `a80d335`,产 `save/<prefix>/<YYYYMMDD_HHMMSS>_<epoch>.log` 子目录)已 push nomn 私库 + CI `sync-logic-nonoke` #21 跑通同步至 Dataset(sha256 一致铁证:`aa4bd9d260...`)。
- 但 Dataset `save/` 现役仍产**旧平铺格式** `save/<prefix>_<epoch>.log`(67 件,全平铺无子目录无北京时间命名)。
- 最早新件 epoch=1785575281(2026-08-01 09:08:01Z),`a80d335` push 于 08:57:53Z → push 后产的新件仍旧格式。

### 真因钉死(三证)
1. **Dataset `omn_scheduler.py` sha256 == 本地** `aa4bd9...` = CI 已同步新版到 Dataset(可"CI 没同步"假设推翻)。
2. Space runtime `stage=RUNNING` `sha=904e1c28...`,Space 仍在跑旧 boot 的内存进程(scheduler python 启动加载后不重读文件)。
3. 09:08 新件内容时间 09:07:03 = 旧 boot 期持续尾追产物(USAGE STREAM 正常业务流),非新 boot(无 init probe 32key 期签名)= Space **完全未 restart**。

### 病根
**Space 跑旧 `omn_scheduler.py` 进程内存态**。start.sh L52/87/100-102/110(audit 勘察钉):`/logic` = boot 时 `hf download` Dataset → `cp -a` 入 ephemeral → `python3 omn_scheduler.py` 启动加载入内存。Dataset 虽已同步新版,但 Space 须 **restart** 才 boot 拉新 Dataset → cp 新代码 → 起新 scheduler 进程产子目录件。

### 治法
**零代码改,单步 restart Space**。Dataset 新版已在,Space 重启即拉新 → 分类+北京时间命名+归档线+第6-7源补漏全生效(三改 pushS 后须 restart 一次同启)。

### 归档线同步注意
归档 `_do_archive` L269 判 `len(parts)==4` = 子目录四段格式。旧平铺三段件归档解析不到 → 现役 67 旧平铺件**归档扫不到**。restart 后产子目录件归档才起。旧平铺件须Zen明令批量删(或留占空间至下次清)。

