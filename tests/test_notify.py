"""v2.2.0 Phase 3 opt-in webhook digest — pure payload builders."""
from __future__ import annotations


def test_teams_card_payload_shape(jrc) -> None:
    facts = [("File", "report.xlsx"), ("Sheets", "12")]
    payload = jrc._teams_card_payload("Jamf Report Generated", facts)

    assert payload["type"] == "message"
    content = payload["attachments"][0]["content"]
    assert content["type"] == "AdaptiveCard"
    body = content["body"]
    title_block = next(b for b in body if b["type"] == "TextBlock")
    assert title_block["text"] == "Jamf Report Generated"
    fact_set = next(b for b in body if b["type"] == "FactSet")
    assert fact_set["facts"] == [
        {"title": "File", "value": "report.xlsx"},
        {"title": "Sheets", "value": "12"},
    ]


def test_slack_blocks_payload_shape(jrc) -> None:
    facts = [("File", "report.xlsx"), ("Sheets", "12")]
    payload = jrc._slack_blocks_payload("Jamf Report Generated", facts)

    assert payload["text"] == "Jamf Report Generated", "fallback notification text"
    header = next(b for b in payload["blocks"] if b["type"] == "header")
    assert header["text"]["text"] == "Jamf Report Generated"
    section = next(b for b in payload["blocks"] if b["type"] == "section")
    mrkdwn = section["text"]["text"]
    assert "*File:* report.xlsx" in mrkdwn
    assert "*Sheets:* 12" in mrkdwn


def test_notify_config_default_is_off(jrc, tmp_path) -> None:
    """A scaffolded/default config has notify off, so no URL resolves without
    --notify."""
    config_path = tmp_path / "config.yaml"
    config_path.write_text("jamf_cli:\n  profile: test\n", encoding="utf-8")
    config = jrc.Config(str(config_path))
    notify = config.notify
    assert notify.get("enabled") is False
    assert notify.get("provider") == "teams"
    assert notify.get("url") == ""
