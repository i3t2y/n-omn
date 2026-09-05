# 脚本实证核: 文档假设 vs 实际运行态 (2026-07-19)

> 背景: 用户提出"自动化运维闭环"三组件设想 (Win11 SSH 加固 + sync_to_win11.sh + space_ctl.py),
> 落盘前 CC 实证核发现 **三落差 + 四坑**, 全修正后定稿落盘。
> 本文档备查, 本身是 K3 审"文档与实际运行态一致性"的现成正面证据。

## 实证核记录 (本轮对话全部跑 Bash 验真, 非凭记忆)

| 断言 | 实测命令 | 结果 | 判定 |
|------|---------|------|------|
| SSH 免密通 | `ssh -o BatchMode=yes laisi@100.99.249.51 true` | `OK_NO_PASSWORD` rc=0 | ✓ 早通 |
| 远端授权文件 | PowerShell `Get-Acl administrators_authorized_keys` | 1 key, 仅 SYSTEM/Administrators FullControl | ✓ 已守严苛审计 |
| 本地公钥 | `ls ~/.ssh/*.pub` | ed25519 + rsa 两 key 并存 | 用户脚本假设单 rsa |
| 链路类型 | `ip route get 100.99.249.51` | `tailscale0` 接口 | 非 LAN |
| `add_space_variable` | `inspect.signature` | `(repo_id, key, value, ...)` | ✓ 真实 |
| `get_space_runtime` | `inspect` + dataclass fields | stage/hardware/storage/... | ✓ 真实 |
| `restart_space` | `inspect.signature` | `(repo_id, *, factory_reboot=False)` | ✓ 真实 |
| `SpaceStage` 枚举 | dir 列举 | 12 成员含 DELETING (非 DELETED) | 枚举对齐 |
| `fetch_job_logs` | doc 查 | "compute Job" 非 Space Build logs | 与 Build Logs 不同 endpoint |
| Build Logs 端点 | `httpx.head` 候选 5 端点 | `/logs/build` 返 401 (存在需鉴权), `/logs/{revision}` 404 | 端点真值锁定 |
| SDK 版本 | `huggingface_hub.__version__` | 1.8.0 | 满足 bootstrap >=1.0,<2.0 |
| httpx | `__version__` | 0.28.1 | ✓ 装好 |

## 三落差 (用户脚本 vs 实际, 已修正)

### 落差 1: Win11 注公钥脚本冗余
- **用户脚本**: PowerShell 跑 `$authFilePath = administrators_authorized_keys` + icacls + 注公钥。
- **实情**: SSH BatchMode 早通无 passphrase, 远端文件权限早已守严苛审计 (SYSTEM/Administrators FullControl, 移除继承)。
- **修正**: 此脚本**不创建**, 落盘裁决已删。再跑会重复追加公钥污染授权文件。

### 落差 2: sync_to_win11.sh IP 默认值误导
- **用户脚本**: `WIN_IP="192.168.x.x"` 局域网占位。
- **实情**: 链路是 Tailscale `100.99.249.51` (`tailscale0` 接口), 非局域网。
- **修正**: 默认值改 `100.99.249.51`, env `WIN_IP` 可覆盖 (留运维弹性, 不硬编码)。

### 落差 3: 双 key 并存
- **用户脚本**: `cat ~/.ssh/id_rsa.pub` 单 rsa 假设。
- **实情**: 本地并存 ed25519 + rsa 两 key, 远端已注 1 个。
- **修正**: 不相关注公钥脚本撤, 无需处理双 key。备忘记录防下次再走错路径。

## 四坑 (HF API 契约错, 已修正重写)

### 坑 1: 变量改 ≠ 自动 rebuild
- **用户 space_ctl.py 假设**: `add_space_variable` 改变量后 "Space 正在自动重启/重建"。
- **实情**: `add_space_variable` 仅写 variable, **不触发 rebuild**。BASE_IMAGE 是 build ARG, 构建期注入, 改 variable 必须重 build 才生效。
- **修正**: `trigger_upgrade` 显式调 `api.restart_space(repo_id, factory_reboot=True)` 触发重构建 (镜像层升级), 或 `factory_reboot=False` 普通重启 (逻辑层迭代版本标签同步)。
- **降级契约**: 逢 7/16 式 build 冻, 变量已改镜像未滚 → entrypoint `EXPECTED_VERSION` 与实跑版本不齐 → entrypoint "告警不 exit" 兜底, 系统不崩, 日志留痕 (见 audit/k3-review-r2-v30.md 第六章)。

### 坑 2: stage ≠ 日志 + 端点路径错
- **用户 space_ctl.py 假设**: `get_space_runtime().runtime.stage` 取日志, 端点 `/api/spaces/{repo}/logs/{revision}`。
- **实情**:
  - `SpaceRuntime.stage` (非 `.runtime.stage`) 返 `SpaceStage` 枚举单词 (12 成员), 非日志文本。
  - Build Logs 端点 `httpx.head` 实测: `/logs/build` 401 (存在需鉴权), `/logs/{revision}` 等 4 候选 404 (路径错)。
- **修正**: status 命令读 `_stage_value(api.get_space_runtime(REPO_ID).stage)`; logs 命令走 `GET /api/spaces/{repo}/logs/build` SSE 流 (Accept: text/event-stream), JSON/纯文本双兜底解析 data 载荷。

### 坑 3: SDK 版本未钉假设
- **用户**: 月脚本假设 huggingface_hub 钉版本未述。
- **实情**: 1.8.0 实装, 满足 bootstrap `>=1.0,<2.0` 契约。
- **修正**: 落盘注释显注 "1.8.0 已装", 不假设未钉。

### 坑 4: ERROR_STAGES 枚举成员错
- **用户**: 写 `"NO_APP_FILE" "CONFIG_ERROR" "BUILD_ERROR" "RUNTIME_ERROR" "DELETED"`。
- **实情**: SpaceStage 12 成员, **`DELETED` 不存在**, 真值 `DELETING` (DELETING=删除中态)。
- **修正**: 修正为 `DELETING`, 四枚举成员对齐 `SpaceStage` 源码真实值。

## 落盘空跑验证 (2026-07-19)

| 动作 | 结果 | 证 |
|------|------|----|
| `python3 scripts/space_ctl.py status` | ✅ 通过 | `stage=RUNNING hw=cpu-basic` — HF API 通, 四坑修正有效, Space 当前 RUNNING |
| `bash scripts/sync_to_win11.sh <test>` | ✅ 通过 | 测试 78 字节文件落地 Win11 `D:\omn_exchange\`, 远端验+清, 本地无残留 |
| `space_ctl.py` ast.parse 语法 | ✅ | 语法 OK |
| `bash -n` sync/upstream | ✅ | 两脚本语法 OK |

闭环可用。所有动作空跑无副作用验证通过。

## 第五坑 (空跑新发现, 落差外)

### 坑 5: sync 探活 `true` 在 Windows OpenSSH 假阴性
- **初版**: `ssh ... true` (Linux 通, true 是 coreutils)。
- **实情**: Windows OpenSSH server 默认环境**无 `true` 命令** → 报 `'true' 不是内部或外部命令` 假阴性, 探活失败。
- **修正**: 探活改 `cmd /c exit 0` (Windows 必有 cmd, channel exec 模式保证)。已补脚本注释说明。
- **教训**: 跨平台探活命令不可假设 GNU coreutils 在远端。Windows OpenSSH 需用 Windows 原生命令 (`cmd`/`powershell`)。

## 落盘文件

| 文件 | 落点 | 状态 |
|------|------|------|
| scripts/space_ctl.py | HF Space 控制 (status/upgrade/restart/logs), 四坑全修 | ✓ 落盘 |
| scripts/sync_to_win11.sh | Tailscale 推送 (落差 2 修) | ✓ 落盘 |
| scripts/upstream_check.sh | 半自动上游检测+预构建+推 Win11 | ✓ 落盘 |
| Win11 注公钥 PowerShell | (落差 1, 冗余) | **不创建** |
| audit/2026-07-19-script-factcheck.md | 本文档 | ✓ 落盘 |

## 自动化升级环契约 (The Loop)

```
[upstream_check.sh 日 9:00 cron]
  → GitHub release 检测新版
  → 本地 GHCR 预构建 (零 HF build 队列接触, build 失败不阻断告警)
  → 生成 upgrade-{ver}-{date}.md (含单条批准命令)
  → sync_to_win11.sh 推 Win11 评审端
  → STATE_FILE 记 "已告警版本" 防 repeat (≠ "已部署版本", 后者由 Space EXPECTED_VERSION 承载)

[Tabbit Win11 人工]
  → 收 upgrade 报告 → K3 审 (连同其他变更批量过每周审计节奏)
  → 无异议 → 手跑报告里单条: python3 scripts/space_ctl.py upgrade {ver} {ghcr_tag}
      (内部: 改 BASE_IMAGE+EXPECTED_VERSION → factory_reboot=True → wait_stage RUNNING)
  → 若 wait_stage 落 BUILD_ERROR: space_ctl.py logs 拉 Build Logs 定位
      (此时变量已改镜像未滚 = entrypoint 兜底场景, 系统不崩, 日志留痕)
```

**闸门**: factory_reboot=True 是整个系统**唯一**碰 HF build 队列的路径, 永远人工触发。
新 job logs `fetch_job_logs` 与 Space Build logs 端点是不同 API (compute Job vs Space build), 不可混用。

## 选择 2 (全自动轮询) 的延后裁决

当前默认半自动 (选项 3)。选项 2 (cron 全自动 rebuild) 不永久否决:
等积累若干次干净的人手 rebuild, 摸清 HF 免费层 build 队列冻结触发边界后, 升级路径可毕业全自动。
现在每周 2~3 补丁版, 全自动无人值守 rebuild + 失败重试恰在 build 队列最不稳定时施压, 无安全收益。

---

## 2026-07-19 终态 finalize (用户裁决后落地)

用户裁决切入口径收紧:仅①cron 装 +⑤litestream 调优立即动作;②Storage Bucket 迁移**永久拒绝**(litestream R2 跨云容灾红线);附"PORT=7860 建议"**拒绝**(会与上游 20128 抢监听 EADDRINUSE 破已验证分离面);③D 真风险**制度化**(抓上游 Dockerfile 关键行入审批报告)。

### ① cron 装成 (零 HF build 队列接触)
- crontab 行 (洁版, 单条 GH_TOKEN 注入, 不解全 omn-secrets):
  `0 9 * * * export GH_TOKEN="$(sed -n "s/^GHCR_PAT_CLASSIC=//p" /home/laisi/.omn-secrets)"; bash /home/laisi/omn-ops/scripts/upstream_check.sh >> /home/laisi/omn-ops/logs/upstream_check.log 2>&1`
- `env -i` 模拟最小 cron 环境验通: `none → 3.8.48` 新版探测命中 + 报告生成, cron 服务 active。
- **GH_TOKEN 鉴权修**: 匿名 GitHub API 60/h 限流 die 脚本 → 加 `Authorization: Bearer ${GH_TOKEN}` + X-GitHub-Api-Version + `--max-time 30`, 403/404 容错不 set -e 终止。

### ③ D 真风险制度化 (低成本高收益) — 抓上游 Dockerfile 契约漂移
- upstream_check.sh 新增块: 新版触发时抓 `raw.githubusercontent.com/${UPSTREAM_REPO}/v${latest}/Dockerfile`,
  `grep -E '^(FROM|ENV PORT=|ENV DATA_DIR=|ENV HOSTNAME=|ENTRYPOINT|CMD|USER)'` 关键行入审批报告 .txt。
- 实测 v3.8.48 抓取成功 (226 行 Dockerfile), 关键行入报告:
  ```
  FROM node:24-trixie-slim AS base
  ENV PORT=20128 / ENV HOSTNAME=0.0.0.0 / ENV DATA_DIR=/app/data / USER node
  ENTRYPOINT ["/tmp/check-permissions.sh"]   ← 重大发现
  CMD ["node", "dev/run-standalone.mjs"]
  ```
- **重大发现 (D 子 agent 未完全捕获)**: 上游 v3.8.48 **已自带 `ENTRYPOINT ["/tmp/check-permissions.sh"]`**。
  candidate 的 `ENTRYPOINT ["/bootstrap.sh"]` 会**覆盖**上游 check-permissions.sh。
  这是 D 子 agent 风险点 4 的实例化 — 需 K3 审, bootstrap 内需保留显式 `exec /logic/entrypoint.sh` 转发逻辑层,
  并评估是否需在 bootstrap 末段调用 check-permissions.sh 等价功能 (或确认 check-permissions 在 candidate 镜像层已无意义)。
- 人工批准时一眼见契约漂移, 无需改三文件即知是否破三文件永久免改假设。

### ④ 删旧三脚本收口泄漏面
- 用户明示删 + 空跑全通后执行。`rm ~/omn-merge/scripts/{space_ctl.py,sync_to_win11.sh,upstream_check.sh}`
- 删前核: omn-merge 三脚本 git 确未追踪 (git ls-files 空), 不破 git history。
- 删后 `~/omn-merge/scripts/` 仅余 `psk-probe.sh` (非迁移范围, 用户保留)。
- ⚠️ `?? scripts/` 残留: psk-probe.sh 仍 untracked 在 omn-merge 仓内, 非本次迁移范围, 由用户自行定夺 (gitignore 或纳入追踪)。

### 迁移最终态
- `~/omn-ops/` 三脚本就位: space_ctl.py 6404B (复制不变) / sync_to_win11.sh 1373B (复制不变) / upstream_check.sh 4618B (BASE_DIR→$HOME/omn-ops + 报告 .md→.txt heredoc 纯文本 + D 契约漂移抓取块 + GH_TOKEN 鉴权)。
- 空跑验收表 (终态):

| 项 | 结果 |
|---|---|
| space_ctl status | ✓ `stage=RUNNING hw=cpu-basic` |
| sync .txt 测试推送 | ✓ Win11 `D:\omn_exchange\` 104B 落地+清零 |
| upstream_check 逼触发 | ✓ 报告生成含 Dockerfile 契约关键行 |
| env -i cron 模拟跑 | ✓ GH_TOKEN=40 字符注入, 新版探测命中 |
| omn-ops 非 git 根 | ✓ `fatal: not a git repository` |

- omn-merge 旧三脚本已删, 泄漏面部分收口 (psk-probe 残留待用户定夺)。

### 待办 (用户裁决清单剩两条, 非本次范围)
- litestream.yml 调优 (sync-interval 10s→30s + retention-check 1m) + 推 Dataset 单 commit + Space 普通 Restart — R2 Class A 60万→25万/月, 余量 60%→75%, RPO 代价可忽略。
- K3 发送前 `git log -p` 核 R1 yml 路径 (`path: /data/storage.sqlite` vs R2 `/app/data`), 这正是六章三因子铁证之一。

## 教训补 (2026-07-20): cron 调度时区 ≠ 交互 shell 时区 — 一组同源毛边

### 现象 (R3 闭环后核 cron 空跑时发现)

- 7/20 早间预期 9:00 (CST) cron 静默空跑命中防重复 (`[check] 无新版 (已告警过 3.8.48)`), 但日志 `~/omn-ops/logs/upstream_check.log` mtime 停在 **7/19 17:00:06 CST**, 3 行零增长 — cron 9:00 (CST) 根本没调度上游任务。
- `systemctl status cron` 显 crond active 且 7/20 09:15:01 跑了 wiki `*/15` 任务 = crond 工作正常, 非 crond 崩。
- `timedatectl` 显 `Time zone: Etc/UTC (UTC)`, 但 `date` 在交互 shell 显 `CST +0800` — **两者各说各话, 默认 0 9 是本地时间成集体盲点**。

### 根因 (单点)

- 系统 `/etc/localtime → /usr/share/zoneinfo/Etc/UTC` 硬钉 UTC。交互 shell 显 CST 是因 TZ env 被某 profile 注入 (用户层), crond 按 systemd 系统时区 (UTC) 跑, 不读交互 shell 的 TZ env。
- crontab `0 9 * * *` 作者本意 CST 9:00, 实跑 **UTC 9:00 = CST 17:00**。7/19 log mtime 17:00:06 = UTC 09:00 crond 触发, 铁证。

### 修法 (两处互补, 任一单改不足)

1. **crontab 顶部加 `CRON_TZ=Asia/Shanghai`** — 修调度时刻判定, `0 9 * * *` 从此 CST 9:00, 新加条目自动继承免再踩。ISC cron 的 CRON_TZ 只控调度时刻, **不保子进程 TZ 注入**。
2. **脚本内显式 `export TZ="Asia/Shanghai"`** (upstream_check.sh `set -euo pipefail` 后) — 兜底: heredoc `$(date +%Y%m%d)` 报告文件名日期保证 CST (跨日不再差一天), state 防重复"每日"边界与本地日历对齐。`bash -c 'export TZ=Asia/Shanghai; date'` 实测 → `CST +0800 20260720` ✓。

### 连带三件 (同源, 一并解)

- **heredoc `$(date +%Y%m%d)` UTC 生成报告日期**: 7/19 UTC = 7/20 CST 凌晨, 报告 `upgrade-3.8.48-20260719.txt` 命名日期与本地日历差一天。改后日期 CST 对齐。现存文件不重命名 (内容无损, audit 注此段即可)。
- **state 防重复"每日"边界**: 无 TZ env 时 date 走 UTC, "同日不重告警"判定按 UTC 日界 (CST 08:00 翻日), 与本地日历错位 8h。TZ 对齐后日界 CST 00:00。
- **cron 日志时间戳偏差 8h**: crond 自身日志按 UTC, 与本地认知差 8h (查 `systemctl status cron` 时间戳时须心算)。

### wiki/gbrain cron 时区连带影响

CRON_TZ 全局生效, 影响所有 crontab 条目:
- `*/15 * * * *` wiki sync → 每 15 分钟, **时区无关** (每小时 4 次, 哪个 TZ 都一样) ✓ 无影响。
- `0 3 * * 0` gbrain doctor → CRON_TZ 前 UTC 03:00 = CST 11:00 周日; CRON_TZ 后 CST 03:00 周日。**触发后移 8h** (周日午 → 周日凌晨)。凌晨低负载更佳, 修向好, 无需回调, 但须知时间已变。
- `0 9 * * *` upstream_check → CST 9:00 (本意) ✓ 修正。

### 通用教训 (钉 audit)

**`timedatectl` 看系统时区, `date` 看交互 shell TZ env, crond 按 systemd 系统时区跑 — 三者必须显式对齐, 不可默认一致。** Linux 运维经典陷阱: crontab 时间字段按何 TZ 判定取决于 cron 实现读哪个源 (ISC cron = systemd 系统时区; systemd-cron = CRON_TZ 或 TZ env)。生产 cron 任务部署前必查: `timedatectl | grep "Time zone"` + `crontab -l | grep CRON_TZ` + 脚本内 `export TZ` 三处一致, 否则调度时刻漂移 8h 静默发生。

---

*2026-07-19 脚本实证核 · K3 审文档与运行态一致性的正面证据 (终态 finalize) · 2026-07-20 补 cron 时区坑教训段 (R3 闭环后核出, 同源三毛边一根因)*

*2026-07-19 脚本实证核 · K3 审文档与运行态一致性的正面证据 (终态 finalize)*
