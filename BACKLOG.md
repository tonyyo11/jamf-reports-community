# Backlog — Deferred Findings

Deferred review findings are tracked as **category-epic issues** on GitHub.
Each epic is a checklist intended to be worked off as a focused release.

**The GitHub issue tracker is the live inventory — not this file.** This file is
an index of the open epics and nothing more. It holds no findings of its own, so
nothing is tracked in two places.

## Open epics

- [Epic: Jamf Security Cloud and cross-product device correlation (2.11)](https://github.com/tonyyo11/jamf-reports-community/issues/283)
- [Epic: 2.11 — Platform API, Protect in backups, Platform connections, and carried-over findings](https://github.com/tonyyo11/jamf-reports-community/issues/284)
- [Epic: 2.12 — AI Governance, environment model, mobile devices first-class, and deferred 2.11 audit findings](https://github.com/tonyyo11/jamf-reports-community/issues/305)
- [Epic: Jamf Pro 11.32–11.34 API — action logs, Apple Vision Pro, and inventory fields not read yet](https://github.com/tonyyo11/jamf-reports-community/issues/390)

Closed epics are not listed here — see the
[closed issues](https://github.com/tonyyo11/jamf-reports-community/issues?q=is%3Aissue+is%3Aclosed+label%3Aenhancement)
for the worked-off history (#101–#104, #147, #182 all shipped between 2026-05 and
2026-06).

## Process

- A new valid-but-out-of-scope finding goes into the matching epic issue as a
  checklist item, or into a new issue if it does not fit one. It does **not** go
  in this file.
- When a finding is fixed, check it off in its epic issue and reference the
  issue number in the fixing commit.
- When a finding is determined invalid on closer review, note why in the issue
  thread and strike the item.
- When an epic closes, drop it from the index above. Do not leave closed epics
  listed as if they were live — a stale index is worse than no index, because
  CLAUDE.md points here as authoritative.

The detailed pre-2.0.0 backlog (organized by source PR) is preserved in this
file's git history if a specific finding's original context is needed.
