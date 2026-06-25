# QWEN.md — mlx-learning Project Context

## What This Is

A toolkit for benchmarking and serving MLX-based LLMs on Apple Silicon. Primary use case: comparing generation speed between local MLX inference and a local inference server on the same machine.

**Host machine:** Apple M5 (base), 32 GB unified memory, 153.6 GB/s bandwidth.

**Default model:** `mlx-community/Qwen3.6-35B-A3B-nvfp4` (MoE, 35B total / 3B active, NVFP4, 256k context). On M5 with omlx: ~49 tok/s warm.

**Active server on M5:** omlx (OpenAI-compatible, port 8000). vllm-mlx also available (shares port 8000 — stop one before starting the other).

## Architecture

| Layer | What | How |
|-------|------|-----|
| **Benchmark CLI** | `mlx-bench` — compares MLX vs server tok/s | `src/mlx_learning/benchmark_cli.py`, registered as `[project.scripts]` entry point |
| **Inference server** | OpenAI-compatible on `:8000` | omlx (`omlx serve`) or vllm-mlx (`vllm-mlx serve`), managed via Makefile targets |
| **Proxy** | OpenAI-compat shim → local MLX server | `scripts/openai_proxy.py` (port 5101) |
| **Bootstrap** | Idempotent one-click setup | `scripts/bootstrap.sh` (driven by `make quickstart`) |
| **Machine detect** | Identifies chip/RAM/bandwidth | `scripts/detect_machine.sh` (used by bootstrap, make targets) |

## Key Files

| File | Purpose |
|------|---------|
| `pyproject.toml` | Project metadata, deps, entry points, tool configs (ruff, mypy, pytest) |
| `Makefile` | Full lifecycle: quickstart, install, download, server, proxy, omlx, vllm |
| `src/mlx_learning/benchmark_cli.py` | `mlx-bench` Typer CLI with `test_mlx`, `test_omlx`, `benchmark` |
| `src/mlx_learning/hello.py` | Minimal module (tested by `tests/test_hello.py`) |
| `scripts/bootstrap.sh` | Idempotent setup: platform check → uv → deps → model → server → health |
| `scripts/detect_machine.sh` | Chip/RAM/bandwidth detection; `--quiet` (KEY=VALUE) and `--check=M5` modes |
| `scripts/openai_proxy.py` | OpenAI-compatible proxy forwarding to local MLX server |
| `scripts/verify_model.py` | Local `config.json` inspector for downloaded models |
| `models/` | Downloaded model snapshots (gitignored) |

## Build & Run Commands

### Quickstart
```bash
make quickstart                  # full bootstrap (idempotent)
make quickstart PORT=8080        # override defaults
SKIP_SERVER=1 make quickstart    # stop after model download
```

### Development
```bash
uv sync                          # install deps
uv sync --extra server           # + huggingface_hub, mlx-vlm
uv run pytest                    # tests
uv run ruff check .              # lint
uv run ruff format .             # format
uv run mypy .                    # type check (strict)
uv run mlx-bench                 # benchmark MLX vs local server
```

### Serving (omlx — M5 default)
```bash
make omlx-start                  # start on 0.0.0.0:8000
make omlx-status                 # check PID, port, model
make omlx-logs                   # tail log
make omlx-stop                   # stop server
```

### Serving (vllm-mlx — alternative)
```bash
make vllm-start                  # start on 0.0.0.0:8000 (stop omlx first)
make vllm-status / logs / stop
make vllm-bench                  # benchmark against vllm-mlx
```

### Serving (mlx_lm.server — legacy)
```bash
make server-start                # port 5001 (default)
make server-status / logs / stop
```

### Model management
```bash
make model-download              # download MODEL_REPO into models/
make detect-machine              # print chip/RAM/bandwidth
make optimize-system             # set GPU wired memory to 30000MB (requires sudo)
```

## Development Conventions

- **uv + Makefile** are the canonical workflows. No ad hoc `pip` flows.
- **src/ layout** — new CLIs go in `[project.scripts]` via `pyproject.toml`.
- **Model naming** — `models/<repo-with-/-replaced-by-__>` (e.g., `models/mlx-community__Qwen3.6-35B-A3B-4bit/`). Preserves multi-model coexistence.
- **mypy strict** with `ignore_missing_imports = true` (MLX/mlx-lm lack type stubs).
- **ruff** — double quotes, 88-char line limit, `skip-magic-trailing-comma = false`.
- **Tests** — minimal coverage; `tests/test_hello.py` tests `mlx_learning.hello.main()`.
- **PID/log files** — `omlx-server.pid/log`, `vllm-server.pid/log`, `mlx-server.pid/log` at repo root (all gitignored).

## Machine-Aware Behavior

All heavy operations (`model-download`, `omlx-start`, `bench`, `bootstrap`) auto-detect the host chip and print bandwidth info. This matters because:
- M2 Pro (200 GB/s) beats M5 (153.6 GB/s) for plain decode — bandwidth-bound.
- M5 has native FP4 GPU accelerators — NVFP4 quantization is significantly faster on M5.
- Use `make detect-machine` or `bash scripts/detect_machine.sh --quiet` to inspect before running anything.

## Server Endpoints

| Server | Default Port | Endpoint |
|--------|-------------|----------|
| omlx | 8000 | `http://127.0.0.1:8000/v1` |
| vllm-mlx | 8000 | `http://127.0.0.1:8000/v1` |
| mlx_lm.server | 5001 | `http://127.0.0.1:5001/v1` |
| OpenAI proxy | 5101 | `http://127.0.0.1:5101/v1` |

## Model Slugs

Model repo names use `__` instead of `/` everywhere (APIs, file paths, configs). E.g., `mlx-community/Qwen3.6-35B-A3B-4bit` → `mlx-community__Qwen3.6-35B-A3B-4bit`.