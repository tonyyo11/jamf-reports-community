import XCTest
@testable import JamfReports

/// PR-22 T-5: `StateFileStore` persists one `<report>.last` file per
/// jamf-cli report kind, recording when that report was last successfully
/// fetched. T-7's resolver reads these timestamps via `isDue` so the
/// `collect` loop can skip reports whose cadence isn't due yet.
///
/// Pinned semantics:
/// - On-disk format: one line, ISO-8601 RFC 3339 UTC, seconds precision.
/// - Reads NEVER throw — missing/empty/malformed all return nil.
/// - Writes ARE allowed to throw — operators need to know if state wasn't
///   persisted (otherwise the next `collect` would loop the report
///   immediately and look like an infinite-fetch bug).
/// - Writes are atomic — a crash mid-write must not corrupt the existing
///   value (or there'd be flapping "never fetched" reads).
final class StateFileStoreTests: XCTestCase {

    private let fileManager = FileManager.default
    private var tempDir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = fileManager.temporaryDirectory
            .appendingPathComponent("sfs-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? fileManager.removeItem(at: tempDir)
        tempDir = nil
        try super.tearDownWithError()
    }

    // MARK: - Reads

    func testReadMissingFileReturnsNil() {
        let store = StateFileStore(directory: tempDir)
        XCTAssertNil(store.lastRun(report: "overview"))
    }

    func testReadMissingDirectoryReturnsNil() {
        // recordRun auto-creates the dir, but a fresh read on a brand new
        // workspace must not throw or create directories — just return nil.
        let store = StateFileStore(
            directory: tempDir.appendingPathComponent("does-not-exist", isDirectory: true)
        )
        XCTAssertNil(store.lastRun(report: "overview"))
    }

    func testReadEmptyFileReturnsNil() throws {
        let url = tempDir.appendingPathComponent("overview.last")
        try Data().write(to: url)
        let store = StateFileStore(directory: tempDir)
        XCTAssertNil(store.lastRun(report: "overview"))
    }

    func testReadMalformedFileReturnsNil() throws {
        let url = tempDir.appendingPathComponent("overview.last")
        try "not a date".write(to: url, atomically: true, encoding: .utf8)
        let store = StateFileStore(directory: tempDir)
        XCTAssertNil(store.lastRun(report: "overview"))
    }

    func testReadValidISO8601ReturnsDate() throws {
        let url = tempDir.appendingPathComponent("overview.last")
        try "2026-05-19T13:51:34Z".write(to: url, atomically: true, encoding: .utf8)
        let store = StateFileStore(directory: tempDir)
        let parsed = store.lastRun(report: "overview")
        XCTAssertNotNil(parsed)
        let formatter = ISO8601DateFormatter()
        XCTAssertEqual(parsed, formatter.date(from: "2026-05-19T13:51:34Z"))
    }

    // MARK: - Writes

    func testRecordRunCreatesStateDirWhenMissing() throws {
        let nested = tempDir.appendingPathComponent("state", isDirectory: true)
        XCTAssertFalse(fileManager.fileExists(atPath: nested.path),
                       "Precondition: state dir should not yet exist")
        let store = StateFileStore(directory: nested)
        try store.recordRun(report: "overview", at: Date(timeIntervalSince1970: 1_700_000_000))
        XCTAssertTrue(fileManager.fileExists(atPath: nested.path),
                      "recordRun must auto-create the state dir on first write")
    }

    func testRecordRunIsRoundTrippableAtSecondPrecision() throws {
        let store = StateFileStore(directory: tempDir)
        // Sub-second component on input — read should equal the floored value.
        let written = Date(timeIntervalSince1970: 1_700_000_000.789)
        try store.recordRun(report: "overview", at: written)
        let read = store.lastRun(report: "overview")
        XCTAssertNotNil(read)
        XCTAssertEqual(
            read!.timeIntervalSince1970,
            1_700_000_000,
            accuracy: 0.0001,
            "Round-trip must truncate to second precision so isDue's elapsed math doesn't flap"
        )
    }

    func testRecordRunOverwritesPriorValue() throws {
        let store = StateFileStore(directory: tempDir)
        let first = Date(timeIntervalSince1970: 1_700_000_000)
        let second = Date(timeIntervalSince1970: 1_700_086_400)
        try store.recordRun(report: "overview", at: first)
        try store.recordRun(report: "overview", at: second)
        let read = store.lastRun(report: "overview")
        XCTAssertEqual(
            read?.timeIntervalSince1970, second.timeIntervalSince1970,
            "Second write must replace the first — atomic rename, not append"
        )
    }

    func testFileContentsAreSingleISO8601LineUTC() throws {
        let store = StateFileStore(directory: tempDir)
        let written = Date(timeIntervalSince1970: 1_700_000_000)
        try store.recordRun(report: "overview", at: written)
        let url = tempDir.appendingPathComponent("overview.last")
        let body = try String(contentsOf: url, encoding: .utf8)
        XCTAssertEqual(body, "2023-11-14T22:13:20Z",
                       "Format pinned: ISO-8601 RFC 3339, UTC, no fractional seconds, no trailing newline")
    }

    func testDifferentReportsAreIndependent() throws {
        let store = StateFileStore(directory: tempDir)
        try store.recordRun(report: "overview", at: Date(timeIntervalSince1970: 1_700_000_000))
        try store.recordRun(report: "security", at: Date(timeIntervalSince1970: 1_700_086_400))
        XCTAssertEqual(
            store.lastRun(report: "overview")?.timeIntervalSince1970, 1_700_000_000
        )
        XCTAssertEqual(
            store.lastRun(report: "security")?.timeIntervalSince1970, 1_700_086_400
        )
    }

    // MARK: - End-to-end with isDue

    /// Compose StateFileStore with CadenceResolver.isDue — this is the
    /// shape T-8 will use in `ReportEngine.collect`.
    func testStoreIntegratesWithIsDue() throws {
        let store = StateFileStore(directory: tempDir)
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let oneDay = 86_400

        // Never fetched — due.
        XCTAssertTrue(
            CadenceResolver.isDue(
                lastRun: store.lastRun(report: "overview"),
                cadence: .seconds(oneDay),
                now: now
            )
        )

        // Just fetched — not due at daily cadence.
        try store.recordRun(report: "overview", at: now)
        XCTAssertFalse(
            CadenceResolver.isDue(
                lastRun: store.lastRun(report: "overview"),
                cadence: .seconds(oneDay),
                now: now
            )
        )

        // Fetched a day ago — due again (exclusive >= boundary).
        try store.recordRun(report: "overview", at: now.addingTimeInterval(-Double(oneDay)))
        XCTAssertTrue(
            CadenceResolver.isDue(
                lastRun: store.lastRun(report: "overview"),
                cadence: .seconds(oneDay),
                now: now
            )
        )
    }
}

/// PR-22 T-6: `WorkspacePaths.stateDir(for:)` is the canonical site
/// callers use to construct `StateFileStore`. Lives under
/// `<jamf_cli.data_dir>/state/` so it round-trips with snapshots: when
/// `data_dir` is profile-scoped for multi-tenant use, the state files
/// follow automatically.
final class WorkspacePathsStateDirTests: XCTestCase {

    private let fileManager = FileManager.default

    private func makeWorkspace(profile: String, configBody: String) throws -> URL {
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("jrc-state-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        setenv("JRC_TEST_WORKSPACES_ROOT", root.path, 1)
        addTeardownBlock { unsetenv("JRC_TEST_WORKSPACES_ROOT") }
        let workspace = root.appendingPathComponent(profile, isDirectory: true)
        try fileManager.createDirectory(at: workspace, withIntermediateDirectories: true)
        let config = workspace.appendingPathComponent("config.yaml")
        try configBody.write(to: config, atomically: true, encoding: .utf8)
        return workspace
    }

    func testStateDirDefaultsToDataDirState() throws {
        let workspace = try makeWorkspace(profile: "stproto", configBody: "")
        let stateDir = try WorkspacePaths.stateDir(for: "stproto")
        XCTAssertEqual(
            stateDir.standardizedFileURL.path,
            workspace.appendingPathComponent("jamf-cli-data", isDirectory: true)
                .appendingPathComponent("state", isDirectory: true)
                .standardizedFileURL.path,
            "Default location: <workspace>/jamf-cli-data/state — sibling to JSON snapshots"
        )
    }

    func testStateDirHonorsCustomDataDir() throws {
        // Multi-tenant scenario — `data_dir` is profile-scoped, state dir
        // must follow into the same dir so deleting the snapshot cache also
        // resets the cadence state.
        let body = """
        jamf_cli:
          data_dir: tenant-a-data
        """
        let workspace = try makeWorkspace(profile: "stcustom", configBody: body)
        let stateDir = try WorkspacePaths.stateDir(for: "stcustom")
        XCTAssertEqual(
            stateDir.standardizedFileURL.path,
            workspace.appendingPathComponent("tenant-a-data", isDirectory: true)
                .appendingPathComponent("state", isDirectory: true)
                .standardizedFileURL.path
        )
    }

    func testStateDirThrowsOnInvalidProfile() {
        XCTAssertThrowsError(try WorkspacePaths.stateDir(for: "Bad Profile!")) { error in
            guard case WorkspacePaths.PathError.invalidProfile = error else {
                return XCTFail("Expected invalidProfile, got \(error)")
            }
        }
    }
}
