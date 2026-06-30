# Model Performance Optimization for Apple Silicon

This repo is shared between an **M2 Pro 32 GB** box and an **M5 32 GB** MacBook Pro 14". They have very different memory subsystems:

| Machine        | Chip            | Bandwidth   | GPU/NPU AI throughput |
| -------------- | --------------- | ----------- | --------------------- |
| M2 Pro MBP     | Apple M2 Pro    | 200 GB/s    | Lower                 |
| M5 MBP 14"     | Apple M5 (base) | 153.6 GB/s  | Higher (neural accels)|

Decode is bandwidth-bound, so the M2 Pro generally wins on plain decode tok/s. The M5 narrows the gap on prompt prefill (compute-bound) and on anything that touches the new neural accelerators. **Always run `make detect-machine` before benchmarking** — the optimal config differs.

## Key Optimizations

### 1. GPU Wired Memory Limit
By default, macOS may reclaim memory used by the GPU, leading to latency spikes during inference. Increasing the wired memory limit prevents this.

**To apply:**
```bash
make optimize-system
```
*This runs `sudo sysctl iogpu.wired_limit_mb=30000`, which is recommended for 32 GB RAM Macs when running the 35B MoE model to ensure maximum stability and performance.* The script prints the detected machine first so you can confirm.

### 2. omlx Server Flags
The `omlx` server is pre-configured in the `Makefile` with the following optimized flags (`OMLX_EXTRA_ARGS`):

- `--max-process-memory 90%`: cap process memory; leaves headroom for the GUI on 32 GB.
- `--hot-cache-max-size 4GB`: in-memory prefix caching for long-context queries (up to 6.4× speedup).
- `--max-concurrent-requests 2`: reduces memory fragmentation / scheduling overhead.
- `--initial-cache-blocks 1024`: pre-allocates KV-cache blocks at startup to eliminate allocation jitter.

**To start omlx with these flags:**
```bash
make omlx-start
```

### 3. Optimized Model & Quantization
The project defaults to `mlx-community/Qwen3.6-35B-A3B-4bit-DWQ` (MoE, 3B active per token), but the right pick is **machine-dependent** — see the empirical M5 result below.

- **DWQ-4bit ("Dynamic Weight Quantization")** is the strongest 4-bit option on MLX *in published guidance* as of early 2026 — it beats standard MLX-4bit, MXFP4-MLX, and NVFP4-MLX on perplexity. The conventional wisdom is also that NVFP4/MXFP4 are designed for Blackwell-class FP4 tensor cores and fall back to FP16 on MLX, making them slower.
- **On M5 specifically**, that conventional wisdom **does not hold** — see the table below: NVFP4 measured ~25% faster than DWQ. M5 ships GPU neural accelerators that change the FP4 calculus, and omlx may have FP4 paths vanilla `mlx-lm` lacks. Empirical measurement > theoretical claim.
- **A3B MoE**: only ~3 B parameters active per token. Apple Silicon decode is memory-bandwidth bound, so tokens/sec scale with *active* weight size, not total size.

#### Reference benchmark — M2 Pro (200 GB/s), historical
512-token gen, 4-bit (pre-DWQ, pre-NVFP4):

| Model                                | Active weights read/token | Tokens/sec |
|--------------------------------------|---------------------------|------------|
| Qwen3.6-27B-4bit (dense)             | ~15 GB                    | **10.6**   |
| Qwen3.6-35B-A3B-4bit (MoE)           | ~1.5–2 GB                 | **45.8**   |

A larger MoE is both stronger and ~4.3× faster than a dense model half its size — because MoE collapses the per-token memory traffic. **DWQ vs NVFP4 has not yet been re-measured on the M2 Pro box** — re-run `make bench` there and append the result to `bench-results/`.

> ⚠️ The `10.6` figure above predates the 2026 Qwen3.6 hybrid-attention VLM checkpoint and almost certainly referred to a standard-attention 27B. Do not treat it as comparable to `mlx-community/Qwen3.6-27B-4bit` (see the M5 dense-27B row below).

#### Reference benchmark — M5 (153.6 GB/s), dense 27B, 2026-06-30
`mlx-community/Qwen3.6-27B-4bit` (dense, **hybrid** Gated-DeltaNet/SSM + full attention; 64 layers), omlx 0.4.4:

| Model                                  | Active/token | tok/s (512) | tok/s (1024) | Bandwidth ceiling | % of ceiling |
|----------------------------------------|-------------:|------------:|-------------:|------------------:|-------------:|
| Qwen3.6-27B-4bit (dense, hybrid attn)  | ~13.5 GB     | **~4.4**    | 4.36         | ~11.4 tok/s       | ~39%         |
| Qwen3.6-35B-A3B-nvfp4 (MoE, reference) | ~1.5 GB      | ~40–49      | —            | —                 | —            |

The dense 27B is **~10× slower** than the 35B-A3B MoE on the *same* M5. It is **not** swap-bound — page-ins during a full decode were only 0.31 GB, so the 15 GB model stays resident (< 26 GB GPU wired limit). It runs at only ~39% of its bandwidth ceiling because the dense footprint **plus** the linear-attention (Gated-DeltaNet/SSM) layers hit an unoptimized sequential MLX path. Full report: [`bench-results/m5-qwen3.6-27b-dense-4bit-20260630.md`](./bench-results/m5-qwen3.6-27b-dense-4bit-20260630.md).

**`nvidia/Qwen3.6-27B-NVFP4` does NOT run on Apple Silicon** — it is an NVIDIA ModelOpt (BF16/F8_E4M3/U8) checkpoint for vLLM/TensorRT-LLM on Hopper/Blackwell CUDA. Its "NVFP4" is a different on-disk format from MLX-native NVFP4; no MLX runtime (omlx, mlx-lm, vllm-mlx) can load it. There is no MLX-native NVFP4 build of any Qwen3.6-27B on HF.

#### Reference benchmark — M5 (153.6 GB/s), 2026-05-03
Qwen3.6-35B-A3B head-to-head, omlx, sequential load → warm → time → unload. Three runs:

| Run / state           | NVFP4 tok/s | DWQ tok/s | NVFP4 / DWQ |
|-----------------------|------------:|----------:|------------:|
| Run 1 — cold (512)    | 39.74       | 31.33     | 1.27×       |
| Run 2 — cold-ish (1024) | 36.47     | 29.23     | 1.25×       |
| Run 3 — warm (1024)   | **49.14**   | 32.11     | **1.53×**   |

NVFP4 wins consistently. The warm-state run is where it genuinely shines — **49.14 tok/s** beats the historical M2 Pro 4-bit ceiling (45.8 tok/s) despite the M5 having ~25% less memory bandwidth. DWQ barely benefits from warm-state (~10% lift) while NVFP4 jumps ~35%, suggesting accelerator/kernel state — not just file cache — favors FP4 on M5.

**Recommendation on M5: use NVFP4.** Both fit in 32 GB with comfortable KV-cache headroom; quality difference is small for normal chat workloads. To switch:

```bash
make omlx-stop
MODEL_REPO=mlx-community/Qwen3.6-35B-A3B-nvfp4 make omlx-start
# or just point clients at "mlx-community__Qwen3.6-35B-A3B-nvfp4" — omlx auto-discovers both
```

Raw logs and methodology live in [`bench-results/`](./bench-results/).

## Monitoring Performance
Compare two omlx-served models side-by-side using the built-in benchmark tool:

```bash
make bench                                                # default models
uv run mlx-bench mlx-community__Qwen3.6-35B-A3B-4bit-DWQ \
                 mlx-community__Qwen3.6-35B-A3B-nvfp4     # explicit
```

The benchmark loads, warms, times, and unloads each model in sequence so memory doesn't bleed between runs.

## References
- [Apple M5 上 omlx + Gemma4-26B 性能调优实录](https://meirong.dev/posts/omlx-gemma4-m5-optimization/)
- [omlx GitHub Repository](https://github.com/jundot/omlx)
- [mlx-community/Qwen3.6-35B-A3B-4bit-DWQ on Hugging Face](https://huggingface.co/mlx-community/Qwen3.6-35B-A3B-4bit-DWQ)
