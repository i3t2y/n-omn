# nonoke/omn v4.3.0 rootfix 全链路闭环归档 (2026-07-21)

> 三天排查闭环归档。从 Step5 阻塞 → 双空间混淆 → 根因钉死 → 修复验收。每一步实证背书,可观测性/幂等/fail-closed 三短板顺手补齐。承接 `2026-07-20-r3plus-step5-anomaly-blocked.md`(其 §六①-③前置由本卡坐实闭环)。

## 0. 战果清单(每条实证背书)

| 项 | 结果 | 证据强度 |
|---|---|---|
| 根因 | readonly 块 jq `@tsv` 喂对象, `set -e` 下确定性崩 | 日志死亡点定位 + 离线 jq 实测 rc=5(旧式崩)/rc=0(新式) **双实证** |
| 修复 | 四处补丁全应用, `bash -n` 过 | 语法级 |
| 推送 | init `49f787c3` / entrypoint `151161d0` 上 main | Dataset API 文件树坐实 |
| combo | nim-pool + nim-codex 双 POST 201 | init 日志行为层 |
| 探针 | nim-codex 200(非400) 路由 deepseek-v4-pro + glm-5.2 直发 200 | gate 行为层 |
| 限流 | 28/3/2200/300000 读回全字段一致 | init 自带 fail-closed 核验 |
| 可观测性 | `[entrypoint] NIM init 已退出 rc=0 (正常完成)` 可 grep | 补丁④ + 日志 |
| 纪律 | 无抢修 + fail-closed 闭环 + 先日志后探针顺序 | 全程守红线 |

## 1. 根因(双实证坐实,非推断)

**日志死亡点**: runtime 日志打印 `[init] [readonly] GET /api/combos HTTP 200 :: combos=[]` 后,**应紧接 auto 行**——旧版无 auto 行输出 → 死点在其间。

**死点代码**(远端 main init L648, 850 行版):
```bash
_RO_AUTO_SUMMARY=$(jq -r '{id, name, strategy, models: (.models // [] | length)} | @tsv' /tmp/omn_ro_auto.json 2>/dev/null)
```
- `@tsv` 只接受**数组**;旧式喂**对象** `{id,name,...}` 必 jq 报错(退出码 5)
- `set -eo pipefail` 下命令替换 `VAR=$(cmd)` 非零退出 → 赋值非零 → 整脚本静默崩
- 每次 boot 打 combos 行后崩, upsert nim-pool/codex **从未执行** → combo 400

**离线实证**(systematic-debugging 第三阶段假设验证):
```
旧式对象@tsv: rc=5 (崩) —— 复现根因
新式数组@tsv `[.id,.name,.strategy,(.models//[]|length)]|@tsv`: rc=0 正常出 tsv `auto-1  auto  round-robin  2`
新式带 `|| true`: 赋值后 "NEXT-LINE-RAN" —— 脚本存活(根因根治证据)
```
根因从"推断"升级"实测"。

## 2. 四处补丁(全应用, `bash -n` 过)

| # | 补丁 | 落点 | 验证 |
|---|---|---|---|
| ① | readonly jq 改数组形式 + 三 jq `\|\| true` + 三 curl `\|\| echo "000"` | candidate init L651-660 | 日志 auto 行 `[空行4列0]` 存活 |
| ② | 横幅 v4.2.3→v4.3.0 + node 标识 + version arg + 两 Done 行 | L5/L7/L462/L735/L817/L854 | 日志 `v4.3.0 on node v24.18.0` |
| ③ | upsert_combo 非 2xx `echo ✗ + cat + return 1`(fail-closed) | L134 | 此轮 POST 201 未触发, 但语义纳入 |
| ④ | entrypoint init 退出 `wait $INIT_PID; rc=$?` + 非零 ✗ 标 | entrypoint-merged.sh L239 | 日志 `rc=0 (正常完成)` |
| (注) | candidate 早含 `_CONCURRENT :-1→-3`(R3+ Restart A, commit c8126267 已在 main) | L145 | 验收② concurrent=3 达标 |

## 3. 执行链(固定顺序,不跳步)

1. **应用补丁** → candidate init + entrypoint
2. **推送** ← `upload_file` 单文件(覆盖单路径不破其他):
   - init → main commit `49f787c3` (15:35:36 UTC)
   - entrypoint(远端名 `entrypoint.sh`) → main commit `151161d0` (15:35:38 UTC)
   - main 8 文件确认: init 51480B / entrypoint 12728B / gate.js 13314B / r2-157.bak 8995B / litestream.yml / package.json / README / .gitattributes
   - **关键**: main commit 链 `c8126267`(08:38) 早做 C=3 改动, candidate 与 main C=3 对齐, 推 init 锁住 C=3 ✓
3. **普通 restart**(factory_reboot=False, 非 factory reboot):
   - 选普通理由: 镜像层未变(只改 Dataset 逻辑层) + memory `hf-free-docker-build-blocked` factory_reboot 会触 7/16 build 冻
   - bootstrap 容器启动重拉新 init; task包"factory reboot"泛指重启 Space, 普通restart达目标且零build冻风险
4. **boot 日志**: Space ~30s RUNNING_APP_STARTING→RUNNING; bootstrap A 模式补环境(python3.13+curl+jq+sqlite3+hf-hub 1.24)约 60s; litestream 0.5.9 sync-interval=10s; R2 bucket omn-data(隔离生产 omniroute-data)✓
5. **七项核验**: 全过(见 §4)
6. **探针**: 全绿(见 §5)

## 4. 七项日志核验(全过)

| 项 | 预期 | 日志实证 | 判 |
|---|---|---|---|
| ① | 横幅 v4.3.0+node | `v4.3.0 (profile=balanced, mode=DEBUG) on node v24.18.0` | ✅ |
| ② | Resilience 读回 28/3/2200/300000 一致 | `RPM=28 minMs=2200 concurrent=3 maxWaitMs=300000` + `✓ 全字段一致` | ✅ |
| ③ | readonly 三 GET 全打印, auto 不死 | combos=[] + auto=`[空行4列0]` + providers=8个nvidia + `三份 GET 完` | ✅ **auto 行存活=根因修复实证** |
| ④ | Compression 200 / CB reset / override 9 | `Compression HTTP 200` + `CB reset HTTP 200` + `override: 9 applied, 0 failed.` | ✅ |
| ⑤ | health + Registering | `check_nim_model_health` 9/9 available + `Registering models` 9 OK | ✅ |
| ⑥ | upsert POST 200/201 | `upsert nim-pool: new -> POST HTTP 201` + `nim-codex: new -> POST HTTP 201` | ✅ **combo 400 根除** |
| ⑦ | Done v4.3.0 | `Done (first-init). v4.3.0` | ✅ |
| 补丁④ | init 退出 rc 标 | `[entrypoint] NIM init 已退出 rc=0 (正常完成).` | ✅ |

## 5. 探针(全绿, 七项全过才放, 铁律守)

gate 鉴权契约: `/v1/*` 用 `X-Internal-PSK` 单头(`safeCompare(bearer, PSK)`); Authorization Bearer 值须=PSK **非** OMNIROUTE_API_KEY。gate 后台关(`GATE_ADMIN_TOKEN<16` → `/api/* 404`)。

| 探针 | 结果 | 证据 |
|---|---|---|
| model=nim-codex | HTTP **200**(非 400!) | 路由 `deepseek-ai/deepseek-v4-pro`(nim-codex 策略=priority **首成员命中**, 非 nim-pool 的 p2c 轮转); `finish_reason:length`; dur 29.5s(thinking 长思 maxWaitMs=300000 容下不 429) |
| model=nvidia/z-ai/glm-5.2 直发 | HTTP **200** | "Pong! GLM is here and running normally."; dur 8.5s |

## 6. 复盘 — 三流程漏洞 + 已固化对策

| 漏洞 | 后果 | 对策(已落) |
|---|---|---|
| 横幅撒谎(旧 v4.2.3 横幅跑新版) | 第一天"部署链断裂"误判 | 横幅带版本+node 标识 → 七项核验第一项 |
| 证据张冠李戴(生产 4.2.3 日志作 dev 证据) | 第二轮误判 | 双空间隔离铁律 + 拓扑隔离表写进交接包 |
| 无声崩溃无标记("非致命") | 死亡点日志隐形一天 | rc=$? 标注 + 非零 ✗ (补丁④) |

**正向经验**: fail-closed 设计立功 —— Resilience 读回核验(脚本自带)全程绿灯, 成区分"前半健康/后半死亡"的关键分界证据。upsert 现纳入同语义(补丁③)。

## 7. 系统化调试四阶段落地回溯

- **阶段1根因**: 读错误 → 日志死亡点(combos行后无auto) → 复现(离线jq套) → 查近期变更(cache snapshot diff) → **关键: 离线读远端真源 main init 坐实死点存在**(非仅 candidate 有)
- **阶段2模式**: 正常 jq(数组@tsv L648/652)一条, 死亡 jq(对象@tsv L648)一条 → 差异[@tsv 喂对象] + 依赖[set -eo pipefail 命令替换语义]
- **阶段3假设**: "jq @tsv 喂对象致非0退出, pipefail 赋值非0崩整脚本" → 最小测试(见 §1 实证三行) → 验证
- **阶段4实施**: 单一修复(数组@tsv+护栏+横幅+fail-closed+rc), 失败测试用例(离线jq), 验证修复(rc=0 + 日志auto存活 + 探针200)。未到架构质疑(一次修复@根因)

## 8. 增量模式首次实弹检验(下次有意 reboot 顺验, 非阻塞)

此轮 first-init(POST 201 新建)。下次 reboot 首次走 Incremental mode 分支:
- 预期: `[init] Incremental mode.` + upsert **POST 201 → PUT 200**(幂等⑦) + `Done (incremental). v4.3.0`
- ⑦ 幂等 upsert 为防 R2 restore 后撞名 400 死循环而写, 此前从未真机跑过
- 验通过 = "重启零副作用"永续关键属性闭环

## 9. Step5 恢复验收序列(承接落地)

1. **combo 读回终验**: 确认 nim-pool(p2c,9 模型)/nim-codex(priority,3 模型)成员与 TIER 分档一致
   - ⚠ gate 后台关(`GATE_ADMIN_TOKEN<16` → `/api/* 404`), **`经 gate /api/combos 确认`路径不可行**(阻塞卡 §六②-1 T0 实证 404)
   - 可行路径 (a): init `hf_snapshot` 每 boot 上传 `combos.json` 至 Dataset(nonoke/omni-logic) — 直接读该文件即成员快照
   - 可行路径 (b) 优: 下次有意 reboot 增量模式 `existed -> PUT 200` 本身即读回证明(增量分支先 GET 拿 CID 才走 PUT), 与 §8 增量实弹合并一次验, 不单独做
2. **nim-pool 探针**: model=nim-pool 打一发, 路由池内成员非 400
3. **排队行为观察**(maxWaitMs=300000 首次受载): 3-5 并发打 glm-5.2, 观 300s 排队完成, 无 120s 旧档丢弃
4. **codex priority 行为**: 连续多发 nim-codex, 确优先钉 deepseek-v4-pro(priority 首成员)非轮转
5. **稳定观察窗**: 挂机 1-2h, 无罚态风暴无 queue drop
6. (下次有意 reboot)增量模式验证

## 10. 知识归档(未来会话直引)

**omni 空间拓扑**: nomke/omn = 生产(4.2.3, 25 key, R2 omniroute-data); nonoke/omn = 永续 dev(v4.3.0, 8 key, R2 omn-data, 逻辑库 nonoke/omni-logic main)。

**判读签名表**(v4.3.0 健康 boot):
横幅 v4.3.0+node → 8 keys → Resilience 读回 28/3/2200/300000 → readonly 三 GET → Compression 200 → CB reset → override 9 → health 9/9 → models 9 OK → upsert PUT(增量)/POST 201(首启) → rc=0 → Done v4.3.0

**排障口诀**:
1. 日志签名先于行为探针(铁律)
2. 横幅带版本+node —— 日志自证身份
3. set -e 脚本无护栏 `VAR=$(cmd)` 命令替换 = 一等静默崩嫌疑
4. 死亡点定位 = 最后打印行与下一应有行之间

## 11. 作废结论(禁止继承)

- "新版 init 未生效"(已证伪, 部署链健康; combo 400 真因在 readonly 死点)
- "增量/首启分支选择错误"(脚本走不到分支, 死在 readonly 块)
- 旧根因候选 (a)-(d) 全部
- **铁律**: 内部状态只认日志签名, 探针只做最终确认, 顺序不可反

## 12. filesystem 痕迹(commit/文件级)

- candidate init: `/home/laisi/omn-merge/candidate-v4.3-reviewed/init-nim-keys.sh`(860 行, 四补丁)
- candidate entrypoint: `entrypoint-merged.sh` L239(补丁④)
- Dataset main: `nonoke/omni-logic` commits 49f787c3 / 151161d0
- HF cache snapshot: `~/.cache/huggingface/hub/datasets--nonoke--omni-logic/snapshots/63f5a70c` 旁新推两件
- memory: `nonoke-omn-v4.3.0-rootfix-landed.md` + `nonoke-omn-v4.3.0-signature-and-step5.md`

---

*2026-07-21 归档 · rootfix 全闭环 · 根因 jq 实测 rc=5/0 升级推断为实测 · 七项日志 + 双探针行为层贯通 · 可观测性/幂等/fail-closed 三短板顺手补齐 · systemat化调试四阶段全程实证 · Step5 阻塞→双空间混淆→根因钉死→修复验收绕路换实证 · 永续节点状态比三天前设计时更扎实*
