"""omn_bucket_sync · omniroute 插件静态包推公开 S3 Bucket

圣上令 2026-07-28: "如果加上 omniroute 自带未安装插件保存, 搜索查证哪种选择收益最大".
  结论: 插件静态包 (node_modules/ + bin/ cliproxyapi-<ver>) 收益最大 —
  Space 48h 休眠自醒 ephemeral 丢即重装 10-100MB/件, 推 Bucket = 重启恢复读而非网装,
  解"插件丢失致 service 崩链"真痛点 (源 agent B 实证: services/ + bin/ 不在 litestream 复制范围).

职责: walk DATA_DIR/services/{9router,cliproxy,mux,bifrost}/node_modules +
      DATA_DIR/bin/cliproxyapi-<ver>/ → boto3 upload_file 公开 Bucket,
      增量跳已存 (head_object 404 才传, 存在且 size 同则 skip).

与 litestream R2 独立 (litestream 复制 storage.sqlite; 此脚本复制插件静态包; 两路 S3 正交).
公开 Bucket ≠ R2 (R2 是运行态私有; 推荐 cbucket/MinIO/任意公开读 S3 兼容作插件 CDN).

拉起: init-nim-keys.sh 末 OMN_BUCKET_SYNC=1 触发一次 (subprocess 调, 不长驻).
停: 进程自然退 (单次 walk 完 upload 即 exit).

依赖: boto3 (helper.sh ensure_pip 装, 缺 -> ImportError 退非零, init catch 降级).

ENV 占位 (圣上 Space Secrets 自建自持, 我零入值零知值):
  OMN_BUCKET_ENDPOINT         # S3 兼容端点 (https://s3.example.com)
  OMN_BUCKET_ACCESS_KEY_ID    # access key (env, 非硬编)
  OMN_BUCKET_SECRET_ACCESS_KEY # secret key (env)
  OMN_BUCKET_NAME             # bucket 名
  OMN_BUCKET_PREFIX           # repo 内对象前缀 (如 plugins/)
  DATA_DIR                    # 持久卷根 (默认 /data)
"""
import os
import sys
from pathlib import Path

DATA_DIR = Path(os.environ.get("DATA_DIR", "/data"))
SERVICES_DIR = DATA_DIR / "services"
BIN_DIR = DATA_DIR / "bin"

# 四个 omniroute service + bin/ cliproxyapi (源 omniroute bootstrap.ts SERVICES + cliproxy binary)
SERVICE_NAMES = ["9router", "cliproxy", "mux", "bifrost"]
BIN_PREFIX = "cliproxyapi-"

# 需要的 Bucket ENV 齐 + 值非空
def _bucket_env_ok():
    return all(os.environ.get(k, "").strip() for k in (
        "OMN_BUCKET_ENDPOINT", "OMN_BUCKET_ACCESS_KEY_ID",
        "OMN_BUCKET_SECRET_ACCESS_KEY", "OMN_BUCKET_NAME"))


def _make_client():
    """建 boto3 S3 client (S3 兼容端点, region auto 兼容 R2/MinIO/CB 等)."""
    import boto3
    return boto3.client(
        "s3",
        endpoint_url=os.environ["OMN_BUCKET_ENDPOINT"],
        aws_access_key_id=os.environ["OMN_BUCKET_ACCESS_KEY_ID"],
        aws_secret_access_key=os.environ["OMN_BUCKET_SECRET_ACCESS_KEY"],
        region_name=os.environ.get("OMN_BUCKET_REGION", "auto"),
    )


def _exists(s3_client, key, local_size):
    """head_object key; 存在且 size 同 -> skip (增量). 404/异 -> 传."""
    try:
        resp = s3_client.head_object(
            Bucket=os.environ["OMN_BUCKET_NAME"], Key=key)
        return resp.get("ContentLength", -1) == local_size
    except Exception:
        return False  # 404 (NoSuchKey) 或他错 -> 视为不存在, 上传


def _walk_sources():
    """yield (local_path, rel_key) for 所有须传件."""
    # services/<name>/node_modules/**
    for name in SERVICE_NAMES:
        nm = SERVICES_DIR / name / "node_modules"
        if nm.is_dir():
            for p in sorted(nm.rglob("*")):
                if p.is_file():
                    # key: plugins/services/<name>/node_modules/<rel>
                    rel = p.relative_to(SERVICES_DIR)
                    yield p, str(rel)
    # bin/cliproxyapi-<ver>/**
    if BIN_DIR.is_dir():
        for p in sorted(BIN_DIR.rglob("*")):
            if p.is_file() and (p.parent.name.startswith(BIN_PREFIX)
                                or str(p.relative_to(BIN_DIR)).startswith(BIN_PREFIX)):
                rel = p.relative_to(DATA_DIR)
                yield p, str(rel)


def main():
    # ENV 未齐 skip 不崩 (init-nim-keys.sh 调用方 catch 降级)
    if not _bucket_env_ok():
        print("[omn-bucket-sync] OMN_BUCKET_* 未齐, skip (插件包不推公开 Bucket)")
        return 0
    try:
        s3 = _make_client()
    except ImportError:
        print("[omn-bucket-sync] boto3 未装 (helper.sh 没跑成功?), skip")
        return 0  # 0 非 1: init 调用方不为插件包同步失败炸主链
    except Exception as e:
        # 不回显 env 值 (防 secret 纪律)
        print(f"[omn-bucket-sync] 建 client 失败: {type(e).__name__}, skip")
        return 0

    prefix = os.environ.get("OMN_BUCKET_PREFIX", "plugins/").strip("/")
    uploaded = skipped = failed = 0
    for local_path, rel_key in _walk_sources():
        key = f"{prefix}/{rel_key}" if prefix else rel_key
        try:
            size = local_path.stat().st_size
            if _exists(s3, key, size):
                skipped += 1
                continue
            s3.upload_file(str(local_path), os.environ["OMN_BUCKET_NAME"], key)
            uploaded += 1
        except Exception:
            failed += 1  # 单件失败不阻其余, 计数
    print(f"[omn-bucket-sync] 传 {uploaded} 跳 {skipped} 失 {failed}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
