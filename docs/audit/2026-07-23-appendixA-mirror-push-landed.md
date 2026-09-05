# 附录 A 镜像覆写推送留证

**日期**: 2026-07-23 ~02:15Z (Zen 显式解除窗规, 绿灯推)
**仓**: omn-merge/本地审计仓 → HF Dataset `nonoke/omn-logic` (永续 dev, bucket omn-data)
**律**: §1 双空间铁律 — nomn/nog/hf/sp3t2y 四远端**全不 push**(nomn=生产禁触); 仅推非oke dev dataset; Space Restart Zen 手动, 我不触 Space。

## 窗规解除记录
原铁句(02:03Z memory 落字): "03:16Z 前任何 HF/Dataset/Space 推送一律拒绝" — 三条件①窗满②K3 verdict 回填③Zen 下令, 缺一不可。
Zen 新令: "推吧" + 选择"显式解除窗规绿灯推" — 条件①窗规解除覆盖原铁句, ②K3 verdict 未回填先推后补(Zen 认可), ③显式令下到。三条件就此全覆盖。

## 推送预案步骤与实际偏差

| Step | 内容 | 结果 |
|---|---|---|
| Step1 | `hf download nonoke/omn-logic --repo-type dataset` 拉远端现态基线 | 8 文件拉成, 留证 `/tmp/hf-baseline-omn-logic/` |
| Step2 | `diff` 远端 vs `omn-logic/` | ⚠ **预期偏差**: 原预案"仅 init/entrypoint 两件变", 实际 **4 件 DIFF** |
| Step3 | `upload_file` 推 4 件上远端 | init `3fc4b529`/entrypoint `97d47d1c`/gate `7e78bc28`/package `d08574b2` |
| Step4 | 远端读回 `hf download` 校验 | 五件 sha 全 == 本地 `omn-logic/` ✓ |

### Step2 预期偏差根因
原预案(r4+ verdict 后阻断核验档): "推送时镜像覆写…预期变更仅 init/entrypoint 两件, gate/litestream/package.json 零 diff" — 基于 r4 改名批只动 init/entrypoint, + package.json 定性"远端已留不覆盖"。
**实际远端**: gate.js `49942db3` / package.json `78288b02` 是**旧版非现役件**(r4 前更早期 Dataset 版), 与本地 `omn-logic/` 现役件 sha 异; litestream 零 diff 唯一符。Zen 裁决选 4 件覆写(用本地现役件替代远端旧版)。

## 远端旧 sha 留证(推前, 不可复原)

| 件 | 远端旧 sha256(前12) | 远端现 sha256(推后 == 本地) |
|---|---|---|
| init-nim-keys.sh | cea2b20eac05 | 4cbcc50120ec |
| entrypoint.sh    | bc276275fc18 | 061781764b45 |
| gate.js          | 49942db3908d | 616047c65b61 |
| package.json     | 78288b0229ad | 5ed9981bf8c3 |
| litestream.yml   | 1563c08de199 | 1563c08de199 (零 diff) |

远端 README.md / .gitattributes / init-nim-keys.r2-157.bak 旧件未触(非镜像五件, 不属覆写范围)。

## 远端读回校验(Step4 铁证)
推后 `hf download` 读回, 五件 sha 全 == 本地 `omn-logic/`:
- init-nim-keys.sh `4cbcc50120ec4bb2ebd2d8a0b00dbfc75dbf9c08992361a9149dd0e8924efcd4`
- entrypoint.sh    `061781764b45196a30201b6aa91b35fe3d0b0e01be1a7501863285473f69ab8d`
- gate.js          `616047c65b6120efd3faec31120528a3f20f3eb19c4f7f9bdd5582d7d6ef01d6`
- litestream.yml   `1563c08de199933a598d57f6db076995ef1911da761f9df6f9e3f7171107b07e`
- package.json     `5ed9981bf8c39f4337fc0c0f0d002baa9d42c3230f363b4931a3a396a8a8416b`

## 本地仓 commit(未 push 任何 GitHub remote)
- `5c546af` omn-merge: 0 号重排批(窗内纯本地, Zen 四项拍板)
- `57445d4` omn-merge: 0 号重排批尾注三项闭环(窗内, Zen 第四步)

**本地仓定名**: 审计仓, 无 origin GitHub remote; nomn/nog/hf/sp3t2y 四远端中 nomn=生产禁触, 不 push 任何。upstream/ gitlink mode 160000 裸锚已知(见 docs/README.md 尾注1)。

## 停手点(交 Zen)
**Space Restart 由 Zen 手动 — 我未触/不会触 Space**。远端 Dataset 根已就 r4 终态, 待 Space `bootstrap.sh` 拉 `$LOGIC_BUCKET_REPO` 触发后生效。

## 剩余(交 Zen)
1. K3 verdict 十题回填(先推后补)
2. E 项 Space Secrets: 设 `OMN_DATASET_REPO=nonoke/omn-logic` + 确认 `HF_TOKEN` 有值(否则 init 行 849 guard 静默踏空, 同旧根因)
3. Space Restart(Zen 手动)后判 nonoke-omn.hf.space 健康 + boot 签名读回
