"""Tests for LogRedactor and cmd_diagnostic_bundle.

The redactor is security-critical: every committed pattern must catch its
shaped input AND must not over-redact common log boilerplate. The bundler
tests verify the zip is correctly assembled, the manifest reflects what's
inside, and the --no-redact / --keep-* flags behave as documented.
"""

from __future__ import annotations

import json
import zipfile
from pathlib import Path

import pytest


# ---------------------------------------------------------------------------
# LogRedactor — secret patterns
# ---------------------------------------------------------------------------


def test_redactor_strips_client_secret_yaml(jrc):
    redactor = jrc.LogRedactor()
    text = 'client_secret: "abcdef1234567890supersecret"'
    out = redactor.redact_text(text)
    assert "abcdef1234567890supersecret" not in out
    assert "REDACTED_CLIENT_SECRET" in out


def test_redactor_strips_client_secret_unquoted_yaml(jrc):
    redactor = jrc.LogRedactor()
    text = "client_secret: abcdef1234567890supersecret"
    out = redactor.redact_text(text)
    assert "abcdef1234567890supersecret" not in out


def test_redactor_strips_client_id_uuid(jrc):
    redactor = jrc.LogRedactor()
    text = 'client_id: "11111111-2222-3333-4444-555555555555"'
    out = redactor.redact_text(text)
    assert "11111111-2222" not in out
    assert "REDACTED_CLIENT_ID" in out


def test_redactor_strips_bearer_token(jrc):
    redactor = jrc.LogRedactor()
    text = "Authorization: Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9"
    out = redactor.redact_text(text)
    assert "eyJhbGc" not in out
    assert "REDACTED_BEARER" in out


def test_redactor_strips_jwt(jrc):
    redactor = jrc.LogRedactor()
    # Three-segment JWT: header.payload.signature
    jwt = "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.fakeSignature1234"
    text = f"token = {jwt}"
    out = redactor.redact_text(text)
    assert jwt not in out
    assert "REDACTED_JWT" in out


def test_redactor_strips_access_token_json(jrc):
    redactor = jrc.LogRedactor()
    text = '{"access_token": "abcdef1234567890", "expires_in": 3600}'
    out = redactor.redact_text(text)
    assert "abcdef1234567890" not in out
    assert "REDACTED_ACCESS_TOKEN" in out
    # expires_in is fine to keep — must not be touched.
    assert "3600" in out


def test_redactor_strips_refresh_token_json(jrc):
    redactor = jrc.LogRedactor()
    text = '{"refresh_token": "refresh-secret-here-1234567890"}'
    out = redactor.redact_text(text)
    assert "refresh-secret" not in out
    assert "REDACTED_REFRESH_TOKEN" in out


def test_redactor_strips_password_yaml(jrc):
    redactor = jrc.LogRedactor()
    text = 'password: "mypassword123"'
    out = redactor.redact_text(text)
    assert "mypassword123" not in out
    assert "REDACTED_PASSWORD" in out


def test_redactor_does_not_redact_password_in_unrelated_text(jrc):
    # "password" appearing in prose without a colon/equals shouldn't trigger.
    redactor = jrc.LogRedactor()
    text = "User must enter a password to continue."
    out = redactor.redact_text(text)
    assert "REDACTED" not in out


# ---------------------------------------------------------------------------
# LogRedactor — PII categories
# ---------------------------------------------------------------------------


def test_redactor_replaces_jamf_hostname_with_stable_placeholder(jrc):
    redactor = jrc.LogRedactor()
    text = "GET https://acme-prod.jamfcloud.com/api/v1/computers"
    out = redactor.redact_text(text)
    assert "acme-prod.jamfcloud.com" not in out
    assert "host-" in out  # placeholder prefix


def test_redactor_same_hostname_gets_same_placeholder_in_same_bundle(jrc):
    redactor = jrc.LogRedactor()
    a = redactor.redact_text("acme-prod.jamfcloud.com")
    b = redactor.redact_text("acme-prod.jamfcloud.com")
    assert a == b


def test_redactor_different_bundles_get_different_placeholders(jrc):
    r1 = jrc.LogRedactor()
    r2 = jrc.LogRedactor()
    a = r1.redact_text("acme-prod.jamfcloud.com")
    b = r2.redact_text("acme-prod.jamfcloud.com")
    assert a != b  # different per-bundle salts


def test_redactor_strips_emails(jrc):
    redactor = jrc.LogRedactor()
    text = "User: jdoe@example.com requested report"
    out = redactor.redact_text(text)
    assert "jdoe@example.com" not in out
    assert "email-" in out


def test_redactor_strips_apple_serials(jrc):
    redactor = jrc.LogRedactor()
    # Apple serial: 10-12 alphanumeric, no vowels (no I/O either).
    text = "Serial: C02XL3FRJHD2 contacted server"
    out = redactor.redact_text(text)
    assert "C02XL3FRJHD2" not in out
    assert "serial-" in out


def test_redactor_keep_flags_disable_categories(jrc):
    redactor = jrc.LogRedactor(
        redact_hostnames=False,
        redact_serials=False,
        redact_emails=False,
    )
    text = "host: acme-prod.jamfcloud.com user: jdoe@example.com serial: C02XL3FRJHD2"
    out = redactor.redact_text(text)
    assert "acme-prod.jamfcloud.com" in out
    assert "jdoe@example.com" in out
    assert "C02XL3FRJHD2" in out


def test_redactor_secret_redaction_always_on(jrc):
    # Even with all PII flags off, credentials must still be redacted.
    redactor = jrc.LogRedactor(
        redact_hostnames=False,
        redact_serials=False,
        redact_emails=False,
        redact_device_names=False,
    )
    text = 'client_secret: "mustnotleak1234567890"'
    out = redactor.redact_text(text)
    assert "mustnotleak1234567890" not in out


# ---------------------------------------------------------------------------
# LogRedactor — JSON walk
# ---------------------------------------------------------------------------


def test_redact_json_sensitive_keys(jrc):
    redactor = jrc.LogRedactor()
    obj = {"client_secret": "leaky", "access_token": "tok", "totalDevices": 42}
    out = redactor.redact_json(obj)
    assert out["client_secret"] == "REDACTED_CLIENT_SECRET"
    assert out["access_token"] == "REDACTED_ACCESS_TOKEN"
    assert out["totalDevices"] == 42  # untouched


def test_redact_json_pii_keys_use_placeholders(jrc):
    redactor = jrc.LogRedactor()
    obj = {"serialNumber": "C02XL3FRJHD2", "computerName": "MacBook-Pro-001"}
    out = redactor.redact_json(obj)
    assert out["serialNumber"].startswith("serial-")
    assert out["computerName"].startswith("device-")


def test_redact_json_recurses_into_nested(jrc):
    redactor = jrc.LogRedactor()
    obj = {"general": {"serialNumber": "C02XL3FRJHD2"}, "devices": [{"hostname": "h1"}]}
    out = redactor.redact_json(obj)
    assert out["general"]["serialNumber"].startswith("serial-")
    assert out["devices"][0]["hostname"].startswith("host-")


def test_redactor_policy_dict_reflects_flags(jrc):
    redactor = jrc.LogRedactor(redact_emails=False)
    policy = redactor.policy()
    assert policy["secrets"] is True
    assert policy["emails"] is False
    assert policy["hostnames"] is True


# ---------------------------------------------------------------------------
# cmd_diagnostic_bundle
# ---------------------------------------------------------------------------


@pytest.fixture
def mock_workspace(tmp_path: Path) -> Path:
    """Build a minimal workspace with logs, a summary, and a config."""
    workspace = tmp_path / "ws"
    (workspace / "automation" / "logs").mkdir(parents=True)
    (workspace / "snapshots" / "computers" / "summaries").mkdir(parents=True)
    (workspace / "automation" / "logs" / "run1.log").write_text(
        'Auth header: Bearer abcdef1234567890superlongtokenvalue\n'
    )
    (workspace / "snapshots" / "computers" / "summaries" / "summary_2026-05-15.json").write_text(
        json.dumps({"date": "2026-05-15", "totalDevices": 100, "serialNumber": "C02XL3FRJHD2"})
    )
    (workspace / "config.yaml").write_text(
        'jamf_cli:\n  profile: "test"\n  client_secret: "shouldnotleak1234567890"\n'
    )
    return workspace


def _make_config(jrc, workspace: Path):
    """Construct a Config rooted at the given workspace."""
    return jrc.Config(str(workspace / "config.yaml"))


def test_bundle_creates_zip_with_expected_entries(jrc, mock_workspace, tmp_path):
    config = _make_config(jrc, mock_workspace)
    output = tmp_path / "bundle.zip"
    result = jrc.cmd_diagnostic_bundle(config, output_path=output)
    assert result == output
    assert output.exists()
    with zipfile.ZipFile(output) as zf:
        names = set(zf.namelist())
    assert "manifest.json" in names
    assert "config.yaml" in names
    assert "workspace_tree.txt" in names
    assert "versions.json" in names
    assert any(n.startswith("logs/") for n in names)
    assert any(n.startswith("summaries/") for n in names)


def test_bundle_redacts_credentials_by_default(jrc, mock_workspace, tmp_path):
    config = _make_config(jrc, mock_workspace)
    output = tmp_path / "bundle.zip"
    jrc.cmd_diagnostic_bundle(config, output_path=output)
    with zipfile.ZipFile(output) as zf:
        config_yaml = zf.read("config.yaml").decode("utf-8")
        log = zf.read("logs/run1.log").decode("utf-8")
    assert "shouldnotleak1234567890" not in config_yaml
    assert "REDACTED_CLIENT_SECRET" in config_yaml
    assert "abcdef1234567890superlongtokenvalue" not in log
    assert "REDACTED_BEARER" in log


def test_bundle_redacts_pii_in_summary_json(jrc, mock_workspace, tmp_path):
    config = _make_config(jrc, mock_workspace)
    output = tmp_path / "bundle.zip"
    jrc.cmd_diagnostic_bundle(config, output_path=output)
    with zipfile.ZipFile(output) as zf:
        summary = json.loads(zf.read("summaries/summary_2026-05-15.json"))
    assert summary["serialNumber"].startswith("serial-")
    assert summary["totalDevices"] == 100  # untouched


def test_bundle_no_redact_flag_preserves_raw_content(jrc, mock_workspace, tmp_path):
    config = _make_config(jrc, mock_workspace)
    output = tmp_path / "bundle.zip"
    jrc.cmd_diagnostic_bundle(config, output_path=output, no_redact=True)
    with zipfile.ZipFile(output) as zf:
        config_yaml = zf.read("config.yaml").decode("utf-8")
        log = zf.read("logs/run1.log").decode("utf-8")
        manifest = json.loads(zf.read("manifest.json"))
    assert "shouldnotleak1234567890" in config_yaml
    assert "abcdef1234567890superlongtokenvalue" in log
    assert manifest["redaction_policy"]["enabled"] is False


def test_bundle_keep_serials_flag_preserves_serial_numbers(jrc, mock_workspace, tmp_path):
    config = _make_config(jrc, mock_workspace)
    output = tmp_path / "bundle.zip"
    jrc.cmd_diagnostic_bundle(config, output_path=output, keep_serials=True)
    with zipfile.ZipFile(output) as zf:
        summary = json.loads(zf.read("summaries/summary_2026-05-15.json"))
        manifest = json.loads(zf.read("manifest.json"))
    assert summary["serialNumber"] == "C02XL3FRJHD2"
    assert manifest["redaction_policy"]["serials"] is False
    # But secrets must still be redacted.
    config_yaml = zipfile.ZipFile(output).read("config.yaml").decode("utf-8")
    assert "shouldnotleak1234567890" not in config_yaml


def test_bundle_manifest_lists_every_zip_entry(jrc, mock_workspace, tmp_path):
    config = _make_config(jrc, mock_workspace)
    output = tmp_path / "bundle.zip"
    jrc.cmd_diagnostic_bundle(config, output_path=output)
    with zipfile.ZipFile(output) as zf:
        manifest = json.loads(zf.read("manifest.json"))
        zip_entries = set(zf.namelist()) - {"manifest.json"}
    manifest_paths = {entry["path"] for entry in manifest["files"]}
    assert manifest_paths == zip_entries


def test_bundle_log_lookback_filters_old_files(jrc, mock_workspace, tmp_path):
    # Create an old log (mtime 30 days back) — should be excluded with --days 7.
    import os
    import time
    old_log = mock_workspace / "automation" / "logs" / "old.log"
    old_log.write_text("ancient")
    old_mtime = time.time() - (30 * 86400)
    os.utime(old_log, (old_mtime, old_mtime))

    config = _make_config(jrc, mock_workspace)
    output = tmp_path / "bundle.zip"
    jrc.cmd_diagnostic_bundle(config, output_path=output, days=7)
    with zipfile.ZipFile(output) as zf:
        names = set(zf.namelist())
    assert "logs/run1.log" in names
    assert "logs/old.log" not in names


def test_bundle_default_output_path_lands_on_desktop(jrc, mock_workspace, tmp_path, monkeypatch):
    config = _make_config(jrc, mock_workspace)
    # Redirect Path.home() to tmp_path so the test doesn't actually write to Desktop.
    monkeypatch.setattr(Path, "home", lambda: tmp_path)
    (tmp_path / "Desktop").mkdir()
    result = jrc.cmd_diagnostic_bundle(config)
    assert result.parent == tmp_path / "Desktop"
    assert result.name.startswith("jamf-reports-diagnostic-")
    assert result.suffix == ".zip"
