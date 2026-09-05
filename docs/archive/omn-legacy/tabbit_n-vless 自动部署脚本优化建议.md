### **这篇文档说对了一半**

文档的核心观点"10007 是伪报错，Worker 代码已上传成功"是对的。但它说"直接忽略，节点已经通了"是错的——你的实际经历已经证明了：1、9、0 三个账号 Worker 存在、Secret 设置成功，但 custom domain 路由为空，访问就是 `ERR_CONNECTION_CLOSED`。

原因很简单：wrangler 在 subdomain API 报 10007 后直接退出（exit code 1），**custom domain 绑定这步从未执行**。`continue-on-error: true` 只是让 workflow 不中断，但 wrangler 内部已经停了，后面的 custom domain 绑定不会补执行。

### **为什么 `daily` 跑完 7 个通 3 个不通**

`daily` 是单 pass，wrangler 只跑一次。10007 是概率性的——CF 边缘数据库同步快慢不同，有时 wrangler 查 subdomain 时数据已就绪就不报错，custom domain 正常绑定；有时没就绪就 10007 退出，custom domain 没绑上。7 个通了是运气好，3 个不通是赶上了同步延迟。

### **修复方案：两层保险**

**第一层**——wrangler.toml 加 `workers_dev = false`，让 wrangler 跳过 subdomain API 调用：

```bash
          echo "name = \"$WNAME\""                    > wrangler.toml
          echo "main = \"$ENTRY\""                   >> wrangler.toml
          echo "compatibility_date = \"2025-01-01\"" >> wrangler.toml
          echo "workers_dev = false"                 >> wrangler.toml
          echo ""                                    >> wrangler.toml
          echo "[[routes]]"                          >> wrangler.toml
          echo "pattern = \"$WSUB\""                 >> wrangler.toml
          echo "custom_domain = true"               >> wrangler.toml
```

**第二层**——在 Verify 步骤里增加 custom domain 路由检查，如果没绑上就手动用 CF API 补绑。在现有的存在性校验之后、关闭 subdomain 之前，插入：

```bash
          # ── 检查 custom domain 路由是否绑定 ───────────────────
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
```

这段逻辑是：先查 Worker 的 routes 列表，如果 `WSUB`（如 `1.w01.cc.cd`）不在里面，就用 CF API 手动绑定。需要 CF Token 有 `Zone:Read` 和 `Worker Routes:Edit` 权限——你的 Token 如果是 Cloudflare 通用 API Token 应该都有。

### **关于脚本里那条旧注释**

原脚本注释写着 `不在 wrangler.toml 里写 workers_dev = false（会触发 10007）`。这个判断在旧版 wrangler 上可能成立，但 wrangler 4.x 的行为已经变了——不写 `workers_dev = false` 时它**主动调用** subdomain API 尝试启用，对没注册 subname 的账号必然 10007。写了之后它**跳过**这个调用，反而不会报错。

### **操作步骤**

1. 改 wrangler.toml 加 `workers_dev = false`
2. 在 Verify 步骤插入 custom domain 路由检查和补绑逻辑
3. 跑 `delete:all` 清空所有账号
4. 跑 `daily` 全量部署
5. 检查日志——每个账号应该出现 `Custom domain route: OK` 或 `Custom domain binding: HTTP 200`，不再有 10007

*内容由 AI 生成仅供参考*