"""Resolve git conflict hunks in CHANGELOG.md as a section-aware union, then check the result.

Each hunk becomes one list of bullets per `### Added/Changed/Fixed/Removed/Security/Dependencies`
header, HEAD's bullets first, identical bullets once. The checks find what a union leaves behind:
conflict markers, continuation lines after a bullet that already ended in `(#NNN)`, a bullet
that appears twice in one release section, and a `###` header repeated in Unreleased.

Usage: changelog_union.py [--dry-run] [--check] CHANGELOG.md
Exit: 0 clean, 1 findings, 2 usage or unresolvable input.
"""

from __future__ import annotations

import argparse
import re
import sys
from collections.abc import Sequence
from pathlib import Path

ORDER = [
    "### Added",
    "### Changed",
    "### Fixed",
    "### Removed",
    "### Security",
    "### Dependencies",
]
PR_END = re.compile(r"\(#\d+\)\.?\s*$")
Bullet = list[str]


def parse(lines: list[str]) -> tuple[list[str], dict[str, list[str]]]:
    """Split a hunk side into the lines before its first `###` header and the sections."""
    sections: dict[str, list[str]] = {}
    pre: list[str] = []
    cur: str | None = None
    for ln in lines:
        if ln.startswith("### "):
            cur = ln.rstrip()
            sections.setdefault(cur, [])
        elif cur is None:
            pre.append(ln)
        else:
            sections[cur].append(ln)
    return pre, sections


def bullets(body: list[str]) -> list[Bullet]:
    """Group lines into bullets: a `- ` line plus the non-blank lines that follow it."""
    out: list[Bullet] = []
    cur: Bullet = []
    for ln in body:
        if ln.startswith("- "):
            if cur:
                out.append(cur)
            cur = [ln]
        elif ln.strip() == "":
            if cur:
                out.append(cur)
                cur = []
        else:
            cur.append(ln)
    if cur:
        out.append(cur)
    return out


def unique(items: list[Bullet]) -> list[Bullet]:
    seen: set[str] = set()
    out: list[Bullet] = []
    for it in items:
        key = "\n".join(x.rstrip() for x in it)
        if key not in seen:
            seen.add(key)
            out.append(it)
    return out


def render(items: list[Bullet]) -> list[str]:
    return [ln if ln.endswith("\n") else ln + "\n" for it in items for ln in it]


def merge(head: list[str], incoming: list[str]) -> list[str]:
    """Union of two hunk sides: loose bullets first, then one block per header."""
    pa, sa = parse(head)
    pb, sb = parse(incoming)
    known = [h for h in ORDER if h in sa or h in sb]
    extra = [h for h in dict.fromkeys([*sa, *sb]) if h not in ORDER]
    out = render(unique(bullets(pa) + bullets(pb)))
    for h in known + extra:
        if out and out[-1].strip():
            out.append("\n")
        out += [h + "\n", "\n"]
        out += render(unique(bullets(sa.get(h, [])) + bullets(sb.get(h, []))))
    return out


def resolve(lines: list[str]) -> tuple[list[str], int]:
    """Replace every conflict hunk in `lines` with its union; return the lines and the count."""
    res: list[str] = []
    i = n = 0
    while i < len(lines):
        if not lines[i].startswith("<<<<<<< "):
            res.append(lines[i])
            i += 1
            continue
        head: list[str] = []
        incoming: list[str] = []
        side = head
        i += 1
        while i < len(lines) and not lines[i].startswith(">>>>>>> "):
            if lines[i].startswith("||||||| "):
                raise ValueError(
                    "diff3 conflict style (|||||||); re-run with merge.conflictStyle=merge"
                )
            if lines[i].startswith("======="):
                side = incoming
            else:
                side.append(lines[i])
            i += 1
        if i >= len(lines):
            raise ValueError("unterminated conflict hunk (no >>>>>>> line)")
        i += 1
        res += merge(head, incoming)
        n += 1
        if i < len(lines) and lines[i].startswith("#") and res and res[-1].strip():
            res.append("\n")
    return res, n


def collapse_blank_runs(lines: list[str]) -> list[str]:
    out: list[str] = []
    blank = 0
    for ln in lines:
        blank = blank + 1 if ln.strip() == "" else 0
        if blank <= 1:
            out.append(ln)
    return out


MARKER = re.compile(r"^(<<<<<<< |=======$|>>>>>>> |\|\|\|\|\|\|\| )")


def orphans(lines: Sequence[str]) -> list[str]:
    """Lines continuing a bullet that already ended in `(#NNN)`: what a bad union leaves behind."""
    findings: list[str] = []
    in_bullet = ended = False
    for no, raw in enumerate(lines, 1):
        ln = raw.rstrip("\n")
        if ln.startswith("- "):
            in_bullet, ended = True, bool(PR_END.search(ln))
        elif not ln.strip() or ln.startswith("#"):
            in_bullet = ended = False
        elif in_bullet and ended and not ln.lstrip().startswith("- "):
            findings.append(
                f"line {no}: orphan continuation after a bullet that ended at (#NNN)"
            )
        elif in_bullet:
            ended = bool(PR_END.search(ln))
    return findings


def duplicates(lines: Sequence[str]) -> list[str]:
    """Bullets with identical text (whitespace collapsed) in one `## ` release section."""
    findings: list[str] = []
    seen: dict[tuple[str, str], int] = {}
    section = ""
    text: list[str] = []
    first = 0

    def flush() -> None:
        if not text:
            return
        key = (section, " ".join(" ".join(text).split()))
        if key in seen:
            findings.append(
                f"line {first}: duplicate of the bullet on line {seen[key]}"
            )
        else:
            seen[key] = first

    for no, raw in enumerate(lines, 1):
        ln = raw.rstrip("\n")
        if ln.startswith("- "):
            flush()
            text, first = [ln], no
        elif ln.startswith("#") or not ln.strip():
            flush()
            text = []
            if ln.startswith("## "):
                section = ln
        elif text:
            text.append(ln)
    flush()
    return findings


def repeated_headers(lines: Sequence[str]) -> list[str]:
    """A `### ` header twice in the Unreleased section: a hunk whose header sat outside it.

    Released sections are left alone; some old ones repeat a header on purpose.
    """
    findings: list[str] = []
    seen: dict[str, int] = {}
    unreleased = False
    for no, raw in enumerate(lines, 1):
        ln = raw.rstrip("\n")
        if ln.startswith("## "):
            unreleased = ln.lower().startswith("## [unreleased]")
            seen = {}
        elif unreleased and ln.startswith("### "):
            if ln in seen:
                findings.append(
                    f"line {no}: {ln} repeats the header on line {seen[ln]}"
                )
            seen.setdefault(ln, no)
    return findings


def check(lines: Sequence[str]) -> list[str]:
    """Findings as `line N: message`; empty when the file is clean."""
    markers = [
        f"line {no}: conflict marker left in the file"
        for no, ln in enumerate(lines, 1)
        if MARKER.match(ln)
    ]
    return markers + orphans(lines) + duplicates(lines) + repeated_headers(lines)


def main(argv: list[str]) -> int:
    ap = argparse.ArgumentParser(description=(__doc__ or "").split("\n\n")[0])
    ap.add_argument("file", type=Path)
    ap.add_argument(
        "--dry-run", action="store_true", help="resolve in memory, write nothing"
    )
    ap.add_argument("--check", action="store_true", help="only run the checks")
    args = ap.parse_args(argv)
    try:
        text = args.file.read_text()
    except OSError as err:
        print(f"changelog_union: cannot read {args.file}: {err}", file=sys.stderr)
        return 2
    lines = text.splitlines(keepends=True)
    hunks = 0
    if not args.check:
        try:
            lines, hunks = resolve(lines)
        except ValueError as err:
            print(f"changelog_union: {args.file}: {err}", file=sys.stderr)
            return 2
        if hunks:
            lines = collapse_blank_runs(lines)
            if not args.dry_run:
                args.file.write_text("".join(lines))
        verb = "would resolve" if args.dry_run else "resolved"
        print(f"{verb} {hunks} hunk(s) in {args.file}")
    findings = check(lines)
    for f in findings:
        print(f"{args.file}: {f}")
    if findings:
        print(f"{len(findings)} finding(s)")
        return 1
    print(
        "checks clean: no conflict markers, orphan continuations, duplicate bullets or headers"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
