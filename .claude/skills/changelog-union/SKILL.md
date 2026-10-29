---
name: changelog-union
description: Resolve a CHANGELOG.md merge or rebase conflict as a section-aware union, then check for leftover conflict markers, orphan continuation lines after a bullet ending in a PR number, duplicate bullets and a repeated Unreleased header. Use whenever git reports a conflict in CHANGELOG.md, and after any hand edit of it in a merge.
argument-hint: "[--dry-run] [--check] CHANGELOG.md"
allowed-tools: Bash(python3 -I ${CLAUDE_SKILL_DIR}/scripts/changelog_union.py *)
---

# Changelog union

Parallel task branches each add bullets under the same `### Added/Changed/Fixed` headers in
`## [Unreleased]`, so every merge or rebase conflicts in CHANGELOG.md. The right resolution is the
union of both sides, not a pick.

Run `python3 -I ${CLAUDE_SKILL_DIR}/scripts/changelog_union.py $ARGUMENTS` from the repo root, with
`CHANGELOG.md` as the file.

- Each conflict hunk becomes one bullet list per header (Added, Changed, Fixed, Removed, Security,
  Dependencies, in that order), HEAD's bullets first, a bullet that is identical on both sides
  once. Loose bullets above a hunk's first header stay above it. A wrapped bullet moves whole.
- `--dry-run` resolves in memory and reports; `--check` only checks and resolves nothing.
- Checks (also run after resolving): a conflict marker left in the file; a continuation line after
  a bullet that already ended in `(#NNN)` (what a bad union leaves behind); the same bullet twice in
  one `## ` section; a `###` header twice in Unreleased (a hunk whose header sat outside it).
- Exit 0 clean, 1 findings (fix them by hand, they are listed with line numbers), 2 for a diff3
  conflict style or an unterminated hunk (re-run with `merge.conflictStyle=merge`).

After exit 0: `git add CHANGELOG.md` and continue the merge or rebase. After exit 1, fix the
listed lines first. The script never stages, commits or continues anything.

Self-check: `python3 ${CLAUDE_SKILL_DIR}/scripts/test_changelog_union.py`.
