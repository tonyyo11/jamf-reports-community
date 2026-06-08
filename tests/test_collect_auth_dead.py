"""Auth-dead collect guard (Python parity with Swift ReportEngine.isCollectAuthDead).

A collect whose live Jamf Pro calls all return 401 (exit 3) and none succeed must
raise JamfAuthError — surfacing the scheduled/manual run as non-success and writing
no degraded summary. A single 401 among successes falls back to cache (no raise).
Protect uses separate OAuth2 auth, so a Protect 401 must not indict Pro credentials.

Exit-code semantics confirmed against production logs:
- exit 3 = HTTP 401 (auth-required core endpoint, credentials expired/revoked)
- exit 1 = general / Platform-API 404 (chronic on on-prem, NOT auth)
"""

from __future__ import annotations

import pytest


# --- Pure helper specs -------------------------------------------------------

def test_failure_exit_code_parsing(jrc):
    assert jrc._jamf_cli_failure_exit_code(RuntimeError("jamf-cli failed (3): unauthorized")) == 3
    assert jrc._jamf_cli_failure_exit_code(RuntimeError("jamf-cli failed (1): boom")) == 1
    assert jrc._jamf_cli_failure_exit_code(RuntimeError("jamf-cli timed out after 60s")) is None


def test_collect_skip_echo_redacts_secrets_keeps_host(jrc):
    """The per-command [skip] error echo scrubs credentials but keeps the host
    visible — secret-only LogRedactor, PII redaction off (matches the
    construction in _collect_snapshots)."""
    redactor = jrc.LogRedactor(
        redact_hostnames=False,
        redact_serials=False,
        redact_emails=False,
        redact_device_names=False,
        redact_usernames=False,
    )
    out = redactor.redact_text(
        "jamf-cli failed (3): client_secret: abcd1234efgh5678 at https://jss.example.com"
    )
    assert "abcd1234efgh5678" not in out  # secret scrubbed
    assert "jss.example.com" in out       # host preserved for debugging


def test_is_auth_failure(jrc):
    assert jrc._is_jamf_auth_failure(RuntimeError("jamf-cli failed (3): x"))
    assert jrc._is_jamf_auth_failure(RuntimeError("HTTP 401 Unauthorized"))
    # exit 1 with a 404 detail is NOT auth even though it failed.
    assert not jrc._is_jamf_auth_failure(RuntimeError("jamf-cli failed (4): not found"))
    assert not jrc._is_jamf_auth_failure(RuntimeError("jamf-cli timed out after 60s"))
    # A parsed exit code is authoritative: a 403 (exit 5) whose stderr happens to
    # say "unauthorized" is a privilege error, NOT dead credentials — it must not
    # fall through to keyword matching and be misclassified as auth-dead.
    assert not jrc._is_jamf_auth_failure(
        RuntimeError("jamf-cli failed (5): user is unauthorized for this resource")
    )


# --- _collect_snapshots verdict integration ----------------------------------

def _raise(code: int, detail: str = "x"):
    def _cmd():
        raise RuntimeError(f"jamf-cli failed ({code}): {detail}")
    return _cmd


def _ok():
    def _cmd():
        return None
    return _cmd


def _wire_collect(jrc, monkeypatch, commands):
    """Make _collect_snapshots iterate `commands` against a stub bridge, with all
    out-of-loop side effects (platform, sofa, retention, archive) neutralized."""

    class _FakeBridge:
        _data_dir = "/tmp/jrc-auth-dead-test"

        def is_available(self):
            return True

    monkeypatch.setattr(jrc, "_jamf_cli_enabled", lambda *_a, **_k: True)
    monkeypatch.setattr(jrc, "_build_jamf_cli_bridge", lambda *_a, **_k: _FakeBridge())
    monkeypatch.setattr(jrc, "_platform_runtime_enabled", lambda *_a, **_k: False)
    monkeypatch.setattr(jrc, "_collect_jamf_cli_commands", lambda *_a, **_k: commands)
    monkeypatch.setattr(jrc, "_collect_sofa_feeds", lambda *_a, **_k: 0)
    monkeypatch.setattr(jrc, "_sweep_snapshots", lambda *_a, **_k: None)
    monkeypatch.setattr(jrc, "_archive_collect_csv_inputs", lambda *_a, **_k: False)


def test_all_401_raises_auth_error(jrc, config_factory, monkeypatch):
    config = config_factory("dummy.yaml")
    commands = [
        ("Security", _raise(3, "unauthorized")),
        ("Patch Status", _raise(3, "unauthorized")),
        ("Compliance Devices", _raise(1, "404 not found")),  # chronic, not auth
    ]
    _wire_collect(jrc, monkeypatch, commands)
    with pytest.raises(jrc.JamfAuthError):
        jrc._collect_snapshots(config)


def test_one_success_does_not_raise(jrc, config_factory, monkeypatch):
    config = config_factory("dummy.yaml")
    commands = [("Overview", _ok()), ("Security", _raise(3, "unauthorized"))]
    _wire_collect(jrc, monkeypatch, commands)
    collected, _archived = jrc._collect_snapshots(config)
    assert collected == 1


def test_protect_401_does_not_trip_pro_verdict(jrc, config_factory, monkeypatch):
    config = config_factory("dummy.yaml")
    # All Pro calls succeed; only the Protect call 401s — separate credentials.
    commands = [("Overview", _ok()), ("Protect Overview", _raise(3, "unauthorized"))]
    _wire_collect(jrc, monkeypatch, commands)
    collected, _archived = jrc._collect_snapshots(config)
    assert collected == 1


def test_chronic_404_only_does_not_raise(jrc, config_factory, monkeypatch):
    config = config_factory("dummy.yaml")
    commands = [("Compliance Devices", _raise(1, "404")), ("DDM Status", _raise(1, "404"))]
    _wire_collect(jrc, monkeypatch, commands)
    collected, _archived = jrc._collect_snapshots(config)
    assert collected == 0  # nothing collected, but no 401 → no raise
