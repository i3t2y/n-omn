# gate.js `ADMIN_ENABLED`/`ADMIN_TOKEN_MIN_LEN` 砍回内联 + 双闸论证留证

**日期**: 2026-07-23
**Space**: nonoke-omn.hf.space(永续 dev, bucket omn-data)
**件**: `omn-logic/gate.js`(HF Dataset `nonoke/omn-logic` 逻辑层五件之一)
**律**: §1 双空间铁律(dev only, nomn 生产零触); §3 secret 值零入会话/文档/git; §6 自验用合成 chr 串。

---

## 一、背景(Supreme 两问)

1. **gate.js admin 是否过于繁琐?** → 已在前轮解决: 520→455 行, 砍 47 行白名单路由器, 留单开关全路径 Basic Auth 透传。见 [[gate-js-single-switch-admin-landed]]。
2. **gate 叠 `GATE_ADMIN_TOKEN` 何闸 vs OR 自身 `INITIAL_PASSWORD`(已是 `openssl rand -hex 16`=32字)是否过度谨慎?** → 本档论证(见 §三)。
3. **(本次新增)删 `ADMIN_ENABLED`+`ADMIN_TOKEN_MIN_LEN` 两具名 const, 判式回内联 `GATE_ADMIN_TOKEN.length (>=|<) 16`, 省行** → 本档 §四 记落定。

---

## 二、两闸不同层(易混点澄清)

易误解点: `GATE_ADMIN_TOKEN` 与 `INITIAL_PASSWORD` 像都"后台密码", 疑冗余。**实非同层**:

| 闸 | 变量 | 层 | 暴露面 | 防什么 |
|---|---|---|---|---|
| 1. gate Basic Auth | `GATE_ADMIN_TOKEN` | **网关层**(HF :7860 出口 Express 代理) | 外网 → gate | 门外第一道: 验谁可撞后台**面**; 关时全 404 不泄露后台存在 |
| 2. OR 自身登录 | `INITIAL_PASSWORD` | **OR 应用层**(127.0.0.1:20128 OmniRoute Next.js) | gate 透传后 → OR `/api/auth/login` | 验谁可拿后台**session**(Cookie/JWT) |

**职责正交**: gate 管"门关不关 + 门外挡暴破", OR 管"凭证验 + 发 session"。砍 gate 层 = 后台门户直裸 OR login 端点。

---

## 三、论证: 叠 `GATE_ADMIN_TOKEN` 是否过度谨慎?

### 3.1 OR 自身 `/api/auth/login` 已全套武装(上游 `omniroute-3.8.43` 源码铁证)

读上游源码核:

- **`src/server/auth/loginGuard.ts`**: 登录暴破守卫, IP 级滑动窗
  - `FAILURE_THRESHOLD = 5`(5 次失败触发)
  - `WINDOW_MS = 15 * 60 * 1000`(15 分钟窗)
  - `LOCKOUT_MS = 15 * 60 * 1000`(锁 15 分钟)
  - 进程内存 `Map<ip, AttemptState>` 追踪, `PRUNE_THRESHOLD = 256` 防 map 无界长
  - **注释明说**: *"defense-in-depth check that pairs with Cloudflare/reverse-proxy rate limiting, **not a substitute for it**."* — OR 自身假定前面有层网关兜暴破
- **`src/lib/auth/managementPassword.ts`**: bcrypt 密码哈希(`ensurePersistentManagementPasswordHash`/`verifyManagementPassword`), 明文 `INITIAL_PASSWORD` 启动迁哈希, 不存明文
- **`src/app/api/auth/login/route.ts`**:
  - `JWT_SECRET` 无 config → fail-fast 500(`[SECURITY] FATAL: JWT_SECRET is not set. Login authentication is disabled.`)
  - Zod 校验 body(`loginSchema`/`validateBody`)
  - `checkLoginGuard(clientIp)` 前置判锁, 锁则返 `retryAfterSeconds` 429
  - 成功签 JWT session(`SignJWT` + `cookies()`), 失败 `recordLoginFailure`
- i18n `zh-CN.json:5057`: "登录暴力破解保护 / 在同一 IP 多次失败后，对 /api/auth/login 进行限流和锁定。" → 此默认开(`bruteForceProtection !== false`)

即 OR 后台**本身已抗暴破**: bcrypt 抗离线撞库 + IP 锁定抗在线撞 + JWT 防 session 伪造。

### 3.2 那 gate 再叠 Basic Auth 多余否?

**不多余**, 非为"密码强度", 是为"暴露面收敛 + 网关兜底":

1. **`INITIAL_PASSWORD` bcrypt 仍允许请求打到 OR 进程** — 每次撞库消耗 loginGuard 配额 + 写 audit log + Zod + bcrypt(慢但占 CPU)。gate Basic Auth **在网关层就 401 拒错凭据**, 错请求**根本不到 OR**。
2. **`GATE_ADMIN_TOKEN` 空/短时后台全 404** — 连 `/api/auth/login` 路径都不可达。暴破者**连撞库入口都探不到**(不泄露后台存在)。`INITIAL_PASSWORD` 单独做不到: OR 在跑, login 端点总暴露, 暴破者知 URL 即撞。
3. **§7 网关接线段**: "gate 后台关 = `/api/*` 全 404" — 正是把 OR 后台从"开着的门"变"藏着的门"。
4. **gate 正是 OR loginGuard 注释假设的那层 reverse-proxy** — OR 设计时假定前面有网关兜分布式撞库(单进程内存 Map 抗不住分布式)。砍 gate = 拆掉 OR 自己假设的防线。

### 3.3 ≥16 阈值是哨兵非过度

`openssl rand -hex 16` = 32 字符已远超够。`ADMIN_TOKEN_MIN_LEN=16` **不为安全**(16 字符随机串已抗暴破), 是**防误设空/占位**(`""`/`CHANGEME`/`123`/`test`/`admin` 这类)。即纯哨兵判, 非安全门。与 `INTERNAL_PSK` 同样 `.length < 16` fail/禁(§7) 哲学一致。

### 3.4 结论(已修正, 见 §8 — gate Basic Auth 已砍)

- 叠 `GATE_ADMIN_TOKEN` 这层**非过度谨慎** — 它管暴露面收 404, OR `INITIAL_PASSWORD` 不能替。
- ≥16 阈值**合理哨兵非过度** — 防误设占位; 16 不偏严, 与 PSK 同哲学。
- **(原判)无可砍冗余处**: 两闸各管一面(gate=暴露面收 404 + 网关兜暴破 / OR=凭证验 session), 正交不重复。

**§8 修正**: gate 层的"网关兜暴破"(Basic Auth)在 2026-07-23 Restart 实战后因浏览器原生 Basic Auth 框反复弹弊大于利被 Supreme 砍除。`GATE_ADMIN_TOKEN` 退为纯暴露面哨兵(§8), 暴破兜底取消, gate 层仅剩"存/否定后台是否暴露 404" 一责。论证 §三.2 第 4 点"gate 正是 loginGuard 假设的 reverse-proxy" **由 Basic Auth 改为暴露面 404** 实现 — 暴破者连后台路径都探不到仍是 gate 的职责, 但若 token 已设(后台开), 撞库就交 OR 自身 loginGuard 5次/15min IP 锁 + bcrypt 抗。

---

## 四、砍 `ADMIN_ENABLED`+`ADMIN_TOKEN_MIN_LEN` 回内联(本次落定)

### 4.1 动机

Supreme 准: 现 gate.js 留两具名 const(`ADMIN_TOKEN_MIN_LEN=16` line 30 + `ADMIN_ENABLED = GATE_ADMIN_TOKEN.length >= ADMIN_TOKEN_MIN_LEN` line 51)作中间层。质疑是否多此一举 — 判式内联省具名层。

### 4.2 改前

```js
const ADMIN_TOKEN_MIN_LEN = 16;                                   // line 30
...
const ADMIN_ENABLED = GATE_ADMIN_TOKEN.length >= ADMIN_TOKEN_MIN_LEN;  // line 51
if (process.env.GATE_ADMIN_TOKEN && GATE_ADMIN_TOKEN.length < ADMIN_TOKEN_MIN_LEN) {
  console.error(`[gate] WARN: ... <${ADMIN_TOKEN_MIN_LEN}, ...`);
}
console.log(`[gate] admin UI: ${ADMIN_ENABLED ? 'enabled' : 'disabled'} ...`);
...
if (!ADMIN_ENABLED) return res.status(404).end();                // 暴露面中间件
if (!ADMIN_ENABLED) return next();                               // Basic Auth 中间件
```

### 4.3 改后(内联)

```js
// 删的两行 const 不再
if (process.env.GATE_ADMIN_TOKEN && GATE_ADMIN_TOKEN.length < 16) {
  console.error(`[gate] WARN: ... <16, 后台关闭 ...`);
}
console.log(`[gate] admin UI: ${GATE_ADMIN_TOKEN.length >= 16 ? 'enabled' : 'disabled'} ...`);
...
if (GATE_ADMIN_TOKEN.length < 16) return res.status(404).end();   // 暴露面
if (GATE_ADMIN_TOKEN.length < 16) return next();                  // Basic Auth
```

### 4.4 落定 Edit

1. 删 `const ADMIN_TOKEN_MIN_LEN = 16;`(原 line 30)
2. 删 `const ADMIN_ENABLED = ...`(原 line 51), 同段 WARN/log 改内联判式
3. 暴露面中间件 `!ADMIN_ENABLED` → `GATE_ADMIN_TOKEN.length < 16`
4. Basic Auth 中间件 `!ADMIN_ENABLED` → `GATE_ADMIN_TOKEN.length < 16`
5. 注释 3 处对齐: "ADMIN_ENABLED 时" → "GATE_ADMIN_TOKEN 有效(≥16)时"

### 4.5 验全绿

- `node --check` 语法 OK
- `grep "ADMIN_ENABLED|ADMIN_TOKEN_MIN_LEN"` 无残留(两 const + 注释全清)
- 行数: 455 → **453**(净省 2 行; 原估"3"松, 实 2 — 添的 WARN/log 判式内联占位抵了一行)
- 4 处判点全改 `GATE_ADMIN_TOKEN.length (< 16 | >= 16)` 等价语义
- 冒烟测: 合成 env(`INTERNAL_PSK`/`OMNIROUTE_API_KEY` 均 32 chr A/B 严守 §6) `require` 加载绿, boot 行见 `[gate] admin UI: disabled`(空 token) / 后续可 enable 验

### 4.6 取舍

- **省**: 2 具名 const + 中间布尔层消, 判式直读
- **代价**: `16` 硬编 4 处(current: WARN/x、log/x、暴露面、BasicAuth)。改阈值改 4 处易漏。**但 14 处阈值本不意图改**(哨兵固定值, 非 tunable), 故代价实际不存在
- **语义零变**: `!ADMIN_ENABLED` ≡ `GATE_ADMIN_TOKEN.length < 16`(ADMIN_ENABLED 原就如此派生)

### 4.7 状态

**本地改完未推**(前轮)→ **2026-07-23 Supreme 令"推吧" → 推成**(commit `d23cea32`, 读回 `722a96a0` == 本地 逐字节 cmp PASS)→ **2026-07-23 03:31 Supreme 手动 Space Restart → boot 真态铁证落地**。

---

## 七、Restart 后 boot 真态(Supreme 手动 2026-07-23 03:31:18)

### 7.1 改造生效铁证
```
[gate] admin UI: enabled (开关状态可记, 不记 token).   ← 内联判式 GATE_ADMIN_TOKEN.length>=16 算出 = Supreme 在 Space Secrets 设有效 token
[gate] listening on 0.0.0.0:7860 -> 127.0.0.1:20128
```
- 新内联版 log 落, 语义对(原 `ADMIN_ENABLED ? ...:...` 换 `GATE_ADMIN_TOKEN.length>=16 ? ...:...`)
- express 无 `MODULE_NOT_FOUND`(B2 预装 `gate 依赖就绪` 生效)
- 无二次 boot = 无 crashloop, 新版真稳态

### 7.2 完整健康签名(saga 闭环态全复现)
- OR: Next.js 16.2.9 Ready, version 3.8.43, 20128
- init: 6 alive / 2 auth_dead(403), nim-01/02/05/06/07/08 注册, **Resilience 读回 RPM=210 concurrent=18 minMs=285 maxWaitMs=300000 全字段一致**(K3 verdict 判据源)
- 9 模型 available / 118 available, combo upsert nim-pool/nim-codex PUT 200
- litestream R2 bucket omn-data sync-interval 10s 正常
- M7 外科单注 `STREAM_READINESS_TIMEOUT_MS=180000`
- init `rc=0` 正常完成 + `HF Dataset uploaded.`(C1 治本write scope + C2 fail-open 闭环保持)

### 7.3 ⚠ 一新现象待查源: `/api/auth/login` 连串 client_close

```
POST /api/auth/login ... errorCode=ECONNRESET abortSource=client_close
destroyInitiator=client elapsedMs≈1 httpStatus=null
msg=admin_client_disconnected_proxy_aborted
```
**时间窗**: 03:31:55~03:34:31, 连串 20+ 条, 约 1s 间隔。

**判读**:
- `admin_client_disconnected_proxy_aborted` + `abortSource=client_close` + `elapsedMs=1~2` + 上游 `httpStatus=null` → **client 立即断, 请求未达 OR 即被关**
- 这是新代码路径 **proxyAdmin** 诊断日志正常打印 — "后台开 + Basic Auth 过 + 透传 OR 时 client 先关"。gate 无错, 是 client 行为
- **来源推测**: `GATE_ADMIN_TOKEN` enabled 暴露了 `/api/auth/login` 这条路。**原白名单版此路径不在 ADMIN_API_ROUTES → 直接 404 不透传, 故无此日志**。现单开关全路径透传 = 更多 admin 路径暴露 + 被探
- 这正**印证 §三论证**: gate 层是 OR loginGuard 假设的配套兜底层, 这些撞库请求现在被 gate 在网关层记, 非打到 OR 消耗 loginGuard 配额 + bcrypt + audit log

### 7.4 风险评估
- 几乎无害: `elapsedMs=1` = client 立即断未造 OR 负载(loginGuard 都没记, 请求没到 OR)
- 撞库面已封: gate Basic Auth 拦错凭据 → 错请求不到 OR; 持对凭据才透传 → 再交 OR 自身 loginGuard(5次/15min 锁) + bcrypt + JWT 兜
- **来源待 Supreme 确**: (a)手动试 admin UI(浏览器并发探活/取消致连串关闭) (b)HF Space ingress 自身探 `/` (c)某探活脚本 (d)外网撞库扫描。若(a)人为 = 正常无需动; 若(d) = gate+loginGuard 双闸已封, 可观察频率是否持续/加 IP 级限。

### 7.5 结论(已修正, 见 §7.6)
gate.js 单开关+内联版(453 行)推送落地 + restart boot 真稳态闭环。`/api/auth/login` 连串 client_close **原判为"预期诊断日志非崩溃" — 此判读已被下一轮根因排查推翻(§7.6)**。

### 7.6 ⚠ 推翻 §7.3 判读 + client_close 根因锁 + 修复落地(2026-07-23)

**原判错**: §7.3 说 `client_close` 是 "client 行为, gate 无错", 推测来源撞库扫描。**事后 Supreme 反馈 "设定的 INITIAL_PASSWORD 在后台输入后进不了, 也无任何提示" + "已删所有备份重设 INITIAL_PASSWORD 仍进不去" 推翻此判** — 真病在 gate 自身, 非外部撞库。

**根因锁**(上游 `omniroute-3.8.43` 源码 + gate 日志铁证对照):
- gate.js proxyV1.line277 + proxyAdmin.line386 各一行:
  ```js
  req.on('close', () => { clientAborted = true; cleanup(); });
  ```
- **机制**: Node 对 `IncomingMessage`(req 流)在**请求体读完**后正常 emit `'close'` 事件 — 这是流结束的**正常信号**, 非 client 真断开。旧 handler 无条件把 'close' 当 client abort → `clientAborted = true` → `cleanup()` → `upstreamReq.destroy()` 掐断去 OR 的连接。
- **暴雷场景**: 浏览器 POST `/api/auth/login` body=`{"password":...}` ~20 字节, 1ms 发完 → gate req emit 'close' → 前结束。OR 此刻在 `route.ts:125 await verifyManagementPassword(password, storedHash)` → `bcrypt.compare`(`SALT_ROUNDS=12`, 慢 100-300ms) → **bcrypt 慢于 body 读完 'close' 触发** → 连接被 gate 掐断 → OR 没机会回 200/401 → 浏览器收 ECONNRESET → **无提示进不去后台**。
- **日志铁证吻合**: `msg=admin_client_disconnected_proxy_aborted` + `abortSource=client_close` + `httpStatus=null`(代码 `code = clientAborted ? null : ...`) + `elapsedMs≈1`(body 读完 ≈1ms 触发)。全部字段值与机制预测一致。
- **反证排除 OR/DB/env 病**: init 脚本内 `[init] Logged in.` = curl **直连 127.0.0.1:20128 绕过 gate** 登 OR 成功 = env 确到 OR + DB 密码对。删备份重设 INITIAL_PASSWORD 无效 = 病不在 OR/DB/env。`/v1/chat/completions` SSE 响应快回头(proxyV1 同缺陷)不暴雷 = 因其响应快于 body 读完掐断, 仅 admin login "短 body + 慢 bcrypt" 暴雷。

**修复**(落地):
- 删两处 `req.on('close', ...)` — body 读完正常 'close' 不该判 abort。
- 添 `res.on('close', () => { if (!res.headersSent) { clientAborted = true; cleanup(); } })` — 仅响应头**未发**(client 在收到响应前跑路)才掐 upstream; 响应已开始流式(`headersSent=true`)→ client 自然关不算 abort。
- 真client 中途断由保留的 `req.on('aborted')` + `req.on('error')` 兜。

**落定数据**:
| 项 | 值 |
|---|---|
| 行数 | 453 → 461(净+8: 删 2 行 + 添 14 行含两段 6 行注释) |
| 语法 | `node --check` OK |
| diff(remote vs local) | 干净仅两处 + 注释, 无意外改 |
| 推 commit | `2e9ad7e0d35ecd242f9a7d4dde32fc7fa996d34b` |
| 远端 sha | `722a96a0`(单开关内联版)→ `18bb1666`(client_close 修复版) |
| 读回验 | sha == 本地, `cmp` 逐字节 PASS |

**剩**: Supreme 手动 Space Restart → boot 看新版生效 → 判浏览器 `/api/auth/login` 登录通否(预期无 `client_disconnected_proxy_aborted`, bcrypt 期间不被掐, 有响应进后台 = 真闭环)。

**续:Restart 后登录通了, 但浏览器原生 Basic Auth 框反复弹**(Supreme 反馈)。框弹时机 Supreme 未细分, 但裁决明确: **保留 GATE_ADMIN_TOKEN 但无需输它登录**。框反复弹的根因机制推测(未实证到单条 401+WWW-Authenticate 记录, 但方向 Supreme 已定): browser 原生 Basic Auth 框在 SPA 后台多子请求/多 path/realm 分区场景下难稳定缓存凭据, 体验差(无登出按钮/无可控重挑), 弊大于利。

---

## 八、砍 Basic Auth — GATE_ADMIN_TOKEN 退为纯哨兵(2026-07-23, Supreme 裁决)

### 8.1 决策

Supreme: "可以保留 GATE_ADMIN_TOKEN, 但无需 auth 输入 GATE_ADMIN_TOKEN 登录。" 即 `GATE_ADMIN_TOKEN` **仅作暴露面开关**(≥16 后台开 / `<16` 全 404), 不再作入口认证。后台写执行认证**全交 OR 自身** `INITIAL_PASSWORD`(bcrypt) + `loginGuard`(5次/15min IP锁) + JWT session。

### 8.2 改动(砍 Basic Auth 整段)

1. 删 `const ADMIN_REALM = 'OmniRoute Admin'` const
2. 删 `adminBasicAuthOk(req)` 函数(14 行: Basic 头解析 + user=admin + timing-safe 比密码)
3. 删 Basic Auth 中间件块(13 行: 401 + `WWW-Authenticate` 头 + `delete req.headers.authorization`)
4. 开关注释改: "兼任开关 + 入口认证" → "仅作暴露面开关, 不作入口认证"; 明标 "不弹 Basic Auth 框, 后台写执行认证全交 OR"
5. 暴露面中间件注释改: "经 Basic Auth" → "直放行透传 OR (无 Basic Auth)"

保留: `safeEqual`(仍服务 `/v1` PSK 校验 line 183); `GATE_ADMIN_TOKEN.length (<16 | >=16)` 四处判式(开/关暴露面 + WARN/log)。

### 8.3 落定数据
| 项 | 值 |
|---|---|
| 行数 | 461 → 435(净 -26: 删 const 1 + 函数 14 + 中间件 13 + 注释净 +约2) |
| 语法 | `node --check` OK |
| Basic Auth 残留 | 零(`adminBasicAuthOk`/`ADMIN_REALM`/`WWW-Authenticate`/`delete req.headers.authorization` 全清) |
| `safeEqual` 仍用 | `/v1` PSK 校验(line 183) |
| client_close 修复段 | 未受扰(`req.on('close')`→`res.on('close')` 对比 diff 未显该段 = HEAD 与 local 一致) |
| 推 commit | `be2bebd2d48dcc0452d7e7713ec385b5c2269601` |
| 远端 sha | `18bb1666`(client_close 修复版)→ `d577be47`(砍 Basic Auth 版) |
| 读回验 | sha == 本地, `cmp` 逐字节 PASS |

### 8.4 安全面变化(须记)

- **砍前**: gate = 暴露面 404(门藏) + Basic Auth 兜暴破(门外挡)。任何撞 OR login 端点者须先过 gate Basic Auth。
- **砍后**: gate = 仅暴露面 404(门藏)。后台开启(token≥16)时任何能访 HF Space URL 者**直撞 OR `/api/auth/login`** → 全靠 OR 自身 `INITIAL_PASSWORD` bcrypt + loginGuard(5次/15min IP锁) + JWT session 抗暴破。
- **取舍理由**: browser 原生 Basic Auth 框反复弹不可控 + 体验差(无登出按钮), OR 自身 loginGuard + bcrypt 已足够抗在线撞库(bcrypt 拖慢 + IP 锁) + 抗离线撞库(bcrypt), 故砍 Basic Auth 净增可用性, 安全降级可接受(dev 空间)。
- **若将来需重加兜底**: 不复活浏览器 Basic 框, 改用无浏览器框的头验(自定义 `X-Admin-Token` 前端脚本注入) 或 gate 层 IP 级速率限。

### 8.5 剩(新)

Supreme 手动 Space Restart → 试后台:
- 预期 boot 仍 `[gate] admin UI: enabled`(token ≥16 不变)
- 浏览器访后台**无 Basic 框**直进
- 首次见 OR 登录页 → 输 `INITIAL_PASSWORD` → OR 设 session cookie → 进后台, 不再重弹任何框

---

## 九、GATE_ADMIN_TOKEN → GATE_ADMIN_ENABLED 纯布尔开关(2026-07-23, Supreme "直接删了 GATE_ADMIN_TOKEN 用01变量")

### 9.1 动机

砍 Basic Auth(§八)后 `GATE_ADMIN_TOKEN` 退为纯哨兵: 仅判 `process.env.GATE_ADMIN_TOKEN.length >= 16` 当布尔用(不验密/不转发/不弹框)。圣上质: 既然已退纯布尔语义, `>=16` 长串值守是曲折表达, 距纯 `0/1` 布尔一步, 应简化 + 少持一长串 secret 守值(§3 secret 纪律更轻)。

### 9.2 是否补安全面? 决策与论证

圣上先问 "搜索查证安全面不降级的办法"。基于 OWASP Authentication Cheat Sheet(fail-closed 账户锁 + MFA 最强, IP 级可多IP绕) + express-rate-limit 权威用法(CDN d.ts 验证), 呈三方案:
- **A. cookie session 闸**(gate 自管后台 session, HMAC-GATE_ADMIN_TOKEN 签 cookie 防重登) — 真不降级但 ~60行 + 双登录 + 6 处 bug 面(cookie 属性/CSRF/HMAC 时序/SPA 子请求拦截), 迭代成本高
- **B. IP 限速**(~30行低 bug) — 但 OWASP: IP 级可多IP绕, 且与 OR loginGuard(IP 5/15)同维度重叠, 非凭据级真兜底
- **C. 头验 X-Admin-Token** — 不适 OR web 后台 SPA 页浏览

圣上问 "A 会不会很麻烦/出错引其他bug?" → 诚实答: 是, A 最繁最易出新 bug(双层登录串扰 + SPA 子请求拦截面 + cookie 属性)。圣上遂定: **"还是这样吧, 就简单加个 admin 登录变量开关, 开时什么也不用, 关时安全面打满"** = 不补兜底, 用纯布尔开关表达开/关态即可。安全面取舍同 §八.4(靠 OR 自身 loginGuard+bcrypt+JWT 抗, dev 可接受)。

### 9.3 改动(纯布尔替换, 安全面零新变)

1. `const GATE_ADMIN_TOKEN = process.env.GATE_ADMIN_TOKEN || ''` → `const ADMIN_ENABLED = process.env.GATE_ADMIN_ENABLED === '1'`(显判, 仅确置 '1' 开; 未设/'0'/空/任意他值均关, 保守 fail-closed)
2. 删 WARN 块(`length < 16` 哨兵判式失效)
3. log: `${GATE_ADMIN_TOKEN.length >= 16 ? ...}` → `${ADMIN_ENABLED ? ...} (GATE_ADMIN_ENABLED 开关状态)`
4. 暴露面中间件: `if (GATE_ADMIN_TOKEN.length < 16) 404` → `if (!ADMIN_ENABLED) 404`
5. 头注 5-13 三处注释更新: 去旧 Basic Auth 描述, 写 "无闸直透传 / 关时全 404 门藏"

### 9.4 落定数据
| 项 | 值 |
|---|---|
| 行数 | 435 → 430(净 -5: 删 WARN 块 3 + token const 注释收 1) |
| 语法 | `node --check` OK |
| `GATE_ADMIN_TOKEN` 残留 | 零(9 处全清) |
| `ADMIN_ENABLED` 引用 | 8 处(const + log + 暴露面 + 注释) |
| client_close 修复段 | 未扰(diff 未显该段 = HEAD 与 local 一致) |
| 推 commit | `5309dc0560f45de591bfdff4d7f059f5eb69d019` |
| 远端 sha | `d577be47`(砍 Basic 版)→ `d187a967`(纯布尔版) |
| 读回验 | sha == 本地, `cmp` 逐字节 PASS |

### 9.5 零空窗(Supreme 先改 Secrets)

推送顺序风险: 若先推代码(期待 `GATE_ADMIN_ENABLED`)而 Space Secrets 仍只有 `GATE_ADMIN_TOKEN` → boot 判 `GATE_ADMIN_ENABLED !== '1'` → 后台关全 404(空窗期, /healthz + /v1 API 健康不受影响, 仅后台诊断期难进)。Supreme **先改 Space Secrets**(`GATE_ADMIN_ENABLED=1` 就位), 再推代码 → **零空窗**, Restart 即生效。

### 9.6 最终语义(后台开关态)

| env 态 | 行为 | 安全 |
|---|---|---|
| `GATE_ADMIN_ENABLED=1`(开) | 后台全路径**无闸**直透传 OR | 最低(靠 OR loginGuard+bcrypt+JWT; 圣上自选免闸) |
| 未设 / `0` / 空 / 任意非 `'1'`(关) | **全路径 404**, OR 不可探 | 打满(门藏 + 隔绝, 外网碰不到 OR) |

### 9.7 剩

Supreme 手动 Space Restart → boot 见 `[gate] admin UI: enabled (GATE_ADMIN_ENABLED 开关状态)` → 浏览器后台无任何框直进 OR 登录页输 `INITIAL_PASSWORD` 进。

---

## 五、§边界遵守全审

- 双空间铁律: 仅改 dev(di omn-logic/gate.js), nomn 生产零触
- secret 纪律: 本档 + 代码零写 token 值; 冒烟测合成 chr 串; 记录只位置不值
- 自验纪律(§6): 测试合成 chr 拼接构造, 严禁真 key/类真 PSK 入会话
- upstream 只读(§5): 仅读 omniroute-3.8.43 源码佐证, 不改不运行不入生产
- 基座裁决(§5): gate.js 为本地逻辑层件, 不涉 3.8.43/3.8.49 基座迁移, 无回退/升级风险
- 未 push 任何 GitHub remote(审计仓无 origin); Space Restart 未触(Supreme 手动)

---

## 六、关联

- [[gate-js-single-switch-admin-landed]] — 前轮 520→455 单开关砍白名单(本档续其砍具名层)
- [[omn-v4.3.2-r3-k3-stream-readiness-maxwait]] — saga 闭环后续改链
- audit/2026-07-23-crashloop-saga-landed.md — 双期 crashloop 闭环(改 gate 链风险源)
