# Qwen Code Context — MLX Learning & Benchmark

## Project Overview

A toolkit for benchmarking and serving MLX-based LLMs on Apple Silicon, served via the [omlx](https://github.com/omlx/omlx) multi-model OpenAI-compatible server. The primary use case is comparing generation speed between local MLX inference, Ollama, and omlx — all on the same machine.

**Stack:** Python 3.11+ — `mlx`, `mlx-lm`, `mlx-vlm`, `typer`, `rich`, `openai` — served via `omlx` (installed via brew).

**Default model:** `mlx-community/Qwen3.5-35B-A3B-4bit` (MoE, 35B total / 3B active params, 4-bit quantized — fits on 32 GB Mac).

## Architecture

Two independent layers:

1. **Benchmark CLI** (`src/mlx_learning/benchmark_cli.py`) — registered as `mlx-bench`. Loads MLX models via `mlx_lm.load`/`mlx_lm.generate` locally, posts to Ollama (`localhost:11434`) and omlx (`localhost:8000`) to compare tokens/sec side by side.

2. **omlx multi-model server** (Makefile-driven) — serves all models auto-discovered under `models/`. Exposes `/v1/chat/completions`, `/v1/models`, and related OpenAI-compatible endpoints. State tracked via `omlx-server.pid` / `omlx-server.log` (gitignored).

## Building and Running

### Prerequisites

- `uv` (for Python environment management)
- `omlx` (via `brew install omlx`)
- `HF_TOKEN` env var (optional — the default Qwen model is public)

### Development commands

```bash
uv sync                          # install base deps
uv sync --extra server           # + huggingface_hub, mlx-vlm (for serving)
uv run pytest                    # run tests
uv run ruff check .              # lint
uv run ruff format .             # format
uv run mypy .                    # type check (strict mode)
uv run mlx-bench                 # benchmark MLX vs Ollama vs omlx
```

### Serving with omlx

```bash
make server-install              # install server deps (mlx-lm, mlx-vlm, hf_hub)
make model-download              # download default model into models/
make omlx-start                  # start omlx on 0.0.0.0:8000
make omlx-status                 # check server PID, port, model info
make omlx-logs                   # tail the log
make omlx-stop                   # stop the server
```

Switch models: `make model-download MODEL_REPO=mlx-community/Qwen3-30B-A3B-4bit`

### Serve with mlx-lm directly (legacy)

```bash
make server-start                # starts mlx_lm.server on HOST:PORT (default :5001)
make server-stop
make server-status
make server-logs
make proxy-start                 # OpenAI-compat proxy shim on :5101 -> MLX server
make proxy-stop
```

## Development Conventions

- **uv + Makefile** are the canonical workflows. Do not introduce ad hoc `pip` flows.
- **src/ layout** — new CLIs go in `[project.scripts]` via `pyproject.toml`, not as top-level scripts.
- **Model naming** — `models/<repo-with-/-replaced-by-__>` (e.g., `models/mlx-community__Qwen3.5-35B-A3B-4bit/`). Preserves multi-model coexistence.
- **mypy strict** with `ignore_missing_imports = true` (MLX/mlx-lm lack type stubs).
- **Tests are minimal** — only `tests/test_hello.py` covers `mlx_learning.hello.main()`.
- **PID/log files** (`omlx-server.pid`, `omlx-server.log`) live at repo root and are gitignored.

## Key Files

| File | Purpose |
|------|---------|
| `pyproject.toml` | Project metadata, deps, entry points, tool configs (ruff, mypy, pytest) |
| `Makefile` | Full lifecycle: install, download, server, proxy, omlx, bench |
| `src/mlx_learning/benchmark_cli.py` | `mlx-bench` Typer CLI with `test_mlx`, `test_ollama`, `test_omlx`, `benchmark` |
| `scripts/openai_proxy.py` | OpenAI-compatible proxy forwarding to a local MLX server |
| `scripts/verify_model.py` | Local `config.json` inspector for downloaded models |
| `models/` | Downloaded model snapshots (gitignored) |
