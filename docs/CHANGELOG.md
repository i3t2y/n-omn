这是为您整理的 **v4.2.x 系列版本变更日志 (Changelog)**。你可以将其追加到 `README.md` 的末尾，或者单独保存为 `CHANGELOG.md`。

这份日志记录了从最初的 v3.8.0 增量脚本，到解决 400 策略错误、R2 冲突、再到实现被动健康决策和日志入库的全过程。

---

## **OmniRoute NIM Initializer Changelog**

### **v4.2.3 (2026-07-10)**
- **[新功能] DEBUG 日志入库**：`hf_snapshot` 现在支持将 `init_*.log` 拷入 snapshot 目录并重命名为 `debug_*.log` 上传至 HF Dataset。
- **[运维] 本地日志滚动**：新增 `NIM_DEBUG_LOG_KEEP` 变量（默认 5），自动清理容器内 `/data` 目录下的旧初始化日志，防止磁盘膨胀。
- **[文档] 升级论证**：基于 GitHub Issue #6773 (NIM 404) 论证了维持 3.8.43 版本的必要性，并制定了升级复查触发条件。
- **[修复] context-monitor 累积判读八进制算术错误**（`context_accumulator_update`，阻断性）：原 `IFS=$'\t' read` 把 tab 当 IFS 空白类——折叠连续空字段、剥离行首 tab，一旦某列（`model`/`suc_max`/`fail_min`）为 NULL→空串，6 列被折叠成 <6 段，`MAX(timestamp)` 串错位落入 `_fail_n`，进 `$(( _suc_n + _fail_n ))` 触发八进制解析报错（`error token "09T22"`），致累积更新整swallow 中断。改用 `mapfile -t -d $'\t'` 数组逐字段拆行，保留空字段、6 索引严格对齐 SQL 列序，数字列空兜 0。
- **[修复] nim_health_pick 列名改 3.8.43 真实列**（`_score_model`，既有 bug）：原 `SELECT` 用 `status_code`/`model_id`/`created_at`/`latency_ms` 全列错名，`call_logs` 无对应列 → `sqlite3` 报错被 `2>/dev/null` 吞 → row 恒空 → 恒 `NA`，选型全程失效退默认档。按 `OmniRoute src/lib/usage/callLogs.ts` 确认真实列名后重写：`status_code→status`、`model_id→model`、`created_at→timestamp`；移除无对应列的 `AVG(latency_ms)` 聚合，`SELECT` 瘦身为 成功率+样本数 两列；`_pick_from` 同步剥 ms 延迟比较与展示，退化为按成功率选型。
- **[修复] context_accumulator_update confidence 写空致 #2 回写失效**（既有 bug）：原 `confidence='$(_conf)'` 误用命令替换 `$(_conf)`（应为变量展开 `$_conf`），bash 执行命令 `_conf` → `command not found` → confidence 写空串。下游 #2 回写逻辑 `WHERE confidence IN ('medium','high')` 对空串不命中 → `model_context_overrides` 的 `monitor+manual` 行恒 0，高置信推荐（如 glm-5.2 382 样本应判 high）永不落地。改 `$_conf`，并加防回归注释区分命令替换与变量展开。
### **v4.2.2 (2026-07-09)**
- **[修复] 幂等 Combo 创建**：新增 `upsert_combo` 函数，通过“先 GET 查名再决定 PUT/POST”的逻辑，彻底解决了 R2 restore 回旧 DB 后导致的 `Combo name already exists` (400) 报错。
- **[优化] 增量判定逻辑**：放宽增量模式入口，任一 `nim-*` combo 存在或 `INIT_MARKER` 存在即跳过首次注册，提升 Space 重启速度。
- **[修复] 探针鲁棒性**：修复了探针在某些极端网络下可能导致的变量残留问题，确保 `nim-probe-bad.txt` 每次运行前重置。

### **v4.2.1 (2026-07-09)**
- **[核心修复] 移除非法策略**：彻底移除 `quota-share` 策略（确认为内部机制而非合法 combo strategy），主池默认切换为 `p2c`。
- **[新功能] 策略白名单**：引入 `_is_valid_strat` 校验，所有 combo 策略必须通过 3.8.43 合法性白名单，非法值强制降级 `round-robin`，根治 400 错误。
- **[新功能] 被动健康选型**：新增 `nim_health_pick()` 函数。通过 SQL 统计本地 `call_logs` 近 1 小时的真实成功率与延迟，实现“零风控足迹”的模型推荐。
- **[优化] 熔断历史保留**：修改增量模式下的 breaker 清理逻辑，仅删除过期熔断，保留仍在冷却窗内的健康信号。
- **[新功能] 轻量主动探针**：新增 `nim_probe()` 函数（默认关闭），实现每模型每小时 1 次、max_tokens=1 的极低频跨 key 轮换探测。

### **v4.2.0 (2026-07-08)**
- **[优化] 模型目录对齐**：全量更新 `TIER_FAST` / `TIER_STABLE` 清单，对齐 2026-07 现行 NVIDIA NIM 官方 slug（如 `glm-5.2` / `deepseek-v4-pro`）。
- **[优化] 动态配额推导**：RPM 与并发数不再写死，改为按 `存活 Key 数 × 35` 动态计算，充分榨取多账号池性能。
- **[新功能] 多层兜底 Combo**：新增 `nim-max` 组合，实现“NIM 存活池 → 免费供应商（Cerebras/Pollinations/CF）”的自动滑落，确保永不断供。

### **v4.1.0 (2026-07-01)**
- **[架构] 基础镜像钉死**：引入 digest 双写锁定 `3.8.43`，规避 `latest` 标签导致的 Turbopack 构建失败与 migration 117 挂起问题。
- **[功能] 实时探活**：引入 `check_nim_model_health`，启动时通过 `/v1/models` 自动过滤已被 NVIDIA 下架的模型，根治 404 报错。
- **[修复] 格式订正**：将 combo models 格式由字符串数组修正为对象数组 `[{"model":"x"}]`。

---
*Base Version: v3.8.0-legacy*

*内容由 AI 生成仅供参考*