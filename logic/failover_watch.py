#!/usr/bin/env python3
"""failover_watch - provider 连接池摘除 + 冷却回池 (n-omn issue #2, plan A)

定案 (2026-10-18):
- 请求内首字节切换做不到 (选路在 Next.js 后端 :20128 黑盒), 只做池级摘除 + 冷却回池.
- 借鉴 magpie internal/gateway/fallback.go: 失败冷却 (默认 60s 对齐).
- 登录复用 hot_apply.py 样板 (cookie /tmp/omn-cookie.txt, INITIAL_PASSWORD).
- 拉起: entrypoint.sh `python3 /logic/failover_watch.py &` (daemon 模式, 同 omn_scheduler).
- 日志: $DATA_DIR/backups/logs/raw/failover-watch.log + stdout (和 shipper 对齐).

ENV:
  FAILOVER_WATCH_ENABLED  总闸 (entrypoint.sh 判断, 默认 1)
  FAILOVER_DRY_RUN        默认 1: 只打日志不动真格; =0 才调 toggle 接口
  FAILOVER_POLL_SEC       轮询间隔秒, 默认 60
  FAILOVER_COOLDOWN_SEC   冷却秒, 默认 60 (和 magpie 对齐)
  FAILOVER_MAX_DISABLE    单轮最多摘除数, 默认 5 (防误杀)
  FAILOVER_MIN_ENABLED    摘完池内最少保留 enabled 数, 默认 1
  FAILOVER_WATCH_PROXIES  =1 时连 proxies 一起看 (默认 0, 钩子未实现)
  OR_BASE                 后端基址, 默认 http://127.0.0.1:20128
  INITIAL_PASSWORD / OMN_COOKIE_FILE  (复用 hot_apply)
  DATA_DIR                日志目录, 默认 /opt/omn-data

钩子 (Z 后面收紧规则):
  - is_blocked(conn, ctx): 判定 blocked 的条件
    (HTTP 状态 / 连续失败次数 / 后端返回的 status 字段)
  - set_enabled(): toggle 接口待实测 (PUT/PATCH /api/providers/{id})
  - poll_proxies(): FT 代理池, 必要时再做 (和模型上游故障转移是两条线)
"""
from __future__ import annotations

import os
import sys
import time
import urllib.request

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from hot_apply import _http, _opener, list_connections, login, DEFAULT_COOKIE_FILE

BASE = os.environ.get("OR_BASE", "http://127.0.0.1:20128").rstrip("/")
POLL_SEC = int(os.environ.get("FAILOVER_POLL_SEC", "60"))
COOLDOWN_SEC = int(os.environ.get("FAILOVER_COOLDOWN_SEC", "60"))
MAX_DISABLE = int(os.environ.get("FAILOVER_MAX_DISABLE", "5"))
MIN_ENABLED = int(os.environ.get("FAILOVER_MIN_ENABLED", "1"))
DRY_RUN = os.environ.get("FAILOVER_DRY_RUN", "1") == "1"
WATCH_PROXIES = os.environ.get("FAILOVER_WATCH_PROXIES", "0") == "1"
DATA_DIR = os.environ.get("DATA_DIR", "/opt/omn-data")
LOG_FILE = os.path.join(DATA_DIR, "backups", "logs", "raw", "failover-watch.log")

BLOCKED_STATUSES = {"blocked", "error", "failed"}


def log(msg: str) -> None:
    line = f"[failover-watch] {time.strftime('%Y-%m-%d %H:%M:%S')} {msg}"
    print(line, flush=True)
    try:
        os.makedirs(os.path.dirname(LOG_FILE), exist_ok=True)
        with open(LOG_FILE, "a", encoding="utf-8") as f:
            f.write(line + "\n")
    except Exception:
        pass


# ── 钩子 1: 判定 blocked ──────────────────────────────────────────────
def is_blocked(conn: dict, ctx: dict) -> tuple[bool, str]:
    """conn: GET /api/providers 的单个 connection dict.
    ctx: {"fails": 连续命中次数}.
    返回 (是否blocked, 原因). Z 后面收紧: 当前只认后端明确吐出的状态字, 不猜.
    候选加码 (待后端字段实测): conn['lastError']/['error'] 非空 + fails>=N,
    或探活该 connection 的模型端点看 HTTP 状态. """
    st = str(conn.get("status") or "").strip().lower()
    if st in BLOCKED_STATUSES:
        return True, f"status={st}"
    return False, ""


# ── 钩子 2: toggle enabled (待实测) ────────────────────────────────────
_toggle_method: str | None = None  # 实测出哪个能用就记住


def set_enabled(opener, base: str, cid: str, enabled: bool) -> bool:
    """PUT/PATCH /api/providers/{id} {"enabled": bool}. 返回是否成功.
    DRY_RUN 下只打日志. 若两个都失败, 打 ERROR 提示实测等价接口. """
    global _toggle_method
    if DRY_RUN:
        log(f"dry-run: would set enabled={str(enabled).lower()} id={cid}")
        return True
    cands = [_toggle_method] if _toggle_method else ["PUT", "PATCH"]
    for m in cands:
        try:
            code, body = _http(opener, m, f"{base}/api/providers/{cid}", {"enabled": enabled})
        except Exception as e:  # noqa: BLE001 - 网络抖动下轮重试
            log(f"toggle {m} id={cid} exc={type(e).__name__}: {e}")
            continue
        if code in (200, 201, 204):
            if not _toggle_method:
                _toggle_method = m
                log(f"toggle API 实测可用: {m} /api/providers/{{id}}")
            return True
        log(f"toggle {m} id={cid} http={code} body={str(body)[:200]}")
    log("ERROR toggle API 未找到 (PUT/PATCH /api/providers/{id} 均失败), 需实测等价接口")
    return False


# ── 钩子 3: FT 代理池 (和模型上游是两条线, 必要时再做) ──────────────────
def poll_proxies(opener) -> None:
    """GET /api/v1/management/proxies 看代理状态. 当前 stub. """
    pass


def key_of(conn: dict) -> str:
    return str(conn.get("id") or conn.get("name"))


def get_opener():
    cookie_file = os.environ.get("OMN_COOKIE_FILE", DEFAULT_COOKIE_FILE)
    password = os.environ.get("INITIAL_PASSWORD", "")
    if os.path.isfile(cookie_file) and not password:
        opener, _ = _opener(cookie_file)
        return opener
    if not password:
        raise SystemExit("无 INITIAL_PASSWORD 且无 cookie, 等下轮")
    return login(BASE, password, cookie_file)


def tick(fails: dict, disabled_at: dict) -> None:
    opener = get_opener()
    conns = list_connections(opener, BASE)
    now = time.time()

    # 1) 冷却回池
    for k, ts in list(disabled_at.items()):
        if now - ts >= COOLDOWN_SEC:
            if set_enabled(opener, BASE, k, True):
                if not DRY_RUN:
                    log(f"re-enable id={k} (冷却 {COOLDOWN_SEC}s 到)")
                    del disabled_at[k]
                    fails.pop(k, None)
                else:
                    log(f"dry-run: 冷却到, 本应 re-enable id={k}")

    # 2) 摘除
    victims: list[tuple[str, dict, str]] = []
    for c in conns:
        k = key_of(c)
        if k in disabled_at:
            continue
        if not c.get("enabled", True):
            continue  # 别人/手动关掉的, 不碰
        blocked, reason = is_blocked(c, {"fails": fails.get(k, 0)})
        if blocked:
            fails[k] = fails.get(k, 0) + 1
            victims.append((k, c, reason))
        else:
            fails.pop(k, None)

    alive = sum(1 for c in conns if c.get("enabled", True) and key_of(c) not in disabled_at)
    budget = max(0, min(MAX_DISABLE, alive - MIN_ENABLED))
    for k, c, reason in victims[:budget]:
        ok = set_enabled(opener, BASE, k, False)
        tag = "dry-run: " if DRY_RUN else ""
        if ok and not DRY_RUN:
            disabled_at[k] = now
        log(f"{tag}{'disable' if ok else 'disable-FAILED'} "
            f"id={k} name={c.get('name', '?')} reason={reason} fails={fails.get(k)}")
    if len(victims) > budget:
        log(f"WARN 熔断保护: {len(victims)} 个命中 blocked, 本轮只摘 {budget} 个 "
            f"(MAX_DISABLE={MAX_DISABLE}/MIN_ENABLED={MIN_ENABLED})")

    # 3) 代理池钩子
    if WATCH_PROXIES:
        poll_proxies(opener)


def main() -> None:
    log(f"start base={BASE} poll={POLL_SEC}s cooldown={COOLDOWN_SEC}s "
        f"dry_run={DRY_RUN} max_disable={MAX_DISABLE}")
    if WATCH_PROXIES:
        log("proxies hook: stub, 未实现")
    fails: dict = {}
    disabled_at: dict = {}
    while True:
        try:
            tick(fails, disabled_at)
        except SystemExit as e:
            log(f"tick SystemExit: {e}")
        except Exception as e:  # noqa: BLE001 - daemon 不死, 下轮重试
            log(f"tick exc {type(e).__name__}: {e}")
        time.sleep(POLL_SEC)


if __name__ == "__main__":
    main()
