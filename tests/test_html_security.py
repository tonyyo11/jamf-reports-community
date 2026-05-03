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
