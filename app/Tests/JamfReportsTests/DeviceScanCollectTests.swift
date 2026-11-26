import XCTest
@testable import JamfReports

/// The scan phase runs against a stub jamf-cli that answers
/// `classic-computer-history get <id>` and `ddm-status status-items <mgmt>`
/// from files in a temp dir; the `computers` snapshot it reads is written
/// straight to disk (`collect(tiers: [.scan])` never runs the inventory-tier
/// `computers` command, so the scan phase can only read a snapshot already
/// there). The stub is NOT named `jamf-cli` (codesign gate).
final class DeviceScanCollectTests: XCTestCase {

    private var root: URL!
    private var binDir: URL!
    private var answers: URL!
    private let profile = "scanphase"

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("JRC-Scan-\(UUID().uuidString)", isDirectory: true)
        let workspacesRoot = root.appendingPathComponent("Jamf-Reports", isDirectory: true)
        try FileManager.default.createDirectory(
            at: workspacesRoot.appendingPathComponent(profile, isDirectory: true),
            withIntermediateDirectories: true)
        binDir = root.appendingPathComponent("bin", isDirectory: true)
        answers = root.appendingPathComponent("answers", isDirectory: true)
        try FileManager.default.createDirectory(at: binDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: answers, withIntermediateDirectories: true)
        setenv("JRC_TEST_WORKSPACES_ROOT", workspacesRoot.path, 1)
        addTeardownBlock { unsetenv("JRC_TEST_WORKSPACES_ROOT") }
        let ws = try XCTUnwrap(ProfileService.workspaceURL(for: profile))
        try "jamf_cli:\n  profile: \"\(profile)\"\n".write(
            to: ws.appendingPathComponent("config.yaml"), atomically: true, encoding: .utf8)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
        try super.tearDownWithError()
    }

    /// Writes `answers/<name>` files and a stub that maps argv to them:
    ///   classic-computer-history get <id>   → answers/hist-<id>
    ///     (exit = first line of answers/hist-<id>.exit if present; an answers/<name>.sleep file
    ///      makes any call sleep until it is stopped, and <name>.stop creates answers/stop)
    ///   … status-items <mgmt>               → answers/ddm-<mgmt>  (same exit rule; either
    ///                                          resource spelling — see statusItemsArguments)
    ///   … --scan-failures (both matrix kinds) → answers/matrix, only when it or
    ///                                          answers/matrix.exit exists
    /// Any answers/<name>.err goes to stderr first.
    /// Anything else → prints [] exit 0, so the argv matrix's kinds "succeed" harmlessly.
    private func makeStub() throws -> URL {
        let url = binDir.appendingPathComponent("stub-cli")
        let script = """
        #!/bin/sh
        [ "$1 $2" = "config list" ] && { printf '%s' '[{"name":"\(profile)"}]'; exit 0; }
        A="\(answers.path)"
        printf '%s\\n' "$*" >> "$A/calls.log"
        emit() { f="$A/$1"; [ -f "$f.sleep" ] && exec sleep 30; [ -f "$f.stop" ] && : > "$A/stop"; \\
                 if [ -f "$f.exit" ]; then code=$(cat "$f.exit"); else code=0; fi; \\
                 [ -f "$f.err" ] && cat "$f.err" >&2; [ -f "$f" ] && cat "$f"; exit "$code"; }
        case "$*" in
          *" classic-computer-history get "*) id=$(echo "$*" | sed -E 's/.*classic-computer-history get ([^ ]+).*/\\1/'); emit "hist-$id" ;;
          *" status-items "*) m=$(echo "$*" | sed -E 's/.*status-items ([^ ]+).*/\\1/'); \\
            emit "ddm-$m" ;;
          *" --scan-failures "*) if [ -f "$A/matrix" ] || [ -f "$A/matrix.exit" ]; then \\
            emit matrix; fi; case "$*" in *patch-status*) \\
            printf '%s' '[{"section":"device_failures","data":[],"fetch_error":""}]' ;; \\
            *) printf '[]' ;; esac; exit 0 ;;
          *) printf '[]'; exit 0 ;;
        esac
        """
        try script.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    private func answer(_ name: String, _ body: String, exit code: Int? = nil) throws {
        try body.write(to: answers.appendingPathComponent(name), atomically: true, encoding: .utf8)
        if let code {
            try "\(code)".write(to: answers.appendingPathComponent("\(name).exit"),
                                atomically: true, encoding: .utf8)
        }
    }

    /// Every argv the stub was invoked with, one line each — proves a call
    /// type genuinely never reached a given device rather than being called
    /// and then filtered out downstream.
    private func callsLog() -> String {
        (try? String(
            contentsOf: answers.appendingPathComponent("calls.log"), encoding: .utf8
        )) ?? ""
    }

    private func historyCalls(for id: String) -> Int {
        callsLog().components(separatedBy: "classic-computer-history get \(id) ").count - 1
    }

    private func computers(
        _ rows: [(id: String, name: String, mgmt: String, ddm: Bool)]
    ) -> String {
        let objs = rows.map {
            "{\"id\":\"\($0.id)\",\"general\":{\"name\":\"\($0.name)\"," +
            "\"managementId\":\"\($0.mgmt)\"," +
            "\"declarativeDeviceManagementEnabled\":\($0.ddm)}}"
        }
        return "[" + objs.joined(separator: ",") + "]"
    }

    /// Writes the `computers` snapshot straight to the workspace data dir,
    /// bypassing jamf-cli entirely — `collect(tiers: [.scan])` never issues
    /// `computers list`, so the scan phase can only ever read a snapshot
    /// already on disk (spec: "the newest on disk when computers was not due").
    private func writeComputers(
        _ rows: [(id: String, name: String, mgmt: String, ddm: Bool)]
    ) throws {
        let dir = try WorkspacePaths.dataDir(for: profile)
            .appendingPathComponent("computers", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try computers(rows).write(
            to: dir.appendingPathComponent("computers_20260904T120000.json"),
            atomically: true, encoding: .utf8)
    }

    private let cleanHistory = #"{"commands":{"completed":"","failed":"","pending":""}}"#
    private let failedHistory =
        #"{"commands":{"completed":"","failed":{"command":{"name":"InstallApplication","#
        + #""status":"timed out"}},"pending":""}}"#
    private let ddmPayload =
        #"{"statusItems":[{"key":"device.operating-system.version","value":"27.0","#
        + #""lastUpdateTime":"2026-09-04T07:00:00.000"},"#
        + #"{"key":"management.declarations.configurations","#
        + #""value":"{active=true, identifier=D-1, valid=true, server-token=x}","#
        + #""lastUpdateTime":"2026-09-04T07:00:00.000"},"#
        + #"{"key":"mdm.push-token","value":"SECRET","#
        + #""lastUpdateTime":"2026-09-04T07:00:00.000"}]}"#

    private func runScan(
        force: Bool = true, skipExpensive: Bool = false,
        probe: @escaping ReportEngine.AuthConfirmationProbe =
            ReportEngine.defaultAuthConfirmationProbe,
        deviceLimits: ReportEngine.DeviceCallLimits = ReportEngine.DeviceCallLimits(),
        scanStop: (@Sendable (Int) -> Bool)? = nil
    ) async throws -> [String] {
        let stub = try makeStub()
        let collector = LogTextCollector()
        try await ReportEngine.collect(
            workspace: WorkspaceID(validating: profile),
            profile: profile, workspacePaths: WorkspacePaths.self,
            tiers: [.scan], skipExpensive: skipExpensive, force: force,
            authConfirmationProbe: probe, locateJamfCLI: { stub },
            deviceLimits: deviceLimits, scanStop: scanStop, now: .testNoon,
            onLine: collector.append)
        return collector.texts
    }

    private func latest<T: Decodable>(_ kind: String, as: T.Type) throws -> T? {
        let dir = try WorkspacePaths.dataDir(for: profile)
            .appendingPathComponent(kind, isDirectory: true)
        guard let url = FileManager.newestJSONFile(in: dir) else { return nil }
        return try JSONDecoder().decode(T.self, from: Data(contentsOf: url))
    }

    // MARK: - Happy path

    func testWritesBothSnapshotsAndNeverTheToken() async throws {
        try writeComputers([("1", "A", "m1", true), ("2", "B", "m2", false)])
        try answer("hist-1", failedHistory); try answer("hist-2", cleanHistory)
        try answer("ddm-m1", ddmPayload)
        let lines = try await runScan()

        let health = try XCTUnwrap(
            try latest("mdm-command-health", as: [MDMCommandHealthRecord].self)
        )
        XCTAssertEqual(health.map(\.deviceId).sorted(), ["1", "2"])
        XCTAssertEqual(health.first { $0.deviceId == "1" }?.failedCommands, ["InstallApplication"])

        let ddm = try XCTUnwrap(try latest("ddm-device-status", as: [DDMDeviceStatusRecord].self))
        XCTAssertEqual(ddm.map(\.deviceId), ["1"], "only the DDM-enabled Mac is queried")
        XCTAssertEqual(ddm.first?.declarations.first?.identifier, "D-1")
        let ddmDir = try WorkspacePaths.dataDir(for: profile)
            .appendingPathComponent("ddm-device-status")
        let raw = try String(
            contentsOf: try XCTUnwrap(FileManager.newestJSONFile(in: ddmDir)), encoding: .utf8
        )
        XCTAssertFalse(raw.contains("SECRET"))
        XCTAssertTrue(lines.contains { $0.hasPrefix("[ok] ddm-device-status") }, "\(lines)")
        XCTAssertTrue(lines.contains { $0.hasPrefix("[ok] mdm-command-health") }, "\(lines)")

        let store = StateFileStore(directory: try WorkspacePaths.stateDir(for: profile))
        XCTAssertNotNil(store.lastRun(report: "ddm-device-status"))
        XCTAssertNotNil(store.lastRun(report: "mdm-command-health"))

        let calls = callsLog()
        XCTAssertTrue(calls.contains("status-items m1"), calls)
        XCTAssertFalse(calls.contains("status-items m2"), calls)
    }

    // MARK: - Failure rules

    func testStatusItems404RecordsNotReportedNotAnError() async throws {
        try writeComputers([("1", "A", "m1", true)])
        try answer("hist-1", cleanHistory)
        try answer("ddm-m1", "", exit: Int(CLIBridge.exitCodeNotFound))
        let lines = try await runScan()
        let ddm = try XCTUnwrap(try latest("ddm-device-status", as: [DDMDeviceStatusRecord].self))
        XCTAssertEqual(ddm.first?.ddmReported, false)
        XCTAssertFalse(lines.contains { $0.contains("[partial] ddm-device-status") })
    }

    func testMoreThanAQuarterFailingRecordsTheKindFailedAndWritesNothing() async throws {
        try writeComputers([
            ("1", "A", "m1", false), ("2", "B", "m2", false),
            ("3", "C", "m3", false), ("4", "D", "m4", false),
        ])
        try answer("hist-1", cleanHistory); try answer("hist-2", cleanHistory)
        try answer("hist-3", "", exit: 1); try answer("hist-4", "", exit: 1)   // 2 of 4 = 50%
        let lines = try await runScan()
        XCTAssertNil(try latest("mdm-command-health", as: [MDMCommandHealthRecord].self))
        let store = StateFileStore(directory: try WorkspacePaths.stateDir(for: profile))
        XCTAssertEqual(store.failures(report: "mdm-command-health")?.count, 1)
        XCTAssertTrue(
            lines.contains { $0.contains("[partial] mdm-command-health") && $0.contains("2 of 4") },
            "\(lines)"
        )
    }

    func testBelowBudgetWritesAndMarksPartial() async throws {
        try writeComputers([
            ("1", "A", "m1", false), ("2", "B", "m2", false),
            ("3", "C", "m3", false), ("4", "D", "m4", false),
        ])
        for i in 1...3 { try answer("hist-\(i)", cleanHistory) }
        try answer("hist-4", "", exit: 1)   // 1 of 4 = 25%, not more
        let lines = try await runScan()
        let health = try XCTUnwrap(
            try latest("mdm-command-health", as: [MDMCommandHealthRecord].self)
        )
        XCTAssertEqual(health.count, 3)
        XCTAssertTrue(
            lines.contains { $0 == "[partial] mdm-command-health: 1 of 4 devices did not respond" },
            "\(lines)"
        )
    }

    func testExit6StopsTheCallType() async throws {
        try writeComputers([("1", "A", "m1", false), ("2", "B", "m2", false)])
        try answer("hist-1", "", exit: Int(CLIBridge.exitCodeRateLimited))
        try answer("hist-2", cleanHistory)
        _ = try await runScan()
        XCTAssertNil(try latest("mdm-command-health", as: [MDMCommandHealthRecord].self))
        let store = StateFileStore(directory: try WorkspacePaths.stateDir(for: profile))
        XCTAssertEqual(
            store.lastFailureExitCode(for: "mdm-command-health"), CLIBridge.exitCodeRateLimited
        )
    }

    /// A server that never answers costs the limit on every device; three timed-out calls in a
    /// row stop the call type, recorded with the timeout's code so it stays retryable.
    func testThreeTimedOutCallsInARowStopTheCallType() async throws {
        let ids = (1...20).map { String($0) }
        try writeComputers(ids.map { ($0, "Mac\($0)", "m\($0)", false) })
        for id in ids {
            try answer("hist-\(id)", cleanHistory)
            try "".write(to: answers.appendingPathComponent("hist-\(id).sleep"),
                         atomically: true, encoding: .utf8)
        }

        let lines = try await runScan(
            deviceLimits: .init(timeout: 1, stopAfterTimeouts: 3))

        let calls = ids.reduce(0) { $0 + historyCalls(for: $1) }
        XCTAssertGreaterThanOrEqual(calls, 3)
        XCTAssertLessThan(calls, 10, "the call type must stop, not time out on all 20 devices")
        XCTAssertTrue(
            lines.contains {
                $0.contains("stopped mdm-command-health: 3 calls in a row timed out after 1 s")
            }, "\(lines)")
        XCTAssertTrue(
            lines.contains { $0.hasPrefix("[partial] mdm-command-health: stopped after repeated") },
            "the partial line must say timeouts, not exit -2: \(lines)")
        XCTAssertNil(try latest("mdm-command-health", as: [MDMCommandHealthRecord].self))
        let store = StateFileStore(directory: try WorkspacePaths.stateDir(for: profile))
        XCTAssertEqual(
            store.lastFailureExitCode(for: "mdm-command-health"), CLIBridge.exitCodeTimedOut)
        XCTAssertFalse(WorkspaceStore.lastFailureRepeatsOnRetry("mdm-command-health", in: store),
                       "a timeout stop is retried by the next run")
    }

    // MARK: - Cadence floor (a failed attempt still counts as an attempt)

    func testChronicFailureIsNotRetriedInsideTheCadence() async throws {
        try writeComputers([("1", "A", "m1", false)])
        try answer("hist-1", cleanHistory)
        let store = StateFileStore(directory: try WorkspacePaths.stateDir(for: profile))
        let now = Date()
        store.record(.landed, report: "ddm-device-status", at: now)
        store.record(.failed(exitCode: nil), report: "mdm-command-health", at: now)
        let lines = try await runScan(force: false)
        XCTAssertTrue(lines.contains { $0 == "[skip] device scan: not due" }, "\(lines)")
        XCTAssertNil(try latest("mdm-command-health", as: [MDMCommandHealthRecord].self))
    }

    func testCredentialFailureDoesNotHoldTheScanForAWeek() async throws {
        try writeComputers([("1", "A", "m1", false)])
        try answer("hist-1", cleanHistory)
        let store = StateFileStore(directory: try WorkspacePaths.stateDir(for: profile))
        let now = Date()
        store.record(.landed, report: "ddm-device-status", at: now)
        store.record(
            .landed, report: "mdm-command-health", at: now.addingTimeInterval(-8 * 86_400))
        store.record(
            .failed(exitCode: CLIBridge.exitCodeUnauthorized), report: "mdm-command-health",
            at: now.addingTimeInterval(-86_400))
        let lines = try await runScan(force: false)
        XCTAssertFalse(lines.contains { $0 == "[skip] device scan: not due" }, "\(lines)")
        XCTAssertNotNil(try latest("mdm-command-health", as: [MDMCommandHealthRecord].self))
    }

    func testForceIgnoresTheCadenceFloor() async throws {
        try writeComputers([("1", "A", "m1", false)])
        try answer("hist-1", cleanHistory)
        let store = StateFileStore(directory: try WorkspacePaths.stateDir(for: profile))
        let now = Date()
        store.record(.landed, report: "ddm-device-status", at: now)
        store.record(.failed(exitCode: nil), report: "mdm-command-health", at: now)
        _ = try await runScan(force: true)
        XCTAssertNotNil(try latest("mdm-command-health", as: [MDMCommandHealthRecord].self))
    }

    func testExit3AfterExit8KeepsTheExit8Record() async throws {
        try writeComputers([("1", "A", "m1", true)])
        try answer("hist-1", "", exit: Int(CLIBridge.exitCodeRefusedByPolicy))
        try answer("ddm-m1", "", exit: Int(CLIBridge.exitCodeUnauthorized))
        _ = try await runScan()

        let store = StateFileStore(directory: try WorkspacePaths.stateDir(for: profile))
        XCTAssertEqual(
            store.lastFailureExitCode(for: "mdm-command-health"),
            CLIBridge.exitCodeRefusedByPolicy,
            "the earlier exit 8 on history must survive a later exit 3 on the other call type"
        )
        XCTAssertEqual(
            store.lastFailureExitCode(for: "ddm-device-status"), CLIBridge.exitCodeUnauthorized
        )
    }

    func testExit5OnFirstDeviceStopsThatCallTypeOnly() async throws {
        try writeComputers([("1", "A", "m1", true), ("2", "B", "m2", true)])
        try answer("hist-1", cleanHistory); try answer("hist-2", cleanHistory)
        try answer("ddm-m1", "", exit: Int(CLIBridge.exitCodePermissionDenied))
        try answer("ddm-m2", ddmPayload)
        let lines = try await runScan()
        XCTAssertNil(try latest("ddm-device-status", as: [DDMDeviceStatusRecord].self),
                     "the status-items call type stopped after the first 403")
        XCTAssertNotNil(try latest("mdm-command-health", as: [MDMCommandHealthRecord].self),
                        "the history call type carried on")
        XCTAssertTrue(lines.contains { $0.contains("Read Computers") }, "\(lines)")
        XCTAssertTrue(lines.contains { $0.contains("Inventory > Devices (Jamf Account)") },
                      "a gateway profile needs the Jamf Account permission: \(lines)")

        let store = StateFileStore(directory: try WorkspacePaths.stateDir(for: profile))
        XCTAssertEqual(
            store.lastFailureExitCode(for: "ddm-device-status"),
            CLIBridge.exitCodePermissionDenied
        )
        XCTAssertNotNil(store.lastRun(report: "mdm-command-health"))
    }

    /// jamf-cli's hint names the grant for the API that answered; the scan passes it on.
    func testExit5NamesThePermissionFromJamfCLIsHint() async throws {
        try writeComputers([("1", "A", "m1", true)])
        try answer("hist-1", cleanHistory)
        let hint = "grant the Jamf Platform API integration these permissions in Jamf Account: "
            + "Inventory > Devices: Read (devices:read). Names are as the permission picker "
            + "shows them: <map URL>"
        let envelope: [String: Any] = [
            "error": "request failed", "message": "permission denied (HTTP 403)",
            "exitCode": 5, "exitCodeName": "permission", "hint": hint,
        ]
        let body = String(
            decoding: try JSONSerialization.data(withJSONObject: envelope), as: UTF8.self)
        try answer("ddm-m1", body, exit: Int(CLIBridge.exitCodePermissionDenied))
        let lines = try await runScan()
        let warn = try XCTUnwrap(lines.first { $0.contains("exit 5 from a device") }, "\(lines)")
        XCTAssertTrue(
            warn.contains("missing permission: Inventory > Devices: Read (devices:read)"), warn)
        XCTAssertFalse(warn.contains("Read Computers"), warn)
    }

    /// Fixture is UNCAPTURED (go-keyring's error shape, on stderr only): a locked keychain
    /// fails every device with exit 1, so the scan stops both call types after the first.
    func testLockedKeychainOnStderrStopsTheScanAndRecordsTheCause() async throws {
        try writeComputers([("1", "A", "m1", true), ("2", "B", "m2", true)])
        for id in ["1", "2"] {
            try answer("hist-\(id)", "", exit: 1)
            try "Error: reading keychain item jamf-cli/p/client-secret: exit status 36\n".write(
                to: answers.appendingPathComponent("hist-\(id).err"), atomically: true,
                encoding: .utf8)
        }
        let lines = try await runScan()
        XCTAssertTrue(lines.contains { $0.contains("login keychain is locked") }, "\(lines)")
        XCTAssertNil(try latest("mdm-command-health", as: [MDMCommandHealthRecord].self))
        XCTAssertNil(try latest("ddm-device-status", as: [DDMDeviceStatusRecord].self))
        let store = StateFileStore(directory: try WorkspacePaths.stateDir(for: profile))
        XCTAssertEqual(store.cause(for: "mdm-command-health")?.kind, .keychainLocked)
        XCTAssertEqual(store.cause(for: "ddm-device-status")?.kind, .keychainLocked)
    }

    func testExit8SkipsHistoryForTheRun() async throws {
        try writeComputers([("1", "A", "m1", true)])
        try answer("hist-1", "", exit: Int(CLIBridge.exitCodeRefusedByPolicy))
        try answer("ddm-m1", ddmPayload)
        let lines = try await runScan()
        XCTAssertNil(try latest("mdm-command-health", as: [MDMCommandHealthRecord].self))
        XCTAssertNotNil(try latest("ddm-device-status", as: [DDMDeviceStatusRecord].self))
        XCTAssertTrue(
            lines.contains {
                $0.contains("mdm-command-health") && $0.contains("refused by policy")
            },
            "\(lines)"
        )

        let store = StateFileStore(directory: try WorkspacePaths.stateDir(for: profile))
        XCTAssertEqual(
            store.lastFailureExitCode(for: "mdm-command-health"),
            CLIBridge.exitCodeRefusedByPolicy
        )
        XCTAssertNotNil(store.lastRun(report: "ddm-device-status"))
    }

    /// The background item's same-day retry reads this phase's `[partial]` lines (#207): a
    /// kind stopped by a policy refusal is one a retry would only repeat.
    func testAPolicyStoppedScanIsNotRetriedTheSameDay() async throws {
        try writeComputers([("1", "A", "m1", false)])
        try answer("hist-1", "", exit: Int(CLIBridge.exitCodeRefusedByPolicy))
        let watcher = try await scanWithTodaysSummaryWritten()
        XCTAssertFalse(watcher.retryCouldHelp(profile: profile, now: .testNoon))
    }

    /// A scan stopped by rejected credentials is retried: its cadence floor leaves exit 3
    /// out, so the retry rescans once someone re-authenticates.
    func testACredentialStoppedScanIsStillRetriedTheSameDay() async throws {
        try writeComputers([("1", "A", "m1", false)])
        try answer("hist-1", "", exit: Int(CLIBridge.exitCodeUnauthorized))
        let watcher = try await scanWithTodaysSummaryWritten(probe: { _, _ in false })
        XCTAssertTrue(watcher.retryCouldHelp(profile: profile, now: .testNoon))
    }

    /// Runs the scan after today's summary is on disk, as the day's freshness run leaves it
    /// before a weekly scan, and returns a watcher fed with the run's lines.
    private func scanWithTodaysSummaryWritten(
        probe: @escaping ReportEngine.AuthConfirmationProbe =
            ReportEngine.defaultAuthConfirmationProbe
    ) async throws -> CollectHonestyWatcher {
        let summaries = try WorkspacePaths.summariesDir(for: profile)
        try FileManager.default.createDirectory(at: summaries, withIntermediateDirectories: true)
        let today = SummaryJSONParser.dateFormatter.string(from: .testNoon)
        try #"{"date":"\#(today)","totalDevices":1,"source":"jamf-cli"}"#.write(
            to: summaries.appendingPathComponent("summary_\(today).json"),
            atomically: true, encoding: .utf8)
        let lines = try await runScan(probe: probe)
        let watcher = CollectHonestyWatcher()
        lines.forEach(watcher.observe)
        XCTAssertTrue(watcher.incomplete, "\(lines)")
        return watcher
    }

    func testExit3StopsBothCallTypes() async throws {
        try writeComputers([("1", "A", "m1", true)])
        try answer("hist-1", "", exit: Int(CLIBridge.exitCodeUnauthorized))
        try answer("ddm-m1", ddmPayload)
        // The token check passes but the retry is rejected again: a real 401, so stop.
        let lines = try await runScan(probe: { _, _ in true })
        XCTAssertNil(try latest("mdm-command-health", as: [MDMCommandHealthRecord].self))
        XCTAssertNil(try latest("ddm-device-status", as: [DDMDeviceStatusRecord].self))
        XCTAssertTrue(
            lines.contains { $0.contains("stopping both call types") }, "\(lines)"
        )

        let store = StateFileStore(directory: try WorkspacePaths.stateDir(for: profile))
        XCTAssertEqual(
            store.lastFailureExitCode(for: "mdm-command-health"), CLIBridge.exitCodeUnauthorized
        )
        XCTAssertEqual(
            store.lastFailureExitCode(for: "ddm-device-status"), CLIBridge.exitCodeUnauthorized
        )
        XCTAssertEqual(historyCalls(for: "1"), 2, "a confirmed token gets exactly one retry")
        XCTAssertTrue(lines.contains {
            $0.hasPrefix("[partial] mdm-command-health: stopped after exit 3")
        }, "a kind that was not written must mark the run partial: \(lines)")
    }

    func testExit3WithAFreshTokenRetriesOnceAndLands() async throws {
        try writeComputers([("1", "A", "m1", false)])
        try answer("hist-1", cleanHistory, exit: Int(CLIBridge.exitCodeUnauthorized))
        let answers: URL = self.answers
        let counter = ProbeCounter()
        // The fresh token is what fixes the device, so the probe clears its failure.
        let lines = try await runScan(probe: { _, _ in
            await counter.record()
            try? FileManager.default.removeItem(at: answers.appendingPathComponent("hist-1.exit"))
            return true
        })

        let health = try XCTUnwrap(
            try latest("mdm-command-health", as: [MDMCommandHealthRecord].self)
        )
        XCTAssertEqual(health.map(\.deviceId), ["1"])
        XCTAssertFalse(lines.contains { $0.contains("stopping both call types") }, "\(lines)")
        XCTAssertTrue(lines.contains { $0.contains("got a fresh token") }, "\(lines)")
        XCTAssertEqual(historyCalls(for: "1"), 2)
        let probeCalls = await counter.calls
        XCTAssertEqual(probeCalls, 1)
    }

    func testExit3WithoutAFreshTokenStopsWithoutRetrying() async throws {
        try writeComputers([("1", "A", "m1", true)])
        try answer("hist-1", "", exit: Int(CLIBridge.exitCodeUnauthorized))
        try answer("ddm-m1", ddmPayload)
        let counter = ProbeCounter()
        let lines = try await runScan(probe: { _, _ in await counter.record(); return false })

        XCTAssertNil(try latest("mdm-command-health", as: [MDMCommandHealthRecord].self))
        XCTAssertNil(try latest("ddm-device-status", as: [DDMDeviceStatusRecord].self))
        XCTAssertTrue(lines.contains { $0.contains("stopping both call types") }, "\(lines)")
        XCTAssertEqual(historyCalls(for: "1"), 1, "no retry when the token check fails")
        XCTAssertFalse(callsLog().contains("status-items"), "the DDM call type stopped too")
        let probeCalls = await counter.calls
        XCTAssertEqual(probeCalls, 1)
    }

    func testSimultaneousExit3sShareOneTokenCheck() async throws {
        let ids = ["1", "2", "3", "4"]
        try writeComputers(ids.map { (id: $0, name: "M\($0)", mgmt: "m\($0)", ddm: false) })
        for id in ids {
            try answer("hist-\(id)", cleanHistory, exit: Int(CLIBridge.exitCodeUnauthorized))
        }
        let answers: URL = self.answers
        let counter = ProbeCounter()
        // A slow check stays in flight while the other three devices are rejected.
        _ = try await runScan(probe: { _, _ in
            await counter.record()
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            for id in ids {
                try? FileManager.default.removeItem(
                    at: answers.appendingPathComponent("hist-\(id).exit"))
            }
            return true
        })

        let probeCalls = await counter.calls
        XCTAssertEqual(probeCalls, 1, "devices rejected together must share one token check")
        let health = try XCTUnwrap(
            try latest("mdm-command-health", as: [MDMCommandHealthRecord].self)
        )
        XCTAssertEqual(health.count, 4)
    }

    func testTokenCheckForcesAFreshExchange() async throws {
        let stub = try makeStub()
        _ = await ReportEngine.defaultAuthConfirmationProbe(profile, stub)
        XCTAssertTrue(callsLog().contains("pro auth token --refresh"), callsLog())
    }

    func testZeroDDMDevicesLandsAnEmptySnapshot() async throws {
        try writeComputers([("1", "A", "m1", false), ("2", "B", "m2", false)])
        try answer("hist-1", cleanHistory); try answer("hist-2", cleanHistory)
        let lines = try await runScan()

        let ddm = try latest("ddm-device-status", as: [DDMDeviceStatusRecord].self)
        XCTAssertNotNil(ddm, "a fleet with no DDM-enabled Macs still lands a snapshot")
        XCTAssertEqual(ddm ?? [], [])
        XCTAssertTrue(
            lines.contains { $0 == "[ok] ddm-device-status: 0 device(s)" }, "\(lines)"
        )

        let store = StateFileStore(directory: try WorkspacePaths.stateDir(for: profile))
        XCTAssertNotNil(store.lastRun(report: "ddm-device-status"))
    }

    func testNoComputersSnapshotSkipsWithOneLine() async throws {
        // No computers snapshot written to disk at all.
        let lines = try await runScan()
        XCTAssertTrue(
            lines.contains { $0 == "[skip] device scan: no computers snapshot" }, "\(lines)"
        )
        XCTAssertNil(try latest("mdm-command-health", as: [MDMCommandHealthRecord].self))
    }

    func testSkipExpensiveSkipsTheWholePhase() async throws {
        try writeComputers([("1", "A", "m1", true)])
        try answer("hist-1", failedHistory); try answer("ddm-m1", ddmPayload)
        _ = try await runScan(skipExpensive: true)
        XCTAssertNil(try latest("mdm-command-health", as: [MDMCommandHealthRecord].self))
        XCTAssertNil(try latest("ddm-device-status", as: [DDMDeviceStatusRecord].self))
    }

    func testAllDevicesCompleteAcrossTheConcurrencyWindow() async throws {
        // Each history answer is served by a stub that records its own PID
        // overlap; simpler and deterministic: assert the code constant, and
        // that 12 devices complete (the window logic drains fully).
        XCTAssertEqual(ReportEngine.deviceScanConcurrency, 4)
        let rows = (1...12).map { ("\($0)", "M\($0)", "m\($0)", false) }
        try writeComputers(rows)
        for i in 1...12 { try answer("hist-\(i)", cleanHistory) }
        _ = try await runScan()
        let health = try XCTUnwrap(
            try latest("mdm-command-health", as: [MDMCommandHealthRecord].self)
        )
        XCTAssertEqual(health.count, 12)
    }

    func testUnsafeDeviceIdIsSkippedNotPassedToArgv() async throws {
        try writeComputers([("-rf", "Evil", "m1", false), ("2", "B", "m2", false)])
        try answer("hist-2", cleanHistory)
        let lines = try await runScan()
        let health = try XCTUnwrap(
            try latest("mdm-command-health", as: [MDMCommandHealthRecord].self)
        )
        XCTAssertEqual(health.map(\.deviceId), ["2"])
        XCTAssertTrue(lines.contains { $0.contains("unsafe id") }, "\(lines)")
    }

    /// `isSafeDeviceIdentifier` trims before it checks, so a padded id used to pass the check
    /// and reach argv padded. Both ids are trimmed once at decode, for argv and the rows alike.
    func testPaddedIdsReachArgvAndRowsTrimmed() async throws {
        try writeComputers([(" 2 ", "B", " m2 ", true)])
        try answer("hist-2", cleanHistory)
        try answer("ddm-m2", ddmPayload)
        _ = try await runScan()

        XCTAssertEqual(historyCalls(for: "2"), 1, callsLog())
        XCTAssertTrue(callsLog().contains("status-items m2 "), callsLog())
        let health = try XCTUnwrap(
            try latest("mdm-command-health", as: [MDMCommandHealthRecord].self)
        )
        XCTAssertEqual(health.map(\.deviceId), ["2"])
        let ddm = try XCTUnwrap(try latest("ddm-device-status", as: [DDMDeviceStatusRecord].self))
        XCTAssertEqual(ddm.map(\.deviceId), ["2"])
        XCTAssertEqual(ddm.map(\.managementId), ["m2"])
    }

    /// A device listed twice in `computers` is scanned once and lands once in each
    /// snapshot, so the DDM and command-health sheets do not repeat it.
    func testADeviceListedTwiceIsScannedOnce() async throws {
        try writeComputers([("2", "B", "m2", true), ("2", "B", "m2", true)])
        try answer("hist-2", cleanHistory)
        try answer("ddm-m2", ddmPayload)
        _ = try await runScan()

        XCTAssertEqual(historyCalls(for: "2"), 1, callsLog())
        let health = try XCTUnwrap(
            try latest("mdm-command-health", as: [MDMCommandHealthRecord].self)
        )
        XCTAssertEqual(health.map(\.deviceId), ["2"])
        let ddm = try XCTUnwrap(try latest("ddm-device-status", as: [DDMDeviceStatusRecord].self))
        XCTAssertEqual(ddm.map(\.deviceId), ["2"])
    }

    /// Every device is filtered out by the unsafe-id guard, so `targets` is
    /// empty. Nothing was attempted: no snapshot lands, and neither the
    /// success nor the failure counters advance — a run that reaches no
    /// device is neither a landing nor a failure.
    func testAllUnsafeIdsAttemptsNothingAndLandsNothing() async throws {
        try writeComputers([("-rf", "Evil", "m1", false), ("-x", "Also Evil", "m2", false)])
        let lines = try await runScan()
        let warning = "[warn] device scan: no reachable devices — nothing attempted"
        XCTAssertTrue(lines.contains { $0 == warning }, "\(lines)")
        XCTAssertNil(try latest("mdm-command-health", as: [MDMCommandHealthRecord].self))
        XCTAssertNil(try latest("ddm-device-status", as: [DDMDeviceStatusRecord].self))
        let store = StateFileStore(directory: try WorkspacePaths.stateDir(for: profile))
        XCTAssertNil(store.lastRun(report: "mdm-command-health"))
        XCTAssertNil(store.failures(report: "mdm-command-health"))
    }

    // MARK: - jamf_cli.collect_skip

    /// A listed kind never reaches jamf-cli, even on a forced collect, and records
    /// nothing — like the Platform-only skip, it is not a failure. The scan tier's
    /// other argv kind still runs.
    func testCollectSkipKeepsAListedKindAwayFromJamfCLI() async throws {
        let ws = try XCTUnwrap(ProfileService.workspaceURL(for: profile))
        try "jamf_cli:\n  profile: \"\(profile)\"\n  collect_skip: [patch_device_failures]\n"
            .write(to: ws.appendingPathComponent("config.yaml"), atomically: true, encoding: .utf8)
        let lines = try await runScan()

        XCTAssertTrue(
            lines.contains("[skip] patch-device-failures: listed in jamf_cli.collect_skip"),
            "\(lines)")
        let calls = callsLog()
        XCTAssertFalse(calls.contains("patch-status --scan-failures"), calls)
        XCTAssertTrue(calls.contains("update-status --scan-failures"), calls)
        let store = StateFileStore(directory: try WorkspacePaths.stateDir(for: profile))
        XCTAssertNil(store.lastRun(report: "patch-device-failures"))
        XCTAssertNil(store.failures(report: "patch-device-failures"))
    }

    /// A scan call type turned off makes no call and records nothing; the other still lands.
    func testCollectSkipTurnsOffOneScanCallType() async throws {
        let ws = try XCTUnwrap(ProfileService.workspaceURL(for: profile))
        try "jamf_cli:\n  profile: \"\(profile)\"\n  collect_skip: [mdm_command_health]\n"
            .write(to: ws.appendingPathComponent("config.yaml"), atomically: true, encoding: .utf8)
        try writeComputers([("1", "A", "m1", true)])
        try answer("hist-1", cleanHistory); try answer("ddm-m1", ddmPayload)
        let lines = try await runScan()

        XCTAssertTrue(
            lines.contains("[skip] mdm-command-health: listed in jamf_cli.collect_skip"),
            "\(lines)")
        XCTAssertFalse(callsLog().contains("classic-computer-history"), callsLog())
        XCTAssertNotNil(try latest("ddm-device-status", as: [DDMDeviceStatusRecord].self))
        XCTAssertNil(try latest("mdm-command-health", as: [MDMCommandHealthRecord].self))
        let store = StateFileStore(directory: try WorkspacePaths.stateDir(for: profile))
        XCTAssertNotNil(store.lastRun(report: "ddm-device-status"))
        XCTAssertNil(store.lastRun(report: "mdm-command-health"))
        XCTAssertNil(store.failures(report: "mdm-command-health"))
    }

    func testCollectSkipTurnsOffTheDDMCallType() async throws {
        let ws = try XCTUnwrap(ProfileService.workspaceURL(for: profile))
        try "jamf_cli:\n  profile: \"\(profile)\"\n  collect_skip: [ddm-device-status]\n"
            .write(to: ws.appendingPathComponent("config.yaml"), atomically: true, encoding: .utf8)
        try writeComputers([("1", "A", "m1", true)])
        try answer("hist-1", cleanHistory); try answer("ddm-m1", ddmPayload)
        _ = try await runScan()

        XCTAssertFalse(callsLog().contains("status-items"), callsLog())
        XCTAssertNotNil(try latest("mdm-command-health", as: [MDMCommandHealthRecord].self))
        XCTAssertNil(try latest("ddm-device-status", as: [DDMDeviceStatusRecord].self))
        let store = StateFileStore(directory: try WorkspacePaths.stateDir(for: profile))
        XCTAssertNil(store.failures(report: "ddm-device-status"))
    }

    /// A shared workspace scans by the list this Mac confirmed, not the one a peer wrote.
    func testAPinnedWorkspaceScansByThePinnedList() async throws {
        let ws = try XCTUnwrap(ProfileService.workspaceURL(for: profile))
        let config = ws.appendingPathComponent("config.yaml")
        let text = { (list: String) in
            "shared_workspace:\n  enabled: true\njamf_cli:\n  profile: \"\(self.profile)\"\n"
                + "  collect_skip: \(list)\n"
        }
        try text("[mdm-command-health]").write(to: config, atomically: true, encoding: .utf8)
        _ = SharedConfigPin.check(profile: profile)
        try text("[]").write(to: config, atomically: true, encoding: .utf8)
        try writeComputers([("1", "A", "m1", true)])
        try answer("hist-1", cleanHistory); try answer("ddm-m1", ddmPayload)
        let lines = try await runScan()

        XCTAssertTrue(
            lines.contains("[skip] mdm-command-health: listed in jamf_cli.collect_skip"),
            "\(lines)")
        XCTAssertFalse(callsLog().contains("classic-computer-history"), callsLog())
    }

    /// An unreadable snapshot of a kind that is off cannot hold up the kind that is on.
    func testAnUnreadableSnapshotOfAnOffKindDoesNotBlockThePass() async throws {
        let ws = try XCTUnwrap(ProfileService.workspaceURL(for: profile))
        try "jamf_cli:\n  profile: \"\(profile)\"\n  collect_skip: [mdm-command-health]\n"
            .write(to: ws.appendingPathComponent("config.yaml"), atomically: true, encoding: .utf8)
        let dir = try WorkspacePaths.dataDir(for: profile)
            .appendingPathComponent("mdm-command-health", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try "not json".write(
            to: dir.appendingPathComponent("mdm-command-health_20260903T120000.json"),
            atomically: true, encoding: .utf8)
        try writeComputers([("1", "A", "m1", true)])
        try answer("ddm-m1", ddmPayload)
        let lines = try await runScan(force: false)

        XCTAssertFalse(lines.contains { $0.contains("could not be read") }, "\(lines)")
        XCTAssertNotNil(try latest("ddm-device-status", as: [DDMDeviceStatusRecord].self))
    }

    /// A fleet with no computers: the scan is skipped, nothing recorded, the run not Partial.
    func testAFleetWithNoComputersSkipsTheScanAndRecordsNothing() async throws {
        let data = try WorkspacePaths.dataDir(for: profile)
        try GoldenFleetWorkspace.writeSnapshot(
            kind: "overview", dataDir: data, at: Date().addingTimeInterval(-60), rows: [
                ["section": "Fleet", "resource": "Managed Computers", "value": 0],
                ["section": "Fleet", "resource": "Unmanaged Computers", "value": 0],
                ["section": "Fleet", "resource": "Managed Devices", "value": 4],
                ["section": "Fleet", "resource": "Unmanaged Devices", "value": 0],
            ])
        try GoldenFleetWorkspace.writeSnapshot(
            kind: "computers", dataDir: data, at: Date().addingTimeInterval(-60), rows: [])
        try GoldenFleetWorkspace.writeSnapshot(
            kind: "mobile-devices-list", dataDir: data, at: Date().addingTimeInterval(-60),
            rows: (0..<4).map { ["id": "\($0)", "name": "iPad \($0)", "deviceType": "iOS"] })
        let lines = try await runScan()

        XCTAssertTrue(lines.contains("[plan] device scan: skipped (no computers in Jamf Pro)"),
                      "\(lines)")
        XCTAssertFalse(lines.contains { $0.hasPrefix("[partial]") }, "\(lines)")
        XCTAssertFalse(callsLog().contains("classic-computer-history"), callsLog())
        let store = StateFileStore(directory: try WorkspacePaths.stateDir(for: profile))
        XCTAssertNil(store.failures(report: "mdm-command-health"))
        XCTAssertNil(store.lastRun(report: "mdm-command-health"))
    }

    // MARK: - A dead matrix verdict and the scan (#207 G17)

    /// Runs a scan-tier collect that must fail on its reports; returns the history calls made.
    private func runDeadScan() async throws -> Int {
        do {
            _ = try await runScan()
            XCTFail("a run whose reports landed nothing must still fail")
        } catch ReportEngineError.collectDead(_, let failedCount, _) {
            XCTAssertEqual(failedCount, 2)
        }
        return historyCalls(for: "1")
    }

    /// Both scan-tier reports exit 0 with nothing to save after jamf-cli printed a 403 on
    /// stderr, as for an API role without patch or software-update read. Jamf answered, so
    /// the scan, which reads the cached `computers`, still runs; the run still fails.
    /// The stderr line is the swallowed-403 shape `CollectFailureCauseTests` uses.
    func testReportsJamfRefusedStillLetTheScanRun() async throws {
        try writeComputers([("1", "A", "m1", false)])
        try answer("hist-1", cleanHistory)
        try answer("matrix", "")
        try answer("matrix.err", "Error: fetching plans: permission denied (HTTP 403): forbidden\n")
        let calls = try await runDeadScan()
        XCTAssertEqual(calls, 1, callsLog())
        XCTAssertNotNil(try latest("mdm-command-health", as: [MDMCommandHealthRecord].self))
        XCTAssertNotNil(try latest("ddm-device-status", as: [DDMDeviceStatusRecord].self))
    }

    /// A report that exits 5 is a missing permission too: Jamf answered.
    func testReportsThatExit5StillLetTheScanRun() async throws {
        try writeComputers([("1", "A", "m1", false)])
        try answer("hist-1", cleanHistory)
        try answer("matrix", "", exit: Int(CLIBridge.exitCodePermissionDenied))
        let calls = try await runDeadScan()
        XCTAssertEqual(calls, 1, callsLog())
    }

    /// Exit 0 with nothing to save and nothing on stderr is what `update-status` prints
    /// after its fetches fail (spec §13.2): an outage shape, so no fan-out.
    func testReportsThatCameBackEmptyWithoutACauseDoNotScan() async throws {
        try writeComputers([("1", "A", "m1", false)])
        try answer("hist-1", cleanHistory)
        try answer("matrix", "")
        let calls = try await runDeadScan()
        XCTAssertEqual(calls, 0, callsLog())
    }

    func testAMatrixOutageStillStopsBeforeTheScan() async throws {
        try writeComputers([("1", "A", "m1", false)])
        try answer("hist-1", cleanHistory)
        try answer("matrix", "", exit: Int(CLIBridge.exitCodeNotFound))
        do {
            _ = try await runScan()
            XCTFail("an outage must fail the run")
        } catch ReportEngineError.collectDead {}
        XCTAssertEqual(historyCalls(for: "1"), 0, callsLog())
    }

    func testDeadCredentialsStillStopBeforeTheScan() async throws {
        try writeComputers([("1", "A", "m1", false)])
        try answer("hist-1", cleanHistory)
        try answer("matrix", "", exit: Int(CLIBridge.exitCodeUnauthorized))
        do {
            _ = try await runScan(probe: { _, _ in false })
            XCTFail("dead credentials must fail the run")
        } catch ReportEngineError.authExpired {}
        XCTAssertEqual(historyCalls(for: "1"), 0, callsLog())
    }

    func testOnlyCausesThatShowJamfAnsweredLetADeadRunScan() {
        typealias Outcome = ReportEngine.CollectOutcome
        func allows(_ outcomes: [Outcome]) -> Bool {
            ReportEngine.deadRunAllowsDeviceScan(outcomes)
        }
        let refused = Outcome(kind: "a", exitCode: 0, cause: .missingPermission)
        let denied = Outcome(
            kind: "b", exitCode: CLIBridge.exitCodePermissionDenied, cause: .missingPermission)
        let plansOff = Outcome(kind: "c", exitCode: 0, cause: .softwareUpdatePlansOff)
        let noBenchmark = Outcome(kind: "d", exitCode: 0, cause: .noConfiguredBenchmark)
        let usage = Outcome(kind: "e", exitCode: CLIBridge.exitCodeUsage, cause: .other)
        XCTAssertTrue(allows([refused, denied, plansOff, noBenchmark]))
        XCTAssertTrue(allows([refused, usage]),
                      "a usage error says nothing about the server, as in isCollectDead")
        XCTAssertFalse(allows([refused, Outcome(kind: "f", exitCode: 0, cause: .other)]),
                       "exit 0 with no cause is the shape of fetches that failed")
        XCTAssertFalse(allows([refused, Outcome(kind: "g", exitCode: 0)]), "not JSON")
        XCTAssertFalse(allows([refused, Outcome(kind: "h", exitCode: 1, cause: .other)]))
        XCTAssertFalse(allows([refused, Outcome(
            kind: "i", exitCode: ReportEngine.launchFailureExitCode)]))
        XCTAssertFalse(allows([Outcome(kind: "j", exitCode: 4, cause: .scopeRejected)]),
                       "a rejected scope answers for the scan's credential too")
    }
}

/// Same helper `CollectHonestyTests` keeps privately; duplicated here rather
/// than made shared, to keep that file's blast radius zero.
private final class LogTextCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []
    var append: @Sendable (CLIBridge.LogLine) -> Void {
        { line in self.lock.lock(); defer { self.lock.unlock() }; self.lines.append(line.text) }
    }
    var texts: [String] { lock.lock(); defer { lock.unlock() }; return lines }
}

/// Counts confirmation-probe calls from inside a `@Sendable` probe closure.
private actor ProbeCounter {
    private(set) var calls = 0
    func record() { calls += 1 }
}

extension DeviceScanCollectTests {
    // MARK: - Passes (large-fleet L3)

    private func store() throws -> StateFileStore {
        StateFileStore(directory: try WorkspacePaths.stateDir(for: profile))
    }

    /// An earlier `mdm-command-health` snapshot: Mac `i` scanned `days[i]` days ago.
    @discardableResult
    private func writeEarlierHealth(_ days: [String: Double]) throws -> [String: String] {
        let dir = try WorkspacePaths.dataDir(for: profile)
            .appendingPathComponent("mdm-command-health", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var stamps: [String: String] = [:]
        let rows = days.keys.sorted().map { id -> MDMCommandHealthRecord in
            let at = ISO8601Time.string(Date().addingTimeInterval(-days[id]! * 86_400))
            stamps[id] = at
            return MDMCommandHealthRecord(deviceId: id, name: "M\(id)", failedCount: 0,
                                          pendingCount: 0, failedCommands: [],
                                          oldestPendingDays: nil, scannedAt: at)
        }
        try JSONEncoder().encode(rows)
            .write(to: dir.appendingPathComponent("mdm-command-health_20260901T120000.json"))
        return stamps
    }

    private func scannedIDs() -> [String] {
        callsLog().split(separator: "\n").compactMap { line in
            guard let range = line.range(of: "classic-computer-history get ") else { return nil }
            return line[range.upperBound...].split(separator: " ").first.map(String.init)
        }
    }

    private func fleet(_ count: Int) throws -> [String] {
        let ids = (1...count).map(String.init)
        try writeComputers(ids.map { ($0, "M\($0)", "m\($0)", false) })
        for id in ids { try answer("hist-\(id)", cleanHistory) }
        return ids
    }

    /// Moves the open round's last pass back, as if the next pass ran the next day. 36 hours
    /// is always an earlier local day.
    private func nextDay() throws {
        let state = try store()
        var round = try XCTUnwrap(state.deviceScanRound())
        round.lastPass = round.lastPass.addingTimeInterval(-36 * 3_600)
        try state.recordDeviceScanRound(round)
    }

    private func stopAfter(_ n: Int) -> @Sendable (Int) -> Bool { { $0 >= n } }

    private func scanPartials(_ lines: [String]) -> [String] {
        lines.filter {
            $0.hasPrefix("[partial] mdm-command-health") || $0.hasPrefix("[partial] ddm-device")
        }
    }

    /// A stopped pass takes the oldest Macs, writes one snapshot holding every Mac, records
    /// nothing, and the round finishes on a later day's pass.
    func testAStoppedPassLeavesTheRestForTheNextDay() async throws {
        let ids = try fleet(8)
        // Oldest first: 8 (20 days), 7, 6 … 1 (13 days).
        let earlier = try writeEarlierHealth(
            Dictionary(uniqueKeysWithValues: ids.map { ($0, 12 + Double($0)!) }))
        let lines = try await runScan(force: false, scanStop: stopAfter(4))

        XCTAssertEqual(Set(scannedIDs()), ["8", "7", "6", "5"], "oldest first")
        XCTAssertTrue(lines.contains(
            "[info] device scan: scanned 4 of 8 Macs this pass; 4 left for the next pass"),
            "\(lines)")
        XCTAssertEqual(scanPartials(lines), [])
        let health = try XCTUnwrap(try latest("mdm-command-health", as: [MDMCommandHealthRecord].self))
        XCTAssertEqual(health.map(\.deviceId), ids, "every Mac is in the one snapshot")
        for row in health where !scannedIDs().contains(row.deviceId) {
            XCTAssertEqual(row.scannedAt, earlier[row.deviceId], "carried with its own date")
        }
        let state = try store()
        for kind in ["mdm-command-health", "ddm-device-status"] {
            XCTAssertNil(state.lastRun(report: kind), "an unfinished pass does not land \(kind)")
            XCTAssertNil(state.failures(report: kind), "nor records a failure")
        }
        XCTAssertEqual(state.deviceScanRound()?.remaining, 4)

        try nextDay()
        let finish = try await runScan(force: false)
        XCTAssertEqual(Set(scannedIDs().dropFirst(4)), ["1", "2", "3", "4"], "\(finish)")
        XCTAssertTrue(finish.contains { $0.hasPrefix("[ok] mdm-command-health: 8 device(s)") })
        XCTAssertNotNil(state.lastRun(report: "mdm-command-health"))
        XCTAssertNotNil(state.lastRun(report: "ddm-device-status"))
        XCTAssertNil(state.deviceScanRound())
    }

    /// A round file whose attempts cover every current target has nothing left: a new round
    /// starts and scans the Macs; nothing lands without an attempt.
    func testARoundThatCoversEveryTargetStartsAfresh() async throws {
        let ids = try fleet(3)
        let state = try store()
        try state.recordDeviceScanRound(DeviceScanRound(
            started: Date().addingTimeInterval(-2 * 86_400),
            lastPass: Date().addingTimeInterval(-36 * 3_600), attempted: ids, remaining: 2))
        let lines = try await runScan(force: false, scanStop: stopAfter(2))
        XCTAssertEqual(scannedIDs().count, 2, "\(lines)")
        XCTAssertNil(state.lastRun(report: "mdm-command-health"))
        XCTAssertEqual(state.deviceScanRound()?.attempted.count, 2, "a new round's attempts")
    }

    func testAPassThatAttemptsNothingLandsNothing() async throws {
        _ = try fleet(3)
        let lines = try await runScan(force: false, scanStop: { _ in true })
        XCTAssertTrue(scannedIDs().isEmpty)
        XCTAssertTrue(lines.contains(
            "[info] device scan: scanned 0 of 3 Macs this pass; 3 left for the next pass"))
        let state = try store()
        XCTAssertNil(state.lastRun(report: "mdm-command-health"))
        XCTAssertNil(state.lastRun(report: "ddm-device-status"))
        XCTAssertNil(state.deviceScanRound())
        XCTAssertNil(try latest("mdm-command-health", as: [MDMCommandHealthRecord].self))
    }

    func testAnUnreadableEarlierSnapshotIsNotOverwritten() async throws {
        _ = try fleet(3)
        let dir = try WorkspacePaths.dataDir(for: profile)
            .appendingPathComponent("mdm-command-health", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("mdm-command-health_20260901T120000.json")
        try "{not json".write(to: file, atomically: true, encoding: .utf8)
        let lines = try await runScan(force: false)
        XCTAssertTrue(lines.contains(
            "[warn] device scan: mdm-command-health snapshot could not be read; pass skipped"))
        XCTAssertTrue(scannedIDs().isEmpty)
        XCTAssertEqual(FileManager.newestJSONFile(in: dir), file)
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "{not json")
        let state = try store()
        XCTAssertNil(state.lastRun(report: "mdm-command-health"))
        XCTAssertNil(state.failures(report: "mdm-command-health"))
        XCTAssertNil(state.deviceScanRound())

        // A forced scan takes the whole fleet, so its snapshot is whole and replaces the bad
        // file; otherwise one corrupt file would block the scan until someone removed it.
        let forced = try await runScan(force: true)
        XCTAssertTrue(forced.contains(
            "[warn] device scan: mdm-command-health snapshot could not be read; "
                + "this full scan replaces it"))
        XCTAssertEqual(scannedIDs().count, 3)
        XCTAssertEqual(
            try latest("mdm-command-health", as: [MDMCommandHealthRecord].self)?.count, 3)
    }

    /// A pass with failures carries on: the 25% rule is judged over the round.
    func testAPassWithFailuresDoesNotEndTheRound() async throws {
        let ids = try fleet(8)
        for id in ["1", "2", "3"] { try answer("hist-\(id)", "", exit: 1) }
        let lines = try await runScan(force: false, scanStop: stopAfter(4))
        XCTAssertEqual(scanPartials(lines), [], "\(lines)")
        let state = try store()
        XCTAssertNil(state.failures(report: "mdm-command-health"))
        let round = try XCTUnwrap(state.deviceScanRound())
        XCTAssertEqual(round.history, DeviceScanTally(attempted: 4, failed: 3))
        XCTAssertEqual(round.remaining, ids.count - 4)
    }

    func testTheRoundTotalUnderAQuarterLandsAfterASmallFailingPass() async throws {
        _ = try fleet(8)
        _ = try await runScan(force: false, scanStop: stopAfter(6))
        try nextDay()
        // The final pass takes 7 and 8; one fails: half of the pass, 1 of 8 for the round.
        try answer("hist-8", "", exit: 1)
        let lines = try await runScan(force: false)
        let state = try store()
        XCTAssertNotNil(state.lastRun(report: "mdm-command-health"), "\(lines)")
        XCTAssertNil(state.failures(report: "mdm-command-health"))
        XCTAssertTrue(lines.contains { $0.hasPrefix("[partial] mdm-command-health: 1 of 8 ") })
    }

    func testTheRoundTotalOverAQuarterFailsTheKindAtTheRoundEnd() async throws {
        _ = try fleet(8)
        for id in ["1", "2"] { try answer("hist-\(id)", "", exit: 1) }
        _ = try await runScan(force: false, scanStop: stopAfter(6))
        let state = try store()
        XCTAssertNil(state.failures(report: "mdm-command-health"), "2 of 6 mid-round")
        try nextDay()
        try answer("hist-8", "", exit: 1)
        let lines = try await runScan(force: false)
        XCTAssertEqual(state.failures(report: "mdm-command-health")?.count, 1, "\(lines)")
        XCTAssertNil(state.lastRun(report: "mdm-command-health"))
        XCTAssertTrue(lines.contains {
            $0.hasPrefix("[partial] mdm-command-health: 3 of 8 devices failed")
        }, "\(lines)")
        XCTAssertNotNil(state.lastRun(report: "ddm-device-status"), "the other kind lands")
        XCTAssertNil(state.deviceScanRound())
    }

    func testAMacWhoseCallFailedKeepsItsEarlierRow() async throws {
        _ = try fleet(4)
        let earlier = try writeEarlierHealth(["1": 3, "2": 3, "3": 3, "4": 3])
        try answer("hist-2", "", exit: 1)
        _ = try await runScan()
        let health = try XCTUnwrap(try latest("mdm-command-health", as: [MDMCommandHealthRecord].self))
        XCTAssertEqual(health.map(\.deviceId), ["1", "2", "3", "4"])
        XCTAssertEqual(health.first { $0.deviceId == "2" }?.scannedAt, earlier["2"])
        XCTAssertNotEqual(health.first { $0.deviceId == "1" }?.scannedAt, earlier["1"])
    }

    /// A Mac attempted in an earlier pass of the round is done for it, answered or not.
    func testAMacThatFailedIsNotRetriedInTheSameRound() async throws {
        _ = try fleet(8)
        try answer("hist-1", "", exit: 1)
        _ = try await runScan(force: false, scanStop: stopAfter(4))
        let state = try store()
        XCTAssertTrue(try XCTUnwrap(state.deviceScanRound()).attempted.contains("1"))
        try nextDay()
        _ = try await runScan(force: false)
        XCTAssertEqual(historyCalls(for: "1"), 1)
        XCTAssertNil(state.deviceScanRound())
        XCTAssertNotNil(state.lastRun(report: "mdm-command-health"))
        XCTAssertNotNil(state.lastRun(report: "ddm-device-status"))
    }

    /// A pass that reaches no DDM Mac keeps the fleet's DDM rows: only Macs still DDM-enabled
    /// and in `computers` are carried.
    func testAPassThatReachesNoDDMMacKeepsTheirRows() async throws {
        try writeComputers([("1", "M1", "m1", true), ("2", "M2", "m2", false),
                            ("3", "M3", "m3", false), ("4", "M4", "m4", false),
                            ("5", "M5", "m5", false), ("6", "M6", "m6", false)])
        // 3–6 were never scanned, so the pass takes them first.
        try writeEarlierHealth(["1": 1, "2": 2])
        let old = ISO8601Time.string(Date().addingTimeInterval(-3 * 86_400))
        let ddmDir = try WorkspacePaths.dataDir(for: profile)
            .appendingPathComponent("ddm-device-status", isDirectory: true)
        try FileManager.default.createDirectory(at: ddmDir, withIntermediateDirectories: true)
        let rows = ["1", "2", "9"].map {
            DDMDeviceStatusRecord(deviceId: $0, name: "M\($0)", managementId: "m\($0)",
                                  osVersion: nil, reportDate: nil, ddmReported: true,
                                  declarations: [], softwareUpdate: .empty, scannedAt: old)
        }
        try JSONEncoder().encode(rows)
            .write(to: ddmDir.appendingPathComponent("ddm-device-status_20260901T120000.json"))
        for id in (1...6).map(String.init) { try answer("hist-\(id)", cleanHistory) }
        try answer("ddm-m1", ddmPayload)
        let lines = try await runScan(force: false, scanStop: stopAfter(4))
        XCTAssertEqual(Set(scannedIDs()), ["3", "4", "5", "6"], "\(lines)")
        let ddm = try XCTUnwrap(try latest("ddm-device-status", as: [DDMDeviceStatusRecord].self))
        XCTAssertEqual(ddm.map(\.deviceId), ["1"])
        XCTAssertEqual(ddm.first?.scannedAt, old)
    }

    func testAManualRefreshWaitingStopsAPass() async throws {
        let ids = try fleet(8)
        for id in ids { try answer("hist-\(id).sleep", "") }
        try FileManager.default.removeItem(at: answers.appendingPathComponent("hist-1.sleep"))
        try answer("hist-1.stop", "")
        let stopFile = answers.appendingPathComponent("stop")
        // The first call answers at once and raises the stop; the others hang until their
        // short timeout, so the fifth Mac's slot opens only after the stop is up.
        let lines = try await ReportEngine.$runStop.withValue({
            FileManager.default.fileExists(atPath: stopFile.path) ? .manualRefresh : nil
        }) {
            try await runScan(
                force: false,
                deviceLimits: ReportEngine.DeviceCallLimits(timeout: 0.5, stopAfterTimeouts: 99))
        }
        XCTAssertEqual(Set(scannedIDs()), ["1", "2", "3", "4"], "\(lines)")
        XCTAssertTrue(lines.contains { $0.hasSuffix("4 left for the next pass") }, "\(lines)")
        XCTAssertEqual(scanPartials(lines), [])
        XCTAssertFalse(lines.contains { $0.hasPrefix(ReportEngine.stoppedEarlyMarker) })
        XCTAssertNil(try store().lastRun(report: "mdm-command-health"))
    }

    func testAFleetThatFitsInOnePassLandsAsBefore() async throws {
        try writeComputers([("1", "A", "m1", true), ("2", "B", "m2", false)])
        try answer("hist-1", cleanHistory); try answer("hist-2", cleanHistory)
        try answer("ddm-m1", ddmPayload)
        let lines = try await runScan(force: false)
        XCTAssertFalse(lines.contains { $0.contains("left for the next pass") }, "\(lines)")
        XCTAssertTrue(lines.contains { $0.hasPrefix("[ok] mdm-command-health: 2 device(s)") })
        XCTAssertTrue(lines.contains { $0.hasPrefix("[ok] ddm-device-status: 1 device(s)") })
        let state = try store()
        XCTAssertNotNil(state.lastRun(report: "mdm-command-health"))
        XCTAssertNotNil(state.lastRun(report: "ddm-device-status"))
        XCTAssertNil(state.deviceScanRound())
        let health = try XCTUnwrap(try latest("mdm-command-health", as: [MDMCommandHealthRecord].self))
        XCTAssertTrue(health.allSatisfy { $0.scannedAt != nil })
    }
}
