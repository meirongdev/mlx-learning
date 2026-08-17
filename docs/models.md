# Models

Catalog of every model that has been on disk, plus the per-endpoint rules that
aren't obvious from the omlx API. Operational setup is in [serving.md](./serving.md);
speed numbers are in [performance.md](./performance.md).

## Naming

Model directories are `models/<HF repo with / replaced by __>`, and that same
slug is the `model` field in API requests:

```
mlx-community/Qwen3.6-35B-A3B-nvfp4  →  models/mlx-community__Qwen3.6-35B-A3B-nvfp4
                                     →  {"model": "mlx-community__Qwen3.6-35B-A3B-nvfp4"}
```

Preserve this so multiple models coexist under `models/`. omlx auto-discovers
every subdirectory at startup — drop a model in and `make omlx-restart`
(it does **not** rescan live).

## Catalog

The **On disk** column reflects state after the 2026-06-28 M5 cleanup, plus the
2026-08-17 M5 additions (`Qwen3.8-27B-mxfp4` + its drafter, and the Gemma 4 MTP
assistant — ~15.5 GB, kept after the MTP round; delete if you want the space back).

| Model dir                                           | Quantization | Size   | Context | On disk | Notes |
|-----------------------------------------------------|--------------|--------|---------|---------|-------|
| `mlx-community__Qwen3.6-35B-A3B-nvfp4`              | NVFP4        | ~19 GB | 256k    | M2 Pro  | **M2 Pro's main model. 57.9 tok/s warm @ 512 on omlx 0.5.4rc1** (was 45.36 on 0.4.x — the upgrade alone gave +27%). Fastest on M5 too (39.74 @ 512); removed from M5 2026-06-28 |
| `mlx-community__Qwen3.6-35B-A3B-4bit-DWQ`           | DWQ-4bit     | ~19 GB | 256k    | M2 Pro  | M2 Pro: 45.36 tok/s; on M5: 31.33 tok/s (slower than NVFP4). Removed from M5 2026-06-28 |
| `mlx-community__Qwen3.6-35B-A3B-4bit`               | std 4bit     | ~19 GB | 256k    | M2 Pro  | M2 Pro: **45.89 tok/s** (marginally fastest on M2 Pro). Removed from M5 2026-06-28 |
| `mlx-community__gemma-4-26b-a4b-it-nvfp4`           | NVFP4        | ~15 GB | 256k    | —       | Non-QAT Gemma 4; removed from M5 2026-06-28 |
| `mlx-community__gemma-4-26B-A4B-it-qat-nvfp4`       | QAT NVFP4    | ~15 GB | 256k    | **M5**  | **M5's main (chat/VLM) model.** Gemma 4 VLM; runs on omlx (M5 default) and vllm-mlx 0.3.0+ (~30 tok/s @ 512/1024); QAT = better quality at 4-bit. Crashed on vllm-mlx 0.2.9 |
| `mlx-community__Qwen3-Embedding-0.6B-4bit-DWQ`      | DWQ-4bit     | ~0.34 GB | —     | **M5**  | **Embedding** (1024-dim, multilingual). Added 2026-06-28 for testing `/v1/embeddings`. Cross-lingual sanity check passed (en↔zh cosine ~0.72) |
| `mlx-community__Qwen3-Embedding-4B-4bit-DWQ`        | DWQ-4bit     | ~2.1 GB | —      | M2 Pro  | **Embedding** (2560-dim). Verified 2026-08-01: en↔zh cosine 0.68 |
| `mlx-community__Qwen3-ASR-1.7B-8bit`                | 8bit         | ~1.9 GB | —      | M2 Pro  | **ASR** (`/v1/audio/transcriptions`). Better multilingual/Chinese than `parakeet-tdt-0.6b-v3`, which is the higher-download English default |
| `mlx-community__Qwen3-TTS-12Hz-1.7B-CustomVoice-8bit` | 8bit       | ~2.9 GB | —      | M2 Pro  | **TTS** (`/v1/audio/speech`). See the voice list below — there is no `default` |
| `mlx-community__Qwen3-Reranker-0.6B-4bit`           | 4bit         | ~0.4 GB | —      | M2 Pro  | **Reranker** (`/v1/rerank`). Added 2026-08-01. Required for that endpoint — an embedding model will not do |
| `z-lab__Qwen3.6-35B-A3B-DFlash`                     | bf16         | ~0.77 GB | —     | M2 Pro (unused) | DFlash speculative drafter. **Benchmarked and rejected — cost 19–29%.** Kept for reference only; safe to delete |
| `mlx-community__gemma-4-26B-A4B-it-qat-assistant-nvfp4` | QAT NVFP4 | ~0.26 GB | —    | M2 Pro (unused), **M5 (on disk, MTP off)** | Google's official Gemma 4 MTP drafter (`gemma4_assistant`, `block_size=4`). **Rejected on M2 Pro (−12%) but re-tested on M5 2026-08-17: −0.6% general, +21.5% code at 78% acceptance.** Keep on M5 if the workload is code-heavy — enabling it is a one-key change, see serving.md; delete on M2 Pro |
| `mlx-community__diffusiongemma-26B-A4B-it-4bit`     | std 4bit     | ~15 GB | 256k    | M2 Pro (unused) | **Separate model, not a Gemma 4 version** (see below). **Benchmarked and rejected — 14.3 vs 44.3 tok/s.** Still listed in `/v1/models`, so a client can pick it and get 3× slower replies. Safe to delete |

### Qwen3.8-27B (dense) — evaluated as a second model, not deployed

Evaluated 2026-08-16 for the capability jump (Terminal-Bench 2.1 63.4→73.0,
DeepSWE 1.1 13.3→42.2, OSWorld-Verified 63.9→84.3, native vision), **not** for
speed: the whole family runs 4–5× slower than the deployed MoE. It is a VLM
(`Qwen3_5ForConditionalGeneration` + `vision_config`), so omlx loads it through
`VLMBatchedEngine` — which is why the MTP fast-verify kernel never arms for it.

**Two checkpoints are back on disk — on the M5.** All seven were downloaded,
benchmarked and removed on the M2 Pro 2026-08-16 (~45.5 GB reclaimed); `mxfp4`
plus its `MTP-mxfp4` drafter were then re-downloaded to the **M5** on 2026-08-17
to test the family on the other machine. That round changed the verdict for M5 —
see the MTP note below. The M2 Pro still keeps only `Qwen3.6-35B-A3B-nvfp4` for
inference, which is 4–5× faster and, unlike what the name suggests, **also serves
vision** (`Qwen3_5MoeForConditionalGeneration` with a `vision_config`; verified
end-to-end). The rows below are kept so the options are not silently retried.

| Model dir | Quantization | Size | On disk | Notes |
|---|---|---|---|---|
| `mlx-community__Qwen3.8-27B-mxfp4` | mxfp4, gs 32 | ~14 GB | **M5** | Best bare in every cell on both machines (M2 Pro 11.48–11.83, M5 8.45–8.50). **On M5, pair it with the drafter below — +41–98%.** On M2 Pro, run it bare |
| `mlx-community__Qwen3.8-27B-MTP-mxfp4` | mxfp4, gs 32 | ~241 MB | **M5** | Re-downloaded 2026-08-17. Only +11% on general / net loss on code *on M2 Pro*, but **wins every cell on M5** — the drafter is identical, the verify hardware is not |
| `mlx-community__Qwen3.8-27B-nvfp4` | nvfp4, gs 16 | ~15 GB | — | Deleted. Higher peak (14.29) but only *with* a drafter and only on redundant general text; bare it loses to mxfp4 everywhere |
| `mlx-community__Qwen3.8-27B-4bit` | affine, gs 64 | ~15 GB | — | Deleted. Superseded by mxfp4 bare (11.45 vs 11.75); worst under MTP (−22%) |
| `mlx-community__Qwen3.8-27B-MTP-nvfp4` | nvfp4, gs 16 | ~253 MB | — | Deleted with its base model. Was the only drafter worth pairing *on M2 Pro* |
| `mlx-community__Qwen3.8-27B-MTP-bf16` | none | ~829 MB | — | Deleted. 3.4× the size buys no acceptance |
| `mlx-community__Qwen3.8-27B-MTP-4bit` | affine, gs 64 | ~253 MB | — | Deleted. Costs 22% |

**Start from `mxfp4`, not the faster-peaking `nvfp4` pair** — it is the best bare
quantization in every cell on both machines, and on M5 the MTP objection below
does not apply.

*On M2 Pro*, peak throughput needs the drafter, i.e. two checkpoints plus a
settings change, and the MTP peak lands on the workload this model is *least*
wanted for: it is a net loss on code. **On M5 that reverses** — the `mxfp4` +
`MTP-mxfp4` pair wins every cell by 41–98%, code included, so both checkpoints
are worth their disk. The documented `vlm_mtp_enabled` / TurboQuant KV conflict
does not bite on the M5 at all — **neither** model there enables TurboQuant
(`turboquant_kv_bits=None` at load for both this one and Gemma 4).
See [performance.md](./performance.md) and
[benchmarks/m5-qwen38-27b-mxfp4-mtp-20260817.md](./benchmarks/m5-qwen38-27b-mxfp4-mtp-20260817.md).

Restore any of these with `make model-download MODEL_REPO=...`.
Drafters are auto-detected as helpers (`HELPER_CONFIG_MODEL_TYPE_SUFFIXES =
("_assistant", "_mtp")`) and stay hidden from `/v1/models` given
`hide_helper_models: true` — **note the M5 does not set that flag**, so
`Qwen3.8-27B-MTP-mxfp4` is currently listed there and a client could select the
drafter as if it were a chat model.

Never downloaded — excluded by the 32 GB wired limit: `-8bit` (29.53 GB),
`-mxfp8` (28.69 GB), `-bf16` (54.74 GB). Untested: `-OptiQ-4bit`, but see the
OptiQ note below — omlx cannot load the sidecar its speedup depends on.

## Endpoint requirements

### `/v1/embeddings` and `/v1/rerank` need two different models

A reranker is a SequenceClassification model. Pointing `/v1/rerank` at an
embedding model returns HTTP 400 `"is not a reranker model"`. Before 2026-08-01
the M2 Pro had only an embedding model, so `/v1/rerank` was advertised but
unusable for every request.

```bash
make model-download MODEL_REPO=mlx-community/Qwen3-Embedding-4B-4bit-DWQ   # /v1/embeddings
make model-download MODEL_REPO=mlx-community/Qwen3-Reranker-0.6B-4bit      # /v1/rerank
make omlx-restart

curl -s localhost:8000/v1/embeddings -H 'Content-Type: application/json' \
  -d '{"model":"mlx-community__Qwen3-Embedding-4B-4bit-DWQ","input":["你好","world"]}'
curl -s localhost:8000/v1/rerank -H 'Content-Type: application/json' \
  -d '{"model":"mlx-community__Qwen3-Reranker-0.6B-4bit","query":"什么是苹果芯片","documents":["Apple Silicon is an ARM SoC","香蕉是一种水果"]}'
```

### `/v1/audio/speech` has no `default` voice

Valid values: `serena, vivian, uncle_fu, ryan, aiden, ono_anna, sohee, eric, dylan`.
Passing `"default"` returns 500.

### Helper models must be hidden

Set `model.hide_helper_models: true` in `~/.omlx/settings.json` (omlx defaults
it to `false`). Otherwise a downloaded speculative-decoding drafter is
discovered as `type: llm` and **listed in `/v1/models` as a selectable chat
model** — it will fail if a client picks it.

## Context length

All Qwen3.x models support 262,144 tokens with RoPE scaling. The Gemma 4 QAT
model is **also 256k** — `config.json` `text_config.max_position_embeddings=262144`
(an earlier note claimed 128k; that was wrong). omlx respects the model config
and loads this window automatically.

## Staying current

### Checking whether a local snapshot is stale

`make model-download` writes HF metadata under `<model_dir>/.cache/huggingface/`.
The first line of any `*.metadata` file is the commit hash the snapshot came
from, so it can be compared against the repo's current HEAD without
re-downloading anything:

```bash
for d in models/*/; do
  local_rev=$(head -1 "$(find "$d.cache/huggingface" -name '*.metadata' | head -1)" 2>/dev/null)
  repo="mlx-community/$(basename "$d" | sed 's/^mlx-community__//')"
  remote_rev=$(curl -s "https://huggingface.co/api/models/$repo" | python3 -c 'import sys,json;print(json.load(sys.stdin).get("sha",""))')
  [ "$local_rev" = "$remote_rev" ] && echo "current  $repo" || echo "STALE    $repo"
done
```

### Audit 2026-08-16

All six deployed models were at their repo's HEAD; nothing had been re-uploaded
since download.

| Model | Repo last updated |
|---|---|
| `Qwen3.6-35B-A3B-nvfp4` | 2026-04-16 |
| `gemma-4-26B-A4B-it-qat-nvfp4` | 2026-06-05 |
| `Qwen3-Embedding-4B-4bit-DWQ` | 2025-06-07 |
| `Qwen3-Reranker-0.6B-4bit` | 2026-06-06 |
| `Qwen3-ASR-1.7B-8bit` | 2026-01-29 |
| `Qwen3-TTS-12Hz-1.7B-CustomVoice-8bit` | 2026-01-26 |

**No upgrade was taken, and none is available for the main slot.** There is
still no Qwen MoE newer than Qwen3.6 — Qwen3.8-27B is *dense*, not a successor,
and measured 4–5× slower (see [performance.md](./performance.md)). Surveyed and
not taken:

| Candidate | Why not |
|---|---|
| `NVIDIA-Nemotron-3.5-Lightning-30B-A3B-mxfp4` (2026-08-11) | The only same-shape A3B MoE alternative, so plausibly comparable speed — but a different vendor and quality profile. A capability trade, not an upgrade; unbenchmarked here |
| `Qwen3.6-35B-A3B-OptiQ-4bit` (2026-07-14) | Quality-only under omlx. Its speedup rides on the `optiq/mtp.safetensors` sidecar omlx cannot load, so that 1.64 GB is dead weight on top of +1.7 GB of core weights (see the OptiQ note below) |
| `Qwen3-VL-Embedding-8B` / `-2B`, `Qwen3-VL-Reranker-2B` | Newer than the deployed text-only pair, but multimodal retrieval is a *new capability*, not an upgrade. Worth considering given the main model is itself a VLM |
| `nemotron-3.5-asr-streaming-0.6b` (2026-06-05) | Streaming ASR is a genuine advantage, but it is smaller (0.6B vs 1.7B) and the reason Qwen3-ASR was chosen is its Chinese/multilingual quality — would need measuring before switching |

## Model-selection findings

### DiffusionGemma is NOT a newer Gemma 4

It is a separate model built *on* the Gemma 4 26B-A4B architecture
(`model_type: diffusion_gemma`, `DiffusionGemmaForBlockDiffusion`), generating by
discrete diffusion over a 256-token canvas instead of autoregressively. Same
param shape (25.2B/3.8B active), multimodality and 256k context; different
training and quality profile. Its speed claim holds for batch-parallel
datacenter serving, not single-stream on this box.

omlx also **does not expose the diffusion tunables** — `max_denoising_steps`,
`diffusion_sampler`, `diffusion_threshold` exist in
`mlx_vlm/generate/diffusion.py` but nothing in omlx sets them, and editing the
model's `generation_config.json` 48→16 steps changed nothing measurable. The
diffusion lane also force-clears sampling controls, thinking settings, guided
grammar and TurboQuant KV (tool calling survives).

### There is no newer Gemma 4 26B-A4B to move to

Google's family for that shape: `-it` (2026-03-11), `-it-assistant` (2026-04-23),
`-it-qat-q4_0-unquantized` (2026-04-29), `-qat-q4_0-gguf` (2026-05-01),
`-qat-q4_0-unquantized-assistant` (2026-05-29), `diffusiongemma` (2026-06-09).
The deployed `qat-nvfp4` is already on the QAT track; everything else for this
shape is a requantization of the same weights (`qat-OptiQ-4bit`,
`qat-q4_0-mlx-aligned`) — a possible quality nudge, not speed or capability.
No Gemma 5 exists as of 2026-08-01.

### OptiQ is a quality win that omlx can't cash in

`mlx-community/Qwen3.6-35B-A3B-OptiQ-4bit` is a genuinely better *quality* quant
(sensitivity-aware mixed 4/8-bit — 392 layers at 8-bit) but costs **+1.7 GB** of
core weights, and its advertised 1.4× decode rides on an `optiq/mtp.safetensors`
sidecar that **omlx cannot load** — omlx resolves only the *vision* sidecar
(`omlx/engine/vlm.py::_resolve_optiq_vision_sidecar`). Under omlx that 1.64 GB is
dead weight.

Native `mtp_enabled` is also unavailable: no mlx-community Qwen3.6-35B-A3B quant
ships MTP tensors in its index (checked 4bit / DWQ / AntiLoop-NVFP4 / OptiQ —
all 0).
