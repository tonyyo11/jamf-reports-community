# Backlog — Deferred Findings

Deferred review findings are tracked as **category-epic issues** on GitHub.
Each epic is a checklist intended to be worked off as a focused release:

- [Epic: Accessibility & WCAG 2.2 completion](https://github.com/tonyyo11/jamf-reports-community/issues/101)
- [Epic: Test coverage hardening](https://github.com/tonyyo11/jamf-reports-community/issues/102)
- [Epic: Security & silent-failure hardening](https://github.com/tonyyo11/jamf-reports-community/issues/103)
- [Epic: Code hygiene & refactors](https://github.com/tonyyo11/jamf-reports-community/issues/104)
- [Epic: jamf-cli upstream compatibility & capability tracking](https://github.com/tonyyo11/jamf-reports-community/issues/147)
- [Epic: Guided experience — config doctor, CSV/EA walkthrough, getting-started checklist](https://github.com/tonyyo11/jamf-reports-community/issues/182)

## Process

The GitHub issue tracker is the live inventory — not this file.

- A new valid-but-out-of-scope finding goes into the matching epic issue as a
  checklist item, or into a new issue if it does not fit one.
- When a finding is fixed, check it off in its epic issue and reference the
  issue number in the fixing commit.
- When a finding is determined invalid on closer review, note why in the issue
  thread and strike the item.

The detailed pre-2.0.0 backlog (organized by source PR) is preserved in this
file's git history if a specific finding's original context is needed.

## Deferred follow-ups awaiting epic filing (2026-06 review)

Consciously-deferred items from the 2026-06 review. File each into the noted
epic (or a new issue) and strike it here once tracked on GitHub.

- **Stale-threshold divergence** (epic #104, code hygiene) —
  `DeviceInventoryService`/`StaleDeviceService` hardcode a 30-day threshold and
  bucket on `daysSinceContact`, not the config `stale_device_days`. This diverges
  from the summary path at non-default thresholds; prod runs the default, so
  non-blocking today.
- **Patch-compliance metric definition** (epic #104, code hygiene) — patch
  compliance is reported two ways: device-weighted in the report sheets vs an
  unweighted per-title average in `summary.json`/Trends. Unifying on
  device-weighted is a metric-definition decision and would introduce a one-time
  patch-trend re-baselining step.
- **Version-tracking shell logic has no automated coverage** (epic #102, test
  coverage) — `build-app.sh` RELEASE / BUILD_NUMBER / channel-naming logic is not
  covered by CI (CI runs pytest + `swift build`, not `.app` packaging). Until it
  is, the version-bump checklist must run BOTH build modes (beta and `RELEASE=1`)
  by hand.
- **"Verify intent" data-flow items** (epic #104, code hygiene) — two items each
  need an owner decision: (a) the `policy-status-failures` snapshot kind is ~19
  days stale — intentionally sunset, or lost in a refactor? (b) the empty
  `computers-list` alias directory — legacy drop to delete, or a documented alias
  to keep?
