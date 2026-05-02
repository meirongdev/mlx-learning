# Qwen Code Context — MLX Learning & Benchmark

## Project Overview

A toolkit for benchmarking and serving MLX-based LLMs on Apple Silicon, served via the [omlx](https://github.com/omlx/omlx) multi-model OpenAI-compatible server. The primary use case is comparing generation speed between local MLX inference and omlx on the same machine.

**Stack:** Python 3.11+ — `mlx`, `mlx-lm`, `mlx-vlm`, `typer`, `rich`, `openai` — served via `omlx` (installed via brew).

**Default model:** `mlx-community/Qwen3.6-35B-A3B-4bit-DWQ` (MoE, 35B total / 3B active, DWQ-4bit, 256k context). DWQ is the published-best 4-bit MLX quant. **However on the M5 box** NVFP4 measured ~25% faster (39.74 vs 31.33 tok/s @ 512, see `bench-results/`) — likely M5's GPU neural accelerators or omlx-specific FP4 paths. Override `MODEL_REPO=mlx-community/Qwen3.6-35B-A3B-nvfp4` on M5 when tok/s matters. M2 Pro has not yet been re-measured.

## Hosts

This repo runs on two Macs (both 32 GB unified memory):

| Machine    | Chip            | Bandwidth   |
|------------|-----------------|-------------|
| M2 Pro MBP | Apple M2 Pro    | 200 GB/s    |
| M5 MBP 14" | Apple M5 (base) | 153.6 GB/s  |

Run `make detect-machine` (or `bash scripts/detect_machine.sh`) before any download/serve/benchmark — outputs chip, RAM, bandwidth, and the GPU wired-memory limit.

## Architecture

Two independent layers:

1. **Benchmark CLI** (`src/mlx_learning/benchmark_cli.py`) — registered as `mlx-bench`. Loads MLX models via `mlx_lm.load`/`mlx_lm.generate` locally and posts to omlx (`localhost:8000`) to compare tokens/sec.

2. **omlx multi-model server** (Makefile-driven) — serves all models auto-discovered under `models/`. Exposes `/v1/chat/completions`, `/v1/models`, and related OpenAI-compatible endpoints. State tracked via `omlx-server.pid` / `omlx-server.log` (gitignored).

## Building and Running

### Prerequisites

- macOS on Apple Silicon (M1/M2/M3/M4) — MLX does not support Intel Macs
- `uv` (for Python environment management) — auto-installed by `make quickstart`
- `omlx` — install via Homebrew tap:
  ```bash
  brew tap jundot/omlx https://github.com/jundot/omlx
  brew install omlx
  # Upgrade: brew update && brew upgrade omlx
  # Run as service: brew services start omlx
  ```
- `HF_TOKEN` env var (optional — the default Qwen model is public)

### Quickstart (one command)

```bash
make quickstart                  # scripts/bootstrap.sh: platform check -> uv -> deps -> model -> omlx -> health check
make quickstart PORT=8080                                         # PORT/HOST/MODEL_REPO overridable
```

Idempotent — safe to re-run. `SKIP_SERVER=1` halts after the model download.

### Development commands

```bash
uv sync                          # install base deps
uv sync --extra server           # + huggingface_hub, mlx-vlm (for serving)
uv run pytest                    # run tests
uv run ruff check .              # lint
uv run ruff format .             # format
uv run mypy .                    # type check (strict mode)
uv run mlx-bench                 # benchmark MLX vs omlx
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
- **Model naming** — `models/<repo-with-/-replaced-by-__>` (e.g., `models/mlx-community__Qwen3.6-35B-A3B-4bit-DWQ/`). Preserves multi-model coexistence.
- **mypy strict** with `ignore_missing_imports = true` (MLX/mlx-lm lack type stubs).
- **Tests are minimal** — only `tests/test_hello.py` covers `mlx_learning.hello.main()`.
- **PID/log files** (`omlx-server.pid`, `omlx-server.log`) live at repo root and are gitignored.

## Key Files

| File | Purpose |
|------|---------|
| `pyproject.toml` | Project metadata, deps, entry points, tool configs (ruff, mypy, pytest) |
| `Makefile` | Full lifecycle: quickstart, install, download, server, proxy, omlx, bench |
| `scripts/bootstrap.sh` | Idempotent one-click setup driven by `make quickstart` |
| `src/mlx_learning/benchmark_cli.py` | `mlx-bench` Typer CLI with `test_mlx`, `test_omlx`, `benchmark` |
| `scripts/openai_proxy.py` | OpenAI-compatible proxy forwarding to a local MLX server |
| `scripts/verify_model.py` | Local `config.json` inspector for downloaded models |
| `models/` | Downloaded model snapshots (gitignored) |
