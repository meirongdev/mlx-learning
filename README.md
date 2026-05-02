# MLX Learning & Benchmark

Tools and scripts for running and benchmarking [MLX](https://github.com/ml-explore/mlx) models on Apple Silicon. Models are served by [`mlx_lm.server`](https://github.com/ml-explore/mlx-lm) — a production-ready OpenAI-compatible server included with mlx-lm.

The default model is **`mlx-community/Qwen3.6-35B-A3B-4bit-DWQ`** (MoE, 35B total / 3B active per token, DWQ-4bit quantized, 256k context). DWQ ("Dynamic Weight Quantization") is currently the strongest 4-bit MLX quant — it beats both standard MLX-4bit and FP4 variants (NVFP4 / MXFP4 fall back to FP16 on MLX).

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
4. Downloads `MODEL_REPO` into `models/` (skipped if already complete)
5. Starts `mlx_lm.server` on `0.0.0.0:5001`
6. Health-checks `GET /v1/models`

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

## Serving models with mlx_lm.server

`mlx_lm.server` is bundled with mlx-lm (no additional install needed). Download a model first, then start the server:

```bash
# Install the optional serving deps (mlx-lm, mlx-vlm, huggingface_hub)
make server-install

# Download the default model (~19 GB, 4-bit MoE) into models/
make model-download

# Start the server (listens on 0.0.0.0:5001)
make server-start

# Inspect / tail / stop
make server-status
make server-logs
make server-stop
```

The model lands in `models/mlx-community__Qwen3.6-35B-A3B-4bit-DWQ/` (slashes replaced with `__`).

### Switching to another model

Stop the server and restart with a different model:

```bash
make server-stop
make server-bootstrap MODEL_REPO=mlx-community/Qwen3-30B-A3B-4bit
```

### Smoke test

```bash
curl -s http://localhost:5001/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{"model": "models/mlx-community__Qwen3.6-35B-A3B-4bit-DWQ",
       "messages": [{"role": "user", "content": "Hi"}],
       "max_tokens": 32}' | jq .
```

Streaming:

```bash
curl -s http://localhost:5001/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{"model": "models/mlx-community__Qwen3.6-35B-A3B-4bit-DWQ",
       "messages": [{"role": "user", "content": "Hi"}],
       "stream": true}'
```

## Benchmark CLI (`mlx-bench`)

Compares generation speed of MLX vs omlx side by side.

```bash
uv run mlx-bench
uv run mlx-bench --prompt "Explain black holes" --max-tokens 256 --verbose
```

Options: `--mlx-model`, `--omlx-model`, `--prompt`, `--max-tokens`, `--verbose`.

### Reference numbers

See `OPTIMIZATION.md` for the full per-machine table. Reproduce on whichever box you're on:

```bash
make detect-machine          # always start here
make omlx-start              # fire up omlx
uv run mlx-bench mlx-community__Qwen3.6-35B-A3B-4bit-DWQ \
                 mlx-community__Qwen3.6-35B-A3B-nvfp4
```

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
- `Makefile` — install, download, omlx server lifecycle
- `models/` — downloaded model snapshots (gitignored)

## Process / log files

The Makefile tracks the running daemon via PID + log files in the repo root (all gitignored):

- `omlx-server.pid`, `omlx-server.log` — the omlx model server

## Serving with omlx (multi-model server)

[omlx](https://github.com/jundot/omlx) is a multi-model OpenAI-compatible server that auto-discovers all models under `models/`.

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
make omlx-status                 # check PID, port, model info
make omlx-logs                   # tail the log
make omlx-stop                   # stop the server
```

Endpoint: `http://127.0.0.1:8000/v1`
