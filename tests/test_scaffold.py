"""Regression tests for scaffold header matching."""

from __future__ import annotations


def test_bootstrap_token_allowed_does_not_match_bootstrap_token(jrc) -> None:
    assert jrc._column_match_score("Bootstrap Token Allowed", "bootstrap_token") == 0


def test_bootstrap_token_escrowed_matches_bootstrap_token(jrc) -> None:
    assert jrc._column_match_score("Bootstrap Token Escrowed", "bootstrap_token") > 0


def test_operating_system_version_scores_for_operating_system(jrc) -> None:
    assert jrc._column_match_score("Operating System Version", "operating_system") > 0
