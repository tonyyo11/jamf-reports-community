import XCTest
@testable import JamfReports

/// A snapshot refused for its size is unreadable, not absent: the report that leaves its data
/// out names it and its size instead of saying no snapshot was found.
final class SnapshotSizeRefusalTests: XCTestCase {

    private var data: URL!

    private final class Lines: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: [String] = []
        func add(_ line: CLIBridge.LogLine) { lock.withLock { stored.append(line.text) } }
        var all: [String] { lock.withLock { stored } }
    }

    override func setUpWithError() throws {
        try super.setUpWithError()
        data = FileManager.default.temporaryDirectory
            .appendingPathComponent("jrc-size-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: data.appendingPathComponent("ea-results"), withIntermediateDirectories: true)
        BoundedFile.resetSizeRefusals()
    }

    override func tearDownWithError() throws {
        BoundedFile.resetSizeRefusals()
        try? FileManager.default.removeItem(at: data)
        try super.tearDownWithError()
    }

    func testARefusedSnapshotIsNamedWithItsSizeNotCalledMissing() throws {
        let file = data.appendingPathComponent("ea-results/ea-results_20261117T120000.json")
        try Data(count: 3 * 1_048_576).write(to: file)
        let missing = CoreDashboardError.noCachedData(names: ["ea-results", "ea_results"])
        XCTAssertEqual(
            missing.skipReason, "No cached jamf-cli snapshot found for: ea-results, ea_results")

        XCTAssertNil(BoundedFile.readSnapshotLogged(file, limit: 2 * 1_048_576))
        XCTAssertEqual(
            BoundedFile.allSizeRefusals,
            [BoundedFile.SizeRefusal(kind: "ea-results", megabytes: 3, limitMegabytes: 2)])
        XCTAssertEqual(
            missing.skipReason,
            "the ea-results snapshot is 3 MB, over the 2 MB this Mac reads; left out")
        XCTAssertEqual(
            CoreDashboardError.noCachedData(names: ["security"]).skipReason,
            "No cached jamf-cli snapshot found for: security", "another kind is still missing")

        let lines = Lines()
        ReportEngine.reportSizeRefusals(artifact: "tabs", onLine: lines.add)
        XCTAssertEqual(lines.all, [
            "[warn] the ea-results snapshot is 3 MB, over the 2 MB this Mac reads: "
                + "the tabs that use it are left out",
        ])

        BoundedFile.resetSizeRefusals()
        XCTAssertNotNil(BoundedFile.readSnapshotLogged(file, limit: 4 * 1_048_576))
        XCTAssertEqual(BoundedFile.allSizeRefusals, [], "a file inside the limit is no refusal")
        XCTAssertEqual(
            missing.skipReason, "No cached jamf-cli snapshot found for: ea-results, ea_results")
    }

    func testAMissingFileIsNotARefusal() {
        XCTAssertNil(BoundedFile.readSnapshotLogged(
            data.appendingPathComponent("ea-results/none.json"), limit: 10))
        XCTAssertEqual(BoundedFile.allSizeRefusals, [])
    }

    /// Their rows grow with the fleet, so they read under the inventory limit.
    func testThePerDeviceScanKindsUseTheInventoryLimit() {
        for kind in ["ddm-device-status", "mdm-command-health", "school-device-detail"] {
            XCTAssertEqual(BoundedFile.limit(forKind: kind), BoundedFile.inventoryLimit, kind)
        }
        XCTAssertEqual(BoundedFile.limit(forKind: "policies"), BoundedFile.snapshotLimit)
    }
}
