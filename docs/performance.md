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

⚠️ **That 10.6 is not comparable to today's checkpoint.** It predates the 2026
Qwen3.6 hybrid-attention VLM build and almost certainly measured a
standard-attention 27B. Re-measured on **M5, omlx 0.4.4, 2026-06-30** against
`mlx-community/Qwen3.6-27B-4bit` as it ships now (dense, 64 layers, 3:1
Gated-DeltaNet/SSM linear-attention to full attention):

| Model on M5                      | Active/token | tok/s (512) | Bandwidth ceiling | % of ceiling |
|----------------------------------|-------------:|------------:|------------------:|-------------:|
| Qwen3.6-27B-4bit (dense, hybrid) | ~13.5 GB     | **~4.4**    | ~11.4 tok/s       | ~39%         |
| Qwen3.6-35B-A3B-nvfp4 (MoE)      | ~1.5 GB      | ~40–49      | —                 | —            |

So the dense 27B is ~10× slower than the MoE *on the same machine*, and it is not
swap-bound — 0.31 GB of page-ins across a full 121 s decode, so the 15 GB model
stays resident under the 26 GB wired limit. It reaches only ~39% of its bandwidth
ceiling because the linear-attention layers hit an unoptimized sequential MLX
path, on top of the dense footprint. The M2 Pro has not been re-measured on this
exact checkpoint, so the cross-machine gap for it is unknown. The model was
deleted from M5 after the run. Report:
`benchmarks/m5-qwen3.6-27b-dense-4bit-20260630.md`.

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

> **Superseded early reading of the same batch.** It was first summarized as a
> *length* effect — std 4bit overtaking NVFP4 at 1024 tokens (45.89 vs 41.05), NVFP4
> "degrading −19.6% from 512 → 1024". Those cells were cold/warm-mixed and do not line
> up with the table above; the cold/warm split is the axis that reproduced. Treat
> length-dependence on M5 as unmeasured rather than observed.

**On the M2 Pro all three formats tie** (omlx 0.4.x: std 4bit 45.89, DWQ 45.36,
NVFP4 45.36 — within 1%). Expected: no native FP4 hardware, and all formats read
the same ~19 GB, so the 200 GB/s bus is the ceiling regardless of format.

So: **M5 → NVFP4. M2 Pro → any of the three.** (M5 no longer keeps a Qwen as of
2026-06-28; if you reintroduce one, prefer `mlx-community/Qwen3.6-35B-A3B-nvfp4`.)

## Speculative decoding: the break-even table

`speedup = accepted_tokens_per_round / c`, where `c` is the cost of one verify
forward expressed in decode-steps. Break-even is exactly `accepted == c`.
**Measure acceptance, never assume it** — omlx prints it on the `vlm_mtp stats`
log line ([serving.md](./serving.md#enabling-mtp-speculative-decoding)), MTPLX
prints it from `mtplx tune`.

| Machine | Model | Drafter | `c` = break-even tokens/round | Measured |
|---|---|---|---:|---|
| M2 Pro | Qwen3.8-27B (dense) | omlx `vlm_mtp`, external | **~2.04** | +12–28% general, −5…−10% code (2026-08-16) |
| M5 | Qwen3.8-27B (dense) | omlx `vlm_mtp`, external | **~1.26** | **+41–98%, every cell** (2026-08-17) |
| M5 | gemma-4-26B-A4B (MoE) | omlx `vlm_mtp`, external | **~2.70** | −0.6% general, **+21.5% code** (2026-08-17) |
| M2 Pro | gemma-4-26B-A4B (MoE) | omlx `vlm_mtp`, external | — | −12%, different harness (2026-08-01) |
| M2 Pro | Qwen3.6-35B-A3B (MoE) | MTPLX, model's own MTP heads | **~1.66** | +12.9% vs its own AR, +5.2% vs omlx (2026-08-21) |

Two effects, don't conflate them: **M5's verify hardware is cheap** (neural
accelerators — `c` 1.26 vs M2 Pro's 2.04 on the same dense model), and **MoE
verify is expensive** (each extra verified position costs ~4.9× more than on a
dense model *on the same machine* — the union-of-experts weight read is real).
On M5 those roughly cancel, leaving Gemma 4 at break-even on general text and a
solid win on code, where Google's drafter hits 78% acceptance.

So: **on M5 enable it for dense models unconditionally; for Gemma 4 enable it if
your workload is code-heavy, and don't bother if it is chat-heavy.** DFlash
(−19…−29%) was only ever tested on M2 Pro and remains unretested on M5. Parallel
decoding (DiffusionGemma, −68%) stays rejected everywhere.

**Quote the *effective* `c`** — backed out of the measured speedup — not the one
implied by verify time alone. The latter omits the drafter's own forward pass and
flattered MTPLX by 12% (1.46 vs 1.66 at depth 1).

The sections below are the evidence behind each row, oldest first.

## Speculative and parallel decoding lose on these MoE models — on the M2 Pro

Measured three ways on the M2 Pro, 2026-08-01. **Do not retry these blind.**
The Gemma MTP row was re-measured on the M5 on 2026-08-17 and **does not
reproduce there** — see [below](#and-on-m5-the-moe-verdict-flips-for-code).

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

The Gemma row is the strongest evidence for that reading — it used Google's own
purpose-built drafter (`google/gemma-4-26B-A4B-it-assistant`, 246k downloads,
`model_type: gemma4_assistant`, 0.27 GB, first-class omlx support), so "the
drafter wasn't matched to the model" is not an available explanation for the
M2 Pro loss. What the M5 round later showed is that the penalty, while real, is
not by itself disqualifying — see below.

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

That ~2.0 threshold is **an M2 Pro number, not a constant** — see the next
section, which measures it at ~1.26 on the M5.

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

### …and the break-even threshold is per-machine — on M5 speculation just wins

The M2 Pro round was replicated on the M5 on 2026-08-17 with the same model,
drafter, omlx version and prompts. **MTP won every cell, including code:**

| cell | M5 bare | M5 + MTP | Δ | M2 Pro Δ (same config) |
|---|---:|---:|---:|---:|
| general 512 | 8.50 | 15.01 | **+77%** | −1% |
| general 1024 | 8.45 | 16.75 | **+98%** | +11% |
| code 512 | 8.49 | 12.09 | **+42%** | −2% |
| code 1024 | 8.50 | 11.98 | **+41%** | −4% |

Acceptance was statistically identical on both machines (2.41 tokens/round on
general/1024 either way) — draft quality is a model property, so the entire
difference is **verify cost**. Backing it out of `speedup = tokens_per_round / c`:

| Machine | Cost of one M=4 verify, in decode steps | Break-even tokens/round |
|---|---:|---:|
| M2 Pro | ~2.04 | **~2.04** |
| M5 | ~1.26 | **~1.26** |

**So: on M5, enable MTP on dense models — there was no losing workload in the
tested set. On M2 Pro, check acceptance first.** This is the same neural-accelerator
story as the NVFP4 anomaly above: a batched M=4 verify is compute-dense and
bandwidth-light, exactly the shape M5 is good at, while single-token decode is
pure bandwidth, where M5 loses.

Consequence worth internalizing: **MTP inverts the machine ranking.** Bare, M2 Pro
beats M5 by 39%; with MTP, M5 beats M2 Pro in every cell (16.75 vs 13.14 at best).
"The older M2 Pro is faster" is a plain-decode statement only.

Full data: [`benchmarks/m5-qwen38-27b-mxfp4-mtp-20260817.md`](./benchmarks/m5-qwen38-27b-mxfp4-mtp-20260817.md).

### …and on M5 the MoE verdict flips, for code

Gemma 4 + Google's own assistant, measured on M5 2026-08-17 (the machine that
actually deploys it — the −12% above was an M2 Pro run):

| cell | bare | + MTP | Δ | tokens/round |
|---|---:|---:|---:|---:|
| general 512 | 38.59 | 38.25 | −0.9% | 2.57 |
| general 1024 | 38.67 | 38.56 | −0.3% | 2.63 |
| code 512 | 39.05 | **47.44** | **+21.5%** | 3.36 |
| code 1024 | 38.87 | **47.23** | **+21.5%** | 3.34 |

Break-even is **~2.70** tokens/round here. General text sits exactly on it and is a
coin flip run-to-run (best run +7.7% at 2.88, worst −8.1% at 2.37, same implied
verify cost); code clears it at 78% acceptance and wins solidly.

**The union-of-experts penalty is confirmed and now has a number.** Comparing the
two models measured on M5 the same day, each *extra* verified position costs

| Model | M | `c` | cost per extra position |
|---|---:|---:|---:|
| Qwen3.8-27B mxfp4 (dense) | 4 | 1.26 | **0.087** |
| gemma-4-26B-A4B (MoE) | 5 | 2.70 | **0.425** |

— **~4.9× more on the MoE.** So the structural argument above was right; what it
got wrong was treating the penalty as disqualifying. A drafter good enough to
clear the higher bar still wins, and Google's clears it on code.

Note the workload inversion versus the dense model: Qwen's MTP head drafts code at
44% acceptance and general at 70%, Google's assistant is 78% on code and 54% on
general. **Which workload benefits is a property of the drafter, not of
speculation.**

Full data: [`benchmarks/m5-gemma4-mtp-20260817.md`](./benchmarks/m5-gemma4-mtp-20260817.md).

> **Benchmarking trap this round exposed.** The first bare Gemma pass, run right
> after a model swap, read **25–30% low** and would have shown MTP at "+24–70%,
> every cell" — dramatic and entirely false. `mtpbench.py`'s one-generation warm-up
> is insufficient after a swap. Discard a full pass before timing, and reject any
> bare baseline whose cells disagree by more than a few percent: bare decode on
> these machines is flat.

All reverted. Implementation notes if ever revisited: the DFlash engine bypasses
the Scheduler and does not apply TurboQuant KV
(`grep -c turboquant .../omlx/engine/dflash.py` → 0); `vlm_mtp_enabled`
hard-conflicts with TurboQuant KV plus penalties/thinking-budget/guided-grammar.

## Reference numbers

Qwen3.6-35B-A3B, warmup + 512-token generation.

### omlx (default server)

| Machine      | Bandwidth   | Best quant | tok/s | Notes |
|--------------|-------------|------------|------:|-------|
| M2 Pro 32 GB | 200 GB/s    | NVFP4 | **59.11 warm** (omlx 0.6.3rc2) | 2026-08-21. Was 58.04 on 0.5.7 and 57.9 on 0.5.4rc1 — flat across both upgrades. On 0.4.x this box measured 45.89 / 45.36 / 45.36, all tied; **the 0.4.x → 0.5.4rc1 upgrade alone added +27%** |
| M5 32 GB     | 153.6 GB/s  | NVFP4 | **39.74 cold / 49.14 warm** | omlx 0.4.x, not re-measured on 0.5.x. DWQ: 31.33 cold / 32.11 warm |

Gemma 4 (`gemma-4-26B-A4B-it-qat-nvfp4`): **44.3 tok/s warm** on M2 Pro /
omlx 0.5.4rc1; ~30 tok/s on M5 under 0.4.x.

#### Ornith 1.5 beats the deployed Qwen3.6 on decode, M2 Pro

Measured 2026-08-21, omlx 0.6.3rc2, same box and session —
[`m2pro-ornith-1.5-35b-a3b-4bit-20260821.md`](./benchmarks/m2pro-ornith-1.5-35b-a3b-4bit-20260821.md).
`ornith-ai/Ornith-1.5-35B-A3B-MLX-4bit` is a `qwen3_5_moe` MoE in **affine 4-bit gs64**,
against the deployed NVFP4 Qwen3.6 at near-identical size.

| Model | Quant | Decode (512) | Prefill (~4.9k) | Resident |
|---|---|---:|---:|---:|
| Ornith-1.5-35B-A3B-MLX-4bit | affine 4-bit gs64 | **63.33** (+7.7%) | 392 (−3.4%) | 18.41–18.50 GB |
| Qwen3.6-35B-A3B-nvfp4 | NVFP4 | 58.82 | **406** | 19.21–19.36 GB |

**Decode +7.7%, prefill −3.4%** — the faster decoder is the slower prefiller. Two variables
move together (model family *and* quant format), so this is not an isolated format result;
it does not contradict "all three formats tie on M2 Pro", which was measured within one model.

⚠️ **omlx's affine-4bit prefill fast path is M5-only.** `qwen35_q4_mlp` passes every
declared gate for this checkpoint (affine, gs64, 4-bit, ≥2048 prompt tokens) and still
never armed: it is gated behind `is_nax_available()`, **False on M2 Pro**. Do not expect a
prefill win from choosing an affine 4-bit checkpoint on this box — and re-run this pair on
the M5, where the gate should open.

Neither checkpoint can speculate: both declare `mtp_num_hidden_layers: 1` and ship **no
`mtp.*` weights**. Ornith's MLX build is also **text-only** — the upstream model is a VLM,
but the conversion carries no `visual.*` weights.

### vllm-mlx 0.3.0 (alternative engine)

| Machine      | Best quant        | tok/s (512)     | tok/s (1024 warm) | Notes |
|--------------|-------------------|----------------:|------------------:|-------|
| M2 Pro 32 GB | std 4bit or NVFP4 | **58.13–57.40** | **58.83–58.65**   | DWQ only 45–46 tok/s (slow path) |
| M5 32 GB     | NVFP4             | **51.09**       | **52.25**         | DWQ not tested; +5–10% vs omlx 0.4.x |

**DWQ under vllm-mlx is significantly slower than std 4-bit / NVFP4** (~46 vs
~59 tok/s on M2 Pro) — vllm-mlx lacks optimized kernels for DWQ's per-group
dequant scheme. Under omlx all three formats are equal on M2 Pro.

### MTPLX 2.9.0 (native MTP, alternative engine)

Measured on M2 Pro 2026-08-21 —
[`m2pro-mtplx-qwen36-35b-20260821.md`](./benchmarks/m2pro-mtplx-qwen36-35b-20260821.md).
MTPLX drafts from the target model's **own MTP heads**; omlx's `vlm_mtp` attaches an
**external** drafter. It refuses to attach an MTP sidecar to an arbitrary trunk, so its
own `Youssofal/…-MTPLX-Optimized-Speed-FP16` build (affine 4-bit gs64) is forced — the
quantization change comes with the engine.

| Config | tok/s (512, median of 3) | vs omlx 0.6.3rc2 |
|---|---:|---:|
| omlx, `Qwen3.6-35B-A3B-nvfp4` | **59.11** | baseline |
| MTPLX, `--no-mtp` | **55.06** | **−6.9%** |
| MTPLX, `--depth 1` | **62.16** | **+5.2%** |

**MTP earns +12.9% inside MTPLX, but its bare decode starts 6.9% behind omlx, so the net
is +5.2%** — not enough to move the deployment, given a second 20 GB checkpoint, the loss
of nvfp4 and of omlx's embeddings/rerank/audio endpoints and multi-model LRU, and a
run-to-run spread that widens from 0.16% to ±3.5%.

Depth 1 only: acceptance falls 87% → 44% → 25% over depths 1–3, and **D3 is a net loss**
(0.95× AR). Effective `c` ≈ **1.66** at depth 1 — cheaper than the ~2.04 omlx's external
drafter needs on a *dense* model on this same box, despite this being a MoE. That is the
predicted signature of the affine-gated fast verify kernel finally arming; see
[`m2pro-qwen38-27b-mtp-20260816.md`](./benchmarks/m2pro-qwen38-27b-mtp-20260816.md) for
why it never armed under omlx. Code workloads — the ones that inverted the sign on both
prior MTP investigations — are **untested**.

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

`mlx-bench` (`src/mlx_learning/benchmark_cli.py`, registered in
`[project.scripts]`) drives an **OpenAI-compatible HTTP endpoint** — it never
loads MLX in-process, so `--omlx-url` retargets it at any compatible server
(vllm-mlx, `mlx_lm.server`, MTPLX). Per model it loads → warms → times a
fixed-length generation against `/v1/chat/completions` → unloads (`--no-unload`
keeps it resident), so memory doesn't bleed between runs. Notes on comparability:

- **Warm up properly.** After a model swap the first full pass can read 25–30%
  low, which fabricates spectacular fake speedups. Discard it, or keep the model
  resident with `--no-unload` and take a later run.

- **Prefill is included.** Wall-clock from request → response, so the published
  number includes prompt processing. With the default ~30-token prompt and 512+
  generated tokens that's <5% — but short generations amortize it badly, so a
  64-token run reads low and is not comparable to a 512-token one.
- **The GPU wired limit matters** at 32 GB. Confirm `make detect-machine` before
  benchmarking; macOS resets it on reboot.
- **Record the omlx version.** The 0.4.x → 0.5.4rc1 jump moved the M2 Pro by
  +27%, which dwarfs every quantization difference on that machine.
