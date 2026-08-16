#!/usr/bin/env python3
"""Repeat-and-median benchmark with omlx vlm_mtp telemetry capture.

Mirrors src/mlx_learning/benchmark_cli.py's metric exactly (completion_tokens /
wall-clock POST duration, non-streaming) so numbers stay comparable to the
reports in docs/benchmarks/, but adds what those reports needed and `mlx-bench`
does not provide:

  - N timed repeats per cell, median reported (mlx-bench times a single run)
  - a second, low-predictability "code" prompt
  - capture of omlx's per-request `vlm_mtp stats:` log line, which is what
    separates draft quality (acceptance) from verify cost

Usage:
    uv run python scripts/mtpbench.py --model SLUG [--model SLUG ...] \
        [--prompts general,code] [--max-tokens 512,1024] [--repeats 3] \
        --out results.jsonl
"""

from __future__ import annotations

import argparse
import json
import re
import statistics
import subprocess
import sys
import time
from dataclasses import asdict, dataclass
from pathlib import Path

import requests

PROMPTS = {
    # Identical to mlx-bench's default so cells stay comparable to prior runs.
    "general": "Write a 200-word introduction to quantum computing for a 10-year-old.",
    # Low-predictability output: the workload a dense model would be adopted for.
    # Record the prompt in the report — acceptance rates depend on it.
    "code": (
        "Write a Python function `merge_intervals(intervals)` that merges "
        "overlapping closed intervals and returns them sorted. Handle empty "
        "input, single intervals, full containment, and touching endpoints. "
        "Include type hints, a docstring, and five pytest test cases."
    ),
}

STATS_RE = re.compile(
    r"vlm_mtp stats:.*?rounds=(?P<rounds>\d+) "
    r"accepted=(?P<acc>\d+)/(?P<tot>\d+) \((?P<pct>[\d.]+)%\) "
    r"tokens_per_round=(?P<tpr>[\d.]+)"
)


@dataclass
class Sample:
    """One timed request, plus MTP telemetry if the server emitted any."""

    tokens: int
    seconds: float
    tok_s: float
    mtp: bool = False
    rounds: int | None = None
    accepted: str | None = None
    acceptance_pct: float | None = None
    tokens_per_round: float | None = None


def brew_log() -> Path | None:
    """Path to the Homebrew-managed omlx log, or None if not brew-managed."""
    try:
        prefix = subprocess.check_output(["brew", "--prefix"], text=True).strip()
    except (OSError, subprocess.SubprocessError):
        return None
    path = Path(prefix) / "var/log/omlx.log"
    return path if path.exists() else None


def read_since(log: Path, offset: int) -> str:
    """Return log text written since `offset`."""
    if log.stat().st_size <= offset:
        return ""
    with log.open("rb") as fh:
        fh.seek(offset)
        return fh.read().decode("utf-8", "replace")


def one_request(
    base: str, model: str, prompt: str, max_tokens: int, log: Path | None
) -> Sample | None:
    offset = log.stat().st_size if log else 0
    payload = {
        "model": model,
        "messages": [{"role": "user", "content": prompt}],
        "stream": False,
        "max_tokens": max_tokens,
    }
    start = time.perf_counter()
    try:
        resp = requests.post(f"{base}/v1/chat/completions", json=payload, timeout=1800)
    except requests.RequestException as exc:
        print(f"    request failed: {exc}", file=sys.stderr)
        return None
    elapsed = time.perf_counter() - start

    if resp.status_code != 200:
        print(f"    HTTP {resp.status_code}: {resp.text[:300]}", file=sys.stderr)
        return None

    tokens = int(resp.json().get("usage", {}).get("completion_tokens", 0))
    if not tokens or elapsed <= 0:
        print("    no completion_tokens in response", file=sys.stderr)
        return None

    sample = Sample(
        tokens=tokens,
        seconds=round(elapsed, 3),
        tok_s=round(tokens / elapsed, 2),
    )

    if log is not None:
        matches = list(STATS_RE.finditer(read_since(log, offset)))
        if matches:
            m = matches[-1]
            sample.mtp = True
            sample.rounds = int(m["rounds"])
            sample.accepted = f"{m['acc']}/{m['tot']}"
            sample.acceptance_pct = float(m["pct"])
            sample.tokens_per_round = float(m["tpr"])
    return sample


def run_cell(
    base: str,
    model: str,
    prompt_name: str,
    max_tokens: int,
    repeats: int,
    log: Path | None,
) -> dict[str, object] | None:
    samples: list[Sample] = []
    for i in range(repeats):
        result = one_request(base, model, PROMPTS[prompt_name], max_tokens, log)
        if result is None:
            continue
        samples.append(result)
        extra = ""
        if result.tokens_per_round is not None:
            extra = f"  tpr={result.tokens_per_round} acc={result.acceptance_pct}%"
        print(
            f"  {prompt_name:8s} {max_tokens:5d}  run{i + 1}: "
            f"{result.tok_s:6.2f} tok/s ({result.tokens} tok){extra}",
            flush=True,
        )
    if not samples:
        return None

    tok_s = [s.tok_s for s in samples]
    tprs = [s.tokens_per_round for s in samples if s.tokens_per_round is not None]
    accs = [s.acceptance_pct for s in samples if s.acceptance_pct is not None]
    median = statistics.median(tok_s)
    print(f"  -> median {median:.2f} tok/s")

    return {
        "model": model,
        "prompt": prompt_name,
        "max_tokens": max_tokens,
        "median_tok_s": round(median, 2),
        "samples": tok_s,
        "mtp": samples[0].mtp,
        "median_tokens_per_round": round(statistics.median(tprs), 2) if tprs else None,
        "median_acceptance_pct": round(statistics.median(accs), 1) if accs else None,
        "runs": [asdict(s) for s in samples],
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--base", default="http://127.0.0.1:8000")
    parser.add_argument("--model", action="append", required=True)
    parser.add_argument("--prompts", default="general,code")
    parser.add_argument("--max-tokens", default="512,1024")
    parser.add_argument("--repeats", type=int, default=3)
    parser.add_argument("--label", default="", help="tag written into each record")
    parser.add_argument("--out", required=True)
    args = parser.parse_args()

    log = brew_log()
    print(f"omlx log: {log or '(not found — MTP telemetry disabled)'}")

    prompt_names = [p.strip() for p in args.prompts.split(",") if p.strip()]
    token_counts = [int(t) for t in args.max_tokens.split(",") if t.strip()]
    out_path = Path(args.out)

    for model in args.model:
        print(f"\n=== {model} ===")
        print("  warming up...", flush=True)
        # Cold load + one decode, excluded from timing.
        if one_request(args.base, model, "hi", 8, log) is None:
            print(f"  SKIP {model}: warmup failed", file=sys.stderr)
            continue

        for prompt_name in prompt_names:
            for max_tokens in token_counts:
                row = run_cell(
                    args.base, model, prompt_name, max_tokens, args.repeats, log
                )
                if row is None:
                    continue
                row["label"] = args.label
                with out_path.open("a") as fh:
                    fh.write(json.dumps(row) + "\n")

    print(f"\nwrote {out_path}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
