#!/usr/bin/env bash
# ============================================================
# p0-events-table — 事件写入函数库 (source 进 init/entrypoint 用)
# ============================================================
# 职责: 把一行 events INSERT 进 storage.sqlite (Litestream 正在复制那个库).
# 红线: 零新增持久通道 — 只写 $DB_PATH, 禁另开任何日志文件.
# 非接入: R3 宣判前不 source 进现役脚本, 仅定义待用.

# 前置: 调用方须已设 DB_PATH(= $DATA_DIR/storage.sqlite, 见 entrypoint-merged.sh:17)
# env 占位: 不硬编码库路径, 走注入, 防"另一库"漂移上线.

# ── 枚举校验(应用层兜 schema 无 CHECK 的洞) ──
# 理由: sqlite3 CLI 不便给 CHECK 约束 + 中文错误, 应用层先拦更清.
_EVENTS_VALID_TYPES="boot_banner upsert_result cb_trip fallback_enter fallback_exit queue_drop"

# 内部: event_type 是否在枚举内
_events_valid_type() {
  local _t="$1"
  for _v in $_EVENTS_VALID_TYPES; do
    [ "$_t" = "$_v" ] && return 0
  done
  return 1
}

# 内部: JSON 串转义 (最小集: " \ 换行 回车)
# 注: sqlite3 参数化 INSERT 在 CLI 拼串不便, 用 json 转义 + 单引号包裹.
#   payload已是JSON串, 勿二次转义; 调用方传已合法 JSON.
_events_json_escape() {
  # 仅转双引号及反斜杠, 保证 shell 单引号包裹后入库 payload 仍合法 JSON
  local _s="$1"
  _s="${_s//\\/\\\\}"      # \ → \\
  _s="${_s//\"/\\\"}"      # " → \"
  printf '%s' "$_s"
}

# 内部: shell 单引号转义 (防 payload 含单引号截断/注入)
_events_sq_escape() {
  local _s="$1"
  printf '%s' "${_s//\'/\'\'}"
}

# ── 公开: 写一行 event ─────────────────────────────────
# 用法: write_event "boot_banner" '{"port":20128,"exposed":7860}'
# 返回: 0 成功, 非0 失败(DB缺失/type非法/写入错) — fail-open 不中断调用方逻辑
#       (事件入库是观测面, 不应反过来把业务请求拖崩; 与 v2 异常即停并行不冲突:
#        异常即停指"命中与推断冲突信号"停手报回, 非每条事件错都停)
write_event() {
  local _type="$1"
  local _payload="${2:-{}}"

  # 守门1: DB_PATH 必须设且文件在
  if [ -z "${DB_PATH:-}" ] || [ ! -f "$DB_PATH" ]; then
    echo "[events] WARN: DB_PATH 未就绪, 跳过 event 入库 (type=$_type)" >&2
    return 1
  fi
  # 守门2: sqlite3 CLI 可用 (bootstrap 已装)
  if ! command -v sqlite3 >/dev/null 2>&1; then
    echo "[events] WARN: sqlite3 不可用, 跳过 event 入库 (type=$_type)" >&2
    return 1
  fi
  # 守门3: event_type 枚举校验
  if ! _events_valid_type "$_type"; then
    echo "[events] WARN: 非法 event_type '$_type' (合法: $_EVENTS_VALID_TYPES), 拒写" >&2
    return 1
  fi

  local _ts
  _ts="$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)"
  [ -z "$_ts" ] && _ts="1970-01-01T00:00:00Z"  # date 失败兜底, 不留空列

  local _p_esc
  _p_esc="$(_events_sq_escape "$(_events_json_escape "$_payload")")"

  # 写入: events 表 (schema 见 events_schema.sql, IF NOT EXISTS 幂等建表以防漏建)
  sqlite3 "$DB_PATH" "
    CREATE TABLE IF NOT EXISTS events (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      ts TEXT NOT NULL, event_type TEXT NOT NULL, payload TEXT NOT NULL DEFAULT '{}'
    );
    INSERT INTO events (ts, event_type, payload) VALUES ('$_ts', '$_type', '$_p_esc');
  " 2>/dev/null || { echo "[events] WARN: INSERT 失败 (type=$_type)" >&2; return 1; }

  return 0
}
