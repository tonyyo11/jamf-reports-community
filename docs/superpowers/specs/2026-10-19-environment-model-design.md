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
| `jamf_cli.profile` | Must be blank or equal to the run's profile (`ReportEngine.runProfile`, `profileMismatch`) | Replaced by `profiles.jamf_pro`. Not read under a `profiles:` block; still read without one (3.3, D14) |
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
  product is present when its slot names a profile. There is no pause: clearing the slot
  removes the product (7.4).
- `jamf_pro` and `jamf_school` are exclusive. Both set is a Config Doctor `.fail` row
  (`environment.two_mdms`) and collect refuses with one `[error]`: one environment has one
  MDM. An organisation with both runs two environments in one report group.
- The same profile may fill `jamf_pro` and `platform`. That is a Jamf Cloud user with only a
  gateway profile, and today's Platform-only workspace migrates to it (3.3). Every command
  family then names its profile explicitly, with no hidden fallback.
- A profile is in at most one slot of one workspace on this Mac, apart from the
  `jamf_pro` + `platform` case above. Config Doctor fails `environment.profile_shared`
  across workspaces, because two environments collecting one tenant double every rollup.
  Under D17 the MDM slots cannot collide (each names its own folder), so the row is about the
  add-on slots. It is a Doctor row only: collect does not refuse, and there is no tie-break.
- When `jamf_pro` and `platform` are different profiles, the Jamf Pro host that `platform`
  reaches (`PlatformTwin.learnJamfProURL`) must be `jamf_pro`'s host, compared on what each
  server reports. If it is not, Doctor
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

Under a `profiles:` block, a Platform-only kind is skipped when `platform` is blank
(`[plan] skipping N sources (no Platform API profile in this environment)`), not when
`jamf_pro`'s auth method is OAuth. Without the block nothing changes (D19): the Platform-only
kinds run on the workspace's own profile and `ReportEngine.nonPlatformAuthMethod` skips them
by that profile's auth method, with today's `[skip] <kind>: requires a Platform API profile`
wording and its fail-toward-collecting rule. `environmentLevelKinds` still applies to the `platform`
profile's level. #284's catalog item (`commands -o json` scopes) later replaces both fixed
lists. It does not change this routing.

### 3.3 Reading old configs (no write needed)

`EnvironmentProfiles.resolve(config:workspace:)` is the one reader. When `profiles:` is
absent it derives the slots from the keys in the file today, so every existing workspace runs
unchanged before anything is written:

| Old shape | Derived slots |
|---|---|
| Pro workspace, OAuth or token | `jamf_pro` = workspace ID |
| Pro workspace whose profile is a platform profile | `jamf_pro` = workspace ID. No `platform` slot is derived: the Platform-only kinds run on that profile and skip by its auth method, as today (3.2). `resolve`'s `auth:` parameter, which no caller passes, is removed in P3 |
| `protect.enabled: true` | `protect` = `protect.profile`; a blank `protect.profile` is no Protect (skipped with one `[warn]`), as `protectCollect` does today. Corrected 2026-10-29: the earlier text claimed a fallback to the jamf-cli default Protect profile, which the code never had |
| `school_cli` primary | `jamf_school` = workspace ID, `jamf_pro` blank |
| `school_cli` foreign (an old School login in a Pro workspace) | ignored, as today. Doctor keeps its `school_cli.profile` row |
| `jamf_cli.profile` set and equal to the workspace ID | no effect (it always had to match) |

If `profiles:` is present, it wins and the old keys are not read. Then Config Doctor names each
old key still in the file (`environment.old_keys`, `.suggest`): "Not read while profiles: is
set; delete the line." Without the block the old keys are live, so the row is silent. A file
without `profiles:` keeps running through this derivation for all of 2.x (D14).

A golden test runs each old shape through the collect plan and asserts that today's command lines
are produced byte for byte. This is the gate for phases P1 to P3.

### 3.4 Writing the block, and the old keys

The first save from the Data Sources environment card (section 6) writes `profiles:` through
a scoped `saveBlock`, as `ChartsConfigWriter` does, and backs up to `config.yaml.bak-<stamp>`
first. It leaves `jamf_cli.profile`, `protect.*` and `school_cli.*` where they are (D14):
under the block they are inert (3.3), and the old-key writers already refuse under a block
(`ConfigService.saveBlock(profilesSlot:)`). A hand-edited file that already has `profiles:` is
never rewritten from the old keys. Onboarding and `jamf-reports scaffold --out` write
`profiles:` directly, with no old keys.

None of these keys joins `ConfigSchema.retiredKeys` while 3.3 reads them. That list is global,
and every scoped save drops its entries from the block it rewrites
(`ConfigService.dropRetiredKeys`): on a file without `profiles:`, the Backups screen's Jamf
Protect switch (`BackupChoiceConfigWriter`, `saveBlock("protect")`) would delete
`protect.profile` and disconnect Protect. `saveBlock("profiles")` also cannot remove keys from
other blocks. Retiring them for real needs a migration that writes `profiles:` into every
legacy file, then removing the 3.3 derivation: a separate decision, not 2.12.

Old builds on a shared workspace: an older build reading a file with `profiles:` gets an
unknown-key warning for the block. A file migrated by the Data Sources save keeps its old keys,
so the older build still finds Jamf Pro (the folder name), Protect and School as before; a file
onboarding wrote has only the block, so the older build sees Jamf Pro with no Protect. The design still does not write the old
keys into a new file (D3), so the release notes recommend upgrading every Mac that shares a
workspace together; it is advice, not a correctness requirement.

## 4. Workspace identity

- **Workspace ID** = the folder name under the workspaces root, encoded and validated by the
  `ProfileName` rules (`pathComponent`, `labelComponent`, `folderKey`, `problem(with:)`). A
  new type, `WorkspaceID`, wraps it so a call site cannot pass one where a jamf-cli profile is
  meant, or the reverse. `ProfileService.workspaceURL(for:)` becomes
  `WorkspacePaths.workspaceURL(for: WorkspaceID)`.
- The MDM slot names the workspace, permanently (D17): under a `profiles:` block,
  `EnvironmentProfiles.refusal` refuses a block whose MDM slot is not the workspace ID, as it
  does since P1. A new workspace's folder is the MDM profile's name (`Example`, not
  `Example-API`), so a one-product environment looks exactly as it does today. An environment
  with no MDM (7.5) is named by its first filled slot of `jamf_school`, `jamf_pro`, `protect`
  in that order. There is no custom folder name and no separate display-name key (D4); a
  friendly name comes with D4's later renaming feature. Because the MDM slot cannot differ
  from the folder, it cannot drift and needs no pin (4.1).
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
- `CollectRouter.run(profile:)` becomes `run(workspace:)`. The case-variant check stays on the
  workspace's own folder spelling (`ProfileService.caseVariantWorkspace`), which under D17 is
  also the MDM slot. Add-on slots name logins that are never workspaces, so they need no
  case-variant check.
- Log lines name the product and its profile:
  `[info] collecting computers for Example (Jamf Pro)`. Run History keeps one log per run, per
  workspace.

### 4.1 Pins

A slot names a credential in this Mac's keychain, so a peer that points a slot at another
tenant's profile would make this Mac collect that tenant into a team folder. Each slot is
covered once, with the existing pin mechanism (D18):

- `jamf_pro` and `jamf_school` need no pin: under D17 they must equal the workspace ID, and
  `EnvironmentProfiles.refusal` refuses any other value.
- `protect` is pinned today. `SharedConfigPin.current` reads `profiles.protect` once the block
  exists and `protect.profile` before it, under the one `protect.profile` key, so a peer cannot
  add the block unseen. Nothing to migrate.
- `platform` gains a pin key, `profiles.platform`, in P3, the phase that first sends `-p` from
  it. `adoptingMissingKeys` pins it the first time this Mac sees it, and `unconfirmedKeys`
  holds it unconfirmed at first sight when it differs from the MDM slot, as it does for
  `output.timestamp_authority`. A legacy workspace's derived `platform` equals the workspace ID
  (3.3), so it is never held.
- `security_cloud` gets the same key and rule in P12.

The rule is today's: a change from a peer or a hand edit is ignored until the operator confirms
it in Config Doctor. A held or drifted slot reads as blank, and that product is skipped with
`[skip] <product>: profiles.<slot> changed in the shared config.yaml and is not confirmed on this Mac`,
as `protectAllowed` skips Protect today. A Data Sources save re-pins only the slots it changed
(`changedProfileKeys`).

### 4.2 Discovery and the sidebar

- The sidebar lists workspaces (folders holding a `config.yaml`) only. A jamf-cli profile that
  no workspace names is no longer shown as a workspace waiting to be created. It appears in the
  adoption screen and in a Data Sources card, "Profiles not in an environment" (product, auth
  method, host), with Add to this environment and New environment.
- `droppingPairedProductProfiles` generalises: a profile named in any workspace's slots is
  never a workspace candidate, and `runnableProfiles` becomes `runnableWorkspaces`.
- `ProfileService.localOnlyWorkspaces` skips a folder whose `EnvironmentProfiles.namedOwner`
  names another profile, treating it as a copy. Under a block `namedOwner` is the MDM slot, and
  under D17 a copied folder's MDM slot names the folder it was copied from, so the same test
  and the refusal both catch it. No second copy test is added.
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

UI: the adoption screen shows one card per proposed environment. Each card shows its name (the
MDM profile's, D17), one row per slot with its profile, and a row menu: Move to environment…, Remove from environment.
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
     Platform API, Jamf School, or none (Protect only, section 7.5). It is named after that
     profile (D17).
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
- Phasing (D23): P4 ships the rows, Check and Remove. Add and Change open the Add sheet as it
  ships today (5.1's first slice) until P5 and P6 give it the slot-aware steps. A removed
  product's screens hide once P8's `EnvironmentProducts` exists; until then they stay as they
  are and show the product's last data.
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

One `CollectRouter.run(workspace:)` per run, inside the one tick lock hold. P3 keeps today's
order (D19), so the golden test's command lines and router log lines do not move:

1. `SharedConfigPin.checkpoint` and `EnvironmentProfiles.resolve`.
2. The MDM inside `ReportEngine.collect`, which holds the environment-level gate (the
   shared-workspace claim and freshness, the once-a-day full-collect guard) as it does today:
   the Jamf Pro matrix, with Jamf Pro kinds on `jamf_pro` and Platform-only kinds on
   `platform` in the same loop (each matrix entry carries its family, and
   `collectCommandMatrix` takes a profile per family instead of one profile), then the
   verdicts (7.2), the device scan (Jamf Pro only), SOFA, `patch-release-dates` and today's
   summary. Or the School loop on `jamf_school`.
3. Protect on `protect`, as `CollectRouter` runs it today: after a `.collected` MDM collect,
   and after one that failed as a whole, whose error it then rethrows.
4. Security Cloud: Radar reads on `security_cloud`, then the gateway half on `platform` (P12).

P8 lifts the gate out of `collect` into the router, because an environment with no MDM (7.5)
has no collect to hold it. From then the gate runs first and a stand-down or the day guard
stops every product. P9 adds one environment finalize, when the summary gains Protect fields
(section 8); until then Protect adds nothing to the summary, so there is nothing to finalize
twice.

`[plan]` lines name each product's profile: `[plan] environment Example — Jamf Pro: Example,
Platform API: Example-API, Protect: Example-Protect — collecting N sources: …`.

### 7.2 Failure honesty

- Verdicts are per profile, not per product (D20). The matrix's outcomes are grouped by the
  profile each kind ran with, and `enforceCollectVerdicts` runs once per group: the auth-dead
  verdict (exit 3, confirmed by `pro auth token --refresh` on that group's profile), the
  outage guard (`isCollectDead`) and `deadRunCause`. A Platform profile and an OAuth profile
  that reach one Jamf Pro are two credentials and get two verdicts; one profile in both slots
  is one group, today's behaviour.
- The device scan runs on `jamf_pro`, so it runs only when the `jamf_pro` group is neither
  auth-dead nor dead (a dead group still scans when `deadRunAllowsDeviceScan` allows it, as
  today). Without this, Platform kinds that landed would hide a dead OAuth credential: the run
  would read as Partial and the scan would fan out against a server that refused or never
  answered.
- Today's summary is not written when `jamf_pro` sources were attempted and none landed. A run where only the
  Platform kinds landed must not date cached Mac figures today (`matrixLandedNothing`).
- A `jamf_pro` group that is auth-dead throws `authExpired` as today: the exit code, the
  failure webhook and Run History are unchanged, and Protect still runs before the rethrow. A
  dead `platform` group with a live `jamf_pro` group records its kinds failed, logs the
  `[partial]` line below, and the run continues.
- A Platform kind that did not land is named in the run's existing `[partial] N of M source(s) did not
  land` line (`ReportEngine.unlandedSourcesLine`), which `CollectHonestyWatcher` reads per kind;
  `retryCouldHelp` then asks per kind as today, so a permanent failure is not retried all day. No new line.
- Protect's follow rule does not change in P3 (7.1). The day guard and a stand-down already
  stop it, because `collect` does not return `.collected`.
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

Not built (D19). Nobody asked for a whole-product pause, and `collect_skip` keeps its kind
list. To stop collecting a product, clear its slot; its snapshots stay until retention
removes them.

### 7.5 Environments with no MDM (#207 L3)

A Protect, or Protect plus Security Cloud, environment runs the gate and then Protect alone.
The once-a-day guard and the shared claim are environment-level, so Protect gets them once P8
lifts the gate into the router (7.1). Its daily summary has every Mac and mobile figure nil and the Protect figures set. The
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

- One workspace per client environment, named after its MDM profile (`ClientA-Prod`,
  `ClientA-Dev`, D17). Each has its own jamf-cli profiles (and so its own keychain items),
  folder, webhook and retention.
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
| P3 | Collect across products, in today's order (7.1, D19): `collectCommandMatrix` per family, `[plan]` lines naming each profile, per-profile verdicts (7.2, D20), the block-only Platform skip (3.2), `resolve`'s `auth:` parameter removed, the `profiles.platform` pin key (4.1, D18), the host check from the server's own answer for each profile (`PlatformTwin.learnJamfProURL`), the recorded `Connection` URL or jamf-cli's configured URL only when the server gives none. Every site that skips Platform kinds today follows the block rule in the same PR (`nonPlatformAuthMethod` callers, `CollectSourcesPlan`, `expectedKinds`, `collectCommandMatrix` callers) | Stub jamf-cli through the `locateJamfCLI` seam (not named `jamf-cli`). Golden test unchanged. `jamf_pro` auth-dead with Platform kinds landed: `authExpired`, no scan, no summary rebuild, Protect still runs. `platform` auth-dead with `jamf_pro` live: Partial, scan runs. One profile in both slots: today's verdicts. Platform kinds skipped with no `platform` under a block. Host mismatch skips Platform kinds. A `platform` slot that differs from the MDM slot is held at first sight and skips Platform kinds until confirmed. A permanent failure's `[partial]` line does not make `retryCouldHelp` true. The confirmation probe works on a gateway profile unchanged: in jamf-cli 1.35.0 `pro auth token --refresh` goes through the profile's own provider (`PlatformOAuth2Provider.Refresh`, a real exchange), is not refused by the exit-8 gateway check (it carries no API annotation), and a rejected exchange exits 1 on either provider, which the probe already reads as rejected. Read from source; no gateway tenant was available to run it |
| P4 | Data Sources Environment card with rows, Check and Remove (Add and Change through today's Add sheet, D23), `ProfilesConfigWriter` (writes the block, leaves the old keys, 3.4), Doctor rows (`two_mdms`, `profile_shared`, `platform_host` naming both hosts on this Mac, `environment.old_keys`, a slot profile jamf-cli does not list), the `platform.twin` hint reworded to the one-environment shape (D21), pin-aware re-resolve after the checkpoint | Writer keeps comments outside the block, backs up, and leaves `protect.*`, `school_cli.*` and `jamf_cli.profile` in place. A scoped save of the `protect` block on a file without `profiles:` keeps `protect.profile`. Pin drift on a peer edit of `platform`. Each Doctor row. The binding's `jamf_cli.profile` write is unchanged (D22). Needs visual verification at `PageScaffold.minSupportedWidth` |
| P5 | Discovery: slots hide profiles, sidebar lists workspaces only, "Profiles not in an environment" card | `droppingPairedProductProfiles` generalised. Active-workspace fallback when a profile moves into a slot |
| P6 | `EnvironmentProposal`, the adoption screen and the one Add sheet (5.1) that replaces Settings › Add connection and the chip's School item, with Re-check | The four-profile example gives two environments. Connection siblings are never merged. Two platform profiles on one host are flagged. Protect is suggested by prefix and never preselected without the label. Existing workspaces are extended, not duplicated. Re-check lists a profile added after launch. Preselection per 5.1. Needs visual verification |
| P7 | Merge: `WorkspaceMergePlan`, executor with journal, sheet | Fixture workspaces: overlapping summary days filled, same-name snapshots identical and different, schedules keep their labels, report groups de-duplicated, crash after N steps resumes, refused under the lock and under a peer claim, source moved and never deleted |
| P8 | `EnvironmentProducts`, `TabVisibility.limited(to:)`, product-aware Overview, Config and report sections. Protect-only environment (L3), with the environment gate lifted out of `collect` into the router (7.1). School per-kind state and summary (L6) | Tab sets per product mix. A Protect-only collect writes a summary with Mac figures nil. A stand-down or the day guard stops every product, with and without an MDM. A School summary is written |
| P9 | Daily summary product and composition fields, Trends and alert keys, `environment.protect_match` Doctor row, one environment finalize (7.1) | Nil when absent. Alert on an absent product never fires. Match-rate row thresholds |
| P10 | New collection: `computer-storage` reduced kind, mobile storage and battery readers, the App Installers kind | Fixtures taken from real jamf-cli output, never written by hand from documentation. The reducer drops every field outside the allow-list |
| P11 | Replaced by the mobile spec's M6: Fleet Overview for the active environment, no selector. `FleetRollup` gains the new fields for report-group exports only. P8 and P9 lose their mobile parts to M2 to M4 (mobile spec, section 7) | See M6 |
| P12 | Security Cloud: `security_cloud` slot setup, Radar collect, gateway half on `platform` | Blocked on a tenant (#283). Plugs into P3, P4 and P9 |
| P13 | Docs: wiki (Data Sources, Getting Started, Automation, Security), README, CLAUDE.md/AGENTS.md, CHANGELOG | — |

Order: P1 → P2 → P3. P4 needs P2. P5, P6 and P7 need P4. P8 needs P3. P9 needs P8. P10 can
start after P1. P11 needs P9 and P10.

## 14. Decisions

All 14 recommendations were accepted on 2026-10-19. D3 and D14 were changed on 2026-11-03, after
the spec review; the earlier text is in the history of this file.

| # | Decision | Recommendation |
|---|---|---|
| D1 | One `profiles:` block, or a `profile` key in each product's block | One block: one reader, one writer, one pin set, one migration target. Product settings stay in their own blocks |
| D2 | Which profile runs Jamf Pro commands when OAuth and Platform both exist | OAuth. Platform runs only Platform-only kinds, the Platform reads and the Security Cloud gateway half |
| D3 | Write both old and new keys for one release, for older builds on a shared workspace | No: a new file gets `profiles:` only. A migrated file keeps its old keys (D14), so an older peer still reads it; upgrading every Mac together is advised, not required. The pin and the unknown-key row make a mismatch visible |
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
| D14 | Release that retires `jamf_cli.profile`, `protect.*` and `school_cli.*` | None in 2.x. A file without `profiles:` keeps running through 3.3; under the block the keys are inert and Doctor suggests deleting them. They never enter `ConfigSchema.retiredKeys` while any file shape reads them (3.4). Real retirement needs a migration of every legacy file, decided separately |

Added after the Jamf School test, accepted on 2026-10-19:

| # | Decision | Recommendation |
|---|---|---|
| D15 | Add connection and add workspace as one flow | One Add sheet (5.1) from every entry point, first launch included. It asks add-on or new environment, with facts preselecting the answer |
| D16 | When the Add sheet re-reads jamf-cli's profiles | When it opens and on Re-check. No background polling |

Added after the spec review, accepted on 2026-11-03:

| # | Decision | Recommendation |
|---|---|---|
| D17 | Lift the "MDM slot = workspace ID" refusal in P4 so a folder can have a custom name | No. Keep it permanently (4). The MDM slot then cannot drift, needs no pin, and the copy test, case-variant check and tenant guard keep working unchanged. An environment with no MDM is named by its first filled slot. Friendly names come with D4's renaming feature |
| D18 | How the `platform` slot is protected from a peer's edit | One `profiles.platform` pin key in P3, through `adoptingMissingKeys`, held unconfirmed at first sight when it differs from the MDM slot (4.1). No seeding step and no P3-to-P4 dependency. `security_cloud` follows in P12 |
| D19 | P3's scope | Today's order and gate: the gate lift moves to P8 (needed only by an environment with no MDM) and one finalize to P9 (Protect adds nothing to today's summary). The Platform-kind skip by `platform` applies only under a `profiles:` block; without it, today's auth-method rule, and `resolve`'s unused `auth:` parameter is removed. No whole-product `collect_skip`. An MDM auth-dead run keeps throwing `authExpired`, never downgraded to Partial |
| D20 | Whether the Platform API is its own product for collect verdicts | The question is not needed: verdicts are per profile (credential), not per product (7.2). The device scan follows the `jamf_pro` group, and today's summary is not written when nothing landed, or when `jamf_pro` sources were attempted and none landed. One profile in both slots is one verdict, as today |
| D21 | The shipped `platform.twin` Doctor row, which tells a user with a Platform and an OAuth workspace on one Jamf Pro to keep the Platform one | Reword it now to D2 and D5: keep the OAuth workspace, add the Platform profile to it as `profiles.platform`, and exclude the Platform workspace. The guided merge is P7 |
| D22 | Whether the binding (`reconcileConfigProfile`) stops writing `jamf_cli.profile` | No. Under a block it never writes (the MDM slot is the workspace, D17); on an old-shape file it writes the workspace's own name, which the copied-folder test reads. The key stays valid under D14 |
| D23 | The Environment card's actions that need later phases | P4 ships rows, Check and Remove. Add and Change open today's Add sheet until P5 and P6; hiding a removed product's screens waits for P8 (section 6) |
