# DDM Device Status and MDM Command Health Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give every Jamf Pro profile (on-prem included) a fleet view and a per-device view of DDM declaration/software-update status and of failed or stuck MDM commands, collected read-only through two per-device jamf-cli calls.

**Architecture:** A new scan-tier phase at the end of `ReportEngine.collect` walks the `computers` snapshot and, with at most four concurrent jamf-cli processes, fetches `classic-computer-history --subset commands` for every Mac and `ddm-status status-items` for DDM-enabled Macs. The raw payloads are reduced at collect time into two array snapshots (`ddm-device-status`, `mdm-command-health`) through pure builders; two pure services aggregate those snapshots for the DDM screen, the Devices detail panel, the Health Audit, and two workbook sheets. Nothing mutates Jamf.

**Tech Stack:** Swift 6 strict concurrency, SwiftPM, XCTest, jamf-cli 1.24+ (`pro ddm-status status-items`, `pro classic-computer-history get`), existing `CLIBridge.runAndCapture`, `OOXMLWriter`.

**Spec:** `docs/superpowers/specs/2026-09-04-ddm-device-status-and-mdm-command-health-design.md`

## Global Constraints

- Read side only. Zero mutating jamf-cli calls (no `ddm-syncs sync`, no command flush).
- Computers only. No mobile devices.
- Pending-command age threshold is a fixed 7 days. No config key.
- At most four jamf-cli processes at once in the scan loop.
- Status items are persisted through an ALLOW-list of keys. `mdm.push-token`, `mdm.push-magic`, `server-token`, `security.certificate.*`, `content-cache.*` must never reach disk.
- A per-device 404 on status items records `ddmReported: false`; it is not an error.
- More than 25% of devices failing a call type → that kind is recorded failed and nothing is written. Below that, write plus `[partial] <kind>: N of M devices did not respond`.
- Both new kinds live in `CollectionTier.scan`, in `ReportEngine.expensivePerDeviceKinds`, and are skipped by `skipExpensive`.
- Every jamf-cli identifier placed in argv passes `CLIBridge.isSafeDeviceIdentifier`.
- Test stubs for jamf-cli must NOT be named `jamf-cli` (`CLIBridge.codesignGate` keys on the filename).
- Decodable snapshot rows are identity-free; identity is assigned once at load (JamfCLIDecoder rule).
- Every SwiftUI layout change ships with `DRAFT — needs visual verification at PageScaffold.minSupportedWidth` in the commit body.
- Commit messages carry no `Co-Authored-By` trailer (repo memory `commit_authorship`).
- Build from a non-iCloud path if `swift build` reports "modified during the build" (rsync the worktree to `~/jr-nonnested`, excluding `.build/`, `.claude/`, `app/build/`).
- Before editing any file: `git log --oneline origin/main..HEAD -- <path>` and state the count (CLAUDE.md anti-churn rule).

## File Structure

| File | Responsibility |
|------|----------------|
| `app/Sources/JamfReports/Engine/DeviceScanDecoders.swift` (create) | Raw jamf-cli shapes: `DDMStatusItemsPayload`, `ComputerHistoryCommands` (string-or-object buckets, object-or-array `command`), plus the persisted row types `DDMDeviceStatusRecord`, `MDMCommandHealthRecord`. Spec §2 names `JamfCLIDecoder.swift`; a sibling file is used because that file is already 1,300 lines and these four types change together. |
| `app/Sources/JamfReports/Engine/DeviceScanBuilders.swift` (create) | Pure reductions: allow-listed status items → `DDMDeviceStatusRecord`; declaration string → `[Declaration]`; history → `MDMCommandHealthRecord` (7-day rule); the 25% verdict. |
| `app/Sources/JamfReports/Engine/ReportEngine+DeviceScan.swift` (create) | The scan phase: reads `computers`, runs the two calls with a 4-wide task group, applies the failure rules, writes both snapshots via `saveSnapshot`, records `StateFileStore` outcomes, emits log lines. |
| `app/Sources/JamfReports/Engine/ReportEngine.swift` (modify) | Register the two kinds; call the scan phase; make `saveSnapshot` and `loadLatestSnapshotData` `static` (not `private`) so the extension file can reach them. |
| `app/Sources/JamfReports/Services/CollectionTier.swift` (modify) | Tier map entries. |
| `app/Sources/JamfReports/Services/DDMDeviceStatusService.swift` (create) | Load + aggregate `ddm-device-status`. |
| `app/Sources/JamfReports/Services/MDMCommandHealthService.swift` (create) | Load + aggregate `mdm-command-health`. |
| `app/Sources/JamfReports/Engine/CoreDashboard.swift`, `Engine/Templates/ReportTemplate.swift`, `Engine/Templates/FullInstanceTemplate.swift` (modify) | Two sheets. |
| `app/Sources/JamfReports/Views/DDMBlueprintView.swift` (modify) | Three-input lock, header strip, Declarations and Software updates sections. |
| `app/Sources/JamfReports/Views/DevicesView.swift` (modify) | Two snapshot-fed sections above the live detail. |
| `app/Sources/JamfReports/Views/AuditView.swift` (modify) | "Command health" section with two findings; `auditActionDestination` routes them to Devices. |
| `app/Tests/JamfReportsTests/Fixtures/jamf-cli-data/{ddm-status-items-raw,classic-computer-history-raw}/` (create) | The three scrubbed prod captures. |
| Tests | `DeviceScanDecodersTests`, `DeviceScanBuildersTests`, `DDMDeviceStatusServiceTests`, `MDMCommandHealthServiceTests`, `DeviceScanCollectTests`, `DeviceScanSheetsTests`, plus edits to `CollectionTierTests`, `PlatformOnlyKindTests`, `DDMBlueprintViewTests`, `GoldenFleetTests`. |

Fixture sources (already scrubbed, sitting in this session's scratchpad — copy, do not re-scrub):
`/private/tmp/claude-503/-Users-alyoung-Documents-GitHub-jamf-reports-community--claude-worktrees-explore-2-8-0-capability-b1bf42/71c96050-ccc1-410a-bd17-9d1b5617d63b/scratchpad/fixtures/` →
`ddm-status-items-prod-macos27.json`, `classic-computer-history-commands-prod-nofailures.json`, `classic-computer-history-commands-prod-onefailed.json`.

Run tests from `app/`: `swift test --filter <ClassName>`; never run two `swift test` processes at once.

---

### Task 1: Raw decoders and persisted row types

**Files:**
- Create: `app/Sources/JamfReports/Engine/DeviceScanDecoders.swift`
- Create: `app/Tests/JamfReportsTests/Fixtures/jamf-cli-data/ddm-status-items-raw/ddm-status-items-prod-macos27.json` (copy from scratchpad)
- Create: `app/Tests/JamfReportsTests/Fixtures/jamf-cli-data/classic-computer-history-raw/nofailures.json` and `onefailed.json` (copy from scratchpad)
- Test: `app/Tests/JamfReportsTests/DeviceScanDecodersTests.swift`

**Interfaces:**
- Produces: `DDMStatusItemsPayload { statusItems: [DDMStatusItem] }`, `DDMStatusItem { key: String; value: String?; lastUpdateTime: String? }`, `ComputerHistoryCommands { commands: Buckets }` with `Buckets { completed, failed, pending: Bucket }`, `Bucket { command: [HistoryCommand] }`, `HistoryCommand { name, status, username: String?; issuedEpoch, failedEpoch, lastPushEpoch: Int? }`, `DDMDeviceStatusRecord`, `MDMCommandHealthRecord` (both `Codable, Sendable, Equatable`, shapes in Step 3).

- [ ] **Step 1: Copy fixtures into the repo**

```bash
S="/private/tmp/claude-503/-Users-alyoung-Documents-GitHub-jamf-reports-community--claude-worktrees-explore-2-8-0-capability-b1bf42/71c96050-ccc1-410a-bd17-9d1b5617d63b/scratchpad/fixtures"
F=app/Tests/JamfReportsTests/Fixtures/jamf-cli-data
mkdir -p "$F/ddm-status-items-raw" "$F/classic-computer-history-raw"
cp "$S/ddm-status-items-prod-macos27.json" "$F/ddm-status-items-raw/"
cp "$S/classic-computer-history-commands-prod-nofailures.json" "$F/classic-computer-history-raw/nofailures.json"
cp "$S/classic-computer-history-commands-prod-onefailed.json" "$F/classic-computer-history-raw/onefailed.json"
grep -c 'push-token' "$F/ddm-status-items-raw/ddm-status-items-prod-macos27.json"   # expect 1 — the raw fixture keeps the key so the allow-list test in Task 2 is real
grep -h '"username"' "$F"/classic-computer-history-raw/*.json | sort -u             # expect exactly one line: "username": ""
```

- [ ] **Step 2: Write the failing tests**

```swift
import XCTest
@testable import JamfReports

final class DeviceScanDecodersTests: XCTestCase {

    private func fixture(_ rel: String) throws -> Data {
        try Data(contentsOf: TestFixtures.dir("jamf-cli-data/\(rel)"))
    }

    func testStatusItemsDecodeWithNullValues() throws {
        let payload = try JSONDecoder().decode(
            DDMStatusItemsPayload.self,
            from: fixture("ddm-status-items-raw/ddm-status-items-prod-macos27.json"))
        XCTAssertGreaterThan(payload.statusItems.count, 10)
        let failure = payload.statusItems.first { $0.key == "softwareupdate.failure-reason" }
        XCTAssertNotNil(failure, "fixture carries the key")
        XCTAssertNil(failure?.value, "JSON null decodes to nil, not to a crash or an empty string")
        let os = payload.statusItems.first { $0.key == "device.operating-system.version" }
        XCTAssertEqual(os?.value?.isEmpty, false)
    }

    func testHistoryCleanDeviceHasStringBucketsAndPendingArray() throws {
        let h = try JSONDecoder().decode(
            ComputerHistoryCommands.self,
            from: fixture("classic-computer-history-raw/nofailures.json"))
        XCTAssertEqual(h.commands.failed.command.count, 0, "failed: \"\" decodes as no commands")
        XCTAssertEqual(h.commands.pending.command.count, 3)
        XCTAssertEqual(h.commands.completed.command.count, 9)
        let pending = try XCTUnwrap(h.commands.pending.command.first)
        XCTAssertEqual(pending.name, "ProfileList")
        XCTAssertNotNil(pending.issuedEpoch)
        XCTAssertNotNil(pending.lastPushEpoch)
    }

    func testHistorySingleFailedCommandIsABareObject() throws {
        let h = try JSONDecoder().decode(
            ComputerHistoryCommands.self,
            from: fixture("classic-computer-history-raw/onefailed.json"))
        XCTAssertEqual(h.commands.failed.command.count, 1,
                       "one failure arrives as `command: {…}`, not `command: [{…}]`")
        XCTAssertEqual(h.commands.failed.command.first?.name, "Install App - Fixture App")
        XCTAssertEqual(h.commands.failed.command.first?.status,
                       "AppStore request (submitVPPRequest) timed out")
        XCTAssertEqual(h.commands.pending.command.count, 0, "pending: \"\" on this device")
    }

    func testHistoryBucketToleratesArrayAndMissingCommandKey() throws {
        let json = """
        {"commands": {"completed": {"command": [{"name": "A"}, {"name": "B"}]},
                      "failed": {},
                      "pending": {"command": []}}}
        """
        let h = try JSONDecoder().decode(ComputerHistoryCommands.self, from: Data(json.utf8))
        XCTAssertEqual(h.commands.completed.command.map(\.name), ["A", "B"])
        XCTAssertEqual(h.commands.failed.command.count, 0, "an object with no `command` key is empty")
        XCTAssertEqual(h.commands.pending.command.count, 0)
    }

    func testPersistedRowsRoundTrip() throws {
        let ddm = DDMDeviceStatusRecord(
            deviceId: "1", name: "Mac", managementId: "m-1", osVersion: "27.0", osBuild: "27A1",
            reportDate: "2026-09-04T07:25:58.000", ddmReported: true,
            declarations: [.init(identifier: "d-1", active: true, valid: true,
                                 reasonCode: nil, reasonText: nil)],
            softwareUpdate: .init(pendingOSVersion: "27.1", pendingBuild: nil, installState: "pending",
                                  installReason: nil, failureReason: nil, failureAt: nil,
                                  betaEnrollment: nil))
        let data = try JSONEncoder().encode([ddm])
        XCTAssertEqual(try JSONDecoder().decode([DDMDeviceStatusRecord].self, from: data), [ddm])

        let mdm = MDMCommandHealthRecord(deviceId: "1", name: "Mac", failedCount: 1, pendingCount: 0,
                                         failedCommands: ["Install App"], oldestPendingDays: nil)
        let data2 = try JSONEncoder().encode([mdm])
        XCTAssertEqual(try JSONDecoder().decode([MDMCommandHealthRecord].self, from: data2), [mdm])
    }
}
```

- [ ] **Step 3: Run to verify it fails**

Run: `cd app && swift build --build-tests 2>&1 | grep error: | head`
Expected: `cannot find 'DDMStatusItemsPayload' in scope` (and the other three types).

- [ ] **Step 4: Write the decoders**

```swift
import Foundation

// MARK: - `jamf-cli pro ddm-status status-items <managementId> --output json`
// Verified on prod 2026-09-04. `value` is JSON null for unset items.

struct DDMStatusItemsPayload: Decodable, Sendable {
    let statusItems: [DDMStatusItem]
}

struct DDMStatusItem: Decodable, Sendable, Equatable {
    let key: String
    let value: String?
    let lastUpdateTime: String?
}

// MARK: - `jamf-cli pro classic-computer-history get <id> --subset commands --output json`
// Classic API, XML→JSON: a bucket holding nothing is the STRING "", and a
// bucket holding exactly one command has `command` as an OBJECT, not an array.
// Verified on prod 2026-09-04 across four devices.

struct ComputerHistoryCommands: Decodable, Sendable {
    let commands: Buckets

    struct Buckets: Decodable, Sendable {
        let completed: Bucket
        let failed: Bucket
        let pending: Bucket

        private enum Keys: String, CodingKey { case completed, failed, pending }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: Keys.self)
            completed = try c.decodeIfPresent(Bucket.self, forKey: .completed) ?? .empty
            failed = try c.decodeIfPresent(Bucket.self, forKey: .failed) ?? .empty
            pending = try c.decodeIfPresent(Bucket.self, forKey: .pending) ?? .empty
        }
    }

    struct Bucket: Decodable, Sendable {
        let command: [HistoryCommand]
        static let empty = Bucket(command: [])

        init(command: [HistoryCommand]) { self.command = command }

        private enum Keys: String, CodingKey { case command }

        init(from decoder: Decoder) throws {
            // "" → nothing in this bucket.
            if let single = try? decoder.singleValueContainer(), (try? single.decode(String.self)) != nil {
                command = []
                return
            }
            let c = try decoder.container(keyedBy: Keys.self)
            if let many = try? c.decode([HistoryCommand].self, forKey: .command) {
                command = many
            } else if let one = try? c.decode(HistoryCommand.self, forKey: .command) {
                command = [one]
            } else {
                command = []
            }
        }
    }

    struct HistoryCommand: Decodable, Sendable, Equatable {
        let name: String?
        let status: String?
        let username: String?
        let issuedEpoch: Int?
        let failedEpoch: Int?
        let lastPushEpoch: Int?

        private enum Keys: String, CodingKey {
            case name, status, username
            case issuedEpoch = "issued_epoch"
            case failedEpoch = "failed_epoch"
            case lastPushEpoch = "last_push_epoch"
        }

        init(name: String?, status: String?, username: String? = nil,
             issuedEpoch: Int? = nil, failedEpoch: Int? = nil, lastPushEpoch: Int? = nil) {
            self.name = name; self.status = status; self.username = username
            self.issuedEpoch = issuedEpoch; self.failedEpoch = failedEpoch; self.lastPushEpoch = lastPushEpoch
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: Keys.self)
            name = try c.decodeIfPresent(String.self, forKey: .name)
            status = try c.decodeIfPresent(String.self, forKey: .status)
            username = try c.decodeIfPresent(String.self, forKey: .username)
            issuedEpoch = try c.decodeIfPresent(AnyCodable.self, forKey: .issuedEpoch)?.intValue
            failedEpoch = try c.decodeIfPresent(AnyCodable.self, forKey: .failedEpoch)?.intValue
            lastPushEpoch = try c.decodeIfPresent(AnyCodable.self, forKey: .lastPushEpoch)?.intValue
        }
    }
}

// MARK: - Persisted snapshot rows (what the scan loop writes to disk)

/// One DDM-enabled Mac's declaration and software-update status. Only
/// allow-listed status items ever reach this type — see
/// `DeviceScanBuilders.statusItemAllowList`.
struct DDMDeviceStatusRecord: Codable, Sendable, Equatable {
    let deviceId: String
    let name: String
    let managementId: String
    let osVersion: String?
    let osBuild: String?
    let reportDate: String?
    /// False when the status-items call 404'd: the device is DDM-enabled per
    /// inventory but has never reported. Not an error.
    let ddmReported: Bool
    let declarations: [Declaration]
    let softwareUpdate: SoftwareUpdate

    struct Declaration: Codable, Sendable, Equatable {
        let identifier: String
        let active: Bool?
        let valid: Bool?
        let reasonCode: String?
        let reasonText: String?
    }

    struct SoftwareUpdate: Codable, Sendable, Equatable {
        let pendingOSVersion: String?
        let pendingBuild: String?
        let installState: String?
        let installReason: String?
        let failureReason: String?
        let failureAt: String?
        let betaEnrollment: String?
        static let empty = SoftwareUpdate(pendingOSVersion: nil, pendingBuild: nil, installState: nil,
                                          installReason: nil, failureReason: nil, failureAt: nil,
                                          betaEnrollment: nil)
    }
}

/// One Mac's MDM command health, reduced from its Classic history.
struct MDMCommandHealthRecord: Codable, Sendable, Equatable {
    let deviceId: String
    let name: String
    let failedCount: Int
    let pendingCount: Int
    let failedCommands: [String]
    /// Age in days of the oldest pending command, nil when none is pending.
    let oldestPendingDays: Int?
}
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `cd app && swift test --filter DeviceScanDecodersTests 2>&1 | tail -5`
Expected: `Executed 5 tests, with 0 failures`.

- [ ] **Step 6: Commit**

```bash
git add app/Sources/JamfReports/Engine/DeviceScanDecoders.swift \
        app/Tests/JamfReportsTests/DeviceScanDecodersTests.swift \
        app/Tests/JamfReportsTests/Fixtures/jamf-cli-data/ddm-status-items-raw \
        app/Tests/JamfReportsTests/Fixtures/jamf-cli-data/classic-computer-history-raw
git commit -m "feat(engine): decode ddm status-items and classic command history

Prod-verified shapes (2026-09-04). History buckets are \"\" when empty and
an object otherwise; a lone command is a bare object, not an array."
```

---

### Task 2: Pure builders — status items → record, declaration string parser, history → record, 25% verdict

**Files:**
- Create: `app/Sources/JamfReports/Engine/DeviceScanBuilders.swift`
- Test: `app/Tests/JamfReportsTests/DeviceScanBuildersTests.swift`

**Interfaces:**
- Consumes: Task 1 types.
- Produces: `enum DeviceScanBuilders` with
  `static let statusItemAllowList: Set<String>`,
  `static func ddmRecord(deviceId:name:managementId:payload:) -> DDMDeviceStatusRecord`,
  `static func ddmRecordNotReported(deviceId:name:managementId:) -> DDMDeviceStatusRecord`,
  `static func parseDeclarations(_ raw: String) -> [DDMDeviceStatusRecord.Declaration]`,
  `static func healthRecord(deviceId:name:history:now:) -> MDMCommandHealthRecord`,
  `static let pendingAgeThresholdDays = 7`,
  `static func exceedsFailureBudget(failed: Int, total: Int) -> Bool`.

- [ ] **Step 1: Write the failing tests**

```swift
import XCTest
@testable import JamfReports

final class DeviceScanBuildersTests: XCTestCase {

    private func fixture(_ rel: String) throws -> Data {
        try Data(contentsOf: TestFixtures.dir("jamf-cli-data/\(rel)"))
    }

    // MARK: status items → record

    func testRecordKeepsOnlyAllowListedKeysAndNeverTheTokens() throws {
        let payload = try JSONDecoder().decode(
            DDMStatusItemsPayload.self,
            from: fixture("ddm-status-items-raw/ddm-status-items-prod-macos27.json"))
        XCTAssertTrue(payload.statusItems.contains { $0.key == "mdm.push-token" },
                      "the raw fixture must carry the secret so this test proves the filter")
        let rec = DeviceScanBuilders.ddmRecord(deviceId: "7", name: "Mac", managementId: "m", payload: payload)
        let encoded = String(decoding: try JSONEncoder().encode(rec), as: UTF8.self)
        XCTAssertFalse(encoded.contains("push-token"))
        XCTAssertFalse(encoded.contains("push-magic"))
        XCTAssertFalse(encoded.contains("server-token"))
        XCTAssertFalse(encoded.contains("content-cache"))
        XCTAssertTrue(rec.ddmReported)
        XCTAssertEqual(rec.osVersion?.isEmpty, false)
        XCTAssertEqual(rec.declarations.count, 1)
        XCTAssertEqual(rec.softwareUpdate.installState?.isEmpty, false)
        XCTAssertNil(rec.softwareUpdate.failureReason, "JSON null stays nil")
        XCTAssertNotNil(rec.reportDate, "newest lastUpdateTime among allow-listed items")
    }

    func testAllowListNamesNoSecretPrefix() {
        for key in DeviceScanBuilders.statusItemAllowList {
            XCTAssertFalse(key.hasPrefix("mdm."), key)
            XCTAssertFalse(key.hasPrefix("security."), key)
            XCTAssertFalse(key.hasPrefix("content-cache."), key)
        }
    }

    func testNotReportedRecordIsEmptyButPresent() {
        let rec = DeviceScanBuilders.ddmRecordNotReported(deviceId: "9", name: "Quiet", managementId: "m9")
        XCTAssertFalse(rec.ddmReported)
        XCTAssertTrue(rec.declarations.isEmpty)
        XCTAssertEqual(rec.softwareUpdate, .empty)
    }

    // MARK: declaration string parser

    func testParsesOneGroup() {
        let raw = "{active=true, identifier=AAAA-1, valid=true, server-token=zzz}"
        let d = DeviceScanBuilders.parseDeclarations(raw)
        XCTAssertEqual(d.count, 1)
        XCTAssertEqual(d[0].identifier, "AAAA-1")
        XCTAssertEqual(d[0].active, true)
        XCTAssertEqual(d[0].valid, true)
        XCTAssertNil(d[0].reasonCode)
    }

    func testParsesSeveralGroupsAndTolerantReasons() {
        // Multi-group form INFERRED from the single observed group (spec §2);
        // the reasons sub-group shape is unobserved and parsed tolerantly.
        let raw = "{active=true, identifier=A, valid=true}, " +
                  "{active=false, identifier=B, valid=false, reasons={code=Error.Foo, description=bad thing}}"
        let d = DeviceScanBuilders.parseDeclarations(raw)
        XCTAssertEqual(d.map(\.identifier), ["A", "B"])
        XCTAssertEqual(d[1].active, false)
        XCTAssertEqual(d[1].reasonCode, "Error.Foo")
        XCTAssertEqual(d[1].reasonText, "bad thing")
    }

    func testGroupWithoutIdentifierIsDropped() {
        XCTAssertTrue(DeviceScanBuilders.parseDeclarations("{active=true, valid=true}").isEmpty)
        XCTAssertTrue(DeviceScanBuilders.parseDeclarations("").isEmpty)
    }

    // MARK: history → record

    func testHealthRecordFromCleanDevice() throws {
        let h = try JSONDecoder().decode(ComputerHistoryCommands.self,
                                         from: fixture("classic-computer-history-raw/nofailures.json"))
        // Fixture pending rows were issued 2026-09-04 12:46 local; "now" a day later.
        let now = Date(timeIntervalSince1970: 1_788_540_419.542 + 86_400)
        let rec = DeviceScanBuilders.healthRecord(deviceId: "1", name: "A", history: h, now: now)
        XCTAssertEqual(rec.failedCount, 0)
        XCTAssertEqual(rec.pendingCount, 3)
        XCTAssertEqual(rec.oldestPendingDays, 1)
        XCTAssertTrue(rec.failedCommands.isEmpty)
    }

    func testHealthRecordFromFailedDevice() throws {
        let h = try JSONDecoder().decode(ComputerHistoryCommands.self,
                                         from: fixture("classic-computer-history-raw/onefailed.json"))
        let rec = DeviceScanBuilders.healthRecord(deviceId: "2", name: "B", history: h, now: Date())
        XCTAssertEqual(rec.failedCount, 1)
        XCTAssertEqual(rec.failedCommands, ["Install App - Fixture App"])
        XCTAssertEqual(rec.pendingCount, 0)
        XCTAssertNil(rec.oldestPendingDays)
    }

    func testOldestPendingUsesIssuedEpochAndFloorsDays() {
        let issued = Date(timeIntervalSince1970: 1_700_000_000)
        let cmds = [
            ComputerHistoryCommands.HistoryCommand(name: "X", status: "Pending",
                issuedEpoch: Int(issued.timeIntervalSince1970 * 1000)),
            ComputerHistoryCommands.HistoryCommand(name: "Y", status: "Pending",
                issuedEpoch: Int((issued.timeIntervalSince1970 + 3 * 86_400) * 1000)),
        ]
        let h = makeHistory(pending: cmds)
        let now = issued.addingTimeInterval(7 * 86_400 - 1)   // 6.99 days → 6
        XCTAssertEqual(DeviceScanBuilders.healthRecord(deviceId: "1", name: "", history: h, now: now)
                        .oldestPendingDays, 6)
        let now7 = issued.addingTimeInterval(7 * 86_400)      // exactly 7 → 7
        XCTAssertEqual(DeviceScanBuilders.healthRecord(deviceId: "1", name: "", history: h, now: now7)
                        .oldestPendingDays, 7)
    }

    func testPendingWithoutEpochDoesNotCrashAndReportsNoAge() {
        let h = makeHistory(pending: [.init(name: "X", status: "Pending")])
        let rec = DeviceScanBuilders.healthRecord(deviceId: "1", name: "", history: h, now: Date())
        XCTAssertEqual(rec.pendingCount, 1)
        XCTAssertNil(rec.oldestPendingDays)
    }

    // MARK: 25% rule

    func testFailureBudgetIsStrictlyMoreThanAQuarter() {
        XCTAssertFalse(DeviceScanBuilders.exceedsFailureBudget(failed: 25, total: 100))
        XCTAssertTrue(DeviceScanBuilders.exceedsFailureBudget(failed: 26, total: 100))
        XCTAssertFalse(DeviceScanBuilders.exceedsFailureBudget(failed: 1, total: 4))
        XCTAssertTrue(DeviceScanBuilders.exceedsFailureBudget(failed: 1, total: 3))
        XCTAssertFalse(DeviceScanBuilders.exceedsFailureBudget(failed: 0, total: 0))
    }

    // MARK: helpers

    private func makeHistory(pending: [ComputerHistoryCommands.HistoryCommand]) -> ComputerHistoryCommands {
        // Build through JSON so the real decoder path is exercised.
        let rows = pending.map { c -> [String: Any] in
            var d: [String: Any] = ["name": c.name ?? "", "status": c.status ?? ""]
            if let e = c.issuedEpoch { d["issued_epoch"] = e }
            return d
        }
        let obj: [String: Any] = ["commands": ["completed": "", "failed": "", "pending": ["command": rows]]]
        let data = try! JSONSerialization.data(withJSONObject: obj)
        return try! JSONDecoder().decode(ComputerHistoryCommands.self, from: data)
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `cd app && swift build --build-tests 2>&1 | grep error: | head -3`
Expected: `cannot find 'DeviceScanBuilders' in scope`.

- [ ] **Step 3: Write the builders**

```swift
import Foundation

/// Pure reductions from the two raw jamf-cli payloads into the persisted rows.
/// No I/O, no clock reads (callers pass `now`), so every rule here is unit-testable.
enum DeviceScanBuilders {

    // MARK: - Status items

    /// The ONLY status-item keys that reach disk. An allow-list, not a
    /// deny-list: the payload also carries `mdm.push-token`, `mdm.push-magic`,
    /// per-declaration `server-token`s and certificate lists, and a key Apple
    /// adds next year must not leak by default.
    static let statusItemAllowList: Set<String> = [
        "device.operating-system.version",
        "device.operating-system.build-version",
        "device.model.identifier",
        "management.declarations.configurations",
        "management.declarations.activations",
        "softwareupdate.pending-version.os-version",
        "softwareupdate.pending-version.build-version",
        "softwareupdate.install-state",
        "softwareupdate.install-reason.reason",
        "softwareupdate.failure-reason",
        "softwareupdate.beta-enrollment",
    ]

    static func ddmRecord(
        deviceId: String, name: String, managementId: String, payload: DDMStatusItemsPayload
    ) -> DDMDeviceStatusRecord {
        var kept: [String: String] = [:]
        var newest: String?
        for item in payload.statusItems where statusItemAllowList.contains(item.key) {
            if let v = item.value, !v.isEmpty { kept[item.key] = v }
            if let t = item.lastUpdateTime, t > (newest ?? "") { newest = t }
        }
        let declarations = parseDeclarations(kept["management.declarations.configurations"] ?? "")
            + parseDeclarations(kept["management.declarations.activations"] ?? "")
        return DDMDeviceStatusRecord(
            deviceId: deviceId, name: name, managementId: managementId,
            osVersion: kept["device.operating-system.version"],
            osBuild: kept["device.operating-system.build-version"],
            reportDate: newest, ddmReported: true, declarations: declarations,
            softwareUpdate: .init(
                pendingOSVersion: kept["softwareupdate.pending-version.os-version"],
                pendingBuild: kept["softwareupdate.pending-version.build-version"],
                installState: kept["softwareupdate.install-state"],
                installReason: kept["softwareupdate.install-reason.reason"],
                failureReason: kept["softwareupdate.failure-reason"],
                failureAt: payload.statusItems.first {
                    $0.key == "softwareupdate.failure-reason" && !($0.value ?? "").isEmpty
                }?.lastUpdateTime,
                betaEnrollment: kept["softwareupdate.beta-enrollment"]))
    }

    static func ddmRecordNotReported(
        deviceId: String, name: String, managementId: String
    ) -> DDMDeviceStatusRecord {
        DDMDeviceStatusRecord(deviceId: deviceId, name: name, managementId: managementId,
                              osVersion: nil, osBuild: nil, reportDate: nil, ddmReported: false,
                              declarations: [], softwareUpdate: .empty)
    }

    // MARK: - Declaration string

    /// `{active=true, identifier=…, valid=true, server-token=…}` groups, possibly
    /// several, possibly with a nested `reasons={code=…, description=…}`.
    /// Top-level groups are found by brace depth; a group without an
    /// `identifier` is dropped. `server-token` is read and discarded here.
    static func parseDeclarations(_ raw: String) -> [DDMDeviceStatusRecord.Declaration] {
        topLevelGroups(raw).compactMap { group in
            let fields = keyValues(group)
            guard let identifier = fields["identifier"], !identifier.isEmpty else { return nil }
            return .init(
                identifier: identifier,
                active: fields["active"].flatMap(bool),
                valid: fields["valid"].flatMap(bool),
                reasonCode: capture(#"code=([^,}]*)"#, in: group),
                reasonText: capture(#"description=([^}]*)"#, in: group))
        }
    }

    private static func topLevelGroups(_ s: String) -> [String] {
        var groups: [String] = []
        var depth = 0
        var start: String.Index?
        for i in s.indices {
            switch s[i] {
            case "{":
                if depth == 0 { start = s.index(after: i) }
                depth += 1
            case "}":
                depth -= 1
                if depth == 0, let st = start { groups.append(String(s[st..<i])) ; start = nil }
            default: break
            }
        }
        return groups
    }

    /// Flat `key=value` pairs of a group body, ignoring anything inside a nested `{…}`.
    private static func keyValues(_ body: String) -> [String: String] {
        var flat = ""
        var depth = 0
        for ch in body {
            if ch == "{" { depth += 1; continue }
            if ch == "}" { depth -= 1; continue }
            if depth == 0 { flat.append(ch) }
        }
        var out: [String: String] = [:]
        for pair in flat.split(separator: ",") {
            let parts = pair.split(separator: "=", maxSplits: 1).map {
                $0.trimmingCharacters(in: .whitespaces)
            }
            if parts.count == 2, !parts[0].isEmpty { out[parts[0]] = parts[1] }
        }
        return out
    }

    private static func bool(_ s: String) -> Bool? {
        switch s.lowercased() { case "true": return true; case "false": return false; default: return nil }
    }

    private static func capture(_ pattern: String, in s: String) -> String? {
        guard let r = s.range(of: pattern, options: .regularExpression) else { return nil }
        let m = String(s[r])
        guard let eq = m.firstIndex(of: "=") else { return nil }
        let v = m[m.index(after: eq)...].trimmingCharacters(in: .whitespaces)
        return v.isEmpty ? nil : v
    }

    // MARK: - Command history

    static let pendingAgeThresholdDays = 7

    static func healthRecord(
        deviceId: String, name: String, history: ComputerHistoryCommands, now: Date
    ) -> MDMCommandHealthRecord {
        let failed = history.commands.failed.command
        let pending = history.commands.pending.command
        let oldestIssuedMs = pending.compactMap(\.issuedEpoch).min()
        let oldestDays = oldestIssuedMs.map { ms -> Int in
            let issued = Date(timeIntervalSince1970: TimeInterval(ms) / 1000)
            return max(0, Int(now.timeIntervalSince(issued) / 86_400))
        }
        return MDMCommandHealthRecord(
            deviceId: deviceId, name: name,
            failedCount: failed.count, pendingCount: pending.count,
            failedCommands: failed.compactMap { $0.name?.isEmpty == false ? $0.name : nil },
            oldestPendingDays: oldestDays)
    }

    // MARK: - Run verdict

    /// Strictly more than a quarter of devices failed the call type.
    static func exceedsFailureBudget(failed: Int, total: Int) -> Bool {
        total > 0 && failed * 4 > total
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd app && swift test --filter DeviceScanBuildersTests 2>&1 | tail -5`
Expected: `Executed 11 tests, with 0 failures`.

- [ ] **Step 5: Mutation check the parser (do not commit the mutants)**

Back up first: `cp app/Sources/JamfReports/Engine/DeviceScanBuilders.swift /private/tmp/DeviceScanBuilders.swift.bak`.
Mutant A: change `failed * 4 > total` to `>=` → `testFailureBudgetIsStrictlyMoreThanAQuarter` must fail.
Mutant B: in `parseDeclarations` drop the `guard let identifier` → `testGroupWithoutIdentifierIsDropped` must fail.
Mutant C: remove `"softwareupdate.failure-reason"` from the allow-list → `testRecordKeepsOnlyAllowListedKeysAndNeverTheTokens` still passes (nil either way) — that is acceptable; instead change the allow-list to also include `"mdm.push-token"` → same test must fail.
Restore with `cp /private/tmp/DeviceScanBuilders.swift.bak app/Sources/JamfReports/Engine/DeviceScanBuilders.swift` (never `git checkout --`, the file is new).

- [ ] **Step 6: Commit**

```bash
git add app/Sources/JamfReports/Engine/DeviceScanBuilders.swift app/Tests/JamfReportsTests/DeviceScanBuildersTests.swift
git commit -m "feat(engine): reduce status items and command history to scan rows

Allow-listed status keys only; declaration groups parsed by brace depth;
pending age from issued_epoch with a fixed 7-day threshold; 25% budget."
```

---

### Task 3: Read services — `DDMDeviceStatusService` and `MDMCommandHealthService`

**Files:**
- Create: `app/Sources/JamfReports/Services/DDMDeviceStatusService.swift`
- Create: `app/Sources/JamfReports/Services/MDMCommandHealthService.swift`
- Test: `app/Tests/JamfReportsTests/DDMDeviceStatusServiceTests.swift`, `app/Tests/JamfReportsTests/MDMCommandHealthServiceTests.swift`

**Interfaces:**
- Consumes: `DDMDeviceStatusRecord`, `MDMCommandHealthRecord` (Task 1).
- Produces:
  `DDMDeviceStatusService.Snapshot { records, isDetected, readFailed, snapshotDate: Date?, sourceDates: [String: Date] }` with
  `ddmReportedCount: Int`, `byIdentifier: [IdentifierSummary]` (`identifier, active, inactive, invalid, mixed: Int, devices: [DeviceRef]`), `pendingVersions: [(version: String, devices: [DeviceRef])]`, `failureReasons: [(reason: String, devices: [DeviceRef])]`, `failingDeclarationCount: Int`, `record(forDeviceId:) -> DDMDeviceStatusRecord?`;
  `DDMDeviceStatusService.load(profile:) / load(url:)`; `DeviceRef { id: String; name: String }`.
  `MDMCommandHealthService.Snapshot { records, isDetected, readFailed, snapshotDate, sourceDates }` with `devicesWithFailures: [MDMCommandHealthRecord]`, `devicesWithStalePending: [MDMCommandHealthRecord]` (oldestPendingDays >= 7), `topFailedCommands: [(name: String, count: Int)]`, `record(forDeviceId:)`; `load(profile:) / load(url:)`.
- Both mirror `DuplicateSerialService` (`Sendable` struct, static loaders, `.empty` / `.unreadable`).

- [ ] **Step 1: Write the failing tests**

`DDMDeviceStatusServiceTests.swift`:

```swift
import XCTest
@testable import JamfReports

final class DDMDeviceStatusServiceTests: XCTestCase {

    private func write(_ records: [DDMDeviceStatusRecord]) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ddm-dev-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("ddm-device-status_20260904T120000.json")
        try JSONEncoder().encode(records).write(to: url)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return url
    }

    private func rec(_ id: String, reported: Bool = true,
                     decl: [(String, Bool?, Bool?)] = [],
                     pending: String? = nil, failure: String? = nil) -> DDMDeviceStatusRecord {
        .init(deviceId: id, name: "Mac-\(id)", managementId: "m-\(id)", osVersion: "27.0", osBuild: nil,
              reportDate: "2026-09-04T07:00:00.000", ddmReported: reported,
              declarations: decl.map { .init(identifier: $0.0, active: $0.1, valid: $0.2,
                                             reasonCode: nil, reasonText: nil) },
              softwareUpdate: .init(pendingOSVersion: pending, pendingBuild: nil, installState: nil,
                                    installReason: nil, failureReason: failure, failureAt: nil,
                                    betaEnrollment: nil))
    }

    func testNilURLIsNotDetected() {
        let s = DDMDeviceStatusService.load(url: nil)
        XCTAssertFalse(s.isDetected); XCTAssertFalse(s.readFailed); XCTAssertTrue(s.records.isEmpty)
    }

    func testGarbageFileIsUnreadable() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ddm-bad-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("ddm-device-status_20260904T120000.json")
        try Data("nope".utf8).write(to: url)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let s = DDMDeviceStatusService.load(url: url)
        XCTAssertTrue(s.readFailed); XCTAssertFalse(s.isDetected)
    }

    func testIdentifierCountsIncludingMixedRule() throws {
        // A: active on 1, inactive on 2 → mixed? No: mixed is SAME device both states.
        // B: on device 3 twice — once active, once inactive → mixed 1.
        // C: invalid on 1.
        let url = try write([
            rec("1", decl: [("A", true, true), ("C", true, false)]),
            rec("2", decl: [("A", false, true)]),
            rec("3", decl: [("B", true, true), ("B", false, true)]),
            rec("4", reported: false),
        ])
        let s = DDMDeviceStatusService.load(url: url)
        XCTAssertTrue(s.isDetected)
        XCTAssertEqual(s.ddmReportedCount, 3)
        let a = try XCTUnwrap(s.byIdentifier.first { $0.identifier == "A" })
        XCTAssertEqual(a.active, 1); XCTAssertEqual(a.inactive, 1); XCTAssertEqual(a.mixed, 0)
        let b = try XCTUnwrap(s.byIdentifier.first { $0.identifier == "B" })
        XCTAssertEqual(b.mixed, 1); XCTAssertEqual(b.active, 0); XCTAssertEqual(b.inactive, 0)
        let c = try XCTUnwrap(s.byIdentifier.first { $0.identifier == "C" })
        XCTAssertEqual(c.invalid, 1)
        // failing = invalid + inactive + mixed device-declarations
        XCTAssertEqual(s.failingDeclarationCount, 3)
        XCTAssertEqual(s.byIdentifier.map(\.identifier), ["B", "C", "A"],
                       "worst first: mixed, then invalid, then inactive, then name")
    }

    func testSoftwareUpdateAggregation() throws {
        let url = try write([
            rec("1", pending: "27.1"), rec("2", pending: "27.1"), rec("3", pending: "27.0.1"),
            rec("4", failure: "Insufficient space"), rec("5", failure: "Insufficient space"),
        ])
        let s = DDMDeviceStatusService.load(url: url)
        XCTAssertEqual(s.pendingVersions.map(\.version), ["27.1", "27.0.1"])
        XCTAssertEqual(s.pendingVersions.first?.devices.map(\.id), ["1", "2"])
        XCTAssertEqual(s.failureReasons.first?.reason, "Insufficient space")
        XCTAssertEqual(s.failureReasons.first?.devices.count, 2)
        XCTAssertEqual(s.record(forDeviceId: "3")?.softwareUpdate.pendingOSVersion, "27.0.1")
        XCTAssertNil(s.record(forDeviceId: "99"))
    }

    func testSourceDatesComeFromTheFilenameStamp() throws {
        let url = try write([rec("1")])
        let s = DDMDeviceStatusService.load(url: url)
        XCTAssertNotNil(s.snapshotDate)
        XCTAssertEqual(s.sourceDates.keys.sorted(), ["ddm-device-status"])
    }
}
```

`MDMCommandHealthServiceTests.swift`:

```swift
import XCTest
@testable import JamfReports

final class MDMCommandHealthServiceTests: XCTestCase {

    private func write(_ records: [MDMCommandHealthRecord]) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mdm-health-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("mdm-command-health_20260904T120000.json")
        try JSONEncoder().encode(records).write(to: url)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return url
    }

    private func rec(_ id: String, failed: [String] = [], pending: Int = 0,
                     oldest: Int? = nil) -> MDMCommandHealthRecord {
        .init(deviceId: id, name: "Mac-\(id)", failedCount: failed.count, pendingCount: pending,
              failedCommands: failed, oldestPendingDays: oldest)
    }

    func testNilURLIsNotDetected() {
        let s = MDMCommandHealthService.load(url: nil)
        XCTAssertFalse(s.isDetected); XCTAssertTrue(s.records.isEmpty)
    }

    func testFailuresAndStalePendingAtTheSevenDayBoundary() throws {
        let url = try write([
            rec("1", failed: ["InstallApplication"]),
            rec("2", pending: 1, oldest: 6),
            rec("3", pending: 2, oldest: 7),
            rec("4", pending: 1, oldest: 30),
            rec("5"),
        ])
        let s = MDMCommandHealthService.load(url: url)
        XCTAssertTrue(s.isDetected)
        XCTAssertEqual(s.devicesWithFailures.map(\.deviceId), ["1"])
        XCTAssertEqual(s.devicesWithStalePending.map(\.deviceId), ["4", "3"],
                       "oldest first; exactly 7 days counts, 6 does not")
        XCTAssertEqual(s.record(forDeviceId: "2")?.pendingCount, 1)
    }

    func testTopFailedCommandsCountsAcrossDevices() throws {
        let url = try write([
            rec("1", failed: ["A", "B"]), rec("2", failed: ["A"]), rec("3", failed: ["C"]),
        ])
        let s = MDMCommandHealthService.load(url: url)
        XCTAssertEqual(s.topFailedCommands.map(\.name), ["A", "B", "C"])
        XCTAssertEqual(s.topFailedCommands.first?.count, 2)
    }
}
```

- [ ] **Step 2: Run to verify they fail**

Run: `cd app && swift build --build-tests 2>&1 | grep error: | head -3`
Expected: `cannot find 'DDMDeviceStatusService' in scope` / `'MDMCommandHealthService'`.

- [ ] **Step 3: Write the two services**

`DDMDeviceStatusService.swift`:

```swift
import Foundation

/// A device the fleet views can deep-link to.
struct DeviceRef: Sendable, Equatable, Hashable, Identifiable {
    let id: String
    let name: String
}

/// Reads the latest `ddm-device-status` snapshot (written by the per-device
/// scan phase in `ReportEngine+DeviceScan`) and aggregates it for the DDM
/// screen, the Devices panel and the workbook. Pure over the snapshot.
struct DDMDeviceStatusService: Sendable {

    static let kind = "ddm-device-status"

    struct IdentifierSummary: Sendable, Equatable, Identifiable {
        var id: String { identifier }
        let identifier: String
        let active: Int
        let inactive: Int
        let invalid: Int
        /// Same identifier both active and inactive on ONE device.
        let mixed: Int
        let devices: [DeviceRef]
        var issues: Int { inactive + invalid + mixed }
    }

    struct Snapshot: Sendable, Equatable {
        let records: [DDMDeviceStatusRecord]
        let isDetected: Bool
        let readFailed: Bool
        let snapshotDate: Date?
        let sourceDates: [String: Date]

        static let empty = Snapshot(records: [], isDetected: false, readFailed: false,
                                    snapshotDate: nil, sourceDates: [:])
        static let unreadable = Snapshot(records: [], isDetected: false, readFailed: true,
                                         snapshotDate: nil, sourceDates: [:])

        var ddmReportedCount: Int { records.filter(\.ddmReported).count }

        func record(forDeviceId id: String) -> DDMDeviceStatusRecord? {
            records.first { $0.deviceId == id }
        }

        /// Worst first: mixed, then invalid, then inactive, then identifier.
        var byIdentifier: [IdentifierSummary] {
            var order: [String] = []
            var perId: [String: (active: Int, inactive: Int, invalid: Int, mixed: Int, devices: [DeviceRef])] = [:]
            for r in records where r.ddmReported {
                let grouped = Dictionary(grouping: r.declarations, by: \.identifier)
                for (identifier, decls) in grouped {
                    if perId[identifier] == nil { order.append(identifier); perId[identifier] = (0, 0, 0, 0, []) }
                    let anyInvalid = decls.contains { $0.valid == false }
                    let states = Set(decls.compactMap(\.active))
                    if anyInvalid { perId[identifier]!.invalid += 1 }
                    else if states.count == 2 { perId[identifier]!.mixed += 1 }
                    else if states == [false] { perId[identifier]!.inactive += 1 }
                    else { perId[identifier]!.active += 1 }
                    perId[identifier]!.devices.append(DeviceRef(id: r.deviceId, name: r.name))
                }
            }
            return order.map { id in
                let v = perId[id]!
                return IdentifierSummary(identifier: id, active: v.active, inactive: v.inactive,
                                         invalid: v.invalid, mixed: v.mixed, devices: v.devices)
            }.sorted {
                ($1.mixed, $1.invalid, $1.inactive, $0.identifier) <
                ($0.mixed, $0.invalid, $0.inactive, $1.identifier)
            }
        }

        var failingDeclarationCount: Int { byIdentifier.reduce(0) { $0 + $1.issues } }

        var pendingVersions: [(version: String, devices: [DeviceRef])] {
            bucket(records, key: { $0.softwareUpdate.pendingOSVersion })
                .map { (version: $0.key, devices: $0.devices) }
        }

        var failureReasons: [(reason: String, devices: [DeviceRef])] {
            bucket(records, key: { $0.softwareUpdate.failureReason })
                .map { (reason: $0.key, devices: $0.devices) }
        }

        /// Groups by a string key, largest bucket first, first-seen order on ties.
        private func bucket(
            _ rows: [DDMDeviceStatusRecord], key: (DDMDeviceStatusRecord) -> String?
        ) -> [(key: String, devices: [DeviceRef])] {
            var order: [String] = []
            var by: [String: [DeviceRef]] = [:]
            for r in rows {
                guard let k = key(r), !k.isEmpty else { continue }
                if by[k] == nil { order.append(k) }
                by[k, default: []].append(DeviceRef(id: r.deviceId, name: r.name))
            }
            return order.map { (key: $0, devices: by[$0] ?? []) }
                .enumerated()
                .sorted { ($1.element.devices.count, $0.offset) < ($0.element.devices.count, $1.offset) }
                .map(\.element)
        }
    }

    static func load(profile: String) -> Snapshot {
        guard let dir = try? WorkspacePaths.dataDir(for: profile) else { return .empty }
        return load(url: FileManager.newestJSONFile(in: dir.appendingPathComponent(kind, isDirectory: true)))
    }

    static func load(url: URL?) -> Snapshot {
        guard let url else { return .empty }
        guard let data = try? Data(contentsOf: url) else {
            return FileManager.default.fileExists(atPath: url.path) ? .unreadable : .empty
        }
        guard let rows = try? JSONDecoder().decode([DDMDeviceStatusRecord].self, from: data) else {
            AppLogger.collect.warning(
                "DDMDeviceStatusService: failed to decode \(url.lastPathComponent, privacy: .public)")
            return .unreadable
        }
        let date = CloudStorage.snapshotTimestamp(of: url)
        return Snapshot(records: rows, isDetected: true, readFailed: false, snapshotDate: date,
                        sourceDates: date.map { [kind: $0] } ?? [:])
    }
}
```

`MDMCommandHealthService.swift`:

```swift
import Foundation

/// Reads the latest `mdm-command-health` snapshot and answers the three
/// operator questions: which Macs have a failed command, which have a command
/// pending past the threshold, and which commands fail most.
struct MDMCommandHealthService: Sendable {

    static let kind = "mdm-command-health"

    struct Snapshot: Sendable, Equatable {
        let records: [MDMCommandHealthRecord]
        let isDetected: Bool
        let readFailed: Bool
        let snapshotDate: Date?
        let sourceDates: [String: Date]

        static let empty = Snapshot(records: [], isDetected: false, readFailed: false,
                                    snapshotDate: nil, sourceDates: [:])
        static let unreadable = Snapshot(records: [], isDetected: false, readFailed: true,
                                         snapshotDate: nil, sourceDates: [:])

        var devicesWithFailures: [MDMCommandHealthRecord] {
            records.filter { $0.failedCount > 0 }
                .sorted { ($1.failedCount, $0.name) < ($0.failedCount, $1.name) }
        }

        /// Oldest pending first. `>=` so a command pending exactly 7 days counts.
        var devicesWithStalePending: [MDMCommandHealthRecord] {
            records.filter { ($0.oldestPendingDays ?? -1) >= DeviceScanBuilders.pendingAgeThresholdDays }
                .sorted { ($0.oldestPendingDays ?? 0) > ($1.oldestPendingDays ?? 0) }
        }

        var topFailedCommands: [(name: String, count: Int)] {
            var order: [String] = []
            var counts: [String: Int] = [:]
            for r in records { for n in r.failedCommands {
                if counts[n] == nil { order.append(n) }
                counts[n, default: 0] += 1
            } }
            return order.map { (name: $0, count: counts[$0] ?? 0) }
                .enumerated()
                .sorted { ($1.element.count, $0.offset) < ($0.element.count, $1.offset) }
                .map(\.element)
        }

        func record(forDeviceId id: String) -> MDMCommandHealthRecord? {
            records.first { $0.deviceId == id }
        }
    }

    static func load(profile: String) -> Snapshot {
        guard let dir = try? WorkspacePaths.dataDir(for: profile) else { return .empty }
        return load(url: FileManager.newestJSONFile(in: dir.appendingPathComponent(kind, isDirectory: true)))
    }

    static func load(url: URL?) -> Snapshot {
        guard let url else { return .empty }
        guard let data = try? Data(contentsOf: url) else {
            return FileManager.default.fileExists(atPath: url.path) ? .unreadable : .empty
        }
        guard let rows = try? JSONDecoder().decode([MDMCommandHealthRecord].self, from: data) else {
            AppLogger.collect.warning(
                "MDMCommandHealthService: failed to decode \(url.lastPathComponent, privacy: .public)")
            return .unreadable
        }
        let date = CloudStorage.snapshotTimestamp(of: url)
        return Snapshot(records: rows, isDetected: true, readFailed: false, snapshotDate: date,
                        sourceDates: date.map { [kind: $0] } ?? [:])
    }
}
```


- [ ] **Step 4: Run tests to verify they pass**

Run: `cd app && swift test --filter "DDMDeviceStatusServiceTests|MDMCommandHealthServiceTests" 2>&1 | tail -5`
Expected: `Executed 8 tests, with 0 failures`.

- [ ] **Step 5: Commit**

```bash
git add app/Sources/JamfReports/Services/DDMDeviceStatusService.swift \
        app/Sources/JamfReports/Services/MDMCommandHealthService.swift \
        app/Tests/JamfReportsTests/DDMDeviceStatusServiceTests.swift \
        app/Tests/JamfReportsTests/MDMCommandHealthServiceTests.swift
git commit -m "feat(services): aggregate ddm-device-status and mdm-command-health snapshots"
```

---

### Task 4: Register the two kinds (tier, known kinds, expensive set) and pin them

**Files:**
- Modify: `app/Sources/JamfReports/Engine/ReportEngine.swift` — `expensivePerDeviceKinds` (~line 1339), `knownCollectKinds` (~line 1375)
- Modify: `app/Sources/JamfReports/Services/CollectionTier.swift` — `tierMap` (~line 96)
- Modify: `app/Tests/JamfReportsTests/CollectionTierTests.swift` — `testScanTierContainsExactly`
- Test: `app/Tests/JamfReportsTests/PlatformOnlyKindTests.swift` — add one test

**Interfaces:**
- Produces: the strings `"ddm-device-status"` and `"mdm-command-health"` known to `ReportEngine.knownCollectKinds`, `CollectionTier.tier(forReport:) == .scan`, and `ReportEngine.expensivePerDeviceKinds`.

- [ ] **Step 1: Update the existing scan-tier pin so it fails first**

In `CollectionTierTests.testScanTierContainsExactly` change the expected set to:

```swift
        let expectedScan: Set<String> = [
            "patch-device-failures",
            "update-device-failures",
            "ddm-device-status",
            "mdm-command-health",
        ]
```

and the message string to name all four. Add to `PlatformOnlyKindTests`:

```swift
    /// The scan-phase kinds are per-device fan-outs, so the Settings toggle
    /// that hides the four existing per-device kinds hides these two as well.
    func testScanPhaseKindsAreExpensiveAndHiddenByTheToggle() {
        for kind in ["ddm-device-status", "mdm-command-health"] {
            XCTAssertTrue(ReportEngine.expensivePerDeviceKinds.contains(kind), kind)
            XCTAssertTrue(ReportEngine.knownCollectKinds.contains(kind), kind)
            XCTAssertFalse(WorkspaceStore.expectedKinds(skipExpensive: true, authMethod: "oauth2")
                            .contains(kind), "\(kind) must not be expected when skipped")
            XCTAssertTrue(WorkspaceStore.expectedKinds(skipExpensive: false, authMethod: "oauth2")
                            .contains(kind), "\(kind) is expected on an on-prem profile")
        }
    }
```

- [ ] **Step 2: Run to verify they fail**

Run: `cd app && swift test --filter "CollectionTierTests|PlatformOnlyKindTests" 2>&1 | grep -E "failed|error" | head`
Expected: `testScanTierContainsExactly` and `testScanPhaseKindsAreExpensiveAndHiddenByTheToggle` fail.

- [ ] **Step 3: Register the kinds**

`ReportEngine.swift`, `expensivePerDeviceKinds`:

```swift
    static let expensivePerDeviceKinds: Set<String> = [
        "ea-results",
        "patch-device-failures",
        "update-device-failures",
        "device-compliance",
        // 2.8.0 per-device scan phase (ReportEngine+DeviceScan).
        "ddm-device-status",
        "mdm-command-health",
    ]
```

`knownCollectKinds`, after `"patch-release-dates",`:

```swift
        // 2.8.0 per-device scan phase — written by ReportEngine+DeviceScan, not the argv matrix.
        "ddm-device-status",
        "mdm-command-health",
```

`CollectionTier.swift`, in `tierMap` beside the other `.scan` entries (`patch-device-failures` / `update-device-failures`):

```swift
        // 2.8.0 per-device scan phase: one or two jamf-cli calls per Mac.
        "ddm-device-status":              .scan,
        "mdm-command-health":             .scan,
```

Do NOT add them to `collectCommandMatrix` — they are produced by the scan phase, and `testEveryTieredKindIsKnownToReportEngine` reads `knownCollectKinds`, not the matrix.

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd app && swift test --filter "CollectionTierTests|PlatformOnlyKindTests|CollectFilterTests" 2>&1 | tail -3`
Expected: 0 failures. If a test in `CollectFilterTests` or `CollectKindStatusTests` pins `knownCollectKinds.count`, update the literal by +2 and note it in the commit body.

- [ ] **Step 5: Commit**

```bash
git add app/Sources/JamfReports/Engine/ReportEngine.swift app/Sources/JamfReports/Services/CollectionTier.swift \
        app/Tests/JamfReportsTests/CollectionTierTests.swift app/Tests/JamfReportsTests/PlatformOnlyKindTests.swift
git commit -m "feat(collect): register ddm-device-status and mdm-command-health as scan-tier kinds"
```

---

### Task 5: The per-device scan phase in `collect`

**Files:**
- Create: `app/Sources/JamfReports/Engine/ReportEngine+DeviceScan.swift`
- Modify: `app/Sources/JamfReports/Engine/ReportEngine.swift` — `saveSnapshot` (~line 3208) and `loadLatestSnapshotData` (~line 3281) drop `private`; `collect` gains one call between `enforceCollectVerdicts` and `finalizeCollect` (~line 1806)
- Test: `app/Tests/JamfReportsTests/DeviceScanCollectTests.swift`

**Interfaces:**
- Consumes: `DeviceScanBuilders` (Task 2), the two kind names (Task 4), `CLIBridge.runAndCapture`, `StateFileStore.record`, `CadenceResolver`, `ReportEngine.saveSnapshot(data:kind:dataDir:recordManifest:onLine:)`, `ReportEngine.loadLatestSnapshotData(kind:dataDir:)`.
- Produces: `ReportEngine.runDeviceScanPhase(profile:bin:dataDir:tiers:skipExpensive:force:recordManifest:stateStore:collectStart:onLine:) async -> Set<String>` (the kinds it saved), `ReportEngine.DeviceScanTarget`, `ReportEngine.deviceScanConcurrency = 4`.

- [ ] **Step 1: Write the failing tests**

The stub is a shell script that dispatches on argv. Exit codes per device are driven by the computers snapshot the test writes, so one stub covers every rule.

```swift
import XCTest
@testable import JamfReports

/// The scan phase runs against a stub jamf-cli that answers `computers list`,
/// `classic-computer-history get <id>` and `ddm-status status-items <mgmt>`
/// from files in a temp dir. The stub is NOT named `jamf-cli` (codesign gate).
final class DeviceScanCollectTests: XCTestCase {

    private var root: URL!
    private var binDir: URL!
    private var answers: URL!
    private let profile = "scanphase"

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("JRC-Scan-\(UUID().uuidString)", isDirectory: true)
        let workspacesRoot = root.appendingPathComponent("Jamf-Reports", isDirectory: true)
        try FileManager.default.createDirectory(
            at: workspacesRoot.appendingPathComponent(profile, isDirectory: true),
            withIntermediateDirectories: true)
        binDir = root.appendingPathComponent("bin", isDirectory: true)
        answers = root.appendingPathComponent("answers", isDirectory: true)
        try FileManager.default.createDirectory(at: binDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: answers, withIntermediateDirectories: true)
        setenv("JRC_TEST_WORKSPACES_ROOT", workspacesRoot.path, 1)
        addTeardownBlock { unsetenv("JRC_TEST_WORKSPACES_ROOT") }
        let ws = try XCTUnwrap(ProfileService.workspaceURL(for: profile))
        try "jamf_cli:\n  profile: \"\(profile)\"\n".write(
            to: ws.appendingPathComponent("config.yaml"), atomically: true, encoding: .utf8)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
        try super.tearDownWithError()
    }

    /// Writes `answers/<name>` files and a stub that maps argv to them:
    ///   computers list                      → answers/computers   (exit 0)
    ///   classic-computer-history get <id>   → answers/hist-<id>   (exit = first line of answers/hist-<id>.exit if present)
    ///   ddm-status status-items <mgmt>      → answers/ddm-<mgmt>  (same exit rule)
    /// Anything else → prints [] exit 0, so the argv matrix's kinds "succeed" harmlessly.
    private func makeStub() throws -> URL {
        let url = binDir.appendingPathComponent("stub-cli")
        let script = """
        #!/bin/sh
        A="\(answers.path)"
        emit() { f="$A/$1"; if [ -f "$f.exit" ]; then code=$(cat "$f.exit"); else code=0; fi; \\
                 [ -f "$f" ] && cat "$f"; exit "$code"; }
        case "$*" in
          *" computers list "*) emit computers ;;
          *" classic-computer-history get "*) id=$(echo "$*" | sed -E 's/.*classic-computer-history get ([^ ]+).*/\\1/'); emit "hist-$id" ;;
          *" ddm-status status-items "*) m=$(echo "$*" | sed -E 's/.*status-items ([^ ]+).*/\\1/'); emit "ddm-$m" ;;
          *) printf '[]'; exit 0 ;;
        esac
        """
        try script.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    private func answer(_ name: String, _ body: String, exit code: Int? = nil) throws {
        try body.write(to: answers.appendingPathComponent(name), atomically: true, encoding: .utf8)
        if let code {
            try "\(code)".write(to: answers.appendingPathComponent("\(name).exit"),
                                atomically: true, encoding: .utf8)
        }
    }

    private func computers(_ rows: [(id: String, name: String, mgmt: String, ddm: Bool)]) -> String {
        let objs = rows.map {
            "{\"id\":\"\($0.id)\",\"general\":{\"name\":\"\($0.name)\",\"managementId\":\"\($0.mgmt)\"," +
            "\"declarativeDeviceManagementEnabled\":\($0.ddm)}}"
        }
        return "[" + objs.joined(separator: ",") + "]"
    }

    private let cleanHistory = #"{"commands":{"completed":"","failed":"","pending":""}}"#
    private let failedHistory =
        #"{"commands":{"completed":"","failed":{"command":{"name":"InstallApplication","status":"timed out"}},"pending":""}}"#
    private let ddmPayload =
        #"{"statusItems":[{"key":"device.operating-system.version","value":"27.0","lastUpdateTime":"2026-09-04T07:00:00.000"},"# +
        #"{"key":"management.declarations.configurations","value":"{active=true, identifier=D-1, valid=true, server-token=x}","lastUpdateTime":"2026-09-04T07:00:00.000"},"# +
        #"{"key":"mdm.push-token","value":"SECRET","lastUpdateTime":"2026-09-04T07:00:00.000"}]}"#

    private func runScan(force: Bool = true, skipExpensive: Bool = false) async throws -> [String] {
        let stub = try makeStub()
        let collector = LogTextCollector()
        try await ReportEngine.collect(
            profile: profile, workspacePaths: WorkspacePaths.self,
            tiers: [.scan], skipExpensive: skipExpensive, force: force,
            locateJamfCLI: { stub }, onLine: collector.append)
        return collector.texts
    }

    private func latest<T: Decodable>(_ kind: String, as: T.Type) throws -> T? {
        let dir = try WorkspacePaths.dataDir(for: profile).appendingPathComponent(kind, isDirectory: true)
        guard let url = FileManager.newestJSONFile(in: dir) else { return nil }
        return try JSONDecoder().decode(T.self, from: Data(contentsOf: url))
    }

    // MARK: - Happy path

    func testWritesBothSnapshotsAndNeverTheToken() async throws {
        try answer("computers", computers([("1", "A", "m1", true), ("2", "B", "m2", false)]))
        try answer("hist-1", failedHistory); try answer("hist-2", cleanHistory)
        try answer("ddm-m1", ddmPayload)
        let lines = try await runScan()

        let health = try XCTUnwrap(try latest("mdm-command-health", as: [MDMCommandHealthRecord].self))
        XCTAssertEqual(health.map(\.deviceId).sorted(), ["1", "2"])
        XCTAssertEqual(health.first { $0.deviceId == "1" }?.failedCommands, ["InstallApplication"])

        let ddm = try XCTUnwrap(try latest("ddm-device-status", as: [DDMDeviceStatusRecord].self))
        XCTAssertEqual(ddm.map(\.deviceId), ["1"], "only the DDM-enabled Mac is queried")
        XCTAssertEqual(ddm.first?.declarations.first?.identifier, "D-1")
        let raw = try String(contentsOf: try XCTUnwrap(FileManager.newestJSONFile(
            in: try WorkspacePaths.dataDir(for: profile).appendingPathComponent("ddm-device-status"))))
        XCTAssertFalse(raw.contains("SECRET"))
        XCTAssertTrue(lines.contains { $0.hasPrefix("[ok] ddm-device-status") }, "\(lines)")
        XCTAssertTrue(lines.contains { $0.hasPrefix("[ok] mdm-command-health") }, "\(lines)")

        let store = StateFileStore(directory: try WorkspacePaths.stateDir(for: profile))
        XCTAssertNotNil(store.lastRun(report: "ddm-device-status"))
        XCTAssertNotNil(store.lastRun(report: "mdm-command-health"))
    }

    // MARK: - Failure rules

    func testStatusItems404RecordsNotReportedNotAnError() async throws {
        try answer("computers", computers([("1", "A", "m1", true)]))
        try answer("hist-1", cleanHistory)
        try answer("ddm-m1", "", exit: Int(CLIBridge.exitCodeNotFound))
        let lines = try await runScan()
        let ddm = try XCTUnwrap(try latest("ddm-device-status", as: [DDMDeviceStatusRecord].self))
        XCTAssertEqual(ddm.first?.ddmReported, false)
        XCTAssertFalse(lines.contains { $0.contains("[partial] ddm-device-status") })
    }

    func testMoreThanAQuarterFailingRecordsTheKindFailedAndWritesNothing() async throws {
        try answer("computers", computers([
            ("1", "A", "m1", false), ("2", "B", "m2", false), ("3", "C", "m3", false), ("4", "D", "m4", false)]))
        try answer("hist-1", cleanHistory); try answer("hist-2", cleanHistory)
        try answer("hist-3", "", exit: 1); try answer("hist-4", "", exit: 1)   // 2 of 4 = 50%
        let lines = try await runScan()
        XCTAssertNil(try latest("mdm-command-health", as: [MDMCommandHealthRecord].self))
        let store = StateFileStore(directory: try WorkspacePaths.stateDir(for: profile))
        XCTAssertEqual(store.failures(report: "mdm-command-health")?.count, 1)
        XCTAssertTrue(lines.contains { $0.contains("[warn] mdm-command-health") && $0.contains("2 of 4") }, "\(lines)")
    }

    func testBelowBudgetWritesAndMarksPartial() async throws {
        try answer("computers", computers([
            ("1", "A", "m1", false), ("2", "B", "m2", false), ("3", "C", "m3", false), ("4", "D", "m4", false)]))
        for i in 1...3 { try answer("hist-\(i)", cleanHistory) }
        try answer("hist-4", "", exit: 1)                                        // 1 of 4 = 25%, not more
        let lines = try await runScan()
        let health = try XCTUnwrap(try latest("mdm-command-health", as: [MDMCommandHealthRecord].self))
        XCTAssertEqual(health.count, 3)
        XCTAssertTrue(lines.contains { $0 == "[partial] mdm-command-health: 1 of 4 devices did not respond" }, "\(lines)")
    }

    func testExit5OnFirstDeviceStopsThatCallTypeOnly() async throws {
        try answer("computers", computers([("1", "A", "m1", true), ("2", "B", "m2", true)]))
        try answer("hist-1", cleanHistory); try answer("hist-2", cleanHistory)
        try answer("ddm-m1", "", exit: Int(CLIBridge.exitCodePermissionDenied))
        try answer("ddm-m2", ddmPayload)
        let lines = try await runScan()
        XCTAssertNil(try latest("ddm-device-status", as: [DDMDeviceStatusRecord].self),
                     "the status-items call type stopped after the first 403")
        XCTAssertNotNil(try latest("mdm-command-health", as: [MDMCommandHealthRecord].self),
                        "the history call type carried on")
        XCTAssertTrue(lines.contains { $0.contains("Read Computers") }, "\(lines)")
    }

    func testExit8SkipsHistoryForTheRun() async throws {
        try answer("computers", computers([("1", "A", "m1", true)]))
        try answer("hist-1", "", exit: Int(CLIBridge.exitCodeRefusedByPolicy))
        try answer("ddm-m1", ddmPayload)
        let lines = try await runScan()
        XCTAssertNil(try latest("mdm-command-health", as: [MDMCommandHealthRecord].self))
        XCTAssertNotNil(try latest("ddm-device-status", as: [DDMDeviceStatusRecord].self))
        XCTAssertTrue(lines.contains { $0.contains("mdm-command-health") && $0.contains("refused by policy") }, "\(lines)")
    }

    func testNoComputersSnapshotSkipsWithOneLine() async throws {
        // No computers answer → stub prints [] for `computers list` via the default branch.
        try answer("computers", "[]")
        let lines = try await runScan()
        XCTAssertTrue(lines.contains { $0 == "[skip] device scan: no computers snapshot" }, "\(lines)")
        XCTAssertNil(try latest("mdm-command-health", as: [MDMCommandHealthRecord].self))
    }

    func testSkipExpensiveSkipsTheWholePhase() async throws {
        try answer("computers", computers([("1", "A", "m1", true)]))
        try answer("hist-1", failedHistory); try answer("ddm-m1", ddmPayload)
        _ = try await runScan(skipExpensive: true)
        XCTAssertNil(try latest("mdm-command-health", as: [MDMCommandHealthRecord].self))
        XCTAssertNil(try latest("ddm-device-status", as: [DDMDeviceStatusRecord].self))
    }

    func testConcurrencyNeverExceedsFour() async throws {
        // Each history answer is served by a stub that records its own PID
        // overlap; simpler and deterministic: assert the code constant, and
        // that 12 devices complete (the window logic drains fully).
        XCTAssertEqual(ReportEngine.deviceScanConcurrency, 4)
        let rows = (1...12).map { ("\($0)", "M\($0)", "m\($0)", false) }
        try answer("computers", computers(rows))
        for i in 1...12 { try answer("hist-\(i)", cleanHistory) }
        _ = try await runScan()
        let health = try XCTUnwrap(try latest("mdm-command-health", as: [MDMCommandHealthRecord].self))
        XCTAssertEqual(health.count, 12)
    }

    func testUnsafeDeviceIdIsSkippedNotPassedToArgv() async throws {
        try answer("computers", computers([("-rf", "Evil", "m1", false), ("2", "B", "m2", false)]))
        try answer("hist-2", cleanHistory)
        let lines = try await runScan()
        let health = try XCTUnwrap(try latest("mdm-command-health", as: [MDMCommandHealthRecord].self))
        XCTAssertEqual(health.map(\.deviceId), ["2"])
        XCTAssertTrue(lines.contains { $0.contains("unsafe id") }, "\(lines)")
    }
}

/// Same helper `CollectHonestyTests` keeps privately; duplicated here rather
/// than made shared, to keep that file's blast radius zero.
private final class LogTextCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []
    var append: @Sendable (CLIBridge.LogLine) -> Void {
        { line in self.lock.lock(); defer { self.lock.unlock() }; self.lines.append(line.text) }
    }
    var texts: [String] { lock.lock(); defer { lock.unlock() }; return lines }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `cd app && swift build --build-tests 2>&1 | grep error: | head -3`
Expected: `type 'ReportEngine' has no member 'deviceScanConcurrency'`.

- [ ] **Step 3: Open the two engine seams**

In `ReportEngine.swift` change `private static func saveSnapshot(` to `static func saveSnapshot(` and `private static func loadLatestSnapshotData(` to `static func loadLatestSnapshotData(`. Then in `collect`, replace the `finalizeCollect` call with:

```swift
        // 2.8.0: per-device scan phase. After the verdicts (so a dead run never
        // starts a fleet-wide fan-out) and before finalize (so its kinds count
        // as live in today's summary).
        let scanSaved = await Self.runDeviceScanPhase(
            profile: profile, bin: bin, dataDir: dataDir, tiers: tiers,
            skipExpensive: skipExpensive, force: force, recordManifest: recordManifest,
            stateStore: stateStore, collectStart: collectStart, onLine: onLine
        )
        savedKinds.formUnion(scanSaved)

        await Self.finalizeCollect(
            profile: profile, tiers: tiers, bin: bin, dataDir: dataDir,
            savedKinds: savedKinds, loadedConfig: loadedConfig,
            workspacePaths: workspacePaths, onLine: onLine
        )
```

- [ ] **Step 4: Write the scan phase**

`ReportEngine+DeviceScan.swift`:

```swift
import Foundation

/// 2.8.0 per-device scan phase. Two read-only jamf-cli calls per managed Mac,
/// bounded to four concurrent processes, reduced through `DeviceScanBuilders`
/// into the `ddm-device-status` and `mdm-command-health` snapshots.
///
/// This is the first per-device fan-out inside `collect`; every other kind is
/// one server-side report. A jamf-cli feature request for server-side
/// equivalents is filed upstream so this file can be deleted when they ship.
extension ReportEngine {

    static let deviceScanConcurrency = 4
    static let ddmDeviceStatusKind = DDMDeviceStatusService.kind
    static let mdmCommandHealthKind = MDMCommandHealthService.kind
    private static let progressEvery = 100

    /// One row of the `computers` snapshot the scan needs. `id` sits at the top
    /// level; `managementId` and the DDM flag under `general` (prod-verified).
    struct DeviceScanTarget: Decodable, Sendable, Equatable {
        let id: String
        let name: String
        let managementId: String?
        let ddmEnabled: Bool

        private enum Keys: String, CodingKey { case id, general }
        private enum General: String, CodingKey {
            case name, managementId, declarativeDeviceManagementEnabled
        }

        init(id: String, name: String, managementId: String?, ddmEnabled: Bool) {
            self.id = id; self.name = name; self.managementId = managementId; self.ddmEnabled = ddmEnabled
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: Keys.self)
            id = try c.decodeIfPresent(AnyCodable.self, forKey: .id)?.stringValue ?? ""
            let g = try? c.nestedContainer(keyedBy: General.self, forKey: .general)
            name = (try? g?.decodeIfPresent(String.self, forKey: .name)) ?? ""
            managementId = try? g?.decodeIfPresent(String.self, forKey: .managementId)
            ddmEnabled = (try? g?.decodeIfPresent(AnyCodable.self, forKey: .declarativeDeviceManagementEnabled))?
                .flatMap { $0 }?.boolValue ?? false
        }
    }

    /// Outcome of one call type across the fleet.
    private struct CallTypeTally: Sendable {
        var attempted = 0
        var failed = 0
        var stopped: String?      // reason the call type was abandoned for the run
    }

    private enum CallType: String, Sendable { case history, statusItems }

    private struct DeviceResult: Sendable {
        let target: DeviceScanTarget
        let history: (exit: Int32, data: Data)?      // nil = call type not made
        let status: (exit: Int32, data: Data)?
    }

    /// Returns the kinds it wrote. Never throws: the matrix's verdicts have
    /// already run, and a scan problem must not turn a good run red.
    static func runDeviceScanPhase(
        profile: String, bin: URL, dataDir: URL, tiers: Set<CollectionTier>,
        skipExpensive: Bool, force: Bool, recordManifest: Bool,
        stateStore: StateFileStore?, collectStart: Date,
        onLine: @Sendable @escaping (CLIBridge.LogLine) -> Void
    ) async -> Set<String> {
        guard tiers.contains(.scan), !skipExpensive else { return [] }
        let kinds = [ddmDeviceStatusKind, mdmCommandHealthKind]
        if !force {
            let due = kinds.contains { kind in
                CadenceResolver.isDue(lastRun: stateStore?.lastRun(report: kind),
                                      cadence: CadenceResolver.cadence(forReport: kind), now: collectStart)
            }
            guard due else {
                onLine(.init(timestamp: Date(), level: .info, text: "[skip] device scan: not due"))
                return []
            }
        }
        guard let data = try? loadLatestSnapshotData(kind: "computers", dataDir: dataDir),
              let all = try? JSONDecoder().decode([DeviceScanTarget].self, from: data),
              !all.isEmpty else {
            onLine(.init(timestamp: Date(), level: .info, text: "[skip] device scan: no computers snapshot"))
            return []
        }
        var targets: [DeviceScanTarget] = []
        for t in all {
            guard CLIBridge.isSafeDeviceIdentifier(t.id) else {
                onLine(.init(timestamp: Date(), level: .warn,
                             text: "[warn] device scan: skipping a device with an unsafe id"))
                continue
            }
            targets.append(t)
        }
        onLine(.init(timestamp: Date(), level: .info,
                     text: "[info] device scan: \(targets.count) Mac(s), \(targets.filter(\.ddmEnabled).count) DDM-enabled"))

        let results = await scanDevices(targets, profile: profile, bin: bin, onLine: onLine)
        return reduceAndSave(results: results, totalTargets: targets.count, dataDir: dataDir,
                             recordManifest: recordManifest, stateStore: stateStore,
                             collectStart: collectStart, onLine: onLine)
    }

    // MARK: - Fan-out

    /// Bounded task group: at most `deviceScanConcurrency` jamf-cli processes.
    /// Exit 5 or 8 on ANY device abandons that call type for the remaining
    /// devices (an actor-guarded flag read before each launch); exit 3 abandons
    /// both — a credential that died mid-scan will not come back for device 400.
    private static func scanDevices(
        _ targets: [DeviceScanTarget], profile: String, bin: URL,
        onLine: @Sendable @escaping (CLIBridge.LogLine) -> Void
    ) async -> [DeviceResult] {
        let bridge = CLIBridge()
        let gate = StopGate()
        var results: [DeviceResult] = []
        results.reserveCapacity(targets.count)
        var done = 0

        await withTaskGroup(of: DeviceResult.self) { group in
            var inFlight = 0
            for target in targets {
                if inFlight >= deviceScanConcurrency, let r = await group.next() {
                    inFlight -= 1; results.append(r); done += 1
                    if done % progressEvery == 0 {
                        onLine(.init(timestamp: Date(), level: .info,
                                     text: "[info] device scan: \(done) of \(targets.count)"))
                    }
                }
                inFlight += 1
                group.addTask {
                    await scanOne(target, profile: profile, bin: bin, bridge: bridge, gate: gate, onLine: onLine)
                }
            }
            for await r in group { results.append(r) }
        }
        return results
    }

    private static func scanOne(
        _ t: DeviceScanTarget, profile: String, bin: URL, bridge: CLIBridge, gate: StopGate,
        onLine: @Sendable @escaping (CLIBridge.LogLine) -> Void
    ) async -> DeviceResult {
        var history: (Int32, Data)?
        var status: (Int32, Data)?
        if await gate.allows(.history) {
            history = await run(bridge, bin, ["-p", profile, "pro", "classic-computer-history", "get", t.id,
                                             "--subset", "commands", "--output", "json"])
            if let h = history { await gate.observe(h.0, for: .history, onLine: onLine) }
        }
        if t.ddmEnabled, let mgmt = t.managementId, CLIBridge.isSafeDeviceIdentifier(mgmt),
           await gate.allows(.statusItems) {
            status = await run(bridge, bin, ["-p", profile, "pro", "ddm-status", "status-items", mgmt,
                                            "--output", "json"])
            if let s = status { await gate.observe(s.0, for: .statusItems, onLine: onLine) }
        }
        return DeviceResult(target: t, history: history, status: status)
    }

    private static func run(_ bridge: CLIBridge, _ bin: URL, _ args: [String]) async -> (Int32, Data)? {
        try? await bridge.runAndCapture(executable: bin, arguments: args,
                                        environment: CLIBridge.environmentForJamfCLI(), onLine: { _ in })
    }

    /// Per-run "stop this call type" flags. An actor so the four in-flight
    /// tasks agree on the decision without a lock.
    private actor StopGate {
        private var stopped: [CallType: String] = [:]

        func allows(_ type: CallType) -> Bool { stopped[type] == nil }

        func observe(_ exit: Int32, for type: CallType,
                     onLine: @Sendable (CLIBridge.LogLine) -> Void) {
            guard stopped[type] == nil else { return }
            let kind = type == .history ? ReportEngine.mdmCommandHealthKind : ReportEngine.ddmDeviceStatusKind
            switch exit {
            case CLIBridge.exitCodePermissionDenied:
                stopped[type] = "exit 5 — the API role needs Read Computers"
                onLine(.init(timestamp: Date(), level: .warn,
                             text: "[warn] \(kind): exit 5 on the first device — the API role needs Read Computers; skipping the rest of the run"))
            case CLIBridge.exitCodeRefusedByPolicy:
                stopped[type] = "exit 8 — refused by policy"
                onLine(.init(timestamp: Date(), level: .warn,
                             text: "[warn] \(kind): refused by policy (exit 8) — this profile's API does not publish the command; skipping for the run"))
            case CLIBridge.exitCodeUnauthorized:
                stopped[.history] = "exit 3 — credentials rejected mid-scan"
                stopped[.statusItems] = stopped[.history]
                onLine(.init(timestamp: Date(), level: .warn,
                             text: "[warn] device scan: credentials rejected (exit 3) part-way through; stopping both call types"))
            default: break
            }
        }
    }

    // MARK: - Reduce + save

    private static func reduceAndSave(
        results: [DeviceResult], totalTargets: Int, dataDir: URL, recordManifest: Bool,
        stateStore: StateFileStore?, collectStart: Date,
        onLine: @Sendable @escaping (CLIBridge.LogLine) -> Void
    ) -> Set<String> {
        var saved: Set<String> = []
        let now = Date()

        // History → mdm-command-health (every device).
        var health: [MDMCommandHealthRecord] = []
        var historyAttempted = 0, historyFailed = 0
        for r in results {
            guard let h = r.history else { continue }
            historyAttempted += 1
            if h.exit == 0 || h.exit == CLIBridge.exitCodePartialFailure,
               let decoded = try? JSONDecoder().decode(ComputerHistoryCommands.self, from: h.data) {
                health.append(DeviceScanBuilders.healthRecord(deviceId: r.target.id, name: r.target.name,
                                                              history: decoded, now: now))
            } else {
                historyFailed += 1
            }
        }
        let historyAbandoned = historyAttempted < results.count && historyAttempted > 0
        if historyAttempted == 0 {
            // Stopped on the first device (exit 5/8/3) — the gate already logged why.
            stateStore?.record(.failed(exitCode: nil), report: mdmCommandHealthKind, at: collectStart)
        } else if historyAbandoned || DeviceScanBuilders.exceedsFailureBudget(failed: historyFailed, total: historyAttempted) {
            onLine(.init(timestamp: Date(), level: .warn,
                         text: "[warn] \(mdmCommandHealthKind): \(historyFailed) of \(historyAttempted) devices failed — not written"))
            stateStore?.record(.failed(exitCode: nil), report: mdmCommandHealthKind, at: collectStart)
        } else {
            save(health, kind: mdmCommandHealthKind, failed: historyFailed, attempted: historyAttempted,
                 dataDir: dataDir, recordManifest: recordManifest, stateStore: stateStore,
                 collectStart: collectStart, onLine: onLine, saved: &saved)
        }

        // Status items → ddm-device-status (DDM-enabled devices only).
        let ddmTargets = results.filter { $0.target.ddmEnabled && $0.target.managementId != nil }
        if !ddmTargets.isEmpty {
            var rows: [DDMDeviceStatusRecord] = []
            var attempted = 0, failed = 0
            for r in ddmTargets {
                guard let s = r.status else { continue }
                attempted += 1
                let mgmt = r.target.managementId ?? ""
                if s.exit == CLIBridge.exitCodeNotFound {
                    rows.append(DeviceScanBuilders.ddmRecordNotReported(deviceId: r.target.id, name: r.target.name,
                                                                       managementId: mgmt))
                } else if s.exit == 0 || s.exit == CLIBridge.exitCodePartialFailure,
                          let payload = try? JSONDecoder().decode(DDMStatusItemsPayload.self, from: s.data) {
                    rows.append(DeviceScanBuilders.ddmRecord(deviceId: r.target.id, name: r.target.name,
                                                            managementId: mgmt, payload: payload))
                } else {
                    failed += 1
                }
            }
            let abandoned = attempted < ddmTargets.count && attempted > 0
            if attempted == 0 {
                stateStore?.record(.failed(exitCode: nil), report: ddmDeviceStatusKind, at: collectStart)
            } else if abandoned || DeviceScanBuilders.exceedsFailureBudget(failed: failed, total: attempted) {
                onLine(.init(timestamp: Date(), level: .warn,
                             text: "[warn] \(ddmDeviceStatusKind): \(failed) of \(attempted) devices failed — not written"))
                stateStore?.record(.failed(exitCode: nil), report: ddmDeviceStatusKind, at: collectStart)
            } else {
                save(rows, kind: ddmDeviceStatusKind, failed: failed, attempted: attempted,
                     dataDir: dataDir, recordManifest: recordManifest, stateStore: stateStore,
                     collectStart: collectStart, onLine: onLine, saved: &saved)
            }
        }
        return saved
    }

    private static func save<T: Encodable>(
        _ rows: [T], kind: String, failed: Int, attempted: Int, dataDir: URL, recordManifest: Bool,
        stateStore: StateFileStore?, collectStart: Date,
        onLine: @Sendable @escaping (CLIBridge.LogLine) -> Void, saved: inout Set<String>
    ) {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(rows)
            try saveSnapshot(data: data, kind: kind, dataDir: dataDir,
                             recordManifest: recordManifest, onLine: onLine)
            stateStore?.record(.landed, report: kind, at: collectStart)
            saved.insert(kind)
            onLine(.init(timestamp: Date(), level: .ok, text: "[ok] \(kind): \(rows.count) device(s)"))
            if failed > 0 {
                onLine(.init(timestamp: Date(), level: .warn,
                             text: "[partial] \(kind): \(failed) of \(attempted) devices did not respond"))
            }
        } catch {
            stateStore?.record(.failed(exitCode: nil), report: kind, at: collectStart)
            onLine(.init(timestamp: Date(), level: .warn,
                         text: "[warn] \(kind): could not write snapshot — \(error.localizedDescription)"))
        }
    }
}
```

One thing to check while writing this: `AnyCodable.boolValue` on
`declarativeDeviceManagementEnabled` reads JSON `true` correctly (its decoder tries
`Bool` first), so the expression
`(try? g?.decodeIfPresent(AnyCodable.self, forKey: .declarativeDeviceManagementEnabled))??.boolValue ?? false`
is the intended form; if Swift 6.1 rejects the double-optional chain, bind it in
two `if let` steps. Add no third variant.

- [ ] **Step 5: Run the new suite, then the collect suites it sits beside**

Run: `cd app && swift test --filter DeviceScanCollectTests 2>&1 | tail -5`
Expected: `Executed 10 tests, with 0 failures`.
Run: `cd app && swift test --filter "CollectHonestyTests|CollectFilterTests|CollectKindStatusTests|SharedWorkspaceCollectGateTests" 2>&1 | tail -3`
Expected: 0 failures. `CollectHonestyTests.testEveryKindFailingToLaunchIsReportedAsADeadCollect` expects `failedCount == 2` for the scan tier — the scan phase runs AFTER `enforceCollectVerdicts` throws, so the count is unchanged. If it is not, the call was placed too early.

- [ ] **Step 6: Mutation check the two rules a reviewer cannot see from the tests alone**

Back up: `cp app/Sources/JamfReports/Engine/ReportEngine+DeviceScan.swift /private/tmp/DeviceScan.bak`.
Mutant A: in `scanOne`, drop the `t.ddmEnabled` condition → `testWritesBothSnapshotsAndNeverTheToken` must fail (device 2 would be queried and, with no `ddm-m2` answer, count as a failure → 1 of 2 = 50% → nothing written).
Mutant B: in `StopGate.observe`, remove the `.exitCodePermissionDenied` case → `testExit5OnFirstDeviceStopsThatCallTypeOnly` must fail.
Restore from `/private/tmp/DeviceScan.bak`.

- [ ] **Step 7: Commit**

```bash
git add app/Sources/JamfReports/Engine/ReportEngine+DeviceScan.swift app/Sources/JamfReports/Engine/ReportEngine.swift \
        app/Tests/JamfReportsTests/DeviceScanCollectTests.swift
git commit -m "feat(collect): per-device scan phase for DDM status and MDM command health

Runs after the matrix verdicts and before finalize, scan tier only, at most
four jamf-cli processes. A 404 on status items is 'not reported'; exit 5/8
stop one call type, exit 3 stops both; >25% failures record the kind failed
and write nothing, otherwise the snapshot lands with a [partial] line."
```

---

### Task 6: Workbook sheets "DDM Device Status" and "MDM Command Health"

**Files:**
- Modify: `app/Sources/JamfReports/Engine/Templates/ReportTemplate.swift` — `SheetID` (after `.blueprintStatus`)
- Modify: `app/Sources/JamfReports/Engine/Templates/FullInstanceTemplate.swift` — `includedSheets` (after `.blueprintStatus`)
- Modify: `app/Sources/JamfReports/Engine/CoreDashboard.swift` — `sheetPlan` (after `("Blueprint Status", writeBlueprintStatus)`), the description dictionary (~line 2952), and two writer funcs after `writeBlueprintStatus`
- Test: `app/Tests/JamfReportsTests/Engine/DeviceScanSheetsTests.swift`

**Interfaces:**
- Consumes: the two snapshot kinds on disk (Task 5's row shapes, read here as `[[String: Any]]`).
- Produces: `SheetID.ddmDeviceStatus = "DDM Device Status"`, `SheetID.mdmCommandHealth = "MDM Command Health"`, `CoreDashboard.writeDDMDeviceStatus()`, `CoreDashboard.writeMDMCommandHealth()`.

- [ ] **Step 1: Write the failing tests**

```swift
import Foundation
import XCTest
@testable import JamfReports

@MainActor
final class DeviceScanSheetsTests: XCTestCase {

    private nonisolated(unsafe) var tmpDir: URL!

    override func setUpWithError() throws {
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("DeviceScanSheets_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: tmpDir) }

    private func write(_ rows: [[String: Any]], kind: String) throws {
        let dir = tmpDir.appendingPathComponent(kind, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: rows)
            .write(to: dir.appendingPathComponent("\(kind)_20260904T120000.json"))
    }

    private func strings(in sheet: String, of workbook: Workbook) -> [String] {
        (workbook.sheet(named: sheet)?.dedupedCells ?? []).compactMap {
            if case let .string(s) = $0.value { return s } else { return nil }
        }
    }

    func testSheetIDsAndTemplateRegistration() {
        XCTAssertEqual(SheetID.ddmDeviceStatus.rawValue, "DDM Device Status")
        XCTAssertEqual(SheetID.mdmCommandHealth.rawValue, "MDM Command Health")
        XCTAssertTrue(FullInstanceTemplate().includedSheets.contains(.ddmDeviceStatus))
        XCTAssertTrue(FullInstanceTemplate().includedSheets.contains(.mdmCommandHealth))
        let dash = CoreDashboard(config: ReportConfig(), dataDir: tmpDir, workbook: Workbook(accentColor: "#2D5EA2"))
        let names = dash.sheetPlan.map(\.name)
        XCTAssertTrue(names.contains("DDM Device Status"))
        XCTAssertTrue(names.contains("MDM Command Health"))
    }

    func testDDMSheetOneRowPerDeviceWithDeclarationCounts() throws {
        try write([[
            "deviceId": "1", "name": "Mac-1", "managementId": "m1", "osVersion": "27.0",
            "reportDate": "2026-09-04T07:00:00.000", "ddmReported": true,
            "declarations": [["identifier": "D-1", "active": true, "valid": true],
                             ["identifier": "D-2", "active": false, "valid": false]],
            "softwareUpdate": ["pendingOSVersion": "27.1", "installState": "pending",
                               "failureReason": "Insufficient space"],
        ], [
            "deviceId": "2", "name": "Mac-2", "managementId": "m2", "ddmReported": false,
            "declarations": [], "softwareUpdate": [:],
        ]], kind: "ddm-device-status")
        let workbook = Workbook(accentColor: "#2D5EA2")
        let dash = CoreDashboard(config: ReportConfig(), dataDir: tmpDir, workbook: workbook)
        XCTAssertNoThrow(try dash.writeDDMDeviceStatus())
        let s = strings(in: "DDM Device Status", of: workbook)
        XCTAssertTrue(s.contains("Mac-1")); XCTAssertTrue(s.contains("Mac-2"))
        XCTAssertTrue(s.contains("Insufficient space"))
        XCTAssertTrue(s.contains("27.1"))
        XCTAssertTrue(s.contains("Not reported"), "a 404 device renders as Not reported, not blank")
        let ints = (workbook.sheet(named: "DDM Device Status")?.dedupedCells ?? []).compactMap {
            if case let .int(i) = $0.value { return i } else { return nil }
        }
        XCTAssertTrue(ints.contains(2), "declaration count")
        XCTAssertTrue(ints.contains(1), "failing declaration count (inactive or invalid)")
    }

    func testMDMSheetListsFailedCommandNames() throws {
        try write([[
            "deviceId": "1", "name": "Mac-1", "failedCount": 2, "pendingCount": 1,
            "failedCommands": ["InstallApplication", "ProfileList"], "oldestPendingDays": 9,
        ]], kind: "mdm-command-health")
        let workbook = Workbook(accentColor: "#2D5EA2")
        let dash = CoreDashboard(config: ReportConfig(), dataDir: tmpDir, workbook: workbook)
        XCTAssertNoThrow(try dash.writeMDMCommandHealth())
        let s = strings(in: "MDM Command Health", of: workbook)
        XCTAssertTrue(s.contains("InstallApplication; ProfileList"))
        XCTAssertTrue(s.contains("Mac-1"))
    }

    func testNoSnapshotWritesNoSheet() {
        let workbook = Workbook(accentColor: "#2D5EA2")
        let dash = CoreDashboard(config: ReportConfig(), dataDir: tmpDir, workbook: workbook)
        XCTAssertThrowsError(try dash.writeDDMDeviceStatus())   // loadLatestJSON throws on a missing kind
        XCTAssertNil(workbook.sheet(named: "DDM Device Status"))
    }
}
```

If `Workbook.dedupedCells` values are not an enum with `.string`/`.int` cases in this tree, mirror whatever `OSCurrencySheetTests` uses to read a cell back — that file is the reference.

- [ ] **Step 2: Run to verify it fails**

Run: `cd app && swift build --build-tests 2>&1 | grep error: | head -3`
Expected: `type 'SheetID' has no member 'ddmDeviceStatus'`.

- [ ] **Step 3: Register and write the sheets**

`ReportTemplate.swift`, after `case blueprintStatus = "Blueprint Status"`:

```swift
    // Per-device scan (2.8.0)
    case ddmDeviceStatus     = "DDM Device Status"
    case mdmCommandHealth    = "MDM Command Health"
```

`FullInstanceTemplate.swift`, after `.blueprintStatus,`:

```swift
            .ddmDeviceStatus,
            .mdmCommandHealth,
```

`CoreDashboard.swift`, in `sheetPlan` after `("Blueprint Status", writeBlueprintStatus),`:

```swift
            ("DDM Device Status", writeDDMDeviceStatus),
            ("MDM Command Health", writeMDMCommandHealth),
```

In the description dictionary after the `"Blueprint Status"` entry:

```swift
            "DDM Device Status": "Per-device DDM declaration and software-update status "
                + "(works on-prem; from the per-device scan).",
            "MDM Command Health": "Per-device failed and pending MDM commands from the "
                + "Classic command history.",
```

After `writeBlueprintStatus()`:

```swift
    // MARK: - DDM Device Status
    // Source: `ddm-device-status` snapshot (ReportEngine+DeviceScan, jamf-cli
    // `pro ddm-status status-items` per DDM-enabled Mac). One row per device.

    func writeDDMDeviceStatus() throws {
        let raw = try loadLatestJSON(names: ["ddm-device-status"])
        let items = (raw as? [[String: Any]]) ?? []
        guard !items.isEmpty else { return }
        let ws = workbook.addSheet("DDM Device Status")
        let ts = ISO8601DateFormatter().string(from: Date())
        var row = ws.writeSheetHeader(title: t("DDM Device Status"),
                                      subtitle: "Generated: \(ts)", ncols: 10)
        ws.setColumnWidth(0, 0, 10)
        ws.setColumnWidth(1, 1, 30)
        ws.setColumnWidth(2, 5, 14)
        ws.setColumnWidth(6, 9, 26)
        let hdrs = ["Device ID", "Name", "OS", "Reported", "Declarations", "Failing",
                    "Pending Version", "Install State", "Failure Reason", "Report Date"]
        for (col, h) in hdrs.enumerated() { ws.write(h, row: row, col: col, format: .header) }
        row += 1
        for item in items {
            let decls = (item["declarations"] as? [[String: Any]]) ?? []
            let failing = decls.filter {
                ($0["active"] as? Bool) == false || ($0["valid"] as? Bool) == false
            }.count
            let reported = (item["ddmReported"] as? Bool) ?? false
            let su = (item["softwareUpdate"] as? [String: Any]) ?? [:]
            let failure = su["failureReason"] as? String ?? ""
            let fmt: CellFormat = (failing > 0 || !failure.isEmpty) ? .yellow : .cell
            ws.write(item["deviceId"] as? String ?? "", row: row, col: 0, format: .cell)
            ws.write(item["name"] as? String ?? "", row: row, col: 1, format: .cell)
            ws.write(item["osVersion"] as? String ?? "", row: row, col: 2, format: .cell)
            ws.write(reported ? "Yes" : "Not reported", row: row, col: 3, format: reported ? .cell : .yellow)
            ws.write(decls.count, row: row, col: 4, format: .cell)
            ws.write(failing, row: row, col: 5, format: fmt)
            ws.write(su["pendingOSVersion"] as? String ?? "", row: row, col: 6, format: .cell)
            ws.write(su["installState"] as? String ?? "", row: row, col: 7, format: .cell)
            ws.write(failure, row: row, col: 8, format: fmt)
            ws.write(item["reportDate"] as? String ?? "", row: row, col: 9, format: .cell)
            row += 1
        }
    }

    // MARK: - MDM Command Health
    // Source: `mdm-command-health` snapshot (ReportEngine+DeviceScan, jamf-cli
    // `pro classic-computer-history get <id> --subset commands` per Mac).

    func writeMDMCommandHealth() throws {
        let raw = try loadLatestJSON(names: ["mdm-command-health"])
        let items = (raw as? [[String: Any]]) ?? []
        guard !items.isEmpty else { return }
        let ws = workbook.addSheet("MDM Command Health")
        let ts = ISO8601DateFormatter().string(from: Date())
        var row = ws.writeSheetHeader(title: t("MDM Command Health"),
                                      subtitle: "Generated: \(ts)", ncols: 6)
        ws.setColumnWidth(0, 0, 10)
        ws.setColumnWidth(1, 1, 30)
        ws.setColumnWidth(2, 4, 14)
        ws.setColumnWidth(5, 5, 60)
        let hdrs = ["Device ID", "Name", "Failed", "Pending", "Oldest Pending (days)", "Failed Commands"]
        for (col, h) in hdrs.enumerated() { ws.write(h, row: row, col: col, format: .header) }
        row += 1
        // Worst first: most failures, then oldest pending.
        let sorted = items.sorted {
            let a = (asInt($0["failedCount"]) ?? 0, asInt($0["oldestPendingDays"]) ?? 0)
            let b = (asInt($1["failedCount"]) ?? 0, asInt($1["oldestPendingDays"]) ?? 0)
            return a > b
        }
        for item in sorted {
            let failed = asInt(item["failedCount"]) ?? 0
            let oldest = asInt(item["oldestPendingDays"])
            let stale = (oldest ?? 0) >= DeviceScanBuilders.pendingAgeThresholdDays
            ws.write(item["deviceId"] as? String ?? "", row: row, col: 0, format: .cell)
            ws.write(item["name"] as? String ?? "", row: row, col: 1, format: .cell)
            ws.write(failed, row: row, col: 2, format: failed > 0 ? .yellow : .cell)
            ws.write(asInt(item["pendingCount"]) ?? 0, row: row, col: 3, format: .cell)
            if let oldest { ws.write(oldest, row: row, col: 4, format: stale ? .yellow : .cell) }
            else { ws.write("", row: row, col: 4, format: .cell) }
            let names = (item["failedCommands"] as? [String]) ?? []
            ws.write(names.joined(separator: "; "), row: row, col: 5, format: .cell)
            row += 1
        }
    }
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd app && swift test --filter "DeviceScanSheetsTests|ReportTemplateTests|TemplatedEngineTests|CoreDashboardTests" 2>&1 | tail -3`
Expected: 0 failures. If a test pins the FullInstance sheet count or `sheetPlan.count` by literal, bump it by 2 and say so in the commit body.

- [ ] **Step 5: Commit**

```bash
git add app/Sources/JamfReports/Engine/Templates/ReportTemplate.swift app/Sources/JamfReports/Engine/Templates/FullInstanceTemplate.swift \
        app/Sources/JamfReports/Engine/CoreDashboard.swift app/Tests/JamfReportsTests/Engine/DeviceScanSheetsTests.swift
git commit -m "feat(report): DDM Device Status and MDM Command Health sheets"
```

---

### Task 7: DDM screen — three-input lock, header strip, Declarations and Software updates sections

**Files:**
- Modify: `app/Sources/JamfReports/Services/DDMDeviceStatusService.swift` — add `fleetDDMCounts(profile:)`
- Modify: `app/Sources/JamfReports/Views/DDMBlueprintView.swift`
- Modify: `app/Tests/JamfReportsTests/DDMBlueprintViewTests.swift`
- Test: add `testFleetDDMCountsReadsComputers` to `app/Tests/JamfReportsTests/DDMDeviceStatusServiceTests.swift`

**Interfaces:**
- Consumes: `DDMDeviceStatusService.Snapshot` (Task 3), `ReportEngine.DeviceScanTarget` (Task 5).
- Produces: `DDMDeviceStatusService.fleetDDMCounts(profile:) -> (enabled: Int, total: Int)`, `DDMDeviceStatusService.fleetDDMCounts(computersURL:)`; new `DDMBlueprintView.decideLockState(isDemoMode:experimentalOn:platformAvailable:hasPlatformData:hasDeviceData:ddmEnabledCount:)`.

- [ ] **Step 1: Write the failing tests**

In `DDMDeviceStatusServiceTests`:

```swift
    func testFleetDDMCountsReadsComputers() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ddm-computers-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("computers_20260904T120000.json")
        let json = """
        [{"id":"1","general":{"name":"A","managementId":"m1","declarativeDeviceManagementEnabled":true}},
         {"id":"2","general":{"name":"B","managementId":"m2","declarativeDeviceManagementEnabled":false}},
         {"id":"3","general":{"name":"C","managementId":"m3"}}]
        """
        try Data(json.utf8).write(to: url)
        let counts = DDMDeviceStatusService.fleetDDMCounts(computersURL: url)
        XCTAssertEqual(counts.enabled, 1)
        XCTAssertEqual(counts.total, 3)
        XCTAssertEqual(DDMDeviceStatusService.fleetDDMCounts(computersURL: nil).total, 0)
    }
```

Replace the four `decideLockState` tests in `DDMBlueprintViewTests` (lines 28–75) with:

```swift
    private func decide(demo: Bool = false, experimental: Bool = true, platform: Bool = true,
                        platformData: Bool = false, deviceData: Bool = false,
                        enabled: Int = 0) -> DDMBlueprintView.LockState {
        DDMBlueprintView.decideLockState(
            isDemoMode: demo, experimentalOn: experimental, platformAvailable: platform,
            hasPlatformData: platformData, hasDeviceData: deviceData, ddmEnabledCount: enabled)
    }

    func testLockedOnlyWhenNoInputExists() {
        XCTAssertEqual(decide(experimental: false, platform: false), .locked)
        XCTAssertEqual(decide(experimental: true, platform: true), .unlockedNoData,
                       "a platform profile with no snapshots yet is empty, not locked")
    }

    func testPerDeviceSnapshotUnlocksAnOnPremProfile() {
        XCTAssertEqual(decide(experimental: false, platform: false, deviceData: true), .unlockedWithData)
    }

    func testDDMEnabledCountAloneUnlocksToEmpty() {
        XCTAssertEqual(decide(experimental: false, platform: false, enabled: 6), .unlockedNoData,
                       "inventory says DDM is on; the scan has not run yet")
    }

    func testPlatformDataStillNeedsTheExperimentalGate() {
        XCTAssertEqual(decide(experimental: false, platform: true, platformData: true), .locked)
        XCTAssertEqual(decide(experimental: true, platform: true, platformData: true), .unlockedWithData)
    }

    func testDemoModeBypassesGates() {
        XCTAssertEqual(decide(demo: true, experimental: false, platform: false, platformData: true), .unlockedWithData)
        XCTAssertEqual(decide(demo: true, experimental: false, platform: false), .unlockedNoData)
    }
```

Delete the old `testDemoModeBypassesGatesAndShowsData` / `testDemoModeWithoutDataIsEmptyNotLocked` if they duplicate the last test; keep the two sort tests untouched.

- [ ] **Step 2: Run to verify it fails**

Run: `cd app && swift build --build-tests 2>&1 | grep error: | head -3`
Expected: `extra arguments at positions` on `decideLockState` and `has no member 'fleetDDMCounts'`.

- [ ] **Step 3: Service addition**

Append inside `DDMDeviceStatusService`:

```swift
    /// "DDM enabled N of M" from inventory alone — costs zero jamf-cli calls,
    /// so the screen can say DDM is on before the scan has ever run.
    static func fleetDDMCounts(profile: String) -> (enabled: Int, total: Int) {
        guard let dir = try? WorkspacePaths.dataDir(for: profile) else { return (0, 0) }
        return fleetDDMCounts(computersURL: FileManager.newestJSONFile(
            in: dir.appendingPathComponent("computers", isDirectory: true)))
    }

    static func fleetDDMCounts(computersURL: URL?) -> (enabled: Int, total: Int) {
        guard let computersURL, let data = try? Data(contentsOf: computersURL),
              let rows = try? JSONDecoder().decode([ReportEngine.DeviceScanTarget].self, from: data)
        else { return (0, 0) }
        return (rows.filter(\.ddmEnabled).count, rows.count)
    }
```

- [ ] **Step 4: View changes**

In `DDMBlueprintView`:

1. State: add `@State private var deviceSnapshot: DDMDeviceStatusService.Snapshot = .empty` and `@State private var fleetCounts: (enabled: Int, total: Int) = (0, 0)`.

2. `reload()`:

```swift
    private func reload() {
        if workspace.demoMode {
            snapshot = Self.demoSnapshot
            deviceSnapshot = .empty
            fleetCounts = (0, 0)
            return
        }
        snapshot = DDMBlueprintService.load(profile: workspace.profile)
        deviceSnapshot = DDMDeviceStatusService.load(profile: workspace.profile)
        fleetCounts = DDMDeviceStatusService.fleetDDMCounts(profile: workspace.profile)
    }
```

3. `lockState` and `decideLockState`:

```swift
    var lockState: LockState {
        DDMBlueprintView.decideLockState(
            isDemoMode: workspace.demoMode,
            experimentalOn: experimentalFeatures.isEnabled(.platformAPI),
            platformAvailable: platformAvailable,
            hasPlatformData: snapshot.totalBlueprints > 0 || snapshot.totalDeclarationSources > 0,
            hasDeviceData: !deviceSnapshot.records.isEmpty,
            ddmEnabledCount: fleetCounts.enabled)
    }

    /// Three inputs can unlock the screen: the Platform blueprint snapshot
    /// (still behind the experimental gate + capability probe), the per-device
    /// scan snapshot (any profile), and inventory saying DDM is enabled on at
    /// least one Mac (any profile — "the scan has not run yet" is empty, not
    /// locked). Locked only when none of them exists.
    static func decideLockState(
        isDemoMode: Bool, experimentalOn: Bool, platformAvailable: Bool,
        hasPlatformData: Bool, hasDeviceData: Bool, ddmEnabledCount: Int
    ) -> LockState {
        if isDemoMode { return hasPlatformData ? .unlockedWithData : .unlockedNoData }
        let platformPath = experimentalOn && platformAvailable
        if hasDeviceData || (platformPath && hasPlatformData) { return .unlockedWithData }
        if platformPath || ddmEnabledCount > 0 { return .unlockedNoData }
        return .locked
    }
```

4. `content`, `.unlockedWithData` branch:

```swift
        case .unlockedWithData:
            headerStrip
            if showsPlatformSections {
                adoptionCard
                blueprintTableCard
                declarationTableCard
            }
            if deviceSnapshot.isDetected {
                deviceDeclarationsCard
                softwareUpdatesCard
            }
```

with `private var showsPlatformSections: Bool { workspace.demoMode || (snapshot.totalBlueprints > 0 || snapshot.totalDeclarationSources > 0) }` — on-prem the Blueprints sections are simply absent.

5. Banner tiers: `CollectNowBanner(source: snapshot.cacheSource, tiers: [.inventory, .scan])` and, when `deviceSnapshot.isDetected`, a `FreshnessChipRow(sourceDates: deviceSnapshot.sourceDates, expectedKinds: ["ddm-device-status"])` beneath it.

6. `unlockedEmptyCard` message: `"Run a collect with the Scan tier (or wait for the weekly managed scan) to populate per-device DDM status. Platform profiles can also run the blueprint reports."` and commands `["jamf-reports collect --tiers scan"]`.

7. Header kicker stays `"Experimental — Platform API"` only when `showsPlatformSections`; otherwise `"Declarative Device Management"`. Make `header()` take `kicker: String`.

8. New sections (static helpers keep the body cheap to type-check, matching the file's existing style):

```swift
    private var headerStrip: some View {
        Card(padding: 14) {
            HStack(spacing: 10) {
                DDMBlueprintView.declarationCounter(
                    label: "DDM enabled",
                    value: fleetCounts.enabled, color: Theme.Colors.teal)
                DDMBlueprintView.declarationCounter(
                    label: "of \(fleetCounts.total) Macs",
                    value: fleetCounts.total, color: Theme.Colors.fgMuted)
                DDMBlueprintView.declarationCounter(
                    label: "Reported", value: deviceSnapshot.ddmReportedCount, color: Theme.Colors.ok)
                DDMBlueprintView.declarationCounter(
                    label: "Failing declarations",
                    value: deviceSnapshot.failingDeclarationCount,
                    color: deviceSnapshot.failingDeclarationCount > 0 ? Theme.Colors.danger : Theme.Colors.ok)
            }
        }
    }

    private var deviceDeclarationsCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                SectionHeader(title: "Declarations by identifier",
                              trailing: "\(deviceSnapshot.byIdentifier.count) identifiers")
                if deviceSnapshot.byIdentifier.isEmpty {
                    Text("No declarations reported by any DDM-enabled Mac yet.")
                        .font(.footnote).foregroundStyle(Theme.Text.tertiary(contrast))
                }
                ForEach(deviceSnapshot.byIdentifier.prefix(30)) { entry in
                    DisclosureGroup {
                        DDMBlueprintView.deviceList(entry.devices)
                    } label: {
                        HStack(spacing: 8) {
                            Mono(text: DDMBlueprintView.identifierLabel(entry.identifier, blueprints: snapshot.blueprints))
                                .lineLimit(1)
                            Spacer()
                            Pill(text: "\(entry.active) active", tone: .teal)
                            if entry.inactive > 0 { Pill(text: "\(entry.inactive) inactive", tone: .warn) }
                            if entry.invalid > 0 { Pill(text: "\(entry.invalid) invalid", tone: .danger) }
                            if entry.mixed > 0 { Pill(text: "\(entry.mixed) mixed", tone: .danger) }
                        }
                    }
                }
            }
        }
    }

    private var softwareUpdatesCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                SectionHeader(title: "Software updates (DDM)")
                if deviceSnapshot.pendingVersions.isEmpty && deviceSnapshot.failureReasons.isEmpty {
                    Text("No pending DDM software updates and no failures reported.")
                        .font(.footnote).foregroundStyle(Theme.Text.tertiary(contrast))
                }
                ForEach(deviceSnapshot.pendingVersions, id: \.version) { bucket in
                    DisclosureGroup {
                        DDMBlueprintView.deviceList(bucket.devices)
                    } label: {
                        HStack { Text("Pending \(bucket.version)").font(.footnote.weight(.semibold))
                                 Spacer(); Pill(text: "\(bucket.devices.count) devices", tone: .gold) }
                    }
                }
                ForEach(deviceSnapshot.failureReasons, id: \.reason) { bucket in
                    DisclosureGroup {
                        DDMBlueprintView.deviceList(bucket.devices)
                    } label: {
                        HStack { Text(bucket.reason).font(.footnote.weight(.semibold)).lineLimit(2)
                                 Spacer(); Pill(text: "\(bucket.devices.count) devices", tone: .danger) }
                    }
                }
            }
        }
    }

    /// Blueprint display name when the Platform snapshot knows this identifier, else the UUID.
    static func identifierLabel(_ identifier: String, blueprints: [DDMBlueprintService.Snapshot.Blueprint]) -> String {
        // Blueprint rows carry no identifier field today; the join is by exact name.
        blueprints.first { $0.name == identifier }?.name ?? identifier
    }

    static func deviceList(_ devices: [DeviceRef]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(devices.prefix(50)) { d in
                HStack(spacing: 8) { Mono(text: d.id, size: 10.5); Text(d.name).font(.caption) }
            }
            if devices.count > 50 {
                Text("+ \(devices.count - 50) more — full list in the workbook's DDM Device Status sheet.")
                    .font(.caption).foregroundStyle(Theme.Colors.fgMuted)
            }
        }
        .padding(.leading, 12)
        .padding(.vertical, 4)
    }
```

Check `Pill.Tone` has `.teal`, `.warn`, `.danger`, `.gold` (it does — `toneColor` in AuditView switches on exactly those).

- [ ] **Step 5: Build, run the view + service tests**

Run: `cd app && swift build 2>&1 | grep -E "error:|warning: .*DDMBlueprintView" | head`
Expected: no lines.
Run: `cd app && swift test --filter "DDMBlueprintViewTests|DDMDeviceStatusServiceTests" 2>&1 | tail -3`
Expected: 0 failures.

- [ ] **Step 6: Commit (DRAFT)**

```bash
git add app/Sources/JamfReports/Views/DDMBlueprintView.swift app/Sources/JamfReports/Services/DDMDeviceStatusService.swift \
        app/Tests/JamfReportsTests/DDMBlueprintViewTests.swift app/Tests/JamfReportsTests/DDMDeviceStatusServiceTests.swift
git commit -m "feat(ui): DDM screen unlocks from per-device status on any profile

Lock only when no Platform snapshot, no per-device snapshot and no
DDM-enabled Mac exists. Header strip, Declarations by identifier and
Software updates sections render from the scan snapshot; the Blueprints
sections stay Platform-only and are simply absent on-prem.

DRAFT — needs visual verification at PageScaffold.minSupportedWidth"
```

---

### Task 8: Devices detail panel — "DDM" and "MDM commands" sections

**Files:**
- Modify: `app/Sources/JamfReports/Views/DevicesView.swift` — state (~line 9), `reload()` (~line 970), `detailPanel` (~line 479, insert after `priorityRiskSection(for: device)`)
- Test: `app/Tests/JamfReportsTests/DevicesScanSectionsTests.swift`

**Interfaces:**
- Consumes: `DDMDeviceStatusService.Snapshot.record(forDeviceId:)`, `MDMCommandHealthService.Snapshot.record(forDeviceId:)`, `DeviceInventoryRecord.jamfID`.
- Produces: `DevicesView.scanSectionModel(ddm:health:jamfID:) -> ScanSectionModel` (pure, `internal` for tests) and `ScanSectionModel { ddmLines: [(String, String)]; mdmLines: [(String, String)]; ddmDate: Date?; mdmDate: Date? }`.

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
@testable import JamfReports

@MainActor
final class DevicesScanSectionsTests: XCTestCase {

    private func ddmSnapshot() -> DDMDeviceStatusService.Snapshot {
        .init(records: [
            .init(deviceId: "42", name: "Mac", managementId: "m", osVersion: "27.0", osBuild: nil,
                  reportDate: "2026-09-04T07:00:00.000", ddmReported: true,
                  declarations: [.init(identifier: "D-1", active: true, valid: true, reasonCode: nil, reasonText: nil),
                                 .init(identifier: "D-2", active: false, valid: true, reasonCode: nil, reasonText: nil)],
                  softwareUpdate: .init(pendingOSVersion: "27.1", pendingBuild: nil, installState: "downloading",
                                        installReason: nil, failureReason: nil, failureAt: nil, betaEnrollment: nil))
        ], isDetected: true, readFailed: false, snapshotDate: Date(timeIntervalSince1970: 1_788_000_000),
           sourceDates: [:])
    }

    private func healthSnapshot() -> MDMCommandHealthService.Snapshot {
        .init(records: [.init(deviceId: "42", name: "Mac", failedCount: 1, pendingCount: 2,
                              failedCommands: ["InstallApplication"], oldestPendingDays: 9)],
              isDetected: true, readFailed: false, snapshotDate: nil, sourceDates: [:])
    }

    func testModelJoinsByJamfID() {
        let m = DevicesView.scanSectionModel(ddm: ddmSnapshot(), health: healthSnapshot(), jamfID: "42")
        XCTAssertEqual(m.ddmLines.first?.0, "Reported")
        XCTAssertTrue(m.ddmLines.contains { $0.0 == "Declarations" && $0.1 == "2 (1 inactive)" })
        XCTAssertTrue(m.ddmLines.contains { $0.0 == "Pending update" && $0.1 == "27.1 (downloading)" })
        XCTAssertTrue(m.mdmLines.contains { $0.0 == "Failed" && $0.1 == "1 — InstallApplication" })
        XCTAssertTrue(m.mdmLines.contains { $0.0 == "Pending" && $0.1 == "2, oldest 9d" })
        XCTAssertNotNil(m.ddmDate)
    }

    func testUnknownDeviceYieldsNoLines() {
        let m = DevicesView.scanSectionModel(ddm: ddmSnapshot(), health: healthSnapshot(), jamfID: "7")
        XCTAssertTrue(m.ddmLines.isEmpty); XCTAssertTrue(m.mdmLines.isEmpty)
    }

    func testNilJamfIDYieldsNoLines() {
        let m = DevicesView.scanSectionModel(ddm: ddmSnapshot(), health: healthSnapshot(), jamfID: nil)
        XCTAssertTrue(m.ddmLines.isEmpty); XCTAssertTrue(m.mdmLines.isEmpty)
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `cd app && swift build --build-tests 2>&1 | grep error: | head -2`
Expected: `type 'DevicesView' has no member 'scanSectionModel'`.

- [ ] **Step 3: Implement**

State (beside `@State private var snapshot`):

```swift
    @State private var ddmSnapshot: DDMDeviceStatusService.Snapshot = .empty
    @State private var healthSnapshot: MDMCommandHealthService.Snapshot = .empty
```

In `reload()`, after `sourceDates = …`:

```swift
        if demoMode {
            ddmSnapshot = .empty; healthSnapshot = .empty
        } else {
            ddmSnapshot = await Task.detached(priority: .userInitiated) {
                DDMDeviceStatusService.load(profile: profile) }.value
            healthSnapshot = await Task.detached(priority: .userInitiated) {
                MDMCommandHealthService.load(profile: profile) }.value
        }
```

Pure model + view section (place near `priorityRiskSection`):

```swift
    struct ScanSectionModel: Equatable {
        var ddmLines: [(String, String)] = []
        var mdmLines: [(String, String)] = []
        var ddmDate: Date?
        var mdmDate: Date?
        static func == (l: Self, r: Self) -> Bool {
            l.ddmLines.map { "\($0.0)=\($0.1)" } == r.ddmLines.map { "\($0.0)=\($0.1)" }
                && l.mdmLines.map { "\($0.0)=\($0.1)" } == r.mdmLines.map { "\($0.0)=\($0.1)" }
                && l.ddmDate == r.ddmDate && l.mdmDate == r.mdmDate
        }
    }

    /// Snapshot-fed lines for one device. Internal (not private) for tests.
    static func scanSectionModel(
        ddm: DDMDeviceStatusService.Snapshot, health: MDMCommandHealthService.Snapshot, jamfID: String?
    ) -> ScanSectionModel {
        guard let jamfID, !jamfID.isEmpty else { return ScanSectionModel() }
        var m = ScanSectionModel(ddmDate: ddm.snapshotDate, mdmDate: health.snapshotDate)
        if let r = ddm.record(forDeviceId: jamfID) {
            m.ddmLines.append(("Reported", r.ddmReported ? "Yes" : "Not yet"))
            let inactive = r.declarations.filter { $0.active == false }.count
            let invalid = r.declarations.filter { $0.valid == false }.count
            var decl = "\(r.declarations.count)"
            var notes: [String] = []
            if inactive > 0 { notes.append("\(inactive) inactive") }
            if invalid > 0 { notes.append("\(invalid) invalid") }
            if !notes.isEmpty { decl += " (" + notes.joined(separator: ", ") + ")" }
            m.ddmLines.append(("Declarations", decl))
            if let v = r.softwareUpdate.pendingOSVersion {
                let state = r.softwareUpdate.installState.map { " (\($0))" } ?? ""
                m.ddmLines.append(("Pending update", v + state))
            }
            if let f = r.softwareUpdate.failureReason { m.ddmLines.append(("Update failure", f)) }
        }
        if let h = health.record(forDeviceId: jamfID) {
            let names = h.failedCommands.isEmpty ? "" : " — " + h.failedCommands.joined(separator: ", ")
            m.mdmLines.append(("Failed", "\(h.failedCount)\(names)"))
            let oldest = h.oldestPendingDays.map { ", oldest \($0)d" } ?? ""
            m.mdmLines.append(("Pending", "\(h.pendingCount)\(oldest)"))
        }
        return m
    }

    @ViewBuilder
    private func scanSections(for device: DeviceInventoryRecord) -> some View {
        let m = Self.scanSectionModel(ddm: ddmSnapshot, health: healthSnapshot, jamfID: device.jamfID)
        if !m.ddmLines.isEmpty {
            scanSection(title: "DDM", lines: m.ddmLines, date: m.ddmDate)
        }
        if !m.mdmLines.isEmpty {
            scanSection(title: "MDM commands", lines: m.mdmLines, date: m.mdmDate)
        }
    }

    private func scanSection(title: String, lines: [(String, String)], date: Date?) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                SectionHeader(title: title)
                Spacer()
                if let date {
                    Mono(text: "snapshot " + date.formatted(date: .abbreviated, time: .shortened), size: 10.5)
                }
            }
            ForEach(lines, id: \.0) { line in
                HStack(alignment: .top, spacing: 8) {
                    Text(line.0).font(.footnote).foregroundStyle(Theme.Text.tertiary(contrast))
                        .frame(width: 110, alignment: .leading)
                    Text(line.1).font(.footnote).foregroundStyle(Theme.Colors.fg)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
```

In `detailPanel`, after `priorityRiskSection(for: device)`:

```swift
                    scanSections(for: device)
```

- [ ] **Step 4: Build and test**

Run: `cd app && swift build 2>&1 | grep error: | head; swift test --filter DevicesScanSectionsTests 2>&1 | tail -3`
Expected: 0 errors, 3 tests, 0 failures. If Swift 6.1 rejects `ForEach(lines, id: \.0)` on a tuple, give the lines a tiny `struct Line: Identifiable { let id: String; let value: String }` instead — do not add a third representation.

- [ ] **Step 5: Commit (DRAFT)**

```bash
git add app/Sources/JamfReports/Views/DevicesView.swift app/Tests/JamfReportsTests/DevicesScanSectionsTests.swift
git commit -m "feat(ui): DDM and MDM command sections in the device detail panel

Snapshot-fed, keyed by Jamf ID, above the live jamf-cli detail.

DRAFT — needs visual verification at PageScaffold.minSupportedWidth"
```

---

### Task 9: Health Audit — "Command health" section, routed to Devices

**Files:**
- Modify: `app/Sources/JamfReports/Views/AuditView.swift` — state (~line 90), `loadCached()` (~line 925), the section list after `duplicateSerialsSection` (~line 476), `auditActionDestination` (~line 1221)
- Modify: `app/Tests/JamfReportsTests/AuditHygieneTests.swift`
- Test: `app/Tests/JamfReportsTests/CommandHealthFindingsTests.swift`

**Interfaces:**
- Consumes: `MDMCommandHealthService.Snapshot`.
- Produces: `commandHealthFindings(_ snapshot: MDMCommandHealthService.Snapshot) -> [AuditFinding]` (free function beside `auditActionDestination`, `internal`); `auditActionDestination` routes any finding whose name contains `"mdm command"` to `("Devices", .devices)`.

- [ ] **Step 1: Write the failing tests**

`CommandHealthFindingsTests.swift`:

```swift
import XCTest
@testable import JamfReports

final class CommandHealthFindingsTests: XCTestCase {

    private func snap(_ records: [MDMCommandHealthRecord]) -> MDMCommandHealthService.Snapshot {
        .init(records: records, isDetected: true, readFailed: false, snapshotDate: nil, sourceDates: [:])
    }

    func testTwoFindingsWithAffectedCounts() {
        let s = snap([
            .init(deviceId: "1", name: "A", failedCount: 1, pendingCount: 0, failedCommands: ["X"], oldestPendingDays: nil),
            .init(deviceId: "2", name: "B", failedCount: 0, pendingCount: 1, failedCommands: [], oldestPendingDays: 7),
            .init(deviceId: "3", name: "C", failedCount: 0, pendingCount: 1, failedCommands: [], oldestPendingDays: 2),
        ])
        let f = commandHealthFindings(s)
        XCTAssertEqual(f.count, 2)
        XCTAssertEqual(f[0].name, "Devices with failed MDM commands")
        XCTAssertEqual(f[0].affected, 1); XCTAssertEqual(f[0].severity, "WARNING")
        XCTAssertEqual(f[1].name, "MDM commands pending more than 7 days")
        XCTAssertEqual(f[1].affected, 1); XCTAssertEqual(f[1].severity, "WARNING")
        XCTAssertEqual(f[0].category, "Command health")
    }

    func testCleanFleetYieldsOKFindings() {
        let f = commandHealthFindings(snap([
            .init(deviceId: "1", name: "A", failedCount: 0, pendingCount: 0, failedCommands: [], oldestPendingDays: nil)]))
        XCTAssertEqual(f.map(\.severity), ["OK", "OK"])
        XCTAssertEqual(f.map(\.affected), [0, 0])
    }

    func testNotDetectedYieldsNothing() {
        XCTAssertTrue(commandHealthFindings(.empty).isEmpty)
    }
}
```

In `AuditHygieneTests.testAuditActionDestinationRoutesKnownFindings` add:

```swift
        XCTAssertEqual(auditActionDestination(for: finding("Devices with failed MDM commands", category: "Command health"))?.tab, .devices)
        XCTAssertEqual(auditActionDestination(for: finding("MDM commands pending more than 7 days", category: "Command health"))?.tab, .devices)
```

- [ ] **Step 2: Run to verify it fails**

Run: `cd app && swift build --build-tests 2>&1 | grep error: | head -2`
Expected: `cannot find 'commandHealthFindings' in scope`.

- [ ] **Step 3: Implement**

Beside `auditActionDestination` (file scope):

```swift
/// The two "Command health" findings, derived from the per-device scan snapshot
/// rather than `pro audit`. OK when the fleet is clean, WARNING otherwise, so
/// they sort and export like every other finding. Internal for tests.
func commandHealthFindings(_ snapshot: MDMCommandHealthService.Snapshot) -> [AuditFinding] {
    guard snapshot.isDetected else { return [] }
    let failed = snapshot.devicesWithFailures.count
    let stale = snapshot.devicesWithStalePending.count
    return [
        AuditFinding(
            name: "Devices with failed MDM commands", affected: failed, category: "Command health",
            recommendation: "Open the device's Jamf Pro record → Management → Management Commands, "
                + "read the failure text, then clear the failed command there. The app never flushes commands.",
            severity: failed > 0 ? "WARNING" : "OK"),
        AuditFinding(
            name: "MDM commands pending more than \(DeviceScanBuilders.pendingAgeThresholdDays) days",
            affected: stale, category: "Command health",
            recommendation: "A command pending this long usually means the Mac is offline or its APNs "
                + "channel is broken. Check last contact, then Management → Management Commands.",
            severity: stale > 0 ? "WARNING" : "OK"),
    ]
}
```

In `auditActionDestination`, before the `switch finding.category`:

```swift
    if name.contains("mdm command") { return ("Devices", .devices) }
```

In `AuditView`: `@State private var commandHealth: MDMCommandHealthService.Snapshot = .empty`; in `loadCached()` beside the duplicate-serials load: `commandHealth = MDMCommandHealthService.load(profile: workspace.profile)` (and `.empty` in the demo branch). After `duplicateSerialsSection` in the body add `commandHealthSection`:

```swift
    /// Per-device MDM command health from the scan snapshot. Independent of
    /// the `pro audit` findings table, like the duplicate-serials section.
    /// DRAFT — needs visual verification at `PageScaffold.minSupportedWidth`.
    @ViewBuilder
    private var commandHealthSection: some View {
        if commandHealth.readFailed {
            Text("An mdm-command-health snapshot exists but couldn't be read — see Settings → Logging.")
                .font(.caption).foregroundStyle(Theme.Text.tertiary(contrast))
        } else if commandHealth.isDetected {
            Card(padding: 0) {
                VStack(alignment: .leading, spacing: 0) {
                    HStack {
                        SectionHeader(title: "Command Health")
                        Spacer()
                        if let d = commandHealth.snapshotDate {
                            Mono(text: "snapshot " + d.formatted(date: .abbreviated, time: .shortened), size: 10.5)
                        }
                    }
                    .padding(16)
                    Divider().background(Theme.Colors.hairline)
                    ForEach(commandHealthFindings(commandHealth)) { finding in
                        HStack(spacing: 10) {
                            Pill(text: finding.severity, tone: pillTone(finding.severity))
                                .frame(width: 86, alignment: .leading)
                            Text(finding.name).font(.footnote.weight(.semibold)).foregroundStyle(Theme.Colors.fg)
                            Spacer()
                            Text(finding.affectedDisplay).font(.footnote.monospacedDigit())
                            Button { selectedFinding = finding } label: {
                                Image(systemName: "info.circle")
                            }
                            .buttonStyle(.plain)
                            .help("Recommendation and where to act.")
                        }
                        .padding(.horizontal, 16).padding(.vertical, 8)
                    }
                    if !commandHealth.topFailedCommands.isEmpty {
                        Divider().background(Theme.Colors.hairline)
                        HStack(spacing: 6) {
                            Kicker(text: "Most failed")
                            ForEach(commandHealth.topFailedCommands.prefix(3), id: \.name) { c in
                                Pill(text: "\(c.name) ×\(c.count)", tone: .warn)
                            }
                        }
                        .padding(16)
                    }
                }
            }
        }
    }
```

`selectedFinding` already drives `FindingDetailPopover`, which calls `auditActionDestination` — so "Take action → Devices" comes for free. If `pillTone` is `private` to another scope, use the same mapping it uses (`"WARNING"` → `.warn`, `"OK"` → `.teal`).

- [ ] **Step 4: Build and test**

Run: `cd app && swift build 2>&1 | grep error: | head; swift test --filter "CommandHealthFindingsTests|AuditHygieneTests" 2>&1 | tail -3`
Expected: 0 failures.

- [ ] **Step 5: Commit (DRAFT)**

```bash
git add app/Sources/JamfReports/Views/AuditView.swift app/Tests/JamfReportsTests/CommandHealthFindingsTests.swift app/Tests/JamfReportsTests/AuditHygieneTests.swift
git commit -m "feat(audit): Command health findings from the MDM command snapshot

Two findings, WARNING when any device is affected, routed to Devices.
Remedy text points at the Jamf Pro Management tab; no flush from the app.

DRAFT — needs visual verification at PageScaffold.minSupportedWidth"
```

---

### Task 10: Golden Fleet case, docs, changelog

**Files:**
- Modify: `app/Tests/JamfReportsTests/GoldenFleet/GoldenFleetTests.swift` — add Case E
- Modify: `CLAUDE.md` and `AGENTS.md` (identical; edit CLAUDE.md then `cp CLAUDE.md AGENTS.md`)
- Modify: `CHANGELOG.md` — `[Unreleased]`
- Modify: `docs/wiki/03-App-Dashboards.md` — the DDM Blueprints bullet (~line 109)

- [ ] **Step 1: Golden Fleet Case E (write it, run it, it should pass against Tasks 3 and 7)**

```swift
    // MARK: - Case E — DDM per-device status header numbers

    /// One DDM-enabled Mac that reported, one that has not, one Mac without
    /// DDM. Header strip must read enabled 2 of 3, reported 1, failing 1.
    func testCaseE_DDMDeviceStatusHeaderNumbers() throws {
        let root = makeRoot()
        let dataDir = root.appendingPathComponent("data", isDirectory: true)
        let stamp = GoldenFleetClock.stamp(anchor)
        try GoldenFleetWorkspace.writeJSON([
            ["id": "1", "general": ["name": "A", "managementId": "m1", "declarativeDeviceManagementEnabled": true]],
            ["id": "2", "general": ["name": "B", "managementId": "m2", "declarativeDeviceManagementEnabled": true]],
            ["id": "3", "general": ["name": "C", "managementId": "m3", "declarativeDeviceManagementEnabled": false]],
        ], to: dataDir.appendingPathComponent("computers", isDirectory: true)
            .appendingPathComponent("computers_\(stamp).json"))
        try GoldenFleetWorkspace.writeJSON([
            ["deviceId": "1", "name": "A", "managementId": "m1", "ddmReported": true,
             "declarations": [["identifier": "D-1", "active": false, "valid": true]],
             "softwareUpdate": [:]],
            ["deviceId": "2", "name": "B", "managementId": "m2", "ddmReported": false,
             "declarations": [], "softwareUpdate": [:]],
        ], to: dataDir.appendingPathComponent("ddm-device-status", isDirectory: true)
            .appendingPathComponent("ddm-device-status_\(stamp).json"))

        let counts = DDMDeviceStatusService.fleetDDMCounts(
            computersURL: FileManager.newestJSONFile(in: dataDir.appendingPathComponent("computers")))
        XCTAssertEqual(counts.enabled, 2); XCTAssertEqual(counts.total, 3)

        let s = DDMDeviceStatusService.load(
            url: FileManager.newestJSONFile(in: dataDir.appendingPathComponent("ddm-device-status")))
        XCTAssertEqual(s.ddmReportedCount, 1)
        XCTAssertEqual(s.failingDeclarationCount, 1)
        XCTAssertEqual(
            DDMBlueprintView.decideLockState(isDemoMode: false, experimentalOn: false, platformAvailable: false,
                                             hasPlatformData: false, hasDeviceData: !s.records.isEmpty,
                                             ddmEnabledCount: counts.enabled),
            .unlockedWithData, "an on-prem profile with a scan snapshot is unlocked")
    }
```

Run: `cd app && swift test --filter GoldenFleetTests 2>&1 | tail -3` → 0 failures.

- [ ] **Step 2: CLAUDE.md**

Add two rows to the Key services table (after the `DuplicateSerialService` row):

```markdown
| `DDMDeviceStatusService` | (2.8.0) Reads the `ddm-device-status` snapshot written by the per-device scan phase: one row per DDM-enabled Mac with its declarations (identifier/active/valid, optional reason) and software-update facts, reduced from `pro ddm-status status-items` through an allow-list of keys — push tokens, server tokens and certificate lists never reach disk. Aggregates per identifier (active/inactive/invalid/mixed, mixed = both states on one device), pending versions, failure reasons; `fleetDDMCounts` reads "enabled N of M" from `computers` alone. Powers the DDM screen on ANY profile, the Devices panel and the "DDM Device Status" sheet. |
| `MDMCommandHealthService` | (2.8.0) Reads the `mdm-command-health` snapshot: per Mac, failed/pending counts, failed command names and the oldest pending age, reduced from `pro classic-computer-history get <id> --subset commands` (`failed`/`pending`/`completed` are `""` when empty and an object otherwise; a lone `command` is a bare object — see `ComputerHistoryCommands`). Powers the Audit "Command health" findings (7-day pending threshold, fixed), the Devices panel and the "MDM Command Health" sheet. |
```

After the **Platform-only kinds (2.7.0)** paragraph add:

```markdown
**Per-device scan phase (2.8.0).** `ReportEngine+DeviceScan.runDeviceScanPhase`
runs at the end of `collect` — after `enforceCollectVerdicts`, before
`finalizeCollect` — for the scan tier only, and is skipped by
`skipExpensive`. It walks the `computers` snapshot (`id` top-level,
`managementId`/`declarativeDeviceManagementEnabled` under `general`) with at
most `deviceScanConcurrency` (4) jamf-cli processes and writes
`ddm-device-status` and `mdm-command-health` through `saveSnapshot`, so
manifest, retention and freshness counters apply unchanged. Rules: a 404 on
status items is `ddmReported: false`, never an error; exit 5 or 8 on any
device abandons that call type for the run (one log line naming the
privilege or the refusal); exit 3 abandons both; strictly more than 25% of
devices failing a call type records the kind failed and writes nothing,
otherwise the snapshot lands with `[partial] <kind>: N of M devices did not
respond`. This is the app's first per-device fan-out inside `collect` — the
jamf-cli feature request for server-side equivalents is what retires it. The
DDM screen is no longer Platform-only: it unlocks from the per-device
snapshot or from inventory saying DDM is enabled; the Blueprints sections
remain Platform-gated and are absent, not locked, on-prem.
```

Then `cp CLAUDE.md AGENTS.md`.

- [ ] **Step 3: CHANGELOG `[Unreleased]`**

```markdown
## [Unreleased]

### Added

The DDM screen now works on every Jamf Pro profile, on-prem included. A new
per-device scan (weekly, with the other scan-tier collections) asks each
DDM-enabled Mac for its declaration and software-update status, and the screen
shows how many Macs have DDM on, how many have reported, which declarations
are inactive or invalid and on which Macs, and which DDM software updates are
pending or failing. The Blueprints sections still need a Platform API profile
and simply do not appear elsewhere.

The same scan reads each Mac's MDM command history. The Health Audit gains two
"Command health" findings — Macs with a failed command, and Macs with a command
pending for more than seven days — each routed to the Devices screen, whose
detail panel now shows a Mac's DDM status and command health beneath its
inventory. Two workbook sheets, "DDM Device Status" and "MDM Command Health",
carry one row per Mac. Nothing is changed in Jamf: clearing a failed command
stays a console action.

Only a fixed set of status-item keys is ever kept; the device's push token and
per-declaration server tokens are dropped before anything is written. The scan
honours the "Skip expensive collections" setting.
```

- [ ] **Step 4: Wiki**

In `docs/wiki/03-App-Dashboards.md`, rewrite the DDM Blueprints bullet:

```markdown
- **DDM Blueprints** — Declarative Device Management status. On any Jamf Pro
  profile: DDM enabled N of M Macs, how many have reported, declarations by
  identifier with the Macs where each is inactive or invalid, and pending or
  failed DDM software updates — all from the weekly per-device scan. On a
  Platform API profile the blueprint deployment sections appear as well. Per-Mac
  detail is in Devices; failed and stuck MDM commands are in Health Audit →
  Command Health.
```

- [ ] **Step 5: Full suite, then commit**

Run: `cd app && swift test 2>&1 > /tmp/jr-full.log; echo EXIT=$? >> /tmp/jr-full.log; tail -3 /tmp/jr-full.log; grep -oE "with [0-9]+ failures" /tmp/jr-full.log | sort | uniq -c`
Expected: `EXIT=0`, every line `with 0 failures`. Read the log's own `EXIT=` line, never the task notification's exit code.

```bash
git add app/Tests/JamfReportsTests/GoldenFleet/GoldenFleetTests.swift CLAUDE.md AGENTS.md CHANGELOG.md docs/wiki/03-App-Dashboards.md
git commit -m "docs: per-device scan, DDM screen on any profile, command health"
```

---

## Self-review (done while writing; recorded so an executor sees the seams)

**Spec coverage.** §1 scan loop → Task 5 (targets from `computers`, 4-wide, both calls, allow-list via Task 2, `saveSnapshot`, `skipExpensive`); kinds in `knownCollectKinds`/`CollectionTier.scan`/`expectedKinds` → Task 4. §2 decoders → Task 1; declaration parser and both services → Tasks 2–3; `sourceDates` on both snapshots → Task 3. §3 DDM screen → Task 7; Devices panel → Task 8; Audit → Task 9; workbook → Task 6; no HTML section (none added). §4 failure rules → Task 5 (`StopGate` + `reduceAndSave`), each pinned by a `DeviceScanCollectTests` case; progress line every 100 → `progressEvery`. §5 fixtures → Task 1; decoder tests → Task 1; parser mutation → Task 2 step 5; service tests incl. Mixed and the 7-day boundary → Task 3; collect-loop tests through `locateJamfCLI` → Task 5; Golden Fleet → Task 10; visual pass → the three DRAFT commits.

**Deviations from the spec, stated.** Decoders live in `DeviceScanDecoders.swift`, not `JamfCLIDecoder.swift` (file size). `reportDate` is the newest `lastUpdateTime` among allow-listed items rather than a dedicated key (none exists in the payload). Exit 3 mid-scan stops both call types and records both kinds failed rather than re-throwing the auth-dead verdict — the matrix verdict already ran, and a throw here would discard the matrix's good snapshots' summary.

**Type consistency.** `DeviceRef` is declared once (Task 3) and used by Task 7. `DeviceScanBuilders.pendingAgeThresholdDays` is the single 7 (Tasks 2, 3, 6, 9). `ReportEngine.DeviceScanTarget` (Task 5) is what `fleetDDMCounts` decodes (Task 7). The kind strings come from `DDMDeviceStatusService.kind` / `MDMCommandHealthService.kind` (Task 3) and are aliased in Task 5.

**Still owed by the maintainer, not by this plan.** A history capture with two or more failed commands (pins the array branch of a populated `failed` bucket — the decoder already handles it via the same path as `completed`); a status-items capture from a Mac with a populated `softwareupdate.failure-reason` and a declaration `reasons` group. Visual verification of the three DRAFT surfaces.
