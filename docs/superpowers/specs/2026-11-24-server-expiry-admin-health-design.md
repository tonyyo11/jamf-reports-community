# Server and admin health

*   **Author:** Tony Young
*   **Status:** In Review
*   **Date:** 2026-11-24

--------------------------------------------------------------------------------

## Overview

Jamf Reports 2.13, wave A of epic [#421](https://github.com/tonyyo11/jamf-reports-community/issues/421). The app learns, from jamf-cli 1.38.0, when a Jamf Pro server's own credentials and server-side processes are about to fail, and it reports a small set of admin-hygiene counts when the organization opts in. It adds one Health Audit card ("Server and admin health"), one workbook tab (after every core tab), one "Needs attention" line per problem in the HTML report, optional daily-summary fields, alert rules and Trends series.

Default sources (Jamf Pro, read-only):

| Fact | Command | Shape seen |
|---|---|---|
| Built-in CA expiry | `pro certificate-authority active` (`notAfter`) | Live |
| SSO signing certificate expiry | `pro sso-settings cert get` (`keystoreDetails.expiration`) | Keys live, date format unseen |
| Volume purchasing token expiry, licence use | `pro volume-purchasing-locations list` | Unverified |
| ADE sync errors (newest sync per instance) | `pro device-enrollments syncs` | Unverified |
| Jamf Pro's own notifications | `pro jamf-pro-notifications list` | Unverified |
| Devices with push disabled | `pro apns-client-push-status list` | Unverified |

"Shape seen": **Live** means rows were returned on a test server and their keys and types are recorded in Appendix A; **Unverified** means the command answered with no rows, so the row shape is unseen; the fixture is captured before the kind is built.

Opt-in sources (off until the organization turns them on, counts only):

| Fact | Command | Shape seen |
|---|---|---|
| LAPS rotations stuck pending | `pro local-admin-password pending-rotations` (`totalCount`) | Wrapper only |
| Admin accounts (local vs federated, full access, password age, failed logins, status) | `pro accounts list` | Live |
| API clients (disabled, scopes, token lifetime) | `pro api-integrations list` | Live |

A Jamf School workspace gets nothing from this wave. jamf-cli 1.38.0 has no School command for certificates, tokens, notifications, admin accounts or API clients, and `school overview` holds only counts.

## Terms used in this document

*   **Acronyms**: CA, the certificate authority built into Jamf Pro that signs each Mac's MDM identity; SSO, single sign-on (SAML) to Jamf Pro; ADE, Apple's Automated Device Enrollment (Jamf's "device enrollment instances"); VPP, Apple's volume purchasing (Jamf's "volume purchasing locations"); LAPS, local administrator password solution; APNs, Apple Push Notification service; MDM, mobile device management.
*   **Wave A, epic #421**: the 2.13 plan is tracked in GitHub issue #421 (tonyyo11/jamf-reports-community), split into waves; this is the first. [#390](https://github.com/tonyyo11/jamf-reports-community/issues/390) tracks the Jamf Pro 11.32 to 11.34 API changes.
*   **jamf-cli exit codes** (as the app reads them): 0 success; 1 general or network error; 2 bad flags (a caller bug, or a command missing from an older jamf-cli); 3 credentials rejected (HTTP 401); 4 not found (HTTP 404); 5 privilege missing (HTTP 403); 6 rate limited (HTTP 429); 7 partial success; 8 refused because the profile's API does not publish that command (for example a Jamf Pro command on a Platform API profile). Some list commands print a `permission denied (HTTP 403)` line on stderr and still exit 0 with an empty list; the app already detects that line (`FailureCause.forbiddenStderrMarker`).
*   **Collect, kind, tier**: a collect runs one jamf-cli command per *kind* and saves its JSON as a dated *snapshot*. A kind *lands* when its snapshot is saved; the app then writes `state/<kind>.last`. Kinds belong to *tiers* with their own cadence: refresh (about every 12 hours), inventory (about every 48 hours), scan (weekly). `jamf_cli.collect_skip` is the existing opt-out list.
*   **Run outcomes**: a run whose kinds all landed is OK. A run in which an attempted kind did not land is **Partial** (the run log gets a `[partial]` line, Run History shows Partial, and the scheduler retries later the same day). A run in which nothing landed, or credentials were rejected, is **dead** and fails. After two failed attempts in a row a kind shows in the **health banner** above every screen. With `jamf_cli.use_cached_data: false`, any kind that does not land fails the whole run. A failure is recorded with its exit code and a classified *cause*; a *permanent* cause (for example a missing privilege) is one a retry would repeat, so automatic retries skip it.
*   **Screens**: the **Health Audit** screen holds cards of findings; **Config Doctor** (inside Health Audit) lists configuration and permission advice as rows; **Data Sources** shows each source with an on/off switch; **Trends** charts daily-summary figures over time. The **daily summary** is one JSON file per day of fleet figures that Trends, alert rules and reports read.
*   **Alert rules and alert messages**: `alerts:` rules in config.yaml compare a daily-summary metric with a threshold (`below` means strictly less than; `above` strictly greater) and post an **alert message** to the organization's Teams or Slack webhook. `notify.detail: full` sends figures; `minimal` sends only event facts. In this document "card" always means a Health Audit card, never a webhook message.
*   **Workspace and shared workspace**: a workspace is one folder per Jamf environment holding config.yaml, snapshots, state and reports. Several Macs can share one workspace folder through a sync provider or network share. Each Mac then pins the config.yaml values a peer could misuse (`SharedConfigPin`): a pinned value changed by another Mac, or by hand, is ignored on this Mac until its operator confirms it in Config Doctor. A change written by this Mac's own screens is confirmed for that value at the time of writing (`confirmWritten`), so the writing Mac needs no Confirm.
*   **`jamf_cli.keep_account_names`**: off by default; when on, the app keeps user names and emails it otherwise strips from saved snapshots (for example on the Computers inventory). The reductions in this design ignore it: nothing they drop is ever kept.
*   **Platform API profile, Protect-only environment**: a Platform API profile reaches Jamf Pro through Jamf's cloud gateway rather than the server's own API; a Protect-only environment has Jamf Protect and no Jamf Pro or Jamf School.

## The Problem

The certificates and tokens a Jamf Pro server depends on expire on dates nobody watches. When the built-in CA expires, Macs stop renewing their MDM identity. When the SSO signing certificate expires, admins and users cannot log in. When a volume purchasing token expires, app installs and updates stop. When ADE syncs fail, new devices enroll without their prestage. Jamf Pro shows some of these in its own notifications, but only to someone logged in to the console, and the app collects none of them today.

What the app already has is not enough:

*   `pro overview`, collected on every run, carries "Built-in CA Expires", "ADE Sync Status" and "Active Alerts" as display text. It has no SSO expiry, no volume purchasing token expiry and no notification types, and its wording is jamf-cli's, not a contract.
*   ADE token expiry is already collected and shown by 2.12's Management health (`EnrollmentTokenSnapshot`). This wave keeps it there and shares its expiry calculation; it does not collect the token again.
*   The APNs push certificate, the classic enrollment breaker, has no expiry date in jamf-cli 1.38.0 (only "APNs Certificate: OK" in the overview), so it cannot be added yet.

Admin hygiene is a second, smaller problem: admin accounts with full access and old passwords, API clients that were disabled but never removed, and LAPS rotations that never complete are invisible until an audit. Reading them needs privileges that many organizations will not grant a reporting login (LAPS rotations need the privilege that also reveals LAPS passwords), so they are opt-in and reduced to counts before anything is saved.

The proposed solution: add the sources above as typed collect kinds with a reduction before disk, one shared expiry calculator, one card, one tab, HTML lines, summary fields and state-change alerts. A refused permission on a new source is reported once in Config Doctor and does not make a run Partial.

## Goals

*   An admin sees, on the Health Audit and in the workbook, how many days remain until the built-in CA and SSO certificates and each volume purchasing token expire, and which are inside `thresholds.cert_warning_days` (default 90) or already expired.
*   One expiry calculator serves every credential, the 2.12 ADE token included, from the run's single `now`. An expired credential is a value (expired N days ago), never an error.
*   The ADE sync state, Jamf Pro notifications and push-disabled devices show as counts with a "Needs attention" line when above zero. Zero is shown only when the data proves it.
*   Upgrading to 2.13 with an unchanged API role shows, for the new sources, only one Config Doctor hint per refused source, naming the privilege. (The landing-guard fix can surface an existing source that was silently refused; see Risks.) A source that landed before and is later refused is reported like any other failing source.
*   The opt-in sources are off by default, are never attempted while off, have their own switch in Data Sources, are confirmed on each Mac of a shared workspace before they run, and are listed apart from the required privileges in onboarding.
*   No name, email, phone, distinguished name, Apple ID, client ID, keystore, password or LAPS username reaches disk, a log line, a webhook, the diagnostic bundle or AI input, whatever `jamf_cli.keep_account_names` says.
*   The daily summary stores expiry instants and fixed-definition counts only, so an expired certificate never makes a summary unreadable. An expiry alert rule posts at most one alert message per credential each time that credential crosses the rule's threshold and again when it expires, and Trends shows the counts.
*   Every new source has a captured fixture before its code merges.

## Non-Goals

*   Jamf School (no commands exist).
*   APNs push certificate expiry (no jamf-cli date).
*   LAPS settings (`settings get` needs a write privilege to read), LAPS passwords, history and audit.
*   Per-account or per-client lists: the opt-in half is counts only.
*   Reading values from `pro overview`'s display text.
*   Workspaces that reach Jamf Pro through a Platform API profile: these kinds are skipped at plan time until a gateway profile is tested.
*   Fixing anything on the server (no write commands).

## Open Questions

*   **SSO date format**: the test server has no SSO certificate, so `keystoreDetails.expiration` was null. Epoch seconds, milliseconds or ISO text is unknown until captured.
*   **Unverified shapes**: volume purchasing, ADE syncs, notifications and push status returned `[]`; LAPS returned only its wrapper. Each needs a capture from a server with data before its code merges.
*   **Notifications for an API client**: the reference says notifications are per user and site; whether an API client always sees an empty list on some servers is unknown.
*   **Privileges with none listed**: `pro certificate-authority active` and `pro jamf-pro-notifications list` list no privilege in the catalog. The real requirement comes from a 403 on a restricted role, not a guess.
*   **Notifications that repeat a credential**: once a notification fixture exists, decide whether credential-expiry notification types (CA, SSO, volume purchasing, ADE) fold into the credential rows so the HTML report does not state one expiring certificate twice, and whether any type carries an APNs signal.
*   **Platform gateway**: whether CA, notifications and the others are served through a Platform API profile is unverified (`api-integrations` is marked unserved).

## Critical User Journeys (CUJs)

### CUJ 1: A certificate is about to expire

*   **Given**: a Jamf Pro workspace whose API role can read the CA, and a built-in CA that expires in 40 days.
*   **When**: a scheduled collect runs.
*   **Then**: the Health Audit card shows "Built-in CA expires in 40 days", the workbook tab lists it, the HTML report has a "Needs attention" line, and a rule `server_credential_days_left below 45` posts one alert message for the CA on the first run under 45 days, and one more on the first run after it expires; never one a day.

### CUJ 2: Upgrading with an unchanged API role

*   **Given**: a 2.12 workspace whose API role lacks Read SSO Settings and Read Volume Purchasing Locations.
*   **When**: the first 2.13 collect runs.
*   **Then**: the run reads OK, not Partial; no health banner appears; Config Doctor shows one hint naming each missing privilege; the card shows "Not permitted: Read SSO Settings" for that row, never zero or a stale figure.

### CUJ 3: A privilege is removed later

*   **Given**: a workspace whose SSO expiry landed last week.
*   **When**: someone removes Read SSO Settings from the role and the next collect is refused.
*   **Then**: the source is reported as failing, like any source that stopped landing, and the card keeps the last known expiry with its date, marked as no longer measured.

### CUJ 4: Turning on admin hygiene on a shared workspace

*   **Given**: a workspace shared by two Macs, admin hygiene off.
*   **When**: an admin turns on "Admin accounts and API clients" in Data Sources on Mac A.
*   **Then**: Mac A's switch writes the opt-in and confirms its own write, so Mac A collects the counts on its next run; Mac B sees the changed value as drift and does not collect until its operator confirms it in Config Doctor; neither Mac writes a name or client ID to disk.

### CUJ 5: Jamf School workspace

*   **Given**: a Jamf School workspace.
*   **When**: any collect, report or Health Audit runs.
*   **Then**: none of these commands runs, the card and tab are not shown, and no hint appears.

## Technical Plan (Architecture)

### Data flow

```text
CollectRouter.run ─► ReportEngine.collect (Jamf Pro only; School never reaches it)
   planCollect ── skip: tier, collect_skip, opt-in off, jamf-cli < 1.38.0,
   │               Platform-auth workspace profile, refusal re-probed weekly
   ▼
collectOneKind(kind, timeout: serverHealthTimeout 180 s)
   │ exit 0, unless empty list + 403 stderr line (every kind, see Landing guard)
   │        ──► reduce<Kind>(payload)  (allow-list, always, ignores keep_account_names)
   │             └─► saveSnapshot(<kind>/<kind>_<stamp>.json) ──► .last
   │ not landed ──► recordUnlandedAttempt (existing path: failure + cause recorded)
   │     ├─ exit 4 ──► notConfigured (any time): [info], never Partial
   │     ├─ never landed AND (exit 5, or exit 0 + empty list + 403 line)
   │     │     ──► outcome marked advisory, dropped from the run's outcome list:
   │     │         [info] line, no [partial]
   │     └─ anything else ──► Partial as today
   ▼
ServerHealth.load(dataDir:, warningDays:, now:)   one reader, one calculator
   ├─► Health Audit card "Server and admin health"   (AuditView)
   ├─► workbook tab "Server and Admin Health"        (last tab)
   ├─► HtmlReport attentionItems sentences
   ├─► DailySummary fields (instants + counts) ──► MetricAlertEvaluator, Trends
   └─► Config Doctor rows (not permitted, opt-in name unknown)
```

### New collect kinds

All are Jamf Pro matrix rows (`jamfProCommandMatrix`), device side `.both` in `sourceSides`; the six default kinds are optional in `collect_skip` (`optionalKinds`), while the three opt-in kinds are not (their only switch is `collect_opt_in`); and collected only when jamf-cli is 1.38.0 or later (`JamfCLIInstaller.supportsServerHealth`, the `supportsDashboard` pattern: below it the kinds are skipped with `CollectSkipReason.serverHealthUnsupported` and recorded nowhere). 1.38.0 is the only version on which the commands were run; the gate moves down only after a run on an older binary.

| Kind | Command | Tier | Saved (allow-list) | Default |
|---|---|---|---|---|
| `certificate-authority` | `pro certificate-authority active` | inventory | `{notAfter}` (epoch seconds) | on |
| `sso-certificate` | `pro sso-settings cert get` | inventory | `{expiration}` as Jamf sends it; `{expiration: null}` when no certificate | on |
| `volume-purchasing-locations` | `pro volume-purchasing-locations list` | inventory | rows `{id, locationName, tokenExpiration, totalPurchasedLicenses, totalUsedLicenses}` | on |
| `device-enrollment-syncs` | `pro device-enrollments syncs` | refresh | newest row per `instanceId`: `{instanceId, syncState, timestamp}` | on |
| `jamf-pro-notifications` | `pro jamf-pro-notifications list` | refresh | rows `{type}` only; `params` and `id` are dropped until a captured fixture shows safe keys | on |
| `push-disabled-devices` | `pro apns-client-push-status list` | refresh | `{count}` | on |
| `laps-pending-rotations` | `pro local-admin-password pending-rotations` | inventory | `{totalCount}` | opt-in |
| `admin-accounts` | `pro accounts list` | inventory | counts: `{total, fullAccessLocal, fullAccessFederated, withFailedLogins, passwordOlderThanYear}` | opt-in |
| `api-integrations` | `pro api-integrations list` | inventory | counts: `{total, disabled, enabledWithTokenOverOneDay}` | opt-in |

Reductions run in `saveCollectedPayload` before any byte reaches disk, through one function per kind (`ServerHealthReduction`), and are not skipped when `jamf_cli.keep_account_names` is true. The counts for the three opt-in kinds are computed in memory from the response and only the count document is saved. A payload of an unexpected type (an object where a list is expected) is not saved and records a failure, as `reducingComputers` does today. `locationName` passes `ConfigSchema.displayText` at display time; it is an admin-chosen label, not a person.

Timeouts: the nine kinds run with `serverHealthTimeout` (180 s), not the 60-minute `collectKindTimeout`, through the per-call timeout `invokeWithRetry` already takes.

### Landing guard (every kind)

Today a kind lands when jamf-cli exits 0 (or 7) with a non-empty payload (`ReportEngine.swift`, the guard before `saveCollectedPayload`). jamf-cli can print `permission denied (HTTP 403)` on stderr and still exit 0 with `[]`, which then lands as an empty list. This is a defect of the class, not only of the new kinds: an empty list from a refused request must never read as zero. **Unverified**: the code path is real (read in `ReportEngine.swift`), but no capture yet shows jamf-cli printing `[]` together with the 403 line; the five empty captures in Appendix A showed only `page_fetch` lines on stderr and no 403. PR 0 starts by capturing one refused list command on a role that lacks its privilege (exit code, stdout bytes, stderr) and is dropped if jamf-cli never produces that combination. From 2.13, on every collect path that saves jamf-cli JSON (Jamf Pro, Jamf School, Protect, Security Cloud, Compliance Benchmarks; not the HTML dashboard), exit 0 or 7 with an empty payload (`null`, `[]`, `{}`, or a `results` array that is empty) AND the 403 line (`StderrSignalWatcher.sawForbidden`) goes to `recordUnlandedAttempt` with a missing-permission cause and is never saved. A non-empty payload is kept even when the 403 line appeared, since a command that makes several requests may have been refused on only one. Existing kinds that were silently landing `[]` on a 403 will now show as failing; the CHANGELOG says so. This fix ships as its own first PR (build step 0), separate from the new sources. For the nine server-health kinds, exit 7 (partial success) is also not saved, because a reduced count from a partial list would look complete.

### Refusal rule ("advisory kinds")

`ReportEngine.serverHealthKinds` is the set of the nine kinds. For a kind in that set, an attempt is a **refusal** when jamf-cli exits 5, or exits 0 while `StderrSignalWatcher` saw the 403 line, AND the kind has never landed on this workspace (no `state/<kind>.last`). The refusal is a property of the workspace's API role, so it lives in the shared `state/` folder with every other failure; a peer can forge or delete a state file, which the project already rates Low and bounds with the future-stamp guard below. A refusal:

*   records the failure through the existing `StateFileStore.recordFailure` path with its cause (`FailureCause.missingPermission`, names from jamf-cli's hint), and its failure date. `StateFileStore.isAdvisory(kind:)` = a kind in `serverHealthKinds` whose stored cause is `notConfiguredOnServer` (any time), or `missingPermission` with no `.last`; never true for any other kind;
*   logs `[info] <kind>: not permitted for this login (<privilege>, when jamf-cli named one); see Config Doctor`, never `[partial]`;
*   is decided inside `recordUnlandedAttempt`, after the failure is recorded and before its `use_cached_data: false` abort, and returned as an advisory outcome that the collect loop does not keep, so `degradedKinds`, the dead-run verdict, the abort and any verdict added later never see it; `DataFreshnessHealth` and `expectedKinds` read the same predicate;
*   is re-probed quietly: scheduled and automatic runs skip it at plan time (`CollectSkipReason.notPermitted`) until 7 days after the stored failure date, measured from the run's `now`, through `StateFileStore.advisoryHoldUntil(report:now:)`, a sibling of `timeoutHoldUntil` that reuses its future-stamp guard (a date more than `SharedWorkspace.clockSkewTolerance` ahead reads as absent, so a forged stamp can only cause an early probe). This is how a privilege added to the role in Jamf Pro is picked up without anyone opening the app; Collect now picks it up at once, and the Config Doctor hint says so. A re-probe that is refused again refreshes the date silently; one that lands clears the cause and the kind joins `expectedKinds`. Collect now (`force`) probes at once.

**Exit 4** (not found) on a server-health kind means the feature is not set up on the server (no SSO, no volume purchasing). At any time, landed before or not, it records the new `FailureCause.Kind.notConfiguredOnServer` (permanent), logs `[info] <kind>: not set up on this Jamf Pro server`, is dropped from the run's outcomes like a refusal, and shows as "Not set up on this server", never as a privilege to add. It is held by the same `advisoryHoldUntil` (skip reason `CollectSkipReason.notConfigured`) and re-probed weekly; Collect now overrides it.

A kind that has landed before keeps today's behaviour on any other failure: Partial, the banner after two failures, the existing missing-permission wording. Timeouts, exit 1, exit 2, exit 3, exit 6, exit 7 and decode failures are never refusals. Timeouts (exit -2) are not retried inside a run (`retryableExitCodes` is {1, 6}), so the nine kinds add at most 27 minutes to a run in the worst case (all nine hanging), against the 45-minute default run budget, which stops between sources as today. Exit 8 does not reach this rule: a workspace whose own profile uses Platform auth skips all nine kinds at plan time (`CollectSkipReason.serverHealthNotOnGateway`) until a gateway profile is tested.

### Opt-in

One new key, `jamf_cli.collect_opt_in` (a list of kind names, like `collect_skip`; absent or empty means none). Only `laps-pending-rotations`, `admin-accounts` and `api-integrations` are accepted; anything else is ignored and Config Doctor names it. It is pinned per Mac in `SharedConfigPin` with the `keep_account_names` rule: a name removed applies at once, a name added (and every name at first sight, and when an existing pin first learns the key) waits for a Confirm on this Mac. `SharedConfigPin.collectOptIn(configured:profile:)` is the one reader. `planCollect` skips an opt-in kind that is not in the effective list with `CollectSkipReason.notOptedIn`, which `CollectSourcesPlan` shows as an off switch. `CollectSkipConfigWriter` is generalised into one list-key writer parameterised by key and allowed set, and writes `collect_opt_in` through the same `saveBlock` and `confirmWritten` path it uses for `collect_skip`; while the key has drifted it writes a removal (which only narrows) and refuses an addition. `expectedKinds` contains an opt-in kind only when it is in the effective list.

Data Sources shows three switches, one per opt-in kind, each off by default: "LAPS rotations pending (needs View Local Admin Password, which can also read LAPS passwords)", "Admin accounts (needs Read Accounts; counts only)" and "API clients (needs Read API Integrations; counts only)". While LAPS is opted in, Config Doctor shows a warn row saying the reporting login holds a privilege that can read LAPS passwords. Turning a kind off stops its collect at once; its snapshots stay on disk under the normal retention rules but are no longer shown on the card or tab, and `lapsPendingCount` stops being written, so Trends shows a gap.

`CommandCatalog.collectArguments()` leaves the opt-in argvs out, so onboarding's required-privilege list never includes Read Accounts, Read API Integrations or View Local Admin Password. A new `CommandCatalog.optionalPrivileges()` lists them under "Optional, only if you turn on admin hygiene", and the LAPS line says that this privilege can also read LAPS passwords.

### One expiry calculator

`CredentialExpiry` (`Models/CredentialExpiry.swift`) generalises `EnrollmentToken.State`: `{key, label, source: day(String) | instant(Date), expiresText: String?, daysLeft: Int?, state: expired | expiring | ok | notReported}`, built from either a local calendar day (ADE `tokenExpirationDate`, volume purchasing `tokenExpiration` if date-only) or an instant (CA `notAfter` seconds; SSO `expiration` once its format is captured). `warningDays` comes from `ThresholdsConfig.resolvedCertWarningDays`. `daysLeft` is whole calendar days from `startOfDay(now)` in the Mac's calendar; `expiring` is `daysLeft <= warningDays`. A date-only credential is `expired` when `daysLeft` is negative; an instant credential is `expired` as soon as `now >= expiresAt`, so it never reads "expiring" on the day it has already passed. `EnrollmentToken` keeps its API and computes its state through `CredentialExpiry.state(daysLeft:warningDays:)`, so the ADE token and the new credentials agree. `warningDays` is `thresholds.cert_warning_days` (default 90, `ManagementHealth.defaultWarningDays`); the Config screen's label becomes "Certificate and token expiry warning" (the row already shows the unit), key unchanged.

### ServerHealth model

`ServerHealth.load(dataDir:warningDays:now:)` (`Models/ServerHealth.swift`) reads the newest snapshot of each kind through `BoundedFile.readSnapshotLogged` and the state folder, and returns one value per fact in one of seven states:

*   `notCollected`: never attempted (no snapshot, no recorded failure). The card row is hidden.
*   `notConfigured`: exit 4; shown as "Not set up on this server".
*   `notPermitted(privileges)`: an advisory refusal. Shown as "Not permitted: <privilege>"; when jamf-cli named no privilege (as for the CA and notifications commands, whose privilege the catalog does not list), "Not permitted for this login".
*   `failed(cause)`: attempted, never landed, not a refusal (timeout, exit 1, decode failure). Shown as "Could not be collected: <cause label>".
*   `unreadable`: the newest snapshot exists but cannot be read.
*   `none`: landed with no rows; shown as 0. A kind lands only after its fixture exists (see Captured fixtures), so a landed empty list is a real zero.
*   `value(figure, stale: Date?)`: landed with data; when the kind has failed since it last landed, `stale` holds the snapshot date and the row reads "as of <date>, no longer measured". A credential whose expiry field is missing or in an unknown format (`CredentialExpiry.notReported`) is shown as "expiry not reported" in its row; it is not counted as expiring. Notifications at zero read "none visible to this login", because Jamf Pro filters notifications by user and site and an API client may see none even when an admin does. ADE token expiry comes from `EnrollmentTokenSnapshot` (2.12's reader), never from a new source, and is listed on this card beside the other credentials only by reference ("ADE tokens: see Management health"), so it is shown once. ADE sync rows carry only an instance ID; the card names the instance from the existing `device-enrollment-instances` snapshot, whose saved `name` is an admin-chosen label (2.12 keeps it), shown through `ConfigSchema.displayText`. The new kinds save no names.

### Surfaces

*   **Health Audit card** `ServerHealthSection` (`Views/ServerHealthSection.swift`), after the Management health card in `AuditView`, built off-main in `loadCached`. Rows: Credentials (CA, SSO, each volume purchasing token, with days left and state), ADE syncs failing (instances whose newest sync is not successful), Jamf Pro notifications by type (Jamf's type names, through `displayText`, sorted by count then name, the five most common with "5 of M types"), push-disabled devices, licence use per volume purchasing location (used of purchased), and, when opted in, LAPS pending, admin and API client counts. Hidden on a Jamf School workspace and when no kind has ever been attempted.
*   **Workbook tab** `SheetID.serverAdminHealth`, "Server and Admin Health", last in the Full Instance and Operational templates' sheet lists (after every core tab; EA and Charts tabs follow). Sections in fixed order: Credentials, ADE syncs, Notifications, Push, Volume purchasing licences, Admin hygiene (opt-in). Skipped with no landed kind. The CHANGELOG names the new tab.
*   **HTML report**: `HtmlReport.attentionItems` adds one sentence per expired or expiring credential (except ADE tokens, which 2.12's Management health sentence already states), failing ADE sync, notification type and push-disabled count above zero. No new section.
*   **Daily summary** (optional fields, absent when not measured; written by `finalizeEnvironmentSummary`):

    | Field | Type | Source | Written when |
    |---|---|---|---|
    | `serverCredentialExpiries` | `[String: CredentialExpiryEntry]`, key `ca`, `sso`, `vpp:<id>`, `ade:<id>`; entry `{expires, asOf}` | newest landed snapshot of each credential kind (`ade:<id>` from `device-enrollment-instances` via `EnrollmentTokenSnapshot`) | every collect that writes a summary, from the newest landed snapshot if it is within `jamf_cli.max_cache_age_hours` (default 168), so an inventory-tier kind (every 48 h) is present every day |
    | `adeSyncFailingCount` | Int | `device-enrollment-syncs` | the kind landed this run |
    | `jamfProNotificationCount` | Int | `jamf-pro-notifications` | the kind landed this run |
    | `pushDisabledCount` | Int | `push-disabled-devices` | the kind landed this run |
    | `lapsPendingCount` | Int | `laps-pending-rotations` (opt-in) | the kind landed this run |

    `expires` is text: an ISO 8601 instant for CA and SSO, a `yyyy-MM-dd` day for date-only credentials (ADE, and volume purchasing if date-only), so Macs in different time zones store the same text; `asOf` is the snapshot's date. Text never meets `numbersAreInRange`; the counts join `environmentCounts`. `filling(from:)` and `withEnvironment` carry them per group like the Protect pair. Admin-account and API-client counts are not in the summary: they are opt-in, change only when an admin edits the server, and are read from the newest snapshot; the LAPS pending count is, because rotations pile up between runs.
*   **Alerts**:
    *   New metric keys: `server_credential_days_left`, `ade_sync_failing_count`, `jamf_pro_notification_count`, `push_disabled_count`, `laps_pending_count`. None is a percentage (`AlertMetric.isPercentage` lists them false). The four counts are ordinary single-value metrics.
    *   `server_credential_days_left` accepts only `below`; `resolvedRules` drops `above` and `drops_more_than` for it with the existing Config Doctor row. It is evaluated once per entry of `serverCredentialExpiries` (a separate entry point, `MetricAlertEvaluator.evaluateCredentials`; `value(in:)` is unchanged and returns nil for this metric); days come from `CredentialExpiry` and the run's `now`, and may be negative.
    *   A hit's key is (rule, credential key, `expires` text, state), where state is `hit` (days below the threshold, not expired) or `expired`. So a credential posts at most twice per expiry: once crossing the threshold and once on expiring.
    *   Dedup extends the existing `MetricAlertLedger` file (one ledger): its record gains an optional `credentialKeys: [{rule, key, expires, state}]` beside the daily `{day, keys}`, kept across days. Read before the send, written after a confirmed send. Because the key contains the `expires` text, a renewed credential is a new key; an entry is pruned only when its `expires` is more than 60 days in the past. No snapshot is read by the evaluator. A planted entry can silence only one exact (credential, expiry, state) triple. An unreadable ledger fails toward sending, as `MetricAlertLedger` does today (a message on each run until it is readable again). A 2.12 build writing the file drops `credentialKeys`, which re-sends each credential's current state once.
*   **Trends**: a gated metric group like Protect's (raw values `serverCredentialSoonestDays` (computed from the stored expiries and each summary's date, higher is better, a day axis that can go below zero), `adeSyncFailing`, `jamfProNotifications`, `pushDisabled`, `lapsPending` (lower is better)), offered only on a Jamf Pro workspace whose summaries carry them, never in `schoolMetrics` or demo history.
*   **Config Doctor** (`ConfigDoctorService+ServerHealth.swift`): `server_health.not_permitted` (suggest, one row listing each refused kind and its privilege, hint "Add the privilege to the API role, then Collect now"; when no privilege is known, "this login cannot read <source>; check the API role's privileges for it"), `server_health.opt_in_unknown` (warn, a `collect_opt_in` name that is not opt-in), `server_health.laps_privilege` (warn while LAPS is opted in: the login can read LAPS passwords), and the opt-in drift row through the existing shared-config block.
*   **Demo mode**: `DemoData+ServerHealth.swift` figures derived from `DemoData.referenceDate`, asserted in a test; no workspace read.

The full new-source chain (`knownCollectKinds`, tier, `expectedKinds`, `CollectSourcesPlan`, catalog privileges, `freshSummaryIsBetter`, `retryCouldHelp`, the HTML appendix reason, demo data) is listed per file in the Detailed Implementation Plan.

### Product and environment gates

The kinds are Jamf Pro matrix rows, so a Jamf School workspace and a Protect-only environment never run them (`CollectRouter`, `proCommandRefusal`). `expectedKinds` adds them only for a Jamf Pro workspace. The card, tab and HTML lines read snapshots that only a Jamf Pro collect writes, and the card checks `environmentProducts.has(.jamfPro)`.

### Captured fixtures

`app/Tests/JamfReportsTests/Fixtures/server-health/`, one file per command, from real output with every value replaced by a synthetic value of the same JSON type and format (keys, nesting and types exactly as captured), plus a README naming the server version and capture date. CA, accounts and API integrations are captured from the test server now. The other six are captured from a server with data before the PR that adds their kind merges; the kind, its matrix row and its fixture land in the same PR (a test asserts every matrix kind has a fixture). There is no runtime "unverified" state.

## Alternatives Considered

### Alternative A: Parse `pro overview` display text

*   **Pros**: no new command, no new privilege; CA expiry and ADE sync status are already there.
*   **Cons**: wording and date format belong to jamf-cli's display, not a contract; no SSO, volume purchasing or notification types; one changed word silently breaks the figure.
*   **Reason for Rejection**: Rejected by author: display text is not a contract, and it has no SSO, volume purchasing or notification fields.

### Alternative B: Extend the Management health card and tab

*   **Pros**: one card instead of two; ADE token expiry already lives there.
*   **Cons**: Management health is per-Mac; mixing server credentials and admin counts into it makes both harder to read.
*   **Reason for Rejection**: Rejected by author: a per-Mac card mixed with server facts is harder to read; sharing the expiry calculator gets the reuse without merging the cards.

### Alternative C: Store days left in the daily summary

*   **Pros**: Trends and alerts read the figure directly.
*   **Cons**: an expired certificate is a negative count, which `numbersAreInRange` rejects, making the whole day unreadable; the figure also changes meaning with `cert_warning_days`.
*   **Reason for Rejection**: Rejected by author: a negative count drops the whole day's summary; storing expiry text and computing days when read avoids it.

### Alternative D: Every refused permission quiet

*   **Pros**: simplest rule.
*   **Cons**: a privilege removed from a role later would hide a source that used to land.
*   **Reason for Rejection**: Rejected by author: a privilege removed later would hide a source that used to land, with no signal.

### Alternative E: LAPS settings (`local-admin-password settings get`)

*   **Pros**: shows whether auto-rotate is on.
*   **Cons**: reading it needs Update Local Admin Password Settings, a write privilege; it is configuration, not health.
*   **Reason for Rejection**: Rejected by author: needs a write privilege on a read-only reporting login, and it is configuration, not health.

### Alternative F: Opt-in as a `collect_skip` default list

*   **Pros**: no new key.
*   **Cons**: `collect_skip` is opt-out; an absent key would then collect the sensitive kinds, and shared-workspace pinning of `collect_skip` lets a later Mac's empty list turn them on.
*   **Reason for Rejection**: Rejected by author: an opt-out list would collect sensitive kinds by default; a separate opt-in list whose additions wait for a Confirm keeps them off until chosen.

### Alternative G: Daily-repeating level alerts (`below 30` every day)

*   **Pros**: no new ledger.
*   **Cons**: `MetricAlertLedger` resets daily, so one expiring certificate posts an alert message every day for a month.
*   **Reason for Rejection**: Rejected by author: a daily message trains people to ignore it; one message on crossing and one on expiry carry the same information.

### Alternative H: Jamf Pro notifications only

*   **Pros**: one source instead of four for the credential expiries; Jamf already decides what is worth a notice.
*   **Cons**: notifications are filtered by user and site, so an API client may see none; they carry no expiry date the app has seen (shape unverified); they say nothing until Jamf's own window.
*   **Reason for Rejection**: Rejected by author: the typed dates are the reliable signal; notifications are kept as a count beside them.

--------------------------------------------------------------------------------

## Risks & Mitigations

| Risk | Impact | Mitigation |
|---|---|---|
| No server with data is found for the six unverified shapes | Those kinds never ship | Each kind ships in its own PR with its fixture; CA, SSO (once its date is seen), the opt-in counts and the shared calculator ship without them. |
| The landing-guard fix turns existing silent 403 empties into failures | Some 2.12 workspaces read Partial after upgrading | Called out in the CHANGELOG; the failure names the privilege; the data was already wrong. |
| LAPS opt-in raises what the stored login can do | A leaked reporting credential could read LAPS passwords | Opt-in only, confirmed per Mac; onboarding and the switch say so; a Config Doctor warn row stays while it is on. |
| A peer Mac edits the ledger, a state file or `collect_opt_in` | One credential's alert silenced, a refusal shown loud or quiet, or sensitive kinds turned on | A ledger entry covers one exact credential and expiry; future-dated state stamps read as absent; opt-in additions wait for a Confirm on each Mac. |
| The alert ledger cannot be read | An alert message on every run | Fails toward sending, as the existing ledger does. |
| A partial (exit 7) list reduced to a count | A figure that looks complete | Exit 7 is not saved for these kinds. |
| Nine more calls lengthen a run | Run budget pressure on slow servers | 180 s per call, no retry of timeouts, inventory tier for six of them; worst case 27 minutes, inside the 45-minute budget. |
| A 2.12 Mac on a shared workspace rebuilds today's summary | The new fields disappear for that day | Fields are optional; Trends shows a gap; the ledger never treats a missing summary field as removal. |

## Non-Functional Requirements

*   **Security and privacy**: allow-list reductions before disk for every kind, independent of `keep_account_names`; no person field, client ID, keystore, Apple ID or LAPS username in snapshots, run logs (jamf-cli stderr for these kinds goes through the existing redaction; the `[info]` refusal line carries only the privilege name), alert messages (facts are counts and days only, and only with `notify.detail: full`), AI input or the diagnostic bundle. The opt-in sensitive privileges are listed apart and never required.
*   **Performance**: nine more jamf-cli launches at most per full collect (six by default), each bounded at 180 s; six in the inventory tier (every 48 h), three in refresh. A refused kind is re-probed at most once a week by scheduled runs; timeouts are not retried within a run.
*   **Rollout and rollback**: all summary fields are optional; a 2.12 Mac on a shared workspace rebuilding the same day's summary drops them (stated in the CHANGELOG). Turning a kind off is `collect_skip` (default kinds) or removing it from `collect_opt_in`. A downgrade to 2.12 ignores the new snapshot folders and the unknown config key (Config Doctor in 2.12 lists it as unknown).

--------------------------------------------------------------------------------

## Additional Resources

*   Epic [#421](https://github.com/tonyyo11/jamf-reports-community/issues/421) (2.13), wave A section; [#390](https://github.com/tonyyo11/jamf-reports-community/issues/390) (Jamf Pro 11.32–11.34 API).
*   [Management health design](2026-11-15-management-health-design.md) (the 2.12 card this one sits beside).
*   [Review checklist](../review-checklist.md).
*   Appendix A below holds the shape evidence.

## Future Improvements

*   APNs push certificate expiry when jamf-cli exposes a date.
*   Platform API workspaces once a gateway profile is tested.
*   Notification `params` (which certificate, which token) once a fixture shows the keys.
*   Admin hygiene as lists for an organization that opts into names, behind `keep_account_names`.

--------------------------------------------------------------------------------

## Detailed Implementation Plan

Paths are under `app/Sources/JamfReports/` and tests under `app/Tests/JamfReportsTests/` unless shown. Every PR builds with `swift build --build-tests` on Swift 6.1 and leaves the full suite green. Each PR lists the files it may touch; nothing outside that list changes.

### PR 0: refused empty lists never land (every collect path)

Defect fix for review-checklist class 2, on its own, before any new source. Gate: first capture a list command run by a role without its privilege (exit code, stdout bytes, stderr). If jamf-cli never exits 0 with an empty list and the 403 line, this PR is not built and the Technical Plan's Landing guard section is removed.

*   **Predicate** `ReportEngine.isRefusedEmpty(payload: Data, sawForbidden: Bool) -> Bool` (new, `Engine/ReportEngine.swift`): true when `sawForbidden` and the payload, after `jsonPayload(from:)` salvage, is JSON `null`, `[]`, `{}`, or an object whose `results` is `[]`. Checked on jamf-cli's own stdout, before the app substitutes its own payloads (`noBlueprints`' `[]`, `emptyUpdateReport`), which are created only on their own stderr markers and so are never refused-empty.
*   **Sites** (all in this PR, each routing a refused-empty payload to its existing unlanded path with cause `missingPermission`):
    *   `Engine/ReportEngine.swift`: the Jamf Pro landing guard in `collectOneKind` (before `saveCollectedPayload`, exit 0 and exit 7); the Jamf School loop's guard; the Protect loop's guard.
    *   `Engine/ReportEngine+SecurityCloud.swift`: the `security risk list` guard.
    *   `Engine/ReportEngine+ComplianceBenchmarks.swift`: `collectBenchmarkReport` gains a `StderrSignalWatcher` per title run (it has none today); the refused-empty check runs per title, and a refused title fails the kind like any failed title.
    *   Out of scope, stated: `collectDashboard` (its payload is an HTML file written with `--out-file`, not a JSON list).
*   `Engine/ReportEngine.swift` `recordUnlandedAttempt`: a new `forcedCause: FailureCause?` parameter; the refused-empty branch passes `FailureCause(kind: .missingPermission, names: [])`, because `classify` returns `.other` for any non-zero exit (exit 7 included) before it reads the 403 flag. `Services/FailureCause.swift`: no change.
*   **Tests** `Engine/RefusedEmptyLandingTests.swift` (Create), using the `locateJamfCLI:` stub harness of `CollectFailureCauseTests`: per site, `[]` + 403 line is unlanded with cause `missingPermission`; `null`, `{}` and `{"results": []}` likewise; rows + 403 line still land; `[]` without the line still lands; exit 7 with `[]` + line is unlanded.
*   `CHANGELOG.md`: Fixed bullet ("a source Jamf Pro refused with an empty answer is now reported as missing a privilege instead of saved as empty; some workspaces may show it as failing after upgrading").

### PR 1: seams and gates (no new command runs)

*   `Services/FailureCause.swift`: `Kind.notConfiguredOnServer` (label "not set up on this Jamf Pro server", `isPermanent` true); `Services/ConnectionCheck.swift`: map it to `.undecided` in its exhaustive switch.
*   `Services/StateFileStore.swift`: `isAdvisory(kind:) -> Bool` = `kind` is in `ReportEngine.serverHealthKinds` AND (cause `notConfiguredOnServer`, any time, OR (cause `missingPermission` AND no `<kind>.last`)); false for every other kind; `advisoryHoldUntil(report:now:) -> Date?` = the newest stamp in `failures(report:)` + 7 days when `isAdvisory`, nil when that stamp is more than `SharedWorkspace.clockSkewTolerance` ahead of `now` (the `timeoutHoldUntil` guard).
*   `Engine/ReportEngine.swift`:
    *   `serverHealthKinds: Set<String>` (nine), `serverHealthOptInKinds` (three), `serverHealthTimeout: TimeInterval = 180`. Constants only; no matrix row yet.
    *   `recordUnlandedAttempt`: for a kind in `serverHealthKinds`, exit 4 passes `forcedCause: FailureCause(kind: .notConfiguredOnServer)` (classify cannot tell which kind it is). Then, after `stateStore?.record(...)` and **before** `guard useCachedData`, when `kind` is in `serverHealthKinds` and the state now `isAdvisory`, log `[info] <kind>: <text>` (below) and return a `KindCollectResult` whose outcome has the new `CollectOutcome.advisory = true`. The collect loop's `outcomes.append` skips advisory outcomes, so `degradedKinds`, `isCollectDead`, `deadRunCause`, `writeEarlySummary` and the `use_cached_data: false` abort never see them.
    *   Text: missing permission, `"<kind>: not permitted for this login (<privileges>); see Config Doctor"`; not set up, `"<kind>: not set up on this Jamf Pro server"`. `<privileges>` = the cause's names, else `CommandCatalog.privilegesListed(for:)` of the kind's argv from the bundled catalog, else omitted.
    *   Per-call timeout for server-health kinds: `min(kindTimeout, serverHealthTimeout)`, so the test seam still wins.
*   `Engine/ReportEngine+CollectPlan.swift`: `CollectSkipReason` cases with `skipDetail` / `planLabel`:
    *   `.serverHealthUnsupported`: "needs jamf-cli 1.38.0 or later" / "jamf-cli older than 1.38.0"
    *   `.serverHealthNotOnGateway`: "not collected through a Platform API profile yet" / "Platform API profile"
    *   `.notOptedIn`: "turned off (opt-in) in Data Sources" / "not turned on"
    *   `.notPermitted`: "not permitted for this login; checked again weekly" / "not permitted"
    *   `.notConfigured`: "not set up on this Jamf Pro server; checked again weekly" / "not set up"
    *   `profileSkip` (before tiers), in this order after `collectSkip`: `.serverHealthNotOnGateway` (workspace profile's own auth is `platform`; unknown auth never skips), `.serverHealthUnsupported` (`JamfCLIInstaller.supportsServerHealth(version)` false; unknown version never skips), `.notOptedIn`.
    *   `scheduleSkip`, after the tier check, inside `!inputs.force` beside `repeatedTimeouts`: `.notPermitted` / `.notConfigured` from a new `advisoryHold: (String) -> CollectSkipReason?` closure parameter (defaulting to `{ _ in nil }`, like `timeoutHold`); `collect` builds it as: `advisoryHoldUntil(report:now:)` later than `now` → `.notConfigured` when the stored cause is `notConfiguredOnServer`, else `.notPermitted`.
    *   `CollectPlanInputs`: `var serverHealthSupported = true`, `var workspaceAuthIsPlatform = false`, `var optInKinds: Set<String> = []` (defaults keep both memberwise call sites building). Both callers set them in this PR: `collect` (`ReportEngine.swift`, where it builds `CollectPlanInputs`) from `JamfCLIInstaller.supportsServerHealth(detectedVersion)`, `profileAuth == .platform`, and `advisoryHold` from its `stateStore`; `CollectSourcesPlan.matrix` from its `Inputs` (`jamfCLIVersion`, `auth`) and `Inputs.advisory`. `optInKinds` is set in PR 5.
*   `Engine/ReportEngine+CollectSkip.swift`: `optionalKinds` and `listedSkipKinds` subtract `serverHealthOptInKinds`, so `collect_skip` never names an opt-in kind (the writer refuses it as `unknownSource`).
*   `Services/JamfCLIInstaller.swift`: `supportsServerHealth(_ version: String?) -> Bool` (true for ≥ 1.38.0 and for an unknown version, which never skips).
*   `Models/CredentialExpiry.swift` (Create): `struct CredentialExpiry { enum Source { case day(String), instant(Date) }; let key: String; let label: String; let expiresText: String?; let daysLeft: Int?; let state: State }`, `enum State { expired, expiring, ok, notReported }`, `static func state(daysLeft:warningDays:)`, `static func parse(_ raw: Any?) -> Source?` with the **capture rule**: an integer above 10^11 is epoch milliseconds, any other integer epoch seconds; a `yyyy-MM-dd` string is a day; any other string goes through ISO 8601 with or without fractional seconds, a string with no zone read as UTC; anything else nil (`notReported`). Instant credentials are `expired` when `now >= expiresAt`. `warningDays` comes from `ThresholdsConfig.resolvedCertWarningDays`.
*   `Models/EnrollmentToken.swift`: add `id: String?` and `expiryDay: String?` (raw `tokenExpirationDate`, both already saved by 2.12's `keepingEnrollmentIdentity`); state through `CredentialExpiry.state`; `Models/DemoData+Management.swift` updated for the new fields.
*   Tests: `CredentialExpiryTests.swift` (Create: each capture-rule branch; two time zones give one day count for a day credential; instant expired on its own day), `EnrollmentTokenTests.swift` (Modify: new fields, unchanged states), `StateFileStoreAdvisoryTests.swift` (Create: `isAdvisory` for each cause and landed state; an existing kind such as `computers` with a never-landed missing permission is not advisory; hold from a fixed `now`; a future stamp gives no hold), `CollectPlanTests.swift` (Modify: reason order; unknown auth and unknown version never skip; `collect` and `CollectSourcesPlan` pass the inputs).

### PR 2: built-in CA expiry end to end

*   `Engine/ReportEngine.swift`: matrix row `["-p", profile, "pro", "certificate-authority", "active", "--output", "json"]` → kind `certificate-authority`; `knownCollectKinds`. In `collectOneKind`, exit 7 for a kind in `serverHealthKinds` goes to `recordUnlandedAttempt` (cause from `classify`, an ordinary failure: Partial, retried by the next run) instead of `saveCollectedPayload`. `saveCollectedPayload` calls `ServerHealthReduction.reduce(kind:payload:now:)` for server-health kinds, before any write, regardless of `keepAccountNames`; nil means not saved and a failure is recorded.
*   `Engine/ServerHealthReduction.swift` (Create): row extraction shared with `keepingEnrollmentIdentity` (bare list, `results` envelope, `null`) moved into one helper `ReportEngine.listRows(of:)`; CA keeps `{notAfter}` (integer).
*   `Services/CollectionTier.swift` (`tierMap`: inventory), `Engine/ReportEngine+FleetSides.swift` (`sourceSides`: `.both`).
*   `Models/ServerHealth.swift` (Create): `enum FactState { notCollected, notConfigured, notPermitted([String]), failed(String), unreadable, none, value(Fact, stale: Date?) }`; `struct ServerHealth { let credentials: [CredentialRow]; let adeSyncs: FactState; let notifications: FactState; let pushDisabled: FactState; let licences: FactState; let adminHygiene: FactState }`; `static func load(dataDir:warningDays:now:) -> ServerHealth` reading snapshots through `BoundedFile.readSnapshotLogged` and `StateFileStore` (`isAdvisory`, cause, `.last`). `CredentialRow { key, label, fact: FactState }`, where a landed credential is `value(.credential(CredentialExpiry), stale:)` and a refused or failed one carries its own state, so every credential row has the seven states.
*   `Views/ServerHealthSection.swift` (Create), `Views/AuditView.swift` (Modify): card after Management health, loaded in `loadCached`, hidden unless `environmentProducts.has(.jamfPro)` and some kind has been attempted. Copy marked DRAFT for the visual pass: title "Server and admin health"; row "Built-in CA: expires in N days (date)" / "expired N days ago" / "Not permitted: <privilege>" / "Not set up on this server" / "Could not be collected: <cause>"; "ADE tokens: see Management health".
*   `Engine/CoreDashboard+ServerHealth.swift` (Create), `Engine/CoreDashboard.swift`, `Engine/Templates/ReportTemplate.swift`, `FullInstanceTemplate.swift`, `OperationalTemplate.swift` (Modify): `SheetID.serverAdminHealth` = "Server and Admin Health", last in both templates' `includedSheets` (so after every core tab; EA and Charts tabs still follow); gated like `gatedOnProtect` with a new `CoreDashboardError.noServerHealthData` when no server-health kind has landed. Columns per section: Credentials (Credential, Expires, Days left, State, As of); later sections added by their PRs.
*   `Engine/HtmlReport+Inputs.swift`, `Engine/HtmlReport+Glance.swift`: `Inputs.serverHealth`; one `attentionItems` sentence per expired or expiring credential except `ade:` (already stated by `ManagementReport.tokenSentence`), worded like `ManagementReport.stateText`.
*   `Services/ConfigDoctorService+ServerHealth.swift` (Create), `Services/ConfigDoctorService.swift` (Modify): `server_health.not_permitted` (suggest; one row listing each advisory kind with its privileges or "this login cannot read <source>"; hint "Add the privilege to the API role, then Collect now"; not-set-up kinds are not listed).
*   `Services/WorkspaceStore+Automation.swift`, `Services/WorkspaceStore+Refresh.swift`: `expectedKinds` gains parameters `serverHealthSupported: Bool`, `workspaceAuthIsPlatform: Bool`, `optIn: Set<String>`, `advisory: Set<String>` and excludes accordingly; the caller computes them (advisory from `StateFileStore.isAdvisory`).
*   `Services/CollectSourcesPlan.swift`: `Inputs.advisory: [String: FailureCause]`; a server-health kind listed with its advisory text; no new `Product` group (they sit under Jamf Pro).
*   `Services/CommandCatalog.swift`: `bundledCollectPrivileges` updated for the new default argvs (CA lists none); `CommandCatalogTests.swift` (Modify): CA into `unmappedUnlisted` until a 403 capture names its privilege.
*   `Models/DemoData+ServerHealth.swift` (Create): a CA expiring at `referenceDate` + 40 days.
*   `Fixtures/server-health/certificate-authority-active.json` (Create, synthetic values in the captured shape) and `Fixtures/server-health/README.md` (server version, capture date, the synthetic-value rule).
*   Tests: `Engine/ServerHealthRefusalTests.swift` (Create, `locateJamfCLI:` stub answering for `certificate-authority`: never-landed exit 5 is advisory, logs `[info]`, run not Partial; under `use_cached_data: false` it does not throw; exit 4 is advisory before and after a landing; landed-then-exit-5 is Partial; exit 1 and a timeout stay Partial; a held kind is skipped unforced and probed with `force`), `ServerHealthReductionTests.swift` (Create: CA keeps only `notAfter`; an extra key and a person key in the payload are dropped), `ServerHealthTests.swift` (Create: the seven states for CA), `Engine/CoreDashboardTests.swift` (Modify: sheet list and count), `FleetSidesTests.swift` and `CollectionTierTests.swift` (Modify: totality), `CLIHelpContractTests.swift` (Modify: new `AppCommand` case), `ManagementHealthHtmlTests.swift` (Modify: one ADE sentence only), a School test in `ServerHealthTests.swift` (no card, no tab, no hint) and a Platform-auth test in `CollectPlanTests.swift` (all server-health kinds skipped).
*   Localizable strings: new keys added by hand to `app/Localization/Localizable.xcstrings` with all languages; `sync-strings.zsh --prune-stale` is not run (it marks used keys stale in a fresh worktree).

### PR 3a to 3e: one PR per remaining default kind, each after its fixture

Order: SSO (`sso-certificate`), volume purchasing (`volume-purchasing-locations`), ADE syncs (`device-enrollment-syncs`), notifications (`jamf-pro-notifications`), push (`push-disabled-devices`). Each PR touches only: its matrix row, a `CommandCatalogTests` `unmappedUnlisted` edit when the catalog lists no privilege for it (notifications), (no `--all`: jamf-cli fetches every page by default; `pro accounts list --page-size 2` returned all 5 rows over three `page_fetch` events), `knownCollectKinds`, `tierMap`, `sourceSides`, its reduction in `ServerHealthReduction.swift`, its `ServerHealth` field, its card row and tab section, its HTML sentence, `bundledCollectPrivileges`, its fixture and tests, the CHANGELOG.

Each PR opens with a **capture amendment**: a short Appendix B entry added to this spec, reviewed with the fixture, recording the captured keys and types and the values that decide behaviour. The rules it must settle, and the defaults if the capture agrees with them:

*   SSO: `keystoreDetails.expiration` through `CredentialExpiry.parse`; saved `{expiration}`.
*   Volume purchasing: rows `{id, locationName, tokenExpiration, totalPurchasedLicenses, totalUsedLicenses}`; `tokenExpiration` through `CredentialExpiry.parse`; licence use shown as used of purchased per location.
*   ADE syncs: newest row per `instanceId` by `timestamp` (parsed by `CredentialExpiry.parse`'s ISO rule); the amendment lists the `syncState` values that count as failing, taken from the capture and Jamf's API reference; an unlisted value is shown as Jamf names it and not counted.
*   Notifications: rows `{type}`; the amendment decides whether credential-expiry types (CA, SSO, VPP, ADE) are folded into the credential rows; zero reads "none visible to this login".
*   Push: `{count}` = number of rows returned.

Tab section columns: SSO joins Credentials; Volume purchasing (Location, Token expires, Days left, State, Licences used, Licences purchased); ADE syncs (Instance, Newest sync, State) with the instance named from `device-enrollment-instances` `id` → `name`, "Unknown instance" when absent; Notifications (Type, Count); Push (Devices with push disabled).

### PR 4: daily summary, alerts and Trends

*   `Services/SummaryJSONParser.swift`: `DailySummary` fields `serverCredentialExpiries: [String: CredentialExpiryEntry]?` (`{expires: String, asOf: String}`), `adeSyncFailingCount`, `jamfProNotificationCount`, `pushDisabledCount`, `lapsPendingCount` (Int?); counts join `environmentCounts`; `filling(from:)` per group; `ServerHealthSummaryFigures` struct; `withEnvironment(serverHealth:)`.
*   `Engine/ReportEngine+EnvironmentFinalize.swift`: `finalizeEnvironmentSummary` reads the landed server-health kinds from `landed[.jamfPro]` (no new `LandedSources` field) and writes counts for kinds landed this run and expiries from the newest landed snapshot whose age is within `jamf_cli.max_cache_age_hours` (default 168); the `.keptExisting` guard also passes when server-health figures exist.
*   `Engine/ReportEngine.swift`: no change to `freshSummaryIsBetter` (the new fields are added after it, by `finalizeEnvironmentSummary`, as the Protect fields are); `writeEarlySummary` keeps them through `filling(from:)`.
*   `Services/MetricAlertEvaluator.swift`: `AlertMetric` cases `serverCredentialDaysLeft` ("Server credential days left"), `adeSyncFailingCount` ("ADE syncs failing"), `jamfProNotificationCount` ("Jamf Pro notifications"), `pushDisabledCount` ("Devices with push disabled"), `lapsPendingCount` ("LAPS rotations pending"), `isPercentage` false; `value(in:)` returns nil for `serverCredentialDaysLeft`; new `evaluateCredentials(rules:current:now:warningDays:) -> [MetricAlertHit]`, one hit per credential below the threshold (state `hit`) or expired (state `expired`); `MetricAlertHit` gains `credentialKey: String?`, `expires: String?`, `credentialState: String?`; credential `dedupKey` = `label|ruleDescription|credentialKey|expires|state`.
*   `Engine/ConfigDecoder.swift` (`resolvedRules`) and `Services/ConfigDoctorService.swift` (`alertRuleFailure`): `serverCredentialDaysLeft` accepts `below` only.
*   `Services/MetricAlertLedger.swift`: `Record` gains optional `credentialKeys: [CredentialKey]` (`{rule, key, expires, state}`), kept across days; every `record` merges and preserves it; entries pruned when `expires` is more than 60 days past. JSON: `{"day": "...", "keys": [...], "credentialKeys": [{"rule": "below 45", "key": "ca", "expires": "2027-03-01T00:00:00Z", "state": "hit"}]}`.
*   `Services/ScheduledRunSignals.swift` (`notifyMetricAlerts`): credential hits are checked against `credentialKeys` (not the daily `pendingKeys`), sent, and recorded after a confirmed send. Message text, `notify.detail: full`: "Built-in CA expires in N days (yyyy-MM-dd)" / "Built-in CA expired N days ago"; labels "SSO certificate", "Volume purchasing token", "ADE token", no names or IDs; `minimal`: "A server credential is expiring" / "A server credential has expired".
*   Trends: `Models/Models.swift`, `Services/WorkspaceStore.swift`, `Services/TrendStore.swift`, `Models/OverviewLayout.swift`: gated group of four count series (lower is better) and `serverCredentialSoonestDays` (higher is better, day axis allowing negatives, ADE included and named by which credential it is); Jamf Pro only; not in `schoolMetrics` or demo history.
*   No change needed, stated: `retryCouldHelp` / `lastFailureRepeatsOnRetry` (both new causes are permanent, which they already treat as repeating); `AttentionLog` (no new attention code); HTML appendix (no new section).
*   Tests: `MetricAlertEvaluatorTests.swift`, `MetricAlertLedgerTests.swift`, `MetricAlertRunDayTests.swift` (Modify: two credentials crossing on different days each post; expiring then expired posts twice; an unrenewed expired credential never posts a third time; renewal re-arms; a 2.12-written ledger re-sends once; `above` dropped for this metric), `Engine/ServerHealthSummaryTests.swift` (Create: a CA expired yesterday decodes; expiries present on a day their kind did not land, absent beyond `max_cache_age_hours`; same-day rebuild).

### PR 5: admin hygiene (opt-in)

*   `Engine/ConfigDecoder.swift`: `jamf_cli.collect_opt_in` (list; a non-list reads as empty).
*   `Services/SharedConfigPin.swift`: key `collectOptIn` with a stored confirmed set, wired into `Key.text(of:)`, `copy(from:into:)`, `current(fromYAML:)`, `unconfirmedKeys` (a non-empty list at first sight is unconfirmed), `adoptingMissingKeys` (learning the key adopts nothing) and the decoder. Effective list = configured ∩ confirmed on a workspace the pin applies to; on a local workspace (no pin) it is the configured list, as `collectSkipList` does. A name removed in config.yaml drops out at once and is also removed from the confirmed set without a Confirm (the `repinningBackupOptOuts` pattern, extended to this key); a name added waits until Confirm adds it. `collectOptIn(configured:profile:) -> Set<String>` is the one reader. Touchpoints also include `repinningBackupOptOuts`.
*   `Services/CollectSkipConfigWriter.swift`: parameterised by key and allowed set (`collect_skip` with `optionalKinds`, `collect_opt_in` with `serverHealthOptInKinds`); `setOptedIn(_:kind:profile:)`; `setCollecting` checks `serverHealthOptInKinds` first and throws a new `.optInSource` ("turn it on under Admin hygiene in Data Sources") instead of `.coreSource`; while the key has drifted, a removal is written (it only narrows) and an addition is refused; `confirmWritten` for the value written. `Services/ConfigEditedKeys.swift`: an `apply` for the writer so both keys register.
*   `Engine/ReportEngine.swift`: matrix rows for `laps-pending-rotations`, `admin-accounts`, `api-integrations`; `knownCollectKinds`; tiers inventory; `sourceSides` `.both`; `collect` sets `CollectPlanInputs.optInKinds` from `SharedConfigPin.collectOptIn`, and `CollectSourcesPlan` from `Inputs.optInList`.
*   `Engine/ServerHealthReduction.swift` (count documents, `reduce(kind:payload:now:)`):
    *   LAPS: `{totalCount}` from the wrapper.
    *   Accounts: `total` = rows; `fullAccessLocal` = `accessLevel == "FullAccess"` and `privilegeLevel == "ADMINISTRATOR"` and `accountType == "DEFAULT"` and `accountStatus == "Enabled"`; `fullAccessFederated` = the same with `accountType == "FEDERATED"`; `withFailedLogins` = `failedLoginAttempts > 0`; `passwordOlderThanYear` = `accountType == "DEFAULT"` and `accountStatus == "Enabled"` and `lastPasswordChange` (no zone, read as UTC; unverified, recorded in Appendix B with PR 5) more than 365 days before `now`; `passwordAgeUnknown` = such accounts whose `lastPasswordChange` is missing or unparsable.
    *   API clients: `total`; `disabled` = `enabled == false`; `enabledWithTokenOverOneDay` = `enabled == true` and `accessTokenLifetimeSeconds > 86400`.
*   `Services/CollectSourcesPlan.swift`: `Inputs.optInList`; `SourceSwitch.optIn(on:)` returned by `switchState` before `.hidden`; labels "LAPS rotations pending (needs View Local Admin Password, which can also read LAPS passwords)", "Admin accounts (needs Read Accounts; counts only)", "API clients (needs Read API Integrations; counts only)". `Views/SourcesView.swift` renders it.
*   `Services/CommandCatalog.swift`, `Services/CommandCatalog+Privileges.swift`, `Views/OnboardingView.swift`: `collectArguments()` excludes opt-in argvs; `optionalPrivileges()`; onboarding shows them as "Optional, only if you turn on admin hygiene" with the LAPS warning.
*   `Services/ConfigDoctorService+ServerHealth.swift`: `server_health.opt_in_unknown` (warn: a name that is not opt-in, or a non-list value) and `server_health.laps_privilege` (warn while LAPS is opted in).
*   `Services/DiagnosticBundleService.swift`: `collect_opt_in` added to `vocabularyKeys`, so the bundle shows which kinds are opted in.
*   Card rows and tab section "Admin hygiene" (Accounts: full-access local, full-access federated, with failed logins, password older than a year, password age unknown; API clients: total, disabled, enabled with a token over one day; LAPS rotations pending). `lapsPendingCount` joins the summary and Trends (PR 4's field).
*   Fixtures: `Fixtures/server-health/accounts-list.json`, `api-integrations-list.json` (captured shapes, synthetic values), `local-admin-password-pending-rotations.json` (the captured `{totalCount, results}` wrapper; the reduction reads only `totalCount`, so LAPS does not wait for a capture with rows).
*   Tests: `Engine/ServerHealthReductionTests.swift` (Modify: one test per predicate, UTC reading, an unparsable date, no name in the saved document), `CollectOptInTests.swift` (Create: pin effective list for a peer adding and a peer removing, on both Macs; writer refusal and narrowing; planner skip; catalog exclusion), `CollectSourcesPlanTests.swift`, `CollectSkipSwitchTests.swift`, `SharedConfigPinTests.swift`, `CommandCatalogTests.swift` (Modify).

### Docs (with the PR that changes the behaviour)

`CHANGELOG.md` (each PR's bullets; PR 2 names the new workbook tab under Changed; PR 4 notes that a 2.12 Mac on a shared workspace drops the new summary fields), `config.example.yaml` (PR 5: `collect_opt_in`), `README.md`, `docs/wiki/13-Permissions-and-Access.md` (privileges, optional group), `CLAUDE.md` and `AGENTS.md` ("Server and admin health (2.13)" paragraph, kept in sync), epic #421 checkboxes.

### Verification Plan

*   **Build**: `cd app && swift build --build-tests`, also on the Swift 6.1 toolchain CI uses (Xcode 16.4).
*   **Tests**: the full `swift test`, and the named suites per PR.
*   **Lint**: `xcrun swift-format lint` on touched files as a hint; catalog keys added by hand.
*   **Live**: collect against the test Jamf Pro server with an unchanged role (OK run, a Config Doctor hint for refused kinds), with the privileges added (the card fills), and with the opt-in on (counts only: search the snapshot folders for the captured account names and client IDs, expect no match).
*   **Visual**: card and tab at `PageScaffold.minSupportedWidth`, DRAFT visual item for Tony.

--------------------------------------------------------------------------------

## Appendix A: Shape evidence

Captured 2026-11-24 with jamf-cli 1.38.0 against a Jamf Pro test server; stderr was saved for every command and held only `page_fetch` progress lines, no 403 line (an OAuth API client), read-only, keys and JSON types only. The epic's 2026-11-15 notes record rows for volume purchasing, ADE syncs and notifications on a Jamf Pro 11.34 development server, with no saved raw output.

| Command | Exit | Shape | Catalog privilege |
|---|---|---|---|
| `pro certificate-authority active` | 0 | object: `notAfter`, `notBefore` int (epoch seconds), subject/issuer/serial strings, `signature{}`, `keyUsage[]`, fingerprints | none listed |
| `pro sso-settings cert get` | 0 | `{keystore{key, keys[], type, keystoreSetupType, keystoreFileName}, keystoreDetails{keys[], serialNumber, subject, issuer, expiration}}`; no certificate, so `expiration` null | Read SSO Settings |
| `pro volume-purchasing-locations list` | 0 | `[]` | Read Volume Purchasing Locations |
| `pro device-enrollments syncs` | 0 | `[]` | Read Device Enrollment Program Instances |
| `pro jamf-pro-notifications list` | 0 | `[]` | none listed |
| `pro local-admin-password pending-rotations` | 0 | `{totalCount int, results[]}` (empty) | View Local Admin Password |
| `pro apns-client-push-status list` | 0 | `[]` | View MDM command information in Jamf Pro API |
| `pro accounts list` (also with `--page-size 2`: 5 rows over 3 pages) | 0 | rows: `id` str, `username`, `realname`, `email`, `phone`, `distinguishedName` str, `siteId` int, `accessLevel` (FullAccess, SiteAccess), `privilegeLevel` (ADMINISTRATOR, AUDITOR), `failedLoginAttempts` int, `accountStatus` (Enabled), `accountType` (DEFAULT, FEDERATED), `ropfMigrationScope`, `ldapServerId` int, `lastPasswordChange` `yyyy-MM-ddTHH:mm:ss`, `changePasswordOnNextLogin` bool | Read Accounts |
| `pro api-integrations list` | 0 | rows: `authorizationScopes[str]`, `displayName`, `enabled` bool, `accessTokenLifetimeSeconds` int, `id` int, `appType` (CLIENT_CREDENTIALS), `clientId` | Read API Integrations |

The Jamf Pro API reference confirms `GET /v2/local-admin-password/pending-rotations` needs View Local Admin Password (rows `{lapsUser{clientManagementId, guid, username, userSource}, createdDate}`) and `GET /v2/local-admin-password/settings` needs Read User-Initiated Enrollment and Update Local Admin Password Settings.

--------------------------------------------------------------------------------

*Drafted with EGM*
