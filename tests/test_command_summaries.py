"""Tests for app-facing command summary JSON files."""

from __future__ import annotations

import json
from pathlib import Path

import pytest


@pytest.mark.integration
@pytest.mark.filterwarnings("ignore:No artists with labels found to put in legend")
def test_generate_writes_summary_json(config_factory, monkeypatch, tmp_path, jrc) -> None:
    """generate can emit a stable summary alongside normal console output."""
    config = config_factory("dummy.yaml")
    config._data["jamf_cli"]["enabled"] = True
    config._data["jamf_cli"]["allow_live_overview"] = False
    monkeypatch.setattr(jrc, "_find_jamf_cli_binary", lambda: None)

    summary_path = tmp_path / "generate-summary.json"
    report_path = jrc.cmd_generate(
        config,
        None,
        str(tmp_path / "cached-jamf-cli.xlsx"),
        summary_json=str(summary_path),
    )

    payload = json.loads(summary_path.read_text(encoding="utf-8"))
    assert payload["schema_version"] == 1
    assert payload["command"] == "generate"
    assert payload["status"] == "ok"
    assert payload["outputs"][0]["path"] == str(report_path)
    assert payload["outputs"][0]["exists"] is True
    assert payload["counts"]["sheets_written"] >= 1
    assert "Report Sources" in payload["sheets"]["all"]


def test_generate_skips_trend_summary_when_workbook_close_fails(
    config_factory,
    monkeypatch,
    tmp_path,
    jrc,
    fixtures_root,
) -> None:
    """A failed xlsxwriter finalization must not leave a trend summary behind."""
    config = config_factory("dummy.yaml")
    config._data["jamf_cli"]["enabled"] = False
    config._data["charts"]["enabled"] = False

    def fail_close(self) -> None:
        raise RuntimeError("simulated workbook close failure")

    monkeypatch.setattr(jrc.xlsxwriter.Workbook, "close", fail_close)

    report_path = tmp_path / "broken-report.xlsx"
    historical_dir = tmp_path / "snapshots"
    with pytest.raises(RuntimeError, match="simulated workbook close failure"):
        jrc.cmd_generate(
            config,
            str(fixtures_root / "csv" / "dummy_all_macs.csv"),
            str(report_path),
            str(historical_dir),
        )

    summaries_dir = historical_dir / "summaries"
    assert not report_path.exists()
    assert not summaries_dir.exists() or list(summaries_dir.glob("summary_*.json")) == []


def test_collect_writes_summary_json(config_factory, monkeypatch, tmp_path, jrc) -> None:
    """collect can summarize snapshot and archive counts for the app."""
    config = config_factory("dummy.yaml")
    summary_path = tmp_path / "collect-summary.json"
    monkeypatch.setattr(jrc, "_collect_snapshots", lambda *_args: (3, True))

    jrc.cmd_collect(config, summary_json=str(summary_path))

    payload = json.loads(summary_path.read_text(encoding="utf-8"))
    assert payload["command"] == "collect"
    assert payload["status"] == "ok"
    assert payload["counts"]["collected_snapshots"] == 3
    assert payload["counts"]["archived_csv"] == 1


def test_school_generate_writes_summary_json(jrc, fixtures_root, tmp_path) -> None:
    """school-generate can summarize workbook output and written sheets."""
    config = jrc.Config(str(fixtures_root / "config" / "school_test.yaml"))
    config._data["output"]["output_dir"] = str(tmp_path / "Generated Reports")
    csv_path = str(fixtures_root / "csv" / "harboredu_school_devices.csv")
    out_file = str(tmp_path / "school_report.xlsx")
    summary_path = tmp_path / "school-generate-summary.json"

    jrc.cmd_school_generate(
        config,
        csv_path=csv_path,
        out_file=out_file,
        summary_json=str(summary_path),
    )

    payload = json.loads(summary_path.read_text(encoding="utf-8"))
    assert payload["command"] == "school-generate"
    assert payload["status"] == "ok"
    assert payload["outputs"][0]["path"] == out_file
    assert payload["counts"]["sheets_written"] >= 1
    assert payload["counts"]["csv_rows"] >= 1


def test_school_collect_writes_summary_json(monkeypatch, tmp_path, jrc, fixtures_root) -> None:
    """school-collect can summarize collected and failed School snapshots."""
    config = jrc.Config(str(fixtures_root / "config" / "school_test.yaml"))
    summary_path = tmp_path / "school-collect-summary.json"

    class FakeBridge:
        _profile = "school-test"
        _data_dir = tmp_path / "school-data"

        def is_available(self) -> bool:
            return True

        def overview(self) -> list[dict[str, str]]:
            return []

        def devices_list(self) -> list[dict[str, str]]:
            return []

        def device_groups_list(self) -> list[dict[str, str]]:
            return []

        def users_list(self) -> list[dict[str, str]]:
            return []

        def groups_list(self) -> list[dict[str, str]]:
            return []

        def classes_list(self) -> list[dict[str, str]]:
            return []

        def apps_list(self) -> list[dict[str, str]]:
            return []

        def profiles_list(self) -> list[dict[str, str]]:
            return []

        def locations_list(self) -> list[dict[str, str]]:
            return []

    monkeypatch.setattr(jrc, "_build_school_bridge", lambda _config: FakeBridge())

    jrc.cmd_school_collect(config, summary_json=str(summary_path))

    payload = json.loads(summary_path.read_text(encoding="utf-8"))
    assert payload["command"] == "school-collect"
    assert payload["status"] == "ok"
    assert payload["counts"]["requested_snapshots"] == 9
    assert payload["counts"]["collected_snapshots"] == 9


def test_build_summary_from_bridge_omits_csv_only_metrics(jrc, fixtures_root) -> None:
    """Bridge-mode summaries omit fields that need CSV data.

    `compliancePct` and `crowdstrikePct` cannot be derived from jamf-cli alone.
    Emitting them as 0.0 produces a flat-line trend that users mistake for a
    real reading. The Swift `DailySummary` decoder treats them as `Double?` and
    `TrendStore` skips nil points; the Python side must therefore omit the keys
    rather than emitting zeros.
    """
    config = jrc.Config(str(fixtures_root / "config" / "dummy.yaml"))

    class StubBridge:
        def is_available(self) -> bool:
            return True

        def security_report(self) -> list[dict[str, object]]:
            return [{
                "section": "summary",
                "data": {"total_devices": 50, "filevault_encrypted_pct": "92.0%"},
            }]

        def inventory_summary(self) -> list[dict[str, object]]:
            return [{"os_version": "15.7.3", "count": 50}]

        def device_compliance(self) -> list[dict[str, object]]:
            return [{"stale": True}, {"stale": False}]

        def patch_status(self) -> list[dict[str, object]]:
            return [{"compliance_pct": "80%"}]

    summary = jrc._build_summary_from_bridge(config, StubBridge(), "2026-04-27")

    assert summary is not None
    assert summary["source"] == "jamf-cli"
    assert "compliancePct" not in summary
    assert "crowdstrikePct" not in summary
    assert summary["totalDevices"] == 50
    assert summary["fileVaultPct"] == 92.0
