"""Tests for LaunchAgent automation output selection."""

from __future__ import annotations

import json
import plistlib
import subprocess
from pathlib import Path

import pytest


@pytest.mark.integration
def test_launchagent_snapshot_only_generates_configured_outputs(
    config_factory,
    tmp_path: Path,
    monkeypatch,
    jrc,
) -> None:
    config = config_factory("dummy.yaml")
    config._data["automation"] = {
        "generate_xlsx": True,
        "generate_html": True,
        "generate_inventory_csv": True,
    }

    inventory_path = tmp_path / "automation_inventory_dummy.csv"
    report_path = tmp_path / "scheduled-report.xlsx"
    html_path = tmp_path / "scheduled-report.html"
    status_path = tmp_path / "status.json"
    calls: list[tuple[str, str]] = []

    monkeypatch.setattr(
        jrc,
        "_select_automation_csv",
        lambda *_args: (None, None, "", "No CSV selected"),
    )
    monkeypatch.setattr(jrc, "_collect_snapshots", lambda *_args: (1, False))

    def fake_inventory_csv(_config, out_file):
        calls.append(("inventory-csv", str(out_file)))
        inventory_path.write_text("serial\nABC123\n", encoding="utf-8")
        return inventory_path

    def fake_generate(_config, csv_path, out_file, historical_csv_dir, notify_url, csv_extra=None):
        del out_file, historical_csv_dir, notify_url, csv_extra
        calls.append(("generate", str(csv_path)))
        report_path.write_text("xlsx", encoding="utf-8")
        return report_path

    def fake_html(_config, out_file, no_open=False):
        del out_file
        calls.append(("html", str(no_open)))
        html_path.write_text("<html></html>", encoding="utf-8")
        return html_path

    monkeypatch.setattr(jrc, "cmd_inventory_csv", fake_inventory_csv)
    monkeypatch.setattr(jrc, "cmd_generate", fake_generate)
    monkeypatch.setattr(jrc, "cmd_html", fake_html)

    jrc.cmd_launchagent_run(
        config,
        "snapshot-only",
        None,
        14,
        None,
        str(status_path),
    )

    status = json.loads(status_path.read_text(encoding="utf-8"))
    assert status["success"] is True
    assert status["inventory_csv_path"] == str(inventory_path)
    assert status["report_path"] == str(report_path)
    assert status["xlsx_report_path"] == str(report_path)
    assert status["html_report_path"] == str(html_path)
    assert ("generate", str(inventory_path)) in calls


@pytest.mark.integration
def test_launchagent_jamf_cli_only_can_emit_html_without_xlsx(
    config_factory,
    tmp_path: Path,
    monkeypatch,
    jrc,
) -> None:
    config = config_factory("dummy.yaml")
    config._data["automation"] = {
        "generate_xlsx": False,
        "generate_html": True,
        "generate_inventory_csv": False,
    }
    status_path = tmp_path / "status.json"
    html_path = tmp_path / "scheduled-report.html"

    monkeypatch.setattr(
        jrc,
        "cmd_generate",
        lambda *_args, **_kwargs: pytest.fail("cmd_generate should not be called"),
    )
    monkeypatch.setattr(
        jrc,
        "cmd_inventory_csv",
        lambda *_args, **_kwargs: pytest.fail("cmd_inventory_csv should not be called"),
    )

    def fake_html(_config, out_file, no_open=False):
        del out_file
        assert no_open is True
        html_path.write_text("<html></html>", encoding="utf-8")
        return html_path

    monkeypatch.setattr(jrc, "cmd_html", fake_html)

    jrc.cmd_launchagent_run(
        config,
        "jamf-cli-only",
        None,
        14,
        None,
        str(status_path),
    )

    status = json.loads(status_path.read_text(encoding="utf-8"))
    assert status["success"] is True
    assert status["report_path"] is None
    assert status["xlsx_report_path"] is None
    assert status["html_report_path"] == str(html_path)


@pytest.mark.integration
def test_cmd_html_archives_older_timestamped_outputs(
    config_factory,
    tmp_path: Path,
    monkeypatch,
    jrc,
) -> None:
    config = config_factory("dummy.yaml")
    config._data["jamf_cli"]["enabled"] = True
    config._data["output"]["archive_enabled"] = True
    config._data["output"]["keep_latest_runs"] = 1
    config._data["output"]["timestamp_outputs"] = True

    output_dir = Path(config._data["output"]["output_dir"])
    output_dir.mkdir(parents=True, exist_ok=True)
    older_one = output_dir / "JamfReport_2026-04-01_010101.html"
    older_two = output_dir / "JamfReport_2026-04-02_010101.html"
    older_one.write_text("<html>old1</html>", encoding="utf-8")
    older_two.write_text("<html>old2</html>", encoding="utf-8")

    class FakeBridge:
        def is_available(self) -> bool:
            return True

    monkeypatch.setattr(jrc, "_build_jamf_cli_bridge", lambda *args, **kwargs: FakeBridge())

    def fake_generate(self):
        self._out_file.parent.mkdir(parents=True, exist_ok=True)
        self._out_file.write_text("<html>new</html>", encoding="utf-8")
        return self._out_file

    monkeypatch.setattr(jrc.HtmlReport, "generate", fake_generate)

    out_path = jrc.cmd_html(config, None, no_open=True)

    archive_dir = output_dir / "archive" / "JamfReport"
    assert out_path.exists()
    assert len(list(output_dir.glob("JamfReport_*.html"))) == 1
    archived_names = {path.name for path in archive_dir.glob("*.html")}
    assert older_one.name in archived_names
    assert older_two.name in archived_names


@pytest.mark.integration
def test_launchagent_setup_writes_disabled_python_owned_plist(
    config_factory,
    tmp_path: Path,
    monkeypatch,
    jrc,
) -> None:
    config = config_factory("dummy.yaml")
    config._data["jamf_cli"]["profile"] = "dummy"
    workspace_dir = tmp_path / "workspace"
    agents_dir = tmp_path / "agents"
    monkeypatch.setattr(jrc, "_unload_launchagent", lambda _label: "gui/test")

    jrc.cmd_launchagent_setup(
        config,
        str(config.path),
        None,
        "csv-assisted",
        "daily",
        "06:15",
        None,
        None,
        str(workspace_dir),
        str(agents_dir),
        None,
        None,
        None,
        None,
        True,
        False,
        True,
    )

    label = "com.github.tonyyo11.jamf-reports-community.dummy"
    plist_path = agents_dir / f"{label}.plist"
    payload = plistlib.loads(plist_path.read_bytes())

    assert payload["Label"] == label
    assert payload["Disabled"] is True
    assert payload["StartCalendarInterval"] == [{"Hour": 6, "Minute": 15}]
    assert payload["WorkingDirectory"] == str(config.base_dir)
    assert payload["StandardOutPath"] == str(
        workspace_dir / "automation" / "logs" / f"{label}.out.log"
    )
    assert payload["StandardErrorPath"] == str(
        workspace_dir / "automation" / "logs" / f"{label}.err.log"
    )
    args = payload["ProgramArguments"]
    assert "launchagent-run" in args
    assert ["--mode", "csv-assisted"] == args[args.index("--mode") : args.index("--mode") + 2]
    assert str(workspace_dir / "automation" / f"{label}_status.json") in args
    assert str(workspace_dir / "csv-inbox") in args


def test_write_launchagent_plist_keeps_existing_file_when_replace_fails(
    jrc,
    monkeypatch,
    tmp_path: Path,
) -> None:
    label = f"{_PREFIX}.dummy"
    plist_path = tmp_path / f"{label}.plist"
    old_payload = {"Label": label, "ProgramArguments": ["old"]}
    plist_path.write_bytes(plistlib.dumps(old_payload, sort_keys=True))

    real_replace = jrc.os.replace

    def fake_replace(src, dst):  # noqa: ANN001 - mirrors os.replace
        if Path(dst) == plist_path:
            raise OSError("replace blocked")
        real_replace(src, dst)

    monkeypatch.setattr(jrc.os, "replace", fake_replace)

    with pytest.raises(OSError, match="replace blocked"):
        jrc._write_launchagent_plist(
            plist_path,
            label,
            ["new"],
            tmp_path,
            [{"Hour": 6, "Minute": 15}],
            tmp_path / "out.log",
            tmp_path / "err.log",
        )

    assert plistlib.loads(plist_path.read_bytes()) == old_payload
    previous_path = jrc._launchagent_previous_plist_path(plist_path)
    assert plistlib.loads(previous_path.read_bytes()) == old_payload
    assert list(tmp_path.glob(".*.tmp")) == []


def test_load_launchagent_restores_previous_plist_when_replacement_bootstrap_fails(
    jrc,
    monkeypatch,
    tmp_path: Path,
) -> None:
    label = f"{_PREFIX}.dummy"
    plist_path = tmp_path / f"{label}.plist"
    previous_path = jrc._launchagent_previous_plist_path(plist_path)
    old_payload = {"Label": label, "ProgramArguments": ["old"]}
    new_payload = {"Label": label, "ProgramArguments": ["new"]}
    plist_path.write_bytes(plistlib.dumps(new_payload, sort_keys=True))
    previous_path.write_bytes(plistlib.dumps(old_payload, sort_keys=True))

    calls: list[list[str]] = []
    bootstrap_payloads: list[str] = []

    def fake_run(cmd, **_kwargs):  # noqa: ANN001 - mirrors subprocess.run
        calls.append(list(cmd))
        if cmd[1] == "bootstrap":
            payload = plistlib.loads(plist_path.read_bytes())
            bootstrap_payloads.append(payload["ProgramArguments"][0])
            if len(bootstrap_payloads) == 1:
                raise subprocess.CalledProcessError(5, cmd, stderr="bad plist")
        return subprocess.CompletedProcess(cmd, 0, stdout="", stderr="")

    monkeypatch.setattr(jrc.subprocess, "run", fake_run)

    with pytest.raises(SystemExit) as excinfo:
        jrc._load_launchagent(plist_path, label, run_now=False)

    assert "Error: launchctl bootstrap failed: bad plist" in str(excinfo.value)
    assert "Previous LaunchAgent restored and reloaded." in str(excinfo.value)
    assert [cmd[1] for cmd in calls] == ["bootout", "bootstrap", "bootstrap", "enable"]
    assert bootstrap_payloads == ["new", "old"]
    assert plistlib.loads(plist_path.read_bytes()) == old_payload
    assert not previous_path.exists()


def test_launchagent_setup_rejects_legacy_swift_label(config_factory, tmp_path: Path, jrc) -> None:
    config = config_factory("dummy.yaml")
    config._data["jamf_cli"]["profile"] = "dummy"

    with pytest.raises(SystemExit, match="LaunchAgent label must start"):
        jrc.cmd_launchagent_setup(
            config,
            str(config.path),
            "com.tonyyo.jrc.dummy.daily",
            "jamf-cli-only",
            "daily",
            "06:15",
            None,
            None,
            str(tmp_path / "workspace"),
            str(tmp_path / "agents"),
            None,
            None,
            None,
            None,
            True,
            False,
            False,
        )


# ---------------------------------------------------------------------------
# _validate_launchagent_label — direct edge-case coverage
# ---------------------------------------------------------------------------

# The Swift app's ``LaunchAgentWriter.isValidLabel`` and the Python validator
# must agree on the allowed character set ([a-z0-9._-]). Anything either side
# accepts that the other rejects produces a plist that the GUI cannot load.

_PREFIX = "com.github.tonyyo11.jamf-reports-community"


@pytest.mark.parametrize(
    "label",
    [
        f"{_PREFIX}.dummy",
        f"{_PREFIX}.dummy.daily",
        f"{_PREFIX}.harbor-edu_v2",
        f"{_PREFIX}.school-test.weekly-mon",
    ],
)
def test_validate_launchagent_label_accepts_valid_labels(jrc, label: str) -> None:
    assert jrc._validate_launchagent_label(label) == label


@pytest.mark.parametrize(
    "label,reason",
    [
        (f"{_PREFIX}.Dummy", "uppercase"),
        (f"{_PREFIX}.DAILY", "uppercase"),
        (f"{_PREFIX}.dummy.", "trailing dot"),
        (f"{_PREFIX}.dummy..weekly", "double dot"),
        (f"{_PREFIX}.dummy daily", "whitespace"),
        (f"{_PREFIX}.dummy/weekly", "slash"),
        ("com.example.other.dummy", "wrong prefix"),
        (_PREFIX, "no namespace tail"),
        (f"{_PREFIX}.", "empty tail"),
    ],
)
def test_validate_launchagent_label_rejects_invalid_labels(jrc, label: str, reason: str) -> None:
    del reason  # included for readable parametrize ids
    with pytest.raises(SystemExit, match="LaunchAgent label"):
        jrc._validate_launchagent_label(label)


def test_validate_launchagent_label_strips_surrounding_whitespace(jrc) -> None:
    label = f"  {_PREFIX}.dummy  "
    assert jrc._validate_launchagent_label(label) == f"{_PREFIX}.dummy"


def test_default_launchagent_label_lowercases_uppercase_profile_stem(jrc, tmp_path: Path) -> None:
    """A config stem that contains uppercase still yields a Swift-loadable label.

    Profiles are validated lowercase, but if the config has no profile and the
    file stem is mixed-case (e.g. ``Dummy.yaml``), the auto-generated label
    must still pass ``_validate_launchagent_label``.
    """
    cfg_path = tmp_path / "DummyTenant.yaml"
    cfg_path.write_text("jamf_cli:\n  enabled: true\n", encoding="utf-8")
    config = jrc.Config(str(cfg_path))
    label = jrc._default_launchagent_label(config)
    # Same string must round-trip through the validator without raising.
    assert jrc._validate_launchagent_label(label) == label
    assert label.startswith(f"{_PREFIX}.")
    # Tail must contain only the Swift-allowed character set.
    tail = label[len(_PREFIX) + 1:]
    assert tail == tail.lower()
