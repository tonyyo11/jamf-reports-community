import ArgumentParser
import XCTest
@testable import JamfReports

/// `--scheduled-run` (an external scheduler) and the included CLI's collect, generate, html and
/// backup write the same snapshots and reports a GUI collect or a tick does, so they take the
/// same tick lock: one of them at a time, and a refused one runs nothing.
@MainActor
final class HeadlessRunTickLockTests: XCTestCase {

    private let profile = "headless"

    private struct Workspace {
        let root: URL
        let profile: String
        var directory: URL { root.appendingPathComponent(profile, isDirectory: true) }
        var reports: URL { directory.appendingPathComponent("Generated Reports") }
        var runLogs: URL { directory.appendingPathComponent("automation/logs") }

        func reportFiles() -> [String] {
            (try? FileManager.default.contentsOfDirectory(atPath: reports.path)) ?? []
        }

        func runRecords() -> [String] {
            (try? FileManager.default.contentsOfDirectory(atPath: runLogs.path)) ?? []
        }
    }

    /// A workspace under a temporary root, which in DEBUG also moves Application Support, so
    /// `TickLock.defaultURL` is a file of this test's own.
    private func makeWorkspace() throws -> Workspace {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("jrc-headless-lock-\(UUID().uuidString)", isDirectory: true)
        let workspace = Workspace(root: root, profile: profile)
        try FileManager.default.createDirectory(
            at: workspace.directory, withIntermediateDirectories: true)
        try "columns:\n  computer_name: Name\n".write(
            to: workspace.directory.appendingPathComponent("config.yaml"),
            atomically: true, encoding: .utf8)
        setenv("JRC_TEST_WORKSPACES_ROOT", root.path, 1)
        addTeardownBlock {
            unsetenv("JRC_TEST_WORKSPACES_ROOT")
            try? FileManager.default.removeItem(at: root)
        }
        return workspace
    }

    // MARK: - The included CLI

    /// Each writing command, run with another process holding the lock: the same refusal, no
    /// output and no Run History record, since nothing started.
    func testEveryWritingCLICommandIsRefusedWhileAnotherProcessHoldsTheLock() async throws {
        let workspace = try makeWorkspace()
        let lock = TickLock(url: TickLock.defaultURL)
        let commands: [(String, () async throws -> Void)] = [
            ("generate", { try await Generate.parse(["--profile", self.profile]).run() }),
            ("collect", { try await Collect.parse(["--profile", self.profile]).run() }),
            ("html", { try await Html.parse(["--profile", self.profile]).run() }),
            ("backup", { try await Backup.parse(["--profile", self.profile]).run() }),
        ]
        try await whileAnotherProcessHolds(lock) {
            for (name, command) in commands {
                do {
                    try await command()
                    XCTFail("\(name) must be refused")
                } catch let code as ExitCode {
                    XCTAssertEqual(code.rawValue, TickRunner.queuedExitCode, name)
                }
            }
        }
        XCTAssertEqual(workspace.reportFiles(), [], "a refused command writes nothing")
        XCTAssertEqual(workspace.runRecords(), [], "and records no run")
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: workspace.directory.appendingPathComponent("backups").path))
    }

    func testTheCLIGenerateRunsHoldingTheLockAndGivesItBack() async throws {
        let workspace = try makeWorkspace()
        let lock = TickLock(url: TickLock.defaultURL)
        try await Generate.parse(["--profile", profile]).run()
        XCTAssertEqual(workspace.reportFiles().filter { $0.hasSuffix(".xlsx") }.count, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: lock.url.path),
                       "released when the command ends")
    }

    /// Reading and listing do not write snapshots or reports, so they never wait for the lock.
    func testAReadOnlyCommandIgnoresTheLock() async throws {
        _ = try makeWorkspace()
        let lock = TickLock(url: TickLock.defaultURL)
        try await whileAnotherProcessHolds(lock) {
            try await Schedules.List.parse([]).run()
        }
    }

    // MARK: - --scheduled-run

    private func schedule() -> Schedule {
        Schedule(
            name: "headless", profile: profile, schedule: "manual", cadence: "custom",
            mode: .jamfCLIOnly, next: "—", last: "—", lastStatus: .ok, artifacts: [],
            enabled: true, launchAgentLabel: nil, multiTarget: nil, tiers: nil,
            excludedProfiles: nil)
    }

    /// The external scheduler reads the exit code: the queued one, as a turned-away tick's.
    func testAScheduledRunIsTurnedAwayWhileAnotherProcessHoldsTheLock() async throws {
        let workspace = try makeWorkspace()
        let lock = TickLock(url: TickLock.defaultURL)
        try await whileAnotherProcessHolds(lock) {
            let outcome = await runScheduleExclusively(schedule(), verbose: false, lock: lock)
            XCTAssertNil(outcome)
        }
        XCTAssertEqual(workspace.reportFiles(), [])
        XCTAssertEqual(workspace.runRecords(), [])
    }

    func testAScheduledRunHoldsTheLockWhileItRunsAndGivesItBack() async throws {
        let workspace = try makeWorkspace()
        let lock = TickLock(url: TickLock.defaultURL)
        let outcome = await runScheduleExclusively(schedule(), verbose: false, lock: lock)
        XCTAssertEqual(outcome?.exitCode, 0)
        XCTAssertEqual(workspace.reportFiles().filter { $0.hasSuffix(".xlsx") }.count, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: lock.url.path))
    }

    // MARK: - TickLock.holdingForRun

    private func temporaryLock() -> TickLock {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("tick-\(UUID().uuidString).lock")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return TickLock(url: url)
    }

    func testTheLockNamesThisProcessWhileTheBodyRunsAndIsGoneAfter() async throws {
        let lock = temporaryLock()
        let seen = try await lock.holdingForRun { () -> String? in
            try? String(contentsOf: lock.url, encoding: .utf8)
        }
        XCTAssertEqual(seen, String(getpid()))
        XCTAssertFalse(FileManager.default.fileExists(atPath: lock.url.path))
    }

    /// A long collect must not let the lock go stale, or a wake takes it over mid-run.
    func testTheLockIsKeptFreshForALongRun() async throws {
        let lock = temporaryLock()
        let fresh = try await lock.holdingForRun(beatEvery: .milliseconds(20)) { () -> Bool in
            try FileManager.default.setAttributes(
                [.modificationDate: Date().addingTimeInterval(-10 * 60)],
                ofItemAtPath: lock.url.path)
            let deadline = ContinuousClock.now.advanced(by: .seconds(10))
            while ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(10))
                let modified = (try? FileManager.default.attributesOfItem(
                    atPath: lock.url.path))?[.modificationDate] as? Date
                if abs(modified?.timeIntervalSinceNow ?? -600) < 5 { return true }
            }
            return false
        }
        XCTAssertEqual(fresh, true)
    }

    func testAHeldLockRunsNothingAndIsLeftAlone() async throws {
        let lock = temporaryLock()
        try await whileAnotherProcessHolds(lock) {
            let ran = Flag()
            let result = await lock.holdingForRun { () -> Int in
                ran.set()
                return 1
            }
            XCTAssertNil(result)
            XCTAssertFalse(ran.isSet)
        }
    }

    func testAThrowingBodyStillGivesTheLockBack() async throws {
        let lock = temporaryLock()
        do {
            _ = try await lock.holdingForRun { () -> Int in
                throw CLIBridgeError.executableNotFound
            }
            XCTFail("the body's error must propagate")
        } catch {
            XCTAssertEqual(error as? CLIBridgeError, .executableNotFound)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: lock.url.path))
    }

    /// The tick needs the same file, so a broken Application Support must not make the command
    /// refuse every run.
    func testAnUnwritableLockFileDoesNotStopTheRun() async throws {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("missing-\(UUID().uuidString)/tick.lock")
        let result = await TickLock(url: missing).holdingForRun { 7 }
        XCTAssertEqual(result, 7)
    }
}

private final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var raised = false
    var isSet: Bool { lock.withLock { raised } }
    func set() { lock.withLock { raised = true } }
}
