# Management health and snapshot usernames — design

Status: draft for the owner's review (2026-11-15), revised after an independent plan review the
same day (its findings are folded in; the scope question it raised is Decision 9). Scope agreed for 2.12: read every field the
app already collects and never reads, and let the organization decide whether account names stay
in saved snapshots. Tracked in #305; later work (new sources, a Jamf Pro server version read,
new security controls) is in #421.

Two changes:

1. **Management health**: facts about how well each Mac is managed, read from snapshots the app
   already saves. No new jamf-cli command, no new collect kind.
2. **Usernames in saved snapshots**: account names the `computers` snapshot holds and nothing
   reads are removed before the snapshot is saved, unless the organization chooses to keep them.

## What is true today

Checked on `dev/2-12-0` (grep over `app/Sources`), a test tenant on Jamf Pro 11.33, and a
production `computers` snapshot from October 2026 on Jamf Pro 11.30 (aggregates only).

- `saveCollectedPayload` saves the `computers` payload whole apart from `purchasing`
  (`keepingOnlyPODate`). Every key below is on disk in every snapshot.
- No source file names any of these keys for a Mac. `activationLockEnabled` and `supervised` are
  read for mobile devices only. `ProtectComputerRow` has no coding key for `signaturesVersion` or
  `lastDisconnectionReason`. No reader opens the contents of `device-enrollment-instances`
  (the HTML report counts its rows).
- Nothing stores the Jamf Pro server version: `ConnectionCheck` reads it at setup and drops it.

| Key (`computers` row) | Values seen | Production picture |
|---|---|---|
| `general.mdmProfileExpiration` | ISO date or null | about 1 in 6 expired or inside 90 days, nearly all on stale Macs; about 1% inside 90 days on a Mac that still checks in; none inside 30 days on one |
| `general.jamfBinaryVersion` | `11.33.3-t…` or null | about 1 in 7 below the fleet's newest major.minor |
| `general.userApprovedMdm` | bool | about 1% false |
| `general.mdmCapable.capable` | bool | about 1% false |
| `general.supervised` | bool | all true |
| `general.enrolledViaAutomatedDeviceEnrollment` | bool | about 1 in 7 false |
| `general.lastCloudBackupDate` | date or null | all null |
| `security.attestationStatus` | `SUCCESS`, `PENDING`, `MDA_UNSUPPORTED_DUE_TO_HARDWARE`, `DEVICE_PROPERTIES_MISMATCH` | most `SUCCESS`; a few mismatches |
| `security.lastSuccessfulAttestation` | date or null | set on most |
| `security.recoveryLockEnabled` | bool or null | almost all false |
| `security.activationLockEnabled` | bool or null | almost all false |
| `security.externalBootLevel` | `ALLOW_…`, `DISALLOW_BOOTING_FROM_EXTERNAL_MEDIA`, `NOT_SUPPORTED`, null | mostly allow |
| `security.autoLoginDisabled` | bool | all true |
| `security.remoteDesktopEnabled` | bool or null | almost all true |
| `hardware.batteryHealth` | `NORMAL`, `UNSUPPORTED`, `UNKNOWN` (others not seen) | about 3 in 4 `NORMAL` |
| `hardware.batteryCapacityPercent` | number | about 1 in 7 under 80 |
| `general.appleEnrollmentType`, `general.awaitingConfiguration`, `security.lockdownModeEnabled` | key absent on 11.30; null on the 11.33 test Macs | no real value seen yet |

An unmanaged record carries null for most of these. The expiry split was measured at the
snapshot's own time with a 30-day check-in cut: every expired profile and all but a handful of
the expiring ones belong to Macs that have stopped checking in, which is why the finding is split.

Not seen on any tenant: a `device-enrollment-instances` row (the test tenant has no Automated
Device Enrollment instance). The API reference names `tokenExpirationDate`; the reader is written
from a captured production row, never from the reference (see Open before build).

## One model

`ManagementFacts` (`Models/ManagementFacts.swift`): one Mac's management fields, decoded field by
field from the `computers` row so an odd value costs that field, never the list (the
`ComputerScoreFacts` pattern). Every field is Optional; an absent key, a null and an unparsable
value are all "not reported". It is built in one place, `DeviceInventoryService.recordFromComputer`,
and rides on the record as `management: ManagementFacts?`; there is no second join. When records
merge and both carry facts that differ, the merged value is nil (the `hardwareEncrypted` rule).
The stale split reads the record's own `ComputerDates` through `StaleRule`, as the contact gap
does; a Mac with no known date is in neither bucket and is counted as "check-in unknown".

`ManagementHealth` (`Models/ManagementHealth.swift`): the pure calculator over
`[ManagementFacts]`, the stale rule and `now`. Every surface below reads its result; none counts
for itself (review checklist class 1). It returns, per finding, the Macs it holds and the number
evaluated (Macs that reported the field), so each figure is `{met, of}` and a field no Mac
reports has no figure (class 2).

Managed Macs only: a record `BinaryMissing` or the managed flag marks unmanaged is left out of
every finding, since Jamf reports nulls for it and it is already listed elsewhere.

### Findings

| Finding | Rule | Shown as |
|---|---|---|
| MDM profile expired | `mdmProfileExpiration` before `now` | a gap; the Mac leaves management |
| MDM profile expiring | within `thresholds.cert_warning_days` (90 when unset) | warning; split into "still checking in" and "also stale" by `StaleRule`, because a stale Mac cannot renew and is already on the stale list |
| Jamf binary version | major.minor below the highest major.minor any managed Mac reports; a version that does not parse is not reported | neutral count, worded "behind the newest binary in this fleet (11.33)"; no figure when fewer than two versions are reported. Not a warning, not in the Management filter or the HTML attention list: one test Mac ahead, or the day after a server upgrade, would flag the fleet |
| MDM not user-approved | `userApprovedMdm == false` | gap |
| MDM not capable | `mdmCapable.capable == false` | gap |
| Not supervised | `supervised == false` | count |
| Not enrolled through Automated Device Enrollment | `enrolledViaAutomatedDeviceEnrollment == false` | count, neutral: an organization may enroll by hand on purpose |
| Attestation | `SUCCESS` is attested; `MDA_UNSUPPORTED_DUE_TO_HARDWARE` leaves the Mac out of the share; `PENDING` is pending; any other value is listed as Jamf gives it under "Attestation problem" | share attested, plus a count per other status |
| Battery needs service | `batteryHealth` other than `NORMAL`, `UNSUPPORTED`, `UNKNOWN`, shown as Jamf gives it; and `batteryCapacityPercent` under 80 as its own count | counts, neutral |
| Recovery Lock, Activation Lock, external boot, auto-login, Remote Desktop | the value as reported | neutral counts of on, off and not reported; never a gap in 2.12 (see Not in this change) |
| Lockdown Mode, awaiting configuration, enrollment type | shown only when at least one Mac reports a value | counts |
| Last iCloud backup | detail panel only, when set | a date |

The sparse-data rule applies: a neutral count is never graded against 100%.

### Automated Device Enrollment token

From the newest `device-enrollment-instances` snapshot: per instance, days until
`tokenExpirationDate`. Expired is a gap; within `thresholds.cert_warning_days` is a warning. The
instance name is shown in the app and the workbook, never in a webhook card or AI input. No
snapshot, an unreadable one, or rows without the field read as "not collected" / "could not be
read" / "not reported", each worded apart (class 16).

### Jamf Protect

`ProtectComputerRow` gains `signaturesVersion` (a number) and `lastDisconnectionReason` (text),
decoded per field. The Protect screen's computers table and the workbook's Protect computers tab
gain both columns; the screen gains one line: "N of M behind the newest signatures in this
tenant". They stay on the Protect surfaces, not on the Management health card, because a Jamf
School workspace with Protect has no `computers` snapshot.

## Where it shows

| Surface | What | Seam |
|---|---|---|
| Health Audit | a "Management health" card after Contact gap: one row per finding with its count and denominator; a row opens Computers on that filter. Hidden when there is no `computers` snapshot; an unreadable snapshot says so. | `ManagementHealthSection`, a sibling of `ContactGapSection`, fed from `AuditView.loadCached`'s inventory read |
| Computers | one filter, "Management", holding Macs with any gap or warning finding; a "Management" detail section listing every reported field for the Mac, with the remediation for a gap (re-enroll, approve MDM in System Settings, renew by check-in). | `DeviceFilter`, the detail panel beside `binaryMissingSection`; `DeviceInventoryRecord` gains one optional `management: ManagementFacts?` filled in `recordFromComputer` |
| Workbook | a new tab "Management Health": a summary block (finding, Macs, evaluated) and one row per Mac with a gap or warning (name, serial, finding, value, days). The Automated Device Enrollment instances and their days left sit under the summary. | `SheetID.managementHealth`, `CoreDashboard.sheetPlan` after "Check-in Health"; Full Instance, Operational and Security Posture templates |
| HTML report | "Needs attention" sentences for expired MDM profiles, profiles expiring on Macs that still check in, and an expired or expiring enrollment token; a capped table of those Macs in "Computers needing intervention" with a Reason column, as the contact-gap rows have. | `attentionItems`, `HtmlReport+Inputs` |
| Daily summary, Trends, alerts | see Daily summary; proposed for 2.13 (Decision 9) | the summary writer beside `secureBootPct`, `TrendSeries.Metric`, `MetricAlertEvaluator.AlertMetric` |
| AI insight | the Audit input gains the finding counts by name only | `FleetInsightInput.audit` |

Product gates: the card, filter and tab need a `computers` snapshot, so a Jamf School, Protect-only
or mobile-only workspace shows none of them (School has no Audit or Computers tab). Reads and
decodes run off the main actor in the screens' existing loaders. Finding names are screen strings
(`L()`); status values from Jamf (`DEVICE_PROPERTIES_MISMATCH`) are data and are never localized
or matched through a localized string.

Demo mode: `DemoData` derives every figure from the 524-Mac demo fleet; no control reads a
workspace. Layout work (the card, the detail section) is DRAFT until the owner's visual pass at
`PageScaffold.minSupportedWidth`.

Workbook layout change to announce in the CHANGELOG: one new tab, "Management Health", after
"Check-in Health"; two new columns at the end of the Protect computers tab. No existing tab,
column or row moves.

## Daily summary

```json
"management": {
  "mdmProfileNotExpired": {"met": 644, "of": 652},
  "userApprovedMdm":      {"met": 648, "of": 652},
  "automatedEnrollment":  {"met": 560, "of": 652},
  "attested":             {"met": 569, "of": 585}
}
```

- Only figures whose definition cannot move are stored. "Inside the warning window" moves with
  `thresholds.cert_warning_days` and "binary behind" moves with the fleet's newest version (and is
  redefined in 2.13), so neither is persisted: a `drops_more_than` rule would fire on a config
  edit, and `sameBasis` covers only patch and score. They stay on the screens and reports.
- The enrollment token's days left is not in the summary either: a negative count fails
  `environmentFieldsAreConsistent` and the day's summary would be rejected on the day the token
  expires. The token is reported from the snapshot on the Audit card, workbook and HTML report.
- The `MobileSummary.Share` type is reused. A pair no Mac reports is absent, never 0; the object
  is absent with no managed Macs. `filling(from:)`, `freshSummaryIsBetter` and
  `numbersAreInRange` (`met <= of`) include it.
- Trends metrics, with raw values `mdmProfileNotExpired`, `userApprovedMdm`, `automatedEnrollment`
  and `attested` (added to `init?(rawValue:)`), offered only when the loaded summaries carry them.
  They are not Overview score cards.
- Alert keys: `mdm_profile_not_expired_pct`, `user_approved_mdm_pct`, `automated_enrollment_pct`,
  `attested_pct`. An absent value never fires.
- No backfill. Not a score factor.

## Usernames in saved snapshots

**What is removed.** Before the `computers` payload is saved, in the same pass as
`keepingOnlyPODate` (one reduction function, one `[warn]`, one failure path: a payload that
cannot be reduced is not saved):

- `general.mdmCapable.capableUsers` and `general.mdmCapable.userManagementInfo` (local account
  names and their management IDs); `mdmCapable.capable` stays.
- `general.lastLoggedInUsernameBinary`, `lastLoggedInUsernameMdm`, `lastLoggedInUsernameSelfService`
  (the three timestamps stay).
- `diskEncryption.fileVault2EnabledUserNames` (a list of account names on every production Mac;
  no reader).
- In `mobile-devices-list`, in the pass that removes the lost-mode text:
  `general.lastLoggedInUsernameSelfService`.

`saveCollectedPayload` has no config today: the key is resolved once at collect start (through
the pin) and passed down, so one run never mixes both behaviours.

**The organization's decision.**

```yaml
jamf_cli:
  keep_account_names: false   # true keeps the account names above in saved snapshots
```

- Absent or false: removed. True: kept as jamf-cli returned them, for an organization that reads
  the snapshots with its own tools. A value that is not a boolean reads as false and Config
  Doctor names it.
- Pinned in `SharedConfigPin` with the `protect.backup_on_synced_storage` rule
  (`repinningBackupOptOuts`): a change to false applies at once; a change to true, a `true` at
  first sight, or a `true` met when an existing pin learns the key, waits for a Confirm on this
  Mac, so a peer on a shared folder cannot switch another Mac to writing names. Until confirmed,
  this Mac removes names from what it saves and touches nothing already on disk. The switch's
  writer confirms exactly what it wrote.
- Config Doctor: a `.suggest` row saying which applies, and a `.warn` row when names are kept and
  the data folder is on shared storage (`CloudStorage.isSharedStorage`). Config › Data Sources (or
  the Workspace tab) holds the switch, written by a scoped writer like `ChartsConfigWriter`.
- The key joins `ConfigSchema` and `config.example.yaml`; its reader is the reduction function.

**Snapshots already on disk.** Not rewritten in 2.12. The lost-mode rewrite is the wrong
precedent here: every `computers` file holds the keys, so every dated snapshot (about 13 MB each)
would be re-serialized, re-stamped and re-uploaded by a sync provider, inline under the tick lock;
a once-per-workspace marker would miss a false, true, false sequence; an archive outside the
workspace would be skipped; and on shared storage a Mac whose `true` is not yet confirmed would
erase history another Mac chose to keep, which cannot be undone. Config Doctor's row says that
snapshots saved before this build still hold the names; they leave only through retention (off by
default) or by hand. A rewrite gets its own design in #421, and when built runs only when config.yaml itself
says absent or false, never on drift, an unconfirmed `true` or an unreadable pin.

**The class.** The PR sweeps every saved kind for person-identifying fields no reader names and
lists the grep and its result in the PR body. Known to need a ruling (Decision 10): `userAndLocation` in `computers` and `mobile-devices-list`
carries `realname`, `phone`, `position` and `room` beside the `username` and `email` Offline
Outreach reads; no source file names the first three. Jamf School `school-users` is swept the same
way. A field with a reader stays; a field without one joins the key above.

The diagnostic bundle is unchanged: it already replaces usernames, and never bundles snapshots.

## Not in this change (in #421)

- Recovery Lock, auto-login, Remote Desktop and external boot as `security_policy.controls` or
  score factors: an organization-level policy choice that needs the security-policy spec amended.
- "Behind the server version": needs a `jamf-pro-version` collect kind.
- Storage, and battery as a summary figure (P10).
- A backfill of `management` history.

## Build order

Each slice is one PR into `dev/2-12-0`, stacked.

1. `ManagementFacts`, `ManagementHealth`, fixtures cut from real rows (identifiers replaced).
   Tests only; the caller lands in slice 2 of the same stack.
2. Health Audit card, Computers filter and detail section, demo data. DRAFT visual.
3. Workbook tab, HTML attention lines and table, the Protect decoder fields and columns.
   CHANGELOG "Changed" bullet.
4. Account-name removal at save time, the key, pin, Config Doctor rows, the switch.
5. Daily summary object, Trends metrics, alert keys (2.13 if Decision 9 is taken as recommended).
6. Docs: CLAUDE.md and AGENTS.md, `config.example.yaml`, wiki (Health Audit, Security and
   Operational Considerations, Permissions), CHANGELOG.

## Open before build

- A `device-enrollment-instances` row from production, keys and value types only, to confirm the
  expiry field's name and date format. Until then slice 1 leaves the token reader out.
- One real value each for `appleEnrollmentType`, `awaitingConfiguration` and
  `lockdownModeEnabled` from a Jamf Pro 11.32+ server with enrolled hardware; without one they
  are decoded as text or boolean and shown as reported.

## Decisions for the owner

| # | Question | Recommendation |
|---|---|---|
| 1 | MDM profile warning window | Reuse `thresholds.cert_warning_days` (90) rather than add a key. Production supports it: inside 90 days, about 1% of Macs still check in (renewal is failing) and the rest are stale |
| 2 | "Binary behind" without the server version | Compare with the newest major.minor in the fleet in 2.12; switch to the server version in 2.13 |
| 3 | Account names: default | Removed by default, `keep_account_names: true` to keep; nothing reads them, so no screen changes |
| 4 | Existing snapshots | Leave them in 2.12 and say so in Config Doctor; design a rewrite in 2.13 |
| 5 | Key name and place | `jamf_cli.keep_account_names`, beside `data_dir` |
| 6 | History backfill for `management` | None |
| 7 | One "Management" filter or one per finding | One filter; the Audit card's rows narrow it |
| 8 | Neutral controls (Recovery Lock and the rest) | Counts only in 2.12; policy levels in 2.13 |
| 9 | The summary object, Trends metrics and alert keys after rc1 | Move to 2.13: they add a persisted schema, and the screens, workbook and HTML report carry the figures in 2.12. Slices 1 to 4 are additive and go out with a second release candidate |
| 10 | `realname`, `phone`, `position`, `room` in `userAndLocation` | Remove under the same key if the sweep confirms no reader; `username` and `email` stay for Offline Outreach |

## Test matrix

| Case | Expected |
|---|---|
| Field absent, null or unparsable | not reported; no figure; out of the denominator |
| Unmanaged or binary-missing Mac | in no finding |
| Profile expiring on a stale Mac, a Mac that checks in, a Mac with no dates | exactly one bucket each |
| One binary version; an unparsable version; one Mac ahead | no figure; not reported; a neutral count, no warning |
| Records merge with differing facts | nil |
| Key true at first sight, on pin upgrade, or flipped by a peer | names removed on save; nothing on disk touched; Config Doctor asks for a Confirm |
| Key true to false | applies at once |
| Key not a boolean | false; Config Doctor row |
| Reducer cannot serialize the payload | snapshot not saved; failure recorded |
| Jamf School, Protect-only, mobile-only workspace | no card, filter or tab |
| Unreadable `computers` snapshot | "could not be read", never empty |
| Demo mode | no workspace read |
