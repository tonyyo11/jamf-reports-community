"""T-13 integrity envelope: HTML meta+footer and XLSX `.sha256` sidecar."""

from __future__ import annotations

import hashlib
import re
from pathlib import Path


def _make_html_report(jrc, config_factory, tmp_path):
    """Return an HtmlReport instance wired to a dummy config and offline bridge."""
    config = config_factory("dummy.yaml")
    bridge = jrc.JamfCLIBridge(
        save_output=False,
        data_dir=str(tmp_path),
        use_cached_data=False,
    )
    out_path = tmp_path / "report.html"
    return jrc.HtmlReport(config, bridge, out_path, no_open=True)


def _minimal_data() -> dict:
    """Return a minimal data dict that satisfies HtmlReport._render."""
    return {
        "overview": [
            {"section": "General", "resource": "Server URL", "value": "https://example.test"}
        ],
        "security": [],
    }


def test_html_report_embeds_report_sha256_meta(jrc, config_factory, tmp_path) -> None:
    """The rendered HTML must declare a `report-sha256` meta tag."""
    report = _make_html_report(jrc, config_factory, tmp_path)
    html = report._render(_minimal_data())

    assert '<meta name="report-sha256"' in html
    # Placeholder shape: 64 hex chars (either zeros pre-substitution or real digest).
    matches = re.findall(
        r'<meta name="report-sha256" content="([0-9a-f]{64})">', html
    )
    assert len(matches) == 1, f"expected exactly 1 meta tag, found {len(matches)}"


def test_html_report_footer_includes_verify_command(jrc, config_factory, tmp_path) -> None:
    """The footer must surface a shasum verification command for the user."""
    report = _make_html_report(jrc, config_factory, tmp_path)
    html = report._render(_minimal_data())

    assert 'class="verify-footer"' in html
    assert "shasum -a 256" in html
    assert "report.html" in html  # the filename of the output we configured


def test_html_report_meta_hash_matches_placeholder_version_bytes(
    jrc, config_factory, tmp_path
) -> None:
    """The meta hash must equal sha256 of the placeholder-version file bytes.

    Per T-13 design (see HtmlReport.generate docstring): the embedded hash
    covers the report's source fingerprint. Verifiers reproduce it by
    substituting the embedded hash back to the placeholder (64 zeros) and
    re-hashing.
    """
    report = _make_html_report(jrc, config_factory, tmp_path)
    # Drive the public generate() path so the substitution happens.
    report._fetch_all = lambda: _minimal_data()  # bypass jamf-cli fetch
    report._append_history_snapshot = lambda _data: None
    out_path = report.generate()

    file_bytes = out_path.read_bytes()
    text = file_bytes.decode("utf-8")

    # Extract the embedded hash.
    match = re.search(
        r'<meta name="report-sha256" content="([0-9a-f]{64})">', text
    )
    assert match is not None, "meta tag not found in written HTML"
    embedded_hash = match.group(1)
    assert embedded_hash != "0" * 64, "placeholder was not substituted"

    # Reproduce the digest the way an external verifier would.
    placeholder_text = text.replace(embedded_hash, "0" * 64)
    expected = hashlib.sha256(placeholder_text.encode("utf-8")).hexdigest()
    assert embedded_hash == expected, (
        f"meta hash {embedded_hash} != recomputed placeholder-version hash {expected}"
    )


def test_html_generate_substitutes_both_placeholder_sites(
    jrc, config_factory, tmp_path
) -> None:
    """The placeholder appears in two sites (meta tag + footer); both must be substituted."""
    report = _make_html_report(jrc, config_factory, tmp_path)
    report._fetch_all = lambda: _minimal_data()
    report._append_history_snapshot = lambda _data: None
    out_path = report.generate()

    text = out_path.read_text(encoding="utf-8")
    # Placeholder must NOT appear in the final file — both sites should be
    # populated with the real digest.
    assert "0" * 64 not in text, (
        "placeholder still present in written HTML — substitution incomplete"
    )


def test_write_sha256_sidecar_uses_shasum_format(jrc, tmp_path) -> None:
    """Sidecar format: `<hash><two-spaces><basename>\\n` for shasum -a 256 -c."""
    artifact = tmp_path / "report.xlsx"
    artifact.write_bytes(b"dummy xlsx body")
    expected_hash = hashlib.sha256(b"dummy xlsx body").hexdigest()

    sidecar = jrc._write_sha256_sidecar(artifact)
    assert sidecar is not None
    assert sidecar.name == "report.xlsx.sha256"

    text = sidecar.read_text(encoding="utf-8")
    assert text == f"{expected_hash}  report.xlsx\n", (
        "sidecar must be exactly `<hash><two-spaces><basename><LF>` "
        "so `shasum -a 256 -c` accepts it"
    )


def test_write_sha256_sidecar_returns_none_when_artifact_missing(
    jrc, tmp_path
) -> None:
    """Missing artifact = warning + None return; never raises."""
    sidecar = jrc._write_sha256_sidecar(tmp_path / "does-not-exist.xlsx")
    assert sidecar is None


def test_xlsx_sidecar_sha256_matches_file_content(jrc, tmp_path) -> None:
    """Round-trip: write a dummy XLSX, sidecar must verify with shasum -c semantics."""
    artifact = tmp_path / "jamf_report_2026-05-17.xlsx"
    blob = b"\x50\x4b\x03\x04" + b"fake xlsx content " * 100  # PK header + payload
    artifact.write_bytes(blob)
    expected = hashlib.sha256(blob).hexdigest()

    sidecar = jrc._write_sha256_sidecar(artifact)
    assert sidecar is not None
    content = sidecar.read_text(encoding="utf-8").rstrip("\n")
    hash_part, _, name_part = content.partition("  ")
    assert hash_part == expected
    assert name_part == artifact.name
