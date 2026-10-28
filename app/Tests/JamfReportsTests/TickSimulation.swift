import Foundation
@testable import JamfReports

/// One run a simulated wake started.
struct TickSimRun: Equatable, CustomStringConvertible {
    let at: Date
    let reason: TickScheduler.Reason

    var description: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEE MM-dd HH:mm:ss"
        return "\(formatter.string(from: at)) \(reason)"
    }
}

/// Drives the real `runTick` wake by wake. The state file, blocked stamp, run-now markers and
/// lock are temporary files, the clock is the wake's time, and the run itself is a stand-in, so
/// a test states the Mac's wakes and gets back every run with its reason and time.
final class TickSimulation {
    var state: TickState
    let schedule: Schedule
    /// Wakes a lock held elsewhere turns away (a GUI collect), half-open.
    var blocked: [Range<Date>] = []
    /// Wakes at which a Run now is queued for `schedule`.
    var runNow: [Date] = []
    /// What a run started at the given time returns. Default: exit 0, complete.
    var outcome: (Date) -> ScheduleRunOutcome = { _ in
        ScheduleRunOutcome(exitCode: 0, incomplete: false)
    }
    /// Whether today's summary is missing at the given wake.
    var summaryMissing: (Date) -> Bool = { _ in true }
    private let directory: URL

    /// Labels with a Run now marker still queued.
    var markers: Set<String> { TickRunner.pendingRunNowLabels(dir: markerDir) }
    private var markerDir: URL { directory.appendingPathComponent("run-now") }

    init(schedule: Schedule, state: TickState) {
        self.schedule = schedule
        self.state = state
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("tick-sim-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: directory) }

    /// A run that fails and that a retry could help.
    static let failure = ScheduleRunOutcome(exitCode: 1, incomplete: false, retryCouldHelp: true)

    /// The agent's wakes, every `TickLock.wakeInterval` from `start` until before `end`.
    static func wakes(from start: Date, to end: Date) -> [Date] {
        stride(from: start.timeIntervalSinceReferenceDate,
               to: end.timeIntervalSinceReferenceDate, by: TickLock.wakeInterval)
            .map(Date.init(timeIntervalSinceReferenceDate:))
    }

    func run(wakes: [Date]) async -> [TickSimRun] {
        let stateURL = directory.appendingPathComponent("tick-state.json")
        let lock = TickLock(url: directory.appendingPathComponent(".tick.lock"))
        try? state.save(url: stateURL)
        let store = ScheduleStore(url: directory.appendingPathComponent("schedules.json"))
        if let record = ScheduleRecord(schedule: schedule) { try? store.save([record]) }
        let recorded = RunLog()
        let label = schedule.launchAgentLabel ?? ""
        for now in wakes {
            if runNow.contains(where: { abs($0.timeIntervalSince(now)) < 1 }) {
                try? TickRunner.requestRunNow(label: label, dir: markerDir)
            }
            let summaryMissing = summaryMissing(now)
            let outcome = outcome(now)
            let environment = TickEnvironment(
                lock: lock, blockedURL: directory.appendingPathComponent(".tick.blocked"),
                stateURL: stateURL, markerDir: markerDir, scheduleStore: store,
                profiles: { [] }, policy: { AutomationPolicy() }, clock: { now },
                summaryIsMissing: { _, _, _ in summaryMissing },
                perform: { run in
                    recorded.add(TickSimRun(at: now, reason: run.reason))
                    return outcome
                })
            // A GUI collect holds the lock: the tick queues behind it.
            let held = blocked.contains { $0.contains(now) } ? lock.claim() : nil
            _ = await runTick(arguments: ["--tick"], environment: environment)
            if case .acquired(let hold) = held { hold.release() }
        }
        state = TickState.load(url: stateURL)
        return recorded.runs
    }
}

private final class RunLog: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [TickSimRun] = []
    var runs: [TickSimRun] { lock.withLock { recorded } }
    func add(_ run: TickSimRun) { lock.withLock { recorded.append(run) } }
}
