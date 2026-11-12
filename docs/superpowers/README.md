# Design specs and implementation plans

These files are point-in-time design specs and implementation plans from the 2.8.0 to 2.12.0 cycles. They record what was intended when they were written, not what the app does now. `CLAUDE.md`, `CHANGELOG.md` and `docs/wiki` are the authority on shipped behaviour.

Status below was last checked on 2026-11-12 against `dev/2-12-0` (app 2.12.0 in development; the 2.8.0 to 2.9.0 rows were checked on 2026-10-10). It supersedes any "Status:" line inside an individual file (for example "awaiting review" or "uncommitted"); those files are left as written, apart from the plans, which carry their own status line.

Pairing: four spec and plan pairs (DDM, ticker, connection access, security policy) and seven environment-model plans (P3 to P9) that share one spec. Several other specs were built without a plan, and some plans have no spec.

| File | What it designs | Status |
|------|-----------------|--------|
| [specs/2026-09-04-ddm-device-status-and-mdm-command-health-design.md](specs/2026-09-04-ddm-device-status-and-mdm-command-health-design.md) | Per-device DDM status and MDM command health scan | Shipped in 2.8.0 |
| [plans/2026-09-04-ddm-device-status-and-mdm-command-health.md](plans/2026-09-04-ddm-device-status-and-mdm-command-health.md) | Plan for the DDM and MDM command health spec | Shipped in 2.8.0 |
| [specs/2026-09-05-smappservice-ticker-design.md](specs/2026-09-05-smappservice-ticker-design.md) | One SMAppService background item replaces LaunchAgent plists | Shipped in 2.8.0 (the spec says 2.9.0) |
| [plans/2026-09-05-smappservice-ticker.md](plans/2026-09-05-smappservice-ticker.md) | Plan for the ticker spec | Shipped in 2.8.0 |
| [specs/2026-09-11-jamf-cli-1.29.0-compat-design.md](specs/2026-09-11-jamf-cli-1.29.0-compat-design.md) | jamf-cli 1.29 patch-failure envelope, gated spec-derived names, gated `--no-verify` | Shipped in 2.8.0; the gates were removed in 2.11 when the floor became 1.29.0. The later sections are first-person working notes to the maintainer |
| [specs/2026-09-12-connection-access-and-setup-design.md](specs/2026-09-12-connection-access-and-setup-design.md) | Failure causes, reachability record, access card, guided setup ("spec 1 of 2") | Partly shipped in 2.8.1; non-binding (see below) |
| [plans/2026-09-14-2-8-1-connection-access.md](plans/2026-09-14-2-8-1-connection-access.md) | The 2.8.1 slice of the connection access spec | Shipped in 2.8.1 |
| [specs/2026-10-01-security-policy-design.md](specs/2026-10-01-security-policy-design.md) | `security_policy` control levels and the hardware-encrypted FileVault rule | Shipped in 2.9.0 |
| [plans/2026-10-01-security-policy.md](plans/2026-10-01-security-policy.md) | Plan for the security policy spec | Shipped in 2.9.0; its `score_weights` task is superseded |
| [plans/2026-10-01-ai-insight-surfaces.md](plans/2026-10-01-ai-insight-surfaces.md) | Shared `FleetInsightInput` seam, four insight cards, external tier removed | Shipped in 2.9.0 |
| [plans/2026-10-01-epic-decisions-and-cleanup.md](plans/2026-10-01-epic-decisions-and-cleanup.md) | Owner decisions on epic items, dead-code deletes, CI symbol guard | Shipped in 2.9.0 |
| [plans/2026-10-01-epics-207-226-mechanical-items.md](plans/2026-10-01-epics-207-226-mechanical-items.md) | About 30 mechanical epic items (G15 to G38) | Shipped in 2.9.0 |
| [plans/2026-10-02-hand-edited-config.md](plans/2026-10-02-hand-edited-config.md) | Unknown-key detection, YAML parse notes, saves that preserve hand edits | Shipped in 2.9.0 |
| [specs/2026-10-04-model-providers-and-app-intents-design.md](specs/2026-10-04-model-providers-and-app-intents-design.md) | Remote model providers and App Intents | Not built; superseded by the on-device-only decision (2.9); non-binding (see below) |
| [specs/2026-10-05-security-score-factors-design.md](specs/2026-10-05-security-score-factors-design.md) | `security_policy.score_factors` list | Shipped in 2.9.0 |
| [specs/2026-10-05-stale-basis-and-contact-gap-design.md](specs/2026-10-05-stale-basis-and-contact-gap-design.md) | `thresholds.stale_basis`, `contact_gap_days`, the contact-gap card | Shipped in 2.9.0 |
| [plans/2026-10-10-monocle-review-plan.md](plans/2026-10-10-monocle-review-plan.md) | Follow-up to an external security review (Monocle), docs audit and epic triage | Shipped after 2.9.0 (PRs #250 to #260, 2026-10-10); re-score 70/100 unchanged, raw 59 to 66 |
| [specs/2026-10-18-security-cloud-and-device-correlation-design.md](specs/2026-10-18-security-cloud-and-device-correlation-design.md) | Cross-product device correlation and Security Cloud plan (epic #283) | Slices 1 and 2 shipped in 2.12 (collect, `profiles.security_cloud` slot, UDID match, summary fields, alerts, Trends metrics); the Security Cloud screen, risk pill, score factor and gateway half are not built |
| [specs/2026-10-19-environment-model-design.md](specs/2026-10-19-environment-model-design.md) | The workspace becomes the environment: one profile per product, merging workspaces, a multi-environment view (epics #283, #284) | P1 to P9 and P12 (slices 1 and 2) shipped in 2.12; P10 (computer storage, app installers) not built; P11 superseded by the mobile spec; P13 (docs) open |
| [specs/2026-10-19-mobile-first-class-design.md](specs/2026-10-19-mobile-first-class-design.md) | Mobile devices beside computers: Overview, Trends, summary fields, Health Audit; Fleet Overview shows one environment (#207 L5) | M1 to M5 shipped in 2.12 (Fleet Overview for one environment, `mobile` summary object, Overview section, Health Audit card, composition); M6 device tiles and product cards not built |
| [plans/2026-10-28-2-12-0-plan.md](plans/2026-10-28-2-12-0-plan.md) | The 2.12.0 plan: waves, decisions and what each wave ships | Mostly shipped in 2.12; the timestamp-authority and manifest design differs from decision 2 (the manifest is always written, only the timestamp is opt-in; no `sign_manifest` key); computer storage (P10) not built |
| [specs/2026-10-30-localization-plan.md](specs/2026-10-30-localization-plan.md) | GUI localization: `L`/`LK`/`LShown`, a string catalog, seven languages | Shipped in 2.12; `CLAUDE.md` "Localization (2.12)" is the current reference |
| [plans/2026-11-03-environment-model-p3.md](plans/2026-11-03-environment-model-p3.md) to [plans/2026-11-07-environment-model-p9.md](plans/2026-11-07-environment-model-p9.md) | Environment model P3 to P9: Platform route, profiles writer and Doctor rows, unassigned profiles, proposals, workspace merge, products and Protect-only environment, summary fields | Shipped in 2.12 (files p3 to p9, one row for all seven) |
| [specs/2026-11-11-percentage-rounding-design.md](specs/2026-11-11-percentage-rounding-design.md) | `display.percent_decimals` and `PercentFormat` | Shipped in 2.12 (#410) |
| [specs/2026-11-11-site-limited-login-design.md](specs/2026-11-11-site-limited-login-design.md) | Detect a site-limited jamf-cli login and say reports cover only what it sees | Shipped in 2.12 |
| [plans/2026-11-11-readme-marketplace.md](plans/2026-11-11-readme-marketplace.md) | A simpler README with marketplace-style sections | Shipped in 2.12 (#404) |

## Known divergences

- DDM and MDM command health: exit 3 now runs a token refresh and retries once (the spec said unchanged); the 7-day pending rule is `>=`, not "older than".
- Ticker: run-now markers and tick state live in `~/Library/Application Support/JamfReports`, not in the workspace. The plan records this; the spec does not.
- Connection access: `FailureCause`, `StderrSignalWatcher`, `ConnectionCheck`, the Compliance Benchmarks collect and wiki page 13 shipped. Sections 8 to 17 (reachability record, source states, Access card, region picker and permission checklist, `jamf-reports permissions`) were not built, "spec 2" was never written, and no epic tracks them. The plan lists seven deliberate deviations the spec does not mention.
- Security policy: section 5 `score_weights` was retired before release and replaced by `score_factors` (see the score factors spec). `on_values`/`off_values`, `edr_agent` and `score_factors` shipped under the same block and are documented in `CLAUDE.md` only. Fleet counts start from jamf-cli's own summary and add a `notReported` state.
- Score factors: the `checked_in` factor follows `thresholds.stale_basis` (from the stale-basis spec), not last contact alone.
- Model providers and App Intents: the shipped app is on-device only (wiki page 03b) and 2.9 removed `ai.external`. No epic tracks this spec.
