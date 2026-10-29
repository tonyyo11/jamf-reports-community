---
name: class-sweep
description: List every sibling site of a seam a fix routes through, plus the twelve review-checklist class greps, as a checklist with a PR-body block. Use when fixing or reviewing a bug that bypasses a shared reader, validator, timeout, product gate, redactor, escape or calculator, before editing and again before the PR.
argument-hint: "[--changed BASE] [--limit N] [SEAM_REGEX]"
allowed-tools: Bash(${CLAUDE_SKILL_DIR}/scripts/class-sweep *), Bash(${CLAUDE_SKILL_DIR}/scripts/test-class-sweep)
---

# Class sweep

A fix that routes one site through a seam and leaves its siblings is incomplete: the same defect
class came back in every release from 2.8.0 to 2.11.0. This lists the siblings so none is missed.

1. Name the seam the broken site bypasses (the function or type that should have been used) and
   write an extended regex for it, for example `BoundedFile|confinedFolder`.
2. Run `${CLAUDE_SKILL_DIR}/scripts/class-sweep $ARGUMENTS`. In a review, pass `--changed BASE` so
   the class greps cover the files the diff touched; without it they cover all of `app/Sources`.
   Read-only: it writes nothing.
3. The output has the seam's sites (always complete), then classes 1 to 12 from
   `docs/superpowers/review-checklist.md` with the grep used, each hit as `- [ ] file:line ... —
   moved | left: why`. Classify every seam site: moved into this change, or left with a reason. A
   site left because it needs its own design is named with this grep in the epic, not dropped.
4. For each class hit in the diff, apply that class's question from the checklist. Most class
   greps list the places a seam is used: a new site that is missing from the list is the finding.
5. Paste the `PR body block` at the end into the PR and fill in the counts.

The greps are `grep -E` over `*.swift` (portable; no ripgrep needed). Class 5 is the checklist's own
command. The other classes grep the symbols the checklist names (calculators, product gates, the
honesty chain, redactors, escapes, demo guards), so they list the places that already use the
seam: a new site that is missing from the list is the one to examine.

Limits, stated plainly: this lists consumers of the seam, not bypasses. A bypass in a file that
never mentions the seam (a raw `Data(contentsOf:)` in a file that never names `BoundedFile`) shows
only through the class greps, which for most classes are the seam's own symbols. Open question, not
built: a `--bypass REGEX` option that lists the raw API calls the seam replaces in files that do not
mention the seam. It needs its own design (what counts as the raw call per seam).

Self-check: `${CLAUDE_SKILL_DIR}/scripts/test-class-sweep` (a throwaway repo; covers the default
`--limit` path, `--limit 0` and a bad `--limit`).
