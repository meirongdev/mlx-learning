# Copilot instructions for mlx-learning

## Build, test, lint, and runtime commands

- `make quickstart` — one-click setup on a fresh Apple Silicon Mac: verifies platform, installs `uv` if missing, `uv sync --extra server`, downloads `MODEL_REPO` (machine-aware default), installs and starts **omlx**, health-checks `/v1/models`. Idempotent — re-run freely. See `scripts/bootstrap.sh`.
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
make omlx-restart                  # REQUIRED after upgrade (see below)
brew services start omlx           # run as background service
```

omlx 0.4.x removed `--max-process-memory`; the Makefile now uses `--memory-guard aggressive` (or `--memory-guard-gb N`) in `OMLX_EXTRA_ARGS`. Current version on the M2 Pro: **0.5.4rc1**.

> ⚠️ **`brew upgrade omlx` does not restart the running server.** It removes the old Cellar directory while the LaunchAgent keeps serving from the missing path, so endpoints whose deps only exist in the new build start returning 500 and tracebacks reference a version that is gone (no source lines). On 2026-08-01 a stale 0.4.4 process broke `/v1/embeddings` and both `/v1/audio/*` endpoints while 0.5.4rc1 sat installed and unused. Always `make omlx-restart` after upgrading and verify `ps -axo pid,etime,comm | grep omlx-server` shows a fresh `etime`. The `mlx_audio` / `mlx_embeddings` deps ship **inside the Homebrew build** — never `pip install` them to "fix" a 500.

## Default serving target

`MODEL_REPO` is **per-machine** — the Makefile picks it from `scripts/detect_machine.sh` (M5 → Gemma 4, else → Qwen). Override with `MODEL_REPO=... make <target>`.

- **M2 Pro** → `mlx-community/Qwen3.6-35B-A3B-nvfp4` (MoE, 35B total / 3B active, 256k), served by **omlx** (switched from vllm-mlx 2026-06-28). **57.9 tok/s warm** on omlx 0.5.4rc1. Its `models/` also holds an embedding (`Qwen3-Embedding-4B-4bit-DWQ`), reranker (`Qwen3-Reranker-0.6B-4bit`), ASR (`Qwen3-ASR-1.7B-8bit`) and TTS (`Qwen3-TTS-12Hz-1.7B-CustomVoice-8bit`) model. **`/v1/rerank` needs a real reranker** — an embedding model returns HTTP 400.
- **M5** → `mlx-community/gemma-4-26B-A4B-it-qat-nvfp4` (Gemma 4 VLM, QAT-NVFP4, 256k), served by **omlx** (switched 2026-06-28). M5's `models/` holds **only** this model — the Qwen dirs + non-QAT Gemma were removed.
- `VLLM_MODEL_REPO` defaults to `$(MODEL_REPO)`.
- `OMLX_HOST=0.0.0.0`, `OMLX_PORT=8000`, `OMLX_MODEL_DIR=models`

The Makefile derives `MODEL_DIR` as `models/<repo-with-/-replaced-by-__>`. omlx auto-discovers all model subdirectories under `OMLX_MODEL_DIR`.

**No parallel or speculative decoding pays off on these MoE models — measured three ways on 2026-08-01, do not enable any of them.** DFlash on Qwen3.6-35B-A3B: −19% (4-bit draft) to −29% (bf16). Google's own MTP assistant on Gemma 4 26B-A4B via `vlm_mtp`: −12% (38.9 vs 44.3 tok/s). DiffusionGemma's block-parallel denoising: −68% (14.3 vs 44.3). **Principle: on a sparse MoE, processing N positions in one forward pass activates the union of experts across those N positions, so the weight read grows with N instead of staying at the per-token active set** — "speculation beats bandwidth limits" is a dense-model rule and inverts here. See `CLAUDE.md` for the table.

**`google/diffusiongemma-26B-A4B-it` is not a newer Gemma 4** — it is a separate discrete-diffusion model built on the same architecture (`model_type: diffusion_gemma`). There is no newer Gemma 4 26B-A4B release and no Gemma 5; the deployed `qat-nvfp4` is already on Google's QAT track, and remaining variants are requantizations of the same weights.

Set `model.hide_helper_models: true` in `~/.omlx/settings.json` (omlx defaults to `false`) before adding any drafter checkpoint — otherwise it is discovered as `type: llm` and listed in `/v1/models` as a selectable chat model.

On the M5 box, NVFP4 beat DWQ ~25% for `Qwen3.6-35B-A3B` (39.74 vs 31.33 tok/s @ 512; 2026-05-03, `bench-results/`), likely due to M5's GPU neural accelerators and/or omlx FP4 paths. M5 no longer keeps Qwen (Gemma 4 only as of 2026-06-28); if reintroduced, prefer `mlx-community/Qwen3.6-35B-A3B-nvfp4`.

## Alternative server engine: vllm-mlx

`vllm-mlx` (PyPI, `uv tool install vllm-mlx`) is a vLLM-style OpenAI-compatible MLX server. Against omlx **0.4.x** it was 5–10% faster on M5 and ~28% faster on M2 Pro (58.8 vs 45.9 tok/s). **That gap is gone on the M2 Pro as of 2026-08-01**: omlx 0.5.4rc1 decodes at **57.9 tok/s**, i.e. parity — so there is no longer a throughput reason to switch. It also crashed on Gemma 4 VLM in 0.2.9 (fixed in 0.3.0). Default remains **omlx**: operationally simpler, works on every model class, now equally fast. Full bench + flag map: `bench-results/m5-omlx-vs-vllm-mlx-nvfp4-20260503.md`, `bench-results/m2pro-omlx-vs-vllm-mlx-20260503.md`.

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
