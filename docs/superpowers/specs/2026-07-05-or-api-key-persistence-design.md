# OR_API_KEY 跨重建固定化设计

- 日期：2026-07-05
- 分支：fusion-main
- 范围：`gate.js`、`entrypoint.sh`、`init-nim-keys.sh`
- 状态：待批准

## 1. 背景与问题

当前 `OR_API_KEY` 由 `init-nim-keys.sh` 调用 OmniRoute `/api/keys` 现场生成，写入普通文件 `/data/.or-api-key`。`gate.js` 启动时读该文件作上游 `Authorization: Bearer`。

跨重建（HF Space rebuild）失效点：
- `.or-api-key` 是普通文件，不在 sqlite，不被 Litestream 备份。
- 若 `/data` 不持久或 R2 restore 失败，文件丢失 → init 重新生成新 key → sqlite 中累积重复 key，外部持有旧 key 失效。
- 鉴权链路依赖 init 脚本时序（gate 启动强制要求 `.or-api-key` 存在），存在 race。

## 2. 源码级查证结论（上游 `github.com/diegosouzapw/OmniRoute`）

关键事实：

1. `POST /api/keys`（`src/app/api/keys/route.ts`）用 Zod `createKeySchema` 校验，仅接受 `name / noLog / scopes / allowUsageCommand / usageLimitEnabled / dailyUsageLimitUsd / weeklyUsageLimitUsd`，**不接受自定义 key 值**。key 由服务端 `createApiKey()` 自动生成。

2. `createApiKey`（`src/lib/db/apiKeys.ts`）：将 key 双存于 `api_keys` 表 — `key`（**明文**）+ `key_hash`（SHA-256 hex，用于快速查找）。
   - **修正既往误判**：上游 AES-256-GCM 加密的对象是 `provider_connections.credentials`（NIM key、OAuth tokens），**非** `api_keys.key`。`api_keys.key` 是明文，shell 可用 `sqlite3` 读出。即"SQLite 感知复用"技术可行（不是被加密阻断），仅因代码用文件标记判断而未实现。
   - **选型理由修订**：env-bypass 方案优越性不因上述修正而削弱——即便 SQLite 复用可行，env-bypass 仍更优：不依赖 Litestream restore 成功（restore 失败则 DB 无记录可读）、不依赖 init 脚本时序（无需先查 DB 再决定复用还是创建）、是上游原生支持的零侵入机制。选型理由从"克服加密存储约束"修订为"减少运行时依赖环节"。

3. **`validateApiKey` 第 1 步 env-key 旁路**（同文件）：
   ```ts
   if (key === process.env.OMNIROUTE_API_KEY || key === process.env.ROUTER_API_KEY) return true;
   ```
   即设环境变量 `OMNIROUTE_API_KEY`，该值即合法 key，**无需在 sqlite 存在记录**，且不依赖 Litestream restore。

## 3. 设计：HF Space Secret 驱动 + env-bypass + 旧链路 fallback

### 3.1 核心机制

放弃"`.or-api-key` 文件 + `/api/keys` 现场生成"作主路径，改用上游原生 env-bypass：

- HF Space Secret `OMNIROUTE_API_KEY` = 用户预生成的固定强随机串（HF Space 持久，跨重建不变）。
- `entrypoint.sh` 透传该 env 给 `node /app/server.js` → 上游 `validateApiKey` env-bypass 放行。
- `gate.js` 用同一 Secret 作上游 `Authorization: Bearer`。
- `init-nim-keys.sh` 检测到该 env 存在时跳过 `/api/keys` 创建段。

### 3.2 fallback（保留旧链路）

未设 `OMNIROUTE_API_KEY` 时，保留原 `/api/keys` 生成 + `/data/.or-api-key` 文件链路，不破坏现有部署。

### 3.3 组件改动

#### 3.3.1 `entrypoint.sh`

- `node /app/server.js` 的 env 块新增透传：
  ```sh
  OMNIROUTE_API_KEY="$OMNIROUTE_API_KEY" \
  ```
- 等待 `.or-api-key` 的硬超时段改为：env `OMNIROUTE_API_KEY` 存在时跳过该等待（gate 不再依赖该文件）。

#### 3.3.2 `gate.js`

- `OR_API_KEY` 来源优先 `process.env.OMNIROUTE_API_KEY`，回退读 `/data/.or-api-key`。
- 防御性读取（`fs.readFileSync` 文件不存在抛 ENOENT 而非 falsy，需 try/catch，否则 env 与文件皆缺时未捕获异常崩溃而非走显式 fatal）：
  ```js
  let OR_API_KEY = (process.env.OMNIROUTE_API_KEY || '').trim();
  if (!OR_API_KEY) {
    try {
      OR_API_KEY = fs.readFileSync('/data/.or-api-key', 'utf8').trim();
    } catch (e) { /* 文件不存在，保持空 */ }
  }
  if (!OR_API_KEY) {
    console.error('[gate] FATAL: No OR_API_KEY (neither OMNIROUTE_API_KEY env nor /data/.or-api-key file)');
    process.exit(1);
  }
  ```
  env 分支补 `.trim()` 与文件分支对称防御：env-bypass 是严格字符串相等比对，若 HF Secret 注入意外携带首尾空白会致比对失配 401；同理 `Authorization: Bearer <值>` 含空白会偏差。`trim` 对正常 Secret 无影响，零成本容错。
- 启动校验改为：env 存在 **或** 文件存在二者居其一即可；二者皆无才 fatal（对齐现有 `INTERNAL_PSK` 缺失即 fatal 风格）。
- **PSK 间接层保留不变**：本方案仅改 `OR_API_KEY` 获取方式（gate→OmniRoute 内层鉴权），`INTERNAL_PSK` 校验 + 请求头替换（客户端→gate 外层鉴权）原样保留。两层职责：

  | 层级 | 凭证来源 | env-bypass 后变化 |
  |------|----------|-------------------|
  | 外层（客户端→gate） | `INTERNAL_PSK` | 不变 |
  | 内层（gate→OmniRoute） | `OR_API_KEY` | 从动态创建改为固定 env |

#### 3.3.3 `init-nim-keys.sh`

- "创建或复用 OmniRoute 内部 API Key"段（当前第 133-164 行）开头加守卫，**env 分支显式赋 `OR_KEY`**（供后续步骤使用，而非仅靠镜像文件 + 后段 `cat` 间接取值）：
  ```sh
  if [ -n "$OMNIROUTE_API_KEY" ]; then
    OR_KEY="$OMNIROUTE_API_KEY"                      # 关键：供后续 export-json 等使用
    echo "$OMNIROUTE_API_KEY" > "$OR_API_KEY_FILE"   # 写文件镜像，供诊断/兼容
    chmod 600 "$OR_API_KEY_FILE"
    echo "[init] OMNIROUTE_API_KEY env set, env-bypass 模式，跳过 /api/keys 创建。"
  elif [ -f "$OR_API_KEY_FILE" ] && [ -s "$OR_API_KEY_FILE" ]; then
    OR_KEY=$(cat "$OR_API_KEY_FILE")
    ...复用旧文件...
  else
    ...原 /api/keys 创建逻辑，赋值 OR_KEY...
  fi
  ```
- **后续 `OR_KEY` 消费点同步**：第 411-415 行与 569-573 行的配置快照导出块（`/api/settings/export-json` 用 `Authorization: Bearer $OR_KEY`）当前各自 `OR_KEY=$(cat "$OR_API_KEY_FILE")`。env 模式下虽能 `cat` 出镜像值（env 分支已写镜像 → env-bypass 放行），但为对齐 env-bypass 直接性与去间接依赖，改这两处为优先取 env：`OR_KEY="${OMNIROUTE_API_KEY:-$(cat "$OR_API_KEY_FILE")}"`。
- NIM key 注册段不变（用 cookie 登录，与 `OR_KEY` 无关）。

### 3.4 数据流

```
HF Space Secret OMNIROUTE_API_KEY (固定)
   │
   ├──► entrypoint.sh 透传 ──► node server.js (env-bypass 放行)
   │
   ├──► gate.js 读 env ──► 上游 Authorization: Bearer <Secret>
   │
   └──► init-nim-keys.sh 检测 env ──► 跳过 /api/keys，写 .or-api-key 镜像
```

跨重建：Secret 持久 → 同 key 固定；鉴权不依赖 sqlite restore；无 sqlite 累积 key；无 init/gate race。

### 3.5 错误处理

- env 与文件皆缺 → gate fatal 退出（现状行为保留）。
- env 模式下 `.or-api-key` 写入失败 → 仅记 warn，不 fatal（gate 已不依赖文件）。
- 用户提供的 Secret 值若过弱 → 不阻断（env-bypass 不校验强度），README 注明建议 ≥32 字节随机。

### 3.6 测试 / 验证

- env 设固定 Secret，重启容器 → gate 转发 `/v1` 上游 200。
- 删 `/data/.or-api-key` + 重启 → 仍 200（env-bypass 不依赖文件）。
- 不设 env（fallback）→ 仍走旧 `/api/keys` 生成，行为同现状。
- **跨重建固定验证**：记录首次部署后 init 日志出现 `[init] OMNIROUTE_API_KEY env set, env-bypass 模式` → 触发 HF Space 重建 → 确认重建后日志仍显示 env 模式、且客户端无需改配置即可正常调用（直接验证"跨重建固定"核心价值）。
- README 增补 Secret 配置说明。

### 3.7 README 增补与 Secret 清理

README 需补：

- **`OMNIROUTE_API_KEY` Secret 说明**：作用为"固定 `OR_API_KEY`，通过上游 env-bypass 机制实现跨重建稳定"；值要求"≥32 字节强随机串（建议 `openssl rand -hex 32` 生成）"。
- **与 `INTERNAL_PSK` 关系**：`INTERNAL_PSK` 是客户端→gate 外层鉴权，`OMNIROUTE_API_KEY` 是 gate→OmniRoute 内层鉴权，两者独立配置、值不同。
- **`OR_API_KEY` Secret 清理**（迁移说明）：HF Space 中可能残留 stage3 时期的 `OR_API_KEY` Secret（与 `OMNIROUTE_API_KEY` 是不同变量名）。env-bypass 只查 `process.env.OMNIROUTE_API_KEY` 或 `ROUTER_API_KEY`，**不查 `OR_API_KEY`**。残留 `OR_API_KEY` 不被任何代码消费，应删除以免命名混淆。

## 4. 实施前提

- **`INTERNAL_PSK` Secret 必须已配置**（值与客户端 `$OMN_TOKEN` 一致）。本方案独立于此前排查出的 PSK 阻塞问题，但须同步解决——否则即使 `OR_API_KEY` 固定化成功，gate 仍因 PSK 缺失对所有 `/v1` 请求返回 401。

## 5. 影响与风险

- **正向**：跨重建固定、去 sqlite 依赖、去 race、去重复 key 累积。
- **风险**：用户未设 Secret 仍走旧链路（行为不变，无回归）。env-bypass 对 Secret 强度无校验 → 文档约束。
- **不引入新依赖**。

## 6. 不做

- 不改 OmniRoute 上游源码（仅用其 env-bypass）。
- 不删除 `.or-api-key` 文件链路（保留 fallback）。
- 不改 NIM key 注册段。
- 不引入 R2 额外备份 key 文件（无需）。
