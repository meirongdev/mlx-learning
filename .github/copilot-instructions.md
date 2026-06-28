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
brew trust jundot/omlx             # newer Homebrew refuses untrusted third-party taps
brew install omlx                  # install
brew update && brew upgrade omlx   # upgrade to latest
brew services start omlx           # run as background service
```

omlx 0.4.x removed `--max-process-memory`; the Makefile now uses `--memory-guard aggressive` (or `--memory-guard-gb N`) in `OMLX_EXTRA_ARGS`.

## Default serving target

`MODEL_REPO` is **per-machine** — the Makefile picks it from `scripts/detect_machine.sh` (M5 → Gemma 4, else → Qwen). Override with `MODEL_REPO=... make <target>`.

- **M2 Pro** → `mlx-community/Qwen3.6-35B-A3B-nvfp4` (MoE, 35B total / 3B active, 256k), served by **vllm-mlx**.
- **M5** → `mlx-community/gemma-4-26B-A4B-it-qat-nvfp4` (Gemma 4 VLM, QAT-NVFP4, 256k), served by **omlx** (switched 2026-06-28). M5's `models/` holds **only** this model — the Qwen dirs + non-QAT Gemma were removed.
- `VLLM_MODEL_REPO` defaults to `$(MODEL_REPO)`.
- `OMLX_HOST=0.0.0.0`, `OMLX_PORT=8000`, `OMLX_MODEL_DIR=models`

The Makefile derives `MODEL_DIR` as `models/<repo-with-/-replaced-by-__>`. omlx auto-discovers all model subdirectories under `OMLX_MODEL_DIR`.

On the M5 box, NVFP4 beat DWQ ~25% for `Qwen3.6-35B-A3B` (39.74 vs 31.33 tok/s @ 512; 2026-05-03, `bench-results/`), likely due to M5's GPU neural accelerators and/or omlx FP4 paths. M5 no longer keeps Qwen (Gemma 4 only as of 2026-06-28); if reintroduced, prefer `mlx-community/Qwen3.6-35B-A3B-nvfp4`.

## Alternative server engine: vllm-mlx

`vllm-mlx` (PyPI, `uv tool install vllm-mlx`) is a vLLM-style OpenAI-compatible MLX server tested on this repo on 2026-05-03 (M5 only — M2 Pro pending). On Qwen3.6-35B-A3B NVFP4, it's **5–10% faster** than omlx at single-stream decode (51–52 vs 48–50 tok/s). **It crashes on Gemma 4 VLM** in 0.2.9 (`mlx_vlm` thread/stream bug). Default remains omlx because it's operationally simpler and works on every model class. Use vllm-mlx selectively for Qwen-class text LLMs when continuous batching, tool/reasoning parsers, KV-cache quantization, or speculative decoding matter. Full bench + flag map: `bench-results/m5-omlx-vs-vllm-mlx-nvfp4-20260503.md`.

## High-level architecture

- **Benchmark CLI** — `src/mlx_learning/benchmark_cli.py` exposes the `mlx-bench` Typer command (registered via `[project.scripts]`). It loads MLX models via `mlx_lm.load`/`mlx_lm.generate` locally and posts to omlx at `http://127.0.0.1:8000/v1/chat/completions` to compare tokens/sec.
- **omlx multi-model server (Makefile-driven)** — production-ready OpenAI-compatible server for Apple Silicon. Serves all models under `models/` with LRU-based memory management. Exposes `/v1/chat/completions`, `/v1/models`, `/v1/embeddings`, `/v1/rerank`, and related endpoints on `:8000`. Scans `models/` at startup (drop a model in, then `make omlx-restart`). State tracked via `omlx-server.pid` / `omlx-server.log`.
- Tests are minimal: `tests/test_hello.py` only covers `mlx_learning.hello.main()`. The benchmark CLI and serving workflow are not covered.

## Key conventions

- `uv` + Makefile are the canonical workflows. Don't reach for ad hoc `pip` commands.
- `src/` layout; new CLIs go in `[project.scripts]` in `pyproject.toml`, not as top-level scripts.
- Model directory naming: `models/<HF_REPO_with_/_replaced_by___>`. Preserve this so multiple models coexist under `models/`.
- PID and log files (`omlx-server.pid`, `omlx-server.log`) live at the repo root and are gitignored.
- Ruff and mypy config live in `pyproject.toml`; mypy is `strict` with `ignore_missing_imports = true` (MLX/mlx-lm lack stubs).

## Other assistant configuration

- `CLAUDE.md` mirrors this file for Claude Code. Keep both in sync when defaults change.
