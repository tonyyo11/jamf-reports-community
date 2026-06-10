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


def test_all_fail_no_auth_raises_collect_error(jrc, config_factory, monkeypatch):
    """Total outage: every live Pro call fails, none is a 401, zero succeed →
    JamfCollectError (not JamfAuthError). Closes the gap where an all-fail-no-401
    run fell through to cmd_generate and froze a degraded summary from cache."""
    config = config_factory("dummy.yaml")
    commands = [("Compliance Devices", _raise(1, "404")), ("DDM Status", _raise(4, "not found"))]
    _wire_collect(jrc, monkeypatch, commands)
    with pytest.raises(jrc.JamfCollectError):
        jrc._collect_snapshots(config)


def test_all_fail_mixed_codes_no_auth_raises_collect_error(jrc, config_factory, monkeypatch):
    """A mix of non-auth failure codes (general/403/429) with zero successes is
    still a total outage → JamfCollectError."""
    config = config_factory("dummy.yaml")
    commands = [
        ("Security", _raise(5, "forbidden")),
        ("Patch Status", _raise(6, "rate limited")),
        ("Inventory", _raise(1, "connection refused")),
    ]
    _wire_collect(jrc, monkeypatch, commands)
    with pytest.raises(jrc.JamfCollectError):
        jrc._collect_snapshots(config)


def test_collect_error_is_not_auth_error(jrc):
    """JamfCollectError and JamfAuthError are distinct sibling RuntimeErrors so a
    caller can tell a credential problem from a connectivity outage."""
    assert issubclass(jrc.JamfCollectError, RuntimeError)
    assert not issubclass(jrc.JamfCollectError, jrc.JamfAuthError)
    assert not issubclass(jrc.JamfAuthError, jrc.JamfCollectError)


def test_partial_success_with_failures_does_not_raise(jrc, config_factory, monkeypatch):
    """At least one success means a partial collect — falls back to cache for the
    failed kinds, never raising the collect-dead verdict."""
    config = config_factory("dummy.yaml")
    commands = [
        ("Overview", _ok()),
        ("Compliance Devices", _raise(1, "404")),
        ("Patch Status", _raise(4, "not found")),
    ]
    _wire_collect(jrc, monkeypatch, commands)
    collected, _archived = jrc._collect_snapshots(config)
    assert collected == 1


def test_auth_flavor_still_raises_auth_error_not_collect(jrc, config_factory, monkeypatch):
    """When at least one failure is a 401 and none succeed, the auth verdict wins
    over the generic collect verdict (auth-dead is the more specific diagnosis)."""
    config = config_factory("dummy.yaml")
    commands = [("Security", _raise(3, "unauthorized")), ("Patch Status", _raise(1, "404"))]
    _wire_collect(jrc, monkeypatch, commands)
    with pytest.raises(jrc.JamfAuthError):
        jrc._collect_snapshots(config)


def test_protect_only_failure_does_not_raise(jrc, config_factory, monkeypatch):
    """A Protect-only failure (separate OAuth2) among Pro successes must not trip
    either verdict — Protect does not count toward the Pro outage tally."""
    config = config_factory("dummy.yaml")
    commands = [("Overview", _ok()), ("Protect Overview", _raise(1, "down"))]
    _wire_collect(jrc, monkeypatch, commands)
    collected, _archived = jrc._collect_snapshots(config)
    assert collected == 1


# --- School collect all-fail verdict -----------------------------------------

class _FakeSchoolBridge:
    """Stub school bridge whose every fetcher raises — a total outage."""

    _data_dir = "/tmp/jrc-school-test"
    _profile = "schooltest"

    def is_available(self):
        return True

    def _fail(self, *_a, **_k):
        raise RuntimeError("jamf-cli failed (1): connection refused")

    overview = devices_list = device_groups_list = _fail
    users_list = groups_list = classes_list = _fail
    apps_list = profiles_list = locations_list = _fail


def test_school_collect_all_fail_exits_nonzero(jrc, config_factory, monkeypatch, tmp_path):
    """cmd_school_collect previously recorded status 'partial' and exited 0 even at
    0/9 collected. An all-failed school collect must now raise SystemExit and write
    a 'fail' summary instead of reporting success on an empty result."""
    config = config_factory("dummy.yaml")
    monkeypatch.setattr(jrc, "_build_school_bridge", lambda *_a, **_k: _FakeSchoolBridge())
    summary_json = tmp_path / "school-summary.json"
    with pytest.raises(SystemExit):
        jrc.cmd_school_collect(config, str(summary_json))
    import json
    written = json.loads(summary_json.read_text(encoding="utf-8"))
    assert written["status"] == "fail"
    assert written["counts"]["collected_snapshots"] == 0
