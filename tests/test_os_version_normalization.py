"""Tests for `_normalize_os_version` and the ChartGenerator OS timeseries (PR-17).

The chart generator was treating `"26.4"` and `"26.4.0"` as separate
versions, splitting the same device count across two adoption lines.
Normalization strips trailing `.0` patch components while keeping at
least `major.minor` and preserving any non-numeric prefix.
"""

from datetime import datetime

import pandas as pd
import pytest


def _chart(jrc):
    """Minimal ChartGenerator stand-in — pure-function tests don't need
    the full constructor (pandas-via-Config, xlsxwriter, etc.)."""
    return object.__new__(jrc.ChartGenerator)


# ---------------------------------------------------------------------------
# _normalize_os_version — pure-function behavior
# ---------------------------------------------------------------------------

@pytest.mark.parametrize(
    "ver_in,ver_out",
    [
        # Trailing zero stripped down to major.minor
        ("26.4.0", "26.4"),
        ("15.4.0", "15.4"),
        ("10.15.0", "10.15"),
        # major.minor with .0 as minor is preserved (don't reduce below 2 components)
        ("26.0", "26.0"),
        ("26.0.0", "26.0"),
        # Genuine non-zero patch unchanged
        ("26.4.1", "26.4.1"),
        ("26.0.1", "26.0.1"),
        ("15.7.3", "15.7.3"),
        # Multiple trailing zeros all stripped (but keeps major.minor floor)
        ("26.4.0.0", "26.4"),
        # Non-numeric prefix preserved
        ("macOS 15.4.0", "macOS 15.4"),
        ("macOS 15.7.3", "macOS 15.7.3"),
        ("Mac OS X 10.15.7", "Mac OS X 10.15.7"),
        # Leading/trailing whitespace handled
        ("  26.4.0  ", "26.4"),
        # No version digits at all — returned as-is (after .strip())
        ("Unknown", "Unknown"),
        ("", ""),
        # Single component (no .) — no normalization possible, return as-is
        ("26", "26"),
    ],
)
def test_normalize_os_version_examples(jrc, ver_in, ver_out) -> None:
    assert jrc._normalize_os_version(ver_in) == ver_out


# ---------------------------------------------------------------------------
# Integration: _build_os_timeseries (CSV path)
# ---------------------------------------------------------------------------

def test_build_os_timeseries_collapses_trailing_zero_variants(jrc) -> None:
    """`26.4` and `26.4.0` come out of CSV exports as separate values when
    different MDM rows record different precisions. Normalization at read
    time merges them into a single column with combined counts."""
    df = pd.DataFrame({"OS Version": ["26.4", "26.4.0", "26.4", "26.4.0", "26.4.1"]})
    snapshots = [(datetime(2026, 5, 18), df)]

    ts = _chart(jrc)._build_os_timeseries(snapshots, "OS Version")

    # `26.4` + `26.4.0` → 4 devices on the merged `26.4` column
    assert "26.4" in ts.columns
    assert "26.4.0" not in ts.columns
    assert int(ts["26.4"].iloc[0]) == 4
    # Non-zero patch stays separate
    assert "26.4.1" in ts.columns
    assert int(ts["26.4.1"].iloc[0]) == 1


# ---------------------------------------------------------------------------
# Integration: _build_inventory_summary_timeseries (jamf-cli JSON path)
# ---------------------------------------------------------------------------

def test_build_inventory_summary_timeseries_collapses_trailing_zero_variants(jrc) -> None:
    """Same normalization on the JSON-sourced path so the two snapshot
    pipelines stay in sync."""
    payload = [
        {"os_version": "26.4", "count": 10},
        {"os_version": "26.4.0", "count": 5},
        {"os_version": "26.4.1", "count": 2},
        {"os_version": "26.0.0", "count": 3},
    ]
    snapshots = [(datetime(2026, 5, 18), payload)]

    ts = _chart(jrc)._build_inventory_summary_timeseries(snapshots)

    assert "26.4" in ts.columns
    assert "26.4.0" not in ts.columns
    assert int(ts["26.4"].iloc[0]) == 15  # 10 + 5
    assert "26.4.1" in ts.columns
    assert int(ts["26.4.1"].iloc[0]) == 2
    # `26.0.0` collapses to `26.0`, not to `26` (major.minor floor)
    assert "26.0" in ts.columns
    assert "26" not in ts.columns
    assert int(ts["26.0"].iloc[0]) == 3
