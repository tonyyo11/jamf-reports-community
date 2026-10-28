import XCTest
@testable import JamfReports

/// School and Protect collects tell the truth about launch failures and a refused state folder,
/// as the Jamf Pro collect does.
final class SchoolProtectCollectHonestyTests: XCTestCase {
    private var root: URL!
    private var bin: URL!
    private let profile = "school-honesty"

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("JRC-SPHonesty-\(UUID().uuidString)", isDirectory: true)
        let workspaces = root.appendingPathComponent("Jamf-Reports", isDirectory: true)
        try FileManager.default.createDirectory(
            at: workspaces.appendingPathComponent(profile, isDirectory: true),
            withIntermediateDirectories: true)
        setenv("JRC_TEST_WORKSPACES_ROOT", workspaces.path, 1)
        addTeardownBlock { unsetenv("JRC_TEST_WORKSPACES_ROOT") }
        // Not named `jamf-cli`: `CLIBridge.codesignGate` keys on that filename.
        bin = root.appendingPathComponent("stub-cli")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
        try super.tearDownWithError()
    }

    private func installStub(executable: Bool, exitCode: Int = 1) throws {
        let body = executable ? "#!/bin/sh\nexit \(exitCode)\n" : "not an executable\n"
        try body.write(to: bin, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: executable ? 0o755 : 0o644], ofItemAtPath: bin.path)
    }

    func testSchoolRunWhereEveryKindFailsToLaunchIsADeadCollect() async throws {
        try installStub(executable: false)
        let stub: URL = bin
        do {
            try await ReportEngine.schoolCollect(
                profile: profile, workspacePaths: WorkspacePaths.self, force: true,
                locateJamfCLI: { stub }, onLine: { _ in })
            XCTFail("a School run that launched nothing must not succeed")
        } catch ReportEngineError.collectDead(_, let failedCount, _) {
            XCTAssertGreaterThan(failedCount, 0)
        }
    }

    /// UNCAPTURED fixture: go-keyring's error shape, printed on stderr only.
    private func installLockedKeychainStub() throws {
        let body = "#!/bin/sh\necho 'Error: reading keychain item jamf-cli/p/client-secret: "
            + "exit status 36' >&2\nexit 1\n"
        try body.write(to: bin, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: bin.path)
    }

    func testSchoolRunWithALockedKeychainIsADeadCollectNamingTheKeychain() async throws {
        try installLockedKeychainStub()
        let stub: URL = bin
        let seen = LineBox()
        do {
            try await ReportEngine.schoolCollect(
                profile: profile, workspacePaths: WorkspacePaths.self, force: true,
                locateJamfCLI: { stub }, onLine: seen.append)
            XCTFail("a locked keychain must not read as a successful School run")
        } catch ReportEngineError.collectDead(_, _, let cause) {
            XCTAssertEqual(cause, .keychainLocked)
            XCTAssertTrue(seen.texts.contains { $0.contains(FailureCause.keychainLockedHint) },
                          "\(seen.texts)")
        }
    }

    func testProtectCollectRecordsALockedKeychainAsTheCause() async throws {
        let data = try WorkspacePaths.dataDir(for: profile)
        try FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)
        try installLockedKeychainStub()
        let stub: URL = bin
        try await ReportEngine.protectCollect(
            profile: profile, dataDir: data, locateJamfCLI: { stub }, onLine: { _ in })
        let store = StateFileStore(directory: try WorkspacePaths.stateDir(for: profile))
        let kind = try XCTUnwrap(ReportEngine.protectCommandMatrix(profile: profile).first?.kind)
        XCTAssertEqual(store.cause(for: kind)?.kind, .keychainLocked)
    }

    /// jamf-cli's swallowed 403: exit 0, nothing on stdout, the refusal on stderr.
    private func installSwallowed403Stub() throws {
        let body = "#!/bin/sh\necho 'permission denied (HTTP 403)' >&2\nexit 0\n"
        try body.write(to: bin, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: bin.path)
    }

    /// `failedRun` is for a collect that threw (a dead School run prints no `[partial]` line, so
    /// the verdict comes from the failures it recorded); otherwise the `[partial]` line decides.
    private func assertMissingPermissionEndsRetries(
        kind: String, lines: LineBox, failedRunSince start: Date? = nil
    ) throws {
        let store = StateFileStore(directory: try WorkspacePaths.stateDir(for: profile))
        XCTAssertEqual(store.cause(for: kind)?.kind, .missingPermission)
        let watcher = CollectHonestyWatcher()
        lines.texts.forEach(watcher.observe)
        if let start {
            XCTAssertFalse(watcher.retryCouldHelp(profile: profile, exitCode: 1, since: start),
                           "a refused permission is not fetched by a retry: \(lines.texts)")
        } else {
            XCTAssertTrue(watcher.incomplete, "Run History still reads the run as Partial")
            XCTAssertFalse(watcher.retryCouldHelp(profile: profile),
                           "a refused permission is not fetched by a retry: \(lines.texts)")
        }
    }

    func testSchoolSwallowed403IsAMissingPermissionAndNotRetried() async throws {
        try installSwallowed403Stub()
        let stub: URL = bin
        let seen = LineBox()
        let start = Date().addingTimeInterval(-1)
        do {
            try await ReportEngine.schoolCollect(
                profile: profile, workspacePaths: WorkspacePaths.self, force: true,
                locateJamfCLI: { stub }, onLine: seen.append)
            XCTFail("every source refused: the run is dead")
        } catch ReportEngineError.collectDead(_, _, let cause) {
            XCTAssertEqual(cause, .noPermission)
        }
        let kind = try XCTUnwrap(ReportEngine.schoolCommandMatrix(profile: profile).first?.kind)
        try assertMissingPermissionEndsRetries(kind: kind, lines: seen, failedRunSince: start)
    }

    func testProtectSwallowed403IsAMissingPermissionAndNotRetried() async throws {
        let data = try WorkspacePaths.dataDir(for: profile)
        try FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)
        try installSwallowed403Stub()
        let stub: URL = bin
        let seen = LineBox()
        try await ReportEngine.protectCollect(
            profile: profile, dataDir: data, locateJamfCLI: { stub }, onLine: seen.append)
        let kind = try XCTUnwrap(ReportEngine.protectCommandMatrix(profile: profile).first?.kind)
        try assertMissingPermissionEndsRetries(kind: kind, lines: seen)
    }

    /// A `state` folder that is a link is refused with one `[warn]`, not skipped in silence.
    private func linkStateFolder() throws -> URL {
        let data = try WorkspacePaths.dataDir(for: profile)
        try FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)
        let elsewhere = root.appendingPathComponent("elsewhere", isDirectory: true)
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: data.appendingPathComponent("state"), withDestinationURL: elsewhere)
        return data
    }

    private func refusals(_ lines: [String]) -> [String] {
        lines.filter { $0.hasPrefix("[warn] state is not used") }
    }

    func testSchoolCollectWarnsOnceWhenTheStateFolderIsRefused() async throws {
        _ = try linkStateFolder()
        try installStub(executable: true)
        let stub: URL = bin
        let seen = LineBox()
        _ = try? await ReportEngine.schoolCollect(
            profile: profile, workspacePaths: WorkspacePaths.self, force: true,
            locateJamfCLI: { stub }, onLine: seen.append)
        XCTAssertEqual(refusals(seen.texts).count, 1, "\(seen.texts)")
    }

    func testProtectCollectWarnsOnceWhenTheStateFolderIsRefused() async throws {
        let data = try linkStateFolder()
        try installStub(executable: true)
        let stub: URL = bin
        let seen = LineBox()
        try await ReportEngine.protectCollect(
            profile: profile, dataDir: data, locateJamfCLI: { stub }, onLine: seen.append)
        XCTAssertEqual(refusals(seen.texts).count, 1, "\(seen.texts)")
    }
}

private final class LineBox: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []

    var append: @Sendable (CLIBridge.LogLine) -> Void {
        { line in
            self.lock.lock(); defer { self.lock.unlock() }
            self.lines.append(line.text)
        }
    }

    var texts: [String] {
        lock.lock(); defer { lock.unlock() }
        return lines
    }
}
