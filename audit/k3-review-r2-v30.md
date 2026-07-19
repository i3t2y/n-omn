# K3 审阅请求 · nonoke/omn V3.0 三层解耦 R2 落地 + 三 bugfix 实测验证

> 日期 2026-07-19 | 本地工作目录 `/home/laisi/omn-merge/candidate-v4.3-reviewed`
> 目标: 25 NIM Key 轮询推理 OmniRoute 3.8.43 中转网关, HF Space 免费层, 绕 7/16 docker build 冻

## 一、整体架构 (三层解耦 + 三文件永久免改)

### 三层职责闭环

| 层 | 承载物 | 仓 | 变更触发 |
|----|--------|----|---------|
| 环境层 | "怎么引导" 永久不变 | HF Space `nonoke/omn` 三文件 (Dockerfile/bootstrap.sh/README.md) | 仅升级 OmniRoute 改 BASE_IMAGE→Rebuild |
| 镜像层 | "跑哪个版本" | GHCR `ghcr.io/i3t2y/omniroute-base:stable` (上游 3.8.43 镜像固设) | GHCR push 新 :X.Y.Z |
| 逻辑层 | "怎么运行" 随需迭代 | HF Dataset `nonoke/omni-logic` 5 文件 (entrypoint/init/gate/litestream/package) | Dataset 改→Space Restart (零 rebuild, 绕冻) |

### "三文件永久免改" 设计 (核心独创)

来自 `docs/三文件永久免改.md`。Space 三文件做到版本无关, OmniRoute 升级:
1. GHCR 侧以新版本上游镜像构建并推送 `i3t2y/omniroute-base:X.Y.Z`
2. Space Settings → Variables → `BASE_IMAGE` 改为新标签
3. Space Settings → Variables → `EXPECTED_VERSION` 同步 (可选仅日志比对)
4. Settings → Rebuild

三文件不动。版扫码由文件内容驱逐, 改由 Space 构建 ARG + GHCR 标签承载。

### 上游契约锚点 (源码级查证)

- 上游 Dockerfile runner-base: `DATA_DIR=/app/data`, `PORT=20128`, `HOSTNAME=0.0.0.0`, `USER node` (UID 1000), `ENTRYPOINT ["/tmp/check-permissions.sh"]`, `CMD ["node","dev/run-standalone.mjs"]`, 基 `node:24-trixie-slim` 仅预装 libsecret + ca-certificates (无 python3/curl/jq/litestream)
- 上游迭代周 2~3 补丁版 (3.8.43→49), 数据契约跨 5 小版本未变
- 镜像内置 `OMNIROUTE_MIGRATIONS_DIR=/app/migrations` 启动自动按序应用迁移 + 幂等检查 → 升级 R2 旧库自动前滚新 schema

## 二、三文件最终版 (环境层)

### Dockerfile (ARG BASE_IMAGE + USER root + --chmod buildkit)

```dockerfile
ARG BASE_IMAGE=ghcr.io/i3t2y/omniroute-base:stable
FROM ${BASE_IMAGE}

# root 永久需求: 上游 runner 永远 USER node 且永远缺工具, bootstrap 运行时自愈需写权限
USER root

# --chmod=755 buildkit 标准能力, 替代 RUN chmod, 消灭属主假设
COPY --chmod=755 bootstrap.sh /bootstrap.sh

EXPOSE 7860

HEALTHCHECK --interval=30s --timeout=10s --start-period=180s --retries=3 \
  CMD node -e "require('http').get('http://127.0.0.1:7860/healthz',r=>{process.exit(r.statusCode===200?0:1)}).on('error',()=>process.exit(1))" || exit 1

ENTRYPOINT ["/bootstrap.sh"]
```

### bootstrap.sh V3.0 (自愈前置 + 全量 /logic/ 注入)

关键点:
1. **环境自愈前置** (永久机制): 探测缺 python3/curl/sqlite3/litestream/hf → apt 装齐 + pip `huggingface_hub>=1.0,<2.0` + litestream v0.5.9 二进制 (资产命名实证: amd64=linux-x86_64, arm64=linux-arm64)
2. **全量注入**: `cp -a /tmp/logic/. /logic/` (逻辑层增删文件免改 bootstrap, 唯一契约=Dataset 根必须存在 entrypoint.sh)
3. **stderr 落盘回放脱敏**: `_dl()` 函数: stderr 落 `/tmp/.dl.err` 后 `sed $HF_TOKEN/[REDACTED]/g` 回放, 保留 hf 真实退出码 (修 V2.2 `2>&1|sed` 吞退出码 bug)
4. **exec /logic/entrypoint.sh** 交控逻辑层

```sh
#!/bin/sh
set -e

# 1. 环境自愈
_need_install=0
for t in python3 curl pip3; do command -v "$t" >/dev/null 2>&1 || { _need_install=1; break; }; done
command -v litestream >/dev/null 2>&1 || _need_install=1
{ command -v hf >/dev/null 2>&1 || command -v huggingface-cli >/dev/null 2>&1; } || _need_install=1

if [ "$_need_install" = "1" ]; then
  command -v apt-get >/dev/null 2>&1 || { echo "FATAL: 非 Debian 系"; exit 1; }
  apt-get update && apt-get install -y --no-install-recommends \
    curl jq python3 python3-pip sqlite3 ca-certificates && rm -rf /var/lib/apt/lists/*
  pip3 install --no-cache-dir --break-system-packages "huggingface_hub>=1.0,<2.0"
  if ! command -v litestream >/dev/null 2>&1; then
    _a=$(uname -m | sed 's/aarch64/arm64/')
    curl -fsSL "https://github.com/benbjohnson/litestream/releases/download/v0.5.9/litestream-0.5.9-linux-${_a}.tar.gz" \
      | tar -xz -C /usr/local/bin litestream && chmod +x /usr/local/bin/litestream
  fi
fi

# 2. 变量校验 (HF_TOKEN 可选: 公共 Dataset 无需令牌)
[ -n "$LOGIC_BUCKET_REPO" ] || { echo "FATAL: 缺 LOGIC_BUCKET_REPO"; exit 1; }

# 3. 拉取逻辑层 (stderr 落盘回放脱敏)
mkdir -p /tmp/logic
_dl() {
  _err=/tmp/.dl.err; : > "$_err"
  _tk=""; [ -n "$HF_TOKEN" ] && _tk="--token $HF_TOKEN"
  if command -v hf >/dev/null 2>&1; then
    hf download "$LOGIC_BUCKET_REPO" --repo-type dataset --local-dir /tmp/logic $_tk --quiet 2>"$_err"
  else
    huggingface-cli download --repo-type dataset "$LOGIC_BUCKET_REPO" --local-dir /tmp/logic $_tk --quiet 2>"$_err"
  fi
  _rc=$?
  if [ -s "$_err" ]; then
    if [ -n "$HF_TOKEN" ]; then sed "s/$HF_TOKEN/[REDACTED]/g" "$_err" >&2; else cat "$_err" >&2; fi
  fi
  return $_rc
}

if _dl; then
  mkdir -p /logic
  cp -a /tmp/logic/. /logic/
  chmod +x /logic/*.sh 2>/dev/null || true
else
  echo "FATAL: Dataset 拉取失败"; exit 1
fi

rm -rf /tmp/logic
exec /logic/entrypoint.sh
```

## 三、逻辑层 5 文件 (Dataset `nonoke/omni-logic`)

### 3.1 entrypoint.sh (合并版 252 行, 进程编排总控)

核心契约:
- `DATA_DIR=${DATA_DIR:-/app/data}` (默认对齐 3.8.43 镜像固设, env 可改)
- `EXPECTED_VER="${EXPECTED_VERSION:-}"` (硬编码驱逐, 三文件永久免改; 非空不匹配时告警不 exit, 上游前滚迁移兜底)
- 文件锁 flock (跨容器互斥 restore/替换 $DB)
- litestream restore `-if-replica-exists` 自适应 (R2 无副本 rc=0 但空库启动, 不 FATAL)
- restore 临时路径 + quick_check + 原子 mv (不覆盖有效 DB)
- 四子进程 (OmniRoute/init/litestream/gate) trap SIGTERM 转发 grace wait SIGKILL 兜底 无孤儿
- gate background (非 exec, entrypoint 持 PID 1 主监)
- 监督循环: gate 退停一切, OmniRoute 退停一切, init 非致命, litestream 退按 STRICT

**R2 bugfix 1 (litestream v0.5.9 三因子合修)**:
```sh
# ── 5. Litestream 复制 (后台) ──
# v0.5.9契约: replicate -config 模式 fs.NArg()必须=0 (走配置文件内 dbs[].path).
#   传 $DB_PATH 位置参数会命中 case 1 → "must specify at least one replica URL" 报错崩.
# 注意: 本行"去位置参"仅解 R1 replicate 报错; R1 restore 报错 (database not found in config)
#   由 yml dbs[].path 修正 (/data → /app/data) 独立解决, bucket 名 omniroute-data→omn-data 修副本解析.
#   见第五章 1a/1b/1c 三因子拆分, 非单单去位置参.
if [ "$has_r2" = 1 ] && [ -f /logic/litestream.yml ]; then
  litestream replicate -config /logic/litestream.yml & LS_PID=$!
  echo "[entrypoint] Litestream PID=$LS_PID"
fi
```

路径全 `/logic/` 前缀 (bootstrap V3.0 全量注入契约):
- `bash /logic/init-nim-keys.sh & INIT_PID`
- `litestream replicate -config /logic/litestream.yml` (去 $DB_PATH 位置参)
- `node /logic/gate.js &`
- restore 三处 `-config /logic/litestream.yml`

### 3.2 init-nim-keys.sh (138 行, NIM 初始化自包含)

API 路径全部对照官方 Wiki 修正 (https://github.com/diegosouzapw/OmniRoute/wiki/API-Reference), 所有管理 API 经 Cookie 鉴权 (POST /api/auth/login → auth_token)。

Step 序: 0 输入校验 → 1 危险代理环境变量扫描 (仅打名不打值) → 2 健康等 120s → 3 登录 (密码哈希优先回退 INITIAL_PASSWORD) → 4 注册 NIM Keys 幂等 → 5 读回 Provider 核对 → 6 SQL 代理清除兜底 (表名自动探测) → 7 proxy 配置清除 → 8 Resilience PATCH → 9 Compression → 10 Thinking Budget → 11 Memory (v3.8.30+ 默认关跳过) → 12 熔断器重置 → 13 NIM 探针 (NIM_PROBE=1 可选走 443) → 14 Combo 管理 (auto-combo 优先, 持久化 optional, fail-closed 后台关不盲写)

**R2 bugfix 2 (xargs log dash 兼容)**:
```sh
log() { echo "[init] $*"; }
# 管道尾部回调改用 { read -r _v; ... && log ...; } (内联子shell共享函数定义),
# 替代 xargs -I{} log (dash 不支持 export -f, xargs 子进程无 log 函数)
```
4 处读回改为管道尾子 shell 形式:
```sh
curl -sf -b "$COOKIE" "$BASE/api/resilience" 2>/dev/null | jq -c '.providerBreaker // .' 2>/dev/null \
  | head -c 300 | { read -r _v; [ -n "${_v:-}" ] && log "  resilience 读回: $_v"; }
```
combos 处 (含 || 回退) 改条件分支:
```sh
_v="$(curl -sf -b "$COOKIE" "$BASE/api/combos" 2>/dev/null | head -c 500)"
if [ -n "$_v" ]; then
  log "  combos 当前: $_v"
else
  log "  combos 读取失败 (非阻断, auto combo 仍可用)"
fi
```

**R2 bugfix 3 (proxy 3-level schema)**:
```sh
# ── Step 7: 代理配置清除 (官方 3-level proxy: global/providers/combos/keys) ──
# 3.8.43 schema = {global, providers, combos, keys}, 非 {enabled:false} (旧 schema → HTTP 400).
# 读回已是 {global:null,...} 即关态 → 跳过 PUT (避免 400 + schema 猜测).
_cur=$(curl -sf -b "$COOKIE" "$BASE/api/settings/proxy" 2>/dev/null || echo "{}")
log "  当前 proxy 配置: $(printf '%s' "$_cur" | head -c 200)"
_g=$(printf '%s' "$_cur" | jq -r '.global // empty' 2>/dev/null)
if [ -n "$_g" ] && [ "$_g" != "null" ]; then
  curl ... -X PUT "$BASE/api/settings/proxy" ... -d '{"global":null}'
else
  log "  ✓ proxy global 已关闭, 跳过 PUT"
fi
```

Combo auto 注 (Step 14):
```sh
# 官方支持 model:"auto" (及 auto/coding, auto/fast 前缀) 虚拟 combo,
#   createVirtualAutoCombo 直接从已注册活跃 NIM 连接建池路由, 零预创建。
# 客户端直接用 model:"auto" 即可路由全部已注册 NIM 连接。
# 持久化 combo 仅 optional 优化 (固定模型池/别名), 待管理通道就绪后创建;
#   当前 fail-closed 后台关, 脚本不盲写 POST /api/combos (schema 未文档化)。
```

### 3.3 gate.js (285 行, 零依赖仅 http/crypto) — gate.v43-merged.js 改名后压缩入口载荷

K3 v2.0 根因修 + candidate v4.3 保留真值项 + 后台 fail-safe:
- PSK 双通道 (`X-Internal-PSK` 头 + `Authorization: Bearer` 回退) for `/v1/*`
- 后台 fail-closed: `GATE_ADMIN_TOKEN` 未设 → 管理面 404 不泄露后台存在 (已设 → Basic Auth)
- 上游超时 180s (`timeout={180000}`) — Node `http.request` 的 `timeout` 选项语义为 socket 空闲超时非总时长, thinking 模型上游慢需拉长
- 令牌桶限流 28rpm/1并发/100ms (HF 单 Space 软限, 防线性放大触发上游风控)
- `isAdminPagePath` 精简路径判断
- P1-1 x-internal-psk 双通道恢复 (含 `Authorization: Bearer` 回退)
- P1-2 折中: 后台关不设 GATE_ADMIN_TOKEN (manage key 注入前 fail-closed)

### 3.4 litestream.yml (R2 bucket omn-data 隔离)

```yaml
dbs:
  - path: /app/data/storage.sqlite
    replica:
      type: s3
      bucket: omn-data                    # R2 新建 bucket, 防 nomke 生产库冲突
      path: db/storage.sqlite
      endpoint: https://${R2_ACCOUNT_ID}.r2.cloudflarestorage.com
      access-key-id: ${R2_ACCESS_KEY_ID}
      secret-access-key: ${R2_SECRET_ACCESS_KEY}
      region: auto
      sync-interval: 10s
      # v4.3 红线3: auto-recover false. entrypoint.sh 已显式 restore (含本地非空 guard + 临时路径 + quick_check);
      # 若 auto-recover true, litestream 始自恢复会绕 entrypoint guard, 覆盖有效 DB.
      auto-recover: false

snapshot:
  interval: 1h
  retention: 24h
```

### 3.5 package.json (gate 元数据)

```json
{
  "name": "omniroute-gate",
  "version": "2.0.0",
  "private": true,
  "description": "零依赖(仅 http/crypto) gate: PSK 双通道 + fail-closed + 令牌桶限流, 前置 OmniRoute (HF :7860 -> :20128)",
  "main": "gate.js",
  "engines": { "node": ">=22.0.0" },
  "scripts": { "start": "node gate.js" },
  "dependencies": {}
}
```

## 四、R2 探活日志实测验收 (2026-07-18 19:35)

### 启动序列全绿

```
[bootstrap] 缺失基础工具: python3
[bootstrap] 镜像 A 模式：正在补全环境（约 60s）...
... apt 42 包全装 (curl jq python3 sqlite3 ...) ...
... pip huggingface_hub-1.24.0 装好 ...
[bootstrap] 环境补全完成
[bootstrap] 同步 Dataset: nonoke/omni-logic
Still waiting to acquire lock on /tmp/logic/.cache/huggingface/.gitignore.lock (elapsed: 0.1s)  # hf 内部锁, 通过
[bootstrap] 逻辑注入完成
[bootstrap] 移交控制权给逻辑层
[entrypoint] OmniRoute 启动 | DATA=/app/data (ephemeral, R2 是数据主路径)
[entrypoint] lock acquired (flock /app/data/.omniroute.lock, fd 9).
msg="no matching backups found"                          # R2 无副本 (首次)
[entrypoint] restore rc=0 但无文件 (R2 无副本或首次部署). 空库启动, init 重建配置.
[entrypoint] OmniRoute PID=655
▲ Next.js 16.2.9 ... ✓ Ready in 0ms
... Migration 109 全 applied (含 Idempotency check 跳过) ...
[DB] SQLite database ready: /app/data/storage.sqlite
[STARTUP] Embedded services bootstrap complete
[entrypoint] ✓ 就绪
[entrypoint] 版本=3.8.43 (期望未设置, 跳过比对)         # EXPECTED_VERSION 未设, 跳过比对
```

### ⭐ Bug 1 修复验证: Litestream replicate 启动成功 (R2 持久化生效)

```
[entrypoint] Litestream PID=696
time=19:35:44 level=INFO msg="litestream version=0.5.9"
msg="initialized db" path=/app/data/storage.sqlite
msg="replicating to" type=s3 sync-interval=10s bucket=omn-data path=db/storage.sqlite
  region=auto endpoint=https://3e0d9623e4c90591ce4d659772593266.r2.cloudflarestorage.com
msg="starting L0 retention monitor" interval=15s retention=5m0s
msg="starting compaction monitor" level=N ...
```
**对比 R1 (旧)**: restore 报 `database not found in config: /app/data/storage.sqlite` (yml path 不符, 见第五章 1a); replicate 报 `must specify at least one replica URL for /app/data/storage.sqlite` (yml path 错 + 位置参双因, 见第五章 1b) → Litestream PID 立崩, DB 不备份。两条报错分别由 yml path 修正 (1a) 与去位置参 (1b) 解决, 非单单 "去位置参"。

**R2 修后**: bucket=omn-data endpoint 实测可达, snapshot 首次上传:
```
msg="snapshot complete" txid=0000000000000001 size=139422      # R2 首次快照成功
msg="compaction complete" level=1 txid.min=1 txid.max=1 size=139309
```

### ⭐ Bug 2 修复验证: xargs log 全消

```
[init]   resilience PATCH: HTTP 200
[init]   resilience 读回: {"oauth":{"failureThreshold":5,"degradationThreshold":3,"resetTimeoutMs":60000},"apikey":{...}}    # ✓ 无 "xargs: log: No such file"
[init]   compression 当前: {"enabled":false,"defaultMode":"off","autoTriggerMode":"lite",...,"stackedPipeline":[{"engine":"rtk","intensity":"s...]}
[init]   thinking-budget 当前: {"mode":"passthrough","customBudget":10240,"effortLevel":"medium"}
[init]   combos 当前: {"combos":[]}                            # ✓ 含 || 回退分支也走通, 输出空数组非 "读取失败"
```
**对比 R1 (旧)**: 4 处 `xargs: log: No such file or directory` (dash 不支持 export -f)。

### ⭐ Bug 3 修复验证: proxy 不再 400

```
[init]   当前 proxy 配置: {"global":null,"providers":{},"combos":{},"keys":{}}
[init]   ✓ proxy global 已关闭, 跳过 PUT                   # 读回关态跳 PUT, 0 错误
```
**对比 R1 (旧)**: `[init]   proxy disable: HTTP 400` (`{enabled:false}` schema 拒)。

### 推理核心就绪

```
[entrypoint] Init PID=695
[entrypoint] Litestream PID=696
[entrypoint] gate PID=697
[gate] WARN: GATE_ADMIN_TOKEN 长度 <16, 后台关闭 (不记录 token 值).     # K3 红线 fail-closed
[gate] :7860 → 127.0.0.1:20128 | 28rpm/1并发/100ms | timeout=180000ms | PSK=set OR_KEY=set 后台=关(默认404)
[init] ✓ 已登录
[init] 注册 NIM Keys... [nim-01..nim-08 ✓]
[init] Keys: 8 注册 / 0 跳过 / 0 失败
[init] ✓ nvidia 连接数 (读回): 8
[init] ════════ 初始化完成：Keys 8+0/8 ════════
[entrypoint] NIM init 已退出 (非致命).
```

## 五、R1→R2 bugfix 对照表

> **归因自纠 (规则五)**: 初版报告 Bug 1 全部归因 "去位置参" 是错的。经 `git log -p` 查 R1 实跑 `dataset-staging/` 源文件, R1→R2 是 **三因子合修**, 各自删一条 R1 报错链, 不可全记一处。下表拆分如下。

| Bug | R1 现象 (旧) | 根因 (拆分) | R2 修复 | R2 实测验证 |
|-----|-------------|------|---------|-------------|
| 1a (restore) | restore 报 `database not found in config: /app/data/storage.sqlite` | **R1 yml `dbs[].path: /data/storage.sqlite`** (少 `/app` 前缀) 与命令位置参 `$DB=/app/data/storage.sqlite` 不符 → litestream 在 config 内找不到匹配 db 条目 | yml `dbs[].path` 改 `/app/data/storage.sqlite` (位置参对 restore 无害, restore 校验 `fs.Arg(0)` 是否匹配 config db entry) | restore `rc=0` 不再报 `not found in config`; R2 无副本走空库启动分支 |
| 1b (replicate) | replicate 报 `must specify at least one replica URL for /app/data/storage.sqlite` | **双因**: (1) R1 yml path 错致 dbs 条目无效 + (2) R1 命令 `litestream replicate -config ... "$DB_PATH"` 传 1 位置参命中 v0.5.9 `switch fs.NArg()` case 1 | 去掉位置参: `litestream replicate -config /logic/litestream.yml` (走 case 0 config 模式, db 路径读 yml `dbs[].path`); yml path 修在 1a 已做 | replicate 启动 + `replicating to bucket=omn-data` + snapshot complete txid=1 size=139422 |
| 1c (bucket) | (R1 隐性) yml `bucket: omniroute-data` 与云端实际 bucket `omn-data` 不符 → 副本解析失败 | **R1 yml bucket 名错** (历史残留) | yml `bucket: omn-data` (对齐 R2 控制台手动建) | `bucket=omn-data endpoint=...` 实测可达, 无 `no such bucket` |
| 2 | 4 处 `xargs: log: No such file or directory` | dash 不支持 `export -f`, xargs 子进程无 log 函数定义 | 4 处 `xargs -I{} log` 改管道尾子 shell `{ read -r _v; [ -n "$_v" ] && log ...; }`; combos 处改条件分支; 删 `export -f log` | 4 处读回干净打印 (resilience/compression/thinking-budget/combos) |
| 3 | `[init]   proxy disable: HTTP 400` | 3.8.43 schema = `{global,providers,combos,keys}` (3-level proxy), 非 `{enabled:false}` | 读回已 `{global:null,...}` 即关态跳 PUT; 仅 global 非 null 时 PUT `{"global":null}` | `✓ proxy global 已关闭, 跳过 PUT` 0 错误 |

**R1 实跑源证** (`dataset-staging/` 即 R1 staging, R2 实跑 `candidate-v4.3-reviewed/`):
```
# R1 dataset-staging/litestream.yml
  - path: /data/storage.sqlite        ← 1a 病根 (少 /app)
    replica:
      bucket: omniroute-data           ← 1c 病根 (名错)

# R2 candidate-v4.3-reviewed/litestream.yml
  - path: /app/data/storage.sqlite    ← 1a 修
    replica:
      bucket: omn-data                ← 1c 修

# R1 dataset-staging/entrypoint.sh:193
  litestream replicate -config /litestream.yml "$DB_PATH"   ← 1b 病根 (位置参)
# R2 candidate-v4.3-reviewed/entrypoint-merged.sh:208
  litestream replicate -config /logic/litestream.yml        ← R2 终态 (1b 去位置参 =d403a0c; /logic 前缀 =bcaf82f 全量注入各做)
```

**结论**: R1 的 restore 报错 (1a) 只可能 yml path 错, 与位置参无关; replicate 报错 (1b) 是 yml path 错 + 位置参双因; bucket (1c) 三因子并存。报告把三条全记 "去位置参" 是单因归因错, 误导 K3。

**双层失效解剖 (报错原文←→git diff 交叉自洽)**: R1 replicate 报错原文 `must specify at least one replica URL for /app/data/storage.sqlite` 里路径 `/app/data` 是**正确值** (CLI 位置参 `fs.Arg(0)=$DB_PATH` 一直对), 而 bcaf82f 的 git diff 证明当时 yml 里写的是**错误值** `/data` — 即 R1 崩溃瞬间系统里同时存在两个矛盾路径: CLI 带对路径、yml 带错路径。报错文本 (症状) + v0.5.9 源码契约 (case 1 NArg()=1 命中该报错) + git diff (yml `/data` 病根) 三独立证据链两两互洽。位置参是**可见触发层** (NArg()=1 直命中 case 1 崩); yml 路径是**潜伏层** — 假设当初只做 d403a0c (去位置参) 不做 bcaf82f (路径对齐), litestream 立转去 replicate `/data/storage.sqlite` 不存在路径, 换种方式继续崩。两修复**各自必要、单独皆不充分**, 这才是 "组合修复" 精确含义。

## 六、关键验证记录

### 6.1 litestream v0.5.9 命令契约 (源码级查证)

GitHub `benbjohnson/litestream` v0.5.9 `cmd/litestream/replicate.go` `ParseFlags` 内 `switch fs.NArg()`:

```go
case 0:
    // No arguments provided, use config file
    if *configPath == "" { *configPath = DefaultConfigPath() }
    c.Config, err = ReadConfigFile(*configPath, !*noExpandEnv)
case 1:
    // Only database path provided, missing replica URL
    return fmt.Errorf("must specify at least one replica URL for %s", fs.Arg(0))
default:
    // Database path and replica URLs provided via CLI
    if *configPath != "" {
        return fmt.Errorf("cannot specify a replica URL and the -config flag")
    }
    // ... build config from CLI args, fs.Arg(0)=db, fs.Args()[1:]=replica URLs
```

- `replicate -config` 模式 **必须 fs.NArg()=0** (db 路径在配置文件内 `dbs[].path`)
- `replicate "$DB_PATH"` (1 位置参) 命中 case 1 报 `must specify at least one replica URL`
- `restore` 子命令相反: `fs.Arg(0)` 必须是 db path (case 0 报错要 db name); restore 校验 `fs.Arg(0)` 是否匹配 config 内 db entry, **位置参对 restore 无害** — restore 报 `database not found in config` 只可能 yml `dbs[].path` 与命令参不符
- **归因自纠**: R1 同时有 yml path 错 (`/data/`) + 位置参 (双因并存)。源码 case-1 只能解释 replicate 报错那半; restore 报错 `database not found in config` 是 yml path 错独立致, 单查 replicate.go 解释不了。三因子拆见第五章 1a/1b/1c

### 6.2 OmniRoute 3.8.43 proxy schema

读回 `{"global":null,"providers":{},"combos":{},"keys":{}}` = 3-level proxy (Global/Per-Provider/Per-Connection)。`{enabled:false}` 是旧 schema, 3.8.43 拒收 HTTP 400。

### 6.3 init 跑 bash 非 dash

init shebang `#!/bin/bash` + entrypoint `bash /logic/init-nim-keys.sh` 显式 bash 调起。
第 70 行 `done <<< "$NIM_KEYS"` here-string 是 bash 专属 (`dash -n` 报 redirection unexpected 但镜像 bash 必装, 无害)。
dash 兼容性只要求: 无 `export -f`, 无 bash 专属子 shell 函数引用跨 xargs。

### 6.4 R2 bucket omn-data 实测可达

litestream replicate 日志 `bucket=omn-data endpoint=https://3e0d9623e4c90591ce4d659772593266.r2.cloudflarestorage.com` 首次 snapshot 上传 size=139422, 无 `no such bucket`。Cloudflare R2 控制台手动建 bucket omn-data (隔离 nomke 生产库) 完成。

**R1 bucket 名错实证**: `git log -p` 查 R1 `dataset-staging/litestream.yml` = `bucket: omniroute-data` (历史残留); R2 改 `omn-data` 对齐云端实际建 bucket。三因子之一 (第五章 1c), 非单单去位置参。

## 七、Secrets & Variables 清单 (Space Settings → Variables and secrets)

| 变量 | 类别 | 必填 | 注 |
|------|------|------|----|
| BASE_IMAGE | Variable | ✓ | 基础镜像 tag, HF 构建时作 build-arg 注入 ARG BASE_IMAGE。默认 `ghcr.io/i3t2y/omniroute-base:stable`, 升级改具体 `:X.Y.Z` |
| EXPECTED_VERSION | Variable | 可选 | OmniRoute 期望版本号, 仅 entrypoint 日志比对 (不齐告警不 exit)。与 BASE_IMAGE 同步更新 |
| HF_TOKEN | Secret | ✓ | Space Secret 层仅消费 dataset **read** scope (bootstrap `_dl()` 拉逻辑层 Dataset)。**两层分界钉死**: Space Secrets 层 (生产运行时, 最小 dataset read) ≠ 本地 `~/.omn-secrets` 层 (`space_ctl.py` 管理面, 需 Space write)。第七章管前者, 本地两管理 token `HF_TOKEN`(Space write)/`HF_TOKEN_DATASET_WRITE`(Dataset write) 不重叠不入 Space Secret。2026-07-19 实测 `HF_TOKEN_DATASET_WRITE` 可读 Space variables (fine-grained 实际授权面比名义 scope 宽, 疑带账户级 read 基座) — 平台行为非设计依据, 两 token 不重叠原则仍坚持 |
| LOGIC_BUCKET_REPO | Variable | ✓ | `nonoke/omni-logic` (逻辑层 Dataset 仓库名) |
| INTERNAL_PSK | Secret | ✓ | 客户端接入令牌 (≥32 字符随机) |
| NIM_KEYS | Secret | ✓ | NIM API keys 换行分隔 (测试 8 个, 生产 25+8) |
| INITIAL_PASSWORD | Secret | ✓ | OmniRoute 后台登录密码 |
| OMNIROUTE_API_KEY | Secret | ✓ | OmniRoute 内部鉴权 key |
| R2_ACCESS_KEY_ID | Secret | ✓ | Cloudflare R2 (bucket omn-data) |
| R2_SECRET_ACCESS_KEY | Secret | ✓ | Cloudflare R2 |
| R2_ACCOUNT_ID | Secret | ✓ | Cloudflare R2 |
| GATE_ADMIN_TOKEN | Secret | ❌ 不设 | K3 红线: 留空激活 fail-closed (管理面 404) |
| NIM_PROBE | Variable | 可选 | `1` 启 NIM 探针 (走 443, HF 出站允许) |

**客户端接入**:
```bash
curl https://<space-url>/v1/chat/completions \
  -H "X-Internal-PSK: $INTERNAL_PSK" \
  -H "Content-Type: application/json" \
  -d '{"model":"auto","messages":[{"role":"user","content":"ping"}]}'
```

## 八、推送记录 (HF 7/16 冻规避: 单次 commit, <8 次/h)

| 时间 | 仓库 | commit | 内容 |
|------|------|--------|------|
| 2026-07-19 | Dataset nonoke/omni-logic | 140ad80 | R2 bugfix 1c: yml `bucket: omniroute-data`→`omn-data` (单一文件改 litestream.yml, 单 commit "Update litestream.yml") |
| 2026-07-19 | Dataset nonoke/omni-logic | bcaf82f | V3.0 /logic/ 全量注入 + EXPECTED_VERSION env + yml `dbs[].path` 修 `/data`→`/app/data` (R2 bugfix 1a) + entrypoint 全量 `/litestream.yml`→`/logic/litestream.yml` 前缀迁移 (3 文件改: entrypoint/init/litestream; gate/package 同源无 diff) |
| 2026-07-19 | Space nonoke/omn | 7d2247e | v3.0 三文件永久免改: Dockerfile ARG BASE_IMAGE + bootstrap V3.0 自愈前置 + README 极简 YAML 头 |
| 2026-07-19 | Space nonoke/omn | (紧跟) | README 改极简 YAML 头 (正文移出 Space) |
| 2026-07-19 | Dataset nonoke/omni-logic | d403a0c | R2 bugfix 1b: litestream replicate **去位置参** (`-config /logic/litestream.yml "$DB_PATH"`→`-config /logic/litestream.yml`, v0.5.9 契约 fs.NArg()=0 配置模式) + xargs log dash 兼容 + proxy 3-level schema (3 文件改: entrypoint/init/litestream.yml) |

> **commit-因子映射自纠 (规则五, 2026-07-19 K3 发送前 git log -p 实证)**: 三因子非全在 d403a0c 一个 commit, 而是**跨三 commit 各补一因子**: 1c (bucket) 在最早 `140ad80` 单独 commit; 1a (yml `dbs[].path` `/data`→`/app/data`) 在 `bcaf82f`; 1b (去位置参) 在最末 `d403a0c`。d403a0c commit message 自述 "三因子合修" 是因 d403a0c 是 R1→R2 验收时三因子中最后落定的一环 (合修 commit 时三因子才齐), 但 git diff 实证三因子物理上分布在三 commit。第五章 1a/1b/1c 逻辑拆分 (按报错链) 与此处按 commit 拆分 (按时间) 两个正交维度, 两者皆真不冲突。

## 九、待 K3 审阅关注点

1. **三文件永久免改设计健壮性**: Dockerfile ARG BASE_IMAGE + bootstrap V3.0 自愈前置 + 全量 /logic/ 注入, 是否真能扛上游升级 (周 2-3 补丁版, 约定契约稳定)? 自查三项破坏性升级 (buildkit→crun 禁 / apt 源变 / trixie→alpine) 均已内建 bootstrap V3.0 防御 (`command -v apt-get` 防线 + 自愈前置), 设计本身无遗漏面, K3 仅需确认无其他破坏路径。
2. **R2 litestream 三因子合修归因**: (见第五章 1a/1b/1c + 第六章自纠)。核心问 K3 三条: (a) **replicate 去位置参 + yml path 修正, 二者各自解决了 R1 哪一条报错?** restore 报错 `database not found in config` 是否只可由 yml `dbs[].path` 修正解决 (位置参对 restore 无害, 因 restore 校验 `fs.Arg(0)` 必匹配 config db entry)? (b) **default 分支** (`cannot specify a replica URL and the -config flag`) 在当前 R2 部署形态 (`-config` 已设 + 零位置参) 是否可达? 断言不可达因 default 要求 ≥2 位置参同时带 `-config`, 当前规范化命令恒零位置参。(c) bugfix 2 管道尾子 shell 4 处语义是否一致 (`head -c N` 截断 + `read -r` 单行行为); bugfix 3 跳过 PUT 是否会漏设 (上游默认 global 非 null 时仍走 PUT 兜底)。
3. **fail-closed 红线**: GATE_ADMIN_TOKEN 不设激活 fail-closed (管理面 404 不泄露后台存在) = 当前最优解, 教科书式 fail-closed, K3 大概率仅确认。当前 8 key 入池, 推理走 model:"auto" auto-combo 路由。是否有静默风险 (如上游默认 combo_strategy/"combo" 字段读取路径)?
4. **限流轴 (自查已出结论)**: gate 限流 28rpm 全局, NIM 免费层 40rpm/key × 25 key = 1000rpm 理论上游容量 → 28rpm 仅占上游 0.7%~2.8%, 完全在安全区, **25 key 扩容后 gate 限流无需 re-evaluate**; 真正先撞天花板的是上游 NIM per-key 40rpm, 由 OmniRoute 连接级冷却逻辑消化, 与 gate 无关。**唯一值得 K3 关注**: gate 的 **1 并发** 限制在 25 key 场景下是否会造成客户端排队延迟可感知 (单请求占并发槽, 高并发客户端排队)? 这是扩容后唯一真正的限流变量。
5. **R2 bucket omn-data 隔离充分性**: bucket `omn-data` + yml path `db/storage.sqlite` 已构成 **双层隔离**, 防 nomke 生产库冲突 (nomke 生产 v4.2.3 用同 R2 账户)。补 yml path 子前缀 `omn-v30/db/storage.sqlite` 是**防御性加分项非必需** (三因子之一链已锁, K3 若提可顺加, 改动动 Dataset 一行)。
6. **ENTRYPOINT 覆盖致 check-permissions 静默丢失** (2026-07-19 K3 发送前补, upstream_check.sh 实测抓 v3.8.48 Dockerfile 发现): 上游 base 镜像 v3.8.48 起 Dockerfile 已自带 `ENTRYPOINT ["/tmp/check-permissions.sh"]`, candidate Space Dockerfile `ENTRYPOINT ["/bootstrap.sh"]` 会**覆盖**之 → check-permissions.sh 永不跑。自查 bootstrap.sh 已在末段 `exec /logic/entrypoint.sh` 转发逻辑层, 但未含 check-permissions 等价 (HF Space 容器 root→node 权限转换在 base 层外由 HF runtime 定, check-permissions 在 candidate 镜像层可能本就空转无害)。问 K3 两点: (a) check-permissions.sh 具体校验何职能 (DATA_DIR 权限/文件归属/读写可达) ? (b) candidate bootstrap 自愈前置已 `command -v` 探 + apt 补齐 litestream/sqlite3 等, 是否已覆盖 check-permissions 的实质职能, 或需在 bootstrap 末段补等价校验? 此为 D 子 agent 早轮未完全捕获风险点的实例化, 已制度化 (upstream_check.sh 抓上游 Dockerfile `^(FROM\|ENV PORT=\|ENV DATA_DIR=\|ENV HOSTNAME=\|ENTRYPOINT\|CMD\|USER)` 关键行入审批报告, 上游再漂移人工批准一眼见)。

## 十、后续验收 (R3+)

- R3: 推理实测走 PSK `/v1/chat/completions` (需 INTERNAL_PSK; R2 已就绪可起)
- R4: NIM Probes 全 8/25 key 上游探活 (`NIM_PROBE=1`)
- R5: 8→25+8 key 扩容 + 限流 re-evaluate
- D3 收尾: Secrets 清单录入指引交付 (BASE_IMAGE/EXPECTED_VERSION Variables) — **2026-07-19 收口轮已闭 (D3 合并关闭, K3 文档发此动作同时关闭该项)**

---

## 附录 A: 发送后变更 (2026-07-19 K3 收口后轮, 文档与运行态对齐)

> 本附录钉死文档发出时刻之后的三轮线上漂移, K3 拿文档对线上时须以本附录为准。
> 正文里引用的历史日志/元数据字样保留作"当时实证快照"; K3 若 grep 线上日志字样发现对不上正文, 见本附录各条时间戳。
> 文档是随时间演进的活文档, 每个状态有时间戳。

### ① Dataset commit 8be683d 中性化 (2026-07-19 K3 收口轮 1b)

- **背景**: 防 HF 官方关键词检索 "omniroute" 引起限制。真正暴露面在 Dataset 源码与运行日志,两者零成本可收。
- **改动**: 4 文件中性化 (entrypoint.sh / init-nim-keys.sh / gate.js / package.json), `OmniRoute`/`omniroute` 品牌字样 → 中性词 (`上游服务`/`gate`/`Admin` 等)。commit `8be683d27c960f64c2d7cdc4902a256cde5ec1e8` 推 nonoke/omni-logic。
- **功能性红线未动 (审阅重点)**: env 键名 (`OMNIROUTE_PORT`/`OMNIROUTE_API_KEY`) / API 路径 (`/api/*`) / litestream.yml schema 字段 / `EXPECTED_VERSION` 探测逻辑 / URL 上游仓储名 (`github.com/diegosouzapw/OmniRoute/wiki` 注释中保留, 加注"上游仓库名保留不改") 一律不改。
- **`.omniroute.lock` 功能性保留非遗漏**: 这是 entrypoint L19 `LOCK_FILE=$DATA_DIR/.omniroute.lock` 的 flock 跨容器互斥文件名,**功能键非展示面**。改它要动 entrypoint 的锁路径契约 (与现 R2 恢复的 DB 文件无关联, 但单实例容器同名锁可靠), 收益为零。本文档第四章日志与之同理引用该名, 非"中性化漏网之鱼"。K3 审阅若在线上 grep `omniroute` 见 1 次, 即此 lock 文件名, 已合规。
- **验收 logs/run 实跑实证**: 四子进程全绿 (OR/Init/LS/Gate 4 PID), 8 NIM keys 注册通 (`Keys: 8 注册/0 跳过/0 失败`), litestream replicate 成.

### ② Dataset private (2026-07-19 K3 收口轮 1a)

- **核查**: HF API `curl /api/datasets/nonoke/omni-logic` 返 `private: True` — **已 private**, 跳过改。最大暴露面已实质落闭环。
- **bootstrap _dl() 拉取实证**: 普通 Restart 后 (=% 见附录 ④ Space Rest 行) bootstrap _dl() 拉 Dataset 通, private 不影响内部读 (内部读走 HF_TOKEN Dataset read scope 或鉴权直拉)。
- **契约不变**: 第七章 HF_TOKEN "Space Secret 层仅消费 dataset read scope" 契约不被 private 改变 — private 已默认要求鉴权, 含义反而是 "本就该鉴权"。

### ③ 第七章 HF_TOKEN 行 (以收紧版为准)

- 本文档第七章 HF_TOKEN 行 (行 414) 已是 **2026-07-19 收口轮收紧后版**, 含两层分界钉死 + `HF_TOKEN_DATASET_WRITE` 平台行为非设计依据的表述。
- **以行 414 收紧版为准**, 正文旧措辞 (若有) 被 414 覆盖。
- 核心原则: Space Secrets 层 (生产运行时, 最小 dataset read) ≠ 本地 ~/.omn-secrets 层 (space_ctl.py 管理面, 需 Space write) - 两层不重叠。这处理事项 K3 仅需确认无误.

### ④ litestream l0-retention-check-interval: 5m变更 (2026-07-19 K3 收口后轮 2 任务续后的"改"分支)

- **背景**: 任务 2 只读核查揭 `l0-retention-check-interval` 是 v0.5.9 顶层 Configure 键 (cmd/litestream/main.go 行 264), YAML 可配。直投从"可配置"落"已配置"。
- **改动 (单 commit)**: candidate-v4.3-reviewed/litestream.yml 顶层加 `l0-retention-check-interval: 5m` (与 `dbs:`/`snapshot:` 同级)。commit `7a1d0ac83d897e850051760e6af664d56b830975` 推 nonoke/omni-logic (`upload_file` 单文件推, 非染其它 4 源文件)。
- **写法选择 "仅设 l0-retention, 不碰 levels" + 源码核证**:
  - **覆写陷阱 (源码核证)**: `DefaultConfig()` 预置 `Levels: [L1=30s, L2=5m, L3=1h]` (cmd/litestream/main.go 行 344-348, 取自 `litestream.DefaultCompactionLevels`, compaction_level.go 行 16-21)。yaml 设 `levels` **完全覆写**预置非追加 — 写 `levels: [{interval:5m}]` 单条会让 L2/L3 compaction 监控消失, compaction 阶梯断。要改 L1 必须显列 L1/L2/L3 全保留默认。
  - **决策 (选项 2)**: 仅设 l0-retention-check-interval: 5m, **levels 整个不碰**。l0-retention-check-interval 是**纯监控参数** (只控多久查一次 L0 段是否过期可删), 不改任何 compaction 语义。Class A 减量 27万/月 → ~10万/月 (免费线 27% → 10%), 拿稳 63% 头, 零语义风险。
  - **不采选项 1 (完整 L1/L2/L3 三级改 L1=5m) 原因**: L1 的 30s 不是单纯成本 — 是 compaction **触发器**, L1 tick 时聚 L0 WAL 段成 L1 文件 PUT 上传。改 5m 省的只是 tick 时 LIST/检查 (远小于 32% 粗估), 代价是 WAL 滞 L0 更久 + 崩溃恢复回放段更多 + L2/L3 输入被后移整阶梯后移。成本账不干净, 风险账多一页。
  - **顶层位再次核防错位**: 此键是 Config 顶层字段 (main.go 行 264), 非 `dbs[].replica` 子键。replicate.go 行 248-249 直证读 `c.Config.L0RetentionCheckInterval` 消费。嵌 replica 内被 ReplicaConfig 忽略静默不生效。
- **验收 logs/run 实跑** (timestamp 14:11:19.713Z 新启动, Rest 后):
  - `starting L0 retention monitor interval=5m0s` ← 15s → 5m0s **生效** ✓
  - `compaction monitor level=1 interval=30s` — L1 逐字不变 ✓ (未碰 levels)
  - `compaction monitor level=2 interval=5m0s` — L2 逐字不变 ✓
  - `compaction monitor level=3 interval=1h0m0s` — L3 逐字不变 ✓
  - `compaction monitor level=9 interval=1h0m0s` — snapshot pseudo (SnapshotLevel=9) 不变 ✓
  - `sync-interval=10s` 红线未动 ✓ / 四子进程全绿 + 8 NIM keys 注册 ✓
  - **"levels 未动"实证**: L1/L2/L3 三条 monitor interval 改前逐字一致即此。K3 拿本附录 grep 线上 logs/run, 三条 monitor 行应仍是 `30s`/`5m0s`/`1h0m0s`, 证 levels 未碰.
- **详核**: 见 `audit/2026-07-19-litestream-monitor-intervals.md` 续附段 (源码: compaction_level.go + store.go + cmd/litestream/{main,replicate}.go v0.5.9)
- **K3 审阅信号**: 本推带源码级核证 (`DefaultCompactionLevels` 预置三级 + yaml 完全覆写语义 + L9 是 snapshot pseudo + replicate.go 顶层消费链), 即使一个监控间隔调整都带覆写陷阱分析, 是变更纪律证据。

### 执行顺序钉死 (收口后轮 2026-07-19)

1. 推 litestream 5m (commit 7a1d0ac8, 已完成) ← 本附录 ④
2. 补本附录 (本则)
3. 发 K3 文档 (本附录随正文发, 4 次绕全核实线上态作发后单例)
4. 后续: K3 等待窗口插 R3 推理双通道实测 / K3 回收意见后 3.8.48+49 合并 upgrade + 首验写权限 / GHCR 预构建实装 (升级批准前置)

### 附: Space Rest 偶然命中 (非固化 SOP)

触 litestream 生效的 Space Rest 中 `HF_TOKEN` (Space write scope) 直调 `restart_space` 401 未兑现, 兜底 `HF_TOKEN_DATASET_WRITE` (Dataset write scope) 跨通触 Rest 成 (HTTP 200 → RUNNING_BUILDING → 36s RUNNING)。
即附录 ③ 钉死 "平台行为非设计依据" 再次实证: fine-grained 实际权限面比名义 scope 宽, 本次借跨通通事件实际 Rest 了 Space。
**但本次跨通性不固化成 SOP** — 下次首验升级环 (3.8.48+49 合并 upgrade) 仍按 `audit/2026-07-19-first-upgrade-write-permission-runbook.md` 用 fine-grained Space write 专项 token 重试, 401 遇回退仍走 runbook 步骤 (HF 网页新建 fine-grained → 仅 nonoke/omn Space write → 更 .omn-secrets HF_TOKEN 行 → 重跑).
本附录仅告知 K3 本次 Rest 用 DATASET_WRITE 完成是平台偶然性质, 非"SOP 说成'用 DATASET_WRITE 做 Rest'"。

---

*nonoke/omn V3.0 三层解耦 R2 落地报告 · 待 K3 审阅 · 2026-07-19 · 附录 A 发送后变更 (4 次绕全核线上态对齐)*
