"""Regression tests for scaffold header matching."""

from __future__ import annotations

from pathlib import Path

import pytest


def test_bootstrap_token_allowed_does_not_match_bootstrap_token(jrc) -> None:
    assert jrc._column_match_score("Bootstrap Token Allowed", "bootstrap_token") == 0


def test_bootstrap_token_escrowed_matches_bootstrap_token(jrc) -> None:
    assert jrc._column_match_score("Bootstrap Token Escrowed", "bootstrap_token") > 0


def test_operating_system_version_scores_for_operating_system(jrc) -> None:
    assert jrc._column_match_score("Operating System Version", "operating_system") > 0


def test_scaffold_injects_profile_into_jamf_cli(
    jrc, fixtures_root: Path, tmp_path: Path
) -> None:
    csv_path = fixtures_root / "csv" / "dummy_all_macs.csv"
    out_path = tmp_path / "config.yaml"
    jrc.cmd_scaffold(str(csv_path), str(out_path), profile="my-tenant")

    text = out_path.read_text(encoding="utf-8")
    assert 'profile: "my-tenant"' in text


def test_scaffold_without_profile_keeps_empty_default(
    jrc, fixtures_root: Path, tmp_path: Path
) -> None:
    csv_path = fixtures_root / "csv" / "dummy_all_macs.csv"
    out_path = tmp_path / "config.yaml"
    jrc.cmd_scaffold(str(csv_path), str(out_path))

    text = out_path.read_text(encoding="utf-8")
    assert 'profile: ""' in text


def test_scaffold_rejects_invalid_profile(
    jrc, fixtures_root: Path, tmp_path: Path
) -> None:
    csv_path = fixtures_root / "csv" / "dummy_all_macs.csv"
    out_path = tmp_path / "config.yaml"
    with pytest.raises(SystemExit):
        jrc.cmd_scaffold(str(csv_path), str(out_path), profile="Bad-Profile")
