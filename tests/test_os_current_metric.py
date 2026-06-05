"""Tests for the SOFA-driven OS-current trend metric helpers.

The ``osCurrentPct`` summary metric used to match device OS versions against
the static config ``custom_eas`` -> ``current_versions`` list, which goes stale
and under-reports current devices. The metric is now computed from the SOFA
feed: a device is "current" when its OS version is **>= the latest release
within its own major version** (Tahoe 26 -> latest 26.x, Sequoia 15 -> latest
15.x). The denominator is the full fleet (``total_devices``).

These semantics mirror the Swift engine's ``ReportEngine.osCurrentPercent`` /
``SOFAFeedService.fleetCurrency`` / ``versionTuple`` exactly (``>=`` comparison,
``total_devices`` denominator, leading-digit-per-component parsing). Both
engines consume bare-numeric OS strings. These tests exercise the pure helpers
with a synthetic SOFA latest-per-major map and a synthetic device OS list so
they need no live feed.
"""

from __future__ import annotations

import pytest


# ---------------------------------------------------------------------------
# _sofa_latest_per_major — builds {major: latest version tuple} from SOFA rows
# ---------------------------------------------------------------------------

class _FakeSOFAClient:
    """Stand-in for SOFAFeedClient that returns canned latest_versions rows."""

    def __init__(self, rows):
        self._rows = rows

    def latest_versions(self):
        return self._rows


def _macos_row(product_version, family="macOS"):
    return {"platform": family, "product_version": product_version}


def test_latest_per_major_maps_macos_majors(jrc):
    client = _FakeSOFAClient([
        _macos_row("26.5.1"),
        _macos_row("15.7.7"),
        _macos_row("14.7.6"),
    ])
    assert jrc._sofa_latest_per_major(client) == {
        26: (26, 5, 1), 15: (15, 7, 7), 14: (14, 7, 6),
    }


def test_latest_per_major_filters_non_macos_platforms(jrc):
    # Apple unified versioning: iOS 26 must not collide with macOS 26.
    client = _FakeSOFAClient([
        {"platform": "iOS / iPadOS", "product_version": "26.5"},
        _macos_row("26.5.1"),
    ])
    assert jrc._sofa_latest_per_major(client) == {26: (26, 5, 1)}


def test_latest_per_major_keeps_greatest_when_major_repeats(jrc):
    # Two macOS 15 rows -> the numerically greatest wins (mirrors Swift).
    client = _FakeSOFAClient([_macos_row("15.7.4"), _macos_row("15.7.7")])
    assert jrc._sofa_latest_per_major(client) == {15: (15, 7, 7)}


def test_latest_per_major_empty_when_no_macos_rows(jrc):
    client = _FakeSOFAClient([{"platform": "tvOS", "product_version": "26.5"}])
    assert jrc._sofa_latest_per_major(client) == {}


# ---------------------------------------------------------------------------
# _os_current_pct — % of fleet >= the latest version for its major
# ---------------------------------------------------------------------------

def test_transition_fleet_high_pct_not_zero(jrc):
    """A fleet mostly on the newest major's latest should report a high %.

    This is the regression case: with a stale static list it reported ~0.2%;
    SOFA-driven it should report the true ~75%.
    """
    latest = {26: (26, 5, 1), 15: (15, 7, 7)}
    versions = (
        [("26.5.1", 1)] * 75
        + [("26.4.1", 1)] * 15   # behind on major 26
        + [("15.7.6", 1)] * 10   # behind on major 15
    )
    pct = jrc._os_current_pct(latest, versions, total_devices=100)
    assert pct == pytest.approx(75.0)


def test_current_within_each_major(jrc):
    latest = {26: (26, 5, 1), 15: (15, 7, 7)}
    versions = [("26.5.1", 1), ("15.7.7", 1), ("15.7.6", 1)]
    # 2 of 3 are at-or-above latest within their major.
    assert jrc._os_current_pct(latest, versions, total_devices=3) == pytest.approx(200 / 3)


def test_newer_than_latest_counts_current(jrc):
    """A device numerically ahead of the SOFA latest is current (>= semantics).

    Locks the >= choice: 26.6 > the feed's 26.5.1 still counts as current,
    matching the Swift engine's compareTuples >= 0.
    """
    latest = {26: (26, 5, 1)}
    versions = [("26.6", 1), ("26.5.1", 1), ("26.5.0", 1)]
    # 26.6 and 26.5.1 are >= latest; 26.5.0 is behind -> 2 of 3.
    assert jrc._os_current_pct(latest, versions, total_devices=3) == pytest.approx(200 / 3)


def test_trailing_zero_padding_matches(jrc):
    """``26.0`` and ``26.0.0`` compare equal to latest 26.0 under zero-padding."""
    latest = {26: (26, 0)}
    versions = [("26.0.0", 1), ("26.0", 1)]
    assert jrc._os_current_pct(latest, versions, total_devices=2) == pytest.approx(100.0)


def test_old_major_counts_against_total_not_current(jrc):
    """A device on a major SOFA does not track is NOT current but still counts.

    Denominator is total_devices (mirrors Swift): one current of two -> 50%.
    """
    latest = {26: (26, 5, 1)}
    versions = [("26.5.1", 1), ("13.6.9", 1)]   # 13.x not in the map
    assert jrc._os_current_pct(latest, versions, total_devices=2) == pytest.approx(50.0)


def test_inventory_summary_count_weighting(jrc):
    """Aggregated (version, count) rows weight by count, not row presence."""
    latest = {26: (26, 5, 1), 15: (15, 7, 7)}
    versions = [("26.5.1", 30), ("15.7.7", 10), ("15.7.6", 60)]
    assert jrc._os_current_pct(latest, versions, total_devices=100) == pytest.approx(40.0)


def test_none_when_sofa_map_empty(jrc):
    assert jrc._os_current_pct({}, [("26.5.1", 1)], total_devices=1) is None


def test_none_when_no_devices(jrc):
    assert jrc._os_current_pct({26: (26, 5, 1)}, [], total_devices=0) is None


def test_blank_and_nonnumeric_versions_not_current(jrc):
    latest = {26: (26, 5, 1)}
    # "" -> () (skipped); "Unknown" -> (0,) major 0, not in map -> not current.
    versions = [("26.5.1", 1), ("", 1), ("Unknown", 1)]
    # Only the first device is current; the other two count toward the total.
    assert jrc._os_current_pct(latest, versions, total_devices=3) == pytest.approx(100 / 3)


# ---------------------------------------------------------------------------
# _os_version_tuple — mirrors Swift SOFAFeedService.versionTuple byte-for-byte
# ---------------------------------------------------------------------------

@pytest.mark.parametrize("raw,expected", [
    ("15.7.3", (15, 7, 3)),
    ("26.1", (26, 1)),
    ("26.5.1 (25F80)", (26, 5, 1)),   # trailing build suffix: "1 " -> 1
    ("26.0-rc1", (26, 0)),            # leading-digits-only per component
    ("", ()),
    ("Unknown", (0,)),               # no leading digit -> 0 (matches Swift)
    # Empty components are omitted, mirroring Swift split(separator:".").
    ("26.5.", (26, 5)),
    (".5", (5,)),
    ("26..1", (26, 1)),
])
def test_version_tuple(jrc, raw, expected):
    assert jrc._os_version_tuple(raw) == expected
