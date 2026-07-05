| 变量名 | 类型 | 必需 | 说明 |
| --- | --- | --- | --- |
| CLIENT_TOKEN | Secret | 是 | 客户端访问 Worker 的 Bearer Token |openssl rand -hex 32
| INTERNAL_PSK | Secret | 是 | Worker 转发到 gate.js 的内部 Bearer Token |与 HF Space 同一个值
| UPSTREAM_BASE | Variable | 是 | HF Space gate 地址，不带尾斜杠 |https://3t2y-a.hf.space
| WECOM_WEBHOOK | Secret | 否 | 企业微信告警 Webhook |
| RESEND_API_KEY | Secret | 否 | Resend 邮件告警 API Key |
| ALERT_EMAIL_FROM | Variable | 否 | 告警发件邮箱 |
| ALERT_EMAIL_TO | Variable | 否 | 告警收件邮箱 |
| STATE | KV Binding | 建议 | 用于滑动窗口统计、dedupe、告警状态 |

