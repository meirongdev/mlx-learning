Machine: Apple M5, 32 GB, 153 GB/s
Date: 2026-06-30
Tool: mlx-bench (omlx sequential benchmark)
Model: mlx-community/Qwen3.6-27B-4bit  (slug: mlx-community__Qwen3.6-27B-4bit)
Prompt: "Write a 200-word introduction to quantum computing for a 10-year-old."
Server: omlx 0.4.4

## Why this model and not nvidia/Qwen3.6-27B-NVFP4

The original request was to bench `nvidia/Qwen3.6-27B-NVFP4` on M5. **That repo cannot run on
Apple Silicon.** It is quantized with **NVIDIA ModelOpt** (tensor types BF16 / F8_E4M3 / U8) and
is built for **vLLM / TensorRT-LLM on NVIDIA Hopper/Blackwell GPUs (Linux/CUDA)**. "NVFP4" there
is a different on-disk format from the MLX-native NVFP4 that `mlx-community` ships — same FP4 name
(E2M1), incompatible packing/scale tensors. No MLX runtime (omlx, mlx-lm, or vllm-mlx — which is
MLX-backed, *not* CUDA vLLM) can deserialize a ModelOpt checkpoint.

A search of HF found **no MLX-native NVFP4 build of any Qwen3.6-27B**. The only MLX-format dense
27B options are `mlx-community/Qwen3.6-27B-4bit` (std affine 4-bit) and `...-OptiQ-4bit`. Since a
dense model is bandwidth-bound on its full active weights regardless of FP4-vs-int4 packing, the
std MLX 4-bit build is a faithful stand-in. This run uses it.

## Model architecture (why it's slow)

`config.json`: `Qwen3_5ForConditionalGeneration` (a VLM; text path used here), **dense** (no MoE).

- num_hidden_layers: 64, hidden_size: 5120, intermediate_size: 17408, head_dim: 256
- Quantization: MLX affine 4-bit, group_size 64  (~15 GB on disk, ~13.5 GB active/token)
- **Hybrid attention**: `layer_types` = 3× `linear_attention` + 1× `full_attention`
  (`full_attention_interval=4`). The linear layers are Gated-DeltaNet / SSM-style
  (keys: `mamba_ssm_dtype`, `linear_conv_kernel_dim`, `linear_key_head_dim`). Has MTP layers.
- max_position_embeddings: 262144 (256k)

## Results (omlx 0.4.4)

| Run                              | omlx config | max_tokens | tok/s | load (s) |
|----------------------------------|-------------|-----------:|------:|---------:|
| warmup-excluded (cold load)      | aggressive  | 512        | 4.62  | 20.08    |
| warm (2nd consec, aggressive)    | aggressive  | 512        | 3.44  | —        |
| warmup-excluded (cold load)      | lean*       | 512        | 4.44  | 15.87    |
| warm                             | lean*       | 512        | 4.23  | —        |
| warm                             | lean*       | 1024       | 4.36  | —        |

\* lean = `--hot-cache-max-size 512MB --max-concurrent-requests 1 --initial-cache-blocks 16`
  (vs the canonical `--hot-cache-max-size 4GB --initial-cache-blocks 1024 --max-concurrent-requests 2`).
  Lean made no material difference, so cache tuning is not the bottleneck. Canonical config restored after the run.

**Representative M5 number: ~4.4 tok/s** (stable across 512 and 1024; the 3.44 was a single
2nd-consecutive-run outlier under the heavier aggressive cache).

## Is it memory-pressure / swap?  No.

The box had ~12-13 GB of pre-existing swap (inactive/compressed memory from apps), which raised
the suspicion that the 15 GB model was being streamed from SSD. Diagnostic: counted `vm_stat`
Pageins across one full 512-token decode (121 s):

  pageins during decode = 20,805 pages × 16 KB = **0.31 GB**

If the model were re-read per token we'd see thousands of GB. 0.31 GB means the weights stayed
resident in page/GPU memory (model 15 GB < 26 GB GPU wired limit). So **~4.4 tok/s is the genuine
decode speed**, not a swap artifact.

## Why so far below the bandwidth ceiling

- Bandwidth ceiling: 153.6 GB/s ÷ ~13.5 GB active ≈ **11.4 tok/s** absolute max for a dense 27B 4-bit.
- Measured 4.4 tok/s ≈ **39% of ceiling** — much lower efficiency than the 35B-A3B MoE.
- Cause: the dense weight footprint **plus** the Gated-DeltaNet/SSM **linear-attention layers hitting
  an unoptimized, sequential MLX path** (analogous to DWQ having no fast kernel under vllm-mlx).

## Comparison / takeaway

| Model on M5 (omlx)                         | active/token | tok/s (512) |
|--------------------------------------------|-------------:|------------:|
| mlx-community/Qwen3.6-35B-A3B-nvfp4 (MoE)   | ~1.5 GB      | ~40-49      |
| **mlx-community/Qwen3.6-27B-4bit (dense)** | ~13.5 GB     | **~4.4**    |

The dense 27B is **~10× slower** than the 35B-A3B MoE on the same machine — reinforcing the repo
thesis that MoE (small active footprint) is the only practical class for 32 GB Apple Silicon.

Note: the older OPTIMIZATION.md figure "Qwen3.6-27B-4bit (dense) = 10.6 tok/s (M2 Pro)" is **not
directly comparable** — it predates this 2026 hybrid-attention VLM checkpoint and almost certainly
referred to a standard-attention 27B. Re-measure M2 Pro on this exact checkpoint for an apples-to-apples gap.

Raw run logs: scratch (mlx-bench console output) summarized above.
