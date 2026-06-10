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


def test_redactor_strips_api_key_yaml(jrc):
    """api_key in free-text log lines must be redacted (matches `_SENSITIVE_JSON_KEYS` floor)."""
    redactor = jrc.LogRedactor()
    text = "api_key: abcd1234efgh5678"  # 16 chars, above 8-char floor
    out = redactor.redact_text(text)
    assert "abcd1234efgh5678" not in out
    assert "REDACTED_API_KEY" in out


def test_redactor_strips_apikey_equals_form(jrc):
    """apikey (no underscore) in equals/URL form must also be redacted."""
    redactor = jrc.LogRedactor()
    text = 'apikey="abcdef0123456789abcdef01234567"'  # 32 chars
    out = redactor.redact_text(text)
    assert "abcdef0123456789abcdef01234567" not in out
    assert "REDACTED_API_KEY" in out


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
    (workspace / "snapshots" / "summaries").mkdir(parents=True)
    (workspace / "automation" / "logs" / "run1.log").write_text(
        'Auth header: Bearer abcdef1234567890superlongtokenvalue\n'
    )
    (workspace / "snapshots" / "summaries" / "summary_2026-05-15.json").write_text(
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


def test_bundle_collects_summaries_from_configured_historical_dir(jrc, tmp_path):
    """Summaries must be read from the resolved ``charts.historical_csv_dir``,
    not a hardcoded ``snapshots/computers/summaries`` path. Uses a distinct
    directory name so the assertion discriminates config-honoring from a
    hardcoded fallback."""
    workspace = tmp_path / "ws-histdir"
    (workspace / "automation" / "logs").mkdir(parents=True)
    summaries_dir = workspace / "histsnaps" / "summaries"
    summaries_dir.mkdir(parents=True)
    (summaries_dir / "summary_2026-05-20.json").write_text(
        json.dumps({"date": "2026-05-20", "totalDevices": 7, "serialNumber": "C02XL3FRJHD2"})
    )
    (workspace / "config.yaml").write_text(
        'jamf_cli:\n  profile: "histdir"\ncharts:\n  historical_csv_dir: "histsnaps"\n'
    )
    config = jrc.Config(str(workspace / "config.yaml"))
    output = tmp_path / "bundle.zip"
    jrc.cmd_diagnostic_bundle(config, output_path=output)
    with zipfile.ZipFile(output) as zf:
        names = set(zf.namelist())
        summary = json.loads(zf.read("summaries/summary_2026-05-20.json"))
    assert "summaries/summary_2026-05-20.json" in names
    assert summary["totalDevices"] == 7
    assert summary["serialNumber"].startswith("serial-")


# ---------------------------------------------------------------------------
# Review-gate regressions (PR-A second pass)
# ---------------------------------------------------------------------------


def test_redactor_strips_on_prem_jamf_hostname(jrc):
    """M-2: on-prem hosts like jamf.acme.corp must be matched, not just *.jamfcloud.com."""
    redactor = jrc.LogRedactor()
    text = "GET https://jamfpro.internal.agency.gov/api/v1/computers"
    out = redactor.redact_text(text)
    assert "jamfpro.internal.agency.gov" not in out
    assert "https://host-" in out
    # Path must be preserved.
    assert "/api/v1/computers" in out


def test_redactor_strips_webhook_url(jrc):
    """M-1 security-reviewer: webhook URLs with tenant paths must be redacted."""
    redactor = jrc.LogRedactor()
    text = (
        'webhook_url: "https://acme.webhook.office.com/webhookb2/abc-def-ghi@xyz/'
        'IncomingWebhook/longtenantidentifier/123"'
    )
    out = redactor.redact_text(text)
    assert "longtenantidentifier" not in out
    assert "REDACTED_WEBHOOK_URL" in out


def test_redactor_strips_basic_auth_header(jrc):
    """S-1: HTTP Basic Authorization headers must be redacted."""
    redactor = jrc.LogRedactor()
    text = "Authorization: Basic dXNlcjpwYXNzd29yZA=="
    out = redactor.redact_text(text)
    assert "dXNlcjpwYXNzd29yZA==" not in out
    assert "REDACTED_BASIC_CREDENTIAL" in out


def test_keep_device_names_does_not_disable_username_redaction(jrc):
    """M-2 hunter: --keep-device-names previously coupled to usernames; must be separate."""
    redactor = jrc.LogRedactor(redact_device_names=False)  # device names preserved
    obj = {"computerName": "MacBook-001", "username": "jdoe"}
    out = redactor.redact_json(obj)
    # Device name preserved as requested.
    assert out["computerName"] == "MacBook-001"
    # Username MUST still be redacted — default redact_usernames=True applies.
    assert out["username"].startswith("user-")


def test_keep_usernames_independently_disables_username_redaction(jrc):
    redactor = jrc.LogRedactor(redact_usernames=False)
    obj = {"username": "jdoe", "serialNumber": "C02XL3FRJHD2"}
    out = redactor.redact_json(obj)
    assert out["username"] == "jdoe"
    # Other PII still redacted.
    assert out["serialNumber"].startswith("serial-")


def test_redactor_policy_dict_has_separate_usernames_key(jrc):
    """Manifest must surface the usernames flag independently of device_names."""
    redactor = jrc.LogRedactor(redact_device_names=False, redact_usernames=True)
    policy = redactor.policy()
    assert "usernames" in policy
    assert "device_names_in_json" in policy
    assert policy["usernames"] is True
    assert policy["device_names_in_json"] is False


def test_bundle_manifest_does_not_leak_absolute_workspace_path(jrc, mock_workspace, tmp_path):
    """M-1: manifest.json must not contain the full /Users/<username>/ path."""
    config = _make_config(jrc, mock_workspace)
    output = tmp_path / "bundle.zip"
    jrc.cmd_diagnostic_bundle(config, output_path=output)
    with zipfile.ZipFile(output) as zf:
        manifest = json.loads(zf.read("manifest.json"))
    # Workspace field should be the basename only, not the absolute path.
    assert manifest["workspace"] == mock_workspace.name
    assert "/" not in manifest["workspace"]
    assert "Users" not in manifest["workspace"]


def test_bundle_workspace_tree_does_not_leak_absolute_path(jrc, mock_workspace, tmp_path):
    """M-1: workspace_tree.txt first line must not be the absolute path."""
    config = _make_config(jrc, mock_workspace)
    output = tmp_path / "bundle.zip"
    jrc.cmd_diagnostic_bundle(config, output_path=output)
    with zipfile.ZipFile(output) as zf:
        tree = zf.read("workspace_tree.txt").decode("utf-8")
    first_line = tree.split("\n", 1)[0]
    # First line should be `<basename>/`, NOT `/Users/<username>/<rest>/`.
    assert first_line == f"{mock_workspace.name}/"
    assert "/Users/" not in tree


def test_bundle_default_output_path_lands_on_desktop(jrc, mock_workspace, tmp_path, monkeypatch):
    config = _make_config(jrc, mock_workspace)
    # Redirect Path.home() to tmp_path so the test doesn't actually write to Desktop.
    monkeypatch.setattr(Path, "home", lambda: tmp_path)
    (tmp_path / "Desktop").mkdir()
    result = jrc.cmd_diagnostic_bundle(config)
    assert result.parent == tmp_path / "Desktop"
    assert result.name.startswith("jamf-reports-diagnostic-")
    assert result.suffix == ".zip"


# ---------------------------------------------------------------------------
# LogRedactor — home-path / username redaction (Phase 2)
# ---------------------------------------------------------------------------


def test_redactor_strips_username_from_users_path(jrc):
    """Absolute /Users/<name>/ paths in free-text leak the local macOS username."""
    redactor = jrc.LogRedactor()
    text = "can't open file '/Users/jdoe/emdash/worktrees/app/script.py'"
    out = redactor.redact_text(text)
    assert "/Users/jdoe/" not in out
    assert "/Users/user-" in out
    # The rest of the path is preserved.
    assert "/emdash/worktrees/app/script.py" in out


def test_redactor_username_path_same_placeholder_each_time(jrc):
    redactor = jrc.LogRedactor()
    out = redactor.redact_text("/Users/jdoe/a and /Users/jdoe/b")
    placeholders = {seg.split("/")[2] for seg in out.split() if seg.startswith("/Users/")}
    assert len(placeholders) == 1  # both occurrences collapse to one placeholder


def test_redactor_keep_usernames_preserves_users_path(jrc):
    redactor = jrc.LogRedactor(redact_usernames=False)
    out = redactor.redact_text("/Users/jdoe/Documents/report.xlsx")
    assert "/Users/jdoe/" in out


# ---------------------------------------------------------------------------
# LogRedactor — extended PII JSON keys (Phase 2)
# ---------------------------------------------------------------------------


def test_redact_json_redacts_udid_ip_realname_assettag(jrc):
    redactor = jrc.LogRedactor()
    obj = {
        "udid": "00008020-001A2B3C4D5E6F00",
        "ipAddress": "10.1.2.3",
        "realName": "Jane Doe",
        "assetTag": "ASSET-4471",
    }
    out = redactor.redact_json(obj)
    assert out["udid"].startswith("udid-")
    assert out["ipAddress"].startswith("ip-")
    assert out["realName"].startswith("user-")
    assert out["assetTag"].startswith("device-")


def test_redact_json_redacts_org_structure_keys(jrc):
    redactor = jrc.LogRedactor()
    obj = {"building": "HQ West", "department": "Field Ops", "room": "3-114"}
    out = redactor.redact_json(obj)
    assert out["building"].startswith("org-")
    assert out["department"].startswith("org-")
    assert out["room"].startswith("org-")


def test_redact_json_udid_ip_org_have_no_keep_flag(jrc):
    """udid/ip/org are always-on — no --keep-* flag turns them off."""
    redactor = jrc.LogRedactor(
        redact_hostnames=False,
        redact_serials=False,
        redact_emails=False,
        redact_device_names=False,
        redact_usernames=False,
    )
    obj = {"udid": "00008020-001A2B3C", "ipAddress": "10.0.0.9", "building": "HQ"}
    out = redactor.redact_json(obj)
    assert out["udid"].startswith("udid-")
    assert out["ipAddress"].startswith("ip-")
    assert out["building"].startswith("org-")


# ---------------------------------------------------------------------------
# LogRedactor — seed-from-workspace device-name redaction (Phase 2)
# ---------------------------------------------------------------------------


@pytest.fixture
def seeded_workspace(tmp_path: Path) -> Path:
    """A workspace with cached jamf-cli JSON carrying device identifiers."""
    workspace = tmp_path / "ws-seed"
    data_dir = workspace / "jamf-cli-data" / "computers"
    data_dir.mkdir(parents=True)
    (data_dir / "computers.json").write_text(json.dumps([
        {"computerName": "Lab-MacBook-Reception", "serialNumber": "ZZ9XL3FRJHD2",
         "udid": "00008020-AAAA1111BBBB2222", "username": "field-tech-amy"},
        {"computerName": "Lab-MacBook-Loading", "serialNumber": "YY8XL3FRJHD3"},
    ]))
    return workspace


def test_seed_from_workspace_collects_identifiers(jrc, seeded_workspace):
    redactor = jrc.LogRedactor()
    # 2 device names + 2 serials + 1 udid + 1 username = 6 distinct literals.
    assert redactor.seed_from_workspace(seeded_workspace) == 6


def test_seed_from_workspace_returns_zero_without_cache(jrc, tmp_path):
    redactor = jrc.LogRedactor()
    assert redactor.seed_from_workspace(tmp_path / "no-such-ws") == 0


def test_seeded_redactor_strips_device_name_from_free_text(jrc, seeded_workspace):
    """The free-text device-name gap: a device name in a log line — not a
    regex-patternable token — must be redacted once the redactor is seeded."""
    redactor = jrc.LogRedactor()
    redactor.seed_from_workspace(seeded_workspace)
    log = "[info] collecting inventory for Lab-MacBook-Reception (user field-tech-amy)"
    out = redactor.redact_text(log)
    assert "Lab-MacBook-Reception" not in out
    assert "field-tech-amy" not in out
    assert "device-" in out
    assert "user-" in out


def test_unseeded_redactor_leaves_device_name(jrc):
    """Without seeding, a free-text device name has no pattern and survives —
    the documented limitation that seed_from_workspace closes."""
    redactor = jrc.LogRedactor()
    out = redactor.redact_text("collecting inventory for Lab-MacBook-Reception")
    assert "Lab-MacBook-Reception" in out


def test_seed_min_length_floor_skips_short_values(jrc, tmp_path):
    """Short identifiers are not seeded — avoids over-matching common words."""
    workspace = tmp_path / "ws-short"
    data_dir = workspace / "jamf-cli-data" / "computers"
    data_dir.mkdir(parents=True)
    (data_dir / "c.json").write_text(json.dumps([{"computerName": "Mac"}]))  # 3 chars
    redactor = jrc.LogRedactor()
    redactor.seed_from_workspace(workspace)
    out = redactor.redact_text("the word Mac appears in this log")
    assert "Mac" in out  # below the 4-char floor — not redacted


def test_bundle_seeds_redactor_and_strips_device_names_from_logs(jrc, tmp_path):
    """End-to-end canary: a device name written into a log is absent from the
    generated bundle once the workspace has cached JSON to seed from."""
    workspace = tmp_path / "ws-canary"
    (workspace / "automation" / "logs").mkdir(parents=True)
    cache = workspace / "jamf-cli-data" / "computers"
    cache.mkdir(parents=True)
    (cache / "c.json").write_text(json.dumps([{"computerName": "Canary-MacBook-X1"}]))
    (workspace / "automation" / "logs" / "run.log").write_text(
        "[info] generate finished for Canary-MacBook-X1\n"
    )
    (workspace / "config.yaml").write_text('jamf_cli:\n  profile: "canary"\n')
    config = jrc.Config(str(workspace / "config.yaml"))
    output = tmp_path / "bundle.zip"
    jrc.cmd_diagnostic_bundle(config, output_path=output)
    with zipfile.ZipFile(output) as zf:
        log = zf.read("logs/run.log").decode("utf-8")
    assert "Canary-MacBook-X1" not in log
    assert "device-" in log


def test_bundle_zip_is_owner_only(jrc, mock_workspace, tmp_path):
    """The finished diagnostic zip is chmod'd 0o600 regardless of where it lands."""
    import stat
    config = _make_config(jrc, mock_workspace)
    output = tmp_path / "bundle.zip"
    jrc.cmd_diagnostic_bundle(config, output_path=output)
    mode = stat.S_IMODE(output.stat().st_mode)
    assert mode == 0o600
    assert not (mode & 0o077)  # no group/other access


def test_bundle_diagnostics_dir_is_owner_only(jrc, mock_workspace, tmp_path):
    """When the output lands in a 'diagnostics' dir, that dir is tightened to 0o700."""
    import stat
    config = _make_config(jrc, mock_workspace)
    diag_dir = tmp_path / "diagnostics"
    output = diag_dir / "bundle.zip"
    jrc.cmd_diagnostic_bundle(config, output_path=output)
    mode = stat.S_IMODE(diag_dir.stat().st_mode)
    assert mode == 0o700
