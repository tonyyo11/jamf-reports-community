# Deployment and patching: App Installers deployments and patch policies (wave C)

*   **Author:** Tony Young
*   **Status:** Proposed
*   **Date:** 2026-11-25

--------------------------------------------------------------------------------

## Overview

Jamf Reports gains two read-only sources from Jamf Pro, collected through jamf-cli:

*   **App Installers deployments** (`pro app-installers-deployments list`). Each row is one deployment: the app, the latest version Jamf offers, the deployed version, and the status of the Macs it targets (installed, available in Self Service, in progress, failed) and the Macs in its scope that another deployment of the same title serves (`unqualified`).
*   **Patch policies** (`pro patch-policies list`). Each row is one policy: its name, whether it is enabled, the target version, the patch title it belongs to, and the status of the Macs it targets (completed, deferred, failed, pending).

The app saves both daily as reduced snapshots. An enabled deployment or an enabled policy goes to "Needs attention" when its failed Macs reach a warning or critical share of the Macs it targets. The organization sets both levels; the defaults are 10% and 25%. Below the warning level the counts are shown as information.

This is epic #421, section "Deployment and patching", built on the new-source pattern from wave A (PR #461).

## The Problem

An admin sees a failing deployment or patch policy in Jamf Pro today, while it is failing. Jamf Pro shows the current state only. It does not keep the history: how many Macs failed last week, whether the share is rising, when it started. Nor does it give a report an admin can export and file.

Jamf Reports already keeps dated snapshots, a daily summary and Trends for other sources. It does not collect App Installers deployments or patch policies. The nearest data it has is weaker for this question:

*   `app-status` lists apps that errored in a command-history window. It does not know which deployment an app belongs to, or how many Macs each deployment targets.
*   `patch-status` and `patch-device-failures` describe patch titles and failing devices. They do not give per-policy counts, so a failing policy cannot be told apart from a healthy one on the same title.

What the app adds is the record. Every day's reduced snapshot is kept, so each deployment's and policy's figures for any past day stay on disk and in that day's workbook. The daily summary keeps, per source, how many were at a level, which Trends draws. A per-row history view ("at a level since") is a later wave.

Two facts shape the design:

*   **App Installers exists only on Jamf Cloud.** On an on-premises Jamf Pro server the command answers exit 4 with the error name `not_found` (captured during design). The app must treat that as "not on this server" and stay quiet: no Partial run, no retry, no stale-data banner.
*   **Patch policies are in real use, and most are quiet.** On a production server checked during design, most patch policies were disabled, some enabled ones had failures, and every failure was under 10% of its policy's scope; some policies had nothing in scope. At the default levels such a server shows no finding. What an admin reads is the counts, and the history of them.

Terms used below: a kind **lands** when a run saves its snapshot. A kind is **advisory** when its last failure is recorded but is not a fault to fix: no Partial run, no retry, and Data Freshness does not expect it. An advisory kind has a **7-day hold**: no unforced re-probe for a week.

## Goals

*   Collect both sources on every Jamf Pro workspace, by default, on the refresh tier, with `jamf_cli.collect_skip` as the off switch.
*   Save each snapshot reduced before it reaches disk, keeping only the keys a reader uses.
*   On a server without App Installers (exit 4), record nothing as a failure: the kind is advisory and is not collected again for 7 days. The first time the kind lands, even as an empty list, it is a normal source from then on.
*   One calculator for the failed share of a row: failed Macs over the Macs in scope, where in scope is the sum of the row's status counts that belong to it (for App Installers: installed, available, in progress and failed; `unqualified`, Macs assigned to another deployment of the title, is left out and shown as its own column). A row with nothing in scope has no share. A missing count leaves the row unmeasured, never 0.
*   Two organization-defined levels, warning and critical, as percentages under `thresholds`, shared by both sources, defaulting to 10 and 25, checked by Config Doctor.
*   A row reaches a level only with at least a minimum number of Macs in scope, so a deployment of 2 Macs with 1 failure does not read as critical. Every figure is printed as "N of M Macs".
*   Findings cover enabled deployments and enabled policies only.
*   Store, per source and day, how many enabled rows were judged and how many were at warning and at critical, together with the levels and the minimum scope they were judged at, so a later change of either never rewrites earlier days.
*   Show the figures in a Health Audit card and one workbook tab (a section per source), in HTML "Needs attention" sentences, and as two Trends series.
*   List App Installers deployments whose deployed version differs from the latest, as a workbook column that separates pinned deployments from lagging ones, so a reader can tell a deliberate version from a stuck one.
*   Run on jamf-cli 1.35.0 or later, independent of wave A's 1.38.0 gate.

## Non-Goals

*   **Alerts.** No alert keys in this wave.
*   **Patch software title configurations.** Per-title adoption from the release date is wave B (B1).
*   **Prestages, prestage scope and inventory preload.** A serial assigned but never enrolled is normal (not built yet, or decommissioned and still in Apple Business Manager), and neither source carries a date.
*   **A change-request window report.** Adoption from a change's start date to its end, exported as evidence, is its own wave.
*   **A per-row history view.** "At a level since <date>" needs a reader over many snapshots; a later wave.
*   **Moving the Patch Failures sheet's policy-to-title name join to the policy ID.** This wave makes the ID available; the switch is its own change.
*   **Jamf School.** jamf-cli has no such commands for School.
*   **Opt-in and the missing-permission advisory.** Both privileges (Read Mac Applications, Read Patch Policies) are required by the default source set (`app-status`, `patch-status`).
*   **Any write to Jamf Pro.** No retry, scope or install command.
*   **Mobile App Installers or mobile patch.** The commands are computer only.

## Critical User Journeys (CUJs)

### CUJ 1: A deployment fails on a Jamf Cloud server

*   **Given**: A Jamf Cloud workspace with App Installers, a deployment of Sketch to 400 Macs, the default levels.
*   **When**: The daily collect finds 48 failed Macs out of 400 in scope.
*   **Then**: The Health Audit card lists Sketch at warning, "48 of 400 Macs failed (12%)". The workbook tab and the HTML report's "Needs attention" say the same. Trends shows how many App Installers deployments were at a level each day.

### CUJ 2: An on-premises server

*   **Given**: An on-premises workspace, whose server has no App Installers.
*   **When**: Any collect runs.
*   **Then**: `app-installers-deployments` answers exit 4 `not_found`. The run log has one `[info]` line, the run is not Partial, nothing retries, and Data Freshness does not list the kind. The Health Audit card shows the App Installers section as "Not set up on this Jamf Pro server". Patch policies collect and show as usual.

### CUJ 3: Patch policies under the threshold

*   **Given**: A server with many patch policies, some of them with failures under 10% of their scope and some with nothing in scope.
*   **When**: An admin opens the Health Audit card or the workbook tab.
*   **Then**: No policy is in "Needs attention". The tab lists every enabled policy with "N of M Macs failed", completed, deferred and pending, and its patch title. Policies with nothing in scope show "Nothing in scope". Disabled policies are listed apart and never judged.

### CUJ 4: An organization changes its levels

*   **Given**: Two months of history at the default levels.
*   **When**: The admin sets warning to 5% and critical to 15%.
*   **Then**: The card and the reports judge today's rows at the new levels. Each earlier day's summary still records the levels it was judged at, so Trends does not compare counts across the change: the change figure covers only days judged at today's levels, and a note names the day the levels changed.

## Technical Plan (Architecture)

### Base and dependencies

Wave C is built on `feat/wave-a-server-health` (PR #461, head `f9ae3342` when this was written) and opened as the next layer of that stack, into `dev/2-13-0`. Wave A adds the Jamf Pro server's own health sources (built-in CA expiry, notifications, opt-in admin counts) with a Server and Admin Health card and tab, and the quiet "advisory" handling wave C reuses. Reverting wave A reverts wave C. Wave C uses these wave A names: `FailureCause.Kind.notConfiguredOnServer`, `StateFileStore.isAdvisory(kind:)`, `StateFileStore.advisoryHoldUntil(report:now:)`, `StateFileStore.advisoryCauses(profile:)`, the plan's `advisoryHold` closure and `CollectSkipReason.notConfigured`, `ReportEngine.listRows(of:)`, `ServerHealthSummaryFigures` and `DailySummary.withEnvironment(products:protect:securityCloud:serverHealth:)` as the pattern for summary figures, and `expectedKinds(advisory:)`. If wave A's fix round renames or reshapes any of them, wave C is rebased onto the result before review.

### Collection

Two new collect kinds join the Jamf Pro command matrix, both on the **refresh** tier (`CollectionTier`), both optional (`ReportEngine.optionalKinds`, so `jamf_cli.collect_skip` turns either off), both `.mac` in `ReportEngine.sourceSides` (the commands report computers only). Neither is in `platformOnlyKinds`.

Reduction keeps exactly these keys, each only when it has the stated JSON type (anything else is left out of that row):

| Kind | Command | Kept keys |
|---|---|---|
| `app-installers-deployments` | `pro app-installers-deployments list --output json` | `id` string, `name` string, `enabled` boolean, `updateBehavior` string, `app.latestVersion` string, `app.deployedVersion` string, `computerStatuses.{installed, available, inProgress, failed, unqualified}` numbers |
| `patch-policies` | `pro patch-policies list --output json` | `id`, `policyName`, `policyTargetVersion`, `softwareTitle`, `softwareTitleConfigurationId` strings; `policyEnabled` boolean; `completed`, `deferred`, `failed`, `pending` numbers |

Everything else in the captured rows is dropped, including `iconUrl`, `category`, `site`, `smartGroup`, the other `app` keys and `policyDeploymentMethod`. None of the kept keys identifies a person. A top-level `null`, `[]` or a `{results: [...]}` envelope reads as a list (`null` is saved as `[]`, a real empty answer). A payload that is not a list of objects saves nothing and records a failure.

Both commands are listed in jamf-cli's catalog as served by the Jamf Platform gateway (`applications:read`, `patch-policies:read`; from the catalog, not yet run), so they are not skipped on a Platform API profile (a login to Jamf's cloud gateway rather than to the Jamf Pro server directly).

Both need jamf-cli 1.35.0 or later. jamf-cli's command catalog bundled with the app at the time of writing lists both commands at 1.35.0, and the commands were run on 1.37.0 and 1.38.0; output shape on 1.35-1.36 is unverified (see Risks). `JamfCLIInstaller.supportsDeploymentSources(_:)` follows the existing `supportsDashboard` rule: false for an unknown or unparseable version and below 1.35.0, so a run that could not read the version skips both with `CollectSkipReason.deploymentSourcesUnsupported`. Data Sources applies the same check.

Each kind gets a 180 s call limit, like wave A's sources. jamf-cli fetches every page of both lists by default (`--all` defaults to true; on the NFR server, `--page-size 10` still returned all 63 App Installers rows), so a long list is never cut at one page. A partial answer (exit 7) is a failure and saves nothing, as for wave A's sources: a list with rows missing would undercount the rows at a level.

**Each day's first run collects them.** Both kinds are on the 12-hour refresh cadence, and the daily summary takes their figures only from a run that lands them. So, as `planAddOn` already does for add-on products, "not due" applies only within the local day of the last landing: the first run of a new day always collects both, and no day is left without figures.

### Splitting wave A's set

Wave A keys several behaviours on one set, `ReportEngine.serverHealthKinds` (the alternatives weighed are J and K). Wave C adds two named sets beside it:

```text
ReportEngine.notSetUpOnExit4Kinds   = serverHealthKinds ∪ {"app-installers-deployments"}
ReportEngine.untilFirstLandingKinds = {"app-installers-deployments"}
```

and moves exactly three reads to them:

1.  `ReportEngine.recordUnlandedAttempt`: exit 4 records `FailureCause.notConfiguredOnServer` for a kind in `notSetUpOnExit4Kinds`. The rule checks the exit code alone, as wave A's does today; the `not_found` name was captured as confirmation, and keying on exit 4 keeps one rule for both waves. A kind in `untilFirstLandingKinds` that has landed is classified by `FailureCause.classify` instead, so it reads as an ordinary failure that the same-day retry and self-repair still try.
2.  `StateFileStore.isAdvisory(kind:)`: the `notConfiguredOnServer` case applies to `notSetUpOnExit4Kinds`, and for a kind in `untilFirstLandingKinds` only while it has never landed (`lastRun == nil`). The `missingPermission` case stays keyed on `serverHealthKinds`.
3.  `StateFileStore.advisoryCauses(profile:)`: iterates `notSetUpOnExit4Kinds`.

Everything else (Platform skip, version gate, opt-in, reduction branch) stays keyed on `serverHealthKinds`; the short call limit and the exit-7 rule apply to `deploymentKinds` too, so wave A's behaviour is unchanged; its tests are the check. `patch-policies` is in neither set: on a server that answers exit 4 for it, it is an ordinary failure.

**Why the two rules differ.** Wave A's kinds stay quiet on exit 4 at any time, because a server can turn the built-in CA or notifications on and off. App Installers is quiet only until it first lands: a Jamf Cloud server that once answered and later returns exit 4 is a real failure, not a feature that went away. The "has landed" fact is the per-workspace state file `state/app-installers-deployments.last`.

This replaces the research-stage plan, in which only inventory preload needed the quiet path; preload was dropped and App Installers now needs it.

### Flow

```text
collect (refresh tier, Jamf Pro workspace; first run of each day always collects)
  ├─ app-installers-deployments ── exit 0 ──► DeploymentSourceReduction ──► snapshot
  │                              └ exit 4, never landed ──► [info] not set up; advisory, 7-day hold
  └─ patch-policies ─────────────── exit 0 ──► DeploymentSourceReduction ──► snapshot
                                   └ exit ≠ 0 ──► failure recorded (normal)

finalizeEnvironment (CollectRouter passes the levels and the run's date)
  └─ deploymentSummaryFigures(landed:levels:now:) ──► DailySummary appInstallersHealth / patchPolicyHealth

read side (card, workbook tab, HTML, Trends)
  └─ DeploymentHealth.load(dataDir:advisory:) + judge(levels) ── one calculator for every surface
```

### One calculator: `DeploymentHealth`

A new pure model, `Models/DeploymentHealth.swift`, is the only place a row is judged. Every surface reads it.

*   **Row.** `DeploymentRow { source (appInstallers | patchPolicy), id, name, enabled, failed, inScope, extra }`. For App Installers, `inScope = installed + available + inProgress + failed`, and `unqualified` is carried in `extra` for its own column. For a patch policy, `inScope = completed + deferred + failed + pending`. Any of those counts missing or not a whole number leaves the row **unmeasured** (no share, never 0). A row with no `id` is dropped and counted in a "rows left out" line; a missing `name` shows "(no name)". `failed > inScope` cannot happen, since `failed` is part of the sum.
*   **Judgement, in order.** The first rule that applies decides:
    1.  `enabled != true` (false or unknown): `notJudged`.
    2.  Any count missing: `unmeasured`.
    3.  `inScope == 0`: `nothingInScope`.
    4.  `inScope < DeploymentHealth.minimumInScope` (10): `belowMinimumScope`.
    5.  `failed * 100 >= critical * inScope`: `critical`.
    6.  `failed * 100 >= warning * inScope`: `warning`.
    7.  Otherwise: `belowLevels`.

    Compared in integers, so exactly 10% is at the 10% level.
*   **Minimum scope.** Fixed in code, not a setting: it exists to stop a 1-of-2 row reading critical. A deployment under 10 Macs that fails on all of them is not judged; the tab still lists it with its counts. This is an accepted limit.
*   **Levels.** `warning` and `critical`, whole percentages, from config (below).
*   **Version.** For App Installers only: `latestVersion` and `deployedVersion` compared as given after trimming; a blank on either side is unknown. When they differ, the row is **pinned** if `updateBehavior == "MANUAL"`, otherwise **lagging**. Information only, never a finding.
*   **Snapshot states.** For each source the model reports one of: `notCollected` (no snapshot), `notSetUp` (advisory `notConfiguredOnServer` on file and never landed), `unreadable` (the newest snapshot did not decode, or is a planted newest file), `empty` (landed, zero rows: a real 0), or `rows` with the snapshot's date. Each has its own wording (see Surfaces).

### Configuration

Two keys under `thresholds`, decoded into `ThresholdsConfig` beside `warning_disk_percent` and `critical_disk_percent` and handled the same way (whole numbers through `wholeNumber`, written by `wholeNumberFields`, Config Doctor through `wholeNumberKeys`):

```yaml
thresholds:
  deployment_failure_warning_percent: 10
  deployment_failure_critical_percent: 25
```

Resolution:

*   A value that is not a whole number, or is outside 1 to 100, falls back alone to its own default (10 or 25).
*   Then, if warning is above critical, both use 10 and 25.
*   Warning equal to critical is valid; every row at that level reads critical.

Config Doctor names a value that is not a whole number (the existing `wholeNumberRows`) and adds one row for a value outside 1 to 100 or an inverted pair, saying which levels the app uses. Edited on Config › Thresholds. Both sources share them.

### Daily summary

One optional object per source on `DailySummary`, written by the environment finalize step only when the kind landed that run:

```text
appInstallersHealth / patchPolicyHealth: {
  judged: Int            // enabled rows at or above the minimum scope with a share
  atWarning: Int         // judged rows at warning, not critical
  atCritical: Int
  warningPercent: Int, criticalPercent: Int   // the levels these counts were judged at
  minimumInScope: Int    // the floor these counts were judged at
}
```

*   **A day the kind did not land.** That day keeps an earlier same-day summary's group if it had one; otherwise the day has none: no Trends point, never yesterday's figures.
*   **Range checks.** The counts join `environmentCounts` (non-negative, within `maxSummaryNumber`), and `environmentFieldsAreConsistent` adds `atWarning + atCritical <= judged`, `1 <= warningPercent <= criticalPercent <= 100` and `minimumInScope >= 1`. A summary failing these does not decode (`NumberOutOfRange`), so the writer only ever writes values that pass them.
*   **Merging.** The fields are `private(set) var` on the memberwise init, and `filling(from:)` keeps the older group when the newer has none.

### Surfaces

Every surface below is left out on a Jamf School or Protect-only workspace and in a mobile-only fleet. Every printed percentage goes through `PercentFormat` (`config.percentFormat`). Deployment, policy and title names are organization-chosen labels, like the policy names the Policy Health sheet already shows: they are shown through `ConfigSchema.displayText`, never written to log lines, and not seeded into the redactor.

**Health Audit card** "Deployments and patch policies" (`DeploymentHealthSection`, under wave A's server-health card), one section per source:

*   Critical rows, then warning rows, each "name: N of M Macs failed (P%)", sorted by share descending, capped at 10 with "N of M shown".
*   "K judged, below the levels (warning W%, critical C%)".
*   "R not judged: X disabled, Y nothing in scope, Z under 10 Macs, U unmeasured" (parts that are 0 left out).
*   Source state instead of rows: "Not collected yet", "Not set up on this Jamf Pro server", "Could not be read", "None on this server".
*   On the patch-policy section: "Devices failing per title are on the Patch screen."

**Workbook tab** "Deployment Health" (`SheetID.deploymentHealth`), right after wave A's "Server and Admin Health" tab, one section per source:

| Section | Columns |
|---|---|
| App Installers | Name, Enabled, Macs in scope, Failed, Failed %, Level, Assigned to another deployment, Deployed version, Latest version, Version |
| Patch policies | Name, Enabled, Macs in scope, Completed, Deferred, Pending, Failed, Failed %, Level, Target version, Patch title |

Enabled rows first, by level then share; disabled rows after, under a "Disabled" heading row. The share is a percentage cell through `Workbook(percentFormat:)`. Skipped when neither snapshot exists.

**HTML report:**

*   "Needs attention": one sentence per source while any row is at a level, with one and many forms ("1 App Installers deployment has failed installs on W% or more of its Macs" / "N App Installers deployments have … of their Macs", and the patch-policy pair), linked through `attentionAnchors`.
*   A section `SectionID.deploymentHealth` (raw value `deployment_health`), last in the Patching group, with a table of the rows at a level capped at `HtmlSectionFormatters.maxFailureRows` with "N of M", critical first.
*   Its "Not included" reason when neither source was collected.

**Trends:** two metrics, `appInstallersAtLevel` and `patchPoliciesAtLevel`, each `atWarning + atCritical`, offered where a summary carries them (never in demo mode, never as Overview score cards). A change is measured only across days judged at the same levels and floor (`TrendStore.comparablePoints` with the basis `warning/critical/minimum`), and a note names the day the basis changed, as for the Security Score.

**Data Sources:** both kinds listed under Jamf Pro, shown by their command text like every source; App Installers in `notSetUp` reads "Not set up on this Jamf Pro server"; `patch-policies` gets its own "turned off" sentence (it does not feed the patch part of the Security Score).

**Data Freshness:** `expectedKinds` leaves out an advisory kind (it already takes `advisory:`); with the split it receives `advisoryCauses` over `notSetUpOnExit4Kinds`, so an on-prem server never shows App Installers as stale.

### What labels never say

"Failing" (the Patch screen's word for a title with under 50% of its devices on the latest version) and "behind" (its word for a version gap) are not used. The words are "failed installs", "at warning", "at critical", "pinned", "lagging".

## Risks and Mitigations

1.  **The stack depends on unmerged wave A.** Wave C is rebased onto any change to the wave A names above; reverting wave A reverts wave C.
2.  **A Jamf Cloud tenant with App Installers turned off may answer something other than exit 4.** That case reads as a normal failure until its answer is captured.
3.  **Output shape on jamf-cli 1.35-1.36 is unverified.** A payload that is not a list of objects saves nothing and records a failure.
4.  **An organization that turns off `app-status` or `patch-status` may never have granted the matching privilege.** The new source then fails with a missing-permission cause naming the privilege (a Partial run); `collect_skip` turns it off.
5.  **A workspace repointed from Jamf Cloud to on-prem keeps the "has landed" fact.** App Installers then fails on exit 4 (a Partial run) until `state/app-installers-deployments.last` is removed or the source is turned off.

## Alternatives Considered

### Alternative A: Patch titles that cannot patch

*   **Pros**: Flags an enabled patch policy that targets a version its title has no package for, or a title whose patch source is turned off.
*   **Cons**: Needs the patch software title configurations kind, which this wave does not collect. The weaker form, "titles with no packages", flags all 65 titles on the NFR server, since a server that patches through App Installers or only reports has none.
*   **Reason for Rejection**: Deferred, not rejected: it can be built later on this wave's `softwareTitleConfigurationId`. A patch title alone is information about an app's published versions and release dates, not something that patches.

### Alternative B: Enrollment pipeline (prestage scope and inventory preload against inventory)

*   **Pros**: Lists serials assigned to the organization that Jamf Pro has no record of.
*   **Cons**: Needs a new privilege that reads personal and purchasing data (preload), and no prestage shape has been captured (no ADE token on the test server).
*   **Reason for Rejection**: A serial assigned but never enrolled is normal (a Mac not built yet, or one decommissioned and still in Apple Business Manager), and neither source carries a date to tell those from a forgotten Mac. Inventory preload had no use left once the pipeline was dropped.

### Alternative C: A change-request window report in this wave

*   **Pros**: Matches how an admin works: put a release on a change request, watch adoption from the start date to the end, and file the result.
*   **Cons**: Needs a period model and per-version adoption.
*   **Reason for Rejection**: Per-version adoption is wave B's (B1), not built yet; the report gets its own wave on top of it.

### Alternative D: Failed share over the whole fleet

*   **Pros**: One denominator for every row.
*   **Cons**: A deployment to 40 Macs with every Mac failing would read under 10% on a fleet of 500.
*   **Reason for Rejection**: The fleet of a deployment or policy is the Macs in its scope.

### Alternative E: Counting `unqualified` in a deployment's scope

*   **Pros**: Matches the deployment's scope as configured.
*   **Cons**: The App Installers API defines `unqualified` as Macs in scope but assigned to another deployment of the same title; counting them dilutes the failed share (40 of 100 reads 10% with 300 such Macs added).
*   **Reason for Rejection**: Left out of the denominator and shown as its own column.

### Alternative F: Fixed levels

*   **Pros**: No configuration, no Config Doctor rows.
*   **Cons**: One fixed level cannot fit both a 30-Mac and a 30,000-Mac fleet.
*   **Reason for Rejection**: The levels are settings with defaults of 10% and 25%.

### Alternative G: Storing "rows at a level" without the levels they were judged at

*   **Pros**: One number per day, read directly by Trends.
*   **Cons**: A level change silently changes what every later point means, and nothing on disk says so.
*   **Reason for Rejection**: Each day's counts carry the levels and floor they were judged at, and Trends compares only days with the same basis.

### Alternative H: Widen the quiet rule to any failure of a kind that never landed

*   **Pros**: Covers every unknown answer from a server without the feature, with no capture needed.
*   **Cons**: Hides a real Jamf Cloud outage, timeout or credential problem for 7 days.
*   **Reason for Rejection**: The on-prem answer was captured (exit 4, `not_found`), and only that answer is quiet, only until the kind first lands.

### Alternative I: Decide "no App Installers" from the server's host name

*   **Pros**: No call needed on an on-prem server.
*   **Cons**: Jamf Cloud servers can use custom domains, and an on-prem server can sit on any name.
*   **Reason for Rejection**: The server's own answer decides.

### Alternative J: Add App Installers to wave A's `serverHealthKinds`, or rename that set

*   **Pros**: One line in wave C.
*   **Cons**: The set also switches on wave A's 1.38.0 version gate (an organization on jamf-cli 1.37 would never collect them), its skip on Platform API profiles (both wave C commands are served by the gateway), and the missing-permission quiet path.
*   **Reason for Rejection**: Those three behaviours are wrong for App Installers; wave C adds named sets and moves three reads to them.

### Alternative K: One per-source behaviour table replacing wave A's sets

*   **Pros**: Later waves add a row instead of splitting a set again.
*   **Cons**: Refactors wave A's reviewed and tested checks in several places.
*   **Reason for Rejection**: The two named sets cover this wave with three moved reads; a table stays a candidate if a later wave needs a further behaviour split.

### Alternative L: Opt-in collection and the missing-permission quiet path for these sources

*   **Pros**: Matches wave A's pattern exactly.
*   **Cons**: Read Mac Applications and Read Patch Policies are required by the default source set; a missing privilege here is a real problem to show.
*   **Reason for Rejection**: Collected by default; `collect_skip` is the off switch. The residual case is Risk 4.

### Alternative M: Alert keys in this wave

*   **Pros**: A webhook card when a deployment reaches a level.
*   **Cons**: A level alert repeats every day a deployment stays over it, and admins see the failure in Jamf Pro first.
*   **Reason for Rejection**: No alerts until a change-based rule is designed.

### Alternative N: Hold patch-policy findings until a failing fixture exists (wave B's rule)

*   **Pros**: No judgement shipped on an unseen shape.
*   **Cons**: Delays a source that production servers already use.
*   **Reason for Rejection**: A production server returned patch policies with exactly the captured keys and types, some with failures, so failing rows of this shape have been seen. Wave B's hold stays as it is: it covers wave B's own per-device patch parts, not this source.

### Alternative O: Patch-policy results on the Patch screen

*   **Pros**: One place for patch failures.
*   **Cons**: The Patch screen counts distinct devices failing per title, from `patch-device-failures`; a policy's figure is its own status counts over its own scope. The two answer different questions.
*   **Reason for Rejection**: The card judges deployments and policies by one rule and one set of levels, which the Patch screen does not have. The card's patch-policy section points to the Patch screen for devices per title.

## Detailed Implementation Plan

All paths are relative to the repository root; Swift sources are under `app/Sources/JamfReports/`, tests under `app/Tests/JamfReportsTests/` (engine suites in its `Engine/` folder). The branch is `feat/wave-c-deployment-health`, cut from `origin/feat/wave-a-server-health` at `f9ae3342`, and the PR targets `dev/2-13-0` as the next layer of wave A's stack.

The work lands in four phases. Each phase is one commit with its own tests and string sync, and ends at a checkpoint: `cd app && swift build --build-tests`, then the phase's suites through filtered `swift test`, all passing.

### Phase 1: the set split and collection

Caller: the collect path and Data Sources. Checkpoint suites: `DeploymentSourceReductionTests`, `DeploymentCollectTests`, `StateFileStoreAdvisoryTests`, `CollectPlanTests`, `CollectSourcesPlanTests`, `CollectionTierTests`, `FleetSidesTests`, `CommandCatalogTests`, `CLIHelpContractTests`, `JamfCLIInstallerTests`, `LocalizationCatalogTests`.

#### 1. `Engine/ReportEngine.swift` (Modify)

*   Add `"app-installers-deployments"` and `"patch-policies"` to `knownCollectKinds` (which makes them optional through `optionalKinds`), and two rows to the private `jamfProCommandMatrix`: `["-p", profile, "pro", "app-installers-deployments", "list", "--output", "json"]` and `["-p", profile, "pro", "patch-policies", "list", "--output", "json"]`. `CLIHelpContractTests.AppCommand.collectMatrix` already checks every matrix row; no new argument functions.
*   Add `static let deploymentKinds: Set<String> = ["app-installers-deployments", "patch-policies"]`, `static let notSetUpOnExit4Kinds: Set<String> = serverHealthKinds.union(["app-installers-deployments"])` and `static let untilFirstLandingKinds: Set<String> = ["app-installers-deployments"]`.
*   `recordUnlandedAttempt`: the exit-4 test reads `notSetUpOnExit4Kinds`.
*   Timeout: a kind in `deploymentKinds` gets `min(kindTimeout, serverHealthTimeout)`.
*   `saveCollectedPayload`: a branch for `deploymentKinds`, before the `serverHealthKinds` branch, calls `DeploymentSourceReduction.reduce(kind:payload:)`. Nil logs `[warn] <kind>: unexpected payload shape — snapshot not saved` and records `.failed(exitCode:)` with `FailureCause` kind `.other`.
*   `collect` plan inputs: `planInputs.deploymentSourcesSupported = JamfCLIInstaller.supportsDeploymentSources(detectedVersion)`.

#### 2. `Engine/DeploymentSourceReduction.swift` (Create)

*   `enum DeploymentSourceReduction { static func reduce(kind: String, payload: Data) -> Data? }`.
*   Reads a top-level array, `null` (as `[]`) or a `{results: [...]}` envelope.
*   Rebuilds each object with only the kept keys of the Collection table, each only with its stated JSON type, nested objects rebuilt with their kept keys only.
*   Returns the encoded array (empty array kept); nil for anything that is not a list of objects.

#### 3. `Engine/ReportEngine+CollectPlan.swift` (Modify)

*   `CollectPlanInputs.deploymentSourcesSupported: Bool = true`.
*   New `CollectSkipReason.deploymentSourcesUnsupported(installedVersion:)`, with its `skipDetail` ("needs jamf-cli 1.35.0 or later"), `planLabel` and position in `profileSkip` directly after `.dashboardUnsupported`.
*   `scheduleSkip`: for a kind in `deploymentKinds`, "not due" applies only when its last landing is on the current local day (the `planAddOn` rule).
*   The advisory hold already applies through `advisoryHold`, which covers `app-installers-deployments` by way of `isAdvisory`.

#### 4. `Services/JamfCLIInstaller.swift` (Modify)

*   `nonisolated static func supportsDeploymentSources(_ installedVersion: String?) -> Bool`: false for nil, for a version whose `versionParts` is empty, and below 1.35.0 through `compareVersions`; true otherwise. Same shape as `supportsDashboard`.

#### 5. `Services/StateFileStore.swift` (Modify)

*   `isAdvisory(kind:)`: guard on `notSetUpOnExit4Kinds`. The `notConfiguredOnServer` case returns true, except for a kind in `untilFirstLandingKinds` with `lastRun(report:) != nil`. The `missingPermission` case returns false unless the kind is in `serverHealthKinds`.
*   `advisoryCauses(profile:)` iterates `notSetUpOnExit4Kinds`.

#### 6. `Services/CollectionTier.swift` (Modify)

*   Both kinds on `.refresh` in `tierMap`.

#### 7. `Engine/ReportEngine+FleetSides.swift` (Modify)

*   Both kinds `.mac` in `sourceSides`.

#### 8. `Services/CommandCatalog.swift` (Modify)

*   `bundledCollectPrivileges.listed` gains "Read Mac Applications" and "Read Patch Policies", so it stays equal to the fixture's (`collectArguments()` picks up the matrix rows on its own).

#### 9. `Services/CollectSourcesPlan.swift` and `Views/SourcesView.swift` (Modify)

*   `CollectSourcesPlan` passes `deploymentSourcesSupported: JamfCLIInstaller.supportsDeploymentSources(inputs.installedVersion)` beside `supportsDashboard`.
*   App Installers in its advisory state uses the existing `.notConfigured` row state ("Not set up on this Jamf Pro server"); rows show their command text, as every source does.
*   `SourcesView.quietSentence(for:)` gets a branch for `patch-policies` before the `patch-` prefix rule: "Patch policy results stop updating. Screens and report tabs keep showing what was last collected, with its date; the daily summary stops using it."

#### 10. `Services/WorkspaceStore+Refresh.swift` and `Services/WorkspaceStore+Automation.swift` (Modify)

*   `expectedKinds` gains `deploymentSourcesSupported` (default `false`, as `dashboardSupported`) and drops both kinds when it is false; it drops any kind in `advisory`, whatever set it is in.
*   It receives `advisory:` from `StateFileStore.advisoryCauses` (now over `notSetUpOnExit4Kinds`). School and Protect-only workspaces already return early.

#### 11. `Models/DemoData+Admin.swift` (Modify)

*   Both kinds join `refreshKinds` and `snapshotBytes`, so Data Sources shows a demo date.

#### 12. Fixtures: `app/Tests/JamfReportsTests/Fixtures/deployment-health/` (Create)

*   `app-installers-deployments-list.json`: rows with the keys and types captured on the NFR server, values made up.
*   `patch-policies-list.json`: synthetic rows with the 11 captured keys and types, including failing, disabled and nothing-in-scope rows.
*   `app-installers-not-found.json`: the exit-4 error envelope with the error name `not_found`.
*   `README.md`: which file mirrors a capture and which is synthetic, and the jamf-cli versions seen.
*   No value from a production server appears in any fixture, test, doc or commit: production checks return aggregates only and stay off the repo. Test servers (the NFR server, Jamf's public test server) supply the shapes, with names and IDs replaced.

#### 13. Phase 1 tests

*   `app/Tests/JamfReportsTests/DeploymentSourceReductionTests.swift` (Create):
    *   kept and dropped keys for both kinds;
    *   wrong-type values left out;
    *   `null`, `[]` and a `{results}` envelope read as lists;
    *   a non-list returns nil.
*   `app/Tests/JamfReportsTests/Engine/DeploymentCollectTests.swift` (Create):
    *   exit 4 on App Installers never landed is `[info]`, advisory, not Partial and held 7 days;
    *   exit 4 after a landing is a failure;
    *   exit 4 on `patch-policies` is a failure;
    *   skipped below 1.35.0 and for an unknown version;
    *   collected on a Platform API profile;
    *   `collect_skip` turns each off;
    *   the first run of a new day collects both inside the 12-hour cadence;
    *   a nil reduction records a failure.
*   `JamfCLIInstallerTests` (Modify): `supportsDeploymentSources` for 1.34.9, 1.35.0, nil and an unparseable string.
*   `StateFileStoreAdvisoryTests` (Modify):
    *   wave A kinds unchanged;
    *   App Installers advisory only before its first landing;
    *   missing permission is not advisory for it.
*   `CollectPlanTests`, `CollectSourcesPlanTests`, `CollectionTierTests`, `FleetSidesTests`, `CommandCatalogTests` (Modify): the new kinds in the plan, the skip reason and its position, Data Sources' version check, the tier, the side, the privileges.
*   `EnvironmentProfilesGoldenTests`: its hash covers every row of `collectCommandMatrix`, so the two new rows change every Jamf Pro shape's `sha256`; the hashes are regenerated from the test's mismatch output and the router transcripts stay unchanged.

### Phase 2: calculator, configuration and surfaces

Callers: the card, the tab and the HTML land in this phase. Checkpoint suites: `DeploymentHealthTests`, `DeploymentHealthSheetTests`, `DeploymentHealthHtmlTests`, `ThresholdsConfigTests`, `ConfigDoctorValueRowsTests`, `ConfigServiceTests`, `SheetOrderTests`, `DemoDataDeploymentTests`, `LocalizationCatalogTests`, `HTMLWithWorkbookTests`.

#### 14. `Models/DeploymentHealth.swift` (Create)

*   **Types:**
    *   `enum DeploymentSource { case appInstallers, patchPolicy }` with its kind and display name.
    *   `struct DeploymentLevels { warning: Int; critical: Int; static let defaults = (10, 25) }`.
    *   `struct DeploymentRow { source; id: String; name: String?; enabled: Bool?; failed: Int?; inScope: Int?; assignedElsewhere: Int?; deployedVersion: String?; latestVersion: String?; updateBehavior: String?; completed/deferred/pending: Int?; targetVersion: String?; softwareTitle: String? }`, built per field from a reduced row (a wrong type reads nil). A row with no `id` is dropped and counted.
    *   `enum RowJudgement { notJudged, unmeasured, nothingInScope, belowMinimumScope, critical, warning, belowLevels }`.
    *   `enum VersionState { same, pinned, lagging, unknown }`.
    *   `enum SourceState { notCollected, notSetUp, unreadable, empty, rows([DeploymentRow], date: Date, leftOut: Int) }`.
    *   `struct SourceFigures { judged, atWarning, atCritical }`.
*   **Judging:** `static let minimumInScope = 10`. `static func judge(_ row: DeploymentRow, levels: DeploymentLevels) -> RowJudgement` applies the ordered rules of the Technical Plan.
*   **Loading:** `static func load(dataDir: URL, advisory: [String: FailureCause]) -> [DeploymentSource: SourceState]` follows `ProtectDashboardService.load`: `FileManager.newestJSONFile(in:)`, then `BoundedFile.readSnapshotLogged` rooted at the data folder, then decode. A planted newest file or a failed read or decode is `unreadable`.
*   **Figures:** `static func figures(_ rows: [DeploymentRow], levels: DeploymentLevels) -> SourceFigures`.

#### 15. `Engine/ConfigDecoder.swift` (Modify)

*   `ThresholdsConfig` gains `deploymentFailureWarningPercent: Int?` and `deploymentFailureCriticalPercent: Int?` (keys `deployment_failure_warning_percent`, `deployment_failure_critical_percent`), decoded through `c.wholeNumber` in the custom `init(from:)`, plus the matching `CodingKeys`.
*   `resolvedDeploymentLevels: DeploymentLevels`:
    *   each value outside 1-100 or missing becomes its own default;
    *   if warning > critical after that, both are 10 and 25.

#### 16. `Services/ConfigDoctorService+Values.swift` (Modify)

*   Both keys join `wholeNumberKeys` with defaults 10 and 25.
*   One new warn row per key outside 1-100, and one for warning above critical, each saying the levels the app uses (tags in the `thresholdValueRows` `.order` style).

#### 17. `Services/ConfigService.swift` and `Views/ConfigView.swift` (Modify)

*   `ConfigState` (`Services/ConfigService.swift:73`) gains two text fields.
*   They join `wholeNumberFields`/`setWholeNumbers` beside the disk percentages (save sites at 749-761 and 993-994), with the same `notAWholeNumber` handling.
*   Two fields on Config › Thresholds: "Deployment failure warning (%)" and "Deployment failure critical (%)".
*   `ConfigEditedKeys`' probe state sets non-default values, so both keys are recorded as edited.

#### 18. `config.example.yaml` and `app/Tests/JamfReportsTests/Fixtures/config/parsed/config.example.yaml.txt` (Modify)

*   Both keys under `thresholds`, uncommented, at their defaults, with a comment line each.
*   The golden is regenerated with `JRC_UPDATE_PARSE_GOLDENS=1 swift test --filter YAMLParseCharacterizationTests`.

#### 19. `Views/DeploymentHealthSection.swift` (Create) and `Views/AuditView.swift` (Modify)

*   The card as specified in Surfaces, built off the main actor in `AuditView.loadCached` through `ScreenLoad.paint`, from `DeploymentHealth.load` and the workspace's `resolvedDeploymentLevels`.
*   In demo mode it reads `DemoData.deploymentHealth`.

#### 20. `Models/DemoData+Deployments.swift` (Create)

*   A few deployments and policies sized from `DemoData`'s 524 Macs: one at warning, one pinned, one with nothing in scope, one disabled.

#### 21. `Engine/CoreDashboard+DeploymentHealth.swift` (Create), `Engine/CoreDashboard.swift`, `Engine/Templates/ReportTemplate.swift`, `Engine/Templates/FullInstanceTemplate.swift`, `Engine/Templates/OperationalTemplate.swift`, `Engine/Templates/CustomTemplate.swift` (Modify)

*   `SheetID.deploymentHealth = "Deployment Health"`, registered in `sheetPlan` right after `serverAdminHealth`, with a description in `sheetManifestDescriptions()`, in Full Instance and Operational, and mapped in `CustomTemplate.htmlSections` to `.deploymentHealth`.
*   The writer has the sections, columns and sort of Surfaces; every cell goes through `CellValue.safe`.
*   With neither snapshot, it throws `CoreDashboardError.noCachedData(names:)`.

#### 22. `Engine/HtmlReport+DeploymentHealth.swift` (Create), `Engine/HtmlReport+Inputs.swift`, `Engine/HtmlReport+Glance.swift`, `Engine/HtmlReport+Layout.swift`, `Engine/HtmlReport.swift` (Modify)

*   `Inputs` gains the two source states (an empty list kept as `empty`).
*   `SectionID.deploymentHealth` (raw `deployment_health`, with its `title`) goes last in `HtmlDetailGroup.patching`, rendered by the new file.
*   The attention sentences go in `HtmlReport+Glance.swift` with an `attentionAnchors` entry.
*   The "Not included" reason when neither source was collected.
*   Full Instance and Operational list the section.

#### 23. Phase 2 tests

*   `app/Tests/JamfReportsTests/DeploymentHealthTests.swift` (Create):
    *   each judgement rule in order;
    *   exactly 10% and exactly 25%;
    *   `unqualified` left out;
    *   a row with no `id` dropped, no `name` shown as "(no name)";
    *   pinned, lagging and unknown versions;
    *   each source state, including a planted newest file.
*   `ThresholdsConfigTests` (Create or Modify): defaults; one value out of range; a non-number; warning above critical; warning equal to critical.
*   `ConfigDoctorValueRowsTests`, `ConfigServiceTests` (Modify): the rows; the `apply` round trip of both keys.
*   `app/Tests/JamfReportsTests/Engine/DeploymentHealthSheetTests.swift` (Create): columns, order, sort, disabled block, skip.
*   `app/Tests/JamfReportsTests/Engine/SheetOrderTests.swift` (Modify): the tab after Server and Admin Health.
*   `app/Tests/JamfReportsTests/Engine/DeploymentHealthHtmlTests.swift` (Create): sentences in one and many forms; their absence below the levels; the cap with "N of M"; the "Not included" reason.
*   `app/Tests/JamfReportsTests/DemoDataDeploymentTests.swift` (Create): demo rows agree with the shared facts.

### Phase 3: daily summary and Trends

Checkpoint suites: `DeploymentSummaryTests`, `SummaryJSONParserTests`, `TrendStoreTests`, `TrendsViewNoDataTests`, `LocalizationCatalogTests`.

#### 24. `Services/SummaryJSONParser.swift` (Modify)

*   `struct DeploymentSummaryGroup: Codable, Equatable, Sendable { judged, atWarning, atCritical, warningPercent, criticalPercent, minimumInScope }`.
*   Optional `appInstallersHealth` and `patchPolicyHealth` as `private(set) var`, with `CodingKeys`, `decodeIfPresent`/`encodeIfPresent`, and the memberwise init.
*   `withEnvironment(products:protect:securityCloud:serverHealth:deployments:)` with `deployments: [DeploymentSource: DeploymentSummaryGroup]? = nil` sets a group only when given.
*   `filling(from:)` keeps the older group when the newer has none.
*   The counts join `environmentCounts`; `environmentFieldsAreConsistent` adds the checks of the Daily summary section.

#### 25. `Engine/ReportEngine+DeploymentSummary.swift` (Create)

*   `static func deploymentSummaryFigures(dataDir: URL, landed: Set<String>, levels: DeploymentLevels, now: Date) -> [DeploymentSource: DeploymentSummaryGroup]?`: a group for each kind in `landed` whose newest snapshot (at the run's `now`) decodes, built from `DeploymentHealth.figures`; nil when neither landed.

#### 26. `Services/CollectRouter.swift` and `Engine/ReportEngine+EnvironmentFinalize.swift` (Modify)

*   `CollectRouter.finalizeEnvironment` passes `deploymentLevels: config?.thresholds?.resolvedDeploymentLevels ?? .defaults` to `ReportEngine.finalizeEnvironmentSummary`.
*   `finalizeEnvironmentSummary` computes `deploymentSummaryFigures(dataDir:landed: landed[.jamfPro] ?? [], levels:now: day)` and passes the result to `withEnvironment(deployments:)`.
*   `freshSummaryIsBetter` and the keep-existing guard are unchanged: a landed Jamf Pro kind already makes the guard pass.

#### 27. `Models/Models.swift`, `Services/TrendStore.swift`, `Services/WorkspaceStore.swift`, `Views/TrendsView.swift`, `Engine/ChartPalette.swift`, `Models/OverviewLayout.swift`, `Views/OverviewView.swift` (Modify)

*   `TrendSeries.Metric` gains `appInstallersAtLevel` and `patchPoliciesAtLevel` in a `deploymentMetrics` list joined to the `init?(rawValue:)` union.
*   **Per metric:**
    *   labels "App Installers deployments at a level" and "Patch policies at a level";
    *   `unit` `""`, `isDeviceCount` false, `minY` 0, no `maxY` and no default goal;
    *   polarity `.lowerIsBetter`;
    *   `ChartPalette.hex(forMetric:)` reuses the existing slot of the nearest lower-is-better count metric, with no new slot;
    *   `OverviewLayout.dataRequirement` text "Needs App Installers deployments (or patch policies) collected";
    *   `OverviewView` drill-down caption and related destination Audit.
*   **Offering:** `WorkspaceStore.availableMetrics`/`isOffered` offer them on a Jamf Pro workspace whose loaded summaries carry the group, never in demo mode, never as Overview score cards.
*   **Values:** `TrendStore.offers`, `value(for:in:)` and `environmentValue` read `atWarning + atCritical`.
*   **Comparison:** `comparablePoints(of:in:)` uses the basis `"\(warningPercent)/\(criticalPercent)/\(minimumInScope)"`, and a basis note in the `securityScoreDefinitionNote` pattern names the day the basis changed, shown in `TrendsView`.

#### 28. Phase 3 tests

*   `app/Tests/JamfReportsTests/Engine/DeploymentSummaryTests.swift` (Create):
    *   groups written only for landed kinds;
    *   the levels, the floor and the run's `now` used;
    *   a non-landing day without an earlier same-day group has none;
    *   `filling(from:)`;
    *   each range check rejects a bad summary;
    *   an older summary without the keys decodes;
    *   `CollectRouter` passes configured levels.
*   `TrendStoreTests`, `TrendsViewNoDataTests` (Modify):
    *   the two metrics offered only with data;
    *   the change measured only within one basis;
    *   the basis note for no change, a level change and a floor change.

### Phase 4: docs

#### 29. `CHANGELOG.md`, `README.md`, `CLAUDE.md`, `AGENTS.md`, `docs/wiki/13-Permissions-and-Access.md` (Modify)

*   **CHANGELOG** Unreleased: Added (the two sources, the card, the tab, Trends); Changed (a new workbook tab after Server and Admin Health).
*   **README:** one line under what is collected.
*   **CLAUDE.md and AGENTS.md:** a short paragraph in the jamf_cli config section on the two kinds, `notSetUpOnExit4Kinds`/`untilFirstLandingKinds`, `DeploymentHealth` and the two keys.
*   **Permissions wiki:** both privileges for the new sources, and the gateway permissions `applications:read` and `patch-policies:read` for a Platform API profile.

#### 30. `app/Localization/Localizable.xcstrings` (Modify, every phase)

*   Each phase runs `app/scripts/sync-strings.zsh --prune-stale` and translates its new GUI strings into the six languages with `app/Localization/glossary.md`, so `LocalizationCatalogTests` passes at every checkpoint.
*   Workbook, HTML and log text stay English.

### Verification Plan

*   **Compilation/Build**: `cd app && swift build --build-tests` at every phase checkpoint.
*   **Unit Tests**: each phase's suites through filtered `swift test`; the full suite through the `tip-test` skill on the branch tip before the PR, with the counts reported.
*   **Swift 6.1 floor**: the `vm-test` skill in `ci-macos15-xcode16.4`, then `ci-macos26-xcode26.0.1`.
*   **Static Analysis & Linting**: no `.pre-commit-config.yaml`; `xcrun swift-format lint` on the touched files as a hint only.
*   **Localization**: `LocalizationCatalogTests` and `HTMLWithWorkbookGUITests.testNoTranslatedTextReachesAReportOrItsLog` (in `HTMLWithWorkbookTests.swift`) pass.
*   **Real data**:
    *   a collect against the NFR profile lands `app-installers-deployments` and a workbook shows the tab;
    *   a collect against `jamf-dummy` lands `patch-policies`;
    *   on a production on-premises server, one bounded run (aggregates only, nothing saved or committed) confirms App Installers is quiet and patch policies land.
*   **Visual**: the Health Audit card, the Config › Thresholds fields and the Trends series are layout changes. Their commit body is marked `DRAFT — needs visual verification`, and they are checked by Tony at the 2.13 RC.

--------------------------------------------------------------------------------

*Drafted with EGM*
