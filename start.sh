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

# ── 3. 拉取逻辑层（Bucket 源, manifest 版本钉补回 atomic 锁） ──
#     2026-08-25 换 Bucket (圣上批 B): nonoke 锁后 Dataset 拉 403, 迁 xnexus/logic Bucket.
#     Bucket 非版本化无 commit_id/revision → 无 atomic 快照. 竞速根治手工补回:
#       manifest.json = 提交点 (记 n-omn@SHA + 每文件 sha256), 由 CI 推文件后最后写.
#       boot 先拉 manifest + 8 件, 逐文件校验 sha256 与 manifest 一致 = 同点全件.
#       不一致 (manifest 旧文件新 或 文件旧 manifest 新) = 撞到 push 窗口 → fail 退出,
#       下个 boot 重拉自愈 (push 完成 manifest 更新后再拉即对). 竞速面被哈希抓住.
echo "[start] 同步 Bucket: $LOGIC_BUCKET_REPO"
mkdir -p /tmp/logic

_logic_err=/tmp/.logic.err; : > "$_logic_err"
# 3.1 拉 manifest + 9 件 (8 业务 + flaretunnel 二进制) + 校验 sha256 (HF_HOME/HF_TOKEN 环境自动, 值零落会话)
#     flaretunnel 二进制 = 逻辑层资产 (entrypoint L217 注释), 源 flaretunnel/FlareTunnel.go 编译,
#     与 8 件同批上传同 manifest 校验 (9/22 nonoke 删后迁 Bucket 时未随迁, boot WARN 跳 FT 根因).
if command -v python3 >/dev/null 2>&1; then
  if LOGIC_BUCKET_REPO="$LOGIC_BUCKET_REPO" python3 -c '
import os, hashlib, json, sys
from huggingface_hub import download_bucket_files
repo = os.environ["LOGIC_BUCKET_REPO"]
files = ["entrypoint.sh","gate.js","init-nim-keys.sh","litestream.yml","package.json",
         "helper.sh","omn_redact.py","omn_scheduler.py","flaretunnel"]
local = "/tmp/logic"
try:
    download_bucket_files(repo, files=[("manifest.json", f"{local}/manifest.json")] + [(f, f"{local}/{f}") for f in files])
except Exception as e:
    print(f"[start] FATAL: 拉取 Bucket 失败: {type(e).__name__}", file=sys.stderr); sys.exit(1)
mp = f"{local}/manifest.json"
if not os.path.isfile(mp):
    print("[start] FATAL: 缺 manifest.json (Bucket 未初始化或拉取窗口)", file=sys.stderr); sys.exit(1)
manifest = json.load(open(mp))
mfiles = manifest.get("files", {})
bad = []
for f in files:
    if f not in mfiles:
        print(f"[start] FATAL: manifest 缺 {f}", file=sys.stderr); sys.exit(1)
    fp = f"{local}/{f}"
    if not os.path.isfile(fp):
        bad.append(f); continue
    h = hashlib.sha256(open(fp, "rb").read()).hexdigest()
    if h != mfiles[f]:
        bad.append(f)
if bad:
    print(f"[start] FATAL: {len(bad)} 文件 sha256 与 manifest 不一致 {bad} — 撞到 push 窗口, 下个 boot 自愈", file=sys.stderr); sys.exit(1)
_n = str(manifest.get("n-omn", "?"))[:7]
print(f"[start] Bucket 校验通过 (n-omn@{_n} {len(files)} 件 sha256 全对)")
' 2>"$_logic_err"; then
    :
  else
    if [ -n "$HF_TOKEN" ]; then sed "s/$HF_TOKEN/[REDACTED]/g" "$_logic_err" >&2; else cat "$_logic_err" >&2; fi
    echo "[start] FATAL: 拉取逻辑层失败 (manifest 校验未过)"; exit 1
  fi
else
  echo "[start] FATAL: 缺 python3 无法拉 Bucket"; exit 1
fi

# 3.2 FT Worker 端点 (独立写入者: deploy-ft-workers CI, 非 sync-logic manifest 管)
#     另拉 flaretunnel_endpoints.json — 可选件 (entrypoint 缺则跳 FT, 非阻断).
#     不进 manifest 版本钉: 由 deploy-ft-workers 独立写, 与 dev/logic 8 件不同写入者不同节奏.
if command -v python3 >/dev/null 2>&1; then
  LOGIC_BUCKET_REPO="$LOGIC_BUCKET_REPO" python3 -c '
import os, sys
from huggingface_hub import download_bucket_files
repo = os.environ["LOGIC_BUCKET_REPO"]
try:
    download_bucket_files(repo, files=[("flaretunnel_endpoints.json", "/tmp/logic/flaretunnel_endpoints.json")])
except Exception as e:
    print(f"[start] WARN: 拉 flaretunnel_endpoints.json 失败 (FT 未用则忽略): {type(e).__name__}", file=sys.stderr)
' 2>"$_logic_err" || true
  [ -s "$_logic_err" ] && { if [ -n "$HF_TOKEN" ]; then sed "s/$HF_TOKEN/[REDACTED]/g" "$_logic_err" >&2; else cat "$_logic_err" >&2; fi; }
fi

# 全量注入：逻辑层增删文件无需改动本脚本
mkdir -p /logic
cp -a /tmp/logic/. /logic/
chmod +x /logic/*.sh 2>/dev/null || true
echo "[start] 逻辑注入完成"

rm -rf /tmp/logic
echo "[start] 移交控制权给逻辑层"
exec /logic/entrypoint.sh
