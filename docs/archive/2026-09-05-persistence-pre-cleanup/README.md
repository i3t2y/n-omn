# 2026-09-05 持久化大清理·归档层

首席架构师裁: n-omn 持久化/备份链全砍 (litestream→R2, HF Dataset snapshot, capture_loop→Dataset, 归档 daemon, db 健康探针)。
本目录 = 砍前全量快照, 回滚 = 从此拷回或 git revert 重建 commit。

终态: GitHub=代码真源; Bucket 挂载=logic 部署通道 + /data/omn-logs/save/ 日志直写 + /data/omn-log-snapshot/ 配置快照; SQLite 空库启动+init 幂等重建。
