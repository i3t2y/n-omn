#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""k3_probe.py — kimi-k3 主动健康探针 (只读)

用途
----
定期探测 omn 网关 `/v1/chat/completions` 的 kimi-k3 上游真实吐字能力,
在故障早期输出降级/恢复信号到 stdout (一行一条, 带 UTC 时间戳)。
本脚本不做任何通知、不落盘, 输出交外部 cron / 采集器消费。

设计依据: docs/ops/k3-故障诊断-2026-09-10.md
  - 不设 temperature → 绕过上游 semanticCache, 排除 "1-5ms 假成功 200" 污染
  - stream 必须有至少 1 个非空 content delta, 空 SSE 流 (EARLY_EOF) 计失败
  - 非 stream 校验 message.content 非空
  - 单发小请求, 不触发 combo 重放, 只反映上游真实可用性

依赖: 仅 Python 标准库 (argparse/json/os/socket/ssl/sys/time/urllib)

本地验证: bash tools/mock/repro_k3_probe.sh (mock 上游, 不触网, 零副作用)

输出协议 (每行一条, UTC ISO8601 + 空格分隔)
  <UTC> PROBE mode=<stream|nostream> ok=<0|1> http=<code|-> ms=<int> verdict=<...>
  <UTC> SIGNAL K3_DEGRADED streak=<n> reason=<...>
  <UTC> SIGNAL K3_RECOVERED streak=<n> reason=<...>
  <UTC> SUMMARY ok=<n>/<total> ...

退出码: 健康 0; 处于 DEGRADED 2; 参数/环境错误 3
"""

import argparse
import json
import os
import socket
import ssl
import sys
import time
import urllib.error
import urllib.request
from datetime import datetime, timezone

DEFAULT_ENDPOINT = "https://omn.360710.xyz/v1/chat/completions"
DEFAULT_MODEL = "nvidia/moonshotai/kimi-k3"
DEFAULT_PSK_FILE = os.path.expanduser("~/.omn-secrets")

# 阈值 (env 可覆盖)
DEF_TIMEOUT = 30.0        # 单请求超时 (s) > 30s 判失败
DEF_DEGRADED_AFTER = 3    # 连续 3 次失败 → K3_DEGRADED
DEF_RECOVER_AFTER = 2     # 连续 2 次成功 → K3_RECOVERED
DEF_INTERVAL = 60.0       # 常驻模式轮询间隔 (s)


def utc_now() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def log(line: str) -> None:
    """stdout 单行输出, flush 保证 cron/采集器即时可见。"""
    sys.stdout.write(line + "\n")
    sys.stdout.flush()


def env_float(name: str, default: float) -> float:
    try:
        return float(os.environ.get(name, default))
    except (TypeError, ValueError):
        return default


def env_int(name: str, default: int) -> int:
    try:
        return int(os.environ.get(name, default))
    except (TypeError, ValueError):
        return default


def load_psk(explicit: str = None) -> str:
    """PSK 来源优先级: --psk > $K3_PSK 或 $OMN_PSK > PSK 文件首行。

    红线: 值只留在内存, 绝不回显/落盘/入日志。
    """
    if explicit:
        return explicit.strip()
    for key in ("K3_PSK", "OMN_PSK"):
        v = os.environ.get(key)
        if v:
            return v.strip()
    psk_file = os.environ.get("K3_PSK_FILE", DEFAULT_PSK_FILE)
    try:
        with open(psk_file, "r", encoding="utf-8") as fh:
            for raw in fh:
                line = raw.strip()
                if line and not line.startswith("#"):
                    return line
    except OSError:
        pass
    return ""


def build_payload(model: str, stream: bool) -> bytes:
    """构造 1-token "ok" 请求。

    刻意不设 temperature: 上游 semanticCache 仅在显式 temperature=0 时命中,
    省略即绕过缓存, 避免 1-5ms 假成功干扰判读。
    """
    payload = {
        "model": model,
        "messages": [{"role": "user", "content": "ok"}],
        "max_tokens": 1,
        "stream": bool(stream),
    }
    return json.dumps(payload).encode("utf-8")


def probe_once(endpoint: str, model: str, psk: str, stream: bool,
               timeout: float) -> dict:
    """发一次探针请求, 返回结果字典。

    返回键: ok(bool) http(int|None) ms(int) verdict(str) detail(str)
    verdict 取值: ok / http_error / timeout / network_error / empty_stream /
                  empty_content / bad_json
    """
    body = build_payload(model, stream)
    headers = {
        "Content-Type": "application/json",
        "Accept": "text/event-stream" if stream else "application/json",
    }
    if psk:
        # 生产契约: X-Gate-PSK 优先, 兼容 Authorization Bearer 由网关侧接受
        headers["X-Gate-PSK"] = psk

    req = urllib.request.Request(
        endpoint, data=body, headers=headers, method="POST",
    )
    started = time.monotonic()
    http_code = None
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            http_code = resp.getcode()
            if stream:
                outcome = consume_stream(resp)
            else:
                outcome = consume_json(resp)
    except urllib.error.HTTPError as exc:
        http_code = exc.code
        # 排空错误体, 避免连接复用问题; 内容不回显
        try:
            exc.read(4096)
        except Exception:
            pass
        elapsed = int((time.monotonic() - started) * 1000)
        return {"ok": False, "http": http_code, "ms": elapsed,
                "verdict": "http_error", "detail": "http_%s" % http_code}
    except socket.timeout:
        elapsed = int((time.monotonic() - started) * 1000)
        return {"ok": False, "http": http_code, "ms": elapsed,
                "verdict": "timeout", "detail": "socket_timeout"}
    except (urllib.error.URLError, ssl.SSLError, OSError) as exc:
        elapsed = int((time.monotonic() - started) * 1000)
        reason = getattr(exc, "reason", exc)
        return {"ok": False, "http": http_code, "ms": elapsed,
                "verdict": "network_error", "detail": type(reason).__name__}

    elapsed = int((time.monotonic() - started) * 1000)
    ok, verdict, detail = outcome
    return {"ok": ok, "http": http_code, "ms": elapsed,
            "verdict": verdict, "detail": detail}


def consume_json(resp) -> tuple:
    """非 stream: 校验 message.content 非空。"""
    raw = resp.read()
    try:
        doc = json.loads(raw.decode("utf-8", "replace"))
    except (ValueError, UnicodeDecodeError):
        return False, "bad_json", "unparseable_body"
    try:
        content = doc["choices"][0]["message"]["content"]
    except (KeyError, IndexError, TypeError):
        return False, "empty_content", "no_choices_message"
    if content is None or not str(content).strip():
        return False, "empty_content", "blank_message"
    return True, "ok", "nonempty_content"


def consume_stream(resp) -> tuple:
    """stream: 必须出现至少 1 个非空 content delta。

    空 SSE 流 (只收到 [DONE] 或干脆 EOF) 判失败 — 对齐上游 EARLY_EOF 判据。
    """
    saw_done = False
    saw_text = False
    for raw in resp:
        line = raw.decode("utf-8", "replace").strip()
        if not line or not line.startswith("data:"):
            continue
        chunk = line[5:].strip()
        if chunk == "[DONE]":
            saw_done = True
            continue
        try:
            doc = json.loads(chunk)
        except ValueError:
            continue
        for choice in doc.get("choices", []) or []:
            delta = choice.get("delta") or {}
            piece = delta.get("content")
            if piece is not None and str(piece).strip():
                saw_text = True
    if saw_text:
        return True, "ok", "stream_nonempty_delta"
    if saw_done:
        return False, "empty_stream", "done_without_content"
    # 未见任何 SSE 事件就 EOF: 上游静默掐连接 (非空流), 与空流同判失败但 detail 分开
    return False, "empty_stream", "eof_without_content"


class State:
    """跨轮次跟踪连败/连胜, 触发降级与恢复信号。"""

    def __init__(self, degraded_after: int, recover_after: int):
        self.degraded_after = degraded_after
        self.recover_after = recover_after
        self.fail_streak = 0
        self.ok_streak = 0
        self.degraded = False

    def update(self, ok: bool, reason: str) -> list:
        """喂入一次轮次结果 (stream+nostream 合并判定), 返回待输出的信号行。"""
        signals = []
        if ok:
            self.ok_streak += 1
            self.fail_streak = 0
            if self.degraded and self.ok_streak >= self.recover_after:
                signals.append(
                    "%s SIGNAL K3_RECOVERED streak=%d reason=consecutive_ok"
                    % (utc_now(), self.ok_streak)
                )
                self.degraded = False
                self.ok_streak = 0
        else:
            self.fail_streak += 1
            self.ok_streak = 0
            if (not self.degraded
                    and self.fail_streak >= self.degraded_after):
                signals.append(
                    "%s SIGNAL K3_DEGRADED streak=%d reason=%s"
                    % (utc_now(), self.fail_streak, reason)
                )
                self.degraded = True
        return signals


def run_round(state: State, args) -> bool:
    """跑一轮 (stream + 非 stream 各一)。全成功才算本轮 ok。"""
    round_ok = True
    fail_reason = "unknown"
    for stream in (True, False):
        res = probe_once(args.endpoint, args.model, args.psk, stream,
                         args.timeout)
        mode = "stream" if stream else "nostream"
        log("%s PROBE mode=%-8s ok=%d http=%-4s ms=%-6d verdict=%s detail=%s"
            % (utc_now(), mode, 1 if res["ok"] else 0,
               res["http"] if res["http"] is not None else "-",
               res["ms"], res["verdict"], res["detail"]))
        if not res["ok"]:
            round_ok = False
            fail_reason = res["verdict"]
    for sig in state.update(round_ok, fail_reason):
        log(sig)
    return round_ok


def dry_run(args) -> int:
    """离线演示: 不触网, 按脚本化序列展示状态机全生命周期。"""
    log("%s DRYRUN begin endpoint=%s model=%s"
        % (utc_now(), args.endpoint, args.model))
    state = State(args.degraded_after, args.recover_after)
    script = [
        (True, "ok", 210),
        (False, "timeout", 30000),
        (False, "http_error", 503),
        (False, "empty_stream", 12),
        (True, "ok", 180),
        (True, "ok", 205),
    ]
    for ok, verdict, ms in script:
        http = 200 if ok else (503 if verdict == "http_error" else "-")
        log("%s PROBE mode=stream   ok=%d http=%-4s ms=%-6d verdict=%s detail=dryrun"
            % (utc_now(), 1 if ok else 0, http, ms, verdict))
        log("%s PROBE mode=nostream ok=%d http=%-4s ms=%-6d verdict=%s detail=dryrun"
            % (utc_now(), 1 if ok else 0, http, ms, verdict))
        for sig in state.update(ok, verdict):
            log(sig)
        time.sleep(0.1)
    log("%s DRYRUN end final_degraded=%s" % (utc_now(), state.degraded))
    return 0


def parse_args(argv):
    p = argparse.ArgumentParser(
        description="kimi-k3 主动健康探针 (只读, stdlib-only)")
    p.add_argument("--endpoint",
                   default=os.environ.get("K3_ENDPOINT", DEFAULT_ENDPOINT),
                   help="omn /v1/chat/completions 入口")
    p.add_argument("--model",
                   default=os.environ.get("K3_MODEL", DEFAULT_MODEL),
                   help="目标模型 id")
    p.add_argument("--psk", default=None,
                   help="网关 PSK (缺省读 $K3_PSK/$OMN_PSK/~/.omn-secrets)")
    p.add_argument("--timeout", type=float,
                   default=env_float("K3_PROBE_TIMEOUT", DEF_TIMEOUT),
                   help="单请求超时秒 (默认 30; 超时即 verdict=timeout)")
    p.add_argument("--interval", type=float,
                   default=env_float("K3_PROBE_INTERVAL", DEF_INTERVAL),
                   help="常驻轮询间隔秒 (默认 60)")
    p.add_argument("--once", action="store_true",
                   help="只跑一轮 (cron 单次)")
    p.add_argument("--dry-run", action="store_true",
                   help="离线演示状态机, 不触网")
    p.add_argument("--degraded-after", type=int,
                   default=env_int("K3_DEGRADED_AFTER", DEF_DEGRADED_AFTER),
                   help="连续失败次数触发 K3_DEGRADED (默认 3)")
    p.add_argument("--recover-after", type=int,
                   default=env_int("K3_RECOVER_AFTER", DEF_RECOVER_AFTER),
                   help="连续成功次数触发 K3_RECOVERED (默认 2)")
    p.add_argument("--insecure", action="store_true",
                   help="跳过 TLS 校验 (仅调试, 默认开启校验)")
    return p.parse_args(argv)


def main(argv=None) -> int:
    args = parse_args(argv if argv is not None else sys.argv[1:])

    if args.dry_run:
        return dry_run(args)

    args.psk = load_psk(args.psk)
    if not args.psk:
        log("%s ERROR no_psk (set $K3_PSK or ~/.omn-secrets)" % utc_now())
        return 3

    if args.insecure:
        ctx = ssl.create_default_context()
        ctx.check_hostname = False
        ctx.verify_mode = ssl.CERT_NONE
        opener = urllib.request.build_opener(
            urllib.request.HTTPSHandler(context=ctx))
        urllib.request.install_opener(opener)

    state = State(args.degraded_after, args.recover_after)
    log("%s PROBE-START endpoint=%s model=%s timeout=%ss"
        % (utc_now(), args.endpoint, args.model, args.timeout))

    if args.once:
        ok = run_round(state, args)
        return 0 if ok else 2

    rounds = total_ok = 0
    try:
        while True:
            rounds += 1
            if run_round(state, args):
                total_ok += 1
            log("%s SUMMARY ok=%d/%d degraded=%s"
                % (utc_now(), total_ok, rounds, state.degraded))
            time.sleep(max(1.0, args.interval))
    except KeyboardInterrupt:
        log("%s SUMMARY ok=%d/%d degraded=%s (interrupted)"
            % (utc_now(), total_ok, rounds, state.degraded))
        return 0


if __name__ == "__main__":
    sys.exit(main())
