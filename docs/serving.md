# Serving

Operational detail for the four server stacks. Speed comparisons are in
[performance.md](./performance.md); what to serve is in [models.md](./models.md).

| Server               | Start               | Endpoint                                      | Purpose |
|----------------------|---------------------|-----------------------------------------------|---------|
| omlx                 | `make omlx-start`   | `http://127.0.0.1:8000/v1`                    | **Default.** All model classes: chat, VLM, embeddings, rerank, audio |
| vllm-mlx             | `make vllm-start`   | `http://127.0.0.1:8000/v1`                    | Alternative engine; at parity with omlx since 0.5.4rc1 |
| stable-diffusion.cpp | `make sd-start`     | `http://127.0.0.1:7860/v1/images/generations` | Text-to-image (FLUX.2 Klein 4B) |
| mlx_lm.server        | `make server-start` | `http://127.0.0.1:5001/v1`                    | Legacy, single-model, testing only |

omlx and vllm-mlx both bind `:8000` — stop one before starting the other.

## omlx

Endpoints on `:8000`: `/v1/chat/completions`, `/v1/completions`, `/v1/models`,
`/v1/embeddings`, `/v1/rerank`, `/v1/responses`, `/v1/audio/{speech,transcriptions,voices}`,
`/v1/messages`, `/v1/mcp/*`, plus an `/admin` UI.

```bash
brew tap jundot/omlx https://github.com/jundot/omlx
brew trust jundot/omlx           # newer Homebrew refuses untrusted third-party taps
brew install omlx
brew services start omlx         # run as a background service (auto-restarts)

brew update && brew upgrade omlx
make omlx-restart                # REQUIRED after upgrade — see below
```

### The live config is `~/.omlx/settings.json`, not the Makefile

On these machines omlx runs as a Homebrew LaunchAgent whose `ProgramArguments`
are just `omlx serve` with **no flags**, so every effective setting — host, port,
model dir, memory guard, cache, sampling — comes from `~/.omlx/settings.json`.

`make/omlx.mk`'s `OMLX_EXTRA_ARGS` documents the intended configuration but only
applies to the nohup source-install fallback (`OMLX_FORCE_NOHUP=1`). **To change
live behaviour: edit `~/.omlx/settings.json`, then `make omlx-restart`.**
(The M2 Pro's `settings.json` currently uses tier `custom` with a 30 GB ceiling.)

`scripts/omlx.sh` owns all lifecycle logic and is brew-aware: it delegates
start/stop/restart to `brew services` when omlx is Homebrew-managed (which owns
`:8000` via KeepAlive), polls `/v1/models` until healthy, and force-recovers from
an orphaned `omlx-server` that survives a `brew services restart`.

### ⚠️ `brew upgrade omlx` does NOT restart the running server

It deletes the old Cellar directory while the LaunchAgent keeps serving from the
now-missing path — KeepAlive doesn't notice. Symptom: endpoints whose
dependencies only exist in the *new* build start returning 500, and tracebacks
print file paths for a version that is no longer on disk, **with no source lines**.

This bit us on 2026-08-01: a 26-day-old 0.4.4 process was serving while 0.5.4rc1
sat installed and unused, breaking `/v1/embeddings` and both `/v1/audio/*`
endpoints. Always `make omlx-restart` after upgrading, then confirm freshness:

```bash
ps -axo pid,etime,comm | grep omlx-server        # etime must be small
lsof -p "$(pgrep -f omlx-server | head -1)" | grep -o '/opt/homebrew/Cellar/omlx/[^/]*' | sort -u
```

The audio/embedding deps (`mlx_audio`, `mlx_embeddings`) ship **inside the
Homebrew build** — 0.4.4 lacked them, 0.5.4rc1 has them. If those endpoints 500
with `No module named 'mlx_audio.tts.models'`, do **not** `pip install`; you are
running a stale server.

### Letting clients choose behaviour

omlx offers two ways to expose a capability and let the caller decide whether to
use it. They differ in what the client has to know.

**1. Request parameters** — for clients you control. `ChatCompletionRequest`
accepts `thinking_budget`, `chat_template_kwargs`, `guided_grammar`,
`structured_outputs`, `specprefill*` and the full sampling set. Per-model server
settings act as defaults that these override.

**2. Exposed profiles** — for clients that only know how to pick a model name
(Codex CLI, Qwen Code, IDE plugins). A named profile marked `expose_as_model`
is advertised in `/v1/models` as its own ID, `{base_model}:{api_name}`.

Profiles live in `~/.omlx/model_profiles.json`, read at startup. The admin API
(`POST /admin/api/models/{id}/profiles`) requires admin auth; writing the file
directly and restarting does not.

```json
{
  "version": 1,
  "profiles": {
    "mlx-community__Qwen3.6-35B-A3B-nvfp4": {
      "fast": {
        "name": "fast",
        "display_name": "Fast (no thinking)",
        "api_name": "fast",
        "description": "Thinking disabled for latency-sensitive callers.",
        "settings": { "enable_thinking": false },
        "expose_as_model": true
      }
    }
  }
}
```

After `make omlx-restart`, `mlx-community__Qwen3.6-35B-A3B-nvfp4:fast` is
selectable like any other model. Measured on the M2 Pro, same prompt
("What is 17*23? Reply with just the number."):

| model ID | generated | `content` | `reasoning_content` | wall |
|---|---:|---|---|---:|
| `…-nvfp4` | 256 tok | `391` | 664 chars | 4.87 s |
| `…-nvfp4:fast` | 3 tok | `391` | — | **0.41 s** |

Same answer, 12× faster. The profile reuses the base model's loaded engine — a
cold 19 GB load would take 15–20 s, so 0.41 s confirms no reload.

**Which fields cost a reload.** `omlx/model_profiles.py` splits settings in two:

- `UNIVERSAL_PROFILE_FIELDS` (19) — applied as a request-time overlay, **no
  reload**: `temperature`, `top_p`/`top_k`/`min_p`, the penalties,
  `enable_thinking`, `preserve_thinking`, `thinking_budget_*`,
  `reasoning_parser`, `guided_grammar*`, `chat_template_kwargs`,
  `forced_ct_kwargs`, `max_context_window`, `max_tokens`, `force_sampling`,
  `max_tool_result_tokens`.
- `MODEL_SPECIFIC_PROFILE_FIELDS` (28) — engine-construction fields that trigger
  a **transient engine variant reload**: `turboquant_kv_*`, `mtp_*`,
  `vlm_mtp_*`, `dflash_*`, `specprefill_*`, `index_cache_freq`.

So thinking toggles are free to switch; TurboQuant KV and MTP are not.

**Locking a setting against clients.** `forced_ct_kwargs` is a per-model list of
`chat_template_kwargs` keys the client **cannot** override. The precedence chain
(`model_settings.py::merge_chat_template_kwargs`), lowest to highest:

1. `settings.chat_template_kwargs`
2. the dedicated `enable_thinking` / `preserve_thinking` toggles
3. per-request `chat_template_kwargs` — *except* keys in `forced_ct_kwargs`
4. thinking-budget activation, when `enable_thinking` is still unset
5. the model's preserve-thinking default

That makes each key individually either a default (client may override) or a
lock (client may not).

### Thinking control

The deployed Qwen3.6 MoE is a reasoning model. Thinking is **on by default** and
the trace is returned in a separate `reasoning_content` field, not in `content`.

| request | generated | `content` | `reasoning_content` |
|---|---:|---|---|
| default | 300 tok | `391` | present |
| `chat_template_kwargs: {"enable_thinking": false}` | 3 tok | `391` | absent |
| `thinking_budget: 0` | 5 tok | `391` | absent |
| `thinking_budget: 128` | 132 tok | `391` | present |

> ⚠️ **Do not use a small `thinking_budget`, and do not judge a reasoning model
> by a low `max_tokens`.** Truncating mid-thought leaves the `<think>` block
> unclosed, so the parser cannot split it and the partial reasoning **spills
> into `content`**. Measured: `thinking_budget: 32` returned
> `'- Constraint: "Reply with just the number."'` as the answer — and generated
> *more* tokens (275) than `thinking_budget: 128` (132), having fallen into a
> repetition loop. 128 and up behave correctly. To switch thinking off, use
> `enable_thinking: false`, never a tiny budget.

**New models rarely need configuration for this.** `<think>` stripping is done
by `omlx/adapter/output_parser.py`, which detects the protocol per model family
(Harmony sessions, DeepSeek V4, Cohere2 MoE, MiniMax's `<mm:think>` normalized
to `<think>`, …). Tool-call parsers are auto-detected too — the log line
`VLM tool calling enabled: parser=qwen3_coder` comes from a model whose settings
are `{}`. The `reasoning_parser` setting is **not** the think-stripper: it is
only used to build xgrammar structural tags (`server.py::_patch_output_format`),
i.e. when structured output and reasoning are combined. Per-model config is
needed only for non-default behaviour, engine-level features, or that
structured-output-plus-reasoning case.

### Memory tuning

- **System**: `make optimize-system` raises `iogpu.wired_limit_mb` to 30720.
  **macOS resets this on every reboot** — re-run after each boot, or omlx clamps
  to the kernel value and logs `Metal cap (…) is below the oMLX static ceiling (…)`.
  Effective ceiling = `min(omlx ceiling, iogpu cap) − hot_cache_max_size`.
  (The M5 box is currently set to 26000.)
- **omlx flags** (`make/omlx.mk`, `OMLX_EXTRA_ARGS`):
  - `--memory-guard aggressive` — use most of memory for throughput, with a guard
    reserve. omlx 0.4.x **removed `--max-process-memory`**; use
    `--memory-guard {safe,balanced,aggressive}` or `--memory-guard-gb N` for a
    hard ceiling. `aggressive` preserves the old 90% intent.
  - `--hot-cache-max-size 4GB` — prefix caching; near-zero latency on repeated
    prompts (up to 6.4× on long-context repeats).
  - `--max-concurrent-requests 2` — reduces memory fragmentation.
  - `--initial-cache-blocks 1024` — pre-allocates KV cache to avoid allocation locks.

## vllm-mlx

A vLLM-style OpenAI-compatible server with a native MLX backend (PyPI, by
waybarrios). Kept as an alternative engine — see [performance.md](./performance.md)
for why it is no longer a throughput upgrade on the M2 Pro.

```bash
uv tool install vllm-mlx     # ~2.5 GB; pulls in PyTorch
make omlx-stop               # free port 8000
make vllm-start
make vllm-bench
```

Flag mapping from omlx:

| omlx | vllm-mlx |
|------|----------|
| `--memory-guard aggressive` (was `--max-process-memory 90%`) | `--gpu-memory-utilization 0.90` |
| `--hot-cache-max-size 4GB` | `--cache-memory-mb 4096` |
| `--max-concurrent-requests 2` | `--max-num-seqs 2` |
| `--initial-cache-blocks 1024` | `--use-paged-cache --max-cache-blocks 1024` |

`make vllm-bench` passes `--no-unload` because vllm-mlx has no per-model unload
endpoint.

**Gemma 4 26B (`Gemma4ForConditionalGeneration`) crashed on vllm-mlx 0.2.9** —
`mlx_vlm` thread/stream bug: `RuntimeError: There is no Stream(gpu, 0) in current
thread`, in both `--mllm` and auto-detected modes, with streaming silently
returning empty completions. **Fixed in 0.3.0**; re-tested 2026-06-07 on M5, both
streaming and non-streaming generate correctly (~30 tok/s @ 512). A non-fatal
`Failed to build TextModel from vlm: float division by zero` warning at load
falls back to the full VLM path and does not block generation.

## stable-diffusion.cpp

FLUX.2 Klein 4B distilled, text-to-image, on `:7860` via the OpenAI
`/v1/images/generations` shape — chosen so it coexists with omlx on 8000.

```bash
make sd-install           # macOS ARM64 binary -> bin/
make sd-model-download    # diffusion model + VAE + Qwen3-4B encoder -> models-sd/
make sd-start
```

Needs three files, not one: FLUX.2 uses an **LLM** (Qwen3-4B) as its text
encoder rather than CLIP/T5. The distilled model requires `--cfg-scale 1.0
--steps 4` (set in `make/sd.mk` as `SD_EXTRA_ARGS`).

## mlx_lm.server (legacy)

The original single-model server from mlx-lm, kept on `:5001` for testing a model
straight out of mlx-lm without omlx in the way. One model at a time, no LRU
memory management, no embeddings/rerank/audio endpoints.

```bash
make server-start         # SERVER_MODULE=mlx_vlm.server for VLMs
make verify               # smoke-test + inspect the local config.json
```

## Process and log files

omlx under Homebrew logs to `$(brew --prefix)/var/log/omlx.log` and
`~/.omlx/logs/`; the repo-root `omlx-server.pid`/`.log` pair is used only by the
source-install fallback. The other three servers do use repo-root PID + log
files: `vllm-server.*`, `sd-server.*`, `mlx-server.*`. All are gitignored.

## Pointing coding assistants at omlx

Use the `__` slug, and update it whenever the default model changes.

**Codex CLI** (`~/.codex/config.toml`) — omlx serves `/v1/responses` natively:

```toml
model_provider = "omlx"
model = "mlx-community__Qwen3.6-35B-A3B-nvfp4"

[model_providers.omlx]
name = "oMLX"
base_url = "http://127.0.0.1:8000/v1"
wire_api = "responses"
```

**Qwen Code** (`~/.qwen/settings.json`):

```json
{
  "security": { "auth": { "selectedType": "openai" } },
  "model": { "name": "mlx-community__Qwen3.6-35B-A3B-nvfp4" },
  "openaiBaseUrl": "http://127.0.0.1:8000/v1"
}
```
