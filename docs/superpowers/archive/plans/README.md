# Archived implementation plans

Executed step-by-step plans from the 2.8.0 to 2.12.0 cycles, kept as history. Their task boxes were not ticked as the work landed, so an unticked box here does not mean open work: the GitHub epics (#305, #421, #390) are the list of outstanding work, and `CLAUDE.md` describes what was built. The specs these plans implement are indexed in [../../README.md](../../README.md).

| File | What it plans | Status |
|------|---------------|--------|
| [2026-09-04-ddm-device-status-and-mdm-command-health.md](2026-09-04-ddm-device-status-and-mdm-command-health.md) | Plan for the DDM and MDM command health spec | Shipped in 2.8.0 |
| [2026-09-05-smappservice-ticker.md](2026-09-05-smappservice-ticker.md) | Plan for the ticker spec | Shipped in 2.8.0 |
| [2026-09-14-2-8-1-connection-access.md](2026-09-14-2-8-1-connection-access.md) | The 2.8.1 slice of the connection access spec | Shipped in 2.8.1 |
| [2026-10-01-security-policy.md](2026-10-01-security-policy.md) | Plan for the security policy spec | Shipped in 2.9.0; its `score_weights` task is superseded |
| [2026-10-01-ai-insight-surfaces.md](2026-10-01-ai-insight-surfaces.md) | Shared `FleetInsightInput` seam, four insight cards, external tier removed | Shipped in 2.9.0 |
| [2026-10-01-epic-decisions-and-cleanup.md](2026-10-01-epic-decisions-and-cleanup.md) | Owner decisions on epic items, dead-code deletes, CI symbol guard | Shipped in 2.9.0 |
| [2026-10-01-epics-207-226-mechanical-items.md](2026-10-01-epics-207-226-mechanical-items.md) | About 30 mechanical epic items (G15 to G38) | Shipped in 2.9.0 |
| [2026-10-02-hand-edited-config.md](2026-10-02-hand-edited-config.md) | Unknown-key detection, YAML parse notes, saves that preserve hand edits | Shipped in 2.9.0 |
| [2026-10-10-monocle-review-plan.md](2026-10-10-monocle-review-plan.md) | Follow-up to an external security review (Monocle), docs audit and epic triage | Shipped after 2.9.0 (PRs #250 to #260, 2026-10-10); re-score 70/100 unchanged, raw 59 to 66 |
| [2026-10-28-2-12-0-plan.md](2026-10-28-2-12-0-plan.md) | The 2.12.0 plan: waves, decisions and what each wave ships | Mostly shipped in 2.12; the timestamp-authority and manifest design differs from decision 2 (the manifest is always written, only the timestamp is opt-in; no `sign_manifest` key); computer storage (P10) not built |
| [2026-11-03-environment-model-p3.md](2026-11-03-environment-model-p3.md) to [2026-11-07-environment-model-p9.md](2026-11-07-environment-model-p9.md) | Environment model P3 to P9: Platform route, profiles writer and Doctor rows, unassigned profiles, proposals, workspace merge, products and Protect-only environment, summary fields | Shipped in 2.12 (files p3 to p9, one row for all seven) |
| [2026-11-11-readme-marketplace.md](2026-11-11-readme-marketplace.md) | A simpler README with marketplace-style sections | Shipped in 2.12 (#404) |
