# Benchmark results

Raw `mlx-bench` logs, one file per run. Filenames encode `<machine>-<comparison>-<max_tokens>-<UTC date>.log`.

This repo ships across two dev machines, so each result must record which one produced it. Always pair a new bench with `make detect-machine` output (already printed in the log header by `make bench`).

## Running

```bash
# Always start here — confirms which machine you're on.
make detect-machine

# Make sure omlx is up.
make omlx-status   # or: make omlx-start

# Default: 512-token gen, 200-word quantum-computing prompt.
uv run mlx-bench mlx-community__Qwen3.6-35B-A3B-4bit-DWQ \
                 mlx-community__Qwen3.6-35B-A3B-nvfp4

# Save under bench-results/ with a date-stamped name.
uv run mlx-bench <model1> <model2> --max-tokens 1024 \
  | tee bench-results/$(./scripts/detect_machine.sh --quiet \
       | awk -F= '/MACHINE_CHIP_SHORT/ {gsub(/'\''/, "", $2); print tolower($2)}')-$(date +%Y%m%d-%H%M%S).log
```

## Summary so far

### M5 (Apple M5 base, 32 GB, 153.6 GB/s)
Qwen3.6-35B-A3B head-to-head, omlx 0.x, MLX (latest). Each model loaded → warmed → timed → unloaded sequentially. All runs with the same default prompt ("Write a 200-word introduction to quantum computing for a 10-year-old.").

| Run | Date / state           | max_tokens | NVFP4 tok/s | DWQ tok/s | NVFP4 / DWQ |
|-----|------------------------|-----------:|------------:|----------:|------------:|
| 1   | 2026-05-03, cold start | 512        | **39.74**   | 31.33     | 1.27×       |
| 2   | 2026-05-03, cold-ish   | 1024       | **36.47**   | 29.23     | 1.25×       |
| 3   | 2026-05-03, warm       | 1024       | **49.14**   | 32.11     | **1.53×**   |

**NVFP4 wins consistently on M5 + omlx.** The gap widens once the system is warm — file cache, omlx hot prefix cache (`--hot-cache-max-size 4GB`), and any GPU/accelerator state are all primed. Steady-state tok/s on this M5 is closer to **49 tok/s** for NVFP4 than the cold-start ~38 tok/s. DWQ benefits less from warm-state (only ~10% lift, vs NVFP4's ~35%), suggesting something other than file cache is helping NVFP4 — likely accelerator or kernel warmup specific to FP4.

This is the *opposite* of published MLX guidance ("MLX upcasts NVFP4 to FP16, so it's slower than 4-bit"). Two plausible reasons it inverts on M5:

1. **M5 GPU neural accelerators.** Apple's October 2025 announcement explicitly called out new in-GPU neural accelerators for AI. Apple ML Research published "Exploring LLMs with MLX and the Neural Accelerators in the M5 GPU" describing FP-format speedups specific to M5.
2. **omlx custom kernels.** omlx is a separate engine from `mlx-lm` and may ship FP4 paths that vanilla `mlx-lm` lacks.

Either way: the empirical measurement on this hardware says NVFP4 wins, and warm-state NVFP4 (~49 tok/s) actually beats the historical M2 Pro 4-bit ceiling (45.8 tok/s) despite the M5 having ~25% less memory bandwidth.

### M2 Pro (Apple M2 Pro, 32 GB, 200 GB/s)
Historical reference (pre-DWQ, pre-NVFP4 comparison), 4-bit standard quantization:

| Model                                | tok/s |
|--------------------------------------|------:|
| Qwen3.6-27B-4bit (dense)             | 10.6  |
| Qwen3.6-35B-A3B-4bit (MoE)           | 45.8  |

**Not yet re-benchmarked with DWQ + NVFP4 on the M2 Pro.** The M2 Pro lacks M5's neural accelerators, so the InsiderLLM guidance (DWQ > NVFP4 on MLX) is more likely to hold there. Re-run the head-to-head on the M2 Pro box and append a row when available.

## Methodology notes

- **Prefill is included in tok/s.** `mlx-bench` measures wall-clock from request → response, so the published number includes prompt processing. With the default ~30-token prompt and 512+ generated tokens, prefill is a small share (<5%).
- **Models are unloaded between runs** so KV cache doesn't carry over. Cold load times in the log are first-time-from-disk after install; OS file cache may make subsequent loads faster.
- **GPU wired memory limit** matters at 32 GB. Always check `make detect-machine` shows `GPU wired limit: 26000+ MB` before benchmarking.
- **omlx server flags** (defined in Makefile `OMLX_EXTRA_ARGS`): `--max-process-memory 90% --hot-cache-max-size 4GB --max-concurrent-requests 2 --initial-cache-blocks 1024`. Changing these would invalidate comparisons.
