# Stage E · audit/07 — 生产预发实例 Readback

> 生成日期: 2026-07-13
> 部署 commit: 4acb882
> GitHub: github.com/i3t2y/n-omn (main)
> HF Space: huggingface.co/spaces/nomke/omn
> Actions 状态: 已触发 / 待确认（run ID: 无 gh CLI, 需人工确认 https://github.com/i3t2y/n-omn/actions）

## 文件同步确认

| 文件 | 源 | diff 结果 |
|------|----|----------|
| gate.js | candidate-v4.3-reviewed/ | 无差异 |
| entrypoint.sh | candidate-v4.3-reviewed/ | 无差异 |
| init-nim-keys.sh | candidate-v4.3-reviewed/ | 无差异 |

## Dockerfile / README 对齐确认

| 文件 | 状态 | 说明 |
|------|------|------|
| Dockerfile | 未改 (已 pin 3.8.43) | FROM diegosouzapw/omniroute:3.8.43@sha256:517c160643c56ad72e3e305458d961c9a4c87f711393c13020450f9f088d1570 (tag+digest 双锁, 步骤三判断无需改: 镜像名 diego 为生产真实, 改 iego 会拉不存在镜像致 build fail) |
| README.md | frontmatter 已落 (1194f22) | sdk=docker app_port=7860 (EXPOSED_PORT 三处实证: gate.js:29 / Dockerfile ENV / entrypoint:13) |

## P1–P6 Readback（部署后待确认）

| 项 | 检查方式 | 预期 | 实际 | 状态 |
|---|---------|------|------|------|
| P1 R2 旧 generation | litestream generations <url> | 最新 gen 晚于 purge | 待生产确认 | SKIP |
| P2 replicate 隐式 restore | Space 启动日志 restore/replicate 顺序 | restore 先于 purge | 待日志确认 | SKIP |
| P3 flock 路径 | 日志 flock path= | /data 共享卷 | 待日志确认 | SKIP |
| P4 purge 边界 | 日志 pre-purge deleted=N | deleted=N remaining=0 | 待日志确认 | SKIP |
| P5 wal_checkpoint | 日志 busy/log/checkpointed | busy=0 | 待日志确认 | SKIP |
| P6 account.proxy | Space 健康检查响应 | 正常, proxy 为空 | 待 Space Running | SKIP |

（P1–P6 全部 SKIP, 因 HF Space 尚未确认 Running. Space Running 后对照以上检查方式逐项确认更新本表.）

## 人工确认步骤

Space 启动后执行:

1. 查看 HF Space 构建日志:
   https://huggingface.co/spaces/nomke/omn/logs

2. 日志搜索关键词记实际值:
   - "flock path="
   - "pre-purge deleted="
   - "wal_checkpoint"
   - "restore" / "replicate"
   - "FATAL" / "ERROR"（出现即立即处理）

3. Space Running 后健康检查:
   curl -s https://nomke-omn.hf.space/health
   （若端口/路径不同用实际 URL）

4. 实际结果填上方 P1–P6 表, 更新 audit/07 本地 commit.

## Actions 触发链路

push 4acb882 → github.com/i3t2y/n-omn (main)
  → .github/workflows/sync-to-hf-space.yml (触发条件: push main + paths 含 gate.js/entrypoint.sh/init-nim-keys.sh)
  → Actions checkout GitHub repo 根级白名单文件 (Dockerfile/entrypoint.sh/init-nim-keys.sh/litestream.yml/gate.js/package.json/README.md)
  → git push --force hf main → huggingface.co/spaces/nomke/omn
(secret: HF_TOKEN; HF Space build 拉根级 Dockerfile sdk=docker)

人工查 Actions run: https://github.com/i3t2y/n-omn/actions
HF Space URL: https://huggingface.co/spaces/nomke/omn

## 结论

整体部署状态：PARTIAL
说明：代码已 push GitHub (4acb882), sync-to-hf-space Actions 已触发 (paths 命中),
HF Space 构建状态及 P1–P6 readback 待人工确认 (无 gh CLI 故 run ID 未取).
