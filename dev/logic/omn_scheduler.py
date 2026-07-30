"""omn_scheduler · 全源日志永续守护 (capture daemon + CommitScheduler)

圣上令 2026-07-30 终极旨: 靠积累 log 达 omni+nim多key+免费模型最优 (避上下文崩塌/优模型调用/便排错).
  全源架构: gate/ft/app/init 四源 raw 落 _raw 临时区 → capture daemon 尾追增量 →
    omn_redact.redact_text 脱敏 (默6正则盖类A/B/C 真 secret 形态) → 写 staging 出件 →
    CommitScheduler 内置线程读 folder 变化自动 upload 私有 Dataset save/ (给 AI 分析).
  私库只圣读为何仍脱敏: 圣旨改派"日志最终给 AI 分析", 须脱敏防 secret 进 AI 上下文流.

三件红线: 本脚本读 Space Secrets ENV, 不改 Dockerfile/start.sh. 最小打扰.
  D 总闸 OMN_LOG_TO_DATASET (默1=积累期推; =0=稳定后全数据收集层停让性能, 桥/gate/init/上游零感知).

拉起: entrypoint.sh `python3 /logic/omn_scheduler.py &` (复用现役 daemon 模式).
停: SIGTERM/SIGINT -> scheduler.__exit__ (trigger 最后 upload + stop), capture daemon daemon 自然随主退.

保留未启用链 (圣上裁砍七成, 留代码将来多人启):
  路2加密 (EncryptedScheduler): 私库只圣读 = 加密 redundant; ENCRYPTION_KEY 缺即 skip.
  db 快照 (capture_db): litestream 已复制整个 storage.sqlite, scheduler 重复.

依赖:
  - huggingface_hub (start.sh:32 自愈装, 区间 >=1.0,<2.0)
  - cryptography    (helper.sh ensure_pip 装, 缺 -> 路2 自动 skip, ImportError catch)
  - omn_redact      (同目录 omn_redact.py, PYTHONPATH=/logic; 默6正则可 ENV REDACT_PATTERNS 覆盖动态调)
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

# ── 总闸 (圣旨 D): 默1 推 save; =0 关全数据收集层让性能 (桥/gate/init/上游业务零感知) ──
LOG_TO_DATASET = os.environ.get("OMN_LOG_TO_DATASET", "1") == "1"

# ── 路径 (staging 付给 scheduler 的 working tree) ──
DATA_DIR = Path(os.environ.get("DATA_DIR", "/data"))
STAGING = DATA_DIR / "omn-sched"
STDOUT_STAGING = STAGING               # 路1 明文 JSONL staging (摊平, .log 直放 omn-sched 根, Dataset 侧 path_in_repo=save)
# RAW_DIR 须在 STAGING 外! CommitScheduler folder_path=STDOUT_STAGING=STAGING 整目录 upload,
#   _raw 若在其下 → 明文 raw (gate/ft/app/init 未脱敏) 混入 save = 圣旨脱敏漏泄.
#   故 raw 区独立分目录, scheduler 上传不触及, capture_loop 读 raw → omn_redact → 写 STDOUT_STAGING.
RAW_DIR = DATA_DIR / "omn-raw"          # 四源 raw 临时区: 明文原态, capture_loop 尾追脱敏后写 STDOUT_STAGING (不进 save)
ENC_SRC = STAGING / "enc-src"         # 路2 加密源 (redact 后拷入) [未实例化]
ENC_STAGING = STAGING / "enc-out"     # EncryptedScheduler working tree (放 .tar.gz) [未实例化]
DB_STAGING = STAGING / "db"           # db JSON staging [未调]
GATE_STDERR = Path(os.environ.get("OMN_GATE_STDERR", str(RAW_DIR / "gate-stderr.log")))

# mkdir 延迟到 main/capture 调用时 (import 无副作用, 本地无 /data 权限不崩)
def _ensure_dirs():
    for d in (STDOUT_STAGING, RAW_DIR, ENC_SRC, ENC_STAGING, DB_STAGING):
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
# E 复活: capture_stdout 泛化多源 (gate/ft/app/init 三源) 尾追增量.
#   entrypoint 三源 raw 落 RAW_DIR/*.{log}, 本函数每轮按 offset 只读新段 → omn_redact → 追写出件进 STDOUT_STAGING.
#   解决旧版两病: ① 硬编单源 gate ② 每轮全读重写=同 gate 行重复推 N 次 (squash 爆 + Dataset 垃圾).
# _CAP_OFFSETS: {raw_path: 已读字节}, 进程级; 轮转源 (app.log 上游已轮转会换 inode) 用 path 末查 size 重置.
_CAPTURE_OFFSETS = {}


def _capture_one(raw_path, out_prefix):
    """单源尾追: 按 offset 读新段 → redact → 写出件; 返回是否写出."""
    if not raw_path.exists():
        return False
    if OMN_REDACT is None:
        return False  # redact 缺 -> 不写明文 (保 secret 纪律), skip
    try:
        cur_size = raw_path.stat().st_size
    except Exception:
        return False
    prev = _CAPTURE_OFFSETS.get(str(raw_path), 0)
    # 轮转/截断: 文件变小 -> 重置 offset 从头 (上游 logRotation.ts 后新流)
    if cur_size < prev:
        prev = 0
    if cur_size == prev:
        return False  # 无新增
    try:
        with open(raw_path, "r", errors="replace") as f:
            f.seek(prev)
            chunk = f.read(cur_size - prev)
    except Exception:
        return False
    _CAPTURE_OFFSETS[str(raw_path)] = cur_size
    if not chunk.strip():
        return False
    ts = int(time.time())
    red = OMN_REDACT.redact_text(chunk)
    if not red.strip():
        return False
    out_file = STDOUT_STAGING / f"{out_prefix}_{ts}.log"
    out_file.write_text(red)
    return True


def capture_stdout():
    """三源 (gate/ft/app) raw 尾追 → redact → 写 staging 出件 (推 save).init.log 由 capture_init 单独接 (类 C)."""
    # gate stderr (logGate JSON) · ft (Go 半结构) · app (上游 structured JSONL) 三源均落 RAW_DIR
    _capture_one(RAW_DIR / "gate-stderr.log", "gate")
    _capture_one(RAW_DIR / "flaretunnel.log", "ft")
    _capture_one(RAW_DIR / "app.log", "app")


def capture_init():
    """init.log (类 C bash 全文) 尾追 → redact → 写 staging.

    init.log tee 原件现不过任何脱敏 = 圣旨真漏口; 此函数占接此路补脱敏.
    init 自 sed 5 链 (hf_snapshot 上传副本) 保留双路并行不冲突.
    init.log 滚动带戳 (init_<dt>.log), glob 多件各独立尾追 (_CAPTURE_OFFSETS 按 path 存).
    """
    for p in sorted(RAW_DIR.glob("init_*.log")):
        _capture_one(p, "init")


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
    """起 CommitScheduler (路1: staging folder → 私有 Dataset save/ 推).

    圣上 2026-07-30 终极旨: 靠积累 log 达 omni+nim多key+免费模型最优 (避上下文崩塌/优模型调用/便排错).
      全源架构 (E 脱敏层复活): gate/ft/app/init 四源 raw 落 _raw, capture daemon 尾追+omn_redact
        脱敏后写本 staging folder, scheduler 内置线程读 folder 自动 upload (私库给 AI 分析须脱敏).
      D 总闸 OMN_LOG_TO_DATASET: 默1 推 (积累期); =0 全数据收集层停让性能 (桥/gate/init/上游零感知).
      路2加密 (EncryptedScheduler) + db (capture_db) 两链不实例化 (圣上裁砍七成: 私库 dbContext litestream
        已复制; 加密私库只圣读 redundant), 留代码将来多人再启.
    """
    # D 总闸: 稳定后圣上配 OMN_LOG_TO_DATASET=0 → 全数据收集层停让性能 (不起 scheduler 不起 capture)
    if not LOG_TO_DATASET:
        return
    _ensure_dirs()
    if not OMN_DATASET_REPO or not HF_TOKEN:
        # 缺 repo/token -> skip (不死, daemon 空跑待 env 补)
        return
    # 路1: staging folder (capture daemon 写已脱敏出件) → 私有 Dataset save/ 推 (squash_history 防 history 爆)
    s1 = CommitScheduler(
        repo_id=OMN_DATASET_REPO, repo_type="dataset",
        folder_path=str(STDOUT_STAGING),
        path_in_repo="save",  # 摊平, .log/.json 直放 save/根 (Dataset nonoke/omn-logic/save)
        every=SCHED_EVERY, token=HF_TOKEN, squash_history=True,
    )
    _SCHEDULERS.extend([s1])


def _capture_loop():
    """独立 daemon 线程: 周期 capture 写 staging (scheduler 内置线程读 staging upload).

    D 总闸: OMN_LOG_TO_DATASET=0 时线程启动即早退, 不抢资源 (主链零感知).
    """
    if not LOG_TO_DATASET:
        return
    _ensure_dirs()
    while True:
        try:
            capture_stdout()
            capture_init()
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
    # E 复活: capture daemon 线程起, 三源 + init 尾追 → redact → 写 staging.
    # scheduler 内置线程读 folder_path 变化 upload 进 save. D 闸关时两线程均早退.
    _start_schedulers()
    # capture daemon (D 闸在 _capture_loop 内查, =0 即早退不起循环)
    threading.Thread(target=_capture_loop, daemon=True).start()
    signal.signal(signal.SIGTERM, _on_signal)
    signal.signal(signal.SIGINT, _on_signal)
    # 主线程挂住 (scheduler 内置 thread upload + capture daemon 尾追)
    signal.pause()


if __name__ == "__main__":
    main()
