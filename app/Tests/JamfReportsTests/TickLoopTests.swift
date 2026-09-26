import XCTest
@testable import JamfReports

/// The per-schedule half of a tick (`TickLoop.runDue`), with the state file, the
/// runs and the digest replaced by a recorder so the order of effects is visible.
///
/// The rules pinned here: a start the state file cannot remember never runs and
/// never reaches disk later; no stamp failure stops the schedules after it or the
/// overdue digest; and a run-now marker is cleared after its start is stamped and
/// before its run, never after.
final class TickLoopTests: XCTestCase {

    private func label(_ name: String) -> String {
        "com.github.tonyyo11.jamf-reports-community.alpha.\(name)"
    }

    private func due(
        _ name: String, _ reason: TickScheduler.Reason = .fire
    ) -> TickScheduler.DueRun {
        let schedule = Schedule(
            name: name, profile: "alpha", schedule: "Daily 06:00", cadence: "custom",
            mode: .snapshotOnly, next: "—", last: "—", lastStatus: .ok, artifacts: [],
            enabled: true, launchAgentLabel: label(name)
        )
        return TickScheduler.DueRun(schedule: schedule, reason: reason)
    }

    private func markerDir() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("run-now-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    /// Drives `TickLoop.runDue` from an empty state; every run exits 0 and complete.
    /// With `markerDir`, run-now markers are real files there.
    private func runDue(
        _ runs: [TickScheduler.DueRun], recorder: TickLoopRecorder, markerDir: URL? = nil
    ) async -> Int32 {
        await TickLoop.runDue(
            runs, state: TickState(),
            save: { recorder.save($0) },
            clearRunNowMarker: { label in
                recorder.cleared(label)
                if let markerDir { TickRunner.clearRunNowMarker(label: label, dir: markerDir) }
            },
            perform: { run in
                let label = run.schedule.launchAgentLabel ?? ""
                let onDisk = markerDir.map {
                    FileManager.default.fileExists(atPath: $0.appendingPathComponent(label).path)
                } ?? false
                recorder.ran(label, markerOnDisk: onDisk)
                return ScheduleRunOutcome(exitCode: 0, incomplete: false)
            },
            notifyOverdue: { recorder.digest() })
    }

    // MARK: - Clean tick

    func testACleanTickStampsEachRunAndExitsZeroAfterTheDigest() async {
        let recorder = TickLoopRecorder()
        let code = await runDue([due("first"), due("second")], recorder: recorder)

        XCTAssertEqual(code, 0)
        XCTAssertEqual(recorder.events, [
            .saved, .ran(label("first")), .saved,
            .saved, .ran(label("second")), .saved,
            .digest,
        ], "a calendar fire has no marker to clear")
    }

    // MARK: - Stamp failures

    func testAFailedStartStampSkipsOnlyThatScheduleAndIsNeverPersisted() async {
        // Save 1 is `first`'s start stamp.
        let recorder = TickLoopRecorder(failingSaves: [1])
        let code = await runDue([due("first"), due("second")], recorder: recorder)

        XCTAssertEqual(code, 1)
        XCTAssertEqual(recorder.events, [
            .saveFailed,
            .saved, .ran(label("second")), .saved,
            .digest,
        ])
        XCTAssertFalse(recorder.saved.isEmpty)
        for state in recorder.saved {
            XCTAssertNil(state.lastStarted[label("first")],
                         "a start that never happened must not reach disk with a later save")
        }
    }

    func testAFailedSuccessStampDoesNotStopTheSchedulesAfterIt() async {
        // Save 1 is `first`'s start stamp, save 2 its success.
        let recorder = TickLoopRecorder(failingSaves: [2])
        let code = await runDue([due("first"), due("second")], recorder: recorder)

        XCTAssertEqual(code, 1)
        XCTAssertEqual(recorder.events, [
            .saved, .ran(label("first")), .saveFailed,
            .saved, .ran(label("second")), .saved,
            .digest,
        ])
        // The run happened, so the next save that works records its success.
        XCTAssertNotNil(recorder.saved.last?.lastSucceeded[label("first")])
        XCTAssertNotNil(recorder.saved.last?.lastSucceeded[label("second")])
    }

    func testTheOverdueDigestStillRunsAfterAStampFailure() async {
        let recorder = TickLoopRecorder(failingSaves: [1])
        let code = await runDue([due("only")], recorder: recorder)

        XCTAssertEqual(code, 1)
        XCTAssertEqual(recorder.events, [.saveFailed, .digest])
    }

    // MARK: - Run-now markers

    func testARunNowMarkerSurvivesAFailedStartStamp() async throws {
        let dir = markerDir()
        try TickRunner.requestRunNow(label: label("asked"), dir: dir)
        let recorder = TickLoopRecorder(failingSaves: [1])
        let code = await runDue([due("asked", .runNow)], recorder: recorder, markerDir: dir)

        XCTAssertEqual(code, 1)
        XCTAssertEqual(recorder.events, [.saveFailed, .digest], "an unstamped run never starts")
        XCTAssertEqual(TickRunner.pendingRunNowLabels(dir: dir), [label("asked")],
                       "the request must still be queued for the next wake")
    }

    func testARunNowMarkerIsClearedBeforeItsRunStarts() async throws {
        let dir = markerDir()
        try TickRunner.requestRunNow(label: label("asked"), dir: dir)
        let recorder = TickLoopRecorder()
        let code = await runDue([due("asked", .runNow)], recorder: recorder, markerDir: dir)

        XCTAssertEqual(code, 0)
        XCTAssertEqual(recorder.events, [
            .saved, .cleared(label("asked")), .ran(label("asked")), .saved, .digest,
        ], "cleared once the start is stamped, and before the run")
        XCTAssertEqual(recorder.markerOnDiskAtRunStart, [false],
                       "a run that crashes the process must not leave a marker to re-run it")
        XCTAssertTrue(TickRunner.pendingRunNowLabels(dir: dir).isEmpty)
    }
}

/// Stands in for the state file, the runs and the digest, recording the order they
/// happen in. `failingSaves` are the 1-based save attempts that fail.
private final class TickLoopRecorder: @unchecked Sendable {
    enum Event: Equatable {
        case saved, saveFailed, cleared(String), ran(String), digest
    }

    private let lock = NSLock()
    private let failingSaves: Set<Int>
    private var saveAttempts = 0
    private var _events: [Event] = []
    private var _saved: [TickState] = []
    private var _markerOnDisk: [Bool] = []

    init(failingSaves: Set<Int> = []) {
        self.failingSaves = failingSaves
    }

    /// `saveTickState`'s contract: true when the stamps reached disk.
    func save(_ state: TickState) -> Bool {
        lock.withLock { () -> Bool in
            saveAttempts += 1
            guard !failingSaves.contains(saveAttempts) else {
                _events.append(.saveFailed)
                return false
            }
            _events.append(.saved)
            _saved.append(state)
            return true
        }
    }

    func cleared(_ label: String) {
        lock.withLock { _events.append(.cleared(label)) }
    }

    func ran(_ label: String, markerOnDisk: Bool) {
        lock.withLock {
            _events.append(.ran(label))
            _markerOnDisk.append(markerOnDisk)
        }
    }

    func digest() {
        lock.withLock { _events.append(.digest) }
    }

    var events: [Event] { lock.withLock { _events } }
    var saved: [TickState] { lock.withLock { _saved } }
    var markerOnDiskAtRunStart: [Bool] { lock.withLock { _markerOnDisk } }
}
