## 背景

同 `fix-omn-deploy-bucket`：`logic/` 共 **8 件业务文件**，部署清单漏了第 8 件 `policy-guard.js`，
致 `gate.js:22` 顶层 `require('./policy-guard.js')` 在 `/logic` 找不到件 → gate 崩 →
`entrypoint` STRICT 全停 → HF 重启循环。

本 PR 修 **boot 侧**清单（上传侧清单见 `fix-omn-deploy-bucket`）。

## 本 PR 改动

- `space/start.sh` 的 boot 拉取清单补 `policy-guard.js`（8 → 9 项）
- 把上方「boot 先拉 manifest + 8 件」注释对齐为「9 件」

## 验证

- 清单与 `logic/` 实际文件集逐项对齐
- `sh -n` 通过
- 两个内嵌 `python -c` 块语法通过

## 合并顺序 ⚠️ 必须先合 fix-omn-deploy-bucket

本件合并会触发 `sync-space-xnexus` → 推 Space 骨架 → **HF 自动 Rebuild** → 容器重启。

若桶内 `manifest.json` 尚未包含 `policy-guard.js`，新 boot 会报
`[start] FATAL: manifest 缺 policy-guard.js` 并退出
（下个 boot 自愈，但会多几次失败）。

**因此：先合 `fix-omn-deploy-bucket`，等其 Actions 变绿、桶内 manifest 更新后，再合本件。**

合并生效后，Space 会重启一次；若 HF 未自动拉起，手动 Restart 一次即可。
