# Benchmark results

Written-up `mlx-bench` runs. This file is the running summary; each `<machine>-<comparison>-<date>.md` is a full report for one investigation.

Raw per-run `.log` output from the 2026-05-03 batch was pruned once its conclusions landed here and in `../performance.md` — write results up rather than accumulating logs.

This repo ships across two dev machines, so each result must record which one produced it. Always pair a new bench with `make detect-machine` output (already printed in the header by `make bench`).

## Running

```bash
# Always start here — confirms which machine you're on.
make detect-machine

# Make sure omlx is up.
make omlx-status   # or: make omlx-start

# Default: 512-token gen, 200-word quantum-computing prompt.
uv run mlx-bench mlx-community__Qwen3.6-35B-A3B-4bit-DWQ \
                 mlx-community__Qwen3.6-35B-A3B-nvfp4

# Or just: make bench   (uses this machine's MODEL_REPO; BENCH_MODELS/BENCH_ARGS to override)
```

Write the conclusion up as a dated `.md` in this directory and fold the headline number into [`../performance.md`](../performance.md). Don't commit raw run logs.

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

### Server engine: omlx vs vllm-mlx (M5)

(2026-05-03, Qwen3.6-35B-A3B NVFP4, single-stream, vllm-mlx flags matched to omlx config — see `m5-omlx-vs-vllm-mlx-nvfp4-20260503.md` for the flag map.)

| Run | omlx (tok/s) | vllm-mlx 0.2.9 (tok/s) | Δ |
|---|---:|---:|---:|
| 512 cold-warm | 46.29 | **51.09** | +10.4% |
| 1024 cold-warm | 49.74 | **52.25** | +5.0% |
| 1024 warm | 48.67 | **51.73** | +6.3% |

vllm-mlx is **5–10% faster** on text LLMs and stays ahead but converges as warmup completes — the steady-state ceiling on this M5 is ~52 tok/s (bandwidth-bound for both). The win mostly comes from start-up / paged-cache scheduling, not steady-state kernel efficiency.

**Gemma 4 26B (VLM): vllm-mlx 0.2.9 is broken.** Both `--mllm` and auto-detected MLLM paths crash with `RuntimeError: There is no Stream(gpu, 0) in current thread` from `mlx_vlm/generate.py`. Streaming returns empty completions silently. omlx serves Gemma 4 fine at ~38 tok/s. Detailed report and traceback: `m5-omlx-vs-vllm-mlx-nvfp4-20260503.md`. **Fixed in vllm-mlx 0.3.0** (re-tested 2026-06-07 on M5, ~30 tok/s @ 512).

**M2 Pro:** done — see `m2pro-omlx-vs-vllm-mlx-20260503.md`. The gap was *larger*, not smaller (+28% for vllm-mlx on std 4bit / NVFP4), but it closed entirely once omlx reached 0.5.4rc1 (57.9 vs 58.8 tok/s). See [`../performance.md`](../performance.md).

### Dense 27B on M5 — the MoE thesis, re-checked (2026-06-30, omlx 0.4.4)

`mlx-community/Qwen3.6-27B-4bit` (dense, hybrid Gated-DeltaNet/SSM + full
attention, 64 layers) on M5: **~4.4 tok/s**, stable across 512 and 1024, against
~40–49 for the 35B-A3B MoE on the same box — ~10× slower. Not swap-bound (0.31 GB
page-ins over a 121 s decode) and not cache-tuning-sensitive (a lean omlx cache
config changed nothing). It reaches ~39% of its ~11.4 tok/s bandwidth ceiling
because the linear-attention layers hit an unoptimized sequential MLX path.

The intended target, `nvidia/Qwen3.6-27B-NVFP4`, turned out to be an NVIDIA
ModelOpt/CUDA checkpoint no MLX runtime can load — see
[`../models.md`](../models.md). Model deleted from M5 after the run. Report:
`m5-qwen3.6-27b-dense-4bit-20260630.md`.

### Speculative decoding (MTP) on a dense model — Qwen3.8-27B mxfp4

Same model, drafter, omlx 0.5.7 and prompts on both machines. Acceptance is
identical across machines; only verify cost differs.

| cell | M2 Pro bare | M2 Pro + MTP | M5 bare | M5 + MTP |
|---|---:|---:|---:|---:|
| general 512 | 11.62 | 11.52 (−1%) | 8.50 | **15.01 (+77%)** |
| general 1024 | 11.83 | 13.14 (+11%) | 8.45 | **16.75 (+98%)** |
| code 512 | 11.48 | 11.23 (−2%) | 8.49 | **12.09 (+42%)** |
| code 1024 | 11.75 | 11.30 (−4%) | 8.50 | **11.98 (+41%)** |

Break-even is **~2.04** accepted tokens/round on M2 Pro but **~1.26** on M5, so MTP
is a coin-flip on one machine and an unconditional win on the other. It also
inverts the machine ranking: M2 Pro leads bare, M5 leads with MTP. Reports:
`m2pro-qwen38-27b-mtp-20260816.md`, `m2pro-qwen38-27b-mxfp4-mtp-20260816.md`,
`m5-qwen38-27b-mxfp4-mtp-20260817.md`.

### MTP on the MoE — Gemma 4 26B-A4B + Google's assistant, M5

| cell | bare | + MTP | Δ | tokens/round |
|---|---:|---:|---:|---:|
| general 512 | 38.59 | 38.25 | −0.9% | 2.57 |
| general 1024 | 38.67 | 38.56 | −0.3% | 2.63 |
| code 512 | 39.05 | **47.44** | **+21.5%** | 3.36 |
| code 1024 | 38.87 | **47.23** | **+21.5%** | 3.34 |

The M2 Pro's −12% does not reproduce on M5. Break-even is ~2.70 tokens/round, so
general text sits on the fence and code clears it. Comparing against the dense model
on the same machine, each extra verified position costs **~4.9× more on the MoE** —
the union-of-experts penalty, quantified. Report: `m5-gemma4-mtp-20260817.md`.

## Methodology notes

- **Prefill is included in tok/s.** `mlx-bench` measures wall-clock from request → response, so the published number includes prompt processing. With the default ~30-token prompt and 512+ generated tokens, prefill is a small share (<5%).
- **Warm up harder after a model swap.** `scripts/mtpbench.py` warms with one short generation, which was **not enough** for Gemma 4 loaded right after evicting another 15 GB model: the whole first pass read 25–30% low and would have reported a fake "+24–70%" MTP win (2026-08-17). Discard a full pass before timing, and treat any bare baseline whose cells disagree by more than a few percent as invalid — bare decode on these machines is flat across prompt and length.
- **Models are unloaded between runs** so KV cache doesn't carry over. Cold load times in the log are first-time-from-disk after install; OS file cache may make subsequent loads faster.
- **GPU wired memory limit** matters at 32 GB. Always check `make detect-machine` shows `GPU wired limit: 26000+ MB` before benchmarking.
- **omlx server config.** The 2026-05-03 runs used `--max-process-memory 90% --hot-cache-max-size 4GB --max-concurrent-requests 2 --initial-cache-blocks 1024`; `--max-process-memory` was removed in omlx 0.4.x (now `--memory-guard`). Changing these invalidates comparisons — and note that on these machines the *live* server reads `~/.omlx/settings.json`, not the Makefile flags, so record what `settings.json` actually held.
