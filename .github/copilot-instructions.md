# Copilot instructions for mlx-learning

## Build, test, lint, and runtime commands

- `make quickstart` — one-click setup on a fresh Apple Silicon Mac: verifies platform, installs `uv` if missing, `uv sync --extra server`, downloads `MODEL_REPO`, starts `mlx_lm.server`, health-checks `/v1/models`. Idempotent — re-run freely. See `scripts/bootstrap.sh`.
- `uv sync` (or `make install`) — install base deps.
- `uv sync --extra server` (or `make server-install`) — install serving deps (`mlx-lm`, `mlx-vlm`, `huggingface_hub`).
- `uv build` — build distributables.
- `uv run pytest` (or `make test`) — full test suite.
- `uv run pytest tests/test_hello.py::test_hello` — single test.
- `uv run ruff check .` (or `make lint`) — lint.
- `uv run ruff format .` (or `make format`) — format.
- `uv run mypy .` — strict type check.
- `uv run mlx-bench` (or `make bench`) — benchmark MLX vs omlx.
- `make model-download` — download `MODEL_REPO` into `MODEL_DIR`. `HF_TOKEN` is **optional** (most `mlx-community/*` repos are public); pass it only for gated/private repos.
- `make omlx-install` — check/install omlx (Homebrew tap `jundot/omlx`).
- `make omlx-start` / `omlx-stop` / `omlx-restart` / `omlx-status` / `omlx-logs` — omlx server lifecycle.
- `make detect-machine` — print chip/RAM/bandwidth. Repo is shared between an M2 Pro and an M5 (both 32 GB); host-dependent steps (`model-download`, `omlx-start`, `bench`, `bootstrap.sh`) call this first.

### omlx (Homebrew tap)

```bash
brew tap jundot/omlx https://github.com/jundot/omlx
brew install omlx                  # install
brew update && brew upgrade omlx   # upgrade to latest
brew services start omlx           # run as background service
```

## Default serving target

- `MODEL_REPO=mlx-community/Qwen3.6-35B-A3B-4bit-DWQ` (MoE, 35B total / 3B active per token, DWQ-4bit, 256k context).
- `OMLX_HOST=0.0.0.0`, `OMLX_PORT=8000`
- `OMLX_MODEL_DIR=models`

The Makefile derives `MODEL_DIR` as `models/<repo-with-/-replaced-by-__>`. omlx auto-discovers all model subdirectories under `OMLX_MODEL_DIR`.

DWQ ("Dynamic Weight Quantization") is the published-best 4-bit MLX quant as of early 2026. **However, on the M5 box** an empirical run (2026-05-03, `bench-results/`) shows NVFP4 ~25% faster than DWQ for `Qwen3.6-35B-A3B` (39.74 vs 31.33 tok/s @ 512), likely due to M5's GPU neural accelerators and/or omlx-specific FP4 paths. Treat the DWQ default as "the safe fallback" and override to `mlx-community/Qwen3.6-35B-A3B-nvfp4` when running on M5 if tok/s matters. The M2 Pro box has not been re-measured; conventional guidance (DWQ > NVFP4) likely still applies there.

## High-level architecture

- **Benchmark CLI** — `src/mlx_learning/benchmark_cli.py` exposes the `mlx-bench` Typer command (registered via `[project.scripts]`). It loads MLX models via `mlx_lm.load`/`mlx_lm.generate` locally and posts to omlx at `http://127.0.0.1:8000/v1/chat/completions` to compare tokens/sec.
- **omlx multi-model server (Makefile-driven)** — production-ready OpenAI-compatible server for Apple Silicon. Serves all models under `models/` with LRU-based memory management. Exposes `/v1/chat/completions`, `/v1/models`, and related endpoints on `:8000`. State tracked via `omlx-server.pid` / `omlx-server.log`.
- Tests are minimal: `tests/test_hello.py` only covers `mlx_learning.hello.main()`. The benchmark CLI and serving workflow are not covered.

## Key conventions

- `uv` + Makefile are the canonical workflows. Don't reach for ad hoc `pip` commands.
- `src/` layout; new CLIs go in `[project.scripts]` in `pyproject.toml`, not as top-level scripts.
- Model directory naming: `models/<HF_REPO_with_/_replaced_by___>`. Preserve this so multiple models coexist under `models/`.
- PID and log files (`omlx-server.pid`, `omlx-server.log`) live at the repo root and are gitignored.
- Ruff and mypy config live in `pyproject.toml`; mypy is `strict` with `ignore_missing_imports = true` (MLX/mlx-lm lack stubs).

## Other assistant configuration

- `CLAUDE.md` mirrors this file for Claude Code. Keep both in sync when defaults change.
