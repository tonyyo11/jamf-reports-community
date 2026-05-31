"""Regression test: csv-assisted automation mode must hard-fail when no CSV is present.

The documented Schedule.RunMode contract (and the Swift app) require csv-assisted runs to
fail loudly when no CSV is available, rather than silently degrading to jamf-cli-only output.
"""

from __future__ import annotations

from pathlib import Path

import pytest


@pytest.mark.integration
def test_csv_assisted_hard_fails_without_csv(config_factory, tmp_path: Path, monkeypatch, jrc):
    config = config_factory("dummy.yaml")
    config._data["automation"] = {
        "generate_xlsx": True,
        "generate_html": False,
        "generate_inventory_csv": False,
    }
    # No CSV is selectable from the inbox or report families.
    monkeypatch.setattr(jrc, "_select_automation_csv", lambda *_a: (None, None, "", "No CSV"))
    monkeypatch.setattr(jrc, "_collect_snapshots", lambda *_a: (0, False))

    status_path = tmp_path / "status.json"
    with pytest.raises(SystemExit, match="csv-assisted"):
        jrc.cmd_launchagent_run(config, "csv-assisted", None, 14, None, str(status_path))
