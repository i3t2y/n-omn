根据最新的脚本优化（引入 **PRESET 预设场景**、**并发锁**、**超时保护**以及 **workflow_dispatch 动态覆盖**），我为你更新了 `DEPLOY.md`。

新版文档重点解释了如何使用「一键场景」来简化操作，建议直接整体替换原文件。

### **### DEPLOY.md 最终优化版（含场景预设说明）**

---

```markdown
# n-vless 自动部署说明（场景预设版）

本项目通过 **GitHub Actions + Cloudflare Workers** 实现多账号自动部署。当前版本已整合 **PRESET（场景预设）** 功能，只需一个参数即可完成复杂操作。

## 🚀 核心优化摘要

| 优化项 | 说明 |
|---|---|
| **PRESET 预设** | 支持 `daily`, `first`, `solo:N` 等场景，一键切换复杂变量组合 |
| **动态覆盖** | 支持在 Actions 启动界面直接输入参数，不破坏 Variables 持久配置 |
| **并发保护** | 引入 `concurrency` 锁，防止手动与定时任务冲突互删 |
| **存在性校验** | `Verify` 步骤新增真实性检查，彻底解决 10007 伪报错掩盖真实失败的问题 |
| **超时保护** | 增加 15 分钟强制超时，防止 API 挂起白白消耗 Actions 额度 |

---

## 一、如何使用 PRESET（推荐）

现在你不需要逐个修改 Variables 里的 `GEN_NAMES` 或 `PASS_MODE`，只需修改一个名为 **`PRESET`** 的变量（或在启动界面输入）：

| PRESET 值 | 适用场景 | 内部逻辑 |
|---|---|---|
| `gen` | **生成随机名** | 只生成 Worker 名字并存入变量，不部署 |
| `first` | **首次全量部署** | 10个账号全部部署，且使用双 pass 绕过扫描 |
| `daily` | **日常维护** | 全部账号单次快速部署（默认推荐） |
| `solo:N` | **单账号维护** | 只部署第 N 个账号（如 `solo:3`） |
| `secrets` | **仅更新密钥** | 只更新 UUID/SUB，不重新部署 JS 代码 |
| `delete:1` | **指定删除** | 删除当前 `WORKER_NAMES` 对应的 Worker |
| `delete:all` | **清空账号** | 彻底删除账号下所有 Worker（慎用） |

> **优先级说明**：Actions 启动界面输入 > Variables 中的 `PRESET` > 细粒度变量。

---

## 二、GitHub 配置清单

### 1. Secrets（必须）
| 名称 | 说明 |
|---|---|
| `CF_ACCOUNT_IDS` | 多个 Account ID，逗号分隔 |
| `CF_TOKENS` | 对应 API Token，顺序须一致 |
| `VLESS_UUID` | 你的 UUID |
| `MY_WS_PATH` | WebSocket 路径（不含 `/`） |
| `GH_PAT` | 用于回写变量的 Token（需 Variables 读写权限） |

### 2. Variables（控制参数）
| 名称 | 默认值 | 说明 |
|---|---|---|
| `PRESET` | `daily` | 填入上表中的预设词即可一键配置 |
| `WORKER_NAMES` | (自动) | 脚本自动写入，无需手动修改 |
| `CRON_ENABLE` | `1` | `0` 则屏蔽定时触发 |

---

## 三、快速上手流程

### 第一步：生成名字
在 Actions 页面点击 `Run workflow`，在 **Preset** 框输入 `gen` 并启动。完成后在 Summary 页面查看生成的随机名。

### 第二步：首次部署
点击 `Run workflow`，输入 `first` 并启动。此时会进行双部署流程。

### 第三步：日常维护
保持 Variables 中的 `PRESET` 为 `daily` 即可。脚本会每天 03:00 UTC 自动运行。

---

## 四、技术细节：10007 错误与 Verify 校验

本脚本在 `Deploy` 步骤开启了 `continue-on-error`。这是因为 Cloudflare 的 `subdomain` API 存在延迟，新 Worker 刚上传时查询会报 10007 错误导致脚本中断。

**现在的逻辑是：**
1. **Deploy**：即使报 10007 也继续往下走。
2. **Verify**：先通过 API 查询 Worker 是否**真实存在**。
   - 如果不存在：说明部署真失败了，此时脚本会报错退出。
   - 如果存在：说明 10007 是伪报错，脚本继续执行「主动关闭 workers.dev」的操作。

---

## 五、客户端配置（Clash 示例）

```yaml
- name: duck-nest-f1
  type: vless
  server: duck-nest-f1.w01.cc.cd
  port: 443
  uuid: <你的UUID>
  network: ws
  tls: true
  servername: duck-nest-f1.w01.cc.cd
  ws-opts:
    path: /<MY_WS_PATH>
    headers:
      Host: duck-nest-f1.w01.cc.cd
```

---

✅ **至此，n-vless 已进入全自动化场景管理阶段。**
```

---
你可以将此内容保存为 `.github/DEPLOY.md`。这个版本不仅是说明书，更是一份「运维手册」，能帮你快速理解 PRESET 的强大之处。

*内容由 AI 生成仅供参考*