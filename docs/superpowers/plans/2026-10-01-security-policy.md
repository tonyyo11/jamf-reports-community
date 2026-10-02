# Organization-defined security policy

Implements `docs/superpowers/specs/2026-10-01-security-policy-design.md` at full scope: per-control levels, the hardware-encrypted FileVault level, and section 5 (score weights in `security_policy.score_weights`). T2 Macs are detected by a closed model-identifier list. With no `security_policy` block every persisted number (summary.json P0/P1, score, percentages) stays as it is today. One correction to the spec's section 2: fleet counts (P0/P1, score inputs) start from jamf-cli's own summary counts, as today, and device rows only move hardware-encrypted FileVault-off Macs. jamf-cli's summary and its device rows disagree (fixture `security.json`: `sip_enabled` 1 and `gatekeeper_enabled` 100 while 100 rows read `NOT_COLLECTED`), so counting rows would change today's numbers. Tasks run in order in one worktree, each followed by a review. Source and test paths are under `app/Sources/JamfReports/` and `app/Tests/JamfReportsTests/`; `config.example.yaml` is at the repo root.

## Global Constraints

- Work only inside this worktree. Do not push, open a PR, or edit GitHub issues.
- Do not edit `CHANGELOG.md`, `README.md`, `CLAUDE.md`, `AGENTS.md` or `BACKLOG.md`; put the proposed CHANGELOG line (plain language, what changed for the user) in your report instead.
- Before the first edit of each file, run `git log --oneline origin/main..HEAD -- <path>` and put the count in your report. At 3 or more, state why your change does not undo that work.
- One commit per task. Subject `feat(security-policy): <imperative, ≤72 chars>` (or `fix`/`refactor`/`test`), body names the task (`Task 3 of docs/superpowers/plans/2026-10-01-security-policy.md`). No attribution or co-author trailers. Do not use: critical, crucial, essential, significant, comprehensive, robust, elegant.
- Test first. Characterization tests come first: write them against the unchanged code, see them pass, keep them passing through the change. With no `security_policy` block every consumer yields today's numbers, except the changes your task lists as intended; assert each of those in its own named test. For new behaviour, write the failing test, see it fail for the stated reason, then build.
- Fixtures use real shapes only, and you say where each came from. Security report device rows: `section`, `name`, `serial`, `os_version`, `filevault`, `sip`, `firewall` (Bool), `gatekeeper`; summary `data`: `total_devices`, `filevault_encrypted`, `sip_enabled`, `firewall_enabled`, `gatekeeper_enabled`. Computers: `hardware.serialNumber`, `hardware.appleSilicon` (Bool), `hardware.modelIdentifier` (String), `diskEncryption.bootPartitionEncryptionDetails.partitionFileVault2State`, `security.sipStatus`, `security.firewallEnabled`, `security.gatekeeperStatus`, `security.bootstrapTokenEscrowed`. CSV headers `Apple Silicon`, `Architecture Type`, `Model Identifier`. Never invent other names.
- Tests never read or write the real `~/Jamf-Reports`, never run `jamf-cli`, and clean up any `UserDefaults` key they set with a per-test `defer` (no `tearDown` override on a `@MainActor` test class; Swift 6.1 on CI rejects it). A test class for a SwiftUI `View` type carries class-level `@MainActor`. Test a profile-keyed service by pointing `JRC_TEST_WORKSPACES_ROOT` at a temp dir and restoring it (pattern: `CLIBridgeCachedSnapshotCorruptionTests`).
- Swift 6 strict concurrency; CI compiles with Swift 6.1, which is stricter about `@MainActor` than the local 6.4. No force-unwrap in production code, functions ≤100 lines, lines ≤100 columns, no new package dependency, no new Service/View/Model file without a caller in the same commit.
- Match the surrounding code's comment density. Comments say why, in one or two lines.
- Do not change SwiftUI layout primitives (`HStack`, `VStack`, `frame`, `padding`, spacing, `layoutPriority`, `Spacer`) unless the task says so. If you must, put `DRAFT — needs visual verification` in that commit's body.
- No organisation-specific values anywhere (no real host names, tenant names, people).
- Delete files with `trash`, not `rm -rf`.
- Gate before each commit, from `<worktree>/app`: `swift build --build-tests 2>&1 | grep "error:" || echo OK`, then `swift test --filter '<SuiteA>|<SuiteB>'` for the suites you touched or added. Report the actual counts. Do not run the whole suite; the controller runs it at integration.
- If the task would pass ~350 changed source lines, or something it describes does not match the code, stop, leave the tree clean, and report what you found instead of building it.
- Replaced classifiers are deleted, not kept behind shims. No new type beyond what the task names.
- A new config key gets a default in the decoder, a reader, and a `config.example.yaml` entry; the controller handles README and CLAUDE.md.
- The scoped config store follows `NotifyConfigStore` / `ChartsConfigStore` (`ChartsConfigLoader`, `ChartsConfigWriter`) and stays outside `ConfigService.managedTopLevelKeys`.
- Persisted raw values are never renamed: `TrendSeries.Metric`, `OverviewSection`, the `crowdstrike` raw value, summary.json field names.
- Hardware lookup (controller amendment, overrides any task text that says `hardware[serialKey(x.serial)]`): the hardware index is looked up through `HardwareEncryption.lookup(serial: String?, name: String?, in index: [String: Bool]) -> Bool?`, which Task 2 defines. `index(computers:)` stores each computer under `"s:" + serialKey(serial)` when it has a serial, and under `"n:" + name` (trimmed, lowercased `general.name`) only when exactly one computer in the snapshot has that name. `lookup` tries the serial key first; when the row's serial is empty it tries the name key; otherwise nil (the control's own level applies). Reason: on the project's test tenants only 1 to 2 of about 100 records carry a serial, in both the security rows and the `computers` snapshot, so a serial-only join could never be exercised there. Task 2's tests add: a row with no serial and a unique name resolves; a row with no serial whose name two computers share resolves to nil.
- `reading` as built (controller amendments after Task 1's review, overriding Task 1's rule list where they differ): a value containing "encrypting paused" reads false (a paused encryption is not transient); a value containing "some partitions" reads nil; `OPTIMIZING` and SIP `NOT_AVAILABLE` read nil. Later tasks call `SecurityControlPolicy.reading` and never restate its rules.
- Locate code by symbol with `rg`; never trust line numbers. Other work lands on these files first (blank `connected_value` handling in `RiskScoringService`, `OverviewView` strings, `CoreDashboard` mobile sheets, `HtmlReport` `asInt` and chart-JSON escaping); build on it, do not undo it.

## Task 1: Policy model, config key, and the compliance proxy on verdicts

Files: create `Models/SecurityPolicy.swift` and `Services/SecurityPolicyConfigStore.swift` (loader only). Modify `Engine/ConfigDecoder.swift` (`ReportConfig`), `Services/CompliancePostureService.swift`, `Views/CompliancePostureView.swift` (one string), `Engine/ReportEngine.swift` (`buildSummaryFromCLI`), `config.example.yaml`. Tests: create `SecurityControlPolicyTests.swift`; extend `CompliancePostureServiceTests.swift`.

Consumes: existing `SecurityDevice`, `ConfigLoader.loadFromString(_:)`, `ChartsConfigLoader` (pattern).

Produces:
- `enum SecurityControl: String, CaseIterable, Sendable { case fileVault = "filevault", sip, firewall, gatekeeper }`
- `enum SecurityControlLevel: String, CaseIterable, Sendable { case fail, warning, ignore }`
- `enum SecurityVerdict: Sendable, Equatable { case pass, fail, warning, ignored, unknown }`
- `struct SecurityControlPolicy: Sendable, Equatable, Decodable` with `var fileVault, sip, firewall, gatekeeper: SecurityControlLevel`, `var fileVaultOffHardwareEncrypted: SecurityControlLevel?`, `static let default`, `init(fileVault: SecurityControlLevel = .fail, sip: SecurityControlLevel = .fail, firewall: SecurityControlLevel = .fail, gatekeeper: SecurityControlLevel = .fail, fileVaultOffHardwareEncrypted: SecurityControlLevel? = nil)`, `init(from decoder: Decoder) throws`, `func level(for control: SecurityControl) -> SecurityControlLevel`, `var usesHardwareRule: Bool`, `func hardwareRuleApplies(fileVaultReading: Bool?, hardwareEncrypted: Bool?) -> Bool`, `static func reading(_ raw: String?) -> Bool?`, `func verdict(for control: SecurityControl, reading: Bool?, hardwareEncrypted: Bool?) -> SecurityVerdict`, `func verdict(for control: SecurityControl, value: String?, hardwareEncrypted: Bool?) -> SecurityVerdict`, `func gapCount(fileVault: Bool?, sip: Bool?, firewall: Bool?, gatekeeper: Bool?, hardwareEncrypted: Bool?) -> Int?`
- `ReportConfig.securityPolicy: SecurityControlPolicy?` (CodingKey `security_policy`); `extension ReportConfig { var resolvedSecurityPolicy: SecurityControlPolicy }` (`?? .default`)
- `enum SecurityPolicyConfigLoader { static func load(profile: String) -> SecurityControlPolicy }`
- `CompliancePostureService.deviceGapCount(_ device: SecurityDevice, policy: SecurityControlPolicy, hardwareEncrypted: Bool?) -> Int?`; `CompliancePostureService.load(from url: URL, policy: SecurityControlPolicy) -> Snapshot?`; `Snapshot.ControlGap` gains `var warningDevices: Int = 0` as its last stored property.

Behaviour:
1. `controls` keys `filevault`, `sip`, `firewall`, `gatekeeper`; values `fail`, `warning`, `ignore`, trimmed, case-insensitive. A missing or unrecognised control value is `.fail`; a missing or unrecognised `filevault_off_hardware_encrypted` is nil. `init(from:)` never throws (the `AlertRule` pattern): a scalar or sequence where a mapping belongs yields the default for that part and the rest of config.yaml still decodes.
2. `usesHardwareRule`: `fileVaultOffHardwareEncrypted` is `.warning` or `.ignore` and `fileVault` is not `.ignore`. `hardwareRuleApplies`: `usesHardwareRule && fileVaultReading == false && hardwareEncrypted == true`.
3. `reading`, the one value reading every surface uses, on the value trimmed, lowercased, `_` replaced by a space: (a) empty → nil; (b) contains `not collected`, `not available`, `not supported`, `unknown` or `pending` → nil; (c) matches `^\d+/\d+$` (Jamf CSV "encrypted/total partitions") → true when both numbers are equal and > 0, else false; (d) equals `false`, `no`, `0`, `off` or `none`, or contains `not `, `no partitions`, `disabled`, `unencrypted`, `inactive`, `decrypt` or `missing` → false; (e) equals `true`, `yes`, `1` or `on`, or contains `enabled`, `encrypted`, `escrowed`, `installed`, `active`, `app store` or `identified developers` → true; (f) otherwise nil. So ENCRYPTING, INELIGIBLE and RESTART_NEEDED read unknown, as commit 088ccd25 decided.
4. `verdict(reading:)`: level `.ignore` → `.ignored`; reading nil → `.unknown`; true → `.pass`; false → for `.fileVault` when `hardwareRuleApplies`, the hardware level, else the control's level (`fail` → `.fail`, `warning` → `.warning`, `ignore` → `.ignored`). `verdict(value:)` is `verdict(reading: Self.reading(value))`.
5. `gapCount`: nil when every non-ignored control's reading is nil; else the number of `.fail` verdicts.
6. Loader mirrors `ChartsConfigLoader`: no workspace or no file → `.default`; a file that fails to decode → `.default` and `AppLogger.report.warning` naming the file.
7. `CompliancePostureService`: delete `isFileVaultFailing`, `isSIPFailing`, `isFirewallFailing`, `isGatekeeperFailing`, `knownValue`. Gap counts come from `policy.gapCount` (strings through `reading`, the `firewall` Bool as is). `controlGaps` has one row per control not at `.ignore` (labels `FileVault`, `SIP`, `Firewall`, `Gatekeeper`), `failingDevices` counting `.fail` and `warningDevices` counting `.warning`; sort unchanged. `load(profile:)` gets the policy from the loader. Pass `hardwareEncrypted: nil` everywhere in this task; Task 2 supplies it.
8. `CompliancePostureView.controlBar`: when `warningDevices > 0`, `"\(n) failing"` reads `"\(n) failing · \(w) warnings"`.
9. `buildSummaryFromCLI` compliance proxy: `deviceGapCount(device, policy: config.resolvedSecurityPolicy, hardwareEncrypted: nil)`.
10. `config.example.yaml`, after the `alerts:` block, in the file's banner style:
```yaml
# SECURITY POLICY — what counts as a security gap, for every screen, report and
# scheduled run of this workspace. fail (default): a gap — action items, the
# per-device gap count, risk points and the score, shown red. warning: shown
# amber, not a gap, does not lower the score. ignore: not evaluated; its score
# weight is dropped. Percentages (FileVault on, SIP on, ...) are facts and never
# change. Omit the block, or any key, for the default.
security_policy:
  controls:
    filevault: fail      # fail | warning | ignore
    sip: fail
    firewall: fail
    gatekeeper: fail
  # FileVault off on a Mac whose internal volume is hardware-encrypted (Apple
  # silicon, or Intel with the T2 chip). Omit to use the filevault level.
  # filevault_off_hardware_encrypted: warning
```

Tests: `SecurityControlPolicyTests` — `reading` keeps the answer for every value in the three lists of `SecurityValueStateTests` (bad → false, good → true, unknown → nil), plus `1/1` true, `0/1` false, `All Partitions Encrypted` true, `No Partitions Encrypted` false, `Not collected` nil; decoding through `ConfigLoader.loadFromString` (block absent → nil and resolved `.default`; full block; `Warning`; `warn` → `.fail`; `controls: "x"` and `security_policy: [1]` leave the rest of the config decoded); the verdict matrix (each level × reading true/false/nil × hardware true/false/nil, rule `warning` and `ignore`, `filevault: ignore` disabling the rule); the `gapCount` nil rule. `CompliancePostureServiceTests` — characterization on fixture `jamf-cli-data/security/security.json`, default policy: 101 devices, gap counts 100×1 and 1×3, control gaps FileVault 1, SIP 0, Firewall 101, Gatekeeper 1; `testNotCollectedControlsAreUnknownNotFailing` rewritten on the new signature; `firewall: ignore` → no Firewall row, gaps 100×0 and 1×2; `firewall: warning` → Firewall failing 0, warnings 101. Intended change at default: a row whose FileVault is `ENCRYPTING`, `INELIGIBLE` or `RESTART_NEEDED` is no longer a FileVault gap (it moves the summary.json compliance proxy).

Out of scope: hardware detection (Task 2), Devices and risk (Task 3), P0/P1 and score (Task 4), a Config Doctor row for an unrecognised level (report it). Layout: none.

## Task 2: Hardware-encrypted detection in the compliance proxy

Files: create `Models/HardwareEncryption.swift`. Modify `Services/CompliancePostureService.swift`, `Engine/ReportEngine.swift`, and fixture `Fixtures/jamf-cli-data/computers-v4/computers-v4.json` (add `"appleSilicon": true` to each of its three `hardware` objects; the Mac14,x models are Apple silicon). Tests: create `HardwareEncryptionTests.swift`; extend `CompliancePostureServiceTests.swift`, `Engine/SummaryJSONEmitTests.swift`.

Consumes (Task 1): `SecurityControlPolicy` (`usesHardwareRule`, `reading(_:)`, `gapCount(fileVault:sip:firewall:gatekeeper:hardwareEncrypted:)`), `CompliancePostureService.deviceGapCount(_:policy:hardwareEncrypted:)`, `SecurityPolicyConfigLoader.load(profile:)`, `ReportConfig.resolvedSecurityPolicy`.

Produces:
- `enum HardwareEncryption` with `static let t2ModelIdentifiers: Set<String>`, `static func isHardwareEncrypted(appleSilicon: Bool?, modelIdentifier: String?, architecture: String?) -> Bool?`, `static func isHardwareEncrypted(computer item: [String: Any]) -> Bool?`, `static func serialKey(_ serial: String?) -> String?`, `static func index(computers items: [[String: Any]]) -> [String: Bool]`, `static func index(dataDir: URL, for policy: SecurityControlPolicy) -> [String: Bool]`
- `CompliancePostureService.load(from url: URL, policy: SecurityControlPolicy, hardware: [String: Bool]) -> Snapshot?`, replacing Task 1's two-argument form.

Behaviour:
1. `t2ModelIdentifiers` is exactly `iMac20,1`, `iMac20,2`, `iMacPro1,1`, `MacPro7,1`, `Macmini8,1`, `MacBookAir8,1`, `MacBookAir8,2`, `MacBookAir9,1`, `MacBookPro15,1`, `MacBookPro15,2`, `MacBookPro15,3`, `MacBookPro15,4`, `MacBookPro16,1`, `MacBookPro16,2`, `MacBookPro16,3`, `MacBookPro16,4`. Its doc comment cites https://support.apple.com/en-us/103265 and Apple's "Identify your … model" pages (checked 2026-10-01).
2. `isHardwareEncrypted`, first match wins: `appleSilicon == true` → true; architecture (trimmed, lowercased) is `arm64` or starts with `apple m` (config.example documents `Apple M3 Pro`) → true; model identifier (trimmed) in the T2 set → true; a known Intel Mac (`appleSilicon == false`, or architecture `x86_64`, `i386` or starting with `intel`) with a non-empty model identifier → false; otherwise nil. Nil means the control's own level applies.
3. `isHardwareEncrypted(computer:)` reads `hardware.appleSilicon` (Bool, NSNumber, or `"true"`/`"false"`) and `hardware.modelIdentifier`. `serialKey`: trimmed, uppercased, nil when empty.
4. `index(computers:)` maps `serialKey(hardware.serialNumber)` to non-nil results; the first row wins. `index(dataDir:for:)` returns `[:]` without touching disk unless `policy.usesHardwareRule`; else reads the newest `<dataDir>/computers/` file via `FileManager.newestJSONFile(in:)`; an unreadable or non-array file gives `[:]` and `AppLogger.report.warning` naming it.
5. `CompliancePostureService.load(profile:)` and `buildSummaryFromCLI` build the index once and pass `hardware[serialKey(device.serial)]`. Never read `computers` through `cachedData(kind:)`: that adds `computers` to summary.json `collectionSources`.

Tests: `HardwareEncryptionTests` — all 16 identifiers true; `MacBookPro14,1` and `iMac19,1` with `appleSilicon: false` → false; `MacBookPro17,1` and `MacBookAir10,1` with no other fact → nil (not T2, nothing says Intel); `appleSilicon: true`, `arm64`, `Apple M3 Pro` → true; Intel without a model → nil; all nil → nil; `index(computers:)` on `computers-v4.json` → three entries, true, keyed `FXTR0021AA`, `FXTR0022AA`, `FXTR0023AA`; on `computers-list.json` (no hardware facts) → empty; `index(dataDir:for: .default)` → empty with a valid file present. Compliance proxy with inline rows, rule `warning`: Apple-silicon FileVault-off Mac 0 gaps, `MacBookPro16,2` (T2) 0, `MacBookPro14,1` 1, a serial with no computers row 1, an empty serial 1; rule `ignore`: the same gaps and no warnings. Summary writer: no block → `collectionSources` has no `computers` key; rule `warning` → the proxy `compliancePct` you computed by hand.

Out of scope: Devices, risk, P0/P1, wording. Layout: none.

## Task 3: Devices, risk and the inventory gap count on one reading

Files: modify `Models/Models.swift` (`DeviceInventoryRecord`, `DeviceInventorySnapshot`; delete `statusLooksBad`, `valueLooksGood`, `SecurityValueState`), `Models/SecurityPolicy.swift`, `Services/DeviceInventoryService.swift`, `Services/RiskScoringService.swift`, `Views/DevicesView.swift`. Tests: trash `SecurityValueStateTests.swift` (its cases live in `SecurityControlPolicyTests`); update `DeviceInventoryRecordTests`, `DeviceSecurityStateTests`, `RiskScoringServiceTests`; `OverviewLiveDataTests` must pass unchanged.

Consumes: Task 1 `SecurityControlPolicy.reading(_:)`, `verdict(for:value:hardwareEncrypted:)`, `gapCount(fileVault:sip:firewall:gatekeeper:hardwareEncrypted:)`, `hardwareRuleApplies(fileVaultReading:hardwareEncrypted:)`, `SecurityPolicyConfigLoader.load(profile:)`; Task 2 `HardwareEncryption.isHardwareEncrypted(appleSilicon:modelIdentifier:architecture:)`, `isHardwareEncrypted(computer:)`.

Produces:
- `DeviceInventoryRecord`: `var hardwareEncrypted: Bool? = nil` (last stored property); `func securityGapCount(policy: SecurityControlPolicy) -> Int` and `func risk(policy: SecurityControlPolicy) -> Risk`, replacing the properties.
- `DeviceInventorySnapshot`: `var securityPolicy: SecurityControlPolicy = .default` (last stored property); `var fileVaultOffHardwareEncryptedCount: Int`; `securityGapCount` uses `securityPolicy`.
- `SecurityControlPolicy`: `static let hardwareEncryptedFileVaultOffLabel = "FileVault off (hardware-encrypted)"`; `func fileVaultLabel(_ value: String, hardwareEncrypted: Bool?) -> String`.
- `RiskScoringService.Input.from(record: DeviceInventoryRecord, agentCheck: RiskScoringService.SecurityAgentCheck? = nil, policy: SecurityControlPolicy) -> Self`.

Behaviour:
1. `securityGapCount(policy:)` = `policy.gapCount(...) ?? 0` over the FileVault, SIP, firewall and Gatekeeper readings with `hardwareEncrypted`, plus 1 when `reading(bootstrapToken) == false` (bootstrap token is not governed by the policy). `risk(policy:)` is today's rule on that count.
2. `fileVaultEnabled` = `reading(fileVault)`. `fileVaultPercent` keeps its denominator (non-empty values); its numerator counts `reading == true`. `fileVaultOffHardwareEncryptedCount` counts devices where `hardwareRuleApplies(reading(fileVault), hardwareEncrypted)`.
3. `fileVaultLabel` returns the label constant when `hardwareRuleApplies`, else `value` unchanged.
4. `merge`: `hardwareEncrypted = hardwareEncrypted ?? other.hardwareEncrypted`.
5. `recordFromComputer`: `hardwareEncrypted = isHardwareEncrypted(computer: item)` on the raw item. `recordFromCSV`: Apple silicon from header `Apple Silicon` (yes/true → true, no/false → false, else nil), model from `Model Identifier`, architecture from `Architecture Type`, then `Architecture`.
6. `DeviceInventoryService.load`: policy from the loader; sort by `risk(policy:)`; set `snapshot.securityPolicy`. `sourceDates` untouched.
7. `RiskScoringService`: delete `normalizedStatus`, `looksAffirmative`, `looksNegative`. FileVault, SIP, Gatekeeper and firewall pass unless `policy.verdict(for:value:hardwareEncrypted:)` is `.fail`; `bootstrapEscrowed = reading(bootstrapToken) != false`.
8. `DevicesView`: pill and glyph tone from the verdict (pass `.teal`, fail `.danger`, warning `.warn`, ignored or unknown `.muted`); Bootstrap from `reading` (true `.teal`, false `.danger`, nil `.muted`). Glyph for `.warn`: symbol `exclamationmark.circle.fill`, colour `Theme.Colors.warn`. FileVault pill text and glyph help use `fileVaultLabel`. The `.security` filter, risk pills, priority risk and CSV export use `activeSnapshot.securityPolicy`. FileVault tile sub, when `fileVaultOffHardwareEncryptedCount > 0`: `"\(gaps) security gaps · \(n) more hardware-encrypted, FileVault off"`.

Tests: characterization on the unchanged code first: `computers-list.json` records (gaps 0, 5, 0 and their risk) and `csv/jamf1128_computers_builtin.csv` rows via `recordFromCSV` (record today's gap counts and `fileVaultPercent`). Intended changes at default, one test each: `Not collected`, `Not supported` and `Not available` are no longer gaps or risk points; `Off`, `none`, `inactive`, `missing` and `DECRYPTING` are gaps and risk points; CSV FileVault `0/1` is a gap and `1/1` counts as encrypted; `No Partitions Encrypted` is not encrypted. Policy: with rule `warning` an Apple-silicon FileVault-off record has 0 gaps, the label `FileVault off (hardware-encrypted)`, and no `noFileVault` risk factor (present at default). `hardwareEncrypted` from inline computers JSON (Apple silicon → true; `MacBookPro16,2` with `appleSilicon: false` → true; `MacBookPro14,1` with false → false) and from the jamf1128 CSV (`Apple Silicon` Yes → true). Existing risk tests pass `policy: .default`.

Out of scope: Security Posture, workbook, HTML; whether live data carries `security.bootstrapTokenEscrowedStatus` (report it, keep the key). Layout: none (text, tone and symbol only).

## Task 4: Fleet counts for summary.json and the Security Posture screen

Files: create `Models/SecurityFleetCounts.swift`. Modify `Models/SecurityPolicy.swift`, `Engine/ReportEngine.swift` (`buildSummaryFromCLI`), `Services/SecurityPostureService.swift` (delete the `SecurityScoreCalculator.input(from: SecurityPostureService.Snapshot)` extension), `Views/SecurityPostureView.swift`, `Models/DemoData+Security.swift`. Tests: create `SecurityFleetCountsTests.swift`; update `PostureViewsRenderTests`, `DemoDataSecurityTests`; `GoldenFleet/GoldenFleetTests` passes unchanged.

Consumes: Task 1 `SecurityControlPolicy` (`level(for:)`, `reading(_:)`, `usesHardwareRule`, `hardwareRuleApplies(fileVaultReading:hardwareEncrypted:)`), `SecurityPolicyConfigLoader.load(profile:)`, `ReportConfig.resolvedSecurityPolicy`; Task 2 `HardwareEncryption.index(dataDir:for:)`, `serialKey(_:)`.

Produces:
- `struct SecurityFleetCounts: Sendable, Equatable` with `struct Control: Sendable, Equatable { let level: SecurityControlLevel; let on: Int; let fail: Int; let warning: Int }`, `let totalDevices: Int`, `let controls: [SecurityControl: Control]`, `let fileVaultOffHardwareEncrypted: Int`, `static let empty`, `var p0: Int?`, `var p1: Int?`, `func scoreInput() -> SecurityScoreCalculator.Input`, `static func onCounts(_ summary: SecuritySummaryData) -> [SecurityControl: Int]`, `static func build(totalDevices: Int, onCounts: [SecurityControl: Int], devices: [SecurityDevice], hardware: [String: Bool], policy: SecurityControlPolicy) -> SecurityFleetCounts`, `static func build(items: [SecurityReportItem], hardware: [String: Bool], policy: SecurityControlPolicy) -> SecurityFleetCounts?`
- `SecurityControlPolicy.effectiveScoreWeights(_ base: SecurityScoreWeights) -> SecurityScoreWeights`
- `SecurityPostureService.Snapshot`: `var fleetCounts: SecurityFleetCounts = .empty`, `var policy: SecurityControlPolicy = .default`; `load(from url: URL, policy: SecurityControlPolicy, hardware: [String: Bool]) throws -> Snapshot`.

Behaviour:
1. A control is in `controls` only when the summary carries its count. `off = max(total − on, 0)`; level `fail` puts `off` in `fail`, `warning` in `warning`, `ignore` in neither.
2. When `usesHardwareRule`: `moved` = min(`off`, device rows where `hardwareRuleApplies(reading(row.fileVault), hardware[serialKey(row.serial)])`); take `moved` out of FileVault's fail or warning bucket, add it to `warning` when the rule is `warning` (drop it when `ignore`); `fileVaultOffHardwareEncrypted = moved`, else 0.
3. `p0`: nil when the summary has no FileVault count (today's rule); else the sum of `fail` over FileVault, SIP and Firewall present. `p1`: Gatekeeper's `fail`, nil when absent.
4. `scoreInput()`: compliant `on + warning` for FileVault, SIP and Firewall when present (ignored ones included). `effectiveScoreWeights` zeroes each of those three weights at `.ignore`, so the calculator skips it without listing it as missing. `build(items:)` returns nil without a summary section.
5. `buildSummaryFromCLI`: one hardware index, shared with the proxy; `fleet = build(items:hardware:policy:)`; `actionItemsP0 = fleet.p0`, `actionItemsP1 = fleet.p1`; score from `fleet.scoreInput()` with `policy.effectiveScoreWeights(.defaultWeights)`. Percent fields unchanged.
6. `SecurityPostureService.load(profile:)` sets `policy` and `fleetCounts`. View: score input `fleetCounts.scoreInput()`, weights `snapshot.policy.effectiveScoreWeights(<the current @AppStorage weights>)`; P0/P1 tiles `fleetCounts.p0 ?? 0` and `p1 ?? 0`. KPI tile `sub` (the value is unchanged): ignored control `Not counted by this workspace's policy`; FileVault with `fileVaultOffHardwareEncrypted > 0` `"\(on) of \(total) · \(n) more hardware-encrypted, FileVault off"`; other controls with warnings `"\(on) of \(total) · \(w) warnings"`; else today's `"\(on) of \(total)"`.
7. `DemoData.securityPostureSnapshot.fleetCounts` = `build(totalDevices:onCounts:...)` from `securityControls`, no devices, `.default`.

Tests: characterization first — GoldenFleet case A (P0 15, P1 2, score 98.0) unchanged; fixture `security.json` through `emitSummaryJSON`: P0 202, P1 1, score 33.3; the demo ring score unchanged. `SecurityFleetCountsTests`: default equals today's arithmetic; `sip: warning` → P0 drops SIP and SIP compliant equals total; `firewall: ignore` → firewall weight 0 and firewall not in `score.missing`; rule `warning` and `ignore` move and count as specified; `filevault: ignore` with rule `warning` moves nothing.

Out of scope: workbook, HTML, config-stored weights (Task 7). Layout: none (strings only).

## Task 5: Workbook and HTML report

Files: modify `Engine/CoreDashboard.swift`, `Engine/CSVDashboard.swift`, `Engine/HtmlReport.swift`, `Models/SecurityFleetCounts.swift`. Tests: extend `Engine/CoreDashboardSecurityTests.swift`, `Engine/ExecutiveSummarySheetTests.swift`, `Engine/CSVDashboardTests.swift`, `Engine/HtmlReportTests.swift`.

Consumes: Task 1 `SecurityControlPolicy` (`verdict(for:value:hardwareEncrypted:)`, `reading(_:)`, `level(for:)`), `ReportConfig.resolvedSecurityPolicy`; Task 2 `HardwareEncryption.index(dataDir:for:)`, `isHardwareEncrypted(computer:)`, `isHardwareEncrypted(appleSilicon:modelIdentifier:architecture:)`; Task 3 `fileVaultLabel(_:hardwareEncrypted:)`; Task 4 `SecurityFleetCounts` (`build(items:hardware:policy:)`, `controls`, `p0`, `p1`, `scoreInput()`, `fileVaultOffHardwareEncrypted`), `effectiveScoreWeights(_:)`.

Produces: `SecurityFleetCounts.nonFailingPct(_ control: SecurityControl) -> Double?` — nil when the control is absent, at `.ignore`, or total is 0; else `(total − fail) / total × 100`.

Behaviour:
1. Executive Summary (`applySecurityMetrics`, `applySecurityScoreAndActions`): P0/P1 from the fleet, which fixes the FileVault-only P0 under the label "P0 Action Items (FV/SIP/FW gaps)"; score from `scoreInput()` with `effectiveScoreWeights(.defaultWeights)`. `ExecutiveSummaryMetrics` gains `var fileVaultOffHardwareEncrypted: Int?`; when > 0 the row `FileVault off, hardware-encrypted` follows `FileVault Coverage`.
2. Security Posture sheet: when > 0, the row `FileVault off, hardware-encrypted` with the count follows `FileVault Encrypted`.
3. Compliance Posture sheet, per control row: `.ignore` → status `Not counted`, format `.cell`; else `ragStatus(pct: nonFailingPct)`, where `GREEN` with warnings > 0 becomes `AMBER`/`.yellow`. The value column is unchanged.
4. Device Security State: delete `securityControlFormat`. Hardware per row from `isHardwareEncrypted(computer:)`. The four controls: pass `.green`, fail `.red`, warning `.yellow`, ignored or unknown `.cell`; FileVault text through `fileVaultLabel`; Bootstrap from `reading`. Intended at default: `UNENCRYPTED` red (defect fix), unreadable values such as `NOT_COLLECTED` neutral (were red), `ENCRYPTING` neutral (was green).
5. CSVDashboard Security Controls: delete `isSecurityCompliant`. The four controls use the verdict with `isHardwareEncrypted(appleSilicon: nil, modelIdentifier: <columns.model value>, architecture: <columns.architecture value>)`: compliant = pass, non-compliant = fail, unknown = unknown (now including unreadable values such as `Not collected`). When any control is not at `fail` or `filevault_off_hardware_encrypted` is set, a sixth column `Warning` follows `% Compliant`. An ignored control's label reads `"\(label) (not counted)"` and its Non-Compliant cell `—`. Bootstrap Token uses `reading`; Secure Boot keeps its rule (`full security`, `medium security` compliant), inlined.
6. HtmlReport `buildSummaryTiles` (both callers) takes the fleet, built from the same `security` snapshot decoded as `[SecurityReportItem]`, plus the index. Tile values unchanged. Class: `.ignore` → none, label `"\(label) (not counted)"`; else `colorClass(nonFailingPct)`, with `ok` becoming `warn` when warnings > 0. The FileVault tile adds `<div class="tile-label">\(n) more hardware-encrypted, FileVault off</div>` when n > 0.

Tests: characterization first — Device Security State formats on `computers-list.json`, Compliance Posture statuses and HTML tile classes on `security.json`, CSV control counts on `csv/jamf1128_computers_builtin.csv`; then the intended changes listed above, and Executive Summary P0 on `security.json` going from 1 to 202 (defect fix). Policy cases with inline rows: rule `warning`, `firewall: ignore`.

Out of scope: the HTML exec-summary sentence, mobile sheets. Layout: none (not SwiftUI).

## Task 6: Security Policy card in Config → Scoring

Files: modify `Services/SecurityPolicyConfigStore.swift` (add the writer), `Services/WorkspaceStore.swift`, `Views/ConfigView.swift` (`ScoringTab`), `Models/SecurityPolicy.swift`. Tests: create `SecurityPolicyConfigStoreTests.swift`.

Consumes: Task 1 `SecurityControlPolicy` (memberwise `init`, the four levels, `fileVaultOffHardwareEncrypted`), `SecurityControl`, `SecurityControlLevel`, `SecurityPolicyConfigLoader.load(profile:)`.

Produces: `enum SecurityPolicyConfigWriter { static func save(_ policy: SecurityControlPolicy, profile: String) throws }`; `SecurityControl.displayName` (`FileVault`, `System Integrity Protection`, `Firewall`, `Gatekeeper`); `SecurityControlLevel.displayName` (`Fail`, `Warning`, `Not counted`); `WorkspaceStore.securityPolicy: SecurityControlPolicy` (initially `.default`); `WorkspaceStore.saveSecurityPolicy(_ policy: SecurityControlPolicy) throws`.

Behaviour:
1. The writer follows `ChartsConfigWriter`: read-modify-write of `security_policy`; sets `controls.filevault|sip|firewall|gatekeeper` to raw values; sets `filevault_off_hardware_encrypted`, or removes that entry when nil; keeps every other key inside the block and every other top-level key; encodes with `replacingTopLevelKeys: ["security_policy"]`; atomic replace; errors `invalidProfile`, `invalidDocumentRoot`.
2. `loadConfig()` sets `securityPolicy` from the loader (`.default` in demo mode and with no config). `saveSecurityPolicy`: in demo mode returns without writing; else writes, then assigns.
3. A new Card above "Security Score Weights": `SectionHeader` `Security Policy`; caption `Decides what counts as a security gap on every screen, report and scheduled run for this workspace. Saved to config.yaml.`; one row per control (its `displayName` and a segmented Picker of the three level names); a row `FileVault off on a hardware-encrypted Mac` with options `Same as FileVault` (nil), `Fail`, `Warning`, `Not counted`, disabled while FileVault is `Not counted`, captioned `Apple silicon Macs and Intel Macs with the T2 chip always encrypt the internal disk; with FileVault off it unlocks without a password.`
4. Every change saves at once. A thrown error shows `"Couldn't save the security policy: \(error.localizedDescription)"` in the card in `Theme.Colors.danger`, and the pickers stay on the saved policy. Demo mode: controls disabled with `.help(DemoData.liveOnlyHelp)`.

Tests: writer round trip in a temp workspace (save, then the loader returns an equal policy); `notify:`, `charts:` and an unknown key inside `security_policy` survive a save; a nil hardware level removes the key; an invalid profile throws; `saveSecurityPolicy` in demo mode writes nothing.

Layout: yes. The commit body carries `DRAFT — needs visual verification`; in the report, describe how you checked the card at `PageScaffold.minSupportedWidth` (640).

## Task 7: Score weights move into `security_policy.score_weights`

Files: modify `Models/SecurityPolicy.swift`, `Services/SecurityPolicyConfigStore.swift`, `Engine/ReportEngine.swift`, `Engine/CoreDashboard.swift`, `Views/SecurityPostureView.swift`, `Views/ConfigView.swift` (`ScoringTab`), `Models/FleetHealthMetrics.swift`, `config.example.yaml`. Tests: extend `SecurityControlPolicyTests`, `SecurityPolicyConfigStoreTests`, `Engine/SummaryJSONEmitTests`; update `EDRAgentLabelTests` (drop the `serialize()` assertion).

Consumes: Task 1/6 `SecurityControlPolicy` and its `init`; Task 4 `effectiveScoreWeights(_:)`, `SecurityFleetCounts.scoreInput()`, `SecurityPostureService.Snapshot.policy`; Task 6 `SecurityPolicyConfigWriter.save(_:profile:)`, `WorkspaceStore.securityPolicy`, `saveSecurityPolicy(_:)`; existing `SecurityScoreWeights`, `ScoringConfig.parse(_:)`, `ScoringConfig.storageKey`.

Produces: `SecurityControlPolicy.scoreWeights: SecurityScoreWeights?` (the init gains `scoreWeights: SecurityScoreWeights? = nil`); `var resolvedScoreWeights: SecurityScoreWeights` (`effectiveScoreWeights(scoreWeights ?? .defaultWeights)`); `static func ScoringConfig.displayedWeights(config: SecurityScoreWeights?, legacyRaw: String) -> (weights: SecurityScoreWeights, fromLegacyPreference: Bool)`.

Behaviour:
1. Keys `filevault`, `sip`, `firewall`, `edr_agent`, `mscp`, `xprotect`, `cve`, `secure_boot`, each an integer or a numeric string (YAMLCodec has no float branch; mirror `AlertRule.tolerantDouble`); missing, negative, over 100 or non-numeric → that slot's default. Block absent or not a mapping → nil. Never throws.
2. Every score uses `policy.resolvedScoreWeights`: the summary writer, the Executive Summary, the Security Posture ring (`snapshot.policy`). Remove `@AppStorage(ScoringConfig.storageKey)` from `SecurityPostureView`.
3. The writer writes `score_weights` (rounded integers) or removes it when nil; other keys untouched.
4. `displayedWeights`: config weights when set; else the legacy preference when non-empty (parsed); else defaults. The Scoring tab shows those; each stepper change saves the whole set via `saveSecurityPolicy`; "Reset to v3.5 defaults" saves nil. The preference is read, never written or cleared. Delete `ScoringConfig.serialize()`.
5. The existing caption `Text` gets a new string (same view): `These weights drive the Security Score everywhere: Security Posture, the Overview, Trends, alerts and reports. They are saved to this workspace's config.yaml. Set a weight to 0 to drop that metric entirely. Missing metrics in your data are auto-renormalized so the score still scales to 100.`, followed, while `fromLegacyPreference`, by ` These are this Mac's earlier weights; they apply once you change one, which saves them to this workspace.`
6. `config.example.yaml`, inside `security_policy:` after the hardware line:
```yaml
  # Security Score weights, 0-100 each. Omit for these defaults.
  # score_weights:
  #   filevault: 15
  #   sip: 15
  #   firewall: 15
  #   edr_agent: 10
  #   mscp: 20
  #   xprotect: 5
  #   cve: 15
  #   secure_boot: 5
```

Tests: decoding (integers, `"20"`, a missing slot, `-5`, `150`, a scalar block); GoldenFleet case A data with `filevault: 30` → the score computed by hand, no block → 98.0; `firewall: ignore` with a custom firewall weight → weight 0; writer round trip with weights; `displayedWeights` for config set, legacy only, and neither (pass the raw string; no UserDefaults access).

Out of scope: clearing the legacy preference. Layout: none (one caption string).

## Task 8: SIP, Firewall and Gatekeeper score cards

Files: modify `Models/Models.swift` (`TrendSeries.Metric`), `Services/TrendStore.swift`, `Models/OverviewLayout.swift`, `Views/OverviewView.swift`, `Views/OverviewCustomizeSheet.swift`, `Models/DemoData.swift`. Tests: update `EDRAgentLabelTests`; extend `TrendStoreTests`, `OverviewLayoutTests`, `DemoDataSecurityTests`.

Consumes: Task 1 `SecurityControl`, `SecurityControlPolicy.level(for:)`; Task 6 `WorkspaceStore.securityPolicy`.

Produces: `TrendSeries.Metric` cases `sip`, `firewall`, `gatekeeper` appended after `managedDevices` (raw values `sip`, `firewall`, `gatekeeper`); `var securityControl: SecurityControl?`; `func isOffered(under policy: SecurityControlPolicy) -> Bool`; `static func OverviewCustomizeSheet.scoreCardRows(selected: [TrendSeries.Metric], policy: SecurityControlPolicy) -> [TrendSeries.Metric]`.

Behaviour:
1. Labels `System Integrity Protection`, `Firewall Enabled`, `Gatekeeper Enabled`; unit `%`; `minY` 60; colours `0x64D2FF`, `0x5E5CE6`, `0xAC8E68`. `TrendStore` values `sipPct`, `firewallPct`, `gatekeeperPct`. `dataRequirement` `Needs jamf-cli's security report.`; `detailHint` `Open Security Posture for the per-control breakdown.`; `relatedTabs` `[.securityPosture, .devices]`.
2. `securityControl`: `.fileVault`, `.sip`, `.firewall`, `.gatekeeper` map to their control, the rest to nil. `isOffered` is false only when that control is at `.ignore`.
3. The static `scoreCardRows(selected:policy:)` replaces the sheet's private `scoreCardRows` property and returns today's order without not-offered metrics; the Overview score-card section skips selected metrics that are not offered; the stored selection is untouched. Trends lists all three (they are facts). `defaultScoreCards` unchanged.
4. `DemoData.trends` gains the three series ending on the `securityControls` shares (SIP 100.0, Firewall 482/524, Gatekeeper 512/524) through the existing `trend(...pinnedLast:)`.

Tests: `allCases` equals today's order followed by `.sip, .firewall, .gatekeeper`; a persisted `sip,firewall` selection round-trips; TrendStore values; the mapping and `isOffered`; `scoreCardRows` with `firewall: ignore`; the demo series end on the shares.

Out of scope: new summary fields. Layout: no primitive change; say in the report how the new cards render.

## Task 9: One fleet, every surface, three policies

Files: create `GoldenFleet/SecurityPolicyConsistencyTests.swift`; extend `GoldenFleet/GoldenFleetWorkspace.swift` with security-row and computers-row helpers. No source change: if a surface disagrees, stop and report which.

Consumes: `ReportEngine(config:dataDir:).emitSummaryJSON(summariesDir:)`; `SecurityPostureService.load(from:policy:hardware:)`; `CompliancePostureService.load(from:policy:hardware:)`; `HardwareEncryption.index(dataDir:for:)`; `DeviceInventoryService.recordFromComputer(_:source:)`; `RiskScoringService.score(input: .from(record:policy:))`; `CoreDashboard.executiveMetrics(config:dataDir:)`, `writeDeviceSecurityState()`, `writeCompliancePosture()`, `workbook.sheet(named:)`; `HtmlReport(config:dataDir:).generate(...)`; `ConfigLoader.loadFromString(_:)`; `SecurityControlPolicy.resolvedScoreWeights`; `SecurityFleetCounts.scoreInput()`.

The fleet: a security report with these six device rows and the summary below; a computers snapshot with rows for all but `FXTR0105AA` (same FileVault, SIP, firewall and Gatekeeper values, bootstrap token escrowed).

| Serial | Hardware | FileVault | SIP | Firewall | Gatekeeper |
|---|---|---|---|---|---|
| FXTR0101AA | appleSilicon true, Mac14,2 | ENCRYPTED | ENABLED | true | APP_STORE_AND_IDENTIFIED_DEVELOPERS |
| FXTR0102AA | appleSilicon true, Mac14,5 | UNENCRYPTED | ENABLED | true | APP_STORE |
| FXTR0103AA | appleSilicon false, MacBookPro16,2 | UNENCRYPTED | ENABLED | false | APP_STORE |
| FXTR0104AA | appleSilicon false, MacBookPro14,1 | UNENCRYPTED | DISABLED | true | DISABLED |
| FXTR0105AA | no computers row | UNENCRYPTED | ENABLED | false | APP_STORE |
| FXTR0106AA | appleSilicon true, Mac15,3 | ENCRYPTED | ENABLED | true | APP_STORE |

Summary `data`: `total_devices` 6, `filevault_encrypted` 2, `sip_enabled` 5, `firewall_enabled` 4, `gatekeeper_enabled` 5. Policies: A no block; B `filevault_off_hardware_encrypted: warning`; C `controls.firewall: ignore`.

| Surface | A | B | C |
|---|---|---|---|
| summary.json P0 / P1 | 7 / 1 | 5 / 1 | 5 / 1 |
| summary.json score | 61.1 | 72.2 | 58.3 |
| summary.json `fileVaultPct` | 33.3 | 33.3 | 33.3 |
| summary.json proxy `compliancePct` | 33.3 | 50.0 | 33.3 |
| Posture fleet P0 / P1 / moved | 7 / 1 / 0 | 5 / 1 / 2 | 5 / 1 / 0 |
| Compliance Posture Pass band | 2 | 3 | 2 |
| Executive Summary P0 / P1 / score | 7 / 1 / 61.1 | 5 / 1 / 72.2 | 5 / 1 / 58.3 |
| Risk `noFileVault` on 0102 / 0103 | yes / yes | no / no | yes / yes |
| Risk `firewallDisabled` on 0103 | yes | yes | no |
| Device Security State FileVault, 0102 | `UNENCRYPTED`, red | `FileVault off (hardware-encrypted)`, yellow | `UNENCRYPTED`, red |
| Compliance Posture sheet, Firewall status | RED | RED | Not counted |
| HTML FileVault tile class / note | bad / none | bad / `2 more hardware-encrypted, FileVault off` | bad / none |
| HTML Firewall tile class / label | bad / `Firewall` | bad / `Firewall` | none / `Firewall (not counted)` |

Assert every cell; each column must agree across surfaces because they read the same files. Layout: none.
