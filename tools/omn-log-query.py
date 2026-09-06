#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""omn 运行态日志/状态查询工具 (ops/ 层, 永不进 Space, 零 key 落盘)

用法 (python3 直跑, key 从 ~/.omn-secrets 进程内读, 零输出):
  python3 tools/omn-log-query.py gate [N]     # 查 gate 请求日志: httpStatus/errorCode 分布 + 4xx/5xx 明细
  python3 tools/omn-log-query.py gate <模型名> # 按模型聚合: app 路由行拿模型 + 时间窗关联 gate 状态 (模型级 429/502)
  python3 tools/omn-log-query.py app [N]      # 查上游 app 日志: errorCode/ProxyFetch/limit 签名
  python3 tools/omn-log-query.py ft           # 查 FT 代理实时计数 (/v1/ft/metrics, PSK) + 桥日志错误签名
  python3 tools/omn-log-query.py health       # 查运行时连接健康 (manage key = OMNIROUTE_API_KEY, ~/.omn-secrets 已真值)
  python3 tools/omn-log-query.py combo        # 查 combo 池配置 (同 manage key)
  python3 tools/omn-log-query.py storm [N]    # M3 口径: 风暴特征串计数 (gate+app 日志, 应=0)

日志来源:
  - gate 请求日志: Dataset xnexus/logic save/gate/  (scheduler 每~10s 抓增量, 每请求一行 JSON)
  - 上游 app 日志: Dataset xnexus/logic save/app/   (含 errorCode / ProxyFetch / 上游限流)
  - FT 桥日志:     Dataset xnexus/logic save/ft/    (自签 CA 提示居多, 非错误)
  - manage 状态:   gate /api/* (manage key = ~/.omn-secrets 的 OMNIROUTE_API_KEY, 非 OMN_MANAGE_TOKEN)
"""
import re, os, sys, json, socket, collections, bisect, datetime, urllib.request, urllib.error, urllib.parse
socket.setdefaulttimeout(25)

SEC = os.path.expanduser('~/.omn-secrets')
def getval(name):
    if not os.path.isfile(SEC): return None
    m = re.search(rf'^{re.escape(name)}\s*=\s*["\']?([^"\'\n]+)', open(SEC).read(), re.M)
    return m.group(1).strip() if m else None

BASE = getval('OMN_XNEXUS_URL')
PSK  = getval('INTERNAL_PSK')
HF   = getval('HF_TOKEN')
# manage key 真变量 = OMNIROUTE_API_KEY (init 种 DB apiKeys; OMN_MANAGE_TOKEN 是 ops 层误造名, 上游无此 env)
MGR  = getval('OMNIROUTE_API_KEY')
DS   = "xnexus/logic"

# ── Dataset 读取 (HF_TOKEN 即可, 无需 omniroute key) ─────────────────
def ds_tree(sub):
    """分页拉全量文件树。坑: tree API 分页不用 after 参数(被忽略, 恒返回首 1000),
    真游标在响应 Link 头 rel="next" 的 cursor 参数 (base64) — 2026-08-31 实测坐实"""
    out, url = [], f"https://huggingface.co/api/datasets/{DS}/tree/main/{sub}?recursive=true&limit=1000"
    for _ in range(50):   # 每页 1000, 50 页封顶
        req = urllib.request.Request(url, headers={"Authorization": f"Bearer {HF}"})
        try:
            with urllib.request.urlopen(req, timeout=25) as r:
                d = json.loads(r.read())
                out += d
                m = re.search(r'<([^>]+)>;\s*rel="next"', r.headers.get('Link', ''))
                if not m: break          # 无 next 页 = 拉全
                url = m.group(1)         # next URL 自带 cursor + limit
        except Exception: break
    return [it for it in out if it.get('type') == 'file']

def ds_fetch(path):
    req = urllib.request.Request(f"https://huggingface.co/datasets/{DS}/resolve/main/{path}",
                                 headers={"Authorization": f"Bearer {HF}"})
    try:
        with urllib.request.urlopen(req, timeout=25) as r:
            return r.read().decode('utf-8', 'replace')
    except Exception: return ""

def latest_logs(sub, n):
    files = sorted(ds_tree(sub), key=lambda x: x.get('path',''))
    if not files:
        print(f"  [{sub}] 无文件"); return []
    return files[-n:]

def parse_jsonlines(files):
    rows = []
    for it in files:
        for ln in ds_fetch(it['path']).splitlines():
            try: rows.append(json.loads(ln))
            except Exception: pass
    return rows

# ── gate 请求日志: 429/502 真源 ─────────────────────────────────────
def _ts_ms(row):
    """行时间戳统一成 epoch ms: gate 行 ts=int, app 行 time/timestamp=ISO"""
    if isinstance(row.get('ts'), int):
        return row['ts']
    t = row.get('time') or row.get('timestamp')
    if not t: return None
    try:
        return int(datetime.datetime.fromisoformat(t.replace('Z', '+00:00')).timestamp() * 1000)
    except Exception:
        return None

def q_gate(arg="12"):
    """gate [N|model]: N=最近 N 文件分布+4xx/5xx; model=按模型聚合(gate 无 model 字段,
    model 名取自 app HTTP/ROUTING 行, httpStatus 靠时间窗关联 gate 行)"""
    user = str(arg)
    if user.isdigit():
        n = max(int(user), 1)
        files = latest_logs("save/gate", n)
        rows = parse_jsonlines(files)
        print(f"[gate] 最新 {len(files)} 文件 {len(rows)} 条请求")
        if not rows: return
        dist = collections.Counter((r.get('httpStatus'), r.get('errorCode'), r.get('stage')) for r in rows)
        print("--- httpStatus/errorCode/stage 分布 ---")
        for (st, ec, stg), c in dist.most_common(12):
            print(f"  HTTP {st} err={ec} stage={stg} x{c}")
        print("--- 4xx/5xx 明细 ---")
        bad = [r for r in rows if r.get('httpStatus') and r['httpStatus'] >= 400]
        for r in bad[:12]:
            print(f"  ts={str(r.get('ts'))[:19]} path={r.get('path')} {r.get('httpStatus')} "
                  f"err={r.get('errorCode')} abort={r.get('abortSource')} el={r.get('elapsedMs')}ms "
                  f"target={r.get('upstream_target')} msg={r.get('msg')}")
        if not bad: print("  (窗口内无 4xx/5xx)")
        return
    # ── 按模型聚合 ──
    frag = user
    afiles = latest_logs("save/app", 8)
    gfiles = latest_logs("save/gate", 16)
    arows  = parse_jsonlines(afiles)
    grows  = parse_jsonlines(gfiles)
    hits = []
    for r in arows:
        if re.search(re.escape(frag), json.dumps(r), re.I):
            t = _ts_ms(r)
            if t is not None:
                hits.append((t, r))
    print(f"[gate:model={frag}] app 窗口 {len(afiles)} 文件命中 {len(hits)} 请求, "
          f"gate 窗口 {len(grows)} 条用于时间窗关联 (±60s)")
    if not hits: return
    gidx = sorted((_ts_ms(r) or 0, r) for r in grows)
    gts  = [t for t, _ in gidx]
    pairs = []
    for t, r in hits:
        i = bisect.bisect_left(gts, t)
        best = None
        for cand in (i, i - 1):
            if 0 <= cand < len(gts) and abs(gts[cand] - t) < 60000:
                if best is None or abs(gts[cand] - t) < best[0]:
                    best = (abs(gts[cand] - t), gidx[cand][1])
        pairs.append((t, r, best[1] if best else None))
    dist = collections.Counter((g.get('httpStatus') if g else None) for _, _, g in pairs)
    print("--- 时间窗关联 status 分布 ---")
    for st, c in dist.most_common():
        print(f"  HTTP {st} x{c}")
    print("--- 4xx/5xx (关联 app 路由行) ---")
    bad = [(t, r, g) for t, r, g in pairs if g and g.get('httpStatus') and g['httpStatus'] >= 400]
    for t, r, g in bad[:10]:
        print(f"  t={t} {g.get('httpStatus')} err={g.get('errorCode')} el={g.get('elapsedMs')}ms")
        print(f"      app: {json.dumps(r, ensure_ascii=False)[:170]}")
    if not bad: print("  (窗口内该模型无 4xx/5xx)")

# ── 上游 app 日志: errorCode / 限流签名 ─────────────────────────────
def q_app(n=8):
    files = latest_logs("save/app", n)
    rows = parse_jsonlines(files)
    print(f"[app] 最新 {len(files)} 文件 {len(rows)} 行")
    if not rows: return
    comp = collections.Counter(r.get('component') for r in rows)
    print("--- 行级 component 分布 ---")
    for c, n in comp.most_common(10):
        print(f"  {c} x{n}")
    for pat in ["errorCode", "rate.?limit", "429", "502", "timeout", "exhausted", "limit"]:
        cnt = sum(1 for r in rows if pat in json.dumps(r))
        if cnt: print(f"  签名 '{pat}': {cnt} 行")
    print("--- 异常行样本 ---")
    shown = 0
    for r in rows:
        s = json.dumps(r)
        if re.search(r'errorCode|429|502|exhausted|rate.?limit|timeout', s, re.I) and shown < 8:
            print(f"  {s[:240]}"); shown += 1
    if not shown: print("  (无异常签名)")

# ── FT 代理: 实时计数 + 桥日志 ──────────────────────────────────────
def q_ft():
    if not BASE or not PSK:
        print("[ft] 缺 OMN_XNEXUS_URL/INTERNAL_PSK"); return
    req = urllib.request.Request(f"{BASE}/v1/ft/metrics", headers={"Authorization": f"Bearer {PSK}"})
    try:
        with urllib.request.urlopen(req, timeout=20) as r:
            body = r.read().decode()
            print(f"[ft] /v1/ft/metrics HTTP {r.status} (桥活)")
            # 聚合 per-Worker 计数
            reqs, succ, fail = {}, {}, {}
            for m in re.finditer(r'flaretunnel_worker_(requests|successes|failures)_total\{name="([^"]+)"\} (\d+)', body):
                kind, name, v = m.group(1), m.group(2), int(m.group(3))
                (reqs if kind == 'requests' else succ if kind == 'successes' else fail)[name] = v
            names = sorted(reqs)
            print(f"  共 {len(names)} Worker; 全池 request/succ/fail:")
            tr = ts = tf = 0
            for nm in names:
                r_, s_, f_ = reqs.get(nm,0), succ.get(nm,0), fail.get(nm,0)
                tr += r_; ts += s_; tf += f_
                if f_:  # 只打有失败或非零的
                    pass
            print(f"  合计: requests={tr} successes={ts} failures={tf} (成功率 {ts/max(tr,1)*100:.0f}%)")
            print("  per-Worker (top 失败):")
            for nm in sorted(names, key=lambda x: -fail.get(x,0))[:8]:
                print(f"    {nm}: req={reqs.get(nm,0)} ok={succ.get(nm,0)} fail={fail.get(nm,0)}")
    except urllib.error.HTTPError as e:
        print(f"[ft] /v1/ft/metrics HTTP {e.code}: {e.read(150)!r} (401=PSK错, 503=FT未启/桥死)")
    except Exception as e:
        print(f"[ft] {type(e).__name__}: {e}")
    # 桥日志错误签名
    files = latest_logs("save/ft", 4)
    alltxt = "".join(ds_fetch(it['path']) for it in files)
    print(f"[ft] 桥日志最近 {len(files)} 文件 {len(alltxt)}B, 错误签名:")
    for pat in ["429","502","503","timeout","ECONN","CERT","certificate","error","fail","refused"]:
        c = len(re.findall(pat, alltxt, re.I))
        if c: print(f"  {pat}: {c}")
    if 'certificate' in alltxt.lower() and 'CERT' not in alltxt:
        pass
    if len(re.findall('certificate', alltxt, re.I)) and not re.search(r'fail|error|refused|429|502|503|timeout', alltxt, re.I):
        print("  (仅自签 CA 提示, 无真实错误)")

# ── manage 状态 (manage key = OMNIROUTE_API_KEY) ────────────────────────
def q_manage(path, label, depth=400):
    if not BASE or not MGR:
        print(f"[{label}] 缺 OMNIROUTE_API_KEY (~/.omn-secrets 无此值)"); return
    req = urllib.request.Request(f"{BASE}{path}", headers={"Authorization": f"Bearer {MGR}", "Accept": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=25) as r:
            d = r.read(depth)
            try: j = json.loads(d); print(f"[{label}] {path} HTTP {r.status}"); print(json.dumps(j, ensure_ascii=False)[:depth])
            except: print(f"[{label}] {path} HTTP {r.status} {d[:depth]!r}")
    except urllib.error.HTTPError as e:
        print(f"[{label}] {path} HTTP {e.code}: {e.read(200)!r} (AUTH_001=manage key 无效)")

# ── M3 风暴计数 (上线窗口径, 应=0) ──────────────────────────────────
def q_storm(n=10):
    STORM = ['ALL_ACCOUNTS_INACTIVE', 'all .* accounts unavailable', 'Preserving last upstream error',
             'no active credentials', 'zero live accounts', 'all keys down']
    tot = 0
    for sub in ["save/gate", "save/app"]:
        files = latest_logs(sub, n)
        alltxt = "".join(ds_fetch(it['path']) for it in files)
        for pat in STORM:
            c = len(re.findall(pat, alltxt, re.I))
            if c:
                print(f"[storm] {sub} '{pat}' x{c}"); tot += c
    print(f"[storm] 最近 {n} 文件窗口内风暴串计数 = {tot} {'(PASS=0)' if tot==0 else '(!FAIL)'}")

CMDS = {
    'gate':   (lambda: q_gate(sys.argv[2] if len(sys.argv)>2 else "12"),  "gate 分布+4xx/5xx, 或 gate <模型名> 聚合"),
    'app':    (lambda: q_app(int(sys.argv[2]) if len(sys.argv)>2 else 8),   "上游 app 日志错误签名"),
    'ft':     (q_ft,  "FT 实时计数 + 桥日志"),
    'health': (lambda: q_manage("/api/health-autopilot", "health"), "连接健康 (manage key)"),
    'providers': (lambda: q_manage("/api/providers", "providers"), "providers (manage key)"),
    'models': (lambda: q_manage("/api/models", "models"), "模型枚举 (manage key)"),
    'combo':  (lambda: q_manage("/api/combos", "combo"), "combo 池 (manage key)"),
    'storm':  (lambda: q_storm(int(sys.argv[2]) if len(sys.argv)>2 else 10), "风暴特征串计数"),
}

if __name__ == '__main__':
    if len(sys.argv) < 2 or sys.argv[1] not in CMDS:
        print(__doc__); print("子命令:", ", ".join(f"{k}({v})" for k, v in CMDS.items())); raise SystemExit(1)
    fn, _ = CMDS[sys.argv[1]]
    fn()