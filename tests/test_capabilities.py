"""Tests for the app-facing capabilities manifest."""

from __future__ import annotations

import json


def test_capabilities_manifest_includes_products_and_surfaces(jrc) -> None:
    manifest = jrc._capabilities_manifest()

    assert manifest["schema_version"] == 1
    assert {p["id"] for p in manifest["products"]} >= {
        "jamf_pro",
        "jamf_school",
        "jamf_protect",
        "jamf_platform",
    }
    assert "capabilities" not in manifest["commands"]["jamf_pro"]
    assert any(s["id"] == "protect-overview" for s in manifest["status_surfaces"])
    assert any(s["id"] == "school-devices" for s in manifest["status_surfaces"])
    assert any(s["id"] == "os-adoption" for s in manifest["historical_surfaces"])
    assert "JSON summaries are opt-in" in " ".join(manifest["known_gaps"])
    assert "Jamf Protect is collected" in " ".join(manifest["known_gaps"])


def test_capabilities_command_outputs_json_without_config(jrc, monkeypatch, tmp_path, capsys) -> None:
    monkeypatch.chdir(tmp_path)
    monkeypatch.setattr("sys.argv", ["jamf-reports-community.py", "capabilities"])

    jrc.main()

    out = capsys.readouterr().out
    payload = json.loads(out)
    assert payload["schema_version"] == 1
    assert "columns" in payload["config_sections"]


def test_capabilities_command_outputs_text(jrc, capsys) -> None:
    jrc.cmd_capabilities("text")

    out = capsys.readouterr().out
    assert "Products:" in out
    assert "Current status surfaces:" in out
    assert "Historical surfaces:" in out
