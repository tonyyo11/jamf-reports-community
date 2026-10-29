# Review checklist

Twelve defect classes recurred in every release from 2.8.0 to 2.11.0. None came from a jamf-cli
change; each was fixed where it was reported and found again at a sibling site in the next
release. Reviewers (people and subagents) run this list over a diff before the standard review.
A fix that routes one site through an existing seam fixes every sibling in the same PR, and the
PR body lists the grep that found them.

| # | Class | Check |
|---|---|---|
| 1 | One figure, many calculators | A new consumer of a count, share or rating calls the existing calculator (`StaleRule`, `PatchStatusService.fleetCompliancePct`, `SecurityControlPolicy.reading`, `RiskScoringService.risk`, `SecurityAgentCheck`). Ask where else this number is produced. |
| 2 | Absent read as zero | Decoded or computed data stays Optional until a source reports it; the UI shows a dash or Unknown. `?? 0`, `?? false`, `?? ""` on data is a finding without a comment saying why absent means zero. Shares carry their denominator. |
| 3 | New source without the honesty chain | StateFileStore record → `FailureCause` → `[partial]`/`[skip]` with the shared wording → `isCollectDead` → `retryCouldHelp` → `expectedKinds`/`DataFreshnessHealth` → `CollectSourcesPlan` → `[plan]` → `AttentionLog` → Config Doctor → `knownCollectKinds`/tier map → HTML appendix reason → captured fixture. |
| 4 | Jamf Pro assumed | A profile can be School, Protect, Security Cloud, Platform or organization-level. Every entry point gates: sidebar, Overview, Config tabs, Data Sources, Generate, each CLI subcommand, scheduled-run modes, auth probe, launch audit, backup, diff, device lookup, demo mode, Add sheet, Doctor rows, redaction seeds. |
| 5 | Workspace file read outside the seam | `rg "Data\(contentsOf|String\(contentsOf|contents\(atPath|contentsOfDirectory" app/Sources` over the diff. A workspace path read without `BoundedFile`/`confinedFolder` (links, pipes, hard links, size) is MUST-FIX. |
| 6 | Setting with no reader | Every config key and switch names its reader symbol; `ConfigSchema` knows the key; a switch's effect is traceable to the engine. No reader, no key. |
| 7 | Unbounded child or request | Every `Process` and `URLSession` call names its timeout and drains both pipes. CLAUDE.md lists the calls left unbounded on purpose. |
| 8 | Unredacted egress | A new card, log copy, bundle, terminal or CLI output goes through `LogRedactor.redactedForSharing`; a new stored identifier (host, ID, name) joins the redactor seed with a test that uses that value. |
| 9 | Launch-time verdict never invalidated | A new cache or per-profile state says what clears it: profile switch, demo toggle, `credentialsChanged()`, config save. |
| 10 | Demo mode touches the Mac | A new control is disabled with `DemoData.liveOnlyHelp` in demo mode; a new read never runs under `demoMode`. |
| 11 | Sink interprets text | Teams Markdown, HTML, xlsx, CSV, terminal and file names each have one escape function applied at the sink, never twice. |
| 12 | Caps and units | A capped list says "N of M" and sorts by severity before the cap. Every count names its unit (computers, devices, statuses, commands) and its denominator. |

Smaller but recurring: a decoder that fails a whole list on one odd value (decode per field;
fixtures captured from real jamf-cli output, never written from documentation); local-day
arithmetic from the file-name stamp, never mtime, with future stamps clamped and tests that take
a fixed day; SwiftUI layout verified at `PageScaffold.minSupportedWidth`.
