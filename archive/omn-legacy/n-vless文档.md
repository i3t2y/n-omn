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

以上就是完整的 DEPLOY.md。如果你需要我把它保存为 Markdown 文件下载，或者直接推送到仓库，告诉我就行。

*内容由 AI 生成仅供参考*