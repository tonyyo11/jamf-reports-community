"""Tests for JamfCLIBridge behavior."""

from __future__ import annotations


def test_run_and_save_falls_back_to_committed_cache(monkeypatch, fixtures_root, jrc) -> None:
    bridge = jrc.JamfCLIBridge(
        save_output=False,
        data_dir=str(fixtures_root / "jamf-cli-data"),
        profile="dummy",
        use_cached_data=True,
    )
    monkeypatch.setattr(bridge, "_run", lambda args: (_ for _ in ()).throw(RuntimeError("boom")))

    data = bridge.overview()

    assert isinstance(data, list)
    assert bridge.source_info("overview")["mode"] == "cached-fallback"


def test_computers_inventory_patch_builds_expected_set_args(monkeypatch, jrc) -> None:
    bridge = jrc.JamfCLIBridge(save_output=False, use_cached_data=False)
    captured: list[str] = []

    def fake_run(args):
        captured.extend(args)
        return {"ok": True}

    monkeypatch.setattr(bridge, "_run", fake_run)

    result = bridge.computers_inventory_patch(
        "ABC123",
        {"general.managed": "true", "extensionAttributes.demo": "present"},
    )

    assert result == {"ok": True}
    assert captured == [
        "pro",
        "computers-inventory",
        "patch",
        "--serial",
        "ABC123",
        "--set",
        "general.managed=true",
        "--set",
        "extensionAttributes.demo=present",
    ]


def test_update_device_failures_returns_empty_envelope_for_toggle_off(monkeypatch, jrc) -> None:
    bridge = jrc.JamfCLIBridge(save_output=False, use_cached_data=False)
    monkeypatch.setattr(bridge, "_require_report_command", lambda *args, **kwargs: None)

    def raise_toggle_error(*args, **kwargs):
        raise RuntimeError("Managed Software Update Plans toggle is off.")

    monkeypatch.setattr(bridge, "_run_and_save", raise_toggle_error)

    result = bridge.update_device_failures()

    assert isinstance(result, list)
    assert result[0]["message"] == "No managed software update data found."
    assert result[0]["failed_plans"] == []
