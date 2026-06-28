# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Multi-machine setup

This repo runs on **two dev machines**, both 32 GB:

| Machine          | Chip               | Memory bandwidth | Notes                                 |
| ---------------- | ------------------ | ---------------- | ------------------------------------- |
| M2 Pro MacBook   | Apple M2 Pro       | 200 GB/s         | Older but higher memory bandwidth     |
| M5 MacBook Pro   | Apple M5 (base)    | 153.6 GB/s       | Newer; faster GPU/NPU but narrower bus |

Decode tok/s on Apple Silicon is memory-bandwidth-bound, so the M2 Pro is **faster** for dense decode despite the M5's newer architecture. Always identify the host before running benchmarks or downloading weights:

```bash
make detect-machine                          # human-readable: chip / RAM / bandwidth / wired limit
bash scripts/detect_machine.sh --quiet       # KEY=VALUE for `eval $(...)`
bash scripts/detect_machine.sh --check=M5    # exit 1 if not running on the expected chip
```

`make model-download`, `make omlx-start`, `make bench`, and `scripts/bootstrap.sh` all print this header automatically.

## Commands

```bash
# One-click on a fresh Apple Silicon Mac (idempotent, driven by scripts/bootstrap.sh)
make quickstart                  # platform check -> uv (auto-install) -> deps -> model -> omlx serve -> /v1/models probe

# Install
uv sync                          # base deps
uv sync --extra server           # + mlx-lm, mlx-vlm, huggingface_hub  (or: make server-install)

# omlx (Homebrew tap)
brew tap jundot/omlx https://github.com/jundot/omlx
brew trust jundot/omlx           # newer Homebrew refuses untrusted third-party taps
brew install omlx                # install omlx
brew update && brew upgrade omlx # upgrade to latest
brew services start omlx         # run as background service (auto-restarts)

# Test / lint / types
uv run pytest
uv run pytest tests/test_hello.py::test_hello   # single test
uv run ruff check .
uv run ruff format .
uv run mypy .                                    # strict mode

# Benchmark MLX vs omlx
uv run mlx-bench                                 # or: make bench

# omlx multi-model server (default on both M2 Pro & M5)
make omlx-start | omlx-stop | omlx-restart | omlx-status | omlx-logs [b]default[/b]
make omlx-bench                           # benchmark model via mlx-bench --no-unload

# vllm-mlx (alternative server, higher raw tok/s for text-only LLMs)
make vllm-start | vllm-stop | vllm-restart | vllm-status | vllm-logs
make vllm-bench                           # benchmark VLLM_MODEL_SLUG with --no-unload
```

`HF_TOKEN` is **optional** — the default model is public. Pass it only for gated/private repos.

## Default serving target

`MODEL_REPO` is **per-machine** — the Makefile picks it from `scripts/detect_machine.sh` (M5 → Gemma 4, everything else → Qwen). Override with `MODEL_REPO=... make <target>`.

| Var            | Value                                                              |
| -------------- | ------------------------------------------------------------------ |
| `MODEL_REPO` (M2 Pro) | `mlx-community/Qwen3.6-35B-A3B-nvfp4` (MoE, 3B active, 256k ctx) |
| `MODEL_REPO` (M5)     | `mlx-community/gemma-4-26B-A4B-it-qat-nvfp4` (Gemma 4 VLM, 256k ctx) |
| `MODEL_DIR`        | `models/<MODEL_REPO with / → __>/` (derived)                    |
| `VLLM_MODEL_REPO`  | follows `MODEL_REPO` (defaults to `$(MODEL_REPO)`)               |
| `VLLM_HOST`        | `0.0.0.0`                                                          |
| `VLLM_PORT`        | `8000`                                                             |
| `OMLX_HOST`        | `0.0.0.0`                                                          |
| `OMLX_PORT`        | `8000`                                                             |
| `OMLX_MODEL_DIR`   | `models`                                                           |

**Per-machine deployment (2026-06-28):**
- **M2 Pro → Qwen via omlx** (switched to omlx 2026-06-28; previously vllm-mlx since 2026-05-03).
- **M5 → Gemma 4 via omlx** (switched 2026-06-28). M5's `models/` holds `mlx-community__gemma-4-26B-A4B-it-qat-nvfp4` (main chat/VLM) plus `mlx-community__Qwen3-Embedding-0.6B-4bit-DWQ` (embeddings, for testing) — the 3 Qwen chat dirs + the non-QAT Gemma were removed.

omlx and vllm-mlx both bind `:8000`; stop one before starting the other.

### Quantization on this hardware — empirical, not theoretical

Published MLX guidance (early 2026): DWQ-4bit > standard 4bit > NVFP4 / MXFP4, because FP4 formats fall back to FP16 on MLX and lose the bandwidth win.

**On the M5 box** that does NOT hold. Three runs on 2026-05-03 (omlx, Qwen3.6-35B-A3B):

| Run                      | NVFP4 tok/s | DWQ tok/s |
|--------------------------|------------:|----------:|
| Cold, 512 tokens         | 39.74       | 31.33     |
| Cold-ish, 1024 tokens    | 36.47       | 29.23     |
| Warm, 1024 tokens        | **49.14**   | 32.11     |

NVFP4 is 1.25–1.53× faster on M5 — gap widens with warm state. Warm NVFP4 (~49 tok/s) actually beats the historical M2 Pro 4-bit ceiling (45.8 tok/s). Likely cause: M5's GPU neural accelerators (announced Oct 2025) and/or omlx-specific FP4 kernels. So:
- **M5**: among Qwen quants, NVFP4 is fastest. As of 2026-06-28 M5 no longer keeps Qwen (it serves Gemma 4 only) — but if you reintroduce a Qwen on M5, prefer `mlx-community/Qwen3.6-35B-A3B-nvfp4`.
- **M2 Pro**: not yet re-measured; conventional wisdom (DWQ > NVFP4) likely still holds. Re-test before changing the M2 Pro setup.
- Raw logs in [`bench-results/`](./bench-results/).

### Performance Optimization (M-series)

The following optimizations are enabled for `omlx` to maximize throughput (applies to any served model; M5's current model is `gemma-4-26B-A4B-it-qat-nvfp4`):

- **System-level**: Run `make optimize-system` to raise `iogpu.wired_limit_mb` (current default: `30000`; M5 32 GB box is currently set to `26000`).
- **omlx flags** (in `Makefile` under `OMLX_EXTRA_ARGS`):
  - `--memory-guard aggressive`: Allow omlx to use most of memory for throughput, with a guard reserve. **omlx 0.4.x removed `--max-process-memory`** — use `--memory-guard {safe,balanced,aggressive}` (or `--memory-guard-gb N` for a hard ceiling) instead. `aggressive` preserves the old `90%` intent.
  - `--hot-cache-max-size 4GB`: Prefix caching for near-zero latency on repeating prompts.
  - `--max-concurrent-requests 2`: Reduces memory fragmentation.
  - `--initial-cache-blocks 1024`: Pre-allocates KV cache to avoid allocation locks.

`MODEL_DIR` is derived from `MODEL_REPO` by replacing `/` with `__`. omlx auto-discovers all subdirectories under `OMLX_MODEL_DIR`.

### Available Models on omlx

omlx auto-discovers any model dropped under `models/`. Catalog of known models (the **On disk** column reflects state after the 2026-06-28 M5 cleanup):

| Model dir                                           | Quantization | Size   | Context | On disk | Notes |
|-----------------------------------------------------|--------------|--------|---------|---------|-------|
| `mlx-community__Qwen3.6-35B-A3B-nvfp4`              | NVFP4        | ~19 GB | 256k    | M2 Pro  | **Fastest on M5** (39.74 tok/s @ 512); M2 Pro (now on omlx): 45.36 tok/s (no HW advantage). Removed from M5 2026-06-28 |
| `mlx-community__Qwen3.6-35B-A3B-4bit-DWQ`           | DWQ-4bit     | ~19 GB | 256k    | M2 Pro  | M2 Pro: 45.36 tok/s; on M5: 31.33 tok/s (slower than NVFP4). Removed from M5 2026-06-28 |
| `mlx-community__Qwen3.6-35B-A3B-4bit`               | std 4bit     | ~19 GB | 256k    | M2 Pro  | M2 Pro: **45.89 tok/s** (marginally fastest on M2 Pro). Removed from M5 2026-06-28 |
| `mlx-community__gemma-4-26b-a4b-it-nvfp4`           | NVFP4        | ~15 GB | 256k    | —       | Non-QAT Gemma 4; removed from M5 2026-06-28 |
| `mlx-community__gemma-4-26B-A4B-it-qat-nvfp4`       | QAT NVFP4    | ~15 GB | 256k    | **M5**  | **M5's main (chat/VLM) model.** Gemma 4 VLM; runs on omlx (M5 default) and vllm-mlx 0.3.0+ (~30 tok/s @ 512/1024); QAT = better quality at 4-bit. Crashed on vllm-mlx 0.2.9 |
| `mlx-community__Qwen3-Embedding-0.6B-4bit-DWQ`     | DWQ-4bit     | ~0.34 GB | —     | **M5**  | **Embedding model** (1024-dim, multilingual). Added 2026-06-28 for testing `/v1/embeddings`. Cross-lingual sanity check passed (en↔zh cosine ~0.72). |

**Why A3B MoE instead of a dense 27B?** Apple-Silicon decode is memory-bandwidth bound: the active-weight footprint per token determines `tok/s`. Measured on M2 Pro: Qwen3.6-27B dense = 10.6 tok/s, Qwen3.6-35B-A3B = 45.8 tok/s (~4.3× faster, with a larger/stronger model). Anything under ~16 GB of *active* weights is the ceiling for this class of machine.

**256k context**: All Qwen3.x models support 262,144 tokens max context with RoPE scaling. The Gemma 4 QAT model is **also 256k** — `config.json` `text_config.max_position_embeddings=262144` (an earlier note here said 128k; that was wrong). omlx respects model config and automatically loads this context window.

**Embeddings & rerank**: omlx (0.4.x) exposes OpenAI-compatible `/v1/embeddings` and `/v1/rerank` alongside chat. Drop an MLX embedding model under `models/` and `make omlx-restart` (omlx scans the dir at startup, not live). Example:

```bash
make model-download MODEL_REPO=mlx-community/Qwen3-Embedding-0.6B-4bit-DWQ
make omlx-restart
curl -s localhost:8000/v1/embeddings -H 'Content-Type: application/json' \
  -d '{"model":"mlx-community__Qwen3-Embedding-0.6B-4bit-DWQ","input":["你好","world"]}'
```

### Per-machine reference numbers (Qwen3.6-35B-A3B, 512-token gen)

#### omlx (default server)

| Machine      | Bandwidth   | Best quant (omlx) | tok/s | Notes |
|--------------|-------------|-------------------|------:|-------|
| M2 Pro 32 GB | 200 GB/s    | std 4bit (`mlx-community__Qwen3.6-35B-A3B-4bit`) | **45.89** | 2026-05-03; DWQ=45.36, NVFP4=45.36 — all three tied (bandwidth-bound, no FP4 HW) |
| M5 32 GB     | 153.6 GB/s  | **NVFP4** (`mlx-community__Qwen3.6-35B-A3B-nvfp4`) | **39.74 cold / 49.14 warm** | DWQ measured 31.33 cold / 32.11 warm; NVFP4 wins by 1.25–1.53× |

#### vllm-mlx 0.3.0 (alternative, higher raw tok/s)

| Machine      | Bandwidth   | Best quant (vllm-mlx) | tok/s (512) | tok/s (1024 warm) | Notes |
|--------------|-------------|----------------------|------------:|------------------:|-------|
| M2 Pro 32 GB | 200 GB/s    | std 4bit or NVFP4    | **58.13–57.40** | **58.83–58.65** | DWQ only 45–46 tok/s (slow path); +28% vs omlx on non-DWQ |
| M5 32 GB     | 153.6 GB/s  | NVFP4                | **51.09**       | **52.25**       | DWQ not tested; +5–10% vs omlx |

**M2 Pro is ~12–13% faster than M5 under vllm-mlx** — bandwidth gap fully expressed. Under omlx, M5 NVFP4 warm (~49 tok/s) nearly closes the gap due to FP4 HW kernels; vllm-mlx doesn't exploit those.

**DWQ under vllm-mlx is significantly slower than std 4-bit / NVFP4** (~46 vs ~59 tok/s on M2 Pro). vllm-mlx lacks optimized kernels for DWQ's per-group dequant scheme. Under omlx all three formats are equal on M2 Pro (all bandwidth-bound).

The M2 Pro is faster despite being older — bandwidth dominates decode. See `bench-results/` for raw logs.

### Alternative server engine: vllm-mlx (M2 Pro was on vllm-mlx until 2026-06-28)

`vllm-mlx` (PyPI, by waybarrios) is a vLLM-style OpenAI-compatible server with native MLX backend. Tested 2026-05-03 against omlx on both machines, **single-stream**:

**M5, NVFP4:**

| Run | omlx (tok/s) | vllm-mlx 0.2.9 (tok/s) | Δ |
|---|---:|---:|---:|
| 512 cold-warm | 46.29 | **51.09** | +10.4% |
| 1024 cold-warm | 49.74 | **52.25** | +5.0% |
| 1024 warm | 48.67 | **51.73** | +6.3% |

**M2 Pro, all three quants:**

| Quant | omlx (tok/s) | vllm-mlx (tok/s, 1024 warm) | Δ |
|---|---:|---:|---:|
| NVFP4     | 45.36 | **58.65** | +29% |
| std 4-bit | 45.89 | **58.83** | +28% |
| DWQ-4bit  | 45.36 | 46.38     | +2%  |

vllm-mlx wins **5–10% on M5** and **~28% on M2 Pro** for std 4-bit / NVFP4. DWQ gains nothing under vllm-mlx (no optimized kernel). **Gemma 4 26B (`Gemma4ForConditionalGeneration`) crashed on vllm-mlx 0.2.9** (`mlx_vlm` thread/stream bug: `RuntimeError: There is no Stream(gpu, 0) in current thread`; both `--mllm` and auto-detected modes; streaming returned empty completions silently) — **fixed in vllm-mlx 0.3.0**. Re-tested 2026-06-07 on M5 with `mlx-community/gemma-4-26B-A4B-it-qat-nvfp4`: both streaming and non-streaming generate correctly (~30 tok/s @ 512, 29.7 warm @ 1024). 0.3.0 release notes now explicitly list Gemma 3/4 as supported vision models. A non-fatal `Failed to build TextModel from vlm: float division by zero` warning at load falls back to the full VLM path and does not block generation. So:

- **Keep omlx as default.** Operationally simpler (Homebrew service, lean deps), works on every model class including VLMs.
- **Use vllm-mlx selectively** for Qwen-class text LLMs with std 4-bit or NVFP4 when max throughput matters. Gemma 4 26B also runs on **vllm-mlx 0.3.0+** (M5: ~30 tok/s, qat-nvfp4) — but it's slower than Qwen3.6-35B-A3B (~51 tok/s) because Gemma's ~4B-active VLM path is heavier than the 3B-active Qwen MoE; for Gemma, omlx stays comparable and simpler.
- **Avoid DWQ with vllm-mlx** — no speed benefit, negates the vllm-mlx advantage.

Full reports + raw logs: `bench-results/m5-omlx-vs-vllm-mlx-nvfp4-20260503.md`, `bench-results/m2pro-omlx-vs-vllm-mlx-20260503.md`. Trying it:

```bash
uv tool install vllm-mlx                 # installs into ~/.local/share/uv/tools (~2.5 GB; pulls in PyTorch)
make omlx-stop                            # free port 8000
vllm-mlx serve ./models/mlx-community__Qwen3.6-35B-A3B-nvfp4 \
  --served-model-name mlx-community__Qwen3.6-35B-A3B-nvfp4 \
  --host 0.0.0.0 --port 8000 \
  --gpu-memory-utilization 0.90 --cache-memory-mb 4096 \
  --max-num-seqs 2 --use-paged-cache --max-cache-blocks 1024
# bench: uv run mlx-bench mlx-community__Qwen3.6-35B-A3B-nvfp4 --max-tokens 1024 --no-unload
```

omlx flag → vllm-mlx flag map: `--memory-guard aggressive` (was `--max-process-memory 90%` pre-0.4.x) → `--gpu-memory-utilization 0.90`; `--hot-cache-max-size 4GB` → `--cache-memory-mb 4096`; `--max-concurrent-requests 2` → `--max-num-seqs 2`; `--initial-cache-blocks 1024` → `--use-paged-cache --max-cache-blocks 1024`. Use `--no-unload` with `mlx-bench` because vllm-mlx has no per-model unload endpoint.

## Architecture

Two independent layers:

**1. Benchmark CLI** (`src/mlx_learning/benchmark_cli.py`)
The `mlx-bench` Typer command (registered in `pyproject.toml` under `[project.scripts]`). Loads MLX models via `mlx_lm.load`/`mlx_lm.generate` locally and posts to omlx at `http://127.0.0.1:8000/v1/chat/completions` to compare tokens/sec.

**2. omlx multi-model server** (Makefile-driven)
Production-ready OpenAI-compatible server for Apple Silicon. Serves all models found under `models/` with LRU-based memory management. Exposes `/v1/chat/completions`, `/v1/models`, and related endpoints on `:8000`. State tracked via `omlx-server.pid` / `omlx-server.log`.

## Key conventions

- `uv` + Makefile are the canonical workflows; don't introduce ad hoc `pip` flows.
- `src/` layout; new CLIs go in `[project.scripts]`, not as top-level scripts.
- Model directory naming `models/<repo-with-/-replaced-by-__>` — preserve so multiple models coexist under `models/`.
- PID/log files (`omlx-server.pid`, `omlx-server.log`) live at repo root and are gitignored.
- mypy runs `strict` with `ignore_missing_imports = true` (MLX/mlx-lm lack stubs).
- Tests are minimal — only `tests/test_hello.py` covers `mlx_learning.hello.main()`. Benchmark CLI and serving are uncovered.
- Anything that depends on the host (download / serve / bench) must run `scripts/detect_machine.sh` first so logs make sense across machines.

When defaults or commands change, update both this file and `.github/copilot-instructions.md`.
