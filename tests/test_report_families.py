"""Tests for report-family CSV selection and scoring logic.

Covers:
- _report_family_header_score (computers / mobile / compliance)
- _list_of_strings
- _sha256_file / _archive_csv_snapshot dedup
- _default_generate_csv family priority
- _family_for_csv_path path-based detection
- _guess_report_family_from_headers header-based fallback
- _select_automation_csv manifest-wins and inbox-fallback routing
"""

from __future__ import annotations

import hashlib
import shutil
import tempfile
from pathlib import Path
from typing import Any
from unittest.mock import MagicMock, patch

import pytest

# ---------------------------------------------------------------------------
# Helpers — import the module-level functions under test.
# The project is a single file; import it via importlib so we can patch
# individual names without polluting the global namespace.
# ---------------------------------------------------------------------------

import importlib.util
import sys

_SCRIPT = Path(__file__).parent.parent / "jamf-reports-community.py"


def _load_module():
    spec = importlib.util.spec_from_file_location("jrc", _SCRIPT)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


# Load once at module level to keep test startup fast.
_jrc = _load_module()


# ---------------------------------------------------------------------------
# _list_of_strings
# ---------------------------------------------------------------------------


@pytest.mark.parametrize(
    "value, expected",
    [
        (None, []),
        ("", []),
        ("  ", []),
        ("single", ["single"]),
        ("  padded  ", ["padded"]),
        (["a", "b", "c"], ["a", "b", "c"]),
        (["a", " ", "b"], ["a", "b"]),  # empty-after-strip items are dropped
        ([1, 2, 3], ["1", "2", "3"]),  # non-strings are coerced
        ([], []),
    ],
)
def test_list_of_strings(value: Any, expected: list[str]) -> None:
    assert _jrc._list_of_strings(value) == expected


# ---------------------------------------------------------------------------
# _report_family_header_score — computers
# ---------------------------------------------------------------------------


def _make_config(columns: dict, mobile_columns: dict = None, compliance: dict = None):
    """Return a minimal mock Config-like object for header scoring tests."""
    cfg = MagicMock()
    cfg.columns = columns
    cfg.mobile_columns = mobile_columns or {}
    cfg.compliance = compliance or {}
    return cfg


COMPUTERS_CORE = {
    "computer_name": "Computer Name",
    "serial_number": "Serial Number",
    "operating_system": "macOS Version",
    "last_checkin": "Last Contact",
}

COMPUTERS_FULL = {
    **COMPUTERS_CORE,
    "department": "Department",
    "model": "Model Identifier",
    "email": "Email Address",
}


@pytest.mark.parametrize(
    "headers, expected_primary, expected_secondary_ge",
    [
        # All four core columns present → primary = 4
        (
            ["Computer Name", "Serial Number", "macOS Version", "Last Contact", "Department"],
            4,
            5,
        ),
        # Three core columns → primary = 3
        (
            ["Computer Name", "Serial Number", "macOS Version", "Other"],
            3,
            3,
        ),
        # Zero matching columns → both scores = 0
        (
            ["Display Name", "Device Family", "OS Version"],
            0,
            0,
        ),
        # Case-insensitive: _normalized_text lowercases and strips punctuation
        (
            ["computer name", "serial number", "macos version", "last contact"],
            4,
            4,
        ),
    ],
)
def test_report_family_header_score_computers(
    headers: list[str],
    expected_primary: int,
    expected_secondary_ge: int,
) -> None:
    cfg = _make_config(COMPUTERS_FULL)
    primary, secondary = _jrc._report_family_header_score(cfg, "computers", headers)
    assert primary == expected_primary
    assert secondary >= expected_secondary_ge


# ---------------------------------------------------------------------------
# _report_family_header_score — mobile
# ---------------------------------------------------------------------------

MOBILE_COLUMNS = {
    "device_name": "Display Name",
    "serial_number": "Serial Number",
    "operating_system": "OS Version",
    "last_checkin": "Last Inventory Update",
    "email": "Email Address",
    "model": "Model",
    "device_family": "Device Family",
}


@pytest.mark.parametrize(
    "mobile_cols, headers, expected_primary_ge",
    [
        # All configured mobile columns present
        (
            MOBILE_COLUMNS,
            ["Display Name", "Serial Number", "OS Version", "Last Inventory Update",
             "Email Address", "Model", "Device Family"],
            7,
        ),
        # Partial match
        (
            MOBILE_COLUMNS,
            ["Display Name", "Serial Number"],
            2,
        ),
        # Empty mobile_columns: falls back to hardcoded defaults; some will match
        (
            {},
            ["Display Name", "Serial Number", "OS Version", "Model"],
            3,
        ),
        # No match at all
        (
            MOBILE_COLUMNS,
            ["Computer Name", "macOS Version"],
            0,
        ),
    ],
)
def test_report_family_header_score_mobile(
    mobile_cols: dict,
    headers: list[str],
    expected_primary_ge: int,
) -> None:
    cfg = _make_config({}, mobile_columns=mobile_cols)
    primary, _ = _jrc._report_family_header_score(cfg, "mobile", headers)
    assert primary >= expected_primary_ge


# ---------------------------------------------------------------------------
# _report_family_header_score — compliance
# ---------------------------------------------------------------------------


@pytest.mark.parametrize(
    "compliance_cfg, headers, expected_primary_ge",
    [
        # All four compliance columns present
        (
            {
                "failures_count_column": "Failures Count",
                "failures_list_column": "Failures List",
            },
            ["Failures Count", "Failures List", "Computer Name", "Serial Number"],
            4,
        ),
        # Only compliance columns, no computer name/serial
        (
            {
                "failures_count_column": "Failure Count",
                "failures_list_column": "Failed Rules",
            },
            ["Failure Count", "Failed Rules", "Department"],
            2,
        ),
        # No configured compliance columns → score 0
        (
            {},
            ["Computer Name", "Serial Number"],
            0,
        ),
    ],
)
def test_report_family_header_score_compliance(
    compliance_cfg: dict,
    headers: list[str],
    expected_primary_ge: int,
) -> None:
    cfg = _make_config(COMPUTERS_CORE, compliance=compliance_cfg)
    primary, _ = _jrc._report_family_header_score(cfg, "compliance", headers)
    assert primary >= expected_primary_ge


# ---------------------------------------------------------------------------
# _sha256_file
# ---------------------------------------------------------------------------


def test_sha256_file_matches_hashlib(tmp_path: Path) -> None:
    content = b"dummy csv content for hashing"
    f = tmp_path / "test.csv"
    f.write_bytes(content)
    expected = hashlib.sha256(content).hexdigest()
    assert _jrc._sha256_file(f) == expected


def test_sha256_file_different_content(tmp_path: Path) -> None:
    a = tmp_path / "a.csv"
    b = tmp_path / "b.csv"
    a.write_bytes(b"content a")
    b.write_bytes(b"content b")
    assert _jrc._sha256_file(a) != _jrc._sha256_file(b)


# ---------------------------------------------------------------------------
# _archive_csv_snapshot dedup
# ---------------------------------------------------------------------------


def test_archive_csv_snapshot_creates_new(tmp_path: Path) -> None:
    src = tmp_path / "source.csv"
    src.write_text("col1,col2\nval1,val2\n")
    hist = tmp_path / "snapshots"
    hist.mkdir()

    dest, created = _jrc._archive_csv_snapshot(str(src), str(hist))
    assert created is True
    assert dest is not None
    assert dest.exists()


def test_archive_csv_snapshot_dedup_skips_identical(tmp_path: Path) -> None:
    content = "col1,col2\nval1,val2\n"
    src = tmp_path / "source.csv"
    src.write_text(content)
    hist = tmp_path / "snapshots"
    hist.mkdir()

    # First archive creates the file
    dest1, created1 = _jrc._archive_csv_snapshot(str(src), str(hist))
    assert created1 is True

    # Second archive with identical content should return the existing file
    dest2, created2 = _jrc._archive_csv_snapshot(str(src), str(hist))
    assert created2 is False
    assert dest2 == dest1


def test_archive_csv_snapshot_allows_different_content(tmp_path: Path) -> None:
    hist = tmp_path / "snapshots"
    hist.mkdir()

    src1 = tmp_path / "v1.csv"
    src1.write_text("col1,col2\nval1,val2\n")
    dest1, created1 = _jrc._archive_csv_snapshot(str(src1), str(hist))
    assert created1 is True

    src2 = tmp_path / "v2.csv"
    src2.write_text("col1,col2\nnewval1,newval2\n")
    dest2, created2 = _jrc._archive_csv_snapshot(str(src2), str(hist))
    assert created2 is True
    assert dest2 != dest1


# ---------------------------------------------------------------------------
# _family_for_csv_path
# ---------------------------------------------------------------------------


def _make_family_config(
    family_name: str,
    current_dir: str,
    enabled: bool = True,
    include_globs: list = None,
) -> dict:
    return {
        "enabled": enabled,
        "current_dir": current_dir,
        "historical_dir": "",
        "include_globs": include_globs or ["*.csv"],
        "exclude_globs": [],
        "prefer_name_contains": [],
    }


def test_family_for_csv_path_matches_computers(tmp_path: Path) -> None:
    computers_dir = tmp_path / "computers"
    computers_dir.mkdir()
    csv = computers_dir / "inventory.csv"
    csv.write_text("Computer Name,Serial Number\nMac1,ABC123\n")

    cfg = MagicMock()
    cfg.report_families = {
        "computers": _make_family_config("computers", str(computers_dir)),
        "mobile": {"enabled": False, "current_dir": "", "historical_dir": "",
                   "include_globs": [], "exclude_globs": [], "prefer_name_contains": []},
        "compliance": {"enabled": False, "current_dir": "", "historical_dir": "",
                       "include_globs": [], "exclude_globs": [], "prefer_name_contains": []},
    }
    cfg.resolve_path_value = lambda v: Path(v) if v else None

    result = _jrc._family_for_csv_path(cfg, csv)
    assert result == "computers"


def test_family_for_csv_path_outside_any_family(tmp_path: Path) -> None:
    csv = tmp_path / "unrelated.csv"
    csv.write_text("col1\nval1\n")

    cfg = MagicMock()
    cfg.report_families = {
        "computers": {"enabled": False, "current_dir": "", "historical_dir": "",
                      "include_globs": [], "exclude_globs": [], "prefer_name_contains": []},
        "mobile": {"enabled": False, "current_dir": "", "historical_dir": "",
                   "include_globs": [], "exclude_globs": [], "prefer_name_contains": []},
        "compliance": {"enabled": False, "current_dir": "", "historical_dir": "",
                       "include_globs": [], "exclude_globs": [], "prefer_name_contains": []},
    }
    cfg.resolve_path_value = lambda v: Path(v) if v else None

    result = _jrc._family_for_csv_path(cfg, csv)
    assert result is None


# ---------------------------------------------------------------------------
# _select_automation_csv — manifest vs inbox routing
# ---------------------------------------------------------------------------


def test_select_automation_csv_prefers_manifest_over_inbox(tmp_path: Path) -> None:
    # Set up a computers family directory with a valid CSV
    computers_dir = tmp_path / "computers"
    computers_dir.mkdir()
    manifest_csv = computers_dir / "fleet.csv"
    manifest_csv.write_text("Computer Name,Serial Number\nMac1,ABC\n")

    # Set up an inbox directory with a different CSV
    inbox_dir = tmp_path / "inbox"
    inbox_dir.mkdir()
    inbox_csv = inbox_dir / "inbox.csv"
    inbox_csv.write_text("Computer Name,Serial Number\nMac2,DEF\n")

    cfg = MagicMock()
    cfg.report_families = {
        "computers": _make_family_config("computers", str(computers_dir)),
        "mobile": {"enabled": False, "current_dir": "", "historical_dir": "",
                   "include_globs": [], "exclude_globs": [], "prefer_name_contains": []},
        "compliance": {"enabled": False, "current_dir": "", "historical_dir": "",
                       "include_globs": [], "exclude_globs": [], "prefer_name_contains": []},
    }
    cfg.resolve_path_value = lambda v: Path(v).expanduser() if v else None
    cfg.columns = {}
    cfg.mobile_columns = {}
    cfg.compliance = {}

    selected_csv, family_name, origin, note = _jrc._select_automation_csv(
        cfg, str(inbox_dir), freshness_days=14
    )
    # Manifest should win even though inbox also has a file
    assert selected_csv is not None
    assert family_name == "computers"
    assert "report_families" in origin


def test_select_automation_csv_falls_back_to_inbox(tmp_path: Path) -> None:
    # No enabled families configured
    inbox_dir = tmp_path / "inbox"
    inbox_dir.mkdir()
    inbox_csv = inbox_dir / "inbox.csv"
    inbox_csv.write_text("Computer Name\nMac1\n")

    cfg = MagicMock()
    cfg.report_families = {
        "computers": {"enabled": False, "current_dir": "", "historical_dir": "",
                      "include_globs": [], "exclude_globs": [], "prefer_name_contains": []},
        "mobile": {"enabled": False, "current_dir": "", "historical_dir": "",
                   "include_globs": [], "exclude_globs": [], "prefer_name_contains": []},
        "compliance": {"enabled": False, "current_dir": "", "historical_dir": "",
                       "include_globs": [], "exclude_globs": [], "prefer_name_contains": []},
    }
    cfg.resolve_path_value = lambda v: Path(v).expanduser() if v else None
    cfg.columns = {}
    cfg.mobile_columns = {}
    cfg.compliance = {}

    selected_csv, family_name, origin, note = _jrc._select_automation_csv(
        cfg, str(inbox_dir), freshness_days=14
    )
    assert selected_csv is not None
    assert origin == "csv_inbox"
    assert family_name is None


def test_select_automation_csv_returns_none_when_both_empty(tmp_path: Path) -> None:
    inbox_dir = tmp_path / "inbox"
    inbox_dir.mkdir()  # exists but empty

    cfg = MagicMock()
    cfg.report_families = {
        "computers": {"enabled": False, "current_dir": "", "historical_dir": "",
                      "include_globs": [], "exclude_globs": [], "prefer_name_contains": []},
        "mobile": {"enabled": False, "current_dir": "", "historical_dir": "",
                   "include_globs": [], "exclude_globs": [], "prefer_name_contains": []},
        "compliance": {"enabled": False, "current_dir": "", "historical_dir": "",
                       "include_globs": [], "exclude_globs": [], "prefer_name_contains": []},
    }
    cfg.resolve_path_value = lambda v: Path(v).expanduser() if v else None
    cfg.columns = {}
    cfg.mobile_columns = {}
    cfg.compliance = {}

    selected_csv, family_name, origin, note = _jrc._select_automation_csv(
        cfg, str(inbox_dir), freshness_days=14
    )
    assert selected_csv is None
    assert origin == ""
