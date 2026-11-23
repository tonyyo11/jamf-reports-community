import Foundation

/// The Jamf School per-device scan: one `school devices get <udid>` per device, run by
/// `CollectRouter` after everything else a collect does, so a scan that fails, stalls or is
/// killed costs nothing but itself. It never emits `[partial]`: no retry would fix a scan.
/// Like the Jamf Pro scan (large-fleet design L3) it runs in passes: a pass takes the devices
/// not yet attempted this round, oldest scan first, until `jamf_cli.scan_budget_minutes`, and
/// writes one whole-fleet snapshot; the round lives in `device-scan.round`.
extension ReportEngine {

    static let schoolDeviceDetailKind = "school-device-detail"
    /// A scan is due when the last attempt, success or failure, is this old.
    static let schoolDeviceScanInterval: TimeInterval = 7 * 24 * 3_600
    /// The first calls that, all failing, stop the scan: a dead key costs seconds, not N calls.
    static let schoolDeviceScanFirstCalls = 20

    /// Bounds the tests shrink; `calls` is the Jamf Pro scan's per-call limit type. `budget`
    /// nil is `jamf_cli.scan_budget_minutes`' default; `stop` (tests) replaces the budget and
    /// `runStop` decision and gets how many devices the pass has started.
    struct SchoolDeviceScanLimits: Sendable {
        var calls = DeviceCallLimits()
        var budget: TimeInterval?
        var concurrency = ReportEngine.deviceScanConcurrency
        var stop: (@Sendable (Int) -> Bool)?
    }

    enum SchoolDeviceScanPlan: Equatable, Sendable {
        case tierNotSelected
        case turnedOff
        case notDue(lastAttempt: Date?)
        /// The `state` folder is refused or unwritable: no attempt stamp, so no scan.
        case stateUnavailable
        case due

        var planText: String {
            switch self {
            case .tierNotSelected: "device scan: not selected (tier scan not selected)"
            case .turnedOff: "device scan: turned off (jamf_cli.collect_skip)"
            case .notDue(let last): "device scan: not due (last attempt: \(collectLogDateLabel(last)))"
            case .stateUnavailable: "device scan: not due (the state folder is not available)"
            case .due: "device scan: due"
            }
        }
    }

    /// The only fields kept from a device call, so no device name or user reaches disk. A field
    /// the call did not report, or reported as the wrong type, is absent.
    struct SchoolDeviceDetailRow: Codable, Sendable, Equatable, DeviceScanRow {
        var udid: String
        var serialNumber: String?
        var batteryLevel: Int?
        var deviceEnrollType: String?
        var totalCapacity: Int?
        /// When the pass that wrote this row scanned the device (ISO 8601).
        var scannedAt: String?

        var deviceId: String { udid.lowercased() }
    }

    struct SchoolScanTarget: Sendable, Equatable {
        let udid: String
        let serial: String

        /// The round and the merge key a device by its lowercased UDID.
        var key: String { udid.lowercased() }
    }

    /// Tier, then `collect_skip`, then the cadence. `force` is not an input: every GUI collect
    /// and a School `jamf-cli-full` schedule pass it, so it cannot mean "a person asked". While
    /// a round is open, any run takes one pass a local day, whatever its tiers; the attempt
    /// stamp counts too, since a peer's pass in progress has stamped it but not the round.
    static func planSchoolDeviceScan(
        tiers: Set<CollectionTier>, collectSkip: Set<String>, stateStore: StateFileStore?,
        now: Date
    ) -> SchoolDeviceScanPlan {
        let round = DeviceScanPasses.round(in: stateStore, now: now)
        guard tiers.contains(.scan) || round != nil else { return .tierNotSelected }
        guard !collectSkip.contains(schoolDeviceDetailKind) else { return .turnedOff }
        guard let stateStore else { return .stateUnavailable }
        let last = schoolDeviceScanLastAttempt(stateStore: stateStore, now: now)
        if let round {
            let today = [round.lastPass, last].compactMap { $0 }
                .contains { Calendar.current.isDate($0, inSameDayAs: now) }
            return today ? .notDue(lastAttempt: max(round.lastPass, last ?? round.lastPass)) : .due
        }
        // The resolver's tolerance keeps a schedule that starts a little early on day 7 due.
        let due = CadenceResolver.isDue(
            lastRun: last, cadence: .seconds(Int(schoolDeviceScanInterval)), now: now)
        return due ? .due : .notDue(lastAttempt: last)
    }

    /// The `state` folder without a warning: `schoolCollect` already warns about a refused one.
    static func schoolScanStateStore(dataDir: URL) -> StateFileStore? {
        (try? WorkspacePaths.confinedFolder(["state"], under: dataDir))
            .map(StateFileStore.init(directory:))
    }

    /// A stamp ahead of now (a peer's clock on a shared workspace) reads as absent.
    static func schoolDeviceScanLastAttempt(stateStore: StateFileStore?, now: Date) -> Date? {
        [stateStore?.lastRun(report: schoolDeviceDetailKind),
         stateStore?.failures(report: schoolDeviceDetailKind)?.last]
            .compactMap { $0 }.filter { $0 <= now }.max()
    }

    static func schoolDeviceArguments(profile: String, udid: String) -> [String] {
        ["-p", profile, "school", "devices", "get", udid, "--output", "json"]
    }

    /// Devices in School's trash and rows with no usable UDID are not scanned; a UDID listed
    /// twice is scanned once.
    static func schoolScanTargets(listData: Data) -> [SchoolScanTarget]? {
        guard let rows = (try? JSONSerialization.jsonObject(with: listData)) as? [[String: Any]]
        else { return nil }
        var seen = Set<String>()
        return SchoolFleetService.partitionFleet(rows).members.compactMap { row in
            let udid = ((row["udid"] as? String) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard CLIBridge.isSafeDeviceIdentifier(udid), seen.insert(udid.lowercased()).inserted
            else { return nil }
            return SchoolScanTarget(udid: udid, serial: (row["serialNumber"] as? String) ?? "")
        }
    }

    /// The allow-listed row of one `school devices get` object; nil when `data` is not one.
    static func reduceSchoolDeviceDetail(_ data: Data, target: SchoolScanTarget)
        -> SchoolDeviceDetailRow? {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return nil }
        func whole(_ key: String) -> Int? {
            guard let n = object[key] as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID()
            else { return nil }
            return wholeInt(n.doubleValue)
        }
        func text(_ key: String) -> String? {
            (object[key] as? String)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .flatMap { $0.isEmpty ? nil : $0 }
        }
        return SchoolDeviceDetailRow(
            udid: target.udid, serialNumber: text("serialNumber") ?? nonBlank(target.serial),
            batteryLevel: whole("batteryLevel").flatMap { (0...100).contains($0) ? $0 : nil },
            deviceEnrollType: text("deviceEnrollType"),
            totalCapacity: whole("totalCapacity").flatMap { $0 >= 0 ? $0 : nil })
    }

    private static func nonBlank(_ text: String) -> String? {
        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : text
    }

    /// Never scanned first, then the oldest scan, then the list order. Not by location: the
    /// `school-devices` rows jamf-cli prints carry none.
    static func schoolPassOrder(
        _ targets: [SchoolScanTarget], earlier: [SchoolDeviceDetailRow]
    ) -> [SchoolScanTarget] {
        let dates = DeviceScanPasses.latestDates(earlier)
        return targets.enumerated()
            .sorted { a, b in
                switch (dates[a.element.key], dates[b.element.key]) {
                case (nil, nil): return a.offset < b.offset
                case (nil, _): return true
                case (_, nil): return false
                case let (x?, y?): return x != y ? x < y : a.offset < b.offset
                }
            }
            .map(\.element)
    }

    // MARK: - The step

    /// Runs after the collect, its add-ons, `finalize()` and the claim release. Never throws and
    /// never touches the run's result. The attempt stamp is written when the scan starts, so a
    /// peer on a shared workspace sees it as not due; a pass that leaves devices for later puts
    /// the earlier stamp back and records the round instead, so the cadence does not advance.
    static func runSchoolDeviceScanStep(
        workspace: WorkspaceID, school: String, workspacePaths: WorkspacePaths.Type,
        plan: SchoolDeviceScanPlan, devicesData: Data?,
        locateJamfCLI: @Sendable () -> URL?, limits: SchoolDeviceScanLimits, now: Date,
        onLine: @Sendable @escaping (CLIBridge.LogLine) -> Void
    ) async {
        let kind = schoolDeviceDetailKind
        guard let dataDir = try? workspacePaths.dataDir(for: workspace.name) else { return }
        guard plan == .due else { return }
        func say(_ level: CLIBridge.LogLevel, _ text: String) {
            onLine(.init(timestamp: Date(), level: level, text: text))
        }
        guard let devicesData, let targets = schoolScanTargets(listData: devicesData) else {
            say(.info, "[skip] \(kind): school-devices did not land this run")
            return
        }
        guard let bin = locateJamfCLI() else {
            say(.warn, "[warn] \(kind) not written: jamf-cli was not found")
            return
        }
        // `plan` is due only with a state folder; without a stamp every run would scan again.
        guard let stateStore = schoolScanStateStore(dataDir: dataDir) else {
            say(.warn, "[warn] \(kind) not written: the state folder is not available")
            return
        }
        let previousStamp = stateStore.lastRun(report: kind)
        do { try stateStore.recordRun(report: kind, at: now) } catch {
            say(.warn, "[warn] \(kind) not written: attempt not recorded — "
                + error.englishDescription)
            return
        }
        func restoreStamp() {
            if let previousStamp {
                try? stateStore.recordRun(report: kind, at: previousStamp)
            } else {
                stateStore.clearRun(report: kind)
            }
        }
        let ids = Set(targets.map(\.key))
        // An unreadable earlier file is replaced only by a scan of the whole fleet: a pass's rows
        // must never stand in for it, and with no forced scan on School, a budget would keep it.
        let earlier = DeviceScanPasses.earlierRows(
            kind: kind, dataDir: dataDir, as: SchoolDeviceDetailRow.self)
        if earlier == nil {
            say(.warn, "[warn] \(kind) snapshot could not be read; this scan takes the whole "
                + "fleet and replaces it")
        }
        var round = earlier == nil ? nil : DeviceScanPasses.round(in: stateStore, now: now)
        var doneBefore = Set(round?.attempted ?? []).intersection(ids)
        // A round that already covers every current device has nothing left: start afresh.
        if doneBefore == ids { round = nil; doneBefore = [] }
        let pending = schoolPassOrder(
            targets.filter { !doneBefore.contains($0.key) }, earlier: earlier ?? [])
        let passStart = Date()
        let budget = limits.budget
            ?? TimeInterval(JamfCLIConfig.defaultScanBudgetMinutes * 60)
        let stopRun = runStop
        let wholeFleet = earlier == nil
        let shouldStop: @Sendable (Int) -> Bool = limits.stop ?? { _ in
            wholeFleet ? stopRun?() != nil
                : passShouldStop(passStart: passStart, now: Date(), budget: budget,
                                 runStop: stopRun)
        }
        say(.info, "[info] \(kind): scanning \(pending.count) device(s)")
        let prior = round?.history ?? DeviceScanTally()
        let outcome = await scan(
            pending, profile: school, bin: bin, limits: limits,
            round: (total: ids.count, failed: prior.failed), shouldStop: shouldStop)
        if outcome.cancelled {
            // Nothing written and no failure: the next run is due and the round is as it was.
            restoreStamp()
            say(.info, "[info] \(kind): cancelled")
            return
        }
        let tally = prior + DeviceScanTally(
            attempted: outcome.attempted.count, failed: outcome.failed)
        if let stop = outcome.stop {
            // Over the round's whole fleet, as the early 25% stop counts it.
            let (exit, cause, reason) = stop.describe(failed: tally.failed, total: ids.count)
            say(.warn, "[warn] \(kind) not written: \(reason)\(cause.map(causeSuffix) ?? "")")
            stateStore.record(.failed(exitCode: exit), report: kind, at: now, cause: cause)
            stateStore.clearDeviceScanRound()
            return
        }
        let left = pending.count - outcome.attempted.count
        // A pass that started nothing, or a whole-fleet scan cut short, writes and records
        // nothing. An empty fleet still lands an empty snapshot.
        guard pending.isEmpty || !outcome.attempted.isEmpty, left <= 0 || !wholeFleet else {
            restoreStamp()
            say(.info, "[info] \(kind): scanned \(outcome.attempted.count) of \(ids.count) "
                + "devices this pass; nothing written, \(left) left for the next pass")
            return
        }
        if left <= 0, DeviceScanBuilders.exceedsFailureBudget(
            failed: tally.failed, total: tally.attempted) {
            let reason = SchoolScanStop.budget.describe(failed: tally.failed, total: tally.attempted)
            say(.warn, "[warn] \(kind) not written: \(reason.2)")
            stateStore.record(.failed(exitCode: nil), report: kind, at: now)
            stateStore.clearDeviceScanRound()
            return
        }
        let stamp = ISO8601Time.string(Date())
        let rows = DeviceScanPasses.merged(
            scanned: outcome.rows.map { var row = $0; row.scannedAt = stamp; return row },
            earlier: earlier ?? [], carry: ids, now: Date())
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            try saveSnapshot(data: encoder.encode(rows), kind: kind, dataDir: dataDir, onLine: onLine)
        } catch {
            stateStore.record(.failed(exitCode: nil), report: kind, at: now)
            say(.warn, "[warn] \(kind) not written: \(error.englishDescription)")
            return
        }
        guard left <= 0 else {
            let next = DeviceScanRound(
                started: round?.started ?? now, lastPass: now,
                attempted: doneBefore.union(outcome.attempted).sorted(), remaining: left,
                history: tally)
            do { try stateStore.recordDeviceScanRound(next) } catch {
                say(.warn, "[warn] \(kind): round not recorded — \(error.englishDescription)")
            }
            restoreStamp()
            say(.info, "[info] \(kind): scanned \(outcome.attempted.count) of \(ids.count) "
                + "devices this pass; \(left) left for the next pass")
            return
        }
        stateStore.clearDeviceScanRound()
        stateStore.record(.landed, report: kind, at: now)
        say(.ok, "[ok] \(kind): \(rows.count) device(s)")
        if tally.failed > 0 {
            say(.info, "[info] \(kind): \(tally.failed) of \(tally.attempted) devices did not respond")
        }
        say(.info, "[info] \(kind) took \(Int(Date().timeIntervalSince(passStart).rounded()))s")
    }

    // MARK: - Fan-out

    struct ScanOutcome: Sendable {
        var rows: [SchoolDeviceDetailRow] = []
        /// Lowercased UDIDs of the devices whose call finished, answered or not.
        var attempted: Set<String> = []
        var failed = 0
        var stop: SchoolScanStop?
        var cancelled = false
    }

    enum SchoolScanStop: Sendable {
        case exit(Int32, Data, keychainLocked: Bool)
        case budget
        case firstCalls(Int)

        /// The exit code to record, the cause and the log reason.
        func describe(failed: Int, total: Int) -> (Int32?, FailureCause?, String) {
            switch self {
            case .exit(let code, let data, let locked):
                let cause = FailureCause.classify(
                    exitCode: code, stdout: data, sawKeychainLockedOnStderr: locked)
                return (code, cause, "a device call exited \(code) (\(ReportEngine.exitText(code)))")
            case .budget:
                return (nil, nil,
                        "\(failed) of \(total) devices did not respond (over 25%)")
            case .firstCalls(let n):
                return (nil, nil, "the first \(n) device calls all failed")
            }
        }
    }

    private enum CallResult: Sendable {
        case ok(SchoolDeviceDetailRow)
        case failed(exit: Int32?, data: Data, keychainLocked: Bool)
    }

    /// Decides, as calls finish, whether the scan goes on. An actor so the in-flight calls agree.
    /// The 25% stop counts the round's earlier failures over the round's whole fleet: past it,
    /// the round's end could not land.
    private actor SchoolScanGate {
        private let roundTotal: Int
        private let roundFailed: Int
        private let firstCalls: Int
        private(set) var stop: SchoolScanStop?
        private var completed = 0
        private(set) var failed = 0

        init(pending: Int, roundTotal: Int, roundFailed: Int) {
            self.roundTotal = roundTotal
            self.roundFailed = roundFailed
            self.firstCalls = min(ReportEngine.schoolDeviceScanFirstCalls, pending)
        }

        func admit() -> Bool { stop == nil }

        func finish(_ result: CallResult) {
            guard stop == nil else { return }
            completed += 1
            guard case .failed(let exit, let data, let locked) = result else { return }
            failed += 1
            if let exit, [3, 5, 6, 8].contains(exit) {
                stop = .exit(exit, data, keychainLocked: locked)
            } else if DeviceScanBuilders.exceedsFailureBudget(
                failed: roundFailed + failed, total: roundTotal) {
                stop = .budget
            } else if completed == firstCalls, failed == completed {
                stop = .firstCalls(firstCalls)
            }
        }
    }

    private static func scan(
        _ targets: [SchoolScanTarget], profile: String, bin: URL, limits: SchoolDeviceScanLimits,
        round: (total: Int, failed: Int), shouldStop: @Sendable (Int) -> Bool
    ) async -> ScanOutcome {
        guard !targets.isEmpty else { return ScanOutcome() }
        let bridge = CLIBridge()
        let gate = SchoolScanGate(
            pending: targets.count, roundTotal: round.total, roundFailed: round.failed)
        var outcome = ScanOutcome()
        func take(_ done: (String, SchoolDeviceDetailRow?)) {
            outcome.attempted.insert(done.0)
            if let row = done.1 { outcome.rows.append(row) }
        }
        await withTaskGroup(of: (String, SchoolDeviceDetailRow?).self) { group in
            var inFlight = 0
            var started = 0
            for target in targets {
                if inFlight >= max(1, limits.concurrency), let done = await group.next() {
                    inFlight -= 1
                    take(done)
                }
                // A cancelled run admits no more calls; the ones in flight finish or time out.
                // The budget only stops starting devices.
                guard !Task.isCancelled, await gate.admit(), !shouldStop(started) else { break }
                started += 1
                inFlight += 1
                group.addTask {
                    let result = await callOne(
                        target, profile: profile, bin: bin, bridge: bridge,
                        timeout: limits.calls.timeout)
                    await gate.finish(result)
                    if case .ok(let row) = result { return (target.key, row) }
                    return (target.key, nil)
                }
            }
            for await done in group { take(done) }
        }
        outcome.cancelled = Task.isCancelled
        outcome.stop = await gate.stop
        outcome.failed = await gate.failed
        let order = Dictionary(uniqueKeysWithValues: targets.enumerated().map { ($1.udid, $0) })
        outcome.rows.sort { (order[$0.udid] ?? 0) < (order[$1.udid] ?? 0) }
        return outcome
    }

    /// A non-zero exit, a timeout, a launch failure and an answer that is not an object are each
    /// one device that did not respond.
    private static func callOne(
        _ target: SchoolScanTarget, profile: String, bin: URL, bridge: CLIBridge,
        timeout: TimeInterval
    ) async -> CallResult {
        guard let result = await run(
            bridge, bin, schoolDeviceArguments(profile: profile, udid: target.udid),
            timeout: timeout) else {
            return .failed(exit: nil, data: Data(), keychainLocked: false)
        }
        if result.exit == 0, let row = reduceSchoolDeviceDetail(result.data, target: target) {
            return .ok(row)
        }
        return .failed(exit: result.exit, data: result.data, keychainLocked: result.keychainLocked)
    }
}
