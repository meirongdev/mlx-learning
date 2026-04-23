# Model Performance Optimization for Apple Silicon

This project incorporates optimization techniques for Apple Silicon (M-series, specifically M5) as documented in the [omlx + Gemma4-26B Performance Optimization guide](https://meirong.dev/posts/omlx-gemma4-m5-optimization/).

## Key Optimizations

### 1. GPU Wired Memory Limit
By default, macOS may reclaim memory used by the GPU, leading to latency spikes during inference. Increasing the wired memory limit prevents this.

**To apply:**
```bash
make optimize-system
```
*This runs `sudo sysctl iogpu.wired_limit_mb=30000`, which is recommended for 32GB RAM Macs when running the 35B MoE model to ensure maximum stability and performance.*

### 2. omlx Server Flags
The `omlx` server is pre-configured in the `Makefile` with the following optimized flags:

- `--hot-cache-max-size 4GB`: Enables in-memory prefix caching for long-context queries (up to 6.4x speedup).
- `--max-concurrent-requests 2`: Reduces memory fragmentation and scheduling overhead.
- `--initial-cache-blocks 1024`: Pre-allocates KV cache blocks at startup to eliminate allocation jitter.

**To start omlx with these flags:**
```bash
make omlx-start
```

### 3. Optimized Model & Quantization
The project defaults to `mlx-community/Qwen3.6-35B-A3B-4bit` (MoE, 3B active per token).
- **4-bit quantization**: Broadly compatible MLX quantization that fits a 35B MoE into ~19 GB on disk, leaving room for KV cache + hot cache on 32 GB machines.
- **A3B MoE**: only ~3 B parameters active per token. Apple Silicon decode is memory-bandwidth bound, so tokens/sec scale with *active* weight size, not total size. Measured on M2 Pro 200 GB/s:

  | Model | Active weights read/token | Tokens/sec (512-token gen) |
  |---|---|---|
  | Qwen3.6-27B-4bit (dense) | ~15 GB | **10.6** |
  | Qwen3.6-35B-A3B-4bit (MoE, default) | ~1.5–2 GB | **45.8** |

  A larger MoE is both stronger and ~4.3× faster than a dense model half its size — only because MoE collapses the per-token memory traffic.

## Monitoring Performance
You can compare the performance of `mlx_lm.server` vs `omlx` using the built-in benchmark tool:

```bash
make bench
```

## References
- [Apple M5 上 omlx + Gemma4-26B 性能调优实录](https://meirong.dev/posts/omlx-gemma4-m5-optimization/)
- [omlx GitHub Repository](https://github.com/jundot/omlx)
