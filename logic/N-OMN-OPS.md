# n-omn 运维（2026-10-18 收口）

## 开机 502 → 503 诚实等待

**根因**：`entrypoint` 后台跑 `init-nim-keys.sh`，同时打开 gate。目录未登记完时 `/v1` 打到空 catalog → 上游 502，还烧 fallback 账。

**做法**（本仓已落地，Restart 即效）：

1. `helper.sh` 在 `node gate.js` **之前**调用 `patch_init_hold.py`，把 middleware 写进 `gate.js`（幂等）。
2. 若 init 进程仍在，写 `$DATA_DIR/.init-running`（并镜像 `/data/.init-running`）。
3. gate 的 `init_hold`：有 running 锁 → `/v1` 回 **503** + `Retry-After: 5`；有 fail 锁 → 503 `init_failed`。
4. **`/healthz` 不拦**（cron-job.org 保活继续 200）。
5. init 退出后 helper 子进程清锁；无 `.init-done` 则打 fail 锁。

强制放行（排障）：`GATE_INIT_HOLD=0`。

## 加 key / 模型 / 绑 FT（不重启）

```bash
export INITIAL_PASSWORD='...'
export AMD_KEYS=$'key1\nkey2'
# 编辑 /logic/hot-apply.example.json 后：
python3 /logic/hot_apply.py --spec /logic/hot-apply.example.json
```

- 按 **name** 去重，不重跑整份 init。
- 登录 cookie 落 `/tmp/omn-cookie.txt`（与 init 同路径）。
- 自动绑已有 `flaretunnel-*` 代理（provider scope）。
- **不写 sqlite**。

## 部署

逻辑真源在 Bucket `/logic`。把本仓 `logic/` 同步进 Bucket 后 **Restart Space** 一次。

不必改 Dockerfile / start 镜像。

## 验证

```bash
cd /logic && node tests/init_hold.test.js
# 冷启后：init 期间 curl /v1/... 应 503；/healthz 应 200
# init 日志出现 Done 后 /v1 恢复
```
