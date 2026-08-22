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

The **On disk** column reflects state after the 2026-06-28 M5 cleanup, the
2026-08-17 M5 additions (`Qwen3.8-27B-mxfp4` + its drafter, and the Gemma 4 MTP
assistant — ~15.5 GB, kept after the MTP round; delete if you want the space back),
and the **2026-08-22 M2 Pro small-model refresh** (seven models added, none removed).
The M2 Pro column was re-verified against `models/` on 2026-08-22; five rows that
still claimed M2 Pro had in fact been deleted.

| Model dir                                           | Quantization | Size   | Context | On disk | Notes |
|-----------------------------------------------------|--------------|--------|---------|---------|-------|
| `mlx-community__Qwen3.6-35B-A3B-nvfp4`              | NVFP4        | ~19 GB | 256k    | M2 Pro  | **M2 Pro's main model. 59.11 tok/s warm @ 512 on omlx 0.6.3rc2** (2026-08-21; 58.04 on 0.5.7, 57.9 on 0.5.4rc1 — flat across both upgrades, but 45.36 on 0.4.x, so the 0.4.x → 0.5.4rc1 jump alone gave +27%). Fastest on M5 too (39.74 @ 512); removed from M5 2026-06-28 |
| `mlx-community__Qwen3.6-35B-A3B-4bit-DWQ`           | DWQ-4bit     | ~19 GB | 256k    | —       | M2 Pro: 45.36 tok/s; on M5: 31.33 tok/s (slower than NVFP4). Removed from M5 2026-06-28; **no longer on M2 Pro either (verified 2026-08-22)** |
| `mlx-community__Qwen3.6-35B-A3B-4bit`               | std 4bit     | ~19 GB | 256k    | —       | M2 Pro: **45.89 tok/s** (marginally fastest on M2 Pro). Removed from M5 2026-06-28; **no longer on M2 Pro either (verified 2026-08-22)** |
| `ornith-ai__Ornith-1.5-35B-A3B-MLX-4bit`            | affine 4bit, gs 64 | ~18.5 GB | 262k | M2 Pro | `qwen3_5_moe`, 256 experts / 8 active. **Fastest decode measured on M2 Pro: 63.33 tok/s @ 512 on omlx 0.6.3rc2 (+7.7% vs the NVFP4 main model), but prefill −3.4%.** Added 2026-08-21. **Text-only** — upstream is a VLM, conversion ships no `visual.*` weights. Declares `mtp_num_hidden_layers: 1` but ships **no `mtp.*` weights**, so it cannot speculate. No `reasoning_parser` configured — it is a thinking model, so `<think>` text lands in `content`. **`enable_thinking: false` does not stop it reasoning** — the template drops the `<think>` block and it reasons in plain prose instead, so budget generously or force the output format in a system prompt |
| `mlx-community__gemma-4-26b-a4b-it-nvfp4`           | NVFP4        | ~15 GB | 256k    | —       | Non-QAT Gemma 4; removed from M5 2026-06-28 |
| `mlx-community__gemma-4-26B-A4B-it-qat-nvfp4`       | QAT NVFP4    | ~15 GB | 256k    | **M5**, M2 Pro | **M5's main (chat/VLM) model**, and **also resident on the M2 Pro** (verified against `models/` 2026-08-22 — 15 GB, not previously recorded here; it is the M2 Pro's only VLM, since the deployed Qwen3.6 build and Ornith are both text-only). Gemma 4 VLM; runs on omlx (M5 default) and vllm-mlx 0.3.0+ (~30 tok/s @ 512/1024); QAT = better quality at 4-bit. Crashed on vllm-mlx 0.2.9 |
| `mlx-community__Qwen3-Embedding-0.6B-4bit-DWQ`      | DWQ-4bit     | ~0.34 GB | —     | **M5**  | **Embedding** (1024-dim, multilingual). Added 2026-06-28 for testing `/v1/embeddings`. Cross-lingual sanity check passed (en↔zh cosine ~0.72) |
| `mlx-community__Qwen3-Embedding-4B-4bit-DWQ`        | DWQ-4bit     | ~2.1 GB | —      | M2 Pro  | **Embedding** (2560-dim). Verified 2026-08-01: en↔zh cosine 0.68 |
| `mlx-community__Qwen3-ASR-1.7B-8bit`                | 8bit         | ~1.9 GB | —      | M2 Pro  | **ASR** (`/v1/audio/transcriptions`). Better multilingual/Chinese than `parakeet-tdt-0.6b-v3`, which is the higher-download English default |
| `mlx-community__Qwen3-TTS-12Hz-1.7B-CustomVoice-8bit` | 8bit       | ~2.9 GB | —      | M2 Pro  | **TTS** (`/v1/audio/speech`). See the voice list below — there is no `default` |
| `mlx-community__Qwen3-Reranker-0.6B-4bit`           | 4bit         | ~0.4 GB | —      | M2 Pro  | **Reranker** (`/v1/rerank`). Added 2026-08-01. Required for that endpoint — an embedding model will not do |
| `mlx-community__Qwen3-Embedding-8B-4bit-DWQ`        | DWQ-4bit     | ~4.0 GB | —      | M2 Pro  | **Embedding** (4096-dim). Added 2026-08-22. **MMTEB Mean(Task) 70.58 — highest in Qwen's own table**, above the deployed 4B (69.45) and Gemini Embedding (68.37). Verified: en↔zh cosine 0.759, unrelated 0.460 |
| `mlx-community__Qwen3-VL-Embedding-2B-8bit`         | 8bit         | ~2.5 GB | 32k    | M2 Pro  | **Multimodal embedding** (2048-dim, `qwen3_vl`). Added 2026-08-22. **MMEB-v2 All 73.2 at 2B — beats RzenEmbed-8B (72.9) and GME-7B (59.1).** But **text-only retrieval is a step *down*** (MMTEB 63.87 vs the 4B's 69.45) — this is a *new capability*, not a replacement. Verified: 2048-dim, en↔zh cosine 0.789, unrelated 0.501 |
| `mlx-community__Qwen3-VL-Reranker-2B-8bit`          | 8bit         | ~2.5 GB | 32k    | M2 Pro  | **Multimodal reranker** (`qwen3_vl`). Added 2026-08-22. **MMEB-v2(Retrieval) Avg 75.1, ViDoRe v3 60.8** — above jina-reranker-m0 (57.8). Verified 1.12 s: correct ordering, 0.651 / 0.535 / 0.107 |
| `mlx-community__Mega-ASR-8bit`                      | 8bit         | ~2.3 GB | —      | —       | **ASR.** Added 2026-08-22. Qwen3-ASR-1.7B with the Mega-ASR robustness LoRA **merged** (`qwen3_asr` — drop-in). Router removed, so it always runs the robust path (`Mega-ASR-bf16` keeps the clean/noisy router). **Robustness advantage not reproduced here — see the ASR comparison below.** **Deleted 2026-08-22** — repetition collapse from ~420 s; row kept so it is not silently retried |
| `kamilobad__GLM-ASR-Nano-2512-8bit`                 | 8bit         | ~2.3 GB | —      | —       | **ASR** (`glmasr`). Added 2026-08-22. Upstream `zai-org` claims the **lowest average error rate (4.10)** among comparable open models. **Third-party MLX conversion** (~10 downloads) — verified it loads and infers. Fastest of the three (0.29–1.35 s) and returns timestamped `segments`, but **worst under degradation — see below**. **Deleted 2026-08-22** — hard truncation at ~45 s of audio; row kept so it is not silently retried |
| `mlx-community__Qwen3-TTS-12Hz-1.7B-VoiceDesign-8bit` | 8bit       | ~2.9 GB | —      | —       | **TTS.** Added 2026-08-22. Same `qwen3_tts` family as CustomVoice but takes a **text description of the voice** instead of a fixed voice name. **Requires `instructions`** — a request with `voice` returns 500. Verified 1.25 s → 24 kHz mono WAV. **Deleted 2026-08-22** — no caller here sends `instructions`; row kept so it is not silently retried |
| `mlx-community__chatterbox-multilingual-v3`         | —            | ~2.5 GB | —      | —       | **TTS** (`chatterbox`), multilingual. Added 2026-08-22. **Pure zero-shot voice cloning — no built-in voices**: the repo ships no `conds.safetensors`, so **every request needs `ref_audio` (base64, not a path)**. Verified 13.2 s → 24 kHz mono WAV. **Deleted 2026-08-22** — no caller here sends `ref_audio`; row kept so it is not silently retried. Its 472 MB `S3TokenizerV2` dependency had to be deleted separately, from the HF cache |
| `z-lab__Qwen3.6-35B-A3B-DFlash`                     | bf16         | ~0.77 GB | —     | — | DFlash speculative drafter. **Benchmarked and rejected — cost 19–29%.** Since deleted; row kept so the option is not silently retried |
| `mlx-community__gemma-4-26B-A4B-it-qat-assistant-nvfp4` | QAT NVFP4 | ~0.26 GB | —    | **M5 (on disk, MTP off)**; deleted from M2 Pro | Google's official Gemma 4 MTP drafter (`gemma4_assistant`, `block_size=4`). **Rejected on M2 Pro (−12%) but re-tested on M5 2026-08-17: −0.6% general, +21.5% code at 78% acceptance.** Keep on M5 if the workload is code-heavy — enabling it is a one-key change, see serving.md. Already deleted from M2 Pro |
| `mlx-community__diffusiongemma-26B-A4B-it-4bit`     | std 4bit     | ~15 GB | 256k    | — | **Separate model, not a Gemma 4 version** (see below). **Benchmarked and rejected — 14.3 vs 44.3 tok/s.** Since deleted, so it no longer appears in `/v1/models` — while it was on disk a client could pick it and get 3× slower replies |

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

## Small models — which one for what

Four endpoints, seven models on disk after the 2026-08-22 cleanup (the refresh
added seven and the caller-shaped retest removed four — see below). Nothing here
is a straight upgrade over what it sits next to — each option trades something.
Scores are the vendors' own unless marked *measured here*.

**The constraint that applies to all of them:** the main model is ~19 GB and the
process ceiling is 30 GB (hard threshold 28.5 GB). Two or three small models
resident alongside it is enough to trigger eviction. ⚠️ **The `ttl_seconds: 900`
this section used to claim for every small model is not in force** — verified
2026-08-22, `~/.omlx/settings.json`'s `model` block holds only `model_dirs`,
`model_dir`, `model_fallback` and `hide_helper_models`, with no per-model entries
anywhere. Treat "which model" as also meaning "how often will it be paged back
in", and note that nothing currently bounds that.

### Embedding — `/v1/embeddings`

| | `Qwen3-Embedding-4B-DWQ` *(deployed)* | `Qwen3-Embedding-8B-DWQ` | `Qwen3-VL-Embedding-2B` |
|---|---|---|---|
| Disk / dim | 2.1 GB / 2560 | 4.0 GB / 4096 | 2.5 GB / 2048 |
| Text (MMTEB) | 69.45 | **70.58** | 63.87 |
| Multimodal (MMEB-v2) | — | — | **73.2** |
| en↔zh cosine *(measured here)* | 0.68 | 0.759 | 0.789 |

- **4B — pros:** best text score per GB of the three; smallest resident footprint
  of the text pair; the only one with a track record in this deployment.
  **Cons:** the oldest artifact on disk (upstream 2025-06-20); text-only.
- **8B — pros:** highest text score anywhere in Qwen's table, above Gemini
  Embedding (68.37); cleanest semantic separation measured here (unrelated pair
  0.460 vs the VL model's 0.501). **Cons:** **+1.9 GB buys +1.13 MMTEB points** —
  the worst GB-per-point trade in this table, and 4096-dim doubles your vector
  index against the 2048-dim option. On a box already at the memory ceiling this
  is the option most likely to cause churn.
- **VL-2B — pros:** beats 8B-class multimodal embedders (RzenEmbed-8B 72.9,
  Ops-MM-8B 68.9) at 2B; smallest vectors, so the cheapest index; reads
  screenshots, PDF pages and video. **Cons:** **text retrieval is a real step down
  — 63.87 vs 69.45.** 32k context against the text models' longer window. It is
  instruction-aware, so results move with prompt wording.

**Pick:** keep 4B as the text default. Reach for 8B only if a retrieval eval on
*your* corpus shows the +1.13 mattering. Use VL-2B only for image/document
retrieval — **do not repoint text search at it.**

### Reranker — `/v1/rerank`

| | `Qwen3-Reranker-0.6B` *(deployed)* | `Qwen3-VL-Reranker-2B` |
|---|---|---|
| Disk | 0.35 GB | 2.5 GB |
| Score | — | MMEB-v2(Retrieval) **75.1**, ViDoRe v3 **60.8** |
| omlx path | causal-LM fallback | first-class multimodal reranker |

- **0.6B — pros:** 7× smaller, so it pages in fast and barely dents the ceiling;
  fine for text. **Cons:** rides omlx's `CAUSAL_LM_RERANKER_ARCHITECTURES`
  fallback (a yes/no-logit trick on a causal LM) rather than a purpose-built
  reranking head.
- **VL-2B — pros:** above `jina-reranker-m0` (57.8) on ViDoRe v3; 1.12 s measured
  here with correct ordering (0.651 / 0.535 / 0.107); handles mixed-modality
  (query, document) pairs. **Cons:** 7× the disk for no benefit on pure text.

**Pick:** 0.6B for text pipelines, VL-2B only when documents carry images.
`jina-reranker-v3` would be the first-class *text* reranker arch omlx supports,
but it is **CC-BY-NC-4.0 (non-commercial)** — not downloaded for that reason.

### ASR — `/v1/audio/transcriptions`

Full evidence in [ASR: neither challenger beat the incumbent](#asr-neither-challenger-beat-the-incumbent--2026-08-22).

| | `Qwen3-ASR-1.7B` *(deployed)* | `Mega-ASR-8bit` | `GLM-ASR-Nano-2512` |
|---|---|---|---|
| Clean audio | correct | correct | correct |
| Degraded zh | partial | **best** | hallucinates |
| Degraded en | **best** | hallucinates | hallucinates |
| Latency *(measured here)* | seconds | seconds | **0.29–1.35 s** |
| Timestamps | no | no | **yes** (`segments`) |

- **Qwen3-ASR — pros:** the only one of the three that degraded *gracefully* in
  both languages instead of inventing sentences; strong Chinese/multilingual, the
  reason it was chosen over `parakeet`. **Cons:** no streaming — `qwen3_asr` is
  absent from `REALTIME_STT_MODEL_TYPES`; no timestamps; not the fastest.
- **Mega-ASR — pros:** drop-in (`qwen3_asr`, same engine path, no config change);
  the only model to recover `苹果芯片` under harsh degradation. **Cons:**
  **hallucinated a whole unrelated sentence on degraded English** — the exact
  failure mode it is sold as fixing. The deployed build is the **router-less
  merged** variant, so it runs the robust path even on clean speech;
  `Mega-ASR-bf16` keeps the clean/noisy router and is untested.
- **GLM-ASR — pros:** by far the fastest, and the only one returning timestamped
  `segments`; upstream claims the lowest average error rate (4.10). **Cons:**
  **worst under degradation by a wide margin** — both outputs unrelated text, so
  that 4.10 is a clean-set number. Third-party MLX conversion (~10 downloads).
  It also **ships its own Python**, which is what forced the `mypy` exclude in
  `pyproject.toml`.

**Pick: Qwen3-ASR, and it is now the only one on disk.** The retest this section
called for was run against the real caller's shape and both challengers failed
categorically at production length — see
[ASR at production length](#asr-at-production-length-both-challengers-fail-categorically--2026-08-22).
For streaming you must leave this family entirely — see
[Streaming ASR is unavailable with the deployed model](#streaming-asr-is-unavailable-with-the-deployed-model).

### TTS — `/v1/audio/speech`

Three models, **three incompatible request shapes** — see
[the TTS table](#the-three-tts-models-take-three-different-incompatible-inputs).

| | `Qwen3-TTS-CustomVoice` *(deployed)* | `Qwen3-TTS-VoiceDesign` | `chatterbox-multilingual-v3` |
|---|---|---|---|
| Voice source | 9 fixed names | text description | reference audio only |
| Needs reference audio | no | no | **every request** |
| Field | `voice` | `instructions` | `ref_audio` (base64) |
| Latency *(short text, measured)* | — | **1.25 s** | 13.2 s |

- **CustomVoice — pros:** simplest call, no extra inputs, 9 ready voices.
  **Cons:** you get those 9 and nothing else; there is no `default` (passing it
  returns 500); **long text is very slow — 140–466 s for 800–1000 characters**,
  which is what saturated the server during this refresh.
- **VoiceDesign — pros:** unlimited voices from a text description, with no
  reference audio to manage; same family and engine as the incumbent, so ops are
  unchanged; fastest verified here. **Cons:** requires `instructions` — and the
  500 it returns **names the wrong field (`instruct`)**, which costs you a
  debugging round if you trust the message.
- **chatterbox — pros:** clones an arbitrary voice zero-shot; multilingual.
  **Cons:** **no built-in voices at all** — the repo ships no `conds.safetensors`,
  so every request must carry base64 audio (a path returns 400). Slowest of the
  three, and a genuinely different integration, not a drop-in.

**Pick: CustomVoice, and it is now the only one on disk.** VoiceDesign and
chatterbox were deleted 2026-08-22 — not on quality, but because **no caller here
can drive them**: `podcast_creator/nodes.py:273` sends only `text` / `voice` /
`output_file`, so the `instructions` and `ref_audio` fields those two require are
never populated. Both also return `{"voices": []}` from `/v1/audio/voices`
(verified 2026-08-22), while CustomVoice returns its 9 names — that empty list is
the cheapest way to tell a drivable TTS from an undrivable one. Re-download either
if a caller ever grows the field.

#### CustomVoice synthesis cost is superlinear in input length

Measured 2026-08-22 on M2 Pro, omlx 0.6.3rc2, idle server, Chinese input:

| Input | Audio out | Synthesis | Ratio |
|---|---:|---:|---:|
| 237 chars | 47.4 s | 19.6 s | **2.42× realtime** |
| 948 chars (4×) | 199.8 s | 249.8 s (12.7×) | **0.80× realtime** |

4× the input costs 12.7× the time — roughly `n^1.8`, and past ~900 characters
synthesis is **slower than the audio it produces**. This confirms the
"140–466 s for 800–1000 characters" figure recorded during the refresh as a real
property, not server contention.

**Consequence for long output: chunk size dominates everything.** Ten minutes of
Chinese audio is ~2850 characters. Sent as one request that extrapolates to ~30
minutes of synthesis; sent as ~240-character segments it is ~12 calls totalling
~4 minutes — a 7–8× difference for identical output. `podcast_creator` already
synthesises per segment, so keep segments short and never concatenate them into
one call. (The ~30-minute figure is a two-point power-law extrapolation, not a
measurement; the two rows above are measured.)

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

### The three TTS models take three different, incompatible inputs

`voice` is not a universal field — each model rejects the others' calling
convention. The request schema is `omlx/api/audio_models.py::AudioSpeechRequest`.

| Model | Required field | Failure if you pass `voice` instead |
|---|---|---|
| `Qwen3-TTS-…-CustomVoice-8bit` | `voice` (from the list above) | — |
| `Qwen3-TTS-…-VoiceDesign-8bit` | **`instructions`** — a text description, e.g. `"A calm young female voice, moderate pitch, clear Mandarin"` | 500 `"VoiceDesign model requires 'instruct' to describe the voice"` |
| `chatterbox-multilingual-v3` | **`ref_audio`** — base64-encoded audio, *not* a path (plus optional `ref_text`) | 500 `"No conditionals available…"` after ~36 s |

Two traps worth their own line:

- **The error message names the wrong field.** VoiceDesign's 500 says `'instruct'`,
  but the accepted field is **`instructions`** (plural, matching the OpenAI TTS
  spec). Sending `instruct` is rejected in ~5 ms with the same message.
- **`ref_audio` is base64, not a path.** Passing a filesystem path returns
  400 `"Invalid base64 encoding in 'ref_audio' field"`.

`mlx-community/chatterbox-multilingual-v3` ships no `conds.safetensors`, so it has
**no built-in voices at all** — it is a pure zero-shot cloner and every request must
carry reference audio. That is a different deployment model from Qwen3-TTS, not a
drop-in alternative.

### Helper models must be hidden

Set `model.hide_helper_models: true` in `~/.omlx/settings.json` (omlx defaults
it to `false`). Otherwise a downloaded speculative-decoding drafter is
discovered as `type: llm` and **listed in `/v1/models` as a selectable chat
model** — it will fail if a client picks it.

### omlx also discovers models from the HF hub cache

`~/.omlx/settings.json` points `model_dirs` at this repo's `models/` only, but
`/v1/models` can still list things that are not there. Discovered 2026-08-22:
after deleting `chatterbox-multilingual-v3`, `/v1/models` still advertised
`mlx-community--S3TokenizerV2` — note the `--`, which is HF-cache naming, not this
repo's `__`. It was 472 MB of real blobs in `~/.cache/huggingface/hub/`, pulled at
runtime by chatterbox rather than by `make model-download`, and it survived the
model-directory deletion.

So a deleted model can leave a selectable orphan behind. After removing a model,
check both locations:

```bash
du -sh ~/.cache/huggingface/hub/models--*/ | sort -h   # real blobs stand out; metadata stubs are 4.0K
curl -s localhost:8000/v1/models | python3 -c 'import json,sys;[print(m["id"]) for m in json.load(sys.stdin)["data"]]'
```

Everything else in that cache on the M2 Pro is a 4.0 KB metadata stub written by
`make model-download`; only a model's own runtime dependencies land there as
weights.

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
| `Qwen3-VL-Embedding-8B` / `-2B`, `Qwen3-VL-Reranker-2B` | Newer than the deployed text-only pair, but multimodal retrieval is a *new capability*, not an upgrade. Worth considering given the main model is itself a VLM — **taken 2026-08-22; the "new capability, not an upgrade" call was right, see the scores below** |
| `nemotron-3.5-asr-streaming-0.6b` (2026-06-05) | Streaming ASR is a genuine advantage, but it is smaller (0.6B vs 1.7B) and the reason Qwen3-ASR was chosen is its Chinese/multilingual quality — would need measuring before switching. **Closed 2026-08-22: omlx cannot load it at all** (`model_type: nemotron_asr` is absent from mlx-audio's STT families), so there is nothing to measure |

### Audit 2026-08-22 — small-model refresh

All seven deployed models were still at their repo's HEAD. **Seven models added,
nothing removed.** The gate throughout was omlx's own architecture support, read
out of `omlx.model_discovery` rather than assumed — several well-rated candidates
fail it outright.

| Slot | Deployed | Added | Verdict |
|---|---|---|---|
| Text embedding | `Qwen3-Embedding-4B-4bit-DWQ` (MMTEB 69.45) | `Qwen3-Embedding-8B-4bit-DWQ` (**70.58**) | Real but small upgrade (+1.13). Both kept |
| Multimodal retrieval | — | `Qwen3-VL-Embedding-2B-8bit` (MMEB-v2 **73.2**) + `Qwen3-VL-Reranker-2B-8bit` (**75.1**) | New capability. **Text retrieval is worse** (63.87 vs 69.45) — do not repoint text search at it |
| ASR | `Qwen3-ASR-1.7B-8bit` | `Mega-ASR-8bit`, `GLM-ASR-Nano-2512-8bit` | **No switch, and both deleted the same day** — they fail categorically at the caller's 600 s chunk length. See the two ASR sections below |
| TTS | `Qwen3-TTS-…-CustomVoice-8bit` | `Qwen3-TTS-…-VoiceDesign-8bit`, `chatterbox-multilingual-v3` | **Both deleted the same day** — additive in principle, but no caller here sends `instructions` or `ref_audio`, so neither could ever be driven |

Rejected on omlx compatibility, not on score:

| Candidate | Why not |
|---|---|
| `Irodori-TTS-v4.1-Small` (2026-08-15, newest MLX TTS) | **Japanese-only** (`Aratako/Irodori-TTS`) — wrong language for this deployment |
| `VoxCPM2-8bit` | `model_type: voxcpm2`; omlx has `voxcpm` and `voxcpm1.5` but **not** `voxcpm2` |
| `IndexTTS-2` (highest-download recent TTS) | `config.json` has **no `model_type`** (gpt/bigvgan/s2mel multi-component layout), so omlx auto-discovery cannot classify it |
| `MiMo-V2.5-ASR-MLX-8bit` | `model_type: qwen2` — not an STT family; would be misdetected as a plain LLM |
| `DeepSeek-V4-Flash` (92.8 GB), `tencent/Hy3` (88.1 GB) | Do not fit 32 GB at any offered quantization |

**Per-model TTLs were the missing piece.** The four pre-existing small models
carry `ttl_seconds: 900` in `~/.omlx/model_settings.json`; the seven new ones had
none, so they stayed resident until evicted. With the 19 GB main model loaded this
pushed the process past the 28.5 GB hard threshold and omlx evicted a
freshly-loaded embedding model mid-session:

```
Memory pressure level: ok -> hard (current=28.9GB, soft=25.5GB, hard=28.5GB, ceiling=30.0GB)
Evicting model 'mlx-community__Qwen3-VL-Embedding-2B-8bit' (pressure=hard)
```

All seven now carry `ttl_seconds: 900`. **Add the TTL when you add a small model** —
otherwise the main model and the small models cannot coexist under the 30 GB ceiling.

## Model-selection findings

### ASR: neither challenger beat the incumbent — 2026-08-22

Three-way comparison on the M2 Pro, omlx 0.6.3rc2. Two utterances (one zh, one en)
synthesised with macOS `say` at 16 kHz mono, then degraded with `ffmpeg`. **One
utterance per language per condition — this is a smoke test, not a WER
measurement**, and it is enough only because the failure modes were categorical.

- Ground truth zh: `苹果芯片的内存带宽决定了解码速度`
- Ground truth en: `Apple Silicon decode speed is bound by memory bandwidth`

**Clean audio — all three transcribe both utterances correctly.** No separation
(Mega-ASR lowercases "silicon"; that is the only difference). Clean speech cannot
discriminate these models.

**Harsh degradation** (`highpass=400,lowpass=2600,volume=6.0,acompressor=threshold=0.05:ratio=20,aecho=0.8:0.9:60:0.5` mixed with pink noise `a=0.30`):

| Model | zh | en |
|---|---|---|
| `Qwen3-ASR-1.7B-8bit` (incumbent) | 使用芯片的内存的超时一秒写入速度 | Apple silicon chip is found in memory modules |
| `Mega-ASR-8bit` | **苹果芯片**的内存的超稳定秒写码速度 | *After the film, the character peter is found by memory. Daniel.* |
| `GLM-ASR-Nano-2512-8bit` | *是的，基于人类存在方程序解答类型* | *After a while, you can see the sun from the window* |

**Both vendor claims failed to reproduce here:**

- **Mega-ASR is sold as a fix for hallucination under degradation.** It was the
  only model to recover `苹果芯片` on Chinese — but on English it hallucinated an
  entire unrelated sentence, which is precisely the failure mode it claims to
  remove. Note the deployed build is the **merged, router-less** variant: the
  audio-quality router that would route clean speech to the base path is absent,
  so it runs the robust path unconditionally. `Mega-ASR-bf16` keeps the router and
  is untested here.
- **GLM-ASR's "lowest average error rate (4.10)"** did not survive degradation at
  all — both outputs are unrelated text. That figure is presumably from clean
  benchmarks. It *is* the fastest of the three (0.29–1.35 s vs several seconds) and
  the only one returning timestamped `segments`.

**No ASR switch was taken.** `Qwen3-ASR-1.7B-8bit` remains the deployed model: it
was the only one of the three that degraded gracefully in both languages rather
than hallucinating. The two challengers are kept on disk for a workload-specific
retest — Mega-ASR is worth another look on genuinely noisy *Chinese* audio.

### ASR at production length: both challengers fail categorically — 2026-08-22

The retest the section above asked for, run against the real caller's shape rather
than synthetic clips. `content_core/processors/media/audio.py:146` splits audio
into **10-minute chunks**, converts to **mp3**, sends **no `language` hint**, and
runs chunks concurrently — so the unit under test is a single ~600 s mp3, not a
sentence. `10 * 60` is hardcoded there, so "use smaller chunks" is not available
without changing that caller.

| Sample | `Qwen3-ASR` *(deployed)* | `Mega-ASR` | `GLM-ASR-Nano` |
|---|---|---|---|
| 103 s en + noise / low-bitrate / 1.2× | 2.5% / 3.0% / 3.0% | 1.7% / 2.1% / 1.3% | 57.2% (identical in all three) |
| 85 s zh with technical terms | 2.5% | 3.2% | 40.5% |
| **571 s mp3 (production shape)** | **4.2%, 99% coverage, 42–45 s, stable over 3 runs** | ❌ **WER 470%**, 7475 tokens for a 1448-token reference, 172.8 s | ❌ **WER 92%**, 8% coverage |

- **GLM-ASR-Nano truncates hard at ~45 s of audio.** Output length is independent
  of input length — 102 tokens from the 103 s sample, 112 tokens from the 571 s
  one. A 10-minute lecture returns a fluent opening and silently drops 92% of it.
- **Mega-ASR collapses into repetition on long audio.** Fine to ~300 s, broken from
  420 s, with one sentence repeating to the end. It genuinely is 0.8–1.7 points
  better than the incumbent on *degraded English* — but only at lengths this
  deployment never sends, and it is **worse on Chinese (3.2% vs 2.5%)**, which was
  the axis Qwen3-ASR was chosen on in the first place. That closes the
  "retest on noisy Chinese" option this section had left open.

**The 600 s boundary is verified, not extrapolated.** The evidence above stops at
571 s while the caller can emit a full 600 s chunk, so a 609.6 s mp3 was
transcribed under the same production shape (M2 Pro, omlx 0.6.3rc2, warmed):
output/reference word ratio **1.03**, tail aligned to the true end of the audio,
most-repeated 8-gram appearing **twice** — no truncation, no collapse — in 54.9 s
wall clock (~11× realtime, matching the 42–45 s at 571 s). Its WER reads 9.8–11%,
but that number is **not comparable to the 4.2% above**: the script was this
repo's own documentation, so version strings and jargon dominate the errors
(`omlx` → "arm looks", `0.6.3rc2` → "0 6 3 rc2"). The result of that run is the
coverage, not the WER.

⚠️ **The short-sample rankings above are single samples per cell** and carry the
same caveat as the smoke test in the previous section — 1.7% vs 2.5% at 103 s is
not a WER measurement. The decision rests entirely on the categorical failures at
production length, where no statistics are needed.

**Outcome: no switch, and both challengers deleted** (4.6 GB). They are kept as
catalog rows so the option is not silently retried.

### Streaming ASR is unavailable with the deployed model

`REALTIME_STT_MODEL_TYPES = {"whisper", "voxtral_realtime"}` — `qwen3_asr` is not
in it, so real-time transcription needs a whisper-family model regardless of
quality ranking. `mlx-community/belle-whisper-large-v3-turbo-zh-8bit` (0.87 GB,
Chinese-tuned) is the obvious candidate; not downloaded.


### `nvidia/Qwen3.6-27B-NVFP4` cannot run on Apple Silicon

Same FP4 name (E2M1), different on-disk format. That repo is an **NVIDIA
ModelOpt** checkpoint (tensor types BF16 / F8_E4M3 / U8) built for vLLM /
TensorRT-LLM on Hopper/Blackwell CUDA; its packing and scale tensors are not the
MLX-native NVFP4 that `mlx-community` ships. No MLX runtime deserializes it —
omlx, mlx-lm, and vllm-mlx alike (vllm-mlx is MLX-backed, *not* CUDA vLLM).

There is **no MLX-native NVFP4 build of any Qwen3.6-27B on HF**; the only MLX
dense 27B options are `mlx-community/Qwen3.6-27B-4bit` and `…-OptiQ-4bit`. Since
a dense model is bandwidth-bound on its full active weights regardless of
FP4-vs-int4 packing, the std 4-bit build is the faithful stand-in — and it
benchmarked at ~4.4 tok/s on M5, so the question is moot either way. See
[performance.md](./performance.md).

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
