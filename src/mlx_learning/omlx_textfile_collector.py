"""Render omlx's serving counters as a Prometheus textfile-collector snapshot.

omlx 0.6.x exposes no ``/metrics`` and bundles no ``prometheus_client``. Its
counters live in exactly two places:

* ``GET /admin/api/stats`` — richer (memory pressure, queue depth), but behind
  an admin session cookie that requires ``auth.api_key`` to be set.
* ``~/.omlx/stats.json`` — no auth, rewritten atomically by
  ``server_metrics.save_alltime()`` every 300s (``_SAVE_INTERVAL``) and once
  more on shutdown.

This reads the file. Nothing here touches the inference server.

The file stores *raw cumulative* sums rather than the pre-averaged
``avg_prefill_tps`` the admin endpoint returns, and that is the whole point:
the endpoint's average is smeared over all time since the counters were last
cleared, so it cannot show a trend. ``rate()`` over these counters can::

    # prefill tokens/sec over the last 30m. Cached tokens are served from the
    # KV cache and never prefilled, so they must come out of the numerator —
    # this is the same subtraction server_metrics._build_snapshot() does.
    rate(omlx_processed_prompt_tokens_total[30m])
      / rate(omlx_prefill_seconds_total[30m])

    # decode tokens/sec over the last 30m, per model
    rate(omlx_model_completion_tokens_total[30m])
      / rate(omlx_model_generation_seconds_total[30m])

Because the source file only lands every 300s, counters here are step-shaped.
Keep ``rate()`` windows well above that — 15m minimum, 30m+ preferred.

Not available from this file, and not faked here: memory pressure, queue
depth, per-request latency, and speculative-decoding acceptance. Acceptance in
particular stays log-only (``scheduler.py`` computes it purely to log it), so
AGENTS.md rule 3 still applies — confirm the drafter line in the server log.
"""

from __future__ import annotations

import json
import math
import os
import stat
import sys
import tempfile
import time
from collections.abc import Callable, Mapping, Sequence
from dataclasses import dataclass
from pathlib import Path
from typing import Any

import typer

app = typer.Typer(add_completion=False)

DEFAULT_STATS_PATH = Path.home() / ".omlx" / "stats.json"
DEFAULT_OUTPUT_DIR = (
    Path.home() / ".local" / "var" / "lib" / "node_exporter" / "textfile_collector"
)
OUTPUT_FILENAME = "omlx.prom"

# node_exporter reads the file as the invoking user here, but a 0600 temp file
# would break the moment the exporter is moved to its own account.
_FILE_MODE = stat.S_IRUSR | stat.S_IWUSR | stat.S_IRGRP | stat.S_IROTH


@dataclass(frozen=True)
class Counters:
    """One omlx counter bundle — either the global totals or a single model."""

    prompt_tokens: float
    completion_tokens: float
    cached_tokens: float
    requests: float
    prefill_duration: float
    generation_duration: float

    @property
    def processed_prompt_tokens(self) -> float:
        """Prompt tokens actually prefilled, i.e. excluding KV-cache hits.

        Clamped at zero: a counter that can go backwards reads as a reset to
        Prometheus, and cached_tokens > prompt_tokens should be impossible but
        is not worth trusting a JSON file over.
        """
        return max(self.prompt_tokens - self.cached_tokens, 0.0)


@dataclass(frozen=True)
class Stats:
    """A parsed ``stats.json``."""

    total: Counters
    per_model: dict[str, Counters]


# (metric suffix, HELP text, accessor). Rendered once unlabelled as
# `omlx_<suffix>` and once per model as `omlx_model_<suffix>`.
_FIELDS: tuple[tuple[str, str, Callable[[Counters], float]], ...] = (
    (
        "requests_total",
        "Completed requests recorded by omlx since the all-time counters were last cleared.",
        lambda c: c.requests,
    ),
    (
        "prompt_tokens_total",
        "Cumulative prompt tokens accepted, including tokens served from the KV cache.",
        lambda c: c.prompt_tokens,
    ),
    (
        "cached_prompt_tokens_total",
        "Cumulative prompt tokens served from the KV cache instead of being prefilled.",
        lambda c: c.cached_tokens,
    ),
    (
        "processed_prompt_tokens_total",
        "Cumulative prompt tokens actually prefilled (prompt minus cached).",
        lambda c: c.processed_prompt_tokens,
    ),
    (
        "completion_tokens_total",
        "Cumulative generated (decoded) tokens.",
        lambda c: c.completion_tokens,
    ),
    (
        "prefill_seconds_total",
        "Cumulative wall-clock seconds spent in prefill.",
        lambda c: c.prefill_duration,
    ),
    (
        "generation_seconds_total",
        "Cumulative wall-clock seconds spent in decode.",
        lambda c: c.generation_duration,
    ),
)


def _escape_label_value(value: str) -> str:
    """Escape a label value per the Prometheus text exposition format."""
    return value.replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n")


def _fmt(value: float) -> str:
    """Format a sample value the way Prometheus parses it."""
    if isinstance(value, int):
        return str(value)
    if math.isnan(value):
        return "NaN"
    if math.isinf(value):
        return "+Inf" if value > 0 else "-Inf"
    if value.is_integer() and abs(value) < 1e15:
        return str(int(value))
    return repr(value)


def _render_family(
    name: str,
    metric_type: str,
    help_text: str,
    samples: Sequence[tuple[Mapping[str, str], float]],
) -> list[str]:
    """Render one metric family: HELP, TYPE, then its samples."""
    lines = [f"# HELP {name} {help_text}", f"# TYPE {name} {metric_type}"]
    for labels, value in samples:
        if labels:
            rendered = ",".join(
                f'{key}="{_escape_label_value(val)}"' for key, val in labels.items()
            )
            lines.append(f"{name}{{{rendered}}} {_fmt(value)}")
        else:
            lines.append(f"{name} {_fmt(value)}")
    return lines


def _number(raw: Mapping[str, Any], key: str) -> float:
    """Pull a numeric field, treating absent or non-numeric as zero."""
    value = raw.get(key)
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        return 0.0
    return float(value)


def _counters_from(raw: Mapping[str, Any], prefix: str = "") -> Counters:
    """Build Counters from a mapping. Global keys carry a ``total_`` prefix."""
    return Counters(
        prompt_tokens=_number(raw, f"{prefix}prompt_tokens"),
        completion_tokens=_number(raw, f"{prefix}completion_tokens"),
        cached_tokens=_number(raw, f"{prefix}cached_tokens"),
        requests=_number(raw, f"{prefix}requests"),
        prefill_duration=_number(raw, f"{prefix}prefill_duration"),
        generation_duration=_number(raw, f"{prefix}generation_duration"),
    )


def parse_stats(raw: Mapping[str, Any]) -> Stats:
    """Parse a decoded ``stats.json`` payload."""
    per_model: dict[str, Counters] = {}
    raw_models = raw.get("per_model")
    if isinstance(raw_models, dict):
        for model_id, model_raw in raw_models.items():
            if isinstance(model_id, str) and isinstance(model_raw, dict):
                per_model[model_id] = _counters_from(model_raw)
    return Stats(total=_counters_from(raw, prefix="total_"), per_model=per_model)


def load_stats(path: Path) -> tuple[Stats, float]:
    """Read and parse ``stats.json``; returns the stats and the file's mtime."""
    text = path.read_text()
    mtime = path.stat().st_mtime
    decoded = json.loads(text)
    if not isinstance(decoded, dict):
        raise ValueError(
            f"{path}: expected a JSON object, got {type(decoded).__name__}"
        )
    return parse_stats(decoded), mtime


def render(stats: Stats, stats_mtime: float, now: float) -> str:
    """Render the full exposition text for one snapshot."""
    lines: list[str] = []

    for suffix, help_text, accessor in _FIELDS:
        lines += _render_family(
            f"omlx_{suffix}",
            "counter",
            f"{help_text} Server-wide total.",
            [({}, accessor(stats.total))],
        )

    for suffix, help_text, accessor in _FIELDS:
        samples: list[tuple[Mapping[str, str], float]] = [
            ({"model": model_id}, accessor(counters))
            for model_id, counters in sorted(stats.per_model.items())
        ]
        lines += _render_family(
            f"omlx_model_{suffix}",
            "counter",
            f"{help_text} Broken down by model.",
            samples,
        )

    # omlx only flushes stats.json every 300s, and only when a request has
    # landed since the last flush. An idle server therefore goes stale
    # legitimately — alert on this together with request rate, not alone.
    lines += _render_family(
        "omlx_stats_file_mtime_seconds",
        "gauge",
        "Unix mtime of the omlx stats.json this snapshot was rendered from.",
        [({}, stats_mtime)],
    )
    lines += _render_family(
        "omlx_stats_collected_timestamp_seconds",
        "gauge",
        "Unix time at which this snapshot was rendered.",
        [({}, now)],
    )

    return "\n".join(lines) + "\n"


def write_atomic(text: str, out_path: Path) -> None:
    """Write ``text`` to ``out_path`` atomically, so a scrape never sees a torn file."""
    out_path.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp_name = tempfile.mkstemp(dir=out_path.parent, prefix=".omlx-", suffix=".tmp")
    tmp_path = Path(tmp_name)
    try:
        with os.fdopen(fd, "w") as handle:
            handle.write(text)
        tmp_path.chmod(_FILE_MODE)
        os.replace(tmp_path, out_path)
    except BaseException:
        tmp_path.unlink(missing_ok=True)
        raise


def collect_once(stats_path: Path, out_path: Path | None) -> str:
    """Read stats, render, and write unless ``out_path`` is None. Returns the text."""
    stats, mtime = load_stats(stats_path)
    text = render(stats, mtime, time.time())
    if out_path is not None:
        write_atomic(text, out_path)
    return text


@app.command()
def main(
    stats_path: Path = typer.Option(
        DEFAULT_STATS_PATH, "--stats-path", help="Path to omlx's stats.json"
    ),
    output_dir: Path = typer.Option(
        DEFAULT_OUTPUT_DIR,
        "--output-dir",
        help="node_exporter --collector.textfile.directory",
    ),
    filename: str = typer.Option(
        OUTPUT_FILENAME, "--filename", help="Name of the .prom file to write"
    ),
    interval: float = typer.Option(
        0.0,
        "--interval",
        help="Loop forever, sleeping this many seconds between runs (0 = run once)",
    ),
    to_stdout: bool = typer.Option(
        False, "--stdout", help="Print the rendering instead of writing the .prom file"
    ),
) -> None:
    """Write omlx's counters to a Prometheus textfile-collector .prom file.

    On failure the existing .prom is deliberately left in place rather than
    replaced with a zeroed one: wiping the counters would look like a counter
    reset and blow a hole in every rate() over the gap. Detect a dead collector
    with node_exporter's own node_textfile_mtime_seconds instead.
    """
    out_path = None if to_stdout else output_dir / filename

    def run_once() -> bool:
        try:
            text = collect_once(stats_path, out_path)
        except (OSError, ValueError, json.JSONDecodeError) as exc:
            print(f"omlx-textfile-collector: {exc}", file=sys.stderr)
            return False
        if to_stdout:
            print(text, end="")
        return True

    if interval <= 0:
        raise typer.Exit(code=0 if run_once() else 1)

    while True:
        run_once()
        try:
            time.sleep(interval)
        except KeyboardInterrupt:
            raise typer.Exit(code=0) from None


if __name__ == "__main__":
    app()
