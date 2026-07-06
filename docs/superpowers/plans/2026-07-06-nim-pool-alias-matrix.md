# NIM 模型池重建 + alias 矩阵 实现计划

> **面向 AI 代理的工作者：** 必需子技能：使用 superpowers:subagent-driven-development（推荐）或 superpowers:executing-plans 逐任务实现此计划。步骤使用复选框（`- [ ]`）语法来跟踪进度。

**目标：** 按 spec `docs/superpowers/specs/2026-07-06-nim-pool-alias-matrix-design.md` 重建 NIM 模型池（移下架 + 加强候选）+ 9 alias 矩阵 + init 巡检函数。

**架构：** ① `init-nim-keys.sh` 增 `check_nim_model_health()` 巡检（`/v1/models` grep 失配剔除下架）+ register_model 模型集换 13 个 + nim-pool Combo 11 + nim-codex 头号 gpt-oss-120b + 增量模式 Combo 修复。② `~/.omn_env` 9 alias 全 NIM 通道替换。

**技术栈：** bash（init 脚本）、curl + jq（OmniRoute API + NIM API）、git。

**查证依据：** spec §7 已查证 — `PUT /api/combos/{id}` 更新 Combo（非 DELETE+POST）；`nemo55` alias = `nvidia/nvidia/nemotron-3-ultra-550b-a55b`（双 nvidia 正确）。

---

## 文件结构

| 文件 | 职责 | 变更类型 |
|------|------|---------|
| `init-nim-keys.sh` | 增加 check_nim_model_health() + 换模型集 + 增量 Combo 修复 | 修改 |
| `~/.omn_env` | 9 alias 全 NIM 通道替换 | 修改 |
| `docs/CURRENT_STATE_v3.8.md` | §4/§5 同步实态（模型池换、巡检机制、查证结论） | 修改 |

init 脚本无单测框架。验证用 `bash -n` 语法检查 + 巡检函数 dry-run（mock NIM 响应）+ HF Space 重建日志实测 alias 200。spec §1.3 洞察"ping 超时非下架"指导巡检函数。

---

## 任务 1：init 增 check_nim_model_health() 巡检函数

**文件：**
- 修改：`init-nim-keys.sh`（在第 475 行 `echo "[init] First-time init: registering models..."` 之前插入函数定义 + 调用占位；函数本体定义放在第 412 行首次初始化检查块之前）

- [ ] **步骤 1：读 init 脚本确认插入位置**

读 `init-nim-keys.sh` 第 412-475 行，确认首次初始化检查块（417-472）与模型注册段（474-507）边界。函数定义插第 412 行之前（脚本早段，函数先定义后调用）。

- [ ] **步骤 2：在第 412 行之前插入 check_nim_model_health() 函数定义**

用 Edit 工具，old_string 锚定第 412 行注释 `# ── 首次初始化检查（SQLite 感知...`，new_string 在其前插入函数定义：

```bash
# ── NIM 模型健康巡检 ──────────────────────────────────────────
# 决策一/二：init 内附巡检，用 NIM /v1/models 与 PRODUCTION_MODELS 交叉比对。
# 实测洞察（spec §1.3）：下架判定只看 /v1/models 列表 grep 失配，
# ping 超时仅负载线索不算下架。自动操作严格限制"仅剔除已下架"，不自动加新模型。
# DEPRECATED_MODELS 用临时文件 /tmp/nim-deprecated.txt 跨函数传递。
check_nim_model_health() {
  echo "[init] Checking NIM model availability via /v1/models..."

  local NIM_KEY_FIRST
  # NIM_KEYS 多行字符串，取第一个非空行作巡检 key
  NIM_KEY_FIRST=$(printf '%s\n' "$NIM_KEYS" | sed '/^[[:space:]]*$/d' | head -n1 | tr -d '\r' | xargs)

  if [ -z "$NIM_KEY_FIRST" ]; then
    echo "[init] WARN: no NIM key available for health check, skipping."
    echo "" > /tmp/nim-deprecated.txt
    return 0
  fi

  local NIM_AVAILABLE
  NIM_AVAILABLE=$(curl -s --max-time 10 https://integrate.api.nvidia.com/v1/models \
    -H "Authorization: Bearer $NIM_KEY_FIRST" \
    | jq -r '.data[].id' 2>/dev/null | sort)

  local MODEL_COUNT
  MODEL_COUNT=$(printf '%s\n' "$NIM_AVAILABLE" | grep -c . 2>/dev/null || echo 0)
  if [ "$MODEL_COUNT" -lt 5 ]; then
    echo "[init] WARN: NIM /v1/models returned $MODEL_COUNT models — possible endpoint issue, skipping health check."
    echo "" > /tmp/nim-deprecated.txt
    return 0
  fi

  # 巡检 PRODUCTION_MODELS 对照集（13 个 = 11 nim-pool + 2 备用目录）
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

  local DEPRECATED_LIST=""
  echo "[init] ── NIM model availability ──"
  for model in "${PRODUCTION_MODELS[@]}"; do
    # grep -qx 精确整行匹配（防 kimi-k2-thinking 误匹 kimi-k2.6）
    if printf '%s\n' "$NIM_AVAILABLE" | grep -qx "$model"; then
      echo "[init]   OK        $model"
    else
      echo "[init]   DEPRECATED $model — not in /v1/models"
      DEPRECATED_LIST="$DEPRECATED_LIST $model"
    fi
  done
  echo "[init] ──────────────────────────────"

  # 写临时文件供 register_model/Combo 段跳过用
  printf '%s\n' $DEPRECATED_LIST > /tmp/nim-deprecated.txt
  return 0
}

# ── 首次初始化检查（SQLite 感知，替代文件标记）─────────────────────────────
# HF Space 重建后容器内文件标记消失，故改为查询 combos 表判断是否已初始化
if [ -f "$_DB_PATH" ]; then
```

- [ ] **步骤 3：bash -n 语法检查**

运行：`bash -n /home/laisi/omn-merge/init-nim-keys.sh`
预期：无输出（语法正确），exit 0

- [ ] **步骤 4：dry-run 验证巡检函数（mock 无 key 路径）**

环境无 NIM_KEYS 时函数走 "no NIM key" 分支。在临时 shell source 函数后调：

```bash
bash -c 'source <(sed -n "/^check_nim_model_health/,/^}/p" /home/laisi/omn-merge/init-nim-keys.sh); NIM_KEYS=""; check_nim_model_health; echo "deprecated file: "; cat /tmp/nim-deprecated.txt'
```

预期：打印 "no NIM key available for health check, skipping." + /tmp/nim-deprecated.txt 为空。

- [ ] **步骤 5：commit**

```bash
git add init-nim-keys.sh
git commit -m "feat(init): 增 check_nim_model_health NIM 模型健康巡检函数

spec §4.5 决策一实现：init 内附巡检，curl /v1/models 与 PRODUCTION_MODELS
交叉比对。实测洞察 spec §1.3：下架判定只看列表 grep 失配，ping 超时不算下架。
DEPRECATED_MODELS 用 /tmp/nim-deprecated.txt 跨函数传递。自动操作严格限制
仅剔下架不自动加新模型。

源码依据见 spec §7。"
```

---

## 任务 2：首次初始化分支调巡检 + register_model 模型集换 13 个

**文件：**
- 修改：`init-nim-keys.sh` 第 474-511 行（register_model 段）

- [ ] **步骤 1：Edit register_model 模型集**

old_string 锚定第 499-511 行现有 register_model 调用块，new_string 替换为新 13 个（11 核心 + 2 备用）+ 在段首插入巡检调用：

```bash
# ── 模型目录注册 ──────────────────────────────────────────────
echo "[init] First-time init: registering models..."

check_nim_model_health

register_model() {
  local MODEL_ID="$1"
  # 跳过已下架（巡检写 /tmp/nim-deprecated.txt）
  if grep -qx "$MODEL_ID" /tmp/nim-deprecated.txt 2>/dev/null; then
    echo "[init] model $MODEL_ID -> SKIPPED (deprecated by health check)"
    return 0
  fi
  local MODEL_RESP_FILE="/tmp/omniroute-model-$(echo "$MODEL_ID" | tr '/' '-').json"

  MODEL_CODE=$(curl -s -o "$MODEL_RESP_FILE" -w "%{http_code}" \
    -b "$COOKIE_FILE" \
    -X POST "$BASE_URL/api/provider-models" \
    -H "Content-Type: application/json" \
    -d "$(jq -n --arg provider "nvidia" --arg modelId "$MODEL_ID" \
      '{provider: $provider, modelId: $modelId}')")

  if [ "$MODEL_CODE" = "200" ] || [ "$MODEL_CODE" = "201" ]; then
    echo "[init] model $MODEL_ID -> OK ($MODEL_CODE)"
  elif [ "$MODEL_CODE" = "409" ]; then
    echo "[init] model $MODEL_ID -> already exists (skipped)"
  else
    echo "[init] model $MODEL_ID -> WARN HTTP $MODEL_CODE"
    cat "$MODEL_RESP_FILE" || true
  fi
}

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

echo "[init] Model registration done."
```

删旧两行：`register_model "qwen/qwen3-coder-480b-a35b-instruct"` + `moonshotai/kimi-k2-thinking`（原 500 行）。mistral-medium-3.5-128b 从 nim-pool 核心段移至备用段。

- [ ] **步骤 2：bash -n 语法检查**

运行：`bash -n /home/laisi/omn-merge/init-nim-keys.sh`
预期：exit 0 无输出

- [ ] **步骤 3：grep 确认下架模型已移除 + 新增存在**

- [ ] 运行：`grep -c "qwen3-coder-480b\|kimi-k2-thinking" /home/laisi/omn-merge/init-nim-keys.sh`
  预期：`0`（全删）
- [ ] 运行：`grep -c "gpt-oss-120b\|qwen3-next-80b\|nemotron-3-ultra-550b\|mistral-large-3-675b" /home/laisi/omn-merge/init-nim-keys.sh`
  预期：`≥4`（新增 4 个出现，外加 Combo 段会再计数，需 ≥4）

- [ ] **步骤 4：commit**

```bash
git add init-nim-keys.sh
git commit -m "fix(init): 模型池重建 移 2 下架 加 5 强候选 128b 降备用

按 spec §4.4：register_model 集换 13 个。
- 移除 qwen3-coder-480b(410 下架)、kimi-k2-thinking(/v1/models 已无，下架)
- 新增强候选 gpt-oss-120b/qwen3-next-80b/nemotron-3-ultra-550b/mistral-large-3-675b/deepseek-v4-pro
- mistral-medium-3.5-128b 间歇超时从 nim-pool 核心降备用目录(675b 替主力)
- deepseek-v4-flash 备用目录(503 风险不入 Combo)
- register_model 增下架跳过逻辑读 /tmp/nim-deprecated.txt
- 段首调 check_nim_model_health 驱动巡检"
```

---

## 任务 3：nim-pool + nim-codex Combo models 数组更新

**文件：**
- 修改：`init-nim-keys.sh` 第 515-582 行（两 Combo 创建段）

- [ ] **步骤 1：Edit nim-pool Combo models 数组**

old_string 锚定第 525-535 行 nim-pool 的 `models`: 数组（含 9 个），new_string 换为 11 个 + 跳过下架逻辑：

```bash
# nim-pool models：剔除巡检发现已下架，避免 round-robin 命中 410
NIM_POOL_MODELS=""
for m in \
  "minimaxai/minimax-m2.7" \
  "moonshotai/kimi-k2.6" \
  "z-ai/glm-5.2" \
  "nvidia/nemotron-3-super-120b-a12b" \
  "mistralai/mistral-small-4-119b-2603" \
  "meta/llama-3.2-90b-vision-instruct" \
  "openai/gpt-oss-120b" \
  "qwen/qwen3-next-80b-a3b-instruct" \
  "nvidia/nemotron-3-ultra-550b-a55b" \
  "deepseek-ai/deepseek-v4-pro" \
  "mistralai/mistral-large-3-675b-instruct-2512"; do
  if ! grep -qx "$m" /tmp/nim-deprecated.txt 2>/dev/null; then
    NIM_POOL_MODELS="${NIM_POOL_MODELS},\"$m\""
  fi
done
NIM_POOL_MODELS="${NIM_POOL_MODELS#,}"  # 去首逗号
```

然后 POST body 用 jq 动态构建：

```bash
COMBO_BODY=$(jq -n --argjson models "$(printf '[%s]' "$NIM_POOL_MODELS")" \
  '{name:"nim-pool", strategy:"round-robin", models:$models}')

COMBO_CODE=$(curl -s -o "$COMBO_RESP_FILE" -w "%{http_code}" \
  -b "$COOKIE_FILE" \
  -X POST "$BASE_URL/api/combos" \
  -H "Content-Type: application/json" \
  -d "$COMBO_BODY")
```

- [ ] **步骤 2：Edit nim-codex Combo models 数组**

old_string 锚定第 564-570 行 nim-codex 的 strategy+models（含下架 qwen3-coder 头号），new_string 换为 gpt-oss-120b 头号 + 跳下架：

```bash
# nim-codex models：context-relay 头号由下架 qwen3-coder-480b 改 gpt-oss-120b
NIM_CODEX_MODELS=""
for m in \
  "openai/gpt-oss-120b" \
  "qwen/qwen3-next-80b-a3b-instruct" \
  "mistralai/mistral-medium-3.5-128b"; do
  if ! grep -qx "$m" /tmp/nim-deprecated.txt 2>/dev/null; then
    NIM_CODEX_MODELS="${NIM_CODEX_MODELS},\"$m\""
  fi
done
NIM_CODEX_MODELS="${NIM_CODEX_MODELS#,}"

CODEX_COMBO_BODY=$(jq -n --argjson models "$(printf '[%s]' "$NIM_CODEX_MODELS")" \
  '{name:"nim-codex", strategy:"context-relay", models:$models}')

CODEX_COMBO_CODE=$(curl -s -o "$CODEX_COMBO_RESP_FILE" -w "%{http_code}" \
  -b "$COOKIE_FILE" \
  -X POST "$BASE_URL/api/combos" \
  -H "Content-Type: application/json" \
  -d "$CODEX_COMBO_BODY")
```

注意：mistral-medium-3.5-128b 在 nim-codex 仍保留（context-relay 长文摘需要 128K 窗口容忍间歇，作 relay target 非头号）；若巡检判其虽列表在但不可用，跳过。它在 nim-pool 退出但 nim-codex 留作 relay 备选。

- [ ] **步骤 3：bash -n 语法检查**

运行：`bash -n /home/laisi/omn-merge/init-nim-keys.sh`
预期：exit 0

- [ ] **步骤 4：grep 确认旧静态 models 数列已删**

运行：`grep -c '"qwen/qwen3-coder-480b-a35b-instruct"' /home/laisi/omn-merge/init-nim-keys.sh`
预期：`0`（下架模型不再硬编码进 Combo body）

- [ ] **步骤 5：commit**

```bash
git add init-nim-keys.sh
git commit -m "feat(init): nim-pool/nim-codex Combo models 动态构建剔除下架

按 spec §4.2/§4.3：
- nim-pool Combo 11 模型(去 2 下架 + 675b 替 128b + 加强候选)
- nim-codex Combo 头号由下架 qwen3-coder-480b 改 gpt-oss-120b(spec §4.3)
  context-relay 需快多 Key 拼上下文，gpt-oss 1.1-1.9s 稳
- Combo models 改动态构建循环读 /tmp/nim-deprecated.txt 剔下架
  避免硬编码下架模型 → round-robin 命中 410 浪费轮转"
```

---

## 任务 4：增量模式分支加巡检 + Combo 修复

**文件：**
- 修改：`init-nim-keys.sh` 第 419-468 行（`if [ "${COMBO_COUNT:-0}" -gt 0 ]` 增量分支）

- [ ] **步骤 1：Edit 增量分支插入巡检 + Combo 修复**

old_string 锚定第 420-422 行：

```bash
  if [ "${COMBO_COUNT:-0}" -gt 0 ]; then
    echo "[init] Already initialized (nim-pool found in DB), skip first-time setup."

    # ===== 配置快照导出到 HF Dataset（重建场景：DB 有完整配置）=====
```

new_string 在 skip echo 后、HF Dataset 段前插入巡检 + Combo 修复：

```bash
  if [ "${COMBO_COUNT:-0}" -gt 0 ]; then
    echo "[init] Already initialized (nim-pool found in DB), skip first-time setup."

    # ===== 巡检 + 增量 Combo 修复（spec §4.6）=====
    check_nim_model_health

    if [ -s /tmp/nim-deprecated.txt ]; then
      echo "[init] Incremental: deprecated models detected, repairing Combos..."
      # GET /api/combos 找各 Combo id
      COMBOS_JSON=$(curl -s -b "$COOKIE_FILE" "$BASE_URL/api/combos")
      for combo_name in nim-pool nim-codex; do
        local CID
        CID=$(printf '%s' "$COMBOS_JSON" | jq -r --arg n "$combo_name" \
          '.combos[]? // .[]? | select(.name==$n) | .id' | head -n1)
        if [ -n "$CID" ]; then
          # 按 Combo 名重算 models（剔除下架）
          local NEW_MODELS=""
          if [ "$combo_name" = "nim-pool" ]; then
            for m in "minimaxai/minimax-m2.7" "moonshotai/kimi-k2.6" "z-ai/glm-5.2" \
                     "nvidia/nemotron-3-super-120b-a12b" "mistralai/mistral-small-4-119b-2603" \
                     "meta/llama-3.2-90b-vision-instruct" "openai/gpt-oss-120b" \
                     "qwen/qwen3-next-80b-a3b-instruct" "nvidia/nemotron-3-ultra-550b-a55b" \
                     "deepseek-ai/deepseek-v4-pro" "mistralai/mistral-large-3-675b-instruct-2512"; do
              grep -qx "$m" /tmp/nim-deprecated.txt 2>/dev/null || NEW_MODELS="${NEW_MODELS},\"$m\""
            done
            local STRAT="round-robin"
          else
            for m in "openai/gpt-oss-120b" "qwen/qwen3-next-80b-a3b-instruct" "mistralai/mistral-medium-3.5-128b"; do
              grep -qx "$m" /tmp/nim-deprecated.txt 2>/dev/null || NEW_MODELS="${NEW_MODELS},\"$m\""
            done
            local STRAT="context-relay"
          fi
          NEW_MODELS="${NEW_MODELS#,}"
          local PUT_BODY
          PUT_BODY=$(jq -n --arg name "$combo_name" --arg strat "$STRAT" \
            --argjson models "$(printf '[%s]' "$NEW_MODELS")" \
            '{name:$name, strategy:$strat, models:$models}')
          local PUT_CODE
          PUT_CODE=$(curl -s -o /dev/null -w "%{http_code}" \
            -b "$COOKIE_FILE" -X PUT "$BASE_URL/api/combos/$CID" \
            -H "Content-Type: application/json" -d "$PUT_BODY")
          echo "[init] Incremental: PUT /api/combos/$CID ($combo_name) HTTP $PUT_CODE"
        else
          echo "[init] Incremental: $combo_name not found in DB, skip repair."
        fi
      done
    else
      echo "[init] Incremental: no deprecated models, Combos OK."
    fi

    # ===== 配置快照导出到 HF Dataset（重建场景：DB 有完整配置）=====
```

- [ ] **步骤 2：bash -n 语法检查**

运行：`bash -n /home/laisi/omn-merge/init-nim-keys.sh`
预期：exit 0

注意：`local` 在 `if` 块顶层非函数内可用 bash 4+ 容忍，但 `local` 仅在函数内有作用域意义。此处 `local` 实际作用等同普通变量（增量分支不在函数内）。若 `bash -n` 报 `local: not in a function` 警告（非错误），改 `local` 为去掉前缀的普通赋值。

- [ ] **步骤 3：grep 确认增量修复逻辑存在**

运行：`grep -c "PUT .*api/combos/\$CID\|Incremental: deprecated" /home/laisi/omn-merge/init-nim-keys.sh`
预期：`≥2`

- [ ] **步骤 4：commit**

```bash
git add init-nim-keys.sh
git commit -m "feat(init): 增量模式 Combo 修复 巡检发现下架 PUT /api/combos/{id}

按 spec §4.6 已查证：PUT /api/combos/{id} body {name,models,strategy}
更新已存 Combo(源码 [id]/route.ts GET/PUT/DELETE)。
增量模式（nim-pool 已在 DB）调巡检，若 /tmp/nim-deprecated.txt 非空
则 GET 找 nim-pool/nim-codex 的 id → PUT 重算 models 剔下架。
修当前 DB 已建 nim-codex 含下架 qwen3-coder-480b 头号的问题。"
```

---

## 任务 5：~/.omn_env 9 alias 全替换

**文件：**
- 修改：`~/.omn_env`（第 10-15 行 alias）

- [ ] **步骤 1：读 ~/.omn_env 确认现状**

读 `/home/laisi/.omn_env`，确认现有 6 alias（cg52/ck26/cm27/cq48/cd4f/cd4p）在第 10-15 行。

- [ ] **步骤 2：Edit 替换第 10-15 行 alias 段**

old_string 锚定第 9-15 行注释 + 6 alias，new_string 换为 9 alias 全 NIM 通道：

```bash
# CC 模型快捷启动 Alias（全 NIM 通道，spec §3.2 / §5）
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

nemo55 双 nvidia 已实证（spec §7.2）。dpf/dpp 改 NIM 通道（OMN_*），原走 ds2api 的 cd4f/cd4p 删除（DeepSeek 通道废弃，spec §3.2 决策）。

- [ ] **步骤 3：bash 语法检查 omn_env**

运行：`bash -n /home/laisi/.omn_env`
预期：exit 0 无输出

- [ ] **步骤 4：source 验证 alias 定义生效**

运行：`bash -c 'source /home/laisi/.omn_env && type gpt12 glm52 nemo55 dpf'`
预期：每 alias 输出 `gpt12 is aliased to 'env -u ...'`，4 行均有。

- [ ] **步骤 5：grep 确认旧 alias 清除**

运行：`grep -E "^alias (cg52|cq48|cd4f|cd4p|ck26|cm27)=" /home/laisi/.omn_env`
预期：无输出（6 旧 alias 全删）

- [ ] **步骤 6：commit（omn_env 在 home 不在仓库，跳过 git，记功效）**

`~/.omn_env` 不在仓库（home 目录），不 commit。此步确认 alias 生效为准。若需版本化，可选 ln 到仓库或 skip。验证完成即任务完成。

---

## 任务 6：CURRENT_STATE_v3.8.md 实态同步

**文件：**
- 修改：`docs/CURRENT_STATE_v3.8.md` §4（Combo 模型池）+ §5（NIM 上架）+ §12（下一步清单）

- [ ] **步骤 1：Edit §4 Combo 模型池段（第 73-101 行）**

更新 nim-pool 11 模型 + nim-codex 头号 gpt-oss-120b + 备用目录 2 模型，移除下架表注。

- [ ] **步骤 2：Edit §5 NIM 模型上架段（第 105-143 行）**

更新实证结论：
- 下架从 1 个改 2 个（增 kimi-k2-thinking）
- 9 → 12 模型 nim-pool + 2 备用，重列表格
- 新增 ping 测速实证表（§1.2 内容）
- 新增"ping 超时非下架"洞察
- §5.3 未核验范围收缩（已带 nvapi key 核验完）

- [ ] **步骤 3：Edit §12 下一步清单（第 226-237 行）**

第 5 项 "NIM 模型池实际核验" 标记完成，引用本 spec + plan 路径。

- [ ] **步骤 4：grep 确认 §5/§4 旧"9 个模型"措辞已更新**

运行：`grep -c "9 个模型\|qwen3-coder-480b.*nim-pool" docs/CURRENT_STATE_v3.8.md`
预期：`0`（旧描述清）

- [ ] **步骤 5：commit**

```bash
git add docs/CURRENT_STATE_v3.8.md
git commit -m "docs(state): §4/§5/§12 同步 NIM 模型池重建实态

spec §1 实证写入 SSOT：
- §4 nim-pool 11 + nim-codex 头号 gpt-oss-120b + 备用 2
- §5 下架从 1 增 2(kimi-k2-thinking 新发现)，加 ping 测速表
- §5.3 未核验范围收口(已带 nvapi key 核验)
- §12 第 5 项核验标记完成引用 spec/plan 路径"
```

---

## 任务 7：端到端验证 + 最终 commit/push

**文件：**
- 验证：`init-nim-keys.sh` 整体脚本 + `~/.omn_env`

- [ ] **步骤 1：全脚本 bash -n 最终语法检查**

运行：`bash -n /home/laisi/omn-merge/init-nim-keys.sh`
预期：exit 0

- [ ] **步骤 2：shellcheck 静态检查（若装了）**

运行：`shellcheck /home/laisi/omn-merge/init-nim-keys.sh 2>/dev/null || echo "shellcheck not installed, skip"`
预期：无 error 级问题（warning 可接受）

- [ ] **步骤 3：grep 总览模型集一致性**

运行：

```bash
echo "=== init 内 PRODUCTION_MODELS referenced ==="
grep -oE '"(minimaxai/minimax-m2.7|moonshotai/kimi-k2.6|z-ai/glm-5.2|nvidia/nemotron-3-super-120b-a12b|mistralai/mistral-small-4-119b-2603|mistralai/mistral-medium-3.5-128b|meta/llama-3.2-90b-vision-instruct|openai/gpt-oss-120b|qwen/qwen3-next-80b-a3b-instruct|nvidia/nemotron-3-ultra-550b-a55b|deepseek-ai/deepseek-v4-pro|mistralai/mistral-large-3-675b-instruct-2512)"' /home/laisi/omn-merge/init-nim-keys.sh | sort | uniq -c
```

预期：13 个模型每个出现 ≥1 次（nim-pool 列 + nim-codex 列 + 增量修复 + 巡检集）。kimi-k2-thinking / qwen3-coder-480b 不出现。

- [ ] **步骤 4：alias 矩阵在 HF Space 重建后实测**

HF Space 重建触发 init → 巡检跑 → model 注册 + Combo 创建/修复 → alias 200。需用户手动触发重建或等下次自然重建。

运行：`source /home/laisi/.omn_env && gpt12 --version && echo "gpt12 launch OK"`（确认 alias 可启动 Claude，真调 API 待重建后）

- [ ] **步骤 5：git log 确认所有任务 commit 落定**

运行：`git log --oneline -8`
预期：见任务 1-6 的 commit + spec 2 commit，共约 8 个。

- [ ] **步骤 6：push 到远端**

```bash
git push origin main
```

预期：push 成功，远端 nomn/main 含所有 commit。

---

## 自检

1. **规格覆盖度**：spec §2(标准) → alias 矩阵任务 5；§4.1-4.6(init 改) → 任务 1-4；§5(omn_env) → 任务 5；§7(查证) → 计划查证段 + 后续任务引用；§1 实证 → 任务 6 同步 SSOT。无遗漏。
2. **占位符扫描**：无 "TODO/待定/类似任务N"。每步骤含完整代码或精确命令。任务 4 步骤 2 关于 `local` 警告的预案已写明。
3. **类型一致性**：PRODUCTION_MODELS 13 项在任务 1（定义）、任务 2（register）、任务 3（Combo 数组）、任务 4（增量修复）四处一致；nim-pool 11 / nim-codex 3 跨任务一致；`/tmp/nim-deprecated.txt` 路径跨任务一致；`PUT /api/combos/{id}` 端点跨任务一致。

## 执行交接

计划已完成并保存到 `docs/superpowers/plans/2026-07-06-nim-pool-alias-matrix.md`。两种执行方式：

**1. 子代理驱动（推荐）** - 每个任务调度一个新的子代理，任务间进行审查，快速迭代

**2. 内联执行** - 在当前会话中使用 executing-plans 执行任务，批量执行并设有检查点

选哪种方式？
