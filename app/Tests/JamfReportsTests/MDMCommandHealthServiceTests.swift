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
