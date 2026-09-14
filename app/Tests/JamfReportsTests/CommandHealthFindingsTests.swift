import XCTest
@testable import JamfReports

final class CommandHealthFindingsTests: XCTestCase {

    private func snap(_ records: [MDMCommandHealthRecord]) -> MDMCommandHealthService.Snapshot {
        .init(records: records, isDetected: true, readFailed: false,
              snapshotDate: nil, sourceDates: [:])
    }

    func testTwoFindingsWithAffectedCounts() {
        let s = snap([
            .init(deviceId: "1", name: "A", failedCount: 1, pendingCount: 0,
                  failedCommands: ["X"], oldestPendingDays: nil),
            .init(deviceId: "2", name: "B", failedCount: 0, pendingCount: 1,
                  failedCommands: [], oldestPendingDays: 7),
            .init(deviceId: "3", name: "C", failedCount: 0, pendingCount: 1,
                  failedCommands: [], oldestPendingDays: 2),
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
            .init(deviceId: "1", name: "A", failedCount: 0, pendingCount: 0,
                  failedCommands: [], oldestPendingDays: nil)]))
        XCTAssertEqual(f.map(\.severity), ["OK", "OK"])
        XCTAssertEqual(f.map(\.affected), [0, 0])
    }

    func testNotDetectedYieldsNothing() {
        XCTAssertTrue(commandHealthFindings(.empty).isEmpty)
    }
}
