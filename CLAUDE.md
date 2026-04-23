# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

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

| Var            | Value                                         |
| -------------- | --------------------------------------------- |
| `MODEL_REPO`   | `mlx-community/Qwen3.6-35B-A3B-4bit` (MoE, 3B active, 256k ctx) |
| `MODEL_DIR`    | `models/mlx-community__Qwen3.6-35B-A3B-4bit/` |
| `OMLX_HOST`    | `0.0.0.0`                                     |
| `OMLX_PORT`    | `8000`                                        |
| `OMLX_MODEL_DIR` | `models`                                    |

### Performance Optimization (M-series)

The following optimizations are enabled for `omlx` to maximize throughput for `Qwen3.6-35B-A3B-4bit`:

- **System-level**: Run `make optimize-system` to set `iogpu.wired_limit_mb=26000`.
- **omlx flags**:
  - `--hot-cache-max-size 4GB`: Prefix caching for near-zero latency on repeating prompts.
  - `--max-concurrent-requests 2`: Reduces memory fragmentation.
  - `--initial-cache-blocks 1024`: Pre-allocates KV cache to avoid allocation locks.

`MODEL_DIR` is derived from `MODEL_REPO` by replacing `/` with `__`. omlx auto-discovers all subdirectories under `OMLX_MODEL_DIR`.

### Available Models on omlx

Only the default model is installed. omlx auto-discovers any additional model dropped into `models/`.

| Model | Quantization | Size on disk | Context | Notes |
|-------|-------------|--------------|---------|--------|
| Qwen3.6-35B-A3B-4bit | 4bit | 19 GB | 256k (262k tokens) | Default — MoE, 3B active per token, ~46 tok/s on M2 Pro 200GB/s (512-token gen, measured) |

**Why A3B MoE instead of a dense 27B?** Apple-Silicon decode is memory-bandwidth bound: the active-weight footprint per token determines `tok/s`. Measured on M2 Pro: Qwen3.6-27B dense = 10.6 tok/s, Qwen3.6-35B-A3B = 45.8 tok/s (~4.3× faster, with a larger/stronger model). Anything under ~16 GB of *active* weights is the ceiling for this class of machine.

**Qwen3.6 (256k context)**: All Qwen3.x models support 262,144 tokens max context with RoPE scaling. omlx respects model config and automatically loads this context window.

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

When defaults or commands change, update both this file and `.github/copilot-instructions.md`.
