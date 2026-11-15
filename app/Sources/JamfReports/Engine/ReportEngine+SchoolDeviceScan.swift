import Foundation

/// The Jamf School per-device scan: one `school devices get <udid>` per device, run by
/// `CollectRouter` after everything else a collect does, so a scan that fails, stalls or is
/// killed costs nothing but itself. It never emits `[partial]`: no retry would fix a scan.
extension ReportEngine {

    static let schoolDeviceDetailKind = "school-device-detail"
    /// A scan is due when the last attempt, success or failure, is this old.
    static let schoolDeviceScanInterval: TimeInterval = 7 * 24 * 3_600
    static let schoolDeviceScanDeadline: TimeInterval = 3_600
    /// The first calls that, all failing, stop the scan: a dead key costs seconds, not N calls.
    static let schoolDeviceScanFirstCalls = 20

    /// Bounds the tests shrink; `calls` is the Jamf Pro scan's per-call limit type.
    struct SchoolDeviceScanLimits: Sendable {
        var calls = DeviceCallLimits()
        var deadline = ReportEngine.schoolDeviceScanDeadline
        var concurrency = ReportEngine.deviceScanConcurrency
    }

    enum SchoolDeviceScanPlan: Equatable, Sendable {
        case tierNotSelected
        case turnedOff
        case notDue(lastAttempt: Date?)
        case due

        var planText: String {
            switch self {
            case .tierNotSelected: "device scan: not selected (tier scan not selected)"
            case .turnedOff: "device scan: turned off (jamf_cli.collect_skip)"
            case .notDue(let last): "device scan: not due (last attempt: \(collectLogDateLabel(last)))"
            case .due: "device scan: due"
            }
        }
    }

    /// The only fields kept from a device call, so no device name or user reaches disk. A field
    /// the call did not report, or reported as the wrong type, is absent.
    struct SchoolDeviceDetailRow: Codable, Sendable, Equatable {
        var udid: String
        var serialNumber: String?
        var batteryLevel: Int?
        var deviceEnrollType: String?
        var totalCapacity: Int?
    }

    struct SchoolScanTarget: Sendable, Equatable {
        let udid: String
        let serial: String
    }

    /// Tier, then `collect_skip`, then the cadence. `force` is not an input: every GUI collect
    /// and a School `jamf-cli-full` schedule pass it, so it cannot mean "a person asked".
    static func planSchoolDeviceScan(
        tiers: Set<CollectionTier>, collectSkip: Set<String>, stateStore: StateFileStore?,
        now: Date
    ) -> SchoolDeviceScanPlan {
        guard tiers.contains(.scan) else { return .tierNotSelected }
        guard !collectSkip.contains(schoolDeviceDetailKind) else { return .turnedOff }
        let last = schoolDeviceScanLastAttempt(stateStore: stateStore, now: now)
        let due = last.map { now.timeIntervalSince($0) >= schoolDeviceScanInterval } ?? true
        return due ? .due : .notDue(lastAttempt: last)
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

    // MARK: - The step

    /// Runs after the collect, its add-ons, `finalize()` and the claim release. Never throws and
    /// never touches the run's result. The attempt stamp is written when the scan starts, so a
    /// peer on a shared workspace sees it as not due.
    static func runSchoolDeviceScanStep(
        workspace: WorkspaceID, school: String, workspacePaths: WorkspacePaths.Type,
        tiers: Set<CollectionTier>, collectSkip: Set<String>, devicesData: Data?,
        locateJamfCLI: @Sendable () -> URL?, limits: SchoolDeviceScanLimits, now: Date,
        onLine: @Sendable @escaping (CLIBridge.LogLine) -> Void
    ) async {
        let kind = schoolDeviceDetailKind
        guard let dataDir = try? workspacePaths.dataDir(for: workspace.name) else { return }
        let stateStore = WorkspacePaths
            .confinedFolderOrWarn(["state"], under: dataDir, onLine: onLine)
            .map(StateFileStore.init(directory:))
        guard planSchoolDeviceScan(
            tiers: tiers, collectSkip: collectSkip, stateStore: stateStore, now: now) == .due
        else { return }
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
        // Without a stamp every run would scan again, so a state folder that cannot be written
        // means no scan.
        guard let stateStore else {
            say(.warn, "[warn] \(kind) not written: the state folder is not available")
            return
        }
        do { try stateStore.recordRun(report: kind, at: now) } catch {
            say(.warn, "[warn] \(kind) not written: attempt not recorded — "
                + error.englishDescription)
            return
        }
        let started = Date()
        say(.info, "[info] \(kind): scanning \(targets.count) device(s)")
        let outcome = await scan(targets, profile: school, bin: bin, limits: limits)
        land(outcome, total: targets.count, dataDir: dataDir, stateStore: stateStore, at: now,
             onLine: onLine)
        say(.info, "[info] \(kind) took \(Int(Date().timeIntervalSince(started).rounded()))s")
    }

    private static func land(
        _ outcome: ScanOutcome, total: Int, dataDir: URL, stateStore: StateFileStore, at now: Date,
        onLine: @Sendable (CLIBridge.LogLine) -> Void
    ) {
        let kind = schoolDeviceDetailKind
        if let stop = outcome.stop {
            let (exit, cause, reason) = stop.describe(failed: outcome.failed, total: total)
            onLine(.init(timestamp: Date(), level: .warn,
                         text: "[warn] \(kind) not written: \(reason)\(cause.map(causeSuffix) ?? "")"))
            stateStore.record(.failed(exitCode: exit), report: kind, at: now, cause: cause)
            return
        }
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            try saveSnapshot(
                data: encoder.encode(outcome.rows), kind: kind, dataDir: dataDir, onLine: onLine)
        } catch {
            stateStore.record(.failed(exitCode: nil), report: kind, at: now)
            onLine(.init(timestamp: Date(), level: .warn,
                         text: "[warn] \(kind) not written: \(error.englishDescription)"))
            return
        }
        stateStore.record(.landed, report: kind, at: now)
        onLine(.init(timestamp: Date(), level: .ok,
                     text: "[ok] \(kind): \(outcome.rows.count) device(s)"))
        if outcome.failed > 0 {
            onLine(.init(timestamp: Date(), level: .info,
                         text: "[info] \(kind): \(outcome.failed) of \(total) devices did not respond"))
        }
    }

    // MARK: - Fan-out

    struct ScanOutcome: Sendable {
        var rows: [SchoolDeviceDetailRow] = []
        var failed = 0
        var stop: SchoolScanStop?
    }

    enum SchoolScanStop: Sendable {
        case exit(Int32, Data, keychainLocked: Bool)
        case budget
        case firstCalls(Int)
        case deadline

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
            case .deadline:
                return (CLIBridge.exitCodeTimedOut, nil,
                        "stopped after \(Int(ReportEngine.schoolDeviceScanDeadline / 60)) minutes")
            }
        }
    }

    private enum CallResult: Sendable {
        case ok(SchoolDeviceDetailRow)
        case failed(exit: Int32?, data: Data, keychainLocked: Bool)
    }

    /// Decides, as calls finish, whether the scan goes on. An actor so the in-flight calls agree.
    private actor SchoolScanGate {
        private let total: Int
        private let firstCalls: Int
        private let deadline: Date
        private(set) var stop: SchoolScanStop?
        private var completed = 0
        private(set) var failed = 0

        init(total: Int, deadline: Date) {
            self.total = total
            self.firstCalls = min(ReportEngine.schoolDeviceScanFirstCalls, total)
            self.deadline = deadline
        }

        func admit() -> Bool {
            if stop == nil, Date() >= deadline { stop = .deadline }
            return stop == nil
        }

        func finish(_ result: CallResult) {
            guard stop == nil else { return }
            completed += 1
            guard case .failed(let exit, let data, let locked) = result else { return }
            failed += 1
            if let exit, [3, 5, 6, 8].contains(exit) {
                stop = .exit(exit, data, keychainLocked: locked)
            } else if DeviceScanBuilders.exceedsFailureBudget(failed: failed, total: total) {
                stop = .budget
            } else if completed == firstCalls, failed == completed {
                stop = .firstCalls(firstCalls)
            }
        }
    }

    private static func scan(
        _ targets: [SchoolScanTarget], profile: String, bin: URL, limits: SchoolDeviceScanLimits
    ) async -> ScanOutcome {
        guard !targets.isEmpty else { return ScanOutcome() }
        let bridge = CLIBridge()
        let gate = SchoolScanGate(
            total: targets.count, deadline: Date().addingTimeInterval(limits.deadline))
        var outcome = ScanOutcome()
        await withTaskGroup(of: SchoolDeviceDetailRow?.self) { group in
            var inFlight = 0
            for target in targets {
                if inFlight >= max(1, limits.concurrency), let row = await group.next() {
                    inFlight -= 1
                    if let row { outcome.rows.append(row) }
                }
                guard await gate.admit() else { break }
                inFlight += 1
                group.addTask {
                    let result = await callOne(
                        target, profile: profile, bin: bin, bridge: bridge,
                        timeout: limits.calls.timeout)
                    await gate.finish(result)
                    if case .ok(let row) = result { return row }
                    return nil
                }
            }
            for await row in group { if let row { outcome.rows.append(row) } }
        }
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
