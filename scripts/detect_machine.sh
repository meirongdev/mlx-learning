#!/usr/bin/env bash
# detect_machine.sh — Identify the Apple Silicon chip, RAM, and memory bandwidth.
#
# This repo is shared between an M2 Pro and an M5 (both 32 GB). Memory bandwidth
# differs (200 vs 153.6 GB/s) and so does the optimal model/quantization choice,
# so any script that downloads weights, starts the server, or runs benchmarks
# should print this info first.
#
# Usage:
#   scripts/detect_machine.sh                 # human-readable
#   scripts/detect_machine.sh --quiet         # KEY=VALUE (eval/source-friendly)
#   scripts/detect_machine.sh --check=M5      # exit 0 if chip slug matches, 1 otherwise
#
# Exit codes:
#   0  match / info printed
#   1  chip mismatch under --check=
#   2  not macOS / not Apple Silicon

set -euo pipefail

quiet=0
check_chip=""
for arg in "$@"; do
    case "$arg" in
        --quiet|-q) quiet=1 ;;
        --check=*) check_chip="${arg#--check=}" ;;
        --check-chip=*) check_chip="${arg#--check-chip=}" ;;
        --help|-h)
            sed -n '2,16p' "$0" | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        *)
            echo "unknown arg: $arg" >&2
            exit 2
            ;;
    esac
done

if [[ "$(uname -s)" != "Darwin" || "$(uname -m)" != "arm64" ]]; then
    echo "ERROR: requires macOS on Apple Silicon (got $(uname -s)/$(uname -m))" >&2
    exit 2
fi

chip=$(system_profiler SPHardwareDataType 2>/dev/null \
    | awk -F': ' '/^[[:space:]]*Chip:/ {sub(/^[[:space:]]+/, "", $2); print $2; exit}')
[[ -n "$chip" ]] || chip=$(sysctl -n machdep.cpu.brand_string 2>/dev/null || echo "Unknown")

ram_gb=$(( $(sysctl -n hw.memsize) / 1024 / 1024 / 1024 ))

# Bandwidth (GB/s) per chip family. Sources: Apple newsroom, Wikipedia.
# When a chip has multiple GPU SKUs at different bandwidths, we list the lower
# (the M3 Max 30-core / M5 Max 32-core) — that's the conservative budget.
case "$chip" in
    "Apple M1")        bw=68 ;;
    "Apple M1 Pro")    bw=200 ;;
    "Apple M1 Max")    bw=400 ;;
    "Apple M1 Ultra")  bw=800 ;;
    "Apple M2")        bw=100 ;;
    "Apple M2 Pro")    bw=200 ;;
    "Apple M2 Max")    bw=400 ;;
    "Apple M2 Ultra")  bw=800 ;;
    "Apple M3")        bw=100 ;;
    "Apple M3 Pro")    bw=150 ;;
    "Apple M3 Max")    bw=300 ;;
    "Apple M3 Ultra")  bw=800 ;;
    "Apple M4")        bw=120 ;;
    "Apple M4 Pro")    bw=273 ;;
    "Apple M4 Max")    bw=546 ;;
    "Apple M5")        bw=153 ;;
    "Apple M5 Pro")    bw=307 ;;
    "Apple M5 Max")    bw=460 ;;
    *)                 bw=0 ;;
esac

# Short slug, e.g. "Apple M5 Pro" -> "M5-Pro"
short=$(printf '%s' "$chip" | sed 's/^Apple //; s/ /-/g')

# Wired GPU memory limit (informational)
wired_mb=$(sysctl -n iogpu.wired_limit_mb 2>/dev/null || echo 0)

# --- --check= mode ---
if [[ -n "$check_chip" ]]; then
    short_lc=$(printf '%s' "$short" | tr '[:upper:]' '[:lower:]')
    chip_lc=$(printf '%s' "$chip" | tr '[:upper:]' '[:lower:]')
    want_lc=$(printf '%s' "$check_chip" | tr '[:upper:]' '[:lower:]')
    if [[ "$short_lc" == "$want_lc" || "$chip_lc" == *"$want_lc"* ]]; then
        (( quiet )) || echo "OK: running on $chip ($short)"
        exit 0
    fi
    echo "CHIP MISMATCH: expected '$check_chip', got '$short' ($chip)" >&2
    exit 1
fi

if (( quiet )); then
    printf "MACHINE_CHIP='%s'\n" "$chip"
    printf "MACHINE_CHIP_SHORT='%s'\n" "$short"
    printf 'MACHINE_RAM_GB=%d\n' "$ram_gb"
    printf 'MACHINE_BW_GBPS=%d\n' "$bw"
    printf 'MACHINE_WIRED_MB=%d\n' "$wired_mb"
else
    printf 'Chip:           %s  (%s)\n' "$chip" "$short"
    printf 'Unified memory: %d GB\n' "$ram_gb"
    if (( bw > 0 )); then
        printf 'Memory bandwidth: %d GB/s\n' "$bw"
    else
        printf 'Memory bandwidth: unknown (chip not in lookup table)\n'
    fi
    printf 'GPU wired limit: %d MB\n' "$wired_mb"
fi
