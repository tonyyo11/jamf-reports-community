"""LaunchAgent plist hardening: owner-only perms, redacted command echo, and
LogRedactor coverage of the bare ``--notify <url>`` argv form.
"""
from __future__ import annotations

import plistlib
import stat

WEBHOOK = "https://example.webhook.office.com/webhookb2/abc123/secret-token"


# --- plist file mode ---------------------------------------------------------

def test_write_launchagent_bytes_default_mode_is_owner_only(jrc, tmp_path):
    target = tmp_path / "agent.plist"
    jrc._write_launchagent_bytes(target, b"<plist/>")
    mode = stat.S_IMODE(target.stat().st_mode)
    assert mode == 0o600
    assert not (mode & 0o077)  # no group/other bits


def test_write_launchagent_plist_is_owner_only(jrc, tmp_path):
    plist_path = tmp_path / "com.example.agent.plist"
    jrc._write_launchagent_plist(
        plist_path,
        "com.example.agent",
        ["/usr/bin/python3", "script.py", "launchagent-run", "--notify", WEBHOOK],
        tmp_path,
        [{"Hour": 6, "Minute": 0}],
        tmp_path / "out.log",
        tmp_path / "err.log",
    )
    mode = stat.S_IMODE(plist_path.stat().st_mode)
    assert mode == 0o600
    # The secret IS still in the written plist (this is the live job file).
    payload = plistlib.loads(plist_path.read_bytes())
    assert WEBHOOK in payload["ProgramArguments"]


def test_existing_wider_mode_is_clamped(jrc, tmp_path):
    """A pre-existing world-readable plist must be rewritten without group/other
    read bits, not inherited verbatim."""
    plist_path = tmp_path / "com.example.agent.plist"
    plist_path.write_bytes(b"<plist/>")
    plist_path.chmod(0o644)
    jrc._write_launchagent_plist(
        plist_path,
        "com.example.agent",
        ["/usr/bin/python3", "script.py", "launchagent-run"],
        tmp_path,
        [{"Hour": 6, "Minute": 0}],
        tmp_path / "out.log",
        tmp_path / "err.log",
    )
    mode = stat.S_IMODE(plist_path.stat().st_mode)
    assert not (mode & 0o077)  # group/other cleared


# --- redacted command echo ---------------------------------------------------

def test_redacted_program_args_masks_notify_value(jrc):
    args = ["/usr/bin/python3", "script.py", "launchagent-run", "--notify", WEBHOOK, "--mode", "x"]
    redacted = jrc._redacted_program_args(args)
    assert WEBHOOK not in redacted
    assert "<redacted>" in redacted
    # Surrounding args untouched.
    assert redacted[:4] == args[:4]
    assert redacted[-2:] == ["--mode", "x"]


def test_redacted_program_args_no_notify_unchanged(jrc):
    args = ["/usr/bin/python3", "script.py", "launchagent-run", "--mode", "x"]
    assert jrc._redacted_program_args(args) == args


def test_redacted_program_args_does_not_mutate_input(jrc):
    args = ["a", "--notify", WEBHOOK]
    jrc._redacted_program_args(args)
    assert args == ["a", "--notify", WEBHOOK]  # original list intact


# --- LogRedactor coverage of the bare --notify form --------------------------

def test_logredactor_redacts_notify_argv_space_form(jrc):
    redactor = jrc.LogRedactor()
    text = f"command: python3 script.py launchagent-run --notify {WEBHOOK} --mode full"
    out = redactor.redact_text(text)
    assert WEBHOOK not in out
    assert "REDACTED_WEBHOOK_URL" in out
    assert "--mode full" in out  # trailing args preserved


def test_logredactor_redacts_notify_argv_equals_form(jrc):
    redactor = jrc.LogRedactor()
    out = redactor.redact_text(f"--notify={WEBHOOK}")
    assert WEBHOOK not in out
    assert "REDACTED_WEBHOOK_URL" in out


def test_logredactor_notify_redaction_survives_secret_only_mode(jrc):
    """The secret-only redactor used for log echoes (PII off) still scrubs the
    webhook URL — it is a credential, not PII."""
    redactor = jrc.LogRedactor(
        redact_hostnames=False,
        redact_serials=False,
        redact_emails=False,
        redact_device_names=False,
        redact_usernames=False,
    )
    out = redactor.redact_text(f"--notify {WEBHOOK}")
    assert WEBHOOK not in out
