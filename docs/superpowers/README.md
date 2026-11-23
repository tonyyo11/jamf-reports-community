# Design specs

The files in `specs/` are point-in-time design specs from the 2.7.0 to 2.12.0 cycles. They record what was intended and why, not what the app does now. `CLAUDE.md`, `CHANGELOG.md` and `docs/wiki` are the authority on shipped behaviour.

**Outstanding work is not listed here.** The GitHub epic issues are the list: #305 (2.12), #421 (2.13) and #390 (Jamf Pro 11.32 to 11.34 API), indexed by `BACKLOG.md`. The Epic column below only says which epic holds what a spec left unbuilt.

**Archive.** Executed implementation plans are in [archive/plans/](archive/plans/) (18 plans, 2.8.0 to 2.12.0, with their own [status table](archive/plans/README.md)), and specs that were never built are in [archive/specs/](archive/specs/). A plan moves there once its work has merged; a plan still being executed lives in `plans/`. Nothing is deleted.

Each spec's own `Status:` line agrees with this table. Status was last checked on 2026-11-15 against `dev/2-12-0` (app 2.12.0 in development, so "2.12" below means built and not yet released).

## Specs

| File | What it designs | Status | Release | Epic for open items |
|------|-----------------|--------|---------|---------------------|
| [2026-08-27-period-report-design.md](specs/2026-08-27-period-report-design.md) | Period reports: start, end and change for a reporting window | Shipped; GUI-only | 2.7.0 | #305 (a scheduled executive report) |
| [2026-09-04-ddm-device-status-and-mdm-command-health-design.md](specs/2026-09-04-ddm-device-status-and-mdm-command-health-design.md) | Per-device DDM status and MDM command health scan | Shipped | 2.8.0 | none |
| [2026-09-05-smappservice-ticker-design.md](specs/2026-09-05-smappservice-ticker-design.md) | One SMAppService background item replaces LaunchAgent plists | Shipped (the spec's target said 2.9.0) | 2.8.0 | none |
| [2026-09-11-jamf-cli-1.29.0-compat-design.md](specs/2026-09-11-jamf-cli-1.29.0-compat-design.md) | jamf-cli 1.29 patch-failure envelope, gated spec-derived names, gated `--no-verify` | Shipped; the gates were removed in 2.11 when the floor became 1.29.0. The later sections are first-person working notes to the maintainer | 2.8.0 | #305 (command catalog decides what a profile can collect) |
| [2026-09-12-connection-access-and-setup-design.md](specs/2026-09-12-connection-access-and-setup-design.md) | Failure causes, reachability record, access card, guided setup ("spec 1 of 2") | Partly shipped: failure causes, connection check, Compliance Benchmarks collect, region picker, catalog privileges. The rest is non-binding | 2.8.1, 2.10, 2.12 | none holds the unbuilt sections (see below) |
| [2026-10-01-security-policy-design.md](specs/2026-10-01-security-policy-design.md) | `security_policy` control levels and the hardware-encrypted FileVault rule | Shipped; section 5 `score_weights` was replaced by the score factors spec | 2.9.0 | none |
| [2026-10-05-security-score-factors-design.md](specs/2026-10-05-security-score-factors-design.md) | `security_policy.score_factors` list | Shipped | 2.9.0 | none |
| [2026-10-05-stale-basis-and-contact-gap-design.md](specs/2026-10-05-stale-basis-and-contact-gap-design.md) | `thresholds.stale_basis`, `contact_gap_days`, the contact-gap card | Shipped | 2.9.0 | none |
| [2026-10-18-security-cloud-and-device-correlation-design.md](specs/2026-10-18-security-cloud-and-device-correlation-design.md) | Cross-product device correlation and Security Cloud | Partly shipped: `DeviceCorrelation` and the Protect match (2.11); Security Cloud slot, risk collect, UDID match, summary fields (2.12). Gateway kinds, screen, risk pill, report sections and score factor not built | 2.11, 2.12 | #305 |
| [2026-10-19-environment-model-design.md](specs/2026-10-19-environment-model-design.md) | The workspace becomes the environment: one profile per product, merging workspaces | Partly shipped: P1 to P9 and P12 slices 1 and 2. P10 deferred, P11 replaced by the mobile spec's M6, the rest of P12 and P13 (docs) open | 2.12 | #305 (P12, P13), #421 (P10) |
| [2026-10-19-mobile-first-class-design.md](specs/2026-10-19-mobile-first-class-design.md) | Mobile devices beside computers: Overview, Trends, summary fields, Health Audit; Fleet Overview shows one environment | Partly shipped: M1 to M5 and the M6 tiles that need no new data. Storage, App Installers, the encryption tile and product cards not built | 2.11 (M2, M3), 2.12 | #305 (M6), #421 (storage, App Installers) |
| [2026-10-30-localization-plan.md](specs/2026-10-30-localization-plan.md) | GUI localization: `L`/`LK`/`LShown`, a string catalog, seven languages | Shipped; `CLAUDE.md` "Localization (2.12)" is the current reference | 2.12 | none |
| [2026-11-11-percentage-rounding-design.md](specs/2026-11-11-percentage-rounding-design.md) | `display.percent_decimals` and `PercentFormat` | Shipped (#410) | 2.12 | none |
| [2026-11-11-site-limited-login-design.md](specs/2026-11-11-site-limited-login-design.md) | Detect a site-limited jamf-cli login and say reports cover only what it sees | Shipped | 2.12 | none |
| [2026-11-15-management-health-design.md](specs/2026-11-15-management-health-design.md) | Management health from fields already collected; account names in saved snapshots | Built (#422). Summary object, Trends metrics, alert keys, server version read and policy levels are later work | 2.12 | #421 |
| [2026-11-15-school-device-scan-design.md](specs/2026-11-15-school-device-scan-design.md) | Jamf School per-device scan: battery, enrollment type and storage, every 7 days | Built (#423). The School Devices screen has no columns for it yet | 2.12 | #421 |

Archived spec: [archive/specs/2026-10-04-model-providers-and-app-intents-design.md](archive/specs/2026-10-04-model-providers-and-app-intents-design.md), remote model providers and App Intents. Not built, by decision: the app is on-device only (wiki page 03b) and 2.9 removed `ai.external`. It is not outstanding work and no epic tracks it.

## Known divergences

- DDM and MDM command health: exit 3 now runs a token refresh and retries once (the spec said unchanged); the 7-day pending rule is `>=`, not "older than".
- Ticker: run-now markers and tick state live in `~/Library/Application Support/JamfReports`, not in the workspace. The plan records this; the spec does not.
- Connection access: `FailureCause`, `StderrSignalWatcher`, `ConnectionCheck`, the Compliance Benchmarks collect and wiki page 13 shipped in 2.8.1; the region picker (2.10) and the privilege list from jamf-cli's command catalog (2.12, in place of section 7's static table) came later. The reachability record, Access card and `jamf-reports permissions` (sections 8, 10.2, 11) were not built, "spec 2" was never written, and no epic tracks them. The archived plan lists seven deliberate deviations the spec does not mention.
- Security policy: section 5 `score_weights` was retired before release and replaced by `score_factors` (see the score factors spec). `on_values`/`off_values`, `edr_agent` and `score_factors` shipped under the same block and are documented in `CLAUDE.md` only. Fleet counts start from jamf-cli's own summary and add a `notReported` state.
- Score factors: the `checked_in` factor follows `thresholds.stale_basis` (from the stale-basis spec), not last contact alone.
- Period report: the metric selection is not saved between uses (the design saved it per profile).
- 2.12 plan (archived): the manifest is always written and only the timestamp is opt-in (no `sign_manifest` key), which differs from the plan's decision 2.
