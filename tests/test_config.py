"""Tests for Config and ColumnMapper behavior."""

from __future__ import annotations

from pathlib import Path


def test_config_deep_merges_defaults(tmp_path: Path, jrc) -> None:
    config_path = tmp_path / "config.yaml"
    config_path.write_text(
        "columns:\n"
        "  computer_name: Device Name\n"
        "output:\n"
        "  output_dir: Custom Reports\n",
        encoding="utf-8",
    )

    config = jrc.Config(str(config_path))
    assert config.columns["computer_name"] == "Device Name"
    assert config.columns["serial_number"] == ""
    assert config.output["output_dir"] == "Custom Reports"
    assert config.output["keep_latest_runs"] == 10


def test_column_mapper_returns_empty_string_for_missing_values(jrc, config_factory) -> None:
    config = config_factory("dummy.yaml")
    mapper = jrc.ColumnMapper(config)
    row = jrc.pd.Series({"Computer Name": "Demo Mac", "Serial Number": None})
    assert mapper.get("computer_name") == "Computer Name"
    assert mapper.extract(row, "computer_name") == "Demo Mac"
    assert mapper.extract(row, "serial_number") == ""
    assert mapper.extract(row, "manager") == ""
