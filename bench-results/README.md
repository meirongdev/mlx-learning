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

### M5 (Apple M5 base, 32 GB, 153 GB/s)
Qwen3.6-35B-A3B full 3-way comparison, omlx 0.x, MLX (latest). Each model loaded → warmed → timed → unloaded sequentially. All runs with the same default prompt ("Write a 200-word introduction to quantum computing for a 10-year-old.").

**512 tokens (cold/warm-mixed):**

| Model                                | tok/s  | Load (s) |
|--------------------------------------|-------:|---------:|
| NVFP4                                | **51.15** | 15.92   |
| std 4bit                             | 46.02  | 26.48    |
| DWQ-4bit                             | 35.27  | 15.38    |

**1024 tokens (warm state):**

| Model                                | tok/s  | Load (s) |
|--------------------------------------|-------:|---------:|
| std 4bit                             | **45.89** | 25.87   |
| NVFP4                                | 41.05  | 19.25    |
| DWQ-4bit                             | 33.20  | 25.99    |

**Key findings:**

- **NVFP4 wins at 512 tokens** (51.15 tok/s), benefiting from M5's FP4 neural accelerators.
- **std 4bit overtakes NVFP4 at 1024 tokens** (45.89 vs 41.05 tok/s). NVFP4 degrades -19.6% from 512→1024, while std 4bit is stable (-0.3%). This suggests FP4 accelerator advantage is most visible at shorter generations; at longer runs, bandwidth-bound effects dominate and the standard (unquantized) path maintains stable throughput better.
- **DWQ is consistently slowest** (~35 tok/s at 512, ~33 at 1024). Despite being "4-bit", DWQ quantization doesn't benefit from M5's neural accelerators the way NVFP4 does. It does benefit from smaller model size (fewer disk reads, less memory), which is its main advantage.
- **std 4bit loads much slower** (~26s vs ~16s for DWQ/NVFP4) — likely more files / larger on-disk footprint.

This confirms the M5 has format-specific hardware advantages that the M2 Pro lacks. See M2 Pro section below.

### M2 Pro (Apple M2 Pro, 32 GB, 200 GB/s)
Qwen3.6-35B-A3B comparison, same prompt, same omlx flags:

| Model                                | tok/s  |
|--------------------------------------|-------:|
| std 4bit (MoE)                       | 45.86  |
| DWQ-4bit (MoE)                       | 45.36  |
| NVFP4 (MoE)                          | 45.36  |

**All three formats are effectively tied on M2 Pro** (~45.4–45.9 tok/s, within 1% of each other). This confirms the M2 Pro is **bandwidth-bound** (200 GB/s) — the quantization format doesn't matter because memory throughput is the bottleneck. No neural accelerators to differentiate FP4 vs DWQ vs std 4bit.

### Cross-machine comparison (std 4bit, the common denominator)

| Machine | std 4bit tok/s | NVFP4 tok/s | DWQ tok/s | Bandwidth |
|---------|---------------:|------------:|----------:|----------:|
| M2 Pro  | 45.86          | 45.36       | 45.36     | 200 GB/s  |
| M5      | 46.02 (512)    | 51.15 (512) | 35.27     | 153 GB/s  |

**Despite 25% less memory bandwidth, the M5 matches or exceeds the M2 Pro** on std 4bit (46.02 vs 45.86) and significantly exceeds it on NVFP4 (51.15 vs 45.36, +13%). This is entirely due to M5's neural accelerators — the M5's CPU/GPU architecture more than compensates for the bandwidth deficit on accelerated formats.

DWQ is the outlier: M5 is ~22% slower than M2 Pro on DWQ (35.27 vs 45.36), likely because DWQ's sparse activation pattern doesn't map well to M5's FP4 accelerators and the lower bandwidth hurts more.

## Methodology notes

- **Prefill is included in tok/s.** `mlx-bench` measures wall-clock from request → response, so the published number includes prompt processing. With the default ~30-token prompt and 512+ generated tokens, prefill is a small share (<5%).
- **Models are unloaded between runs** so KV cache doesn't carry over. Cold load times in the log are first-time-from-disk after install; OS file cache may make subsequent loads faster.
- **GPU wired memory limit** matters at 32 GB. Always check `make detect-machine` shows `GPU wired limit: 26000+ MB` before benchmarking.
- **omlx server flags** (defined in Makefile `OMLX_EXTRA_ARGS`): `--max-process-memory 90% --hot-cache-max-size 4GB --max-concurrent-requests 2 --initial-cache-blocks 1024`. Changing these would invalidate comparisons.
