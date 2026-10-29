---
name: tip-test
description: Build and test a ref (a stack tip, bundle branch or PR head) from a detached worktree on a local disk, print the Executed N tests and Swift Testing totals with exit codes, and remove the worktree. Use for the full-suite gate before a PR, merge or stack submit, or with --filter for one suite.
argument-hint: "[--dry-run] [--dir DIR] [--filter PATTERN] REF"
allowed-tools: Bash(${CLAUDE_SKILL_DIR}/scripts/tip-test *)
---

# Tip test

Run `${CLAUDE_SKILL_DIR}/scripts/tip-test $ARGUMENTS`. It adds a detached worktree at `REF`, runs
`swift build --build-tests` then `swift test` (or `swift test --filter PATTERN`) in `app/`, prints
the last `Executed N tests, with F failures` line and the Swift Testing `Test run with N tests`
line, both exit codes and the log path, and removes the worktree on the way out. Exit 0 only when
both steps passed. A full cold run takes minutes; a filtered run is for checking the script or one
suite. Run only one `swift test` at a time on a Mac.

- The worktree folder (`--dir`, default `$HOME/jr-worktrees/stack-tip`) must not exist and must be
  on a local disk: a checkout inside an iCloud-synced folder fails the xctest codesign step, so
  `Mobile Documents` and `CloudStorage` paths are refused.
- Report the printed counts as they are ("6877 XCTest, 0 failures; 72 Swift Testing"). A filter
  run prints no Swift Testing line, and the script says so.
- CI pins older Xcode versions than the host. For changes touching actor isolation or AppKit, also
  run the CI-parity VM check (the personal `vm-test` skill, where it exists) before pushing.
- `--dry-run` checks the ref and folder, prints the plan and creates nothing.
