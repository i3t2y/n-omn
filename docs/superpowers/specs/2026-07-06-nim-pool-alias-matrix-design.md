# NIM 模型池重建 + alias 矩阵设计

> **快照日期**：2026-07-06
> **上游**：OmniRoute v3.8.43（镜像固定）
> **数据来源**：P0-1 curl NIM `/v1/models` 全量 + 多模型 ping 测速（`--max-time 30` + `stream:false`）
> **关联 SSOT**：`docs/CURRENT_STATE_v3.8.md` §4（Combo 与模型池）、§5（NIM 模型上架状态）
>
> 本设计基于实证数据替代 task §三假设（"glm-5.2 实证流畅 4230ms，不要预设热门=差"）。P0-1 测速显示 glm-5.2 ping 冷请求 6× 全 40s 超时，但用户日常 warm 状态流畅，故保留。实证洞察：ping 测速 ≠ 真实可用性，下架判定只看 `/v1/models` 列表。

---

## 1. P0-1 实证数据汇总

### 1.1 `/v1/models` 全量可用模型集

约 110 个模型。与 init 现有 9 模型交叉比对结果：

| init 模型 | `/v1/models` 在？ | 状态判定 |
|-----------|-----------------|---------|
| `minimaxai/minimax-m2.7` | ✅ | 在线 |
| `moonshotai/kimi-k2-thinking` | ❌ **不在** | **下架** |
| `moonshotai/kimi-k2.6` | ✅ | 在线 |
| `z-ai/glm-5.2` | ✅ | 在线（ping 超时，保留） |
| `nvidia/nemotron-3-super-120b-a12b` | ✅ | 在线 |
| `qwen/qwen3-coder-480b-a35b-instruct` | ❌ 不在（前序实证 410 Gone） | **下架** |
| `mistralai/mistral-small-4-119b-2603` | ✅ | 在线 |
| `mistralai/mistral-medium-3.5-128b` | ✅ | 在线（间歇超时） |
| `meta/llama-3.2-90b-vision-instruct` | ✅ | 在线 |

**下架 2 个**（非 task 假设的 1 个）：`kimi-k2-thinking` + `qwen3-coder-480b-a35b-instruct`。前者 task 未列入下架，P0-1 实证发现。

### 1.2 ping 测速结果（`max_tokens=5` + `stream:false` + `max-time 30/40`）

稳定可用（HTTP 200，< 2s）：

| 模型 | 耗时（ms） |
|------|-----------|
| `nvidia/nemotron-3-super-120b-a12b` | 1092 |
| `mistralai/mistral-small-4-119b-2603` | 788 / 923 |
| `qwen/qwen3-next-80b-a3b-instruct` | 1004 / 1192 / 1308 |
| `mistralai/mistral-large-3-675b-instruct-2512` | 1073 / 1355 |
| `moonshotai/kimi-k2.6` | 1845 |
| `minimaxai/minimax-m2.7` | 1859 |
| `openai/gpt-oss-120b` | 1085 / 1925 |
| `nvidia/nemotron-3-ultra-550b-a55b` | 1575 / 1239 |

间歇/超时（保留或备用）：

| 模型 | 耗时 | 判定 |
|------|------|------|
| `z-ai/glm-5.2` | 6× 全 40s / 000 | ping 冷请求超时，**用户日常 warm 状态流畅**，保留 |
| `meta/llama-3.3-70b-instruct` | 3× 全 35s / 000 | 超时，不入 init（非 init 9 模型） |
| `mistralai/mistral-medium-3.5-128b` | 952 → 35s / 000 | 间歇，128K 长文本标签，留 pool 备用 |
| `qwen/qwen3.5-122b-a10b` | 30s/000 → 6496/200 | 间歇不稳，不入 alias |
| `qwen/qwen3.5-397b-a17b` | 2× 全 30s / 000 | 极慢 397B reasoning 系负载高，不入 |
| `deepseek-ai/deepseek-v4-flash` | 2× 503 | 上游拒绝服务，**仅备用观测通道** |
| `deepseek-ai/deepseek-v4-pro` | 13719 / 200 | 慢但可用，备用 |
| `01-ai/yi-large` | 1293 / 404 | 列表有但 404，不可用 |

### 1.3 关键实证洞察（写入实现细节）

1. **ping 测速 ≠ 真实可用性**：`max_tokens=5` 极短请求 + 冷启动对部分模型（glm-5.2 / llama-3.3-70b / mistral-medium-3.5 / qwen3.5-397b）首响应时虚高，curl `--max-time 30` 易超时假死。但实际长会话 / warm 状态流畅。**巡检函数下架判定只看 `/v1/models` 列表 grep**，ping 超时仅作负载线索，不作为移除判据。
2. **`stream:false` 必显式**：curl 默认对 SSE 流式响应处理不当，不显式 `stream:false` 易致 30s 超时假象。巡检测速必须显式 `stream:false`。
3. **下架 = `/v1/models` 列表剔除**：前序实证 qwen3-coder-480b 返回 410 Gone，本次 `/v1/models` 已无此 ID。下架的可靠信号是列表 grep 失配，非 410（410 是调用时才返回，列表层先失配）。
4. **新代大模型优先实测**：凭参数代际差（80B vs 122B vs 397B）不靠清单标签判可用性，测速是唯一客观信号。397B reasoning 系负载高 ping 全超时，122B 间歇。alias 选型落稳快候选。

---

## 2. 选型标准（数据驱动，场景匹配优先）

### 2.1 维度优先级（决策一）

**场景匹配优先**（多 alias 按场景分流），非单维优先级。每场景选该维度最强实证可用模型：

- 编程场景 → 代码能力最强（gpt-oss 代码传承 / qwen3-next 80B 快)
- 中文通用 → 中文质量最强（glm-5.2 验证可用，保留）
- 创意/长文本 → 上下文窗口 + 中文叙事（kimi-k2.6 256K 标称）
- 角色对话 → 中文叙事风格（minimax-m2.7）
- 推理/策略 → 参数规模 + reasoning 深度（nemotron-ultra-550b）
- 多模态/视频 → 图像理解（llama-3.2-90b-vision）

### 2.2 热度/可用性维度（决策修订）

**热度不参与选型否决**。glm-5.2 热门 ping 超时但日常流畅，证明 ping 超时是负载线索非下架。alias 矩阵按场景选最优，pool 兜底。HealthCheck/RPM 运维侧实测感知真可用性。

### 2.3 教育场景（决策修订）

**不单设教育 alias**。与中文通用 `glm52` 重叠覆盖。NIM 模型普遍无 child-safety 调教，深度教育安全走 P1 兜底 provider（Kiro/Antigravity Claude 4.5 原生安全调教，见 §6 后续任务）。

---

## 3. alias 矩阵设计（全 NIM 通道，替换 `~/.omn_env` 旧 alias）

### 3.1 命名规则

- 前缀：模型家族首字母（gpt/qwen/glm/kimi/mini/vis/nemo/dp）
- 后缀：版本/规模标识，一眼定位
- 3-5 位长度
- 旧 `cq48`/`cd4f`/`cd4p`/`cg52`/`ck26`/`cm27` 全部替换为下表新名

### 3.2 终定矩阵

| alias | 拆解 | `--model`（nvidia/ 前缀,Anthropic 入口命名） | 场景 | 实证状态 |
|-------|------|---------------------------------------------|------|---------|
| `gpt12` | gpt+120b | `nvidia/openai/gpt-oss-120b` | 编程主/代码传承 | 1.1-1.9s 200 |
| `qwen8` | qwen+80b | `nvidia/qwen/qwen3-next-80b-a3b-instruct` | 编程辅/中文快 | 1.0-1.3s 200 |
| `glm52` | glm+5.2 | `nvidia/z-ai/glm-5.2` | 中文通用/教育 | 保留（ping 超时但日常流畅） |
| `kimi26` | kimi+k2.6 | `nvidia/moonshotai/kimi-k2.6` | 创意/长文本 | 1.8s 200 |
| `mini27` | mini+m2.7 | `nvidia/minimaxai/minimax-m2.7` | 角色对话 | 1.9s 200 |
| `vis90` | vision+90b | `nvidia/meta/llama-3.2-90b-vision-instruct` | 多模态/视频 | 列表在线 |
| `nemo55` | nemotron+550b | `nvidia/nvidia/nemotron-3-ultra-550b-a55b` | 重推理/策略 | 1.2-1.6s 200 |
| `dpf` | deepseek-flash | `nvidia/deepseek-ai/deepseek-v4-flash` | 备用/观测 | ⚠️ NIM 503 当前 |
| `dpp` | deepseek-pro | `nvidia/deepseek-ai/deepseek-v4-pro` | 备用 | 13.7s 200 |

**DeepSeek 通道决策**：原 `cd4f`/`cd4p` 走 ds2api（自建 DeepSeek `wanglaisi1-ds.hf.space`）。本设计改 `dpf`/`dpp` 走 NIM（OMN 通道），作**观测/备用通道**。注意 NIM `deepseek-v4-flash` 当前 503，备用容错：NIM 侧不可用时走 ds2api 手动切回（不在 alias 内，视情况手动）。

### 3.3 双层命名约定（保留确认）

- **alias `claude --model`**：用 **`nvidia/` 前缀**（Anthropic 兼容入口 `/v1/messages` 命名，如 `nvidia/z-ai/glm-5.2`）
- **init Combo `models` / `register_model` `modelId`**：用 **无 `nvidia/` 前缀**（OmniRoute provider-models 命名，如 `z-ai/glm-5.2`）

两层命名都对，是不同入口层。init 增量修改时严守此约定。

---

## 4. init 脚本修改设计（P0-2）

### 4.1 PRODUCTION_MODELS 巡检交叉比对集（新增 grep 对照集）

init `register_model` 注册全集 13 个（移除下架 2，新增强候选 5 + 128b 降备用）。其中 11 个进 nim-pool Combo,余 2 个（mistral-medium-3.5-128b / deepseek-v4-flash）仅目录备用。巡检覆盖全集：

```
minimaxai/minimax-m2.7
moonshotai/kimi-k2.6
z-ai/glm-5.2
nvidia/nemotron-3-super-120b-a12b
mistralai/mistral-small-4-119b-2603
mistralai/mistral-medium-3.5-128b
meta/llama-3.2-90b-vision-instruct
openai/gpt-oss-120b
qwen/qwen3-next-80b-a3b-instruct
nvidia/nemotron-3-ultra-550b-a55b
deepseek-ai/deepseek-v4-pro
mistralai/mistral-large-3-675b-instruct-2512
deepseek-ai/deepseek-v4-flash
```

deepseek-v4-flash 不入 nim-pool（503 风险），仅 `register_model` 注册为目录备用 + alias `dpf` 单点入口。

mistralai/mistral-medium-3.5-128b 间歇超时（952ms→35s/000），降为备用不入 nim-pool Combo，仅 `register_model` 注册目录。其主力位由 `mistralai/mistral-large-3-675b-instruct-2512` 替代（实证稳 1.1-1.4s 200）。

### 4.2 nim-pool Combo（round-robin，通用 catalog）

`init-nim-keys.sh` 第 518-536 行 POST /api/combos，`models` 数组改为下述 12 个（去 dpf + 去 128b）：

```json
{
  "name": "nim-pool",
  "strategy": "round-robin",
  "models": [
    "minimaxai/minimax-m2.7",
    "moonshotai/kimi-k2.6",
    "z-ai/glm-5.2",
    "nvidia/nemotron-3-super-120b-a12b",
    "mistralai/mistral-small-4-119b-2603",
    "meta/llama-3.2-90b-vision-instruct",
    "openai/gpt-oss-120b",
    "qwen/qwen3-next-80b-a3b-instruct",
    "nvidia/nemotron-3-ultra-550b-a55b",
    "deepseek-ai/deepseek-v4-pro",
    "mistralai/mistral-large-3-675b-instruct-2512"
  ]
}
```

### 4.3 nim-codex Combo（context-relay，代码任务，头号替换）

原头号 `qwen/qwen3-coder-480b-a35b-instruct` 已下架。`init-nim-keys.sh` 第 559-571 行改为：

```json
{
  "name": "nim-codex",
  "strategy": "context-relay",
  "models": [
    "openai/gpt-oss-120b",
    "qwen/qwen3-next-80b-a3b-instruct",
    "mistralai/mistral-medium-3.5-128b"
  ]
}
```

context-relay 头号 `gpt-oss-120b`：多 Key 轮转拼上下文需快响应 + 代码传承强，1.1-1.9s 稳定 200。

### 4.4 register_model 注册段修改（第 499-511 行）

```bash
# nim-pool 核心模型（11，进 Combo）
register_model "minimaxai/minimax-m2.7"
register_model "moonshotai/kimi-k2.6"
register_model "z-ai/glm-5.2"
register_model "nvidia/nemotron-3-super-120b-a12b"
register_model "mistralai/mistral-small-4-119b-2603"
register_model "meta/llama-3.2-90b-vision-instruct"
register_model "openai/gpt-oss-120b"
register_model "qwen/qwen3-next-80b-a3b-instruct"
register_model "nvidia/nemotron-3-ultra-550b-a55b"
register_model "deepseek-ai/deepseek-v4-pro"
register_model "mistralai/mistral-large-3-675b-instruct-2512"

# 额外目录项（备用，不放入 Combo）
register_model "mistralai/mistral-medium-3.5-128b"
register_model "deepseek-ai/deepseek-v4-flash"
```

删旧 `qwen/qwen3-coder-480b-a35b-instruct` + `moonshotai/kimi-k2-thinking` 两行。mistral-medium-3.5-128b 从原 nim-pool 核心段移至备用目录项（间歇超时，主力位由 mistral-large-3-675b 替代）。

### 4.5 check_nim_model_health() 巡检函数（决策一/二，嵌入 init）

嵌入位置：register_model 段之前（首次初始化分支）+ nim-pool 已在 DB 分支（增量模式）。

伪代码（实现时参考 §1.3 洞察：下架判定只看 `/v1/models` grep + `stream:false` 测速）：

```bash
check_nim_model_health() {
  echo "[init] Checking NIM model availability via /v1/models..."

  local NIM_AVAILABLE
  NIM_AVAILABLE=$(curl -s --max-time 10 https://integrate.api.nvidia.com/v1/models \
    -H "Authorization: Bearer ${NIM_KEYS[0]}" \
    | jq -r '.data[].id' 2>/dev/null | sort)

  local MODEL_COUNT
  MODEL_COUNT=$(echo "$NIM_AVAILABLE" | grep -c . 2>/dev/null || echo 0)
  if [ "$MODEL_COUNT" -lt 5 ]; then
    echo "[init] WARN: NIM /v1/models returned $MODEL_COUNT models — possible endpoint issue, skipping health check."
    return 0
  fi

  # 巡检 PRODUCTION_MODELS 对照集
  local PRODUCTION_MODELS=(
    "minimaxai/minimax-m2.7"
    "moonshotai/kimi-k2.6"
    "z-ai/glm-5.2"
    "nvidia/nemotron-3-super-120b-a12b"
    "mistralai/mistral-small-4-119b-2603"
    "mistralai/mistral-medium-3.5-128b"
    "meta/llama-3.2-90b-vision-instruct"
    "openai/gpt-oss-120b"
    "qwen/qwen3-next-80b-a3b-instruct"
    "nvidia/nemotron-3-ultra-550b-a55b"
    "deepseek-ai/deepseek-v4-pro"
    "mistralai/mistral-large-3-675b-instruct-2512"
    "deepseek-ai/deepseek-v4-flash"
  )

  local DEPRECATED_MODELS=()
  for model in "${PRODUCTION_MODELS[@]}"; do
    if echo "$NIM_AVAILABLE" | grep -qx "$model"; then
      echo "[init] OK $model"
    else
      echo "[init] DEPRECATED $model — not in /v1/models"
      DEPRECATED_MODELS+=("$model")
    fi
  done

  # 自动操作严格限制：仅剔除已下架，不自动添加新模型。
  # 下架模型从 register_model 列表 + Combo target 列表剔除。
  # 输出 DEPRECATED_MODELS 供后续 register/Combo 段跳过。
  echo "${DEPRECATED_MODELS[@]}" > /tmp/nim-deprecated.txt
  return 0
}
```

注意点：
- `grep -qx` 精确整行匹配（防 `kimi-k2-thinking` 误匹 `kimi-k2`）
- DEPRECATED_MODELS 写入临时文件，后续 register_model + Combo 创建段读此文件跳过已下架
- 增量模式分支（nim-pool 已在 DB）：巡检后若发现下架，需调用 OmniRoute API 修 Combo（见 §4.6）

### 4.6 增量模式 Combo 修复

增量模式下巡检发现下架模型在已有 Combo 里，需修。当前 nim-codex Combo（DB 已建）含已下架的 qwen3-coder-480b 头号，必须修。

源码查证（§7.1）：`PUT /api/combos/{id}` 接 body `{name, models, strategy}`，非 DELETE+POST。

流程：

```bash
# 1. GET /api/combos 找 nim-codex 的 id
CODEX_ID=$(curl -s -b "$COOKIE_FILE" "$BASE_URL/api/combos" \
  | jq -r '.combos[]? | select(.name=="nim-codex") | .id')

# 2. PUT 更新 models（nim-pool 同理，按巡检结果剔下架）
curl -s -b "$COOKIE_FILE" -X PUT "$BASE_URL/api/combos/$CODEX_ID" \
  -H "Content-Type: application/json" \
  -d '{"name":"nim-codex","strategy":"context-relay","models":[
    "openai/gpt-oss-120b",
    "qwen/qwen3-next-80b-a3b-instruct",
    "mistralai/mistral-medium-3.5-128b"
  ]}'
```

nim-pool 增量修复同模板，models 数组按 §4.2 的 11 个（剔除已下架 2 个）。

---

## 5. `~/.omn_env` alias 修改设计（P0-3）

替换 `~/.omn_env` 第 10-15 行旧 alias，新内容：

```bash
# CC 模型快捷启动 Alias（全 NIM 通道）
alias gpt12='env -u ANTHROPIC_API_KEY ANTHROPIC_BASE_URL="$OMN_BASE_URL" ANTHROPIC_AUTH_TOKEN="$OMN_TOKEN" claude --model nvidia/openai/gpt-oss-120b'
alias qwen8='env -u ANTHROPIC_API_KEY ANTHROPIC_BASE_URL="$OMN_BASE_URL" ANTHROPIC_AUTH_TOKEN="$OMN_TOKEN" claude --model nvidia/qwen/qwen3-next-80b-a3b-instruct'
alias glm52='env -u ANTHROPIC_API_KEY ANTHROPIC_BASE_URL="$OMN_BASE_URL" ANTHROPIC_AUTH_TOKEN="$OMN_TOKEN" claude --model nvidia/z-ai/glm-5.2'
alias kimi26='env -u ANTHROPIC_API_KEY ANTHROPIC_BASE_URL="$OMN_BASE_URL" ANTHROPIC_AUTH_TOKEN="$OMN_TOKEN" claude --model nvidia/moonshotai/kimi-k2.6'
alias mini27='env -u ANTHROPIC_API_KEY ANTHROPIC_BASE_URL="$OMN_BASE_URL" ANTHROPIC_AUTH_TOKEN="$OMN_TOKEN" claude --model nvidia/minimaxai/minimax-m2.7'
alias vis90='env -u ANTHROPIC_API_KEY ANTHROPIC_BASE_URL="$OMN_BASE_URL" ANTHROPIC_AUTH_TOKEN="$OMN_TOKEN" claude --model nvidia/meta/llama-3.2-90b-vision-instruct'
alias nemo55='env -u ANTHROPIC_API_KEY ANTHROPIC_BASE_URL="$OMN_BASE_URL" ANTHROPIC_AUTH_TOKEN="$OMN_TOKEN" claude --model nvidia/nvidia/nemotron-3-ultra-550b-a55b'
alias dpf='env -u ANTHROPIC_API_KEY ANTHROPIC_BASE_URL="$OMN_BASE_URL" ANTHROPIC_AUTH_TOKEN="$OMN_TOKEN" claude --model nvidia/deepseek-ai/deepseek-v4-flash'
alias dpp='env -u ANTHROPIC_API_KEY ANTHROPIC_BASE_URL="$OMN_BASE_URL" ANTHROPIC_AUTH_TOKEN="$OMN_TOKEN" claude --model nvidia/deepseek-ai/deepseek-v4-pro'
```

删旧：`cg52`/`ck26`/`cm27`/`cq48`/`cd4f`/`cd4p` 全部替换。

注：`nemo55` 的 `--model` 是 `nvidia/nvidia/nemotron-3-ultra-550b-a55b`（双 nvidia 正确）。源码查证（§7.2）：full model = `${storagePrefix}/${modelId}`，storagePrefix=provider id=`nvidia`，modelId 本身含厂商子前缀（NIM 该模型为 `nvidia/nemotron-3-ultra-550b-a55b`）。故 alias `--model` 双 nvidia 前缀，与 init `register_model "nvidia/nemotron-3-super-120b-a12b"` 前缀规则一致（init modelId 无 storagePrefix，alias 加上成双）。

---

## 6. 约束与边界

1. **镜像固定 3.8.43**，不跟随 :latest
2. **NIM 32K 限制**无法从 NIM 侧解决，只能引入外部 provider 兜底（P1 任务，见 CURRENT_STATE §12.5/§12.6 后续）
3. **NIM 无下架通告渠道**，必须主动查询 `/v1/models`（巡检机制）
4. **巡检自动操作严格限制**：仅"剔除已下架"，不自动添加新模型（新模型能力需人工评估）
5. **pool 广覆盖**作为应急 catalog，日常走 alias 矩阵
6. **ping 测速非下架判据**：仅 `/v1/models` 列表 grep 失配才是下架判据
7. **DeepSeek 通道**：NIM 侧 dpf/dpp 作观测备用，503 时手动回 ds2api（不在 alias 自动切换范围）

---

## 7. 源码查证结论（writing-plans 阶段已查证，非待定）

查证依据：上游 `github.com/diegosouzapw/OmniRoute` gitee 镜像 `src/app/api/combos/` + `src/lib/providerModels/managedAvailableModels.ts`

1. **Combo 更新 API**（§4.6 已定）：`PUT /api/combos/{id}` 接 body `{name, models, strategy}`，返回更新后 combo。增量模式修 Combo 用此单端点（非 DELETE+POST）。流程：`GET /api/combos` → 找 `nim-codex` 的 `id` → `PUT /api/combos/{id}` body 含新 models 数组。源码：`src/app/api/combos/[id]/route.ts` 有 `GET/PUT/DELETE`，PUT 接 `body.models` 经 `normalizeComboModels` 归一化。

2. **`nemo55` modelId 前缀深度**（§5 已定）：`nvidia/nvidia/nemotron-3-ultra-550b-a55b`（双 nvidia 正确）。源码 `managedAvailableModels.ts`：full model = `${storagePrefix}/${modelId}`，storagePrefix 是 provider id = `nvidia`，modelId 本身含厂商子前缀（NIM 该模型为 `nvidia/nemotron-3-ultra-550b-a55b`，与 `z-ai/glm-5.2` 同级）。故 alias `--model` = `nvidia/nvidia/nemotron-3-ultra-550b-a55b`，与 init `register_model "nvidia/nemotron-3-super-120b-a12b"` 前缀规则一致（init modelId 无 storagePrefix `nvidia/`，alias 加上即双）。

3. **巡检函数嵌入位置**（§4.5 已定）：首次初始化分支 `register_model` 段之前（init 第 475 行 `echo "[init] First-time init: registering models..."` 之前）插入 `check_nim_model_health` 调用；增量模式分支（init 第 417-468 行 `if [ "${COMBO_COUNT:-0}" -gt 0 ]` 块内）插入巡检 + Combo 修复调用。

4. **DEPRECATED_MODELS 传递**：首次初始化用全局数组 `DEPRECATED_MODELS=()` + 临时文件 `/tmp/nim-deprecated.txt`，`register_model` 与 Combo 创建段读此文件跳过已下架模型。bash 数组跨函数作用域用文件传，最稳。

---

## 8. 后续任务（非本 spec 范围，提及以立边界）

- **P0-4 commit + push**：commit message 用 chinese-commit-conventions skill 写
- **P1 外部 provider 兜底**：NIM 32K 限制 + 教育安全，评估 Groq/Kiro/Antigravity/智谱（CURRENT_STATE §12 + task §六第六步）
- **P2 gate.js PATCH-GATE 回填**：stream_options 400 风险（CURRENT_STATE §6）
