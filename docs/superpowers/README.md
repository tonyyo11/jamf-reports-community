# Design specs and implementation plans

These files are point-in-time design specs and implementation plans from the 2.8.0 to 2.9.0 cycle. They record what was intended when they were written, not what the app does now. `CLAUDE.md`, `CHANGELOG.md` and `docs/wiki` are the authority on shipped behaviour.

Status below was checked on 2026-10-10 against `main` at 8ec34f33 (app 2.9.0). It supersedes any "Status:" line inside an individual file (for example "awaiting review" or "uncommitted"); those files are left as written.

Pairing: four spec and plan pairs (DDM, ticker, connection access, security policy). Four specs were built without a plan. Four plans have no spec.

| File | What it designs | Status |
|------|-----------------|--------|
| [specs/2026-09-04-ddm-device-status-and-mdm-command-health-design.md](specs/2026-09-04-ddm-device-status-and-mdm-command-health-design.md) | Per-device DDM status and MDM command health scan | Shipped in 2.8.0 |
| [plans/2026-09-04-ddm-device-status-and-mdm-command-health.md](plans/2026-09-04-ddm-device-status-and-mdm-command-health.md) | Plan for the DDM and MDM command health spec | Shipped in 2.8.0 |
| [specs/2026-09-05-smappservice-ticker-design.md](specs/2026-09-05-smappservice-ticker-design.md) | One SMAppService background item replaces LaunchAgent plists | Shipped in 2.8.0 (the spec says 2.9.0) |
| [plans/2026-09-05-smappservice-ticker.md](plans/2026-09-05-smappservice-ticker.md) | Plan for the ticker spec | Shipped in 2.8.0 |
| [specs/2026-09-11-jamf-cli-1.29.0-compat-design.md](specs/2026-09-11-jamf-cli-1.29.0-compat-design.md) | jamf-cli 1.29 patch-failure envelope, gated spec-derived names, gated `--no-verify` | Shipped in 2.8.0. The later sections are first-person working notes to the maintainer |
| [specs/2026-09-12-connection-access-and-setup-design.md](specs/2026-09-12-connection-access-and-setup-design.md) | Failure causes, reachability record, access card, guided setup ("spec 1 of 2") | Partly shipped in 2.8.1; non-binding (see below) |
| [plans/2026-09-14-2-8-1-connection-access.md](plans/2026-09-14-2-8-1-connection-access.md) | The 2.8.1 slice of the connection access spec | Shipped in 2.8.1 |
| [specs/2026-10-01-security-policy-design.md](specs/2026-10-01-security-policy-design.md) | `security_policy` control levels and the hardware-encrypted FileVault rule | Shipped in 2.9.0 |
| [plans/2026-10-01-security-policy.md](plans/2026-10-01-security-policy.md) | Plan for the security policy spec | Shipped in 2.9.0; its `score_weights` task is superseded |
| [plans/2026-10-01-ai-insight-surfaces.md](plans/2026-10-01-ai-insight-surfaces.md) | Shared `FleetInsightInput` seam, four insight cards, external tier removed | Shipped in 2.9.0 |
| [plans/2026-10-01-epic-decisions-and-cleanup.md](plans/2026-10-01-epic-decisions-and-cleanup.md) | Owner decisions on epic items, dead-code deletes, CI symbol guard | Shipped in 2.9.0 |
| [plans/2026-10-01-epics-207-226-mechanical-items.md](plans/2026-10-01-epics-207-226-mechanical-items.md) | About 30 mechanical epic items (G15 to G38) | Shipped in 2.9.0 |
| [plans/2026-10-02-hand-edited-config.md](plans/2026-10-02-hand-edited-config.md) | Unknown-key detection, YAML parse notes, saves that preserve hand edits | Shipped in 2.9.0 |
| [specs/2026-10-04-model-providers-and-app-intents-design.md](specs/2026-10-04-model-providers-and-app-intents-design.md) | Remote model providers and App Intents | Not built; non-binding (see below) |
| [specs/2026-10-05-security-score-factors-design.md](specs/2026-10-05-security-score-factors-design.md) | `security_policy.score_factors` list | Shipped in 2.9.0 |
| [specs/2026-10-05-stale-basis-and-contact-gap-design.md](specs/2026-10-05-stale-basis-and-contact-gap-design.md) | `thresholds.stale_basis`, `contact_gap_days`, the contact-gap card | Shipped in 2.9.0 |
| [plans/2026-10-10-monocle-review-plan.md](plans/2026-10-10-monocle-review-plan.md) | Follow-up to an external security review (Monocle), docs audit and epic triage | Shipped after 2.9.0 (PRs #250 to #260, 2026-10-10); re-score 70/100 unchanged, raw 59 to 66 |

## Known divergences

- DDM and MDM command health: exit 3 now runs a token refresh and retries once (the spec said unchanged); the 7-day pending rule is `>=`, not "older than".
- Ticker: run-now markers and tick state live in `~/Library/Application Support/JamfReports`, not in the workspace. The plan records this; the spec does not.
- Connection access: `FailureCause`, `StderrSignalWatcher`, `ConnectionCheck`, the Compliance Benchmarks collect and wiki page 13 shipped. Sections 8 to 17 (reachability record, source states, Access card, region picker and permission checklist, `jamf-reports permissions`) were not built, "spec 2" was never written, and no epic tracks them. The plan lists seven deliberate deviations the spec does not mention.
- Security policy: section 5 `score_weights` was retired before release and replaced by `score_factors` (see the score factors spec). `on_values`/`off_values`, `edr_agent` and `score_factors` shipped under the same block and are documented in `CLAUDE.md` only. Fleet counts start from jamf-cli's own summary and add a `notReported` state.
- Score factors: the `checked_in` factor follows `thresholds.stale_basis` (from the stale-basis spec), not last contact alone.
- Model providers and App Intents: the shipped app is on-device only (wiki page 03b) and 2.9 removed `ai.external`. No epic tracks this spec.
