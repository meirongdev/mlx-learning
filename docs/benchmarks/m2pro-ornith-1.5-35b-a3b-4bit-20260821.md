# Ornith-1.5-35B-A3B (affine 4-bit) vs Qwen3.6-35B-A3B (NVFP4) on M2 Pro — 2026-08-21

**Host**: Apple M2 Pro, 32 GB, 200 GB/s, `iogpu.wired_limit_mb=30720`
**Server**: omlx **0.6.3rc2** (:8000), both models served from `models/`
**Method (decode)**: `completion_tokens / wall-clock POST duration`, non-streaming, via
`mlx-bench` (`src/mlx_learning/benchmark_cli.py`) — default prompt, `--max-tokens 512`,
`--no-unload`. **3 repeats per cell, median reported.**
**Method (prefill)**: single `max_tokens=1` request at a ~4.9k-token prompt, prefill time
taken as wall-clock minus the server's own `model_load_duration`. Every request carried a
random nonce prefix and `prompt_tokens_details.cached_tokens == 0` was asserted per run —
without that the prefix cache returns a fabricated sub-second number. 3 repeats, median.

First measurement of **[Ornith 1.5](https://huggingface.co/ornith-ai/Ornith-1.5-35B-A3B-MLX-4bit)**
on this repo's hardware. It is a `qwen3_5_moe` MoE (40 layers, 256 experts, 8 active,
3:1 linear/full attention) shipped as **affine 4-bit, group_size 64** — a different
quantization family from the deployed NVFP4 checkpoint, at near-identical size.

## Headline

1. **Ornith decodes 7.7% faster than the deployed NVFP4 Qwen3.6 — 63.33 vs 58.82 tok/s.**
   Both bands are tight (≤1.0% spread) and non-overlapping, so the gap is real.
2. **Prefill goes the other way, slightly: −3.4% (392 vs 406 tok/s).** Fast decode did not
   buy fast prefill.
3. **The affine-4bit prefill advantage that motivated this run does not exist on this
   machine.** omlx's `qwen35_q4_mlp` patch wants exactly this layout (affine, gs64, ≥2048
   prompt tokens) but is gated behind `is_nax_available()`, which is **False on M2 Pro**.
   It is an M5/neural-accelerator path. On this box, affine-vs-NVFP4 buys nothing on prefill.
4. **Neither checkpoint can do speculative decoding.** Ornith's config declares
   `mtp_num_hidden_layers: 1` but ships **no `mtp.*` weights** (all 1757 tensors are under
   `language_model.`). omlx logs the identical situation for the NVFP4 baseline. Bare
   decode is the only number available for either.
5. **Ornith's MLX conversion is text-only.** The upstream `ornith-ai/Ornith-1.5-35B-A3B` is
   `image-text-to-text`, and the config keeps `image_token_id` / `vision_start_token_id`
   plus an image-aware chat template — but there are no `visual.*` weights and no
   `preprocessor_config.json`. Good for benchmark comparability; you lose the VLM.

## Results

### Decode — 512 tokens, short prompt

| Model | Quant | tok/s (3 runs) | median | vs baseline |
|---|---|---|---:|---:|
| `ornith-ai__Ornith-1.5-35B-A3B-MLX-4bit` | affine 4-bit gs64 | 63.46 / 63.33 / 62.84 | **63.33** | **+7.7%** |
| `mlx-community__Qwen3.6-35B-A3B-nvfp4` | NVFP4 | 58.70 / 58.88 / 58.82 | **58.82** | baseline |

The baseline re-measured at 58.82 against the 59.11 logged earlier the same day on the
same server build — a 0.5% drift, so the rig is consistent and the +7.7% is not drift.

### Prefill — ~4,947-token prompt, uncached

| Model | tok/s (3 runs) | median | vs baseline |
|---|---|---:|---:|---:|
| `ornith-ai__Ornith-1.5-35B-A3B-MLX-4bit` | 393 / 392 / 392 | **392** | **−3.4%** |
| `mlx-community__Qwen3.6-35B-A3B-nvfp4` | 402 / 407 / 406 | **406** | baseline |

### Resident memory (omlx `Loaded model:` lines)

| Model | actual | estimate |
|---|---:|---:|
| Ornith-1.5-35B-A3B-MLX-4bit | **18.41–18.50 GB** | 19.08 GB |
| Qwen3.6-35B-A3B-nvfp4 | **19.21–19.36 GB** | 19.95 GB |

Ornith is ~4.5% smaller resident. Decode is bandwidth-bound, so a smaller active
footprint is the most likely driver of the +7.7% — but 4.5% of size does not fully
account for 7.7% of speed, so kernel differences carry part of it. Not decomposed here.

## Why the prefill patch never armed

`omlx/patches/qwen35_q4_mlp.py` replaces eligible affine `QuantizedLinear` calls in the
Qwen MLP with a native qmm wrapper. Its gates: `mode == "affine"` ✓, `group_size in
{64,128}` ✓ (64), `bits in {2,4,5,6,8}` ✓ (4), `min_tokens=2048` ✓ (4,947), and it patches
`mlx_lm.models.qwen3_5` — the module this checkpoint loads through. Every declared gate
passes.

It still did not run. The patch logs at INFO on apply and no such line appears; the skip
path is `logger.debug("Qwen MLP native qmm unavailable; patch skipped")`, reached when
`_native_qmm_for_bits()` returns `None`. Confirmed directly on this host:

```
is_nax_available() -> False
mlx 0.32.0, mlx.core.fast.qmm_supports_group_size -> absent
```

So the affine fast path is a **neural-accelerator (NAX) feature — M5 only**. This predicts
the same comparison on the M5 could favour Ornith's affine layout on prefill substantially,
which is untested and worth running.

What *did* apply to both models: `qwen35_moe_gate_up` fusion (40 layers),
`turboquant_attention`, `qwen35_gdn_prework`, `qwen35_verify_sdpa_split`,
`qwen35_gdn_chunked` (Metal, `impl=blocked_seq`, `min_t=64`).

## Adjacent finding — code-reading, not measured

`m2pro-mtplx-qwen36-35b-20260821.md` hypothesised that omlx's fast verify kernel "never
armed" because the deployed artifact is NVFP4 while MTPLX's is affine 4-bit gs64.
`omlx/patches/qwen35_verify_qmm.py` states: *"Supported: 4-bit and 8-bit **affine**,
group_size in {32, 64, 128}"*, and unlike `qwen35_q4_mlp` it builds Metal kernels directly
and is **not** NAX-gated. That is consistent with the hypothesis — an affine checkpoint
should be able to arm a verify kernel on M2 Pro that NVFP4 cannot.

**This was not measured**, and it cannot be measured with these two checkpoints: neither
ships MTP weights, so there is no native verify path to arm. Testing it needs an affine
4-bit target plus an external drafter.

## Caveats

- **Config parity is imperfect.** The NVFP4 baseline carries per-model settings
  (`turboquant_kv_enabled: true`, 8-bit KV, `temperature: 0.6`); Ornith ran on bare
  defaults. At these lengths this cannot explain the gap: only 10 of 40 layers are
  `full_attention` with 2 KV heads × 256 head_dim, so the KV cache at ~530 tokens is
  ~10 MB against ~1.5 GB of active weights read per step — under 1% of traffic, and 8-bit
  KV halves only that slice. It would matter at long context, which was not tested.
- **No reasoning parser configured for Ornith.** It is a thinking model whose template
  opens `<think>`, and reasoning text lands in `content` (the baseline has
  `reasoning_parser: "qwen"`). Irrelevant to tok/s; relevant if you deploy it.
- **Two variables move together** — model family *and* quantization format. This is not an
  isolated affine-vs-NVFP4 measurement.
- **Quality was not evaluated.** Throughput only. No eval, no code workload; code was the
  workload that inverted the MTP result on 2026-08-16.
- 512-token decode cell and one ~4.9k prefill cell, general-text prompt, single session.
