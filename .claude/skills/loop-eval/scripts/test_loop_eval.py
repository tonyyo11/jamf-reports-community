"""Self-check for loop_eval.py on the synthetic fixture. Run: python3 test_loop_eval.py"""

import json
import tempfile
import unittest
from pathlib import Path

import loop_eval as le

FIXTURE = Path(__file__).resolve().parent.parent / "fixtures" / "ledger-excerpt.md"


class ParseTests(unittest.TestCase):
    def setUp(self) -> None:
        self.ledger = le.parse_ledger(FIXTURE.read_text())
        self.tasks = self.ledger.tasks

    def test_tasks_found(self) -> None:
        self.assertEqual(
            sorted(self.tasks), ["9.1", "9.2", "9.3", "9.4", "9.6", "Sweep A"]
        )

    def test_rounds_reviews_and_tags(self) -> None:
        t = self.tasks["9.1"]
        self.assertEqual((t.completed, t.rounds), (True, 1))
        self.assertEqual([r.verdict for r in t.reviews], ["needs_fixes", "approved"])
        self.assertEqual([r.kind for r in t.reviews], ["review", "re-review"])
        first = t.reviews[0]
        self.assertEqual((first.must, first.should, first.consider), (1, 1, 1))
        self.assertEqual((t.suite_tests, t.suite_failures), (104, 0))

    def test_explicit_counts_and_no_must_fix(self) -> None:
        review = self.tasks["9.3"].reviews[0]
        self.assertEqual((review.must, review.should, review.consider), (2, 3, 1))
        security = self.tasks["9.2"].reviews[1]
        self.assertEqual(
            (security.kind, security.verdict, security.must),
            ("security", "approved", 0),
        )

    def test_controller_read_and_suite_frozen_at_complete(self) -> None:
        t = self.tasks["9.2"]
        self.assertEqual(t.controller_reads, 1)
        self.assertEqual(
            t.suite_tests, 110, "the figure on the complete line itself is not required"
        )

    def test_the_documented_line_format_parses(self) -> None:
        t = self.tasks["9.6"]
        self.assertEqual((t.completed, t.rounds, t.controller_reads), (True, 1, 1))
        self.assertEqual(
            [(r.kind, r.verdict) for r in t.reviews],
            [("review", "needs_fixes"), ("re-review", "approved")],
        )
        self.assertEqual((t.reviews[0].should, t.reviews[0].consider), (2, 1))
        self.assertEqual((t.suite_tests, t.suite_failures), (200, 0))

    def test_unreadable_and_other_lines_are_counted_not_fatal(self) -> None:
        self.assertEqual([u["line"] for u in self.ledger.unreadable], [17])
        self.assertEqual(self.ledger.other, 6)

    def test_unreadable_head_is_scrubbed(self) -> None:
        self.assertEqual(le.scrub("Task 1 ~/a/b and /x/y"), "Task 1 <path> and <path>")


class OutputTests(unittest.TestCase):
    def test_json_and_baseline_delta(self) -> None:
        summary = le.summarize(le.parse_ledger(FIXTURE.read_text()), "fixture")
        self.assertEqual(summary["totals"]["completed"], 4)
        base = json.loads(json.dumps(summary))
        base["totals"]["rounds"] = 5
        md = le.render(summary, base)
        self.assertIn("| Fix rounds to completion (total) | 5 | 3 | -2 |", md)

    def test_cli_writes_json_and_survives_binary_noise(self) -> None:
        with tempfile.TemporaryDirectory() as d:
            ledger = Path(d) / "progress.md"
            ledger.write_bytes(
                FIXTURE.read_bytes() + b"\xff\xfe Task 9.5 review: Approved\n"
            )
            self.assertEqual(le.main([str(ledger), "--wave", "w"]), 0)
            data = json.loads((Path(d) / "loop-eval.json").read_text())
            self.assertEqual(data["wave"], "w")
            self.assertEqual(le.main([str(Path(d) / "missing.md")]), 2)


if __name__ == "__main__":
    unittest.main()
