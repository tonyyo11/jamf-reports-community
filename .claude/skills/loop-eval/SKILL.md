---
name: loop-eval
description: Score a subagent-driven-development ledger (rounds to approval, reviews and verdicts, MUST-FIX/SHOULD-FIX/CONSIDER tags, suite counts, re-review seats and controller reads) into a markdown table and JSON, and compare it with a baseline JSON. Use at the end of a wave to judge a change to the agent loop on its delta.
argument-hint: "LEDGER [--baseline JSON] [--wave NAME] [--json-out PATH] [--md-out PATH]"
allowed-tools: Bash(python3 -I ${CLAUDE_SKILL_DIR}/scripts/loop_eval.py *)
---

# Loop eval

The eval for `docs/superpowers/agent-loop.md`. Run
`python3 -I ${CLAUDE_SKILL_DIR}/scripts/loop_eval.py $ARGUMENTS` with the ledger path
(`.superpowers/sdd/<plan>/progress.md`).

- Output: a table with one row per task (done, fix rounds before its `complete` line, reviews and
  verdicts A/NF, MUST/SHOULD/CONSIDER tags, re-review seats, controller reads, suite figure), totals
  and medians, the first-push CI result per PR (`ci_first_push`, from `CI <PR>:` lines), and the
  lines it could not read. The same data goes to `--json-out` (default
  `loop-eval.json` beside the ledger).
- `--baseline FILE` adds a table of deltas for the totals against an earlier JSON. The committed
  baseline is `docs/superpowers/agent-loop-eval/2026-10-28-waves-0-6.json`.
- Score the next wave with this skill and compare with `--baseline`; judge a loop change on that
  delta, one change per wave.
- Tolerant by design: a line with no event it knows is counted and listed, never a crash. Tags are
  counted as mentions in the review line (a number after the tag counts as that many), so the
  totals are a lower bound on findings, and the older word `Important` counts as SHOULD-FIX.
- Ledger lines it reads best are listed in the plan's SDD section: one line per event, starting
  `Task <id>`, `review (<reviewer>)`, `fix round <n>`, `complete`, `full suite N/0`.

Self-check: `python3 ${CLAUDE_SKILL_DIR}/scripts/test_loop_eval.py` (uses `fixtures/ledger-excerpt.md`).
