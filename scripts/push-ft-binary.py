#!/usr/bin/env python3
"""推 FlareTunnel 静态二进制资产 → HF Dataset ${OMN_DATASET_REPO}:/flaretunnel

路3 (2026-07-31 圣准): 桥加 /healthz+/metrics 端点后, 须替 Dataset 上现役二进制,
Space Restart 后 (零 Rebuild) Dataset sync 覆盖 /logic/flaretunnel 旧版, 桥焕新.

理由为何不入 git: 二进制产物出局经 Dataset 同步 (flaretunnel/ 源入库 ssot, 产物 .gitignore 拒).
凭用法: 读 ~/.omn-secrets 内 `HF_TOKEN_DATASET_WRITE` (目标 Dataset 写权限, 记忆 [[omn-ops-独立根]]).
  此脚本本身零硬编码凭 (§2 secrets 纪律). 圣上亲跑, 凭不进 Claude 手.

用法 (圣上在本会话以 `!` 前缀跑):
  ! python3 scripts/push-ft-binary.py
输出: upload OK commit URL; 失败打 traceback 退 1.

前置: 须先 `sh flaretunnel/build.sh` (或 docker golang:1.23-alpine 编) 生 flaretunnel/flaretunnel 产物.
"""
import os
import sys
from pathlib import Path

SECRETS = Path.home() / ".omn-secrets"
REPO_LOCAL_BIN = Path(__file__).resolve().parent.parent / "flaretunnel" / "flaretunnel"
DATASET_REPO = os.environ.get("OMN_DATASET_REPO", "")  # 目标 Dataset (运行时空注入, 值零落脚本)
PATH_IN_REPO = "flaretunnel"


def main() -> int:
    if not SECRETS.exists():
        print(f"FAIL: 凭件不存在 {SECRETS} (dev ~/omn-secrets, 见 [[omn-ops-独立根]])")
        return 1
    if not REPO_LOCAL_BIN.exists():
        print(f"FAIL: 二进制产物不存在 {REPO_LOCAL_BIN}")
        print(f"   前置编译: docker run --rm -v \"$PWD/flaretunnel:/work\" -w /work "
              f"golang:1.23-alpine sh -c 'sh /work/build.sh'")
        return 1

    # 读凭 (key 名非值, 防 secret 入 stdout)
    kv = {}
    for ln in SECRETS.read_text().splitlines():
        if "=" in ln and not ln.strip().startswith("#"):
            k, v = ln.split("=", 1)
            kv[k.strip()] = v.strip()
    token = kv.get("HF_TOKEN_DATASET_WRITE") or kv.get("HF_TOKEN")
    if not token:
        print("FAIL: ~/.omn-secrets 无 HF_TOKEN_DATASET_WRITE/HF_TOKEN key")
        return 1

    try:
        from huggingface_hub import HfApi
    except Exception as e:
        print(f"FAIL: huggingface_hub 未装 ({e})")
        print("   装: pip install --break-system-packages 'huggingface_hub>=1.0,<2.0'")
        return 1

    api = HfApi(token=token)
    print(f"push {REPO_LOCAL_BIN} (size={REPO_LOCAL_BIN.stat().st_size}B) -> {DATASET_REPO}:/{PATH_IN_REPO}")
    info = api.upload_file(
        path_or_fileobj=str(REPO_LOCAL_BIN),
        path_in_repo=PATH_IN_REPO,
        repo_id=DATASET_REPO,
        repo_type="dataset",
    )
    print("upload OK:", info)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
