# ops/private-space-proxy-plan.md · xnexus-o 私有化 + 反代注入 token + cron-job 探活 执行清单

> 2026-09-02 归档。性质 = 执行计划（非锁定决策，DECISIONS 只增改约束不在此列）。前提论证链见会话记录。
> 一句话方案：xnexus-o 改私有 → HF 平台强制带 token 入站 → 脱离匿名池（官方 rate-limits 文档：Anonymous per-IP 500/5min vs Free user 1000/5min，双档铁证）→ 反代(CF 侧) 持有 HF token 出站注入 → cron-job.org 带 PSK 探反代。
> 三重收益：①焊死"PSK 泄露绕过反代直连"软肋 ②甩开匿名池入站 429 ③探活走反代 = 探用户真实路径。

---

## 阶段 1：Space 私有化 + 注入头定案（**✅ 完成 2026-09-02 实测定案**）

> **2026-09-02 实测结论（推翻 X-Api-Key 假设）**：HF 私有 Space **只认 `Authorization: Bearer <HF_TOKEN>`**，`X-Api-Key` 返回 404（直连实测三态：无 token→404 / X-Api-Key→404 / Bearer→200）。定案：反代出站 authorization 覆盖为 `Bearer <HF_TOKEN>` 门票，PSK 改走 `X-Gate-PSK` 独立头透传，gate.js `/v1` 校验 X-Gate-PSK 优先、回退 authorization。私有化与注入**同拍落地**（单独改私有而不注入 token，sonoke 通道即断——"我就不法和你说话了"）。

| # | 操作 | 位置 | 成功判据 |
|---|---|---|---|
| 1.1 | xnexus-o 改 **Private** | HF Dashboard → xnexus-o → Settings | ✅ 直连无 token 404（私有化生效） |
| 1.2 | 反代出站注 `Bearer <HF_TOKEN>` → 私有 Space 200 | 反代探活；业务 | ✅ 直连带门票 200 = 私有化+注入同拍闭环 |

## 阶段 2：反代（CF 侧）注入 HF token（**✅ 完成 2026-09-02，部署全绿**）

| # | 操作 | 位置 | 判据 |
|---|---|---|---|
| 2.1 | CF Pages 项目加 **Secret `HF_TOKEN`**（xnexus-o 账号 token，不落 git） | CF Dashboard → 该项目 → Settings → Secrets | 值已注入，代码 `env.HF_TOKEN` 可读 |
| 2.2 | `pages/ho-proxy/functions/_middleware.js` 出站 fetch 覆盖 `authorization: Bearer <HF_TOKEN>` 门票 + `X-Gate-PSK: Bearer <PSK>` 独立头 | 仓库代码 | ✅ 已改，mock **7/7 全绿**（新路 gate-psk 优先 / 老路 auth 回退）。双坑排查闭环：① 文件名须 `_middleware.js`（`[[path]].js` 的 `[[path]]` 被 wrangler 4.128 当 glob 吞空→`No Functions`）；② **部署必须 `cd` 进目录跑 `deploy .`**（相对子路径 `deploy pages/ho-proxy` 不发现 functions→空站 404；cd+`.` 有 toml 也正常，本地三态实证：子路径❌/cd+`.`✅/toml 无关） |
| 2.3 | 多 token 变量预案：`HF_TOKEN`（业务）+ 可选 `HF_TOKEN_MON`（探活/备用）——**同一账号，仅职责分离/备份，无扩容意义** | CF Secrets | 冗余，可选 |
| 2.4 | 部署 Pages 项目（GH Actions tag-driven） | CF 侧 | ✅ **自定义域名 `omn.360710.xyz` 已绑定**，全链路四态全绿 |
| 2.5 | sonoke → 反代 → 私有 Space 真业务 200 | sonoke | ✅ `/v1/models` 200（重启后 gate 加载新逻辑） |

> **生产部署三坑全闭环（wrangler 4.128 + GH Actions tag 触发）**：
> ① 文件名须 `_middleware.js`（`[[path]].js` 的 `[[path]]` 被当 glob 吞空→`No Functions`）
> ② 部署须 `cd` 进目录跑 `deploy .`（相对子路径不发现 functions→空站 404）
> ③ **须 `--branch main` 强制 production**（GH Actions checkout=detached HEAD，`wrangler pages deploy` 默认判 preview 部署；secret 绑 **production** env → preview 读不到 INTERNAL_PSK → 503 "proxy not configured"；且默认 URL `ho-proxy-pages.pages.dev` 无 production 部署一直 404）。`--branch main` 后：无 Bearer→401 / 错 PSK→401 / 真 PSK→透传 gate /v1/models 200 全绿。
> 部署命令：`cd pages/ho-proxy && npx wrangler@latest pages deploy . --project-name ho-proxy-pages --branch main`（workflow 里 secret-put 须在 deploy **前**，否则新 deployment 读不到）。

> **升级预案（✅ 已启用 2026-09-02，实测触发）**：HF 私有 Space 实测不认 X-Api-Key → PSK 迁 `X-Gate-PSK` 头出站 + `Authorization` 让位给 `Bearer <HF_TOKEN>`（HF 标准）+ gate.js `/v1` 校验 X-Gate-PSK 优先、回退 authorization（dev/logic/gate.js L199-212）。已重启生效，全链路四态全绿。

## 阶段 3：cron-job.org 探活（**✅ 完成 2026-09-02**）

| # | 操作 | 位置 | 判据 |
|---|---|---|---|
| 3.1 | 建 cron 任务，**每分钟** GET 反代探活端点（`https://omn.360710.xyz/healthz`） | cron-job.org | ✅ 任务创建成功 |
| 3.2 | 配自定义头 `Authorization: Bearer <PSK>`（**只带 PSK，不带 HF token** —— token 只在 CF 侧） | cron-job.org → 任务 → headers | ✅ 官方已确认支持任意头 |
| 3.3 | 触发一次 | cron-job.org | ✅ 返回 200 `{"ok":true}`（响应头 `x-proxied-host`/`x-proxied-path` 证穿透 gate） |
| 3.4 | 异常告警配置（连续失败通知） | cron-job.org | ✅ 探活反代 = 探用户真实路径，反代挂即报警 |

> 免费档：任务数不限、每任务 60 次/时——每分钟探活完全够。**探活走反代而非直探 Space**，否则测不到反代挂。

## 阶段 4：全链路验收 + 归档

| # | 操作 | 判据 |
|---|---|---|
| 4.1 | sonoke base_url → 反代，业务 POST 200 | 全链路绿 ✅ |
| 4.2 | Pages 唯一生产（worker 版已删不重建；旧版不带 HF 门票私有 Space 必拒；源码留仓库作回滚源） | ✅ 定案 |
| 4.3 | 决策/状态写 ops/（得出私有化实证结论） | 归档 |

## 回滚预案（任一步失败）

- 阶段 1 入站 429 无改善 → **xnexus-o 改回 Public**（平台操作即回滚）
- 阶段 2 头名错 → 改注入头名即可，无其他连带
- 反代出问题 → `HO_PROXY_ENABLED=0` / 删 CNAME 即整体下线

---

## 已锁关键事实（论证查证产出，勿回改）

1. **cron-job.org 支持任意自定义请求头**（官方 FAQ 原话 "arbitrary custom headers"），免费档不限任务数、每任务最高 60 次/时。
2. **HF 限流是 per-account 非 per-token**（同账号多 token 共享池）→ 多 token 仅职责分离/备份，**不扩容、不轮询**。
3. **官方 rate-limits 双档**（2025-09，5 分钟窗口）：Anonymous per-IP = API 500 / Resolvers 3000 / Pages 100；Free user = 1000 / 5000 / 200 → 带 token 即翻倍。
4. **私有 Space 只认所属账号 token** → 多账号 token 是伪需求，已废弃。
5. **Pages 子域跨账号绑定**：子域 CNAME 到 `<site>.pages.dev`，apex 锁同账号 zone；橙云无强制（到 pages.dev 天然进 CF 边缘）；须先 dashboard 关联后加 CNAME 否则 522。

## 相关文档

- 反代 Worker 版: `workers/ho-proxy/`（保留热备）
- 反代 Pages 版: `pages/ho-proxy/`（新建）
- 决策链: `ops/docs/DECISIONS.md`（届时 4.3 再落）
