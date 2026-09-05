#!/bin/sh
# OmniRoute 永续节点 · 自适应引导 v3.0（版本无关）
# 与逻辑层的唯一契约：Dataset 根目录必须存在 entrypoint.sh。
# 其余一切文件名、目录结构均由逻辑层自定义，本脚本不感知。
set -e
echo "[bootstrap] >>> 启动 $(date '+%F %T') <<<"

# ── 1. 环境自愈（永久机制：上游 runner 镜像刻意不装工具链） ──
_need_install=0
for t in python3 curl pip3; do
  command -v "$t" >/dev/null 2>&1 || { echo "[bootstrap] 缺失基础工具: $t"; _need_install=1; break; }
done
command -v litestream >/dev/null 2>&1 || _need_install=1
{ command -v hf >/dev/null 2>&1 || command -v huggingface-cli >/dev/null 2>&1; } || _need_install=1

if [ "$_need_install" = "1" ]; then
  # 防线：自愈能力绑定 Debian 系。上游自 v2.x 起一直是 node:*-trixie-slim，
  # 若未来改发行版，明确报错优于静默跑偏。
  command -v apt-get >/dev/null 2>&1 || {
    echo "[bootstrap] FATAL: 非 Debian 系镜像且工具缺失，无法自愈"; exit 1; }
  echo "[bootstrap] 镜像 A 模式：正在补全环境（约 60s）..."
  apt-get update && apt-get install -y --no-install-recommends \
    curl jq python3 python3-pip sqlite3 ca-certificates && rm -rf /var/lib/apt/lists/*
  # 区间钉版：容忍 1.x 全部补丁，拒绝未来的 2.x 破坏性升级。
  # （[cli] extra 自 1.x 起不存在，CLI 已内建于主包。）
  pip3 install --no-cache-dir --break-system-packages "huggingface_hub>=1.0,<2.0"
  if ! command -v litestream >/dev/null 2>&1; then
    # 资产命名经实证：v0.5.9 的 amd64 资产为 linux-x86_64，arm64 资产为 linux-arm64。
    _a=$(uname -m | sed 's/aarch64/arm64/')
    curl -fsSL "https://github.com/benbjohnson/litestream/releases/download/v0.5.9/litestream-0.5.9-linux-${_a}.tar.gz" \
      | tar -xz -C /usr/local/bin litestream && chmod +x /usr/local/bin/litestream
  fi
  echo "[bootstrap] 环境补全完成"
else
  echo "[bootstrap] 镜像 B 模式：工具链已就绪"
fi

# ── 2. 变量校验（HF_TOKEN 可选：公共 Dataset 无需令牌） ──
[ -n "$LOGIC_BUCKET_REPO" ] || {
  echo "[bootstrap] FATAL: 缺 LOGIC_BUCKET_REPO"; exit 1; }

# ── 3. 拉取逻辑层（stderr 落盘回放脱敏，保留真实退出码） ──
echo "[bootstrap] 同步 Dataset: $LOGIC_BUCKET_REPO"
mkdir -p /tmp/logic
_dl() {
  _err=/tmp/.dl.err; : > "$_err"
  _tk=""; [ -n "$HF_TOKEN" ] && _tk="--token $HF_TOKEN"
  if command -v hf >/dev/null 2>&1; then
    hf download "$LOGIC_BUCKET_REPO" --repo-type dataset --local-dir /tmp/logic $_tk --quiet 2>"$_err"
  else
    huggingface-cli download --repo-type dataset "$LOGIC_BUCKET_REPO" --local-dir /tmp/logic $_tk --quiet 2>"$_err"
  fi
  _rc=$?
  if [ -s "$_err" ]; then
    if [ -n "$HF_TOKEN" ]; then sed "s/$HF_TOKEN/[REDACTED]/g" "$_err" >&2; else cat "$_err" >&2; fi
  fi
  return $_rc
}

if _dl; then
  # 全量注入：逻辑层增删文件无需改动本脚本
  mkdir -p /logic
  cp -a /tmp/logic/. /logic/
  chmod +x /logic/*.sh 2>/dev/null || true
  echo "[bootstrap] 逻辑注入完成"
else
  echo "[bootstrap] FATAL: Dataset 拉取失败"; exit 1
fi

rm -rf /tmp/logic
echo "[bootstrap] 移交控制权给逻辑层"
exec /logic/entrypoint.sh
