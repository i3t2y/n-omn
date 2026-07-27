#!/usr/bin/env python3
# gate 413 三道防伪闸探针 (径 C dev 验收笔1)
# 环境变量: OMN_DEV_SPACE (base url), INTERNAL_PSK (Bearer), MODEL_ID (默认 auto/best-coding)
# 三闸全绿判 gate 413 堤真生效: 拦超阈 + 归属 gate 签名 + 低阈放行不误伤
import json, os, sys, urllib.request, urllib.error

base = os.environ["OMN_DEV_SPACE"].rstrip("/")
key  = os.environ["INTERNAL_PSK"]
model = os.getenv("MODEL_ID", "auto/best-coding")

def post(body_bytes, label):
    print(f"\n=== {label} | body={len(body_bytes)} bytes ===")
    req = urllib.request.Request(
        base + "/v1/chat/completions",
        data=body_bytes,
        headers={"Authorization": f"Bearer {key}",
                 "Content-Type": "application/json"},
    )
    try:
        r = urllib.request.urlopen(req, timeout=60)
        out = r.read()
        print(f"PASS 放行 status={r.status} len={len(out)}")
        # 取首段判是否真上游流(非空响应体)
        snippet = out[:300].decode("utf-8", "replace")
        print(f"resp[:300]: {snippet}")
        return r.status, out
    except urllib.error.HTTPError as e:
        body = e.read().decode("utf-8", "replace")
        print(f"拦 status={e.code}")
        print(f"resp: {body[:800]}")
        return e.code, body
    except Exception as e:
        print(f"ERR {type(e).__name__}: {e}")
        return None, str(e)

def make_body(filler_len):
    return json.dumps({
        "model": model,
        "messages": [{"role": "user", "content": "A" * filler_len}],
        "max_tokens": 1,
    }).encode()

results = []

# 闸③ 先跑: 低阈值(1.5MB 内)放行, 须正常上游响应非413
low = make_body(1_400_000)
st, _ = post(low, "闸③ 低阈值放行(<1.5MB)")
闸3 = (st == 200)
results.append(("闸③ 低阈值放行", 闸3, st))

# 闸①+②: 超阈(1.7MB>1.5MB gate 阈, body>1.6MB 实证要求)必拦413且签名gate
over = make_body(1_700_000)
print(f"\nbody bytes: {len(over)} (须 >1_600_000)")
st_over, resp_over = post(over, "闸①超阈必拦+闸②归属gate签名")
闸1 = (st_over == 413)
# 闸②: 签名 gate (type:context_length_exceeded) 非上游 400/413 张冠李戴
闸2 = ("context_length_exceeded" in str(resp_over))
results.append(("闸① 超阈必拦413", 闸1, st_over))
results.append(("闸② 413归属gate签名(context_length_exceeded)", 闸2, resp_over[:200] if isinstance(resp_over,str) else "sig见上下文"))

print("\n" + "="*60)
print("三道防伪闸验收:")
allgreen = True
for name, ok, ev in results:
    mark = "✅绿" if ok else "❌红"
    print(f"  {mark} {name}")
    if not ok: allgreen = False
print("="*60)
print("笔1 verdict:", "全绿 gate 413 堤真生效" if allgreen else "有红 须查")
