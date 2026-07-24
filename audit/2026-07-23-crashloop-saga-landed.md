# crashloop saga 闭环留证(双期: express + init 副崩)

**日期**: 2026-07-23 01:05-01:08Z(Supreme 令序: "1"→"双管, 权限已改")
**Space**: nonoke-omn.hf.space(永续 dev, bucket omn-data)
**链长**: HF Dataset `nonoke/omn-logic` 逻辑层(五件之二改)+ Space Secrets E 项(Supreme 手)
**律**: §1 双空间铁律 — nomn 生产零触, 仅改 dev dataset; Space Restart Supreme 手动。

## saga 起源
附录 A(02:15Z 推 4 件覆写远端)把远端 gate.js 从旧 zero-dep(`49942db3`)覆写成现役 express 版(`616047c6` require('express')), 但 bootstrap 三层解耦模式仅 `hf download+cp /logic` 不跑 npm install → 引入 crashloop regression。修复过程揭露第二层 init 副崩。

## 第一期: express crashloop(B2 entrypoint 落位)
- 根因: `/logic/` 无 node_modules → `gate.js:21 require('express')` 崩 MODULE_NOT_FOUND
- 修: `omn-logic/entrypoint.sh` 行 234 后加 5.5 段 19 行, gate 起前 `(cd /logic && npm install --omit=dev --silent --no-audit --no-fund)` 预装 express
- 推 commit `b5a7891a`, sha `06178176`→`4803e290`, 读回 cmp 逐字节 PASS
- 效: 两 boot 见 `预装 gate 依赖` → `gate 依赖就绪` → `gate listening 0.0.0.0:7860`, require 崩消失
- 详见 audit/2026-07-23-crashloop-express-fix-landed.md 正文段

## 第二期: init 副崩 403(C2 fail-open + C1 Secrets 双管)
- 起: express 解后 gate 起成, 但 init 末 `upload_folder 403 Forbidden pass create_pr=1` traceback 致 init 整进程 exit rc=1, 两 boot 间隔 ~30s 疑 Space supervisor 重启循环接力
- 根因(`omn-logic/init-nim-keys.sh`): 行2 `set -eo pipefail` + 行849 guard 双键有值但 Space HF_TOKEN **只读**(缺 dataset-write scope) + 行930 PYEOF python `upload_folder` 无 try/except(403 抛 exit 1) + 行987 `hf_snapshot` 裸调(set -e 触发 init 整 exit rc=1), entrypoint 监督仅告警不主动重启 **但 HF Space supervisor 判 traceback 不健康 → 重启 → init 又 403 → 循环**
- token 权限差异: 本地 cache token 推 nonoke/omn-logic 成功=有 write; Space 内 HF_TOKEN 只读=两个不同 token
- 双管修法 C3(Supreme 定):
  - **C1 治本(Supreme 手改 E 项 Secrets)**: Space HF_TOKEN 换有 dataset-write scope token, Quick pracy已改。
  - **C2 保底(我改推)**: init-nim-keys.sh fail-open 容错防 future token 波动再崩。
- C2 Edit: 改1 行930 PYEOF python upload 加 `try: ... except Exception as e:` 降级 WARN + 403 特判提示查 HF_TOKEN scope + token 值 `str(e).replace(HF_TOKEN, <REDACTED>)`脱敏(守 §3); 改2 行987 `hf_snapshot`→`hf_snapshot || true` 函数级兜底防 curl/jq 非 python 段异常触 set -e
- C2 推 commit `ce761d2a`, sha `4cbcc501`→`21cc7cdb`, 行数 995→1008, 读回 cmp 逐字节 PASS
- 详见 audit/2026-07-23-crashloop-express-fix-landed.md 附录 B 段

## 闭环最终态(2026-07-23 01:05-01:08Z boot 日志铁证)
```
[entrypoint] 预装 gate 依赖 (npm install --omit=dev)...
[entrypoint] gate 依赖就绪
[entrypoint] starting gate on port 7860...
[gate] listening on 0.0.0.0:7860 -> 127.0.0.1:20128
...
[init] snapshot: init_vars.json written
[init] snapshot: DEBUG log 上传已禁用（默认关...).
[init] HF Dataset uploaded.        ← C1 治本生效(快照真写入, 403 根除)
[init] Done (incremental). v4.3.2
[entrypoint] NIM init 已退出 rc=0 (正常完成).   ← init 不再 traceback exit 1
... litestream compaction complete 01:06:32 ...  ← 自然运行, 未见二次 [bootstrap]
```
- express crashloop: 根除(gate 稳 listening 7860)
- init 副崩: 根除(`HF Dataset uploaded.` = C1 write 权限真到位; init rc=0 正常完成无 traceback)
- C2 保底备而未用(C1 已治本, upload 成功未走 except 分支), 仍在位防 future token 波动
- **Space 不再重启循环**(boot 01:05:44 → log 尾 01:06:32 自然活跃, 当前 01:08:38Z 无二次 boot) = 真稳态

## 完整健康签名(Boot 01:05)
- upstream: Next.js 16.2.9 Ready, version 3.8.43, EXPOSED 7860→OR 20128
- R2: 恢复成功 + litestream replicate bucket omn-data sync-interval 10s 正常
- init: 6 alive / 2 auth_dead(403 账户级死), 6 key 注册 nim-01/02/05/06/07/08, Resilience 读回 `RPM=210 minMs=285 concurrent=18 maxWaitMs=300000` 全字段一致
- 9 模型 health available(z-ai/glm-5.2, deepseek-v4-flash/pro, llama-3.3-70b, nemotron-3-super-120b, gpt-oss-120b, qwen3.5-397b, mistral-small-4, gemma-4-31b)/118 available
- combo upsert nim-pool/nim-codex PUT 200
- gate: listening 7860→20128, admin UI disabled(GATE_ADMIN_TOKEN <16)
- M7 外科单注: STREAM_READINESS_TIMEOUT_MS=180000(wiki §15 实证)

## 五件远端 Dataset 最终态
| 件 | sha256(前12) | 来源 |
|---|---|---|
| init-nim-keys.sh | 21cc7cdb67b8 | 二期 C2 fail-open(本次) |
| entrypoint.sh    | 4803e290cc6a | 一期 B2 express(本次) |
| gate.js          | 616047c65b61 | 附录 A 覆写 |
| litestream.yml   | 1563c08de199 | 不动 |
| package.json     | 5ed9981bf8c3 | 附录 A 覆写 |

## saga 双期 commit 序列(Dataset nonoke/omn-logic)
- 附录 A(4 件覆写): commit 蕴含 init 3fc4b529/entry 97d47d1c/gate 7e78bc28/package d08574b2
- 一期 express(entrypoint): commit `b5a7891a75e173d70623a180199077e2679a9ed7`
- 二期 C2(init fail-open): commit `ce761d2a8feeeca182ee65d8c3dafff95ec7c1ac`

## 边界遵守全审
- 本地审计仓无 origin, 推 Dataset 共累计 6 件跨 3 批(附录 A + express + C2), nomn 生产**零触**, 不 push 任何 GitHub remote
- HF_TOKEN 经 `~/.cache/huggingface/token` 缓存读(免 source secrets 被 secret-scan 拦), secret 值零入会话/零入 git(上传 fail-open 段 token 脱敏)
- Space Restart 全程由 Supreme 手动 — 我未触不触 Space Secrets/Space 重启动作
- 三层解耦铁律守: 改逻辑层(Dataset entrypoint+init), 不碰环境层(GHCR base)/Space repo 根(bootstrap)

## saga 闭环确认
crashloop saga 双期(express MODULE_NOT_FOUND + init 403 副崩接力)**全根除**, nonoke-omn.hf.space **真稳态运行**。boot 01:05:44–01:06:32 完整健康签名已锁, 两期 fix 链路铁证读回全绿。

## 剩余(非 saga 内, 独立欠项)
1. K3 verdict 十题回填(摘要记先推后补, 仍欠 — 不阻 saga, 独立审项)
2. 窗规状态澄清(03:16Z 后续 dev Dataset 推送逐批显式令?)
3. 周期探活/金丝雀: Space 稳态后可启金丝雀三轮(R1/R2/R3, §2 时序)验证生产意图前的 dev 压力 — 非 saga 范畴
