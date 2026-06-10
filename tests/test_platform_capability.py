"""Tests for the Platform API capability probe and gate helper."""

from __future__ import annotations

import json
import subprocess
from typing import Any

import pytest


def _make_completed(stdout: str, returncode: int = 0) -> subprocess.CompletedProcess:
    """Build a CompletedProcess that subprocess.run would return."""
    return subprocess.CompletedProcess(
        args=["jamf-cli", "config", "list", "--output", "json", "--no-input"],
        returncode=returncode,
        stdout=stdout,
        stderr="",
    )


def _bridge_with_binary(jrc, monkeypatch, *, profile: str = "") -> Any:
    """Return a bridge configured as if jamf-cli were installed."""
    monkeypatch.setattr(jrc, "_find_jamf_cli_binary", lambda: "/fake/jamf-cli")
    return jrc.JamfCLIBridge(
        save_output=False,
        use_cached_data=False,
        profile=profile,
    )


# ---------------------------------------------------------------------------
# has_platform_auth()
# ---------------------------------------------------------------------------


def test_has_platform_auth_true_when_profile_uses_platform_auth(monkeypatch, jrc) -> None:
    bridge = _bridge_with_binary(jrc, monkeypatch, profile="lighthouse")
    output = json.dumps([
        {"name": "lighthouse", "url": "https://gw", "auth-method": "platform", "default": True},
    ])
    monkeypatch.setattr(subprocess, "run", lambda *a, **kw: _make_completed(output))

    assert bridge.has_platform_auth() is True


def test_has_platform_auth_false_when_profile_uses_oauth2(monkeypatch, jrc) -> None:
    bridge = _bridge_with_binary(jrc, monkeypatch, profile="dummy")
    output = json.dumps([
        {"name": "dummy", "url": "https://x", "auth-method": "oauth2", "default": True},
    ])
    monkeypatch.setattr(subprocess, "run", lambda *a, **kw: _make_completed(output))

    assert bridge.has_platform_auth() is False


def test_has_platform_auth_false_when_profile_not_found(monkeypatch, jrc) -> None:
    bridge = _bridge_with_binary(jrc, monkeypatch, profile="missing")
    output = json.dumps([
        {"name": "dummy", "url": "https://x", "auth-method": "oauth2", "default": True},
    ])
    monkeypatch.setattr(subprocess, "run", lambda *a, **kw: _make_completed(output))

    assert bridge.has_platform_auth() is False


def test_has_platform_auth_false_when_jamf_cli_missing(monkeypatch, jrc) -> None:
    monkeypatch.setattr(jrc, "_find_jamf_cli_binary", lambda: None)
    bridge = jrc.JamfCLIBridge(save_output=False, use_cached_data=False, profile="any")

    # subprocess.run should never be called when the binary is absent. Force a
    # failure if it is, so the test catches a regression.
    def fail_if_called(*_args, **_kwargs):
        raise AssertionError("subprocess.run should not be invoked when jamf-cli is absent")

    monkeypatch.setattr(subprocess, "run", fail_if_called)
    assert bridge.has_platform_auth() is False


def test_has_platform_auth_false_when_subprocess_raises(monkeypatch, jrc) -> None:
    bridge = _bridge_with_binary(jrc, monkeypatch, profile="lighthouse")

    def raise_called_process_error(*_args, **_kwargs):
        raise subprocess.CalledProcessError(returncode=1, cmd=["jamf-cli"], stderr="boom")

    monkeypatch.setattr(subprocess, "run", raise_called_process_error)
    assert bridge.has_platform_auth() is False


def test_has_platform_auth_caches_result(monkeypatch, jrc) -> None:
    bridge = _bridge_with_binary(jrc, monkeypatch, profile="lighthouse")
    output = json.dumps([
        {"name": "lighthouse", "url": "https://gw", "auth-method": "platform", "default": True},
    ])
    call_count = {"n": 0}

    def counting_run(*_args, **_kwargs):
        call_count["n"] += 1
        return _make_completed(output)

    monkeypatch.setattr(subprocess, "run", counting_run)

    assert bridge.has_platform_auth() is True
    assert bridge.has_platform_auth() is True
    assert call_count["n"] == 1


def test_has_platform_auth_resolves_default_profile_when_profile_empty(
    monkeypatch, jrc
) -> None:
    bridge = _bridge_with_binary(jrc, monkeypatch, profile="")
    output = json.dumps([
        {"name": "other", "url": "https://x", "auth-method": "oauth2", "default": False},
        {"name": "primary", "url": "https://gw", "auth-method": "platform", "default": True},
    ])
    monkeypatch.setattr(subprocess, "run", lambda *a, **kw: _make_completed(output))

    assert bridge.has_platform_auth() is True


def test_has_platform_auth_false_when_no_default_and_no_profile(monkeypatch, jrc) -> None:
    bridge = _bridge_with_binary(jrc, monkeypatch, profile="")
    output = json.dumps([
        {"name": "one", "url": "https://x", "auth-method": "oauth2", "default": False},
        {"name": "two", "url": "https://y", "auth-method": "platform", "default": False},
    ])
    monkeypatch.setattr(subprocess, "run", lambda *a, **kw: _make_completed(output))

    assert bridge.has_platform_auth() is False


def test_has_platform_auth_false_when_output_is_not_list(monkeypatch, jrc) -> None:
    bridge = _bridge_with_binary(jrc, monkeypatch, profile="dummy")
    monkeypatch.setattr(
        subprocess, "run", lambda *a, **kw: _make_completed('{"error": "bad"}')
    )
    assert bridge.has_platform_auth() is False


# ---------------------------------------------------------------------------
# _platform_gate()
# ---------------------------------------------------------------------------


class _FakeConfig:
    """Minimal Config-shaped double for gating-logic tests."""

    def __init__(self, *, platform_enabled: bool) -> None:
        self._data = {
            "experimental": {"platform_features_enabled": platform_enabled},
        }

    def get(self, *keys: str, default: Any = None) -> Any:
        node: Any = self._data
        for k in keys:
            if not isinstance(node, dict):
                return default
            node = node.get(k, default)
        return node


class _FakeBridge:
    def __init__(self, *, available: bool, has_platform: bool) -> None:
        self._available = available
        self._has_platform = has_platform

    def is_available(self) -> bool:
        return self._available

    def has_platform_auth(self) -> bool:
        return self._has_platform


def test_platform_gate_false_when_flag_disabled(jrc) -> None:
    config = _FakeConfig(platform_enabled=False)
    bridge = _FakeBridge(available=True, has_platform=True)
    assert jrc._platform_gate(config, bridge) is False


def test_platform_gate_false_when_bridge_is_none(jrc) -> None:
    config = _FakeConfig(platform_enabled=True)
    assert jrc._platform_gate(config, None) is False


def test_platform_gate_false_when_bridge_not_available(jrc) -> None:
    config = _FakeConfig(platform_enabled=True)
    bridge = _FakeBridge(available=False, has_platform=True)
    assert jrc._platform_gate(config, bridge) is False


def test_platform_gate_false_when_bridge_lacks_platform_auth(jrc) -> None:
    config = _FakeConfig(platform_enabled=True)
    bridge = _FakeBridge(available=True, has_platform=False)
    assert jrc._platform_gate(config, bridge) is False


def test_platform_gate_true_when_flag_and_bridge_both_ready(jrc) -> None:
    config = _FakeConfig(platform_enabled=True)
    bridge = _FakeBridge(available=True, has_platform=True)
    assert jrc._platform_gate(config, bridge) is True


# ---------------------------------------------------------------------------
# DEFAULT_CONFIG wiring
# ---------------------------------------------------------------------------


def test_default_config_contains_experimental_section(jrc) -> None:
    experimental = jrc.DEFAULT_CONFIG.get("experimental")
    assert isinstance(experimental, dict)
    assert experimental.get("platform_features_enabled") is False
    assert experimental.get("protect_features_enabled") is False


@pytest.mark.parametrize("flag", ["platform_features_enabled", "protect_features_enabled"])
def test_experimental_defaults_are_off(jrc, flag) -> None:
    assert jrc.DEFAULT_CONFIG["experimental"][flag] is False
