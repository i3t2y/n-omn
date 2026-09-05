# ROLLBACK — omniroute 太空舱 v4.3 candidate

> 回退步骤. 不输出/复制任何 Secret 值.

## 快速回退 (关闭后台, 仅 API 暴露)

后台访问由 `GATE_ADMIN_TOKEN` 控制. 关闭后台只需删除该 Secret 并重启:

1. HF Space → Settings → Variables and secrets → 删除 `GATE_ADMIN_TOKEN`.
2. 重启 Space (Factory reboot).
3. 验证: `curl https://<space>/`  → 404; `curl https://<space>/api/providers` → 404; `/healthz` 仍 200; `/v1/*` 仍 PSK 可用.

**整候选回生产 B1**: 不强制. candidate 在独立目录, 直接拉 `nomn/main@42ea8e7` 即回到 B1 生产版 (psk/entrypoint/litestream 原行为).

## LiteStream 回退 (auto-recover)

若需恢复 litestream 自恢复 (`auto-recover: true`) — 注意这会绕过 entrypoint guard (可能覆盖有效 DB), 仅在确信本地无有效 DB 时:
1. 编辑 `litestream.yml`: `auto-recover: true`.
2. 重启 Space.
3. 验证日志含 litestream replicate 自恢复消息.

##LiteStream strict 回退

`LITESTREAM_STRICT=0` 恢复 B1 非致命模式 (restore 失败 warn continue, 不 exit):
- HF Space Settings → 加 `LITESTREAM_STRICT=0`.
- 重启.
- **不推荐** (绕过 fail-safe); 仅诊断恢复问题用.

## 单项功能回退 (Section D 不推荐整段)

- 限流恢复线性 (按 alive_keys): 设 `NIM_FIXED_RPM=35` `NIM_FIXED_CONCURRENT=3` `NIM_FIXED_MIN_INTERVAL_MS=1714` 近似 B1. 不恢复线性算式 (G3 决议保留固定值可调).
- DEBUG Dataset 上传恢复默认开: 设 `NIM_DEBUG_LOG_TO_DATASET=1`. 仍脱敏.
- 上下文覆盖 (自动 Context Override): 不恢复直写 SQLite. 启用须经 API PATCH (见 KNOWN-UNVERIFIED), 仍默认关.

## 全候选目录丢弃

candidate 未合入生产. 如不采用:
```
rm -rf candidate-v4.3-reviewed/ audit/06-candidate-review.md
```
原 audit/00-05 保留审查历史.

## 不得泄露

- 回退步骤不得在命令、日志或文档中输出 `INTERNAL_PSK` / `GATE_ADMIN_TOKEN` / `OMNIROUTE_API_KEY` / NIM keys / R2 keys 真值.
- 如需重置 PSK/admin token: 生成强随机新值覆盖旧 Secret; 旧值不打印.
