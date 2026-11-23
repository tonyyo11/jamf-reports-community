"""Self-check for changelog_union.py. Run: python3 test_changelog_union.py"""

import tempfile
import unittest
from pathlib import Path

import changelog_union as cu

CONFLICT = """# Changelog

## [Unreleased]

### Added

<<<<<<< HEAD
- Head item. (#1)
- Shared item. (#2)
=======
- Shared item. (#2)
- Incoming item. (#3)
>>>>>>> origin/feature

### Fixed

<<<<<<< HEAD
- Head fix wraps
  onto a second line. (#4)
=======
- Incoming fix. (#6)
>>>>>>> origin/feature

## [1.0.0]

### Fixed

- Old fix. (#7)
"""

HEADER_OUTSIDE = """## [Unreleased]

### Fixed

<<<<<<< HEAD
- Head fix. (#4)
=======
### Changed

- Incoming change. (#5)

### Fixed

- Incoming fix. (#6)
>>>>>>> origin/feature
"""


def run(text: str, *flags: str) -> tuple[int, str, str]:
    with tempfile.TemporaryDirectory() as d:
        path = Path(d) / "CHANGELOG.md"
        path.write_text(text, encoding="utf-8")
        code = cu.main([*flags, str(path)])
        return code, path.read_text(encoding="utf-8"), str(path)


class UnionTests(unittest.TestCase):
    def test_union_orders_head_first_and_keeps_identical_once(self) -> None:
        code, out, _ = run(CONFLICT)
        self.assertEqual(code, 0)
        added = out[out.index("### Added") : out.index("### Fixed")]
        self.assertEqual(
            added.count("- Shared item. (#2)"), 1, "identical bullet kept once"
        )
        self.assertLess(added.index("Head item"), added.index("Incoming item"))
        self.assertLess(out.index("Head fix"), out.index("Incoming fix"))
        self.assertIn("  onto a second line. (#4)", out)
        self.assertNotIn("<<<<<<<", out)

    def test_header_outside_the_hunk_is_flagged(self) -> None:
        code, out, _ = run(HEADER_OUTSIDE)
        self.assertEqual(code, 1)
        self.assertEqual(out.count("### Fixed"), 2)

    def test_release_headings_inside_a_hunk_stay_headings(self) -> None:
        text = (
            "<<<<<<< HEAD\n## [Unreleased]\n\n### Added\n\n- One. (#1)\n"
            "=======\n## [Unreleased]\n\n### Added\n\n- Two. (#2)\n\n### Fixed\n\n- Three. (#3)\n"
            ">>>>>>> x\n"
        )
        code, out, _ = run(text)
        self.assertEqual(code, 0)
        self.assertEqual(out.count("## [Unreleased]"), 1)
        self.assertLess(out.index("- One."), out.index("- Two."))
        self.assertIn("### Fixed", out)

    def test_blank_runs_outside_hunks_are_left_alone(self) -> None:
        text = "# Changelog\n\n\n\nintro\n\n### Added\n\n- A. (#1)\n"
        code, out, _ = run(text)
        self.assertEqual((code, out), (0, text))

    def test_non_ascii_round_trips(self) -> None:
        text = "### Added\n\n<<<<<<< HEAD\n- Caf\u00e9 \u2014 one. (#1)\n=======\n- Two. (#2)\n>>>>>>> x\n"
        code, out, _ = run(text)
        self.assertEqual(code, 0)
        self.assertIn("Caf\u00e9 \u2014 one", out)

    def test_dry_run_writes_nothing(self) -> None:
        code, out, _ = run(CONFLICT, "--dry-run")
        self.assertEqual(out, CONFLICT)
        self.assertEqual(code, 0)

    def test_orphan_continuation_is_found(self) -> None:
        text = "## [Unreleased]\n\n### Fixed\n\n- A fix. (#9)\n  left over words\n"
        self.assertEqual(len(cu.orphans(text.splitlines(keepends=True))), 1)
        code, _, _ = run(text, "--check")
        self.assertEqual(code, 1)

    def test_wrapped_bullet_and_nested_bullet_are_not_orphans(self) -> None:
        text = "### Fixed\n\n- Wraps\n  here. (#9)\n- Parent\n  - child. (#10)\n"
        self.assertEqual(cu.orphans(text.splitlines(keepends=True)), [])

    def test_duplicate_in_one_section_only(self) -> None:
        dup = "## [Unreleased]\n\n### Added\n\n- Same. (#1)\n\n### Fixed\n\n- Same. (#1)\n"
        self.assertEqual(len(cu.duplicates(dup.splitlines(keepends=True))), 1)
        other = "## [2.0]\n\n- Same. (#1)\n\n## [1.0]\n\n- Same. (#1)\n"
        self.assertEqual(cu.duplicates(other.splitlines(keepends=True)), [])

    def test_diff3_and_unterminated_hunks_exit_2(self) -> None:
        self.assertEqual(
            run("<<<<<<< a\nx\n||||||| b\ny\n=======\nz\n>>>>>>> c\n")[0], 2
        )
        self.assertEqual(run("<<<<<<< a\nx\n=======\nz\n")[0], 2)


if __name__ == "__main__":
    unittest.main()
