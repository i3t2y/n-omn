```markdown
# DEGRADED 事后分析 — proxy_enabled DEFAULT 1 陷阱

> **日期**：2026-07-08
> **影响范围**：cg52（glm-5.2）等 function 在 Claude Code 35 tools 场景下持续 DEGRADED
> **根因**：`provider_connections.proxy_enabled` 列 `DEFAULT 1`，每次注册 key 时代理自动启用
> **修复**：init 脚本 `purge_proxy_db` 中增加 `UPDATE provider_connections SET proxy_enabled=0 WHERE provider='nvidia'`
> **状态**：已修复并验证

---

## 一、根因——一句话

OmniRoute 的 `provider_connections` 表中，`proxy_enabled` 列定义为 `INTEGER NOT NULL DEFAULT 1`（源码 `src/lib/db/core.ts:228`）。init 脚本通过 `POST /api/providers` 注册 25 个 NIM key 时，请求体不含 `proxyEnabled` 字段，`normalizeBooleanColumn(undefined, true)` 返回 `true`，导致每个 key 的 `proxy_enabled` 被设为 1。请求路由时（`src/lib/db/settings.ts:363-398`），OmniRoute 检测到 `proxy_enabled=1` 即尝试通过 `proxy_registry` 路由请求，registry 为空或指向不存在的 127.0.0.1:20129 端口，连接失败后对部分 function（如 cg52）不执行 direct fallback，直接标记 DEGRADED。

---

## 二、根因的完整证据链

### 证据 1——表定义

```sql
-- src/lib/db/core.ts:228
proxy_enabled INTEGER NOT NULL DEFAULT 1,
per_key_proxy_enabled INTEGER NOT NULL DEFAULT 0,
```

`proxy_enabled` 默认值为 1（启用），`per_key_proxy_enabled` 默认值为 0（禁用）。两者是不同字段——`proxy_enabled` 控制该 connection 是否使用代理，`per_key_proxy_enabled` 控制是否允许 per-key 级别的代理覆盖。

### 证据 2——注册时的写入逻辑

```typescript
// src/lib/db/providers.ts:294
proxyEnabled: normalizeBooleanColumn(data.proxyEnabled, true),
```

当 init 脚本的 `POST /api/providers` 请求体不含 `proxyEnabled` 字段时，`data.proxyEnabled` 为 `undefined`，`normalizeBooleanColumn(undefined, true)` 返回 `true`，写入 DB 时 `proxy_enabled = 1`。

### 证据 3——请求路由时的代理决策

```typescript
// src/lib/db/settings.ts:363-398
// Step 1: 检查全局 proxyEnabled（key_value 表，默认 true）
// Step 2: 检查 connection 的 proxy_enabled 列
//   → proxy_enabled = 1 → 尝试通过 proxy_registry 路由
//     → registry 为空或指向 20129 → ECONNREFUSED
//       → 部分函数不执行 direct fallback → DEGRADED
```

### 证据 4——全新数据库仍触发 DEGRADED

2026-07-07 15:14 重建日志（R2 已清空，全新数据库，`domain_circuit_breakers` 表为空）：

```
[init] First-time init: registering models...
[init] model z-ai/glm-5.2 -> OK (200)
...
{"msg":"📥 POST /v1/messages | nvidia/z-ai/glm-5.2 | 2 msgs | 35 tools"}
{"msg":"COMPRESSION: Prompt compressed (stacked): 31519 -> 31516 tokens"}
{"msg":"Proactive compression triggered: 31516 > 5404 threshold (32768 limit)"}
[ProxyFetch] ECONNREFUSED 127.0.0.1:20129 (×6)
[ERROR] [400]: Function id '3b9748d8...': DEGRADED function cannot be invoked
```

全新数据库、空 circuit_breakers 表、第一条请求——DEGRADED 立即触发。证明 DEGRADED 的来源不是持久化状态，而是请求处理过程中即时设置的。

### 证据 5——cq3n 与 cg52 的关键差异

| 阶段 | cq3n（成功） | cg52（DEGRADED） |
|------|-------------|-----------------|
| ProxyFetch 失败 | ×6 | ×6 |
| ProxyEgress direct success | ✅ 有 | ❌ 无 |
| 请求到达 NIM | ✅ | ❌ |
| 结果 | 2883ms complete | DEGRADED 400 |

两者的 token 数几乎相同（31596 vs 31516），proxy_enabled 也都是 1。差异在于 proxy 失败后的 fallback 策略——cq3n 执行了 direct fallback，cg52 没有。

---

## 三、调试弯路时间线

### 弯路 1——归因于 NIM 32K 超限 + empty content

**假设**：NIM 对超 32K 的请求返回 HTTP 200 + 空 SSE 流，OmniRoute 将其分类为 function 故障，标记 DEGRADED。

**证伪**：15:14 日志显示请求从未到达 NIM——ProxyFetch 在 20129 端口失败后，cg52 没有执行 direct fallback，请求未发送给 NIM。

**耗时**：约 4 小时

### 弯路 2——归因于 domain_circuit_breakers 持久化

**假设**：DEGRADED 状态被写入 `domain_circuit_breakers` 表，通过 Litestream 同步到 R2，重启后从 R2 恢复，跨重建存活。

**证伪**：15:14 重建使用全新数据库（R2 已清空），`domain_circuit_breakers` 表为空，但 DEGRADED 仍在第一条请求触发。

**修复尝试**：`DELETE FROM domain_circuit_breakers`——清除了一个不相关的表。

**耗时**：约 3 小时

### 弯路 3——归因于 per-model limits 改变了错误分类路径

**假设**：per-model limits 让请求被压缩到 32K 边界附近，NIM 对"刚好超限"的请求返回 200 + 空内容，改变了 OmniRoute 的错误分类路径（从 account unavailable 转为 function DEGRADED）。

**证伪**：DEGRADED 在请求到达 NIM 之前就被触发，与压缩后的 token 数无关。

**耗时**：约 2 小时

### 弯路 4——归因于 cg52 的 tokenizer 特性

**假设**：glm-5.2 的 tokenizer 将 35 tools 拆分出更多 token，导致不可压缩部分膨胀到 27-30K，首条消息即超限。

**证伪**：用户指出 skills 变少了（卸载了 superpowers 英文原版），token 数应该更低。cq3n 与 cg52 的 token 数几乎相同（31596 vs 31516）。

**耗时**：约 1 小时

### 弯路 5——v3.7.0 全局 env 关闭 + proxy_registry 清理

**假设**：通过 `ONEPROXY_ENABLED=false` + `NO_PROXY` + `unset HTTP_PROXY` 等 env 变量关闭全局 proxy 生态，清理 `proxy_registry` 表中的 20129 条目，即可切断 proxy 路由路径。

**证伪**：env 变量控制的是 OneProxy 子系统，不是 SQLite `key_value` 表中的全局 `proxyEnabled` 设置（`settings.ts:367-371` 读取的是 DB 而非 env）。proxy_registry 清理也没有触及 `provider_connections.proxy_enabled` 列。

**部分有效**：proxy_registry 清理减少了 registry 中的无效条目，但 per-key `proxy_enabled=1` 仍让 OmniRoute 尝试走代理路径。

**耗时**：约 3 小时

---

## 四、为什么走了这么多弯路

### 根本原因——注意力被运行时行为吸引，未回到 schema 定义

整个调试过程中，所有分析者（cg52、强模型、人类）的注意力都被三类信息吸引：

1. **运行时日志**——ProxyFetch 失败、compression 触发、DEGRADED 错误消息
2. **API 行为**——HTTP 状态码、响应体、端点变化
3. **架构推断**——circuit breaker 状态机、错误分类路径、fallback 策略差异

没有人回到最基础的层面——检查 `provider_connections` 表的列定义和默认值。`grep -rn "proxy_enabled.*DEFAULT" src/` 是一条 5 秒就能执行的命令，能直接揭示 `DEFAULT 1`，但在约 13 小时的调试中从未被执行。

### 归纳谬误——从一个案例的成功推断所有案例

cq3n 在 ProxyFetch 失败后有 `[ProxyEgress] proxy=direct status=success`，请求通过直连到达 NIM。分析者将此归纳为"ProxyFetch 失败对所有 function 都非阻塞"，而没有验证 cg52 是否也有这行。实际上 cg52 的日志中没有 `ProxyEgress` 行——这个差异在日志中是显式的，但从未被对比。

### 错误的理论构建方式——先建理论再找证据

调试过程中多次出现"先构建一个内部自洽的理论，再寻找支持证据"的模式。例如"NIM 返回 empty content → circuit breaker 误判 → DEGRADED 持久化"这套理论内部逻辑通顺，但前提（NIM 返回 empty content 触发 DEGRADED）从未被验证——因为请求从未到达 NIM。正确的方式应该是"先收集所有证据，再构建理论"。

---

## 五、核心教训

### 教训 1——当行为与预期不符时，先检查 schema 定义

表定义中的 `DEFAULT` 值是系统行为的源头。当一个字段被自动设置为非预期值时，第一步应该是 `grep -rn "字段名.*DEFAULT" src/`，而非分析运行时日志。

**诊断命令模板**：

```bash
# 检查可疑字段的表定义和默认值
grep -rn "字段名.*DEFAULT" /home/laisi/OmniRoute/src/lib/db/
```

### 教训 2——ProxyFetch 失败不等于非阻塞

当日志中出现 `[ProxyFetch] ECONNREFUSED` 时，不能假设它对所有 function 都非阻塞。必须验证每个 function 在 ProxyFetch 失败后是否有 `ProxyEgress direct` fallback 行。没有 fallback 行的 function 会被标记 DEGRADED。

**诊断命令模板**：

```bash
# 对比成功和失败的 function 在 ProxyFetch 后的行为差异
grep -A5 "ProxyFetch.*failed" 日志文件 | grep -c "ProxyEgress"
```

### 教训 3——"全新数据库 + 第一条请求"是最强诊断场景

当怀疑某个问题是持久化状态导致的时，清空 R2 创建全新数据库，然后发送第一条请求。如果问题在全新数据库上仍然复现，可以排除所有持久化相关的假设，将注意力集中到请求处理过程本身。

**操作模板**：

1. Cloudflare R2 Dashboard 删除 `omniroute-data/db/` 下所有文件
2. HF Space Restart Space
3. 等待 first-time init 完成
4. 立即发送第一条测试请求
5. 观察 DEGRADED 是否复现

### 教训 4——全局 env 关闭不等于 DB 设置关闭

OmniRoute 的某些配置（如 `proxyEnabled`）存储在 SQLite `key_value` 表中，运行时从 DB 读取（`settings.ts:367-371`），不从环境变量读取。通过 env 变量关闭这些功能不会生效——必须在 DB 层面修改。

**诊断命令模板**：

```bash
# 检查 key_value 表中的 proxy 相关设置
sqlite3 /data/storage.sqlite \
  "SELECT key, value FROM key_value WHERE namespace='settings' AND key LIKE '%proxy%';"
```

---

## 六、快速诊断 Checklist（60 秒）

当 DEGRADED 再次出现时，按以下顺序执行：

### Step 1——确认是否全新数据库仍复现（排除持久化）

```
R2 是否已清空？
  → 是：跳到 Step 2
  → 否：清空 R2 + Restart Space + 发送第一条请求
    → 仍 DEGRADED？→ 跳到 Step 2
    → 不再 DEGRADED？→ 问题是持久化状态，检查 domain_circuit_breakers
```

### Step 2——检查 ProxyFetch 是否出现（确认 proxy 路径）

```
日志中是否有 [ProxyFetch] ECONNREFUSED 127.0.0.1:20129？
  → 是：跳到 Step 3
  → 否：DEGRADED 来自其他原因，检查 NIM 响应
```

### Step 3——检查 per-key proxy_enabled（确认根因）

```
provider_connections 中有多少个 proxy_enabled=1？
  → >0：这就是根因
    → 修复：UPDATE provider_connections SET proxy_enabled=0 WHERE provider='nvidia'
    → 或在 Dashboard 逐个关闭绿色地球图标
  → 0：proxy 已全部关闭但仍有 ProxyFetch
    → 检查 key_value 表的全局 proxyEnabled 设置
    → 检查 proxy_registry 是否有残留条目
```

### Step 4——验证修复

```
关闭 proxy_enabled 后发送测试请求
  → 正常返回：修复确认
  → 仍 DEGRADED：检查是否有其他 proxy 触发路径
    → grep -rn "proxy_enabled\|proxyEnabled" src/ 查找所有引用点
```

---

## 七、修复方案

### init 脚本修复（已实施）

在 `purge_proxy_db` 函数中增加：

```bash
sqlite3 "$_DB_PATH" \
  "UPDATE provider_connections SET proxy_enabled=0 WHERE provider='nvidia';" \
  2>/dev/null || true
```

由于 `purge_proxy_db` 在 init 脚本中被调用 4 次，此 UPDATE 会在每次调用时重复执行——幂等，无副作用。

### 为什么不修改 DEFAULT 值

修改 `core.ts:228` 的 `DEFAULT 1` 为 `DEFAULT 0` 需要修改 OmniRoute 上游源码，不在 omn-merge 仓库控制范围内。init 脚本的 UPDATE 是在应用层的覆盖，每次注册 key 后强制关闭，等价于修改 DEFAULT 值的效果。

### Dashboard 手动关闭（应急）

在 OmniRoute Dashboard > Providers > NVIDIA NIM 页面，逐个点击每个 key 的绿色地球图标使其关闭。适用于不想等待重建的应急场景。

---

## 八、与此前的 DEGRADED 分析的关系

此前构建的所有 DEGRADED 分析（NIM 32K 超限、circuit breaker 持久化、per-model limits 改变错误分类路径）均建立在错误前提上——假设 DEGRADED 由 NIM 返回 empty content 触发。实际上请求从未到达 NIM，DEGRADED 在 OmniRoute 内部的 proxy 路由层就被触发。

但此前的部分修复仍有独立价值：

| 修复 | 是否针对 DEGRADED 根因 | 独立价值 |
|------|---------------------|---------|
| per-model limits + compression | ❌ 非 DEGRADED 根因 | ✅ 独立有效——防止 NIM 32K 超限触发 502 风暴 |
| DELETE FROM domain_circuit_breakers | ❌ 非 DEGRADED 根因 | ⚠️ 附带价值——防止合法 circuit breaker 状态跨重建存活 |
| SSOT 模型清单重构 | ❌ 非 DEGRADED 根因 | ✅ 独立有效——消除三份清单打架 |
| stream_options 验证关闭 | ❌ 非 DEGRADED 根因 | ✅ 独立有效——关闭了一个不存在的风险待办 |
| proxy_registry 清理 | ⚠️ 部分相关——减少无效条目 | ✅ 独立有效——清理 proxy 注册表 |
| per-key proxy_enabled=0 | ✅ DEGRADED 根因修复 | ✅ 根治 |

---

## 九、维护须知

- 新增 NIM key 后，init 脚本会自动执行 `UPDATE provider_connections SET proxy_enabled=0`，无需手动操作
- 如果在 Dashboard 中手动添加了新 key（非通过 init 脚本），需要手动关闭该 key 的代理开关
- `proxy_enabled` 的 DEFAULT 1 是 OmniRoute 上游设计，每次升级 OmniRoute 版本后此行为可能变化——升级后需验证
- 此文档随 init 脚本版本更新，当前对应 v3.7.0+
```