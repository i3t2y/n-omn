#!/bin/sh
# OmniRoute 永续节点 · 自适应引导 v3.0（版本无关）
# 与逻辑层的唯一契约：Dataset 根目录必须存在 entrypoint.sh。
# 其余一切文件名、目录结构均由逻辑层自定义，本脚本不感知。
set -e
echo "[start] >>> 启动 $(date '+%F %T') <<<"
# ENV BASE_IMAGE 由 Dockerfile ARG 重声明后 ENV 转存 (docs.docker.com/reference/dockerfile/#scope),
# dev/prod 鉴别 + 排障接口: 此值随 ARG SPACE Variable 覆盖/build-arg/默认值 :stable 三层优先级而定。
# 空值若现 = start 跑老镜像层无 ENV 转存 (历史镜像), 非阻断信号。
echo "[start] 基础镜像: ${BASE_IMAGE:-(未注入 ENV, 历史镜像层)}"

# ── 1. 环境自愈（永久机制：上游 runner 镜像刻意不装工具链） ──
_need_install=0
for t in python3 curl pip3; do
  command -v "$t" >/dev/null 2>&1 || { echo "[start] 缺失基础工具: $t"; _need_install=1; break; }
done
command -v litestream >/dev/null 2>&1 || _need_install=1
{ command -v hf >/dev/null 2>&1 || command -v huggingface-cli >/dev/null 2>&1; } || _need_install=1

if [ "$_need_install" = "1" ]; then
  # 防线：自愈能力绑定 Debian 系。上游自 v2.x 起一直是 node:*-trixie-slim，
  # 若未来改发行版，明确报错优于静默跑偏。
  command -v apt-get >/dev/null 2>&1 || {
    echo "[start] FATAL: 非 Debian 系镜像且工具缺失，无法自愈"; exit 1; }
  echo "[start] 镜像 A 模式：正在补全环境（约 60s）..."
  apt-get update && apt-get install -y --no-install-recommends \
    curl jq python3 python3-pip sqlite3 ca-certificates && rm -rf /var/lib/apt/lists/*
  # huggingface_hub 区间驱逐自 ENV (Dockerfile ARG HF_HUB_RANGE + ENV 转存, 与 litestream 同模式):
  #   默认 >=1.0,<2.0 守 "拒 2.x 破式升, 容 1.x 全补丁" 防线; 升 2.x 改 ARG 默认值/HF Variable
  #   buildtime 覆盖即零改件。双引号包区间串防 shell 重定向注入 (dash 实测安全)。
  # [cli] extra 自 1.x 起不存在, CLI 内建主包。
  pip3 install --no-cache-dir --break-system-packages "huggingface_hub${HF_HUB_RANGE:->=1.0,<2.0}"
  if ! command -v litestream >/dev/null 2>&1; then
    # 镜像 A 路径补全 (BASE_IMAGE 直指裸上游 diegosouzapw/omniroute 无 litestream 时触发)。
    # 日常路径走 GHCR base (本地 tar COPY 预装) 不触发此分支。
    # 版本号驱逐自 ENV (Dockerfile ARG LITESTREAM_VERSION + ENV 转存, 永不再改三件):
    #   升 litestream 改 Dockerfile ARG 默认值 / HF Variable buildtime 覆盖, 此处零改。
    # 资产命名 v0.5.x 全程稳定 (GitHub API 实证 v0.5.9/v0.5.15 一致):
    #   litestream-{ver}-linux-{arch}.tar.gz, x86_64 直用 (官方主资产即此名, amd64 仅 VFS 扩展件),
    #   aarch64 归一 arm64。uname -m 直拼 URL (x86_64 无须映)。
    _a=$(uname -m | sed 's/aarch64/arm64/')
    _ls_v="${LITESTREAM_VERSION:-0.5.9}"
    curl -fsSL "https://github.com/benbjohnson/litestream/releases/download/v${_ls_v}/litestream-${_ls_v}-linux-${_a}.tar.gz" \
      | tar -xz -C /usr/local/bin litestream && chmod +x /usr/local/bin/litestream
  fi
  echo "[start] 环境补全完成"
else
  echo "[start] 镜像 B 模式：工具链已就绪"
fi

# ── 2. 变量校验（HF_TOKEN 可选：公共 Dataset 无需令牌） ──
[ -n "$LOGIC_BUCKET_REPO" ] || {
  echo "[start] FATAL: 缺 LOGIC_BUCKET_REPO"; exit 1; }

# ── 3. 拉取逻辑层（stderr 落盘回放脱敏，保留真实退出码） ──
#     竞速根治(2026-07-26 K3 硬化案): hf download 默认按 main HEAD resolve,
#     内容取决于 boot 时刻 vs sync-logic-dev push 完成时刻竞速 + HF resolve 端缓存浮动.
#     boot#4 15:30Z 拉出 8 员旧池(sync 15:48Z 迟 18min 抢跑旧 HEAD)即此病.
#     治法: 拉前先取 Dataset HEAD commit_id, 按 commit id 拉取 = 锁定 atomic 同 commit
#     全件, 竞速根除. fetch HEAD 失败 fail-open 回退空 (走 main HEAD) 不阻塞 boot.
echo "[start] 同步 Dataset: $LOGIC_BUCKET_REPO"
mkdir -p /tmp/logic

# 3.1 取 Dataset HEAD commit_id (HF_HOME token 自动, 值零落会话)
_rev=""
_rev_err=/tmp/.rev.err; : > "$_rev_err"
if command -v python3 >/dev/null 2>&1; then
  _rev=$(LOGIC_BUCKET_REPO="$LOGIC_BUCKET_REPO" python3 -c '
import os
try:
    os.environ.setdefault("HF_HOME", os.path.expanduser("~/.cache/huggingface"))
    from huggingface_hub import HfApi
    cid = next(iter(HfApi().list_repo_commits(os.environ["LOGIC_BUCKET_REPO"], repo_type="dataset"))).commit_id
    print(cid)
except Exception as e:
    pass  # fail-open 静默, 走 main HEAD
' 2>"$_rev_err") || true
  [ -n "$_rev" ] && echo "[start] Dataset HEAD 锁定 revision=$(printf %.12s "$_rev") (竞速根治: atomic 同点拉取)" \
                || { echo "[start] WARN: 取 HEAD commit_id 失败, 回退 main HEAD (竞速面未根治)"; [ -s "$_rev_err" ] && { [ -n "$HF_TOKEN" ] && sed "s/$HF_TOKEN/[REDACTED]/g" "$_rev_err" >&2 || cat "$_rev_err" >&2; }; }
fi

_dl() {
  _err=/tmp/.dl.err; : > "$_err"
  _tk=""; [ -n "$HF_TOKEN" ] && _tk="--token $HF_TOKEN"
  _rev_arg=""; [ -n "$_rev" ] && _rev_arg="--revision $_rev"
  if command -v hf >/dev/null 2>&1; then
    hf download "$LOGIC_BUCKET_REPO" --repo-type dataset --local-dir /tmp/logic $_tk $_rev_arg --quiet 2>"$_err"
  else
    huggingface-cli download --repo-type dataset "$LOGIC_BUCKET_REPO" --local-dir /tmp/logic $_tk $_rev_arg --quiet 2>"$_err"
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
  echo "[start] 逻辑注入完成"
else
  echo "[start] FATAL: Dataset 拉取失败"; exit 1
fi

rm -rf /tmp/logic
echo "[start] 移交控制权给逻辑层"
exec /logic/entrypoint.sh
