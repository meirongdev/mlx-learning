# omlx vs vllm-mlx — M2 Pro, Qwen3.6-35B-A3B (all three quants)

**Date:** 2026-05-03  
**Host:** M2 Pro MacBook, 32 GB, 200 GB/s, GPU wired limit 30000 MB  
**Models tested:** Qwen3.6-35B-A3B in three quantization formats (nvfp4, DWQ-4bit, std 4bit)  
**vllm-mlx version:** 0.2.9  
**Workload:** single user, single stream, `mlx-bench` CLI hitting `/v1/chat/completions`  
**Prompt:** "Write a 200-word introduction to quantum computing for a 10-year-old."

## Server configurations

| omlx flag | vllm-mlx equivalent |
|---|---|
| `--max-process-memory 90%` | `--gpu-memory-utilization 0.90` |
| `--hot-cache-max-size 4GB` | `--cache-memory-mb 4096` |
| `--max-concurrent-requests 2` | `--max-num-seqs 2` |
| `--initial-cache-blocks 1024` | `--use-paged-cache --max-cache-blocks 1024` |

## Results — M2 Pro

### NVFP4 (`mlx-community__Qwen3.6-35B-A3B-nvfp4`)

| Run | omlx (tok/s) | vllm-mlx (tok/s) | Δ |
|---|---:|---:|---:|
| 512 tok, cold-warm | 45.36 | **57.40** | +26.4% |
| 1024 tok, warm-1   | —     | **58.67** | — |
| 1024 tok, warm-2   | —     | **58.65** | — |

### DWQ-4bit (`mlx-community__Qwen3.6-35B-A3B-4bit-DWQ`)

| Run | omlx (tok/s) | vllm-mlx (tok/s) | Δ |
|---|---:|---:|---:|
| 512 tok, cold-warm | 45.36 | 45.88 | +1.2% |
| 1024 tok, warm-1   | —     | 46.31 | — |
| 1024 tok, warm-2   | —     | 46.38 | — |

### Std 4-bit (`mlx-community__Qwen3.6-35B-A3B-4bit`)

| Run | omlx (tok/s) | vllm-mlx (tok/s) | Δ |
|---|---:|---:|---:|
| 512 tok, cold-warm | 45.89 | **58.13** | +26.7% |
| 1024 tok, warm-1   | —     | **58.80** | — |
| 1024 tok, warm-2   | —     | **58.83** | — |

## Cross-machine comparison (vllm-mlx 0.2.9, NVFP4, same workload)

| Machine | Bandwidth | 512 tok | 1024 tok warm | Notes |
|---|---|---:|---:|---|
| M2 Pro 32 GB | 200 GB/s | **57.40** | **58.65–58.67** | Higher BW wins even with older GPU |
| M5 32 GB     | 153.6 GB/s | 51.09 | 51.73–52.25 | FP4 HW advantage not leveraged by vllm-mlx |

**M2 Pro is ~12–13% faster than M5 under vllm-mlx on NVFP4** — the bandwidth gap (200 vs 153.6 GB/s) is fully expressed, unlike with omlx where M5's FP4 HW kernels narrow the gap.

## Key findings

### vllm-mlx gains depend strongly on quantization format

| Quant | omlx (tok/s) | vllm-mlx (tok/s) | Δ |
|---|---:|---:|---:|
| NVFP4     | 45.36 | **58.65** | **+29%** |
| std 4-bit | 45.89 | **58.83** | **+28%** |
| DWQ-4bit  | 45.36 | 46.38     | **+2%**  |

vllm-mlx has highly optimized kernels for standard MLX 4-bit and NVFP4 formats, but DWQ falls back to a less-optimized path — likely because DWQ's per-group dynamic weight quantization requires dequant logic that vllm-mlx hasn't specifically tuned.

### omlx on M2 Pro: all three formats are identical (~45 tok/s)

On M2 Pro, omlx is fully memory-bandwidth-bound — the dequant kernel path doesn't matter because the bottleneck is simply how fast weights stream from memory. vllm-mlx breaks this symmetry by using a more compute-efficient decode path for standard formats.

### DWQ ranking reversal under vllm-mlx

Published MLX guidance (early 2026): DWQ-4bit > std 4-bit ≥ NVFP4.  
Under vllm-mlx on M2 Pro: **std 4-bit ≈ NVFP4 >> DWQ-4bit**.  
DWQ's advantage in MLX is in quality-per-bit, not raw throughput — and vllm-mlx doesn't benefit from MLX's DWQ-specific dequant kernels.

## Recommendations for this repo

| Scenario | Engine | Model | Expected tok/s |
|---|---|---|---:|
| M2 Pro, max speed | **vllm-mlx** | std 4-bit or NVFP4 | ~58–59 |
| M2 Pro, omlx (default, simpler) | omlx | any of the three | ~45 |
| M5, max speed | vllm-mlx | NVFP4 | ~52 |
| M5, omlx warm | omlx | NVFP4 | ~49 |
| M2 Pro vs M5, vllm-mlx | M2 Pro wins | — | +12% |
| M2 Pro vs M5, omlx | M5 wins (warm) | NVFP4 only | M5: 49 vs M2: 45 |

**Updated recommendation:**  
- If raw tok/s is the priority, vllm-mlx + std 4bit gives the best results on M2 Pro (~59 tok/s, +28% over omlx).
- omlx remains the simpler default (Homebrew service, no PyTorch dep, VLM support).
- **DWQ is no longer the best choice for vllm-mlx on either machine.** Use std 4-bit or NVFP4 instead.

## Raw log files

- `vllm-mlx-m2pro-nvfp4-512-*.log` — 57.40 tok/s
- `vllm-mlx-m2pro-nvfp4-1024-warm1-*.log` — 58.67 tok/s
- `vllm-mlx-m2pro-nvfp4-1024-warm2-*.log` — 58.65 tok/s
- `vllm-mlx-m2pro-dwq-512-*.log` — 45.88 tok/s
- `vllm-mlx-m2pro-dwq-1024-*.log` — 46.31 / 46.38 tok/s
- `vllm-mlx-m2pro-4bit-512-*.log` — 58.13 tok/s
- `vllm-mlx-m2pro-4bit-1024-*.log` — 58.80 / 58.83 tok/s
