import XCTest
@testable import JamfReports

/// The one FileVault reader for the Computers screen, the security sheet and Fleet Drift.
final class FileVaultValueTests: XCTestCase {

    private func item(
        partition: Any? = nil, status: Any? = nil, enabled: Any? = nil
    ) -> [String: Any] {
        var disk: [String: Any] = [:]
        if let partition { disk["bootPartitionEncryptionDetails"] = ["partitionFileVault2State": partition] }
        if let enabled { disk["fileVault2Enabled"] = enabled }
        var item: [String: Any] = ["diskEncryption": disk]
        if let status { item["operatingSystem"] = ["fileVault2Status": status] }
        return item
    }

    func testChainOrderAndTrimming() {
        XCTAssertEqual(FileVaultValue.raw(computer: item(
            partition: " ENCRYPTED ", status: "ALL_ENCRYPTED", enabled: false)), "ENCRYPTED")
        XCTAssertEqual(FileVaultValue.raw(computer: item(
            partition: "  ", status: "ALL_ENCRYPTED", enabled: false)), "ALL_ENCRYPTED")
        XCTAssertEqual(FileVaultValue.raw(computer: item(status: "", enabled: true)), "true")
        XCTAssertNil(FileVaultValue.raw(computer: item()))
        XCTAssertNil(FileVaultValue.raw(computer: [:]))
    }

    /// The shapes the old `first`/`clean` chain read, each with the value it gave.
    func testShapesMatchTheOldChain() throws {
        let cases: [(Any, String)] = [
            ("UNENCRYPTED", "UNENCRYPTED"), (true, "true"), (false, "false"),
            (NSNumber(value: 1), "true"), (NSNumber(value: 0), "false"),
            (NSNumber(value: 2), "2"), ("1", "1"), ("0", "0"),
        ]
        for (value, expected) in cases {
            for shaped in [item(partition: value), item(status: value), item(enabled: value)] {
                XCTAssertEqual(FileVaultValue.raw(computer: shaped), expected, "\(value)")
            }
        }
        // From JSON, as a snapshot arrives: 0/1 numbers bridge as the old chain read them.
        let json = Data(#"{"diskEncryption":{"fileVault2Enabled":1}}"#.utf8)
        let decoded = try XCTUnwrap(JSONSerialization.jsonObject(with: json) as? [String: Any])
        XCTAssertEqual(FileVaultValue.raw(computer: decoded), "true")
    }

    func testSheetCellMapsOnlyTheEnabledFlag() {
        XCTAssertEqual(CoreDashboard.fileVaultCell("true"), "ENCRYPTED")
        XCTAssertEqual(CoreDashboard.fileVaultCell("0"), "UNENCRYPTED")
        XCTAssertEqual(CoreDashboard.fileVaultCell("1"), "ENCRYPTED")
        XCTAssertEqual(CoreDashboard.fileVaultCell("ALL_ENCRYPTED"), "ALL_ENCRYPTED")
    }

    /// `on_values` of "true"/"false" judge the raw value the sheet now keeps.
    func testOnValuesJudgeTheRawValue() {
        let policy = SecurityControlPolicy(offValues: [.fileVault: ["true"]])
        XCTAssertEqual(policy.verdict(for: .fileVault, value: "true", hardwareEncrypted: nil),
                       .fail)
    }

    func testComputerDatesCarryFileVault() {
        var computer = item(status: "ALL_ENCRYPTED")
        computer["general"] = ["name": "Mac-1", "lastCheckIn": "2026-11-01T00:00:00Z",
                               "reportDate": "2026-11-01T00:00:00Z"]
        computer["operatingSystem"] = ["fileVault2Status": "ALL_ENCRYPTED", "version": "26.1"]
        XCTAssertEqual(ComputerDates(item: computer).fileVault, "ALL_ENCRYPTED")
        XCTAssertTrue(ComputerSnapshot(rows: [ComputerDates(item: computer)]).fileVaultReported)
        XCTAssertFalse(ComputerSnapshot(rows: [ComputerDates(jamfID: "1")]).fileVaultReported)
    }
}
