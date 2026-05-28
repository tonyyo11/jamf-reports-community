"""Tests for v2.1.0 PR 8 — Compliance Benchmarks gate semantics.

Asserts that the v2.1.0 ``experimental.platform_features_enabled`` flag and
``has_platform_auth()`` probe are required IN ADDITION to the legacy
``platform.enabled`` toggle before any Platform sheet renders. Pre-existing
parser-level tests live in ``test_platform_reports.py``; this file pins the
dual-gate semantics so a future regression that flipped only one switch
would surface here.
"""

from __future__ import annotations

import json
from pathlib import Path
from typing import Any
from unittest.mock import MagicMock

import pytest
import xlsxwriter


BENCHMARK = "NIST 800-53r5 Moderate"
FIXTURES_ROOT = Path(__file__).resolve().parent / "fixtures"
CR_DIR = FIXTURES_ROOT / "jamf-cli-data" / "compliance-rules-nist-800-53r5-moderate"
CD_DIR = FIXTURES_ROOT / "jamf-cli-data" / "compliance-devices-nist-800-53r5-moderate"
BP_DIR = FIXTURES_ROOT / "jamf-cli-data" / "blueprint-status"


def _load(path: Path) -> Any:
    with open(path, encoding="utf-8") as fh:
        return json.load(fh)


def _make_dashboard(
    jrc,
    tmp_path: Path,
    bridge_data: dict,
    *,
    platform_enabled: bool,
    experimental_enabled: bool,
    has_platform_auth: bool,
    is_available: bool = True,
):
    """Build a CoreDashboard with explicit dual-gate state."""
    config = jrc.Config(jrc.Config._WORKSPACE_INIT_DEFAULTS_NAME)
    config._data["platform"]["enabled"] = platform_enabled
    config._data["platform"]["compliance_benchmarks"] = [BENCHMARK]
    config._data.setdefault("experimental", {})["platform_features_enabled"] = (
        experimental_enabled
    )

    bridge = MagicMock()
    bridge.is_available.return_value = is_available
    bridge.has_platform_auth.return_value = has_platform_auth
    for attr, value in bridge_data.items():
        getattr(bridge, attr).return_value = value

    wb_path = str(tmp_path / "test.xlsx")
    wb = xlsxwriter.Workbook(wb_path, {"remove_timezone": True})
    fmts = jrc._build_formats(wb)
    dashboard = jrc.CoreDashboard(config, bridge, wb, fmts)
    return dashboard, wb


# ---------------------------------------------------------------------------
# Compliance Rules — gate combinations
# ---------------------------------------------------------------------------


def test_compliance_rules_blocked_when_experimental_off(jrc, tmp_path) -> None:
    """platform.enabled=true + experimental off → skip with gate message."""
    rows = _load(CR_DIR / "platform_compliance_rules_happy.json")
    dashboard, wb = _make_dashboard(
        jrc,
        tmp_path,
        {"compliance_rules": rows},
        platform_enabled=True,
        experimental_enabled=False,
        has_platform_auth=True,
    )
    with pytest.raises(RuntimeError, match="Platform API gate closed"):
        dashboard._write_platform_compliance_rules(BENCHMARK)
    wb.close()


def test_compliance_rules_blocked_when_platform_enabled_off(jrc, tmp_path) -> None:
    """experimental on + platform.enabled off → skip."""
    rows = _load(CR_DIR / "platform_compliance_rules_happy.json")
    dashboard, wb = _make_dashboard(
        jrc,
        tmp_path,
        {"compliance_rules": rows},
        platform_enabled=False,
        experimental_enabled=True,
        has_platform_auth=True,
    )
    with pytest.raises(RuntimeError, match="Platform API gate closed"):
        dashboard._write_platform_compliance_rules(BENCHMARK)
    wb.close()


def test_compliance_rules_blocked_when_profile_not_platform_auth(jrc, tmp_path) -> None:
    """Both flags on, but profile uses oauth2 → skip."""
    rows = _load(CR_DIR / "platform_compliance_rules_happy.json")
    dashboard, wb = _make_dashboard(
        jrc,
        tmp_path,
        {"compliance_rules": rows},
        platform_enabled=True,
        experimental_enabled=True,
        has_platform_auth=False,
    )
    with pytest.raises(RuntimeError, match="Platform API gate closed"):
        dashboard._write_platform_compliance_rules(BENCHMARK)
    wb.close()


def test_compliance_rules_renders_when_full_gate_open(jrc, tmp_path) -> None:
    """All three gates open → sheet writes without raising."""
    rows = _load(CR_DIR / "platform_compliance_rules_happy.json")
    dashboard, wb = _make_dashboard(
        jrc,
        tmp_path,
        {"compliance_rules": rows},
        platform_enabled=True,
        experimental_enabled=True,
        has_platform_auth=True,
    )
    dashboard._write_platform_compliance_rules(BENCHMARK)
    wb.close()


# ---------------------------------------------------------------------------
# Compliance Devices — mirror the same gate set
# ---------------------------------------------------------------------------


def test_compliance_devices_blocked_when_experimental_off(jrc, tmp_path) -> None:
    rows = _load(CD_DIR / "platform_compliance_devices_happy.json")
    dashboard, wb = _make_dashboard(
        jrc,
        tmp_path,
        {"compliance_devices": rows},
        platform_enabled=True,
        experimental_enabled=False,
        has_platform_auth=True,
    )
    with pytest.raises(RuntimeError, match="Platform API gate closed"):
        dashboard._write_platform_compliance_devices(BENCHMARK)
    wb.close()


def test_compliance_devices_renders_when_full_gate_open(jrc, tmp_path) -> None:
    rows = _load(CD_DIR / "platform_compliance_devices_happy.json")
    dashboard, wb = _make_dashboard(
        jrc,
        tmp_path,
        {"compliance_devices": rows},
        platform_enabled=True,
        experimental_enabled=True,
        has_platform_auth=True,
    )
    dashboard._write_platform_compliance_devices(BENCHMARK)
    wb.close()


# ---------------------------------------------------------------------------
# Blueprints + DDM share the same gate, surface inherits the dual semantic
# ---------------------------------------------------------------------------


def test_blueprints_blocked_when_experimental_off(jrc, tmp_path) -> None:
    rows = _load(BP_DIR / "platform_blueprint_status_happy.json")
    dashboard, wb = _make_dashboard(
        jrc,
        tmp_path,
        {"blueprint_status": rows},
        platform_enabled=True,
        experimental_enabled=False,
        has_platform_auth=True,
    )
    with pytest.raises(RuntimeError, match="Platform API gate closed"):
        dashboard._write_platform_blueprints()
    wb.close()


# ---------------------------------------------------------------------------
# _platform_runtime_enabled — runtime helper used by cmd_check/generate/collect
# ---------------------------------------------------------------------------


class _FakeConfig:
    def __init__(self, platform_enabled: bool, experimental_enabled: bool) -> None:
        self._data = {
            "platform": {"enabled": platform_enabled},
            "experimental": {"platform_features_enabled": experimental_enabled},
        }

    def get(self, *keys: str, default: Any = None) -> Any:
        node: Any = self._data
        for k in keys:
            if not isinstance(node, dict):
                return default
            node = node.get(k, default)
        return node


class _FakeBridge:
    def __init__(self, available: bool, has_platform: bool) -> None:
        self._available = available
        self._has_platform = has_platform

    def is_available(self) -> bool:
        return self._available

    def has_platform_auth(self) -> bool:
        return self._has_platform


def test_runtime_enabled_requires_platform_config(jrc) -> None:
    config = _FakeConfig(platform_enabled=False, experimental_enabled=True)
    bridge = _FakeBridge(available=True, has_platform=True)
    assert jrc._platform_runtime_enabled(config, bridge) is False


def test_runtime_enabled_requires_experimental_flag(jrc) -> None:
    config = _FakeConfig(platform_enabled=True, experimental_enabled=False)
    bridge = _FakeBridge(available=True, has_platform=True)
    assert jrc._platform_runtime_enabled(config, bridge) is False


def test_runtime_enabled_requires_platform_auth(jrc) -> None:
    config = _FakeConfig(platform_enabled=True, experimental_enabled=True)
    bridge = _FakeBridge(available=True, has_platform=False)
    assert jrc._platform_runtime_enabled(config, bridge) is False


def test_runtime_enabled_true_when_all_three_pass(jrc) -> None:
    config = _FakeConfig(platform_enabled=True, experimental_enabled=True)
    bridge = _FakeBridge(available=True, has_platform=True)
    assert jrc._platform_runtime_enabled(config, bridge) is True


def test_runtime_enabled_false_when_bridge_is_none(jrc) -> None:
    config = _FakeConfig(platform_enabled=True, experimental_enabled=True)
    assert jrc._platform_runtime_enabled(config, None) is False


# ---------------------------------------------------------------------------
# Capabilities manifest exposes the gate keys
# ---------------------------------------------------------------------------


def test_capabilities_manifest_exposes_platform_api_gate(jrc) -> None:
    manifest = jrc._capabilities_manifest()
    features = manifest.get("experimental_features", {})
    platform_api = features.get("platform_api", {})
    assert "experimental.platform_features_enabled" in platform_api.get("config_keys", [])
    assert "platform.enabled" in platform_api.get("config_keys", [])
    assert "platform.compliance_benchmarks" == platform_api.get("benchmarks_config_key")
