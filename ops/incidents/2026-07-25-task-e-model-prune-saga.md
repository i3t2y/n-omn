# Task E · route-slow 三模型剔令 saga 回填

> boot#3 matrix 暴 gpt-oss-120b + llama-3.3-70b 路由慢挂 (101s 超时 / probe 000000), Task D 先剔 qwen3.5-397b (catalog 可查 ≠ 可服务, 上游 function-not-found 404). boot#5 (7-25 16:25Z) 前完成五处注释化, 终结 combo 双 PUT 回冲复活路径. 本档回填五认知入 audit.

## §1 病历 (boot#3 matrix)
- **nim-codex 笔 1**: priority 命中 `openai/gpt-oss-120b` → 101s 超时挂, 无 fallback.
- **nim-pool 笔 2**: 路由命中 gpt-oss-120b + llama-3.3-70b → 101s 超时挂.
- **probe**: 部分 key 返回 HTTP 000000 (路由层断, 非账户死 — 区别 auth_dead 403).
- **病根**: `check_nim_model_health` 探 NVIDIA 目录有 = `available`, 不标 deprecated; `filter_alive` (init:318) 只剔 `/tmp/nim-deprecated.txt` 命中, 不剔 route-slow → 每 boot combo PUT 把死模型回冲复活. **落源 (注释化 TIER/CODEX 数组) 不落库 (admin 删) 方能切除复灌路径**.

## §2 五处落点 (init-nim-keys.sh)
| 落点 | 行位 | 模型 | 任务 |
|------|------|------|------|
| TIER_FAST | :64 | `meta/llama-3.3-70b-instruct` | Task E 主剔 |
| TIER_STABLE | :68 | `openai/gpt-oss-120b` | Task E 主剔 |
| TIER_STABLE | :69 | `qwen/qwen3.5-397b-a17b` | **Task D 先剔** (非 Task E) |
| NIM_CODEX_MODELS | :89 | `openai/gpt-oss-120b` | Task E 主剔 (codex 同步删) |
| NIM_FAST_MODELS | :94 | `meta/llama-3.3-70b-instruct` | Task E 漏网补剔 |

**措辞修正 (K3 裁)**: "三剔模型"实为"两剔 (Task E) + 一先剔 (Task D)" — qwen3.5-397b 从未入 boot#3/#4 的 8 员意向池, Task D 先行剔除. 旧账册若记三员同案须改, 防误读.

## §3 漏网补剔 (commit b6fa1bb)
- **病灶**: NIM_FAST_MODELS (:92-96) 不进 combo upsert (1023/1024 链), 仅入 `init_vars.json` 快照 (行939 `_arr_json fast_models`). Task E 主剔三处 (TIER_FAST:64 / TIER_STABLE:68 / NIM_CODEX_MODELS:89) 落后, `NIM_FAST_MODELS` 残 `llama-3.3-70b` → **快照说谎**: boot 取证读 init_vars.json 见 llama 在册, 误导未来判案.
- **补剔**: 圣上裁"行94 同样注释化"顺势成全闸复验, 一 push 自动再触 sync-logic-dev 充活体探针.
- **commit**: `b6fa1bb fix(init): Task E 漏网补剔 — NIM_FAST_MODELS llama-3.3-70b 注释化 (snapshot 档)`

## §4 sync 链真态 — 推测升实证 (7-26 cg52 追证)
三个互斥假说 (push 自动触绿 / 圣上手动 dispatch / sync 失败后圣上手改 Dataset) 经 GitHub API 直读分家:

| run id | head commit | conclusion | event | created_at (UTC) |
|---|---|---|---|---|
| #30164340629 | `968b1a1` | **success** | **push** | 2026-07-25T15:48:05Z |
| #30155204189 | `9fe67be` | success | push | 2026-07-25T10:51:14Z |

- **run #30164340629 步骤级绿**: `Upload logic files to Dataset (5 files, flat layout)` ✅ + `Verify sha256 readback (逐字节血缘验证)` ✅ — 即 sync-logic-dev.yml :46-66 sha256 cmp 步骤绿, 5 件 local `dev/logic/**` 与 Dataset `nonoke/omn-logic` 逐字节等.
- **968b1a1 第一父 = 7f39a25** (Task E 主剔), 推 merge 时一并推上远端 → 自动触 sync, 绿. 假说①实证成立; 假说②③排除 (event=push 非 dispatch, conclusion=success 非失败).
- **时序**: sync 15:48Z 绿 → boot#5 16:25Z 拉, boot 拉的是 sync 后 Dataset 终点货. 链通.

**遣憾未闭**: `b6fa1bb` 漏网补剔 **未推远端** (本地 `main ahead nomn/main 1`), 未触 sync. **Dataset 侧 init 不含行94漏网补剔**, Dataset 侧 init_vars.json 快照仍残 llama 残影 (说谎病在 Dataset 侧未根治). 因 `NIM_FAST_MODELS` 不进 combo upsert, 对 pool 意向 6 与 boot#5 注册序列零影响 — 仅为快照档纯洁性欠账, 须圣上推 b6fa1bb 触 sync 方彻底闭.

### b6fa1bb 闭环 (7-25 17:43Z 圣上准推)
- **push**: `968b1a1..b6fa1bb main -> main` (圣上 ! git push)
- **sync run #30168186734**: head=b6fa1bb | **success** | push | 2026-07-25T17:43:01Z, 步骤级 8 步全 success (含 `Upload logic files to Dataset (5 files)` + `Verify sha256 readback (逐字节血缘验证)` 双核心步绿)
- **Dataset 侧 readback 含 Task E 注释痕 (证②)**: hf_hub_download 抽 `init-nim-keys.sh` (snapshot 995f3e65) → remote sha256 = `8e67fc4e38d0` == local sha256 `8e67fc4e38d0` 逐字节等 ✅. 行 94 真态: `# "meta/llama-3.3-70b-instruct"  # 2026-07-25 Task E 漏网补剔 (snapshot 档) ...` ✅
- **Dataset 侧 init_vars.json 快照 llama 残影说谎病根治**, b6fa1bb commit message 自带 "Restart 令自此必须挂两份实证之后 (sync run 绿证 + Dataset readback 含 Task E 注释痕)" 两证闸全收, 闸可解

## §5 probe 缺位认知 (K3 裁入档)
- boot#5 报告全程未提 `nim_probe` 段. boot#3 时代 probe 有 000000/404 对照可读, boot#5 无此段 → **探活对照不在九段绿标构成内**, "全绿"不含探活维度.
- 入档防误读: 九段绿不证 probe 健度. matrix 须独立补探活对照段.

## §6 C1 前置闸 (matrix 开票前增补)
- C1 触发条件 = nim-codex 超时, "priority 命中 gpt-oss-120b" 归因至今无日志实证.
- gpt-oss-120b 已剔, codex 池现 `deepseek-ai/deepseek-v4-pro` + `z-ai/glm-5.2` 双员.
- **裁**: matrix 执行每笔请求必贴 OmniRoute 日志 `ROUTING` / `Using account` 行, 逐笔落 veri 库. nim-codex 超时 → 先读回该笔真实路由模型再裁 C1, 防盲调.

## §6.5 ③matrix 停测真因 (圣上 7-26 裁: 跳过)

**真态暴露**: Space RUNNING 后探 `/v1/chat/completions` 报 `No active credentials for provider: z-ai`, 与 boot#5 日志 `[init] probe z-ai/glm-5.2 32 alive` 表观矛盾.

**圣上裁真因 (钉死)**: 两 Space (nomke/omn 生产 + nonoke/omn dev) **共用同一批 NIM keys**, nonoke 多 8 key. **cg52 自身即通过 nomke 生产 glm-5.2 跑** — 我在 nonoke dev /v1 再发用同 batch key → 占额度冲撞 → provider z-ai 凭据报错 (并非 provider connection 病, 是 key 共享面冲突).

**处置**: ③matrix 四 combo / ④C1 归因**按圣令跳过** — 矩阵复跑实测即污染 key 配额. 前置闸非"卡顿未解"是"结构性不可执行", 入账防未来再探趟坑.

**等价证闭合**: matrix 双 combo 绿的真前置 (剔模型生效) 已他路实证 — ①sync 真态绿 + ②admin 404 + boot#5 注册序列 6 模型全等 + Resilience 300/96/200/300000 读回 + override 6 applied. 主链九段全绿 + 五处剔令注释化闭合可作晋级判据; matrix 四笔实测留切流后 (单 Space 写态) 补验.

## §5后续余账
- [ ] 圣上推 b6fa1bb 触 sync, 根除 Dataset 侧 init_vars 快照 llama 残影
- [ ] ② admin /admin 404 补扎 ✅ 实证落地 (现 RUNNING /admin→404)
- [ ] ~~③ matrix 四笔双 combo~~ — 圣令跳过, 留切流后 (单 Space 写态) 补验
- [ ] ~~④ nim-codex 超时路由归因~~ — 随③跳过
- [ ] ECONNRESET 治理三后案 (SSE 心跳保活 / 压缩阈值对齐 202752 / bootstrap 钉 revision) — 切流后立项
- [ ] bootstrap `hf download` 无 `--revision` 竞速根因 (圣上 K3 裁硬化案): sync workflow 上传后回写 SHA, bootstrap 按 SHA 拉取, 从根消除 boot#4 拉出旧源的竞速
- [ ] probe 缺位 — matrix 路由读回真路径改为 fetch-space-logs evidence 分支消费, 非 Space stdout 直接
