# MTPLX (native MTP) vs omlx on M2 Pro — 2026-08-21

**Host**: Apple M2 Pro, 32 GB, 200 GB/s, `iogpu.wired_limit_mb=30720`
**Servers**: omlx **0.6.3rc2** (:8000) · MTPLX **2.9.0** (:8001, `uvx`-isolated)
**Method**: `completion_tokens / wall-clock POST duration`, non-streaming, via
`mlx-bench` (`src/mlx_learning/benchmark_cli.py`) — default prompt, `--max-tokens 512`,
`--no-unload`. **3 repeats per cell, median reported.** Fans on the Apple auto curve for
every cell (MTPLX's ThermalForge pinning deliberately not installed).

First measurement of **[MTPLX](https://github.com/youssofal/mtplx)** on this repo's
hardware. MTPLX drafts from the target model's **own MTP heads** (exact rejection
sampling, no second model resident) — a different mechanism from omlx's `vlm_mtp`, which
attaches an **external** assistant drafter.

## Headline

1. **MTP is worth +12.9% inside MTPLX, but MTPLX's bare decode is 6.9% slower than
   omlx's — so the net gain over the deployed setup is only +5.2%.**
2. **Verify is cheap on this native path.** Effective `c` ≈ **1.66** for depth 1 on a
   *MoE*, against the **~2.04** measured for omlx's external-drafter path on a *dense*
   model on this same machine. This is consistent with the hypothesis in
   [`m2pro-qwen38-27b-mtp-20260816.md`](./m2pro-qwen38-27b-mtp-20260816.md): the
   affine-gated fast verify kernel never armed under omlx's `vlm_mtp` path, and MTPLX's
   artifact is affine 4-bit gs64 — exactly what such a kernel wants.
3. **Depth 1 only.** D2 is +6% and D3 is a *net loss* (0.95×); acceptance collapses
   87% → 44% → 25% across depths while verify cost grows ~0.35 decode-steps per depth.
4. **Not a clean single-variable comparison** — see Caveats. Three things move at once.

## Results

| Stack | Model | MTP | tok/s (3 runs) | median | vs omlx |
|---|---|---|---|---:|---:|
| omlx 0.6.3rc2 | `mlx-community__Qwen3.6-35B-A3B-nvfp4` | — | 59.03 / 59.11 / 59.22 | **59.11** | baseline |
| MTPLX 2.9.0 | `Youssofal/Qwen3.6-35B-A3B-MTPLX-Optimized-Speed-FP16` | off (`--no-mtp`) | 53.55 / 55.10 / 55.06 | **55.06** | **−6.9%** |
| MTPLX 2.9.0 | same | on (`--depth 1`) | 62.16 / 64.59 / 60.30 | **62.16** | **+5.2%** |

Variable split:

| Step | Δ |
|---|---:|
| omlx nvfp4 → MTPLX AR (runtime + quant + checkpoint) | **−6.9%** |
| MTPLX AR → MTPLX depth 1 (MTP alone) | **+12.9%** |
| net | **+5.2%** |

Run-to-run spread is the other half of the story: omlx sits in a 0.16% band
(59.03–59.22), MTPLX+MTP swings 60.30–64.59 (**±3.5%**) because acceptance depends on
what the model is saying. A single MTPLX run can read anywhere in that band.

## Depth sweep (`mtplx tune --retune`, its own harness)

| Depth | tok/s | vs AR | verify (ms) | acceptance by head |
|---|---:|---:|---:|---|
| AR | 55.83 | 1.00× | — | — |
| **D1** | **62.28** | **1.12×** | 26.43 | MTP1 236/271 = **87.08%** |
| D2 | 59.41 | 1.06× | 31.75 | MTP1 82.22% · MTP2 43.56% |
| D3 | 52.79 | 0.95× | 38.95 | MTP1 83.50% · MTP2 45.50% · MTP3 24.50% |

`tune`'s AR (55.83) and `mlx-bench`'s AR median (55.06) agree within 1.4% across two
independent harnesses — the AR number is solid.

## The break-even math

Per rule 2, `speedup = accepted_tokens_per_round / c`. One AR decode step here is
`1000/55.06 = 18.16 ms`.

| Depth | accepted/round | `c` from verify_ms | measured speedup | **effective `c`** |
|---|---:|---:|---:|---:|
| D1 | 1.871 | 1.46 | 1.129 | **1.66** |
| D2 | 2.258 | 1.75 | 1.064 | 2.12 |
| D3 | 2.535 | 2.15 | 0.946 | 2.68 |

Effective `c` exceeds the verify-only `c` by ~0.2 at every depth — that gap is the draft
head's own forward plus sampling overhead, which the verify_ms figure does not include.
**Quote the effective number when comparing against the break-even table in
[`../performance.md`](../performance.md#speculative-decoding-the-break-even-table)**; the
verify-only figure flatters the method by ~12%.

Against that table: M2 Pro / dense Qwen3.8-27B / omlx `vlm_mtp` needs **~2.04**. Here a
*MoE* lands at **1.66** — cheaper verify despite the union-of-experts weight read that
made MoE verify expensive on M5. The native path, not the model shape, looks like the
difference.

## Caveats

- **Three variables move together**: runtime (omlx → MTPLX), quantization
  (nvfp4 gs16 → affine 4-bit gs64), and checkpoint (`mlx-community` → `Youssofal`).
  The −6.9% AR gap cannot be attributed to any one of them from this data.
- MTPLX refuses to attach an MTP sidecar to an arbitrary trunk, so measuring its MTP on
  *our* nvfp4 checkpoint is not possible by design — the quant change is forced, not chosen.
- 512-token cell only, general-text prompt only. Code was the workload that inverted the
  sign on both prior MTP investigations here; **it is untested for MTPLX.**
- omlx side ran with `turboquant_kv_enabled: true, turboquant_kv_bits: 8` (the deployed
  M2 Pro setting); MTPLX has no equivalent knob engaged.

## Traps found

1. **`mtplx tune` with a *relative* `--model` path fails every candidate and still
   exits 0.** Candidates run in isolated subprocesses whose cwd is not the repo root:
   all four report `model is not available locally` in 0.1 s, the summary prints
   `n/a tok/s`, and `echo $?` says success. Use absolute paths. `mtplx inspect` accepts
   the relative path fine, so inspect passing proves nothing about tune.
2. **`mtplx stop` without `--port` only scans 8000 / 18083–18085** and reports
   "No running MTPLX server found" while the server on :8001 keeps serving. Pass `--port`.
3. **MTPLX writes artifacts into the cwd** (`outputs/cli/tune/<ts>/`), which was not
   gitignored. Added `outputs/` to `.gitignore`.
4. **MTPLX's default port is 8000 — the same as omlx's.** Always pass `--port`.

## Verdict

**Not worth switching the M2 Pro deployment for +5.2%**, given that it costs a 20 GB
second checkpoint, gives up nvfp4, widens run-to-run variance twentyfold, and drops the
`/v1/embeddings|rerank|audio` endpoints and multi-model LRU that omlx provides for the
four helper models on this box.

**Worth revisiting if** code-heavy workloads reproduce the +21.5% pattern seen with
Gemma's drafter on M5 — at 87% acceptance on general text, depth 1 has headroom that a
more predictable workload could cash in.

MTPLX's Gemma 4 build is an **assistant-pair bundle** running on a backend literally named
`gemma4_assistant` — i.e. the same external-drafter mechanism omlx already uses on M5.
Nothing there is mechanically new, so the M5 numbers in
[`m5-gemma4-mtp-20260817.md`](./m5-gemma4-mtp-20260817.md) stand.
