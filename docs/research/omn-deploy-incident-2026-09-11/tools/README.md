# 日志与仓内文件抓取 — 使用说明

> 本目录两个脚本（`fetch.sh` / `get.py`）只解决**通道 C**。真正抓 HF Space 日志走**通道 A**
> （GitHub Actions）。本文把三条通道从头到尾写清楚，附可直接复制的命令与全部踩过的坑。

---

## 0. 为什么需要绕这一圈

HF Space `xnexus/o` 是**私有** Space，且本机**没有 HF token**。⇒ 无法直接
`curl https://huggingface.co/api/spaces/xnexus/o/logs/run`。

但 `i3t2y/n-omn` 仓库里**配了 `HF_TOKEN` secret**。所以唯一可行的路径是：

```
让 GitHub Actions 拿着仓库里的 HF_TOKEN 去抓 → 把日志写回本仓 evidence 分支
→ 本仓是公开仓 ⇒ 任何人（含本机）匿名读回
```

这个"借 CI 的手取证、再把证据放公开处"的绕法，是整套方法的地基。

---

## 1. 三条通道速查

| 想要什么 | 通道 | 门槛 | 延迟 |
|---|---|---|---|
| HF Space **运行/构建日志** | **A** `.github/workflows/fetch-xnexus-logs.yml` | 仓库**写**权限 token（触发用） | ~1–2 min（Actions 排队） |
| **已抓取**的日志 | **B** 读 `evidence` 分支 | 无（公开仓匿名可读） | 即时 |
| CNB 仓内**任意文件** | **C** `cnb git get-content`（本目录脚本封装） | `cnb` CLI 已登录 | 即时 |

---

## 2. 通道 A — 触发 `fetch-xnexus-logs.yml` 抓 HF 日志

### 2.0 它是什么

- 文件：`.github/workflows/fetch-xnexus-logs.yml`（在 `main`，本仓公开可读）
- 触发：**只有 `workflow_dispatch`**——**没有 cron、没有 push 触发**。
  （注释里遗留了"cron 每 30min"的字样，那是 2026-07 的旧设计，`on:` 块里并未实现。**别等它自动跑。**）
- 输入：`log_type` = `run` / `build` / `both`，默认 `run`
- 需要 secret：`HF_TOKEN`（已在仓内配好，触发者无需提供）

### 2.1 方式一：网页 UI（最省事）

1. 打开 `https://github.com/i3t2y/n-omn/actions/workflows/fetch-xnexus-logs.yml`
2. 右上角 **Run workflow** → 分支选 `main` → `log_type` 选 `run`（排查崩溃时选 `both`）
3. 点绿色 **Run workflow**

### 2.2 方式二：REST API（可脚本化；本机 `gh` 不可用，用 curl）

```bash
# 前置：准备一个有 repo 权限的 token（不要写进命令行历史；放文件或环境变量）
export GH_TOKEN="$(tr -d '\r\n' < ~/.workbuddy/_gh_oauth_tok)"   # 示例路径，按你的实际改

curl -sS -X POST \
  -H "Authorization: Bearer $GH_TOKEN" \
  -H "Accept: application/vnd.github+json" \
  "https://api.github.com/repos/i3t2y/n-omn/actions/workflows/fetch-xnexus-logs.yml/dispatches" \
  -d '{"ref":"main","inputs":{"log_type":"run"}}'
```

**成功标志**：HTTP `204`，无返回体。
**常见失败**：

| 返回 | 含义 |
|---|---|
| `401` | token 无效/过期 |
| `403` | token 无 `repo`（Actions 写）权限，或 SSO 未授权 |
| `404` | workflow 文件名写错，或 token 看不到该仓 |

### 2.3 方式三：`gh` CLI（**若**本机已安装；本会话实测未安装）

```bash
gh workflow run fetch-xnexus-logs.yml --repo i3t2y/n-omn --ref main -f log_type=run
gh run watch --repo i3t2y/n-omn          # 跟到结束
```

### 2.4 它会做什么（四步，按顺序）

1. **抓** — `curl -sS -N --max-time 60` 打 HF 日志端点，落 `out/{run,build}.log`
2. **脱敏闸** — 5 条正则扫明文凭据，**命中即整 job `exit 1`，不 commit 不 push**（fail-closed）
3. **落 evidence 分支** — orphan 分支 `evidence`，路径 `logs/xnexus--o/<TS>-<kind>.log`
4. **回显** — Step Summary 给字节数表

### 2.5 落点与命名

```
分支:  evidence        (orphan 起步，与 main 完全分层)
路径:  logs/xnexus--o/YYYYMMDD-HHMM-{run|build}.log
       例: logs/xnexus--o/20260911-1114-run.log     (47399 B)
           logs/xnexus--o/20260911-1114-build.log   ( 1441 B)
```

### 2.6 ⚠️ 快照语义：一次抓取 = 全量 boot 叙事，不是 60 秒切片

连接建立瞬间，HF 会**倾吐容器自启动以来的全部积压历史**，随后才转实时细流。
实测佐证：10 秒窗收 142237 字节，60 秒窗收 142251 字节——多烧 50 秒只多 14 字节。

⇒ **单次抓取即覆盖从 boot 到现在的完整叙事**。排查重启循环时，抓一次就够，
不需要抓两次做"前后对比"（那样反而抓到同样的积压）。

### 2.7 ⚠️ rc 分账：别把 `rc=28` 当失败

HF 日志端点的返回码**不是标准 HTTP 语义**。workflow 里的判定是：

| rc | 判定 | 处置 |
|---|---|---|
| `0` | 完整收完 | 正常 |
| `28` | curl `--max-time 60` 兜底超时 | **正常**，且已落盘的积压历史照常保留 |
| 其他 | 真失败 | 打 WARN，但已落盘字节仍留作部分证据 |
| rc=0 但 0 字节 | 空窗（Space 闲/未启动） | 打 WARN，不 fail |

读日志时若看到 `rc=28 bytes=245500`，**那是成功**。

### 2.8 脱敏闸的 5 条正则（写日志时自查，免得白跑一趟）

```
nvapi-[A-Za-z0-9_-]{20,}                                  # NIM key
(Bearer|X-Internal-PSK)[^A-Za-z0-9]{1,3}[A-Za-z0-9_-]{16,} # Bearer / PSK 实值
hf_[A-Za-z0-9]{20,}                                        # HF token
omniroute-data.*[Aa]ccess[A-Za-z0-9_-]{8,}                 # R2 access key
GATE_ADMIN_TOKEN[^A-Za-z0-9]{1,3}[A-Za-z0-9_-]{16,}        # 历史遗留(机制已废)
```

设计取向写在注释里：**"宁丢一帧日志，不泄一凭据"**。

### 2.9 ⚠️ 7 天保留：工作树会删，git 历史不删

workflow 末尾有 `find "$DEST_DIR" -name '*.log' -mtime +7 -delete`。
⇒ 分支**最新工作树**只保留近 7 天快照；**更早的要从 git 历史里挖**：

```bash
git clone --single-branch --branch evidence https://github.com/i3t2y/n-omn.git ev
cd ev && git log --diff-filter=A --name-only --pretty=format:'%h %ad' --date=short -- 'logs/xnexus--o/*'
git show <commit>:logs/xnexus--o/20260903-1538-run.log > /path/to/old.log
```

---

## 3. 通道 B — 读取已抓取的日志

### 3.1 列出有哪些快照

```bash
curl -s "https://api.github.com/repos/i3t2y/n-omn/contents/logs/xnexus--o?ref=evidence" \
  | grep -E '"name"|"size"'
```

### 3.2 下载某一个（注意中文/空格路径要 URL 编码；这里全 ASCII，可直接用）

```bash
curl -sL -o run.log \
  "https://raw.githubusercontent.com/i3t2y/n-omn/evidence/logs/xnexus--o/20260911-1114-run.log"
wc -c run.log        # 应与 API 返回的 size 一致
```

### 3.3 本次事故已归档的本地副本（不用联网）

```
本目录上级: evidence/ev-run.log      ← 20260911-1114-run.log    (47399 B)
            evidence/ev-build.log    ← 20260911-1114-build.log  ( 1441 B)
```

### 3.4 ⚠️ 判读日志时的两个陷阱

1. **CF 边缘的 `401 {"error":"unauthorized"}` 不是健康信号**。请求在**到达 Space 之前**
   就被 Cloudflare 的 `_middleware.js` 拦掉了，Space 是死是活它都返回 401。
   拿它判断"服务在跑"会得出完全错误的结论。
2. **`entrypoint.sh:434` 的预检只查 `/logic/gate.js` 存在与否**，**不查**它的相对
   `require()` 目标在不在。⇒ `gate.js` 在、但它 `require` 的模块缺失时，预检照样放行，
   崩在后面。这正是 2026-09-11 `policy-guard.js` 漏件事故能一路绿到上线的原因之一。

**可靠的判读锚点**（本次实测有效）：boot 日志里出现

```
[start] Bucket 校验通过 (n-omn@dc66978 9 件 sha256 全对)
```

这一行才说明逻辑层**齐件且校验通过**。

---

## 4. 通道 C — 读 CNB 仓内文件（本目录两个脚本）

`cnb git get-content` 返回的是 YAML，文件内容在 `  content: <base64>` 一行里，
需要 base64 解码。两个脚本做的就是这件事。

### 4.1 `fetch.sh`（bash）

```bash
./fetch.sh <repo> <file-path> [outfile]
# 例
./fetch.sh nexus.zen/omn logic/gate.js            # → cache/gate.js
./fetch.sh nexus.zen/nexus docs/self-improvement/河图-规矩.md cache/gui.md
```

默认输出到 `cache/<basename>`，会在当前目录建 `cache/`。
非 blob（目录或不存在）时打印 `[NOT-BLOB]` 并回显原始响应前 600 字符后 `exit 2`。

### 4.2 `get.py`（python，不落盘则直接打到 stdout）

```bash
python get.py <repo> <file-path>            # 直接打印内容
python get.py <repo> <file-path> out.txt    # 落盘
```

### 4.3 ⚠️ 三个已踩过的坑

1. **`cnb git get-tree` 不是合法子命令**。列目录要用 `get-content` 传目录路径，
   响应里会有 `entries[]` 树。
2. **在 Windows 的子进程里直接 `python get.py` 会找不到 `cnb`**。
   在 bash 里包一层函数最稳：

   ```bash
   fetch(){ cnb git get-content --repo "$1" --file-path "$2" 2>&1 \
            | grep '^  content:' | sed 's/^  content: //' | base64 -d; }
   fetch nexus.zen/omn CLAUDE.md
   ```
3. **判空要用 `errcode: 404`**，别只看退出码——`cnb` 对 404 也可能返回 0。

### 4.4 判断"某路径在不在"（本次查红线用的就是它）

```bash
cnb git get-content --repo nexus.zen/nexus --file-path eval 2>&1 | grep -q 'errcode: 404' \
  && echo "不存在" || echo "存在"
```

---

## 5. 本次事故实际跑过的命令（可整段复制复核）

```bash
# 1) 列 CNB omn 仓根目录，确认部署清单在 NPC 可见域内
cnb git get-content --repo nexus.zen/omn --file-path ""

# 2) 确认 CNB nexus 侧没有 eval/（红线 2 的实质是否还成立）
cnb git get-content --repo nexus.zen/nexus --file-path eval        # → errcode: 404

# 3) 确认公开 GitHub 侧有 eval/、且河图母法未泄
curl -s -o /dev/null -w "%{http_code}\n" \
  "https://raw.githubusercontent.com/i3t2y/nexus/main/eval/heldout.json"          # 200
# 中文路径 curl 会自动做百分号编码, 未编码/编码两种写法实测都返回 404
curl -s -o /dev/null -w "%{http_code}\n" \
  "https://raw.githubusercontent.com/i3t2y/nexus/main/docs/self-improvement/河图-规矩.md"  # 404

# 4) 抓一次 Space 日志（排查崩溃时选 both）
curl -sS -X POST -H "Authorization: Bearer $GH_TOKEN" \
  -H "Accept: application/vnd.github+json" \
  "https://api.github.com/repos/i3t2y/n-omn/actions/workflows/fetch-xnexus-logs.yml/dispatches" \
  -d '{"ref":"main","inputs":{"log_type":"both"}}'

# 5) 等 Actions 跑完，取日志
curl -s "https://api.github.com/repos/i3t2y/n-omn/contents/logs/xnexus--o?ref=evidence" | grep '"name"'
curl -sL -o run.log "https://raw.githubusercontent.com/i3t2y/n-omn/evidence/logs/xnexus--o/20260911-1114-run.log"

# 6) 在日志里找齐件锚点
grep -n "Bucket 校验通过" run.log
```

---

## 6. 验收清单

- [ ] dispatch 返回 HTTP `204`
- [ ] Actions run 的 **desens** 步打印 `脱敏闸已执行 PASS`
- [ ] Step Summary 的字节数 > 0（0 字节 = 空窗，Space 可能没在跑）
- [ ] `evidence` 分支出现 `logs/xnexus--o/<新TS>-run.log`
- [ ] 下载下来的字节数与 API 的 `size` 一致
- [ ] 日志里能 grep 到 `[start] Bucket 校验通过` （而不是只有 CF 的 401）

---

## 7. 关于本目录的归档说明

- 本文**不含任何凭据**：所有 token 一律用 `$GH_TOKEN` / `~/.workbuddy/_gh_oauth_tok`
  之类的占位或示例路径表示。
- 本文引用的日志**正文片段**只有 `[start] Bucket 校验通过 (n-omn@dc66978 9 件 sha256 全对)`
  这一行，作为判读锚点，不含任何密钥或 PSK 实值。
- `fetch.sh` / `get.py` 是通用读取封装，无内嵌凭据。

关联：上级 `README.md` · `docs/ops/incidents/2026-09-11-policy-guard-list-omission-restart-loop.md`
