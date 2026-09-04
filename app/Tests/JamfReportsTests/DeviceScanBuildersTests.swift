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
        let rec = DeviceScanBuilders.ddmRecord(
            deviceId: "7", name: "Mac", managementId: "m", payload: payload)
        let encoded = String(decoding: try JSONEncoder().encode(rec), as: UTF8.self)
        XCTAssertFalse(encoded.contains("push-token"))
        XCTAssertFalse(encoded.contains("push-magic"))
        XCTAssertFalse(encoded.contains("server-token"))
        XCTAssertFalse(encoded.contains("content-cache"))
        XCTAssertTrue(rec.ddmReported)
        XCTAssertEqual(rec.osVersion?.isEmpty, false)
        // Both allow-listed declaration keys are populated on prod, each
        // carrying one group with a distinct identifier (ruling 2).
        XCTAssertEqual(rec.declarations.count, 2)
        XCTAssertEqual(Set(rec.declarations.map(\.identifier)).count, 2,
                        "configurations and activations carry distinct identifiers")
        XCTAssertTrue(rec.declarations.allSatisfy { $0.valid == true })
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
        let rec = DeviceScanBuilders.ddmRecordNotReported(
            deviceId: "9", name: "Quiet", managementId: "m9")
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

    func testValidFieldAcceptsProdWordForm() {
        // Prod writes `valid=valid` / presumably `valid=invalid`, not a bare
        // boolean (ruling 1). `active` stays boolean.
        let validGroup = "{active=true, identifier=A, valid=valid}"
        let invalidGroup = "{active=true, identifier=B, valid=invalid}"
        let a = DeviceScanBuilders.parseDeclarations(validGroup)
        let b = DeviceScanBuilders.parseDeclarations(invalidGroup)
        XCTAssertEqual(a.count, 1)
        XCTAssertEqual(a[0].valid, true)
        XCTAssertEqual(b.count, 1)
        XCTAssertEqual(b[0].valid, false)
    }

    func testParsesSeveralGroupsAndTolerantReasons() {
        // Multi-group form INFERRED from the single observed group (spec §2);
        // the reasons sub-group shape is unobserved and parsed tolerantly.
        let raw = "{active=true, identifier=A, valid=true}, " +
                  "{active=false, identifier=B, valid=false, " +
                  "reasons={code=Error.Foo, description=bad thing}}"
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
        let h = try JSONDecoder().decode(
            ComputerHistoryCommands.self,
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
        let h = try JSONDecoder().decode(
            ComputerHistoryCommands.self,
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
        XCTAssertEqual(
            DeviceScanBuilders.healthRecord(deviceId: "1", name: "", history: h, now: now)
                .oldestPendingDays, 6)
        let now7 = issued.addingTimeInterval(7 * 86_400)      // exactly 7 → 7
        XCTAssertEqual(
            DeviceScanBuilders.healthRecord(deviceId: "1", name: "", history: h, now: now7)
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

    private func makeHistory(
        pending: [ComputerHistoryCommands.HistoryCommand]
    ) -> ComputerHistoryCommands {
        // Build through JSON so the real decoder path is exercised.
        let rows = pending.map { c -> [String: Any] in
            var d: [String: Any] = ["name": c.name ?? "", "status": c.status ?? ""]
            if let e = c.issuedEpoch { d["issued_epoch"] = e }
            return d
        }
        let obj: [String: Any] = [
            "commands": ["completed": "", "failed": "", "pending": ["command": rows]],
        ]
        let data = try! JSONSerialization.data(withJSONObject: obj)
        return try! JSONDecoder().decode(ComputerHistoryCommands.self, from: data)
    }
}
