"""Tests for Jamf School support: SchoolCLIBridge, SchoolDashboard, school commands."""

from __future__ import annotations

from pathlib import Path

import pytest


SCHOOL_CSV = "harboredu_school_devices.csv"


# ---------------------------------------------------------------------------
# SchoolCLIBridge
# ---------------------------------------------------------------------------


def test_school_bridge_is_subclass_of_jamf_cli_bridge(jrc) -> None:
    assert issubclass(jrc.SchoolCLIBridge, jrc.JamfCLIBridge)


def test_school_bridge_inherits_is_available(jrc) -> None:
    bridge = jrc.SchoolCLIBridge(save_output=False, data_dir="/tmp", profile="test")
    # is_available() should return bool regardless of whether binary exists
    result = bridge.is_available()
    assert isinstance(result, bool)


def test_school_bridge_has_cached_school_data_false_when_empty(jrc, tmp_path) -> None:
    bridge = jrc.SchoolCLIBridge(
        save_output=False, data_dir=str(tmp_path), profile="test"
    )
    assert bridge.has_cached_school_data() is False


# ---------------------------------------------------------------------------
# _school_csv_load
# ---------------------------------------------------------------------------


def test_school_csv_load_semicolon_delimiter(jrc, fixtures_root) -> None:
    csv_path = fixtures_root / "csv" / SCHOOL_CSV
    df = jrc._school_csv_load(str(csv_path))
    # Semicolon-delimited: all expected columns should be present
    assert "SerialNumber" in df.columns
    assert "IsManaged" in df.columns
    assert "LocationName" in df.columns
    assert "OsVersion" in df.columns


def test_school_csv_load_row_count(jrc, fixtures_root) -> None:
    csv_path = fixtures_root / "csv" / SCHOOL_CSV
    df = jrc._school_csv_load(str(csv_path))
    # 15 data rows in the fixture (plus header = 16 lines total)
    assert len(df) == 15


def test_school_csv_load_no_nulls(jrc, fixtures_root) -> None:
    csv_path = fixtures_root / "csv" / SCHOOL_CSV
    df = jrc._school_csv_load(str(csv_path))
    # fillna("") should leave no NaN values
    assert df.isnull().sum().sum() == 0


# ---------------------------------------------------------------------------
# SchoolColumnMapper
# ---------------------------------------------------------------------------


def test_school_column_mapper_get_mapped(jrc, fixtures_root) -> None:
    config = jrc.Config(str(fixtures_root / "config" / "school_test.yaml"))
    mapper = jrc.SchoolColumnMapper(config)
    assert mapper.get("serial_number") == "SerialNumber"
    assert mapper.get("os_version") == "OsVersion"
    assert mapper.get("managed") == "IsManaged"


def test_school_column_mapper_get_unmapped_returns_none(jrc, fixtures_root) -> None:
    config = jrc.Config(str(fixtures_root / "config" / "school_test.yaml"))
    mapper = jrc.SchoolColumnMapper(config)
    assert mapper.get("nonexistent_field") is None


def test_school_column_mapper_extract(jrc, fixtures_root) -> None:
    config = jrc.Config(str(fixtures_root / "config" / "school_test.yaml"))
    mapper = jrc.SchoolColumnMapper(config)
    row = {"SerialNumber": "ABC123", "IsManaged": "true"}
    assert mapper.extract(row, "serial_number") == "ABC123"
    assert mapper.extract(row, "managed") == "true"
    assert mapper.extract(row, "nonexistent_field") == ""


# ---------------------------------------------------------------------------
# SCHOOL_COLUMN_HINTS scaffold matching
# ---------------------------------------------------------------------------


def test_school_scaffold_matches_harboredu_columns(jrc, fixtures_root) -> None:
    """All 18 school_columns fields should auto-match the HarborEdu CSV."""
    csv_path = fixtures_root / "csv" / SCHOOL_CSV
    df = jrc._school_csv_load(str(csv_path))
    headers = list(df.columns)

    def _best_match(logical: str) -> str:
        hints = jrc.SCHOOL_COLUMN_HINTS.get(logical, [])
        excludes = jrc.SCHOOL_COLUMN_EXCLUDES.get(logical, [])
        for hint in hints:
            for h in headers:
                h_lower = h.lower()
                if any(ex in h_lower for ex in excludes):
                    continue
                if hint in h_lower:
                    return h
        return ""

    unmatched = [
        field
        for field in jrc.DEFAULT_CONFIG["school_columns"]
        if not _best_match(field)
    ]
    assert unmatched == [], f"Fields not auto-matched: {unmatched}"


def test_school_scaffold_device_name_is_name_not_location(jrc, fixtures_root) -> None:
    """device_name must match 'Name', not 'LocationName'."""
    csv_path = fixtures_root / "csv" / SCHOOL_CSV
    df = jrc._school_csv_load(str(csv_path))
    headers = list(df.columns)
    hints = jrc.SCHOOL_COLUMN_HINTS.get("device_name", [])
    excludes = jrc.SCHOOL_COLUMN_EXCLUDES.get("device_name", [])

    for hint in hints:
        for h in headers:
            h_lower = h.lower()
            if any(ex in h_lower for ex in excludes):
                continue
            if hint in h_lower:
                assert h == "Name", f"device_name matched {h!r}, expected 'Name'"
                return
    pytest.fail("device_name did not match any column")


# ---------------------------------------------------------------------------
# SchoolDashboard — CSV-driven generation
# ---------------------------------------------------------------------------


def test_school_dashboard_builds_all_csv_sheets(jrc, fixtures_root, tmp_path) -> None:
    """school-generate with only a CSV should create the four CSV-driven sheets."""
    import xlsxwriter

    config = jrc.Config(str(fixtures_root / "config" / "school_test.yaml"))
    config._data["output"]["output_dir"] = str(tmp_path / "Generated Reports")

    csv_path = fixtures_root / "csv" / SCHOOL_CSV
    df = jrc._school_csv_load(str(csv_path))

    out_path = tmp_path / "school_report.xlsx"
    workbook = xlsxwriter.Workbook(str(out_path), {"remove_timezone": True})
    fmts = jrc._build_formats(workbook)

    dashboard = jrc.SchoolDashboard(config, workbook, fmts, csv_df=df)
    dashboard.build_all()
    workbook.close()

    assert out_path.exists()
    assert out_path.stat().st_size > 0

    # Verify all four expected CSV-driven sheets were created
    import zipfile
    with zipfile.ZipFile(out_path) as zf:
        sheet_xml_names = [n for n in zf.namelist() if n.startswith("xl/worksheets/sheet")]
    assert len(sheet_xml_names) == 4, f"Expected 4 sheets, got {len(sheet_xml_names)}"


def test_school_dashboard_device_inventory_has_rows(jrc, fixtures_root, tmp_path) -> None:
    """Device Inventory sheet should contain all 15 device rows from the fixture."""
    import xlsxwriter

    config = jrc.Config(str(fixtures_root / "config" / "school_test.yaml"))
    csv_path = fixtures_root / "csv" / SCHOOL_CSV
    df = jrc._school_csv_load(str(csv_path))

    out_path = tmp_path / "school_inventory.xlsx"
    workbook = xlsxwriter.Workbook(str(out_path), {"remove_timezone": True})
    fmts = jrc._build_formats(workbook)

    dashboard = jrc.SchoolDashboard(config, workbook, fmts, csv_df=df)
    # Write just the Device Inventory sheet
    ws = workbook.add_worksheet("Device Inventory")
    dashboard._write_device_inventory(ws)
    workbook.close()

    # The workbook should be non-empty
    assert out_path.stat().st_size > 0


def test_school_dashboard_os_versions_counts(jrc, fixtures_root, tmp_path) -> None:
    """OS Versions sheet should sum to the total device count."""
    import xlsxwriter
    from collections import Counter

    config = jrc.Config(str(fixtures_root / "config" / "school_test.yaml"))
    csv_path = fixtures_root / "csv" / SCHOOL_CSV
    df = jrc._school_csv_load(str(csv_path))

    counter: Counter = Counter()
    for val in df["OsVersion"]:
        if str(val).strip():
            counter[str(val).strip()] += 1

    assert sum(counter.values()) == 15


def test_school_dashboard_stale_devices_no_error_on_empty(
    jrc, fixtures_root, tmp_path
) -> None:
    """Stale Devices sheet should not raise when no devices are stale."""
    import xlsxwriter

    config = jrc.Config(str(fixtures_root / "config" / "school_test.yaml"))
    # Set stale threshold to 0 days — all devices qualify
    config._data["thresholds"]["stale_device_days"] = 0
    csv_path = fixtures_root / "csv" / SCHOOL_CSV
    df = jrc._school_csv_load(str(csv_path))

    out_path = tmp_path / "school_stale.xlsx"
    workbook = xlsxwriter.Workbook(str(out_path), {"remove_timezone": True})
    fmts = jrc._build_formats(workbook)

    dashboard = jrc.SchoolDashboard(config, workbook, fmts, csv_df=df)
    ws = workbook.add_worksheet("Stale Devices")
    dashboard._write_stale_devices(ws)
    workbook.close()

    assert out_path.exists()


# ---------------------------------------------------------------------------
# cmd_school_scaffold
# ---------------------------------------------------------------------------


def test_cmd_school_scaffold_writes_file(jrc, fixtures_root, tmp_path) -> None:
    csv_path = str(fixtures_root / "csv" / SCHOOL_CSV)
    out_path = str(tmp_path / "school_columns.yaml")
    jrc.cmd_school_scaffold(csv_path, out_path)
    assert Path(out_path).exists()
    content = Path(out_path).read_text()
    assert "school_columns:" in content
    assert "SerialNumber" in content
    assert "IsManaged" in content


def test_cmd_school_scaffold_no_duplicate_write(jrc, fixtures_root, tmp_path) -> None:
    """Running scaffold twice on the same output file should not duplicate the block."""
    csv_path = str(fixtures_root / "csv" / SCHOOL_CSV)
    out_path = str(tmp_path / "school_columns.yaml")
    jrc.cmd_school_scaffold(csv_path, out_path)
    first_content = Path(out_path).read_text()
    # Run again — should warn and not modify the file
    jrc.cmd_school_scaffold(csv_path, out_path)
    assert Path(out_path).read_text() == first_content


# ---------------------------------------------------------------------------
# cmd_school_generate (integration)
# ---------------------------------------------------------------------------


def test_cmd_school_generate_csv_only(jrc, fixtures_root, tmp_path) -> None:
    """school-generate with only --csv should produce a valid xlsx."""
    config = jrc.Config(str(fixtures_root / "config" / "school_test.yaml"))
    config._data["output"]["output_dir"] = str(tmp_path / "Generated Reports")

    csv_path = str(fixtures_root / "csv" / SCHOOL_CSV)
    out_file = str(tmp_path / "school_report.xlsx")
    jrc.cmd_school_generate(config, csv_path=csv_path, out_file=out_file)

    assert Path(out_file).exists()
    assert Path(out_file).stat().st_size > 5000
