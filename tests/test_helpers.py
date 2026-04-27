"""Unit tests for helper functions."""

from __future__ import annotations

from pathlib import Path

import openpyxl
import xlsxwriter


def test_parse_manager_extracts_cn_from_dn(jrc) -> None:
    raw = r"CN=SMITH\, JOHN,OU=People,DC=example,DC=com"
    assert jrc._parse_manager(raw) == "Smith, John"


def test_to_int_and_to_bool_handle_common_edge_cases(jrc) -> None:
    assert jrc._to_int("42.9") == 42
    assert jrc._to_int("abc", default=7) == 7
    assert jrc._to_bool("YES") is True
    assert jrc._to_bool("0") is False


def test_safe_write_sanitizes_formula_control_chars_and_inf(tmp_path: Path, jrc) -> None:
    workbook_path = tmp_path / "safe-write.xlsx"
    workbook = xlsxwriter.Workbook(str(workbook_path))
    worksheet = workbook.add_worksheet("Sheet1")

    jrc._safe_write(worksheet, 0, 0, "=SUM(1,2)")
    jrc._safe_write(worksheet, 1, 0, "hello\x00world")
    jrc._safe_write(worksheet, 2, 0, float("inf"))
    jrc._safe_write(worksheet, 3, 0, None)
    workbook.close()

    loaded = openpyxl.load_workbook(workbook_path, data_only=False)
    sheet = loaded["Sheet1"]
    assert sheet["A1"].value == "\t=SUM(1,2)"
    assert sheet["A1"].data_type == "s"
    assert sheet["A2"].value == "helloworld"
    assert sheet["A3"].value == 0
    assert sheet["A4"].value is None


def test_semantic_warnings_flags_managed_as_manager(jrc) -> None:
    config = jrc.Config(jrc.Config._WORKSPACE_INIT_DEFAULTS_NAME)
    config._data["columns"]["manager"] = "Managed"
    df = jrc.pd.DataFrame({"Managed": ["Managed", "Unmanaged"]})
    warnings = jrc._semantic_warnings(config, df)
    assert any("management-state column" in warning for warning in warnings)


def test_inventory_ea_results_are_optional(jrc) -> None:
    class FailingBridge:
        def ea_results_report(self, include_all: bool = True):
            raise RuntimeError("jamf-cli failed")

    ea_columns, unmatched, error = jrc._apply_inventory_ea_results(FailingBridge(), {})

    assert ea_columns == set()
    assert unmatched == 0
    assert "jamf-cli failed" in error


def test_collect_command_plan_includes_cli_only_surfaces(jrc) -> None:
    class FakeBridge:
        def __getattr__(self, _name: str):
            return lambda *args, **kwargs: None

    config = jrc.Config(jrc.Config._WORKSPACE_INIT_DEFAULTS_NAME)
    labels = [
        label
        for label, _command in jrc._collect_jamf_cli_commands(config, FakeBridge(), True)
    ]

    assert "Computer Inventory" in labels
    assert "App Status" in labels
    assert "Update Failures" in labels
    assert "Package Lifecycle" in labels
