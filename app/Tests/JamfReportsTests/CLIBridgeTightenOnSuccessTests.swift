import XCTest
@testable import JamfReports

/// MFS-1 — every successful CLI invocation must trigger the workspace
/// permission sweep. The actual subprocess plumbing is exercised by
/// integration runs; here we stand in for the Python CLI by simulating its
/// effect (writing a 0644 JSON file under the profile workspace) and then
/// invoking `tightenOnSuccess(0, profile:)` — the helper every CLI write
/// path now calls. The post-condition is that the file is at 0600.
@MainActor
final class CLIBridgeTightenOnSuccessTests: XCTestCase {

    private var tempRoot: URL!

    override func setUpWithError() throws {
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("jrc-tighten-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        setenv("JRC_TEST_WORKSPACES_ROOT", tempRoot.path, 1)
    }

    override func tearDownWithError() throws {
        unsetenv("JRC_TEST_WORKSPACES_ROOT")
        if let tempRoot { try? FileManager.default.removeItem(at: tempRoot) }
    }

    func test_tightenOnSuccess_secures0644FilesUnderProfile() throws {
        let profile = "dummy"
        let workspace = tempRoot.appendingPathComponent(profile, isDirectory: true)
        let dataDir = workspace
            .appendingPathComponent("jamf-cli-data", isDirectory: true)
            .appendingPathComponent("audit", isDirectory: true)
        try FileManager.default.createDirectory(at: dataDir, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: NSNumber(value: Int16(0o755))])

        let snapshot = dataDir.appendingPathComponent("test.json")
        try Data(#"{"ok":true}"#.utf8).write(to: snapshot)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o644))],
            ofItemAtPath: snapshot.path
        )
        XCTAssertEqual(try mode(of: snapshot), 0o644, "preconditions: simulated CLI wrote 0644")

        let bridge = CLIBridge()
        // Simulated CLI call exited successfully — the bridge wrapper would
        // have called this immediately after `await run(...)`.
        bridge.tightenOnSuccess(0, profile: profile)

        XCTAssertEqual(try mode(of: snapshot), 0o600,
                       "post: tightenOnSuccess(0, ...) must walk the workspace to 0600")
        XCTAssertEqual(try mode(of: dataDir), 0o700,
                       "post: directory mode must be 0700")
    }

    func test_tightenOnSuccess_runsOnNonZeroExit() throws {
        // Per silent-failure audit MUST-FIX #2: the Python CLI may write some
        // files then crash (non-zero exit). Those files would otherwise keep
        // their default-umask 0644 perms indefinitely, so the sweep must run
        // regardless of exit code.
        let profile = "dummy"
        let workspace = tempRoot.appendingPathComponent(profile, isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        let file = workspace.appendingPathComponent("loose.json")
        try Data().write(to: file)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o644))],
            ofItemAtPath: file.path
        )

        let bridge = CLIBridge()
        bridge.tightenOnSuccess(1, profile: profile)
        XCTAssertEqual(try mode(of: file), 0o600,
                       "non-zero exit must still tighten — partial writes are still device data")
    }

    func test_tightenOnSuccess_isNoOpForInvalidProfile() throws {
        let bridge = CLIBridge()
        // Must not crash, must not throw, must not write anywhere.
        bridge.tightenOnSuccess(0, profile: "../escape")
        bridge.tightenOnSuccess(0, profile: "")
    }

    private func mode(of url: URL) throws -> Int {
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        return ((attrs[.posixPermissions] as? NSNumber)?.intValue ?? 0) & 0o7777
    }
}
