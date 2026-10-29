# The workspace is the environment — design

Status: design, not built. The direction was decided on 2026-10-19, so this document designs it and does
not argue for it. It must land before any Security Cloud collect code (epic #283). It also
covers epic #284's "Several Platform connections; Jamf Pro vs Jamf School" and #207 L1, L3, L5
and L6 (carried over into #284).

## 1. The model in one paragraph

A workspace is one environment: Prod, QA, Dev, a region, or one MSP client. It names up to
one jamf-cli profile per product: the MDM (Jamf Pro or Jamf School, and neither is required),
the Jamf Platform API connection, Jamf Protect, and Jamf Security Cloud (Radar). Collect runs each
product with its own profile into the one workspace folder. Every screen, report and daily
summary describes the environment as a whole. Devices are joined across products by
`DeviceCorrelation` (UDID, case-folded, and management ID, never a name). The app stays
read-only. Several environments are rolled up by report groups and by a new multi-environment
view, the layer above. An MSP keeps one workspace per client, so data folders, keychain
credentials and webhooks stay apart.

Example: jamf-cli holds `Example` (Jamf Pro, OAuth), `Example-API` (Platform API to the same
Jamf Pro), `Example-Dev` and `Example-Dev-API`. On first launch, 2.10 offers four workspaces and
unticks the OAuth twins. This design offers two environments, `Example` and `Example-Dev`, and
each one holds its OAuth profile and its Platform profile.

## 2. What exists today

| Piece | Today | Becomes |
|---|---|---|
| Workspace folder | `~/Jamf-Reports/<ProfileName.pathComponent(profile)>/`. The folder name is the jamf-cli profile | The folder name is the **workspace ID**. Existing folders keep their names, so nothing on disk moves |
| `jamf_cli.profile` | Must be blank or equal to the run's profile (`ReportEngine.runProfile`, `profileMismatch`) | Retired. Replaced by `profiles.jamf_pro` |
| `protect.enabled/profile` | Protect runs after a Pro collect that returned `.collected` (`CollectRouter`) | `profiles.protect`. The follow rule is generalised (section 7) |
| `school_cli.enabled/profile` | Makes the workspace a School one when the profile is blank or the workspace's own (`isPrimary`) | `profiles.jamf_school` |
| `ProfileProductType` | `.jamfPro` / `.jamfSchool` | Replaced by `EnvironmentProducts`: the set of products present |
| `ConnectedProducts` | Reads protect and foreign-school names | Replaced by the `EnvironmentProfiles` reader |
| `PlatformTwin` | Learns a platform profile's Jamf Pro URL and unticks the matching OAuth profile | Pairs the two into one proposed environment (section 5) |
| `droppingPairedProductProfiles` | Hides a Protect or Security Cloud login named by a workspace | Hides every profile named in any workspace's `profiles:` |
| `Connection`/`ConnectionStore` | Groups the platform profiles made from one Jamf Account credential | Same role. Its members now sit in different environments' `platform` slots (section 9) |
| Schedules, tick state, Run History, pins, report groups, Fleet Overview | Keyed by "profile", which is also the folder name | Keyed by workspace ID: the same string for every existing workspace |

The key point: almost everything keyed by "profile" today is really keyed by the folder. The
only places where the profile must be a jamf-cli profile are the `-p` arguments (the collect
matrix, the device scan, benchmarks, backups, Protect and School loops, `ConnectionCheck`,
`PlatformTwin`, doctor, `CLIBridge` helpers) and profile discovery. The design separates
those two meanings without renaming any folder.

## 3. Config schema

### 3.1 The `profiles` block

```yaml
profiles:
  jamf_pro: "Example"          # runs Jamf Pro API commands (any auth method)
  platform: "Example-API"      # runs Platform-only commands; an environment- or tenant-level profile
  jamf_school: ""              # the Jamf School login; never set together with jamf_pro
  protect: "Example-Protect"   # a `protect setup` profile
  security_cloud: ""           # a `security setup` (Radar) profile
```

Rules:

- A blank or absent slot means the product is not in this environment. No `enabled` flags: a
  product is present when its slot names a profile. To pause a product, use
  `jamf_cli.collect_skip` (extended to whole products, see 7.4) rather than clearing its slot.
- `jamf_pro` and `jamf_school` are exclusive. Both set is a Config Doctor `.fail` row
  (`environment.two_mdms`) and collect refuses with one `[error]`: one environment has one
  MDM. An organisation with both runs two environments in one report group.
- The same profile may fill `jamf_pro` and `platform`. That is a Jamf Cloud user with only a
  gateway profile, and today's Platform-only workspace migrates to it (3.3). Every command
  family then names its profile explicitly, with no hidden fallback.
- A profile is in at most one slot of one workspace on this Mac, apart from the
  `jamf_pro` + `platform` case above. Config Doctor fails `environment.profile_shared`
  across workspaces, because two environments collecting one tenant double every rollup.
- When `jamf_pro` and `platform` are different profiles, the Jamf Pro host that `platform`
  reaches (`PlatformTwin.learnJamfProURL`) must be `jamf_pro`'s host. If it is not, Doctor
  fails `environment.platform_host` and collect skips the Platform kinds with one `[warn]`,
  because two different Jamf Pros in one folder would mix their data. An unknown host (the
  probe failed or `jss-url:read` is missing) is a `.warn`, never a block: we could not ask.
- `platform` is never organisation-level (refused, as today).
- Product settings stay in their own blocks: `platform.compliance_benchmarks`, `security_agents`,
  and later a `security:` block for Security Cloud settings, if any exist. That block will not
  hold `profile` or `enabled`. The 2026-10-18 spec's planned `security.enabled/profile` is
  replaced by `profiles.security_cloud`.

`ConfigSchema.tree` gains the block from the decoder's `CodingKeys` (`ProfilesConfig`). The
Config screen's From config.yaml tab and the unknown-key rows follow with no second list.

### 3.2 Which command uses which profile

| Command family | Profile |
|---|---|
| The Jamf Pro collect matrix (minus Platform-only kinds), the device scan, `pro audit`, `pro backup`, `pro device`, group hygiene, `pro computers list` | `jamf_pro` |
| `ReportEngine.platformOnlyKinds` (compliance devices and rules, `ddm-status`, `blueprint-status`), and later `platform-devices`, `platform-device-groups`, `platform audit`, AI governance, the Security Cloud gateway half (`device-groups`, DNS, ZTNA, UEM connectors) | `platform` |
| `school *` | `jamf_school` (its Platform reads, `school blueprints` and `ddm-reports`, use the School profile's own Platform fields, as jamf-cli builds them) |
| `protect *`, `protect backup` | `protect` |
| `security risk list` and the other Radar reads | `security_cloud` |
| The `dashboard` command | `jamf_pro`, with `--include-profile` for `protect` (as today) |
| `ConnectionCheck`, `PlatformTwin` | `platform` |

When both profiles exist, the OAuth (instance) profile runs Jamf Pro commands. Reasons: it works
on-prem, it reaches the Classic API commands the gateway refuses (exit 8), and it keeps the bulk
inventory sweep off the gateway's rate limit. jamf-cli's own wiki tells gateway users to keep an
OAuth profile for exactly this reason. To send everything through the gateway, a user sets
`jamf_pro` to the platform profile.

`ReportEngine.nonPlatformAuthMethod` and the `[skip] <kind>: requires a Platform API profile`
reason change their source. A Platform-only kind is skipped when `platform` is blank
(`[plan] skipping N sources (no Platform API profile in this environment)`), not when
`jamf_pro`'s auth method is OAuth. `environmentLevelKinds` still applies to the `platform`
profile's level. #284's catalog item (`commands -o json` scopes) later replaces both fixed
lists. It does not change this routing.

### 3.3 Reading old configs (no write needed)

`EnvironmentProfiles.resolve(config:workspace:auth:)` is the one reader. When `profiles:` is
absent it derives the slots from the keys in the file today, so every existing workspace runs
unchanged before anything is written:

| Old shape | Derived slots |
|---|---|
| Pro workspace, OAuth or token | `jamf_pro` = workspace ID |
| Pro workspace whose profile is a platform profile | `jamf_pro` and `platform` = workspace ID |
| `protect.enabled: true` | `protect` = `protect.profile`; a blank `protect.profile` is no Protect (skipped with one `[warn]`), as `protectCollect` does today. Corrected 2026-10-29: the earlier text claimed a fallback to the jamf-cli default Protect profile, which the code never had |
| `school_cli` primary | `jamf_school` = workspace ID, `jamf_pro` blank |
| `school_cli` foreign (an old School login in a Pro workspace) | ignored, as today. Doctor keeps its `school_cli.profile` row |
| `jamf_cli.profile` set and equal to the workspace ID | no effect (it always had to match) |

If `profiles:` is present, it wins and the old keys are not read. Then Doctor names each old key
as retired ("No longer read since 2.12").

A golden test runs each old shape through the collect plan and asserts that today's command lines
are produced byte for byte. This is the gate for phases P1 to P3.

### 3.4 Writing and retired keys

The first save from the Data Sources environment card (section 6) writes `profiles:` through
a scoped `saveBlock`, as `ChartsConfigWriter` does. In the same save it drops `jamf_cli.profile`,
`protect.enabled`, `protect.profile`, `school_cli.enabled` and `school_cli.profile`
(`ConfigSchema.retiredKeys`, release 2.12; `ConfigService.dropRetiredKeys`). Like every scoped
writer, it backs up to `config.yaml.bak-<stamp>` first. An empty `protect:` or `school_cli:`
block is removed. A hand-edited file that already has `profiles:` is never rewritten from the
old keys. Onboarding and `jamf-reports scaffold --out` write `profiles:` directly.

Old builds on a shared workspace: an older build reading a file with `profiles:` gets an
unknown-key warning and falls back to the folder name for Jamf Pro, with no Protect. The
design does not write both forms (see decision D3). The release notes tell users to upgrade
every Mac that shares a workspace together.

## 4. Workspace identity

- **Workspace ID** = the folder name under the workspaces root, encoded and validated by the
  `ProfileName` rules (`pathComponent`, `labelComponent`, `folderKey`, `problem(with:)`). A
  new type, `WorkspaceID`, wraps it so a call site cannot pass one where a jamf-cli profile is
  meant, or the reverse. `ProfileService.workspaceURL(for:)` becomes
  `WorkspacePaths.workspaceURL(for: WorkspaceID)`.
- New workspaces: the folder name defaults to the MDM profile's name (`Example`, not
  `Example-API`), so a one-product environment looks exactly as it does today. The user can
  type another name ("Client A Prod"). There is no separate display-name key (D4).
- `ReportEngine.profile` becomes `ReportEngine.workspace` for every folder it reads or writes.
  The per-family profiles come from `EnvironmentProfiles`, resolved once at the top of
  `collect`, `generate` and `backup`, after `SharedConfigPin.checkpoint`.
  `ReportEngineError.profileMismatch` is removed with `jamf_cli.profile`.
- Keyed by workspace ID, with no change of value for existing data: hand-built schedules
  (`ScheduleRecord.profile`, renamed `workspace` with the JSON key kept), managed schedules
  (`multiTarget` "all" becomes all workspaces), `AutomationPolicy.excludedProfiles` (now workspace
  IDs, same values), `ReportGroup.profiles` (same), tick state and run-now labels (the
  label's middle part is `labelComponent(workspaceID)`), Run History logs and status files, the
  shared-config pin file (`shared-config-pin-<pathComponent>.json`), day markers, the alert
  ledger, Fleet Overview rows, the diagnostic bundle folder and `ExportNaming` file names.
- `CollectRouter.run(profile:)` becomes `run(workspace:)`. The case-variant check moves from
  `jamf_cli.profile` to every slot: a slot that names a case variant of another workspace's
  profile is refused.
- Log lines name the product and its profile:
  `[info] collecting computers for Example (Jamf Pro)`. Run History keeps one log per run, per
  workspace.

### 4.1 Pins

Every slot is a shared-config pin key (`profiles.jamf_pro` … `profiles.security_cloud`). This
matters more than any folder setting: a slot names a credential in this Mac's keychain. A peer
that changes `profiles.jamf_pro` to another tenant's profile would make this Mac collect that
tenant into a team folder. The rule matches today's `protect.profile` pin: trust on first sight,
and a later change from a peer or a hand edit is ignored until the operator confirms it in Config
Doctor. The ignored slot reads as blank, and that product is skipped with
`[skip] <product>: profiles.<slot> changed in the shared config.yaml and is not confirmed on this Mac`.
A Data Sources save re-pins only the slots it changed (`changedProfileKeys`).

Migration of an existing pin: the pinned `protect.profile` value seeds `profiles.protect`, so a
peer that writes a different `profiles.protect` before this Mac upgrades shows as drift and
is not adopted at first sight. The other slots seed from the derived values in 3.3.

### 4.2 Discovery and the sidebar

- The sidebar lists workspaces (folders holding a `config.yaml`) only. A jamf-cli profile that
  no workspace names is no longer shown as a workspace waiting to be created. It appears in the
  adoption screen and in a Data Sources card, "Profiles not in an environment" (product, auth
  method, host), with Add to this environment and New environment.
- `droppingPairedProductProfiles` generalises: a profile named in any workspace's slots is
  never a workspace candidate, and `runnableProfiles` becomes `runnableWorkspaces`.
- `ProfileService.localOnlyWorkspaces` skips a folder whose `jamf_cli.profile` names another
  profile, treating it as a copy. With that key retired, the copy test becomes: a folder
  whose MDM slot names a profile that another workspace's MDM slot also names is a copy (the
  `environment.profile_shared` row).
- `WorkspaceStore.activeProfile` becomes `activeWorkspace`. `activeCLIProfile` becomes
  `profile(for product:)`.

## 5. Adoption and onboarding propose environments

`EnvironmentProposal.propose(profiles:learnedJamfProURLs:connections:existingWorkspaces:)` is a
pure function. It replaces `twinOf` in `ExistingCLISetupFlow`:

1. Platform profiles are paired with OAuth or token profiles whose host matches the platform
   profile's learned Jamf Pro URL (`PlatformTwin.twins`). Each pair is one proposed environment:
   `jamf_pro` = the OAuth profile, `platform` = the platform profile, and the folder named after
   the OAuth profile.
2. Two platform profiles in one `Connection` are never in one environment, because each is a
   different environment ID. Two platform profiles that reach the same Jamf Pro host are flagged
   ("two Platform profiles reach one Jamf Pro") and both are left unpaired for the user.
3. A platform profile with no twin is its own environment, with `jamf_pro` = `platform` = that
   profile (today's shape).
4. A Jamf School login is its own environment with `jamf_school`. Its Platform access lives in
   the School profile, so nothing is paired with it.
5. Protect and Security Cloud logins are never paired automatically. There is no server-side
   fact that links a Protect tenant to a Jamf Pro (names prove nothing). Each is shown with an
   "Add to environment" picker. The picker preselects the environment whose MDM profile name is
   the longest prefix of the login's name (`Example-Protect` to `Example`) and labels it
   "suggested by name". The user must confirm. After the first collect, the Protect screen's
   match card (`DeviceCorrelation`) shows the match rate. Config Doctor warns
   (`environment.protect_match`) when fewer than half of the Protect computers that carry an
   identifier match a Jamf Pro computer: the pairing is probably wrong. The same check applies to
   Security Cloud once its identifiers are confirmed.
6. Organisation-level platform profiles and Security Cloud-only logins with no MDM keep their
   2.10 refusals, except where L3 (7.5) makes them valid: a Protect, or Protect plus Security
   Cloud, environment.
7. Profiles that existing workspaces already name are left out. A proposal that would add a
   profile to an existing workspace is offered as "Add Example-API to Example" rather than as a
   new environment.

UI: the adoption screen shows one card per proposed environment. Each card has an editable name,
one row per slot with its profile, and a row menu: Move to environment…, Remove from environment.
Unassigned profiles are listed under the cards. Accept creates each folder, writes
`profiles:`, confirms the written slots in the pin (`confirmWrittenConfig`) and records the
learned Jamf Pro URL on the `Connection` member, as 2.10 does.

Onboarding (new connections): when a Platform profile validates (`ConnectionCheck.accepted`),
onboarding asks Jamf Pro for its URL. If an existing workspace's `jamf_pro` host matches, it
offers "Add to Example" ahead of "New environment". Protect onboarding asks which environment
it belongs to (Protect-only allowed). Security Cloud setup is reachable only from an
environment's Data Sources card.

### 5.1 One Add flow (added 2026-10-19, from the Jamf School test)

Adding a connection and adding a workspace are the same action. Today Settings › Add connection
always opens the seven-step Jamf Pro onboarding, and Jamf School is reachable only from the
first-launch chooser or the workspace chip's "Add Jamf School workspace…". Both are replaced by
one **Add** sheet. Settings › Add connection, the workspace chip's Add item, the Environment
card's empty-slot Add (section 6) and the first-launch chooser all open it. No second button is
added.

1. **What are you adding?** Two choices, each a card with product pictures:
   - **Add to <active environment>**: the environment's slots as cards. Empty slots can be
     chosen: Jamf Protect, Security Cloud, Platform API, and the MDM only while both MDM slots
     are empty. Filled slots are shown greyed with their profile. Not offered on first launch.
   - **New environment**: pick what manages its devices: Jamf Pro, Jamf Pro through the
     Platform API, Jamf School, or none (Protect only, section 7.5). Then name it (default: the
     profile's name).
2. **Use a profile jamf-cli already has, or connect a new one.** The sheet runs profile
   discovery (`config list`) when it opens, and again on **Re-check**. That picks up profiles made
   in Terminal since launch. It lists the profiles of the chosen product that no environment
   names (`JamfCLIProfile.product`). Picking one fills the slot after that product's check
   (`ConnectionCheck` for Platform, the host check of 3.1 for a Platform profile beside
   `jamf_pro`). **Connect new** runs only that product's setup (the PTY `config add-profile`,
   `school setup`, `protect setup` or `security setup`). It skips the workspace step when adding to
   an existing environment.
3. **Re-check suggestions.** When discovery finds profiles that `EnvironmentProposal`
   (section 5) would place, the sheet shows them at the top, for example "Example-API reaches
   the same Jamf Pro as Example — add it?" It also shows a new MDM profile as a candidate new
   environment. Nothing is added without a click.

Facts preselect the choice in step 1, and the user can always change it: a profile whose Jamf
Pro host matches the active environment preselects Add to it. An MDM profile while the active
environment already has an MDM preselects New environment (D10). A Protect or Security Cloud
login preselects Add to the active environment, with a picker for another environment or
"New environment (Protect only)".

Pictures are SF Symbols and the app's own product glyphs, never Jamf logos (NOTICE.md).

**First slice, before P1.** The sheet can ship on today's config. It replaces Settings › Add
connection, the sidebar's "Add workspace…" and "Add Jamf School workspace…", and the School
button in `ConnectionCredentialsSheet`. On today's config it offers:

- New workspace: Jamf Pro, Platform API or Jamf School. Each runs its existing onboarding path
  (`OnboardingFlow` connection types, the School path) from its connection step.
- Add to current workspace: Jamf Protect only, through today's `protect.enabled/profile`
  writer (`ProductConnectSheetView`).
- Re-check: profile discovery lists jamf-cli profiles no workspace names, and adopts one
  through `ExistingCLISetupFlow`.

A Platform API profile added to an existing workspace needs the `profiles` slots (P1 to P4).
A Protect-only workspace needs 7.5 (P8). Neither appears in the sheet until its phase lands:
no disabled placeholder cards. The stale "and CSV mapping" copy goes with the old entry points.

A Jamf School environment shows only what the School API supplies: no Jamf Pro screen,
section, Config tab or Generate option with blanks (section 8, P8). The Jamf School test found
each place it shows today (the Overview, the Generate sheet, Config tabs, the Adopt EAs card).
No `jamf-cli pro` command runs on a School profile: the routing in 3.2 never passes one (a
School environment has no `jamf_pro` slot), and `CLIBridge.refusesProCommand` (from the School
test fixes) stays as the guard behind it.

## 6. Data Sources

An **Environment** card replaces the profile header at the top of Data Sources:

- The workspace name, then one row per slot: product, profile, auth method and level, host
  (the learned Jamf Pro host for `platform`), the last connection check, the newest snapshot
  of that product's kinds, and whether the slot's pin needs confirming.
- Row actions: Add (an empty slot runs that product's setup or picks an unassigned profile),
  Change profile, Remove from environment, and Check. Remove only clears the slot: it never
  removes the jamf-cli profile or any snapshot. A removed product's screens hide, and its data
  stays on disk until retention removes it.
- The `platform` row embeds today's Connection card: the connection name, its other members,
  and Update credentials for all.
- Security Cloud's row shows its two halves on two lines, Radar (the `security_cloud` slot)
  and the gateway half (through `platform`), each with its own status, never one "connected"
  switch (#283).
- The "jamf-cli · live" source list (`CollectSourcesPlan`) is grouped by product as it is
  today, now with each product's profile in the group header. A kind skipped because a slot is
  empty uses the plan's skip wording.

## 7. Collect across products

### 7.1 Order

One `CollectRouter.run(workspace:)` per run, inside the one tick lock hold:

1. `SharedConfigPin.checkpoint`, `EnvironmentProfiles.resolve`, the environment-level gate
   (shared-workspace claim and freshness, the once-a-day full-collect guard). These are per
   workspace today and stay per workspace.
2. The MDM: the Jamf Pro matrix on `jamf_pro`, with the Platform-only kinds on `platform` in
   the same loop (each matrix entry carries its family, and `collectCommandMatrix` takes a
   profile per family instead of one profile). Or the School loop on `jamf_school`.
3. Protect on `protect`.
4. Security Cloud: Radar reads on `security_cloud`, then the gateway half on `platform` (once
   built).
5. The device scan (Jamf Pro only), SOFA and `patch-release-dates`.
6. One environment finalize: today's summary (section 8), the `[partial]` summary line and the
   honesty verdicts.

`[plan]` lines name each product's profile: `[plan] environment Example — Jamf Pro: Example,
Platform API: Example-API, Protect: Example-Protect — collecting N sources: …`.

### 7.2 Failure honesty

- Each product is judged on its own: `isCollectDead`, the outage guard, the auth-dead verdict
  (exit 3) and `FailureCause` per product. An MDM whose credentials were rejected stops the MDM
  kinds and the device scan. Protect and Security Cloud still run, because they hold separate
  credentials. The run is Partial.
- A product that landed nothing logs `[partial] <product>: no source landed` with its causes.
  `CollectHonestyWatcher` reads it like any `[partial]` line, and `retryCouldHelp` asks per
  kind as today.
- Today's rule, "Protect follows only a `.collected` Pro collect", becomes: add-on products
  follow the environment gate, not the MDM's disposition. A stand-down (a peer holds the
  claim) or the day guard stops every product. An MDM collect that ran and failed does not stop
  Protect.
- Per-kind state (`state/<kind>.*`) is already per workspace, and kind names already carry the
  product (`protect-*`, `school-*`, `security-*`), so `DataFreshnessHealth` and
  `expectedKinds` work unchanged once `expectedKinds` reads the products present rather than
  the profile's auth method and `isSchoolWorkspace`. School collect starts recording per-kind
  state (an L6 gap).

### 7.3 Timeouts and the lock

There is no change: every call keeps its limit, and one environment run is one hold. A run
with four products takes longer under the lock. The `[info] <kind> took Ns` lines already show
it.

### 7.4 Pausing a product

`jamf_cli.collect_skip` accepts `protect` and `security_cloud` as whole-product entries, so a
user can pause a product without losing its slot. `ReportEngine.skippableKinds` gains them. A
paused product is left out of the freshness strip, as a skipped kind is today.

### 7.5 Environments with no MDM (#207 L3)

A Protect, or Protect plus Security Cloud, environment runs the gate and then Protect alone.
The once-a-day guard and the shared claim are environment-level, so Protect gets them for
free. Its daily summary has every Mac and mobile figure nil and the Protect figures set. The
Overview shows the Protect section first. This replaces L3's third `ProfileProductType`.

## 8. Screens and the daily summary follow the products present

`EnvironmentProducts` is the one answer to "what does this environment have": the filled slots,
plus the fleet composition from the newest snapshots (Macs > 0, mobile devices > 0) and the
benchmarks and agents configured. `WorkspaceStore` publishes it, and every screen, report section,
Config tab and webhook card reads it instead of `isSchoolWorkspace`, `activeCLIProfile?.auth` or
`ConnectedProducts`.

- Tabs: `TabVisibility.limited(toSchool:)` becomes `limited(to: EnvironmentProducts)`. Protect
  shows only with `protect`, Security Cloud only with `security_cloud`, Compliance Benchmarks
  and DDM Blueprints only with `platform`, the Jamf Pro tabs only with `jamf_pro`, and Mobile
  Fleet only when mobile devices exist.
- Overview: the sections an environment cannot fill are left out, not shown as zero.
  Computers and mobile devices sit side by side when both exist (L5). An environment with no
  MDM opens on Protect.
- Config tabs: the Platform API tab is shown only with `platform`. School-irrelevant tabs carry
  a note on a School environment (L6).
- HTML report and workbook: product groups appear when the product is present. Each figure's
  source line names the product and profile it came from (#284 "reports name the connection").
- Webhook cards name the environment and list the products that contributed.

Daily summary (`DailySummary`) additions. Each is nil when its product or device type is
absent, never 0:

| Field | From |
|---|---|
| `products` (list: `jamf_pro`, `jamf_school`, `platform`, `protect`, `security_cloud`) | the slots that collected that day |
| `protectComputerCount`, `protectMatchedPct`, `protectAlertCounts` (by severity) | Protect snapshots, `DeviceCorrelation` |
| `securityRiskCounts` (by category), `securityCoveredPct` | Security Cloud, once collected |
| The `mobile` object (replaces `mobileEncryptedPct`, `mobilePasscodePct`, `mobileSupervisedPct`; see the mobile spec, section 4.2) | `mobile-devices-list` |
| `lastSeenBuckets` (computers and mobile: under 1 day, under 7 days, 7 days or more) | the stale-basis dates, mobile last inventory |
| `modelFamilyCounts`, `mobileFormFactorCounts`, `osMajorCounts` (computers and mobile) | `computers`, `mobile-devices-list` |
| `storageBuckets` (computers and mobile: under 80%, 80% or more, 90% or more, and the mean) | new collection (8.1) |

The existing Mac figures stay as they are. `mobileOnlySummary` and a Protect-only summary are
produced by the same finalize step. School collect writes a summary from its device rows for the
first time (L6). Trends and alert rules gain the new keys. Alerts on a key whose product is
absent never fire (a nil never fires).

### 8.1 New collection needed

| Figure | Collection | Notes |
|---|---|---|
| Computer storage used | A new `computer-storage` kind: `pro computers list --section STORAGE`, reduced on collect through an allow-list to `{id, udid, bootPercentUsed, capacityMB}` and saved with `saveJSONSnapshot`. Inventory tier, `collect_skip`-able | 2.11 dropped the boot-drive risk factor because STORAGE was not requested. A reduced kind keeps the `computers` snapshot the size it is. Measure the call's time and payload on a large fleet first (D9) |
| Mobile storage used, battery level | Already in `mobile-devices-list` (HARDWARE) | Reader only. Confirmed on jamf-cli 1.31.1: `usedSpacePercentage`, `capacityMb`, `availableSpaceMb`, `batteryLevel` (mobile spec, section 9) |
| App auto-update (App Installers) status | A new kind from jamf-cli's `app-installers` read commands (released in 1.23, never adopted) | Command, shape and whether a per-deployment status needs a fan-out are unverified. Check before planning the tile |
| Mobile last seen | `mobile-devices-list` last inventory update | Jamf Pro's mobile record has no last check-in (Jamf Insights shows none either). The tile says "last inventory" |
| Model family | `computers` HARDWARE model name | Bucket by the marketing name (MacBook, Mac mini, iMac, Mac Pro or Mac Studio). Model identifiers like `Mac14,13` do not name the family |

## 9. Connections after this

`Connection` stays what it is: a per-Mac record of which platform profiles were registered from
one Jamf Account credential, for display and for Update credentials for all. What changes:

- Each member's profile is the `platform` slot of a different environment. Add environments
  creates one environment per ID, with `platform` (and `jamf_pro`, the same profile, when no
  OAuth twin exists), instead of a profile-named workspace.
- `Member.product` becomes the products the check found behind that ID (#284), found by a
  check and never assumed. It is shown on the platform row. It does not pick slots on its own.
- Grouping in the sidebar and Fleet Overview moves from connection sections to report groups,
  plus a connection badge on each environment. A connection is about credentials, not
  reporting.
- #284's "two Pro workspaces under one environment ID are flagged" becomes a Doctor row across
  workspaces: two environments whose `platform` slots carry the same scope ID, or whose
  `jamf_pro` hosts are equal.

## 10. Multi-environment view (Jamf Insights reference)

Superseded on 2026-10-19 by
[2026-10-19-mobile-first-class-design.md](2026-10-19-mobile-first-class-design.md) section 6.
Fleet Overview shows the active environment only, with no selector. Cross-environment figures
exist only in report-group exports. The tiles below now describe one environment. Kept as
written for the record.

Jamf Insights' unit is the instance (one Jamf Pro server). A selector at the top picks several,
and the dashboard updates as instances are selected. Its documentation does not say how figures
combine. Here, the unit is the environment and the selector is a report group.

**Fleet** (Fleet Overview grows into it):

- Selector: "All environments", any report group, or an ad-hoc multi-select. A saved selection is
  a report group (`AutomationPolicy.report_groups`), so the screen, the fleet CSV and workbook
  (`FleetRollup`, `FleetWorkbookEmitter`) and scheduled fleet reports share one definition.
- Tiles, computers and mobile devices side by side in each:
  - Managed devices: computers by model family, mobile devices by form factor.
  - Encryption: FileVault on and off; mobile data protection on and off.
  - Last seen: under 1 day, under 7 days, 7 days or more. These are fixed buckets, the same for
    every environment, so they can be summed. They are separate from each environment's stale
    count, which follows its own `stale_device_days` (D8).
  - Operating system: the share per OS major and version. Computers against SOFA's macOS feed,
    mobile devices against its iOS feed (#207 L5).
  - Storage: mean percentage used, and counts under 80%, at 80% or more, and at 90% or more.
  - App auto-update: installed in the last 30 days and pending in the last 24 hours (macOS),
    once 8.1's App Installers kind exists. Until then the tile is left out, not empty.
  - A row per environment: name, products present, device counts, the date of its newest
    summary, and its health (failing or stale sources). The row opens that environment.
- Combining: counts are summed, and percentages are device-weighted (`FleetRollup`). A tile
  counts only the environments that report its figure and says "3 of 5 environments". It never
  adds counts across products (Protect computers are not added to Jamf Pro computers). Each
  environment's date is shown. When the newest summaries span more than one day, the tile
  says so.
- Source: each environment's newest `DailySummary` (the fields in section 8), read through
  `TrendStore.readSummaries`. The view decodes no snapshots, so twenty client environments load
  as twenty small files. History (a trend per tile) comes from the same summaries.
- Read-only: no management actions, as Jamf Insights' device actions are out of scope.

## 11. Merging two existing workspaces

Today's twin users have two workspaces, `Example` (OAuth) and `Example-API` (Platform). Merge
makes them one environment with no data loss. It is offered from adoption (step 7 in section
5) and from Data Sources › Environment › "Merge another workspace into this one".

**Target and source.** The target is the workspace whose profile goes into `jamf_pro` (the
OAuth one). The source's profile goes into the target's matching slot (`platform`).

**Plan, then apply.** `WorkspaceMergePlan.make(source:target:)` is pure. It lists every file it
would copy, skip or archive, by area, and the sheet shows these counts before anything moves.
The executor holds the tick lock (`HoldPurpose.merge`), so no collect, generate or tick runs
during it. It writes a journal (`automation/.merge-journal.json` in the target) and resumes from
it after a crash. It refuses while a peer holds the shared claim.

| Area | Rule |
|---|---|
| Snapshots (`jamf-cli-data/<kind>/`) | Copy each source file whose name the target lacks. Names carry their own stamp, so readers order them correctly. If both have the same name with the same SHA-256, skip it. If the bytes differ, keep the target's and copy the source's to the archive. Never rename a snapshot (a suffix would break the canonical-name whitelist that filters sync-conflict copies) |
| `state/<kind>.*` | Per kind, keep the side with the newer success. Failure counters come from the same side |
| Daily summaries | A day only the source has is copied. A day both have becomes `target.filling(from: source)`: the target's values win, and the source fills only the figures it measured that the target did not (the Platform-only benchmark figures). Both originals go to the archive |
| Historical chart CSV dir, SOFA cache | Copy files the target lacks |
| Run History logs and `<label>_status.json` | Copy all. Labels keep the source's name, so old runs read as they were |
| Backups | Copy each backup folder with its `.jrc-host` stamp. Names are unique |
| Generated Reports and archive | Copy. Names already carry the profile |
| `config.yaml` | Target's file wins. The source's `profiles` slot is added. `platform.compliance_benchmarks` is copied when the target has none. The source's file goes to the archive, and the sheet lists the keys where the two files differ |
| Schedules (`schedules.json`) | Records for the source are retargeted to the target. A record's stored label is kept (`LaunchAgentWriter.label(for:)` returns it), so tick state and status files stay linked. Managed schedules need nothing |
| Report groups, `excludedProfiles` | Replace the source with the target and de-duplicate |
| Pins | The target's pin is kept, and the new slot is confirmed (this Mac made the change). The source's pin file is removed |
| `connections.json` | Unchanged: the member profile still exists, and `jamfProURL` is recorded |
| The source folder | Moved to `<root>/_merged/<source>-<yyyyMMdd-HHmmss>/` with the archive, never deleted. Discovery never lists it: `_merged` holds no top-level `config.yaml`, and a leading `_` is not a canonical `ProfileName` encoding. The user removes it by hand |

On a shared workspace, the merge runs on one Mac. The other Macs see the source folder
disappear and the target's `profiles` change. That change is pin drift, so each of those Macs
confirms it once before it collects with the new slot.

## 12. MSPs

- One workspace per client environment: "Client A Prod", "Client A Dev". Each has its own
  jamf-cli profiles (and so its own keychain items), folder, webhook and retention.
- Report groups are the client layer ("Client A" = its two environments) and the MSP layer
  ("All clients").
- #207 L1 (an organisation folder holding per-tenant workspaces) is not needed. The workspace
  root is already per Mac (`WorkspaceRootStore`), and report groups name the client. See D11.
- Fleet reports never mix device rows across clients. They carry aggregates only, as today.

## 13. Build plan

Each phase is one PR against the integration branch, with its caller in the same PR. The
golden command-line test from 3.3 runs in every phase from P1.

| # | PR | Tests |
|---|---|---|
| P1 | `ProfilesConfig` decode, `EnvironmentProfiles.resolve` with legacy derivation. Replaces `ConnectedProducts` and the Protect, School and `jamf_cli.profile` reads in `CollectRouter` and `ProfileProductType.detect`. Documents `profiles:` in config.example.yaml (CLAUDE.md: a key is documented in the change that adds its reader) | One test per old shape in 3.3. Golden test: identical command lines for each shape |
| P2 | `WorkspaceID`. `ReportEngine.workspace` for folders, per-family profiles for `-p`. `profileMismatch` removed. Schedules, report groups, pins and Run History renamed to workspace, same values | Folders from the workspace ID, `-p` from the slot. A schedule record with the old JSON key decodes. Golden test still green |
| P3 | Collect across products: `collectCommandMatrix` per family, `[plan]` lines, per-product verdicts, add-on products follow the environment gate, finalize once, `collect_skip` for whole products | Stub jamf-cli through the `locateJamfCLI` seam (not named `jamf-cli`): MDM auth-dead and Protect still runs; stand-down stops all; Platform kinds skipped with no `platform`; host mismatch skips Platform kinds |
| P4 | Data Sources Environment card, `ProfilesConfigWriter`, retired keys dropped on save, pin coverage and seeding, Doctor rows (`two_mdms`, `profile_shared`, `platform_host`, retired keys) | Writer keeps comments outside the block and backs up. Pin drift on a peer edit. Protect pin seeding. Each Doctor row. Needs visual verification at `PageScaffold.minSupportedWidth` |
| P5 | Discovery: slots hide profiles, sidebar lists workspaces only, "Profiles not in an environment" card | `droppingPairedProductProfiles` generalised. Active-workspace fallback when a profile moves into a slot |
| P6 | `EnvironmentProposal`, the adoption screen and the one Add sheet (5.1) that replaces Settings › Add connection and the chip's School item, with Re-check | The four-profile example gives two environments. Connection siblings are never merged. Two platform profiles on one host are flagged. Protect is suggested by prefix and never preselected without the label. Existing workspaces are extended, not duplicated. Re-check lists a profile added after launch. Preselection per 5.1. Needs visual verification |
| P7 | Merge: `WorkspaceMergePlan`, executor with journal, sheet | Fixture workspaces: overlapping summary days filled, same-name snapshots identical and different, schedules keep their labels, report groups de-duplicated, crash after N steps resumes, refused under the lock and under a peer claim, source moved and never deleted |
| P8 | `EnvironmentProducts`, `TabVisibility.limited(to:)`, product-aware Overview, Config and report sections. Protect-only environment (L3). School per-kind state and summary (L6) | Tab sets per product mix. A Protect-only collect writes a summary with Mac figures nil. A School summary is written |
| P9 | Daily summary product and composition fields, Trends and alert keys, `environment.protect_match` Doctor row | Nil when absent. Alert on an absent product never fires. Match-rate row thresholds |
| P10 | New collection: `computer-storage` reduced kind, mobile storage and battery readers, the App Installers kind | Fixtures taken from real jamf-cli output, never written by hand from documentation. The reducer drops every field outside the allow-list |
| P11 | Replaced by the mobile spec's M6: Fleet Overview for the active environment, no selector. `FleetRollup` gains the new fields for report-group exports only. P8 and P9 lose their mobile parts to M2 to M4 (mobile spec, section 7) | See M6 |
| P12 | Security Cloud: `security_cloud` slot setup, Radar collect, gateway half on `platform` | Blocked on a tenant (#283). Plugs into P3, P4 and P9 |
| P13 | Docs: wiki (Data Sources, Getting Started, Automation, Security), README, CLAUDE.md/AGENTS.md, CHANGELOG | — |

Order: P1 → P2 → P3. P4 needs P2. P5, P6 and P7 need P4. P8 needs P3. P9 needs P8. P10 can
start after P1. P11 needs P9 and P10.

## 14. Decisions

All 14 recommendations were accepted on 2026-10-19.

| # | Decision | Recommendation |
|---|---|---|
| D1 | One `profiles:` block, or a `profile` key in each product's block | One block: one reader, one writer, one pin set, one migration target. Product settings stay in their own blocks |
| D2 | Which profile runs Jamf Pro commands when OAuth and Platform both exist | OAuth. Platform runs only Platform-only kinds, the Platform reads and the Security Cloud gateway half |
| D3 | Write both old and new keys for one release, for older builds on a shared workspace | No. Write `profiles:` only and tell users to upgrade every Mac on a shared workspace together. The pin and the unknown-key row make a mismatch visible |
| D4 | A display name separate from the folder name | No. The folder name is the environment's name. Renaming is a later, separate feature |
| D5 | Merge target, and same-day summaries | The OAuth workspace is the target. Same-day summaries become `target.filling(from: source)`, with both originals archived |
| D6 | What happens to the source folder after a merge | It moves to `<root>/_merged/<name>-<stamp>/` and is never deleted by the app |
| D7 | Pair Protect and Security Cloud by name at adoption | Never automatically. A name-prefix suggestion the user confirms, then a Doctor warning when fewer than half the Protect computers match Jamf Pro |
| D8 | Last-seen buckets in the Fleet view | Fixed under 1 day, under 7 days, 7 days or more on each environment's stale-basis dates, kept separate from its stale count |
| D9 | Storage collection shape | A separate reduced `computer-storage` kind, after measuring the STORAGE call on a large fleet. Not added to the `computers` call |
| D10 | Jamf Pro and Jamf School in one environment | Refused. Two environments in one report group |
| D11 | #207 L1 organisation folder | Close it in favour of one workspace per client environment and report groups |
| D12 | Unassigned jamf-cli profiles in the sidebar | No. Workspaces only. Unassigned profiles are listed in Data Sources and adoption |
| D13 | Source of the Fleet view's figures | The daily summary, extended with the small aggregate maps in section 8. Snapshots are never read across environments |
| D14 | Release that retires `jamf_cli.profile`, `protect.*` and `school_cli.*` | The release that ships P4 (planned 2.12). Until then those keys are read as in 3.3 |

Added after the Jamf School test, accepted on 2026-10-19:

| # | Decision | Recommendation |
|---|---|---|
| D15 | Add connection and add workspace as one flow | One Add sheet (5.1) from every entry point, first launch included. It asks add-on or new environment, with facts preselecting the answer |
| D16 | When the Add sheet re-reads jamf-cli's profiles | When it opens and on Re-check. No background polling |
