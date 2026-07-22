Run # 存在性校验（3 次重试，5s 间隔）
  # 存在性校验（3 次重试，5s 间隔）
  EXISTS=""
  for attempt in 1 2 3; do
    EXISTS=$(curl -s -o /dev/null -w "%{http_code}" \
      "https://api.cloudflare.com/client/v4/accounts/$ACCOUNT/workers/scripts/$WNAME" \
      -H "Authorization: ***")
    if [ "$EXISTS" = "200" ]; then break; fi
    echo ">>> Existence check attempt $attempt: HTTP $EXISTS, retrying in 5s..."
    sleep 5
  done
  if [ "$EXISTS" != "200" ]; then
    echo "ERROR: Worker $WNAME not found (HTTP $EXISTS) after 3 attempts. Deploy truly failed."
    exit 1
  fi
  echo ">>> Worker exists: OK (HTTP $EXISTS)"
  
  # ── Custom domain 路由校验 + 补绑 ────────────────────────
  ROUTES=$(curl -s \
    "https://api.cloudflare.com/client/v4/accounts/$ACCOUNT/workers/scripts/$WNAME/routes" \
    -H "Authorization: ***")
  
  if echo "$ROUTES" | grep -q "$WSUB"; then
    echo ">>> Custom domain route: OK ($WSUB)"
  else
    echo ">>> Custom domain route: MISSING, binding via API..."
    ZONE_ID=$(curl -s \
      "https://api.cloudflare.com/client/v4/zones?name=cc.cd" \
      -H "Authorization: ***" | jq -r '.result[0].id')
  
    if [ -z "$ZONE_ID" ] || [ "$ZONE_ID" = "null" ]; then
      echo "WARNING: Cannot find zone_id for cc.cd — manual binding needed"
    else
      BIND=$(curl -s -o /dev/null -w "%{http_code}" -X PUT \
        "https://api.cloudflare.com/client/v4/accounts/$ACCOUNT/workers/domains" \
        -H "Authorization: ***" \
        -H "Content-Type: application/json" \
        -d "{\"hostname\":\"$WSUB\",\"service\":\"$WNAME\",\"zone_id\":\"$ZONE_ID\"}")
      echo ">>> Custom domain binding: HTTP $BIND"
    fi
  fi
  
  # 主动关闭 workers.dev subdomain
  CLOSE=$(curl -s -o /dev/null -w "%{http_code}" -X POST \
    "https://api.cloudflare.com/client/v4/accounts/$ACCOUNT/workers/scripts/$WNAME/subdomain" \
    -H "Authorization: ***" \
    -H "Content-Type: application/json" \
    -d '{"enabled":false}')
  echo ">>> Disable subdomain: HTTP $CLOSE"
  
  # 读回验证
  RESULT=$(curl -s \
    "https://api.cloudflare.com/client/v4/accounts/$ACCOUNT/workers/scripts/$WNAME/subdomain" \
    -H "Authorization: ***")
  echo ">>> Subdomain status: $RESULT"
  
  if echo "$RESULT" | grep -q '"enabled":true'; then
    echo "WARNING: workers.dev is still enabled!"
  else
    echo "OK: workers.dev is disabled"
  fi
  shell: /usr/bin/bash -e {0}
  env:
    TOKEN: cfut_606AnWfS9gkd6AO5Fnl6MzBdSIXUQzqmeHJl68ixe32a6043
    ACCOUNT: 7641c0db44b927f497c3f78cf481c361
    WNAME: tree-honey-t6
    WSUB: 6.w06.cc.cd
>>> Worker exists: OK (HTTP 200)
>>> Custom domain route: MISSING, binding via API...
WARNING: Cannot find zone_id for cc.cd — manual binding needed
>>> Disable subdomain: HTTP 200
>>> Subdomain status: {
  "result": {
    "enabled": false,
    "previews_enabled": false
  },
  "success": true,
  "errors": [],
  "messages": []
}
OK: workers.dev is disabled

问题找到了。日志里关键两行：

```
>>> Custom domain route: MISSING, binding via API...
WARNING: Cannot find zone_id for cc.cd — manual binding needed
```

补绑逻辑查不到 `cc.cd` 的 zone_id——说明 `cc.cd` 这个 zone 不在当前 Worker 的 CF 账号下，或者 Token 没有 `Zone:Read` 权限。但 wrangler 之前能绑成功，说明 wrangler 内部有自己的处理方式。

### **新方案：不依赖 zone_id，改用重试 deploy**

既然 wrangler 自己能绑 custom domain（之前 7 个账号成功过），问题只是 10007 让它中断了。那解法就是：**等 CF 同步后让 wrangler 再跑一次**。第二次 deploy 时 Worker 已存在，subdomain API 不会报 10007，wrangler 能完整走完 custom domain 绑定。

### **改动：在 1st pass 后加一个无条件重试**

在现有 **Deploy Worker (1st pass)** 和 **Wait for scanner cycle** 之间，插入两个新步骤：

```yaml
      # ── 重试部署：等待 CF 同步后重新 deploy，绑定 custom domain ──
      # 10007 是 CF 竞态：Worker 刚上传，subdomain API 未同步
      # 等 10s 后重试，Worker 已存在，wrangler 能完整绑定 custom domain
      - name: Wait for CF sync
        if: needs.gate.outputs.secrets_only == '0'
        run: sleep 10

      - name: Retry Deploy (bind custom domain)
        if: needs.gate.outputs.secrets_only == '0'
        continue-on-error: true
        uses: cloudflare/wrangler-action@v4
        with:
          apiToken:        ${{ steps.creds.outputs.token }}
          accountId:       ${{ steps.creds.outputs.account }}
          command:         deploy
          wranglerVersion: "4"
```

这两个步骤**无条件执行**，不受 `PASS_MODE` 控制。对 `daily` 模式来说，流程变成：

1. Deploy (1st pass) → 代码上传成功，10007 中断
2. sleep 10 → 等 CF 边缘数据库同步
3. Retry Deploy → Worker 已存在，subdomain API 不报 10007，custom domain 绑定成功
4. Verify → 确认路由 OK

对 `first` 模式，retry 之后还会继续走双 pass 流程（Wait → Delete → 2nd pass），但通常 retry 已经绑好了，双 pass 只是多一层保险。

### **同时修复补绑逻辑的 zone_id 问题**

既然 retry deploy 是主方案，补绑只是兜底。补绑查不到 zone_id 的问题，最简单的解决方式是让用户提供 `cc.cd` 的 zone_id 作为 GitHub Variable。

去 `cc.cd` 所在的 CF 账号，Dashboard → 选择 `cc.cd` zone → Overview 页面右下角能看到 **Zone ID**。然后在 GitHub 仓库 Settings → Variables 新增：

| Variable | 值 |
|---|---|
| `CF_ZONE_ID` | cc.cd 的 Zone ID（一串 32 位十六进制） |

然后改补绑逻辑，从 Variable 读取 zone_id：

```bash
            echo ">>> Custom domain route: MISSING, binding via API..."
            ZONE_ID="$CF_ZONE_ID"

            if [ -z "$ZONE_ID" ]; then
              echo "WARNING: CF_ZONE_ID not set — manual binding needed"
            else
              BIND=$(curl -s -o /dev/null -w "%{http_code}" -X PUT \
                "https://api.cloudflare.com/client/v4/accounts/$ACCOUNT/workers/domains" \
                -H "Authorization: Bearer $TOKEN" \
                -H "Content-Type: application/json" \
                -d "{\"hostname\":\"$WSUB\",\"service\":\"$WNAME\",\"zone_id\":\"$ZONE_ID\"}")
              echo ">>> Custom domain binding: HTTP $BIND"
            fi
```

Verify 步骤的 `env:` 也要加 `CF_ZONE_ID`：

```yaml
        env:
          TOKEN:       ${{ steps.creds.outputs.token }}
          ACCOUNT:     ${{ steps.creds.outputs.account }}
          WNAME:       ${{ steps.creds.outputs.wname }}
          WSUB:        ${{ steps.creds.outputs.wsub }}
          CF_ZONE_ID:  ${{ vars.CF_ZONE_ID }}
```

### **完整操作步骤**

1. 在 GitHub Variables 新增 `CF_ZONE_ID`（从 CF Dashboard 获取）
2. 在 1st pass 后插入 `Wait for CF sync` + `Retry Deploy` 两个步骤
3. 改 Verify 步骤的补绑逻辑，从 `CF_ZONE_ID` 读取（不再查 API）
4. Verify 步骤 `env:` 加 `CF_ZONE_ID`
5. 跑 `delete:all` 清空
6. 跑 `daily` 全量部署

retry deploy 是主方案，应该能解决 10007 导致的路由丢失。补绑是兜底，以防 retry 也失败。两层保险。

*内容由 AI 生成仅供参考*