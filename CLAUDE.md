# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Commands

```bash
# Install
uv sync                          # base deps
uv sync --extra server           # + mlx-lm, mlx-vlm, huggingface_hub  (or: make server-install)

# Test / lint / types
uv run pytest
uv run pytest tests/test_hello.py::test_hello   # single test
uv run ruff check .
uv run ruff format .
uv run mypy .                                    # strict mode

# Benchmark MLX vs Ollama
uv run mlx-bench                                 # or: make bench

# omlx multi-model server
make omlx-start | omlx-stop | omlx-status | omlx-logs
```

`HF_TOKEN` is **optional** — the default model is public. Pass it only for gated/private repos.

## Default serving target

| Var            | Value                                         |
| -------------- | --------------------------------------------- |
| `MODEL_REPO`   | `mlx-community/Qwen3.6-35B-A3B-nvfp4` (MoE, 256k ctx) |
| `MODEL_DIR`    | `models/mlx-community__Qwen3.6-35B-A3B-nvfp4/` |
| `OMLX_HOST`    | `0.0.0.0`                                     |
| `OMLX_PORT`    | `8000`                                        |
| `OMLX_MODEL_DIR` | `models`                                    |

`MODEL_DIR` is derived from `MODEL_REPO` by replacing `/` with `__`. omlx auto-discovers all subdirectories under `OMLX_MODEL_DIR`.

### Available Models on omlx

| Model | Quantization | Context | Status |
|-------|-------------|---------|--------|
| Qwen3.6-35B-A3B-nvfp4 | nvfp4 | 256k (262k tokens) | ✅ Default |
| Qwen3.5-35B-A3B-4bit | 4bit | 256k (262k tokens) | ✅ Available |
| gemma-4-26b-a4b-it-nvfp4 | nvfp4 | - | ✅ Available |
| gemma-4-26b-a4b-it-4bit | 4bit | - | ✅ Available |

**Qwen3.6 (256k context)**: All Qwen3.x models support 262,144 tokens max context with RoPE scaling. omlx respects model config and automatically loads this context window.

## Architecture

Two independent layers:

**1. Benchmark CLI** (`src/mlx_learning/benchmark_cli.py`)
The `mlx-bench` Typer command (registered in `pyproject.toml` under `[project.scripts]`). Loads MLX models via `mlx_lm.load`/`mlx_lm.generate` locally and posts to Ollama at `http://localhost:11434/api/generate` to compare tokens/sec.

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
