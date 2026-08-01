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
*This runs `sudo sysctl iogpu.wired_limit_mb=30720`, recommended for 32 GB Macs running the 35B MoE model.* The script prints the detected machine first so you can confirm. **macOS resets this on every reboot** — re-run after each boot, or omlx clamps to the kernel value and logs `Metal cap (…) is below the oMLX static ceiling (…)`. Effective ceiling = `min(omlx ceiling, iogpu cap) − hot_cache_max_size`.

### 2. omlx Server Flags

> ⚠️ **On these machines the Makefile flags below are NOT what the live server runs.** omlx is installed as a Homebrew LaunchAgent whose `ProgramArguments` are just `omlx serve` with no flags, so every effective setting comes from **`~/.omlx/settings.json`** (host, port, model dir, memory guard, cache, sampling). `OMLX_EXTRA_ARGS` only applies to the source-install fallback (`OMLX_FORCE_NOHUP=1`). To change live behaviour, edit `~/.omlx/settings.json` and `make omlx-restart`.

The `Makefile` documents the intended configuration as `OMLX_EXTRA_ARGS`:

- `--memory-guard aggressive`: allow omlx to use most of memory for throughput, with a guard reserve. omlx 0.4.x removed `--max-process-memory` — use `--memory-guard {safe,balanced,aggressive}` (or `--memory-guard-gb N` for a hard ceiling) instead. `aggressive` preserves the old `90%` intent. (Current M2 Pro `settings.json` uses tier `custom` with a 30 GB ceiling.)
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

A larger MoE is both stronger and ~4.3× faster than a dense model half its size — because MoE collapses the per-token memory traffic.

**Updated 2026-08-01 (omlx 0.5.4rc1):** the M2 Pro now runs Qwen3.6-35B-A3B-nvfp4 at **57.9 tok/s warm** — the server upgrade alone added +27% over the 45.8 figure above. The three quant formats were measured on 0.4.x and tied (std 4bit 45.89, DWQ 45.36, NVFP4 45.36), consistent with being bandwidth-bound; only NVFP4 has been re-measured on 0.5.x.

**Speculative / parallel decoding does not help these MoE models** — measured three ways on the M2 Pro: DFlash −19…−29%, Gemma's own MTP assistant −12%, DiffusionGemma −68%. On a sparse MoE, processing N positions in one forward pass activates the *union* of experts across those N positions, so the weight read grows with N rather than staying at the per-token active set. Full table in `CLAUDE.md`.

#### Reference benchmark — M5 (153.6 GB/s), 2026-05-03
Qwen3.6-35B-A3B head-to-head, omlx, sequential load → warm → time → unload. Three runs:

| Run / state           | NVFP4 tok/s | DWQ tok/s | NVFP4 / DWQ |
|-----------------------|------------:|----------:|------------:|
| Run 1 — cold (512)    | 39.74       | 31.33     | 1.27×       |
| Run 2 — cold-ish (1024) | 36.47     | 29.23     | 1.25×       |
| Run 3 — warm (1024)   | **49.14**   | 32.11     | **1.53×**   |

NVFP4 wins consistently. The warm-state run is where it genuinely shines — **49.14 tok/s**, which at the time beat the M2 Pro's 4-bit ceiling (45.8 tok/s) despite the M5 having ~25% less memory bandwidth. *(That comparison no longer holds: on omlx 0.5.4rc1 the M2 Pro reaches 57.9 tok/s. These M5 numbers are from omlx 0.4.x and have not been re-measured — re-run before comparing across machines.)* DWQ barely benefits from warm-state (~10% lift) while NVFP4 jumps ~35%, suggesting accelerator/kernel state — not just file cache — favors FP4 on M5.

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
