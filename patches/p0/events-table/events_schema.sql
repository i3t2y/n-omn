-- ============================================================
-- p0-events-table — SQLite events 表 schema 草案
-- ============================================================
-- Supreme 增补令 #1 · 依附 cg52 v2 §5 P0 局部提前授权
-- 本地合成弹药, R3 宣判(2026-07-23 03:16 后)前不出仓不上 Space.

-- ── 零新增持久通道红线(架构师) ──────────────────────────────
-- 所有写入必须落进 Litestream 正在复制的那个库文件
--   = entrypoint-merged.sh:17  DB_PATH="$DATA_DIR/storage.sqlite"
--   = candidate-v4.3-reviewed/litestream.yml  dbs[0].path=/app/data/storage.sqlite
-- 任何"另开一个日志文件"的实 现 均判不合格 (那正是上一轮
-- "HF 不存日志"讨论要消灭的缺口).
-- 故此表 CREATE 在 storage.sqlite 内, 与 call_logs/context_recommendations/
-- key_value 同库, 自然乘 Litestream → R2 既有通道, 零新增组件.

-- ── 应用方式(非本补丁执行, R3 接入窗) ──────────────────────
-- init 启动时 sqlite3 "$DB_PATH" < events_schema.sql
-- (CREATE TABLE IF NOT EXISTS 幂等, 多次跑无副作用)

CREATE TABLE IF NOT EXISTS events (
  id          INTEGER PRIMARY KEY AUTOINCREMENT,        -- 自增, 顺序即时序
  ts          TEXT    NOT NULL,                          -- ISO8601 UTC, 如 2026-07-22T03:16:00Z
  event_type  TEXT    NOT NULL,                          -- 见下方枚举约束
  payload     TEXT    NOT NULL DEFAULT '{}'              -- JSON 串(sqlite3 json_quote 或手拼)
);

-- event_type 枚举(应用层校验, 配套写入函数 enforce_event_type)
--   boot_banner     — entrypoint boot 启动签名 (PORT/EXPOSED/DATA)
--   upsert_result   — init combo upsert 结果 (PUT/POST HTTP code)
--   cb_trip         — Circuit Breaker 跳闸 (v2 §6 金丝雀记录三类之一)
--   fallback_enter  — Account Fallback 进入罚态 (三类之二)
--   fallback_exit   — Account Fallback 退出罚态 (三类之二对偶)
--   queue_drop      — 队列丢弃 (三类之三)

-- ── 索引: 按时序扫表常用(ts 倒序), event_type 过滤常用 ──
CREATE INDEX IF NOT EXISTS idx_events_ts         ON events (ts);
CREATE INDEX IF NOT EXISTS idx_events_event_type ON events (event_type);

-- ── 列风格对齐现役 ──────────────────────────────────────
-- 现役 context_recommendations: TEXT PRIMARY KEY + INTEGER DEFAULT + TEXT DEFAULT 'insufficient'
-- 本表同风格: TEXT NOT NULL + TEXT DEFAULT '{}', 但 id 用 INTEGER AUTOINCREMENT
--   (事件无天然业务键, 自增序即够; context_recommendations 有 model_id 业务键故 TEXT PK)
--   选择依据: events 是 append-only 时序流, 不需按业务键去重.
