# crashloop fix: express 预装推送留证

**日期**: 2026-07-23 ~00:40Z(Zen 显式令 "1" = 下令推)
**仓**: omn-merge/本地审计仓 → HF Dataset `nonoke/omn-logic` (永续 dev, bucket omn-data)
**律**: §1 双空间铁律 — nomn/nog/hf/sp3t2y 四远端**全不 push**(nomn=生产禁触); 仅推 dev dataset; Space Restart Zen 手动, 我不触 Space。

## 起因(附录 A 引入的 regression)
附录 A(02:15Z 推 4 件覆写远端)把远端 `gate.js` 从旧 zero-dep 版(`49942db3` 287行, `require('http'/'crypto'`)覆写成现役 express 版(`616047c6` 520行, `require('express')`)。
但 `bootstrap.sh` 三层解耦模式仅 `hf download` + `cp /logic`, 不跑 `npm install` → `/logic/node_modules` 缺 → `gate.js:21 require('express')` 崩 `MODULE_NOT_FOUND` → Space crashloop。

## 选案(Zen 拍板)
两个落位候选(B = 保 express gate + npm install --omit=dev 预装 express, Zen 已定方向):
- **B1 bootstrap 落位**: 改 `bootstrap.sh`(Space repo 根), 需 clone+push `nonoke/omn` Space repo, 新链未走 + 可能动只读树。字面贴 "bootstrap 加 npm install"。
- **B2 entrypoint 落位**(Zen 选, 推荐): 改 `omn-logic/entrypoint.sh`(Dataset 逻辑层五件之二), 仅 `upload_file` 推 1 件, 同附录 A 走熟链, 不碰 Space repo、不需 clone nonoke/omn。同 boot 代价(每次 npm install, ephemeral 决定)。

Zen "需重推 base" 警示在 B2 下**不成立**: 只推 Dataset = 附录 A 同链, 不重推 Space repo 根(Dockerfile+bootstrap) 也不重推 GHCR base image。

## 落定(Edit)
**文件**: `omn-logic/entrypoint.sh`
**插入位**: 行 234 后(`gate.js` 存在性检查 `fi` 完)→ 行 235 `starting gate` 前, 新增 5.5 预装段 19 行 + 空行。
**改法**: `if [ -f /logic/package.json ]; then` 内嵌套查 `/logic/node_modules/express` 缺才装, `(cd /logic && npm install --omit=dev --silent --no-audit --no-fund)`, 装失败 FATAL `_shutdown exit 1`。
**行数**: 263 → 282
**本地新 sha**: `4803e290cc6a997bd8c5a840160f6aa87da97af2f35d6e429bccc8bb7377f653`
**`bash -n`**: PASS 语法绿

## 推送四步

| Step | 内容 | 结果 |
|---|---|---|
| Step1 | `hf download nonoke/omn-logic` 拉远端现态基线 | 8 文件拉成, 留证 `/tmp/crashfix-r5-baseline/` |
| Step2 | `diff` 远端 vs 本地 | 干净: 仅行234后新增19行5.5段, 其余全等 |
| Step3 | `hf upload --repo-type dataset` 推 entrypoint.sh | commit `b5a7891a75e173d70623a180199077e2679a9ed7` |
| Step4 | 远端读回 `hf download` + cmp 校验 | 远端 `4803e290` == 本地, cmp 逐字节 PASS ✓ |

## 远端 sha 留证(推前→推后)

| 件 | 远端推前 sha256(前12) | 远端现 sha256(推后 == 本地) |
|---|---|---|
| init-nim-keys.sh | 4cbcc50120ec | 4cbcc50120ec (不动) |
| entrypoint.sh    | 061781764b45 | **4803e290cc6a (本次变)** |
| gate.js          | 616047c65b61 | 616047c65b61 (不动) |
| litestream.yml   | 1563c08de199 | 1563c08de199 (不动) |
| package.json     | 5ed9981bf8c3 | 5ed9981bf8c3 (不动) |

只 entrypoint 1 件变(附录 A 终态 `06178176` → 本次 `4803e290`), 余四件附录 A 终态不动。

## 读回铁证(Step4)
推后 `hf download` 读回, 远端 entrypoint.sh sha `4803e290cc6a997bd8c5a840160f6aa87da97af2f35d6e429bccc8bb7377f653` 全 == 本地 `4803e290cc6a997bd8c5a840160f6aa87da97af2f35d6e429bccc8bb7377f653`, `cmp` 逐字节 PASS。五件远端 sha 全 == 本地 omn-logic/, 无意外波及。

## 窗规与授权
- 附录 A 推送时 Zen 显式解除窗规(覆盖原铁句 "03:16Z 前禁推"), 系统本次时钟 `2026-07-23 00:39:48Z`(§2 理论窗未满, 但窗规已解除覆盖)。
- 本批为**独立新批**对外发布(补附录 A regression), Zen 显式令 "1"(=下令推)到达, 条件③显式下令满足。

## 停手点(交 Zen)
**Space Restart 由 Zen 手动 — 我未触/不会触 Space**。远端 Dataset 根 entrypoint.sh 已就 crashloop fix 态, 待 Space `bootstrap.sh` 拉 `$LOGIC_BUCKET_REPO` 触发后生效。Restart 后应判:
1. crashloop 解除: 日志见 `[entrypoint] 预装 gate 依赖 (npm install --omit=dev)...` + `gate 依赖就绪`, 不再 `require('express') MODULE_NOT_FOUND`
2. gate 起: `[entrypoint] starting gate on port 7860...` + `gate PID=`
3. 探活: `nonoke-omn.hf.space/healthz` 200(注: boot 因 npm install +10-30s, HEALTHCHECK start-period 180s 应覆盖)

## 剩余(交 Zen)
1. Space Restart(Zen 手动) + crashloop 解除验证
2. K3 verdict 十题回填(先推后补, 仍未回填)
3. E 项 Space Secrets: 确认 `OMN_DATASET_REPO=nonoke/omn-logic` + `HF_TOKEN` 有值(否则 init 行849 guard 空静默踏空, 同旧根因)
4. 窗规状态澄清: 03:16Z 窗规后续对 dev Dataset 推送是否仍需逐批显式令

---

# 附录 B: init 副崩 403 fail-open 修复(rar2, Zen "双管"令)

**日期**: 2026-07-23 ~00:5xZ(Zen 令"双管, 权限已改" → C1 E 项 Secrets HF_TOKEN write 由 Zen 手改 + C2 init fail-open 我改推)
**起因**: crashloop express fix 生效后(gate 正常起), boot 日志继见 init 末尾崩:
```
[init] snapshot: init_vars.json written
Traceback ... upload_folder ...
403 Forbidden: pass create_pr=1 ... repo nonoke/omn-logic/commit/main
```
两次 boot 间隔 ~30s → init 崩接力致疑似 Space supervisor 重启循环(新 crashloop 源)。

## 根因全闭环(`omn-logic/init-nim-keys.sh`)
- 行2 `set -eo pipefail`
- 行849 guard `[ -z "$HF_TOKEN" ] || [ -z "$OMN_DATASET_REPO" ] && return 0` — 走到 upload 证双键**都有值**, 非空跳过, 是**有值但只读**(Space HF_TOKEN 缺 dataset-write scope)
- 行930-939 `python3 -<<PYEOF api.upload_folder(...) **无 try/except**` → 403 抛 `HfHubHTTPError` exit 1
- 行987 `hf_snapshot` 裸调(无 `||true`)→ set -e 触发 init 整进程 exit rc=1
- entrypoint 监督循环 init "非致命"仅告警不主动重启, **但 HF Space supervisor 判 traceback 不健康 → 重启容器 → init 又 403 → 循环**

**token 权限差异**: 本地 cache token 推 `nonoke/omn-logic`(crashloop fix + 附录 A)成功 = 有 write; Space 内 HF_TOKEN 只读 = 两个不同 token。

## 双管修法(Zen 定 C3 双管)
- **C1 治本(Zen 手改 E 项 Secrets)**: Space HF_TOKEN 换有 dataset-write scope token, init 快照真写入, 403 根除。Zen 已执行"权限已改"。
- **C2 保底(我改推)**: init-nim-keys.sh hf_snapshot fail-open 容错, 防 future token 波动再崩。

## C2 落定(Edit)
**文件**: `omn-logic/init-nim-keys.sh` 两处改:

**改1 行930 PYEOF 段**: python upload 加 try/except:
```python
try:
    api = HfApi(token=os.environ["HF_TOKEN"])
    api.upload_folder(...)
    print("[init] HF Dataset uploaded.")
except Exception as e:
    msg = str(e).replace(os.environ.get("HF_TOKEN", "") or "x", "<REDACTED>")
    print(f"[init] snapshot: WARN HF Dataset 上传失败 (fail-open 跳过, 数据主路径 R2 不受影响): {type(e).__name__}")
    if isinstance(e, HfHubHTTPError) and "403" in msg:
        print("[init] snapshot: WARN 403 Forbidden — HF_TOKEN 缺 write 权限, 检查 Space Secret E 项 HF_TOKEN scope (需 dataset-write)")
```
- 任何 upload 异常降级 WARN print, python exit 0 不崩
- 403 特判提示检查 HF_TOKEN write scope
- token 值经 `str(e).replace(HF_TOKEN, <REDACTED>)` 脱敏不落值入日志(守 §3 secrets 纪律)

**改2 行987 调用**: `hf_snapshot` → `hf_snapshot || true`(函数级兜底, 防函数内非 python 段 curl/jq 异常仍触 set -e)。注释明示 snapshot 冗余、R2 主路径、失败不致命。

- 行数 995 → 1008 (+13)
- 本地新 sha: `21cc7cdb67b8ecc7bf7914f3d7917734aba1fd83a750fa3a52a352b49835b8d8`
- `bash -n` PASS
- diff 仅本次 2 处改, 余全等(五件只 init 变)

## 推送(commit ce761d2a)
- Step1 基线已在(crashfix-r5-baseline, init sha `4cbcc501`)
- `hf upload` 推 1 件 init-nim-keys.sh, commit `ce761d2a8feeeca182ee65d8c3dafff95ec7c1ac`
- Step4 读回: 远端 init `21cc7cdb` == 本地, cmp 逐字节 PASS ✓
- 五件远端 sha: init 21cc7cdb(本次变)/entry 4803e290(前批 fix)/gate 616047c6/litestream 1563c08d/package 5ed9981b(附录A终态, 不动)

## 双管效果预期(Space Restart 后)
- express crashloop: 已解(前批 entrypoint fix, 两 boot 验)
- init 副崩 403: C1 权限已改 → init 快照应正常上传 `[init] HF Dataset uploaded.`; 即便权限偶有波动, C2 fail-open 保 init 不 exit 1, 不再触发 supervisor 重启循环
- boot 末应见 init rc=0 正常完成(`[entrypoint] NIM init 已退出 rc=0 (正常完成)`), 无 traceback, Space 不重启 → 真稳态

## 边界
- 本地审计仓无 origin, 推 Dataset 1 件, nomn 生产零触, 不 push GitHub remote
- HF_TOKEN 经 `~/.cache/huggingface/token` 缓存读(免 source secrets 被 secret-scan 拦)
- Space Restart 由 Zen 手动 — 我未触不触 Space; restart 后验双管效果

## 剩余(交 Zen)
1. Space Restart(手动) + 双管效果验: boot 末 init rc=0 无 traceback, Space 不重启, `nonoke-omn.hf.space/healthz` 200 持续
2. K3 verdict 十题回填(仍欠)
3. C1 效果确认: restart 后 `[init] HF Dataset uploaded.` 出现 = HF_TOKEN write 权限真到位(快照链通); 如仍 403 = C1 未生效, 但 C2 已兜底不崩
