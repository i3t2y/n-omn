#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""mock_k3_upstream.py — k3_probe.py 本地验证用 mock 上游 (stdlib-only, 零副作用)

用途
----
离线复现 `tools/k3_probe.py` 的判据, 让 docs/ops/evidence/ 下的样例**可重跑**,
不依赖生产 omn 入口、不触网、不需要真 PSK。

路由 (POST /v1/chat/completions, 读请求体 stream 字段决定返回形态)
  /ok     200 + 真 SSE 非空 content delta / 非 stream 非空 message.content
  /empty  200 + SSE 只到 [DONE] (EARLY_EOF) / 非 stream 空 message.content
  /err    503 (上游 5xx)
  /slow   睡眠 --slow 秒后返回 (配 k3_probe --timeout 3 触发 timeout)
  /switch 前 --bad-rounds 轮失败, 之后成功 (验证 DEGRADED → RECOVERED 全周期)

用法
----
  python3 tools/mock/mock_k3_upstream.py --port 8790                 # 起 mock
  bash tools/mock/repro_k3_probe.sh                                  # 一键复现全部证据
"""

import argparse
import json
import sys
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

SSE_OK = (b'data: {"id":"c1","choices":[{"index":0,"delta":{"content":"ok"}}]}\n\n'
          b'data: {"id":"c1","choices":[{"index":0,"delta":{},"finish_reason":"stop"}]}\n\n'
          b'data: [DONE]\n\n')

SSE_EMPTY = (b'data: {"id":"c2","choices":[{"index":0,"delta":{},"finish_reason":"stop"}]}\n\n'
             b'data: [DONE]\n\n')

JSON_OK = {"choices": [{"message": {"role": "assistant", "content": "ok"}}]}
JSON_EMPTY = {"choices": [{"message": {"role": "assistant", "content": ""}}]}

_STATE = {"calls": 0}


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    slow_seconds = 10.0
    bad_rounds = 3        # /switch: 前 N 轮 (每轮 2 发) 返回坏响应

    def log_message(self, *args):   # 静音, 保持 stdout 干净
        pass

    def do_POST(self):
        path = self.path.split("?")[0]
        length = int(self.headers.get("content-length") or 0)
        raw = self.rfile.read(length) if length else b""
        try:
            doc = json.loads(raw or b"{}")
        except ValueError:
            doc = {}
        stream = bool(doc.get("stream"))

        if path == "/ok":
            return self._ok(stream)
        if path == "/empty":
            return self._empty(stream)
        if path == "/err":
            return self._send(503, b'{"error":"upstream unavailable"}',
                              "application/json")
        if path == "/slow":
            time.sleep(self.slow_seconds)
            return self._ok(stream)
        if path == "/switch":
            _STATE["calls"] += 1
            good = _STATE["calls"] > self.bad_rounds * 2
            return self._ok(stream) if good else self._empty(stream)
        return self._send(404, b'{"error":"not found"}', "application/json")

    # ── helpers ──────────────────────────────────────────────
    def _ok(self, stream):
        if stream:
            return self._send(200, SSE_OK, "text/event-stream")
        return self._send(200, json.dumps(JSON_OK).encode(), "application/json")

    def _empty(self, stream):
        if stream:
            return self._send(200, SSE_EMPTY, "text/event-stream")
        return self._send(200, json.dumps(JSON_EMPTY).encode(), "application/json")

    def _send(self, code, body, ctype):
        self.send_response(code)
        self.send_header("content-type", ctype)
        self.send_header("cache-control", "no-cache")
        self.send_header("content-length", str(len(body)))
        self.end_headers()
        try:
            self.wfile.write(body)
        except OSError:
            pass


def main(argv=None):
    p = argparse.ArgumentParser(description="k3_probe 本地 mock 上游 (只读, 零副作用)")
    p.add_argument("--port", type=int, default=8790)
    p.add_argument("--slow", type=float, default=10.0,
                   help="/slow 睡眠秒数 (默认 10, 配 --timeout 3 触发 timeout)")
    p.add_argument("--bad-rounds", type=int, default=3,
                   help="/switch 前 N 轮失败 (默认 3)")
    args = p.parse_args(argv)

    Handler.slow_seconds = args.slow
    Handler.bad_rounds = args.bad_rounds
    srv = ThreadingHTTPServer(("127.0.0.1", args.port), Handler)
    print("mock_k3_upstream on 127.0.0.1:%d "
          "(/ok /empty /err /slow /switch)" % args.port, flush=True)
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        srv.server_close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
