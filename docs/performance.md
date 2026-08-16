# Performance

Everything here is measured on the two machines in this repo, not inherited from
published guidance. Where the two disagree, the measurement wins — that has
happened twice (NVFP4 on M5, speculative decoding on MoE).

Raw reports: [`benchmarks/`](./benchmarks/). Model catalog: [models.md](./models.md).

## The governing constraint

Apple-Silicon decode is **memory-bandwidth bound**: `tok/s ≈ bandwidth / bytes_read_per_token`.
Almost every result below follows from that one equation.

| Machine        | Chip            | Bandwidth   | GPU/NPU AI throughput  |
| -------------- | --------------- | ----------- | ---------------------- |
| M2 Pro MBP     | Apple M2 Pro    | 200 GB/s    | Lower                  |
| M5 MBP 14"     | Apple M5 (base) | 153.6 GB/s  | Higher (neural accels) |

So the older M2 Pro is **faster** for plain decode. The M5 narrows the gap on
prompt prefill (compute-bound) and on anything touching its neural accelerators.

### Why A3B MoE instead of a dense 27B

Only the *active* weight footprint per token matters. Measured on M2 Pro:

| Model                      | Active weights read/token | tok/s    |
|----------------------------|---------------------------|---------:|
| Qwen3.6-27B-4bit (dense)   | ~15 GB                    | **10.6** |
| Qwen3.6-35B-A3B-4bit (MoE) | ~1.5–2 GB                 | **45.8** |

A larger MoE is both stronger and ~4.3× faster than a dense model half its size,
because MoE collapses per-token memory traffic. Anything under ~16 GB of *active*
weights is the ceiling for this class of machine.

## Quantization is machine-dependent

Published MLX guidance (early 2026): DWQ-4bit > standard 4bit > NVFP4 / MXFP4.
DWQ wins on perplexity, and NVFP4/MXFP4 were designed for Blackwell-class FP4
tensor cores — on MLX they were expected to fall back to FP16 and lose the
bandwidth win entirely.

**On the M5 that does not hold.** Three runs on 2026-05-03 (omlx, Qwen3.6-35B-A3B):

| Run                     | NVFP4 tok/s | DWQ tok/s | Ratio |
|-------------------------|------------:|----------:|------:|
| Cold, 512 tokens        | 39.74       | 31.33     | 1.27× |
| Cold-ish, 1024 tokens   | 36.47       | 29.23     | 1.25× |
| Warm, 1024 tokens       | **49.14**   | 32.11     | 1.53× |

The gap widens with warm state — DWQ gains ~10% from warm-up while NVFP4 jumps
~35%, which points at accelerator/kernel state rather than file cache. Warm
NVFP4 (~49 tok/s) beat the historical M2 Pro 4-bit ceiling (45.8) despite ~25%
less bandwidth. Likely cause: M5's GPU neural accelerators (Oct 2025) and/or
omlx-specific FP4 kernels.

**On the M2 Pro all three formats tie** (omlx 0.4.x: std 4bit 45.89, DWQ 45.36,
NVFP4 45.36 — within 1%). Expected: no native FP4 hardware, and all formats read
the same ~19 GB, so the 200 GB/s bus is the ceiling regardless of format.

So: **M5 → NVFP4. M2 Pro → any of the three.** (M5 no longer keeps a Qwen as of
2026-06-28; if you reintroduce one, prefer `mlx-community/Qwen3.6-35B-A3B-nvfp4`.)

## Speculative and parallel decoding lose on these MoE models

Measured three ways on the M2 Pro, 2026-08-01. **Do not retry these blind.**

| Method | Model | Warm tok/s, 512 tok | vs baseline |
|---|---|------:|---|
| plain autoregressive decode | Qwen3.6-35B-A3B-nvfp4 | **57.9** | baseline |
| DFlash + 4-bit draft | Qwen3.6-35B-A3B | 46.8 | **−19%** |
| DFlash + bf16 draft | Qwen3.6-35B-A3B | 40.9 | **−29%** |
| plain autoregressive decode | gemma-4-26B-A4B-it-qat-nvfp4 | **44.3** | baseline |
| Google's own MTP assistant (`vlm_mtp`) | gemma-4-26B-A4B | 38.9 | **−12%** |
| DiffusionGemma block-parallel denoising | diffusiongemma-26B-A4B-4bit | 14.3 | **−68%** |

**Why: on a sparse MoE, any scheme that processes N token positions in one
forward pass activates the _union_ of experts across those N positions, so the
weight read grows roughly with N instead of staying at the per-token active
set.** Qwen3.6-35B-A3B reads ~3B active of 35B per token; verifying a 16-token
block reads a large fraction of the full 35B. The sparsity that makes A3B/A4B
models fast on a bandwidth-bound Mac is exactly what makes parallel decoding
expensive. "Speculation beats the bandwidth limit" is a **dense-model** rule and
inverts here.

### …but on dense models it only half-holds

That closing claim was tested on an actual dense model (Qwen3.8-27B, 2026-08-16,
omlx 0.5.7) and came back **half-confirmed**. Speculation stops being
structurally doomed — MTP produced a real **+12–28% on general text**, which
never happened on any MoE — but it is not a reliable win either. On a
bandwidth-bound Mac the M=4 verify forward is expensive enough that MTP needs
roughly **≥2.0 accepted tokens/round** to break even, and code generation
delivers only 1.69–1.88, making it a **net loss (−5 to −10%) on code**.

**Revised rule: on dense models speculation can pay, but only above ~2.0
accepted tokens/round — measure acceptance from omlx's `vlm_mtp stats` log line
before trusting it.** On MoE it remains a flat no.

Two follow-up levers were measured and both are dead ends:

- **A higher-precision drafter does not help.** Holding the base fixed and
  swapping the 4-bit draft head for an unquantized bf16 one (241 MB → 829 MB)
  moved acceptance by at most a few percent, in the *wrong* direction on general
  text (−11.8% tok/s). Draft quality is limited by the single-layer MTP
  architecture (`mtp_num_hidden_layers: 1`, `block_size: 3`), not by storage
  precision.
- **Verify cost orders monotonically by quantization group size.** At
  indistinguishable acceptance (2.42 vs 2.41), `nvfp4` gs16 gained +28% while
  `mxfp4` gs32 gained only +11%; `affine` gs64 lost 22%. Under MTP, prefer the
  smallest-group quantization available. (Mode and group size are confounded in
  this family, so the causal attribution to group size is not established.)

Full data: [`benchmarks/m2pro-qwen38-27b-mtp-20260816.md`](./benchmarks/m2pro-qwen38-27b-mtp-20260816.md)
and [`benchmarks/m2pro-qwen38-27b-mxfp4-mtp-20260816.md`](./benchmarks/m2pro-qwen38-27b-mxfp4-mtp-20260816.md).

The Gemma row is the strongest evidence — it used Google's own purpose-built
drafter (`google/gemma-4-26B-A4B-it-assistant`, 246k downloads,
`model_type: gemma4_assistant`, 0.27 GB, first-class omlx support), so "the
drafter wasn't matched to the model" is not an available explanation.

All reverted. Implementation notes if ever revisited: the DFlash engine bypasses
the Scheduler and does not apply TurboQuant KV
(`grep -c turboquant .../omlx/engine/dflash.py` → 0); `vlm_mtp_enabled`
hard-conflicts with TurboQuant KV plus penalties/thinking-budget/guided-grammar.

## Reference numbers

Qwen3.6-35B-A3B, warmup + 512-token generation.

### omlx (default server)

| Machine      | Bandwidth   | Best quant | tok/s | Notes |
|--------------|-------------|------------|------:|-------|
| M2 Pro 32 GB | 200 GB/s    | NVFP4 | **58.04 warm** (omlx 0.5.7) | 2026-08-16. Was 57.9 on 0.5.4rc1 — flat across that upgrade. On 0.4.x this box measured 45.89 / 45.36 / 45.36, all tied; **the 0.4.x → 0.5.4rc1 upgrade alone added +27%** |
| M5 32 GB     | 153.6 GB/s  | NVFP4 | **39.74 cold / 49.14 warm** | omlx 0.4.x, not re-measured on 0.5.x. DWQ: 31.33 cold / 32.11 warm |

Gemma 4 (`gemma-4-26B-A4B-it-qat-nvfp4`): **44.3 tok/s warm** on M2 Pro /
omlx 0.5.4rc1; ~30 tok/s on M5 under 0.4.x.

### vllm-mlx 0.3.0 (alternative engine)

| Machine      | Best quant        | tok/s (512)     | tok/s (1024 warm) | Notes |
|--------------|-------------------|----------------:|------------------:|-------|
| M2 Pro 32 GB | std 4bit or NVFP4 | **58.13–57.40** | **58.83–58.65**   | DWQ only 45–46 tok/s (slow path) |
| M5 32 GB     | NVFP4             | **51.09**       | **52.25**         | DWQ not tested; +5–10% vs omlx 0.4.x |

**DWQ under vllm-mlx is significantly slower than std 4-bit / NVFP4** (~46 vs
~59 tok/s on M2 Pro) — vllm-mlx lacks optimized kernels for DWQ's per-group
dequant scheme. Under omlx all three formats are equal on M2 Pro.

> ⚠️ **The "vllm-mlx is ~28% faster" conclusion is superseded on the M2 Pro.**
> Those runs were against omlx **0.4.x**. omlx 0.5.4rc1 decodes at 57.9 tok/s,
> i.e. parity with vllm-mlx's 58.83 — there is no longer a throughput reason to
> switch. Keep omlx. The M5 rows have not been re-measured on 0.5.x.

## Measuring

```bash
make detect-machine   # always first — numbers are meaningless without the host
make omlx-status      # or: make omlx-start
make bench            # this machine's MODEL_SLUG
make bench BENCH_MODELS="slug1 slug2" BENCH_ARGS="--max-tokens 1024"
```

`mlx-bench` loads → warms → times → unloads each model in sequence so memory
doesn't bleed between runs. Notes on comparability:

- **Prefill is included.** Wall-clock from request → response, so the published
  number includes prompt processing. With the default ~30-token prompt and 512+
  generated tokens that's <5% — but short generations amortize it badly, so a
  64-token run reads low and is not comparable to a 512-token one.
- **The GPU wired limit matters** at 32 GB. Confirm `make detect-machine` before
  benchmarking; macOS resets it on reboot.
- **Record the omlx version.** The 0.4.x → 0.5.4rc1 jump moved the M2 Pro by
  +27%, which dwarfs every quantization difference on that machine.
