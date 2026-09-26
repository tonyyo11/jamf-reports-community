# Connection access and setup: design

Status: design approved section by section on 2026-09-11/12; written autonomously on Tony's
instruction to take the recommendations. Not yet reviewed as a whole document.

This is spec 1 of 2. Spec 2, source-aware reporting, is outlined in the handoff section at the
end and gets its own brainstorm.

## 1. Problem

An early tester connected the app to a Jamf Platform API integration with two read
permissions and no Jamf Pro profile. Every collect failed, and the generated HTML report was
empty. Log review found:

- The profile's environment ID was rejected by the gateway (`ENVIRONMENT_NOT_FOUND`), most likely
  a tenant ID pasted into the Environment ID field. Onboarding saved it without complaint.
- Every Jamf Pro API call reported a bare `resource not found (HTTP 404)`, which gave the tester nothing
  to act on.
- Nothing in the app tells an admin which permission a data source needs, for any connection type.
- An integration built with deliberately few permissions would show a permanent red health banner
  and retry hopeless collects hourly.
- The setup instructions are out of date and say nothing about scope levels, environments or least
  privilege. Admins with several environments (test, production, High Compliance, beta) have no
  guidance on choosing one.

## 2. Goals

1. For every jamf-cli connection type, a failed data source says why and names what to grant.
2. Guided Platform API setup that recommends environment level, warns about picking the right
   environment, lists only the permissions needed, and catches a wrong ID before saving.
3. A per-profile record of which APIs the profile actually reaches, so collect stops attempting
   sources it cannot reach and spec 2 can choose report sources.
4. One requirements table in code that drives setup, diagnosis, the CLI and the wiki.

## 3. Non-goals (spec 2 or later)

- Choosing a report's primary source, dropping empty report sections, School HTML sections, and
  Protect-only profiles. All of this is spec 2.
- Collecting Platform device inventory or device groups as new data sources. Spec 2.
- Jamf Security Cloud data. The app collects none today; a later spec.
- Probing every permission during setup. The first collect learns the same thing at no extra cost.
- An in-app setting for which report areas to collect. Access is learned from permission errors.

## 4. Decisions made during the brainstorm

| # | Question | Decision |
|---|---|---|
| 1 | Specificity for Protect and School, where jamf-cli names no permissions | Named permissions for Jamf Pro and gateway profiles; Protect and School name the data and console screen. Protect also shows its API client's granted permissions. |
| 2 | Scope level to recommend | Always recommend environment. Describe tenant as the narrower legacy option. Remove organization from the app's picker. |
| 3 | Deliberately missing permissions | Learn from the permission error. Never landed plus permission error is "not granted": neutral, no hourly retry, still tried on schedule. Landed before plus permission error is "access lost": red. |
| 4 | How firm setup is about the ID | Block only on a definite rejection from the gateway. Warn when the check cannot decide. |
| 5 | Where permission knowledge comes from | jamf-cli's hint first; a requirements table in code for setup, the wiki, and fallback. |
| 6 | Structure | Two specs, access first. Reporting changes move to spec 2. |

Tony also asked that the shared-workspace profile-name assumption (section 8.6) be documented as a
warning for teams using a shared workspace.

## 5. Dependencies and branch

- Builds on 2.8.0: the Platform scope picker, the jamf-cli 1.29 command-name gates, and the gated
  `--no-verify` on Save. Implementation branches off `main` after 2.8.0 merges. It must not stack
  on `feat/enhance-ddm`.
- jamf-cli floor stays 1.18.0; tracked version is 1.29.0. Environment scope already requires 1.28.
  On older jamf-cli, hints are absent or less specific and the requirements table fills in.
- Target release: 2.8.1 or 2.9.0. 2.8.0 shipped on 2026-09-14, so the tester's Platform API
  checks (section 16) can run now; the connection check and cause rules wait on them.
- Test tenants: none for Jamf School, Jamf Security Cloud or the Platform API. Platform behaviour is
  confirmed through the tester. The direct Jamf Pro 403 envelope can come from a test tenant once Tony
  creates a read-limited API client there.
- Wiki corrections that describe current behaviour ship ahead of this work, with a hand-written
  permissions table on page 13. The generated block (section 11.2) replaces that table when
  `AccessRequirements` lands.

## 6. Verified facts this design relies on

Every item below was read from source or official documentation on 2026-09-11/12. Versions matter.

### 6.1 jamf-cli error output (v1.29.0; identical on `main` where compared)

- With `--output json`, a failing command writes a JSON envelope to **stdout**:
  `error`, `message`, `exitCode`, `exitCodeName`, and `hint` when one exists
  (`internal/commands/root.go` `formatErrorTo`). The app already passes `--output json` to every
  collect command and already parses `message` from stdout (`ReportEngine.jamfCLIErrorMessage`).
- `--no-hints`, which the app passes on jamf-cli 1.18+, only suppresses advisory hints on stderr.
  The envelope writer does not consult it (`internal/output/output.go` `SetNoHints`; `formatErrorTo`).
- Permission hint wording, by connection type:
  - Gateway, named: `grant the Jamf Platform API integration these permissions in Jamf Account:
    <Section> > <Permission>: <Actions> (<slug>); ... Names are as the permission picker shows
    them: <map URL>` (`internal/privileges/privileges.go` `Hint`).
  - Gateway, no recorded permission: `the Jamf Platform API integration lacks a permission this
    endpoint requires; check the integration's permissions in Jamf Account — <map URL>`
    (`GatewayFallbackHint`). Both gateway forms contain the marker `Jamf Platform API integration`.
  - Direct Jamf Pro, named: `Required privilege(s): <names>` appended by `EnrichPrivilegeError`
    (`internal/commands/privilege_error.go`).
  - Direct Jamf Pro, no recorded privilege: `the authenticated account lacks the required API
    privileges; check its API role` (`internal/client/client.go` `forbiddenHint`).
- Other exit-5 causes that are not a missing grant:
  - Scope mismatch on a Platform command: hint begins `The credential's scope level does not match
    the scope header sent.` (`scopeMismatchHint`).
  - Scope mismatch on a Jamf Pro command: message is `permission denied (HTTP 403): <body>` and the
    body contains `OWNERSHIP_FORBIDDEN`; the hint is a permissions hint, which is misleading.
  - Gateway edge block: message begins `request blocked at the Jamf gateway edge (HTTP 403)`.
  - Endpoint not served by the gateway: note appended to the hint, `The Jamf Platform gateway does
    not serve this endpoint` or `This endpoint is not part of the Jamf Platform gateway's published
    API` (`internal/gateway/note.go`).
- Unknown environment ID:
  - Platform command: message contains `[ENVIRONMENT_NOT_FOUND]`, and jamf-cli appends a note
    (`AnnotateScopeLevelError`). Seen verbatim in the tester's log.
  - Jamf Pro command: message is `resource not found (HTTP 404): <METHOD> <path>` with no body,
    so the code is invisible (`httpStatusError`). Seen verbatim in the tester's log.
- Platform command 403s exit 5 (`enrichPlatformPrivilegeError`, present at v1.29.0).
- `jamf-cli platform setup` checks the scope ID with `GET /pro/v1/jamf-pro-version`, an endpoint
  that needs no permission. Wire-checked by jamf-cli on 2026-09-08: right ID returns 200; unknown
  environment ID returns 404 `ENVIRONMENT_NOT_FOUND`; unacceptable tenant ID, or the wrong kind of
  ID, returns 403 `OWNERSHIP_FORBIDDEN`; everything else, including a scope with no Jamf Pro behind
  it, is undecided (`internal/commands/platform_gateway_setup.go`).
- The gateway resolves scope before routing and before capability checks, so a permission error
  proves the scope ID was accepted (same file, comments on the probe).

### 6.2 jamf-cli command catalog (v1.29.0, `jamf-cli commands -o json`)

- `gatewayPermissions` gives Jamf Account wording per command; `privileges` gives Jamf Pro API role
  names for Jamf Pro API commands. Classic API commands carry no Jamf Pro privilege names.
- Composite commands (`pro report *`, `pro overview`, `pro audit`) declare nothing; their needs come
  from the endpoints they call, several of which are visible in the tester's log.
- None of the app's collect commands are on the gateway's refused list (59 commands).
- Platform-only read commands the app does not collect today: `pro platform-devices list`,
  `pro platform-device-groups list`, `platform audit`, `pro blueprint-components`, `pro baselines`.

### 6.3 Jamf documentation

- Getting started with Platform API (developer.jamf.com): requires Jamf Account Administrator or a
  custom role with Integrations privileges. Integrations > Create integration; set the scope level
  and select organization, environment(s) or tenant(s); assign permissions by capability; the
  client secret is shown once; integrations remain valid for six months; base URL
  `https://{us|eu|apac}.api.jamfcloud.com` for environment and tenant scope; tokens are region-locked
  and last 900 seconds; `X-Environment-Id` or `X-Tenant-Id` header.
- Where IDs live, per the same guide: open the integration in Jamf Account and click a tenant or
  environment pill in the Integration details panel to copy the ID (confirmed 2026-09-12).
- Jamf Pro permissions map: capability names and sections as used in section 7.
- Device Inventory API: list returns id, name, model, modelIdentifier, serialNumber,
  lastInventoryUpdateTime, lastCheckInTime (computers only), operatingSystemVersion, userId,
  enrollmentType, lastEnrollmentTime, with RSQL filters on those fields. Per-device GET adds
  managed, supervised, mdmCapable, hardware, network, operatingSystem and security blocks. No
  FileVault, SIP, firewall or Gatekeeper for computers.
- Jamf School: API keys are created at Organization > Settings > API, and each key is limited to
  chosen API methods. Method names are not documented publicly.
- Jamf Protect (Creating an API Client in Jamf Protect, learn.jamf.com, read 2026-09-12): clients are
  created at Administrative > API Clients; "you can create a new role and assign the minimum
  required permissions for the API Integration, or you can assign the Read Only role to the
  client." jamf-cli's setup guide and the app's Protect form still say Settings > API Clients. A
  search summary claiming API clients always get Full Admin traced to a legacy docs.jamf.com URL
  that now redirects to a page with no such statement.
- Jamf High Compliance Cloud: no public statement about Platform API availability. jamf-cli knows
  only the US, EU and APAC gateways.

### 6.4 The app today (origin/feat/enhance-ddm @ e326d25)

- `ReportEngine.platformOnlyKinds` hard-codes four Platform reports skipped on non-gateway profiles;
  `WorkspaceStore.expectedKinds` mirrors it.
- Self-remediation skips kinds whose last exit code is 2 or 8 only.
- `StateFileStore` records `.last` on landing and `.fail` with count, date and exit code on failure.
  The integrity manifest covers `.last` files only.
- `schoolCollect` and `protectCollect` save snapshots but record no per-source state.
- `ProfileProductType` has two cases, Jamf Pro and Jamf School; Protect is an add-on to Jamf Pro.
- Onboarding's Platform form still says "account.jamf.com → API Clients", offers Environment,
  Tenant (legacy) and Organization, and Save uses `--no-verify` on jamf-cli 1.29. Validate runs a
  token check and a local config check; neither sends the scope header.
- The included CLI uses `--json` for machine-readable output.

## 7. Requirements table

One static table in Swift source, `Services/AccessRequirements.swift`. Code, not a bundled data
file, avoiding the SwiftPM resource-bundle problem hit in 2.4.0.

### 7.1 Entry shape

| Field | Meaning |
|---|---|
| `kind` | The snapshot kind collect records against, e.g. `security` |
| `area` | Report area, below |
| `api` | `jamfPro`, `jamfProClassic`, `platform`, `school`, `protect`, `external` |
| `gatewayPermissions` | Jamf Account wording, e.g. `Inventory > Devices: Read` |
| `jamfProPrivileges` | Jamf Pro API role names, e.g. `Read Computers`; filled by hand for Classic commands from Jamf's permissions map |
| `environmentOnly` | True for Platform API sources that declare environment scope |
| `console` | For Protect and School: the console screen to check instead of a permission |

Special entries: `sofa` is `external` and needs nothing; `overview` and `audit` are composite and
list no single permission (they show whatever the connection can reach).

A test fails when any kind in `ReportEngine.knownCollectKinds`, or in the School and Protect collect
matrices, has no entry. Same pattern as the collection tier coverage test.

### 7.2 Report areas

| Area | Jamf Account permissions (Read) | Sources |
|---|---|---|
| Fleet and security | Inventory > Devices | security, inventory-summary, device-compliance, computers, software-installs, duplicate-serials, mobile-devices-list, mobile-device-inventory-details |
| Patch management | Patch titles; Patch policies | patch-status, patch-release-dates, patch-device-failures |
| Software updates | Software updates; Inventory > Devices | update-status, update-device-failures |
| Policies and profiles | Policies; Configuration profiles; Device actions | policy-status, policies, classic-macos-profiles, classic-ios-profiles, profile-status, app-status |
| Extension attributes | Device extension attributes; Inventory > Devices | computer-extension-attributes, ea-results |
| Groups and inventory objects | Device groups; Advanced device searches; Sites; Buildings; Departments; Categories; Self Service configuration; Scripts; Packages; Automated Device Enrollment connection | groups, smart-computer-groups, classic-computer-groups, classic-mobile-device-groups, advanced-mobile-device-searches, sites, buildings, departments, categories, scripts, packages, device-enrollment-instances |
| DDM and command health | Inventory > Devices; Device history; at environment level also Declarations reporting and Blueprints | ddm-device-status, mdm-command-health, ddm-status, blueprint-status |
| Compliance Benchmarks | Compliance Benchmarks (environment level only) | compliance-rules, compliance-devices |
| Jamf School | No named permissions; the API key's allowed methods, set at Organization > Settings > API in the School console | school-overview, school-devices, school-device-groups, school-users, school-classes, school-apps, school-profiles, school-locations, school-ibeacons |
| Jamf Protect | The API client's role: Read Only, or a custom role with the minimum read permissions, set at Administrative > API Clients in the Protect console | protect-overview, protect-alerts, protect-computers, protect-insights, protect-plans |

Notes for the checklist copy:

- Extension attribute results also feed Compliance Posture's mSCP bands.
- "Device actions: Read" is how the gateway reads MDM command history; it grants no actions.
- Compliance Benchmarks collection is currently broken by an app defect (section 13).

## 8. Reachability record

### 8.1 Content

One file per profile, `reachability.json` in the profile's state directory (`WorkspacePaths.stateDir`,
under the configurable `jamf_cli.data_dir`), written atomically. Readers open that exact filename, so
a sync-conflict copy on a shared workspace is ignored.
One entry per API: `jamfPro`, `platform`, `school`, `protect`. Each entry holds:

- `state`: `reachable`, `unreachable`, `rejected`, `unknown`, `notConfigured`
- `checkedAt`: when last judged
- `judgedBy`: `setup` or `collect`
- `detail`: short cause text for `unreachable` and `rejected` (for example "no Jamf Pro answered in
  this environment", "the gateway does not know this environment ID")

No IDs, URLs, hostnames or credentials are stored.

### 8.2 Judging

| API | Rule |
|---|---|
| Jamf Pro | Direct connection: `reachable` once any Jamf Pro source lands. Gateway profile: the connection check (section 10.4), run by setup and at the start of each collect. |
| Platform | Gateway profile: `reachable` when the connection check accepted the ID, `rejected` when it rejected it. A rejection also sets Jamf Pro to `rejected`, since every scoped request fails. Any other auth method: `notConfigured`. |
| School | `notConfigured` unless School is set up; otherwise `reachable` when any School source lands, `unknown` otherwise. |
| Protect | Same rule as School, using the Protect collect. |

`unknown` never overwrites a judged state: the previous state and its `checkedAt` are kept. Collect
treats `unknown` as reachable, matching the existing rule that a failed auth-method probe skips
nothing.

### 8.3 How collect uses it

A pure function takes the record and the requirements table and returns the kinds to skip: every
kind whose `api` maps to an entry that is `unreachable`, `rejected` or `notConfigured`
(`jamfProClassic` follows `jamfPro`; `external` is never skipped).

Skipped kinds log `[skip] <kind>: <API> is not reachable for this profile (<detail>)` and record
nothing: no failure counter, no `[partial]` entry, no outage verdict input. This is exactly how
the 2.7.0 Platform-only skip behaves today.

A collect whose connection check rejects the ID does not skip its way to an empty success. It stops
before the matrix with the scope error from section 9.6 and exits 1, the same way the auth-dead
verdict stops a run today.

This replaces `ReportEngine.platformOnlyKinds`, `ReportEngine.nonPlatformAuthMethod` and the
matching filter in `WorkspaceStore.expectedKinds`. The existing tests for that rule are re-pointed at
the new function, because they still describe correct behavior. The device scan phase is skipped
when Jamf Pro is not reachable.

### 8.4 School and Protect recording

`schoolCollect` and `protectCollect` start recording per-kind outcomes through
`StateFileStore.record`, including exit codes and failure causes (section 9). Without this, neither
diagnosis nor reachability has anything to read for those products.

### 8.5 Where it shows

The Access card (section 10.2) opens with one line per API, for example "Jamf Pro API: reachable
through the gateway, checked today" or "Platform API: rejected, the gateway does not know this
environment ID". Spec 2 reads the same record.

### 8.6 Shared workspaces and profile names

The record lives in the workspace, so every Mac sharing a workspace sees it and each collect
refreshes it. jamf-cli profiles and their keychain credentials live on each Mac
(`~/.config/jamf-cli/config.yaml`), while the workspace is keyed only by profile name. If two Macs
use the same profile name with different connections, one direct and one through the gateway or
two different environments, the record flips with each collect and screens show whichever Mac ran
last. The app does not detect this. It is documented as a warning (section 11).

## 9. Failure capture and classification

### 9.1 Capture

`ReportEngine.collectOneKind` already parses the JSON envelope's `message` from stdout. It also
reads `hint` and `error`, then classifies the failure with a pure function (9.2) before recording
it.

Some commands swallow a failed request and exit 0 without data (for example `pro report
update-status` when both of its fetches fail). For those, collect watches that kind's streamed
stderr lines. A line containing `permission denied (HTTP 403)` classifies the attempt as a missing
permission, using the requirements table's list.

### 9.2 Cause rules, first match wins

| # | Signal | Cause | Reachability effect |
|---|---|---|---|
| 1 | message contains `OWNERSHIP_FORBIDDEN`, or hint starts `The credential's scope level does not match` | Scope rejected | Platform `rejected` |
| 2 | message contains `ENVIRONMENT_NOT_FOUND` | Unknown environment ID | Platform `rejected` |
| 3 | message starts `request blocked at the Jamf gateway edge` | Gateway edge block | none |
| 4 | hint contains `does not serve this endpoint` or `not part of the Jamf Platform gateway's published API`, or exit 8 | Not served through the gateway | none |
| 5 | exit 5 and hint contains `Jamf Platform API integration` | Missing permission; names parsed from the hint when present, else from the table | none |
| 6 | exit 5 and hint contains `Required privilege(s):` | Missing privilege; names parsed from the hint | none |
| 7 | exit 5 with no recognized hint, or a swallowed 403 (9.1) | Missing permission; names from the table | none |
| 8 | anything else | Existing handling (auth, network, not found, other) | none |

Parsing rules for named permissions: gateway names are the text between `in Jamf Account: ` and
`. Names are`, split on `; `. Jamf Pro names follow `Required privilege(s): ` and are split on `, `.
If parsing yields nothing, the table's list is used.

### 9.3 Storage

The last cause and hint for each kind live in `state/<kind>.cause.json`: cause, named permissions,
raw hint (capped at 4 KB), exit code, date. Written atomically when a failure is recorded; deleted
when the kind lands. Like `.fail`, it stays outside the integrity manifest.

### 9.4 Source states

| State | Rule | Shown |
|---|---|---|
| Landed | Last attempt saved data | Normal |
| Not granted | Never landed; last cause is 5, 6 or 7 | Neutral, with what to grant |
| Access lost | Landed before; last cause is 5, 6 or 7 | Red, with what to grant |
| Failing | Causes 1 and 2 on the first failure, since a rejected ID is definitive; any other cause after two consecutive failures, as today | Red, with the cause |
| Not applicable | Skipped by the reachability record, or cause 4 | Hidden from the banner and freshness checks; listed on the Access card |

"Landed before" is read from the existing `.last` file; no new tracking.

### 9.5 Retries

Self-remediation's exclusion (`WorkspaceStore.excludingPermanentUsageFailures`) extends from exit
2 and 8 to causes 1, 2, 4, 5, 6 and 7. Edge blocks (3) stay retryable, since jamf-cli advises a
single cold retry. Scheduled collects still attempt every applicable source, and Collect now still
tries everything, so a new grant takes effect on the next run.

### 9.6 Whole-run verdicts

`ReportEngineError.collectDead` gains a cause. When every failure in the run is a permission cause,
the message says the connection reached Jamf but cannot read any data source, and points to Data
Sources > Access. When every failure is cause 1 or 2, it says the gateway rejected the profile's
environment or tenant ID. Otherwise the current outage wording stays.

For gateway profiles, the exit-3 explanation adds that Platform API integrations are valid for six
months and an expired one needs a replacement in Jamf Account.

## 10. Surfaces

### 10.1 Health banner

Access lost and Failing sources raise the banner as today; the detail line names the cause and, for
permission causes, the permission. Not granted and Not applicable sources never raise it.

### 10.2 Access card (Data Sources, below Connection health)

- One line per API from the reachability record.
- One row per report area: Granted, Partly granted, Not granted, or Not applicable, with the missing
  permissions in the connection's vocabulary (Jamf Account names for gateway profiles, Jamf Pro
  privilege names for direct connections, console screens for Protect and School).
- A copy button for the missing permissions.
- For Protect, a button that runs `jamf-cli protect permissions --output json` on demand and lists
  the API client's granted read and write permissions.
- All hint and permission text is rendered as plain text (`Text(verbatim:)`), never as Markdown.

### 10.3 Screens and Run History

- A screen whose sources are Not granted says which permission would fill it, and does not offer
  Collect now. A screen whose sources are Not applicable says which connection serves them.
- Run History's warning line carries the full hint; the 300-character message cap stays for the
  message itself.

### 10.4 Guided Platform setup

One panel shared by onboarding's Platform step, the Update credentials sheet, and the existing-CLI
setup screen when it adopts a gateway profile.

Instructions, open by default on first setup:

1. Sign in to Jamf Account with the Administrator role or a custom role with Integrations
   privileges. Go to Integrations and choose Create integration.
2. Choose Platform environment as the scope level. Tenant is described as the narrower legacy
   option that cannot use the Compliance Benchmarks, blueprint or DDM screens. Organization is not
   offered, because it reaches nothing the app reads.
3. Select only the environment that holds the Jamf Pro tenant you report on. Caution text: one
   account can hold test, production, High Compliance and beta environments, and an integration
   works only in the environment it was created for.
4. Grant only Read permissions for the report areas you want. An embedded checklist built from the
   requirements table produces the list with a copy button. Never grant create, update, delete,
   execute or destructive permissions; the app never writes.
5. Copy the client ID and the client secret. The secret is shown once.
6. Copy the platform environment ID, not the tenant ID and not the client ID: open the integration
   and click the environment pill in the Integration details panel.
7. Integrations are valid for six months.

Fields:

- Region: US, EU or APAC, plus a custom URL. Replaces the free-text gateway URL.
- Scope level: Environment (recommended) or Tenant. Organization removed. An existing organization
  profile keeps working and shows the level read-only.
- ID field, client ID, client secret as today.

Connection check, run on Save & continue after the credentials pass:

1. `jamf-cli -p <profile> pro jamf-pro-version list --output json`.
2. Only if step 1 exits 4: `jamf-cli -p <profile> pro platform-devices list --filter
   'serialNumber=="jrc-connection-check"' --output json`, which matches nothing and returns one empty
   page.

| Result | Setup shows | Continue | Record |
|---|---|---|---|
| Step 1 returns a version | Region, scope level, ID, Jamf Pro version | Yes | Jamf Pro reachable; Platform reachable |
| Step 1 cause 1 | Which ID is wrong and where the right one lives | Blocked | Jamf Pro and Platform rejected |
| Step 2 cause 2 | Same, for the environment ID | Blocked | Jamf Pro and Platform rejected |
| Step 2 succeeds, or fails with cause 5 or 7 | ID accepted; no Jamf Pro answered in this environment | Warning, may continue | Jamf Pro unreachable; Platform reachable |
| Anything else | The check could not decide | Warning, may continue | unknown |

"Continue without validating" is offered for gateway profiles only when the check could not decide.
The OAuth2 direct connection flow is unchanged.

The panel states that Jamf Pro data comes through the gateway when the environment includes a Jamf
Pro tenant, and points Protect and School to the existing Add products step.

## 11. CLI and documentation

### 11.1 CLI

`jamf-reports permissions` prints the requirements table as Markdown, grouped by report area, with
both vocabularies and the environment-only notes. `--json` prints it as JSON, matching the CLI's
existing flag. Scripts and agents get the same list the app shows.

### 11.2 Wiki

- New page `docs/wiki/13-Permissions-and-Access.md`, added to the sidebar under Reference:
  - Which connection you need, including that the gateway serves the Jamf Pro API when the
    environment includes a Jamf Pro tenant.
  - Creating a Platform API integration, following section 10.4.
  - Scope levels.
  - Permissions by report area: a generated block between
    `<!-- generated:permissions:start -->` and `<!-- generated:permissions:end -->`.
  - Protect and School console screens.
  - Reading the Access card and the source states.
  - Error causes from section 9.2 and what to do for each.
  - Warning: shared workspaces and profile names (section 8.6). Every Mac collecting into a shared
    workspace must use the same connection for a given profile name: the same kind of connection
    and, for gateway profiles, the same environment.
- `01-Installation.md`: replace the "Jamf Pro API permissions" table with a pointer to page 13, and
  delete the `patch-managed` paragraph, which describes a Python-era command that no longer exists.
- `10-Security-and-Operational-Considerations.md`: add the profile-name warning to "Shared
  workspace: several Macs, one history". Reword "Multi-Tenant and Team Access", which currently says
  never to share the workspace directory, so it separates credentials (never shared) from the
  workspace folder (shared only through the shared-workspace layout).
- `02-App-Onboarding.md`: the new setup panel and connection check.
- `09-Diagnostics-and-Troubleshooting.md`: the error causes table.
- `Glossary.md`: platform environment, tenant scope level, the source states.
- `CLAUDE.md` and `AGENTS.md`: service rows for the new services; remove the `platformOnlyKinds`
  paragraph; describe the reachability rule.
- `CHANGELOG.md`: user-facing summary.

A drift test renders the Markdown from the table and compares it with the generated block in page 13,
locating the file the same way `AppVersionDriftTests` locates `build-app.sh`.

## 12. Components

| Component | Kind | Responsibility |
|---|---|---|
| `AccessRequirements` | Static table | Section 7 |
| `JamfCLIErrorEnvelope` | Decoder | Parse `error`, `message`, `exitCode`, `hint` from stdout |
| `FailureCause` | Pure function | Section 9.2 |
| `SourceAccessState` | Pure function | Section 9.4 from `.last`, `.fail` and cause files |
| `ReachabilityRecord` and store | Codable plus atomic store | Section 8 |
| `ReachabilitySkips` | Pure function | Section 8.3 |
| `ConnectionCheck` | Pure verdict plus thin runner | Section 10.4 |
| `AccessCard` | SwiftUI view | Section 10.2 |
| `PlatformSetupPanel` | SwiftUI view | Section 10.4 |
| `Permissions` | CLI subcommand | Section 11.1 |

Changed: `ReportEngine` (capture, skips, verdict causes, School and Protect recording),
`StateFileStore` (cause file), `DataFreshnessHealth` and `WorkspaceStore` (states, expected kinds,
remediation exclusion), `CLIBridge.explainExit` (six-month note), `OnboardingFlow`,
`OnboardingView`, `ReauthenticateSheet`, `ExistingCLISetupView`, `SourcesView`, per-screen banners.

## 13. Related defects found during the investigation

Separate fixes, recommended before or alongside this work:

1. `pro report compliance-rules` and `compliance-devices` require a benchmark title (cobra
   `ExactArgs(1)` since at least jamf-cli 1.18). The collect matrix calls them without one, so both
   exit 2 on every gateway profile and the Compliance Benchmarks screen never fills. Fix: list
   benchmarks first, then run both reports per benchmark.
2. `isCollectDead` counts exit 0 as success even when nothing landed. Upstream commands that exit 0
   after every fetch failed keep a dead run from being labeled dead.

## 14. Upstream reports for Tony to file

1. Jamf Pro commands on a gateway profile render a 404 without the response body, hiding
   `ENVIRONMENT_NOT_FOUND`; the unknown-environment note never appears for them.
2. A Jamf Pro command that gets 403 `OWNERSHIP_FORBIDDEN` receives a permissions hint instead of
   the scope-mismatch hint Platform commands get.
3. `pro report update-status` and `update-status --scan-failures` exit 0 when both fetches fail.
4. `pro audit` reports that all checks passed when every check failed.

## 15. Testing

- Unit tests for every pure function: `FailureCause` (one test per rule, plus ordering between
  rules 1 and 5), `SourceAccessState`, `ReachabilitySkips` (unknown skips nothing; gateway without
  Jamf Pro skips all Jamf Pro and Classic kinds and keeps Platform and SOFA; direct connection skips
  Platform kinds; School-only skips Jamf Pro and Platform), `ConnectionCheck` (one test per verdict
  row), the remediation exclusion, and the `collectDead` cause selection.
- Coverage test: every collect kind has a requirements entry.
- Drift test: generated wiki block matches the table.
- Collect integration test: a gateway profile whose connection check says no Jamf Pro sends zero
  Jamf Pro commands, proven by a stub that logs every call (the 2.8.0 DDM scan technique). The stub
  must not be named `jamf-cli`, because of the codesign gate.
- Mutation checks on the cause rules, the skip function, the retry exclusion and the verdict table.
- Fixtures come from real jamf-cli output, never hand-written shapes:
  - Unknown environment on a Platform command and a bare 404 on a Jamf Pro command: the tester's log,
    with the environment ID and trace IDs scrubbed.
  - A gateway permission-denied envelope: one bounded command from the tester against a source they did not
    grant, for example `jamf-cli -p myjamf pro scripts list --output json | head -c 1500`.
  - A direct Jamf Pro permission-denied envelope: requires a read-limited API role on a test tenant.
- Visual verification at `PageScaffold.minSupportedWidth` for the Access card, the setup panel and
  the region picker. Commits touching them carry `DRAFT — needs visual verification`.

## 16. Open items needing live confirmation

| Item | How |
|---|---|
| Whether one integration can span several environments (where the ID lives is documented, section 6.3) | The tester's screen |
| `pro jamf-pro-version list` returns 200 with a version through the gateway | The tester, after fixing the ID |
| `pro platform-devices list` with the serial filter returns one empty page; without Devices: Read it exits 5 with the integration marker | The tester |
| Real gateway permission-denied envelope | The tester, one bounded command |
| Real direct Jamf Pro permission-denied envelope | A read-limited API role on a test tenant; creating it is a write to Jamf Pro and needs Tony's approval |
| Protect and School permission-failure output | No tenants available; the classifier falls back to rule 7 or 8 until captured |
| Whether High Compliance Cloud has a Platform API gateway | Jamf or the tester |

## 17. Handoff to spec 2: source-aware reporting

Inputs this spec provides: the reachability record, the source states, and the requirements table.

Spec 2 needs to cover:

- Choosing each report section's primary source from what the profile reaches: the Jamf Pro API,
  Platform device inventory (which includes Jamf Pro-enrolled devices), Jamf School, or Jamf
  Protect. Each section states which source it used.
- Collecting Platform device inventory and device groups (section 6.3 lists the fields). The list
  call returns the lighter fields; per-device detail costs one call per device.
- Dropping sections whose source is not applicable, not granted, or empty, with one coverage note
  instead of per-section placeholders. Today every HTML section renders a placeholder, and Protect
  sections say "not configured" when Protect is off.
- School HTML sections: today a School profile's HTML is built from Jamf Pro sections and comes out
  empty; only the Excel workbook is School-specific.
- A Protect-only profile type and onboarding path.
- Not showing Mac security controls as failing when the only source is Platform inventory, which has
  none.
