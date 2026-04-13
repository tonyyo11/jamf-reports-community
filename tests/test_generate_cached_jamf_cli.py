"""Integration tests for cached jamf-cli workbook generation."""

from __future__ import annotations

import openpyxl
import pytest


@pytest.mark.integration
@pytest.mark.filterwarnings("ignore:No artists with labels found to put in legend")
def test_generate_from_committed_cached_jamf_cli_data(
    monkeypatch,
    config_factory,
    tmp_path,
    jrc,
) -> None:
    config = config_factory("dummy.yaml")
    config._data["jamf_cli"]["enabled"] = True
    config._data["jamf_cli"]["allow_live_overview"] = False
    monkeypatch.setattr(jrc, "_find_jamf_cli_binary", lambda: None)

    report_path = jrc.cmd_generate(config, None, str(tmp_path / "cached-jamf-cli.xlsx"))

    assert report_path.exists()
    workbook = openpyxl.load_workbook(report_path, data_only=False)
    expected = {
        "Fleet Overview",
        "Mobile Fleet Summary",
        "Security Posture",
        "Inventory Summary",
        "Device Compliance",
        "Patch Compliance",
        "Update Status",
        "Update Failures",
        "Report Sources",
    }
    assert expected.issubset(set(workbook.sheetnames))
