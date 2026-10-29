# Agent loop plan

One row per change to the subagent-driven-development loop, in the order made. The audit and the
rules are in [agent-loop.md](agent-loop.md). A change is judged on the next wave's
[loop-eval](agent-loop.md#the-eval) delta against the baseline, one change per wave; the result
column is filled in from that delta and a reverted change keeps its row.

Audit date: 2026-10-29. Baseline: waves 0 to 6, [table](agent-loop-eval/2026-10-28-waves-0-6.md)
and [JSON](agent-loop-eval/2026-10-28-waves-0-6.json).

## Status

- [x] Verdicts written (agent-loop.md, "The audit").
- [x] Eval defined and baseline measured (`loop-eval`, waves 0 to 6).
- [ ] Verdicts agreed after the first wave scored with the eval.

## Changes

| # | Change | Verdict it applies | Status | Measured result |
|---|---|---|---|---|
| 1 | Skills `review-package`, `class-sweep`, `changelog-union`, `bundle-wave`, `stack-adopt`, `tip-test` replace retyped shell | `fold` | Landed with this plan | Pending: next wave. Expect no change in rounds or findings; the check is that no step was typed by hand and no flag error recurs. |
| 2 | `loop-eval` and the committed baseline | `fold` (eval) | Landed | Baseline taken; first comparison is the next wave. |
| 3 | Scoped re-review of a small, plain fix round (under about 150 changed source lines, no new seam, file write path or product gate) becomes a controller read | `fold` | Rule written; 11 rounds in the baseline were already handled this way | Pending: re-review seats should stay at or below the baseline's 7 while rounds, MUST-FIX and SHOULD-FIX do not rise. |
| 4 | Ledger line format (one line per event) so the eval parses cleanly | n/a | Written in the plan's SDD section | Pending: next ledger reports no unreadable task lines. |
| 5 | Personal `vm-test` skill (not in this repository) | `fold` | Written; checked against a stub `tart` only | Pending: first real VM run. |

## Break map

What this loop could get wrong, and what would notice it.

| What could break | What would notice it |
|---|---|
| A folded re-review misses a defect | A later review of the same layer or CI finds it; the eval's MUST-FIX and SHOULD-FIX medians rise. Restore the seat. |
| A skill script gives a wrong answer | Its dry run and the controller's reading of the output; the class greps list sites and do not decide. |
| A class grep misses a sibling | The reviewer's own pass over the checklist; a finding of a known class in review. |
| The ledger drifts from the parser's format | `loop-eval` lists the lines it could not read. |

## Open questions

- Whether the 150-line threshold is right: it comes from one wave's experience (eight to eleven
  small rounds, no miss recorded). Move it only on the next wave's numbers.
- Whether `class-sweep` should grow a per-class "new site not in the list" check from the diff
  rather than a list of existing sites. Needs its own design.

## Left as it is, and why

- Implementer, task reviewer, security reviewer, research agents: each meets one of the three tests
  (parallel fresh context, independent verification, reads more than the loop needs).
- Briefs, fix-round composition, rulings and the ledger stay in the controller; they need the whole
  conversation.
