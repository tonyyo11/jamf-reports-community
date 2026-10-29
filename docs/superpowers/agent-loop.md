# Agent loop: which work gets a subagent

How this app is built with subagent-driven development (SDD), after applying Anthropic's guidance on
folding subagents into the main agent loop and its single-agent-loop kit. The kit's audit and plan
formats are used here; its code is not. Changes to the loop are listed in
[agent-loop-plan.md](agent-loop-plan.md) and judged by the eval below.

## The rules

A subagent is worth its cost only when one of these holds:

1. **Parallel, fresh, discardable context.** Several pieces of work run at once and none needs the
   others' reading.
2. **Independent verification.** A result is checked by an agent that did not produce it and does
   not see how it was produced.
3. **Reads far more than the loop needs afterwards.** A long log, another repository, a web
   page set: the loop wants the conclusion, not the reading.

Otherwise the work stays in the main loop (the controller). The controller's reference material
sits behind skills: a skill's one-line description is always visible, its body loads when it is
invoked. A long prompt, many tools, a different owner or a fixed sequence of steps does not earn a
context of its own; a fixed sequence is a script.

- **Divide by context, not by role.** Give a subagent a piece that needs little from the rest and
  take back a compact result. Never build a pipeline of specialists that pass the same data along;
  each hand-off loses some of it.
- **Verify the conclusion in the main loop.** Read the diff, run the suite, open the artifact.
  A report is a claim, not evidence.
- **One change per measured run.** Change the loop one thing at a time, score it (below), keep what
  helps. Keeping a subagent is a fine outcome.
- **Keep the always-visible list small.** Skills and tools are grouped by intent; a skill nobody
  invokes is removed.

## The audit

Verdicts use the kit's words: `main` (the controller), `fold` (into the main loop, as a skill or
script), `as-tool` (keeps its own context, called for one bounded job, returns a compact result).
`keep` in the kit means an agent that must hold the conversation itself; none here does, so every
subagent that stays is `as-tool`. The numbers come from the wave 0 to 6 ledger (see
[the baseline](agent-loop-eval/2026-10-28-waves-0-6.md)): 28 tasks seen, 24 completed, 40 fix rounds, 39
review verdicts.

| Role | What it reads | What it returns | Calls per task | Verdict | Reason |
|---|---|---|---|---|---|
| Controller (main loop) | Ledger, briefs, reports, diffs, CI logs | Briefs, rulings, ledger lines, PRs | 1 session | `main` | Directs the others; briefs, fix-round composition, rulings and the ledger stay here. |
| Implementer (Sonnet; Opus for 2.1–2.3, 3.4, 5.2, hard debugging) | Task row, spec section, checklist, its worktree | Status, commits, counts; the report file is the hand-off | 1 dispatch, then one message per fix round (40 rounds over 24 completed tasks) | `as-tool` | Parallel, fresh context in its own worktree, discardable; the controller needs the result, not the reading. |
| Task reviewer (Sonnet `reviewer`) | Brief, report, review package (4 KB to 376 KB across 48 packages) | Verdict, tagged findings with checklist numbers | 1 first review (24 reviewer verdicts across 28 tasks) | `as-tool` | Independent verification of a diff the controller did not write. |
| Security reviewer (Opus `security-reviewer`) | Same, through the security lens | Verdict, MUST-FIX / SHOULD-FIX / CONSIDER | 1 for anything that reads or writes workspace files, adds a product gate or sends data out (8 verdicts) | `as-tool` | Independent verification where a miss is expensive; the stronger model is for this seat only. |
| Scoped re-review of a fix round, large or touching a seam | FIX_BASE..head package, report | Verdict on the fix | 0 or 1 per fix round (7 re-review seats) | `as-tool` | Above the threshold below the controller cannot verify it as cheaply as a fresh reader. |
| Scoped re-review of a small, plain fix round | The same | The same | Was 1 per fix round | `fold` | Under about 150 changed source lines, no new seam, file write path or product gate: the controller reads the diff and the report (8 rounds were confirmed by the controller as closed that way, 11 by ledger phrase; the controller's account is that none missed a defect). |
| Research or comparison agent (web pages, another repository, a long log) | Far more than the loop needs | A compact findings file | 0 to 2 per wave | `as-tool` | Reads far more than the loop needs afterwards. |
| Review packaging | `git log`, `git diff -U10` | One file per range | 1 per review | `fold` (skill `review-package`) | Deterministic; was retyped shell each time. |
| Class-sibling grep | The twelve checklist classes plus a seam regex | Sites grouped by class | 1 per fix or review | `fold` (skill `class-sweep`) | Deterministic; the checklist's greps were retyped, and one used the wrong flag (`rg -E`). |
| CHANGELOG conflict union | A conflicted CHANGELOG.md | Section-aware union and two checks | 1 per merge conflict (9 in one stack build) | `fold` (skill `changelog-union`) | Deterministic; orphan continuation lines and a duplicated bullet both survived a hand merge once. |
| Wave bundling | Task branches, base ref | A bundle branch in a new worktree | 1 per wave bundle | `fold` (skill `bundle-wave`) | Deterministic merge loop. |
| Stack adoption and cascade | Branches, local and origin heads | A `gh stack` | 1 per stack | `fold` (skill `stack-adopt`, person-started) | Deterministic; rewrites local branches, so only the operator starts it. |
| Tip test from local disk | A ref | Executed and Swift Testing totals, exit codes | 1 per gate | `fold` (skill `tip-test`) | Deterministic; an iCloud-synced checkout fails the xctest codesign step, so the folder choice is encoded. |
| Ship a tree to a CI-parity VM | A ref or folder | Build and test totals | 1 per isolation- or AppKit-sensitive change | `fold` (personal skill `vm-test`) | Deterministic; VM names and paths are machine-specific, so it is not in this repository. |
| Eval | The ledger | A table and JSON | 1 per wave | `fold` (skill `loop-eval`) | Deterministic. |

The fold threshold for re-reviews is a rule, not a preference: the controller decides from the diff
stat (`git diff --shortstat FIX_BASE..HEAD -- app/Sources`) and records "controller read the diff"
in the ledger line. If it finds a defect while reading, it dispatches the re-review.

## The skills

Project skills live in `.claude/skills/` (tracked despite the ignored `.claude/`).

| Skill | Use |
|---|---|
| `review-package PLAN BASE HEAD` | One review file per range under `.superpowers/sdd/<plan>/`. |
| `class-sweep [--changed BASE] SEAM_REGEX` | Sibling sites of a seam plus the twelve class greps, with the PR-body block. |
| `changelog-union CHANGELOG.md` | Union-resolve a CHANGELOG conflict, then check orphans and duplicates. |
| `bundle-wave BUNDLE BASE BRANCH...` | Merge task branches into a bundle in a new worktree; never pushes. |
| `stack-adopt BRANCH...` | Adopt branches into a `gh stack`; person-started; never submits. |
| `tip-test REF` | Build and test a ref from a local-disk worktree; prints the totals. |
| `loop-eval LEDGER` | Score a ledger; compare with a baseline. |

Scripts are zsh (the changelog union and the eval are Python: they parse structure). Each script
that would write to git or GitHub has `--dry-run`; none pushes, merges to a shared branch or opens a
PR.

## The eval

The loop is judged on numbers the ledger already records, per task:

- **Rounds to approval:** fix rounds before the task's `complete` line.
- **Reviews and verdicts:** each review (reviewer, security, re-review) with Approved or Needs
  fixes, and its MUST-FIX, SHOULD-FIX and CONSIDER tags.
- **Re-review seats and controller reads:** how many re-reviews were dispatched, and how many fix
  rounds the controller read itself.
- **Full-suite result at completion:** the `Executed N tests` or `N/0` figure.
- **First-push CI result:** per PR, the first `CI <PR>:` ledger line (passed or failed, and the jobs it names); later lines for the same PR are follow-ups. The metric is `ci_first_push`.

`loop-eval` reads these from the ledger (`.superpowers/sdd/<plan>/progress.md`). The ledger is
prose; the parser is tolerant (a line it cannot read is counted and listed) and the plan's SDD
section gives the line format to use from now on.

**Baseline, waves 0 to 6** (ledger of 173 lines, 2026-10-29; the full table and JSON are in
[agent-loop-eval](agent-loop-eval/2026-10-28-waves-0-6.md)): 28 tasks seen, 24 complete; 40 fix
rounds (median 2 per completed task; 2 tasks needed none, 7 one, 12 two, 3 three); 39 review
verdicts (14 Approved, 25 Needs fixes: 24 reviewer, 8 security, 7 re-review); tags 6 MUST-FIX, 25
SHOULD-FIX, 24 CONSIDER; fix rounds read by the controller instead of re-reviewed: 8 confirmed by
the controller, 11 by ledger phrase; the 35 full-suite counts recorded rose from 6845 to 6962
tests with 0 failures in every one (6957 at the last completion); first-push CI: 3 PRs with a
`CI` line (#341, #351, #352), all failed on the first push (a test asserting a folder that a
refused run no longer creates, a lock test that failed on the macOS 15 job only, and a Swift 6.1
isolation error), 0 passed. Tags are mentions in the review line, so they are a lower bound on
findings; the ledger has no verdict line for a few early reviews (visible as a task with no
reviews in the table). The baseline reads the first 173 non-blank ledger lines, which is the wave
0 to 6 state; the ledger has grown since.

**The rule for the next wave.** Score it with the same skill and compare with `--baseline`:

```
loop-eval <next ledger> --wave <name> --baseline docs/superpowers/agent-loop-eval/2026-10-28-waves-0-6.json
```

A loop change (a folded seat, a new skill, a changed threshold) is judged on that delta, one change
per wave, so a movement can be attributed. Rounds, MUST-FIX and SHOULD-FIX should not rise while
re-review seats fall; if they rise, restore the seat and note it in the plan. Waves differ in size
and difficulty, so read medians and per-task rows before a total.

## Upkeep

- Re-run this audit when the model changes or a wave's numbers move against the baseline. Remove a
  skill nobody invoked in two waves.
- A skill's description is its only always-visible text: say when to use it, first. Keep every
  `SKILL.md` short; scripts do the work.
- When a recurring controller step is typed by hand twice, it is a candidate skill; when a subagent
  seat adds no verification the controller could not do from the diff, it is a candidate fold.
