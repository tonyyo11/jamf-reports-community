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


# --- jamf-cli runtime detection -------------------------------------------

_PRO_HELP = """\
Commands for interacting with Jamf Pro.

Usage:
  jamf-cli pro [command]

Core Commands:
  overview                      Show a summary of the Jamf Pro instance
  setup                         Bootstrap OAuth2 credentials

Power Commands:
  report                        Generate operational reports from Jamf Pro data

Computer Management:
  computer-extension-attributes  Manage computer-extension-attributes
  computer-groups-smart-groups   Manage computer-groups-smart-groups
  scripts                        Manage scripts
  packages                       Manage packages

Flags:
  not-a-command                  This line is after Flags: and must be ignored
  -h, --help                     help for pro
"""


class _FakeResult:
    def __init__(self, stdout: str, returncode: int = 0) -> None:
        self.stdout = stdout
        self.stderr = ""
        self.returncode = returncode


def test_parse_pro_commands_extracts_expected_set(jrc, monkeypatch) -> None:
    monkeypatch.setattr(jrc.subprocess, "run", lambda *a, **k: _FakeResult(_PRO_HELP))

    commands = jrc._parse_jamf_cli_pro_commands("/usr/local/bin/jamf-cli")

    assert commands == {
        "overview",
        "setup",
        "report",
        "computer-extension-attributes",
        "computer-groups-smart-groups",
        "scripts",
        "packages",
    }
    # A command-shaped line after the Flags: terminator must not be captured.
    assert "not-a-command" not in commands


def test_parse_pro_commands_garbage_returns_empty_set(jrc, monkeypatch) -> None:
    monkeypatch.setattr(jrc.subprocess, "run", lambda *a, **k: _FakeResult("blah\nnoise\n"))
    assert jrc._parse_jamf_cli_pro_commands("/usr/local/bin/jamf-cli") == set()

    monkeypatch.setattr(jrc.subprocess, "run", lambda *a, **k: _FakeResult("", returncode=1))
    assert jrc._parse_jamf_cli_pro_commands("/usr/local/bin/jamf-cli") == set()


def test_capability_matrix_no_op_when_binary_absent(jrc, monkeypatch) -> None:
    monkeypatch.setattr(jrc, "_find_jamf_cli_binary", lambda: None)

    assert jrc._capability_jamf_cli_matrix() == {
        "available": False,
        "version": None,
        "namespaces": {},
    }


def test_supports_quiet_flags_version_gate(jrc) -> None:
    assert jrc._supports_quiet_flags("1.18.0") is True
    assert jrc._supports_quiet_flags("1.18.2") is True
    assert jrc._supports_quiet_flags("1.19.0") is True
    assert jrc._supports_quiet_flags("2.0.0") is True
    assert jrc._supports_quiet_flags("1.17.9") is False
    assert jrc._supports_quiet_flags("1.16.1") is False
    assert jrc._supports_quiet_flags(None) is False
    assert jrc._supports_quiet_flags("") is False


def test_version_tuple_parsing(jrc) -> None:
    assert jrc._version_tuple("1.18.0") == (1, 18, 0)
    assert jrc._version_tuple("1.18.0-rc1") == (1, 18, 0)
    assert jrc._version_tuple("1.18") == (1, 18)
