# OmniRoute × NVIDIA NIM 网关 — 文档入口

> 当前版本：**v4.2.3**（基础镜像 `diegosouzapw/omniroute:3.8.43` 钉死）
> 生产：HF Space [`nomke/omn`](https://huggingface.co/spaces/nomke/omn)（`https://nomke-omn.hf.space`）
> 部署链路：本地 → `nomn/main`(GitHub) → Actions `sync-to-hf-space.yml` → `git push --force` 到 HF `nomke/omn` → 重建上线

---

## 活跃文档

| 文档 | 用途 |
|------|------|
| [readme4.2.3.md](readme4.2.3.md) | **快速部署**：核心事实、环境变量、三 combo 分工、客户端接入、运维排查（v4.2.3 收拢版） |
| [DEPLOYMENT_GUIDE.md](DEPLOYMENT_GUIDE.md) | **深度部署**：三段式架构、三大技术坑位（含 v4.2.3 粘名 bug）、完整 env 清单、combo 架构、升级路径 |
| [CHANGELOG.md](CHANGELOG.md) | **变更日志**：v4.1.0 → v4.2.3 全部版本演进 |
| [nim_context_probe.sh](nim_context_probe.sh) | **工具**：NIM 真实上下文截断点实测（直连绕过 gate），用于标定 `real_context` |

## 7 个核心文件（仓库根目录）

`init-nim-keys.sh` · `Dockerfile` · `entrypoint.sh` · `gate.js` · `litestream.yml` · `package.json` · `README.md`
（`.github/workflows/sync-to-hf-space.yml` 白名单同步此 7 个文件到 HF，**其余文件不部署**）

## v4.2.3 核心改动（vs v4.2.2 生产）

1. **`models_to_json` 粘名 bug 修复**：`printf '%s'` → `'%s\n'`。旧版多模型参数粘成单串（如 3 模型 → 一个 `nvidia/a/b/c` 垃圾对象），combo 建成 201 但调用全 400。修复后 nim-pool/nim-codex 多模型 round-robin 复活。
2. **DEBUG log 上传 Dataset（·⑨）**：`NIM_DEBUG_LOG_TO_DATASET`(默认 1) + `NIM_DEBUG_LOG_KEEP`(默认 5)，DEBUG 模式 `init_*.log` 拷为 `debug_*.log` 随 `hf_snapshot` 上传 HF Dataset。

---

## 归档（`archive/`）

旧版本设计稿、历史快照、`nog` 项目（另一远端线 `i3t2y/nog`）文档已归档，仅作历史参考，**不再维护**：

- 旧版本研究：`4.1.0.md`、`n-omn-4.2.md`、`3.8.0.txt`
- 历史快照：`CURRENT_STATE_v3.8.md`、`RELEASE_NOTES_v1.0.0.md`、`VALIDATION.md`、`audit-report.md`、`implementation-log.md`
- nog 项目文档：`CHANGELOG.md`、`AI_HANDOFF.md`、`DECISIONS.md`、`EXPERIENCE.md`、`TROUBLESHOOTING.md`
- 事件复盘：`DEGRADED_POSTMORTEM.md`、`DEGRADED分析.md`、`Deep Research OmniRoute.md`
- 规划稿：`superpowers/plans/`、`superpowers/specs/`
- 旧工具：`check_restricted.sh`

详见 [`archive/`](archive/)。

---

*Base image: OmniRoute 3.8.43 · Init script: v4.2.3 · Updated: 2026-07-10*
