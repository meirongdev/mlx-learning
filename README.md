# MLX Learning & Benchmark

Tools and scripts for running and benchmarking [MLX](https://github.com/ml-explore/mlx) models on Apple Silicon. Models are served by [omlx](https://github.com/jundot/omlx) — a multi-model OpenAI-compatible server that auto-discovers models.

The default model is **machine-dependent** (detected via `scripts/detect_machine.sh`):

| Machine     | Default model | Quantization | Notes |
|-------------|--------------|--------------|-------|
| M5 MBP      | `mlx-community/gemma-4-26B-A4B-it-qat-nvfp4` | QAT NVFP4 | Default chat/VLM on M5 |
| M2 Pro MBP  | `mlx-community/Qwen3.6-35B-A3B-nvfp4` | NVFP4 | MoE, 35B total / 3B active |

Quantization performance is machine-dependent: on M2 Pro all formats (4bit / DWQ / NVFP4) score identically (~45–46 tok/s, bandwidth-bound); on M5, NVFP4 is **1.25–1.53× faster** thanks to native FP4 GPU accelerators.

## Multi-machine setup

This repo is shared between two dev boxes (both 32 GB):

| Machine        | Chip            | Memory bandwidth |
| -------------- | --------------- | ---------------- |
| M2 Pro MBP     | Apple M2 Pro    | 200 GB/s         |
| M5 MBP 14"     | Apple M5 (base) | 153.6 GB/s       |

Decode tok/s is bandwidth-bound, so the M2 Pro is **faster** for plain decode despite the M5's newer architecture. Identify the host before running anything heavy:

```bash
make detect-machine                          # prints chip / RAM / bandwidth / wired-limit
bash scripts/detect_machine.sh --quiet       # KEY=VALUE lines for `eval`
bash scripts/detect_machine.sh --check=M5    # exit 1 if not running on the expected chip
```

`make model-download`, `make omlx-start`, `make bench`, and `scripts/bootstrap.sh` print this header automatically.

## Quickstart (one command)

On a fresh Apple Silicon Mac:

```bash
git clone <repository-url>
cd mlx-learning
make quickstart
```

`make quickstart` runs `scripts/bootstrap.sh`, which is idempotent and re-runnable:

1. Verifies macOS + Apple Silicon
2. Installs `uv` via the official installer if missing
3. `uv sync --extra server` (mlx-lm, mlx-vlm, huggingface_hub)
4. Downloads `MODEL_REPO` into `models/` (skipped if already complete); model choice is **machine-aware**
5. Installs **omlx** via Homebrew if missing (`brew tap jundot/omlx`)
6. Starts **omlx** on `0.0.0.0:8000`
7. Health-checks `GET /v1/models`

Override defaults inline:

```bash
make quickstart PORT=8080   # PORT/HOST/MODEL_REPO are all overridable
```

Set `SKIP_SERVER=1` to stop after the model download.

## Prerequisites

- macOS on Apple Silicon (M1 / M2 / M3 / M4). MLX does not support Intel Macs.
- Python 3.11+
- [`uv`](https://github.com/astral-sh/uv) — auto-installed by `make quickstart` if missing
- Optional: a Hugging Face token (`HF_TOKEN`) — only needed for gated/private repos. The default Qwen model is public.

## Manual installation

If you prefer to run each step yourself instead of `make quickstart`:

```bash
git clone <repository-url>
cd mlx-learning
uv sync
```

## Serving models with omlx (multi-model server)

[omlx](https://github.com/jundot/omlx) is the default serving engine. It auto-discovers all models under `models/` and exposes OpenAI-compatible endpoints on `:8000`.

### Install

```bash
brew tap jundot/omlx https://github.com/jundot/omlx
brew install omlx
# Upgrade: brew update && brew upgrade omlx
# Run as background service: brew services start omlx
```

### Usage

```bash
make omlx-start                  # start on 0.0.0.0:8000
make omlx-status                 # check PID, port, available models
make omlx-logs                   # tail the log
make omlx-stop                   # stop the server
```

Endpoint: `http://127.0.0.1:8000/v1`

### Switching to another model

omlx auto-discovers any model directory under `models/`. Drop a new model there and restart:

```bash
make model-download MODEL_REPO=mlx-community/Qwen3-30B-A3B-4bit
make omlx-restart
```

The model slug for API requests is the repo name with `/` replaced by `__`:
`mlx-community/Qwen3-30B-A3B-4bit` → `mlx-community__Qwen3-30B-A3B-4bit`

### Embeddings & rerank

omlx 0.4.x exposes `/v1/embeddings` and `/v1/rerank`. Drop an MLX embedding model under `models/` and restart:

```bash
make model-download MODEL_REPO=mlx-community/Qwen3-Embedding-0.6B-4bit-DWQ
make omlx-restart
curl -s localhost:8000/v1/embeddings -H 'Content-Type: application/json' \
  -d '{"model":"mlx-community__Qwen3-Embedding-0.6B-4bit-DWQ","input":["你好","world"]}'
```

### Legacy: mlx_lm.server

The original `mlx_lm.server` (bundled with mlx-lm) is still available on port 5001 for testing:

```bash
make server-start              # start mlx_lm.server on 0.0.0.0:5001
make server-status / logs / stop
```

## Benchmark CLI (`mlx-bench`)

Compares generation speed of MLX vs omlx side by side.

```bash
uv run mlx-bench
uv run mlx-bench --prompt "Explain black holes" --max-tokens 256 --verbose
```

Options: `--mlx-model`, `--omlx-model`, `--prompt`, `--max-tokens`, `--verbose`.

### Reference numbers (Qwen3.6-35B-A3B, warmup + 512 tokens)

| Model | M2 Pro tok/s | M5 tok/s | Notes |
|-------|------------:|----------:|-------|
| `4bit` (std) | **45.89** | — | M2 Pro best; no FP4 HW advantage |
| `4bit-DWQ` | 45.36 | 31.33 | M2 Pro bandwidth-bound; M5 limited by 153.6 GB/s |
| `nvfp4` | 45.36 | 39.74 cold / **49.14** warm | M5 native FP4 accelerators kick in; warm peak beats M2 Pro |

**Why all three tie on M2 Pro:** decode is memory-bandwidth-bound — `tok/s ≈ bandwidth / bytes_per_token`. All formats load the same ~19 GB of 4-bit weights, so the 200 GB/s bus is the ceiling regardless of format. M2 Pro has no native FP4 hardware, so NVFP4 offers no advantage.

**Why M5 NVFP4 can beat M2 Pro:** M5 (Oct 2025) added native FP4 GPU accelerators that skip dequantization entirely, reducing compute overhead enough to offset the narrower bus (153.6 GB/s). The 49 tok/s warm peak requires model weights to be resident in GPU wired memory; cold runs (~36–40 tok/s) are limited by DRAM bandwidth as usual.

Reproduce on whichever box you're on:

```bash
make detect-machine          # always start here
make omlx-start              # fire up omlx
uv run mlx-bench mlx-community__Qwen3.6-35B-A3B-4bit \
                 mlx-community__Qwen3.6-35B-A3B-4bit-DWQ \
                 mlx-community__Qwen3.6-35B-A3B-nvfp4
```

Raw logs in `bench-results/`.

## Development

```bash
uv run pytest                  # tests
uv run pytest tests/test_hello.py::test_hello   # single test
uv run ruff check .            # lint
uv run ruff format .           # format
uv run mypy .                  # type check (strict)
```

## Layout

- `src/mlx_learning/` — Python package; `benchmark_cli.py` exposes the `mlx-bench` Typer CLI
- `scripts/bootstrap.sh` — idempotent one-click setup (driven by `make quickstart`)
- `scripts/verify_model.py` — local `config.json` inspector
- `Makefile` — install, download, server lifecycle (omlx, vllm-mlx, sd.cpp, legacy mlx_lm.server)
- `bin/` — stable-diffusion.cpp server binary (FLUX.2 Klein 4B for text-to-image)
- `models/` — downloaded model snapshots (gitignored)
- `models-sd/` — sd.cpp model files (diffusion, VAE, LLM encoder)

## Process / log files

The Makefile tracks the running daemon via PID + log files in the repo root (all gitignored):

- `omlx-server.pid`, `omlx-server.log` — the omlx model server

Also tracked: `mlx-server.pid/log` (legacy `mlx_lm.server`), `vllm-server.pid/log` (vllm-mlx), `sd-server.pid/log` (sd.cpp).

## AI coding assistant configuration

Point any OpenAI-compatible coding assistant at the local omlx server (`make omlx-start` must be running). The model slug uses `__` instead of `/` in the repo name.

### Codex CLI (`~/.codex/config.toml`)

```toml
model_provider = "omlx"
model = "mlx-community__Qwen3.6-35B-A3B-4bit"

[profiles.omlx]
model_provider = "omlx"
model = "mlx-community__Qwen3.6-35B-A3B-4bit"

[model_providers.omlx]
name = "oMLX"
base_url = "http://127.0.0.1:8000/v1"
wire_api = "responses"
```

### Qwen Code (`~/.qwen/settings.json`)

```json
{
  "security": { "auth": { "selectedType": "openai" } },
  "model": { "name": "mlx-community__Qwen3.6-35B-A3B-4bit" },
  "openaiBaseUrl": "http://127.0.0.1:8000/v1"
}
```

When you switch the default model, update the `model` field in both files. The slug is always `MODEL_REPO` with `/` replaced by `__` (e.g. `mlx-community/Qwen3.6-35B-A3B-4bit` → `mlx-community__Qwen3.6-35B-A3B-4bit`).
