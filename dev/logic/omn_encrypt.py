"""omn_encrypt · 路2 加密保真 lib
圣上令 2026-07-28: Space Secret ENCRYPTION_KEY 圣上自建自持 (与 INTERNAL_PSK 同级),
  我零入值零知值, 读 os.environ['ENCRYPTION_KEY'] 占位. Fernet (AES-128-CBC + HMAC-SHA256
  authenticated encryption) tar.gz 整体字节级加密 = 路2 保真 (加密保机密不破内容).
算法选 Fernet 而非 gpg/openssl CLI: 镜像不一定装 gpg (Debian slim 默认无), openssl CLI
  裸 AES 无 HMAC 易篡改; Fernet 内建完整性校验, 业界标准保真.
消费链: omn-scheduler.EncryptedScheduler.push_to_hub (ZipScheduler 子类模式重写):
  list src -> Fernet encrypt tar.gz -> upload_file -> unlink local.
  ENCRYPTION_KEY 未设 -> EncryptionKeyMissing -> scheduler catch skip 路2 不崩主链.
依赖: cryptography (helper.sh ensure_pip 装, 缺 ImportError 触链路2 自动 skip).
"""
import os
import tarfile
from cryptography.fernet import Fernet, InvalidToken


class EncryptionKeyMissing(RuntimeError):
    """ENCRYPTION_KEY 未设或格式错, 路2 应 skip 不崩主链 (被 scheduler 捕获)."""
    pass


def _get_fernet():
    """读 ENCRYPTION_KEY Space Secret -> Fernet 实例. 缺 key / 格式错 -> EncryptionKeyMissing."""
    key = os.environ.get("ENCRYPTION_KEY")
    if not key:
        raise EncryptionKeyMissing("ENCRYPTION_KEY 未设, 路2 skip (不崩主链, 路1+db 续推)")
    try:
        return Fernet(key.encode() if isinstance(key, str) else key)
    except Exception as e:
        raise EncryptionKeyMissing(f"ENCRYPTION_KEY 格式错: {type(e).__name__}: {e}")


def encrypt_folder(src_dir, tar_plain_path, tar_enc_path):
    """src_dir -> tar.gz 明文 -> Fernet 整体字节级加密 -> tar_enc_path.
    此函数在 push_to_hub commit 前调用, 加密发生在 commit 前 = .tar.gz 替代明文上传.
    src_dir 内容 = 路1 redact 后 stdout+db 拷贝 (tar 前已脱敏 = 加密保机密不破保真)."""
    f = _get_fernet()  # 缺 key 抛 EncryptionKeyMissing 由 scheduler 捕获
    # 1. tar.gz 明文 (tarfile 标准库, 免外部依赖) - 源 = 路1 已 redact 文本
    with tarfile.open(tar_plain_path, "w:gz") as tar:
        for root, _, files in os.walk(src_dir):
            for fn in files:
                full = os.path.join(root, fn)
                arc = os.path.relpath(full, src_dir)
                tar.add(full, arcname=arc)
    # 2. Fernet 整体字节级加密 (保真: 加密可逆不破内容)
    with open(tar_plain_path, "rb") as fp:
        plain = fp.read()
    enc = f.encrypt(plain)
    with open(tar_enc_path, "wb") as fp:
        fp.write(enc)


def decrypt_file(tar_enc_path, out_dir, key=None):
    """双向验证: Fernet decrypt -> tar.gz -> untar 到 out_dir.
    验证用 (圣上本地持 ENCRYPTION_KEY 解), InvalidToken -> key 错或被篡改.
    运行链路2 不调此 (仅加密), 此函数供圣上/审计回读验证 .tar.gz 可还原."""
    import tempfile
    f = Fernet((key or os.environ["ENCRYPTION_KEY"]).encode()
               if isinstance(key or os.environ.get("ENCRYPTION_KEY"), str)
               else (key or os.environ["ENCRYPTION_KEY"]))
    with open(tar_enc_path, "rb") as fp:
        enc = fp.read()
    plain = f.decrypt(enc)  # InvalidToken 抛 = key 错/被篡改 (验证端报错, 不影响运行链)
    with tempfile.NamedTemporaryFile(suffix=".tar.gz", delete=False) as tmp:
        tmp.write(plain)
        tmp_path = tmp.name
    try:
        with tarfile.open(tmp_path, "r:gz") as tar:
            os.makedirs(out_dir, exist_ok=True)
            tar.extractall(out_dir)
    finally:
        os.remove(tmp_path)
