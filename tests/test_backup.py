"""Tests for ``cmd_backup`` and its safe-rmtree guard.

The backup flow shells out to ``jamf-cli pro backup`` and ends with an atomic
``rename(temp_dir -> final_dir)``. The ``shutil.rmtree`` that runs *before* the
backup starts is the dangerous step: a leftover ``*.partial`` directory from
an interrupted run is fine, but a symlink, a sibling directory, or any path
that escapes ``backups_root`` is not. These tests exercise both the happy
path and the guard's rejection paths.
"""

from __future__ import annotations

import json
import os
import subprocess
from pathlib import Path
from typing import Any
from unittest.mock import patch

import pytest


def _make_config(jrc, tmp_path: Path, *, profile: str = "dummy") -> Any:
    """Return a minimal Config rooted at ``tmp_path`` with jamf-cli enabled."""
    cfg_path = tmp_path / "config.yaml"
    cfg_path.write_text(
        "jamf_cli:\n"
        "  enabled: true\n"
        f"  profile: {profile}\n"
        "  data_dir: jamf-cli-data\n"
        "  command_timeout_seconds: 30\n",
        encoding="utf-8",
    )
    return jrc.Config(str(cfg_path))


def _fake_completed_process(stdout: str = "", stderr: str = "") -> Any:
    """Return a stand-in for ``subprocess.run`` success."""
    return subprocess.CompletedProcess(
        args=["jamf-cli", "pro", "backup"],
        returncode=0,
        stdout=stdout,
        stderr=stderr,
    )


def test_cmd_backup_writes_manifest_and_renames_to_final(tmp_path, monkeypatch, jrc) -> None:
    config = _make_config(jrc, tmp_path)
    backups_root = tmp_path / "backups"

    captured: dict[str, Any] = {}

    def fake_run(cmd, **kwargs):  # noqa: ANN001 - subprocess.run signature
        captured["cmd"] = cmd
        captured["timeout"] = kwargs.get("timeout")
        # Simulate jamf-cli writing one fixture file into the temp directory.
        output_dir = Path(cmd[cmd.index("--output") + 1])
        output_dir.mkdir(parents=True, exist_ok=True)
        (output_dir / "policies.json").write_text(
            json.dumps([{"id": 1, "name": "demo"}]),
            encoding="utf-8",
        )
        return _fake_completed_process(stdout="ok\n")

    monkeypatch.setattr(jrc, "_find_jamf_cli_binary", lambda: "/fake/bin/jamf-cli")
    monkeypatch.setattr(jrc.subprocess, "run", fake_run)

    final_dir = jrc.cmd_backup(config, label="weekly snapshot")

    assert final_dir.exists()
    assert final_dir.parent == backups_root
    assert (final_dir / "policies.json").exists()
    manifest = json.loads((final_dir / "manifest.json").read_text(encoding="utf-8"))
    assert manifest["schema_version"] == 1
    assert manifest["profile"] == "dummy"
    assert manifest["label"] == "weekly snapshot"
    assert manifest["file_count"] == 1
    assert manifest["size_bytes"] > 0
    # No partial directory should remain after a successful run.
    partials = list(backups_root.glob(".*.partial"))
    assert partials == []
    # CLI received a -p override and the temp output path.
    assert captured["cmd"][0] == "/fake/bin/jamf-cli"
    assert "-p" in captured["cmd"] and captured["cmd"][captured["cmd"].index("-p") + 1] == "dummy"
    assert "--no-input" in captured["cmd"]


def test_cmd_backup_cleans_leftover_partial_before_run(tmp_path, monkeypatch, jrc) -> None:
    config = _make_config(jrc, tmp_path)
    backups_root = (tmp_path / "backups").resolve()
    backups_root.mkdir(parents=True, exist_ok=True)

    # Pre-create a leftover ``.partial`` matching the destination jamf-cli will pick.
    final_dir, temp_dir = jrc._backup_destination(config, label="leftover")
    temp_dir.mkdir(parents=True, exist_ok=True)
    (temp_dir / "stale.json").write_text("{}", encoding="utf-8")

    def fake_run(cmd, **_kwargs):  # noqa: ANN001
        output_dir = Path(cmd[cmd.index("--output") + 1])
        # The leftover should already be gone because the guard cleared it.
        assert not (output_dir / "stale.json").exists()
        output_dir.mkdir(parents=True, exist_ok=True)
        (output_dir / "policies.json").write_text("[]", encoding="utf-8")
        return _fake_completed_process()

    # _backup_destination picks a fresh stamp+suffix on each call, so make it deterministic.
    monkeypatch.setattr(jrc, "_backup_destination", lambda *_a, **_kw: (final_dir, temp_dir))
    monkeypatch.setattr(jrc, "_find_jamf_cli_binary", lambda: "/fake/bin/jamf-cli")
    monkeypatch.setattr(jrc.subprocess, "run", fake_run)

    jrc.cmd_backup(config, label="leftover")

    assert final_dir.exists()
    assert not temp_dir.exists()


def test_safe_remove_partial_backup_rejects_path_outside_root(tmp_path, jrc) -> None:
    backups_root = (tmp_path / "backups").resolve()
    backups_root.mkdir()
    outside = (tmp_path / "evil").resolve()
    outside.mkdir()
    bogus = outside / ".pretend.partial"
    bogus.mkdir()

    with pytest.raises(SystemExit, match="outside backups root"):
        jrc._safe_remove_partial_backup(bogus, backups_root)
    # The directory must still exist — guard refused to act.
    assert bogus.exists()


def test_safe_remove_partial_backup_rejects_symlink(tmp_path, jrc) -> None:
    backups_root = (tmp_path / "backups").resolve()
    backups_root.mkdir()
    target = (tmp_path / "outside").resolve()
    target.mkdir()
    link = backups_root / ".redirect.partial"
    os.symlink(target, link)

    with pytest.raises(SystemExit, match="unexpected backup temp dir"):
        jrc._safe_remove_partial_backup(link, backups_root)
    # Symlink itself stays; target is untouched.
    assert link.is_symlink()
    assert target.exists()


def test_safe_remove_partial_backup_rejects_non_partial_name(tmp_path, jrc) -> None:
    backups_root = (tmp_path / "backups").resolve()
    backups_root.mkdir()
    real_backup = backups_root / "2026-04-29_120000"
    real_backup.mkdir()

    with pytest.raises(SystemExit, match="unexpected backup temp dir"):
        jrc._safe_remove_partial_backup(real_backup, backups_root)
    assert real_backup.exists()


def test_safe_remove_partial_backup_no_op_when_missing(tmp_path, jrc) -> None:
    backups_root = (tmp_path / "backups").resolve()
    backups_root.mkdir()
    missing = backups_root / ".not-there.partial"
    # Should silently return — no exception, nothing to do.
    jrc._safe_remove_partial_backup(missing, backups_root)


def test_safe_remove_partial_backup_reports_cleanup_failure(tmp_path, monkeypatch, jrc) -> None:
    backups_root = (tmp_path / "backups").resolve()
    backups_root.mkdir()
    stale = backups_root / ".stale.partial"
    stale.mkdir()

    def fail_rmtree(_path):  # noqa: ANN001
        raise OSError("permission denied")

    monkeypatch.setattr(jrc.shutil, "rmtree", fail_rmtree)

    with pytest.raises(SystemExit, match="failed to remove backup temp dir"):
        jrc._safe_remove_partial_backup(stale, backups_root)
    assert stale.exists()


def test_cmd_backup_requires_jamf_cli_enabled(tmp_path, jrc) -> None:
    cfg_path = tmp_path / "config.yaml"
    cfg_path.write_text(
        "jamf_cli:\n  enabled: false\n",
        encoding="utf-8",
    )
    config = jrc.Config(str(cfg_path))
    with pytest.raises(SystemExit, match="jamf_cli.enabled is false"):
        jrc.cmd_backup(config)


def test_cmd_backup_requires_jamf_cli_binary(tmp_path, monkeypatch, jrc) -> None:
    config = _make_config(jrc, tmp_path)
    monkeypatch.setattr(jrc, "_find_jamf_cli_binary", lambda: None)
    with pytest.raises(SystemExit, match="jamf-cli binary not found"):
        jrc.cmd_backup(config)


def test_cmd_backup_cleans_temp_dir_on_subprocess_failure(tmp_path, monkeypatch, jrc) -> None:
    config = _make_config(jrc, tmp_path)
    monkeypatch.setattr(jrc, "_find_jamf_cli_binary", lambda: "/fake/bin/jamf-cli")

    def boom(cmd, **_kwargs):  # noqa: ANN001
        output_dir = Path(cmd[cmd.index("--output") + 1])
        output_dir.mkdir(parents=True, exist_ok=True)
        (output_dir / "incomplete.json").write_text("partial", encoding="utf-8")
        raise subprocess.CalledProcessError(returncode=2, cmd=cmd, stderr="boom")

    monkeypatch.setattr(jrc.subprocess, "run", boom)

    with pytest.raises(SystemExit, match="jamf-cli pro backup failed"):
        jrc.cmd_backup(config)

    # No leftover .partial directory should remain after the failure.
    backups_root = (tmp_path / "backups").resolve()
    assert list(backups_root.glob(".*.partial")) == []


def test_cmd_backup_cleans_temp_dir_on_timeout(tmp_path, monkeypatch, jrc) -> None:
    config = _make_config(jrc, tmp_path)
    monkeypatch.setattr(jrc, "_find_jamf_cli_binary", lambda: "/fake/bin/jamf-cli")

    def slow(cmd, **_kwargs):  # noqa: ANN001
        output_dir = Path(cmd[cmd.index("--output") + 1])
        output_dir.mkdir(parents=True, exist_ok=True)
        raise subprocess.TimeoutExpired(cmd=cmd, timeout=30)

    monkeypatch.setattr(jrc.subprocess, "run", slow)

    with pytest.raises(SystemExit, match="timed out after"):
        jrc.cmd_backup(config)

    backups_root = (tmp_path / "backups").resolve()
    assert list(backups_root.glob(".*.partial")) == []


def test_cmd_backup_cleans_temp_dir_on_stats_failure_after_success(
    tmp_path, monkeypatch, jrc
) -> None:
    config = _make_config(jrc, tmp_path)
    monkeypatch.setattr(jrc, "_find_jamf_cli_binary", lambda: "/fake/bin/jamf-cli")

    def fake_run(cmd, **_kwargs):  # noqa: ANN001
        output_dir = Path(cmd[cmd.index("--output") + 1])
        output_dir.mkdir(parents=True, exist_ok=True)
        (output_dir / "policies.json").write_text("[]", encoding="utf-8")
        return _fake_completed_process()

    def fail_stats(_path):  # noqa: ANN001
        raise OSError("stat denied")

    monkeypatch.setattr(jrc.subprocess, "run", fake_run)
    monkeypatch.setattr(jrc, "_backup_directory_stats", fail_stats)

    with pytest.raises(SystemExit, match="backup finalization failed after jamf-cli completed"):
        jrc.cmd_backup(config)

    backups_root = (tmp_path / "backups").resolve()
    assert list(backups_root.glob(".*.partial")) == []


def test_cmd_backup_cleans_temp_dir_on_manifest_failure_after_success(
    tmp_path, monkeypatch, jrc
) -> None:
    config = _make_config(jrc, tmp_path)
    monkeypatch.setattr(jrc, "_find_jamf_cli_binary", lambda: "/fake/bin/jamf-cli")

    def fake_run(cmd, **_kwargs):  # noqa: ANN001
        output_dir = Path(cmd[cmd.index("--output") + 1])
        output_dir.mkdir(parents=True, exist_ok=True)
        (output_dir / "policies.json").write_text("[]", encoding="utf-8")
        return _fake_completed_process()

    def fail_manifest(_backup_dir, _manifest):  # noqa: ANN001
        raise OSError("manifest denied")

    monkeypatch.setattr(jrc.subprocess, "run", fake_run)
    monkeypatch.setattr(jrc, "_write_backup_manifest", fail_manifest)

    with pytest.raises(SystemExit, match="backup finalization failed after jamf-cli completed"):
        jrc.cmd_backup(config)

    backups_root = (tmp_path / "backups").resolve()
    assert list(backups_root.glob(".*.partial")) == []


def test_cmd_backup_cleans_temp_dir_on_final_rename_failure_after_success(
    tmp_path, monkeypatch, jrc
) -> None:
    config = _make_config(jrc, tmp_path)
    final_dir, temp_dir = jrc._backup_destination(config, label="rename fail")

    def fake_run(cmd, **_kwargs):  # noqa: ANN001
        output_dir = Path(cmd[cmd.index("--output") + 1])
        output_dir.mkdir(parents=True, exist_ok=True)
        (output_dir / "policies.json").write_text("[]", encoding="utf-8")
        return _fake_completed_process()

    original_rename = jrc.Path.rename

    def fail_final_rename(self, target):  # noqa: ANN001
        if self == temp_dir and target == final_dir:
            raise OSError("rename denied")
        return original_rename(self, target)

    monkeypatch.setattr(jrc, "_backup_destination", lambda *_a, **_kw: (final_dir, temp_dir))
    monkeypatch.setattr(jrc, "_find_jamf_cli_binary", lambda: "/fake/bin/jamf-cli")
    monkeypatch.setattr(jrc.subprocess, "run", fake_run)
    monkeypatch.setattr(jrc.Path, "rename", fail_final_rename)

    with pytest.raises(SystemExit, match="backup finalization failed after jamf-cli completed"):
        jrc.cmd_backup(config, label="rename fail")

    backups_root = (tmp_path / "backups").resolve()
    assert not final_dir.exists()
    assert list(backups_root.glob(".*.partial")) == []


def test_cmd_backup_reports_finalization_and_cleanup_failures(
    tmp_path, monkeypatch, jrc
) -> None:
    config = _make_config(jrc, tmp_path)
    monkeypatch.setattr(jrc, "_find_jamf_cli_binary", lambda: "/fake/bin/jamf-cli")

    def fake_run(cmd, **_kwargs):  # noqa: ANN001
        output_dir = Path(cmd[cmd.index("--output") + 1])
        output_dir.mkdir(parents=True, exist_ok=True)
        (output_dir / "policies.json").write_text("[]", encoding="utf-8")
        return _fake_completed_process()

    def fail_manifest(_backup_dir, _manifest):  # noqa: ANN001
        raise OSError("manifest denied")

    def fail_rmtree(_path):  # noqa: ANN001
        raise OSError("cleanup denied")

    monkeypatch.setattr(jrc.subprocess, "run", fake_run)
    monkeypatch.setattr(jrc, "_write_backup_manifest", fail_manifest)
    monkeypatch.setattr(jrc.shutil, "rmtree", fail_rmtree)

    with pytest.raises(SystemExit) as exc_info:
        jrc.cmd_backup(config)

    message = str(exc_info.value)
    assert "backup finalization failed after jamf-cli completed" in message
    assert "additionally failed to remove temp backup" in message
    assert "failed to remove backup temp dir" in message

    backups_root = (tmp_path / "backups").resolve()
    assert len(list(backups_root.glob(".*.partial"))) == 1
