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
        "Package Lifecycle",
        "Patch Compliance",
        "Smart Groups",
        "Update Status",
        "Update Failures",
        "Report Sources",
    }
    assert expected.issubset(set(workbook.sheetnames))
    sheet = workbook["Smart Groups"]
    assert sheet["A4"].value == "Group Name"
    assert sheet["A5"].value == "3PL AMR Security Profile - 2.0 60 Minute Screensaver"
    assert sheet["B5"].value == "Computer"
    assert sheet["C5"].value == "No"
    assert sheet["D5"].value == 0
    assert sheet["G5"].value == "Zero members"

    package_sheet = workbook["Package Lifecycle"]
    assert package_sheet["A1"].value == "Package Lifecycle"
    assert "jamf-cli pro packages list" in str(package_sheet["A2"].value)
    assert package_sheet["A4"].value == "Total Packages"
    assert package_sheet["B4"].value == 12
    assert package_sheet["A6"].value == "Package Name"
    assert package_sheet["A7"].value == "AdobeAcrobatPro11CC_2014-08-06.pkg"
    notes = [package_sheet[f"G{row}"].value for row in range(7, 19)]
    assert "Reboot required" in notes


@pytest.mark.integration
def test_generate_self_contained_html_from_cached_jamf_cli_data(
    monkeypatch,
    config_factory,
    tmp_path,
    jrc,
) -> None:
    config = config_factory("dummy.yaml")
    config._data["jamf_cli"]["enabled"] = True
    config._data["jamf_cli"]["allow_live_overview"] = False
    monkeypatch.setattr(jrc, "_find_jamf_cli_binary", lambda: None)

    html_path = tmp_path / "cached-jamf-cli.html"
    jrc.cmd_html(config, str(html_path), no_open=True)

    html = html_path.read_text(encoding="utf-8")
    assert "cdn.jsdelivr.net" not in html
    assert '<script src="' not in html
    assert "Report Sources" in html
    assert "const safeCsvValue" in html
    assert "innerHTML =" not in html
    assert '<svg class="trend-svg"' in html
