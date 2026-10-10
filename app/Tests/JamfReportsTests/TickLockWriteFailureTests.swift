import XCTest
@testable import JamfReports

/// A tick whose lock file cannot be written is a failure, not a queue: nobody holds the lock,
/// so it must not stamp a blocked wake or exit 75 on every wake for good.
final class TickLockWriteFailureTests: XCTestCase {

    private var root: URL!
    private var readOnlyDir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("jrc-tick-writefail-\(UUID().uuidString)", isDirectory: true)
        let workspace = root.appendingPathComponent("alpha", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        try Data("jamf_cli:\n  profile: \"alpha\"\n".utf8)
            .write(to: workspace.appendingPathComponent("config.yaml"))
        readOnlyDir = root.appendingPathComponent("readonly", isDirectory: true)
        try FileManager.default.createDirectory(at: readOnlyDir, withIntermediateDirectories: true)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o500], ofItemAtPath: readOnlyDir.path)
        setenv("JRC_TEST_WORKSPACES_ROOT", root.path, 1)
    }

    override func tearDownWithError() throws {
        unsetenv("JRC_TEST_WORKSPACES_ROOT")
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o700], ofItemAtPath: readOnlyDir.path)
        try? FileManager.default.removeItem(at: root)
        try super.tearDownWithError()
    }

    func testAnUnwritableLockFileFailsTheTickInsteadOfReadingAsHeld() async throws {
        let lock = TickLock(url: readOnlyDir.appendingPathComponent(".tick.lock"))
        try XCTSkipIf(
            lock.claim().kind != "writeFailed", "the directory is writable (running as root?)")

        let exit = await runTick(arguments: ["--tick"], lock: lock)

        XCTAssertEqual(exit, 1, "a write failure is not the queued exit code")
        XCTAssertNil(TickLock.takeBlockedSince(), "no wake was turned away")
        let runs = RunHistoryService.list(profile: "alpha")
        let run = try XCTUnwrap(runs.first, "Run History shows the failure")
        XCTAssertEqual(run.name, "Background item")
        XCTAssertEqual(run.status, .fail)
        let text = RunHistoryService.loadLog(run.logURL).map(\.text)
        XCTAssertTrue(
            text.contains { $0.contains("[error] tick: lock file not writable") }, "\(text)")
    }
}
