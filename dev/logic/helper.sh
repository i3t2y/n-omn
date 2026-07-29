#!/bin/sh
# helper.sh · omn 补包统一入口 (圣上令泛化统管各种依赖/环境/插件/文件包)
# 起手仅实装本轮 omn-* Python 依赖 (boto3), 结构泛化留扩展位:
#   包名+区间+校验函数三段可扩, 未来加包只加 helper.ensure_pip 列表不改逻辑。
# 不改 start.sh/Dockerfile 免触三件定态红线 + 免 sync-space Rebuild; 由 entrypoint.sh 调。
# 复用现役 start.sh:32 pip3 --no-cache-dir --break-system-packages + 双引号包区间串 (dash 实测安全)。
#
# 圣上 2026-07-29 裁砍七成: 路2加密降级, cryptography 不再需 (路2不实例化).
#   omn_encrypt.py/_try_import 仍 import 尝试但 _try_import except -> OMN_ENCRYPT=None 无害.
#   留 cryptography 代码 archive 不删, 将来多人/开路2 再加回此列表.
set -u

log() { echo "[helper] $*"; }

# ── pip Python 包补全 (现役实装: boto3 插件 Bucket S3) ──
# 区间驱逐: 双引号包区间串守防线, 容补丁拒破式升。默认值硬码脚本内 (不走 Dockerfile ARG
#   免触三件), 升大版本改此默认值 + 重推 sync-logic (Restart 即效, 零 Rebuild)。
# BOTO3_RANGE ENV 可覆 (圣上若要驱逐版本同 HF_HUB_RANGE 同思路扩展)。
ensure_pip() {
  for _spec in \
    "boto3${BOTO3_RANGE:->=1.28,<2.0}"
  do
    # 解包名 (_spec 形如 "boto3>=1.28,<2.0"), 校验已装跳避免重复
    _pkg=$(printf '%s' "$_spec" | sed 's/[><=].*$//')
    if python3 -c "import $_pkg" >/dev/null 2>&1; then
      log "已装 $_pkg 跳过"
      continue
    fi
    if pip3 install --no-cache-dir --break-system-packages "$_spec" >/dev/null 2>&1; then
      log "装 $_pkg ✓"
    else
      log "WARN: $_pkg 装失败 (对应链降级 skip, 主路径不受影响)"
    fi
  done
}

# ── 扩展位: 未来环境包(apt)/插件包(npm binary)/文件包(curl release tar) 入口留此 ──
#   ensure_apt() / ensure_npm_binary() / ensure_release_tar() 同 ensure_pip 模式
#   (校验已装 → 装 → WARN 不停)。本轮不实装, 圣上后续另令再扩。

ensure_pip
log "补包完成"
