"""Same-day summary upgrade parity with Swift ReportEngine.freshSummaryIsBetter.

The first-run-of-day skip must NOT freeze a degraded morning summary: a later
same-day run that is strictly better (proxy→real mSCP, missing→present bands, or a
recovered stale count on a non-empty fleet) replaces it. A worse or equal run never
downgrades the kept summary.
"""
from __future__ import annotations

import json
from pathlib import Path


# --- pure rule helper --------------------------------------------------------

def test_rule_proxy_to_real_compliance_is_better(jrc):
    existing = {"complianceIsProxy": True, "totalDevices": 100, "staleCount": 5}
    fresh = {"complianceIsProxy": False, "totalDevices": 100, "staleCount": 5}
    assert jrc._fresh_summary_is_better(existing, fresh)


def test_rule_real_to_proxy_is_not_better(jrc):
    """Downgrade real→proxy must never overwrite."""
    existing = {"complianceIsProxy": False, "totalDevices": 100, "staleCount": 5}
    fresh = {"complianceIsProxy": True, "totalDevices": 100, "staleCount": 5}
    assert not jrc._fresh_summary_is_better(existing, fresh)


def test_rule_missing_bands_to_present_is_better(jrc):
    existing = {"complianceIsProxy": False, "totalDevices": 100, "staleCount": 5}
    fresh = {
        "complianceIsProxy": False,
        "totalDevices": 100,
        "staleCount": 5,
        "mscpBands": {"baseline": {"Pass": 90}},
    }
    assert jrc._fresh_summary_is_better(existing, fresh)


def test_rule_empty_bands_to_present_is_better(jrc):
    existing = {"totalDevices": 100, "staleCount": 5, "mscpBands": {}}
    fresh = {"totalDevices": 100, "staleCount": 5, "mscpBands": {"b": {"Pass": 1}}}
    assert jrc._fresh_summary_is_better(existing, fresh)


def test_rule_present_bands_to_missing_is_not_better(jrc):
    existing = {"totalDevices": 100, "staleCount": 5, "mscpBands": {"b": {"Pass": 1}}}
    fresh = {"totalDevices": 100, "staleCount": 5}
    assert not jrc._fresh_summary_is_better(existing, fresh)


def test_rule_zero_stale_to_nonzero_on_nonempty_fleet_is_better(jrc):
    existing = {"totalDevices": 100, "staleCount": 0}
    fresh = {"totalDevices": 100, "staleCount": 7}
    assert jrc._fresh_summary_is_better(existing, fresh)


def test_rule_nonzero_stale_to_zero_is_not_better(jrc):
    """A genuinely-zero-stale tenant (or a degraded later run) must not downgrade
    a real non-zero stale count."""
    existing = {"totalDevices": 100, "staleCount": 7}
    fresh = {"totalDevices": 100, "staleCount": 0}
    assert not jrc._fresh_summary_is_better(existing, fresh)


def test_rule_zero_stale_empty_fleet_is_not_better(jrc):
    """staleCount 0 with totalDevices 0 is not a degraded reading — no upgrade."""
    existing = {"totalDevices": 0, "staleCount": 0}
    fresh = {"totalDevices": 0, "staleCount": 0}
    assert not jrc._fresh_summary_is_better(existing, fresh)


def test_rule_identical_is_not_better(jrc):
    summary = {"complianceIsProxy": False, "totalDevices": 100, "staleCount": 5}
    assert not jrc._fresh_summary_is_better(dict(summary), dict(summary))


# --- persistence decision ----------------------------------------------------

def _write_existing(path: Path, data: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(data), encoding="utf-8")


def test_persist_keeps_existing_when_not_better(jrc, tmp_path):
    summaries = tmp_path / "summaries"
    sf = summaries / "summary_2026-06-10.json"
    existing = {"date": "2026-06-10", "totalDevices": 100, "source": "csv",
                "complianceIsProxy": False, "staleCount": 5}
    _write_existing(sf, existing)
    fresh = dict(existing)
    fresh["complianceIsProxy"] = True  # would be a downgrade
    jrc._persist_summary_with_upgrade(
        sf, summaries, fresh, existing, "2026-06-10", force=False
    )
    on_disk = json.loads(sf.read_text(encoding="utf-8"))
    assert on_disk["complianceIsProxy"] is False  # unchanged — existing kept


def test_persist_replaces_existing_when_better(jrc, tmp_path):
    summaries = tmp_path / "summaries"
    sf = summaries / "summary_2026-06-10.json"
    existing = {"date": "2026-06-10", "totalDevices": 100, "source": "csv",
                "complianceIsProxy": True, "staleCount": 5}
    _write_existing(sf, existing)
    fresh = dict(existing)
    fresh["complianceIsProxy"] = False  # proxy→real upgrade
    jrc._persist_summary_with_upgrade(
        sf, summaries, fresh, existing, "2026-06-10", force=False
    )
    on_disk = json.loads(sf.read_text(encoding="utf-8"))
    assert on_disk["complianceIsProxy"] is False  # replaced


def test_persist_force_always_writes_fresh(jrc, tmp_path):
    summaries = tmp_path / "summaries"
    sf = summaries / "summary_2026-06-10.json"
    existing = {"date": "2026-06-10", "totalDevices": 100, "source": "csv",
                "complianceIsProxy": False, "staleCount": 5}
    _write_existing(sf, existing)
    fresh = {"date": "2026-06-10", "totalDevices": 200, "source": "jamf-cli",
             "complianceIsProxy": True, "staleCount": 9}
    # existing is None under force (caller passes None) — fresh always wins.
    jrc._persist_summary_with_upgrade(
        sf, summaries, fresh, None, "2026-06-10", force=True
    )
    on_disk = json.loads(sf.read_text(encoding="utf-8"))
    assert on_disk["totalDevices"] == 200


def test_persist_writes_when_no_existing(jrc, tmp_path):
    summaries = tmp_path / "summaries"
    summaries.mkdir()
    sf = summaries / "summary_2026-06-10.json"
    fresh = {"date": "2026-06-10", "totalDevices": 50, "source": "csv", "staleCount": 0}
    jrc._persist_summary_with_upgrade(sf, summaries, fresh, None, "2026-06-10", force=False)
    assert json.loads(sf.read_text(encoding="utf-8"))["totalDevices"] == 50


def test_read_existing_rejects_incomplete(jrc, tmp_path, capsys):
    sf = tmp_path / "summary.json"
    sf.write_text(json.dumps({"date": "2026-06-10"}), encoding="utf-8")  # missing keys
    assert jrc._read_existing_summary(sf) is None
    assert "incomplete" in capsys.readouterr().out


def test_read_existing_rejects_corrupt(jrc, tmp_path, capsys):
    sf = tmp_path / "summary.json"
    sf.write_text("{not json", encoding="utf-8")
    assert jrc._read_existing_summary(sf) is None
    assert "corrupt" in capsys.readouterr().out


def test_read_existing_absent_returns_none(jrc, tmp_path):
    assert jrc._read_existing_summary(tmp_path / "missing.json") is None
