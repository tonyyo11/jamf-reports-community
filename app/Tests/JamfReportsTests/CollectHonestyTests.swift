import XCTest
@testable import JamfReports

/// A scheduled collect that exits 0 is read by everything downstream — Run
/// History, the freshness banner, the webhook digest — as "the fleet was polled
/// today". These pin the three ways that used to be false: jamf-cli never
/// launched, this Mac stood down for a peer, and the day's summary never
/// reached disk.
final class CollectHonestyTests: XCTestCase {

    private var root: URL!
    private var binDir: URL!
    private let profile = "honesty"

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("JRC-Honesty-\(UUID().uuidString)", isDirectory: true)
        let workspacesRoot = root.appendingPathComponent("Jamf-Reports", isDirectory: true)
        try FileManager.default.createDirectory(
            at: workspacesRoot.appendingPathComponent(profile, isDirectory: true),
            withIntermediateDirectories: true
        )
        binDir = root.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: binDir, withIntermediateDirectories: true)
        setenv("JRC_TEST_WORKSPACES_ROOT", workspacesRoot.path, 1)
        addTeardownBlock { unsetenv("JRC_TEST_WORKSPACES_ROOT") }
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
        try super.tearDownWithError()
    }

    private func writeConfig(_ yaml: String) throws {
        let ws = try XCTUnwrap(ProfileService.workspaceURL(for: profile))
        try yaml.write(to: ws.appendingPathComponent("config.yaml"),
                       atomically: true, encoding: .utf8)
    }

    /// A file that exists but cannot be executed, so `Process.run()` throws for
    /// every invocation — the launch-failure shape, not a non-zero exit. NOT
    /// named `jamf-cli`: `CLIBridge.codesignGate` keys on exactly that filename
    /// and would refuse before the launch is even attempted.
    private func makeUnlaunchableStub() throws -> URL {
        let url = binDir.appendingPathComponent("stub-cli")
        try "not an executable\n".write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o644], ofItemAtPath: url.path
        )
        return url
    }

    /// A launchable stub with a fixed exit code. Same naming constraint as above.
    private func makeStub(exitCode: Int, stdout: String = "[]") throws -> URL {
        let url = binDir.appendingPathComponent("stub-cli")
        let script = """
        #!/bin/sh
        printf '%s' '\(stdout)'
        exit \(exitCode)
        """
        try script.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: url.path
        )
        return url
    }

    // MARK: - M3: a launch outage is an outage

    /// Before the sentinel outcome, a run where jamf-cli failed to launch for
    /// EVERY kind appended nothing to `outcomes` — and an empty outcome set is
    /// not "dead", so the run fell through to the summary step and recorded a
    /// clean exit 0 while having fetched nothing at all.
    ///
    /// Scoped to the scan tier (two kinds) so the one-retry-with-3s-backoff per
    /// kind does not make this a two-minute test.
    func testEveryKindFailingToLaunchIsReportedAsADeadCollect() async throws {
        try writeConfig("jamf_cli:\n  profile: \"\(profile)\"\n")
        let stub = try makeUnlaunchableStub()
        let collector = LogTextCollector()

        do {
            try await ReportEngine.collect(
                profile: profile,
                workspacePaths: WorkspacePaths.self,
                tiers: [.scan],
                force: true,
                locateJamfCLI: { stub },
                onLine: collector.append
            )
            XCTFail("a run that could not launch jamf-cli at all must not succeed")
        } catch ReportEngineError.collectDead(_, let failedCount) {
            XCTAssertEqual(failedCount, 2, "both scan-tier kinds must count as failures")
        }

        XCTAssertTrue(
            collector.texts.contains { $0.contains("launch failed") },
            "the launch failure must be visible in the run log; got: \(collector.texts)"
        )
        let summaries = try WorkspacePaths.summariesDir(for: profile)
        let written = (try? FileManager.default.contentsOfDirectory(atPath: summaries.path)) ?? []
        XCTAssertTrue(written.isEmpty,
                      "no summary may be written from a run that fetched nothing: \(written)")
    }

    /// The counter has to survive the run too, and with no exit code — the
    /// process never ran, so there is none to record.
    func testLaunchFailureIsPersistedWithNoExitCode() async throws {
        try writeConfig("jamf_cli:\n  profile: \"\(profile)\"\n")
        let stub = try makeUnlaunchableStub()

        try? await ReportEngine.collect(
            profile: profile,
            workspacePaths: WorkspacePaths.self,
            tiers: [.scan],
            force: true,
            locateJamfCLI: { stub },
            onLine: { _ in }
        )

        let store = StateFileStore(directory: try WorkspacePaths.stateDir(for: profile))
        XCTAssertEqual(store.failures(report: "patch-device-failures")?.count, 1)
        XCTAssertNil(store.lastFailureExitCode(for: "patch-device-failures"),
                     "a process that never launched has no exit code to remember")
    }

    /// The sentinel has to be a value every downstream verdict reads correctly:
    /// not success, not a usage error the outage guard forgives, and not an
    /// auth signal.
    func testLaunchFailureSentinelIsNeitherSuccessNorAuthNorUsage() {
        let sentinel = ReportEngine.launchFailureExitCode
        XCTAssertNotEqual(sentinel, 0)
        XCTAssertNotEqual(sentinel, CLIBridge.exitCodePartialFailure)
        XCTAssertNotEqual(sentinel, CLIBridge.exitCodeUsage)
        XCTAssertNotEqual(sentinel, CLIBridge.exitCodeUnauthorized)

        let launchFailed = [ReportEngine.CollectOutcome(kind: "security", exitCode: sentinel)]
        XCTAssertTrue(ReportEngine.isCollectDead(launchFailed),
                      "an all-launch-failure run is a total outage")
        XCTAssertFalse(ReportEngine.isCollectAuthDead(launchFailed),
                       "a launch failure says nothing about credentials")
        XCTAssertFalse(ReportEngine.isCollectDead(launchFailed, skippedNotDueCount: 1),
                       "the not-due veto must still apply")
    }

    /// A 401 alongside a launch failure is still auth-dead: the sentinel must
    /// not be mistaken for a success that would prove credentials are alive.
    func testLaunchFailureDoesNotMaskAnAuthFailure() {
        let outcomes = [
            ReportEngine.CollectOutcome(
                kind: "security", exitCode: ReportEngine.launchFailureExitCode),
            ReportEngine.CollectOutcome(
                kind: "computers", exitCode: CLIBridge.exitCodeUnauthorized),
        ]
        XCTAssertTrue(ReportEngine.isCollectAuthDead(outcomes))
    }

    /// S3: the `[partial]` line names every kind whose data did not land, and a
    /// launch-failed kind is one of those — it has an outcome but nothing saved.
    func testLaunchFailedKindIsNamedAmongTheDegradedSources() {
        let outcomes = [
            ReportEngine.CollectOutcome(kind: "security", exitCode: 0),
            ReportEngine.CollectOutcome(
                kind: "patch-status", exitCode: ReportEngine.launchFailureExitCode),
        ]
        XCTAssertEqual(
            ReportEngine.degradedKinds(outcomes: outcomes, savedKinds: ["security"]),
            ["patch-status"]
        )
    }

    // MARK: - S1: standing down is not a success

    func testStandDownLineCarriesThePartialMarker() {
        let line = ReportEngine.standDownLine(
            reason: "[info] skipping collect — peer-mac collected 4 minutes ago"
        )
        XCTAssertTrue(line.hasPrefix("[partial] stood down: "), "got: \(line)")
        XCTAssertTrue(line.contains("peer-mac collected 4 minutes ago"),
                      "the operator still needs the reason; got: \(line)")
        XCTAssertFalse(line.contains("[info]"),
                       "one level tag per line, or LogLevel.from reads the wrong one")
    }

    func testStandDownLineWithoutAnInnerTagIsLeftAlone() {
        let line = ReportEngine.standDownLine(reason: "another machine is working here")
        XCTAssertEqual(line, "[partial] stood down: another machine is working here")
    }

    /// The marker only earns its keep if Run History downgrades the run.
    func testRunHistoryReadsAStandDownAsPartial() {
        let line = ReportEngine.standDownLine(reason: "[info] peer collected recently")
        let logURL = root.appendingPathComponent("no-such-workspace/automation/logs/x.log")
        XCTAssertTrue(
            RunHistoryService.isPartialRun(logURL: logURL, logTailText: line + "\nexit 0 after 2s")
        )
    }

    /// End to end: a peer that collected minutes ago makes this Mac stand down,
    /// and the run says so on the stream. `locateJamfCLI` returns nil to prove
    /// the decision is made before the binary check — a peer already working is
    /// a reason to defer whether or not this Mac could have collected.
    func testCollectStandsDownForARecentPeerAndSaysSo() async throws {
        try writeConfig("shared_workspace:\n  enabled: true\n")
        try writePeerCollect(at: Date())
        let collector = LogTextCollector()

        try await ReportEngine.collect(
            profile: profile,
            workspacePaths: WorkspacePaths.self,
            force: false,
            locateJamfCLI: { nil },
            onLine: collector.append
        )

        let standDown = collector.texts.filter { $0.hasPrefix(ReportEngine.standDownMarker) }
        XCTAssertEqual(standDown.count, 1, "got: \(collector.texts)")
        XCTAssertTrue(try XCTUnwrap(standDown.first).contains("peer-mac"),
                      "the line must name who collected; got: \(standDown)")
    }

    /// The watcher is what carries those facts to the scheduled-run caller,
    /// since `collect` returns Void.
    func testWatcherRecognizesBothDishonestyMarkers() {
        let standDown = CollectHonestyWatcher()
        standDown.observe("[info] collecting security for prod")
        XCTAssertTrue(standDown.producedFreshSnapshot)

        standDown.observe(ReportEngine.standDownLine(reason: "[info] peer collected recently"))
        XCTAssertTrue(standDown.stoodDown)
        XCTAssertFalse(standDown.producedFreshSnapshot)

        let summaryFailed = CollectHonestyWatcher()
        summaryFailed.observe("\(ReportEngine.summaryNotWrittenMarker) permission denied")
        XCTAssertTrue(summaryFailed.summaryWriteFailed)
        XCTAssertFalse(summaryFailed.stoodDown,
                       "the two markers are different problems and must not be conflated")
        XCTAssertFalse(summaryFailed.producedFreshSnapshot)
    }

    /// The flag the scheduled snapshot-only path gates its success card on.
    ///
    /// A snapshot-only run's entire product is the day's summary — it renders no
    /// workbook — so a card from a run that wrote none names an artifact that
    /// does not exist. Gating on the stand-down alone (which is what this
    /// started as) leaves the summary-write failure posting a clean success, so
    /// this pins that EITHER marker is enough to suppress it.
    func testEitherMarkerSuppressesTheSuccessCard() {
        for marker in [ReportEngine.standDownLine(reason: "[info] peer collected recently"),
                       "\(ReportEngine.summaryNotWrittenMarker) permission denied"] {
            let watcher = CollectHonestyWatcher()
            watcher.observe("[info] collecting security for prod")
            watcher.observe(marker)
            XCTAssertFalse(watcher.producedFreshSnapshot,
                           "a success card must not be posted after: \(marker)")
        }
    }

    /// A healthy run must leave the watcher silent, or every run reads as
    /// degraded and the markers stop meaning anything.
    func testWatcherIsQuietOnAHealthyRun() {
        let watcher = CollectHonestyWatcher()
        for line in ["[info] collecting security for prod",
                     "[ok] security: 1024 bytes",
                     "[partial] 1 of 30 source(s) served stale cache: groups",
                     "[ok] wrote summary_2026-09-02.json — trend chart and StaleDataBanner "
                        + "will reflect this run"] {
            watcher.observe(line)
        }
        XCTAssertFalse(watcher.stoodDown)
        XCTAssertFalse(watcher.summaryWriteFailed)
        XCTAssertTrue(watcher.producedFreshSnapshot)
    }

    // MARK: - S2: a summary that never landed

    /// The write failure used to be a plain `[warn]`, so a run whose trend point
    /// never reached disk still printed "— Trends updated" and recorded a clean
    /// run. Now it carries the `[partial]` marker and the emitter reports false.
    func testFailedSummaryWriteIsMarkedPartialAndReported() throws {
        try XCTSkipIf(getuid() == 0, "a read-only directory does not stop root")
        let dataDir = root.appendingPathComponent("data", isDirectory: true)
        let summariesDir = root.appendingPathComponent("summaries", isDirectory: true)
        let anchor = GoldenFleetClock.anchorNoon()
        try GoldenFleetWorkspace.writeJSON(
            GoldenFleetWorkspace.securitySummaryPayload(
                total: 10, filevault: 10, sip: 10, firewall: 10, gatekeeper: 10),
            to: dataDir.appendingPathComponent("security", isDirectory: true)
                .appendingPathComponent("security_\(GoldenFleetClock.stamp(anchor)).json"))

        try FileManager.default.createDirectory(at: summariesDir, withIntermediateDirectories: true)
        // Readable and traversable but not writable, so the atomic write's temp
        // file cannot be created — the shape of a locked-down or full volume.
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o500], ofItemAtPath: summariesDir.path)
        addTeardownBlock {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o700], ofItemAtPath: summariesDir.path)
        }

        let collector = LogTextCollector()
        let outcome = ReportEngine(config: ReportConfig(), dataDir: dataDir)
            .emitSummaryJSON(summariesDir: summariesDir, onLine: collector.append)

        XCTAssertEqual(outcome, .writeFailed)
        XCTAssertFalse(outcome.summaryIsOnDisk,
                       "the emitter must not claim a summary it could not write")
        XCTAssertNil(outcome.partialReason,
                     "the writer already emitted the marker — the caller must not double-report")
        let marker = collector.texts.filter {
            $0.hasPrefix(ReportEngine.summaryNotWrittenMarker)
        }
        XCTAssertEqual(marker.count, 1, "got: \(collector.texts)")
        XCTAssertTrue(
            RunHistoryService.isPartialRun(
                logURL: root.appendingPathComponent("nope/automation/logs/x.log"),
                logTailText: try XCTUnwrap(marker.first)
            ),
            "a run that lost its summary must not read as a clean success"
        )
    }

    /// The success path still reports true, or the gate above would suppress
    /// "Trends updated" on every healthy run instead.
    func testSuccessfulSummaryWriteIsReported() throws {
        let dataDir = root.appendingPathComponent("data2", isDirectory: true)
        let summariesDir = root.appendingPathComponent("summaries2", isDirectory: true)
        let anchor = GoldenFleetClock.anchorNoon()
        try GoldenFleetWorkspace.writeJSON(
            GoldenFleetWorkspace.securitySummaryPayload(
                total: 10, filevault: 10, sip: 10, firewall: 10, gatekeeper: 10),
            to: dataDir.appendingPathComponent("security", isDirectory: true)
                .appendingPathComponent("security_\(GoldenFleetClock.stamp(anchor)).json"))

        let engine = ReportEngine(config: ReportConfig(), dataDir: dataDir)
        let first = engine.emitSummaryJSON(summariesDir: summariesDir)
        XCTAssertEqual(first, .wrote)
        XCTAssertNil(first.partialReason)
        // Second call the same day keeps the first run's file — today's point is
        // still on disk, which is the question the outcome answers.
        let second = engine.emitSummaryJSON(summariesDir: summariesDir)
        XCTAssertEqual(second, .keptExisting)
        XCTAssertTrue(second.summaryIsOnDisk)
        XCTAssertNil(second.partialReason, "a kept summary is not a partial run")
    }

    /// The reachable hole the first pass left open: an all-exit-2 collect (a
    /// pre-1.23 binary against a newer command matrix) is deliberately NOT
    /// `isCollectDead`, so it runs to completion, writes nothing, and used to
    /// report `[ok] scheduled snapshot complete — Trends updated`.
    func testAllUsageErrorCollectSaysTheSummaryWasNotWritten() async throws {
        try writeConfig("jamf_cli:\n  profile: \"\(profile)\"\n")
        let stub = try makeStub(exitCode: 2, stdout: "")
        let collector = LogTextCollector()

        // Must NOT throw: exit 2 says nothing about server reachability, which
        // is exactly why this run reaches the summary step at all.
        try await ReportEngine.collect(
            profile: profile,
            workspacePaths: WorkspacePaths.self,
            tiers: [.scan],
            force: true,
            locateJamfCLI: { stub },
            onLine: collector.append
        )

        let marker = collector.texts.filter {
            $0.hasPrefix(ReportEngine.summaryNotWrittenMarker)
        }
        XCTAssertEqual(marker.count, 1, "got: \(collector.texts)")
        XCTAssertTrue(try XCTUnwrap(marker.first).contains("no jamf-cli snapshots"),
                      "got: \(marker)")

        let summaries = try WorkspacePaths.summariesDir(for: profile)
        let written = (try? FileManager.default.contentsOfDirectory(atPath: summaries.path)) ?? []
        XCTAssertTrue(written.isEmpty,
                      "nothing was collected, so nothing may be summarized: \(written)")

        let watcher = CollectHonestyWatcher()
        collector.texts.forEach(watcher.observe)
        XCTAssertFalse(watcher.producedFreshSnapshot,
                       "the scheduled caller must not claim Trends updated for this run")
    }

    /// A workspace with no config.yaml skips the emit entirely — also a run that
    /// did not advance Trends, and also silent before this.
    func testCollectWithoutConfigSaysTheSummaryWasNotWritten() async throws {
        let stub = try makeStub(exitCode: 2, stdout: "")
        let collector = LogTextCollector()

        try await ReportEngine.collect(
            profile: profile,
            workspacePaths: WorkspacePaths.self,
            tiers: [.scan],
            force: true,
            locateJamfCLI: { stub },
            onLine: collector.append
        )

        XCTAssertTrue(
            collector.texts.contains {
                $0.hasPrefix(ReportEngine.summaryNotWrittenMarker) && $0.contains("config.yaml")
            },
            "got: \(collector.texts)"
        )
    }

    // MARK: - I1: the included CLI answers to the same gate

    /// `wiki/07-Command-Line` presents `jamf-reports collect` as a supported way
    /// to schedule a run, so a cron-driven collect that stood down — or lost the
    /// day's summary — must not post the success digest or evaluate alerts
    /// either. Exercised through the wiring itself (`teeing` feeds the watcher,
    /// `announcesSuccess` is the gate), so no subprocess and no webhook.
    func testCLICollectRefusesToAnnounceSuccessAfterEitherMarker() {
        for marker in [ReportEngine.standDownLine(reason: "[info] peer collected recently"),
                       "\(ReportEngine.summaryNotWrittenMarker) permission denied"] {
            let signals = makeCLISignals(.collect)
            let tee = signals.teeing { _ in }
            tee(.init(timestamp: Date(), level: .info, text: "[info] collecting security"))
            tee(.init(timestamp: Date(), level: .warn, text: marker))
            XCTAssertFalse(signals.announcesSuccess,
                           "the CLI must not announce success after: \(marker)")
        }
    }

    /// The gate must stay open for a healthy CLI collect, or it suppresses every
    /// digest instead of the dishonest ones.
    func testCLICollectStillAnnouncesSuccessOnAHealthyRun() {
        let signals = makeCLISignals(.collect)
        let tee = signals.teeing { _ in }
        for text in ["[info] collecting security for prod", "[ok] security: 1024 bytes"] {
            tee(.init(timestamp: Date(), level: .info, text: text))
        }
        XCTAssertTrue(signals.announcesSuccess)
    }

    /// `ReportEngine.generate` emits the summary marker too — it writes the
    /// day's summary after the workbook. The workbook is still real, and the
    /// scheduled twin posts its card regardless (`main.swift:547`), so the CLI
    /// must not suppress a generate digest over a summary write it never
    /// promised. Gating `generate` on `producedFreshSnapshot` is the mistake
    /// this pins against.
    func testCLIGenerateStillAnnouncesSuccessWhenOnlyTheSummaryWriteFailed() {
        let signals = makeCLISignals(.generate)
        let tee = signals.teeing { _ in }
        tee(.init(timestamp: Date(), level: .info, text: "[info] writing sheets"))
        tee(.init(timestamp: Date(), level: .warn,
                  text: "\(ReportEngine.summaryNotWrittenMarker) permission denied"))
        XCTAssertTrue(signals.announcesSuccess,
                      "the workbook rendered — its digest names an artifact that exists")
    }

    /// The kind mapping itself, both markers by both kinds, so a future edit
    /// cannot collapse the two rules back into one.
    func testAnnounceGateDiffersByKindOnlyForTheSummaryMarker() {
        for kind in [CLIRunSignals.Kind.collect, .generate] {
            let stoodDown = CollectHonestyWatcher()
            stoodDown.observe(ReportEngine.standDownLine(reason: "[info] peer is working"))
            XCTAssertFalse(CLIRunSignals.announcesSuccess(for: kind, honesty: stoodDown),
                           "a run that stood down produced nothing, whatever its kind")

            let lostSummary = CollectHonestyWatcher()
            lostSummary.observe("\(ReportEngine.summaryNotWrittenMarker) disk full")
            XCTAssertEqual(
                CLIRunSignals.announcesSuccess(for: kind, honesty: lostSummary),
                kind == .generate,
                "only a generate has a product that survives a lost summary"
            )
        }
    }

    /// No workspace, config or recorder: this pins the decision, not the I/O.
    private func makeCLISignals(_ kind: CLIRunSignals.Kind) -> CLIRunSignals {
        CLIRunSignals(
            profile: profile, workspace: nil, config: nil,
            mode: CLIRunSignals.mode(for: kind), kind: kind,
            recorder: nil, honesty: CollectHonestyWatcher()
        )
    }

    // MARK: - Helpers

    /// Another Mac's activity record in the shared workspace.
    private func writePeerCollect(at date: Date) throws {
        let ws = try XCTUnwrap(ProfileService.workspaceURL(for: profile))
        let dir = ws.appendingPathComponent("automation", isDirectory: true)
            .appendingPathComponent("hosts", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        iso.timeZone = TimeZone(secondsFromGMT: 0)
        let json = """
        {"host": {"id": "PEER-0000-0000-0000", "name": "peer-mac"},
         "lastCollectAt": "\(iso.string(from: date))",
         "appVersion": "2.7.0"}
        """
        try json.write(to: dir.appendingPathComponent("peer.json"),
                       atomically: true, encoding: .utf8)
    }

    // MARK: - Platform-only kinds

    /// The counterpart to the oauth2 skip: when the auth method cannot be
    /// resolved — no jamf-cli config to read, as here — nothing may be
    /// skipped. Getting this backwards would silently stop collecting four
    /// kinds on a platform profile whose probe merely failed, so this pins
    /// that the Platform-only kinds are still attempted and still recorded.
    func testUnknownAuthMethodSkipsNothing() async throws {
        try writeConfig("jamf_cli:\n  profile: \"\(profile)\"\n")
        ProfileAuthMethod.invalidateCache()
        // Exit 4 (not found) rather than a launch failure: it is not in
        // `retryableExitCodes`, so the whole inventory tier runs without the
        // 3s retry sleep a launch failure incurs per kind.
        let stub = try makeStub(exitCode: 4)
        let collector = LogTextCollector()

        try? await ReportEngine.collect(
            profile: profile,
            workspacePaths: WorkspacePaths.self,
            tiers: [.inventory],
            force: true,
            locateJamfCLI: { stub },
            onLine: collector.append
        )

        XCTAssertFalse(
            collector.texts.contains { $0.contains("requires a Platform API profile") },
            "an unresolved auth method must not skip anything"
        )
        let store = StateFileStore(directory: try WorkspacePaths.stateDir(for: profile))
        for kind in ReportEngine.platformOnlyKinds {
            XCTAssertEqual(
                store.failures(report: kind)?.count, 1,
                "\(kind) must still be attempted when the auth method is unknown"
            )
        }
    }
}

/// Thread-safe collector for streamed log-line text — `onLine` is `@Sendable`,
/// so a plainly captured `var` is not.
private final class LogTextCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []

    /// Usable directly as an `onLine` handler.
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
