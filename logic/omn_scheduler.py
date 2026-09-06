"""omn_scheduler · 全源日志永续守护 (capture daemon → Bucket 挂载直写)

Zen令 2026-07-30 终极旨: 靠积累 log 达 omni+nim多key+免费模型最优 (避上下文崩塌/优模型调用/便排错).
  2026-09-05 首席架构师裁: 数据集 dataset 链路全废弃, 收编 Bucket 挂载 save/, 写即持久.
  全源架构: gate/ft/app/init/entrypoint 五源 raw 落 _raw → capture daemon 尾追增量 →
    omn_redact.redact_text 脱敏 → 直写 Bucket 挂载 save/<prefix>/.

三件红线: 本脚本读 Space Secrets ENV, 不改 Dockerfile/start.sh. 最小打扰.
  D 总闸 OMN_LOG_TO_DATASET (默1=积累开; =0=稳定后全数据收集层停让性能, 桥/gate/init/上游零感知).

拉起: entrypoint.sh `python3 /logic/omn_scheduler.py &` (复用现役 daemon 模式).
停: mount 直写无 flush 队列, SIGTERM 即死即净 (capture 每 60s 一轮, 最坏丢一轮增量, 可接受).

依赖:
  - omn_redact (同目录 omn_redact.py, PYTHONPATH=/logic; 默6正则可 ENV REDACT_PATTERNS 覆盖动态调)
"""
import os
import sys
import re
import time
import json
import signal
import threading
from datetime import datetime, timezone, timedelta
from pathlib import Path

# 北京时间 (UTC+8) 显式构造, 不靠 TZ env 防漂移 (Space 默认时区不定).
# save/ 子目录内件名用可读北京时间标 + 尾 epoch 防同秒多件覆盖.
_BJ_TZ = timezone(timedelta(hours=8))

# PYTHONPATH 含本目录能 import omn_redact
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

# ── ENV 占位 (Zen Space Secrets 自建自持, 我零入值) ──
# 捕获间隔秒 (独立 daemon 线程)
CAPTURE_INTERVAL = int(os.environ.get("OMN_CAPTURE_INTERVAL", "60"))
# 2026-09-05 裁: OMN_DATASET_REPO / HF_TOKEN / OMN_SCHED_EVERY 废 (CommitScheduler 链删, Bucket 挂载直写无 HF API)

# ── 总闸 (圣旨 D): 默1 推 save; =0 关全数据收集层让性能 (桥/gate/init/上游业务零感知) ──
LOG_TO_DATASET = os.environ.get("OMN_LOG_TO_DATASET", "1") == "1"

# ── 归档 (2026-09-05 首席架构师裁: 整段删除) ──
# 原 7天 tar.gz 推新私库 + 删原库 daemon 已砍: 查错价值≈0 + 自身曾损坏 + litestream 已废.
# 日志真源链: capture_loop → save/ (Bucket 挂载) 直存, 人工需要时手动拿, 无自动归档层.
# ── 路径 (capture 直写 Bucket 挂载 save/, 无 staging 无 upload) ──
DATA_DIR = Path(os.environ.get("DATA_DIR", "/data"))
STDOUT_STAGING = DATA_DIR / "logs" / "save"   # Bucket 挂载直写: capture 出件即持久终态, 无中间层
# RAW_DIR 与 save/ 分立: raw 明文 (gate/ft/app/init 未脱敏) 绝不能入 save = 脱敏红线.
RAW_DIR = DATA_DIR / "logs" / "raw"   # 五源 raw 临时区: 明文原态, capture_loop 尾追脱敏后写 STDOUT_STAGING
GATE_STDERR = Path(os.environ.get("OMN_GATE_STDERR", str(RAW_DIR / "gate-stderr.log")))

# mkdir 延迟到 main/capture 调用时 (import 无副作用, 本地无 /data 权限不崩)
def _ensure_dirs():
    for d in (STDOUT_STAGING, RAW_DIR):
        try:
            d.mkdir(parents=True, exist_ok=True)
        except Exception:
            pass  # 无写权限 -> 路降级, 不阻 import

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
# 路2 加密 (EncryptedScheduler) 已移除 (2026-07-31 Zen裁路2 降级死代码)
# ═══════════════════════════════════════════════════════════════════════
# omn_encrypt.py + EncryptedScheduler 死类 + ENC_SRC/ENC_STAGING 路径已整段移出.
# 路2 砍七成降级后 EncryptedScheduler 从未实例化 (main 内路1+db 主链), 属死代码.
# 私库只圣读 + litestream 已复制 storage.sqlite = 加密冗余, Zen 2026-07-29 裁降级砍.
# 恢复路径: git 历史检出 omn_encrypt.py + 本段 EncryptedScheduler 类. 见 docs/ops/DECISIONS.md.
# huggingface_hub import 已删 (2026-09-05 CommitScheduler/HfApi/hf_hub_download 全废, Bucket 挂载直写零依赖)


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
    """四源 (gate/ft/app/entrypoint) raw 尾追 → redact → 直写 Bucket 挂载 save/. init.log 由 capture_init 单独接 (类 C)."""
    # gate stderr (logGate JSON) · ft (Go 半结构) · app (上游 structured JSONL) 三源均落 RAW_DIR
    _capture_one(RAW_DIR / "gate-stderr.log", "gate")
    # ft 源 glob 撮 flaretunnel*.log: 单桥写 flaretunnel.log (entrypoint.sh:299),
    # 多桥写 flaretunnel-<name>.log (entrypoint.sh:285) 各实例 — 桥崩/CA 等生期降级原证在这.
    # 旧写死 _capture_one(flaretunnel.log) 多桥时抓不到桥 log (Save/ft 0 件),根因证据漏.
    for _ft_raw in sorted(RAW_DIR.glob("flaretunnel*.log")):
        _capture_one(_ft_raw, "ft")
    _capture_one(RAW_DIR / "app.log", "app")
    # entrypoint boot 编排真相 (第5源): tee >>raw 落 backups/logs/raw, 经 omn_redact 兜脱敏后直写 save.
    # (litestream 源 2026-09-05 已删: 备份链废弃, raw 文件不再产生)
    _capture_one(RAW_DIR / "entrypoint.log", "entrypoint")


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
# ═══════════════════════════════════════════════════════════════════════
# 调度初始化 (2026-09-05 裁: CommitScheduler 删, 无 upload 层 — capture 直写 Bucket 挂载即终态)
# ═══════════════════════════════════════════════════════════════════════



def _capture_loop():
    """独立 daemon 线程: 周期 capture 脱敏后直写 Bucket 挂载 save/ (写即持久, 无 upload 层).

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
# ═══════════════════════════════════════════════════════════════════════
# 运行期 DB 健康探针 (Zen令 2026-09-04 裁定 SQLITE_CORRUPT 案 A: 治标最轻 = 可见性 + 调低周期)
# ═══════════════════════════════════════════════════════════════════════
# 背景: 生产 boot 多次复发 `database disk image is malformed` (audit 🚨 真问题, 非过度设计).
#   上游每 interval 跑 runDbHealthCheck(autoRepair:true) 但结果静默 (core.ts 不打日志),
#   且 runDbHealthCheck 在上游只读 core.ts, entrypoint(sh) 加不了打印.
#   方案 A 落点修正: 改走 /api/db/health 路由探针 —— 唯一能拿到健康诊断结果的可见入口
#     (management 路由, GET=诊断 autoRepair:false / POST=autoRepair:true, 须 manage scope key).
#   返回 {isHealthy, issues, repairedCount, backupCreated, autoRepair, checkedAt, driver},
#     issues 项 {type, table?, description, count}, integrity_check_failed 即物理损坏复发.
# probe 独立 daemon 线程, 周期 GET 把 issues 打日志 → entrypoint tee → save/entrypoint/ 持久.
# gate: OMNIROUTE_API_KEY 空 -> skip (真 manage key = Space Secret OMNIROUTE_API_KEY, init 种进 DB apiKeys,
#   Bearer 打 /api/* = 200 通; OMN_MANAGE_TOKEN 是 ops 误造名, 打 /api/* 必 403 AUTH_001, 见 docs/ops/STATUS.md
#   2026-09-02 排障纠错). 缺凭证不抢资源; 探针纯观测绝不影响主链.
#   probe fail-open: 任一异常只打日志, 绝不 raise 出线程.
def _db_health_loop():
    """独立 daemon 线程: 周期 GET /api/db/health 探运行期 DB 健康, issues 打日志.

    gate: OMNIROUTE_API_KEY 非空. 空 -> 早退 (探针停, 主链不受影响).
    间隔: OMN_DB_HEALTH_INTERVAL_MS 毫秒, 默 3600000 (1h; 上游周期检查默认 6h, 调低见 Space env).
    """
    token = os.environ.get("OMNIROUTE_API_KEY", "").strip()
    if not token:
        print("[db-health] skip: OMNIROUTE_API_KEY 未配 (探针停, 主链不受影响)")
        return
    try:
        import urllib.request
    except Exception:
        print("[db-health] skip: urllib.request 不可用")
        return
    port = os.environ.get("OMNIROUTE_PORT", "20128")
    try:
        interval = int(os.environ.get("OMN_DB_HEALTH_INTERVAL_MS", "3600000")) / 1000.0
    except ValueError:
        interval = 3600.0
    url = f"http://127.0.0.1:{port}/api/db/health"
    while True:
        try:
            req = urllib.request.Request(url, headers={"Authorization": f"Bearer {token}"})
            with urllib.request.urlopen(req, timeout=10) as resp:
                body = json.loads(resp.read().decode())
            issues = body.get("issues") or []
            if issues:
                for it in issues:
                    print(f"[db-health] ISSUE type={it.get('type')} table={it.get('table', '')} "
                          f"desc={it.get('description', '')} count={it.get('count', '')}")
            else:
                print(f"[db-health] healthy checkedAt={body.get('checkedAt', '')}")
        except Exception as e:
            print(f"[db-health] probe err: {e}")
        time.sleep(interval)


def _on_signal(signum, frame):
    """SIGTERM/SIGINT -> 直退 (mount 直写无 flush 队列, 即死即净)."""
    raise SystemExit(0)


def main():
    # capture daemon 直写 Bucket 挂载 save/ (无 upload 层, D 闸在 _capture_loop 内查, =0 即早退)
    threading.Thread(target=_capture_loop, daemon=True).start()
    # DB 健康探针 daemon (gate 在 _db_health_loop 内查: OMNIROUTE_API_KEY 非空, 空则早退)
    threading.Thread(target=_db_health_loop, daemon=True).start()
    signal.signal(signal.SIGTERM, _on_signal)
    signal.signal(signal.SIGINT, _on_signal)
    # 主线程挂住 (capture daemon 尾追直写 mount)
    signal.pause()


if __name__ == "__main__":
    main()
