# OR_API_KEY 跨重建固定化 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 让 `OR_API_KEY` 由 HF Space Secret `OMNIROUTE_API_KEY` 固定驱动（上游 env-bypass），跨重建不变，保留旧 `/api/keys`+`.or-api-key` 链路作 fallback。

**Architecture:** gate.js 优先读 env、回退读文件（try/catch 防 ENOENT）；entrypoint.sh 透传 env 给上游 + env 模式跳过等待 `.or-api-key`；init-nim-keys.sh env 分支显式赋 `OR_KEY`、写镜像、跳过 `/api/keys`，并令 411/571 两处 export-json 块优先取 env。PSK 间接层（INTERNAL_PSK 校验+请求头替换）原样保留。

**Tech Stack:** Bash（POSIX sh 兼容点已用 `bash`），Node.js CommonJS（gate.js），HF Space Docker。

参考 spec：`docs/superpowers/specs/2026-07-05-or-api-key-persistence-design.md`

---

## File Structure

- 修改 `gate.js`（第 16-20 行 OR_API_KEY 读取段）→ env 优先 + try/catch + 双缺 fatal
- 修改 `entrypoint.sh`（第 43-55 行 env 块加透传；第 82-105 行等待 `.or-api-key` 段加 env 跳过）
- 修改 `init-nim-keys.sh`（133-164 行创建段加 env 守卫+显式 `OR_KEY`；413、571 行 `OR_KEY=$(cat ...)` 改优先 env）
- 修改 `README.md`（追加 `OMNIROUTE_API_KEY` Secret 说明、与 INTERNAL_PSK 关系、`OR_API_KEY` 旧 Secret 清理说明）

---

## Task 1: gate.js — env 优先 + 防御性读取 + 双缺 fatal

**Files:**
- Modify: `gate.js:16-20`

- [ ] **Step 1: 写失败测试（node 冒烟脚本）**

写 `/tmp/test-gate-key-source.js`：
```js
const assert = require('assert');

// 模拟 gate.js 的来源选择逻辑（抽出为纯函数便于测）
function pickKey(env, readFile) {
  let k = (env.OMNIROUTE_API_KEY || '').trim();
  if (!k) {
    try { k = readFile('/data/.or-api-key', 'utf8').trim(); } catch (e) { /* ENOENT 留空 */ }
  }
  return k;
}

// case A: env 命中 → 用 env（trim 首尾空白）
assert.strictEqual(pickKey({ OMNIROUTE_API_KEY: '  envsecret  ' }, () => { throw new Error('should not read'); }), 'envsecret');

// case A2: env 纯空白 → 视为未设，回退文件
assert.strictEqual(pickKey({ OMNIROUTE_API_KEY: '   ' }, () => 'filesecret\n'), 'filesecret');

// case B: env 缺、文件存在 → 用文件
assert.strictEqual(pickKey({}, () => 'filesecret\n'), 'filesecret');

// case C: env 缺、文件不存在 → undefined（fatal 前提）
const readThrow = () => { const e = new Error('ENOENT'); e.code='ENOENT'; throw e; };
assert.strictEqual(pickKey({}, readThrow), undefined);

console.log('OK gate key-source logic');
```

- [ ] **Step 2: 运行测试确认逻辑成立**

Run: `node /tmp/test-gate-key-source.js`
Expected: `OK gate key-source logic`

- [ ] **Step 3: 改 gate.js 第 16-20 行**

把：
```js
if (!fs.existsSync('/data/.or-api-key')) {
  console.error('[gate] FATAL: /data/.or-api-key 不存在。entrypoint 应先等 init 写入该文件再 exec gate。');
  process.exit(1);
}
const OR_API_KEY = fs.readFileSync('/data/.or-api-key', 'utf8').trim();
```
改为：
```js
// env 优先（HF Secret 固定，env-bypass 跨重建），回退读文件（旧链路兼容）
// env 与文件分支均 .trim()：env-bypass 严格字符串相等比对，首尾空白会致失配 401
let OR_API_KEY = (process.env.OMNIROUTE_API_KEY || '').trim();
if (!OR_API_KEY) {
  try {
    OR_API_KEY = fs.readFileSync('/data/.or-api-key', 'utf8').trim();
  } catch (e) {
    // 文件不存在，保持空，下文 fatal
  }
}
if (!OR_API_KEY) {
  console.error('[gate] FATAL: No OR_API_KEY (neither OMNIROUTE_API_KEY env nor /data/.or-api-key file). entrypoint 应先 init 或配置 OMNIROUTE_API_KEY Secret。');
  process.exit(1);
}
```

- [ ] **Step 4: 语法校验**

Run: `node --check gate.js`
Expected: 无输出（语法 OK）

- [ ] **Step 5: 提交**

```bash
git add gate.js
git commit -m "feat(gate): OR_API_KEY env 优先 + 防御性读取 + 双缺 fatal"
```

---

## Task 2: entrypoint.sh — 透传 env + env 模式跳过等待 .or-api-key

**Files:**
- Modify: `entrypoint.sh:43-55`（env 块）, `entrypoint.sh:82-105`（等待段）

- [ ] **Step 1: 改第 43-55 行 env 块，新增 OMNIROUTE_API_KEY 透传**

在 `API_KEY_SECRET="$API_KEY_SECRET" \` 后、`INITIAL_PASSWORD="$INITIAL_PASSWORD" \` 前插入一行：
```sh
OMNIROUTE_API_KEY="$OMNIROUTE_API_KEY" \
```
完整 env 块变为：
```sh
PORT="$OMNIROUTE_PORT" \
DATA_DIR="$DATA_DIR" \
REQUIRE_API_KEY=true \
HOSTNAME=127.0.0.1 \
NODE_OPTIONS="--max-old-space-size=1024" \
DISABLE_SQLITE_AUTO_BACKUP=true \
PROVIDER_LIMITS_SYNC_INTERVAL_MINUTES=1440 \
CALL_LOGS_TABLE_MAX_ROWS="$CALL_LOGS_TABLE_MAX_ROWS" \
PROXY_LOGS_TABLE_MAX_ROWS="$PROXY_LOGS_TABLE_MAX_ROWS" \
JWT_SECRET="$JWT_SECRET" \
API_KEY_SECRET="$API_KEY_SECRET" \
OMNIROUTE_API_KEY="$OMNIROUTE_API_KEY" \
INITIAL_PASSWORD="$INITIAL_PASSWORD" \
node /app/server.js &
```

- [ ] **Step 2: 改第 82-105 行等待段，env 模式跳过**

把：
```sh
echo "[entrypoint] running NIM key init script in background..."
bash /entrypoint-init-nim.sh &

echo "[entrypoint] waiting for OR_API_KEY to be written (max 120s)..."
j=0
while [ "$j" -lt 120 ]; do
  if [ -f "/data/.or-api-key" ] && [ -s "/data/.or-api-key" ]; then
    echo "[entrypoint] OR_API_KEY ready"
    break
  fi

  if ! kill -0 "$OR_PID" 2>/dev/null; then
    echo "[entrypoint] FATAL: OmniRoute exited while waiting for OR_API_KEY"
    exit 1
  fi

  sleep 2
  j=$((j + 2))
done

if [ ! -f "/data/.or-api-key" ] || [ ! -s "/data/.or-api-key" ]; then
  echo "[entrypoint] FATAL: OR_API_KEY not created within timeout"
  exit 1
fi
```
改为：
```sh
echo "[entrypoint] running NIM key init script in background..."
bash /entrypoint-init-nim.sh &

if [ -n "$OMNIROUTE_API_KEY" ]; then
  echo "[entrypoint] OMNIROUTE_API_KEY env set, env-bypass 模式，跳过等待 .or-api-key。"
else
  echo "[entrypoint] waiting for OR_API_KEY to be written (max 120s)..."
  j=0
  while [ "$j" -lt 120 ]; do
    if [ -f "/data/.or-api-key" ] && [ -s "/data/.or-api-key" ]; then
      echo "[entrypoint] OR_API_KEY ready"
      break
    fi

    if ! kill -0 "$OR_PID" 2>/dev/null; then
      echo "[entrypoint] FATAL: OmniRoute exited while waiting for OR_API_KEY"
      exit 1
    fi

    sleep 2
    j=$((j + 2))
  done

  if [ ! -f "/data/.or-api-key" ] || [ ! -s "/data/.or-api-key" ]; then
    echo "[entrypoint] FATAL: OR_API_KEY not created within timeout"
    exit 1
  fi
fi
```

- [ ] **Step 3: 语法校验**

Run: `sh -n entrypoint.sh`
Expected: 无输出

- [ ] **Step 4: dry-run 验证分支逻辑**

Run:
```bash
OMNIROUTE_API_KEY=testsecret sh -c 'if [ -n "$OMNIROUTE_API_KEY" ]; then echo ENV_SKIP; else echo WAIT; fi'
```
Expected: `ENV_SKIP`

Run:
```bash
sh -c 'if [ -n "$OMNIROUTE_API_KEY" ]; then echo ENV_SKIP; else echo WAIT; fi'
```
Expected: `WAIT`

- [ ] **Step 5: 提交**

```bash
git add entrypoint.sh
git commit -m "feat(entrypoint): 透传 OMNIROUTE_API_KEY + env 模式跳过等待 .or-api-key"
```

---

## Task 3: init-nim-keys.sh — env 守卫 + 显式 OR_KEY + export-json 优先 env

**Files:**
- Modify: `init-nim-keys.sh:133-164`（创建段）, `init-nim-keys.sh:413`（OR_KEY 赋值）, `init-nim-keys.sh:571`（OR_KEY 赋值）

- [ ] **Step 1: 改第 133-164 行创建段，加 env 守卫 + 显式 OR_KEY**

把：
```sh
# ── 创建或复用 OmniRoute 内部 API Key ────────────────────────
if [ -f "$OR_API_KEY_FILE" ] && [ -s "$OR_API_KEY_FILE" ]; then
  echo "[init] OR_API_KEY file already exists, skipping creation."
else
  echo "[init] Creating OmniRoute API Key via /api/keys..."
```
改为：
```sh
# ── 创建或复用 OmniRoute 内部 API Key ────────────────────────
if [ -n "$OMNIROUTE_API_KEY" ]; then
  OR_KEY="$(printf '%s' "$OMNIROUTE_API_KEY" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
  echo "$OR_KEY" > "$OR_API_KEY_FILE"
  chmod 600 "$OR_API_KEY_FILE"
  echo "[init] OMNIROUTE_API_KEY env set, env-bypass 模式，跳过 /api/keys 创建。"
elif [ -f "$OR_API_KEY_FILE" ] && [ -s "$OR_API_KEY_FILE" ]; then
  OR_KEY=$(cat "$OR_API_KEY_FILE")
  echo "[init] OR_API_KEY file already exists, skipping creation."
else
  echo "[init] Creating OmniRoute API Key via /api/keys..."
```
注：env 分支用 `sed` 仅去首尾空白（不去中间），以防 Secret 注入意外携带首尾空白致 export-json 的 `Bearer $OR_KEY` 比对失配。镜像写入文件用已 trim 的 `$OR_KEY`，保证 gate 读文件分支值一致。

- [ ] **Step 2: 确认 else 分支末尾（原第 156-158 行写文件处）虽不变但需确认 OR_KEY 赋值存在**

原 else 分支已有 `OR_API_KEY_VALUE=$(jq ...)` 且写文件，但**未赋 `OR_KEY`**。需在写文件后补赋值。把：
```sh
    echo "$OR_API_KEY_VALUE" > "$OR_API_KEY_FILE"
    chmod 600 "$OR_API_KEY_FILE"
    echo "[init] OR_API_KEY written to $OR_API_KEY_FILE"
```
改为：
```sh
    echo "$OR_API_KEY_VALUE" > "$OR_API_KEY_FILE"
    chmod 600 "$OR_API_KEY_FILE"
    OR_KEY="$OR_API_KEY_VALUE"
    echo "[init] OR_API_KEY written to $OR_API_KEY_FILE"
```

- [ ] **Step 3: 改第 413 行 export-json 块 OR_KEY 赋值，优先 env + trim**

把第 413 行（6 空格缩进）：
```sh
      OR_KEY=$(cat "$OR_API_KEY_FILE")
```
改为（保持 6 空格缩进，env 优先去首尾空白，否则读文件——文件已由 init env 分支写为 trim 后值）：
```sh
      OR_KEY="$(printf '%s' "${OMNIROUTE_API_KEY:-$(cat "$OR_API_KEY_FILE")}" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
```

- [ ] **Step 4: 改第 571 行 export-json 块 OR_KEY 赋值，同上**

把第 571 行（2 空格缩进）：
```sh
  OR_KEY=$(cat "$OR_API_KEY_FILE")
```
改为（保持 2 空格缩进）：
```sh
  OR_KEY="$(printf '%s' "${OMNIROUTE_API_KEY:-$(cat "$OR_API_KEY_FILE")}" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
```

- [ ] **Step 5: 语法校验**

Run: `bash -n init-nim-keys.sh`
Expected: 无输出

- [ ] **Step 6: dry-run 验证 env 守卫分支**

Run:
```bash
OMNIROUTE_API_KEY=testsecret bash -c '
  OR_API_KEY_FILE=/tmp/.or-api-key-test
  rm -f "$OR_API_KEY_FILE"
  if [ -n "$OMNIROUTE_API_KEY" ]; then
    OR_KEY="$OMNIROUTE_API_KEY"
    echo "$OMNIROUTE_API_KEY" > "$OR_API_KEY_FILE"
    chmod 600 "$OR_API_KEY_FILE"
    echo "ENV_BRANCH OR_KEY=$OR_KEY FILE=$(cat $OR_API_KEY_FILE)"
  fi
'
```
Expected: `ENV_BRANCH OR_KEY=testsecret FILE=testsecret`

- [ ] **Step 7: 提交**

```bash
git add init-nim-keys.sh
git commit -m "feat(init): OMNIROUTE_API_KEY env 守卫 + 显式 OR_KEY + export-json 优先 env"
```

---

## Task 4: README — 增补 Secret 说明 + 旧 Secret 清理

**Files:**
- Modify: `README.md`（当前仅 HF metadata stub，无正文）

- [ ] **Step 1: 在 README.md 末尾追加配置说明段**

在文件末尾（第 12 行 `---` 之后）追加：
```markdown

## 配置说明

### HF Space Secrets

| Secret | 作用 | 要求 |
|--------|------|------|
| `INTERNAL_PSK` | 客户端→gate 外层鉴权（`Authorization: Bearer <PSK>`） | 值须与客户端 `$OMN_TOKEN` 一致 |
| `OMNIROUTE_API_KEY` | gate→OmniRoute 内层鉴权，固定 `OR_API_KEY`，经上游 env-bypass 实现跨重建稳定 | ≥32 字节强随机串，建议 `openssl rand -hex 32` 生成 |
| `JWT_SECRET` / `API_KEY_SECRET` / `INITIAL_PASSWORD` | OmniRoute 引擎内部 | 详见 init 脚本 |

`INTERNAL_PSK` 与 `OMNIROUTE_API_KEY` 独立配置、值不同：前者是外层客户端鉴权，后者是内层上游鉴权（env-bypass，不写入 sqlite、不依赖 Litestream restore）。

### 迁移：清理旧 `OR_API_KEY` Secret

若 HF Space 中残留旧 `OR_API_KEY` Secret（stage3 时期命名），应在 Settings → Variables and secrets 中删除：env-bypass 只识别 `OMNIROUTE_API_KEY` 或 `ROUTER_API_KEY`，不识别 `OR_API_KEY`，残留值不被任何代码消费，仅致命名混淆。

未设 `OMNIROUTE_API_KEY` 时，仍走旧链路（init 调 `/api/keys` 生成、写 `/data/.or-api-key`），行为不变。
```

- [ ] **Step 2: 提交**

```bash
git add README.md
git commit -m "docs(readme): OMNIROUTE_API_KEY Secret 说明 + 旧 OR_API_KEY 清理"
```

---

## Task 5: 端到端验证（人工 / 容器内）

**Files:** 无文件改动，仅验证清单

- [ ] **Step 1: 静态全量校验**

Run:
```bash
node --check gate.js && sh -n entrypoint.sh && bash -n init-nim-keys.sh && echo ALL_SYNTAX_OK
```
Expected: `ALL_SYNTAX_OK`

- [ ] **Step 2: env 主路径验证（容器内或 HF Space）**

设 HF Space Secret `OMNIROUTE_API_KEY=<32 字节随机串>`，重建容器。
- 期望 init 日志含：`[init] OMNIROUTE_API_KEY env set, env-bypass 模式，跳过 /api/keys 创建。`
- 期望 entrypoint 日志含：`[entrypoint] OMNIROUTE_API_KEY env set, env-bypass 模式，跳过等待 .or-api-key。`
- 期望 gate 启动无 fatal。
- 客户端以 `Authorization: Bearer <INTERNAL_PSK>` 调 `/v1` → 上游 200。

- [ ] **Step 3: 文件删除容错验证**

env 模式下 `rm /data/.or-api-key` 后重启 gate（不重启 OmniRoute）→ gate 仍拿 env 值启动，无 fatal。

- [ ] **Step 4: fallback 路径验证**

临时移除 `OMNIROUTE_API_KEY` Secret，重建容器 → init 走 `/api/keys` 生成、写 `/data/.or-api-key`，gate 读文件，行为同现状。

- [ ] **Step 5: 跨重建固定验证（核心价值）**

记录首次 env 模式部署后 init 日志中的 env 模式标记 → 触发 HF Space 重建（Factory rebuild 或重启）→ 确认重建后日志仍显示 env 模式、客户端无需改配置即可正常调用。

- [ ] **Step 6: 实施前提确认**

确认 HF Space 已配置 `INTERNAL_PSK` Secret（值与客户端 `$OMN_TOKEN` 一致）。缺失则 gate 对所有 `/v1` 请求 401——本方案独立于该阻塞，但须同步解决。
