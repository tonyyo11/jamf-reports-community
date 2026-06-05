"""Tests for trend-summary emission and helpers used by GUI trend rendering.

The CSV-driven branch of ``_emit_summary_json`` was previously not exercised
by tests. These tests cover:

* ``_percent_string_to_float`` parsing edge cases
* ``_emit_summary_json`` CSV branch (FileVault, compliance, OS-current,
  CrowdStrike) and ``--force-summary`` overwrite behavior
* ``_summary_file_entry`` distinguishing missing path (``None``) from a file
"""

from __future__ import annotations

import json
from typing import Any

import pytest


# ---------------------------------------------------------------------------
# _percent_string_to_float
# ---------------------------------------------------------------------------


@pytest.mark.parametrize(
    "raw,expected",
    [
        ("100%", 100.0),
        ("50.5%", 50.5),
        (" 12 % ", 12.0),
        ("0", 0.0),
        ("", 0.0),
        (None, 0.0),
        ("not a number", 0.0),
        (42, 42.0),
        (3.14, 3.14),
    ],
)
def test_percent_string_to_float(jrc, raw, expected) -> None:
    assert jrc._percent_string_to_float(raw) == expected


# ---------------------------------------------------------------------------
# _summary_file_entry
# ---------------------------------------------------------------------------


def test_summary_file_entry_returns_null_path_when_missing(jrc) -> None:
    entry = jrc._summary_file_entry("xlsx", None)
    assert entry["kind"] == "xlsx"
    assert entry["path"] is None
    assert entry["exists"] is False
    assert entry["size_bytes"] is None
    assert entry["modified_at"] is None
    # Round-trips through JSON as a real null, not an empty string.
    payload = json.loads(json.dumps(entry))
    assert payload["path"] is None


def test_summary_file_entry_records_existing_file(tmp_path, jrc) -> None:
    file_path = tmp_path / "report.xlsx"
    file_path.write_bytes(b"hello")
    entry = jrc._summary_file_entry("xlsx", file_path)
    assert entry["path"] == str(file_path)
    assert entry["exists"] is True
    assert entry["size_bytes"] == 5
    assert entry["modified_at"] is not None


def test_summary_file_entry_handles_nonexistent_path(tmp_path, jrc) -> None:
    missing = tmp_path / "does-not-exist.xlsx"
    entry = jrc._summary_file_entry("xlsx", missing)
    assert entry["path"] == str(missing)
    assert entry["exists"] is False
    assert entry["size_bytes"] is None


# ---------------------------------------------------------------------------
# _emit_summary_json — CSV branch
# ---------------------------------------------------------------------------


class _StubCSVDashboard:
    """Minimal stand-in for ``CSVDashboard`` exposing only what the summary needs."""

    def __init__(self, df, columns: dict[str, str]) -> None:
        self._df = df
        self._columns = columns

    def _col(self, logical: str) -> str | None:
        return self._columns.get(logical)


def _build_csv_config(jrc) -> Any:
    """Return a Config wired for the CSV summary path."""
    config = jrc.Config(jrc.Config._WORKSPACE_INIT_DEFAULTS_NAME)
    # Compliance failure-count column used by the second metric.
    config._data["compliance"]["failures_count_column"] = "Failures"
    # CrowdStrike agent — case-insensitive substring match on agent.name.
    config._data["security_agents"] = [{
        "name": "CrowdStrike Falcon",
        "column": "CrowdStrike Status",
        "connected_value": "Installed",
    }]
    # osCurrentPct is SOFA-driven (latest-within-major); point the SOFA cache
    # at the committed feed fixtures instead of a static current_versions list.
    config._data["sofa"] = {
        "enabled": True,
        "cache_dir": str(jrc.Path(__file__).resolve().parent / "fixtures" / "sofa"),
        "max_cache_age_hours": 10_000,
        "platforms": ["macos"],
    }
    config._data["thresholds"]["stale_device_days"] = 30
    return config


def test_emit_summary_csv_branch_computes_all_metrics(tmp_path, monkeypatch, jrc) -> None:
    pd = jrc.pd
    df = pd.DataFrame({
        "Computer Name": ["A", "B", "C", "D"],
        "FileVault 2 Status": ["Encrypted", "Encrypted", "Not Encrypted", "Encrypted"],
        "Failures": ["0", "0", "3", "0"],
        "Last Check-in": ["2026-04-28", "2026-04-28", "2025-01-01", ""],
        # 15.7.7 is the latest macOS 15.x in the SOFA fixture; 15.7.4 is behind.
        "Operating System": ["15.7.7", "15.7.7", "15.7.4", "15.7.7"],
        "CrowdStrike Status": ["Installed", "Installed", "Missing", "installed"],
    })
    config = _build_csv_config(jrc)
    config._data["columns"]["filevault"] = "FileVault 2 Status"
    config._data["columns"]["last_checkin"] = "Last Check-in"
    config._data["columns"]["operating_system"] = "Operating System"

    csv_dash = _StubCSVDashboard(df, {
        "filevault": "FileVault 2 Status",
        "last_checkin": "Last Check-in",
        "operating_system": "Operating System",
    })

    historical = tmp_path / "snapshots"
    fixed_now = jrc.datetime(2026, 4, 29, 12, 0, 0)

    class _FixedDateTime(jrc.datetime):
        @classmethod
        def now(cls, tz=None):  # noqa: D401 - mirror datetime.now
            return fixed_now if tz is None else fixed_now.replace(tzinfo=tz)

    monkeypatch.setattr(jrc, "datetime", _FixedDateTime)

    jrc._emit_summary_json(config, csv_dash, None, str(historical))

    summary_path = historical / "summaries" / "summary_2026-04-29.json"
    payload = json.loads(summary_path.read_text(encoding="utf-8"))

    assert payload["source"] == "csv"
    assert payload["totalDevices"] == 4
    # 3/4 encrypted -> 75%
    assert payload["fileVaultPct"] == 75.0
    # 3 devices with 0 failures -> 75%
    assert payload["compliancePct"] == 75.0
    # CrowdStrike is "Installed"/"installed" on 3 of 4 -> 75%
    assert payload["crowdstrikePct"] == 75.0
    # 3 of 4 are on the latest macOS 15.x (15.7.7) per SOFA -> 75%
    assert payload["osCurrentPct"] == 75.0
    # One blank check-in is treated as stale; 2026-04-28 is fresh; 2025-01-01 is stale.
    assert payload["staleCount"] == 2
    # No bridge supplied -> patchPct omitted (mirrors Swift `Double?` shape so
    # trend charts treat the metric as missing, not as a real 0% floor).
    assert "patchPct" not in payload


def test_emit_summary_csv_branch_idempotent_unless_forced(tmp_path, monkeypatch, jrc, capsys) -> None:
    pd = jrc.pd
    df = pd.DataFrame({
        "FileVault 2 Status": ["Encrypted"],
        "Failures": ["0"],
        "Last Check-in": ["2026-04-28"],
        "Operating System": ["15.7.3"],
        "CrowdStrike Status": ["Installed"],
    })
    config = _build_csv_config(jrc)
    config._data["columns"]["filevault"] = "FileVault 2 Status"
    config._data["columns"]["last_checkin"] = "Last Check-in"
    config._data["columns"]["operating_system"] = "Operating System"

    csv_dash = _StubCSVDashboard(df, {
        "filevault": "FileVault 2 Status",
        "last_checkin": "Last Check-in",
        "operating_system": "Operating System",
    })

    historical = tmp_path / "snapshots"
    fixed_now = jrc.datetime(2026, 4, 29, 12, 0, 0)

    class _FixedDateTime(jrc.datetime):
        @classmethod
        def now(cls, tz=None):
            return fixed_now if tz is None else fixed_now.replace(tzinfo=tz)

    monkeypatch.setattr(jrc, "datetime", _FixedDateTime)

    jrc._emit_summary_json(config, csv_dash, None, str(historical))
    summary_path = historical / "summaries" / "summary_2026-04-29.json"
    first_mtime = summary_path.stat().st_mtime_ns

    # Re-emit without force: payload preserved, console note printed, mtime unchanged.
    jrc._emit_summary_json(config, csv_dash, None, str(historical))
    captured = capsys.readouterr()
    assert "already exists" in captured.out
    assert "--force-summary" in captured.out
    assert summary_path.stat().st_mtime_ns == first_mtime

    # Mutate the dataframe and re-emit with force=True: file rewritten.
    df.loc[0, "FileVault 2 Status"] = "Not Encrypted"
    jrc._emit_summary_json(config, csv_dash, None, str(historical), force=True)
    payload = json.loads(summary_path.read_text(encoding="utf-8"))
    assert payload["fileVaultPct"] == 0.0


def test_emit_summary_returns_when_historical_dir_missing(jrc) -> None:
    # Should be a no-op without raising, and without creating directories.
    jrc._emit_summary_json(
        _build_csv_config(jrc),
        _StubCSVDashboard(jrc.pd.DataFrame(), {}),
        None,
        None,
    )


def test_emit_summary_returns_when_dataframe_empty(tmp_path, jrc) -> None:
    pd = jrc.pd
    config = _build_csv_config(jrc)
    csv_dash = _StubCSVDashboard(pd.DataFrame(), {})
    jrc._emit_summary_json(config, csv_dash, None, str(tmp_path / "snapshots"))
    summaries_dir = tmp_path / "snapshots" / "summaries"
    # Directory may exist (we mkdir before the early return) but no JSON should be written.
    if summaries_dir.exists():
        assert list(summaries_dir.glob("summary_*.json")) == []


def test_emit_summary_csv_branch_skips_misconfigured_metrics(tmp_path, monkeypatch, jrc) -> None:
    """Unmeasured metrics are omitted, not zero-filled.

    When CrowdStrike or OS-current aren't configured at all, their keys are
    absent from the summary JSON so the Swift TrendStore skips the point
    rather than plotting a false 0% floor. Measured metrics stay present.
    """
    pd = jrc.pd
    df = pd.DataFrame({
        "FileVault 2 Status": ["Encrypted", "Encrypted"],
        "Failures": ["0", "1"],
    })
    config = jrc.Config(jrc.Config._WORKSPACE_INIT_DEFAULTS_NAME)
    config._data["compliance"]["failures_count_column"] = "Failures"
    config._data["columns"]["filevault"] = "FileVault 2 Status"
    # No security_agents and no version-type macos EA — these metrics are omitted.
    csv_dash = _StubCSVDashboard(df, {"filevault": "FileVault 2 Status"})

    historical = tmp_path / "snapshots"
    fixed_now = jrc.datetime(2026, 4, 29, 12, 0, 0)

    class _FixedDateTime(jrc.datetime):
        @classmethod
        def now(cls, tz=None):
            return fixed_now if tz is None else fixed_now.replace(tzinfo=tz)

    monkeypatch.setattr(jrc, "datetime", _FixedDateTime)

    jrc._emit_summary_json(config, csv_dash, None, str(historical))
    payload = json.loads(
        (historical / "summaries" / "summary_2026-04-29.json").read_text(encoding="utf-8")
    )
    assert "crowdstrikePct" not in payload
    assert "osCurrentPct" not in payload
    assert payload["fileVaultPct"] == 100.0
    # 1 of 2 has zero failures -> 50%
    assert payload["compliancePct"] == 50.0


def test_emit_summary_csv_branch_omits_os_current_when_sofa_unavailable(
    tmp_path, monkeypatch, jrc
) -> None:
    """osCurrentPct is omitted (not crashed, not 0%) when SOFA data is absent.

    Exercises the offline/no-cache fallback: an OS column is mapped, but SOFA
    is disabled so the latest-per-major map is empty. The metric key must be
    omitted so the trend chart skips the point rather than plotting a false 0%.
    """
    pd = jrc.pd
    df = pd.DataFrame({
        "FileVault 2 Status": ["Encrypted"],
        "Failures": ["0"],
        "Operating System": ["15.7.7"],
    })
    config = jrc.Config(jrc.Config._WORKSPACE_INIT_DEFAULTS_NAME)
    config._data["compliance"]["failures_count_column"] = "Failures"
    config._data["columns"]["filevault"] = "FileVault 2 Status"
    config._data["columns"]["operating_system"] = "Operating System"
    # SOFA disabled -> latest_versions() returns [] -> no live curl, empty map.
    config._data["sofa"] = {"enabled": False}
    csv_dash = _StubCSVDashboard(df, {
        "filevault": "FileVault 2 Status",
        "operating_system": "Operating System",
    })

    historical = tmp_path / "snapshots"
    fixed_now = jrc.datetime(2026, 4, 29, 12, 0, 0)

    class _FixedDateTime(jrc.datetime):
        @classmethod
        def now(cls, tz=None):
            return fixed_now if tz is None else fixed_now.replace(tzinfo=tz)

    monkeypatch.setattr(jrc, "datetime", _FixedDateTime)

    jrc._emit_summary_json(config, csv_dash, None, str(historical))
    payload = json.loads(
        (historical / "summaries" / "summary_2026-04-29.json").read_text(encoding="utf-8")
    )
    assert "osCurrentPct" not in payload
    assert payload["fileVaultPct"] == 100.0


# ---------------------------------------------------------------------------
# _emit_summary_json — existing-file validation (Finding 4: three-way split)
# ---------------------------------------------------------------------------


@pytest.mark.parametrize(
    "bad_content,expected_phrase",
    [
        ("{not valid json", "corrupt — not valid JSON"),
        (json.dumps({"date": "2026-04-29"}), "valid JSON but incomplete"),
        (json.dumps(["date", "totalDevices", "source"]), "valid JSON but incomplete"),
    ],
    ids=["corrupt-json", "missing-required-key", "top-level-list"],
)
def test_emit_summary_regenerates_invalid_existing_file(
    tmp_path, monkeypatch, jrc, capsys, bad_content, expected_phrase
) -> None:
    """An invalid same-day summary is reported with a cause-specific warn and regenerated.

    The three failure branches (corrupt JSON, structurally-incomplete JSON,
    non-object JSON) each emit a distinct message and fall through to rewrite
    the file, rather than silently skipping on a bad existing summary.
    """
    pd = jrc.pd
    df = pd.DataFrame({"FileVault 2 Status": ["Encrypted"]})
    config = jrc.Config(jrc.Config._WORKSPACE_INIT_DEFAULTS_NAME)
    config._data["columns"]["filevault"] = "FileVault 2 Status"
    csv_dash = _StubCSVDashboard(df, {"filevault": "FileVault 2 Status"})

    historical = tmp_path / "snapshots"
    summaries_dir = historical / "summaries"
    summaries_dir.mkdir(parents=True)
    summary_path = summaries_dir / "summary_2026-04-29.json"
    summary_path.write_text(bad_content, encoding="utf-8")

    fixed_now = jrc.datetime(2026, 4, 29, 12, 0, 0)

    class _FixedDateTime(jrc.datetime):
        @classmethod
        def now(cls, tz=None):
            return fixed_now if tz is None else fixed_now.replace(tzinfo=tz)

    monkeypatch.setattr(jrc, "datetime", _FixedDateTime)

    # force=False — the validation branch only runs when not forced.
    jrc._emit_summary_json(config, csv_dash, None, str(historical))
    captured = capsys.readouterr()

    assert expected_phrase in captured.out
    assert "regenerating" in captured.out
    # The bad file was replaced with a valid, complete summary.
    payload = json.loads(summary_path.read_text(encoding="utf-8"))
    assert payload["date"] == "2026-04-29"
    assert payload["totalDevices"] == 1
    assert payload["source"] == "csv"
