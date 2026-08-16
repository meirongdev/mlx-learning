# AGENTS.md

Single source of truth for AI assistants and contributors.
`CLAUDE.md`, `QWEN.md`, and `.github/copilot-instructions.md` are symlinks to
this file — edit here only.

This file holds the **rules and traps**: what you need loaded before touching
anything. Reference material lives in `docs/` and is meant to be read on demand.

| Need | Read |
|------|------|
| What's on disk, model slugs, per-endpoint requirements | [docs/models.md](./docs/models.md) |
| Benchmark numbers, quantization findings, what's already been tried | [docs/performance.md](./docs/performance.md) |
| Server setup, omlx config, memory tuning, assistant configs | [docs/serving.md](./docs/serving.md) |
| Raw benchmark reports | [docs/benchmarks/](./docs/benchmarks/) |
| Human onboarding | [README.md](./README.md) |

## Hard rules

1. **Identify the machine first.** This repo runs on two boxes with different
   memory subsystems. Any download / serve / benchmark step must run
   `scripts/detect_machine.sh` first, or its output is unattributable.
2. **Never enable speculative or parallel decoding on these MoE models.**
   Measured three ways on 2026-08-01 — DFlash −19…−29%, Google's own Gemma MTP
   assistant −12%, DiffusionGemma −68%. On a sparse MoE, processing N positions
   per forward pass activates the *union* of experts across those positions, so
   the weight read grows with N.
   **On a dense model it can pay, but only above ~2.0 accepted tokens/round**
   (measured 2026-08-16 on Qwen3.8-27B: +12–28% on general text, −5…−10% on
   code) — check omlx's `vlm_mtp stats` log line before trusting it, and note
   `vlm_mtp_enabled` conflicts with TurboQuant KV, which the default model uses.
   Full data: [docs/performance.md](./docs/performance.md).
3. **`make omlx-restart` after every `brew upgrade omlx`** — see the trap below.
4. **Never `pip install` to fix a failing omlx endpoint.** The deps ship inside
   the Homebrew build; a 500 means you're on a stale server, not a missing package.
5. **The live omlx config is `~/.omlx/settings.json`**, not the Makefile flags.
   Editing `OMLX_EXTRA_ARGS` changes nothing on these machines.
6. **Quote benchmark numbers with their machine and omlx version.** Both move
   results more than quantization choice does (the 0.4.x → 0.5.4rc1 upgrade alone
   was +27% on the M2 Pro).

## The machines

| Machine        | Chip            | Memory bandwidth | Serves (via omlx) |
| -------------- | --------------- | ---------------- | ----------------- |
| M2 Pro MacBook | Apple M2 Pro    | 200 GB/s         | `mlx-community/Qwen3.6-35B-A3B-nvfp4` (MoE, 3B active, 256k) |
| M5 MacBook Pro | Apple M5 (base) | 153.6 GB/s       | `mlx-community/gemma-4-26B-A4B-it-qat-nvfp4` (Gemma 4 VLM, 256k) |

Both 32 GB. Decode is memory-bandwidth bound, so **the older M2 Pro is faster**
for plain decode. Both switched to omlx on 2026-06-28.

```bash
make detect-machine                          # chip / RAM / bandwidth / wired limit
bash scripts/detect_machine.sh --quiet       # KEY=VALUE for `eval $(...)`
bash scripts/detect_machine.sh --check=M5    # exit 1 if not on the expected chip
```

`MODEL_REPO` is selected per-machine by the Makefile (M5 → Gemma 4, else → Qwen).
Override with `MODEL_REPO=... make <target>`. `MODEL_DIR` is derived by replacing
`/` with `__`.

## ⚠️ The omlx upgrade trap

`brew upgrade omlx` does **not** restart the running server. It deletes the old
Cellar directory while the LaunchAgent keeps serving from the now-missing path
(KeepAlive doesn't notice). Symptom: endpoints whose deps only exist in the *new*
build return 500, and tracebacks print paths for a version that is gone, **with
no source lines**. On 2026-08-01 a 26-day-old 0.4.4 process was serving while
0.5.4rc1 sat unused, breaking `/v1/embeddings` and both `/v1/audio/*`.

```bash
make omlx-restart
ps -axo pid,etime,comm | grep omlx-server        # etime must be small
lsof -p "$(pgrep -f omlx-server | head -1)" | grep -o '/opt/homebrew/Cellar/omlx/[^/]*' | sort -u
```

## Commands

`make help` is generated from the Makefiles and is always current. The common set:

```bash
make quickstart                  # fresh Mac -> deps -> model -> omlx -> health check
make omlx-start | omlx-restart | omlx-status | omlx-logs | omlx-stop
make model-download MODEL_REPO=...
make bench                       # this machine's model; BENCH_MODELS/BENCH_ARGS to override
make test | lint | format | typecheck
```

`HF_TOKEN` is optional — the default models are public. Pass it only for
gated/private repos.

## Layout

```
AGENTS.md            this file (CLAUDE.md, QWEN.md, copilot-instructions.md → symlinks)
README.md            human onboarding
Makefile             shared config + Setup/Development targets, includes make/*.mk
make/
  model.mk           model download, machine detection, system tuning
  omlx.mk            omlx lifecycle + `bench`
  vllm.mk            vllm-mlx lifecycle
  sd.mk              stable-diffusion.cpp lifecycle
  legacy.mk          mlx_lm.server lifecycle + `verify`
docs/                models.md, performance.md, serving.md, benchmarks/
scripts/
  bootstrap.sh       idempotent one-click setup (make quickstart)
  omlx.sh            brew-aware omlx lifecycle — all the real logic lives here
  detect_machine.sh  chip / RAM / bandwidth detection
  verify_model.py    smoke-test a server + inspect a local config.json
src/mlx_learning/    `mlx-bench` Typer CLI (benchmark_cli.py)
models/ models-sd/ bin/   downloaded weights and binaries (gitignored)
```

### The two code layers

**Benchmark CLI** — `src/mlx_learning/benchmark_cli.py`, registered as `mlx-bench`
in `[project.scripts]`. It benchmarks models over an **OpenAI-compatible HTTP
endpoint**; it does not load MLX in-process. Per model: warm up, time a
fixed-length generation against `/v1/chat/completions`, unload (`--no-unload` to
keep resident), then print a comparison table. `--omlx-url` retargets it at any
compatible server.

**Server lifecycle** — Makefile targets are thin wrappers. omlx's real logic is in
`scripts/omlx.sh` (brew-vs-nohup detection, health polling, orphan recovery); the
other three stacks are simple nohup + PID-file management in their `.mk` files.

## Conventions

- `uv` + Makefile are the canonical workflows; no ad hoc `pip` flows.
- `src/` layout; new CLIs go in `[project.scripts]`, not as top-level scripts.
- New Makefile targets go in the matching `make/*.mk` and carry a `## comment`
  so `make help` picks them up. New stacks get their own `.mk` and a `##@ Section`.
- Model directory naming `models/<repo-with-/-replaced-by-__>` — preserve it so
  multiple models coexist.
- PID/log files live at repo root and are gitignored.
- ruff: double quotes, 88-char lines, `skip-magic-trailing-comma = false`.
  mypy `strict` with `ignore_missing_imports = true` (MLX/mlx-lm lack stubs).
  Both configured in `pyproject.toml`.
- Tests are minimal — `tests/test_hello.py` only covers `mlx_learning.hello.main()`.
  The benchmark CLI and serving are uncovered.
- Commits: descriptive, imperative mood (`Add feature X`, `Fix bug Y`).
- PRs: `make test lint typecheck` must pass. If the change affects benchmark
  performance, state the delta, the machine (`make detect-machine`), and the
  omlx version — a number without all three is not reviewable.
- Write benchmark conclusions up as a dated `.md` in `docs/benchmarks/` and fold
  the headline into `docs/performance.md`. Don't commit raw run logs.

## References

- [Apple M5 上 omlx + Gemma4-26B 性能调优实录](https://meirong.dev/posts/omlx-gemma4-m5-optimization/)
- [omlx GitHub Repository](https://github.com/jundot/omlx)
