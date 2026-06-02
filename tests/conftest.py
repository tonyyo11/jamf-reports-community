"""Shared pytest fixtures for jamf-reports-community."""

from __future__ import annotations

import importlib.util
import sys
from pathlib import Path

import pytest


REPO_ROOT = Path(__file__).resolve().parents[1]
FIXTURES_ROOT = REPO_ROOT / "tests" / "fixtures"


def _load_module():
    script_path = REPO_ROOT / "jamf-reports-community.py"
    spec = importlib.util.spec_from_file_location("jamf_reports_community_module", script_path)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"Could not load module from {script_path}")
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


@pytest.fixture(scope="session")
def jrc():
    """Return the imported jamf-reports-community module."""
    return _load_module()


@pytest.fixture(scope="session")
def fixtures_root() -> Path:
    """Return the committed fixture root."""
    return FIXTURES_ROOT


@pytest.fixture
def config_factory(jrc, fixtures_root, tmp_path):
    """Return a helper that loads a fixture config and rewires outputs to tmp_path."""

    def _factory(config_name: str):
        config = jrc.Config(str(fixtures_root / "config" / config_name))
        config._data["output"]["output_dir"] = str(tmp_path / "Generated Reports")
        config._data["output"]["timestamp_outputs"] = False
        config._data["output"]["archive_enabled"] = False
        config._data["output"]["keep_latest_runs"] = 2
        config._data["charts"]["historical_csv_dir"] = str(tmp_path / "snapshots")
        config._data["charts"]["archive_current_csv"] = False
        return config

    return _factory


@pytest.fixture
def real_sofa_curl(jrc, _block_sofa_network):
    """Return the unpatched SOFAFeedClient._curl_fetch for curl-path tests.

    Depends on the autouse network block so the original is captured before
    this fixture reads it. Tests that need to exercise the real curl/subprocess
    handler request this fixture and restore it explicitly.
    """
    return jrc._ORIGINAL_SOFA_CURL_FETCH


@pytest.fixture(autouse=True)
def _block_sofa_network(jrc, monkeypatch):
    """Prevent SOFAFeedClient from making real network/curl calls in tests.

    Patches `_curl_fetch` to raise so every fetch path falls back to cache (or
    None) and never reaches the network. SOFA tests that exercise cache paths
    keep working unchanged; tests that exercise the curl handler itself request
    the `real_sofa_curl` fixture and restore it explicitly.
    """
    if not hasattr(jrc, "_ORIGINAL_SOFA_CURL_FETCH"):
        jrc._ORIGINAL_SOFA_CURL_FETCH = jrc.SOFAFeedClient._curl_fetch

    def _no_network(self, platform):
        raise RuntimeError("SOFA network disabled in tests")

    monkeypatch.setattr(jrc.SOFAFeedClient, "_curl_fetch", _no_network)
