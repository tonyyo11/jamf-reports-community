---
name: stack-adopt
description: Adopt finished, pushed branches into one gh stack in order, clearing finished worktrees and iCloud duplicate files first and resolving CHANGELOG-only conflicts in the cascading rebase. Use only when the operator asks to build or extend a stack; it rewrites local branches. Never submits.
argument-hint: "[--dry-run] BRANCH..."
disable-model-invocation: true
allowed-tools: Bash(${CLAUDE_SKILL_DIR}/scripts/stack-adopt *)
---

# Stack adopt

Needs `gh` with the `gh-stack` extension (gh 2.90 or later) and `trash`. Run it from the main
checkout, never from inside a worktree it will remove. Branches are given bottom first.

Run `--dry-run` first: `${CLAUDE_SKILL_DIR}/scripts/stack-adopt --dry-run $ARGUMENTS`. Then, with
the operator's go-ahead, the same without `--dry-run`. The sequence:

1. Each branch's local head must equal `origin/<branch>`; otherwise it stops and names both SHAs
   (`gh stack add` rebases, so an unpushed commit would be rewritten away from its PR).
2. Untracked iCloud duplicates (` 2.swift`, ` 2.md`) in the checkout are moved to the Trash with
   `trash`; a tracked file with that name is reported and left.
3. Each branch's finished worktree is removed with `git worktree remove --force`, but only after it
   shows no uncommitted or untracked files; a dirty one stops the run.
4. `gh stack top`, `gh stack add` per branch in order, then `gh stack rebase --no-trunk` in a loop:
   a conflict only in CHANGELOG.md goes through changelog-union, `git add`, `gh stack rebase
   --continue`; any other conflict stops and names the files (`gh stack rebase --abort` restores
   every branch).
5. `gh stack view`.

It never runs `gh stack submit`. After it: run the full suite from a local-disk worktree at the
stack tip (tip-test skill), then `gh stack submit --auto` once the operator approves. If GitHub
refuses a base mid-sync, retarget that PR by hand with `gh pr edit NUMBER --base BRANCH`.
