"""v2.2.0 admin-controlled snapshot retention (Python parity)."""
from __future__ import annotations

import os
import time
from pathlib import Path


def _config(jrc, tmp_path: Path, retention_yaml: str):
    config_path = tmp_path / "config.yaml"
    config_path.write_text(
        "jamf_cli:\n  data_dir: jamf-cli-data\n" + retention_yaml, encoding="utf-8"
    )
    return jrc.Config(str(config_path))


def _snapshot(tmp_path: Path, kind: str, name: str, age_days: float) -> Path:
    d = tmp_path / "jamf-cli-data" / kind
    d.mkdir(parents=True, exist_ok=True)
    f = d / name
    f.write_text("[]", encoding="utf-8")
    when = time.time() - age_days * 86_400
    os.utime(f, (when, when))
    return f


def test_disabled_by_default_is_noop(jrc, tmp_path: Path) -> None:
    old = _snapshot(tmp_path, "computers", "c_old.json", 400)
    config = _config(jrc, tmp_path, "")  # no retention block → defaults (disabled)
    assert jrc._sweep_snapshots(config) == 0
    assert old.exists()


def test_archive_moves_old_files(jrc, tmp_path: Path) -> None:
    old = _snapshot(tmp_path, "computers", "c_old.json", 400)
    fresh = _snapshot(tmp_path, "computers", "c_new.json", 1)
    config = _config(
        jrc, tmp_path,
        "retention:\n  enabled: true\n  mode: archive\n  snapshot_keep_days: 365\n",
    )
    acted = jrc._sweep_snapshots(config)
    assert acted == 1
    assert not old.exists()
    assert fresh.exists()
    archived = tmp_path / "_archive" / "jamf-cli-data" / "computers" / "c_old.json"
    assert archived.exists()


def test_delete_mode_removes(jrc, tmp_path: Path) -> None:
    old = _snapshot(tmp_path, "policies", "p_old.json", 400)
    config = _config(
        jrc, tmp_path,
        "retention:\n  enabled: true\n  mode: delete\n  snapshot_keep_days: 365\n",
    )
    assert jrc._sweep_snapshots(config) == 1
    assert not old.exists()
    assert not (tmp_path / "_archive").exists()


def test_keep_count_protects_newest(jrc, tmp_path: Path) -> None:
    _snapshot(tmp_path, "ea-results", "ea1.json", 100)
    _snapshot(tmp_path, "ea-results", "ea2.json", 200)
    _snapshot(tmp_path, "ea-results", "ea3.json", 300)
    config = _config(
        jrc, tmp_path,
        "retention:\n  enabled: true\n  mode: delete\n"
        "  snapshot_keep_days: 30\n  snapshot_keep_count: 2\n",
    )
    assert jrc._sweep_snapshots(config) == 1  # only the oldest beyond the 2 newest
    assert (tmp_path / "jamf-cli-data" / "ea-results" / "ea1.json").exists()


def test_skip_state_sofa_and_underscore_dirs(jrc, tmp_path: Path) -> None:
    for kind in ("state", "sofa", "_archive"):
        _snapshot(tmp_path, kind, "x.json", 400)
    config = _config(
        jrc, tmp_path,
        "retention:\n  enabled: true\n  mode: delete\n  snapshot_keep_days: 30\n",
    )
    assert jrc._sweep_snapshots(config) == 0
    assert (tmp_path / "jamf-cli-data" / "state" / "x.json").exists()
    assert (tmp_path / "jamf-cli-data" / "sofa" / "x.json").exists()


def test_once_per_day_marker(jrc, tmp_path: Path) -> None:
    _snapshot(tmp_path, "computers", "c_old.json", 400)
    config = _config(
        jrc, tmp_path,
        "retention:\n  enabled: true\n  mode: archive\n  snapshot_keep_days: 365\n",
    )
    assert jrc._sweep_snapshots(config) == 1
    # Second call same day → marker short-circuits even with new old files.
    _snapshot(tmp_path, "computers", "c_old2.json", 400)
    assert jrc._sweep_snapshots(config) == 0
    assert (tmp_path / ".retention-last").exists()
