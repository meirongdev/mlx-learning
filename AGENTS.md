# AGENTS.md

Single source of truth for AI assistants and contributors.
`CLAUDE.md`, `QWEN.md`, and `.github/copilot-instructions.md` are symlinks to
this file — edit here only.

This file holds **only the rules and traps** — what must be loaded before you
touch anything. Everything else (numbers, catalog, configs, commands, layout)
lives in `docs/` and `README.md`, to be read on demand.

| Need | Read |
|------|------|
| What's on disk, model slugs, naming, per-endpoint requirements | [docs/models.md](./docs/models.md) |
| Benchmark numbers, break-even tables, quantization findings, what's been tried | [docs/performance.md](./docs/performance.md) |
| Server setup, omlx config, MTP mechanics, memory tuning, assistant configs | [docs/serving.md](./docs/serving.md) |
| Raw benchmark reports | [docs/benchmarks/](./docs/benchmarks/) |
| Commands, layout, onboarding | [README.md](./README.md) and `make help` |

## The machines

Two 32 GB boxes with different memory subsystems. The Makefile picks
`MODEL_REPO` per machine (M5 → Gemma 4, else → Qwen).

| Machine        | Bandwidth  | Serves (via omlx) |
| -------------- | ---------- | ----------------- |
| M2 Pro MacBook | 200 GB/s   | `mlx-community/Qwen3.6-35B-A3B-nvfp4` (MoE, 3B active) |
| M5 MacBook Pro | 153.6 GB/s | `mlx-community/gemma-4-26B-A4B-it-qat-nvfp4` (Gemma 4 VLM) |

Decode is memory-bandwidth bound, so **the older M2 Pro is faster** for plain
decode — a plain-decode statement only, since speculation inverts the ranking.

## Hard rules

1. **Identify the machine first.** Any download / serve / benchmark step runs
   `make detect-machine` (or `scripts/detect_machine.sh`) first, or its output is
   unattributable.
2. **Speculative decoding is conditional — work out the break-even before
   enabling it, never by reputation.** It ranges from −12% to +98% across the
   machine × model × runtime combinations measured here; parallel decoding
   (DiffusionGemma, −68%) stays rejected everywhere. The governing number is
   `speedup = accepted_tokens_per_round / c`, where `c` is the cost of one verify
   forward in decode-steps. **Measure acceptance from the server's own log —
   never assume it.** Per-machine break-even table:
   [docs/performance.md](./docs/performance.md#speculative-decoding-the-break-even-table).
   How to enable it: [docs/serving.md](./docs/serving.md#enabling-mtp-speculative-decoding).
3. **Drafter attachment is fail-soft.** If it fails you silently measure bare and
   fabricate a "no change" result. Confirm the `VLM MTP enabled ... drafter=` log
   line before believing any speculative number.
4. **Warm up before timing.** After a model swap the first full pass can read
   25–30% low, which fabricates spectacular fake speedups.
5. **`make omlx-restart` after every `brew upgrade omlx`.** The upgrade does not
   restart the running server — it deletes the old Cellar directory while the
   LaunchAgent keeps serving from the now-missing path. Symptoms and the
   freshness check: [docs/serving.md](./docs/serving.md).
6. **Never `pip install` to fix a failing omlx endpoint.** The deps ship inside
   the Homebrew build; a 500 means you're on a stale server, not a missing package.
7. **The live omlx config is `~/.omlx/settings.json`**, not the Makefile flags.
   Editing `OMLX_EXTRA_ARGS` changes nothing on these machines.
8. **Quote benchmark numbers with their machine and server version.** Both move
   results more than quantization choice does (omlx 0.4.x → 0.5.4rc1 alone was
   +27% on the M2 Pro).

## Conventions

- `uv` + Makefile are the canonical workflows; no ad hoc `pip` flows.
- `src/` layout; new CLIs go in `[project.scripts]`, not as top-level scripts.
- New Makefile targets go in the matching `make/*.mk` and carry a `## comment`
  so `make help` picks them up. New stacks get their own `.mk` and a `##@ Section`.
- Model directory naming `models/<repo-with-/-replaced-by-__>` — preserve it so
  multiple models coexist ([docs/models.md](./docs/models.md#naming)).
- PID/log files and tool artifacts live at repo root and are gitignored.
- Style is enforced, not memorized: `make lint typecheck` (ruff + mypy `strict`,
  both configured in `pyproject.toml`).
- Tests are minimal — the benchmark CLI and serving are uncovered.
- Commits: descriptive, imperative mood (`Add feature X`, `Fix bug Y`).
- PRs: `make test lint typecheck` must pass. If the change affects benchmark
  performance, state the delta, the machine (`make detect-machine`), and the
  server version — a number without all three is not reviewable.
- Write benchmark conclusions up as a dated `.md` in `docs/benchmarks/` and fold
  the headline into `docs/performance.md`. Don't commit raw run logs.

## References

- [Apple M5 上 omlx + Gemma4-26B 性能调优实录](https://meirong.dev/posts/omlx-gemma4-m5-optimization/)
- [omlx GitHub Repository](https://github.com/jundot/omlx)
