
原因：DECISIONS.md 用来保存“为什么”，避免 README 被踩坑细节污染，也避免未来 AI 重复推翻已验证结论。  
实测证据：`1.3.0.txt` Line 7593 证明 `nim-pool` 正确路由到 nvidia；Line 9163、9182 证明 `/api/provider-models` 是 Dashboard 模型显示问题的根因修复点。

---

#### **PATCH-MD-C**

文件：`docs/TROUBLESHOOTING.md`  
操作：插入（新建文件）  
位置：文件起始处  
来源类型：实测 + 官方文档 + 当前对话决策  
实测证据：`1.3.0.txt` Line 6102、6179、7194、7593、7643、7650、9163。

```markdown
# Troubleshooting

本文档记录 `nim-omniroute-gateway` 已遇到的问题、根因和处理方法。这里不写架构决策，架构决策见 `docs/DECISIONS.md`。

## 1. gate 日志显示端口或 target 不完整

### 现象

日志中出现类似：

```text
listening :7860
proxying :20128
