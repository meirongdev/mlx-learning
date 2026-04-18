# MLX Learning & Benchmark

Tools and scripts for running and benchmarking [MLX](https://github.com/ml-explore/mlx) models on Apple Silicon, served via [omlx](https://github.com/omlx/omlx) — a production-ready OpenAI-compatible server for Apple Silicon.

The default model is **`mlx-community/Qwen3.5-35B-A3B-4bit`** (MoE, 35B total / 3B active params, 4-bit quantized — runs on a 32 GB Apple Silicon Mac).

## Prerequisites

- Python 3.11+
- [`uv`](https://github.com/astral-sh/uv)
- [`omlx`](https://github.com/omlx/omlx) (`brew install omlx` or see its docs)
- Optional: [Ollama](https://ollama.com) for the comparison benchmark
- Optional: a Hugging Face token (`HF_TOKEN`) — only needed for gated/private repos. The default Qwen model is public.

## Installation

```bash
git clone <repository-url>
cd mlx-learning
uv sync
```

## Serving models with omlx

omlx auto-discovers models from subdirectories of `models/`. Download a model first, then start the server:

```bash
# Install the optional serving deps (mlx-lm, mlx-vlm, huggingface_hub)
make server-install

# Download the default model (~19 GB) into models/
make model-download

# Start the omlx server (listens on 0.0.0.0:8000)
make omlx-start

# Inspect / tail / stop
make omlx-status
make omlx-logs
make omlx-stop
```

The model lands in `models/mlx-community__Qwen3.5-35B-A3B-4bit/` (slashes replaced with `__`), so multiple models can coexist and omlx serves them all.

### Switching to another model

Download any additional model into `models/` — omlx picks it up automatically:

```bash
make model-download MODEL_REPO=mlx-community/Qwen3-30B-A3B-4bit
```

### Smoke test

```bash
curl -s http://localhost:8000/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{"model": "mlx-community__Qwen3.5-35B-A3B-4bit",
       "messages": [{"role": "user", "content": "Hi"}],
       "max_tokens": 32}' | jq .
```

Streaming:

```bash
curl -s http://localhost:8000/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{"model": "mlx-community__Qwen3.5-35B-A3B-4bit",
       "messages": [{"role": "user", "content": "Hi"}],
       "stream": true}' 
```

## Benchmark CLI (`mlx-bench`)

Compares generation speed of MLX vs Ollama side by side.

```bash
uv run mlx-bench
uv run mlx-bench --prompt "Explain black holes" --max-tokens 256 --verbose
```

Options: `--ollama-model`, `--mlx-model`, `--prompt`, `--max-tokens`, `--verbose`.

### Reference numbers (M2 MacBook Pro, 32 GB)

Qwen 3.5 9B, 4-bit quantization:

| Engine | Model               | Tokens/sec | Relative |
| :----- | :------------------ | ---------: | -------: |
| Ollama | qwen3.5:latest (9B) |      18.58 |    1.00x |
| MLX    | Qwen3.5-9B-MLX-4bit |      28.35 |    1.53x |

Reproduce: `uv run mlx-bench --max-tokens 128`

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
- `scripts/verify_model.py` — local `config.json` inspector
- `Makefile` — install, download, omlx server lifecycle
- `models/` — downloaded model snapshots (gitignored)

## Process / log files

The Makefile tracks the running daemon via PID + log files in the repo root (all gitignored):

- `omlx-server.pid`, `omlx-server.log` — the omlx model server
