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
        [ "$1 $2" = "config list" ] && { printf '%s' '[{"name":"\(profile)"}]'; exit 0; }
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
            workspace: WorkspaceID(validating: profile),
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

    /// jamf-cli's own give-up on a server that never answers (exit 1, after it shrank the page
    /// size as far as it goes): one try per run, counted as a timeout, left alone after two.
    func testAServerThatNeverAnswersIsTriedOncePerRunAndBacksOffAfterTwoRuns() async throws {
        try "jamf_cli:\n  profile: \"\(profile)\"\n".write(
            to: try XCTUnwrap(ProfileService.workspaceURL(for: profile))
                .appendingPathComponent("config.yaml"),
            atomically: true, encoding: .utf8)
        let stub = root.appendingPathComponent("bin/stub-cli")
        let calls = root.appendingPathComponent("calls")
        try """
        #!/bin/sh
        [ "$1 $2" = "config list" ] && { printf '%s' '[{"name":"\(profile)"}]'; exit 0; }
        case "$*" in
          *patch-status*)
            echo x >> '\(calls.path)'
            printf '%s' '{"error":"error","message":"fetching patch title configurations: \
        fetching page 0: the server did not answer in time: Get \\"https://jamf.example.com/api\\": \
        http2: timeout awaiting response headers","hint":"pass a smaller --page-size"}'
            exit 1 ;;
        esac
        printf '[]'
        """.write(to: stub, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stub.path)
        let store = StateFileStore(directory: try WorkspacePaths.stateDir(for: profile))
        let kind = "patch-device-failures"

        for run in 1...2 {
            _ = try? await ReportEngine.collect(
                workspace: WorkspaceID(validating: profile),
                profile: profile, workspacePaths: WorkspacePaths.self, tiers: [.scan], force: true,
                authConfirmationProbe: { _, _ in false }, locateJamfCLI: { stub },
                onLine: { _ in })
            let lines = try String(contentsOf: calls, encoding: .utf8).split(separator: "\n")
            XCTAssertEqual(lines.count, run, "one jamf-cli call per run, no retry inside it")
            XCTAssertEqual(store.lastFailureExitCode(for: kind), 1)
            XCTAssertEqual(store.cause(for: kind)?.serverTimedOut, true)
            XCTAssertEqual(store.consecutiveTimeouts(for: kind), run)
            XCTAssertEqual(
                WorkspaceStore.lastFailureRepeatsOnRetry(
                    kind, in: store, countingUnauthorized: false, countingRepeatedTimeouts: true),
                run == 2, "the same-day retry stops after the second run")
        }
        // An unforced collect (a schedule, self-repair, catch-up) now leaves it for a day.
        XCTAssertNotNil(store.timeoutHoldUntil(report: kind))
        _ = try? await ReportEngine.collect(
            workspace: WorkspaceID(validating: profile),
            profile: profile, workspacePaths: WorkspacePaths.self, tiers: [.scan], force: false,
            authConfirmationProbe: { _, _ in false }, locateJamfCLI: { stub },
            onLine: { _ in })
        XCTAssertEqual(
            try String(contentsOf: calls, encoding: .utf8).split(separator: "\n").count, 2,
            "no third call while the hold lasts")
        store.record(.failed(exitCode: 1), report: kind, at: Date())
        XCTAssertEqual(store.consecutiveTimeouts(for: kind), 0, "another failure ends the streak")
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
        [ "$1 $2" = "config list" ] && { printf '%s' '[{"name":"\(profile)"}]'; exit 0; }
        case "$*" in
          *" auth token "*) exec sleep 30 ;;
        esac
        exit 3
        """.write(to: stub, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stub.path)
        let collector = LogTextCollector()

        do {
            _ = try await ReportEngine.collect(
                workspace: WorkspaceID(validating: profile),
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
        [ "$1 $2" = "config list" ] && { printf '%s' '[{"name":"\(profile)"}]'; exit 0; }
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
            workspace: WorkspaceID(validating: profile),
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

    /// Runs the refresh tier with every patch definition call answering `definitionScript`;
    /// returns the definition calls made, the log and the release-date snapshots written.
    private func runDefinitionWalk(
        _ definitionScript: String
    ) async throws -> (attempts: Int, texts: [String], snapshots: [String]) {
        let workspace = try XCTUnwrap(ProfileService.workspaceURL(for: profile))
        try "jamf_cli:\n  profile: \"\(profile)\"\n".write(
            to: workspace.appendingPathComponent("config.yaml"), atomically: true, encoding: .utf8)
        let calls = root.appendingPathComponent("definition-calls.log")
        let rows = (1...12).map {
            #"{"title":"T\#($0)","id":"\#($0)","on_latest":1,"on_other":0,"total":1,"#
                + #""latest":"1.0","compliance_pct":"100%"}"#
        }.joined(separator: ",")
        let stub = root.appendingPathComponent("bin/stub-cli")
        try """
        #!/bin/sh
        [ "$1 $2" = "config list" ] && { printf '%s' '[{"name":"\(profile)"}]'; exit 0; }
        case "$*" in
          *patch-software-title-configurations*) echo x >> '\(calls.path)'; \(definitionScript) ;;
          *--scan-failures*) printf '[]'; exit 0 ;;
          *"report patch-status"*) printf '%s' '[\(rows)]'; exit 0 ;;
        esac
        printf '[]'
        """.write(to: stub, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stub.path)
        let collector = LogTextCollector()
        _ = try? await ReportEngine.collect(
            workspace: WorkspaceID(validating: profile),
            profile: profile, workspacePaths: WorkspacePaths.self, tiers: [.refresh], force: true,
            authConfirmationProbe: { _, _ in false }, locateJamfCLI: { stub },
            refreshSOFA: { _ in (.empty, []) },
            patchDefinitionLimits: .init(timeout: 5, stopAfterTimeouts: 3),
            onLine: collector.append)
        let attempts = ((try? String(contentsOf: calls, encoding: .utf8)) ?? "")
            .split(separator: "\n").count
        let folder = try WorkspacePaths.dataDir(for: profile)
            .appendingPathComponent("patch-release-dates")
        let snapshots = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        return (attempts, collector.texts, snapshots.filter { $0.hasSuffix(".json") })
    }

    /// A rejected token is rejected for every title: one call, then the walk stops (Nov 16
    /// production: 139 calls, then "[ok] patch-release-dates: 0 title(s)").
    func testARefusedPatchDefinitionEndsTheWalkAndWritesNothing() async throws {
        let walk = try await runDefinitionWalk("exit 3")
        XCTAssertEqual(walk.attempts, 1, "every later title would repeat exit 3")
        XCTAssertTrue(walk.texts.contains { $0.contains("stopped patch-release-dates: exit 3") },
                      "\(walk.texts)")
        XCTAssertTrue(walk.texts.contains {
            $0.hasPrefix("[partial]") && $0.contains("patch-release-dates") }, "\(walk.texts)")
        XCTAssertFalse(walk.texts.contains { $0.contains("[ok] patch-release-dates") })
        XCTAssertEqual(walk.snapshots, [])
        let store = StateFileStore(directory: try WorkspacePaths.stateDir(for: profile))
        XCTAssertEqual(store.lastFailureExitCode(for: "patch-release-dates"),
                       CLIBridge.exitCodeUnauthorized)
    }

    /// Titles that all fail with an exit a retry might fix are each tried, then the walk is a
    /// failure, never an empty snapshot that reads as "no release dates".
    func testAWalkWhereNoTitleAnsweredIsNotWritten() async throws {
        let walk = try await runDefinitionWalk("exit 1")
        XCTAssertEqual(walk.attempts, 12)
        XCTAssertTrue(walk.texts.contains {
            $0.contains("patch-release-dates: no title answered — not written") }, "\(walk.texts)")
        XCTAssertTrue(walk.texts.contains {
            $0.hasPrefix("[partial]") && $0.contains("patch-release-dates") }, "\(walk.texts)")
        XCTAssertEqual(walk.snapshots, [])
    }

    // MARK: - patch-version-dates (B1)

    private static let oneDefinition =
        #"printf '%s' '[{"version":"1.0","releaseDate":"2026-01-01T00:00:00Z","absoluteOrderId":"0"}]'; exit 0"#

    /// The newest `patch-version-dates` sidecar's bytes and name, if any.
    private func newestVersionDates() throws -> (name: String, data: Data)? {
        let folder = try WorkspacePaths.dataDir(for: profile)
            .appendingPathComponent(PatchReleaseDateService.versionDatesKind)
        guard let url = FileManager.newestJSONFile(in: folder) else { return nil }
        return (url.lastPathComponent, try Data(contentsOf: url))
    }

    func testAnAnsweredWalkWritesTheSidecarAt0600AndAnIdenticalWalkWritesNothing() async throws {
        let first = try await runDefinitionWalk(Self.oneDefinition)
        XCTAssertTrue(first.texts.contains { $0.contains("[ok] patch-version-dates: 12 title(s)") },
                      "\(first.texts)")
        let written = try XCTUnwrap(try newestVersionDates())
        let folder = try WorkspacePaths.dataDir(for: profile)
        for kind in [PatchReleaseDateService.versionDatesKind, "patch-release-dates"] {
            let url = try XCTUnwrap(FileManager.newestJSONFile(
                in: folder.appendingPathComponent(kind)))
            let mode = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions]
            XCTAssertEqual((mode as? NSNumber)?.intValue, 0o600, kind)
        }
        let second = try await runDefinitionWalk(Self.oneDefinition)
        XCTAssertTrue(second.texts.contains {
            $0.contains("[info] patch-version-dates: 12 title(s), unchanged") }, "\(second.texts)")
        XCTAssertEqual(try newestVersionDates()?.data, written.data)
    }

    func testATitleThatFailsKeepsItsEarlierRowsMarkedStale() async throws {
        _ = try await runDefinitionWalk(Self.oneDefinition)
        let firstStamp = try XCTUnwrap(PatchReleaseDateService.snapshotStamp(
            of: URL(fileURLWithPath: try XCTUnwrap(try newestVersionDates()).name)))
        try await Task.sleep(nanoseconds: 1_100_000_000)  // a new stamp for the next file
        let walk = try await runDefinitionWalk(
            #"case "$*" in *"definitions 3 "*) exit 1 ;; esac; "# + Self.oneDefinition)
        XCTAssertTrue(walk.texts.contains { $0.contains("[ok] patch-version-dates: 12 title(s)") },
                      "\(walk.texts)")
        let rows = try JSONDecoder().decode(
            [PatchVersionDate].self, from: try XCTUnwrap(try newestVersionDates()).data)
        XCTAssertEqual(rows.first { $0.titleId == "3" }?.staleSince, firstStamp)
        XCTAssertNil(rows.first { $0.titleId == "4" }?.staleSince)
    }

    func testDefinitionsWithNoUsableVersionCarryTheEarlierRows() async throws {
        _ = try await runDefinitionWalk(Self.oneDefinition)
        try await Task.sleep(nanoseconds: 1_100_000_000)
        _ = try await runDefinitionWalk(
            #"printf '%s' '[{"version":" ","releaseDate":"2026-01-01T00:00:00Z"}]'; exit 0"#)
        let rows = try JSONDecoder().decode(
            [PatchVersionDate].self, from: try XCTUnwrap(try newestVersionDates()).data)
        XCTAssertFalse(rows.contains { $0.noVersions == true }, "Jamf did list definitions")
        XCTAssertEqual(rows.first { $0.titleId == "1" }?.version, "1.0")
        XCTAssertNotNil(rows.first { $0.titleId == "1" }?.staleSince)
    }

    func testAStoppedWalkLeavesTheSidecarAsItWas() async throws {
        _ = try await runDefinitionWalk(Self.oneDefinition)
        let before = try XCTUnwrap(try newestVersionDates())
        let walk = try await runDefinitionWalk("exit 3")
        XCTAssertFalse(walk.texts.contains { $0.contains("patch-version-dates") }, "\(walk.texts)")
        XCTAssertEqual(try newestVersionDates()?.data, before.data)
    }

    func testASidecarThatCannotBeWrittenIsAWarningAndTheWalkStillLands() async throws {
        let blocker = try WorkspacePaths.dataDir(for: profile)
            .appendingPathComponent(PatchReleaseDateService.versionDatesKind)
        try FileManager.default.createDirectory(
            at: blocker.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("not a folder".utf8).write(to: blocker)
        let walk = try await runDefinitionWalk(Self.oneDefinition)
        XCTAssertTrue(walk.texts.contains {
            $0.contains("[warn] patch-version-dates: could not write snapshot") }, "\(walk.texts)")
        XCTAssertTrue(walk.texts.contains { $0.contains("[ok] patch-release-dates: 12 title(s)") })
        XCTAssertEqual(walk.snapshots.count, 1)
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
