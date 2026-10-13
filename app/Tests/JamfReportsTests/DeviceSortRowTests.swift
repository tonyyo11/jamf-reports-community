import XCTest
@testable import JamfReports

/// The Devices table's Last Check-in, Patch, Security and Risk columns sort on keys built once
/// per filter pass (#272).
final class DeviceSortRowTests: XCTestCase {

    private func mac(_ name: String, days: Int? = nil, patchFailures: Int = 0) -> DeviceInventoryRecord {
        var record = DeviceInventoryRecord.empty(id: "serial:\(name)", source: "computers.json")
        record.name = name
        record.serial = name
        record.daysSinceContact = days
        record.patchFailures = (0..<patchFailures).map { index in
            DevicePatchFailure(
                title: "Title \(index)", status: "failed", date: "", latestVersion: "")
        }
        return record
    }

    private func names(
        _ devices: [DeviceInventoryRecord],
        by keyPath: KeyPathComparator<DeviceSortRow>,
        gaps: @escaping (DeviceInventoryRecord) -> Int = { _ in 0 },
        risk: @escaping (DeviceInventoryRecord) -> Int = { _ in 0 }
    ) -> [String] {
        DeviceSortRow.sorted(devices, using: [keyPath], securityGaps: gaps, riskScore: risk)
            .map(\.device.name)
    }

    func testAMacWithNoContactDateSortsAsTheOldest() {
        XCTAssertEqual(DeviceSortRow.contactSortKey(nil), Int.max)
        XCTAssertEqual(DeviceSortRow.contactSortKey(-3), 0)
        let devices = [mac("old", days: 90), mac("never"), mac("today", days: 0), mac("mid", days: 7)]
        XCTAssertEqual(
            names(devices, by: KeyPathComparator(\DeviceSortRow.contactDays)),
            ["today", "mid", "old", "never"])
        XCTAssertEqual(
            names(devices, by: KeyPathComparator(\DeviceSortRow.contactDays, order: .reverse)),
            ["never", "old", "mid", "today"])
    }

    func testPatchSortsByFailureCountWithTiesInNameOrder() {
        let devices = [mac("b", patchFailures: 2), mac("c"), mac("a", patchFailures: 2), mac("d", patchFailures: 5)]
        XCTAssertEqual(
            names(devices, by: KeyPathComparator(\DeviceSortRow.patchFailures)),
            ["c", "a", "b", "d"])
        XCTAssertEqual(
            names(devices, by: KeyPathComparator(\DeviceSortRow.patchFailures, order: .reverse)),
            ["d", "a", "b", "c"])
    }

    func testSecuritySortsByGapCount() {
        let gaps = ["a": 3, "b": 0, "c": 1]
        let devices = [mac("a"), mac("b"), mac("c")]
        XCTAssertEqual(
            names(devices, by: KeyPathComparator(\DeviceSortRow.securityGaps, order: .reverse),
                  gaps: { gaps[$0.name] ?? 0 }),
            ["a", "c", "b"])
    }

    func testRiskSortsWorstFirstWhenDescendingAndTiesKeepNameOrder() {
        let scores = ["a": 12, "b": 22, "c": 12, "d": 0]
        let devices = [mac("c"), mac("d"), mac("b"), mac("a")]
        let descending = names(
            devices, by: KeyPathComparator(\DeviceSortRow.riskScore, order: .reverse),
            risk: { scores[$0.name] ?? 0 })
        XCTAssertEqual(descending, ["b", "a", "c", "d"])
        let levels = descending.compactMap { scores[$0] }.map(DeviceRisk.Level.from(score:))
        XCTAssertEqual(levels, levels.sorted(by: >))
    }

    func testTheScorerRunsOnlyWhenRiskIsTheSortColumn() {
        var scored = 0
        _ = DeviceSortRow.sorted(
            [mac("a"), mac("b")], using: [KeyPathComparator(\DeviceSortRow.device.displayName)],
            securityGaps: { _ in scored += 1; return 0 }, riskScore: { _ in scored += 1; return 0 })
        XCTAssertEqual(scored, 0)
        _ = DeviceSortRow.sorted(
            [mac("a"), mac("b")], using: [KeyPathComparator(\DeviceSortRow.riskScore)],
            securityGaps: { _ in 0 }, riskScore: { _ in scored += 1; return 0 })
        XCTAssertEqual(scored, 2)
    }
}
