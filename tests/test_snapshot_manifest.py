"""Tests for SHA-256 manifest write + verification on jamf-cli snapshots.

Threat-model T-2 (Google Gemini security-review 2026-05-12): detect tampering
of cached `jamf-cli-data/*.json` between collection and report generation.

Coverage:
- Happy path: manifest written on snapshot save; verifier accepts matching hash.
- Tampered path: contents mutated after manifest write triggers a `[warn]`
  line on read; with `strict=True` the verifier raises.
- Missing manifest: legacy snapshots without a sibling manifest are loaded
  silently with no warn and no abort.
- Manifest is excluded from snapshot globs so it's never mistaken for a payload.
"""

from __future__ import annotations

import json
from pathlib import Path

import pytest


# ---------------------------------------------------------------------------
# Manifest writer
# ---------------------------------------------------------------------------


def test_rewrite_manifest_lists_every_snapshot_file(jrc, tmp_path):
    snapshot_dir = tmp_path / "snapshots"
    snapshot_dir.mkdir()
    a = snapshot_dir / "audit_20260101T000000.json"
    a.write_text('{"a":1}', encoding="utf-8")
    b = snapshot_dir / "audit_20260201T000000.json"
    b.write_text('{"b":2}', encoding="utf-8")

    jrc._rewrite_snapshot_manifest(snapshot_dir)

    manifest_path = snapshot_dir / jrc.SNAPSHOT_MANIFEST_FILENAME
    assert manifest_path.is_file()
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    assert manifest["algorithm"] == "sha256"
    assert set(manifest["files"].keys()) == {a.name, b.name}
    # SHA-256 hex digest is 64 chars.
    assert all(len(v) == 64 for v in manifest["files"].values())


def test_rewrite_manifest_excludes_self_and_partial(jrc, tmp_path):
    snapshot_dir = tmp_path / "snapshots"
    snapshot_dir.mkdir()
    (snapshot_dir / "audit_20260101T000000.json").write_text("{}", encoding="utf-8")
    (snapshot_dir / "audit_20260101T000000.partial").write_text("{}", encoding="utf-8")
    # Pre-existing manifest must be replaced, not double-counted.
    (snapshot_dir / jrc.SNAPSHOT_MANIFEST_FILENAME).write_text(
        '{"old":true}', encoding="utf-8"
    )

    jrc._rewrite_snapshot_manifest(snapshot_dir)

    manifest = json.loads(
        (snapshot_dir / jrc.SNAPSHOT_MANIFEST_FILENAME).read_text(encoding="utf-8")
    )
    assert list(manifest["files"].keys()) == ["audit_20260101T000000.json"]


def test_rewrite_manifest_drops_purged_files(jrc, tmp_path):
    """Older files purged by keep_latest_runs must not stay in the manifest."""
    snapshot_dir = tmp_path / "snapshots"
    snapshot_dir.mkdir()
    a = snapshot_dir / "audit_20260101T000000.json"
    b = snapshot_dir / "audit_20260201T000000.json"
    a.write_text("{}", encoding="utf-8")
    b.write_text("{}", encoding="utf-8")
    jrc._rewrite_snapshot_manifest(snapshot_dir)

    # Simulate keep_latest_runs purging the older file, then a new collect.
    a.unlink()
    jrc._rewrite_snapshot_manifest(snapshot_dir)

    manifest = json.loads(
        (snapshot_dir / jrc.SNAPSHOT_MANIFEST_FILENAME).read_text(encoding="utf-8")
    )
    assert list(manifest["files"].keys()) == [b.name]


# ---------------------------------------------------------------------------
# Verifier
# ---------------------------------------------------------------------------


def test_verify_happy_path(jrc, tmp_path, capsys):
    snapshot_dir = tmp_path / "snapshots"
    snapshot_dir.mkdir()
    snap = snapshot_dir / "audit_20260101T000000.json"
    snap.write_text('{"ok": true}', encoding="utf-8")
    jrc._rewrite_snapshot_manifest(snapshot_dir)

    # No exception, no warn output.
    jrc._verify_snapshot_against_manifest(snap)
    out = capsys.readouterr().out
    assert "[warn]" not in out


def test_verify_tampered_warns_when_not_strict(jrc, tmp_path, capsys):
    snapshot_dir = tmp_path / "snapshots"
    snapshot_dir.mkdir()
    snap = snapshot_dir / "audit_20260101T000000.json"
    snap.write_text('{"a": 1}', encoding="utf-8")
    jrc._rewrite_snapshot_manifest(snapshot_dir)

    # Tamper after manifest write.
    snap.write_text('{"a": 2}', encoding="utf-8")

    jrc._verify_snapshot_against_manifest(snap)
    out = capsys.readouterr().out
    assert "[warn]" in out
    assert "SHA-256 mismatch" in out


def test_verify_tampered_raises_when_strict(jrc, tmp_path):
    snapshot_dir = tmp_path / "snapshots"
    snapshot_dir.mkdir()
    snap = snapshot_dir / "audit_20260101T000000.json"
    snap.write_text('{"a": 1}', encoding="utf-8")
    jrc._rewrite_snapshot_manifest(snapshot_dir)
    snap.write_text('{"a": 2}', encoding="utf-8")

    with pytest.raises(RuntimeError, match="SHA-256 mismatch"):
        jrc._verify_snapshot_against_manifest(snap, strict=True)


def test_verify_silent_when_manifest_absent(jrc, tmp_path, capsys):
    """Legacy snapshots without a manifest are loaded without warn."""
    snapshot_dir = tmp_path / "snapshots"
    snapshot_dir.mkdir()
    snap = snapshot_dir / "audit_20260101T000000.json"
    snap.write_text("{}", encoding="utf-8")

    jrc._verify_snapshot_against_manifest(snap)
    out = capsys.readouterr().out
    assert "[warn]" not in out


def test_verify_silent_when_manifest_missing_entry(jrc, tmp_path, capsys):
    """A snapshot dropped in after manifest write is left alone (partial collect)."""
    snapshot_dir = tmp_path / "snapshots"
    snapshot_dir.mkdir()
    a = snapshot_dir / "audit_20260101T000000.json"
    a.write_text("{}", encoding="utf-8")
    jrc._rewrite_snapshot_manifest(snapshot_dir)
    # Drop in a second snapshot without rewriting manifest.
    b = snapshot_dir / "audit_20260201T000000.json"
    b.write_text("{}", encoding="utf-8")

    jrc._verify_snapshot_against_manifest(b)
    out = capsys.readouterr().out
    assert "[warn]" not in out


# ---------------------------------------------------------------------------
# Bridge integration: manifest written on save, excluded from _latest_cached_json
# ---------------------------------------------------------------------------


def test_latest_cached_json_skips_manifest(jrc, tmp_path):
    data_dir = tmp_path / "jamf-cli-data"
    (data_dir / "audit").mkdir(parents=True)
    snap = data_dir / "audit" / "audit_20260101T000000.json"
    snap.write_text('{"ok": true}', encoding="utf-8")
    # Stage a manifest in the same dir; it must not be picked as the "latest".
    jrc._rewrite_snapshot_manifest(data_dir / "audit")

    bridge = jrc.JamfCLIBridge(save_output=False, data_dir=str(data_dir))
    latest = bridge._latest_cached_json(["audit"])

    assert latest == snap
    assert latest.name != jrc.SNAPSHOT_MANIFEST_FILENAME


def test_load_cached_json_strict_raises_on_tamper(jrc, tmp_path):
    data_dir = tmp_path / "jamf-cli-data"
    audit_dir = data_dir / "audit"
    audit_dir.mkdir(parents=True)
    snap = audit_dir / "audit_20260101T000000.json"
    snap.write_text('{"ok": true}', encoding="utf-8")
    jrc._rewrite_snapshot_manifest(audit_dir)

    snap.write_text('{"ok": false}', encoding="utf-8")

    bridge = jrc.JamfCLIBridge(
        save_output=False, data_dir=str(data_dir), strict_manifest=True
    )
    with pytest.raises(RuntimeError, match="SHA-256 mismatch"):
        bridge._load_cached_json(["audit"])


def test_load_cached_json_warns_on_tamper_when_not_strict(jrc, tmp_path, capsys):
    data_dir = tmp_path / "jamf-cli-data"
    audit_dir = data_dir / "audit"
    audit_dir.mkdir(parents=True)
    snap = audit_dir / "audit_20260101T000000.json"
    snap.write_text('{"ok": true}', encoding="utf-8")
    jrc._rewrite_snapshot_manifest(audit_dir)

    snap.write_text('{"ok": false}', encoding="utf-8")

    bridge = jrc.JamfCLIBridge(save_output=False, data_dir=str(data_dir))
    # Returns the (tampered) payload; warn surfaced via stdout.
    payload = bridge._load_cached_json(["audit"])
    out = capsys.readouterr().out
    assert "[warn]" in out
    assert "SHA-256 mismatch" in out
    assert payload == {"ok": False}
