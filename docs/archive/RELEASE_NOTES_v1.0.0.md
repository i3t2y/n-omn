# Release Notes: v1.0.0

> ⚠️ **历史快照**（v1.0.0, 2026-04-25），记录当时实态，**勿改**（正文是 v1.0.0 release 当时证据，改则版本自矛盾）。当前真态见 [`docs/CURRENT_STATE_v3.8.md`](CURRENT_STATE_v3.8.md)。

Release date: 2026-04-25

## Overview

`v1.0.0` is the first stable GitHub baseline for `nim-omniroute-gateway`.

This release captures the currently working anti-template-loss deployment of the NVIDIA NIM + OmniRoute gateway. It prioritizes reproducibility, operational recovery, and AI handoff clarity over maximum throughput.

## Included

- Hugging Face Space deployment files.
- OmniRoute startup wrapper.
- `gate.js` proxy layer.
- NIM provider initialization script.
- 25-key NIM provider registration.
- Provider rate-limit protection.
- Resilience configuration.
- `nim-pool` production Combo.
- `nim-pool-lab` experimental Combo plan.
- Documentation:
  - `README.md`
  - `docs/DECISIONS.md`
  - `docs/TROUBLESHOOTING.md`
  - `docs/VALIDATION.md`
  - `docs/AI_HANDOFF.md`

## Production model pool

`nim-pool` contains only models validated as production-stable:

- `nvidia/meta/llama-3.3-70b-instruct`
- `nvidia/z-ai/glm-5.1`
- `nvidia/qwen/qwen3-coder-480b-a35b-instruct`

## Experimental model pool

The following models are not part of the production pool in `v1.0.0`:

- `nvidia/deepseek-ai/deepseek-v4-pro`
- `nvidia/deepseek-ai/deepseek-v4-flash`
- `nvidia/minimaxai/minimax-m2.7`
- `nvidia/moonshotai/kimi-k2.5`

They remain candidates for `nim-pool-lab`.

## Resilience baseline

```json
{
  "defaults": {
    "requestsPerMinute": 28,
    "minTimeBetweenRequests": 1,
    "concurrentRequests": 5
  }
}
```

`requestsPerMinute=28` is intentionally conservative for the first stable release. RPM 32 and 35 should be tested in later performance-focused issues.

## Known limitations

- Some provider tests may return `Provider returned empty content`.
- Some providers may enter short rate-limit cooldown after intensive testing.
- Kimi, DeepSeek, and MiniMax are not production-stable in the current validation record.
- Hugging Face Space state must be treated as rebuildable, not as durable SSOT.
- Dashboard model display requires `/api/provider-models`; Combo routing alone is not enough.

## Validation evidence

Validated before release:

- 25 NIM providers registered.
- Provider protection enabled.
- Resilience PATCH returned HTTP 200.
- `nim-pool` Combo created and repaired.
- `nim-pool` routed correctly to NVIDIA provider.
- Production model set reduced to 3 stable models.
```

原因：GitHub Release 页面需要一份清晰的发布说明，`docs/RELEASE_NOTES_v1.0.0.md` 可以作为创建 Release 时的复制源。GitHub Release 基于 tag，适合固化当前可恢复点。  
实测证据：`1.3.0.txt` Line 6001、6024、7593；GitHub 官方说明 Release 是基于 Git tag 的可发布软件迭代。 [GitHub Docs](https://docs.github.com/repositories/releasing-projects-on-github/about-releases)

---
