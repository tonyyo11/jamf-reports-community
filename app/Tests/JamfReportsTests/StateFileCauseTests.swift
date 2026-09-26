import XCTest
@testable import JamfReports

/// `state/<kind>.cause.json` (spec 2026-09-12 §9.3): the newest failure's cause, gone once the
/// kind lands, never in the integrity manifest.
final class StateFileCauseTests: XCTestCase {

    private var tempDir: URL!
    private var store: StateFileStore!
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("sfc-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        store = StateFileStore(directory: tempDir)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
        try super.tearDownWithError()
    }

    private let permission = FailureCause(
        kind: .missingPermission, names: ["Inventory > Devices: Read (devices:read)"],
        hint: "grant the Jamf Platform API integration these permissions", exitCode: 5)

    func testAFailureStoresItsCauseAndDate() throws {
        store.record(.failed(exitCode: 5), report: "security", at: t0, cause: permission)
        let stored = try XCTUnwrap(store.cause(for: "security"))
        XCTAssertEqual(stored.kind, .missingPermission)
        XCTAssertEqual(stored.names, permission.names)
        XCTAssertEqual(stored.recordedAt, t0)
        XCTAssertEqual(store.failures(report: "security")?.count, 1)
    }

    func testLandingDeletesTheCause() {
        store.record(.failed(exitCode: 5), report: "security", at: t0, cause: permission)
        store.record(.landed, report: "security", at: t0.addingTimeInterval(60))
        XCTAssertNil(store.cause(for: "security"))
    }

    /// A launch failure has no cause; keeping the earlier one would mislabel it.
    func testAFailureWithoutACauseDropsTheStaleOne() {
        store.record(.failed(exitCode: 5), report: "security", at: t0, cause: permission)
        store.record(.failed(exitCode: nil), report: "security", at: t0.addingTimeInterval(60))
        XCTAssertNil(store.cause(for: "security"))
    }

    func testCauseFilesStayOutOfTheManifest() throws {
        store.record(.landed, report: "overview", at: t0)
        store.record(.failed(exitCode: 5), report: "security", at: t0, cause: permission)
        try store.rewriteManifest()
        let manifestURL = tempDir.appendingPathComponent(SnapshotManifest.fileName)
        let manifest = try String(contentsOf: manifestURL, encoding: .utf8)
        XCTAssertTrue(manifest.contains("overview.last"))
        XCTAssertFalse(manifest.contains("cause"))
    }

    func testACorruptCauseFileReadsAsNone() throws {
        try Data("not json".utf8).write(to: tempDir.appendingPathComponent("security.cause.json"))
        XCTAssertNil(store.cause(for: "security"))
    }

    func testCollectionStatesCarryTheCause() {
        store.record(.failed(exitCode: 5), report: "security", at: t0, cause: permission)
        XCTAssertEqual(store.collectionStates(for: ["security"]).first?.cause?.kind,
                       .missingPermission)
    }
}
