# 1c 镜像改名候选归档 (2026-07-19)

> K3 收口轮任务 1c: 仅归档镜像改名候选, **本轮不执行** — 禁专为改名触发 factory rebuild。
> 改名搭 3.8.49 升级便车 (该次本就有 factory rebuild, 改名零增量暴露)。

## 背景

关键词暴露面收口 (任务 1a/1b) 已将真正暴露面 (Dataset 源码 + 运行日志) 中性化。
镜像名 (GHCR package 页) 仍持 `omniroute-base` 字样, 是剩余暴露面之一。
但镜像名是 RUNTIME 层 (HF build ARG BASE_IMAGE 引用), 改名须 factory rebuild 整镜像,
违反 "零 rebuild" 收口原则 + 触 HF 7/16 build freeze 风险 (单次密集推 >8 次/h 自动冻)。

## 候选

**目标名**: `ghcr.io/i3t2y/omn-base`

去品牌前缀 `omniroute` → `omn`, 与已稳立的 bucket `omn-data` 同前缀, 命名一致。

## 便车时机

下次 3.8.49 (或更高) 上游升级时:
1. 该次本就须 factory rebuild 镜像 (装新版本依赖) — 改名零增量 rebuild 成本
2. 同 commit 改 GHCR package name + Space `BASE_IMAGE` ARG + bootstrap 自愈前置探测
3. 单次 factory rebuild 触发回避 HF 冻限 (单 commit 推 + 单次 rebuild, 远低于 8 次/h 线)

## 改名须同步改三处 (便车批次)

| 点位 | 当前值 | 目标值 | 类型 |
|------|--------|--------|------|
| GHCR package name | `ghcr.io/i3t2y/omniroute-base` | `ghcr.io/i3t2y/omn-base` | 包注册名 |
| Space Settings → Variables `BASE_IMAGE` | `ghcr.io/i3t2y/omniroute-base:stable` | `ghcr.io/i3t2y/omn-base:stable` | build ARG |
| bootstrap.sh 自愈前置 (如有硬编码 fallback) | 探测 `omniroute-base` | 同改 `omn-base` | 容错逻辑 |

**注**: bootstrap.sh 若纯读 `BASE_IMAGE` ARG 无硬编码 fallback, 仅改 Space Variable 即可, bootstrap 不动。
须在便车前 Read 确认 bootstrap 是否有品牌字硬编码。

## 不做项 (本轮 + 便车前)

- ✗ 不单为镜像改名触发 factory rebuild
- ✗ 不改 GHCR 包名致旧 `:stable` tag 失链 (新包须重新 push + Space 重拉, 旧包可保留作回滚)

## 风险面 (便车时须评估)

1. **回滚链**: 旧 `omniroute-base:stable` tag 若删, 回滚 3.8.49 失败须重推旧包 → 保留旧包至少到新包验稳。
2. **HF 拉取**: HF build 拉新包须 GH_TOKEN 有 `read:packages` scope (现有 classic PAT 已含, 无须改)。
3. **bootstrap 探测**: 若 bootstrap 探 BASE_IMAGE 失败回退硬编码, 须同改硬编码值, 否则 A 模式补齐逻辑误触。

---

*2026-07-19 归档 · 本轮不执行 · 待 3.8.49 升级便车批次*
