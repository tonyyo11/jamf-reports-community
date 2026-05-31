"""Security regression tests for generated HTML reports."""

from __future__ import annotations


def _make_html_report(jrc, config_factory, tmp_path):
    """Return an HtmlReport instance wired to a dummy config and offline bridge."""
    config = config_factory("dummy.yaml")
    bridge = jrc.JamfCLIBridge(
        save_output=False,
        data_dir=str(tmp_path),
        use_cached_data=False,
    )
    return jrc.HtmlReport(config, bridge, tmp_path / "report.html", no_open=True)


def test_html_report_escapes_title_and_branding(jrc, config_factory, tmp_path) -> None:
    report = _make_html_report(jrc, config_factory, tmp_path)
    report._config._data["branding"]["org_name"] = '</title><script>alert("x")</script>'
    data = {
        "overview": [
            {
                "section": "General",
                "resource": "Server URL",
                "value": 'https://example.test/"></title><script>alert("y")</script>',
            }
        ],
        "security": [],
    }

    html = report._render(data)

    assert '</title><script>alert("x")</script>' not in html
    assert '</title><script>alert("y")</script>' not in html
    assert "&lt;/title&gt;&lt;script&gt;" in html


def test_html_css_branding_rejects_style_breakout(jrc, config_factory, tmp_path) -> None:
    report = _make_html_report(jrc, config_factory, tmp_path)
    report._config._data["branding"]["accent_color"] = '#123456;}</style><script>alert(1)</script>'
    report._config._data["branding"]["accent_dark"] = "#004165"

    css = report._css()

    assert "</style>" not in css
    assert "<script" not in css
    assert "--blue-dark: #004165;" in css
    assert "#123456;}" not in css


def test_html_logo_rejects_svg_active_content(jrc, config_factory, tmp_path) -> None:
    report = _make_html_report(jrc, config_factory, tmp_path)
    svg = tmp_path / "logo.svg"
    svg.write_text(
        '<svg xmlns="http://www.w3.org/2000/svg"><script>alert(1)</script></svg>',
        encoding="utf-8",
    )
    report._config._data["branding"]["logo_path"] = str(svg)

    assert report._logo_html() == ""


_COUNTS_ONLY_SUMMARY = {
    "total_devices": 100,
    "filevault_encrypted": 90,
    "sip_enabled": 80,
    "firewall_enabled": 70,
    "gatekeeper_enabled": 95,
}


def _render_with_security(jrc, config_factory, tmp_path, summary: dict) -> str:
    report = _make_html_report(jrc, config_factory, tmp_path)
    data = {
        "overview": [],
        "security": [{"section": "summary", "data": summary}],
    }
    return report._render(data)


def test_sec_bars_derive_from_counts_when_pct_absent(
    jrc, config_factory, tmp_path
) -> None:
    """Counts-only security shape (no *_pct keys) must drive the posture bars.

    Regression: previously the macOS Fleet sec-bars read *_pct only and showed
    0% on this documented v1.16.1 shape while the Executive Summary card showed
    the count-derived values — a same-page contradiction. Both now route
    through `_exec_security_metrics`, so the bars reflect compliant/total.
    """
    html = _render_with_security(jrc, config_factory, tmp_path, _COUNTS_ONLY_SUMMARY)
    # FileVault 90/100, SIP 80/100, Firewall 70/100, Gatekeeper 95/100.
    assert "width:90.0%" in html
    assert "width:80.0%" in html
    assert "width:70.0%" in html
    assert "width:95.0%" in html
    assert ">90.0%<" in html  # sec-bar label, not a 0.0% floor


def test_sec_bars_use_pct_keys_when_present(jrc, config_factory, tmp_path) -> None:
    """When *_pct keys are present they are used unchanged (no regression)."""
    summary = dict(
        _COUNTS_ONLY_SUMMARY,
        filevault_encrypted_pct="88%",  # differs from the 90/100 count ratio
    )
    html = _render_with_security(jrc, config_factory, tmp_path, summary)
    assert "width:88.0%" in html
    assert "width:90.0%" not in html  # the count ratio is not used when _pct exists


def test_sec_bars_and_exec_card_agree_on_counts_only(
    jrc, config_factory, tmp_path
) -> None:
    """The exec card and the posture bars show the same FileVault % on one page."""
    html = _render_with_security(jrc, config_factory, tmp_path, _COUNTS_ONLY_SUMMARY)
    # Exec card stat-value and sec-bar label both read 90.0%.
    assert html.count("90.0%") >= 2
