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

依赖:
  - huggingface_hub (start.sh:32 自愈装, 区间 >=1.0,<2.0)
  - omn_redact      (同目录 omn_redact.py, PYTHONPATH=/logic; 默6正则可 ENV REDACT_PATTERNS 覆盖动态调)
"""
import os
import sys
import re
import time
import json
import signal
import threading
import subprocess
import tarfile
import tempfile
import shutil
from datetime import datetime, timezone, timedelta
from pathlib import Path

# 北京时间 (UTC+8) 显式构造, 不靠 TZ env 防漂移 (Space 默认时区不定).
# save/ 子目录内件名用可读北京时间标 + 尾 epoch 防同秒多件覆盖.
_BJ_TZ = timezone(timedelta(hours=8))

# PYTHONPATH 含本目录能 import omn_redact
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

# ── 归档 ENV (圣上令 2026-08-01: 7天前旧日志按源分四包 tar.gz 推新账号私库, 推成功后删原库腾空间) ──
# 总闸: 默1 启归档线程; =0 关. 挂在 LOG_TO_DATASET 总闸之下 (私库都关了归档无意义, 不抢资源).
ARCHIVE_ENABLED = os.environ.get("OMN_LOG_ARCHIVE", "1") == "1"
# 新私库 repo_id (圣上新账号, replaceable 满换库只改此 Secret). 空 -> skip 整归档线程.
ARCHIVE_REPO = os.environ.get("OMN_LOG_ARCHIVE_REPO", "").strip()
# 新私库 write token (新账号独立 token, 不复用 HF_TOKEN). 空 -> skip.
ARCHIVE_TOKEN = os.environ.get("OMN_LOG_ARCHIVE_TOKEN", "").strip()
# 归档天数窗: 默7 (7天前日志归档). 用 _BJ_TZ 北京时间判 (防 system TZ 漂移).
ARCHIVE_DAYS = int(os.environ.get("OMN_LOG_ARCHIVE_DAYS", "7"))
# 归档线程轮询间隔秒 (独立 daemon, 不挂 capture_loop). 默 3600s (1h).
ARCHIVE_INTERVAL = int(os.environ.get("OMN_ARCHIVE_INTERVAL", "3600"))
# 归档源 prefix 固定七源 (与 capture_loop 一致, 不复用 _capture_one 字面量防漂移)
# (2026-08-01 圣上千补: entrypoint + litestream 两源加入归档扫源, 免7天后仍占私库空间)
# (2026-08-01 圣上再令: debug 件入 save/debug/ 子目录后同构, 加入归档流可删可移归档库)
_ARCHIVE_PREFIXES = ("gate", "ft", "app", "init", "entrypoint", "litestream", "debug")

# ── 路径 (staging 付给 scheduler 的 working tree) ──
DATA_DIR = Path(os.environ.get("DATA_DIR", "/data"))
STAGING = DATA_DIR / "omn-sched"
STDOUT_STAGING = STAGING               # 路1 明文 JSONL staging (摊平, .log 直放 omn-sched 根, Dataset 侧 path_in_repo=save)
# RAW_DIR 须在 STAGING 外! CommitScheduler folder_path=STDOUT_STAGING=STAGING 整目录 upload,
#   _raw 若在其下 → 明文 raw (gate/ft/app/init 未脱敏) 混入 save = 圣旨脱敏漏泄.
#   故 raw 区独立分目录, scheduler 上传不触及, capture_loop 读 raw → omn_redact → 写 STDOUT_STAGING.
RAW_DIR = DATA_DIR / "omn-raw"          # 四源 raw 临时区: 明文原态, capture_loop 尾追脱敏后写 STDOUT_STAGING (不进 save)
GATE_STDERR = Path(os.environ.get("OMN_GATE_STDERR", str(RAW_DIR / "gate-stderr.log")))

# mkdir 延迟到 main/capture 调用时 (import 无副作用, 本地无 /data 权限不崩)
def _ensure_dirs():
    for d in (STDOUT_STAGING, RAW_DIR):
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
    return redact


OMN_REDACT = _try_import()


# ═══════════════════════════════════════════════════════════════════════
# 路2 加密 (EncryptedScheduler) 已移除 (2026-07-31 圣上裁路2 降级死代码)
# ═══════════════════════════════════════════════════════════════════════
# omn_encrypt.py + EncryptedScheduler 死类 + ENC_SRC/ENC_STAGING 路径已整段移出.
# 路2 砍七成降级后 EncryptedScheduler 从未实例化 (main 内路1+db 主链), 属死代码.
# 私库只圣读 + litestream 已复制 storage.sqlite = 加密冗余, 圣上 2026-07-29 裁降级砍.
# 恢复路径: git 历史检出 omn_encrypt.py + 本段 EncryptedScheduler 类. 见 ops/DECISIONS.md.
from huggingface_hub import CommitScheduler, HfApi, hf_hub_download


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
    t_epoch = int(time.time())
    red = OMN_REDACT.redact_text(chunk)
    if not red.strip():
        return False
    # save/<prefix>/北京时间_epoch.log — 分子目录治翻屏 + 可读时标 + epoch 防同秒覆盖
    _stamp = datetime.fromtimestamp(t_epoch, _BJ_TZ).strftime("%Y%m%d_%H%M%S")
    sub = STDOUT_STAGING / out_prefix
    sub.mkdir(parents=True, exist_ok=True)
    out_file = sub / f"{_stamp}_{t_epoch}.log"
    out_file.write_text(red)
    return True


def capture_stdout():
    """五源 (gate/ft/app/entrypoint/litestream) raw 尾追 → redact → 写 staging 出件 (推 save).init.log 由 capture_init 单独接 (类 C)."""
    # gate stderr (logGate JSON) · ft (Go 半结构) · app (上游 structured JSONL) 三源均落 RAW_DIR
    _capture_one(RAW_DIR / "gate-stderr.log", "gate")
    _capture_one(RAW_DIR / "flaretunnel.log", "ft")
    _capture_one(RAW_DIR / "app.log", "app")
    # (2026-08-01 圣上令补) 第6-7源: entrypoint boot 编排真相 + litestream R2 复制链. 两源 entrypoint.sh tee >>raw + replicate >>raw 落 omn-raw, 经 omn_redact 兜脱敏后入 save.
    _capture_one(RAW_DIR / "entrypoint.log", "entrypoint")
    _capture_one(RAW_DIR / "litestream.log", "litestream")


def capture_init():
    """init.log (类 C bash 全文) 尾追 → redact → 写 staging.

    init.log tee 原件现不过任何脱敏 = 圣旨真漏口; 此函数占接此路补脱敏.
    init 自 sed 5 链 (hf_snapshot 上传副本) 保留双路并行不冲突.
    init.log 滚动带戳 (init_<dt>.log), glob 多件各独立尾追 (_CAPTURE_OFFSETS 按 path 存).
    """
    for p in sorted(RAW_DIR.glob("init_*.log")):
        _capture_one(p, "init")


# ═══════════════════════════════════════════════════════════════════════
# 调度初始化 + 主循环
# ═══════════════════════════════════════════════════════════════════════
def _start_schedulers():
    """起 CommitScheduler (路1: staging folder → 私有 Dataset save/ 推).

    圣上 2026-07-30 终极旨: 靠积累 log 达 omni+nim多key+免费模型最优 (避上下文崩塌/优模型调用/便排错).
      全源架构 (E 脱敏层复活): gate/ft/app/init 四源 raw 落 _raw, capture daemon 尾追+omn_redact
        脱敏后写本 staging folder, scheduler 内置线程读 folder 自动 upload (私库给 AI 分析须脱敏).
      D 总闸 OMN_LOG_TO_DATASET: 默1 推 (积累期); =0 全数据收集层停让性能 (桥/gate/init/上游零感知).
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


# ═══════════════════════════════════════════════════════════════════════
# 日志归档 (圣上令 2026-08-01: 7天前旧日志按源分四包推新账号私库, 推成功后删原库腾空间)
# ═══════════════════════════════════════════════════════════════════════
# 独立 daemon 线程, 隔离 HfApi 调用 (list/upload/download/delete 全在此线程, 不挂 capture_loop).
# CommitScheduler 是 append-only 单向上传 (本地 staging 非远程 mirror), 删远程件必走 HfApi
#   list_repo_files 列远程真态, 不可盲扫本地 staging (盲删会误判孤儿件). 见 ops/DECISIONS.md.
# fail-safe 核心铁闸: 推归档库成功后才删原库件 (推失败绝删 = 丢归档). 任一步失败本轮跳过下次重试.
def _archive_loop():
    """独立 daemon 线程: 周期归档 7天前旧日志 → 打包 tar.gz 推新私库 → 删原库腾空间.

    gate: OMN_LOG_ARCHIVE=1 AND OMN_LOG_TO_DATASET=1 AND ARCHIVE_REPO+ARCHIVE_TOKEN 非空.
    缺任一 -> early return 不抢资源 (同 _capture_loop gate 模式). 挂 LOG_TO_DATASET 总闸下.
    """
    if not (ARCHIVE_ENABLED and LOG_TO_DATASET and ARCHIVE_REPO and ARCHIVE_TOKEN):
        return
    while True:
        try:
            _do_archive()
        except Exception:
            pass  # 归档错不阻循环 (下轮重试, fail-safe 保证不丢归档)
        time.sleep(ARCHIVE_INTERVAL)


def _do_archive():
    """一轮归档: 列原库 → 按 _BJ_TZ 7天窗+prefix 分组 → 逐日打包推新库 → 推成删原.

    铁闸: 推归档库成功 (或查证已归档) 后才 delete_files 删原库件. 任一步失败 -> 跳过该 prefix 该日不删.
    幂等: 推前列归档库查 archive/<prefix>/<date>.tar.gz 已存在 -> 跳推只删原件 (已归档证).
    """
    src_api = HfApi(token=HF_TOKEN)        # 原库连接 (圣上现役 nonoke/omn-logic)
    dst_api = HfApi(token=ARCHIVE_TOKEN)   # 新私库连接 (圣上新账号, 独立 token)
    # 列原库全件 (list_repo_files 返 rfilename 全路径如 save/app/xxx.log); 网络错 -> return 不盲删
    try:
        all_files = src_api.list_repo_files(OMN_DATASET_REPO, repo_type="dataset", token=HF_TOKEN)
    except Exception:
        return  # 列不出 (网络/权限) -> 下轮再来, 绝不盲删
    # 7 天窗 (北京时间): cutoff YYYYMMDD 字符串比较 == 日期比较 (同位长, 文件名首8位即北京时间日)
    cutoff = (datetime.now(_BJ_TZ) - timedelta(days=ARCHIVE_DAYS)).strftime("%Y%m%d")
    # 分组 {prefix: {date_str: [repo_path, ...]}} 仅取 ≤ cutoff 的归档件
    by_prefix_date = {p: {} for p in _ARCHIVE_PREFIXES}
    for rf in all_files:
        parts = rf.split("/")
        # capture L155 真出件三段: save/<prefix>/<stamp>_<epoch>.log (parts=3).
        # (原误判四段 len!=4 全杀致零归档, 2026-08-01 圣上 4回重启零删钉病根)
        if len(parts) != 3 or parts[0] != "save" or parts[1] not in _ARCHIVE_PREFIXES:
            continue  # 非 save/<prefix>/<fname> 结构 (快照 json 根平铺 parts=2, debug 根平铺 parts=2 自动跳)
        fname = parts[2]
        if not fname.endswith(".log"):
            continue  # 非日志件 (快照 .json 不动)
        # 日期提取兼容两构: 六源 plain `YYYYMMDD_...` (首8位纯数字) +
        #   debug `debug_YYYYMMDD_...` (debug_ 前缀, 圣上 2026-08-01 准 debug 入归档).
        #   原仅 fname[:8].isdigit() 杀 debug 前缀 -> debug 件零归档零删 (复 parts!=4 同源逻辑遗漏).
        m = re.search(r"(\d{8})_", fname)
        if not m:
            continue  # 无 YYYYMMDD_ 段 (非日志名规) 跳
        date_str = m.group(1)  # YYYYMMDD 北京时间 (capture L134 写名 + init debug_ 前缀同源 _BJ_TZ)
        if date_str > cutoff:
            continue  # 窗内新件不动 (≤ cutoff 才归档)
        by_prefix_date[parts[1]].setdefault(date_str, []).append(rf)
    # 去重: 一次性列归档库全件 (省 API), 查已归档日期集
    try:
        archived = set(dst_api.list_repo_files(ARCHIVE_REPO, repo_type="dataset", token=ARCHIVE_TOKEN))
    except Exception:
        archived = set()  # 列不出 -> 视为无历史走完整打包推 (幂等覆盖, 安全)
    # 逐 prefix 逐日归档 (推成功才删)
    for prefix in _ARCHIVE_PREFIXES:
        for date_str, file_paths in by_prefix_date[prefix].items():
            tar_pin = f"archive/{prefix}/{date_str}.tar.gz"
            already = tar_pin in archived
            tmp_dir = None
            try:
                if not already:
                    # 3d 逐件下载到临时目录 (hf_hub_download 必落盘, 无纯内存 API)
                    tmp_dir = tempfile.mkdtemp(prefix=f"omn-arch-{prefix}-{date_str}-")
                    local_files = []
                    for rf in file_paths:
                        try:
                            lp = hf_hub_download(
                                repo_id=OMN_DATASET_REPO, filename=rf,
                                repo_type="dataset", token=HF_TOKEN, local_dir=tmp_dir,
                            )
                            local_files.append((rf, lp))
                        except Exception:
                            break  # 任一件下载失败 -> abandon 该 prefix 该日, 下轮重试
                    if len(local_files) != len(file_paths):
                        continue  # 下载不全绝不推半包 (推成功才删的前提被破坏 -> 跳)
                    # 打包 tar.gz (arcname 保原 repo 路径, 解出即原 save/<prefix>/ 结构)
                    tar_path = os.path.join(tmp_dir, f"{date_str}.tar.gz")
                    with tarfile.open(tar_path, "w:gz") as tf:
                        for rf, lp in local_files:
                            tf.add(lp, arcname=rf)
                    # 推新私库
                    with open(tar_path, "rb") as f:
                        dst_api.upload_file(
                            path_or_fileobj=f, path_in_repo=tar_pin,
                            repo_id=ARCHIVE_REPO, repo_type="dataset",
                            token=ARCHIVE_TOKEN,
                            commit_message=f"archive {prefix} {date_str} ({len(file_paths)} logs)",
                        )
                # 推成功 (或已归档证 already=True) 后才删原库该日该 prefix 全件 — 铁闸
                # pattern `*{date_str}_*.log`: `*` 前缀通配兼容两构 —
                #   六源 plain `20260801_*.log` (*匹空) + debug `debug_20260801_*.log` (*匹 debug_).
                #   fnmatch `*{date_str}_` 要求紧接日期段, 他日件 (20260802_) 不含本日段不匹, 安全.
                src_api.delete_files(
                    repo_id=OMN_DATASET_REPO,
                    delete_patterns=[f"save/{prefix}/{date_str}_*.log", f"save/{prefix}/*{date_str}_*.log"],
                    repo_type="dataset", token=HF_TOKEN,
                    commit_message=f"archive: purge {prefix} {date_str} (archived to {ARCHIVE_REPO})",
                )
                archived.add(tar_pin)  # 标本批已归档, 防同轮/future 重复推
            except Exception:
                # 任一步失败 -> 本轮跳过该 prefix 该日, 绝不在推成功前删 (避免丢归档)
                continue
            finally:
                if tmp_dir and os.path.exists(tmp_dir):
                    shutil.rmtree(tmp_dir, ignore_errors=True)  # 清临时, 防爆 /tmp


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
    # 归档 daemon (gate 在 _archive_loop 内查: ARCHIVE_ENABLED+LOG_TO_DATASET+repo/token 非空, 缺任一早退)
    threading.Thread(target=_archive_loop, daemon=True).start()
    signal.signal(signal.SIGTERM, _on_signal)
    signal.signal(signal.SIGINT, _on_signal)
    # 主线程挂住 (scheduler 内置 thread upload + capture daemon 尾追)
    signal.pause()


if __name__ == "__main__":
    main()
