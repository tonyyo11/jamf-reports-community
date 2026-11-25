# Jamf Protect configuration posture (2.13 wave E)

*   **Author:** Tony Young
*   **Status:** Approved
*   **Date:** 2026-11-24
*   **Epic:** [#421](https://github.com/tonyyo11/jamf-reports-community/issues/421),
    section "Jamf Protect configuration posture"

--------------------------------------------------------------------------------

## Overview

Jamf Reports already collects four Jamf Protect sources (`protect-overview`,
`protect-alerts`, `protect-computers`, `protect-plans`) and shows them on the
Protect screen, the workbook's Protect tabs and the HTML report. This change comes
in two slices:

*   **E1** adds two small sources and turns three conditions the app can already
    half-see into findings: Macs whose threat-prevention signatures are behind what
    Protect has published, Macs whose Protect agent is behind the current
    installer, and Macs disconnected from Protect for more than a day. The findings
    go into the daily summary, so they get Trends lines and alert keys.
*   **E2** adds two neutral counts read from the `protect-plans` snapshot the app
    already saves: plans with no USB control set and plans with no prevent list.

It works wherever Protect is connected: beside Jamf Pro, beside Jamf School
(Experimental there, as all Protect support on School is), and in a Protect-only
environment.

### Terms

*   **NFR**: the maintainer's not-for-resale Jamf Cloud test server, used for
    read-only captures.
*   **Partial**: how Run History marks a run that logged a `[partial]` line; the
    tick retries such a run the same day.
*   **Freshness banner**: the health strip that lists sources gone stale or
    failing (`DataFreshnessHealth`).
*   **Floor**: the oldest jamf-cli the app runs, 1.29.0.
*   **Not evaluated**: the one wording for a finding the app cannot judge this
    time, always followed by the reason.

## The Problem

An admin running Protect cannot tell from Jamf Reports whether the agent fleet is
current or reachable:

*   **Signatures.** The Protect screen counts Macs behind the newest signature
    version *seen in the fleet* (`ProtectComputerRow.signatureLag`). If every Mac
    is one release behind, it reports none behind. Protect publishes its signature
    versions (`protect threat-prevention-versions list`, jamf-cli 1.38), but the app
    does not read the list.
*   **Agent version.** Each computer row carries the agent `version`, and
    `protect downloads summary` gives the current `installerVersion`. Nothing
    compares them.
*   **Disconnected Macs.** Each row carries `connectionStatus`, `lastDisconnection`
    and `lastDisconnectionReason`. The screen shows the connected share, but a Mac
    asleep for ten minutes and a Mac gone for a month look the same, and nothing is
    kept over time or alerted on.
*   **Configuration.** Plans with no USB control set or no prevent list are visible
    only in the Protect console.

None of these has history, so nobody can see whether things are getting worse, and
no webhook alert can fire on them.

## Goals

1.  **Three findings, the same everywhere they appear.** One calculator, read by
    the Protect screen, the workbook's Protect tabs, the HTML report and the daily
    summary:
    *   *Signatures behind*: a Mac whose `signaturesVersion` is older than the
        newest version Protect published at least 24 hours before `now`.
    *   *Agent behind*: a Mac whose agent `version` is older than the installer
        version, once that installer version has been seen in this workspace's
        snapshots for at least 24 hours.
    *   *Disconnected*: a Mac that is not connected and whose `lastDisconnection`
        is more than 24 hours before `now`, broken down by
        `lastDisconnectionReason`.
2.  **Absent is never zero.** Each finding is a `{met, of}` pair over the Macs that
    report the fields it needs. A finding whose input is missing, or whose baseline
    is not yet 24 hours old, is not evaluated (a dash with the reason), never 0.
3.  **History and alerts.** The three pairs go into `summary_<day>.json`, get Trends
    lines where Protect is connected, and get alert keys
    `protect_signatures_behind_count`, `protect_agent_behind_count` and
    `protect_disconnected_count`.
4.  **Older jamf-cli is not a failure.** `threat-prevention-versions` needs jamf-cli
    1.38, and `downloads summary` is gated at 1.35 (the oldest catalog that lists
    it). Below that version, or when the version is unknown, the source is skipped
    with a `[skip]` line naming the version it needs. Nothing is recorded, the run
    is not Partial, and the source is not expected by the freshness banner.
5.  **Nothing personal or secret reaches disk.** Each new source is reduced to a
    list of kept fields before it is saved; a payload that cannot be reduced is not
    saved.
6.  **One signatures figure.** `signatureLag` is replaced by the calculator. Without
    the published list (old jamf-cli, failed, turned off) the finding is not
    evaluated, with the reason; the app no longer compares against the fleet.
7.  **Neutral configuration counts (E2).** Plans with no USB control set and plans
    with no prevent list, from `protect-plans`. Shown on the Protect screen and the
    workbook's Protect Plans tab with no warning colour; not in the summary.
8.  **Works on every Protect environment**: Jamf Pro with Protect, Jamf School with
    Protect, Protect-only, and demo mode.

## Non-Goals

*   No write to Protect, ever. The only Protect commands the app runs stay
    read-only.
*   Deferred until someone asks: audit logs (changes by operation), users, roles,
    API clients, groups, data retention, and the analytic, USB control and prevent
    list set sources (sets attached to no plan). Their row shapes were captured on
    NFR with this design and are kept outside the repo, so a later wave does not
    repeat the capture.
*   No Security Score factor for Protect findings in this wave.
*   No configurable grace period: 24 hours is a named constant.
*   No new rule for a refused (403) source: it follows today's class (a permanent
    `FailureCause`, no same-day retry).
*   No change to whether a Protect-only workspace gets a workbook or HTML report;
    this wave adds to whatever Protect sections those already have.
*   No joining of findings to Jamf Pro or Jamf School devices.
*   No rewriting of snapshots already on disk.
*   No reduction of the four existing Protect kinds. `protect-computers` saves
    `hostname` and `lastConnectionIp`, and `protect-alerts` a host name; screens
    read the host name, so trimming them needs its own design (logged to #421).

## Assumptions

*   **`connectionStatus`.** A Mac is connected when
    `ProtectDashboardService.isConnected` says so (`Connected` or `online`). Every
    other value is not connected. A Mac with no `connectionStatus` is left out of
    `of`.
*   **`lastDisconnectionReason`.** One value seen on NFR. The breakdown shows
    Jamf's strings as given, capped like the management-health breakdowns (five
    most common, then "N of M values"), through `ConfigSchema.displayText`.
*   **Numbering.** On NFR on 2026-11-24 a Mac's `signaturesVersion` and the
    published `id` are both 5-digit integers, and agent `version` and
    `installerVersion` are both four dotted whole numbers. The comparison assumes
    they share a numbering; no Mac on NFR was on a listed version, so a match was
    not observed. The calculator accepts `id` as a digit string or a whole number.
*   **The published list is capped.** NFR returned 10 rows over 11 days. A Mac
    below the oldest listed `id` is behind by an unknown amount; it still counts as
    behind.
*   **A Mac newer than the installer** (an early-access agent) is not behind.

## Open Questions

*   **Protect permission per source.** Which Protect role permission
    `threat-prevention-versions list` and `downloads summary` need is unknown; a
    role-limited API client on NFR would show it, and also whether a refusal is
    exit 5 or a GraphQL `errors` body. Needed for the wiki's permissions page and to
    word the cause; behaviour follows today's class either way.

## Critical User Journeys (CUJs)

### CUJ 1: The whole fleet is a signature release behind

*   **Given**: a Jamf Pro workspace with Protect, jamf-cli 1.38, Protect published
    signature version N 30 hours ago, and every Mac reports N-1.
*   **When**: the daily collect runs.
*   **Then**: the Protect screen shows "Signatures behind: all Macs", naming version
    N and when it was published; the daily summary records the pair; an alert rule
    on `protect_signatures_behind_count above 0` fires. Today's screen would have
    said none behind.

### CUJ 2: A signature release a few hours old

*   **Given**: version N published 3 hours before the collect; most Macs still on
    N-1, which was published 2 days ago.
*   **When**: the collect runs.
*   **Then**: the baseline is N-1, so those Macs are not behind; a Mac on N-2 is.

### CUJ 3: Agent behind on a new workspace

*   **Given**: a Protect-only workspace collected for the first time today; the
    installer version is 5.x and some Macs run an older agent.
*   **When**: today's collect and tomorrow's collect run.
*   **Then**: today the finding reads "Not evaluated: installer 5.x first seen
    <time>"; tomorrow, once the oldest `protect-installer` snapshot holding 5.x is
    24 hours old, the older Macs count as behind.

### CUJ 4: Laptops asleep at collect time

*   **Given**: 40 laptops closed overnight and one Mac disconnected for nine days
    with a reason recorded.
*   **When**: the 06:00 collect runs.
*   **Then**: the laptops (disconnected under 24 hours) are not a finding; the one
    Mac is, with its reason shown in the breakdown.

### CUJ 5: jamf-cli 1.36

*   **Given**: a workspace on jamf-cli 1.36 with Protect.
*   **When**: the collect runs.
*   **Then**: `[skip] protect-signature-versions: needs jamf-cli 1.38.0 (installed:
    1.36.0)`; the run is not Partial; the freshness banner does not list the
    source; signatures behind reads "Not evaluated: needs jamf-cli 1.38"; the agent
    and disconnected findings work.

### CUJ 6: Jamf School with Protect

*   **Given**: a Jamf School workspace with Protect connected.
*   **When**: the collect runs.
*   **Then**: the three findings and the summary figures are as on Jamf Pro, marked
    Experimental with the rest of School's Protect support.

### CUJ 7: Configuration counts (E2)

*   **Given**: three plans, one with no USB control set and two with no prevent
    list.
*   **When**: the admin opens the Protect screen.
*   **Then**: a neutral "Configuration" card reads "Plans with no USB control set:
    1 of 3" and "Plans with no prevent list: 2 of 3", with no warning colour.

## Technical Plan (Architecture)

Paths are under `app/Sources/JamfReports`.

### Data flow

```text
CollectRouter (unchanged)
     │
     ▼
protectCollect ── reads the jamf-cli version itself (installedVersionOffMain on its own binary)
     │  planAddOn: collectSkip → needsJamfCLI → forced → hold → cadence
     │  run each planned command ──► reduce to kept fields (fail closed) ──► saveSnapshot
     ▼
jamf-cli-data/
  protect-computers/           (existing)
  protect-plans/               (existing; E2 reads it)
  protect-signature-versions/  NEW  [{id, created}]
  protect-installer/           NEW  [{installerVersion}]
     │
     ├──► ProtectAgentHealth.evaluate(computers, published, installer, now)  ── one calculator
     │        │   per-Mac results + three {met, of} findings
     │        ├── Protect screen card, Protect Computers tab, Protect Overview block, HTML section
     │        └── protectSummaryFigures ─► summary_<day>.json ─► Trends, alert keys
     │
     └──► ProtectConfiguration.counts(plans)  (E2, screen and workbook only)
```

### Sources

| Kind | Command | Min jamf-cli | Kept fields |
|---|---|---|---|
| `protect-signature-versions` | `protect threat-prevention-versions list` | 1.38.0 | `id`, `created` |
| `protect-installer` | `protect downloads summary` | 1.35.0 | `installerVersion` |

Captured shapes (NFR, 2026-11-24, keys and types only):

*   `threat-prevention-versions list`: an array, newest first, of
    `{id: string of digits, created: string, 27 characters, ISO 8601 with
    fractional seconds}`. List order is not trusted; the calculator sorts.
*   `downloads summary`: one object
    `{installerVersion: string, installerURL: string, uninstallerURL: string,
    has*: booleans}`. Only `installerVersion` is kept, saved as a one-row array.

Protect kinds come from `protectCommandMatrix`, through `allSourceKinds` and
`DataFreshnessHealth.protectKinds`; the two kinds join the matrix and nothing else
lists them by hand except the places named in the plan below. They are optional
everywhere (`collect_skip` can turn them off; only `protect-computers` is core, in
a Protect-only environment). They share `protect-computers`' cadence, so the
baseline and the computers it is compared with come from the same collect. They are
not added to `knownCollectKinds`, which is the Jamf Pro list. Kind names are new
on-disk names and never change.

### Version gate, one class

Today one source has a jamf-cli version gate: the dashboard (1.31,
`CollectSkipReason.dashboardUnsupported`, `JamfCLIInstaller.supportsDashboard`).
This wave adds another, so the gate becomes one table and one skip reason:

*   `ReportEngine.minimumJamfCLI: [String: String]` maps a kind to the version it
    needs (`dashboard` 1.31.0, `protect-signature-versions` 1.38.0, `protect-installer` 1.35.0,
    the oldest catalog that lists `protect downloads summary`).
*   `JamfCLIInstaller.supports(_ required:, installed:)` replaces
    `supportsDashboard`; an unknown or unparseable installed version answers false,
    as today.
*   `CollectSkipReason.needsJamfCLI(required:installed:)` replaces
    `.dashboardUnsupported`; its `[skip]` line reads
    `<kind>: needs jamf-cli <required> or later (installed: <version | unknown>)`. Nothing
    is recorded, as for every skip reason.
*   `planCollect` (dashboard), `planAddOn` (Protect), `WorkspaceStore.expectedKinds`
    and `CollectSourcesPlan` all read the table.
*   `protectCollect` reads the installed version itself with
    `JamfCLIInstaller.installedVersionOffMain(at:)` on the binary it already
    locates, as the Jamf School collect does. `CollectRouter` and the
    `ProtectCollect` closure type do not change. With no binary the version is nil
    and the gated kind is skipped.

### Reduction before disk

`protectCollect` saves raw bytes through `saveRecordingFailure` today. The new
kinds go through
`ReportEngine.reducingProtect(kind:data:)`, which follows `reducingSecurityRisk`'s
rules with a keep-list per kind: each row keeps only its listed keys, a kept key
keeps only a string, number or boolean, and a top-level `null` is an empty list.
For `protect-installer` a top-level object becomes a one-row array; any other
shape returns nil. An empty list (`null` or `[]`) lands an empty snapshot, read as
"Not evaluated: no published versions" or "no installer version". The reduction runs after the `isJSONSnapshot` check. A nil result is
not saved: it logs `[warn] <kind> not saved: unexpected shape`, records a failed
attempt with no `FailureCause`, and the kind is reported as not landed, so the run
is Partial like any source that did not land. The four existing Protect kinds are
saved as they are today (see Non-Goals).

### The calculator

`Models/ProtectAgentHealth.swift`, pure:

```text
ProtectAgentHealth.evaluate(
    computers: [ProtectComputerRow], published: PublishedList,
    installer: InstallerBaseline, now: Date) -> ProtectAgentHealth
```

`PublishedList` and `InstallerBaseline` each carry either a value or the reason
there is none (not collected, unreadable, needs jamf-cli 1.38, first seen too
recently). The result holds one `MacStatus` per row (signatures behind, agent
behind, disconnected: each yes, no or not evaluated), the three findings
(`{met, of}` or the not-evaluated reason, plus the baseline shown with it), the
disconnected breakdown by reason and a "disconnected, time unknown" count.

*   **Signatures behind.** Baseline = the highest `id` among published versions
    whose `created` is at least 24 hours before `now`. No usable entry (no list,
    every entry younger than 24 hours, no parseable `created`) makes the finding not
    evaluated. A Mac counts in `of` when its `signaturesVersion` is a whole number;
    it is in `met` when below the baseline. `signatureLag` is deleted.
*   **Agent behind.** `InstallerBaseline` is the newest `protect-installer`
    snapshot's `installerVersion` and its first-seen time: the filename stamp of the
    oldest snapshot holding that version. The finding is evaluated only when
    first-seen is at least 24 hours before `now`; otherwise it reads "Not evaluated:
    installer <v> first seen <time>". A Mac counts in `of` when its `version` parses
    as dotted whole numbers; it is in `met` when lower than the installer version
    (`JamfCLIInstaller.compareVersions` on parsed versions only, so an empty string
    is never "0").
*   **Disconnected.** A Mac counts in `of` when it has a `connectionStatus`; it is
    in `met` when `ProtectDashboardService.isConnected` is false and
    `lastDisconnection` parses (`ISO8601Time.parse`) to a time more than 24 hours
    before `now`. A disconnected Mac with no parseable `lastDisconnection` is in
    `of`, not in `met`, and counted as "disconnected, time unknown". The breakdown
    counts `met` Macs by `lastDisconnectionReason`.
*   **`now`.** Every consumer uses the newest `protect-computers` snapshot's
    filename stamp (`FileManager.snapshotDate(of:)`), read by `load`. The summary
    reads it only when `protect-computers` landed in this run, so it is this
    collect's stamp; the screen, workbook and HTML report opened a week later show
    what that collect saw, with the same 24-hour edges as the summary.

`ProtectComputerRow` already decodes `version` and `signaturesVersion`; it gains
`lastDisconnection`. `signaturesVersion` is read as an integer only when it is
whole.

**Reading the snapshots.** `ProtectAgentHealth.load(dataDir:)` reads through
`BoundedFile.readSnapshotLogged` (rooted at the data folder). A snapshot that is
there but cannot be read gives "Not evaluated: <kind> could not be read", never
"not collected". The first-seen scan lists `protect-installer` with
`snapshotFolderEntries`, keeps `isSelectableSnapshot` files that carry a filename
stamp (`CloudStorage.snapshotTimestamp`; a file with none is skipped, since a sync
provider rewrites mtimes), clamps a stamp later than `now` to `now`, orders oldest
first with `isOlderSnapshot`, reads at most 400 files and stops at the first that
holds the current version. If the cap is reached first, first-seen is the oldest
file read.

### Daily summary, alerts, Trends

*   `ProtectSummaryFigures` gains `agent` holding three `MobileSummary.Share?`
    values, from `ProtectAgentHealth.load(dataDir:)`. `protectSummaryFigures` fills
    each only when its inputs landed in this run: disconnected needs `protect-computers`; signatures needs
    `protect-computers` and `protect-signature-versions`; agent needs
    `protect-computers` and `protect-installer`. Its nil check counts the new group,
    so a run that measured only agent health still writes it.
*   `DailySummary` gains `protectSignaturesBehind`, `protectAgentBehind`,
    `protectDisconnected` (`{met, of}`), wired through `withEnvironment`,
    `filling(from:)`, `freshSummaryIsBetter` and `numbersAreInRange` (`met <= of`),
    as `protectMatched` is.
*   `AlertMetric` gains `protect_signatures_behind_count`,
    `protect_agent_behind_count`, `protect_disconnected_count`: the pair's `met`,
    nil when the pair is absent (no `?? 0`).
*   `TrendSeries.Metric` gains `protectSignaturesBehind`, `protectAgentBehind`,
    `protectDisconnected`: counts, lower is better, offered where the environment
    has Protect and a summary carries them, listed in the Overview's score card
    picker like the other Protect metrics.

### Surfaces

| Surface | Change |
|---|---|
| Protect screen | A "Protect agents" card: the three findings, each with its baseline ("version N, published 30 h ago" / "installer 5.x, first seen …"), the disconnected breakdown, and "Not evaluated: <reason>" when absent. Replaces today's signature line. |
| Workbook, Protect Computers tab | Three columns appended at the end, from the per-Mac results: Signatures behind, Agent behind, Disconnected over 24 h (Yes / No / blank when not evaluated). No existing column moves. |
| Workbook, Protect Overview tab | A "Protect agents" block after the existing rows: each finding as "N of M" with its baseline. |
| HTML report | A new "Protect agents" section, present whenever Protect is connected, and one "Needs attention" sentence per finding while its count is above zero. |
| Daily summary, Trends, alerts | As above. |
| E2: Protect screen, Protect Plans tab | A neutral "Configuration" card and a block after the plan rows. |
| Demo mode | Demo published list, installer history and computers, so each finding and E2 count is non-zero. |

### Environments

| | Jamf Pro + Protect | Jamf School + Protect | Protect-only | Demo |
|---|---|---|---|---|
| Collect | after the MDM collect, cadence rules | same, Experimental | every run | none |
| Protect screen card | yes | yes, Experimental | yes (it is the Overview) | demo data |
| Workbook / HTML | Protect tabs and section | Protect tabs (School workbook) | whatever it has today | no |
| Summary, Trends, alerts | yes | yes | yes | demo series |
| E2 counts | screen and Plans tab | same | screen | demo data |

### Slice E2: configuration counts

`Models/ProtectConfiguration.swift`, pure: from the newest `protect-plans`
snapshot it counts plans whose `usbControlSet` is absent or `""` and plans whose
`preventListSets` is absent or `""`, each as "N of M" plans. No snapshot reads "not
collected", an unreadable one "could not be read", never 0. Shown as a neutral
"Configuration" card on the Protect screen and a block after the plan rows on the
Protect Plans tab, with no colour and a caption saying the counts are
informational. Not in the summary. No new source.

## Alternatives Considered

### Alternative A: Every epic source in this wave

*   **Pros**: Closes the whole epic section at once; audit logs, users, roles, API
    clients, groups, retention and the set sources all have captured shapes.
*   **Cons**: Twelve or more new collect calls, each with a 60-minute limit, and a
    Protect-only workspace runs them all every run. Most neutral counts are already
    in `protect overview` and `protect plans list`. Users and API clients need their
    own privacy rules; audit logs overlap between collects and need de-duplication
    to cover more than 7 days.
*   **Reason for Rejection**: Rejected by author: only the signature list and the
    installer version feed a finding; the other sources add calls to every run for
    counts no finding reads.

### Alternative B: A state file for the installer's first-seen time

*   **Pros**: One small read; survives retention archiving old snapshots.
*   **Cons**: The state folder can be on shared storage, so the file needs rules
    for which Mac wins, a peer's future-dated time, a version going backwards and an
    unreadable file.
*   **Reason for Rejection**: Rejected by author: the oldest `protect-installer`
    snapshot holding the version gives the time with no new file and nothing for
    Macs to merge. Retention can only make that time later. Snapshot stamps are in
    the writing Mac's local time, so a peer in an earlier time zone or with a fast
    clock can make the finding start early by up to that difference; future stamps
    are clamped to `now`, and the risk is listed below.

### Alternative C: Keep the fleet comparison as a fallback

*   **Pros**: A workspace without the published list still gets a signatures
    figure; the epic asked to keep it.
*   **Cons**: It reports a uniformly behind fleet as none behind, the failure this
    wave exists to fix, and needs a basis label on every surface and a rule keeping
    it out of the summary.
*   **Reason for Rejection**: Rejected by author: the fallback can only under-report,
    and jamf-cli 1.38 is current; without the list the finding is not evaluated.

### Alternative D: Disconnected means "not connected at collect time"

*   **Pros**: No timestamp needed.
*   **Cons**: Every laptop closed at collect time counts; the alert fires every
    night.
*   **Reason for Rejection**: Rejected by author: disconnected for more than 24
    hours, the same grace as the other two findings, so one reading is enough.

### Alternative E: Two collects in a row before a Mac counts as disconnected

*   **Pros**: Less noise from a Mac that is restarting.
*   **Cons**: One collect of delay, and the previous snapshot has to be read.
*   **Reason for Rejection**: Rejected by author: the 24-hour rule already removes
    the noise this was for.

### Alternative F: A `grace_days` setting

*   **Pros**: An organization could set its own grace, as the Security Score does
    for macOS and XProtect currency.
*   **Cons**: A config key, a Config Doctor row, an editor field and a shared-config
    pin question for one value.
*   **Reason for Rejection**: Rejected by author: a named constant costs none of
    that, and a key can be added later without changing the stored figures' meaning.

### Alternative G: A new "a 403 is never Partial" rule

*   **Pros**: A least-privilege role would not mark every run Partial.
*   **Cons**: A new exception in `isCollectDead`, `retryCouldHelp` and the freshness
    banner, for every product, based on a refusal shape nobody has captured for
    Protect.
*   **Reason for Rejection**: Rejected by author: a refused source follows today's
    rule (permanent cause, no same-day retry). Which permission each new source
    needs is an open question.

## Risks & Mitigations

*   **Retired Macs.** A Mac never removed from Protect stays disconnected forever
    and keeps the count above zero. Accepted: the breakdown and the Computers tab
    name it, and removing it in Protect is the fix.
*   **Weekend closures.** A laptop shut Friday evening is about 60 hours
    disconnected at Monday 06:00. Accepted: an alert rule can use a threshold above
    the weekend's usual count.
*   **Held agents.** Macs on a plan with `autoUpdate` off may be held back on
    purpose and count as agent behind. Accepted and stated on the card's caption.
*   **One offline Mac in all three counts.** A Mac off for a week is disconnected
    and, as releases ship, behind on signatures and agent. Accepted: each finding
    is true; the per-Mac columns show the overlap.
*   **Capped published list.** A Mac below the oldest listed version is behind by an
    unknown amount. It counts as behind; no "how far" figure is shown.
*   **Peer stamps.** A peer's local-time or skewed stamp can start the agent finding
    early (see Alternative B). Mitigated by clamping future stamps; accepted for the
    rest.
*   **Release-day spike.** The day an installer or signature release passes 24
    hours, most of the fleet can count as behind until it updates. Accepted: that is
    the finding.

## Non-Functional Requirements

*   **Privacy.** The two new kinds hold no device, user or tenant identifier after
    reduction. E2 reads plan names already saved. No new value reaches a webhook
    card except the three counts.
*   **Cost.** Two small calls a run; the first-seen scan reads at most 400 small
    files through `BoundedFile` and usually stops at the first.
*   **Rollout.** No config key, no migration. An older summary has no new fields and
    reads as absent. A workspace on jamf-cli below 1.38 shows signatures behind as
    not evaluated.
*   **Workbook layout.** Columns and blocks are appended only; the CHANGELOG lists
    each one under Changed.

--------------------------------------------------------------------------------

## Detailed Implementation Plan

Build order, one PR each, stacked on `dev/2-13-0`: **E1a** (sources, gate,
reduction, expected kinds), **E1b** (calculator and Protect screen), **E1c**
(workbook and HTML), **E1d** (summary, alerts, Trends), **E2** (configuration
counts). Paths are under `app/` unless they start with `docs/` or are repo-root
files. Line numbers are as of commit `10ae87db` (the base of `dev/2-13-0` on
2026-11-24).

### E1a: sources, version gate, reduction, expected kinds

#### 1. `Sources/JamfReports/Engine/ReportEngine.swift` (Modify)

*   **Proposed Changes**: `protectCommandMatrix` gains
    `protect threat-prevention-versions list` → `protect-signature-versions` and
    `protect downloads summary` → `protect-installer`. Add
    `static let minimumJamfCLI: [String: String]` (`dashboard` 1.31.0,
    `protect-signature-versions` 1.38.0, `protect-installer` 1.35.0).
    `protectCollect` reads the version with
    `JamfCLIInstaller.installedVersionOffMain(at:)` on the `bin` it already
    locates (a `readVersion: (URL) async -> String?` parameter defaulting to it,
    so tests set 1.36 or 1.38 without a real binary) and passes it to `planAddOn`; for the two new kinds it saves
    `reducingProtect`'s output after the `isJSONSnapshot` check, and a nil result logs
    `[warn] <kind> not saved: unexpected shape`, records a failed attempt with no
    `FailureCause` and goes on `unlanded`. The dashboard planning (~2386) reads the
    table instead of `supportsDashboard`. `knownCollectKinds` does not change. The
    Protect-only `collectDead` count stays as it is.

#### 2. `Sources/JamfReports/Engine/ReportEngine+ProtectReduce.swift` (Create)

*   **Proposed Changes**: `reducingProtect(kind:data:) -> Data?` with a keep-list
    per kind (`protect-signature-versions`: `id`, `created`; `protect-installer`:
    `installerVersion`, an object wrapped as a one-row array), following
    `reducingSecurityRisk`'s rules (scalars only, `null` is `[]`, other shapes nil).
    Security Cloud's reducer is not changed.

#### 3. `Sources/JamfReports/Engine/ReportEngine+CollectPlan.swift` (Modify)

*   **Proposed Changes**: `CollectSkipReason.dashboardUnsupported` becomes
    `.needsJamfCLI(required: String, installed: String?)` with the skip detail
    `needs jamf-cli <required> or later (installed: <v | unknown>)` and plan grouping
    `needs jamf-cli <required> or later` (today's dashboard wording). `planCollect` checks the table. `planAddOn`
    gains `installedVersion: String? = nil` and checks in this order: `collectSkip`,
    `needsJamfCLI`, forced, timeout hold, cadence. The default keeps Security
    Cloud's and `RunStopTests`' calls unchanged (Security Cloud has no gated kind).

#### 4. `Sources/JamfReports/Services/JamfCLIInstaller.swift` (Modify)

*   **Proposed Changes**: `supports(_ required: String, installed: String?)`
    replaces `supportsDashboard` (same rule: nil or unparseable is false).
    `dashboardVersion` becomes the table entry.

#### 5. `Sources/JamfReports/Services/WorkspaceStore+Refresh.swift`, `WorkspaceStore+Automation.swift` (Modify)

*   **Proposed Changes**: `expectedKinds` drops a kind whose `minimumJamfCLI` entry
    the installed version does not meet, at all three places Protect kinds are
    added: the Protect-only and School early returns (~733, ~745, ~757) and the
    Protect append in `WorkspaceStore+Automation.swift` (~534), as well as the
    dashboard check (~772). `dashboardSupported:` becomes `jamfCLIVersion:`
    (callers in `FleetSidesTests` ~131 and `DashboardCollectTests` ~133 updated).

#### 6. `Sources/JamfReports/Services/CollectSourcesPlan.swift`, `Views/SourcesView.swift` (Modify)

*   **Proposed Changes**: the Jamf Protect group lists both kinds, with "needs
    jamf-cli 1.38" when gated; `dashboardSupported:` becomes the installed version.
    `SourcesView` gets the two display names.

#### 7. Other Protect-kind lists (Modify)

*   **Proposed Changes**: `Engine/ReportEngine+Dashboard.swift` (~53): the "every
    Protect source off" rule counts only the four original kinds, so turning off a
    new kind never drops Protect from the dashboard. `Services/EnvironmentCardState.swift`
    (~28) reads `DataFreshnessHealth.protectKinds`, so the Protect row's newest date
    includes the new kinds with no edit. `ProtectView` freshness chips (~66-69) and
    `ProtectDashboardService` loads and `sourceDates` (~97-100, ~164-167) are
    extended in E1b. `optionalKinds` and `AppCommand.protectMatrix` derive from the
    matrix and need no edit.

#### 8. `Tests/JamfReportsTests/Fixtures/jamf-cli/commands-1.38.0.json` (Create) and `commands-1.35.0.json` (Delete)

*   **Proposed Changes**: re-captured with `scripts/capture-jamf-cli-catalog.zsh` on
    1.38.0 so the contract sees both commands; `CLIHelpContractTests`,
    `CommandCatalogTests` and `CommandCatalog.swift` (~186, which cites the 1.35.0
    catalog) point at it; `AppCommand` lists the two new argvs. The bundled
    privilege table test is re-checked against the new fixture.

#### 9. `Tests/JamfReportsTests/Fixtures/jamf-cli-data/protect-signature-versions/`, `protect-installer/` (Create)

*   **Proposed Changes**: keys as captured from NFR on 1.38.0, values synthetic of
    the same type and form (digit-string ids, 27-character timestamps, a four-part
    version), with a README line saying so; one `id` as a whole number. Plus a
    raw-shape fixture for the reducer test holding every captured key and one
    unknown nested key.

#### 10. Tests (Create/Modify)

*   `CollectPlanTests`: `.needsJamfCLI` for the dashboard and
    `protect-signature-versions` at 1.37, 1.38 and nil; order against `collectSkip`
    and forced; no state written.
*   `ProtectReduceTests` (new): kept keys only; unknown nested key dropped; object
    wrapped for the installer; `null` and `[]` give an empty array; wrong shape nil.
*   `ProtectCollectTests` (new harness over `protectCollect` with a stub binary not
    named `jamf-cli` and `readVersion` injected): a payload that fails reduction records a failed attempt and
    is on `unlanded`; a gated kind on 1.36 leaves the run not Partial.
*   `ProtectOnlyCollectTests`, `SchoolProtectCollectHonestyTests`: gated kind on 1.36
    is not Partial and not dead.
*   `WorkspaceStore` expected-kinds tests (Protect-only, School + Protect, Pro +
    Protect) and `CollectSourcesPlanTests`: gated kind not expected below 1.38.
*   `DashboardCollectTests`, `JamfCLIInstallerTests`, `FleetSidesTests`: renamed
    gate, same behaviour. `CollectionTierTests` unchanged.

### E1b: the calculator and the Protect screen

#### 11. `Sources/JamfReports/Models/ProtectAgentHealth.swift` (Create)

*   **Proposed Changes**: as in the Technical Plan. `static let grace: TimeInterval
    = 24 * 3600`, `static let maxInstallerFiles = 400`; `PublishedSignature {id: Int,
    created: Date}` (`id` from a digit string or a whole number; `created` through
    `ISO8601Time.parse`, tested on the 27-character form); `PublishedList`,
    `InstallerBaseline`, `MacStatus` keyed by row index; the breakdown capped like
    `ManagementHealth.cappedValues`; `load(dataDir:)` with the readers named in
    the Technical Plan.

#### 12. `Sources/JamfReports/Engine/JamfCLIDecoder.swift` (Modify)

*   **Proposed Changes**: `ProtectComputerRow` gains `lastDisconnection` (the text as
    jamf-cli writes it; the calculator parses it with `ISO8601Time.parse`); `signatureLag` is
    deleted.

#### 13. `Sources/JamfReports/Services/ProtectDashboardService.swift` (Modify)

*   **Proposed Changes**: `Snapshot` carries `agentHealth`, loaded off the main
    actor with the other kinds, with `now` from the newest `protect-computers`
    filename stamp; `Snapshot.==` (~68-84) compares it; the two new kinds join
    `unreadableKinds` and `sourceDates`.

#### 14. `Sources/JamfReports/Views/ProtectView.swift` (Modify)

*   **Proposed Changes**: a "Protect agents" card replacing the signature line
    (~697), with the three findings, their baselines and "Not evaluated" reasons, and
    a caption for held agents; freshness chips (~66-69) gain the two kinds. DRAFT:
    needs visual verification at `PageScaffold.minSupportedWidth`.

#### 15. `Sources/JamfReports/Models/DemoData+Security.swift`, `DemoData+Admin.swift` (Modify)

*   **Proposed Changes**: demo computers gain `lastDisconnection`; a demo published
    list; a demo installer whose first-seen is more than 24 hours before
    `DemoData.referenceDate`; demo `protectKinds` and `snapshotBytes` (~193-204)
    include the two kinds; each finding non-zero.

#### 16. Tests

*   `ProtectAgentHealthTests` (new): the test matrix below.
*   `ProtectSignaturesTests`, `ProtectViewTests`: move from `signatureLag` to the
    calculator.
*   `ProtectDashboardServiceTests`: `Snapshot.==` sees a change in agent health.

### E1c: workbook and HTML

#### 17. `Sources/JamfReports/Engine/CoreDashboard.swift` (Modify)

*   **Proposed Changes**: the Protect Computers writer decodes rows through
    `ProtectComputerRow` for the calculator and appends three columns from the
    per-Mac results (header `ncols` 10 → 13, widths, the sheet description ~3249);
    the raw version cell (~2246) is unchanged. Protect Overview gains a "Protect
    agents" block after its last row, including when `writeProtectOverview` has no
    overview rows (its early return ~2141 moves below the block). School's Protect
    tabs share these writers.

#### 18. `Sources/JamfReports/Engine/Templates/ReportTemplate.swift`, `HtmlReport+Sections.swift`, `HtmlReport+Layout.swift`, `HtmlReport+Glance.swift` (Modify)

*   **Proposed Changes**: `SectionID.protectAgents` ("protect_agents"), built by a
    new builder reading the calculator, present whenever Protect is connected (not
    inside `buildProtectAlerts`, which is omitted with no open alerts), omitted with
    the same "protect.enabled is off" reason when Protect is not configured; in the
    detail group that holds `.protectAlerts`, after it, and in
    `FullInstanceTemplate` and every template that lists `.protectAlerts`.
    `attentionItems` adds one sentence per finding above zero, linked to the
    section.

#### 19. Tests

*   Protect tab tests: existing columns unchanged, new columns appended, blank when
    not evaluated; the Overview block written with no overview rows.
*   HTML tests: section present with no open alerts; sentence only above zero;
    `FullInstanceTemplate` covers the new `SectionID`.

### E1d: summary, alerts, Trends

#### 20. `Sources/JamfReports/Models/ProtectSummaryFigures.swift`, `Engine/ReportEngine+EnvironmentFinalize.swift` (Modify)

*   **Proposed Changes**: the `agent` group from `ProtectAgentHealth.load`; each
    share filled only when `landed`
    contains `protect-computers` and the finding's own kind; the nil check (~78)
    includes `agent`.

#### 21. `Sources/JamfReports/Services/SummaryJSONParser.swift`, `Engine/ReportEngine.swift` (Modify)

*   **Proposed Changes**: three `MobileSummary.Share?` fields in `DailySummary`
    (CodingKeys, memberwise init, `init(from:)`, `encode(to:)`), through
    `withEnvironment`, `filling(from:)`, `freshSummaryIsBetter`,
    `freshMeasuresNewEnvironmentField` (~596) and `numbersAreInRange`.

#### 22. `Sources/JamfReports/Services/MetricAlertEvaluator.swift` (Modify)

*   **Proposed Changes**: three `AlertMetric` cases returning the pair's `met`, nil
    when absent; listed as counts.

#### 23. Trends (Modify)

*   **Proposed Changes**: `TrendSeries.Metric.protectMetrics` (`Models/Models.swift`
    ~1151) gains the three metrics (counts, lower is better);
    `WorkspaceStore.protectMetricsOffered` (~219) offers them where Protect is
    connected and a summary carries them; `Services/TrendStore.swift`,
    `Engine/ChartPalette.swift`, `Models/OverviewLayout.swift`,
    `Views/OverviewView.swift` and `Models/DemoData+Summaries.swift` (demo series)
    follow.

#### 24. Tests

*   `MetricAlertEvaluatorTests`: absent pair never fires; `met` 0 never fires
    `above 0`.
*   `TrendStoreProtectMetricsTests`: offered only with Protect and data.
*   Summary tests: a figure from a run that did not land its kind is absent;
    `filling` keeps the earlier pair; `met > of` is out of range; a run that measured
    only agent health writes the summary.

### E2: configuration counts

#### 25. `Sources/JamfReports/Models/ProtectConfiguration.swift` (Create)

*   **Proposed Changes**: `counts(plans:)` over decoded `protect-plans` rows:
    plans with `usbControlSet` absent or `""`, plans with `preventListSets` absent
    or `""`, each `{met, of}`; `load(dataDir:)` through
    `BoundedFile.readSnapshotLogged`, unreadable kept apart from not collected.

#### 26. `Sources/JamfReports/Views/ProtectView.swift`, `Engine/CoreDashboard.swift`, `Models/DemoData+Security.swift` (Modify)

*   **Proposed Changes**: a neutral Configuration card (DRAFT visual) and a block
    after the plan rows on the Protect Plans tab; demo plans with one of each.

#### 27. Tests

*   `ProtectConfigurationTests` (new): absent and `""` both count; no snapshot is
    not collected; unreadable is unreadable.

### Docs (with the PR that changes the behaviour)

*   `CHANGELOG.md`: Added (findings, sources, configuration counts), Changed
    (signature count basis; each appended workbook column and block).
*   `CLAUDE.md` and `AGENTS.md`: the version-gate table, the two kinds and the
    shared reducer, `ProtectAgentHealth`, the summary fields and alert keys.
*   `config.example.yaml` (~376-377) and `docs/wiki/05b-Automation-Trust.md` (~257):
    the three alert keys.
*   `docs/wiki/03-App-Dashboards.md` (Protect screen), `06-Historical-Trends.md`
    (metrics), `05-Scheduling-and-Automation.md` (alert keys),
    `13-Permissions-and-Access.md` (Protect permissions, once known),
    `08-Jamf-School.md` (Experimental note).
*   Epic #421: tick the items this wave closes; add the deferred sources and the
    existing-kind reduction as items.

### Test matrix (calculator)

| Case | Expected |
|---|---|
| Newest published 30 h ago, all Macs one behind | all in `met` |
| Newest published 3 h ago, previous 2 d ago | baseline is the previous one |
| Published list absent / unreadable / all under 24 h / bad `created` | not evaluated, reason given; summary pair absent |
| Published list `null` or `[]` | empty snapshot lands; "Not evaluated: no published versions" |
| `id` as digit string and as whole number | same baseline |
| Mac below the oldest listed `id` | behind |
| `signaturesVersion` 1.5 or missing | Mac not in `of` |
| Installer first seen 2 h ago | agent finding not evaluated, reason given |
| Installer version went back (older than a previous snapshot's) | first-seen is the oldest snapshot holding the current version |
| Installer snapshot stamped in the future | stamp clamped to `now`, not evaluated |
| Installer snapshot with no filename stamp | skipped |
| More than 400 installer snapshots before the first match | first-seen is the oldest file read |
| Agent `version` empty or unparseable | Mac not in `of` |
| Agent newer than installer | not behind |
| Disconnected 2 h / 30 h / no `lastDisconnection` | not met / met / "time unknown" |
| `connectionStatus` `online` | connected |
| No `connectionStatus` | not in `of` |
| Pro + Protect, School + Protect, Protect-only, demo | same figures from the same snapshots |

### Verification Plan

*   **Build**: `cd app && swift build --build-tests` locally, and with Swift 6.1
    (Xcode 16.4, CI's macOS 15 job) for E1b and E1d, which add types used
    across actors.
*   **Tests**: `swift test` (full suite before each PR); filtered runs per slice
    while building.
*   **Lint**: `xcrun swift-format lint` on touched files as a hint.
*   **Live**: a collect against the NFR Protect tenant on jamf-cli 1.38.0 lands both kinds
    and matches the 2026-11-24 capture (three Macs not connected, counted as
    disconnected only past 24 hours; three agents behind the installer once its
    first-seen time is a day old).
*   **Visual**: the Protect screen cards stay DRAFT until the maintainer's visual pass at the RC.

--------------------------------------------------------------------------------

*Drafted with EGM*
