import Foundation
import XCTest
@testable import JamfReports

/// Every collect the app starts from a button leaves a Run History entry, as the first collect
/// always did: Refresh, the heavy-tier prompt, Collect now (which goes through `runTierRefresh`)
/// and the first collect. A collect the tick lock refuses leaves none.
@MainActor
final class AppCollectRunHistoryTests: XCTestCase {

    private let profile = "alpha"
    private let fm = FileManager.default

    /// A store on a temporary workspaces root and tick lock. Neither init nor the re-probes
    /// after a collect run jamf-cli.
    private func makeStore() throws -> (store: WorkspaceStore, lock: TickLock, workspace: URL) {
        pinSkipExpensiveCollectionsOff(self)
        let root = fm.temporaryDirectory
            .appendingPathComponent("jrc-app-collect-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        setenv("JRC_TEST_WORKSPACES_ROOT", root.path, 1)
        addTeardownBlock {
            unsetenv("JRC_TEST_WORKSPACES_ROOT")
            try? FileManager.default.removeItem(at: root)
        }
        let lock = useTemporaryTickLock()
        let store = WorkspaceStore(
            demoMode: false, tickerRegistrar: StubTickerRegistrar(),
            jamfCLIProfileNames: { [] }, discoverProfiles: { [] }, jamfCLIInstallation: { nil })
        store.profile = profile
        store.resolveAuthMethod = { _ in nil }
        let workspace = try XCTUnwrap(ProfileService.workspaceURL(for: profile))
        return (store, lock, workspace)
    }

    private func entries() -> [RunHistoryService.RunSummary] {
        RunHistoryService.list(profile: profile)
    }

    private func statusFile(_ workspace: URL) -> URL {
        workspace.appendingPathComponent(
            "automation/\(WorkspaceStore.appCollectRunLabel)_status.json")
    }

    private enum Path: CaseIterable { case tier, heavyTier, first }

    /// Runs one collect through `path`, `body` standing in for jamf-cli.
    private func run(
        _ path: Path, on store: WorkspaceStore,
        _ body: @escaping @Sendable (@escaping @Sendable (CLIBridge.LogLine) -> Void)
            async throws -> Int32
    ) async {
        switch path {
        case .tier:
            await store.runTierRefresh([.refresh]) { _, _, onLine in try await body(onLine) }
        case .heavyTier:
            store.staleHeavyTiers = [.inventory]
            await store.runHeavyTierRefresh { _, _, onLine in try await body(onLine) }
        case .first:
            await store.runFirstCollect { _, onLine in try await body(onLine) }
        }
    }

    // MARK: - One entry per collect

    func testEachCollectPathRecordsExactlyOneEntryUnderTheReservedLabel() async throws {
        for path in Path.allCases {
            let (store, _, _) = try makeStore()
            await run(path, on: store) { onLine in
                onLine(logLine("[ok] computers"))
                return 0
            }

            let recorded = entries()
            XCTAssertEqual(recorded.count, 1, "\(path)")
            let entry = try XCTUnwrap(recorded.first)
            XCTAssertTrue(entry.label.hasPrefix(WorkspaceStore.appCollectRunLabel + "."),
                          "\(path): \(entry.label)")
            XCTAssertEqual(entry.name, "Manual collect", "\(path)")
            XCTAssertEqual(entry.exitCode, 0, "\(path)")
            XCTAssertEqual(entry.status, .ok, "\(path)")
            XCTAssertTrue(
                RunHistoryService.loadLog(entry.logURL).contains { $0.text == "[ok] computers" },
                "\(path): the run's lines are in its log")
        }
    }

    func testASecondCollectIsASecondEntry() async throws {
        let (store, _, _) = try makeStore()
        await run(.tier, on: store) { _ in 0 }
        // The log name carries the second the run began in.
        try await Task.sleep(for: .milliseconds(1_100))
        await run(.tier, on: store) { _ in 0 }

        XCTAssertEqual(entries().count, 2)
    }

    func testAFailedCollectIsRecordedAsFailedAndTheToastPointsAtRunHistory() async throws {
        for path in [Path.tier, .heavyTier] {
            let (store, _, _) = try makeStore()
            await run(path, on: store) { _ in 1 }

            let entry = try XCTUnwrap(entries().first, "\(path)")
            XCTAssertEqual(entry.exitCode, 1, "\(path)")
            XCTAssertEqual(entry.status, .fail, "\(path)")
            XCTAssertEqual(store.toast?.message, "Refresh finished with exit 1 — see Run History",
                           "\(path)")
            XCTAssertEqual(store.toast?.style, .danger, "\(path)")
        }
    }

    func testACollectThatThrowsIsRecordedAsFailedWithItsError() async throws {
        for path in Path.allCases {
            let (store, _, _) = try makeStore()
            await run(path, on: store) { _ in throw CLIBridgeError.executableNotFound }

            let entry = try XCTUnwrap(entries().first, "\(path)")
            XCTAssertEqual(entry.status, .fail, "\(path)")
            XCTAssertTrue(RunHistoryService.loadLog(entry.logURL).contains {
                $0.text.hasPrefix("[error]")
            }, "\(path)")
        }
    }

    // MARK: - Warnings toast

    func testTheWarningsToastNamesRunHistoryAndTheLogHoldsTheLine() async throws {
        for path in Path.allCases {
            let (store, _, _) = try makeStore()
            let unlanded = ReportEngine.unlandedSourcesLine(
                ["update-status-\(UUID().uuidString)"], attempted: 1)
            await run(path, on: store) { onLine in
                onLine(logLine(unlanded))
                return 0
            }

            XCTAssertEqual(store.toast?.message,
                           "Refresh finished with warnings — see Run History", "\(path)")
            XCTAssertEqual(store.toast?.style, .danger, "\(path)")
            let entry = try XCTUnwrap(entries().first, "\(path)")
            XCTAssertEqual(entry.status, .partial, "\(path)")
            XCTAssertTrue(RunHistoryService.loadLog(entry.logURL).contains { $0.text == unlanded },
                          "\(path)")
        }
    }

    /// An entry that could not be opened must not be named: the toast falls back to the in-app
    /// log, where the lines still go.
    func testWithoutARecordTheToastNamesTheInAppLog() async throws {
        let (store, _, workspace) = try makeStore()
        // A file where the automation folder belongs, so the recorder cannot open its log.
        try fm.createDirectory(at: workspace, withIntermediateDirectories: true)
        try Data().write(to: workspace.appendingPathComponent("automation"))
        let unlanded = ReportEngine.unlandedSourcesLine(
            ["update-status-\(UUID().uuidString)"], attempted: 1)

        await run(.tier, on: store) { onLine in
            onLine(logLine(unlanded))
            return 0
        }

        XCTAssertEqual(store.toast?.message,
                       "Refresh finished with warnings — see Settings › Logging")
        XCTAssertEqual(store.toast?.style, .danger)
        XCTAssertTrue(LogBuffer.shared.snapshot(minLevel: .debug, limit: 2000)
            .contains { $0.message == unlanded })
    }

    // MARK: - A refused collect records nothing

    func testACollectTheStoreRefusesRecordsNothing() async throws {
        let (store, lock, _) = try makeStore()
        let ran = Counter()
        try await whileAnotherProcessHolds(lock) {
            for path in Path.allCases {
                await run(path, on: store) { _ in
                    ran.bump()
                    return 0
                }
            }
        }
        XCTAssertEqual(ran.value, 0)
        XCTAssertEqual(entries().count, 0)
        XCTAssertFalse(fm.fileExists(atPath: statusFile(
            try XCTUnwrap(ProfileService.workspaceURL(for: profile))).path))
    }

    /// A tick can take the lock between the store's check and the bridge's claim.
    func testARefusalFromTheBridgeLeavesNoNewEntryAndKeepsTheLastStatus() async throws {
        for path in Path.allCases {
            let (store, _, workspace) = try makeStore()
            await run(path, on: store) { _ in 0 }
            let before = try Data(contentsOf: statusFile(workspace))
            XCTAssertEqual(entries().count, 1, "precondition: \(path) recorded its run")
            try await Task.sleep(for: .milliseconds(1_100))

            await run(path, on: store) { _ in throw CLIBridgeError.tickLockHeld }

            XCTAssertEqual(entries().count, 1, "\(path): the refused attempt is not listed")
            XCTAssertEqual(try Data(contentsOf: statusFile(workspace)), before, "\(path)")
            XCTAssertEqual(store.toast?.style, .info, "\(path)")
        }
    }

    // MARK: - Schedules never read an app collect

    func testNoScheduleLabelCanBeTheAppCollectLabel() {
        let label = WorkspaceStore.appCollectRunLabel
        func schedule(_ name: String, profile: String, multi: Bool) -> Schedule {
            Schedule(
                name: name, profile: profile, schedule: "Daily 06:00", cadence: "custom",
                mode: .snapshotOnly, next: "—", last: "—", lastStatus: .ok, artifacts: [],
                enabled: true, multiTarget: multi ? MultiTarget(scope: .all) : nil)
        }
        for name in ["manual-collect", "Manual collect", "manual", "collect"] {
            XCTAssertNotEqual(
                LaunchAgentWriter.label(for: schedule(name, profile: profile, multi: false)), label)
            XCTAssertNotEqual(
                LaunchAgentWriter.label(for: schedule(name, profile: "", multi: true)), label)
        }
        XCTAssertFalse(ManagedAutomation.owns(label))
        XCTAssertTrue(LaunchAgentWriter.isValidLabel(label), "the recorder accepts it")
    }

    func testAnAppCollectIsNoScheduledRunInHealthInputsOrTheOverdueCheck() async throws {
        let (store, _, workspace) = try makeStore()
        defer { AutomationHealthModel.shared.issues = [] }
        let twoHoursAgo = Calendar.current.dateComponents(
            [.hour, .minute], from: Date().addingTimeInterval(-2 * 3600))
        let daily = Schedule(
            name: "Daily", profile: profile,
            schedule: String(format: "Daily %02d:%02d",
                             twoHoursAgo.hour ?? 0, twoHoursAgo.minute ?? 0),
            cadence: "custom", mode: .snapshotOnly, next: "—", last: "—", lastStatus: .ok,
            artifacts: [], enabled: true,
            launchAgentLabel: "\(LaunchAgentWriter.labelPrefix).\(profile).daily")
        store.schedules = [daily]

        await run(.tier, on: store) { _ in 0 }
        XCTAssertTrue(fm.fileExists(atPath: statusFile(workspace).path), "precondition")
        // The workspace has to predate the fire for the schedule to be overdue at all.
        try fm.setAttributes([.creationDate: Date(timeIntervalSinceNow: -3 * 86_400)],
                             ofItemAtPath: workspace.path)

        let inputs = LaunchAgentService.healthInputs(schedules: [daily], statusProfile: nil)
        XCTAssertNil(inputs.first?.lastRunFinishedAt)
        XCTAssertNil(inputs.first?.lastRunSuccess)

        let afterTheWindow = Date().addingTimeInterval(TickLock.wakeInterval + 61)
        await store.refreshAutomationHealth(now: afterTheWindow)
        XCTAssertEqual(AutomationHealthModel.shared.issues.map(\.kind), [.overdue],
                       "a manual collect is not the schedule's run")
    }

    // MARK: - Retention

    /// Like the background item's records, app collects keep a window of their own, so a
    /// button pressed often cannot push schedule runs out of the recorder's 50.
    func testOnlyTheNewestAppCollectEntriesAreKeptAndScheduleLogsStay() async throws {
        let (store, _, workspace) = try makeStore()
        let logs = workspace.appendingPathComponent("automation/logs", isDirectory: true)
        try fm.createDirectory(at: logs, withIntermediateDirectories: true)
        let label = WorkspaceStore.appCollectRunLabel
        let keep = WorkspaceStore.keptAppCollectRuns
        func plant(_ name: String, secondsAgo: Double) throws {
            let url = logs.appendingPathComponent(name)
            try Data("[info] exit 0 after 1s\n".utf8).write(to: url)
            try fm.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -secondsAgo)],
                                 ofItemAtPath: url.path)
        }
        for index in 0..<(keep + 5) {
            try plant("\(label).20260101-0000\(String(format: "%02d", index)).log",
                      secondsAgo: 7_200 + Double(index) * 60)
        }
        let scheduled = "\(LaunchAgentWriter.labelPrefix).\(profile).daily.20250101-060000.log"
        try plant(scheduled, secondsAgo: 30 * 86_400)

        await run(.tier, on: store) { _ in 0 }

        let names = try fm.contentsOfDirectory(atPath: logs.path)
        XCTAssertEqual(names.filter { ScheduledRunRecorder.isLogName($0, of: label) }.count, keep)
        XCTAssertTrue(names.contains(scheduled), "another label's older log is not pruned")
        XCTAssertFalse(names.contains("\(label).20260101-000024.log"), "the oldest went first")
    }
}

private func logLine(_ text: String) -> CLIBridge.LogLine {
    CLIBridge.LogLine(timestamp: Date(), level: .info, text: text)
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.withLock { count } }
    func bump() { lock.withLock { count += 1 } }
}
