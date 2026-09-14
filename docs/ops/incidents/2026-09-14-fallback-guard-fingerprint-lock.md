# Incident 2026-09-14 · cron 全线秒 502(指纹会话被 fallback guard 永久锁死)

**窗口**:2026-09-13 ~05:30(UTC)→ 2026-09-14 08:30(UTC),约 27 小时
**影响**:hermes cron eval-gate / 所有无 X-Session-Id 的 batch 客户端 → cron tick 全挂、外部 CI 脚本全挂
**修复路径**:gate.js 两次 commit → GHA sync bucket → Space 手动重启
**最终状态**:已恢复 + 已加固

---

## 一、症状

- hermes cron eval-gate 从 09-13 11:30(北京)起全部 tick 立即报 `HTTP 502 ×Cloudflare-5xx/omn`
- **响应用时 0.1s 级**,说明请求根本没有发到 NVIDIA 上游——**就在 omn 入口被本地拒绝**
- 直接相同 hermes session 交互式 session 却能调通(当时先用 dp4f 没切 omn,所以有干扰)

## 二、根因(negotiated)

omn gate 的 fallback_guard 为方便防"重放风暴",会对 `resolveSessionKey` 算出来的 session key 记账。session key 的取法:

1. X-Session-Id header → `h:...` (**显式**,真实客户端才会给)
2. body.session_id → `b:...` (显式)
3. body 前两条 messages 指纹 → `m:...` (**指纹兜底**,多客户端会折叠成同一个)
4. X-Forwarded-For + path → `f:...` (**指纹兜底**,以上都没有时才走)

hermes cron spawn agent 调 LLM 时**没带任何 X-Session-Id**,所以所有 tick、所有 spawn agent 的请求都落在 `m:`(指纹) 那一个头上。一旦连续 3 次上游抖动(NVIDIA 偶发空响应或 5xx),`canSessionAttempt` 就把这个 key 标 deny;**旧的 `policy-guard.js` 里 denied 状态没有老化**,会永远黏住直到进程重启。

于是 cron 每次 tick 都撞上同一个"被锁"的 `m:` 账本,立即 502,问都不用问上游。

## 三、修复(commit)

### adaffbc — #17: 指纹会话不再锁

```
if (fgGuardApplies && req._fgSessionKey && fgCanLock) {
   // fgCanLock = req._fgSessionKey 以 'h:'/'b:' 开头
```

- 只有 `h:`/`b:` 显式会话允许进入 `canSessionAttempt` 拒流;`m:`/`f:` 指纹会话永不锁定
- 账本继续记(未删 audit),只是永不拒

参考:逻辑、注释、解释见 `logic/gate.js` 内 `#17` 块

### c2b5480 — #18: 指纹会话不再记 failure

仅"不锁"还不够——**记账本身会污染共享账本**,未来如果再放开锁,这个历史失败数还在。

```
function fgExplicitSession(sessionKey) { ... }  // h:/b: true, m:/f: false
```

- `recordFallbackOutcome`(退化空响应):对 `m:`/`f:` 不记 failure,只 log
- fallforward path 4xx/5xx:对 `m:`/`f:` 同样不记
- `fgCanLock` 改用同一 util

### 部署

1. push n-omn main → GHA `sync-logic-xnexus.yml` 自动同步 `logic/gate.js` 到 `xnexus/logic` Bucket(实测:bucket sha256 匹配 git commit)
2. Space **不会自动重启**,要 POST `/api/spaces/xnexus/o/restart`(HF token+ 200 OK)
3. 5 min 后验证:无 X-Session-Id 相同请求连续两次 200(36s/33s 都是真实 NVIDIA 时延,不是门)

## 四、事后余项

- **`PR_SUMMARY.md`** 仓根是重复档,真档在 `docs/self-improvement/PR_SUMMARY-cases-pool-20260911.md`,根的这份删掉(本次 commit 一并)
- **`GATE_UPSTREAM_TIMEOUT_MS`** 已是 180000ms,不动
- **hermes spawn agent 加 X-Session-Id**:不需要了——指纹会话现在根本不能锁住
- **hermes cron deliver=telegram spawn agent 无 token**(`[blocked_config]`):单独的 hermes bug,本次未修;eval-gate cron 临时 deliver=local

## 五、验证证据

```
2026-09-14 15:47(北京) 验证请求(无 X-Session-Id):
  #1 → http=200 t=36.37s
  #2 → http=200 t=33.03s
```

bench hermes cron:
```
4dc91160cefe  k3 + omn, */15
  06:45 UTC  completed ← Space 重启后第一个 tick,全 evaluate
  07:00/07:15/07:30  完成(Space restart 打断 07:30 那个)
  08:00/08:15          完成
  08:30+              稳定
```

## 六、对上述自评(诚实声明)

- **是我诊断**(看 gate.js policy-guard.js`canSessionAttempt` L243 denied 黏住注释,动手前已知道这是个雷)
- **是我动手** push 两次 commit、触发 GHA、调 restart API
- **是我验证**(Space 重启 + 连续 200)
- user Zen 裁定"全做"→ 除上做之外只剩配置面杂项,均不必要或不对称

结论:此类错误对应修复可以复用——凡是多客户端**共享身份**(no session id)+ 记账系统的,判定锁定前必须能区分"这是不是一个真的客户端"。
