# Qwen3.8-27B mxfp4 + drafter-precision test on M2 Pro — 2026-08-16 (round 2)

**Host**: Apple M2 Pro, 32 GB, 200 GB/s, `iogpu.wired_limit_mb=30720`
**Server**: omlx 0.5.7
**Method**: `completion_tokens / wall-clock POST duration`, non-streaming — identical to
`src/mlx_learning/benchmark_cli.py`. Warm-up (cold load + one decode) excluded.
**3 timed repeats per cell, median reported.**

Follow-up to [`m2pro-qwen38-27b-mtp-20260816.md`](./m2pro-qwen38-27b-mtp-20260816.md),
which left `Qwen3.8-27B-mxfp4` as the one viable-but-untested entry in the collection and
tested only quant-matched base/drafter pairs. This round closes both gaps.

> **Prompt caveat.** The prior report does not record its "code" prompt, so this round
> defined its own (a `merge_intervals` implementation task with tests). Comparisons
> *within* this report are apples-to-apples; cross-report **code** cells are not strictly
> so. Cross-report **general** cells use the same mlx-bench default prompt. Where a
> cross-report claim matters below, it is stated in a form that does not depend on prompt
> matching.

## Headline

1. **`mxfp4` is the fastest bare quantization measured on this machine** — its slowest
   cell (11.48) beats the previous best config's fastest cell (`4bit`, 11.45). This
   changes the coding recommendation.
2. **Drafter precision is a dead lever.** A bf16 drafter 3.4× the size of the 4-bit one
   does not raise acceptance materially, and costs throughput on general text.
3. **Verify cost tracks quantization group size monotonically**, independently
   reproducing and extending the prior report's diagnosis of why `4bit` loses under MTP.

## Results

All cells measured this round. MoE control not re-run; the prior report records
**58.04 tok/s** for `Qwen3.6-35B-A3B-nvfp4` on the same server version and method.

| Config | prompt | max_tok | tok/s | tokens/round | acceptance |
|---|---|---:|---:|---:|---:|
| `mxfp4` bare | general | 512 | **11.62** | — | — |
| `mxfp4` bare | general | 1024 | **11.83** | — | — |
| `mxfp4` bare | code | 512 | **11.48** | — | — |
| `mxfp4` bare | code | 1024 | **11.75** | — | — |
| `mxfp4` + `MTP-mxfp4` | general | 512 | 11.52 | 2.14 | 56.9% |
| `mxfp4` + `MTP-mxfp4` | general | 1024 | 13.14 | 2.41 | 70.4% |
| `mxfp4` + `MTP-mxfp4` | code | 512 | 11.23 | 1.88 | 43.8% |
| `mxfp4` + `MTP-mxfp4` | code | 1024 | 11.30 | 1.85 | 42.3% |
| `nvfp4` + `MTP-bf16` | general | 512 | 10.87 | 1.97 | 48.6% |
| `nvfp4` + `MTP-bf16` | general | 1024 | 13.83 | 2.34 | 67.2% |
| `nvfp4` + `MTP-bf16` | code | 512 | 10.61 | 1.88 | 43.8% |
| `nvfp4` + `MTP-bf16` | code | 1024 | 10.80 | 1.81 | 40.7% |

## 1. mxfp4 is the new bare champion

| cell | `mxfp4` (this round) | `4bit` (prior) | `nvfp4` (prior) |
|---|---:|---:|---:|
| general 512 | **11.62** | 11.24 | 10.96 |
| general 1024 | **11.83** | — | 11.16 |
| code 512 | **11.48** | — | 10.98 |
| code 1024 | **11.75** | 11.45 | 11.16 |

Bare dense decode is flat across prompt and length in both rounds — 10.96–11.45 previously,
11.48–11.83 here — textbook bandwidth-bound behaviour for ~15 GB of active weights at
200 GB/s. Because it *is* flat, the cross-report claim survives the prompt caveat:
**mxfp4's worst cell (11.48) exceeds 4bit's best cell (11.45)**, so the ranking does not
depend on which code prompt was used.

The margin is small (+2.6% on the directly comparable code/1024 cell) but consistent
across all four cells, with near-zero variance (code/1024 sampled 11.75 / 11.75 / 11.75).

`config.json`: `mode: "mxfp4"`, `bits: 4`, `group_size: 32`, and it carries a
`vision_config` like every other checkpoint in this family — so it loads through
`VLMBatchedEngine` and the `qwen35_verify_qmm.py` fast kernel stays unarmed, exactly as
the prior report predicted for the whole collection.

## 2. Drafter precision does not buy acceptance

This was the controlled experiment: hold the base model (and therefore verify cost)
fixed at `nvfp4`, and swap only the drafter — 4-bit `MTP-nvfp4` (prior round) against
unquantized `MTP-bf16`, 241 MB → 829 MB.

| cell | `MTP-nvfp4` tokens/round | `MTP-bf16` tokens/round | Δ acceptance | Δ tok/s |
|---|---:|---:|---:|---:|
| general 512 | 2.00 | 1.97 | −1.5% | 12.33 → 10.87 (**−11.8%**) |
| general 1024 | 2.42 | 2.34 | −3.3% | 14.29 → 13.83 (**−3.2%**) |
| code 512 | 1.83 | 1.88 | +2.7% | 10.39 → 10.61 (+2.1%) |
| code 1024 | 1.69 | 1.81 | +7.1% | 10.05 → 10.80 (+7.5%) |

Acceptance barely moves — within a few percent either way, and in the *wrong* direction on
general text. Where it does help (code, +7%), the throughput gain tracks it almost exactly
(+7.5%), which confirms acceptance is the mechanism, but it is nowhere near enough:
**10.80 is still below the 11.16 bare baseline.** MTP remains a net loss on code.

So a 3.4× larger, unquantized draft head is not a better draft head. Draft quality is
limited by the single-layer MTP architecture (`mtp_num_hidden_layers: 1`, `block_size: 3`),
not by how precisely that layer is stored. **Do not spend memory on a higher-precision
drafter.**

## 3. Verify cost is monotonic in group size

The prior report attributed `4bit`'s MTP failure to verify cost by noting acceptance was
near-identical to `nvfp4` (1.90 vs 2.00) while throughput inverted. This round supplies a
third point at nearly identical acceptance:

| base | quantization | tokens/round (general 1024) | bare → +MTP | gain |
|---|---|---:|---|---:|
| `nvfp4` | nvfp4, **gs 16** | 2.42 | 11.16 → 14.29 | **+28%** |
| `mxfp4` | mxfp4, **gs 32** | 2.41 | 11.83 → 13.14 | **+11%** |
| `4bit` | affine, **gs 64** | 1.90 | 11.24 → 8.79 | **−22%** |

`nvfp4` and `mxfp4` produce statistically indistinguishable acceptance (2.42 vs 2.41) yet
differ 2.5× in payoff. That isolates verify cost, and it orders **monotonically by group
size: 16 < 32 < 64**.

Caveat: mode and group size are confounded in this family — each format ships exactly one
group size, so this data cannot separate "nvfp4 vs mxfp4 vs affine" from "gs16 vs gs32 vs
gs64". The monotonicity is a real pattern in the measurements; the causal attribution to
group size specifically is not established.

Practical consequence either way: **under MTP, prefer the smallest-group quantization
available.**

## Revised recommendation

Unchanged at the top: keep `Qwen3.6-35B-A3B-nvfp4` as the default at **58.04 tok/s**.
Everything in this collection is still 4–5× slower.

If Qwen3.8-27B is added as a second, deliberately-selected model:

| workload | config | tok/s | change |
|---|---|---:|---|
| coding / agentic | **`Qwen3.8-27B-mxfp4`, MTP off** | **11.75** | **was `4bit` at 11.45** |
| general / high-redundancy | `Qwen3.8-27B-nvfp4` + `MTP-nvfp4` | 14.29 | unchanged |

`mxfp4` + `MTP-mxfp4` is not recommended for either: it loses to bare mxfp4 on code
(−2.2 to −3.8%) and its general-text gain (+11%) is well short of the nvfp4 pair's +28%.

The functionality cost of MTP from the prior report still applies — `vlm_mtp_enabled` is
mutually exclusive with TurboQuant KV, guided grammar, thinking budget and repetition
penalties (`omlx/model_settings.py:292-317`), and the default model uses
`turboquant_kv_enabled`, so this is not a global switch.

## What this round rules out

Two plausible optimization paths are now closed by measurement rather than reasoning:

- **A higher-precision drafter** — no acceptance gain, net throughput loss on general text.
- **mxfp4 as an MTP base** — better bare, but middling under MTP.

Still untested in the collection: `Qwen3.8-27B-OptiQ-4bit` (uploaded 2026-08-15, after the
prior report). Note that `docs/models.md` already records OptiQ's speedup riding on an
`optiq/mtp.safetensors` sidecar that omlx cannot load — it resolves only the *vision*
sidecar — so the same dead end likely applies. `8bit` / `mxfp8` / `bf16` remain excluded by
the 32 GB wired limit.

## Reproducing

Measured with [`scripts/mtpbench.py`](../../scripts/mtpbench.py), added in this round —
`mlx-bench` times a single run per model, which is not enough to separate a real 3%
difference from noise, and it does not capture MTP telemetry.

```bash
uv run python scripts/mtpbench.py \
  --model mlx-community__Qwen3.8-27B-mxfp4 \
  --repeats 3 --out results.jsonl
```

Both prompts are defined in that file. The code prompt used here:

> Write a Python function `merge_intervals(intervals)` that merges overlapping closed
> intervals and returns them sorted. Handle empty input, single intervals, full
> containment, and touching endpoints. Include type hints, a docstring, and five pytest
> test cases.

`~/.omlx/model_settings.json` was backed up to `.bak-20260816-pre-mxfp4-round2` and fully
restored afterwards. MTP was enabled per-model as:

```json
"mlx-community__Qwen3.8-27B-mxfp4": {
  "vlm_mtp_enabled": true,
  "vlm_mtp_draft_model": "mlx-community__Qwen3.8-27B-MTP-mxfp4"
}
```

Acceptance telemetry comes from omlx's own per-request log line, which is what separates
draft quality from verify cost:

```
vlm_mtp stats: request=… rounds=605 accepted=418/1210 (34.5%) tokens_per_round=1.69 block_size=3
```
