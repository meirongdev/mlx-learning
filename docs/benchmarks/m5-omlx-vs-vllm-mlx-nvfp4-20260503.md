# omlx vs vllm-mlx — M5 single-stream comparison

**Date:** 2026-05-03
**Host:** M5 MacBook Pro, 32 GB, 153 GB/s, GPU wired limit 26000 MB
**Models tested:**
- `mlx-community/Qwen3.6-35B-A3B-nvfp4` (NVFP4 MoE, ~19 GB, 256k ctx) — text LLM
- `mlx-community/gemma-4-26b-a4b-it-nvfp4` (NVFP4, ~15 GB, 128k ctx) — VLM
**Workload:** single user, single stream, `mlx-bench` CLI hitting `/v1/chat/completions`
**Prompt:** "Write a 200-word introduction to quantum computing for a 10-year-old."

## Server configurations (matched as closely as possible)

| omlx flag | vllm-mlx equivalent |
|---|---|
| `--max-process-memory 90%` | `--gpu-memory-utilization 0.90` |
| `--hot-cache-max-size 4GB` | `--cache-memory-mb 4096` |
| `--max-concurrent-requests 2` | `--max-num-seqs 2` |
| `--initial-cache-blocks 1024` | `--use-paged-cache --max-cache-blocks 1024` |

vllm-mlx version: `0.2.9` (PyPI). omlx version: current Homebrew tap.
vllm-mlx `--continuous-batching` left **off** for apples-to-apples single-stream.

## Results — Qwen3.6-35B-A3B (text LLM)

| Run | omlx (tok/s) | vllm-mlx (tok/s) | Δ |
|---|---:|---:|---:|
| 512 tok, cold-warm | 46.29 | **51.09** | +10.4% |
| 1024 tok, cold-warm | 49.74 | **52.25** | +5.0% |
| 1024 tok, warm | 48.67 | **51.73** | +6.3% |

**vllm-mlx wins all three on single-stream decode.** Margin tightens as the run gets warmer (cache + JIT settling), suggesting the win is more about start-up / paged-cache scheduling than steady-state kernel efficiency. Both servers are bandwidth-bound near the same ceiling (~52 tok/s on this M5).

## Results — Gemma 4 26B (VLM) — vllm-mlx BROKEN

| Run | omlx (tok/s) | vllm-mlx (tok/s) | Δ |
|---|---:|---:|---:|
| 512 tok, cold-warm | 38.27 | ❌ crashes | — |
| 1024 tok, warm | 38.41 | ❌ crashes | — |

**vllm-mlx 0.2.9 cannot serve Gemma 4 26B on this host.** Both `--mllm` flag and auto-detected MLLM mode fail with:

```
RuntimeError: There is no Stream(gpu, 0) in current thread.
  at mlx_vlm/generate.py:553 in mx.async_eval(y)
```

This is an MLX threading bug in `mlx_vlm` (vllm-mlx's MLLM runtime depends on it): generation happens on a worker thread that never had an MLX GPU stream attached. Streaming mode does not crash but returns an empty completion (no content tokens). The same bug presumably affects every `Gemma4ForConditionalGeneration` model in 0.2.9.

Tried as workarounds — none fixed it:
- Without `--mllm` flag (vllm-mlx auto-detects VLM and routes through MLLM anyway).
- `stream: true` (returns `[DONE]` with empty delta — silent failure).

**Cannot test the standard 4-bit Gemma 4** in `models/mlx-community__gemma-4-26b-a4b-it-4bit/` either — only `model.safetensors.index.json` is present, the actual weight shards were never downloaded. (`model-00001-of-00002.safetensors` etc. are missing.)

For Gemma 4 26B on this host, **omlx is the only working option right now.** Once vllm-mlx upstream fixes the `mlx_vlm` thread-stream bug it would be worth re-testing — Gemma 4 has heavy KV cache (128k ctx) so vllm-mlx's `--kv-cache-quantization` could matter.

## Observations

- **Stable output**: vllm-mlx generated coherent Qwen3 thinking-mode output identical in structure to omlx — no quality regression.
- **Load time**: vllm-mlx cold load felt comparable to omlx (~20s for the 19 GB NVFP4 weights); both cache the model in unified memory after first load.
- **Endpoint compat**: `/v1/chat/completions` and `/v1/models` work identically. vllm-mlx returns `owned_by: vllm-mlx`. The `mlx-bench` CLI (built for omlx) ran unmodified — only `--no-unload` is needed because vllm-mlx doesn't expose the per-model unload hook omlx provides.
- **Process footprint**: vllm-mlx pulls in PyTorch + transformers (heavier install: ~2.5 GB tool venv) vs omlx's leaner Homebrew binary.
- **What was NOT tested** (but could change the verdict):
  - `--continuous-batching` under multi-client load (vllm-mlx's headline feature, omlx has no equivalent).
  - `--enable-mtp` / `--specprefill` (speculative decoding).
  - Long-context prefill (`--chunked-prefill-tokens`).
  - KV cache quantization (`--kv-cache-quantization`).

## Verdict for this repo

| Model class | Recommendation |
|---|---|
| Text LLM (Qwen3.6, etc.) | vllm-mlx is **5–10% faster** but omlx is operationally simpler. Either is fine. |
| VLM (Gemma 4, etc.) | **Use omlx — vllm-mlx 0.2.9 is broken on Gemma 4.** |

For the current single-user benchmark workload on text LLMs, vllm-mlx's 5–10% win is measurable but not transformative. omlx is still well-tuned and operationally simpler (Homebrew service, smaller deps). **Switching the repo default is not justified by these numbers alone.**

**Worth re-evaluating vllm-mlx if:**
- Multi-client / agentic workloads where continuous batching kicks in.
- Tool-calling / reasoning parsers needed (vllm-mlx ships parsers for Qwen3, deepseek_r1, hermes, etc.).
- KV-cache pressure hits (vllm-mlx has built-in q8 KV quantization).
- Upstream fixes the `mlx_vlm` Stream-on-worker-thread bug → re-test Gemma 4.

For now: **keep omlx as default; pin vllm-mlx as a known-faster alternative for Qwen-class text LLMs only.**

## Raw logs

Qwen3.6-35B-A3B NVFP4:
- `omlx-baseline-nvfp4-512-20260503-022242.log` — 46.29 tok/s
- `omlx-baseline-nvfp4-1024-coldwarm-20260503-022338.log` — 49.74 tok/s
- `omlx-baseline-nvfp4-1024-warm-20260503-022422.log` — 48.67 tok/s
- `vllm-mlx-nvfp4-512-coldwarm-20260503-022902.log` — 51.09 tok/s
- `vllm-mlx-nvfp4-1024-warm1-20260503-022922.log` — 52.25 tok/s
- `vllm-mlx-nvfp4-1024-warm2-20260503-022948.log` — 51.73 tok/s

Gemma 4 26B NVFP4:
- `omlx-gemma4-nvfp4-512-*.log` — 38.27 tok/s
- `omlx-gemma4-nvfp4-1024-warm-*.log` — 38.41 tok/s
- `vllm-mlx-gemma4.log` (server log) — captures `RuntimeError: There is no Stream(gpu, 0)` traceback
