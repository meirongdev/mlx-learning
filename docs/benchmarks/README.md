# Benchmark reports

One file per investigation, named `<machine>-<subject>-<date>.md`. **This file is
an index, not a summary** — the running summary of numbers lives in
[`../performance.md`](../performance.md), and duplicating it here is what let the
two drift apart. Add a row, keep the numbers out.

This repo ships across two dev machines, so every report records which one produced
it. Raw `.log` / `.jsonl` output is gitignored on purpose — write results up rather
than accumulating logs.

## Running one

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

`scripts/mtpbench.py` is the heavier harness: N repeats per cell with a median, a
second low-predictability code prompt, and capture of omlx's `vlm_mtp stats:` log
line — which is what separates draft quality (acceptance) from verify cost.

Then: write the conclusion up as a dated `.md` here, fold the headline number into
[`../performance.md`](../performance.md), and add the row below.

## Index

| Report | Machine | Date | Subject |
|--------|---------|------|---------|
| [`m2pro-omlx-vs-vllm-mlx-20260503.md`](./m2pro-omlx-vs-vllm-mlx-20260503.md) | M2 Pro | 2026-05-03 | omlx vs vllm-mlx 0.2.9, Qwen3.6-35B-A3B in all three quants |
| [`m5-omlx-vs-vllm-mlx-nvfp4-20260503.md`](./m5-omlx-vs-vllm-mlx-nvfp4-20260503.md) | M5 | 2026-05-03 | Same comparison on NVFP4, plus the Gemma 4 VLM crash on vllm-mlx 0.2.9 |
| [`m5-qwen3.6-27b-dense-4bit-20260630.md`](./m5-qwen3.6-27b-dense-4bit-20260630.md) | M5 | 2026-06-30 | Dense 27B re-check of the MoE thesis (omlx 0.4.4) |
| [`m2pro-qwen38-27b-mtp-20260816.md`](./m2pro-qwen38-27b-mtp-20260816.md) | M2 Pro | 2026-08-16 | MTP speculative decoding on a dense model — the blanket "MTP loses" rule revisited |
| [`m2pro-qwen38-27b-mxfp4-mtp-20260816.md`](./m2pro-qwen38-27b-mxfp4-mtp-20260816.md) | M2 Pro | 2026-08-16 | Round 2: mxfp4 target + drafter precision |
| [`m5-qwen38-27b-mxfp4-mtp-20260817.md`](./m5-qwen38-27b-mxfp4-mtp-20260817.md) | M5 | 2026-08-17 | Same config on M5 — where the per-machine break-even came from |
| [`m5-gemma4-mtp-20260817.md`](./m5-gemma4-mtp-20260817.md) | M5 | 2026-08-17 | Gemma 4 MoE + Google's own MTP assistant, general vs code |
| [`m2pro-mtplx-qwen36-35b-20260821.md`](./m2pro-mtplx-qwen36-35b-20260821.md) | M2 Pro | 2026-08-21 | MTPLX 2.9.0 native MTP heads vs omlx 0.6.3rc2 |
| [`m2pro-ornith-1.5-35b-a3b-4bit-20260821.md`](./m2pro-ornith-1.5-35b-a3b-4bit-20260821.md) | M2 Pro | 2026-08-21 | Ornith-1.5 (affine 4-bit) vs the deployed NVFP4 Qwen3.6, decode and prefill |
