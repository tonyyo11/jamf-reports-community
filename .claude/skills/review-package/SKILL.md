---
name: review-package
description: Write one review package file (commit list, stat, git diff -U10) for a task's recorded BASE..HEAD range, ready to hand a reviewer in a single read. Use before dispatching a reviewer or re-reviewer, or when the controller reviews a small fix diff itself.
argument-hint: "[--dry-run] PLAN_FILE BASE HEAD [OUTFILE]"
allowed-tools: Bash(${CLAUDE_SKILL_DIR}/scripts/review-package *)
---

# Review package

A reviewer reads one file instead of re-deriving the range. Use the task's recorded BASE, never
`HEAD~1`, so a multi-commit task stays whole.

Run `${CLAUDE_SKILL_DIR}/scripts/review-package $ARGUMENTS`.

- `PLAN_FILE` is the plan the task belongs to, for example
  `docs/superpowers/plans/2026-10-28-2-12-0-plan.md`. Its basename (without `.md`) names the
  folder `.superpowers/sdd/<plan>/` under the repo root, which is git-ignored.
- The file is named `review-<base7>..<head7>.diff`, so a re-review after a fix round (new HEAD, or
  FIX_BASE as BASE for a scoped re-review) gets a fresh file and never reuses a stale one.
- `--dry-run` prints the path, commit count and file count and writes nothing.
- The output is the file path and its size. Put that path in the reviewer's brief; do not paste the
  diff into the prompt.

When the reviewer is the controller (a fix diff under about 150 changed source lines that adds no
seam, file write path or product gate; see `docs/superpowers/agent-loop.md`), read the file and the
implementer's report yourself, and record "controller read the diff" in the ledger line.
