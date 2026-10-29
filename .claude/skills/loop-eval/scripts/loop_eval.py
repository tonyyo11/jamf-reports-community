"""Score an SDD ledger: per-task rounds, reviews, verdicts, finding tags, suite result.

The ledger is free prose, one event per line. A line is attributed to a task by its leading
`Task <id>`, `Sweep <A|B>` or `fu-wave<N>`; everything else is counted as `other`. A task line
with no event this script knows is listed as unreadable, never fatal.

Going forward the ledger should use one line per event (see docs/superpowers/plans):
  Task <id>: <status> <commits>...
  Task <id> review (<reviewer>): <Approved|Needs fixes>; MUST-FIX n; SHOULD-FIX n; CONSIDER n
  Task <id> fix round <n>: ...
  Task <id>: complete ... full suite N/0

Usage: loop_eval.py LEDGER [--baseline JSON] [--wave NAME] [--json-out PATH] [--md-out PATH]
"""

from __future__ import annotations

import argparse
import json
import re
import statistics
import sys
from typing import Any
from dataclasses import asdict, dataclass, field
from pathlib import Path

ID = r"\d+(?:\.\d+)?(?:[+/\-]\d+(?:\.\d+)?)*|tick lane"
OWNER = re.compile(
    rf"^(?:Task\s+(?P<task>{ID})|Sweep\s+(?P<sweep>[AB])|(?P<fu>fu-wave\d+))\b"
)
ALIASES = {"tick lane": "1.8/1.7/1.16"}
ROUND = re.compile(r"\bround\s+(\d+)\b", re.I)
SUITE = re.compile(
    r"full suite\s+(\d+)(?:/(\d+))?|Executed\s+(\d+)\s+tests?,\s+with\s+(\d+)\s+failures?"
)
COMPLETE = re.compile(r"(?:^|[:.;]\s*)complete\b", re.I)
READ = re.compile(
    r"controller read the diff|read by the controller|controller read\b", re.I
)
VERDICT_WORDS = re.compile(r"approved|needs fixes|no must-fix|no blocking", re.I)
REVIEW_WORDS = re.compile(r"\b(?:re-?review|review|security)\b", re.I)
KNOWN = re.compile(
    r"dispatched|implemented|blocked|impl-|done|brief|ruling|deferred|round|complete|review|security|sweep",
    re.I,
)


@dataclass
class Review:
    kind: str  # review | re-review | security
    verdict: str  # approved | needs_fixes
    must: int
    should: int
    consider: int
    line: int


@dataclass
class Task:
    id: str
    completed: bool = False
    rounds_seen: set[int] = field(default_factory=set)
    rounds_at_complete: int | None = None
    reviews: list[Review] = field(default_factory=list)
    controller_reads: int = 0
    suite_tests: int | None = None
    suite_failures: int | None = None

    @property
    def rounds(self) -> int:
        if self.rounds_at_complete is not None:
            return self.rounds_at_complete
        return len(self.rounds_seen)


@dataclass
class Ledger:
    tasks: dict[str, Task] = field(default_factory=dict)
    unreadable: list[dict[str, Any]] = field(default_factory=list)
    other: int = 0
    lines: int = 0


def scrub(text: str, words: int = 6) -> str:
    """First few words with anything path-like replaced: safe to commit."""
    out = ["<path>" if re.search(r"[/~\\]", w) else w for w in text.split()[:words]]
    return " ".join(out)


def tag_count(line: str, tag: str) -> int:
    """`MUST-FIX 2` counts 2; otherwise one per mention, `no MUST-FIX` counts 0."""
    total = 0
    for m in re.finditer(rf"(?<![Nn]o )\b{tag}\b(?:\s+(\d+)\b)?", line):
        total += int(m.group(1)) if m.group(1) else 1
    return total


def review_of(line: str, no: int) -> Review | None:
    """A review verdict line names its reviewer up front: `review (...)`, `security (...)`."""
    head = REVIEW_WORDS.search(line[:40])
    if not head:
        return None
    must = tag_count(line, "MUST-FIX")
    should = tag_count(line, "SHOULD-FIX") + tag_count(line, "Important")
    consider = tag_count(line, "CONSIDER")
    if not (VERDICT_WORDS.search(line) or must or should or consider):
        return None
    low = line.lower()
    kind = "security" if re.search(r"security|\bsec-", low[:60]) else "review"
    if re.search(r"re-?review", low[:60]):
        kind = "re-review"
    # No explicit verdict (a security line that only lists tags): blocking means MUST-FIX.
    needs = "needs fixes" in low or (
        not re.search(r"approved|no blocking", low) and must > 0
    )
    if re.search(r"approved|no blocking", low) and "needs fixes" not in low:
        needs = False
    return Review(
        kind, "needs_fixes" if needs else "approved", must, should, consider, no
    )


def apply_line(task: Task, rest: str, no: int) -> bool:
    """Record every event on the line; False when it held none this script knows."""
    known = bool(KNOWN.search(rest))
    for m in ROUND.finditer(rest):
        if not task.completed:
            task.rounds_seen.add(int(m.group(1)))
    review = review_of(rest, no)
    if review:
        task.reviews.append(review)
    if READ.search(rest):
        task.controller_reads += 1
    suite = SUITE.search(rest)
    if suite and not task.completed:
        tests = suite.group(1) or suite.group(3)
        fails = suite.group(2) or suite.group(4)
        task.suite_tests = int(tests)
        task.suite_failures = int(fails) if fails is not None else None
    if COMPLETE.search(rest) and not task.completed:
        task.completed = True
        task.rounds_at_complete = len(task.rounds_seen)
    return known


def owner_of(line: str) -> tuple[str, str] | None:
    m = OWNER.match(line)
    if not m:
        return None
    if m.group("task"):
        key = m.group("task").lower()
        return ALIASES.get(key, key), line[m.end() :]
    if m.group("sweep"):
        return f"Sweep {m.group('sweep')}", line[m.end() :]
    return m.group("fu"), line[m.end() :]


def parse_ledger(text: str) -> Ledger:
    ledger = Ledger()
    for no, raw in enumerate(text.splitlines(), 1):
        line = raw.strip()
        if not line:
            continue
        ledger.lines += 1
        owned = owner_of(line)
        if owned is None:
            ledger.other += 1
            continue
        key, rest = owned
        task = ledger.tasks.setdefault(key, Task(key))
        if not apply_line(task, rest, no):
            ledger.unreadable.append({"line": no, "head": scrub(line)})
    return ledger


def median(values: list[int]) -> float:
    return float(statistics.median(values)) if values else 0.0


def summarize(ledger: Ledger, wave: str) -> dict[str, Any]:
    tasks = sorted(
        ledger.tasks.values(), key=lambda t: [p for p in re.split(r"(\d+)", t.id)]
    )
    done = [t for t in tasks if t.completed]
    reviews = [r for t in tasks for r in t.reviews]
    suites = [t.suite_tests for t in done if t.suite_tests is not None]
    totals = {
        "tasks": len(tasks),
        "completed": len(done),
        "rounds": sum(t.rounds for t in done),
        "reviews": len(reviews),
        "needs_fixes": sum(r.verdict == "needs_fixes" for r in reviews),
        "approved": sum(r.verdict == "approved" for r in reviews),
        "must": sum(r.must for r in reviews),
        "should": sum(r.should for r in reviews),
        "consider": sum(r.consider for r in reviews),
        "re_review_seats": sum(r.kind == "re-review" for r in reviews),
        "controller_reads": sum(t.controller_reads for t in tasks),
        "suite_tests_max": max(suites) if suites else 0,
    }
    medians = {
        "rounds": median([t.rounds for t in done]),
        "reviews": median([len(t.reviews) for t in tasks]),
        "must": median([sum(r.must for r in t.reviews) for t in tasks]),
        "should": median([sum(r.should for r in t.reviews) for t in tasks]),
    }
    return {
        "wave": wave,
        "ledger_lines": ledger.lines,
        "other_lines": ledger.other,
        "unreadable": ledger.unreadable,
        "totals": totals,
        "medians": medians,
        "tasks": [task_json(t) for t in tasks],
    }


def task_json(t: Task) -> dict[str, Any]:
    d = asdict(t)
    d.pop("rounds_seen")
    d.pop("rounds_at_complete")
    d["rounds"] = t.rounds
    return d


def task_table(summary: dict[str, Any]) -> str:
    head = "| Task | Done | Rounds | Reviews | Verdicts | MUST | SHOULD | CONSIDER | Re-review seats | Controller reads | Suite |"
    rows = [head, "|" + "---|" * 11]
    tasks = summary["tasks"]
    for t in tasks:
        rv = t["reviews"]
        verdicts = (
            ", ".join("A" if r["verdict"] == "approved" else "NF" for r in rv) or "-"
        )
        suite = "-"
        if t["suite_tests"] is not None:
            fails = t["suite_failures"]
            suite = f"{t['suite_tests']}/{fails if fails is not None else '?'}"
        seats = sum(r["kind"] == "re-review" for r in rv)
        rows.append(
            f"| {t['id']} | {'yes' if t['completed'] else 'no'} | {t['rounds']} | {len(rv)} | {verdicts} "
            f"| {sum(r['must'] for r in rv)} | {sum(r['should'] for r in rv)} "
            f"| {sum(r['consider'] for r in rv)} | {seats} | {t['controller_reads']} | {suite} |"
        )
    tot, med = summary["totals"], summary["medians"]
    rows.append(
        f"| **Total** | {tot['completed']}/{tot['tasks']} | {tot['rounds']} | {tot['reviews']} "
        f"| {tot['approved']} A, {tot['needs_fixes']} NF | {tot['must']} | {tot['should']} "
        f"| {tot['consider']} | {tot['re_review_seats']} | {tot['controller_reads']} | {tot['suite_tests_max']} |"
    )
    rows.append(
        f"| **Median** | | {med['rounds']:g} | {med['reviews']:g} | | {med['must']:g} | {med['should']:g} | | | | |"
    )
    return "\n".join(rows)


METRICS = [
    ("tasks", "Tasks seen"),
    ("completed", "Tasks completed"),
    ("rounds", "Fix rounds to completion (total)"),
    ("reviews", "Review verdicts"),
    ("must", "MUST-FIX tags"),
    ("should", "SHOULD-FIX tags"),
    ("consider", "CONSIDER tags"),
    ("re_review_seats", "Re-review seats"),
    ("controller_reads", "Controller read the diff"),
    ("suite_tests_max", "Largest suite at a completion"),
]


def delta_table(current: dict[str, Any], baseline: dict[str, Any]) -> str:
    cur, base = current["totals"], baseline.get("totals", {})
    rows = [
        f"Baseline: {baseline.get('wave', '?')}  ->  this run: {current['wave']}",
        "",
        "| Metric | Baseline | This run | Delta |",
        "|---|---|---|---|",
    ]
    for key, label in METRICS:
        b, c = base.get(key), cur.get(key)
        delta = f"{c - b:+d}" if isinstance(b, int) and isinstance(c, int) else "n/a"
        rows.append(f"| {label} | {b if b is not None else '-'} | {c} | {delta} |")
    for key in ("rounds", "should"):
        b = baseline.get("medians", {}).get(key)
        c = current["medians"][key]
        delta = f"{c - b:+g}" if isinstance(b, (int, float)) else "n/a"
        rows.append(
            f"| Median {key} per task | {b if b is not None else '-'} | {c:g} | {delta} |"
        )
    return "\n".join(rows)


def render(summary: dict[str, Any], baseline: dict[str, Any] | None) -> str:
    out = [f"# Loop eval: {summary['wave']}", "", task_table(summary), ""]
    unreadable = summary["unreadable"]
    out.append(
        f"Ledger lines: {summary['ledger_lines']}; not attributed to a task: {summary['other_lines']}; "
        f"task lines with no event this script reads: {len(unreadable)}"
    )
    out += [f"- line {u['line']}: {u['head']} ..." for u in unreadable]
    out.append("")
    out.append(
        "Tags are mentions in the review line (`MUST-FIX 2` counts 2; the older `Important` counts as SHOULD-FIX): a lower bound on findings."
    )
    if baseline is not None:
        out += ["", "## Against the baseline", "", delta_table(summary, baseline)]
    return "\n".join(out) + "\n"


def main(argv: list[str]) -> int:
    ap = argparse.ArgumentParser(description=(__doc__ or "").split("\n\n")[0])
    ap.add_argument("ledger", type=Path)
    ap.add_argument("--baseline", type=Path, help="JSON written by an earlier run")
    ap.add_argument("--wave", default="unnamed", help="label stored in the JSON")
    ap.add_argument(
        "--json-out", type=Path, help="default: loop-eval.json beside the ledger"
    )
    ap.add_argument("--md-out", type=Path, help="also write the markdown here")
    args = ap.parse_args(argv)
    try:
        text = args.ledger.read_text(errors="replace")
    except OSError as err:
        print(f"loop_eval: cannot read {args.ledger}: {err}", file=sys.stderr)
        return 2
    baseline = None
    if args.baseline:
        try:
            baseline = json.loads(args.baseline.read_text())
        except (OSError, ValueError) as err:
            print(
                f"loop_eval: cannot read baseline {args.baseline}: {err}",
                file=sys.stderr,
            )
            return 2
    summary = summarize(parse_ledger(text), args.wave)
    json_out = args.json_out or args.ledger.with_name("loop-eval.json")
    json_out.write_text(json.dumps(summary, indent=2) + "\n")
    md = render(summary, baseline)
    if args.md_out:
        args.md_out.write_text(md)
    print(md, end="")
    print(f"wrote {json_out}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
