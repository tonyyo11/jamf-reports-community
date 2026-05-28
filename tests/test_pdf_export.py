"""Tests for the `pdf` CLI command."""

from __future__ import annotations

from pathlib import Path
from typing import Any

import pytest


def _patch_html_render(monkeypatch, jrc) -> None:
    """Stub HtmlReport.generate() so cmd_pdf can run without jamf-cli data."""

    def _fake_generate(self) -> Path:
        self._out_file.parent.mkdir(parents=True, exist_ok=True)
        self._out_file.write_text(
            "<html><body><h1>Test</h1></body></html>", encoding="utf-8"
        )
        return self._out_file

    monkeypatch.setattr(jrc.HtmlReport, "generate", _fake_generate)


def test_cmd_pdf_uses_weasyprint_when_available(
    monkeypatch, config_factory, tmp_path, jrc
) -> None:
    config = config_factory("dummy.yaml")
    _patch_html_render(monkeypatch, jrc)
    monkeypatch.setattr(jrc, "_weasyprint_available", lambda: True)

    called: dict[str, Any] = {}

    def _fake_render(html_path: Path, pdf_path: Path) -> None:
        called["html"] = html_path
        called["pdf"] = pdf_path
        pdf_path.write_bytes(b"%PDF-1.4 stub\n")

    monkeypatch.setattr(jrc, "_render_pdf_with_weasyprint", _fake_render)

    opened: list[list[str]] = []
    monkeypatch.setattr(
        jrc.subprocess, "run", lambda cmd, check=False: opened.append(cmd)
    )

    out_path = tmp_path / "report.pdf"
    result = jrc.cmd_pdf(config, str(out_path), no_open=True)

    assert result.exists()
    assert result.read_bytes().startswith(b"%PDF")
    assert called["pdf"] == result
    assert called["html"].suffix == ".html"
    assert not called["html"].exists()
    assert opened == []


def test_cmd_pdf_errors_when_weasyprint_missing(
    monkeypatch, config_factory, tmp_path, jrc
) -> None:
    config = config_factory("dummy.yaml")
    monkeypatch.setattr(jrc, "_weasyprint_available", lambda: False)

    with pytest.raises(SystemExit) as excinfo:
        jrc.cmd_pdf(config, str(tmp_path / "report.pdf"), no_open=True)

    message = str(excinfo.value)
    assert "weasyprint" in message
    assert "pip install" in message


def test_cmd_pdf_no_open_skips_subprocess(
    monkeypatch, config_factory, tmp_path, jrc
) -> None:
    config = config_factory("dummy.yaml")
    _patch_html_render(monkeypatch, jrc)
    monkeypatch.setattr(jrc, "_weasyprint_available", lambda: True)
    monkeypatch.setattr(
        jrc,
        "_render_pdf_with_weasyprint",
        lambda html, pdf: pdf.write_bytes(b"%PDF-1.4\n"),
    )

    calls: list[list[str]] = []
    monkeypatch.setattr(
        jrc.subprocess, "run", lambda cmd, check=False: calls.append(cmd)
    )

    jrc.cmd_pdf(config, str(tmp_path / "report.pdf"), no_open=True)
    assert calls == []


def test_cmd_pdf_open_invokes_open_subprocess(
    monkeypatch, config_factory, tmp_path, jrc
) -> None:
    config = config_factory("dummy.yaml")
    _patch_html_render(monkeypatch, jrc)
    monkeypatch.setattr(jrc, "_weasyprint_available", lambda: True)
    monkeypatch.setattr(
        jrc,
        "_render_pdf_with_weasyprint",
        lambda html, pdf: pdf.write_bytes(b"%PDF-1.4\n"),
    )
    monkeypatch.setattr(jrc.sys, "platform", "darwin")

    calls: list[list[str]] = []
    monkeypatch.setattr(
        jrc.subprocess, "run", lambda cmd, check=False: calls.append(cmd)
    )

    out_path = tmp_path / "report.pdf"
    jrc.cmd_pdf(config, str(out_path), no_open=False)

    assert len(calls) == 1
    assert calls[0][0] == "open"
    assert calls[0][1].endswith("report.pdf")


def test_weasyprint_available_uses_find_spec(monkeypatch, jrc) -> None:
    import importlib.util as _util

    monkeypatch.setattr(_util, "find_spec", lambda name: object() if name == "weasyprint" else None)
    assert jrc._weasyprint_available() is True

    monkeypatch.setattr(_util, "find_spec", lambda name: None)
    assert jrc._weasyprint_available() is False
