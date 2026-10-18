#!/usr/bin/env python3
"""Register a provider + models + bind an existing FT proxy without restart.

POST /api/providers does not dedupe by name. Re-running full init-nim-keys.sh
duplicates connections. This script only creates missing names, posts missing
models, and bulk-assigns an existing flaretunnel-* proxy to the provider.

No sqlite writes. Uses the live management API only.
Login uses http.cookiejar and writes /tmp/omn-cookie.txt (same path as init).
"""
from __future__ import annotations

import argparse
import http.cookiejar
import json
import os
import sys
import urllib.error
import urllib.request
from typing import Any

DEFAULT_COOKIE_FILE = os.environ.get("OMN_COOKIE_FILE", "/tmp/omn-cookie.txt")


def _env_keys(name: str) -> list[str]:
    raw = os.environ.get(name, "")
    return [ln.strip() for ln in raw.splitlines() if ln.strip()]


def _cookie_header(jar: http.cookiejar.CookieJar, url: str) -> str:
    req = urllib.request.Request(url)
    jar.add_cookie_header(req)
    return req.get_header("Cookie") or ""


def _opener(cookie_file: str) -> tuple[urllib.request.OpenerDirector, http.cookiejar.MozillaCookieJar]:
    jar = http.cookiejar.MozillaCookieJar(cookie_file)
    if os.path.isfile(cookie_file):
        try:
            jar.load(ignore_discard=True, ignore_expires=True)
        except Exception:
            pass
    opener = urllib.request.build_opener(urllib.request.HTTPCookieProcessor(jar))
    return opener, jar


def _http(
    opener: urllib.request.OpenerDirector,
    method: str,
    url: str,
    body: dict | None,
    timeout: float = 30.0,
) -> tuple[int, Any]:
    data = None if body is None else json.dumps(body).encode()
    req = urllib.request.Request(
        url,
        data=data,
        method=method,
        headers={"Content-Type": "application/json", "Accept": "application/json"},
    )
    try:
        with opener.open(req, timeout=timeout) as resp:
            raw = resp.read()
            code = getattr(resp, "status", None) or resp.getcode()
            if not raw:
                return int(code), None
            try:
                return int(code), json.loads(raw)
            except json.JSONDecodeError:
                return int(code), raw.decode("utf-8", errors="replace")
    except urllib.error.HTTPError as e:
        raw = e.read()
        try:
            payload = json.loads(raw) if raw else None
        except json.JSONDecodeError:
            payload = raw.decode("utf-8", errors="replace") if raw else None
        return int(e.code), payload


def login(base: str, password: str, cookie_file: str = DEFAULT_COOKIE_FILE) -> urllib.request.OpenerDirector:
    opener, jar = _opener(cookie_file)
    code, body = _http(opener, "POST", f"{base}/api/auth/login", {"password": password})
    if code not in (200, 201):
        raise SystemExit(f"login failed http={code} body={body}")
    try:
        jar.save(ignore_discard=True, ignore_expires=True)
    except Exception as e:
        print(f"[hot_apply] WARN cookie save: {e}", flush=True)
    hdr = _cookie_header(jar, base)
    if not hdr and isinstance(body, dict) and body.get("token"):
        # some builds return JWT only
        print("[hot_apply] login ok via token body (no Set-Cookie)", flush=True)
    else:
        print(f"[hot_apply] login ok cookie_file={cookie_file}", flush=True)
    return opener


def list_connections(opener: urllib.request.OpenerDirector, base: str) -> list[dict]:
    code, body = _http(opener, "GET", f"{base}/api/providers", None)
    if code != 200:
        raise SystemExit(f"list providers failed http={code} body={body}")
    if isinstance(body, dict) and "connections" in body:
        return list(body["connections"] or [])
    if isinstance(body, list):
        return body
    return []


def list_proxies(opener: urllib.request.OpenerDirector, base: str) -> list[dict]:
    code, body = _http(opener, "GET", f"{base}/api/v1/management/proxies", None)
    if code != 200:
        code, body = _http(opener, "GET", f"{base}/api/proxies", None)
    if code != 200:
        return []
    if isinstance(body, dict) and "proxies" in body:
        return list(body["proxies"] or [])
    if isinstance(body, list):
        return body
    return []


def pick_proxy(proxies: list[dict], prefer: str | None) -> dict | None:
    named = [p for p in proxies if str(p.get("name", "")).startswith("flaretunnel-")]
    pool = named or proxies
    if not pool:
        return None
    if prefer:
        for p in pool:
            if p.get("name") == prefer or str(p.get("port")) == str(prefer):
                return p
    return pool[0]


def ensure_connection(
    opener: urllib.request.OpenerDirector,
    base: str,
    provider: str,
    name: str,
    api_key: str,
    base_url: str | None,
) -> str:
    existing = list_connections(opener, base)
    for c in existing:
        if c.get("name") == name:
            print(f"[hot_apply] connection exists name={name} id={c.get('id')}")
            return str(c["id"])
    body: dict[str, Any] = {
        "provider": provider,
        "name": name,
        "apiKey": api_key,
        "enabled": True,
    }
    if base_url:
        body["baseUrl"] = base_url
    code, resp = _http(opener, "POST", f"{base}/api/providers", body)
    if code in (200, 201) and isinstance(resp, dict) and resp.get("id"):
        print(f"[hot_apply] connection created name={name} id={resp['id']}")
        return str(resp["id"])
    if code == 409:
        for c in list_connections(opener, base):
            if c.get("name") == name:
                return str(c["id"])
    raise SystemExit(f"create connection failed name={name} http={code} body={resp}")


def ensure_models(
    opener: urllib.request.OpenerDirector, base: str, provider: str, models: list[str]
) -> None:
    for mid in models:
        code, resp = _http(
            opener,
            "POST",
            f"{base}/api/provider-models",
            {"provider": provider, "modelId": mid},
        )
        if code in (200, 201):
            print(f"[hot_apply] model ok {mid}")
        elif code == 409:
            print(f"[hot_apply] model exists {mid}")
        else:
            print(f"[hot_apply] model WARN {mid} http={code} body={resp}")


def bind_proxy(
    opener: urllib.request.OpenerDirector, base: str, provider: str, proxy_id: str
) -> None:
    body = {"scope": "provider", "scopeId": provider, "proxyId": proxy_id}
    code, resp = _http(opener, "PUT", f"{base}/api/v1/management/proxies/bulk-assign", body)
    if code in (200, 201, 204):
        print(f"[hot_apply] proxy bound provider={provider} proxyId={proxy_id}")
        return
    print(f"[hot_apply] proxy bind WARN http={code} body={resp}")


def apply_spec(opener: urllib.request.OpenerDirector, base: str, spec: dict) -> None:
    provider = spec["provider"]
    keys_env = spec.get("keys_env")
    keys = _env_keys(keys_env) if keys_env else list(spec.get("keys") or [])
    if not keys:
        raise SystemExit(f"no keys for provider={provider} (env={keys_env})")
    name_tpl = spec.get("name_template", f"{provider}-{{i}}")
    base_url = spec.get("base_url")
    models = list(spec.get("models") or [])
    prefer_proxy = spec.get("proxy_name") or spec.get("proxy_port")
    proxies = list_proxies(opener, base)
    proxy = pick_proxy(proxies, prefer_proxy)
    ids = []
    for i, key in enumerate(keys, start=1):
        name = name_tpl.format(i=i, provider=provider)
        cid = ensure_connection(opener, base, provider, name, key, base_url)
        ids.append(cid)
    if models:
        ensure_models(opener, base, provider, models)
    if proxy and proxy.get("id"):
        bind_proxy(opener, base, provider, str(proxy["id"]))
    else:
        print("[hot_apply] no FT proxy found; skipped bind")
    print(f"[hot_apply] done provider={provider} connections={len(ids)}")


def main() -> int:
    p = argparse.ArgumentParser()
    p.add_argument("--base", default=os.environ.get("OR_BASE", "http://127.0.0.1:20128"))
    p.add_argument("--spec", required=True, help="JSON file: provider/keys_env/models/...")
    p.add_argument("--password", default=os.environ.get("INITIAL_PASSWORD", ""))
    p.add_argument("--cookie-file", default=DEFAULT_COOKIE_FILE)
    args = p.parse_args()
    with open(args.spec, encoding="utf-8") as f:
        spec = json.load(f)
    base = args.base.rstrip("/")
    if os.path.isfile(args.cookie_file) and not args.password:
        opener, _ = _opener(args.cookie_file)
        print(f"[hot_apply] using existing cookie file {args.cookie_file}", flush=True)
    else:
        if not args.password:
            raise SystemExit("need INITIAL_PASSWORD or existing --cookie-file")
        opener = login(base, args.password, args.cookie_file)
    apply_spec(opener, base, spec)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
