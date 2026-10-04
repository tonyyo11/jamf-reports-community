# Organization-defined security policy — design

Status: proposed 2026-10-01, awaiting owner sign-off. Base: `efae9496` (`v2.9.0-beta1`).

## Why

Community feedback: on Apple silicon and T2 Macs the internal volume is always encrypted by
the Secure Enclave; FileVault off means the volume unlocks without a password, not that the
data is unencrypted. Marking those Macs "not encrypted" and counting them as a security gap is
wrong for some organizations. Others (a baseline that mandates FileVault) want exactly that
strict reading. The app should not pick: the organization defines what counts as a gap.

## What exists today (verified at `efae9496`)

- Eight separate pieces of code decide whether a control is failing, and they disagree:
  `CompliancePostureService.is*Failing`, `SecurityValueState`, `statusLooksBad`,
  `valueLooksGood`, `RiskScoringService`'s affirmative/negative matching,
  `CoreDashboard.securityControlFormat`, `CSVDashboard.isSecurityCompliant`, and jamf-cli's own
  `filevault_encrypted` count.
- P0/P1 action items are computed three ways (`ReportEngine` summary writer: FV+SIP+FW;
  `SecurityPostureView`: the same from the screen's data; `CoreDashboard` Executive Summary:
  FileVault only, under a label that says FV/SIP/FW).
- The Device Security State sheet colours `UNENCRYPTED` green (`contains("ENCRYPT")`).
- Nothing the report engine, scheduled runs or the CLI execute reads app preferences. The
  existing score-weight setting is a per-user preference, so the Security Posture ring uses
  custom weights while the score in `summary.json` (Overview card, Trends, alerts, workbook)
  always uses the defaults.
- Hardware facts: the `computers` snapshot has `hardware.appleSilicon` and
  `hardware.modelIdentifier`. Jamf has no T2 field. `pro report security` device rows carry no
  hardware, so they join to `computers` by serial.

## Design

### 1. The policy lives in the workspace's `config.yaml`

```yaml
security_policy:
  controls:
    filevault: fail      # fail | warning | ignore
    sip: fail
    firewall: fail
    gatekeeper: fail
  # FileVault off on a Mac whose internal volume is hardware-encrypted
  # (Apple silicon, or Intel with the T2 chip). Omit to use the filevault level.
  filevault_off_hardware_encrypted: warning
```

Every key is optional. With the block absent the app behaves exactly as it does today (all
four controls `fail`, no hardware rule). It is per workspace because every machine sharing a
workspace, and every headless run, must apply the same rule.

| Level | Meaning |
|---|---|
| `fail` | Today's behaviour: a security gap. Counts in action items, the per-device gap count, risk points and the score; shown red. |
| `warning` | Shown amber and counted under "Warnings". Not a gap: no action item, no gap count, no risk points; does not lower the score. |
| `ignore` | Not evaluated: no pass/fail, neutral colour, and the control's weight is dropped from the score (the calculator already renormalizes missing metrics). |

The P0/P1 split (FileVault, SIP, Firewall are P0; Gatekeeper is P1) stays as it is.

### 2. One classifier, one fleet counter

- `SecurityControlPolicy` (decoded from the block) with
  `verdict(for control, value, hardwareEncrypted: Bool?) -> pass | fail | warning | ignored | unknown`.
  Unmeasured values stay `unknown`, as `CompliancePostureService.knownValue` already does.
- `HardwareEncryption.isHardwareEncrypted(appleSilicon:modelIdentifier:architecture:) -> Bool?`:
  true for `appleSilicon == true`, an `arm64` architecture string (CSV path), or a model
  identifier in the T2 list (a closed set of 16 identifiers; Intel Macs are discontinued).
  Unknown hardware returns nil and is treated strictly (the control's own level applies).
- `SecurityFleetCounts`: per control pass/fail/warning/unknown counts, P0/P1, and the per-device
  gap count, built from security device rows joined to `computers` by serial.

These replace the eight classifiers and the three P0/P1 computations. Consumers:
`ReportEngine` summary writer, `SecurityPostureService`/View, `CompliancePostureService`,
`RiskScoringService` (through a `hardwareEncrypted` field on `DeviceInventoryRecord`),
`DevicesView` pills and gap count, `CoreDashboard` (Executive Summary, Device Security State,
Compliance Posture sheets), `CSVDashboard`, `HtmlReport` tiles.

### 3. What does not change

- `fileVaultPct` stays the share of Macs with FileVault on: a fact, so history is untouched.
  Where the hardware rule is `warning` or `ignore`, surfaces that show it add a second figure
  ("N more hardware-encrypted, FileVault off") and per-device wording becomes
  "FileVault off (hardware-encrypted)" instead of "Not encrypted".
- Decided upstream, so not governed by the policy: jamf-cli `pro audit` findings, Compliance
  Benchmark rules, mSCP baseline failure counts, `custom_eas`, the embedded jamf-cli dashboard.
- No history rebuild. P0/P1, the compliance proxy and the score in `summary.json` follow the
  policy from the day it changes; Trends shows a step on that day. Documented, not hidden.

### 4. GUI

- Config → Scoring gains a "Security policy" card: one row per control with
  Fail / Warning / Not counted, plus the hardware-encrypted FileVault row with a one-line
  explanation. Saved through a scoped store (the `NotifyConfigStore` pattern), outside
  `ConfigService.managedTopLevelKeys`.
- Overview → Customize: SIP, Firewall and Gatekeeper become selectable score cards
  (`summary.json` already stores them); a control set to Not counted is not offered.
- Layout changes are marked `DRAFT — needs visual verification`.

### 5. Optional, owner's call: score weights move into the same block

`security_policy.score_weights` replaces the per-user Scoring preference, so the ring, the
Overview card, Trends, alerts and reports use one set of weights. The Scoring tab loads from
config, falling back once to the old preference; saving writes config. Cost: a workspace with
customized weights sees its `summary.json` score step on the day it saves.

## Known limits

- `security` is collected every 12 h and `computers` every 48 h; a Mac enrolled in between has
  no hardware row and gets the strict reading until the next inventory collect.
- T2 detection rests on the model-identifier list; the `appleSilicon` flag has only been seen
  on test tenants' mostly synthetic records and should be checked against production data.
- CSV-only workspaces need `columns.architecture` or a model-identifier column mapped; without
  either, the hardware rule cannot apply.

## Also fixed by this change

The `UNENCRYPTED`-green cell and the Executive Summary P0 mismatch are corrected as part of
moving those call sites. Reported next to this work and not yet verified: the app reads
`security.bootstrapTokenEscrowed` where live data carries `bootstrapTokenEscrowedStatus`.

## Tests

Characterization first: with no `security_policy` block, every consumer produces today's
numbers (except the two defects above, asserted to their corrected values). Then per level and
for the hardware rule, with fixtures taken from the real `computers` and `security` shapes.
