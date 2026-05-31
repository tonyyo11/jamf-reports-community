"""Tests for jamf-cli 1.18 group/saved-search bridges and core sheets.

Covers:
- advanced-mobile-device-searches bridge JSON parse + sheet rendering
- classic-computer-groups / classic-mobile-device-groups bridge parse
- Computer Group Inventory / Mobile Device Groups sheets (smart/static split)
- empty-results edge for the advanced-search sheet
"""

from __future__ import annotations

import json
from pathlib import Path

import pytest

openpyxl = pytest.importorskip("openpyxl")
xlsxwriter = pytest.importorskip("xlsxwriter")


def _make_bridge(jrc, data_dir: Path):
    """Build a bridge pinned to cached fixtures.

    ``_run`` is forced to raise so every call falls back to the seeded
    snapshot — otherwise an installed jamf-cli on PATH would issue a live
    request and bypass the committed fixture.
    """
    bridge = jrc.JamfCLIBridge(
        save_output=False,
        data_dir=str(data_dir),
        profile="",
        use_cached_data=True,
    )

    def _no_live(args, timeout=None):
        raise RuntimeError("live calls disabled in test")

    bridge._run = _no_live  # type: ignore[assignment]
    return bridge


def _seed_cache(fixtures_root: Path, tmp_path: Path, key: str) -> Path:
    """Copy a committed fixture command dir into a tmp jamf-cli-data layout."""
    src = fixtures_root / "jamf-cli-data" / key
    data_dir = tmp_path / "jamf-cli-data"
    dst = data_dir / key
    dst.mkdir(parents=True)
    for f in src.glob("*.json"):
        (dst / f.name).write_text(f.read_text())
    return data_dir


def _seed_inline(tmp_path: Path, key: str, payload) -> Path:
    """Write an inline payload as a single cached snapshot."""
    data_dir = tmp_path / "jamf-cli-data"
    dst = data_dir / key
    dst.mkdir(parents=True)
    (dst / f"{key}_2026-01-01T000000.json").write_text(json.dumps(payload))
    return data_dir


def _render_sheet(jrc, bridge, writer_name: str, sheet_name: str, tmp_path: Path):
    """Run a CoreDashboard writer and return the worksheet's cell values."""
    out = tmp_path / "out.xlsx"
    wb = xlsxwriter.Workbook(str(out), {"remove_timezone": True})
    fmts = jrc._build_formats(wb)
    config = jrc.Config(jrc.Config._WORKSPACE_INIT_DEFAULTS_NAME)
    dash = jrc.CoreDashboard(config, bridge, wb, fmts)
    getattr(dash, writer_name)()
    wb.close()

    book = openpyxl.load_workbook(str(out))
    ws = book[sheet_name]
    values = []
    for r in ws.iter_rows():
        for cell in r:
            if cell.value is not None:
                values.append(cell.value)
    return values


# --- Advanced mobile-device searches -------------------------------------


def test_advanced_mobile_searches_bridge_parses_envelope(jrc, fixtures_root, tmp_path):
    data_dir = _seed_cache(fixtures_root, tmp_path, "advanced-mobile-device-searches")
    bridge = _make_bridge(jrc, data_dir)
    out = bridge.advanced_mobile_device_searches_list()
    assert isinstance(out, dict)
    assert out["totalCount"] == 2
    assert isinstance(out["results"], list)
    assert out["results"][0]["name"] == "All Devices"


def test_advanced_mobile_searches_sheet_rows(jrc, fixtures_root, tmp_path):
    data_dir = _seed_cache(fixtures_root, tmp_path, "advanced-mobile-device-searches")
    bridge = _make_bridge(jrc, data_dir)
    values = _render_sheet(
        jrc, bridge, "_write_advanced_mobile_searches", "Advanced Mobile Searches", tmp_path,
    )
    assert "All Devices" in values
    assert "Last Inventory 7+ Days" in values
    # Both live searches carry siteId "-1" -> All Sites.
    assert "All Sites" in values
    # criteria/display-field counts are integers
    assert 0 in values  # "All Devices" has zero criteria
    assert 1 in values  # "Last Inventory 7+ Days" has one criterion
    assert 6 in values  # "All Devices" has six display fields


def test_advanced_mobile_searches_empty_results(jrc, tmp_path):
    data_dir = _seed_inline(
        tmp_path, "advanced-mobile-device-searches", {"totalCount": 0, "results": []}
    )
    bridge = _make_bridge(jrc, data_dir)
    values = _render_sheet(
        jrc, bridge, "_write_advanced_mobile_searches", "Advanced Mobile Searches", tmp_path,
    )
    # Header still rendered; no data rows beyond the column headers.
    assert "Search Name" in values
    assert "Criteria Count" in values


# --- Classic computer / mobile-device groups -----------------------------


def test_classic_computer_groups_bridge_parses(jrc, fixtures_root, tmp_path):
    data_dir = _seed_cache(fixtures_root, tmp_path, "classic-computer-groups")
    bridge = _make_bridge(jrc, data_dir)
    out = bridge.classic_computer_groups_list()
    assert isinstance(out, list)
    assert {g["name"] for g in out} >= {"All Managed Clients", "All Managed Servers"}
    assert any(not g["is_smart"] for g in out)


def test_computer_group_inventory_smart_static_split(jrc, fixtures_root, tmp_path):
    data_dir = _seed_cache(fixtures_root, tmp_path, "classic-computer-groups")
    bridge = _make_bridge(jrc, data_dir)
    values = _render_sheet(
        jrc, bridge, "_write_computer_group_inventory", "Computer Group Inventory", tmp_path,
    )
    # Fixture: 2 smart, 2 static.
    assert any("Total: 4" in str(v) and "Smart: 2" in str(v) and "Static: 2" in str(v)
               for v in values)
    assert "Smart" in values
    assert "Static" in values
    assert "All Managed Clients" in values


def test_mobile_device_groups_smart_static_split(jrc, fixtures_root, tmp_path):
    data_dir = _seed_cache(fixtures_root, tmp_path, "classic-mobile-device-groups")
    bridge = _make_bridge(jrc, data_dir)
    values = _render_sheet(
        jrc, bridge, "_write_mobile_device_groups", "Mobile Device Groups", tmp_path,
    )
    # Fixture: 2 smart, 1 static.
    assert any("Total: 3" in str(v) and "Smart: 2" in str(v) and "Static: 1" in str(v)
               for v in values)
    assert "Test Static Group" in values


def test_classic_group_inventory_missing_is_smart_treated_static(jrc, tmp_path):
    data_dir = _seed_inline(
        tmp_path, "classic-computer-groups", [{"id": 9, "name": "No Flag Group"}],
    )
    bridge = _make_bridge(jrc, data_dir)
    values = _render_sheet(
        jrc, bridge, "_write_computer_group_inventory", "Computer Group Inventory", tmp_path,
    )
    assert any("Total: 1" in str(v) and "Smart: 0" in str(v) and "Static: 1" in str(v)
               for v in values)


def test_classic_group_inventory_empty_list(jrc, tmp_path):
    data_dir = _seed_inline(tmp_path, "classic-computer-groups", [])
    bridge = _make_bridge(jrc, data_dir)
    values = _render_sheet(
        jrc, bridge, "_write_computer_group_inventory", "Computer Group Inventory", tmp_path,
    )
    assert any("Total: 0" in str(v) for v in values)
