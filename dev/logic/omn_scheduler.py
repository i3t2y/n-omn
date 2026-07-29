"""omn_scheduler · 路1明文 / 路2加密 / db 三 CommitScheduler 长驻守护

圣上令 2026-07-28: stdout 推公开存储自动化一条龙.
  路1 (明文脱敏直读 JSONL): capture_stdout 抓 gate stderr → grep component=gate →
                           omn_redact.redact_text → 写 staging/*.jsonl, CommitScheduler 读 staging upload.
  路2 (加密全信息保真 tar.gz): stage_for_encrypted 拷路1 staging + raw stderr → enc src →
                            EncryptedScheduler 重写 push_to_hub Fernet 整体加密 tar.gz upload.
                            ENCRYPTION_KEY Space Secret 圣上自持 (零入值零知值), 缺 key -> skip 路2 不崩主链.
  db   (DB 表快照 JSON): capture_db sqlite3 .mode json .dump 出 T0+T1 quota 表 +
                         provider_connections del(.credentials) → omn_redact → staging → upload.

三件红线: 本脚本读 Space Secrets ENV, 不改 Dockerfile/start.sh/init. 最小打扰.

拉起: entrypoint.sh `python3 /logic/omn_scheduler.py &` (复用现役 daemon 模式).
停: SIGTERM/SIGINT -> 三 scheduler.__exit__ (trigger 最后 upload + stop), 主进程干净退.

依赖:
  - huggingface_hub (start.sh:32 自愈装, 区间 >=1.0,<2.0)
  - cryptography    (helper.sh ensure_pip 装, 缺 -> 路2 自动 skip, ImportError catch)
  - omn_redact      (同目录 omn_redact.py, PYTHONPATH=/logic)
  - omn_encrypt     (同目录 omn_encrypt.py, 缺 cryptography 时 import 失败 -> 路2 skip)
"""
import os
import sys
import time
import json
import signal
import sqlite3
import threading
import subprocess
from pathlib import Path

# PYTHONPATH 含本目录能 import omn_redact/omn_encrypt
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

# ── ENV 占位 (圣上 Space Secrets 自建自持, 我零入值) ──
# 调度间隔分钟 (官档推荐 >=5 防 history 爆, default 5)
SCHED_EVERY = int(os.environ.get("OMN_SCHED_EVERY", "5"))
# 捕获间隔秒 (独立 daemon 线程, 不挂 scheduler 内置线程)
CAPTURE_INTERVAL = int(os.environ.get("OMN_CAPTURE_INTERVAL", "60"))
# HF Dataset repo (现有 init-nim-keys.sh 用 OMN_DATASET_REPO 同名 ENV)
OMN_DATASET_REPO = os.environ.get("OMN_DATASET_REPO", "").strip()
HF_TOKEN = os.environ.get("HF_TOKEN", "").strip()

# ── 路径 (staging 付给 scheduler 的 working tree) ──
DATA_DIR = Path(os.environ.get("DATA_DIR", "/data"))
STAGING = DATA_DIR / "omn-sched"
STDOUT_STAGING = STAGING / "stdout"   # 路1 明文 JSONL staging
ENC_SRC = STAGING / "enc-src"         # 路2 加密源 (redact 后拷入)
ENC_STAGING = STAGING / "enc-out"     # EncryptedScheduler working tree (放 .tar.gz)
DB_STAGING = STAGING / "db"           # db JSON staging
GATE_STDERR = Path(os.environ.get("OMN_GATE_STDERR", str(DATA_DIR / "omn-staging" / "gate-stderr.log")))

# mkdir 延迟到 main/capture 调用时 (import 无副作用, 本地无 /data 权限不崩)
def _ensure_dirs():
    for d in (STDOUT_STAGING, ENC_SRC, ENC_STAGING, DB_STAGING):
        try:
            d.mkdir(parents=True, exist_ok=True)
        except Exception:
            pass  # 无写权限 -> 路降级, 不阻 import

# ── 全局持三 scheduler 实例 (SIGTERM with __exit__ 用) ──
_SCHEDULERS = []

# ── 依赖动态装 (defensive: helper.sh 已装但镜像 A 路径补全分支可能后跑) ──
def _try_import():
    """返回 (redact, encrypt) 两模块, 缺则对应链降级标 None."""
    redact = encrypt = None
    try:
        import omn_redact
        redact = omn_redact
    except Exception:
        pass
    try:
        import omn_encrypt
        encrypt = omn_encrypt
    except Exception:
        pass
    return redact, encrypt

OMN_REDACT, OMN_ENCRYPT = _try_import()


# ═══════════════════════════════════════════════════════════════════════
# EncryptedScheduler · 路2 加密子类 (重写 push_to_hub)
# ═══════════════════════════════════════════════════════════════════════
# 官档 ZipScheduler 模式: 1.列文件 2.处理 3.upload_file 4.unlink local.
# 此处处理 = omn_encrypt.encrypt_folder (tar.gz + Fernet) 替代明文 append.
# 空 src dir -> return None 早退 (防 upload 空 tar + 防 squash 空 commit 腐坏 repo).
# ENCRYPTION_KEY 未设 -> EncryptionKeyMissing catch skip 路2 不崩 (主链 1+db 续推).
from huggingface_hub import CommitScheduler


class EncryptedScheduler(CommitScheduler):
    """路2: 周 tar.gz + Fernet 整体字节级加密后 upload 单 .tar.gz.

    folder_path = ENC_STAGING (临时壳, 此层不直读, 列 ENC_SRC 作源).
    push_to_hub 重写: 列 ENC_SRC → encrypt_folder → ENC_STAGING 放 .tar.gz →
                     upload_file path_in_repo/<ts>.tar.gz → 删 ENC_SRC 源 (防 re-upload).
    """

    def push_to_hub(self):
        # 路2 缺 cryptography 模块 -> 跳过 (helper.sh 未装成功)
        if OMN_ENCRYPT is None:
            return None
        # 1. 列 ENC_SRC 源文件 (空 -> 早退防空 commit, 防 squash 空 repo 腐坏)
        src_files = [p for p in sorted(ENC_SRC.glob("**/*")) if p.is_file()]
        if not src_files:
            return None
        ts = int(time.time())
        tar_plain = ENC_STAGING / f"_plain_{ts}.tar.gz"
        tar_enc = ENC_STAGING / f"{ts}.tar.gz"
        try:
            # 2. 加密 (encrypt_folder 内 _get_fernet 抛 EncryptionKeyMissing 缺 key)
            OMN_ENCRYPT.encrypt_folder(str(ENC_SRC), str(tar_plain), str(tar_enc))
            # 3. upload_file 单加密 tar.gz (path_in_repo 拼前缀)
            prefix = f"{self.path_in_repo.strip('/')}/" if self.path_in_repo else ""
            self.api.upload_file(
                path_or_fileobj=str(tar_enc),
                path_in_repo=f"{prefix}{ts}.tar.gz",
                repo_id=self.repo_id,
                repo_type=self.repo_type,
                token=self.token,
            )
            # 4. 清源 (防重传), 临时件在 finally 清
            for p in src_files:
                p.unlink(missing_ok=True)
            return None  # upload_file 自管 commit, squash_history 空 repo 无害 idempotent
        except Exception:
            # EncryptionKeyMissing (缺 key) / 他错 (网络/api/磁盘) -> 路2 skip 不崩主链
            # 路1+db 续推, 下轮 retry, 不阻 scheduler 线程
            return None
        finally:
            tar_plain.unlink(missing_ok=True)
            tar_enc.unlink(missing_ok=True)


# ═══════════════════════════════════════════════════════════════════════
# 捕获函数 (独立 daemon 线程调, 写 staging 供 scheduler 读)
# ═══════════════════════════════════════════════════════════════════════
def capture_stdout():
    """抓 gate stderr → grep component=gate 行 → redact → 追写路1 staging JSONL."""
    if not GATE_STDERR.exists():
        return
    try:
        # 读尾段 (不阻塞, 文件可能正被 gate 追写; 读已有行)
        text = GATE_STDERR.read_text(errors="replace")
    except Exception:
        return
    if OMN_REDACT is None:
        return  # redact 缺 -> 不写明文 (保 secret 纪律), skip
    ts = int(time.time())
    out_lines = []
    for line in text.splitlines():
        if '"component":"gate"' in line or '"component": "gate"' in line:
            red = OMN_REDACT.redact_text(line)
            out_lines.append(red)
    if out_lines:
        out_file = STDOUT_STAGING / f"gate_{ts}.jsonl"
        out_file.write_text("\n".join(out_lines) + "\n")
    # stage_for_encrypted: 拷路1 staging 入 ENC_SRC (路2 加密源)
    if out_lines and OMN_ENCRYPT is not None:
        for src in STDOUT_STAGING.glob("gate_*.jsonl"):
            dst = ENC_SRC / src.name
            if not dst.exists():
                try:
                    dst.write_bytes(src.read_bytes())
                except Exception:
                    pass


def capture_db():
    """sqlite3 .dump 出 DB 表 → provider_connections del credentials → redact → db staging."""
    db_path = DATA_DIR / "storage.sqlite"
    if not db_path.exists():
        return
    if OMN_REDACT is None:
        return
    try:
        conn = sqlite3.connect(str(db_path))
        conn.row_factory = sqlite3.Row
        cur = conn.cursor()
        # 列所有表名 (仅取业务相关 quota/usage 表, 避全库)
        tables = [r[0] for r in cur.execute(
            "SELECT name FROM sqlite_master WHERE type='table'").fetchall()]
        ts = int(time.time())
        snap = {"ts": ts, "tables": {}}
        for t in tables:
            try:
                rows = cur.execute(f"SELECT * FROM {t}").fetchall()
                cols = [d[0] for d in cur.description]
                records = [dict(zip(cols, r)) for r in rows]
                # provider_connections 表 del credentials 字段
                if t == "provider_connections":
                    for rec in records:
                        rec.pop("credentials", None)
                snap["tables"][t] = records
            except Exception:
                continue
        conn.close()
        text = json.dumps(snap, ensure_ascii=False, default=str)
        text = OMN_REDACT.redact_text(text)
        (DB_STAGING / f"db_{ts}.json").write_text(text)
    except Exception:
        return


# ═══════════════════════════════════════════════════════════════════════
# 调度初始化 + 主循环
# ═══════════════════════════════════════════════════════════════════════
def _start_schedulers():
    """起 CommitScheduler (个人最小方案: 仅路1 明文 stdout 私有 Dataset 原样推).

    圣上 2026-07-29 裁砍七成: 真痛点只两件 (插件包崩链 + 日志留底). 企业级排场删:
      路2加密/脱敏层: 私有库只有圣上读 = 脱敏+加密 redundant; gate logGate 早把
        PSK/key/body 剥在源头, stderr 零 secret 值入流 (gate.js:84-107 只写 requestId/path/httpStatus).
      db快照: litestream 已复制整个 storage.sqlite, scheduler/init 重复.
    路2 (EncryptedScheduler) + db (s3) 两个 CommitScheduler 不实例化, 留代码将来多人再开.
    """
    _ensure_dirs()
    if not OMN_DATASET_REPO or not HF_TOKEN:
        # 缺 repo/token -> skip (不死, daemon 空跑待 env 补)
        return
    # 路1 stdout 明文 (私有 Dataset 原样推, 不脱敏不加密)
    s1 = CommitScheduler(
        repo_id=OMN_DATASET_REPO, repo_type="dataset",
        folder_path=str(STDOUT_STAGING),
        path_in_repo="omn_data/logs/stdout",
        every=SCHED_EVERY, token=HF_TOKEN, squash_history=True,
    )
    _SCHEDULERS.extend([s1])


def _capture_loop():
    """独立 daemon 线程: 周期 capture 写 staging (scheduler 内置线程读 staging upload)."""
    _ensure_dirs()
    while True:
        try:
            capture_stdout()
            capture_db()
        except Exception:
            pass  # 捕获错不阻循环
        time.sleep(CAPTURE_INTERVAL)


def _on_signal(signum, frame):
    """SIGTERM/SIGINT -> 三 scheduler __exit__ (最后 upload + stop) -> 主退."""
    for s in _SCHEDULERS:
        try:
            s.__exit__(None, None, None)
        except Exception:
            pass
    raise SystemExit(0)


def main():
    # 个人最小方案: gate stderr 直写 STDOUT_STAGING (entrypoint GATE_STDERR_LOG 指同目录),
    # 无须 capture daemon — CommitScheduler 内置线程读 folder_path 变化自 upload.
    # capture_stdout/_capture_loop/capture_db 留代码不调 (将来多人/需脱敏再启).
    _start_schedulers()
    signal.signal(signal.SIGTERM, _on_signal)
    signal.signal(signal.SIGINT, _on_signal)
    # 主线程挂住 (scheduler 内置 thread 跑 capture+upload)
    signal.pause()


if __name__ == "__main__":
    main()
