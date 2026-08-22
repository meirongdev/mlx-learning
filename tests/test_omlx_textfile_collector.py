import json
import math
from pathlib import Path
from typing import Any

import pytest

from mlx_learning.omlx_textfile_collector import (
    Counters,
    collect_once,
    load_stats,
    parse_stats,
    render,
    write_atomic,
)

SAMPLE: dict[str, Any] = {
    "total_prompt_tokens": 300,
    "total_completion_tokens": 40,
    "total_cached_tokens": 100,
    "total_requests": 3,
    "total_prefill_duration": 1.5,
    "total_generation_duration": 2.0,
    "per_model": {
        "mlx-community__Qwen3.6-35B-A3B-nvfp4": {
            "prompt_tokens": 200,
            "completion_tokens": 30,
            "cached_tokens": 100,
            "requests": 2,
            "prefill_duration": 1.0,
            "generation_duration": 1.5,
        },
        "mlx-community__gemma-4-26b-a4b-nvfp4": {
            "prompt_tokens": 100,
            "completion_tokens": 10,
            "cached_tokens": 0,
            "requests": 1,
            "prefill_duration": 0.5,
            "generation_duration": 0.5,
        },
    },
}


def _samples(text: str, metric: str) -> list[str]:
    prefix = metric + "{"
    return [
        line
        for line in text.splitlines()
        if line.startswith(prefix) or line.startswith(metric + " ")
    ]


def test_parse_reads_global_and_per_model() -> None:
    stats = parse_stats(SAMPLE)
    assert stats.total.requests == 3
    assert set(stats.per_model) == set(SAMPLE["per_model"])
    assert stats.per_model["mlx-community__gemma-4-26b-a4b-nvfp4"].prompt_tokens == 100


def test_missing_and_malformed_fields_become_zero() -> None:
    stats = parse_stats({"total_requests": "not a number", "per_model": "not a dict"})
    assert stats.total.requests == 0
    assert stats.total.prompt_tokens == 0
    assert stats.per_model == {}


def test_processed_prompt_tokens_excludes_cache_hits() -> None:
    assert parse_stats(SAMPLE).total.processed_prompt_tokens == 200


def test_processed_prompt_tokens_never_goes_negative() -> None:
    # A counter that can decrease reads as a reset to Prometheus.
    counters = Counters(
        prompt_tokens=10,
        completion_tokens=0,
        cached_tokens=50,
        requests=1,
        prefill_duration=0.0,
        generation_duration=0.0,
    )
    assert counters.processed_prompt_tokens == 0


def test_render_emits_help_type_and_both_families() -> None:
    text = render(parse_stats(SAMPLE), stats_mtime=1000.0, now=1234.5)

    assert "# HELP omlx_requests_total" in text
    assert "# TYPE omlx_requests_total counter" in text
    assert "omlx_requests_total 3" in text.splitlines()

    per_model = _samples(text, "omlx_model_requests_total")
    assert len(per_model) == 2
    assert (
        'omlx_model_requests_total{model="mlx-community__Qwen3.6-35B-A3B-nvfp4"} 2'
        in per_model
    )

    assert "omlx_stats_file_mtime_seconds 1000" in text
    assert "omlx_stats_collected_timestamp_seconds 1234.5" in text


def test_per_model_series_sum_to_the_global_family() -> None:
    stats = parse_stats(SAMPLE)
    assert sum(c.requests for c in stats.per_model.values()) == stats.total.requests


def test_label_values_are_escaped() -> None:
    stats = parse_stats(
        {"per_model": {'we"ird\\model\n': {"requests": 1}}},
    )
    text = render(stats, stats_mtime=0.0, now=0.0)
    assert 'omlx_model_requests_total{model="we\\"ird\\\\model\\n"} 1' in text


def test_render_has_no_bare_float_repr_artifacts() -> None:
    # Whole-number floats must not render as "3.0" — harmless to Prometheus but
    # it makes diffing two snapshots noisy.
    text = render(parse_stats(SAMPLE), stats_mtime=1000.0, now=0.0)
    assert "omlx_prompt_tokens_total 300" in text.splitlines()


def test_non_finite_values_use_prometheus_spelling() -> None:
    stats = parse_stats({"total_prefill_duration": math.inf})
    text = render(stats, stats_mtime=0.0, now=0.0)
    assert "omlx_prefill_seconds_total +Inf" in text.splitlines()


def test_write_atomic_leaves_no_temp_files(tmp_path: Path) -> None:
    out = tmp_path / "sub" / "omlx.prom"
    write_atomic("hello\n", out)
    assert out.read_text() == "hello\n"
    assert sorted(p.name for p in out.parent.iterdir()) == ["omlx.prom"]


def test_write_atomic_overwrites_in_place(tmp_path: Path) -> None:
    out = tmp_path / "omlx.prom"
    write_atomic("first\n", out)
    write_atomic("second\n", out)
    assert out.read_text() == "second\n"


def test_written_file_is_world_readable(tmp_path: Path) -> None:
    out = tmp_path / "omlx.prom"
    write_atomic("x\n", out)
    assert out.stat().st_mode & 0o004


def test_collect_once_round_trips_a_real_file(tmp_path: Path) -> None:
    stats_path = tmp_path / "stats.json"
    stats_path.write_text(json.dumps(SAMPLE))
    out = tmp_path / "omlx.prom"

    text = collect_once(stats_path, out)

    assert out.read_text() == text
    assert "omlx_requests_total 3" in text.splitlines()


def test_collect_once_can_skip_writing(tmp_path: Path) -> None:
    stats_path = tmp_path / "stats.json"
    stats_path.write_text(json.dumps(SAMPLE))

    text = collect_once(stats_path, None)

    assert "omlx_requests_total 3" in text.splitlines()
    assert list(tmp_path.iterdir()) == [stats_path]


def test_load_stats_rejects_a_non_object_payload(tmp_path: Path) -> None:
    stats_path = tmp_path / "stats.json"
    stats_path.write_text("[]")
    with pytest.raises(ValueError, match="expected a JSON object"):
        load_stats(stats_path)
