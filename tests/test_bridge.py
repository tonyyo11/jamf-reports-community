"""Tests for JamfCLIBridge behavior."""

from __future__ import annotations

from pathlib import Path

import pytest


class _InventoryCsvBridge:
    """Minimal bridge double for inventory-csv command tests."""

    def is_available(self) -> bool:
        return True

    def computers_list(self, sections=None):
        return [{
            "general": {
                "id": "1",
                "name": "Mac-001",
                "serialNumber": "C02TEST001",
                "remoteManagement": {"managed": True},
            },
        }]

    def ea_results_report(self, include_all=True):
        return []


def _inventory_csv_config(config_factory):
    config = config_factory("dummy.yaml")
    config._data["jamf_cli"]["enabled"] = True
    config._data["inventory_csv"]["skip_security_enrichment"] = True
    config._data["output"]["archive_enabled"] = False
    return config


def test_run_and_save_falls_back_to_committed_cache(monkeypatch, fixtures_root, jrc) -> None:
    bridge = jrc.JamfCLIBridge(
        save_output=False,
        data_dir=str(fixtures_root / "jamf-cli-data"),
        profile="dummy",
        use_cached_data=True,
    )
    monkeypatch.setattr(
        bridge,
        "_run",
        lambda args, timeout=None: (_ for _ in ()).throw(RuntimeError("boom")),
    )

    data = bridge.overview()

    assert isinstance(data, list)
    assert bridge.source_info("overview")["mode"] == "cached-fallback"


def test_inventory_csv_writes_temp_file_before_replacing_final(
    monkeypatch,
    config_factory,
    tmp_path,
    jrc,
) -> None:
    config = _inventory_csv_config(config_factory)
    out_path = tmp_path / "inventory.csv"
    to_csv_paths: list[Path] = []
    original_to_csv = jrc.pd.DataFrame.to_csv

    monkeypatch.setattr(
        jrc,
        "_build_jamf_cli_bridge",
        lambda *args, **kwargs: _InventoryCsvBridge(),
    )

    def recording_to_csv(self, path_or_buf=None, *args, **kwargs):
        to_csv_paths.append(Path(path_or_buf))
        return original_to_csv(self, path_or_buf, *args, **kwargs)

    monkeypatch.setattr(jrc.pd.DataFrame, "to_csv", recording_to_csv)

    result = jrc.cmd_inventory_csv(config, str(out_path))

    assert result == out_path
    assert out_path.exists()
    assert "Mac-001" in out_path.read_text(encoding="utf-8-sig")
    assert len(to_csv_paths) == 1
    temp_path = to_csv_paths[0]
    assert temp_path.parent == out_path.parent
    assert temp_path.name.startswith(f".{out_path.name}.")
    assert temp_path.suffix == ".tmp"
    assert temp_path != out_path
    assert not temp_path.exists()
    assert not list(out_path.parent.glob(".inventory.csv.*.tmp"))


def test_inventory_csv_write_failure_removes_temp_and_preserves_final(
    monkeypatch,
    config_factory,
    tmp_path,
    jrc,
) -> None:
    config = _inventory_csv_config(config_factory)
    out_path = tmp_path / "inventory.csv"
    out_path.write_text("existing\n", encoding="utf-8")
    temp_paths: list[Path] = []

    monkeypatch.setattr(
        jrc,
        "_build_jamf_cli_bridge",
        lambda *args, **kwargs: _InventoryCsvBridge(),
    )

    def failing_to_csv(self, path_or_buf=None, *args, **kwargs):
        temp_path = Path(path_or_buf)
        temp_paths.append(temp_path)
        temp_path.write_text("partial\n", encoding="utf-8")
        raise OSError("disk full")

    monkeypatch.setattr(jrc.pd.DataFrame, "to_csv", failing_to_csv)

    with pytest.raises(SystemExit) as exc_info:
        jrc.cmd_inventory_csv(config, str(out_path))

    message = str(exc_info.value)
    assert "Error: failed to write inventory CSV" in message
    assert "disk full" in message
    assert out_path.read_text(encoding="utf-8") == "existing\n"
    assert len(temp_paths) == 1
    assert not temp_paths[0].exists()
    assert not list(out_path.parent.glob(".inventory.csv.*.tmp"))


def test_computers_inventory_patch_builds_expected_set_args(monkeypatch, jrc) -> None:
    bridge = jrc.JamfCLIBridge(save_output=False, use_cached_data=False)
    captured: list[str] = []

    def fake_run(args, timeout=None):
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


def test_update_status_normalizes_cached_toggle_off_response(monkeypatch, jrc) -> None:
    bridge = jrc.JamfCLIBridge(save_output=False, use_cached_data=False)
    monkeypatch.setattr(bridge, "_require_report_command", lambda *args, **kwargs: None)
    monkeypatch.setattr(bridge, "_run_and_save", lambda *args, **kwargs: {
        "httpStatus": 503,
        "errors": [{
            "description": (
                "This endpoint cannot be used if the Managed Software Update Plans "
                "toggle is off."
            ),
        }],
    })

    result = bridge.update_status()

    assert result == {
        "message": "No managed software update data found.",
        "summary": {},
        "ErrorDevices": [],
    }


def test_update_device_failures_normalizes_cached_toggle_off_response(
    monkeypatch,
    jrc,
) -> None:
    bridge = jrc.JamfCLIBridge(save_output=False, use_cached_data=False)
    monkeypatch.setattr(bridge, "_require_report_command", lambda *args, **kwargs: None)
    monkeypatch.setattr(bridge, "_run_and_save", lambda *args, **kwargs: {
        "httpStatus": 503,
        "errors": [{
            "description": (
                "This endpoint cannot be used if the Managed Software Update Plans "
                "toggle is off."
            ),
        }],
    })

    result = bridge.update_device_failures()

    assert isinstance(result, list)
    assert result[0]["message"] == "No managed software update data found."
    assert result[0]["failed_plans"] == []


def test_update_no_data_response_accepts_only_errors_or_exact_empty_envelopes(jrc) -> None:
    """A regular payload with a matching message must not be dropped as no-data."""
    status_empty = jrc._empty_update_status_envelope()
    failures_empty = jrc._empty_update_failures_envelope()
    real_payload_with_message = {
        "message": "No managed software update data found.",
        "total": 1,
        "status_summary": [{"status": "FAILED", "count": 1}],
    }

    assert jrc._is_update_no_data_response(status_empty) is True
    assert jrc._is_update_no_data_response(failures_empty) is True
    assert jrc._is_update_no_data_response({
        "httpStatus": 503,
        "errors": [{"description": "Managed Software Update Plans toggle is off."}],
    }) is True
    assert jrc._is_update_no_data_response(real_payload_with_message) is False
    assert jrc._is_update_no_data_response([real_payload_with_message]) is False


def test_groups_uses_confirmed_list_command(monkeypatch, jrc) -> None:
    bridge = jrc.JamfCLIBridge(save_output=False, use_cached_data=False)
    captured: list[str] = []

    def fake_run(args, timeout=None):
        captured.extend(args)
        return [{"groupName": "All Managed Clients", "groupType": "COMPUTER"}]

    monkeypatch.setattr(bridge, "_run", fake_run)

    result = bridge.groups()

    assert result == [{"groupName": "All Managed Clients", "groupType": "COMPUTER"}]
    assert captured == ["pro", "groups", "list"]


def test_packages_uses_pro_packages_list(monkeypatch, jrc) -> None:
    bridge = jrc.JamfCLIBridge(save_output=False, use_cached_data=False)
    captured = {}

    def fake_run_and_save(report_type, args, cache_names=None, timeout=None):
        captured["report_type"] = report_type
        captured["args"] = list(args)
        captured["cache_names"] = list(cache_names or [])
        return [{"id": "1"}]

    monkeypatch.setattr(bridge, "_run_and_save", fake_run_and_save)

    result = bridge.packages()

    assert result == [{"id": "1"}]
    assert captured == {
        "report_type": "packages",
        "args": ["pro", "packages", "list"],
        "cache_names": ["packages"],
    }
