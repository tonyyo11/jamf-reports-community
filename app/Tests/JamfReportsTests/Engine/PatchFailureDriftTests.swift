import XCTest
@testable import JamfReports

/// Patch policy failures between two scans: started failing, no longer listed, and the
/// counts of rows that cannot be compared.
final class PatchFailureDriftTests: XCTestCase {

    private func row(_ device: String, _ policy: String, attempt: Int = 1) -> PatchFailureRow {
        PatchFailureRow(policy: "Policy \(policy)", policyId: policy, device: "Mac-\(device)",
                        deviceId: device, statusDate: "", attempt: attempt, lastAction: "",
                        serial: "", osVersion: "", username: "")
    }

    private let fleet = ComputerDateIndex([ComputerDates(jamfID: "1"), ComputerDates(jamfID: "2"),
                                           ComputerDates(jamfID: "10")])

    func testStartedAndNoLongerListed() {
        let drift = PatchFailureDrift(
            current: [row("10", "5"), row("2", "5"), row("1", "9", attempt: 4)],
            baseline: [row("1", "9", attempt: 2), row("1", "5")], computers: fleet)
        XCTAssertEqual(drift.startedFailing.map(\.deviceId), ["2", "10"], "numeric order")
        XCTAssertEqual(drift.noLongerListed.map(\.policyId), ["5"])
        XCTAssertEqual(drift.leftOut, 0)
        XCTAssertEqual(drift.notInComputers, 0)
    }

    func testRepeatedKeyKeepsTheFirstRow() {
        var second = row("1", "5")
        second = PatchFailureRow(policy: "Second", policyId: "5", device: "Mac-1", deviceId: "1",
                                 statusDate: "", attempt: 1, lastAction: "", serial: "",
                                 osVersion: "", username: "")
        let drift = PatchFailureDrift(
            current: [row("1", "5"), second], baseline: [], computers: fleet)
        XCTAssertEqual(drift.startedFailing.map(\.policy), ["Policy 5"])
    }

    func testEmptyIDsAreLeftOutOnBothSides() {
        let drift = PatchFailureDrift(
            current: [row("", "5"), row("1", " ")], baseline: [row("2", "")], computers: fleet)
        XCTAssertEqual(drift.leftOut, 3)
        XCTAssertTrue(drift.startedFailing.isEmpty)
        XCTAssertTrue(drift.noLongerListed.isEmpty)
    }

    func testDroppedPairWhoseMacIsGone() {
        let drift = PatchFailureDrift(
            current: [], baseline: [row("99", "5"), row("2", "5")], computers: fleet)
        XCTAssertEqual(drift.noLongerListed.map(\.deviceId), ["2"])
        XCTAssertEqual(drift.notInComputers, 1)
    }

    func testPairAndLoad() throws {
        let root = GoldenFleetWorkspace.freshRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let anchor = GoldenFleetClock.anchorNoon()
        func at(_ day: Int, hour: Int = 12) -> Date {
            GoldenFleetClock.timestamp(dayOffset: day, hour: hour, minute: 0, relativeTo: anchor)
        }
        let dataDir = root.appendingPathComponent("data", isDirectory: true)
        let rows: [[String: Any]] = [["policy_id": "5", "device_id": "1", "attempt": "2"]]
        let old = try GoldenFleetWorkspace.writeSnapshot(
            kind: "patch-device-failures", dataDir: dataDir, at: at(-7), rows: [])
        _ = try GoldenFleetWorkspace.writeSnapshot(
            kind: "patch-device-failures", dataDir: dataDir, at: at(0, hour: 8), rows: [])
        let landed = try GoldenFleetWorkspace.writeSnapshot(
            kind: "patch-device-failures", dataDir: dataDir, at: at(0), rows: rows)
        let pair = try XCTUnwrap(PatchFailureDrift.pair(dataDir: dataDir, landedStamp: at(0)))
        XCTAssertEqual(pair.baseline.lastPathComponent, old.lastPathComponent)
        XCTAssertEqual(pair.current.lastPathComponent, landed.lastPathComponent)
        XCTAssertNil(PatchFailureDrift.pair(dataDir: dataDir, landedStamp: at(3)))
        let drift = try XCTUnwrap(PatchFailureDrift.load(
            current: pair.current, baseline: pair.baseline, dataDir: dataDir, computers: fleet))
        XCTAssertEqual(drift.startedFailing.count, 1)

        try Data("{bad".utf8).write(to: old)
        XCTAssertNil(PatchFailureDrift.load(
            current: pair.current, baseline: pair.baseline, dataDir: dataDir, computers: fleet))
    }
}
