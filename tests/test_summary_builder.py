"""Failure-branch tests for `_build_summary_from_bridge` and `_emit_summary_json`.

The summary builder emits `[warn]` log lines when individual bridge calls raise
and OMITS the affected metric's key from the emitted JSON. `totalDevices`
is always present; `staleCount` is omitted when device-compliance is
unavailable (unknown is not zero); the percentage metrics (`fileVaultPct`,
`osCurrentPct`, `patchPct`) are conditional. A failed bridge call leaves the
metric unmeasured, so its key is dropped rather than written as a false 0.0 —
the Swift `DailySummary` decoder treats a missing key as nil and skips the
point, whereas a present 0.0 would plot a false zero-floor on the trend chart.
A regression that silenced a warn line, swallowed the exception entirely, or
re-introduced zero-fill would slip past the positive tests in
`test_command_summaries.py`.

`_emit_summary_json` (CSV path) tests close the parallel branch: when the
bridge throws on `patch_status`, the CSV path must OMIT the `patchPct` key
(matching the Swift `Double?` shape) rather than write a false-zero floor.
"""

from __future__ import annotations

import inspect
import json
import re
from typing import Any


# Helper: a baseline stub bridge where every method returns reasonable data.
# Individual tests subclass to make one call raise.
class _BaselineBridge:
    """Always-succeeds bridge. Tests subclass and override one method to raise."""

    def is_available(self) -> bool:
        return True

    def security_report(self) -> list[dict[str, Any]]:
        return [
            {
                "section": "summary",
                "data": {
                    "total_devices": 100,
                    "filevault_encrypted_pct": "92.0%",
                },
            }
        ]

    def inventory_summary(self) -> list[dict[str, Any]]:
        # 15.7.7 is the latest macOS 15.x in the committed SOFA fixture, so the
        # whole fleet is "current" under the SOFA-driven osCurrentPct metric.
        return [{"os_version": "15.7.7", "count": 100}]

    def device_compliance(self) -> list[dict[str, Any]]:
        # staleCount now mirrors Swift: days_since_contact >= stale_days (30),
        # not the server `stale` flag. Two devices exceed the threshold.
        return [
            {"days_since_contact": "45"},
            {"days_since_contact": "5"},
            {"days_since_contact": "60"},
        ]

    def patch_status(self) -> list[dict[str, Any]]:
        return [{"compliance_pct": "80%"}, {"compliance_pct": "70%"}]


def _config_with_macos_ea(jrc, fixtures_root):
    """Build a config wired to the committed SOFA fixtures.

    The OS-adoption branch is now SOFA-driven (latest-within-major), so the
    config's ``sofa`` cache must point at the committed feed fixtures rather
    than relying on a static ``current_versions`` EA list.
    """
    config = jrc.Config(str(fixtures_root / "config" / "dummy.yaml"))
    config._data["sofa"] = {
        "enabled": True,
        "cache_dir": str(fixtures_root / "sofa"),
        "max_cache_age_hours": 10_000,
        "platforms": ["macos"],
    }
    return config


# -------------------------------------------------------------------
# security_report failure → fileVaultPct omitted, [warn] emitted.
# -------------------------------------------------------------------


def test_security_report_failure_omits_fv_pct_and_warns(jrc, fixtures_root, capsys) -> None:
    config = jrc.Config(str(fixtures_root / "config" / "dummy.yaml"))

    class BoomBridge(_BaselineBridge):
        def security_report(self) -> list[dict[str, Any]]:
            raise RuntimeError("simulated security_report failure")

    summary = jrc._build_summary_from_bridge(config, BoomBridge(), "2026-04-27")
    captured = capsys.readouterr()

    assert summary is not None, "totalDevices fallback via inventory_summary should keep summary non-None"
    assert "fileVaultPct" not in summary, "fileVaultPct must be omitted when security_report raises"
    assert "[warn]" in captured.out
    assert "security_report failed" in captured.out
    assert "fileVaultPct omitted (no data)" in captured.out


# -------------------------------------------------------------------
# inventory_summary failure (totalDevices fallback) → returns None, warn emitted.
# -------------------------------------------------------------------


def test_inventory_summary_failure_defaults_total_devices_and_warns(jrc, fixtures_root, capsys) -> None:
    config = jrc.Config(str(fixtures_root / "config" / "dummy.yaml"))

    class BoomBridge(_BaselineBridge):
        # security_report returns no summary section so total_devices stays 0,
        # forcing the inventory_summary fallback path.
        def security_report(self) -> list[dict[str, Any]]:
            return []

        def inventory_summary(self) -> list[dict[str, Any]]:
            raise RuntimeError("simulated inventory_summary failure")

    summary = jrc._build_summary_from_bridge(config, BoomBridge(), "2026-04-27")
    captured = capsys.readouterr()

    # When total_devices is 0 after both paths, the builder returns None per
    # design — the upstream caller skips the summary write rather than
    # emit a misleading totalDevices=0 trend point.
    assert summary is None
    assert "[warn]" in captured.out
    assert "inventory_summary failed" in captured.out
    assert "totalDevices defaulting to 0" in captured.out


# -------------------------------------------------------------------
# device_compliance failure → staleCount omitted (unknown, not zero), warn emitted.
# -------------------------------------------------------------------


def test_device_compliance_failure_omits_stale_count_and_warns(jrc, fixtures_root, capsys) -> None:
    config = jrc.Config(str(fixtures_root / "config" / "dummy.yaml"))

    class BoomBridge(_BaselineBridge):
        def device_compliance(self) -> list[dict[str, Any]]:
            raise RuntimeError("simulated device_compliance failure")

    summary = jrc._build_summary_from_bridge(config, BoomBridge(), "2026-04-27")
    captured = capsys.readouterr()

    assert summary is not None
    assert "staleCount" not in summary, (
        "staleCount must be omitted when device_compliance raises — unknown is not zero"
    )
    assert "[warn]" in captured.out
    assert "device_compliance failed" in captured.out
    assert "staleCount omitted (unknown)" in captured.out


# -------------------------------------------------------------------
# inventory_summary failure during OS adoption → osCurrentPct omitted, warn emitted.
# -------------------------------------------------------------------


def test_os_adoption_inventory_summary_failure_omits_pct_and_warns(jrc, fixtures_root, capsys) -> None:
    config = _config_with_macos_ea(jrc, fixtures_root)

    # We need security_report to succeed (so total_devices > 0 and we proceed
    # past the early return), and inventory_summary to succeed once (in the
    # security fallback path it's never called because total_devices already
    # came from security), then RAISE on the OS-adoption call.
    # The function calls bridge.inventory_summary() twice on different paths.
    # When security_report succeeds with total_devices, the only call to
    # inventory_summary is in the OS-adoption block.
    class BoomBridge(_BaselineBridge):
        def inventory_summary(self) -> list[dict[str, Any]]:
            raise RuntimeError("simulated inventory_summary failure (os adoption)")

    summary = jrc._build_summary_from_bridge(config, BoomBridge(), "2026-04-27")
    captured = capsys.readouterr()

    assert summary is not None
    assert "osCurrentPct" not in summary, "osCurrentPct must be omitted when inventory_summary raises"
    assert "[warn]" in captured.out
    assert "inventory_summary (os adoption) failed" in captured.out
    assert "osCurrentPct omitted (no data)" in captured.out


# -------------------------------------------------------------------
# patch_status failure → patchPct omitted, warn emitted.
# -------------------------------------------------------------------


def test_patch_status_failure_omits_patch_pct_and_warns(jrc, fixtures_root, capsys) -> None:
    config = jrc.Config(str(fixtures_root / "config" / "dummy.yaml"))

    class BoomBridge(_BaselineBridge):
        def patch_status(self) -> list[dict[str, Any]]:
            raise RuntimeError("simulated patch_status failure")

    summary = jrc._build_summary_from_bridge(config, BoomBridge(), "2026-04-27")
    captured = capsys.readouterr()

    assert summary is not None
    assert "patchPct" not in summary, "patchPct must be omitted when patch_status raises"
    assert "[warn]" in captured.out
    assert "patch_status failed" in captured.out
    assert "patchPct omitted (no data)" in captured.out


# -------------------------------------------------------------------
# Sanity: all-succeed baseline keeps every metric populated and emits no warns.
# Acts as a negative control for the failure-branch tests.
# -------------------------------------------------------------------


def test_all_bridge_calls_succeed_emits_no_warn_lines(jrc, fixtures_root, capsys) -> None:
    config = _config_with_macos_ea(jrc, fixtures_root)
    summary = jrc._build_summary_from_bridge(config, _BaselineBridge(), "2026-04-27")
    captured = capsys.readouterr()

    assert summary is not None
    assert summary["totalDevices"] == 100
    assert summary["fileVaultPct"] == 92.0
    assert summary["staleCount"] == 2
    assert summary["osCurrentPct"] == 100.0
    assert summary["patchPct"] == 75.0
    # The negative-control assertion: no warn line in the all-succeed path.
    assert "[warn]" not in captured.out, (
        "Baseline (all bridge calls succeed) must not emit any [warn] line; "
        f"got: {captured.out!r}"
    )


# -------------------------------------------------------------------
# _emit_summary_json (CSV path) — patch_status failure must OMIT patchPct.
# -------------------------------------------------------------------


class _StubCSVDashboard:
    """Minimal CSVDashboard stand-in exposing only what _emit_summary_json reads."""

    def __init__(self, df, columns: dict[str, str]) -> None:
        self._df = df
        self._columns = columns

    def _col(self, logical: str) -> str | None:
        return self._columns.get(logical)


def _build_minimal_csv_config(jrc) -> Any:
    """Build a Config that activates the CSV summary path without any custom EAs."""
    config = jrc.Config(jrc.Config._WORKSPACE_INIT_DEFAULTS_NAME)
    config._data["columns"]["filevault"] = "FileVault Status"
    config._data["columns"]["last_checkin"] = "Last Check-in"
    config._data["columns"]["operating_system"] = "OS Version"
    return config


def test_emit_summary_json_omits_patchpct_when_patch_status_fails(
    tmp_path, monkeypatch, jrc, capsys
) -> None:
    """CSV-path regression: bridge.patch_status() raises → patchPct OMITTED.

    Previously the CSV branch initialized patch_pct = 0.0 and unconditionally
    wrote `patchPct: 0.0` into the JSON. The Swift `DailySummary.patchPct` is
    `Double?`, so 0.0 was treated as a real data point and plotted as a 0%
    trend floor. Omitting the key keeps the Swift consumer's "missing metric"
    semantics intact.
    """
    pd = jrc.pd
    df = pd.DataFrame({
        "Computer Name": ["A", "B"],
        "FileVault Status": ["Encrypted", "Encrypted"],
        "Last Check-in": ["2026-04-28", "2026-04-28"],
        "OS Version": ["15.7.3", "15.7.3"],
    })
    config = _build_minimal_csv_config(jrc)
    csv_dash = _StubCSVDashboard(df, {
        "filevault": "FileVault Status",
        "last_checkin": "Last Check-in",
        "operating_system": "OS Version",
    })

    class BoomBridge(_BaselineBridge):
        def patch_status(self) -> list[dict[str, Any]]:
            raise RuntimeError("simulated patch_status failure")

    historical = tmp_path / "snapshots"
    fixed_now = jrc.datetime(2026, 5, 16, 12, 0, 0)

    class _FixedDateTime(jrc.datetime):
        @classmethod
        def now(cls, tz=None):
            return fixed_now if tz is None else fixed_now.replace(tzinfo=tz)

    monkeypatch.setattr(jrc, "datetime", _FixedDateTime)

    jrc._emit_summary_json(config, csv_dash, BoomBridge(), str(historical))

    summary_path = historical / "summaries" / "summary_2026-05-16.json"
    payload = json.loads(summary_path.read_text(encoding="utf-8"))
    captured = capsys.readouterr()

    # patchPct MUST be omitted, not written as 0.0.
    assert "patchPct" not in payload, (
        "patchPct must be omitted when patch_status raises; "
        f"writing 0.0 would plot a false zero-floor in trends. payload={payload!r}"
    )
    # Warn is required for visibility.
    assert "[warn]" in captured.out
    assert "patch_status failed" in captured.out
    assert "patchPct omitted" in captured.out
    # The other CSV-path metrics must still be present (regression guard for the
    # rewrite — we only changed the patchPct treatment).
    assert payload["totalDevices"] == 2
    assert payload["fileVaultPct"] == 100.0
    assert payload["source"] == "csv"


# -------------------------------------------------------------------
# _emit_summary_json (CSV path) — staleCount omitted when no check-in column.
# -------------------------------------------------------------------


def test_emit_summary_json_omits_stale_count_without_checkin_column(
    tmp_path, monkeypatch, jrc
) -> None:
    """CSV-path regression: no last_checkin mapping → staleCount OMITTED.

    Previously the CSV branch initialized stale_count = 0 and wrote it
    unconditionally, so a workspace whose CSV has no check-in column persisted
    a measured-looking "0 stale devices" — the unknown-is-not-zero class this
    cycle fixed on the bridge path (review finding on PR #187).
    """
    pd = jrc.pd
    df = pd.DataFrame({
        "Computer Name": ["A", "B"],
        "FileVault Status": ["Encrypted", "Encrypted"],
    })
    config = _build_minimal_csv_config(jrc)
    # No last_checkin in the mapper: _col("last_checkin") returns None.
    csv_dash = _StubCSVDashboard(df, {"filevault": "FileVault Status"})

    historical = tmp_path / "snapshots"
    fixed_now = jrc.datetime(2026, 5, 16, 12, 0, 0)

    class _FixedDateTime(jrc.datetime):
        @classmethod
        def now(cls, tz=None):
            return fixed_now if tz is None else fixed_now.replace(tzinfo=tz)

    monkeypatch.setattr(jrc, "datetime", _FixedDateTime)

    jrc._emit_summary_json(config, csv_dash, _BaselineBridge(), str(historical))

    summary_path = historical / "summaries" / "summary_2026-05-16.json"
    payload = json.loads(summary_path.read_text(encoding="utf-8"))
    assert "staleCount" not in payload, (
        "staleCount must be omitted when the CSV has no check-in column — "
        f"unknown is not zero. payload={payload!r}"
    )
    assert payload["totalDevices"] == 2


def test_emit_summary_json_counts_stale_with_checkin_column(
    tmp_path, monkeypatch, jrc
) -> None:
    """Measured branch still measures: an old check-in date counts as stale."""
    pd = jrc.pd
    df = pd.DataFrame({
        "Computer Name": ["A", "B"],
        "Last Check-in": ["2026-05-15", "2025-01-01"],
    })
    config = _build_minimal_csv_config(jrc)
    csv_dash = _StubCSVDashboard(df, {"last_checkin": "Last Check-in"})

    historical = tmp_path / "snapshots"
    fixed_now = jrc.datetime(2026, 5, 16, 12, 0, 0)

    class _FixedDateTime(jrc.datetime):
        @classmethod
        def now(cls, tz=None):
            return fixed_now if tz is None else fixed_now.replace(tzinfo=tz)

    monkeypatch.setattr(jrc, "datetime", _FixedDateTime)

    jrc._emit_summary_json(config, csv_dash, _BaselineBridge(), str(historical))

    summary_path = historical / "summaries" / "summary_2026-05-16.json"
    payload = json.loads(summary_path.read_text(encoding="utf-8"))
    assert payload["staleCount"] == 1


# -------------------------------------------------------------------
# collectionSources (R4 provenance map) — Swift parity.
#
# The map records, per digest input, whether the value was fetched live this
# run ("live"), served from an older cached snapshot ("cache"), never fetched
# ("absent"), or fetched with an unrecognized mode ("unknown"). ea-results is
# gated on a configured mSCP baseline (mirrors Swift !eaBaselines.isEmpty);
# the other four kinds are unconditional.
# -------------------------------------------------------------------


class _SourceInfoBridge(_BaselineBridge):
    """Baseline bridge that also exposes ``source_info(kind) -> {"mode": ...}``."""

    def __init__(self, modes: dict[str, str | None]) -> None:
        self._modes = modes

    def source_info(self, kind: str) -> dict[str, Any]:
        # Mirror the real bridge: an unfetched kind returns {} (no "mode" key).
        mode = self._modes.get(kind)
        return {"mode": mode} if mode is not None else {}


def test_collection_sources_maps_live_and_cache(jrc, fixtures_root) -> None:
    config = _config_with_macos_ea(jrc, fixtures_root)
    bridge = _SourceInfoBridge({
        "security": "live",
        "device-compliance": "cached-fallback",
        "inventory-summary": "live",
        "patch-status": "cached",
    })
    summary = jrc._build_summary_from_bridge(config, bridge, "2026-04-27")

    assert summary is not None
    sources = summary["collectionSources"]
    assert sources["security"] == "live"
    assert sources["inventory-summary"] == "live"
    assert sources["device-compliance"] == "cache"
    assert sources["patch-status"] == "cache"


def test_collection_sources_omits_ea_results_without_baseline(jrc, fixtures_root) -> None:
    # dummy.yaml has failures_count_column "" and no baselines list, so
    # _mscp_resolved_baselines() is empty → ea-results must NOT be queried.
    config = _config_with_macos_ea(jrc, fixtures_root)
    assert jrc._mscp_resolved_baselines(config.compliance) == [], (
        "fixture must have no resolvable baseline for this gate test"
    )
    bridge = _SourceInfoBridge({
        "security": "live",
        "device-compliance": "live",
        "inventory-summary": "live",
        "patch-status": "live",
        "ea-results": "live",
    })
    summary = jrc._build_summary_from_bridge(config, bridge, "2026-04-27")

    assert summary is not None
    sources = summary["collectionSources"]
    assert "ea-results" not in sources, "ea-results must be gated behind a baseline"
    assert set(sources) == {
        "security", "device-compliance", "inventory-summary", "patch-status"
    }


def test_collection_sources_includes_ea_results_with_baseline(jrc, fixtures_root) -> None:
    config = _config_with_macos_ea(jrc, fixtures_root)
    config._data["compliance"]["failures_count_column"] = "mSCP Failures"
    assert jrc._mscp_resolved_baselines(config.compliance), "baseline should resolve"
    bridge = _SourceInfoBridge({
        "security": "live",
        "device-compliance": "live",
        "inventory-summary": "live",
        "patch-status": "live",
        "ea-results": "cached-fallback",
    })
    summary = jrc._build_summary_from_bridge(config, bridge, "2026-04-27")

    assert summary is not None
    assert summary["collectionSources"]["ea-results"] == "cache"


def test_collection_sources_unknown_and_absent_modes(jrc, fixtures_root) -> None:
    config = _config_with_macos_ea(jrc, fixtures_root)
    bridge = _SourceInfoBridge({
        "security": "weird-new-mode",  # unrecognized non-None → "unknown"
        "device-compliance": "live",
        # inventory-summary / patch-status omitted → source_info returns {} → absent
    })
    summary = jrc._build_summary_from_bridge(config, bridge, "2026-04-27")

    assert summary is not None
    sources = summary["collectionSources"]
    assert sources["security"] == "unknown"
    assert sources["device-compliance"] == "live"
    assert sources["inventory-summary"] == "absent"
    assert sources["patch-status"] == "absent"


def test_collection_sources_absent_when_bridge_lacks_source_info(jrc, fixtures_root) -> None:
    # _BaselineBridge has no source_info method → getattr guard → key omitted.
    config = _config_with_macos_ea(jrc, fixtures_root)
    summary = jrc._build_summary_from_bridge(config, _BaselineBridge(), "2026-04-27")

    assert summary is not None
    assert "collectionSources" not in summary


# -------------------------------------------------------------------
# staleCount omitted on the non-raising exhausted-cache path.
#
# device_compliance() returning None (cache exhausted, no live data — distinct
# from raising) must leave staleCount unknown, not write a measured 0.
# -------------------------------------------------------------------


def test_stale_count_omitted_when_device_compliance_returns_none(jrc, fixtures_root) -> None:
    config = jrc.Config(str(fixtures_root / "config" / "dummy.yaml"))

    class NoneBridge(_BaselineBridge):
        def device_compliance(self) -> None:
            return None

    summary = jrc._build_summary_from_bridge(config, NoneBridge(), "2026-04-27")

    assert summary is not None
    assert "staleCount" not in summary, (
        "device_compliance() -> None is the exhausted-cache path; staleCount "
        "stays unknown rather than a false measured 0"
    )


# -------------------------------------------------------------------
# Kinds-parity pin: every kind the summary builder queries must be a real
# report_type the bridge records under _run_and_save("<kind>", ...).
# -------------------------------------------------------------------


def test_collection_source_kinds_match_bridge_report_types(jrc) -> None:
    """Each queried kind is a first-arg of a _run_and_save call in the module.

    Reading the module source (vs hardcoding a parallel list) keeps the pin
    coupled to the real bridge wiring: rename a report_type and this fails
    unless the summary builder's kind literal is renamed too. ``ea-results``
    is recorded by ``ea_results_report`` (the saving variant); the bare
    ``ea_results`` method intentionally does not cache.
    """
    source = inspect.getsource(jrc)
    recorded = set(re.findall(r'_run_and_save\(\s*["\']([\w-]+)["\']', source))
    for kind in ("security", "device-compliance", "inventory-summary",
                 "patch-status", "ea-results"):
        assert kind in recorded, (
            f"summary builder queries source_info({kind!r}) but no "
            f"_run_and_save({kind!r}, ...) records it — provenance would be a "
            "permanent 'absent'"
        )
