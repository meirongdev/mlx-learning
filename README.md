# MLX Learning & Benchmark

Tools and scripts for running and benchmarking [MLX](https://github.com/ml-explore/mlx)
models on Apple Silicon. Models are served by [omlx](https://github.com/jundot/omlx) —
a multi-model OpenAI-compatible server that auto-discovers whatever is under `models/`.

## Quickstart

On a fresh Apple Silicon Mac:

```bash
git clone <repository-url>
cd mlx-learning
make quickstart
```

That runs `scripts/bootstrap.sh`, which is idempotent and re-runnable:

1. Verifies macOS + Apple Silicon, prints the detected machine
2. Installs `uv` via the official installer if missing
3. `uv sync --extra server`
4. Downloads the machine-appropriate `MODEL_REPO` into `models/` (skipped if complete)
5. Installs omlx via Homebrew if missing
6. Starts omlx on `0.0.0.0:8000` and health-checks `GET /v1/models`

Override inline (`PORT` / `HOST` / `MODEL_REPO` are all overridable), or set
`SKIP_SERVER=1` to stop after the model download:

```bash
make quickstart PORT=8080
```

Then `make help` lists every target, grouped by stack, with the current configuration.

### Prerequisites

- macOS on Apple Silicon (M1–M5). MLX does not support Intel Macs.
- Python 3.11+
- [`uv`](https://github.com/astral-sh/uv) — auto-installed by `make quickstart`
- Optional: `HF_TOKEN`, only for gated/private repos. The default models are public.

## Two machines, two defaults

This repo is shared between two 32 GB dev boxes, and the default model is chosen
per-machine by `scripts/detect_machine.sh`:

| Machine     | Bandwidth  | Default model | Quantization |
|-------------|------------|--------------|--------------|
| M2 Pro MBP  | 200 GB/s   | `mlx-community/Qwen3.6-35B-A3B-nvfp4` | NVFP4 (MoE, 35B total / 3B active) |
| M5 MBP      | 153.6 GB/s | `mlx-community/gemma-4-26B-A4B-it-qat-nvfp4` | QAT NVFP4 (VLM) |

Decode is memory-bandwidth-bound, so the **older M2 Pro is faster** for plain
decode. Identify the host before running anything heavy — `make model-download`,
`make omlx-start`, `make bench` and `scripts/bootstrap.sh` all print this header
automatically:

```bash
make detect-machine                          # chip / RAM / bandwidth / wired-limit
bash scripts/detect_machine.sh --quiet       # KEY=VALUE lines for `eval`
bash scripts/detect_machine.sh --check=M5    # exit 1 if not on the expected chip
```

## Serving

omlx is the default engine, on `:8000`, exposing `/v1/chat/completions`,
`/v1/models`, `/v1/embeddings`, `/v1/rerank`, `/v1/responses` and `/v1/audio/*`.

```bash
make omlx-start                  # start on 0.0.0.0:8000
make omlx-status                 # mode, endpoint, health, model count
make omlx-logs
make omlx-restart                # REQUIRED after `brew upgrade omlx`
make omlx-stop
```

> ⚠️ **`brew upgrade omlx` does not restart the running server** — it deletes the
> old Cellar directory while the LaunchAgent keeps serving from the missing path,
> so endpoints whose deps only exist in the new build start returning 500. Always
> `make omlx-restart` after upgrading. Details in [docs/serving.md](./docs/serving.md).

To add a model, drop it under `models/` and restart — omlx scans at startup, not live:

```bash
make model-download MODEL_REPO=mlx-community/Qwen3-30B-A3B-4bit
make omlx-restart
```

The API slug is the repo name with `/` replaced by `__`. Note that
`/v1/embeddings` and `/v1/rerank` need two **different** models — see
[docs/models.md](./docs/models.md).

Three other stacks are wired up: **vllm-mlx** (`make vllm-start`, alternative
engine, also port 8000), **stable-diffusion.cpp** (`make sd-start`, text-to-image
on 7860), and the legacy **mlx_lm.server** (`make server-start`, port 5001).
Setup and trade-offs for all four: [docs/serving.md](./docs/serving.md).

### Metrics

omlx has no `/metrics` endpoint. It does keep counters in `~/.omlx/stats.json`,
flushed every 300s, and `make omlx-metrics` renders those into a Prometheus
textfile-collector snapshot — no auth, and nothing hits the inference server:

```bash
make omlx-metrics-preview    # render to stdout, write nothing
make omlx-metrics            # write $OMLX_TEXTFILE_DIR/omlx.prom
```

node_exporter only reads the file if it was started with
`--collector.textfile.directory`. Metric names, the `rate()` queries worth
running, and the four things this cannot measure (latency percentiles, memory
pressure, queue depth, speculative-decoding acceptance):
[docs/serving.md](./docs/serving.md#metrics-prometheus).

## Benchmarking

`mlx-bench` benchmarks models over an OpenAI-compatible HTTP endpoint. For each
model it warms up, times a fixed-length generation, unloads, then moves on — so
memory doesn't bleed between runs.

```bash
make bench                                   # this machine's default model
make bench BENCH_ARGS="--max-tokens 1024"    # pass flags through
uv run mlx-bench slug1 slug2 slug3           # explicit comparison
```

Options: `--omlx-url`, `--prompt`, `--max-tokens`, `--warmup/--no-warmup`,
`--unload/--no-unload`, `--verbose`. Use `--no-unload` against vllm-mlx, which
has no per-model unload endpoint.

Current headline: **59.11 tok/s** warm @ 512 tokens for Qwen3.6-35B-A3B-nvfp4 on
the M2 Pro under omlx 0.6.3rc2. Two findings worth knowing before optimizing
anything:

- **Quantization choice is machine-dependent.** On M2 Pro every 4-bit format
  ties (bandwidth-bound). On M5, NVFP4 wins by 1.25–1.53× thanks to its FP4 GPU
  accelerators — the opposite of published MLX guidance.
- **Speculative decoding is conditional, not a blanket loss.** Measured here it
  ranges from −12% to +98% depending on machine × model × runtime, so work out the
  break-even (`accepted_tokens_per_round / c`) before enabling it. Parallel decoding
  (DiffusionGemma, −68%) stays rejected everywhere.

Full tables, methodology, and reasoning: [docs/performance.md](./docs/performance.md).
Per-run reports: [docs/benchmarks/](./docs/benchmarks/).

## Development

```bash
make test        # pytest
make lint        # ruff check
make format      # ruff format
make typecheck   # mypy --strict
```

## Layout

```
Makefile             shared config + Setup/Development targets, includes make/*.mk
make/
  model.mk           model download, machine detection, system tuning
  omlx.mk            omlx lifecycle, metrics, + `bench`
  vllm.mk            vllm-mlx lifecycle
  sd.mk              stable-diffusion.cpp lifecycle
  legacy.mk          mlx_lm.server lifecycle + `verify`
docs/                models.md, performance.md, serving.md, benchmarks/
scripts/
  bootstrap.sh       idempotent one-click setup (make quickstart)
  omlx.sh            brew-aware omlx lifecycle — all the real logic lives here
  detect_machine.sh  chip / RAM / bandwidth detection
  verify_model.py    smoke-test a server + inspect a local config.json
src/mlx_learning/    the `mlx-bench` CLI (benchmark_cli.py) and the Prometheus
                     textfile collector (omlx_textfile_collector.py)
models/ models-sd/ bin/   downloaded weights and binaries (gitignored)
```

Rules, traps and conventions live in **[AGENTS.md](./AGENTS.md)**; the
supporting detail — measured benchmarks, model catalog, server configuration —
lives in `docs/`.
`CLAUDE.md`, `QWEN.md` and `.github/copilot-instructions.md` are symlinks to
`AGENTS.md`, so every assistant reads the same file.
