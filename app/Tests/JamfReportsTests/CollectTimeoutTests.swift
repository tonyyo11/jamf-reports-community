import XCTest
@testable import JamfReports

/// A jamf-cli call that never answers is stopped at its limit and recorded as a failed attempt
/// (`exitCodeTimedOut`), and the collect goes on to the next kind. The stub is not named
/// `jamf-cli`, since `CLIBridge.codesignGate` keys on that filename.
final class CollectTimeoutTests: XCTestCase {

    private var root: URL!
    private let profile = "timeouts"

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("JRC-Timeout-\(UUID().uuidString)", isDirectory: true)
        let workspacesRoot = root.appendingPathComponent("Jamf-Reports", isDirectory: true)
        try FileManager.default.createDirectory(
            at: workspacesRoot.appendingPathComponent(profile, isDirectory: true),
            withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("bin"), withIntermediateDirectories: true)
        setenv("JRC_TEST_WORKSPACES_ROOT", workspacesRoot.path, 1)
        addTeardownBlock { unsetenv("JRC_TEST_WORKSPACES_ROOT") }
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
        try super.tearDownWithError()
    }

    /// Sleeps for `patch-status` (the first scan-tier kind) and answers `[]` to anything else.
    private func makeStub() throws -> URL {
        let stub = root.appendingPathComponent("bin/stub-cli")
        let script = """
        #!/bin/sh
        case "$*" in
          *patch-status*) exec sleep 30 ;;
        esac
        printf '[]'
        """
        try script.write(to: stub, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stub.path)
        return stub
    }

    func testAKindThatNeverAnswersIsRecordedTimedOutAndTheCollectGoesOn() async throws {
        try "jamf_cli:\n  profile: \"\(profile)\"\n".write(
            to: try XCTUnwrap(ProfileService.workspaceURL(for: profile))
                .appendingPathComponent("config.yaml"),
            atomically: true, encoding: .utf8)
        let stub = try makeStub()
        let collector = LogTextCollector()

        _ = try? await ReportEngine.collect(
            profile: profile, workspacePaths: WorkspacePaths.self, tiers: [.scan], force: true,
            authConfirmationProbe: { _, _ in false }, locateJamfCLI: { stub },
            kindTimeout: 1, onLine: collector.append)

        let store = StateFileStore(directory: try WorkspacePaths.stateDir(for: profile))
        XCTAssertEqual(store.lastFailureExitCode(for: "patch-device-failures"),
                       CLIBridge.exitCodeTimedOut)
        XCTAssertEqual(store.failures(report: "patch-device-failures")?.count, 1,
                       "a stalled call is not retried inside the run")
        XCTAssertTrue(
            collector.texts.contains { $0.contains("patch-device-failures: timed out") },
            "Run History must say the kind timed out; got: \(collector.texts)")
        XCTAssertTrue(
            collector.texts.contains { $0.range(of: #"^\[info\] patch-device-failures took \d+s$"#,
                                                options: .regularExpression) != nil },
            "each kind's duration is logged; got: \(collector.texts)")
        XCTAssertTrue(
            collector.texts.contains { $0.contains("collecting update-device-failures") },
            "the collect must reach the next kind; got: \(collector.texts)")
        XCTAssertFalse(WorkspaceStore.lastFailureRepeatsOnRetry("patch-device-failures", in: store),
                       "a timeout is retried by the next run, like exit 1")
    }

    /// Every kind answers 401 and the confirmation probe never answers: the run must not read
    /// that as expired credentials (`authExpired` asks the user to re-authenticate).
    func testAnAuthProbeThatTimesOutIsNotExpiredCredentials() async throws {
        try "jamf_cli:\n  profile: \"\(profile)\"\n".write(
            to: try XCTUnwrap(ProfileService.workspaceURL(for: profile))
                .appendingPathComponent("config.yaml"),
            atomically: true, encoding: .utf8)
        let stub = root.appendingPathComponent("bin/stub-cli")
        try """
        #!/bin/sh
        case "$*" in
          *" auth token "*) exec sleep 30 ;;
        esac
        exit 3
        """.write(to: stub, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stub.path)
        let collector = LogTextCollector()

        do {
            _ = try await ReportEngine.collect(
                profile: profile, workspacePaths: WorkspacePaths.self, tiers: [.scan], force: true,
                authConfirmationProbe: ReportEngine.authConfirmationProbe(timeout: 1),
                locateJamfCLI: { stub }, onLine: collector.append)
        } catch ReportEngineError.authExpired {
            XCTFail("a probe that timed out must not read as expired credentials")
        } catch {
            // The run still lands nothing, so the outage guard ends it; that is not auth-dead.
        }

        XCTAssertTrue(collector.texts.contains { $0.contains("auth check timed out") },
                      "\(collector.texts)")
        XCTAssertTrue(collector.texts.contains { $0.contains("collecting update-device-failures") })
    }

    /// A wedged jamf-cli would otherwise cost every title its limit; three timeouts in a row
    /// end the walk and record the kind failed with the timeout's code.
    func testThreeTimedOutPatchDefinitionsInARowEndTheWalk() async throws {
        try "jamf_cli:\n  profile: \"\(profile)\"\n".write(
            to: try XCTUnwrap(ProfileService.workspaceURL(for: profile))
                .appendingPathComponent("config.yaml"),
            atomically: true, encoding: .utf8)
        let calls = root.appendingPathComponent("definition-calls.log")
        let rows = (1...12).map {
            #"{"title":"T\#($0)","id":"\#($0)","on_latest":1,"on_other":0,"total":1,"#
                + #""latest":"1.0","compliance_pct":"100%"}"#
        }.joined(separator: ",")
        let stub = root.appendingPathComponent("bin/stub-cli")
        try """
        #!/bin/sh
        case "$*" in
          *patch-software-title-configurations*) echo x >> '\(calls.path)'; exec sleep 30 ;;
          *--scan-failures*) printf '[]'; exit 0 ;;
          *"report patch-status"*) printf '%s' '[\(rows)]'; exit 0 ;;
        esac
        printf '[]'
        """.write(to: stub, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stub.path)
        let collector = LogTextCollector()

        _ = try? await ReportEngine.collect(
            profile: profile, workspacePaths: WorkspacePaths.self, tiers: [.refresh], force: true,
            authConfirmationProbe: { _, _ in false }, locateJamfCLI: { stub },
            refreshSOFA: { _ in (.empty, []) },
            patchDefinitionLimits: .init(timeout: 1, stopAfterTimeouts: 3),
            onLine: collector.append)

        let attempts = ((try? String(contentsOf: calls, encoding: .utf8)) ?? "")
            .split(separator: "\n").count
        XCTAssertEqual(attempts, 3, "the walk must stop, not time out on all 12 titles")
        XCTAssertTrue(
            collector.texts.contains {
                $0.contains("stopped patch-release-dates: 3 calls in a row timed out after 1 s")
            }, "\(collector.texts)")
        let store = StateFileStore(directory: try WorkspacePaths.stateDir(for: profile))
        XCTAssertEqual(store.lastFailureExitCode(for: "patch-release-dates"),
                       CLIBridge.exitCodeTimedOut)
    }

    func testATimedOutAttemptIsAFailureForTheVerdictsButNotAuthOrUsage() {
        let timedOut = [ReportEngine.CollectOutcome(
            kind: "computers", exitCode: CLIBridge.exitCodeTimedOut)]
        XCTAssertTrue(ReportEngine.isCollectDead(timedOut, savedKinds: []))
        XCTAssertFalse(ReportEngine.isCollectAuthDead(timedOut, savedKinds: []))
        XCTAssertFalse(ReportEngine.isCollectDead(timedOut, savedKinds: [], skippedNotDueCount: 1))
        XCTAssertFalse(ReportEngine.retryableExitCodes.contains(CLIBridge.exitCodeTimedOut))
    }

    func testATimeoutReadsAsTimedOutInTheCauseAndTheExplanation() {
        let cause = FailureCause.classify(exitCode: CLIBridge.exitCodeTimedOut, stdout: Data())
        XCTAssertEqual(cause.kind, .other)
        XCTAssertFalse(cause.isPermanent)
        XCTAssertTrue(cause.label.contains("timed out"))
        let text = CLIBridge.explainExit(CLIBridge.exitCodeTimedOut, operation: "Refresh")
        XCTAssertTrue(text.contains("timed out"))
        XCTAssertFalse(text.contains("exit -2"))
    }
}

private final class LogTextCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []

    var texts: [String] { lock.withLock { storage } }
    func append(_ line: CLIBridge.LogLine) { lock.withLock { storage.append(line.text) } }
}
