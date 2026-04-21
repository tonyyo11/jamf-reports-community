"""Tests for LaunchAgent automation output selection."""

from __future__ import annotations

import json
from pathlib import Path

import pytest


@pytest.mark.integration
def test_launchagent_snapshot_only_generates_configured_outputs(
    config_factory,
    tmp_path: Path,
    monkeypatch,
    jrc,
) -> None:
    config = config_factory("dummy.yaml")
    config._data["automation"] = {
        "generate_xlsx": True,
        "generate_html": True,
        "generate_inventory_csv": True,
    }

    inventory_path = tmp_path / "automation_inventory_dummy.csv"
    report_path = tmp_path / "scheduled-report.xlsx"
    html_path = tmp_path / "scheduled-report.html"
    status_path = tmp_path / "status.json"
    calls: list[tuple[str, str]] = []

    monkeypatch.setattr(
        jrc,
        "_select_automation_csv",
        lambda *_args: (None, None, "", "No CSV selected"),
    )
    monkeypatch.setattr(jrc, "_collect_snapshots", lambda *_args: (1, False))

    def fake_inventory_csv(_config, out_file):
        calls.append(("inventory-csv", str(out_file)))
        inventory_path.write_text("serial\nABC123\n", encoding="utf-8")
        return inventory_path

    def fake_generate(_config, csv_path, out_file, historical_csv_dir, notify_url, csv_extra=None):
        del out_file, historical_csv_dir, notify_url, csv_extra
        calls.append(("generate", str(csv_path)))
        report_path.write_text("xlsx", encoding="utf-8")
        return report_path

    def fake_html(_config, out_file, no_open=False):
        del out_file
        calls.append(("html", str(no_open)))
        html_path.write_text("<html></html>", encoding="utf-8")
        return html_path

    monkeypatch.setattr(jrc, "cmd_inventory_csv", fake_inventory_csv)
    monkeypatch.setattr(jrc, "cmd_generate", fake_generate)
    monkeypatch.setattr(jrc, "cmd_html", fake_html)

    jrc.cmd_launchagent_run(
        config,
        "snapshot-only",
        None,
        14,
        None,
        str(status_path),
    )

    status = json.loads(status_path.read_text(encoding="utf-8"))
    assert status["success"] is True
    assert status["inventory_csv_path"] == str(inventory_path)
    assert status["report_path"] == str(report_path)
    assert status["xlsx_report_path"] == str(report_path)
    assert status["html_report_path"] == str(html_path)
    assert ("generate", str(inventory_path)) in calls


@pytest.mark.integration
def test_launchagent_jamf_cli_only_can_emit_html_without_xlsx(
    config_factory,
    tmp_path: Path,
    monkeypatch,
    jrc,
) -> None:
    config = config_factory("dummy.yaml")
    config._data["automation"] = {
        "generate_xlsx": False,
        "generate_html": True,
        "generate_inventory_csv": False,
    }
    status_path = tmp_path / "status.json"
    html_path = tmp_path / "scheduled-report.html"

    monkeypatch.setattr(
        jrc,
        "cmd_generate",
        lambda *_args, **_kwargs: pytest.fail("cmd_generate should not be called"),
    )
    monkeypatch.setattr(
        jrc,
        "cmd_inventory_csv",
        lambda *_args, **_kwargs: pytest.fail("cmd_inventory_csv should not be called"),
    )

    def fake_html(_config, out_file, no_open=False):
        del out_file
        assert no_open is True
        html_path.write_text("<html></html>", encoding="utf-8")
        return html_path

    monkeypatch.setattr(jrc, "cmd_html", fake_html)

    jrc.cmd_launchagent_run(
        config,
        "jamf-cli-only",
        None,
        14,
        None,
        str(status_path),
    )

    status = json.loads(status_path.read_text(encoding="utf-8"))
    assert status["success"] is True
    assert status["report_path"] is None
    assert status["xlsx_report_path"] is None
    assert status["html_report_path"] == str(html_path)


@pytest.mark.integration
def test_cmd_html_archives_older_timestamped_outputs(
    config_factory,
    tmp_path: Path,
    monkeypatch,
    jrc,
) -> None:
    config = config_factory("dummy.yaml")
    config._data["jamf_cli"]["enabled"] = True
    config._data["output"]["archive_enabled"] = True
    config._data["output"]["keep_latest_runs"] = 1
    config._data["output"]["timestamp_outputs"] = True

    output_dir = Path(config._data["output"]["output_dir"])
    output_dir.mkdir(parents=True, exist_ok=True)
    older_one = output_dir / "JamfReport_2026-04-01_010101.html"
    older_two = output_dir / "JamfReport_2026-04-02_010101.html"
    older_one.write_text("<html>old1</html>", encoding="utf-8")
    older_two.write_text("<html>old2</html>", encoding="utf-8")

    class FakeBridge:
        def is_available(self) -> bool:
            return True

    monkeypatch.setattr(jrc, "_build_jamf_cli_bridge", lambda *args, **kwargs: FakeBridge())

    def fake_generate(self):
        self._out_file.parent.mkdir(parents=True, exist_ok=True)
        self._out_file.write_text("<html>new</html>", encoding="utf-8")
        return self._out_file

    monkeypatch.setattr(jrc.HtmlReport, "generate", fake_generate)

    out_path = jrc.cmd_html(config, None, no_open=True)

    archive_dir = output_dir / "archive" / "JamfReport"
    assert out_path.exists()
    assert len(list(output_dir.glob("JamfReport_*.html"))) == 1
    archived_names = {path.name for path in archive_dir.glob("*.html")}
    assert older_one.name in archived_names
    assert older_two.name in archived_names
