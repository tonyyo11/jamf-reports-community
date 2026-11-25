import XCTest
@testable import JamfReports

/// Collect against a stub that answers the server-health command from files and everything
/// else with an empty list.
final class ServerHealthRefusalTests: XCTestCase {

    private var root: URL!
    private var answers: URL!
    private let profile = "healthcapture"
    private let kind = "certificate-authority"
    private let envelope = """
        {"error":"request failed","message":"permission denied (HTTP 403)","exitCode":5,\
        "hint":"Required privilege(s): Read Example Things."}
        """

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("JRC-Health-\(UUID().uuidString)", isDirectory: true)
        let workspacesRoot = root.appendingPathComponent("Jamf-Reports", isDirectory: true)
        try FileManager.default.createDirectory(
            at: workspacesRoot.appendingPathComponent(profile, isDirectory: true),
            withIntermediateDirectories: true)
        answers = root.appendingPathComponent("answers", isDirectory: true)
        try FileManager.default.createDirectory(at: answers, withIntermediateDirectories: true)
        setenv("JRC_TEST_WORKSPACES_ROOT", workspacesRoot.path, 1)
        addTeardownBlock { unsetenv("JRC_TEST_WORKSPACES_ROOT") }
        ProfileAuthMethod.invalidateCache()
        try writeConfig("jamf_cli:\n  profile: \"\(profile)\"\n")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
        try super.tearDownWithError()
    }

    private func writeConfig(_ text: String) throws {
        let ws = try XCTUnwrap(ProfileService.workspaceURL(for: profile))
        try text.write(to: ws.appendingPathComponent("config.yaml"), atomically: true,
                       encoding: .utf8)
    }

    private var store: StateFileStore {
        get throws { StateFileStore(directory: try WorkspacePaths.stateDir(for: profile)) }
    }

    private var calls: Int {
        ((try? String(contentsOf: answers.appendingPathComponent("calls"), encoding: .utf8))?
            .split(separator: "\n").count) ?? 0
    }

    /// One inventory collect in which the server-health command answers `stdout`, `stderr`
    /// and `exit` (after `sleep` seconds). Returns the log and what `collect` threw.
    @discardableResult
    private func collect(
        stdout: String, stderr: String = "", exit: Int, sleep: Int = 0, force: Bool = true,
        kindTimeout: TimeInterval = ReportEngine.collectKindTimeout
    ) async throws -> (log: [String], error: Error?) {
        try stdout.write(to: answers.appendingPathComponent("stdout"), atomically: true,
                         encoding: .utf8)
        try stderr.write(to: answers.appendingPathComponent("stderr"), atomically: true,
                         encoding: .utf8)
        let stub = root.appendingPathComponent("stub-cli")
        let script = """
        #!/bin/sh
        [ "$1 $2" = "config list" ] && { printf '%s' '[{"name":"\(profile)"}]'; exit 0; }
        case "$*" in
          *\(kind)*)
            echo x >> "\(answers.path)/calls"
            [ \(sleep) -gt 0 ] && sleep \(sleep)
            cat "\(answers.path)/stdout"; cat "\(answers.path)/stderr" >&2; exit \(exit) ;;
          *) printf '[]'; exit 0 ;;
        esac
        """
        try script.write(to: stub, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stub.path)
        let log = ServerHealthLog()
        var thrown: Error?
        do {
            _ = try await ReportEngine.collect(
                workspace: WorkspaceID(validating: profile), profile: profile,
                workspacePaths: WorkspacePaths.self, tiers: [.inventory], force: force,
                locateJamfCLI: { stub }, kindTimeout: kindTimeout, onLine: log.append)
        } catch { thrown = error }
        return (log.texts, thrown)
    }

    private func land() async throws {
        let fixture = try String(
            contentsOf: TestFixtures.dir("server-health/certificate-authority-active.json"),
            encoding: .utf8)
        try await collect(stdout: fixture, exit: 0)
        XCTAssertNotNil(try store.lastRun(report: kind))
    }

    private func partial(_ log: [String]) -> [String] {
        log.filter { $0.hasPrefix("[partial]") && $0.contains(kind) }
    }

    func testANeverLandedRefusalIsAdviceNotAFailure() async throws {
        let (log, error) = try await collect(stdout: envelope, exit: 5)
        XCTAssertNil(error)
        let cause = try XCTUnwrap(try store.cause(for: kind))
        XCTAssertEqual(cause.kind, .missingPermission)
        XCTAssertEqual(cause.names, ["Read Example Things"])
        XCTAssertTrue(try store.isAdvisory(kind: kind))
        XCTAssertTrue(log.contains(
            "[info] \(kind): not permitted for this login (Read Example Things); see Config Doctor"),
            "\(log)")
        XCTAssertTrue(partial(log).isEmpty, "\(log)")
        XCTAssertFalse(log.contains { $0.hasPrefix("[warn] \(kind)") }, "\(log)")
    }

    func testARefusalWithNoNamedPrivilegeSaysOnlyThat() async throws {
        let bare = #"{"error":"request failed","message":"forbidden","exitCode":5}"#
        let (log, _) = try await collect(stdout: bare, exit: 5)
        XCTAssertTrue(log.contains(
            "[info] \(kind): not permitted for this login; see Config Doctor"), "\(log)")
    }

    func testARefusalDoesNotFailARunThatAsksForLiveDataOnly() async throws {
        try writeConfig("jamf_cli:\n  profile: \"\(profile)\"\n  use_cached_data: false\n")
        let (_, error) = try await collect(stdout: envelope, exit: 5)
        XCTAssertNil(error)
        XCTAssertTrue(try store.isAdvisory(kind: kind))
    }

    func testExitFourIsNotSetUpBeforeAndAfterALanding() async throws {
        let (log, error) = try await collect(stdout: "", exit: 4)
        XCTAssertNil(error)
        XCTAssertEqual(try store.cause(for: kind)?.kind, .notConfiguredOnServer)
        XCTAssertTrue(log.contains("[info] \(kind): not set up on this Jamf Pro server"), "\(log)")
        XCTAssertTrue(partial(log).isEmpty)
        try store.clearFailures(report: kind)
        try await land()
        let (again, _) = try await collect(stdout: "", exit: 4)
        XCTAssertTrue(try store.isAdvisory(kind: kind))
        XCTAssertTrue(partial(again).isEmpty, "\(again)")
    }

    func testARefusalAfterALandingIsAnOrdinaryFailure() async throws {
        try await land()
        let (log, _) = try await collect(stdout: envelope, exit: 5)
        XCTAssertFalse(try store.isAdvisory(kind: kind))
        XCTAssertFalse(partial(log).isEmpty, "\(log)")
    }

    /// No capture shows exit 4 for a missing feature (those answered exit 1), so exit 1 is
    /// never read as "not set up".
    func testANotSetUpExitOneStaysAnOrdinaryFailure() async throws {
        let notSetUp = #"{"error":"request failed","message":"SSO is not configured","exitCode":1}"#
        let (log, _) = try await collect(stdout: notSetUp, exit: 1)
        XCTAssertEqual(try store.cause(for: kind)?.kind, .other)
        XCTAssertFalse(try store.isAdvisory(kind: kind))
        XCTAssertFalse(partial(log).isEmpty, "\(log)")
    }

    func testAPartialSuccessIsAFailureAndSavesNothing() async throws {
        let fixture = try String(
            contentsOf: TestFixtures.dir("server-health/certificate-authority-active.json"),
            encoding: .utf8)
        let (log, _) = try await collect(stdout: fixture, exit: 7)
        XCTAssertNil(try store.lastRun(report: kind))
        XCTAssertFalse(partial(log).isEmpty, "\(log)")
    }

    func testATimeoutStaysAnOrdinaryFailure() async throws {
        let (log, _) = try await collect(stdout: "", exit: 0, sleep: 5, kindTimeout: 1)
        XCTAssertFalse(try store.isAdvisory(kind: kind))
        XCTAssertFalse(partial(log).isEmpty, "\(log)")
    }

    func testAHeldKindIsSkippedUnforcedAndProbedWhenForced() async throws {
        try await collect(stdout: envelope, exit: 5)
        let before = calls
        let (held, _) = try await collect(stdout: envelope, exit: 5, force: false)
        XCTAssertEqual(calls, before, "the weekly hold keeps the call away")
        XCTAssertTrue(held.contains {
            $0.hasPrefix("[skip] \(kind): not permitted for this login; checked again weekly")
        }, "\(held)")
        try await collect(stdout: envelope, exit: 5, force: true)
        XCTAssertEqual(calls, before + 1, "Collect now probes at once")
    }

    func testALandedCAIsSavedReducedToItsExpiry() async throws {
        try await land()
        let dir = try WorkspacePaths.dataDir(for: profile).appendingPathComponent(kind)
        let url = try XCTUnwrap(FileManager.newestJSONFile(in: dir))
        let saved = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        XCTAssertEqual(Array(saved.keys), ["notAfter"])
    }

    func testAnOlderJamfCLISkipsTheKindAndRecordsNothing() async throws {
        let plan = ReportEngine.planCollect(
            commands: ReportEngine.collectCommandMatrix(profile: profile, staleDays: 30),
            inputs: {
                var inputs = ReportEngine.CollectPlanInputs(
                    tiers: [.inventory], force: true, skipExpensive: false, nonPlatformAuth: nil,
                    tenantLevel: false, collectSkip: [], dashboardSupported: true,
                    installedVersion: "1.37.0", now: Date())
                inputs.serverHealthSupported = JamfCLIInstaller.supportsServerHealth("1.37.0")
                return inputs
            }(), lastRun: { _ in nil })
        XCTAssertEqual(plan.first { $0.kind == kind }?.skip, .serverHealthUnsupported)
    }
}

private final class ServerHealthLog: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []

    var append: @Sendable (CLIBridge.LogLine) -> Void {
        { line in self.lock.withLock { self.lines.append(line.text) } }
    }

    var texts: [String] { lock.withLock { lines } }
}
