这份文档找到了真正的根因，纠正了我上一条回复里"忽略就好"的错误判断。核心问题是：**10007 让 wrangler 在 custom domain 绑定之前就退出了**，`continue-on-error: true` 只是让 workflow 不中断，但路由实际上没绑上。

两层修复整合如下，只改两个步骤。

---

### **修复一：Patch Worker File — wrangler.toml 加 `workers_dev = false`**

在现有 wrangler.toml 生成块中，`compatibility_date` 之后插入一行，让 wrangler 跳过 subdomain API 调用：

```yaml
      - name: Patch Worker File
        if: needs.gate.outputs.secrets_only == '0'
        env:
          MY_PATH:     $
          WNAME:       $
          WSUB:        $
          FAKE_PAGE:   $
          FAKE_URL:    $
          WORKER_FILE: $
        run: |
          CORE="Vless_workers_pages/$WORKER_FILE"

          if [ -z "$MY_PATH" ]; then
            echo "ERROR: MY_WS_PATH is not set. Aborting."
            exit 1
          fi

          echo 'var window = globalThis;' | cat - "$CORE" > /tmp/_patch.js
          mv /tmp/_patch.js "$CORE"

          sed -i "s|let path = '.*'|let path = '/$MY_PATH'|g" "$CORE"

          if grep -q "let path = '/" "$CORE"; then
            echo ">>> Path injected: /$MY_PATH (file: $WORKER_FILE)"
          else
            echo "WARNING: 'let path' pattern not found in $WORKER_FILE"
          fi

          ENTRY="$CORE"

          if [ "$FAKE_PAGE" = "1" ] || [ "$FAKE_PAGE" = "2" ]; then
            echo "import _core from \"./Vless_workers_pages/$WORKER_FILE\";"  > _entry.js
            echo "export default {"                                            >> _entry.js
            echo "  async fetch(request, env, ctx) {"                         >> _entry.js
            echo "    const _u = new URL(request.url);"                       >> _entry.js
            echo "    const _p = '/$MY_PATH';"                                >> _entry.js
            echo "    if (request.headers.get('upgrade') !== 'websocket' &&"  >> _entry.js
            echo "        _u.pathname !== _p && _u.pathname !== _p + '/') {"  >> _entry.js
            if [ "$FAKE_PAGE" = "2" ]; then
              echo "      return Response.redirect(\"$FAKE_URL\", 301);"      >> _entry.js
            else
              _404='<!DOCTYPE html><html><head><title>404 Not Found</title></head><body><h1>404 Not Found</h1><hr/><p>nginx/1.18.0</p></body></html>'
              echo "      return new Response('$_404',{status:404,headers:{'content-type':'text/html'}});" >> _entry.js
            fi
            echo "    }"                                                       >> _entry.js
            echo "    return _core.fetch(request, env, ctx);"                 >> _entry.js
            echo "  }"                                                        >> _entry.js
            echo "};"                                                         >> _entry.js
            ENTRY="_entry.js"
          fi

          # workers_dev = false：让 wrangler 跳过 subdomain API 调用
          # 不写这行时 wrangler 4.x 会主动调用 subdomain API，新 Worker 必然 10007
          echo "name = \"$WNAME\""                    > wrangler.toml
          echo "main = \"$ENTRY\""                   >> wrangler.toml
          echo "compatibility_date = \"2025-01-01\"" >> wrangler.toml
          echo "workers_dev = false"                 >> wrangler.toml
          echo ""                                    >> wrangler.toml
          echo "[[routes]]"                          >> wrangler.toml
          echo "pattern = \"$WSUB\""                 >> wrangler.toml
          echo "custom_domain = true"               >> wrangler.toml
          echo ">>> wrangler.toml:"
          cat wrangler.toml
```

---

### **修复二：Verify 步骤 — 增加 custom domain 路由检查和补绑**

在现有的存在性校验和关闭 subdomain 之间，插入路由检查块：

```yaml
      - name: Verify workers.dev disabled
        if: needs.gate.outputs.secrets_only == '0'
        env:
          TOKEN:   $
          ACCOUNT: $
          WNAME:   $
          WSUB:    $
        run: |
          # ── 存在性校验（3 次重试，5s 间隔）──────────────────────
          EXISTS=""
          for attempt in 1 2 3; do
            EXISTS=$(curl -s -o /dev/null -w "%{http_code}" \
              "https://api.cloudflare.com/client/v4/accounts/$ACCOUNT/workers/scripts/$WNAME" \
              -H "Authorization: Bearer $TOKEN")
            if [ "$EXISTS" = "200" ]; then break; fi
            echo ">>> Existence check attempt $attempt: HTTP $EXISTS, retrying in 5s..."
            sleep 5
          done
          if [ "$EXISTS" != "200" ]; then
            echo "ERROR: Worker $WNAME not found (HTTP $EXISTS) after 3 attempts."
            exit 1
          fi
          echo ">>> Worker exists: OK"

          # ── Custom domain 路由校验 + 补绑 ────────────────────────
          # workers_dev=false 应该已经让 wrangler 正常绑定，这里是第二层兜底
          ROUTES=$(curl -s \
            "https://api.cloudflare.com/client/v4/accounts/$ACCOUNT/workers/scripts/$WNAME/routes" \
            -H "Authorization: Bearer $TOKEN")

          if echo "$ROUTES" | grep -q "$WSUB"; then
            echo ">>> Custom domain route: OK ($WSUB)"
          else
            echo ">>> Custom domain route: MISSING, binding via API..."
            # 查找 cc.cd 的 zone_id
            ZONE_ID=$(curl -s \
              "https://api.cloudflare.com/client/v4/zones?name=cc.cd" \
              -H "Authorization: Bearer $TOKEN" | jq -r '.result[0].id')

            if [ -z "$ZONE_ID" ] || [ "$ZONE_ID" = "null" ]; then
              echo "WARNING: Cannot find zone_id for cc.cd — manual binding needed"
            else
              BIND=$(curl -s -o /dev/null -w "%{http_code}" -X PUT \
                "https://api.cloudflare.com/client/v4/accounts/$ACCOUNT/workers/domains" \
                -H "Authorization: Bearer $TOKEN" \
                -H "Content-Type: application/json" \
                -d "{\"hostname\":\"$WSUB\",\"service\":\"$WNAME\",\"zone_id\":\"$ZONE_ID\"}")
              echo ">>> Custom domain binding: HTTP $BIND"
            fi
          fi

          # ── 关闭 workers.dev subdomain（双重保险）────────────────
          CLOSE=$(curl -s -o /dev/null -w "%{http_code}" -X POST \
            "https://api.cloudflare.com/client/v4/accounts/$ACCOUNT/workers/scripts/$WNAME/subdomain" \
            -H "Authorization: Bearer $TOKEN" \
            -H "Content-Type: application/json" \
            -d '{"enabled":false}')
          echo ">>> Disable subdomain: HTTP $CLOSE"
```

注意 `env:` 块需要新增 `WSUB`，从 `steps.creds.outputs.wsub` 读取：

```yaml
        env:
          TOKEN:   $
          ACCOUNT: $
          WNAME:   $
          WSUB:    $   # 新增
```

---

### **CF Token 权限确认**

补绑逻辑需要两个权限，确认你的 `CF_TOKENS` 包含：

| 权限 | 用途 |
|---|---|
| `Zone:Read` | 查询 `cc.cd` 的 `zone_id` |
| `Worker Routes:Edit` | 调用 `/workers/domains` 绑定 custom domain |

如果 Token 是用 Cloudflare 预设的 **Edit Cloudflare Workers** 模板创建的，这两项默认都有。

---

### **操作步骤**

```
1. 应用以上两处改动并 commit
2. 触发 delete:all  → 清空全部账号的 Worker（避免旧路由冲突）
3. 触发 first（PASS_MODE=2 首次部署）或 daily（快速重建）
4. 查看每个账号的 Verify 步骤日志：
   期望看到 "Custom domain route: OK" 而不是 "MISSING"
5. 确认通了后改回 PRESET=daily + CRON_ENABLE=1
```

---

### **DEPLOY.md Bug 表追加**

| Bug | 位置 | 症状 | 修复 |
|---|---|---|---|
| wrangler 4.x 未写 `workers_dev=false` 时主动调 subdomain API | Patch Worker File | 10007 让 wrangler 在 custom domain 绑定前退出，路由为空，访问 `ERR_CONNECTION_CLOSED` | wrangler.toml 加 `workers_dev = false` |
| Verify 步骤无 custom domain 路由检查 | Verify | 路由未绑定时无感知、无补救 | 增加 routes 查询 + CF API 补绑兜底；Verify `env:` 新增 `WSUB` |

*内容由 AI 生成仅供参考*