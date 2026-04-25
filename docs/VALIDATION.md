
原因：把踩坑记录从 README 中剥离，形成可检索的故障手册。  
实测证据：`1.3.0.txt` Line 6102 记录 `nim-pool` 被误解析成 openai；Line 6179 记录空 Combo 问题；Line 7194 记录 `models` 为空；Line 7593 记录正确路由成功；Line 9163 记录模型目录显示问题根因。

---

#### **PATCH-MD-D**

文件：`docs/VALIDATION.md`  
操作：插入（新建文件）  
位置：文件起始处  
来源类型：实测  
实测证据：`1.3.0.txt` Line 6001、6024、7593、8467；当前对话摘要中的 14 轮 round-robin 结果。

```markdown
# Validation Record

本文档记录 `nim-omniroute-gateway` GitHub `v1.0.0` 基线的实测证据。

定稿日期：2026-04-25

## 1. 部署启动验证

实测日志显示：

```text
[entrypoint] OmniRoute ready after 2s
[init] logged in, token acquired
[init] setupComplete PATCH → HTTP 200
[init] nim-01 registered (HTTP 201)
...
[init] nim-25 registered (HTTP 201)
[init] NIM Keys: 25 registered, 0
[init] NIM Keys: 25 registered, 0 skipped
[init] applying Resilience config...
[init] Resilience PATCH → HTTP 200
[init] first-time init: creating Combo nim-pool...
[init] Combo nim-pool → HTTP 201
[entrypoint] starting gate on 0.0.0.0:7860
