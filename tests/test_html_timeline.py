"""Tests for HtmlReport macOS Adoption Timeline."""

from __future__ import annotations

import json
from pathlib import Path


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def _make_html_report(jrc, config_factory, tmp_path):
    """Return an HtmlReport instance wired to a dummy config and offline bridge."""
    config = config_factory("dummy.yaml")
    bridge = jrc.JamfCLIBridge(
        save_output=False,
        data_dir=str(tmp_path),
        use_cached_data=False,
    )
    return jrc.HtmlReport(config, bridge, tmp_path / "report.html", no_open=True)


def _make_history(entries: list[dict]) -> bytes:
    """Serialise a history list to JSON bytes."""
    return json.dumps(entries, indent=2).encode("utf-8")


# ---------------------------------------------------------------------------
# _build_timeline_data — fewer than 2 snapshots
# ---------------------------------------------------------------------------

def test_build_timeline_none_when_file_missing(jrc, config_factory, tmp_path) -> None:
    report = _make_html_report(jrc, config_factory, tmp_path)
    result = report._build_timeline_data(
        str(tmp_path / "nonexistent.json"),
        "https://example.jamfcloud.com",
    )
    assert result is None


def test_build_timeline_none_when_zero_snapshots(jrc, config_factory, tmp_path) -> None:
    history_path = tmp_path / "history.json"
    history_path.write_bytes(_make_history([]))
    report = _make_html_report(jrc, config_factory, tmp_path)
    result = report._build_timeline_data(
        str(history_path),
        "https://example.jamfcloud.com",
    )
    assert result is None


def test_build_timeline_none_when_one_snapshot(jrc, config_factory, tmp_path) -> None:
    history_path = tmp_path / "history.json"
    history_path.write_bytes(_make_history([
        {
            "ts": "2026-04-01T10:00:00Z",
            "instance": "https://example.jamfcloud.com",
            "versions": [{"v": "15.4", "c": 100}],
        }
    ]))
    report = _make_html_report(jrc, config_factory, tmp_path)
    result = report._build_timeline_data(
        str(history_path),
        "https://example.jamfcloud.com",
    )
    assert result is None


def test_build_timeline_none_when_wrong_instance(jrc, config_factory, tmp_path) -> None:
    history_path = tmp_path / "history.json"
    history_path.write_bytes(_make_history([
        {
            "ts": "2026-04-01T10:00:00Z",
            "instance": "https://other.jamfcloud.com",
            "versions": [{"v": "15.4", "c": 100}],
        },
        {
            "ts": "2026-04-08T10:00:00Z",
            "instance": "https://other.jamfcloud.com",
            "versions": [{"v": "15.4", "c": 105}],
        },
    ]))
    report = _make_html_report(jrc, config_factory, tmp_path)
    result = report._build_timeline_data(
        str(history_path),
        "https://example.jamfcloud.com",
    )
    assert result is None


def test_build_timeline_none_for_malformed_json(jrc, config_factory, tmp_path) -> None:
    history_path = tmp_path / "history.json"
    history_path.write_text("NOT JSON", encoding="utf-8")
    report = _make_html_report(jrc, config_factory, tmp_path)
    result = report._build_timeline_data(
        str(history_path),
        "https://example.jamfcloud.com",
    )
    assert result is None


# ---------------------------------------------------------------------------
# _build_timeline_data — 2+ snapshots
# ---------------------------------------------------------------------------

def _two_snapshot_history(instance: str = "https://example.jamfcloud.com") -> list[dict]:
    return [
        {
            "ts": "2026-04-01T10:00:00Z",
            "instance": instance,
            "versions": [
                {"v": "15.4", "c": 100},
                {"v": "14.7", "c": 50},
            ],
        },
        {
            "ts": "2026-04-08T10:00:00Z",
            "instance": instance,
            "versions": [
                {"v": "15.4", "c": 110},
                {"v": "14.7", "c": 45},
                {"v": "15.3", "c": 10},
            ],
        },
    ]


def test_build_timeline_returns_dict_for_two_snapshots(
    jrc, config_factory, tmp_path
) -> None:
    history_path = tmp_path / "history.json"
    history_path.write_bytes(_make_history(_two_snapshot_history()))
    report = _make_html_report(jrc, config_factory, tmp_path)
    result = report._build_timeline_data(
        str(history_path), "https://example.jamfcloud.com"
    )
    assert result is not None


def test_build_timeline_labels_match_timestamps(jrc, config_factory, tmp_path) -> None:
    history_path = tmp_path / "history.json"
    history_path.write_bytes(_make_history(_two_snapshot_history()))
    report = _make_html_report(jrc, config_factory, tmp_path)
    result = report._build_timeline_data(
        str(history_path), "https://example.jamfcloud.com"
    )
    assert result is not None
    assert result["labels"] == ["2026-04-01T10:00:00Z", "2026-04-08T10:00:00Z"]


def test_build_timeline_entry_count(jrc, config_factory, tmp_path) -> None:
    history_path = tmp_path / "history.json"
    history_path.write_bytes(_make_history(_two_snapshot_history()))
    report = _make_html_report(jrc, config_factory, tmp_path)
    result = report._build_timeline_data(
        str(history_path), "https://example.jamfcloud.com"
    )
    assert result is not None
    assert result["entry_count"] == 2


def test_build_timeline_dataset_structure(jrc, config_factory, tmp_path) -> None:
    history_path = tmp_path / "history.json"
    history_path.write_bytes(_make_history(_two_snapshot_history()))
    report = _make_html_report(jrc, config_factory, tmp_path)
    result = report._build_timeline_data(
        str(history_path), "https://example.jamfcloud.com"
    )
    assert result is not None
    datasets = result["datasets"]
    assert isinstance(datasets, list)
    assert len(datasets) >= 2
    for ds in datasets:
        assert "label" in ds
        assert "data" in ds
        assert "color" in ds
        assert len(ds["data"]) == 2


def test_build_timeline_versions_sorted_newest_first(jrc, config_factory, tmp_path) -> None:
    history_path = tmp_path / "history.json"
    history_path.write_bytes(_make_history(_two_snapshot_history()))
    report = _make_html_report(jrc, config_factory, tmp_path)
    result = report._build_timeline_data(
        str(history_path), "https://example.jamfcloud.com"
    )
    assert result is not None
    labels = [ds["label"] for ds in result["datasets"]]
    assert labels[0] >= labels[-1], "Versions should be sorted newest-first"


def test_build_timeline_missing_version_fills_zero(jrc, config_factory, tmp_path) -> None:
    """A version not present in a snapshot should contribute 0 for that point."""
    history_path = tmp_path / "history.json"
    history_path.write_bytes(_make_history(_two_snapshot_history()))
    report = _make_html_report(jrc, config_factory, tmp_path)
    result = report._build_timeline_data(
        str(history_path), "https://example.jamfcloud.com"
    )
    assert result is not None
    # 15.3 appears only in the second snapshot; first data point must be 0.
    ds_153 = next((ds for ds in result["datasets"] if ds["label"] == "15.3"), None)
    assert ds_153 is not None
    assert ds_153["data"][0] == 0
    assert ds_153["data"][1] == 10


# ---------------------------------------------------------------------------
# Version normalisation
# ---------------------------------------------------------------------------

def test_normalise_version_strips_trailing_zero(jrc, config_factory, tmp_path) -> None:
    report = _make_html_report(jrc, config_factory, tmp_path)
    assert report._normalise_version("15.4.0") == "15.4"
    assert report._normalise_version("15.4") == "15.4"
    assert report._normalise_version("14.7.0") == "14.7"
    assert report._normalise_version("14.7.1") == "14.7.1"


def test_normalise_version_does_not_strip_non_trailing(jrc, config_factory, tmp_path) -> None:
    report = _make_html_report(jrc, config_factory, tmp_path)
    assert report._normalise_version("10.0.1") == "10.0.1"


def test_version_sort_key_numeric(jrc, config_factory, tmp_path) -> None:
    report = _make_html_report(jrc, config_factory, tmp_path)
    versions = ["14.7", "15.4", "15.3", "26.0"]
    sorted_versions = sorted(versions, key=report._version_sort_key, reverse=True)
    assert sorted_versions[0] == "26.0"
    assert sorted_versions[-1] == "14.7"


def test_build_timeline_deduplicated_on_normalise(jrc, config_factory, tmp_path) -> None:
    """15.4.0 and 15.4 in the same snapshot should merge into a single dataset."""
    history_path = tmp_path / "history.json"
    history_path.write_bytes(_make_history([
        {
            "ts": "2026-04-01T10:00:00Z",
            "instance": "https://example.jamfcloud.com",
            "versions": [
                {"v": "15.4.0", "c": 60},
                {"v": "15.4", "c": 40},
            ],
        },
        {
            "ts": "2026-04-08T10:00:00Z",
            "instance": "https://example.jamfcloud.com",
            "versions": [
                {"v": "15.4", "c": 100},
            ],
        },
    ]))
    report = _make_html_report(jrc, config_factory, tmp_path)
    result = report._build_timeline_data(
        str(history_path), "https://example.jamfcloud.com"
    )
    assert result is not None
    labels = [ds["label"] for ds in result["datasets"]]
    # "15.4" and "15.4.0" both normalise to "15.4" — only one dataset
    assert labels.count("15.4") == 1
    ds_154 = next(ds for ds in result["datasets"] if ds["label"] == "15.4")
    # First snapshot: 60 + 40 = 100, second: 100
    assert ds_154["data"][0] == 100
    assert ds_154["data"][1] == 100


# ---------------------------------------------------------------------------
# _render_timeline_section
# ---------------------------------------------------------------------------

def test_render_timeline_section_empty_for_none(jrc, config_factory, tmp_path) -> None:
    report = _make_html_report(jrc, config_factory, tmp_path)
    assert report._render_timeline_section(None) == ""


def test_render_timeline_section_contains_title(jrc, config_factory, tmp_path) -> None:
    history_path = tmp_path / "history.json"
    history_path.write_bytes(_make_history(_two_snapshot_history()))
    report = _make_html_report(jrc, config_factory, tmp_path)
    timeline = report._build_timeline_data(
        str(history_path), "https://example.jamfcloud.com"
    )
    html = report._render_timeline_section(timeline)
    assert "macOS Adoption Timeline" in html
    assert "2 snapshots" in html
