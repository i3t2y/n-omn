#!/bin/bash
# 进程编排总控 (合并版)
# =====================================================
# K3 v2.0 骨架 (已修 litestream restore -config; ephemeral 盘认清 → R2 是数据主路径)
# + candidate v4.3 加固迁移:
#   1. restore guard 完善版: flock 跨容器互斥 + -o 临时路径原子 mv + quick_check + -if-replica-exists 自适应 + STRICT 日志
#   2. trap SIGTERM/SIGINT: 向 上游服务/init/litestream/gate 四后台子进程转 SIGTERM, grace wait, SIGKILL 兜底, 无孤儿
# gate 用 background 运行 (node /logic/gate.js &) + GATE_PID 纳入 _shutdown 转发;
#   entrypoint 持 PID 1 主监控循环 (while true) 管四子进程。
#   (非 exec 接管 PID 1 — exec 会让三后台成 gate 兄弟变孤儿, trap 失效)
set -eo pipefail

OMNIROUTE_PORT="${OMNIROUTE_PORT:-20128}"
EXPOSED_PORT="${EXPOSED_PORT:-7860}"
# 默认 /app/data = 上游镜像固设 DATA_DIR (3.8.43 基线); env 可改
DATA_DIR="${DATA_DIR:-/app/data}"
export DATA_DIR   # 须 export: init/scheduler 子进程须见同值 (_raw 路径两端对齐, 否子进程回默认 /data 歧义)

# ── boot 编排日志全段落 raw (2026-08-01 圣上令补: entrypoint 本体 echo 全进 PID1 stdout 今丢, 补) ──
#   [entrypoint] 编排真相(健康等待/各进程 PID/FATAL/gate依赖装/启动顺序)经 capture_loop 第6源入 save.
#   omni-raw 须在 scheduler STAGING 外 (防明文混入 save): 同 RAW_DIR, omn_redact 兜脱敏后写 staging 推 save.
#   tee 双路: 同时留 PID1 stdout 供 HF Space runtime logs 看 (窗外即焚的前置应急).
_EP_LOG_RAW="${DATA_DIR}/omn-raw/entrypoint.log"
mkdir -p "$(dirname "$_EP_LOG_RAW")" 2>/dev/null || true
: > "$_EP_LOG_RAW" 2>/dev/null || true   # 截断旧残留 (boot 新轮归零, 与 litestream.log 同), capture_loop offset 按 path 重置免跨 boot 重复推
exec > >(tee -a "$_EP_LOG_RAW") 2>&1
echo "[entrypoint] boot 编排日志 tee -> $_EP_LOG_RAW (_raw → capture_loop entrypoint 源 → omn_redact → save/entrypoint/)"
DB_PATH="$DATA_DIR/storage.sqlite"
DB_TMP="$DATA_DIR/.storage.sqlite.restore.$$"   # 临时恢复路径 (原子保护)
LOCK_FILE="$DATA_DIR/.omniroute.lock"
# 版本校验：硬编码已驱逐，改读 EXPECTED_VERSION env（未设则只记录不比对）。
# 值放 Space Variable 与 BASE_IMAGE 同步更新，三文件永久免改。
EXPECTED_VER="${EXPECTED_VERSION:-}"

# v4.3.2 [M7·查证定版]: 超时 env 外科单注 (官方 Environment wiki §15 实证, 2026-07-22).
#   查证结论(wiki 有 CI check:env-doc-sync 强制 wiki↔.env.example 同步, 缺席=未识别):
#     · STREAM_READINESS_TIMEOUT_MS 默 80000(80s) = 首个非 ping SSE 事件时限 — 长思考"首 token 前静默"
#       真杀手(122s 级思考静默正对此刀). 外科抬至 180s, 不动其他预算; 未设 REQUEST_TIMEOUT_MS 时读自身值.
#     · REQUEST_TIMEOUT_MS = 全局快捷键, 同覆 FETCH_TIMEOUT_MS(默600000)/STREAM_IDLE_TIMEOUT_MS(默600000) —
#       注它会把总时限/流空闲从 600s 拉低到所注值, 双面刃; 本场景无降额需求, 故不注.
#     · DEFAULT_REQUEST_TIMEOUT_MS 不在官方变量表 → 规则五修正: 删除, 早前"双注"方案作废.
#   gate GATE_UPSTREAM_TIMEOUT_MS(行30 默30000) 仍零 diff: Node http.request timeout=socket 不活跃超时,
#     流式有数据即重置、思考静默>30s 触发 — 122s 级首 token 静默经 gate 如何完成列 K3 题5, 解冻后走 env 调.
STREAM_READINESS_TIMEOUT_MS="${STREAM_READINESS_TIMEOUT_MS:-180000}"
export STREAM_READINESS_TIMEOUT_MS
echo "[entrypoint] STREAM_READINESS_TIMEOUT_MS=$STREAM_READINESS_TIMEOUT_MS (M7 外科单注, wiki §15 实证)"

OR_PID=""; INIT_PID=""; LS_PID=""; GATE_PID=""; SCHED_PID=""; FT_PID=""
# FT_PIDS = 空格分隔多桥 PID 串 (多桥模式); 单桥回退时仅一元素. trap/看门狗遍历此串.
FT_PIDS=""

echo "[entrypoint] 上游服务启动 | PORT=$OMNIROUTE_PORT EXPOSED=$EXPOSED_PORT DATA=$DATA_DIR (ephemeral, R2 是数据主路径)"

# ── trap 转发: 向 上游服务/init/litestream/gate 四发 SIGTERM, grace 后 SIGKILL, wait 回收 ──
# 重要: gate 用 background (非 exec 接管 PID 1), entrypoint 持 PID 1 主监控循环;
#   否则 exec gate 会让三后台成 gate 兄弟 (孤儿), trap 失效。
cleanup_done=0
_forward_signal() {
  local sig="$1" pid fpid
  for pid in "$OR_PID" "$INIT_PID" "$LS_PID" "$GATE_PID" "$SCHED_PID"; do
    [ -z "$pid" ] && continue
    kill -0 "$pid" 2>/dev/null && kill -"$sig" "$pid" 2>/dev/null || true
  done
  # 多桥: FT_PIDS 空格分隔, 逐桥发信号 (单桥回退时 FT_PIDS 含一元素, 兼容).
  for fpid in $FT_PIDS; do
    [ -z "$fpid" ] && continue
    kill -0 "$fpid" 2>/dev/null && kill -"$sig" "$fpid" 2>/dev/null || true
  done
  # 兼容: 单桥回退路径也设了 FT_PID, 双保险 (FT_PIDS 已含, 此行冗余但零害).
  [ -n "$FT_PID" ] && kill -0 "$FT_PID" 2>/dev/null && kill -"$sig" "$FT_PID" 2>/dev/null || true
}
_shutdown() {
  [ "$cleanup_done" = 1 ] && return
  cleanup_done=1
  echo "[entrypoint] shutdown: forwarding SIGTERM to background children..."
  _forward_signal TERM
  local g=0 alive
  while [ "$g" -lt 50 ]; do
    alive=0
    for pid in "$OR_PID" "$INIT_PID" "$LS_PID" "$GATE_PID" "$SCHED_PID"; do
      [ -z "$pid" ] && continue
      kill -0 "$pid" 2>/dev/null && alive=1
    done
    for fpid in $FT_PIDS; do
      [ -z "$fpid" ] && continue
      kill -0 "$fpid" 2>/dev/null && alive=1
    done
    [ "$alive" = 0 ] && break
    sleep 0.1 2>/dev/null || sleep 1
    g=$((g + 1))
  done
  echo "[entrypoint] shutdown: force-kill 残留..."
  _forward_signal KILL
  for pid in "$OR_PID" "$INIT_PID" "$LS_PID" "$GATE_PID" "$SCHED_PID"; do
    [ -z "$pid" ] && continue
    wait "$pid" 2>/dev/null || true
  done
  for fpid in $FT_PIDS; do
    [ -z "$fpid" ] && continue
    wait "$fpid" 2>/dev/null || true
  done
  [ -n "$FT_PID" ] && wait "$FT_PID" 2>/dev/null || true
  echo "[entrypoint] shutdown complete."
}
trap '_shutdown' TERM
trap '_shutdown' INT

# ── 文件锁: 防多容器同时 restore/替换 $DB (HF Space 优先单实例, flock 不可用则 WARN 跳过) ──
exec 9>"$LOCK_FILE"
if command -v flock >/dev/null 2>&1; then
  flock -x 9 || { echo "[entrypoint] FATAL: 无法获取文件锁 $LOCK_FILE (另一容器占用?). abort." >&2; exit 1; }
  echo "[entrypoint] lock acquired (flock $LOCK_FILE, fd 9)."
else
  echo "[entrypoint] WARN: flock 不可用, 跳过跨容器互斥 (HF Space 优先单实例)."
fi

# ── 1. Litestream restore (启动前; 红线: 不覆盖有效 DB; ephemeral → R2 是数据主路径) ─
# 优雅降级:
#   R2 无副本 → -if-replica-exists rc=0 但不创建文件 → 空库启动 (init 重建), 不 exit
#   restore 失败 (配置/网络/权限) → WARN + 空库启动, 不 exit (永不因 restore 失败 FATAL)
#   restore 成功+有文件 → quick_check 通过 → 原子 mv → 正式 $DB
#   restore 成功+quick_check 失败 → 丢弃临时+空库启动, 不 exit
# K3 v2.0 修复: restore 增加 -config /litestream.yml (v1 缺此参数读默认 /etc/litestream.yml 导致静默失败)
has_r2=0
[ -n "${R2_ACCESS_KEY_ID:-}" ] && [ -n "${R2_SECRET_ACCESS_KEY:-}" ] && [ -n "${R2_ACCOUNT_ID:-}" ] && has_r2=1

if [ "$has_r2" = 0 ]; then
  echo "[entrypoint] ⚠ R2 凭据未配置 → skip restore, 空库启动 (数据将不可持久, 强烈建议补齐)"
elif [ -f "$DB_PATH" ] && [ -s "$DB_PATH" ]; then
  echo "[entrypoint] 本地库非空 ($DB_PATH) → skip restore (不覆盖有效 DB)"
else
  # 本地库空或不存在 → restore
  rm -f "$DB_TMP" "$DB_TMP-wal" "$DB_TMP-shm"
  printf '%s' "" > /tmp/ls_restore.err
  rc=0
  litestream restore -config /logic/litestream.yml -if-replica-exists -o "$DB_TMP" "$DB_PATH" 2>/tmp/ls_restore.err || rc=$?
  used_tmp=1
  # flag 自适应回退: 仅当某 flag 不支持才降级, 保留其它仍可支持 flag。
  # 优先级: -if-replica-exists -o tmp (最佳, R2 无副本 rc=0 无文件不 WARN)
  #   → -if-replica-exists 单独 (-o 不支持, 仍 R2 无副本 rc=0 无文件不 WARN)
  #   → 裸 restore (两 flag 都不支持, R2 无副本会 rc≠0 → 走 WARN 分支, 但有 "no replica/empty/not found" 字串例外不 WARN)
  if echo "$(cat /tmp/ls_restore.err 2>/dev/null)" | grep -qiE 'unknown flag|invalid option|flag provided but not defined'; then
    _err1="$(cat /tmp/ls_restore.err 2>/dev/null)"
    if printf '%s' "$_err1" | grep -qiE '\-o|output'; then
      # -o 不支持: 保留 -if-replica-exists, 去 -o, 直接 restore $DB_PATH (冷启动空, 无有效 DB 被覆盖)
      echo "[entrypoint] litestream 不支持 -o → 回退 -if-replica-exists 单独 restore $DB_PATH."
      rm -f "$DB_TMP" "$DB_TMP-wal" "$DB_TMP-shm"
      printf '%s' "" > /tmp/ls_restore.err
      rc=0
      litestream restore -config /logic/litestream.yml -if-replica-exists "$DB_PATH" 2>/tmp/ls_restore.err || rc=$?
      used_tmp=0
    elif printf '%s' "$_err1" | grep -qiE 'if-replica-exists'; then
      # -if-replica-exists 不支持: 裸 restore (R2 无副本会 rc≠0, 下文 "no replica" 例外不 WARN)
      echo "[entrypoint] litestream 不支持 -if-replica-exists → 回退裸 restore $DB_PATH."
      rm -f "$DB_TMP" "$DB_TMP-wal" "$DB_TMP-shm"
      printf '%s' "" > /tmp/ls_restore.err
      rc=0
      litestream restore -config /logic/litestream.yml "$DB_PATH" 2>/tmp/ls_restore.err || rc=$?
      used_tmp=0
    fi
  fi

  if [ "$rc" -ne 0 ]; then
    # 裸 restore (两 flag 都不支持) 在 R2 无副本时会 rc≠0, 但属正常首次部署, 不该 WARN。
    # litestream 无副本常见错误字串: "no replica"/"no data"/"not found"/"does not exist"/"empty"。
    if printf '%s' "$(cat /tmp/ls_restore.err 2>/dev/null)" | grep -qiE 'no replica|no (matching )?replica|no data|not found|does not exist|no entries|empty'; then
      echo "[entrypoint] restore rc=$rc 但匹配 '无副本' 错误 (R2 无副本或首次部署, 正常). 空库启动, init 重建配置."
    else
      echo "[entrypoint] ⚠ restore 失败 rc=$rc (见 /tmp/ls_restore.err; 已脱敏, 不打凭据). 空库启动."
      [ "${LITESTREAM_STRICT:-0}" = 1 ] && echo "[entrypoint]   STRICT=1: 仅告警, 不 exit (空库启动)."
    fi
    rm -f "$DB_TMP" "$DB_TMP-wal" "$DB_TMP-shm" 2>/dev/null || true
  elif [ "$used_tmp" = 1 ] && { [ ! -f "$DB_TMP" ] || [ ! -s "$DB_TMP" ]; }; then
    echo "[entrypoint] restore rc=0 但无文件 (R2 无副本或首次部署). 空库启动, init 重建配置."
    rm -f "$DB_TMP" "$DB_TMP-wal" "$DB_TMP-shm" 2>/dev/null || true
  elif [ "$used_tmp" = 1 ]; then
    # 临时文件有效 → quick_check → 原子 mv
    qc_ok=0
    if command -v sqlite3 >/dev/null 2>&1; then
      if sqlite3 "$DB_TMP" "PRAGMA quick_check;" 2>/dev/null | grep -q "^ok$"; then
        qc_ok=1
      else
        echo "[entrypoint] ⚠ quick_check 失败. 丢弃临时 $DB_TMP, 空库启动."
        [ "${LITESTREAM_STRICT:-0}" = 1 ] && echo "[entrypoint]   STRICT=1: 仅告警, 不 exit."
        rm -f "$DB_TMP" "$DB_TMP-wal" "$DB_TMP-shm" 2>/dev/null || true
      fi
    else
      echo "[entrypoint] sqlite3 不可用, 跳过 quick_check (验文件非空)."
      qc_ok=1
    fi
    [ "$qc_ok" = 1 ] && mv "$DB_TMP" "$DB_PATH" && echo "[entrypoint] ✓ 已从 R2 恢复 (原子 mv $DB_TMP → $DB_PATH)"
  else
    # used_tmp=0 (直接 $DB restore): 验 $DB 非空 + quick_check
    if [ ! -f "$DB_PATH" ] || [ ! -s "$DB_PATH" ]; then
      echo "[entrypoint] restore rc=0 但 $DB_PATH 无文件 (R2 无副本或首次部署). 空库启动, init 重建."
    elif command -v sqlite3 >/dev/null 2>&1; then
      if sqlite3 "$DB_PATH" "PRAGMA quick_check;" 2>/dev/null | grep -q "^ok$"; then
        echo "[entrypoint] ✓ 已从 R2 恢复 (直接 $DB_PATH, quick_check ok)"
      else
        echo "[entrypoint] ⚠ quick_check 失败 on $DB_PATH. 丢弃空库启动."
        rm -f "$DB_PATH" "$DB_PATH-wal" "$DB_PATH-shm" 2>/dev/null || true
      fi
    else
      echo "[entrypoint] ✓ 已从 R2 恢复 (直接 $DB_PATH, 文件非空)"
    fi
  fi
fi

# ── 1.5 FlareTunnel 本地桥 (2026-07-30, 档位A: 单桥 :8080 round-robin N Worker) ──
# 拓扑: OmniRoute undici → HTTP CONNECT 127.0.0.1:8080 → 桥 MITM → CF Worker 池 → NIM.
#   目的 = 换 NIM 出口 IP (CF 172.64.0.0/13 出口段动态轮换), 与旧 relay 三故障不同代码路径.
#   拓扑关键: OmniRoute 只见 1 条桥代理 (flaretunnel-8080 → provider scope), Worker 池是
#   桥内部实现细节 — 桥 round-robin 轮分 N Worker 出口, OmniRoute 不感知 N (设计如此).
# 开关: FLARETUNNEL_ENABLED=1 (Space Variable) 才启; 未设/0 = 全段零副作用
#   (AB 双轨同哲学: 默认路径行为不变, 启用路径自举, 回滚 = 删 Variable + Restart).
# 资产: /logic/flaretunnel (静态二进制) + /logic/flaretunnel_endpoints.json (Worker 池, 数由 jp 真读),
#   皆走 Dataset 同步, Restart 即效零 Rebuild.
# 次序红线 (NODE_EXTRA_CA_CERTS 两前提, 2026-07-30 双核+docker 实证):
#   ① 桥先起 → CA 自签落 $FT_CA_DIR (源码实证 generateCACert: crt+key 存在即 early-return
#     复用不重签 → §7 看门狗重启桥不换 CA, 上游已载证书不失效, 无须连带重启);
#   ② export NODE_EXTRA_CA_CERTS 须在 §2 上游 node server.js 启动前 (Node 仅启动时读,
#     运行中 process.env 设无效; 文件缺则 Node 警告忽略 = CA 未载 = nvidia TLS 必崩);
#   ③ OmniRoute undici 源码实证 buildConnector 不注 ca → 默认根 CA 自动含 extra, 无须改上游.
# fail-open: FT 是增强层非地基 — 资产缺/桥起不来 → WARN 跳过全段, 不 FATAL 不 brick Space.
#   (注意降级语义: 若 proxy_enabled 已注册为 1 而桥缺, nvidia 路径停, 日志明示, 人工修资产
#    或关 FLARETUNNEL_ENABLED 后 Restart.)
if [ "${FLARETUNNEL_ENABLED:-0}" = "1" ]; then
  echo "[entrypoint] FT: FLARETUNNEL_ENABLED=1, 启动 FlareTunnel 本地桥 (档位A)..."
  _ft_ok=1
  [ -f /logic/flaretunnel ] || { echo "[entrypoint] FT WARN: /logic/flaretunnel 二进制缺 (Dataset 资产未推?), 跳过 FT"; _ft_ok=0; }
  [ -f /logic/flaretunnel_endpoints.json ] || { echo "[entrypoint] FT WARN: /logic/flaretunnel_endpoints.json 缺, 跳过 FT"; _ft_ok=0; }
  [ -n "${RELAY_AUTH:-}" ] || { echo "[entrypoint] FT WARN: RELAY_AUTH Secret 未设, 跳过 FT (Worker 鉴权必拒)"; _ft_ok=0; }
  if [ "$_ft_ok" = 1 ]; then
    chmod +x /logic/flaretunnel 2>/dev/null || true   # start.sh 仅 chmod /logic/*.sh, 二进制此处自举
    FT_CA_DIR="${FT_CA_DIR:-/tmp/ft-ca}"
    FT_PORT="${FT_PORT:-8080}"                        # 须与 OmniRoute 后台注册代理端口一致 (Step 6)
    FT_LOG="${DATA_DIR}/omn-raw/flaretunnel.log"   # 落 omn-raw 临时区 (scheduler folder 外, 防明文混入 save), capture_loop 尾追+omn_redact 后写 staging 推 save
    mkdir -p "$FT_CA_DIR" "$(dirname "$FT_LOG")" 2>/dev/null || true
    # 单点启动函数: 本段首启 + §7 看门狗重启共用同一命令 (不分叉, "改也为以后不改")
    # 多桥模式 (2026-08-10 圣上令): 读 /logic/flaretunnel_bridges.json 循环起 N 桥,
    #   各占独立 127.0.0.1:$port + 各绑 --workers a-b 子段 (多桥共用 endpoints.json 同名单, 各取不重叠段).
    #   JSON 不存/空/非法 → 回退单桥 (保 FT_WORKER_COUNT ENV 单桥行为不破, 回滚 = 删 JSON + Restart).
    #   JSON 形: [{"name":"nim","port":8081,"workers":"0-23","providers":["nvidia"]},...]
    #     providers (opt): 桥绑何 provider 族名数组 (init 读此绑 proxy→族; 缺则裸桥待指派).
    #       单桥可绑多族共享出口 IP 段池; scopeId 用家族名常量串 "nvidia" 非 row id.
    #       HTTP 墙: 一族只绑一桥 (replace 语义), 单 proxy 可绑多族 (不同 scope_id 互不 replace).
    #   30 桥封顶 (圣上限; HF 2vCPU/16GB 资源定, 超此墙见审计).
    _ft_start() {
      _ft_verbose=""
      [ "${FT_VERBOSE:-0}" = "1" ] && _ft_verbose="--verbose"
      _ft_phys=$(jq 'if type=="array" then length elif .endpoints then (.endpoints|length) elif .workers then (.workers|length) else 0 end' /logic/flaretunnel_endpoints.json 2>/dev/null || echo 0)
      _ft_wflag=""
      _ft_use=$_ft_phys
      if [ "${FT_WORKER_COUNT:-0}" -gt 0 ] 2>/dev/null && [ "$_ft_phys" -gt 0 ] 2>/dev/null; then
        if [ "$FT_WORKER_COUNT" -lt "$_ft_phys" ]; then
          _ft_use=$FT_WORKER_COUNT
          _ft_wflag="--workers 0-$((_ft_use-1))"
          _ft_n=$_ft_use
        else
          [ "$FT_WORKER_COUNT" -gt "$_ft_phys" ] && echo "[entrypoint] FT: FT_WORKER_COUNT=$FT_WORKER_COUNT 超 endpoints.json 实际 $_ft_phys 条, 用满池 ($_ft_phys) 轮换."
        fi
      fi
      # FT_PIDS = 空格分隔 PID 串 (多桥); FT_PORTS = 对应端口串; 兼容单桥时仅一元素.
      FT_PIDS=""; FT_PORTS=""; FT_NAMES=""; export FT_PIDS FT_PORTS FT_NAMES
      _ft_multi=0
      if [ -f /logic/flaretunnel_bridges.json ] && jq -e '. | type=="array" and length>0 and all(.[]; has("port") and has("workers"))' /logic/flaretunnel_bridges.json >/dev/null 2>&1; then
        _ft_nb=$(jq 'length' /logic/flaretunnel_bridges.json 2>/dev/null || echo 0)
        if [ "$_ft_nb" -gt 30 ]; then
          echo "[entrypoint] FT WARN: flaretunnel_bridges.json 桥数 $_ft_nb 超 30 封顶, 只起前 30 (圣上限; 超此资源见审计)."
          _ft_nb=30
        fi
        if [ "$_ft_nb" -gt 0 ] && [ "$_ft_phys" -gt 0 ]; then
          _ft_multi=1
          _i=0
          while [ "$_i" -lt "$_ft_nb" ]; do
            _b_name=$(jq -r ".[$_i].name // \"bridge-$_i\"" /logic/flaretunnel_bridges.json 2>/dev/null)
            _b_port=$(jq -r ".[$_i].port" /logic/flaretunnel_bridges.json 2>/dev/null)
            _b_w=$(jq -r ".[$_i].workers // \"\"" /logic/flaretunnel_bridges.json 2>/dev/null)
            _b_wflag=""
            [ -n "$_b_w" ] && _b_wflag="--workers $_b_w"
            # 段越界校验 (a-b a,b < M): 范围超 phys 则该段 workers flag 仍传, Go LoadWorkers 过滤越界索引段余空池自报.
            /logic/flaretunnel tunnel --host 127.0.0.1 --port "$_b_port" \
              --endpoints /logic/flaretunnel_endpoints.json \
              --relay-auth "$RELAY_AUTH" \
              --ca-dir "$FT_CA_DIR" $_b_wflag $_ft_verbose >>"${FT_LOG%.log}-$_b_name.log" 2>&1 &
            _b_pid=$!
            FT_PIDS="$FT_PIDS $_b_pid"; FT_PORTS="$FT_PORTS $_b_port"; FT_NAMES="$FT_NAMES $_b_name"
            _i=$((_i+1))
          done
          export FT_PIDS FT_PORTS FT_NAMES   # export 同步给 init 子进程见
          echo "[entrypoint] FT: 多桥模式起 $_ft_nb 桥 (PID=[${FT_PIDS# }], PORT=[${FT_PORTS# }], NAME=[${FT_NAMES# }], endpoints.json 池=$_ft_phys, log→${FT_LOG%.log}-<name>.log)"
          return
        fi
      fi
      # 回退单桥 (JSON 不存/空/非法或物权为 0): 现役逻辑不动.
      /logic/flaretunnel tunnel --host 127.0.0.1 --port "$FT_PORT" \
        --endpoints /logic/flaretunnel_endpoints.json \
        --relay-auth "$RELAY_AUTH" \
        --ca-dir "$FT_CA_DIR" $_ft_wflag $_ft_verbose >>"$FT_LOG" 2>&1 &
      FT_PID=$!
      export FT_PID
      : "${_ft_n:=$_ft_phys}"
      echo "[entrypoint] FT: 单桥回退 PID=$FT_PID (127.0.0.1:$FT_PORT, ${_ft_n}/${_ft_phys} Worker round-robin${_ft_wflag:+ (ENV FT_WORKER_COUNT=${FT_WORKER_COUNT} 子集)}, log→$FT_LOG${_ft_verbose:+ verbose metrics-dump ON})"
      # 兼容 FT_PIDS 旧引用: 单桥也填入.
      FT_PIDS=" $FT_PID"; FT_PORTS=" $FT_PORT"; FT_NAMES=" single"; export FT_PIDS FT_PORTS FT_NAMES
    }
    _ft_start
    # CA 等生 (红线②): 桥首启自签 CA 落盘后才可 export; 上限 10s, 桥早夭即弃.
    #   多桥共用一 ca-dir, 首桥代整体判生死 (多桥首桥死 = 全 FT 资产级病, 弃全桥降级).
    _ft_ca="$FT_CA_DIR/flaretunnel_ca.crt"; _ft_wait=0
    _ft_alive() { [ -n "$FT_PID" ] && kill -0 "$FT_PID" 2>/dev/null; }
    while [ "$_ft_wait" -lt 20 ]; do
      if [ -s "$_ft_ca" ]; then break; fi
      if ! _ft_alive; then
        echo "[entrypoint] FT WARN: 桥 CA 等生期间退出 (详见 $FT_LOG), 跳过 FT"; break
      fi
      sleep 0.5; _ft_wait=$((_ft_wait+1))
    done
    if [ -s "$_ft_ca" ] && _ft_alive; then
      export NODE_EXTRA_CA_CERTS="$_ft_ca"
      echo "[entrypoint] FT: CA 就绪, NODE_EXTRA_CA_CERTS=$_ft_ca 已 export (先于 §2 上游启动, 红线②满足)"
    else
      echo "[entrypoint] FT WARN: CA 10s 未就绪, 桥降级关闭 (nvidia 若已注册代理将停, 请修资产或关 FT 开关)"
      # 杀全桥: 单桥杀 FT_PID, 多桥遍历 FT_PIDS.
      [ -n "$FT_PID" ] && kill "$FT_PID" 2>/dev/null || true
      for fpid in $FT_PIDS; do kill "$fpid" 2>/dev/null || true; done
      [ -n "$FT_PID" ] && wait "$FT_PID" 2>/dev/null || true
      for fpid in $FT_PIDS; do wait "$fpid" 2>/dev/null || true; done
      FT_PID=""; FT_PIDS=""
      export FT_PID FT_PIDS   # 降级也须 export 空, 同步给 init 子进程见空跳注册 (防误注册死桥)
    fi
  fi
else
  echo "[entrypoint] FT: FLARETUNNEL_ENABLED 未启用, 跳过 (默认直连路径零变更)"
fi

# ── 2. 启动上游服务 ──
# 2026-07-25 #4 回归修复: 4.2.3 entrypoint 启动行内联 NODE_OPTIONS=--max-old-space-size=4096,
# 4.3.2 迁移时丢失 → dev Node 默认堆 ~1GB, 经 25-key 同体 fallback 堆载累积触顶 OOM 崩盘
# (弹H末日: Mark-Compact 1015→1023MB 触顶 → heap out of memory → Space 关机)。
# 生产 4.2.3 同 #4 链用 4GB 堆扛过 25 次未崩 → 4GB 是该链生产验证过的值, SSOT 优先于推测。
cd /app
# ── C/D app.log 补漏进 save (圣旨: 靠积累 log 达优化真痛点=内层因果) ──
# 上游自带结构化 app.log (logRotation.ts, 默 APP_LOG_TO_FILE!=false 即开),
# 含路由/quota cache/batch 背压/domain 断路器 trip·recover/queue 深度 — 圣旨"优并发/避雪崩/优模型调用"单请求级证据.
# 路径改指 scheduler RAW_DIR (_raw 临时区), capture_loop 尾追+omn_redact 后写 staging folder 推 save (E 脱敏层).
# D 闸: OMN_LOG_TO_DATASET=0 不设 = 上游回默认本机盘 (logs/application/app.log, omn_redact 不 demang 进 folder, 如旧行).
if [ "${OMN_LOG_TO_DATASET:-1}" = "1" ]; then
  export APP_LOG_FILE_PATH="${DATA_DIR}/omn-raw/app.log"   # 落 omn-raw (scheduler folder 外, 防明文混入 save), capture_loop 尾追+omn_redact 后写 staging 推 save
  mkdir -p "$(dirname "$APP_LOG_FILE_PATH")" 2>/dev/null || true
fi
NODE_OPTIONS="${NODE_OPTIONS:---max-old-space-size=4096}" node server.js &
OR_PID=$!
echo "[entrypoint] 上游服务 PID=$OR_PID (heap ${NODE_OPTIONS:-default})"

# ── 3. 健康等待 (180s) ──
_DL=$(( $(date +%s) + 180 ))
_ready=0
while [ $(date +%s) -lt $_DL ]; do
  curl -sf "http://127.0.0.1:$OMNIROUTE_PORT/api/monitoring/health" >/dev/null 2>&1 && { _ready=1; break; }
  kill -0 $OR_PID 2>/dev/null || { echo "[entrypoint] ✗ 上游服务已退出"; exit 1; }
  sleep 2
done
if [ "$_ready" = 0 ]; then
  echo "[entrypoint] ✗ 健康等待超时 (180s 未就绪, 上游 PID $OR_PID 仍活但不响应 /api/monitoring/health)"; exit 1
fi
echo "[entrypoint] ✓ 就绪"
_VER=$(curl -sf "http://127.0.0.1:$OMNIROUTE_PORT/api/monitoring/health" | jq -r '.version // "unknown"' 2>/dev/null || echo unknown)
if [ -n "$EXPECTED_VER" ]; then
  if [ "$_VER" = "$EXPECTED_VER" ]; then
    echo "[entrypoint] 版本=$_VER ✓ (期望 $EXPECTED_VER)"
  else
    # 只告警不 exit：上游前滚迁移会让旧库自动进新 schema，版本不齐仍可跑。
    echo "[entrypoint] ⚠ 版本不齐 实跑=$_VER 期望=$EXPECTED_VER (非致命, 上游迁移自动前滚)"
  fi
else
  echo "[entrypoint] 版本=$_VER (期望未设置, 跳过比对)"
fi

# ── 4. NIM 初始化 (后台) ──
if [ -f /logic/init-nim-keys.sh ] && [ -n "${NIM_KEYS:-}" ]; then
  bash /logic/init-nim-keys.sh & INIT_PID=$!
  echo "[entrypoint] Init PID=$INIT_PID"
fi

# ── 5. Litestream 复制 (后台) ──
# v0.5.9契约: replicate -config 模式 fs.NArg()必须=0 (走配置文件内 dbs[].path).
#   传 $DB_PATH 位置参数会命中 case 1 → "must specify at least one replica URL" 报错.
#   db 路径已在 /logic/litestream.yml 的 dbs[].path 内定义, 命令行不可再传.
if [ "$has_r2" = 1 ] && [ -f /logic/litestream.yml ]; then
  # OMN_PERSIST_WRITE 闸 (2026-08-10 圣上令): 控本次启动后改动是否写回 R2.
  #   1 (默认/开) = litestream replicate 照跑, 在线改 (后台加 key/改设置) 推 R2 → 持久保存.
  #   0 (关)      = replicate 不启 → 本次改动不写回 R2 (不保存). OmniRoute 在线读写本地 SQLite 照常(本次 boot 可见).
  #   语义: 此闸只控"写回 R2"一物, 不删任何东西, 不动 restore 读. 开=保存, 关=不保存. 回滚 = 删 Variable + Restart.
  #   (restore L136 仍跑不受此闸控 — 关态只阻写回不阻读档.)
  _LS_LOG_RAW="${DATA_DIR}/omn-raw/litestream.log"
  mkdir -p "$(dirname "$_LS_LOG_RAW")" 2>/dev/null || true
  : > "$_LS_LOG_RAW" 2>/dev/null || true   # 截断旧残留 (boot 新轮归零), omn-raw 同名件 capture_loop offset 重置
  if [ "${OMN_PERSIST_WRITE:-1}" = "1" ]; then
    # (2026-08-01 圣上令补) litestream stderr 重定向入 raw → capture_loop 第7源入 save.
    # R2 复制链故障(compaction txid gap/proxy_breaker/replica断代)判据, 与 entrypoint 源同落 omn-raw.
    litestream replicate -config /logic/litestream.yml >>"$_LS_LOG_RAW" 2>&1 & LS_PID=$!
    echo "[entrypoint] Litestream PID=$LS_PID (stderr→$_LS_LOG_RAW, capture_loop litestream 源 → save/litestream/)"
  else
    echo "[entrypoint] Litestream: OMN_PERSIST_WRITE=0 关态, replicate 不启 → 本次改动不保存 (不写回 R2)."
    echo "[entrypoint] OMN_PERSIST_WRITE=0: 后台加 key/改设置不保存" > "$_LS_LOG_RAW"
  fi
fi

echo "[entrypoint] 全部就绪：OR=$OR_PID Init=${INIT_PID:-无} LS=${LS_PID:-无} Gate→:$EXPOSED_PORT (background, entrypoint 持 PID 1 主监)"

# ── 6. 启动 gate (background, entrypoint 持 PID 1 主监控循环) ──
# 上游健康二次确认: 若上游已死, 不启 gate (避孤儿 gate 空转)
if ! kill -0 "$OR_PID" 2>/dev/null; then
  echo "[entrypoint] FATAL: 上游服务 died before gate. abort"; _shutdown; exit 1
fi
if [ ! -f /logic/gate.js ]; then
  echo "[entrypoint] FATAL: gate.js 不存在"; _shutdown; exit 1
fi

# ── 5.5 预装 gate 依赖 (三层解耦: /logic 逐 boot 重建 = ephemeral) ──
# gate.js require('express'). AB 双轨自动判 (圣上原设计: 用官方镜像该装, 用全包镜像跳):
#   node module resolution 自动查 本地 /logic/node_modules → 全局 NODE_PATH (express 入 GHCR base).
#   镜像自带 ENV NODE_PATH (B 全包) → 命中跳; 裸上游 (A) 无 express 无 NODE_PATH → require fail → 装兜底.
#   单判据 requireResolve = 与 gate.js 实跑同判据, 不两处分叉(免脚本以后再改).
# 兜底 fail-closed 双锁: npm 装后二次 require 真验 (npm rc=0 ≠ require 通), 仍 fail 早死避 crashloop.
if [ ! -f /logic/package.json ]; then
  echo "[entrypoint] FATAL: /logic/package.json 不存在, 无法预装 gate 依赖"; _shutdown; exit 1
fi
# probe 失败保留 stderr (非 >/dev/null 全吞) — AB 排障看 A 镜像 require 真因 (无全局/无 NODE_PATH/package 表达)
_ProbeErr=$(mktemp)
if node -e "require('express')" >"$_ProbeErr" 2>&1; then
  rm -f "$_ProbeErr"
  echo "[entrypoint] gate 依赖已就绪 (require('express') 命中, 跳 npm install)"
else
  rm -f "$_ProbeErr"
  echo "[entrypoint] 预装 gate 依赖 (npm install --omit=dev)..."
  if (cd /logic && npm install --omit=dev --silent --no-audit --no-fund 2>&1); then
    # 兜底装后二次真验 require (npm rc=0 ≠ require resolve 必成功:
    #   package.json 缺 express 依赖名/版本区间拉空/edge install 病, 皆 npm 不报而 require 仍 fail).
    # 与实跑同判据探, 闭环 fail-closed (装完仍 require 不通 = gate 必崩, 早死优于 crashloop).
    if (cd /logic && node -e "require('express')" >/dev/null 2>&1); then
      echo "[entrypoint] gate 依赖就绪"
    else
      echo "[entrypoint] FATAL: npm install 成功但 require('express') 仍 fail, gate 必崩"; _shutdown; exit 1
    fi
  else
    echo "[entrypoint] FATAL: npm install 失败, gate require express 必崩"; _shutdown; exit 1
  fi
fi

echo "[entrypoint] starting gate on port $EXPOSED_PORT..."
# ── 9. 永续日志 (2026-07-30 全源架构): 三源 gate/ft/app raw 落 omn-raw, capture_loop 尾追+omn_redact 写 staging ──
# gate stderr → omn-raw/gate-stderr.log (capture_loop 过 omn_redact 脱敏后写 staging gate_<ts>.log 推 save).
# omn-raw 须在 scheduler folder 外 (STAGING/omn-sched): CommitScheduler 整目录 upload, _raw 在其下 → 明文混入 save = 脱敏漏泄.
# 圣旨改派: 私库日志给 AI 分析 → 须脱敏, gate 不直写 staging (旧版明文原样推已废).
# D 闸关 (OMN_LOG_TO_DATASET=0) 时 scheduler 不起, raw 文件仍写但无人推 save + 不脱敏 (稳定让性能, 如旧行).
GATE_STDERR_LOG="${DATA_DIR}/omn-raw/gate-stderr.log"
mkdir -p "$(dirname "$GATE_STDERR_LOG")" 2>/dev/null || true
# helper.sh 装插件包依赖 (boto3); logging 路仅 huggingface_hub (start.sh 已装) 无须额外包
if [ -f /logic/helper.sh ]; then
  echo "[entrypoint] helper.sh 装依赖 (boto3 插件包)..."
  bash /logic/helper.sh 2>/dev/null || echo "[entrypoint] WARN: helper.sh 失败, 插件包同步自动降级"
fi
# gate stderr → scheduler working tree (后台运行, 追加模式 >> )
node /logic/gate.js 2>>"$GATE_STDERR_LOG" &
GATE_PID=$!
echo "[entrypoint] gate PID=$GATE_PID, stderr → ${GATE_STDERR_LOG}"
export OMN_GATE_STDERR="$GATE_STDERR_LOG"

# omn_scheduler.py: 单 CommitScheduler 长驻 (路1 明文 stdout 私有 Dataset 原样推).
# 缺 HF_TOKEN/OMN_DATASET_REPO -> _start_schedulers skip 空跑待 env, 不死不崩.
# SIGTERM 经 _forward_signal 转发 -> _on_signal 安全 __exit__ scheduler (最后 upload).
python3 /logic/omn_scheduler.py &
SCHED_PID=$!
echo "[entrypoint] omn_scheduler PID=$SCHED_PID (永续日志: 明文 stderr → 私有 Dataset)"

# ── 7. 监督循环: 任一关键进程退出 → 停其余 ──
# gate 为对外服务 = 退出停一切; 上游服务为必需 = 退出停一切;
# init 非致命 (仅日志); litestream 退出按 STRICT (严格 exit / 非致命告警 PID 置空)
_init_logged=0
while true; do
  if ! kill -0 "$GATE_PID" 2>/dev/null; then
    echo "[entrypoint] gate exited. 停止其余并退出."; _shutdown; exit 1
  fi
  if ! kill -0 "$OR_PID" 2>/dev/null; then
    echo "[entrypoint] 上游服务 exited. 停止其余并退出."; _shutdown; exit 1
  fi
  if [ -n "$INIT_PID" ] && ! kill -0 "$INIT_PID" 2>/dev/null; then
    [ "$_init_logged" = 1 ] || { wait "$INIT_PID" 2>/dev/null; _init_rc=$?; if [ "$_init_rc" -ne 0 ]; then echo "[entrypoint] ✗ NIM init 已退出 rc=$_init_rc (fail-closed 触发或异常)."; else echo "[entrypoint] NIM init 已退出 rc=0 (正常完成)."; fi; _init_logged=1; }
  fi
  if [ -n "$SCHED_PID" ] && ! kill -0 "$SCHED_PID" 2>/dev/null; then
    echo "[entrypoint] WARN: omn_scheduler 已退出 (永续日志 daemon 挂). 业务不受影响, 在线 30min 内可手动抓. PID 置空."
    SCHED_PID=""
  fi
  if [ -n "$LS_PID" ] && ! kill -0 "$LS_PID" 2>/dev/null; then
    if [ "${LITESTREAM_STRICT:-0}" = 1 ]; then
      echo "[entrypoint] FATAL: Litestream replicate exited (strict). 停止."; _shutdown; exit 1
    else
      echo "[entrypoint] WARN: Litestream replicate exited (非致命). DB 不再备份 (LITESTREAM_STRICT=0)."
      LS_PID=""
    fi
  fi
  # ── FT 看门狗: 桥非致命, 死则重启 (上限 5 次后弃守降级) ──
  # 重启安全 (2026-07-30 源码实证 generateCACert 复用语义): 桥重启不换 CA,
  #   上游已载 NODE_EXTRA_CA_CERTS 不失效, 无须连带重启上游 — 与 litestream 非致命同级.
  # 弃守语义: 5 次连死 = 资产/配置级病非抖动, WARN 弃守, FT_PID 置空停止循环判;
  #   nvidia 若已注册代理即降级 (指向死桥调用必败), 人工修资产/关开关后 Restart.
  # 多桥模式 (2026-08-10): 单桥回退仍走 FT_PID 单判定; 多桥遍历 FT_PIDS 各桥判活,
  #   死桥单独重启, 重启计数累加共享 5 次封顶 (全桥累计非每桥独立, 避资源耗尽式循环).
  #   弃守后全桥 PID 置空, 不再循环判.
  if [ "${_ft_abandoned:-0}" != 1 ]; then
    if [ -n "$FT_PID" ] && [ -z "$FT_PIDS" -o "$FT_PIDS" = " $FT_PID" ] && ! kill -0 "$FT_PID" 2>/dev/null; then
      # 单桥回退路径 (FT_PIDS 空 或 仅含 FT_PID 自身): 现役单桥逻辑不动.
      _ft_restarts=$(( ${_ft_restarts:-0} + 1 ))
      if [ "$_ft_restarts" -le 5 ]; then
        echo "[entrypoint] FT 看门狗: 桥退出, 第 $_ft_restarts/5 次重启 (CA 复用不换, 上游无感)..."
        _ft_start
      else
        echo "[entrypoint] FT 看门狗: 桥 5 次连死, 弃守降级 (WARN: proxy_enabled=1 指向死桥, nvidia 路径停; 修资产或关 FLARETUNNEL_ENABLED 后 Restart)"
        FT_PID=""; FT_PIDS=""; export FT_PID FT_PIDS
        _ft_abandoned=1
      fi
    elif [ -n "$FT_PIDS" ]; then
      # 多桥路径: 遍历各桥判活, 死桥单独重启 (各桥 PID 孤立 kill -0).
      _new_pids=""; _new_ports=""; _new_names=""; _any_dead=0
      _i=0
      for fpid in $FT_PIDS; do
        _fport=$(echo "$FT_PORTS" | awk -v i=$((_i)) '{print $(i+1)}')
        _fname=$(echo "$FT_NAMES" | awk -v i=$((_i)) '{print $(i+1)}')
        if kill -0 "$fpid" 2>/dev/null; then
          # 桥活: 保 PID 入新串.
          _new_pids="$_new_pids $fpid"; _new_ports="$_new_ports $_fport"; _new_names="$_new_names $_fname"
        else
          # 桥死: 重启单桥 (保原端口/段), 累加共享计数封顶.
          _ft_restarts=$(( ${_ft_restarts:-0} + 1 )); _any_dead=1
          if [ "$_ft_restarts" -le 5 ]; then
            echo "[entrypoint] FT 看门狗: 桥 $_fname (PID=$fpid, 127.0.0.1:$_fport) 退出, 第 $_ft_restarts/5 次重启..."
            # 单桥重启: 内联执行 (复用 _ft_start 会重起全桥, 此处只重生死桥).
            _ft_verbose=""; [ "${FT_VERBOSE:-0}" = "1" ] && _ft_verbose="--verbose"
            # 从 JSON 取该桥原 workers 段 (按 name 匹配, 缺则空).
            _b_w=""; [ -f /logic/flaretunnel_bridges.json ] && _b_w=$(jq -r --arg n "$_fname" '.[] | select(.name==$n) | .workers // ""' /logic/flaretunnel_bridges.json 2>/dev/null)
            _b_wflag=""; [ -n "$_b_w" ] && _b_wflag="--workers $_b_w"
            /logic/flaretunnel tunnel --host 127.0.0.1 --port "$_fport" \
              --endpoints /logic/flaretunnel_endpoints.json \
              --relay-auth "$RELAY_AUTH" \
              --ca-dir "$FT_CA_DIR" $_b_wflag $_ft_verbose >>"${FT_LOG%.log}-$_fname.log" 2>&1 &
            _npid=$!
            _new_pids="$_new_pids $_npid"; _new_ports="$_new_ports $_fport"; _new_names="$_new_names $_fname"
          else
            echo "[entrypoint] FT 看门狗: 桥 $_fname 退出, 累计 5 次连死, 弃守降级 (全部桥停, nvidia 路径停; 修资产或关 FLARETUNNEL_ENABLED 后 Restart)"
            # 杀剩余活桥, 全弃守.
            for _dpid in $_new_pids $FT_PIDS; do kill "$_dpid" 2>/dev/null || true; done
            for _dpid in $FT_PIDS; do wait "$_dpid" 2>/dev/null || true; done
            FT_PID=""; FT_PIDS=""; export FT_PID FT_PIDS
            _ft_abandoned=1
            _new_pids=""; break
          fi
        fi
        _i=$((_i+1))
      done
      if [ "$_ft_abandoned" != 1 ] && [ -n "$_new_pids" ]; then
        FT_PIDS="${_new_pids# }"; FT_PORTS="${_new_ports# }"; FT_NAMES="${_new_names# }"; export FT_PIDS FT_PORTS FT_NAMES
      fi
    fi
  fi
  sleep 1
done
