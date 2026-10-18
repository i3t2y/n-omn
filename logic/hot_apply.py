#!/usr/bin/env python3
"""Register a provider + models + bind an existing FT proxy without restart.

POST /api/providers does not dedupe by name. Re-running full init-nim-keys.sh
duplicates connections. This script only creates missing names, posts missing
models, and bulk-assigns an existing flaretunnel-* proxy to the provider.

No sqlite writes. Uses the live management API only.
"""
from __future__ import annotations

import argparse
import json
import os
import sys
import urllib.error
import urllib.request
from typing import Any


def _env_keys(name: str) -> list[str]:
    raw = os.environ.get(name, "")
    return [ln.strip() for ln in raw.splitlines() if ln.strip()]


def _http(method: str, url: str, body: dict | None, cookie: str, timeout: float = 30.0) -> tuple[int, Any]:
    data = None if body is None else json.dumps(body).encode()
    req = urllib.request.Request(
        url,
        data=data,
        method=method,
        headers={
            "Content-Type": "application/json",
            "Cookie": cookie,
            "Accept": "application/json",
        },
    )
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            raw = resp.read()
            code = resp.getcode()
            if not raw:
                return code, None
            try:
                return code, json.loads(raw)
            except json.JSONDecodeError:
                return code, raw.decode("utf-8", errors="replace")
    except urllib.error.HTTPError as e:
        raw = e.read()
        try:
            payload = json.loads(raw) if raw else None
        except json.JSONDecodeError:
            payload = raw.decode("utf-8", errors="replace") if raw else None
        return e.code, payload


def login(base: str, password: str) -> str:
    code, body = _http("POST", f"{base}/api/auth/login", {"password": password}, "")
    if code not in (200, 201):
        raise SystemExit(f"login failed http={code} body={body}")
    # Cookie is usually set by the server; some builds also return a token.
    # Prefer Set-Cookie handling via a small redirect-aware path.
    # For Space-local use, INITIAL_PASSWORD session cookie is obtained by a second request.
    # Callers may pass --cookie if login is already done.
    if isinstance(body, dict) and body.get("token"):
        return f"token={body['token']}"
    return ""


def list_connections(base: str, cookie: str) -> list[dict]:
    code, body = _http("GET", f"{base}/api/providers", None, cookie)
    if code != 200:
        raise SystemExit(f"list providers failed http={code} body={body}")
    if isinstance(body, dict) and "connections" in body:
        return list(body["connections"] or [])
    if isinstance(body, list):
        return body
    return []


def list_proxies(base: str, cookie: str) -> list[dict]:
    code, body = _http("GET", f"{base}/api/v1/management/proxies", None, cookie)
    if code != 200:
        # older builds
        code, body = _http("GET", f"{base}/api/proxies", None, cookie)
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
    base: str,
    cookie: str,
    provider: str,
    name: str,
    api_key: str,
    base_url: str | None,
) -> str:
    existing = list_connections(base, cookie)
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
    code, resp = _http("POST", f"{base}/api/providers", body, cookie)
    if code in (200, 201) and isinstance(resp, dict) and resp.get("id"):
        print(f"[hot_apply] connection created name={name} id={resp['id']}")
        return str(resp["id"])
    if code == 409:
        # race: re-list
        for c in list_connections(base, cookie):
            if c.get("name") == name:
                return str(c["id"])
    raise SystemExit(f"create connection failed name={name} http={code} body={resp}")


def ensure_models(base: str, cookie: str, provider: str, models: list[str]) -> None:
    for mid in models:
        code, resp = _http(
            "POST",
            f"{base}/api/provider-models",
            {"provider": provider, "modelId": mid},
            cookie,
        )
        if code in (200, 201):
            print(f"[hot_apply] model ok {mid}")
        elif code == 409:
            print(f"[hot_apply] model exists {mid}")
        else:
            print(f"[hot_apply] model WARN {mid} http={code} body={resp}")


def bind_proxy(base: str, cookie: str, provider: str, proxy_id: str) -> None:
    body = {"scope": "provider", "scopeId": provider, "proxyId": proxy_id}
    code, resp = _http(
        "PUT",
        f"{base}/api/v1/management/proxies/bulk-assign",
        body,
        cookie,
    )
    if code in (200, 201, 204):
        print(f"[hot_apply] proxy bound provider={provider} proxyId={proxy_id}")
        return
    print(f"[hot_apply] proxy bind WARN http={code} body={resp}")


def apply_spec(base: str, cookie: str, spec: dict) -> None:
    provider = spec["provider"]
    keys_env = spec.get("keys_env")
    keys = _env_keys(keys_env) if keys_env else list(spec.get("keys") or [])
    if not keys:
        raise SystemExit(f"no keys for provider={provider} (env={keys_env})")
    name_tpl = spec.get("name_template", f"{provider}-{{i}}")
    base_url = spec.get("base_url")
    models = list(spec.get("models") or [])
    prefer_proxy = spec.get("proxy_name") or spec.get("proxy_port")
    proxies = list_proxies(base, cookie)
    proxy = pick_proxy(proxies, prefer_proxy)
    ids = []
    for i, key in enumerate(keys, start=1):
        name = name_tpl.format(i=i, provider=provider)
        cid = ensure_connection(base, cookie, provider, name, key, base_url)
        ids.append(cid)
    if models:
        ensure_models(base, cookie, provider, models)
    if proxy and proxy.get("id"):
        bind_proxy(base, cookie, provider, str(proxy["id"]))
    else:
        print("[hot_apply] no FT proxy found; skipped bind")
    print(f"[hot_apply] done provider={provider} connections={len(ids)}")


def main() -> int:
    p = argparse.ArgumentParser()
    p.add_argument("--base", default=os.environ.get("OR_BASE", "http://127.0.0.1:20128"))
    p.add_argument("--spec", required=True, help="JSON file: provider/keys_env/models/...")
    p.add_argument("--cookie", default=os.environ.get("OR_COOKIE", ""))
    p.add_argument("--password", default=os.environ.get("INITIAL_PASSWORD", ""))
    args = p.parse_args()
    with open(args.spec, encoding="utf-8") as f:
        spec = json.load(f)
    cookie = args.cookie
    if not cookie:
        if not args.password:
            raise SystemExit("need --cookie or INITIAL_PASSWORD")
        cookie = login(args.base, args.password)
        if not cookie:
            # fallback: many deployments keep a session via curl -c; document that
            raise SystemExit(
                "login returned no cookie; export OR_COOKIE from a browser/curl session"
            )
    apply_spec(args.base.rstrip("/"), cookie, spec)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
