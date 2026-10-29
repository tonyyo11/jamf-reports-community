---
name: bundle-wave
description: Merge finished task branches into one bundle branch in a new worktree, with CHANGELOG-only conflicts resolved by changelog-union, then list the bullets the bundle adds. Use when several approved task PRs should land as one PR (a wave bundle) instead of a long chain. Never pushes or opens the PR.
argument-hint: "[--dry-run] --dir DIR BUNDLE_BRANCH BASE_REF BRANCH..."
allowed-tools: Bash(${CLAUDE_SKILL_DIR}/scripts/bundle-wave *)
---

# Bundle wave

Run `${CLAUDE_SKILL_DIR}/scripts/bundle-wave $ARGUMENTS`.

- `BASE_REF` is what the bundle branches from (for example `origin/dev/2-12-0`); each `BRANCH` is a
  pushed branch, merged `--no-ff` in the order given. Order them so the branch with the most
  overlap goes first.
- Start with `--dry-run`: it fetches, checks every ref and predicts each merge against the base
  (`git merge-tree`). The prediction is per branch against the base alone, so a conflict between two
  of the branches shows only in the real run.
- The worktree goes to `--dir`, which is required (it outlives the run, so there is no temp-folder
  default). Keep it on a local disk: a build in an iCloud-synced folder fails the xctest codesign
  step. Paths under Mobile Documents or CloudStorage are refused.
- A conflict only in `CHANGELOG.md` is resolved by the changelog-union script, staged and committed
  with the merge message. Any other conflict stops the run and names the files; resolve in the
  worktree, commit, and merge the remaining branches by hand (`git merge --abort` abandons one).
- At the end it prints the first line of each bullet the bundle adds to CHANGELOG.md relative to
  the base, to check against the PR bodies.

Then, by hand: run the full suite from the worktree (tip-test skill), push the branch, open the PR.
The script does none of those; opening a PR is the operator's call.
