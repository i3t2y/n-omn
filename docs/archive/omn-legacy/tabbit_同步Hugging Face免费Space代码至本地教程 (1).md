现在评估下，之前因为DEGRADED所作的所有修正，是否有需要清理的？

### **结论：需要清理的只有三类——文档层面的错误归因描述（SSOT §13 需重写）、待办优先级调整（gate.js 预拦截降级）、以及 v3.7.0 的 DEGRADED 相关注释措辞修正。所有代码层面的修正均有独立价值，不建议删除，但 `DELETE FROM domain_circuit_breakers` 和 v3.7.0 的 proxy env 关闭需要补充说明其真实作用，避免后续维护者误以为它们是 DEGRADED 的根治手段**

---

## 一、逐项评估——专门为 DEGRADED 做的修正

### 1. `DELETE FROM domain_circuit_breakers`

**创建动机**——专门为清除"DEGRADED 持久化状态"而设计，假设 DEGRADED 从此表恢复。

**是否需要清理**——保留代码，更新文档说明。

**理由**——DEGRADED 的根因已确认为 `proxy_enabled DEFAULT 1`，与此表无关。但该 SQL 仍有独立价值：当某个 function 因合法的 provider 故障（如 key 临时被封、NIM 平台宕机）被 circuit breaker 正确标记为 DEGRADED 后，该状态会持久化到 `domain_circuit_breakers` 表并跨重建存活。即使故障已恢复，DEGRADED 标记仍存在，导致该 function 在新会话中不可用。`DELETE FROM domain_circuit_breakers` 确保每次重建从干净的 CLOSED 状态开始，这是合理的运维实践。

**操作**——在 SSOT §13 和 init 脚本注释中，将此修正的描述从"DEGRADED 根因修复"更正为"防止合法 circuit breaker 状态跨重建存活"。

### 2. gate.js token 估算预拦截方案

**创建动机**——专门为防止"运行期间 DEGRADED"，假设 NIM 32K 超限返回 empty content 触发 DEGRADED。

**是否需要清理**——降级待办优先级，不实施。

**理由**——DEGRADED 的根因是 proxy 路由失败，非 NIM 超限。`proxy_enabled=0` 修复后，请求能正常到达 NIM。同时 per-model limits + compression 确保请求在 32K 以下，不会触发 NIM empty content。因此 gate.js 预拦截的前提（NIM 返回 empty content 触发 DEGRADED）已被证伪，方案失去必要性。

但存在一个理论残余——如果压缩引擎在极端边界情况下（如不可压缩部分本身接近 32K）仍偶尔超限，NIM 可能返回 empty content。此时 empty content 是否会触发 DEGRADED，取决于 OmniRoute 对 NIM 响应的错误分类逻辑。这一路径在 proxy 修复前无法验证（请求从未到达 NIM），proxy 修复后可以验证但目前无实证。

**操作**——将 SSOT §17 中"gate.js token 估算预拦截"的优先级从 P2 降为 P3，标注"proxy_enabled 修复后非必要，保留为极端边界场景的防呆设计"。

### 3. v3.7.0 的 proxy 生态关闭（env 层）

**创建动机**——为解决 DEGRADED，通过 `ONEPROXY_ENABLED=false` + `NO_PROXY` + `unset HTTP_PROXY` 等关闭全局 proxy。

**是否需要清理**——保留作为防御层，补充 `proxy_enabled` UPDATE 作为根治。

**理由**——env 关闭没有命中根因（OmniRoute 从 SQLite `key_value` 表读取 `proxyEnabled`，不从 env 读取），但 `NO_PROXY` 和 `unset HTTP_PROXY/HTTPS_PROXY/ALL_PROXY` 仍有防御价值——如果 HF Space Secrets 中残留了 proxy 环境变量，这些 unset 会清除它们，避免 Node.js 的全局 fetch 被代理干扰。`ONEPROXY_ENABLED=false` 关闭 OneProxy 子系统，即使 `proxy_enabled=1`，OneProxy 不会尝试创建新的代理连接——这是一个纵深防御层。

**操作**——保留 env 关闭代码不动，在 init 脚本注释中明确分层：
- env 层——防御性关闭（防止残留 proxy 环境变量干扰）
- proxy_registry 层——清理无效注册表条目
- `proxy_enabled` 层——DEGRADED 根因修复（DEFAULT 1 覆盖）

### 4. v3.7.0 的 purge_proxy_db（proxy_registry 清理）

**创建动机**——为解决 DEGRADED，清理 proxy_registry 中的 20129 条目。

**是否需要清理**——保留，有独立价值。

**理由**——proxy_registry 中的无效条目（指向 20129）即使在 `proxy_enabled=0` 后仍可能在某些代码路径下被查询或使用。清理 registry 确保无残留，是合理的卫生实践。当前全新数据库 registry=0，但增量模式下历史数据可能残留——purge 确保一致性。

**操作**——保留 purge_proxy_db 函数不动，`proxy_enabled` UPDATE 已加入同一函数。

### 5. per-model limits（real_context=32768）

**创建动机**——为解决 502 风暴，但也被当作"防止 DEGRADED"的手段。

**是否需要清理**——保留，独立有效。

**理由**——NIM 32K 隐藏限制是真实存在的平台级约束。即使 proxy 修复后请求能到达 NIM，如果压缩引擎不知道 32K 上限，长会话（如 77+ 条消息）仍会因超限触发 502 风暴。per-model limits 让压缩引擎按真实 32K 工作是独立于 DEGRADED 的必要修复。

**操作**——无需任何变更。

---

## 二、文档层面的清理

### 6. SSOT §13 "DEGRADED 持久化问题与修正"

**当前内容**——整个章节基于错误根因（domain_circuit_breakers 持久化），描述了"per-model limits 改变了请求大小分布 → NIM 对刚好超限的请求返回 200 + 空内容 → circuit breaker 标记 DEGRADED → 持久化到 DB"的错误因果链。

**操作**——重写 §13，更正为：

- 根因：`provider_connections.proxy_enabled DEFAULT 1`（core.ts:228）
- 注册 key 时自动启用代理 → 请求路由通过 proxy_registry → 20129 端口无服务 → ECONNREFUSED → 部分 function 不执行 direct fallback → DEGRADED
- 修复：`UPDATE provider_connections SET proxy_enabled=0 WHERE provider='nvidia'`
- 附带保留：`DELETE FROM domain_circuit_breakers`（防止合法熔断状态跨重建存活）
- 详细分析见 `docs/DEGRADED_POSTMORTEM.md`

### 7. SSOT §17 待办清单

**当前内容**——"gate.js token 估算预拦截"列为 P2，描述为"防运行期间 DEGRADED 的根本方案"。

**操作**——更新为：
- ~~gate.js token 估算预拦截~~ → 降级 P3，标注"proxy_enabled 修复后非必要，保留为极端边界防呆"
- 新增已完成项：`proxy_enabled=0 覆盖（DEGRADED 根因修复）` ✅

### 8. init 脚本注释中的 DEGRADED 相关描述

**当前内容**——v3.4.0 的修复历史注释中，`domain_circuit_breakers` 清除被描述为 DEGRADED 修复。

**操作**——在 v3.7.0+ 的注释中增加修正说明，明确 `proxy_enabled` 是根因修复，`domain_circuit_breakers` 是附带保留。

---

## 三、不需要清理的修正

以下修正虽然与 DEGRADED 调试过程有关，但均有独立价值，无需任何变更：

| 修正 | 独立价值 |
|------|---------|
| per-model limits（real_context=32768） | 防止 NIM 32K 超限触发 502 风暴 |
| Compression 端点纠正（PUT + 扁平 body） | v3.8.4x schema 适配，compression 从未生效→生效 |
| Thinking-budget 端点纠正 | v3.8.4x schema 适配 |
| maxBodySizeMb 字段名纠正 | 防止超大请求发送给 NIM（需修复单位转换 bug） |
| Memory embeddingSource remote→static | HF 免费层无需外部 Voyage key |
| SSOT 模型清单重构 | 消除三份清单打架 |
| 巡检函数 jq any() 修复 | 正确检测模型可用性 |
| NODE_OPTIONS 4GB 统一 | 防止 OOM |
| stream_options 验证关闭 | 减少不存在的风险待办 |
| nim-codex context-relay→round-robin | NIM 语义纠正 |
| .gitattributes LF 强制 | 防止 CRLF 导致 shebang 失效 |

---

## 四、具体操作命令

以下命令完成全部清理工作——SSOT §13 重写 + §17 待办更新 + init 脚本注释补充。建议将这些操作交给强模型在 Tabbit 中完成，因为涉及多处文档修改，在 cq3n 的 32K 限制下有风险。

### SSOT §13 重写

```bash
cd /home/laisi/omn-merge

# 定位 §13 的行范围
grep -n "## 13\.\|## 14\." docs/CURRENT_STATE_v3.8.md
```

拿到行号后，用 sed 或编辑器将 §13 整段替换为以下内容：

```markdown
## 13. DEGRADED 问题与修正

### 根因

`provider_connections` 表的 `proxy_enabled` 列定义为 `INTEGER NOT NULL DEFAULT 1`（源码 `src/lib/db/core.ts:228`）。init 脚本注册 NIM key 时请求体不含 `proxyEnabled` 字段，`normalizeBooleanColumn(undefined, true)` 返回 `true`，导致每个 key 的 `proxy_enabled` 自动设为 1。请求路由时 OmniRoute 检测到 `proxy_enabled=1` 即尝试通过 `proxy_registry` 路由，registry 为空或指向不存在的 127.0.0.1:20129 端口，连接失败后对部分 function（如 cg52）不执行 direct fallback，直接标记 DEGRADED。

### 修复

init 脚本 `purge_proxy_db` 函数中增加：

```bash
sqlite3 "$_DB_PATH" "UPDATE provider_connections SET proxy_enabled=0 WHERE provider='nvidia';"
```

### 附带保留——domain_circuit_breakers 清除

`DELETE FROM domain_circuit_breakers` 非根因修复，但保留以防止合法 circuit breaker 状态（如 key 临时失效导致的 DEGRADED）跨重建存活。

### 三层防御

| 层级 | 措施 | 作用 |
|------|------|------|
| env 层 | `ONEPROXY_ENABLED=false` + `NO_PROXY` + `unset HTTP_PROXY` | 防御性关闭，防止残留 proxy 环境变量干扰 |
| proxy_registry 层 | `purge_proxy_db` 清理 registry + assignments | 清理无效注册表条目 |
| proxy_enabled 层 | `UPDATE provider_connections SET proxy_enabled=0` | **DEGRADED 根因修复** |

### 详细分析

见 `docs/DEGRADED_POSTMORTEM.md`（根因链条 + 调试弯路 + 教训 + 诊断 Checklist）。
```

### SSOT §17 待办更新

```bash
# 定位 gate.js token 估算预拦截那一行
grep -n "gate.js token 估算预拦截" docs/CURRENT_STATE_v3.8.md
```

将该行更新为：

```
- ~~gate.js token 估算预拦截~~ → P3（proxy_enabled 修复后非必要，保留为极端边界防呆）
```

并在已完成项中新增：

```
- ✅ proxy_enabled=0 覆盖（DEGRADED 根因修复，v3.7.0+）
```

### commit + push

```bash
cd /home/laisi/omn-merge
git add docs/CURRENT_STATE_v3.8.md
git commit -m 'docs: SSOT §13 重写 DEGRADED 根因（proxy_enabled DEFAULT 1）+ §17 待办更新'
git push nomn main
```

---

## 五、总结

| 修正类型 | 数量 | 处理方式 |
|---------|------|---------|
| 代码层面——保留 | 11 项 | 全部保留，有独立价值 |
| 代码层面——补充说明 | 2 项 | `DELETE FROM domain_circuit_breakers` + proxy env 关闭，补充注释说明真实作用 |
| 代码层面——新增 | 1 项 | `proxy_enabled=0` UPDATE（根因修复，已在 v3.7.0 中加入） |
| 文档层面——重写 | 1 项 | SSOT §13 重写 |
| 文档层面——更新 | 1 项 | SSOT §17 待办降级 |
| 待办层面——降级 | 1 项 | gate.js 预拦截 P2→P3 |
| 从未实施——无需清理 | 1 项 | gate.js 预拦截方案 |

核心原则——不删除任何有独立价值的代码修正，但必须更正所有基于错误根因的文档描述，确保后续维护者不会重复走弯路。`DEGRADED_POSTMORTEM.md` 已经完整记录了根因和弯路，与重写后的 SSOT §13 形成双重保障。

*内容由 AI 生成仅供参考*