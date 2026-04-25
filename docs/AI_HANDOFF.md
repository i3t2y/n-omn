
原因：`VALIDATION.md` 的作用是把“已经跑通过”的证据固化，未来发版、回滚、AI 接手时不用重新猜测哪些步骤真的验证过。  
实测证据：`1.3.0.txt` Line 6001 记录完整启动与注册日志；Line 6024 记录验证表；Line 7593 记录 `nim-pool → nvidia → meta/llama-3.3-70b-instruct` 成功；当前对话摘要记录 14 轮 round-robin 结果。

---

#### **PATCH-MD-E**

文件：`docs/AI_HANDOFF.md`  
操作：插入（新建文件）  
位置：文件起始处  
来源类型：当前对话工作流约束 + 实测 + 官方文档  
实测证据：`1.3.0.txt` Line 6001、6024、7593、8467、9163、9182；当前对话摘要确认 GitHub `v1.0.0` 基线和生产/实验模型池分离。

```markdown
# AI Handoff

本文档给无上下文 AI 使用。任何新会话接手 `nim-omniroute-gateway` 时，必须先读本文档，再读 `README.md`、`docs/DECISIONS.md`、`docs/TROUBLESHOOTING.md`、`docs/VALIDATION.md`。

## 0. 当前唯一基线

GitHub 仓库名：

```text
nim-omniroute-gateway
