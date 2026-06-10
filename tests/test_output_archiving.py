"""Direct tests for output-run archiving and the output.archive_dir containment
guard.

Covers keep_latest_runs edges, sidecar (.sha256/.manifest) co-archiving, and the
workspace-escape fallback for an absolute output.archive_dir.
"""
from __future__ import annotations

import os
from pathlib import Path


def _make_run(directory: Path, family: str, stamp: str, *, sidecars=False) -> Path:
    """Write a timestamped report (and optional sidecars), return the report path."""
    report = directory / f"{family}_{stamp}.xlsx"
    report.write_text("report-body", encoding="utf-8")
    if sidecars:
        (directory / f"{report.name}.sha256").write_text("deadbeef  " + report.name, encoding="utf-8")
        (directory / f"{report.name}.manifest").write_text("{}", encoding="utf-8")
    return report


def _touch_order(paths: list[Path]) -> None:
    """Set ascending mtimes so paths[0] is oldest, paths[-1] is newest."""
    base = 1_700_000_000
    for i, p in enumerate(paths):
        for f in p.parent.glob(p.name + "*"):
            os.utime(f, (base + i * 100, base + i * 100))
        os.utime(p, (base + i * 100, base + i * 100))


# --- keep_latest_runs edges --------------------------------------------------

def test_keep_zero_archives_nothing(jrc, tmp_path):
    out = tmp_path / "out"
    out.mkdir()
    _make_run(out, "report", "2026-06-01_010101")
    moved = jrc._archive_old_output_runs(out, "report", {".xlsx"}, 0, tmp_path / "arch")
    assert moved == []


def test_runs_at_or_below_keep_archive_nothing(jrc, tmp_path):
    out = tmp_path / "out"
    out.mkdir()
    r1 = _make_run(out, "report", "2026-06-01_010101")
    r2 = _make_run(out, "report", "2026-06-02_010101")
    _touch_order([r1, r2])
    moved = jrc._archive_old_output_runs(out, "report", {".xlsx"}, 2, tmp_path / "arch")
    assert moved == []
    assert r1.exists() and r2.exists()


def test_oldest_runs_archived_newest_kept(jrc, tmp_path):
    out = tmp_path / "out"
    out.mkdir()
    arch = tmp_path / "arch"
    r1 = _make_run(out, "report", "2026-06-01_010101")
    r2 = _make_run(out, "report", "2026-06-02_010101")
    r3 = _make_run(out, "report", "2026-06-03_010101")
    _touch_order([r1, r2, r3])
    moved = jrc._archive_old_output_runs(out, "report", {".xlsx"}, 1, arch)
    # Keep 1 newest (r3); archive r1 and r2.
    assert not r1.exists() and not r2.exists()
    assert r3.exists()
    moved_names = {p.name for p in moved}
    assert moved_names == {r1.name, r2.name}
    assert all((arch / "report").joinpath(n).exists() for n in moved_names)


def test_missing_directory_returns_empty(jrc, tmp_path):
    moved = jrc._archive_old_output_runs(tmp_path / "nope", "report", {".xlsx"}, 1, tmp_path / "a")
    assert moved == []


# --- sidecars co-archive -----------------------------------------------------

def test_sidecars_move_with_their_report(jrc, tmp_path):
    out = tmp_path / "out"
    out.mkdir()
    arch = tmp_path / "arch"
    r1 = _make_run(out, "report", "2026-06-01_010101", sidecars=True)
    r2 = _make_run(out, "report", "2026-06-02_010101", sidecars=True)
    _touch_order([r1, r2])
    moved = jrc._archive_old_output_runs(out, "report", {".xlsx"}, 1, arch)
    # r1 archived (oldest); its sidecars must follow, none left orphaned in out/.
    assert not (out / f"{r1.name}.sha256").exists()
    assert not (out / f"{r1.name}.manifest").exists()
    fam = arch / "report"
    assert (fam / f"{r1.name}.sha256").exists()
    assert (fam / f"{r1.name}.manifest").exists()
    # r2 (kept) retains its sidecars in place.
    assert (out / f"{r2.name}.sha256").exists()
    moved_names = {p.name for p in moved}
    assert f"{r1.name}.sha256" in moved_names
    assert f"{r1.name}.manifest" in moved_names


def test_files_with_sidecars_helper(jrc, tmp_path):
    report = tmp_path / "report_2026-06-01.xlsx"
    report.write_text("x", encoding="utf-8")
    (tmp_path / "report_2026-06-01.xlsx.sha256").write_text("h", encoding="utf-8")
    files = jrc._output_run_files_with_sidecars(report)
    names = [p.name for p in files]
    assert names[0] == report.name  # report first
    assert "report_2026-06-01.xlsx.sha256" in names
    assert "report_2026-06-01.xlsx.manifest" not in names  # absent → not listed


# --- output.archive_dir containment guard ------------------------------------

def test_archive_dir_unset_uses_default(jrc, config_factory, tmp_path):
    config = config_factory("dummy.yaml")
    config._data["output"]["archive_dir"] = ""
    out_path = Path(config.base_dir) / "Generated Reports" / "report.xlsx"
    resolved = jrc._resolve_output_archive_dir(config, out_path)
    assert resolved == out_path.parent / "archive"


def test_archive_dir_inside_workspace_allowed(jrc, config_factory):
    config = config_factory("dummy.yaml")
    inside = Path(config.base_dir) / "custom-archive"
    config._data["output"]["archive_dir"] = str(inside)
    out_path = Path(config.base_dir) / "Generated Reports" / "report.xlsx"
    resolved = jrc._resolve_output_archive_dir(config, out_path)
    assert resolved == inside


def test_archive_dir_escape_falls_back_and_warns(jrc, config_factory, tmp_path, capsys):
    config = config_factory("dummy.yaml")
    escape = tmp_path / "outside-workspace"  # tmp_path is NOT under config.base_dir
    config._data["output"]["archive_dir"] = str(escape)
    out_path = Path(config.base_dir) / "Generated Reports" / "report.xlsx"
    resolved = jrc._resolve_output_archive_dir(config, out_path)
    assert resolved == out_path.parent / "archive"  # fell back to default
    assert escape != resolved
    warning = capsys.readouterr().out
    assert "outside the workspace root" in warning


def test_escape_detector_logic(jrc, tmp_path):
    workspace = (tmp_path / "ws").resolve()
    workspace.mkdir()
    inside = workspace / "a" / "b"
    outside = (tmp_path / "elsewhere").resolve()
    assert not jrc._archive_dir_escapes_workspace(workspace, workspace)  # equal
    assert not jrc._archive_dir_escapes_workspace(inside, workspace)
    assert jrc._archive_dir_escapes_workspace(outside, workspace)
