---
name: wave-review
description: Run a wave's first reviews (reviewer on every task, security-reviewer where the plan flags it) as one background workflow and get back ledger lines. Use when two or more tasks in a wave are implemented and waiting for review; a single task or a fix round that needs a follow-up message goes to the Agent tool instead.
argument-hint: "PLAN_FILE TASK_ID..."
allowed-tools: Workflow, Bash(.claude/skills/review-package/scripts/review-package *)
---

# Wave review

Reviewers are one-shot seats: one verdict each, no follow-up message. That is what a workflow run
is for. Implementers keep their own subagent threads, because fix rounds are follow-up messages a
workflow agent cannot receive.

1. For each task, write its package with the `review-package` skill from the task's recorded
   BASE..HEAD (or FIX_BASE..HEAD for a re-review above the fold threshold in
   `docs/superpowers/agent-loop.md`). Note the implementer's report path if there is one.
2. Set `security: true` on the tasks the plan's SDD section names for `security-reviewer`, and on
   any task that reads or writes workspace files, adds a product gate or sends data out.
3. Call Workflow with `name: "wave-review"` and
   `args: {tasks: [{id, package, report, security, kind}]}` (`kind` is `review` or `re-review`).
   Stay under about 10 seats per run; split a larger wave.
4. When it returns, read each review and rule on its findings yourself; a review is a claim, not
   evidence. Append the returned `ledger` lines to `.superpowers/sdd/<plan>/progress.md`.
5. Every entry in `uncovered` is a seat that died. Dispatch that reviewer with the Agent tool and
   ledger it the usual way; never record an uncovered seat as Approved.

The script is `.claude/workflows/wave-review.js`. It changes who dispatches the seats, not what
the seats do: same agents, same checklist, same ledger format, so `loop-eval` compares with the
baseline unchanged.
