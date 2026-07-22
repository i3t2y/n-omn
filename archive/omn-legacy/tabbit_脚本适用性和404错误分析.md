下面是**已同步你当前最终架构的 `.github/DEPLOY.md` 完整新版**，可以直接整体替换原文件内容使用。

---

```markdown
# n-vless 自动部署说明（最终版）

本项目基于 `yonggekkk/Cloudflare-vless-trojan`，通过 **GitHub Actions + Cloudflare Workers** 实现多账号、可控、可维护的自动部署。

本版本已完成以下优化：

- ✅ 变量精简（仅保留必要变量）
- ✅ 支持随机生成 Worker 名（一次生成，长期固定）
- ✅ 支持单账号 / 多账号精确部署
- ✅ 使用 **动态 matrix**，UI 中只显示实际运行的账号
- ✅ 完全绕开 Wrangler 的 workers.dev 自动处理，避免 10007 错误
- ✅ 所有危险操作（Delete / Deploy）均可控、可回滚

---

## 一、文件结构说明

```text
.github/
 ├─ workflows/
 │   └─ sync-deploy.yml     # 主部署脚本
 └─ DEPLOY.md               # 本说明文件（不会被上游覆盖）
```

> ⚠️ 不要把说明写在 README.md，上游同步会覆盖。

---

## 二、GitHub Secrets（必须）

路径：`Settings → Secrets and variables → Secrets`

| 名称 | 说明 |
|---|---|
| `CF_ACCOUNT_IDS` | 多个 Cloudflare Account ID，英文逗号分隔（位置 1~10） |
| `CF_TOKENS` | 对应账号的 API Token，顺序必须和 Account ID 一致 |
| `VLESS_UUID` | 自定义 UUID |
| `MY_WS_PATH` | WebSocket 路径（不含 `/`），例如 `a7f3k9mx` |
| `GH_PAT` | **Fine‑grained PAT**，用于写 Repository Variables（必须） |

### GH_PAT 权限要求

- Resource owner：你的 GitHub 用户名
- Repository access：**Only select repositories → n-vless**
- Permissions → **Variables：Read and write**

---

## 三、GitHub Variables（控制参数）

路径：`Settings → Secrets and variables → Variables`

### 1️⃣ 核心控制变量

| 变量 | 值 | 说明 |
|---|---|---|
| `GEN_NAMES` | `0 / 1` | `1`=只生成随机 Worker 名，不做任何部署 |
| `WORKER_COUNT` | 数字 | 生成几个 Worker 名，默认 `10` |
| `WORKER_NAMES` | 自动写入 | 逗号分隔的 Worker 名列表 |
| `DEPLOY_SCOPE` | `1 / 2` | `1`=单账号，`2`=全部账号 |
| `SOLO_INDEX` | `1~10` | 单账号模式下要部署的账号位置 |
| `PASS_MODE` | `1 / 2` | `2`=首次双部署；`1`=日常单部署 |
| `DELETE_MODE` | `1 / 2` | `1`=删指定 Worker；`2`=删账号下所有 Worker |
| `SUB_MODE` | `1 / 2` | `1`=数字域名；`2`=名字域名 |
| `SYNC_CODE` | `0 / 1` | 是否同步上游代码 |
| `CRON_ENABLE` | `0 / 1` | 是否允许定时触发 |
| `SECRETS_ONLY` | `0 / 1` | `1`=只更新 Secrets，不部署 |

### 2️⃣ 可选伪装页面变量

| 变量 | 值 | 说明 |
|---|---|---|
| `FAKE_PAGE` | `0 / 1 / 2` | `1`=返回 404 页面；`2`=跳转 |
| `FAKE_URL` | URL | `FAKE_PAGE=2` 时跳转目标 |

---

## 四、随机 Worker 命名规则（已固化）

生成一次，后续不再变化：

```
<word1>-<word2>-<letter><digit>
```

示例（统一前缀）：

| index | Worker Name | Numeric Sub | Named Sub |
|---|---|---|---|
| 1 | neon-git-f1 | 1.w01.cc.cd | neon-git-f1.w01.cc.cd |
| 9 | neon-git-f9 | 9.w09.cc.cd | neon-git-f9.w09.cc.cd |
| 10 | neon-git-f0 | 0.w00.cc.cd | neon-git-f0.w00.cc.cd |

---

## 五、首次使用流程（重要）

### ✅ Step 1：生成随机 Worker 名

Variables 设置：

```
GEN_NAMES=1
WORKER_COUNT=10
```

然后 **手动触发 workflow**。

- Actions → Summary 中可看到生成表格
- `WORKER_NAMES` 会自动写入 Variables

### ✅ Step 2：首次全量部署

Variables 修改为：

```
GEN_NAMES=0
DEPLOY_SCOPE=2
PASS_MODE=2
```

手动触发一次。

> 双部署用于绕过 CF 扫描，仅首次需要。

### ✅ Step 3：进入日常模式

```
PASS_MODE=1
CRON_ENABLE=1
```

后续定时自动维护。

---

## 六、单账号维护 / 切换账号

只需要改 **Variables**，无需改代码：

```text
DEPLOY_SCOPE=1
SOLO_INDEX=3
```

UI 中只会出现 `deploy (3)` 一个实例。

---

## 七、关于 workers.dev 与 10007 错误

- ✅ 已 **彻底禁用 Wrangler 自动处理 workers.dev**
- ✅ 由 Verify 步骤使用 CF API **主动关闭 subdomain**
- ✅ 即使 Worker 不存在 / 刚创建，也不会再触发 10007

---

## 八、客户端示例（Clash Verge）

```yaml
- name: neon-git-f1
  type: vless
  server: neon-git-f1.w01.cc.cd
  port: 443
  uuid: <你的UUID>
  network: ws
  tls: true
  servername: neon-git-f1.w01.cc.cd
  ws-opts:
    path: /<MY_WS_PATH>
    headers:
      Host: neon-git-f1.w01.cc.cd
```

> nat64 套壳版 **无需设置 proxyip**，出口为 Cloudflare IPv6 NAT64。

---

## 九、重要结论（记住这三条）

1. **随机名只生成一次**，之后长期固定
2. **PASS_MODE=2 只在首次用**
3. 所有行为只通过 **Variables 控制，不需要改脚本**

---

✅ 至此，n‑vless 已进入「可长期稳定维护」状态。

*内容由 AI 生成仅供参考*