## 背景

`n-omn` 自 2026-09-10 起处于 HF 重启循环（容器 ~17s 一轮），根因是**部署清单漏件**。

`logic/` 实际含 **8 件业务文件**：

```
entrypoint.sh  gate.js  helper.sh  init-nim-keys.sh
omn_redact.py  omn_scheduler.py  package.json  policy-guard.js
```

而三处硬编码部署清单都只列了 **7 件 + flaretunnel = 8 项**，同漏 `policy-guard.js`：

| 位置 | 行 | 作用 |
|---|---|---|
| `.github/workflows/sync-logic-xnexus.yml` | 58–59 | CI 上传 |
| `.github/workflows/sync-logic-xnexus.yml` | 104–105 | CI 回读校验 |
| `space/start.sh` | 60–61 | boot 拉取（另单修改，见 `fix-omn-deploy-boot`） |

`gate.js:22` 顶层 `require('./policy-guard.js')` → 桶内缺件 → gate 启动即崩 →
`entrypoint` 视 gate 死为致命（STRICT）→ 全停 → HF 拉起 → 循环。

## 为什么 CI 一直绿

上传与校验用的是**同一份清单**，只验证「清单里的文件都对」，从不检查「清单本身全不全」。
清单漏件时校验范围同漏 → 自我确认偏误 → 永远绿。

## 本 PR 改动

`sync-logic-xnexus.yml` 两处清单 **8 → 9 项**（补 `policy-guard.js`），并把步骤名与注释的件数口径对齐。

> 注：`space/start.sh:52` 的注释本来就写着「拉 manifest + 9 件（8 业务 + flaretunnel）」——**注释是对的、代码漏了**。

## 验证

- 清单与 `logic/` 实际文件集**逐项对齐**（8 件 + flaretunnel）
- workflow YAML 可解析
- 内嵌 python 块语法通过

## 合并顺序 ⚠️

**先合本件**（只推 Bucket，低风险，不触 Rebuild）；
确认 `sync-logic-xnexus` Actions 变绿后，再合 `fix-omn-deploy-boot`（改 `space/start.sh`，会触 HF 自动 Rebuild）。

顺序反了的话，boot 会因 `[start] FATAL: manifest 缺 policy-guard.js` 再报一轮
（下个 boot 自愈，但会多几次失败）。
