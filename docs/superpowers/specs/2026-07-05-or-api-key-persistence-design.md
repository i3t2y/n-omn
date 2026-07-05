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

2. `createApiKey`（`src/lib/db/apiKeys.ts`）：将 key 双存于 `api_keys` 表 — `key`（明文）+ `key_hash`（SHA-256 hex）。

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
- 启动校验改为：env 存在 **或** 文件存在二者居其一即可；二者皆无才 fatal（对齐现有 `INTERNAL_PSK` 缺失即 fatal 风格）。

#### 3.3.3 `init-nim-keys.sh`

- "创建或复用 OmniRoute 内部 API Key"段（当前第 133-164 行）开头加守卫：
  ```sh
  if [ -n "$OMNIROUTE_API_KEY" ]; then
    echo "$OMNIROUTE_API_KEY" > "$OR_API_KEY_FILE"   # 写文件镜像，供诊断/兼容
    chmod 600 "$OR_API_KEY_FILE"
    echo "[init] OMNIROUTE_API_KEY env set, env-bypass 模式，跳过 /api/keys 创建。"
    # 跳过本段 /api/keys 创建
  elif [ -f "$OR_API_KEY_FILE" ] && [ -s "$OR_API_KEY_FILE" ]; then
    ...复用旧文件...
  else
    ...原 /api/keys 创建逻辑...
  fi
  ```
- NIM key 注册等后续逻辑不变（其 cookie 登录链路独立，与本 key 无关）。

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
- README 增补 Secret 配置说明。

## 4. 影响与风险

- **正向**：跨重建固定、去 sqlite 依赖、去 race、去重复 key 累积。
- **风险**：用户未设 Secret 仍走旧链路（行为不变，无回归）。env-bypass 对 Secret 强度无校验 → 文档约束。
- **不引入新依赖**。

## 5. 不做

- 不改 OmniRoute 上游源码（仅用其 env-bypass）。
- 不删除 `.or-api-key` 文件链路（保留 fallback）。
- 不改 NIM key 注册段。
- 不引入 R2 额外备份 key 文件（无需）。
