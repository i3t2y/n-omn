# xnexus/omn 部署变量 + Token 完整清单

> 圣上 2026-08-24 令"去做好准备" — xnexus/omn 起来所需的全部 env/token。
> 来源: start.sh + dev/logic 8 件实际读取 (已逐项核实缺省行为, 非臆测)。
> 状态: **供圣上在 xnexus/omn Space Secrets/Variables 配置**。
> ⚠️ nonoke 已封(8/23) 生产宕机, xnexus 立即顶替。
> ✅ 逻辑层源已定: **B. Bucket** (2026-08-25 圣上批, 见 docs/logic-switch-bucket-design.md)。
>    即 `LOGIC_BUCKET_REPO` = **xnexus/logic** (Bucket 源), 非 Dataset。
>    注意: 此清单含"沿用生产值"项 — 圣上可先在 xnexus 配好, 实施时逐项核对。

## 一、必须配置 (缺失即 FATAL/坏) — 按优先级

| 优先级 | 变量 | 值来源 | 缺省后果 |
|--------|------|--------|---------|
| 🔴 P0 | `INTERNAL_PSK` | **沿用生产值** (≥16 字符) | gate.js L57 FATAL, 网关起不来 |
| 🔴 P0 | `LOGIC_BUCKET_REPO` | **xnexus/logic** (新源) | start.sh L52 FATAL |
| 🔴 P0 | `NIM_KEYS` | **沿用生产值** (多行) | init-nim-keys L670 ERROR exit |
| 🔴 P0 | `INITIAL_PASSWORD` | **沿用生产值** | init-nim-keys L669 exit |
| 🟠 P1 | `HF_TOKEN` | **换 xnexus 的** (write scope) | 拉不了逻辑层 + 推不了日志 |
| 🟠 P1 | `OMNIROUTE_API_KEY` | **沿用生产值** | init-nim-keys L697 FATAL |

## 二、R2 备份 (litestream, 必配沿用生产值, 保 R2 备份)

| 变量 | 值来源 | 说明 |
|------|--------|------|
| `R2_ACCOUNT_ID` | **沿用生产值** | Cloudflare R2 账号 (litestream.yml L10) |
| `R2_ACCESS_KEY_ID` | **沿用生产值** | R2 access key (L11) |
| `R2_SECRET_ACCESS_KEY` | **沿用生产值** | R2 secret (L12) |
| `R2_BUCKET` | **omn-data** | R2 桶 (§1 单桶, L8) |

## 三、FT 桥 (出口换 IP, 启用则配)

| 变量 | 值来源 | 说明 |
|------|--------|------|
| `FLARETUNNEL_ENABLED` | '1' | 启 FT 桥 (entrypoint L227; 未设=0 关) |
| `RELAY_AUTH` | **沿用生产值** | 桥鉴权 (L232 缺则跳过 FT; L287/301/550 用) |
| `FT_HEALTH_COOLDOWN` | 30 (沿用) | FT 健康感知轮转冷却秒 |
| `FT_WORKER_COUNT` / `FT_CA_DIR` | 默认/生产 | FT 细节 |

## 四、核心配置 (沿用生产值)

| 变量 | 值来源 | 说明 |
|------|--------|------|
| `GATE_ADMIN_ENABLED` | '0' 或删 | 后台开关. '1' 开后台(维护窗), 平时关 |
| `GATE_UPSTREAM_TIMEOUT_MS` | 180000 | 长思考流超时 (对齐上游 M7) |
| `EXPOSED_PORT` | 7860 | gate 监听 (HF 默认) |
| `DATA_DIR` | /data | HF 设; 运行 SQLite/持久件 |

## 五、OMN 运行态 (沿用生产值, 有默认)

| 变量 | 值来源 | 说明 |
|------|--------|------|
| `OMN_DATASET_REPO` | **xnexus/logic 或新日志仓** | 日志抓取目标 (原 nonoke/omni-logic) |
| `OMN_CLEAR_STALE` | '1' | init 清陈旧错态闸 (0 跳) |
| `OMN_LOG_TO_DATASET` | '1' | 日志推 Dataset 闸 (0 关) |
| `OMN_PERSIST_WRITE` | 生产值 | 持久写件 |
| `OMN_MANAGE_TOKEN` | **沿用生产值** (OR 后台内部用) | 代码不直接读, OR 后台 API 鉴权 |

## 六、NIM 调参 (可选, 已有默认, 沿用生产值)

| 变量 | 说明 |
|------|------|
| `NIM_PROBE_ENABLED`/`NIM_PROBE_CONCURRENCY`/`NIM_PROBE_TIMEOUT_S`/`NIM_PROBE_RETRY_ENABLED`/`NIM_PROBE_VERBOSE` | 探活调参 |
| `NIM_FAST_MODELS`/`NIM_EXTRA_MODELS`/`NIM_POOL_MODELS`/`NIM_CODEX_MODELS` | 模型分组 |
| `NIM_PER_KEY_RPM`/`NIM_PER_KEY_CONCURRENT`/`NIM_MAX_WAIT_MS` | 限速/等待 |
| `NIM_COMPRESS_THRESHOLD`/`NIM_REQUEST_BODY_LIMIT`/`NIM_DEBUG_LOG_KEEP` | 杂项 |

## 六.五、多 provider 新 env (2026-08-25 圣上令, 通用多 provider 注册, init-nim-keys.sh 读)

| 变量 | 值来源 | 说明 |
|------|--------|------|
| `GEMINI_KEYS` | **圣上提供免费 key** (多行, 每行一个) | 通用表 google provider (commit 5e333e9) |
| `OPENROUTER_KEYS` | **圣上提供免费 key** (多行) | 通用表 openrouter provider |
| `SENSENOVA_KEYS` | **圣上提供免费 key** (多行) | 通用表 sensenova (商汤) provider |
| `MISTRAL_KEYS` | **圣上提供免费 key** (多行) | 通用表 mistral provider |
| `AMD_KEYS` | **圣上提供免费 key** (多行) | 通用表 amd provider (AMD_BASE_URL 可覆盖 base) |
| `AMD_BASE_URL` | 默认 https://developer.amd.com.cn/radeon/api | 可覆盖 AMD 上游 |

> ⚠️ 这些 env 空 → init 跳过对应 provider, 不影响 NVIDIA 现役路径。已实装 init-nim-keys.sh PROVIDERS 配置表。

## 七、不变量/护栏

- **§2 秘钥**: 以上 token 值零入会话/git/文档, 只在 xnexus Space Secrets 设。
- **沿用生产值**: INTERNAL_PSK/NIM_KEYS/R2_*/OMNIROUTE_API_KEY/INITIAL_PASSWORD 等**必须沿用**, 改则客户端/备份断。
- **换 xnexus**: 仅 HF_TOKEN/LOGIC_BUCKET_REPO/OMN_DATASET_REPO 换 xnexus 的。
- **xnexus/omn = 唯一 Space** (§1), 不新建任何 Space。
- 逻辑层源 xnexus/logic 须建 (Dataset 或 Bucket, 见 docs/logic-switch-bucket-design.md)。

### 手动生成 token 统一方式 (2026-08-25 圣上裁决)

需要**手动生成**的 token (全新值) 统一用 **`openssl rand -hex 24`** (48 字符 hex, 192 位熵):

| env | 生成方式 | 类 |
|-----|---------|----|
| `INTERNAL_PSK` | `openssl rand -hex 24` | A 全新 (xnexus 新账号脱敏) |
| `INITIAL_PASSWORD` | `openssl rand -hex 24` | A 全新 |
| `OMN_MANAGE_TOKEN` | `openssl rand -hex 24` | A 全新 |

- **选 hex 不选 base64**: 纯 hex (0-9a-f) 无 URL/JSON/HTTP header 转义坑; base64 可能含 `/` `+` `=` 需转义. openssl 为 HF Space 通用预装.
- ⚠️ **A 类冲突提示**: checklist 上节标 INTERNAL_PSK/INITIAL_PASSWORD "沿用生产值", 但 xnexus 若走完全脱敏应换新. **裁决在圣上**: 换新则客户端 base_url+PSK 须同步改; 不换则沿用. 此处记"换新"为默认建议, 沿用为保守选项.
- **B 类 (R2_*/NIM_KEYS/OMNIROUTE_API_KEY/RELAY_AUTH/OMN_PERSIST_WRITE) 严禁重新生成**, 必须从生产 Space Secret 复制 (改则 R2 读不到现有库 → 空库冷启丢数据).
- **C 类 (FT_WORKER_COUNT/FT_CA_DIR/GATE_*/NIM 调参) 默认即可**, 不生成.
- **D 类 (HF_TOKEN/HF_TOKEN_XNEXUS) 在 xnexus 账号生成** (非本地), write scope.