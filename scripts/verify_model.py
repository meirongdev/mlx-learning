#!/usr/bin/env python3
"""Smoke-test a running MLX server: hit /chat/completions and inspect local config.json.

Usage:
    python scripts/verify_model.py \
        --base http://127.0.0.1:5001 \
        --model models/mlx-community__Qwen3.6-35B-A3B-4bit
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path
from urllib import request


def hit_chat(base: str, model: str, timeout: int) -> int:
    url = base.rstrip("/") + "/chat/completions"
    payload = json.dumps(
        {
            "model": model,
            "messages": [
                {"role": "system", "content": "Reply in one short sentence."},
                {"role": "user", "content": "Say hello and name the model you are."},
            ],
            "max_tokens": 32,
            "temperature": 0.0,
        }
    ).encode("utf-8")
    req = request.Request(
        url, data=payload, headers={"Content-Type": "application/json"}
    )
    try:
        with request.urlopen(req, timeout=timeout) as r:
            resp = json.load(r)
        print(f"server_response: {json.dumps(resp, ensure_ascii=False)}")
        return 0
    except Exception as e:
        print(f"server request failed: {e}", file=sys.stderr)
        return 1


def inspect_config(model: str) -> int:
    cfg_path = Path(model) / "config.json"
    if not cfg_path.exists():
        print(f"config.json not found at {cfg_path}", file=sys.stderr)
        return 1
    cfg = json.loads(cfg_path.read_text())
    print(f"config.json model_type: {cfg.get('model_type')}")
    print(f"config.json architectures: {cfg.get('architectures')}")
    return 0


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument(
        "--base", default="http://127.0.0.1:5001", help="MLX server base URL"
    )
    ap.add_argument(
        "--model",
        default="models/mlx-community__Qwen3.6-35B-A3B-4bit",
        help="Local model directory (also used as `model` field in the request)",
    )
    ap.add_argument("--timeout", type=int, default=60, help="HTTP timeout in seconds")
    ap.add_argument(
        "--skip-server", action="store_true", help="Only inspect config.json"
    )
    args = ap.parse_args()

    rc = 0
    if not args.skip_server:
        rc |= hit_chat(args.base, args.model, args.timeout)
    rc |= inspect_config(args.model)
    return rc


if __name__ == "__main__":
    sys.exit(main())
