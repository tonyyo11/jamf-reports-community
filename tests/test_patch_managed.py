"""Coverage for cmd_patch_managed — the only production-WRITE CLI path.

These tests exercise the dry-run preview, serials-file parsing (valid, missing,
malformed), the no-serials opposite-state device selection, and per-device error
handling. The jamf-cli bridge is always mocked: no live PATCH is ever issued.
"""
from __future__ import annotations

import pytest


class _FakeBridge:
    """Stub JamfCLIBridge. Records every computers_inventory_patch call and can be
    told which serials should raise on patch."""

    def __init__(self, *, available=True, compliance_rows=None, raise_on=None):
        self._available = available
        self._compliance_rows = compliance_rows if compliance_rows is not None else []
        self._raise_on = set(raise_on or [])
        self.patched: list[tuple[str, dict]] = []

    def is_available(self):
        return self._available

    def device_compliance(self, _days_since_checkin=None):
        return self._compliance_rows

    def computers_inventory_patch(self, serial, field_values):
        if serial in self._raise_on:
            raise RuntimeError("jamf-cli failed (1): server error")
        self.patched.append((serial, field_values))
        return {"general": {"managed": field_values.get("general.managed")}}


@pytest.fixture
def patch_env(jrc, config_factory, monkeypatch):
    """Return a helper that wires a FakeBridge and a config, returning both."""

    def _make(**bridge_kwargs):
        config = config_factory("dummy.yaml")
        # patch-managed requires jamf_cli.enabled.
        config._data["jamf_cli"]["enabled"] = True
        bridge = _FakeBridge(**bridge_kwargs)
        monkeypatch.setattr(jrc, "_build_jamf_cli_bridge", lambda *_a, **_k: bridge)
        return config, bridge

    return _make


# --- dry-run -----------------------------------------------------------------

def test_dry_run_makes_no_patch_calls(jrc, patch_env, tmp_path, capsys):
    serials_file = tmp_path / "serials.txt"
    serials_file.write_text("ABC123\nDEF456\n", encoding="utf-8")
    config, bridge = patch_env()
    jrc.cmd_patch_managed(config, True, dry_run=True, serials_file=str(serials_file))
    out = capsys.readouterr().out
    assert "[dry-run]" in out
    assert "general.managed=true" in out
    assert bridge.patched == []  # NO write performed


# --- serials-file parsing ----------------------------------------------------

def test_serials_file_valid_patches_each(jrc, patch_env, tmp_path):
    serials_file = tmp_path / "serials.txt"
    serials_file.write_text(
        "# header comment\nABC123\n\n  DEF456  \n# trailing\n", encoding="utf-8"
    )
    config, bridge = patch_env()
    jrc.cmd_patch_managed(config, False, dry_run=False, serials_file=str(serials_file))
    patched_serials = [s for s, _ in bridge.patched]
    assert patched_serials == ["ABC123", "DEF456"]  # comments/blanks dropped, trimmed
    assert all(fv == {"general.managed": "false"} for _, fv in bridge.patched)


def test_serials_file_missing_raises(jrc, patch_env, tmp_path):
    config, bridge = patch_env()
    missing = tmp_path / "nope.txt"
    with pytest.raises(SystemExit) as exc:
        jrc.cmd_patch_managed(config, True, dry_run=True, serials_file=str(missing))
    assert "reading serials file" in str(exc.value).lower()


def test_serials_file_empty_after_parsing_raises(jrc, patch_env, tmp_path):
    """A file of only comments/blank lines has no usable serials → SystemExit."""
    serials_file = tmp_path / "serials.txt"
    serials_file.write_text("# only a comment\n\n   \n", encoding="utf-8")
    config, bridge = patch_env()
    with pytest.raises(SystemExit) as exc:
        jrc.cmd_patch_managed(config, True, dry_run=True, serials_file=str(serials_file))
    assert "no serial numbers found" in str(exc.value).lower()


def test_read_serials_file_drops_comments_and_blanks(jrc, tmp_path):
    serials_file = tmp_path / "s.txt"
    serials_file.write_text("#c\nAAA\n\n  BBB  \nCCC#notacomment\n", encoding="utf-8")
    serials = jrc._read_serials_file(str(serials_file))
    assert serials == ["AAA", "BBB", "CCC#notacomment"]


# --- no-serials opposite-state selection -------------------------------------

def test_no_serials_selects_opposite_state_devices(jrc, patch_env):
    # Target managed=True → select devices currently NOT managed.
    rows = [
        {"serial": "MANAGED1", "managed": True},
        {"serial": "UNMANAGED1", "managed": False},
        {"serial": "UNMANAGED2", "managed": "false"},
        {"serial": "", "managed": False},          # blank serial dropped
        {"serial": "MANAGED2", "managed": "true"},
    ]
    config, bridge = patch_env(compliance_rows=rows)
    jrc.cmd_patch_managed(config, True, dry_run=False, serials_file=None)
    patched = [s for s, _ in bridge.patched]
    assert patched == ["UNMANAGED1", "UNMANAGED2"]
    assert all(fv == {"general.managed": "true"} for _, fv in bridge.patched)


def test_no_serials_empty_compliance_raises(jrc, patch_env):
    config, bridge = patch_env(compliance_rows=[])
    with pytest.raises(SystemExit) as exc:
        jrc.cmd_patch_managed(config, True, dry_run=False, serials_file=None)
    assert "device-compliance returned no data" in str(exc.value).lower()


def test_no_serials_all_already_target_state_no_patch(jrc, patch_env, capsys):
    # Every device already managed; targeting managed=True selects none.
    rows = [{"serial": "A", "managed": True}, {"serial": "B", "managed": "true"}]
    config, bridge = patch_env(compliance_rows=rows)
    jrc.cmd_patch_managed(config, True, dry_run=False, serials_file=None)
    assert bridge.patched == []
    assert "No devices to patch." in capsys.readouterr().out


# --- per-device error handling -----------------------------------------------

def test_per_device_failure_continues_and_counts(jrc, patch_env, tmp_path, capsys):
    serials_file = tmp_path / "serials.txt"
    serials_file.write_text("OK1\nFAIL1\nOK2\n", encoding="utf-8")
    config, bridge = patch_env(raise_on=["FAIL1"])
    jrc.cmd_patch_managed(config, True, dry_run=False, serials_file=str(serials_file))
    patched = [s for s, _ in bridge.patched]
    assert patched == ["OK1", "OK2"]  # FAIL1 raised but loop continued
    out = capsys.readouterr().out
    assert "[fail] FAIL1" in out
    assert "2 patched, 1 failed" in out


def test_unsupported_subcommand_aborts(jrc, config_factory, monkeypatch, tmp_path):
    """An 'unknown command' / 'computers-inventory' error aborts with an upgrade
    hint rather than being counted as a per-device failure."""
    serials_file = tmp_path / "serials.txt"
    serials_file.write_text("X1\n", encoding="utf-8")

    class _OldBridge(_FakeBridge):
        def computers_inventory_patch(self, serial, field_values):
            raise RuntimeError('jamf-cli failed (2): unknown command "computers-inventory"')

    config = config_factory("dummy.yaml")
    config._data["jamf_cli"]["enabled"] = True
    monkeypatch.setattr(jrc, "_build_jamf_cli_bridge", lambda *_a, **_k: _OldBridge())
    with pytest.raises(SystemExit) as exc:
        jrc.cmd_patch_managed(config, True, dry_run=False, serials_file=str(serials_file))
    assert "v1.14.0" in str(exc.value)


def test_requires_jamf_cli_enabled(jrc, config_factory):
    config = config_factory("dummy.yaml")
    config._data["jamf_cli"]["enabled"] = False
    with pytest.raises(SystemExit) as exc:
        jrc.cmd_patch_managed(config, True, dry_run=True, serials_file=None)
    assert "jamf_cli.enabled" in str(exc.value)


def test_unavailable_bridge_aborts(jrc, patch_env, tmp_path):
    serials_file = tmp_path / "serials.txt"
    serials_file.write_text("X1\n", encoding="utf-8")
    config, bridge = patch_env(available=False)
    with pytest.raises(SystemExit) as exc:
        jrc.cmd_patch_managed(config, True, dry_run=True, serials_file=str(serials_file))
    assert "jamf-cli not found" in str(exc.value).lower()
