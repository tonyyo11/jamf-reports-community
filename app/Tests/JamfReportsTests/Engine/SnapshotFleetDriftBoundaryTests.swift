import XCTest
@testable import JamfReports

/// Fleet Drift, patch-failure and benchmark-rule edges the 2.13 mutation sweep left unpinned.
/// Every Mac is invented.
final class SnapshotFleetDriftBoundaryTests: XCTestCase {

    private let taken = Date(timeIntervalSince1970: 1_790_000_000)
    private var before: Date { taken.addingTimeInterval(-86_400) }
    private let rule = StaleRule(days: 30)

    private func mac(_ id: Int?, checkIn: Date? = nil, inventory: Date? = nil, os: String? = nil,
                     fileVault: String? = nil, hardware: Bool? = nil) -> ComputerDates {
        ComputerDates(jamfID: id.map(String.init), checkIn: checkIn, inventory: inventory,
                      name: "Mac-\(id ?? 0)", osVersion: os, fileVault: fileVault,
                      hardwareEncrypted: hardware)
    }

    private func macs(_ ids: ClosedRange<Int>) -> [ComputerDates] {
        ids.map { mac($0, checkIn: taken) }
    }

    private func drift(_ current: [ComputerDates], _ prior: [ComputerDates]) -> SnapshotFleetDrift {
        SnapshotFleetDrift(current: current, currentAt: taken, prior: prior, priorAt: before,
                           rule: rule)
    }

    // MARK: - Large change

    func testNothingMovedIsNoLargeChangeWhateverTheCounts() {
        let unidentified = (0..<20).map { _ in mac(nil, checkIn: taken) }
        XCTAssertNil(drift(macs(1...10) + unidentified, macs(1...10)).largeChangePercent)
    }

    func testExactlyAQuarterMovedIsNotLarge() {
        XCTAssertNil(drift(macs(11...90), macs(1...80)).largeChangePercent, "20 of 80 moved")
    }

    func testAFleetOfTwentyThatLostMoreThanHalfIsLarge() {
        XCTAssertEqual(drift(macs(1...9), macs(1...20)).largeChangePercent, 55)
        XCTAssertNil(drift(macs(1...10), macs(1...20)).largeChangePercent, "exactly half is not")
    }

    // MARK: - Identity

    func testAJoinedMacIsNotAmbiguousAndUnidentifiedCountsBothSides() {
        let result = drift([mac(1), mac(2), mac(nil)], [mac(1), mac(nil), mac(nil)])
        XCTAssertEqual(result.ambiguous, 0)
        XCTAssertEqual(result.joined.map(\.jamfID), ["2"])
        XCTAssertEqual(result.unidentified, 3)
    }

    // MARK: - Stale comparison

    func testStaleIsComparedWithAnEmptySideOrInventoryDatesOnly() {
        XCTAssertFalse(drift(macs(1...2), []).staleNotCompared)
        XCTAssertFalse(drift([mac(1, inventory: taken)], [mac(1, inventory: before)])
            .staleNotCompared)
        XCTAssertTrue(drift(macs(1...2), [mac(1), mac(2)]).staleNotCompared,
                      "the earlier snapshot has no dates")
    }

    func testExactlyTheThresholdIsNotStale() {
        let lastSeen = taken.addingTimeInterval(-30 * 86_400 - 3_600)
        let result = drift([mac(1, checkIn: lastSeen)], [mac(1, checkIn: lastSeen)])
        XCTAssertTrue(result.becameStale.isEmpty, "30 days is not more than 30")
    }

    // MARK: - OS

    func testAnOSAppearingOrRespelledIsNoChange() {
        let result = drift([mac(1, checkIn: taken, os: "15.1"), mac(2, checkIn: taken, os: "26.7.0"),
                            mac(3, checkIn: taken, os: "26.7")],
                           [mac(1, checkIn: before), mac(2, checkIn: before, os: "26.7"),
                            mac(3, checkIn: before, os: "26.7.0")])
        XCTAssertTrue(result.osChanged.isEmpty)
    }

    // MARK: - FileVault

    func testFileVaultIsNotComparedWhenOnlyTheCurrentSnapshotReportsIt() {
        let result = drift([mac(1, checkIn: taken, fileVault: "UNENCRYPTED")], [mac(1, checkIn: before)])
        XCTAssertNil(result.fileVaultOff)
        XCTAssertNil(result.fileVaultStoppedReporting)
    }

    func testAWarningThatBecomesAGapOrGoesQuietIsAChange() {
        let policy = SecurityControlPolicy(fileVaultOffHardwareEncrypted: .warning)
        let warning = mac(1, fileVault: "UNENCRYPTED", hardware: true)
        XCTAssertEqual(SnapshotFleetDrift.fileVaultChange(
            from: warning, to: mac(1, fileVault: "UNENCRYPTED", hardware: false), policy: policy),
            .turnedOff)
        XCTAssertEqual(SnapshotFleetDrift.fileVaultChange(
            from: warning, to: mac(1, hardware: true), policy: policy), .stoppedReporting)
    }

    // MARK: - Patch policy failures

    private func failure(_ device: String, _ policy: String) -> PatchFailureRow {
        PatchFailureRow(policy: "Policy \(policy)", policyId: policy, device: "Mac-\(device)",
                        deviceId: device, statusDate: "", attempt: 1, lastAction: "",
                        serial: "", osVersion: "", username: "")
    }

    func testPatchKeysAndTheComputersCheckTrimTheIDs() {
        let index = ComputerDateIndex([mac(5)])
        let same = PatchFailureDrift(current: [failure(" 5", "1")], baseline: [failure("5", "1")],
                                     computers: index)
        XCTAssertTrue(same.startedFailing.isEmpty && same.noLongerListed.isEmpty)
        let dropped = PatchFailureDrift(current: [], baseline: [failure(" 5 ", "1")], computers: index)
        XCTAssertEqual(dropped.noLongerListed.count, 1)
        XCTAssertEqual(dropped.notInComputers, 0)
    }

    func testPatchChangesSortByDeviceThenPolicy() {
        let result = PatchFailureDrift(current: [failure("2", "1"), failure("1", "2")], baseline: [],
                                       computers: ComputerDateIndex([]))
        XCTAssertEqual(result.startedFailing.map(\.deviceId), ["1", "2"])
    }

    // MARK: - Benchmark rules

    private func rule(_ id: String, failed: Int) -> BenchmarkRuleDrift.Rule {
        .init(rule: "Rule \(id)", passed: 1, failed: failed, unknown: 0, devices: 2, passRate: "",
              ruleId: id, benchmark: "CIS")
    }

    func testNewlyFailingRulesAreSortedByID() {
        let result = BenchmarkRuleDrift(current: [rule("b", failed: 1), rule("a", failed: 2)],
                                        baseline: [rule("b", failed: 0), rule("a", failed: 0)])
        XCTAssertEqual(result.newlyFailing.map(\.ruleId), ["a", "b"])
    }
}
