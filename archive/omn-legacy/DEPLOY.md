# n-vless 自动部署文档（AI 可接手版）

> **文档定位**：本文档是项目的唯一权威参考。任何 AI 接手本项目时，
> 无需其他上下文，仅凭本文档即可理解架构、定位问题、提供修复建议。
> 最后更新：2026-06-23

---

## 一、项目概述

本项目基于 `yonggekkk/Cloudflare-vless-trojan`，通过 **GitHub Actions +
Cloudflare Workers** 实现最多 10 个 CF 账号的自动化 VLESS 代理部署与维护。

**核心目标**：以最少的人工干预，保持 N 个 CF Worker 持续存活、配置正确。

**文件结构**：
```
.github/
 ├─ workflows/
 │   └─ sync-deploy.yml     # 唯一的主部署脚本
 └─ DEPLOY.md               # 本文件（上游 sync 不会覆盖，不要放 README.md）
Vless_workers_pages/
 └─ nat64套壳版明文.js       # 上游 Worker 源文件，脚本会在此基础上 patch
```

---

## 二、流水线架构

```
触发（cron / workflow_dispatch）
        │
        ▼
    ┌─ gate ─────────────────────────────────────────┐
    │  1. 解析 PRESET（三层优先级 + :- 默认值）         │
    │  2. 定时触发门控（CRON_ENABLE=0 时拦截）          │
    │  3. 输出 matrix / gen_names / proceed 等        │
    │  4. SOLO_INDEX 范围校验（1~10）                  │
    └────────────────────────────────────────────────┘
        │
        ├──► gen-names（仅 gen_names==1 时）
        │     生成随机 Worker 名 → 写入 WORKER_NAMES Variable
        │
        └──► sync（gen_names!=1 && proceed==true && sync_code==1）
              │  git merge 上游代码（SYNC_CODE=0 时整个 job 不启动）
              │
              ▼
            deploy × N（always() 解耦，sync 失败不阻断部署）
              │  Extract Credentials（含空值校验）
              │  → Delete（需 delete_mode 门控）
              │  → Patch JS → Deploy(1st pass)
              │  → [PASS_MODE=2: wait 30s + Delete Flagged + Deploy(2nd pass)]
              │  → Wait 15s → Set Secrets（jq 构造 + success 校验）
              │  → Verify（3次重试 + 主动关闭 subdomain）
```

### **关键设计决策**

**sync 与 deploy 解耦**：deploy 使用 `always()` + `needs.gate.result == 'success'`
+ `needs.gate.outputs.proceed == 'true'` 三重门控，同时将 sync 的 `success` /
`skipped` / `failure` 三种结果全部纳入条件。sync 失败（如上游冲突）不会级联
杀死所有 deploy 实例，部署使用仓库现有代码继续进行。

**sync job 条件前置**：sync job 的 `if` 条件包含 `sync_code == '1'`，
SYNC_CODE=0 时整个 job 不启动，不消耗 runner 时间（约节省 30~45 秒）。

**10007 伪错误绕过**：Deploy 步骤开启 `continue-on-error: true` 忽略 10007，
由 Verify 步骤通过 CF API 真正确认 Worker 是否存在。不存在则报错，存在则主动
POST 关闭 workers.dev subdomain（避免写 `workers_dev = false` 触发 10007）。

**PRESET 三层优先级**：`workflow_dispatch` 输入 → Variables 中的 PRESET →
各细粒度变量。bash 使用 `:-` 语法实现，有上层值时用上层值，否则降级。

**concurrency 并发锁**：防止手动触发与定时触发同时运行导致 Worker 互删。
`cancel-in-progress: false` 表示排队等待而非取消，保护正在进行的部署。

**matrix 显式 fromJson**：`matrix: ${{ fromJson(needs.gate.outputs.matrix) }}`，
显式解析 JSON，防止旧版 runner 的解析歧义。

---

## 三、GitHub Secrets（必须配置）

路径：`Settings → Secrets and variables → Actions → Secrets`

| 名称 | 说明 |
|---|---|
| `CF_ACCOUNT_IDS` | 多个 Cloudflare Account ID，英文逗号分隔，位置 1~10 |
| `CF_TOKENS` | 对应账号的 API Token，顺序与 Account ID 严格一一对应 |
| `VLESS_UUID` | 自定义 UUID，所有账号共用同一个 |
| `MY_WS_PATH` | WebSocket 路径，不含 `/`，建议 8 位以上随机字符如 `a7f3k9mx` |
| `GH_PAT` | Fine-grained PAT，用于 sync checkout 和 gen-names 写 Variables |
| CF_PROXYIP | 美西 VPS 公网 IP（可选，格式 1.2.3.4 或 1.2.3.4:端口）。1~6 号账号（非 nat64）设置后出口 IP 可控；留空则自动 fallback 到 _worker.js 内置 proxyIPs 列表；7~10 号账号（nat64）自动跳过，不读取此值 |

**GH_PAT 权限要求（两项缺一不可）**：
- Repository access：Only select repositories → 本仓库
- Permissions → **Contents：Read and write**（sync job checkout 推送需要）
- Permissions → **Variables：Read and write**（gen-names 写 WORKER_NAMES 需要）

> ⚠️ 只配置 Variables 权限而缺少 Contents 权限，sync job 会报
> `Write access to repository not granted` 403 错误。

---

## 四、GitHub Variables（行为控制）

路径：`Settings → Secrets and variables → Actions → Variables`

### **4.1 PRESET — 推荐的日常控制方式**

`PRESET` 是整个配置体系的入口。把它设为对应的预设词，脚本自动推导出所有
细粒度变量，无需逐一修改。PRESET 非空时，脚本会显式设置所有行为参数
（GEN_NAMES / DEPLOY_SCOPE / PASS_MODE / DELETE_MODE / SECRETS_ONLY），
不受 Variables 残留值影响；SYNC_CODE / SUB_MODE / FAKE_PAGE / FAKE_URL
属于用户偏好，PRESET 不会覆盖。

| PRESET 值 | 适用场景 | 内部等效设置 |
|---|---|---|
| `gen` | **生成随机 Worker 名** | GEN_NAMES=1，不启动 deploy |
| `first` | **首次全量部署** | GEN_NAMES=0; DEPLOY_SCOPE=2; PASS_MODE=2; DELETE_MODE=0; SECRETS_ONLY=0 |
| `daily` | **日常维护（推荐常驻）** | GEN_NAMES=0; DEPLOY_SCOPE=2; PASS_MODE=1; DELETE_MODE=0; SECRETS_ONLY=0 |
| `solo:N` | **单账号维护** | GEN_NAMES=0; DEPLOY_SCOPE=1; SOLO_INDEX=N; DELETE_MODE=0; SECRETS_ONLY=0 |
| `secrets` | **仅更新密钥** | GEN_NAMES=0; SECRETS_ONLY=1; DEPLOY_SCOPE=2; DELETE_MODE=0 |
| `delete:1` | **删除指定 Worker 后重建** | GEN_NAMES=0; DELETE_MODE=1; SECRETS_ONLY=0; DEPLOY_SCOPE=2 |
| `delete:all` | **清空账号所有 Worker 后重建** | GEN_NAMES=0; DELETE_MODE=2; SECRETS_ONLY=0; DEPLOY_SCOPE=2 |

**三层优先级（高到低）**：
1. `workflow_dispatch` 界面手动输入的 preset（一次性，不改变 Variables）
2. Variables 中保存的 `PRESET`（持久默认值）
3. 各细粒度变量（PRESET 为空时，通过 `:-` 语法读取这些 Variables，未配置则用内置默认值）

**推荐配置**：将 `PRESET` 的 Variables 值设为 `daily`，`CRON_ENABLE` 设为 `1`，
其余细粒度变量保留作备用。临时操作（如首次部署、单账号维护）在 Actions 启动界面
输入 preset，不影响 Variables 的持久配置。

### **4.2 细粒度变量（PRESET 为空时直接生效）**

> 初始化块使用 bash `:-` 语法：env 中有值（来自 Variables）则优先使用 env 值，
> 未配置时才使用代码中的内置默认值。因此这些 Variables 的设置**始终有效**，
> 不会被脚本内部逻辑覆盖。

| 变量 | 建议值 | 合法值 | 内置默认值 | 说明 |
|---|---|---|---|---|
| `PRESET` | `daily` | 见上表 | 空 | 场景预设，留空则读细粒度变量 |
| `CRON_ENABLE` | `1` | `0` / `1` | `1` | `0` = 屏蔽定时触发，测试期间可设为 0 |
| `GEN_NAMES` | `0` | `0` / `1` | `0` | `1` = 只生成 Worker 名，不部署 |
| `WORKER_COUNT` | `10` | 数字 | `10` | 生成几个 Worker 名 |
| `WORKER_NAMES` | 自动写入 | 逗号分隔 | — | 由 gen-names job 写入，勿手动改 |
| `DEPLOY_SCOPE` | `2` | `1` / `2` | `2` | `1` = 单账号；`2` = 全部账号 |
| `SOLO_INDEX` | `1` | `1`~`10` | `1` | 单账号模式下的账号位置 |
| `PASS_MODE` | `1` | `1` / `2` | `1` | `2` = 首次双部署绕扫描；`1` = 日常单部署 |
| `DELETE_MODE` | `0` | `0` / `1` / `2` | `0` | `0` = 不删除；`1` = 删指定；`2` = 删全部 |
| `SECRETS_ONLY` | `0` | `0` / `1` | `0` | `1` = 只更新密钥，跳过部署 |
| `SUB_MODE` | `1` | `1` / `2` | `1` | `1` = 数字域名；`2` = 命名域名 |
| `SYNC_CODE` | `0` 或 `1` | `0` / `1` | `0` | `1` = 同步上游代码；`0` = 跳过 sync job |
| `FAKE_PAGE` | `0` | `0` / `1` / `2` | `0` | `0` = 关；`1` = nginx 404；`2` = 301 跳转 |
| `FAKE_URL` | — | URL | 空 | `FAKE_PAGE=2` 时的跳转目标 |

### **4.3 DELETE_MODE 的正确使用**

`DELETE_MODE` **不应作为常驻默认值设为 1 或 2**。日常部署（PRESET=daily）
不需要先删除 Worker，直接部署会覆盖更新。Delete Worker(s) 步骤有
`delete_mode` 门控，DELETE_MODE=0 时该步骤不运行。

`delete:1` 和 `delete:all` 的实际效果：
- `delete:1`：删除各账号中 WORKER_NAMES 对应的 Worker，然后用当前代码重建
- `delete:all`：删除账号下**所有** Worker，然后只重建 WORKER_NAMES 中的 Worker
  （相当于清空账号，只保留自己的 Worker）

这两个操作完成后，建议立即将 PRESET 改回 `daily`，避免下次定时触发时重复删除。

---

## 五、各场景详细流程说明

### **5.1 PRESET=gen（生成随机 Worker 名）**

**触发时机**：首次使用前，或需要更换所有 Worker 名时。

**执行流程**：
```
gate → gen-names（只有这一个 job 运行）
```

**gen-names 内部逻辑**：
1. 从儿童友好词库（3~5 字母）随机抽取两个单词 W1、W2
2. 随机生成一个小写字母 L
3. 按格式 `{W1}-{W2}-{L}{digit}` 生成 N 个名字（digit = index % 10）
4. 通过 GitHub API（PATCH/POST）写入 WORKER_NAMES Variable
5. 在 Actions Summary 页面输出预览表格

**结果**：WORKER_NAMES Variable 被写入，如 `lamb-pond-j1,lamb-pond-j2,...`

---

### **5.2 PRESET=first（首次全量部署）**

**触发时机**：gen 完名字后的第一次正式部署，且只用一次。

**执行流程**：
```
gate → sync（SYNC_CODE=1 时）→ deploy × 10（PASS_MODE=2 双部署）
```

**deploy 内部每个账号的步骤序列**：
1. **Extract Credentials**：从逗号分隔的 CF_ACCOUNT_IDS / CF_TOKENS /
   WORKER_NAMES 中按 matrix.index 提取当前账号凭证和 Worker 名，
   并推算 Sub 域名（`{DIGIT}.w{SFXNUM}.cc.cd`）
2. **Patch Worker File**：在源 JS 开头注入 `var window = globalThis;`，
   替换 WebSocket path，按 FAKE_PAGE 决定是否生成 `_entry.js` 包裹层，
   生成 `wrangler.toml`（包含 Worker 名、路由、custom_domain）
3. **Deploy (1st pass)**：`continue-on-error: true`，忽略 10007 伪错误
4. **Wait 30s**：等待 CF 扫描器完成一个周期（PASS_MODE=2 专用）
5. **Delete Flagged Worker**：删除可能被 CF 标记的第一次部署产物
6. **Deploy (2nd pass)**：重新部署干净版本，绕过 CF 扫描器标记
7. **Wait 15s**：等待 Worker 在 CF 边缘节点稳定
8. **Set Secrets**：通过 CF API 写入 uuid 和 SUB 两个 Secret（使用 jq
   构造 JSON payload，防止特殊字符损坏，并校验 CF 返回的 success 字段）
9. **Verify**：通过 CF API 查询 Worker 是否真实存在（3 次重试），
   确认存在后 POST 关闭 workers.dev subdomain

**为什么首次需要双部署**：CF 的反滥用扫描器会对新上传的 Worker 内容进行
扫描，第一次部署的 Worker 可能被标记，30 秒后删除再重建可以绕过这个机制。

---

### **5.3 PRESET=daily（日常维护，推荐默认）**

**触发时机**：每天 03:00 UTC 自动触发，或手动维护。

**执行流程**：
```
gate → sync（SYNC_CODE=1 时）→ deploy × 10（PASS_MODE=1 单部署）
```

**与 first 的区别**：跳过 Wait + Delete Flagged + 2nd pass 三个步骤，
部署速度更快。整体每个账号耗时约 2~3 分钟，10 个账号并行约 3 分钟完成。

**Delete Worker(s) 步骤**：在 daily 模式下，PRESET 显式设置 `DELETE_MODE=0`，
步骤条件 `delete_mode == '1' || delete_mode == '2'` 不满足，
Delete 步骤被跳过，直接 Patch → Deploy，不会先删后建。

---

### **5.4 PRESET=solo:N（单账号维护）**

**触发时机**：某个账号出现问题，需要单独修复时。

**执行流程**：
```
gate → sync（SYNC_CODE=1 时）→ deploy × 1（只有 index=N 的实例）
```

**注意**：N 必须是 1~10 的整数，脚本在 gate 中有正则校验，
超出范围会直接 `exit 1` 并打印错误信息。

---

### **5.5 PRESET=secrets（仅更新密钥）**

**触发时机**：更换 UUID 或 SUB 域名后，不需要重新部署 JS 代码时。

**执行流程**：
```
gate → deploy × 10
```

**deploy 内部**：SECRETS_ONLY=1，Patch / Deploy / Wait / Verify 全部跳过，
只有 **Set Secrets** 步骤运行。无需重新编译和上传 Worker 代码，速度极快。

---

### **5.6 PRESET=delete:1 / delete:all**

**触发时机**：需要清理 Worker 时，执行后立即重建。

**delete:1**：DELETE_MODE=1，Delete Worker(s) 步骤删除 WORKER_NAMES 中
对应位置的单个 Worker，然后继续 Patch → Deploy → Set Secrets → Verify
重建它。实际效果是"强制刷新单个 Worker"。

**delete:all**：DELETE_MODE=2，Delete Worker(s) 步骤调用 CF API 列出账号
下所有 Worker 并逐一删除（不止 WORKER_NAMES 中的，而是账号下全部），
然后只重建 WORKER_NAMES 对应的那一个。
实际效果是"清空账号，重建指定 Worker"。

> ⚠️ delete:all 慎用，会删除该 CF 账号下所有 Worker，包括非本项目的。

---

## 六、域名推算规则

Sub 域名由脚本根据 `matrix.index` 自动推算，无需额外配置变量：

```
DIGIT  = index % 10
SFXNUM = printf "%02d" (index % 10)

数字域名（SUB_MODE=1）：{DIGIT}.w{SFXNUM}.cc.cd
命名域名（SUB_MODE=2）：{WORKER_NAME}.w{SFXNUM}.cc.cd
```

| index | DIGIT | SFXNUM | 数字 Sub | 命名 Sub（假设名为 lamb-pond-j1） |
|---|---|---|---|---|
| 1 | 1 | 01 | 1.w01.cc.cd | lamb-pond-j1.w01.cc.cd |
| 10 | 0 | 00 | 0.w00.cc.cd | lamb-pond-j0.w00.cc.cd |

---

## 七、Worker 命名规则

格式：`{word1}-{word2}-{letter}{digit}`，示例：`lamb-pond-j1`

- 单词来自儿童友好词库（3~5 字母），每次运行随机抽取两个不重复的单词
- 字母为随机小写字母，digit = index % 10（第 10 个账号 digit=0）
- 由 `gen-names` job 一次性生成，写入 `WORKER_NAMES` Variable
- 后续不再变化，除非重新触发 `PRESET=gen`

---

## 八、10007 错误机制说明

**根本原因**：Wrangler 若在 `wrangler.toml` 中写 `workers_dev = false`，
会在部署后立即调用 subdomain API，新 Worker 刚创建时该 API 返回 404，
触发 10007 错误。

**本版解决方案**：
1. `wrangler.toml` 中不写 `workers_dev = false`
2. Deploy 步骤开启 `continue-on-error: true`，忽略 10007
3. Verify 步骤通过 CF API 查询 Worker 是否真实存在（3 次重试 + 5s 间隔）：
   - 不存在（非 200）→ 说明部署真失败，报错退出
   - 存在（200）→ 10007 是伪报错，继续执行
4. Verify 步骤通过 CF API 手动 POST `{"enabled":false}` 关闭 subdomain

---

## 九、已修复的真实 Bug 记录

> AI 接手时对照检查当前脚本是否已应用。

| Bug | 位置 | 症状 | 修复 |
|---|---|---|---|
| Set Secrets R2 截断 | Set Secrets 步骤 | `curl: (2) no URL specified` | `PUT \` 与 URL 之间无空行 |
| Delete Mode 2 curl 断行 | Delete Worker(s) Mode 2 | curl 收到空格参数报错 | `"$W" \` 后另起一行写 `-H` |
| GH_PAT 缺 Contents 权限 | sync checkout | 403 Write access not granted | PAT 同时配置 Contents + Variables 权限 |
| deploy 缺 proceed 门控 | deploy if 条件 | CRON 屏蔽时 deploy 仍运行 | 增加 `proceed == 'true'` |
| cron-blocked delete_mode=1 | gate cron-blocked 分支 | 屏蔽触发反而删除 Worker | 改为 `delete_mode=0` |
| sync 失败级联 deploy | deploy if 条件 | sync 失败时 10 个账号全跳过 | 增加 `always()` + `gate.result == 'success'` + sync `failure` 纳入条件 |
| Verify 缺 secrets_only 门控 | Verify 步骤 | secrets 模式新账号误报失败 | 增加 `if: secrets_only == '0'` |
| Delete Worker(s) 缺 delete_mode 门控 | Delete 步骤 if | daily 模式先删后建 | 增加 `delete_mode == '1' \|\| == '2'` |
| FAKE_URL = 截断 | gate outputs | query string 被截断 | 改用 EOF 多行写法 |
| SYNC_CODE=0 仍启动 runner | sync job if | 浪费 30~45s runner | sync if 增加 `sync_code == '1'` |
| gate 初始化清空 Variables | gate 初始化块 | `VAR=""` 覆盖了 env 值，PRESET 为空时细粒度变量全部失效 | 改用 `:-` 语法，env 有值用 env，无值用内置默认值 |
| PRESET 分支残留 DELETE_MODE | gate case 分支 | 上次 delete:1 后 Variables 残留，本次 daily 误删除 | 各 PRESET 分支显式设置 DELETE_MODE=0（除 delete:1/all） |
| PRESET 分支残留 SECRETS_ONLY | gate case 分支 | 上次 secrets 后残留，本次 daily 误跳过部署 | 各 PRESET 分支显式设置 SECRETS_ONLY=0（除 secrets） |
| gen-names 数组引用为空 | gen-names job | WORKER_NAMES 生成空字符串 | 恢复 bash 数组展开语法 |
| 域名缺 SFXNUM | Extract Credentials | 生成 `1.w.cc.cd` 而非 `1.w01.cc.cd` | 增加两位补零 SFXNUM |
| FAKE_URL 单引号注入 | Patch Worker File | URL 含单引号时 JS 语法损坏 | 改用双引号包裹 |
| SUB_MODE 三元反模式 | Extract Credentials | `[ ] && \|\|` cmd1 返回非零时 cmd2 误执行 | 改用标准 if-else |
| CF API 仅检查 HTTP 状态码 | Set Secrets | HTTP 200 + success:false 被误判为成功 | 解析响应体 success 字段 |
| JSON payload 未转义 | Set Secrets | 变量含 `"` 或 `\` 时 JSON 损坏 | 使用 jq 构造 payload |
| 缺少凭证空值校验 | Extract Credentials | 凭证缺失时 401 错误不提前失败 | 提取后立即校验并 exit 1 |
| 缺少 SOLO_INDEX 范围校验 | gate solo:* 分支 | `solo:0` 等非法输入不报错 | 增加正则校验 1~10 |
| delete:all 缺 DEPLOY_SCOPE=2 | gate delete:all 分支 | 残留 solo 时只删一个账号 | 补充 `DEPLOY_SCOPE=2` |
| Worker 文件名硬编码 | Patch Worker File | 1~6 号无法切换非 nat64 版本 | CORE 和 import 路径改为 $WORKER_FILE 动态引用，env: 注入 WORKER_FILE |
| proxyip 缺失导致出口不可控 | Set Secrets | 非 nat64 版本未设置 proxyip，随机使用公共出口 | 按 use_proxyip 标记条件注入 proxyip Secret，jq 构造 payload 防字符损坏 |

---

## 十、Variables 推荐配置（日常状态）

```
PRESET       = daily     ← 最重要，覆盖所有细粒度
CRON_ENABLE  = 1         ← 开启每日自动运行
DELETE_MODE  = 0         ← 日常不删 Worker
PASS_MODE    = 1         ← 日常单部署
DEPLOY_SCOPE = 2         ← 全部账号
SYNC_CODE    = 0 或 1    ← 按需，1 = 同步上游
SUB_MODE     = 1         ← 数字域名
FAKE_PAGE    = 0         ← 关闭伪装页面
```

WORKER_NAMES、WORKER_COUNT、SOLO_INDEX 保持现有值不变。

---

## 十一、首次使用流程

```
Step 1：Run workflow → Preset 输入 gen
         → 等待完成，Summary 查看生成的名字表格
         → WORKER_NAMES 自动写入 Variable

Step 2：Run workflow → Preset 输入 first
         → 双部署流程，约 5~8 分钟完成
         → 仅首次需要，此后 PASS_MODE 改为 1

Step 3：Variables 中设置
         PRESET=daily，CRON_ENABLE=1
         → 后续每天 03:00 UTC 自动维护，无需人工干预
```

---

## 十二、客户端配置示例（Clash）

```yaml
- name: lamb-pond-j1
  type: vless
  server: lamb-pond-j1.w01.cc.cd
  port: 443
  uuid: <你的 VLESS_UUID>
  network: ws
  tls: true
  servername: lamb-pond-j1.w01.cc.cd
  ws-opts:
    path: /<MY_WS_PATH>
    headers:
      Host: lamb-pond-j1.w01.cc.cd
```

> 账号 1~6（非 nat64）​：出口为 CF_PROXYIP 指向的 VPS IPv4，或内置 proxyIPs 列表（CF_PROXYIP 未设置时）。ChatGPT / Netflix 等 IP 敏感服务推荐配 VPS ProxyIP。
> 账号 7~10（nat64）​：出口为 Cloudflare IPv6 NAT64，零成本兜底，不可控。

---

## 十三、三条核心原则

1. **随机名只生成一次**，之后长期固定，除非主动触发 `PRESET=gen`
2. **PASS_MODE=2（双部署）只在首次使用**，日常维护用 `PRESET=daily`
3. **所有行为通过 Variables / PRESET 控制，不需要改脚本本身**



### **n-vless 自动部署手册（DEPLOY.md）**

---

## 一、系统概述

本系统通过 GitHub Actions 实现 Cloudflare Workers VLESS 节点的自动化部署，支持 10 个 CF 账号并行部署，内置三层容错机制应对 Cloudflare 后端的间歇性行为。

**核心能力**：

- 10 账号并行部署（matrix 策略）
- 8 种 PRESET 场景预设，一键切换部署模式
- 双 Pass 流程绕过 CF 扫描器标记
- API 补绑确保 custom domain 100% 绑定
- gen 模式自动生成随机 Worker 名
- 上游代码自动同步
- 1-6 号账号使用非 nat64 + ProxyIP，7-10 号使用 nat64

---

## 二、Variables 配置参考

在 GitHub 仓库 → Settings → Actions → Variables 中配置：

| 变量名 | 说明 | 示例值 |
|---|---|---|
| `PRESET` | 场景预设（优先级最高） | 留空则使用细粒度变量 |
| `CRON_ENABLE` | 定时触发开关 | `0`=关闭，`1`=开启 |
| `DEPLOY_SCOPE` | 部署范围 | `1`=单账号，`2`=全部10个 |
| `SOLO_INDEX` | 单账号索引 | `1`~`10` |
| `GEN_NAMES` | 生成随机 Worker 名 | `0`=否，`1`=是 |
| `PASS_MODE` | 部署 Pass 次数 | `1`=单Pass，`2`=双Pass |
| `DELETE_MODE` | 删除模式 | `0`=不删，`1`=删指定，`2`=删全部 |
| `SECRETS_ONLY` | 仅更新 Secrets | `0`=否，`1`=是 |
| `SYNC_CODE` | 同步上游代码 | `0`=否，`1`=是 |
| `SUB_MODE` | 子域名模式 | `1`=数字子域名，`2`=命名子域名 |
| `FAKE_PAGE` | 伪装页面 | `0`=关，`1`=404页面，`2`=重定向 |
| `FAKE_URL` | 重定向目标 URL | `baidu.com` |

在 GitHub 仓库 → Settings → Secrets and variables → Actions → Secrets 中配置：

| Secret 名 | 说明 | 格式 |
|---|---|---|
| `CF_ACCOUNT_IDS` | 10 个账号 ID | 逗号分隔 |
| `CF_TOKENS` | 10 个账号 Token | 逗号分隔 |
| `WORKER_NAMES` | Worker 名（存储为 Variable） | 逗号分隔 |
| `MY_WS_PATH` | WebSocket 路径 | 单个字符串 |
| `VLESS_UUID` | VLESS UUID | 单个字符串 |
| `SUB_DOMAIN` | 订阅域名 | 单个字符串 |
| `CF_PROXYIP` | 代理 IP（1-6 号账号用） | 单个字符串 |
| `GH_TOKEN` | GitHub PAT（gen 模式写回 Worker 名） | 单个字符串 |

---

## 三、PRESET 预设系统

PRESET 是最高优先级的场景预设，支持三层优先级：`inputs.preset`（手动触发填写）> `vars.PRESET`（Variables 持久值）> 细粒度变量。

| PRESET 值 | 用途 | 关键参数 |
|---|---|---|
| `gen` | 只生成随机 Worker 名，不部署 | `GEN_NAMES=1` |
| `first` | 首次全量部署 | `DEPLOY_SCOPE=2, PASS_MODE=2, DELETE_MODE=0` |
| `daily` | 日常维护 | `DEPLOY_SCOPE=2, PASS_MODE=1, DELETE_MODE=0` |
| `solo:N` | 单账号部署（N=1-10） | `DEPLOY_SCOPE=1, SOLO_INDEX=N` |
| `secrets` | 只更新 Secrets | `SECRETS_ONLY=1, DEPLOY_SCOPE=2` |
| `delete:1` | 删指定 Worker 后重建 | `DELETE_MODE=1, PASS_MODE=2` |
| `delete:all` | 删所有 Worker 后重建 | `DELETE_MODE=2, PASS_MODE=2` |
| 留空 | 沿用所有细粒度 Variables | 由 Variables 决定 |

---

## 四、部署流程详解

### **Job 1: gate（门控 + PRESET 解析）**

解析 PRESET 三层优先级，构建动态 matrix，输出所有行为参数给下游 job。定时触发时检查 `CRON_ENABLE` 开关。

### **Job 2: gen-names（仅 gen 模式运行）**

从儿童友好单词池随机抽取两个词 + 一个字母 + 一个数字，生成 N 个 Worker 名（格式如 `mist-bear-h1`），通过 GitHub API 写入 `WORKER_NAMES` Variable。

### **Job 3: sync（同步上游代码）**

`SYNC_CODE=1` 时执行 `git merge upstream/main`，同步 `yonggekkk/Cloudflare-vless-trojan` 仓库的代码更新。

### **Job 4: deploy（核心部署，matrix 并行）**

每个 matrix 实例对应一个 CF 账号，执行以下步骤：

```
checkout
  → Extract Credentials（提取账号凭证 + 推算子域名）
  → Delete Worker(s)（DELETE_MODE 门控）
  → Patch Worker File（生成 wrangler.toml）
  → Deploy 1st Pass（continue-on-error）
  → [PASS_MODE=2] Wait 30s → Delete Flagged → Deploy 2nd Pass
  → Wait 15s
  → Set Secrets（uuid / SUB / proxyip）
  → Verify（存在性 + custom domain + workers.dev）
```

---

## 五、三层容错机制

这是整个系统的核心设计，用于应对 Cloudflare 后端的间歇性行为。

### **第一层：continue-on-error**

两次 wrangler deploy 均设置 `continue-on-error: true`。当 CF subdomain API 返回间歇性错误（10007 Worker does not exist / 10013 unknown error）时，wrangler 退出码非 0，但 GitHub Actions 不中断流程，后续步骤照常执行。

10007/10013 的本质：`workers_dev = false` 让 wrangler 在代码上传后必定调用 subdomain API 关闭 workers.dev。CF 后端状态正常时零报错，异常时返回 10007/10013。这是间歇性行为，不可预测，与代码配置无关。

### **第二层：API 补绑（custom domain 安全网）**

Verify 步骤通过 `/workers/domains?service=` 端点检测 custom domain 绑定状态。wrangler 的 custom domain 绑定同样是间歇性的——有时成功（日志显示 `Custom domain: OK`），有时失败（日志显示 `MISSING, binding via API...`）。失败时通过 `PUT /workers/domains` 手动补绑，PUT 幂等，重复绑定无害。

### **第三层：DELETE_MODE=0**

避免 `DELETE_MODE=2` 清空账号导致的代码异步回滚风险。当账号被清空后，CF subdomain 状态可能异常，10013 在此场景下可能导致 Worker 代码被异步回滚，Verify 查不到 Worker。日常运行保持 `DELETE_MODE=0`，仅在需要重建时临时使用 `delete:1` 或 `delete:all` 预设。

---

## 六、日志解读指南

### **正常日志（理想情况）**

```
>>> Identity: mist-bear-h1 → 1.w01.cc.cd (pos 1)
>>> Mode: NON-nat64 + ProxyIP (index 1)
[wrangler] Uploaded mist-bear-h1 (0.82 sec)
[wrangler] Deployed mist-bear-h1 triggers (2.16 sec)
[wrangler]   1.w01.cc.cd (custom domain)
>>> Set uuid: success=true
>>> Set SUB: success=true
>>> Set proxyip: success=true
>>> Worker exists: OK (HTTP 200)
>>> Custom domain: OK (1.w01.cc.cd)          ← wrangler 绑定成功
>>> Disable subdomain: HTTP 200
OK: workers.dev is disabled
```

### **容错日志（CF 后端间歇异常）**

```
>>> Identity: lamb-ring-q1 → 1.w01.cc.cd (pos 1)
[wrangler] ⚠️ 10007 Worker does not exist      ← 被吞，不中断
[wrangler 2nd] ⚠️ 10013 unknown error          ← 被吞，不中断
>>> Set uuid: success=true
>>> Set SUB: success=true
>>> Worker exists: OK (HTTP 200)               ← 代码实际已上传
>>> Custom domain: MISSING, binding via API... ← wrangler 未绑上
>>> Found zone_id for w01.cc.cd: c6ab...
>>> Custom domain binding: HTTP 200            ← API 补绑成功
>>> Disable subdomain: HTTP 200
OK: workers.dev is disabled
```

两种日志最终结果都是成功。绿色 job = Worker 存在 + custom domain 绑定 + workers.dev 关闭。

### **真正的失败日志**

```
>>> Existence check attempt 1: HTTP 404, retrying in 5s...
>>> Existence check attempt 2: HTTP 404, retrying in 5s...
>>> Existence check attempt 3: HTTP 404, retrying in 5s...
ERROR: Worker $WNAME not found (HTTP 404) after 3 attempts. Deploy truly failed.
```

Worker 代码被异步回滚，3 次重试均 404。这通常发生在 `DELETE_MODE=2` 清空账号后触发 10013 导致代码回滚。解决方案：改用 `DELETE_MODE=0` 重新部署。

---

## 七、标准操作流程

### **首次部署（新账号 / 重建）**

1. 设置 Variables：`GEN_NAMES=1`，运行生成随机 Worker 名
2. 设置 Variables：`DELETE_MODE=0, PASS_MODE=2, SYNC_CODE=1`
3. 留空 PRESET，手动触发 workflow
4. 等待 10 个账号全部绿色完成
5. 浏览器访问 custom domain 验证连通性

### **日常维护（定时 / 手动）**

1. 设置 Variables：`PASS_MODE=1, DELETE_MODE=0, SYNC_CODE=1, CRON_ENABLE=1`
2. 定时任务每天 03:00 UTC 自动执行
3. 也可手动触发，留空 PRESET

### **只更新 Secrets（换 UUID / 订阅域名）**

1. 更新对应的 Secret
2. 手动触发，PRESET 填 `secrets`
3. 不重新部署 Worker 代码，只更新 Secrets

### **单账号调试**

1. 手动触发，PRESET 填 `solo:4`
2. 只部署第 4 个账号，不影响其他

### **重建指定 Worker**

1. 手动触发，PRESET 填 `delete:1`
2. 删除 `WORKER_NAMES` 对应的 Worker 后双 Pass 重建

---

## 八、域名与账号对应关系

每个账号持有一个 `w0X.cc.cd` zone，子域名推算规则：

```
账号 1  → 1.w01.cc.cd    （SUB_MODE=1，数字子域名）
账号 2  → 2.w02.cc.cd
...
账号 6  → 6.w06.cc.cd
账号 7  → 7.w07.cc.cd    （nat64 版本）
...
账号 10 → 0.w00.cc.cd    （index%10=0）
```

`SUB_MODE=2` 时使用命名子域名（如 `mist-bear-h1.w01.cc.cd`）。

1-6 号账号使用非 nat64 版 `_worker.js` + ProxyIP（出口 IP 可控）；7-10 号使用 `nat64套壳版明文.js`（零成本兜底，不需要 ProxyIP）。

---

## 九、版本演进记录

| 版本 | 关键变更 |
|---|---|
| 初始版 | Verify 查 `/routes` 端点 + zone 硬编码 `cc.cd`（API 补绑失效） |
| 修复 zone | zone 查询改为 `$ZONE_NAME` 动态提取（API 补绑恢复可用） |
| 修复端点 | Verify 从 `/routes` 改为 `/workers/domains?service=`（准确检测 custom domain 状态） |
| 修复预设 | `delete:1` 和 `delete:all` 补上 `PASS_MODE=2`（删除后重建需双 Pass） |
| 当前版 | `DELETE_MODE=0` 为默认，三层容错完整，`/workers/domains` 端点正确 |

---

## 十、故障排查

### **Verify 报 `Cannot find zone_id`**

Token 缺少 `Zone:Read` 权限，或 WSUB 格式不符合 `{DIGIT}.w{SFXNUM}.cc.cd`。去 CF Dashboard 检查 Token 权限。

### **Custom domain binding: HTTP 403**

Token 缺少 `Worker Routes:Edit` 权限。去 CF Dashboard 补权限。

### **Worker not found after 3 attempts**

代码被异步回滚。通常是 `DELETE_MODE=2` 清空账号后触发 10013 导致。改 `DELETE_MODE=0` 重新部署。

### **Set uuid: success=false**

Worker 代码不存在（被回滚），Secrets 无法写入。先确认 Worker 存在再设置 Secrets。

### **wrangler 日志显示 Deployed 但 Verify 报 MISSING**

这是正常现象。wrangler 的 `Deployed ... (custom domain)` 日志只是声明意图，不代表实际绑定成功。API 补绑会完成绑定。

### **定时任务不执行**

检查 `CRON_ENABLE` 是否为 `1`。为 `0` 时 gate job 会拦截定时触发，手动触发不受影响。

上面是 DEPLOY.md 的正文部分，下面继续补充几个实用附录。

---

## 附录 A：Token 权限清单

每个 CF 账号的 API Token 需要以下权限：

| 权限 | 用途 | 步骤 |
|---|---|---|
| Account → Worker Scripts → Edit | 上传/删除 Worker、设置 Secrets、关闭 subdomain | deploy / delete / secrets / verify |
| Account → Worker Routes → Edit | API 补绑 custom domain | Verify |
| Zone → Worker Routes → Edit | custom domain 绑定到 zone | Verify 补绑 |
| Zone → Zone → Read | 查询 zone_id | Verify |
| Zone → DNS → Edit | custom domain 自动创建 DNS 记录 | wrangler deploy / API 补绑 |

**Account Resources**：选择对应账号
**Zone Resources**：选择对应账号持有的 `w0X.cc.cd` zone

如果 Token 权限不全，对应的报错：

| 缺失权限 | 日志表现 |
|---|---|
| Worker Scripts:Edit | wrangler deploy 失败 |
| Worker Routes:Edit | `Custom domain binding: HTTP 403` |
| Zone:Read | `Cannot find zone_id for w0X.cc.cd` |
| DNS:Edit | custom domain 绑定后 DNS 记录缺失，域名无法解析 |

---

## 附录 B：wrangler.toml 模板

脚本动态生成，每次部署覆盖写入：

```toml
name = "mist-bear-h1"
main = "Vless_workers_pages/_worker.js"
compatibility_date = "2025-01-01"
workers_dev = false

[[routes]]
pattern = "1.w01.cc.cd"
custom_domain = true
```

**字段说明**：

| 字段 | 值 | 说明 |
|---|---|---|
| `name` | `$WNAME` | Worker 名称，从 WORKER_NAMES 按位置提取 |
| `main` | `Vless_workers_pages/_worker.js` 或 `nat64套壳版明文.js` | 入口文件，1-6号用非nat64版，7-10号用nat64版 |
| `compatibility_date` | `2025-01-01` | 固定值 |
| `workers_dev` | `false` | 关闭 workers.dev 子域名，部署后由 API 二次确认关闭 |
| `pattern` | `$WSUB` | custom domain 域名，如 `1.w01.cc.cd` |
| `custom_domain` | `true` | 声明为 custom domain 类型（走 /workers/domains API） |

---

## 附录 C：CF API 端点参考

部署流程中使用的全部 Cloudflare API 端点：

### **Worker 管理**

| 方法 | 端点 | 用途 |
|---|---|---|
| `GET` | `/accounts/{id}/workers/scripts` | 列出账号下所有 Worker（DELETE_MODE=2） |
| `DELETE` | `/accounts/{id}/workers/scripts/{name}` | 删除单个 Worker |
| `GET` | `/accounts/{id}/workers/scripts/{name}` | 存在性校验（Verify） |
| `PUT` | `/accounts/{id}/workers/scripts/{name}/secrets` | 设置 Secrets（uuid/SUB/proxyip） |

### **Custom Domain 管理**

| 方法 | 端点 | 用途 |
|---|---|---|
| `GET` | `/accounts/{id}/workers/domains?service={name}` | 查询 Worker 的 custom domain 绑定状态 |
| `PUT` | `/accounts/{id}/workers/domains` | 补绑 custom domain（幂等） |

PUT payload：
```json
{
  "hostname": "1.w01.cc.cd",
  "service": "mist-bear-h1",
  "zone_id": "c6ab357b5469c8a1bdef1f3612db381b"
}
```

### **Subdomain 管理**

| 方法 | 端点 | 用途 |
|---|---|---|
| `POST` | `/accounts/{id}/workers/scripts/{name}/subdomain` | 关闭 workers.dev（`{"enabled":false}`） |
| `GET` | `/accounts/{id}/workers/scripts/{name}/subdomain` | 读回验证关闭状态 |

### **Zone 查询**

| 方法 | 端点 | 用途 |
|---|---|---|
| `GET` | `/zones?name={zone_name}` | 查询 zone_id（如 `w01.cc.cd`） |

---

## 附录 D：10007/10013 行为记录

基于多次运行的实测数据：

| 运行 | Worker 名 | 模式 | 1st deploy | 2nd deploy | Custom domain | 最终结果 |
|---|---|---|---|---|---|---|
| 修改前基线 | dawn-rose-h1 | DELETE_MODE=2, PASS_MODE=2 | 零报错 | 零报错 | MISSING→API补绑200 | 成功 |
| 修改前账号10 | dawn-rose-h0 | 同上 | 零报错 | 零报错 | MISSING→API补绑200 | 成功 |
| 失败运行 | lamb-ring-q1 | 同上 | 10007 | 10013 | MISSING→API补绑200 | 成功（容错救回） |
| 失败运行 | lamb-ring-q4 | 同上 | 10007 | 10013 | MISSING→API补绑200 | 成功（容错救回） |
| delete:all 运行 | — | DELETE_MODE=2, PASS_MODE=2 | 10013 | 10013 | Worker不存在 | 失败（代码回滚） |
| 最新运行 | mist-bear-h1 | DELETE_MODE=0, PASS_MODE=2 | 零报错 | 零报错 | OK（wrangler绑定成功） | 成功 |

**结论**：10007/10013 是 CF subdomain API 的间歇性行为。相同代码、相同配置、相同 wrangler 版本下，有时触发有时不触发。`DELETE_MODE=2` 清空账号会增加 10013 导致代码回滚的风险，`DELETE_MODE=0` 避免此风险。

---

## 附录 E：Variables 快速配置速查

| 场景 | PRESET | 或手动设置 Variables |
|---|---|---|
| 生成新 Worker 名 | `gen` | `GEN_NAMES=1` |
| 首次全量部署 | `first` | `DEPLOY_SCOPE=2, PASS_MODE=2, DELETE_MODE=0, GEN_NAMES=0` |
| 日常维护 | `daily` | `DEPLOY_SCOPE=2, PASS_MODE=1, DELETE_MODE=0, GEN_NAMES=0, CRON_ENABLE=1` |
| 单账号调试 | `solo:4` | `DEPLOY_SCOPE=1, SOLO_INDEX=4, DELETE_MODE=0` |
| 只更新 Secrets | `secrets` | `SECRETS_ONLY=1, DEPLOY_SCOPE=2` |
| 删指定后重建 | `delete:1` | `DELETE_MODE=1, PASS_MODE=2, DEPLOY_SCOPE=2` |
| 全部清空后重建 | `delete:all` | `DELETE_MODE=2, PASS_MODE=2, DEPLOY_SCOPE=2` |
| 沿用 Variables | 留空 | 由各 Variables 决定 |

---

