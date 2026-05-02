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

# omlx multi-model server
make omlx-start | omlx-stop | omlx-status | omlx-logs
```

`HF_TOKEN` is **optional** — the default model is public. Pass it only for gated/private repos.

## Default serving target

| Var            | Value                                                              |
| -------------- | ------------------------------------------------------------------ |
| `MODEL_REPO`   | `mlx-community/Qwen3.6-35B-A3B-4bit-DWQ` (MoE, 3B active, 256k ctx) |
| `MODEL_DIR`    | `models/mlx-community__Qwen3.6-35B-A3B-4bit-DWQ/`                  |
| `OMLX_HOST`    | `0.0.0.0`                                                          |
| `OMLX_PORT`    | `8000`                                                             |
| `OMLX_MODEL_DIR` | `models`                                                         |

### Quantization on this hardware — empirical, not theoretical

Published MLX guidance (early 2026): DWQ-4bit > standard 4bit > NVFP4 / MXFP4, because FP4 formats fall back to FP16 on MLX and lose the bandwidth win.

**On the M5 box** that does NOT hold. Three runs on 2026-05-03 (omlx, Qwen3.6-35B-A3B):

| Run                      | NVFP4 tok/s | DWQ tok/s |
|--------------------------|------------:|----------:|
| Cold, 512 tokens         | 39.74       | 31.33     |
| Cold-ish, 1024 tokens    | 36.47       | 29.23     |
| Warm, 1024 tokens        | **49.14**   | 32.11     |

NVFP4 is 1.25–1.53× faster on M5 — gap widens with warm state. Warm NVFP4 (~49 tok/s) actually beats the historical M2 Pro 4-bit ceiling (45.8 tok/s). Likely cause: M5's GPU neural accelerators (announced Oct 2025) and/or omlx-specific FP4 kernels. So:
- **M5**: prefer `mlx-community/Qwen3.6-35B-A3B-nvfp4` for tok/s. Repo default `MODEL_REPO=...4bit-DWQ` is conservative; override it on M5.
- **M2 Pro**: not yet re-measured; conventional wisdom (DWQ > NVFP4) likely still holds. Re-test before changing the M2 Pro setup.
- Raw logs in [`bench-results/`](./bench-results/).

### Performance Optimization (M-series)

The following optimizations are enabled for `omlx` to maximize throughput for `Qwen3.6-35B-A3B-4bit-DWQ`:

- **System-level**: Run `make optimize-system` to raise `iogpu.wired_limit_mb` (current default: `30000`; M5 32 GB box is currently set to `26000`).
- **omlx flags** (in `Makefile` under `OMLX_EXTRA_ARGS`):
  - `--max-process-memory 90%`: Cap process to leave headroom for the GUI.
  - `--hot-cache-max-size 4GB`: Prefix caching for near-zero latency on repeating prompts.
  - `--max-concurrent-requests 2`: Reduces memory fragmentation.
  - `--initial-cache-blocks 1024`: Pre-allocates KV cache to avoid allocation locks.

`MODEL_DIR` is derived from `MODEL_REPO` by replacing `/` with `__`. omlx auto-discovers all subdirectories under `OMLX_MODEL_DIR`.

### Available Models on omlx

omlx auto-discovers any model dropped under `models/`. Currently on disk (M5 box):

| Model dir                                           | Quantization | Size   | Context | Notes |
|-----------------------------------------------------|--------------|--------|---------|-------|
| `mlx-community__Qwen3.6-35B-A3B-nvfp4`              | NVFP4        | ~19 GB | 256k    | **Fastest on M5** (39.74 tok/s @ 512); pick this on M5 |
| `mlx-community__Qwen3.6-35B-A3B-4bit-DWQ`           | DWQ-4bit     | ~19 GB | 256k    | Repo default; better perplexity in theory; on M5 it measured 31.33 tok/s (slower than NVFP4) |
| `mlx-community__gemma-4-26b-a4b-it-nvfp4`           | NVFP4        | ~15 GB | 128k    | Smaller alt; not benchmarked here |

**Why A3B MoE instead of a dense 27B?** Apple-Silicon decode is memory-bandwidth bound: the active-weight footprint per token determines `tok/s`. Measured on M2 Pro: Qwen3.6-27B dense = 10.6 tok/s, Qwen3.6-35B-A3B = 45.8 tok/s (~4.3× faster, with a larger/stronger model). Anything under ~16 GB of *active* weights is the ceiling for this class of machine.

**Qwen3.6 (256k context)**: All Qwen3.x models support 262,144 tokens max context with RoPE scaling. omlx respects model config and automatically loads this context window.

### Per-machine reference numbers (Qwen3.6-35B-A3B, 512-token gen)

| Machine      | Bandwidth   | Best 4-bit so far | tok/s | Notes |
|--------------|-------------|-------------------|------:|-------|
| M2 Pro 32 GB | 200 GB/s    | std 4bit (`mlx-community__Qwen3.6-35B-A3B-4bit`) | ~45.8 | Historical; DWQ/NVFP4 not yet re-tested |
| M5 32 GB     | 153.6 GB/s  | **NVFP4** (`mlx-community__Qwen3.6-35B-A3B-nvfp4`) | **39.74 cold / 49.14 warm** | DWQ measured 31.33 cold / 32.11 warm; NVFP4 wins by 1.25–1.53× |

The M2 Pro is faster despite being older — bandwidth dominates decode. See `OPTIMIZATION.md` and `bench-results/` for raw logs.

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
