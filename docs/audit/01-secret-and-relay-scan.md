# Stage A · 敏感与 Relay 扫描 (audit/01-secret-and-relay-scan.md)

> 第六独立审查者 · Stage A 产出 · 只读, 未改任何文件
> 生成日期: 2026-07-11
> **凭据脱敏原则: 只记 文件:行号:命中类型, 绝不复制凭据值。疑似真实凭据一律显示 `[REDACTED]`。**

---

## 0. 扫描范围与方法

范围: `/home/laisi/omn-merge/` 全仓 (生产 6 文件 + cf-worker + docs + .github) 与源码 `/home/laisi/OmniRoute/` 关键文件。

方法: grep 高熵凭据模式 (nvapi-/Bearer/sk-/AKIA/hf_/api_key=/password=) + Relay 残留模式 (RELAY_URL/RELAY_TOKEN/x-relay/vercel/deno/cloudflare relay/RELAY_BACKEND/BIFROST)。
所有命中经 `sed` 去值化, 报告只留 路径:行号:类型。

---

## 1. 明文凭据命中扫描

### 1.1 生产根文件 (Dockerfile/entrypoint.sh/gate.js/init-nim-keys.sh/litestream.yml/package.json)

**高熵明文凭据命中: 0**

- gate.js / entrypoint.sh / Dockerfile / litestream.yml / package.json: 无任何明文 key/token/secret。凭据全走 `process.env` / `os.environ`(init `bash`)。
- init-nim-keys.sh: `NIM_KEYS` 等以 env 读入, curl 用 `"Authorization: Bearer $NIM_KEY"` / `"Bearer ${_key}"` 变量引用 (注: 报告中变量引用被脱敏脚本误判为命中, 实为变量名非值)。

→ 符合红线 1 "凭据不硬编码"。**L1 通过。**

### 1.2 cf-worker/

**高熵明文凭据命中: 0**
- `cf-worker/index.js` 用 `env.INTERNAL_PSK` / `env.CLIENT_TOKEN` / `env.UPSTREAM_BASE` / `env.WECOM_WEBHOOK` / `env.RESEND_API_KEY`, 全走 Worker secret binding, 无硬编码。
- `cf-worker/readme.md` 列 Secret/Variable 名称 (CLIENT_TOKEN/INTERNAL_PSK/UPSTREAM_BASE/WECOM_WEBHOOK/RESEND_API_KEY), **仅变量名**, 无值。

→ **L1 通过。**

### 1.3 docs/ (含 4.3 候选与历史)

**高熵明文凭据命中: 0**(所有 grep 命中均为 `"Authorization: Bearer $VAR"` / `"Bearer ${_key}"` 变量引用脱敏, 非真实值)。

代表命中 (均变量引用, 值已脱敏):
- docs/nim_context_probe.sh:51,69 — `Authorization: Bearer $NIM_KEY`
- docs/DEPLOYMENT_GUIDE.md:389,402,417 — `Authorization:` (变量)
- docs/archive/4.3/4.2.3.md:444,487,868 — `Bearer ${_key}` / `export-json` 调用 (变量)
- docs/archive/4.3/in4.3.txt:593,626 — `Bearer ${_key}` (变量)
- docs/archive/audit-report.md(多处) / n-omn-4.2.md(多处) / 3.8.0.txt(多处) — 历史材料, 同变量引用模式

**无一处发现裸明文 nvapi-XXX / sk-XXX / hf_XXX / AKIA key 值。**

→ **L1 通过。** docs 含大量 curl 示例, 均用 env 变量, 未泄真实凭据。

### 1.4 源码 `OmniRoute/.env.example` 与 git 史

- `.env.example` 高熵命中 0; `JWT_SECRET=`(空) / `API_KEY_SECRET=`(空) / `INITIAL_PASSWORD=CHANGEME`(占位)。2034 行配置示例, 无真实值。
- `git log --name-only --all` 无 `.env` / `secret` / `credential` 文件名入库痕迹 (init-nim-keys.sh 的 "Update" commit 属正常代码提交, 无 secret 文件)。

→ **L1 通过。**

---

## 2. Relay 残留扫描 (分类: 外部 Relay(删) / 历史讨论(标废弃) / 内部策略名(Not NIM Relay))

### 2.1 命中分类总表

| 命中位置 | 命中文本 (脱敏) | 分类 | 处置 |
|----------|----------------|------|------|
| init-nim-keys.sh:30-35 | `ONEPROXY_ENABLED=false` / `ENABLE_SOCKS5_PROXY=false` / unset `OMNIROUTE_RELAY_BACKEND` / `BIFROST_BASE_URL` / `HTTP_PROXY*` | **内部关闭代理生态(主动关闭)** | KEEP (合规, 符合背景 #1) |
| init-nim-keys.sh:171-203 | `NIM_PROXY_RELAY_HOST=127.0.0.1` / `_PROXY_RELAY_PORT=20129` / `purge_proxy_db` 清 `proxy_registry` | **内部 proxy registry 清理名(本地 loopback)** | KEEP (非外部 Relay, 是清理旧本地 proxy 登记) |
| init-nim-keys.sh:102 | `_VALID_STRATS="...context-relay...fusion..."` 策略名枚举 | **内部策略名枚举(非 NIM Key 池用)** | KEEP (仅枚举可用 strategy 字符串; 默认 pool=p2c, codex=round-robin, **未选 context-relay/fusion** 作 NIM 主池; Stage C 须确认无路径默认 SELECT context-relay) |
| cf-worker/index.js + .github/workflows/deploy-cf-worker.yml | Cloudflare Worker 部署 (wrangler@4) | **双层网关外层(白名单+PSK+告警), 非流量 Relay** | STAGE-B 裁决: 是否视为合规 Gate 或按"外部 Cloudflare"红线删除 (见 audit/00 §5/§6.7) |
| entrypoint.sh:62 | `env-bypass 模式` | **已验证机制(记忆索引 omniroute-upstream-env-bypass-stable)** | KEEP (非 relay, 是 API Key 直传 bypass) |

### 2.2 外部 Relay 硬禁项 (RELAY_URL_*/RELAY_TOKEN_*/x-relay-*) 命中

**全仓 0 命中。** grep `RELAY_URL|RELAY_TOKEN|x-relay` 跨生产文件/docs/cf-worker/.github = 空。
→ 符合红线 "禁 RELAY_URL_*/RELAY_TOKEN_*/x-relay-*"。**L1 通过。**

### 2.3 外部 Relay 平台 (vercel/deno/cloudflare relay host) 命中

- `vercel.com` / `deno.dev` / `workers.dev` 串: 仅 `cf-worker/wrangler.toml` 的 `workers_dev=true` (Cloudflare Workers 部署开关, 非中继 RELAY 平台语义)。
- **无任何 Vercel Relay 或 Deno Relay 接入代码。**

→ 外部 Relay (Vercel/Deno) 0 命中。Cloudflare 维度仅 `cf-worker` 本身, 角色待 Stage B 裁决。

### 2.4 context-relay / fusion 策略名风险

背景红线: "禁止把 context-relay 当作 NIM 多 Key 无缝会话方案"。
- `init-nim-keys.sh:102` `_VALID_STRATS` 枚举含 `context-relay` 与 `fusion`, 但:
  - L143 `_POOL_STRATEGY="${NIM_POOL_STRATEGY:-p2c}"` (默认 p2c, 非 context-relay)
  - L148 `_CODEX_STRATEGY="${NIM_CODEX_STRATEGY:-round-robin}"` (默认 round-robin)
  - L150 `_FALLBACK_STRATEGY="round-robin"`
  - → **默认未选 context-relay/fusion 作 NIM 主策略**。
- 但枚举存在 → Stage C 须**确认无任何代码路径在 NIM 多 Key 场景默认写入 context-relay 或 fusion**; 若候选要更保守, 可从 `_VALID_STRATS` 删除 `context-relay` `fusion` 以消除歧义 (Stage B 裁决)。
- 背景结论 #3 "Context Relay 仅限 Codex 账号轮换, NIM Key 池无状态" 与现状一致 (NIM 池 p2c, 非 context-relay)。

---

## 3. 结论

| 维度 | 结果 | 证据 |
|------|------|------|
| 明文凭据硬编码 | **0** (全走 env/secret binding) | L1 |
| RELAY_URL/RELAY_TOKEN/x-relay-* | **0 命中** | L1 |
| 外部 Relay (Vercel/Deno) | **0 命中** | L1 |
| context-relay/fusion 作 NIM 默认 | **默认未选 (p2c/round-robin)** | L1 |
| Cloudflare | 仅 cf-worker (角色待 Stage B 裁决) | L1 |
| 代理生态 | 主动关闭 (ONEPROXY/SOCKS5/RELAY_BACKEND/BIFROST 全 unset/false) | L1 |

**红线 1 (凭据不进 Dataset/日志明文)**: 静态扫描 0 明文命中。但**动态风险残留**: init-nim-keys.sh `NIM_DEBUG_LOG_TO_DATASET` 默认开 (audit/00 §6.9), DEBUG 日志内容脱敏未守 → Stage C 动态验证。

**红线 2 (Gate 暴露面/PSK)**: cf-worker 与 gate.js 路由白名单基本符合 (/healthz+/v1), 但 gate.js 非 /v1 透传未 404, PSK 两处非 timing-safe, cf-worker `/__health` 额外路径 → Stage B/C 裁决与修复 (audit/00 §6.4/§6.5/§6.8)。

**红线 3 (Litestream 不覆盖非空本地)**: entrypoint.sh restore 无非空 guard → Stage B/C 修复 (audit/00 §6.6)。

本扫描**未输出、未复制、未持久化、未报告任何凭据值**; 扫描仅做模式匹配与脱敏元数据记录, 疑似值一律 `[REDACTED]`。符合 Stage A 约束。

---

## 附录 · 扫描命令记录 (复现用)

```
# 明文凭据 (去值化)
grep -rnE 'nvapi-[A-Za-z0-9_-]{20,}|Bearer [A-Za-z0-9_-]{20,}|sk-[A-Za-z0-9]{20,}|AKIA[0-9A-Z]{16}|hf_[A-Za-z0-9]{20,}|api[_-]?key[=:]\s*["'\'']?[A-Za-z0-9]{16,}' \
  --include='*.sh' --include='*.js' --include='*.yml' --include='*.md' --include='*.toml' --include='Dockerfile' \
  Dockerfile entrypoint.sh gate.js init-nim-keys.sh litestream.yml package.json docs/ cf-worker/ .github/

# Relay 残留
grep -rinE 'RELAY_URL|RELAY_TOKEN|x-relay|vercel\.com|deno\.dev|workers\.dev|RELAY_BACKEND|BIFROST_BASE_URL|context-relay|fusion' \
  Dockerfile entrypoint.sh gate.js init-nim-keys.sh litestream.yml package.json docs/ cf-worker/ .github/

# .env.example 占位校验
grep -cE 'nvapi-...|sk-...|hf_...|AKIA...' OmniRoute/.env.example
```
