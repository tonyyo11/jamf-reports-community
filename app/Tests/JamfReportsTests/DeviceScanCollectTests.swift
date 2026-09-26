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
    ///     (exit = first line of answers/hist-<id>.exit if present)
    ///   … status-items <mgmt>               → answers/ddm-<mgmt>  (same exit rule; either
    ///                                          resource spelling — see statusItemsArguments)
    /// Anything else → prints [] exit 0, so the argv matrix's kinds "succeed" harmlessly.
    private func makeStub() throws -> URL {
        let url = binDir.appendingPathComponent("stub-cli")
        let script = """
        #!/bin/sh
        A="\(answers.path)"
        printf '%s\\n' "$*" >> "$A/calls.log"
        emit() { f="$A/$1"; if [ -f "$f.exit" ]; then code=$(cat "$f.exit"); else code=0; fi; \\
                 [ -f "$f" ] && cat "$f"; exit "$code"; }
        case "$*" in
          *" classic-computer-history get "*) id=$(echo "$*" | sed -E 's/.*classic-computer-history get ([^ ]+).*/\\1/'); emit "hist-$id" ;;
          *" status-items "*) m=$(echo "$*" | sed -E 's/.*status-items ([^ ]+).*/\\1/'); \\
            emit "ddm-$m" ;;
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
            ReportEngine.defaultAuthConfirmationProbe
    ) async throws -> [String] {
        let stub = try makeStub()
        let collector = LogTextCollector()
        try await ReportEngine.collect(
            profile: profile, workspacePaths: WorkspacePaths.self,
            tiers: [.scan], skipExpensive: skipExpensive, force: force,
            authConfirmationProbe: probe, locateJamfCLI: { stub }, onLine: collector.append)
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
