import Foundation

/// Shared shape a persisted scan row must have so `ReportEngine.landOrReject`
/// can sort it by device id before writing.
private protocol DeviceIdentified { var deviceId: String { get } }
extension MDMCommandHealthRecord: DeviceIdentified {}
extension DDMDeviceStatusRecord: DeviceIdentified {}

/// 2.8.0 per-device scan phase. Two read-only jamf-cli calls per managed Mac,
/// bounded to four concurrent processes, reduced through `DeviceScanBuilders`
/// into the `ddm-device-status` and `mdm-command-health` snapshots.
///
/// This is the first per-device fan-out inside `collect`; every other kind is
/// one server-side report. A jamf-cli feature request for server-side
/// equivalents is filed upstream so this file can be deleted when they ship.
extension ReportEngine {

    static let deviceScanConcurrency = 4
    static let ddmDeviceStatusKind = DDMDeviceStatusService.kind
    static let mdmCommandHealthKind = MDMCommandHealthService.kind
    private static let progressEvery = 100

    /// One row of the `computers` snapshot the scan needs. `id` sits at the top
    /// level; `managementId` and the DDM flag under `general` (prod-verified).
    struct DeviceScanTarget: Decodable, Sendable, Equatable {
        let id: String
        let name: String
        let managementId: String?
        let ddmEnabled: Bool

        private enum Keys: String, CodingKey { case id, general }
        private enum General: String, CodingKey {
            case name, managementId, declarativeDeviceManagementEnabled
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: Keys.self)
            id = try c.decodeIfPresent(AnyCodable.self, forKey: .id)?.stringValue ?? ""
            let g = try? c.nestedContainer(keyedBy: General.self, forKey: .general)
            name = (try? g?.decodeIfPresent(String.self, forKey: .name)) ?? ""
            managementId = try? g?.decodeIfPresent(String.self, forKey: .managementId)
            // Two if-let steps: try? flattens decodeIfPresent's result to a single optional.
            var ddm = false
            if let container = g,
               let raw = try? container.decodeIfPresent(
                   AnyCodable.self, forKey: .declarativeDeviceManagementEnabled
               ) {
                ddm = raw.boolValue ?? false
            }
            ddmEnabled = ddm
        }
    }

    private enum CallType: String, Sendable {
        case history, statusItems

        var kind: String {
            switch self {
            case .history: return ReportEngine.mdmCommandHealthKind
            case .statusItems: return ReportEngine.ddmDeviceStatusKind
            }
        }
    }

    /// One call type's outcome for one device. `.notMade` never counts toward
    /// either "attempted" or "failed" — the call type was stopped, or the
    /// device was never eligible (not DDM-enabled, no managementId). Everything
    /// else that keeps a jamf-cli process from producing usable data — a launch
    /// failure, or an unsafe managementId that must never reach argv — counts
    /// as a failure against the call type's 25% budget even though no process
    /// ran; only `.ran` means the process actually launched and exited.
    private enum CallOutcome: Sendable {
        case notMade
        case launchFailed
        case ran(exit: Int32, data: Data)
    }

    private struct DeviceResult: Sendable {
        let target: DeviceScanTarget
        let history: CallOutcome
        let status: CallOutcome
    }

    /// Returns the kinds it wrote. Never throws: the matrix's verdicts have
    /// already run, and a scan problem must not turn a good run red.
    static func runDeviceScanPhase(
        profile: String, bin: URL, dataDir: URL, tiers: Set<CollectionTier>,
        skipExpensive: Bool, force: Bool, recordManifest: Bool,
        stateStore: StateFileStore?, collectStart: Date,
        onLine: @Sendable @escaping (CLIBridge.LogLine) -> Void
    ) async -> Set<String> {
        guard tiers.contains(.scan), !skipExpensive else { return [] }
        let kinds = [ddmDeviceStatusKind, mdmCommandHealthKind]
        if !force {
            let due = kinds.contains { kind in
                CadenceResolver.isDue(
                    lastRun: lastAttemptDate(for: kind, stateStore: stateStore),
                    cadence: CadenceResolver.cadence(forReport: kind),
                    now: collectStart
                )
            }
            guard due else {
                onLine(.init(timestamp: Date(), level: .info, text: "[skip] device scan: not due"))
                return []
            }
        }
        guard let data = try? loadLatestSnapshotData(kind: "computers", dataDir: dataDir),
              let all = try? JSONDecoder().decode([DeviceScanTarget].self, from: data),
              !all.isEmpty else {
            onLine(.init(
                timestamp: Date(), level: .info,
                text: "[skip] device scan: no computers snapshot"
            ))
            return []
        }
        var targets: [DeviceScanTarget] = []
        for t in all {
            guard CLIBridge.isSafeDeviceIdentifier(t.id) else {
                onLine(.init(
                    timestamp: Date(), level: .warn,
                    text: "[warn] device scan: skipping a device with an unsafe id"
                ))
                continue
            }
            targets.append(t)
        }
        guard !targets.isEmpty else {
            onLine(.init(
                timestamp: Date(), level: .warn,
                text: "[warn] device scan: no reachable devices — nothing attempted"
            ))
            return []
        }
        onLine(.init(
            timestamp: Date(), level: .info,
            text: "[info] device scan: \(targets.count) Mac(s), "
                + "\(targets.filter(\.ddmEnabled).count) DDM-enabled"
        ))

        let (results, stops) = await scanDevices(
            targets, profile: profile, bin: bin, onLine: onLine
        )
        return reduceAndSave(
            results: results, stops: stops, dataDir: dataDir,
            recordManifest: recordManifest, stateStore: stateStore,
            collectStart: collectStart, onLine: onLine
        )
    }

    /// A failed attempt still counts as an attempt for cadence purposes —
    /// otherwise a chronically-failing kind never advances its `.last` state
    /// and self-remediation's hourly retry turns it into an hourly full
    /// fan-out instead of waiting for the scan tier's normal weekly cadence.
    /// `force: true` (manual Collect now) bypasses this via the `!force`
    /// guard above.
    private static func lastAttemptDate(for kind: String, stateStore: StateFileStore?) -> Date? {
        [stateStore?.lastRun(report: kind), stateStore?.failures(report: kind)?.last]
            .compactMap { $0 }
            .max()
    }

    // MARK: - Fan-out

    /// Bounded task group: at most `deviceScanConcurrency` jamf-cli processes.
    /// Exit 5 or 8 on ANY device abandons that call type for the remaining
    /// devices (an actor-guarded flag read before each launch); exit 3 abandons
    /// both — a credential that died mid-scan will not come back for device 400.
    private static func scanDevices(
        _ targets: [DeviceScanTarget], profile: String, bin: URL,
        onLine: @Sendable @escaping (CLIBridge.LogLine) -> Void
    ) async -> (results: [DeviceResult], stops: [CallType: Int32]) {
        let bridge = CLIBridge()
        let gate = StopGate()
        var results: [DeviceResult] = []
        results.reserveCapacity(targets.count)
        var done = 0

        await withTaskGroup(of: DeviceResult.self) { group in
            var inFlight = 0
            for target in targets {
                if inFlight >= deviceScanConcurrency, let r = await group.next() {
                    inFlight -= 1
                    results.append(r)
                    done += 1
                    if done % progressEvery == 0 {
                        onLine(.init(
                            timestamp: Date(), level: .info,
                            text: "[info] device scan: \(done) of \(targets.count)"
                        ))
                    }
                }
                inFlight += 1
                group.addTask {
                    await scanOne(
                        target, profile: profile, bin: bin, bridge: bridge,
                        gate: gate, onLine: onLine
                    )
                }
            }
            for await r in group { results.append(r) }
        }
        return (results, await gate.stops())
    }

    private static func scanOne(
        _ t: DeviceScanTarget, profile: String, bin: URL, bridge: CLIBridge, gate: StopGate,
        onLine: @Sendable @escaping (CLIBridge.LogLine) -> Void
    ) async -> DeviceResult {
        var history: CallOutcome = .notMade
        var status: CallOutcome = .notMade

        if await gate.allows(.history) {
            if let h = await run(bridge, bin, [
                "-p", profile, "pro", "classic-computer-history", "get", t.id,
                "--subset", "commands", "--output", "json",
            ]) {
                history = .ran(exit: h.0, data: h.1)
                await gate.observe(h.0, for: .history, onLine: onLine)
            } else {
                history = .launchFailed
                await gate.noteLaunchFailure(.history, onLine: onLine)
            }
        }

        if t.ddmEnabled {
            if let mgmt = t.managementId, CLIBridge.isSafeDeviceIdentifier(mgmt) {
                if await gate.allows(.statusItems) {
                    if let s = await run(bridge, bin, [
                        "-p", profile, "pro", "ddm-status", "status-items", mgmt,
                        "--output", "json",
                    ]) {
                        status = .ran(exit: s.0, data: s.1)
                        await gate.observe(s.0, for: .statusItems, onLine: onLine)
                    } else {
                        status = .launchFailed
                        await gate.noteLaunchFailure(.statusItems, onLine: onLine)
                    }
                }
            } else if t.managementId != nil {
                // Has a managementId, but it fails the safety check — never
                // hand it to argv. Counts as a failure for the DDM budget.
                status = .launchFailed
                onLine(.init(
                    timestamp: Date(), level: .warn,
                    text: "[warn] device scan: skipping a device with an unsafe management id"
                ))
            }
            // else: no managementId at all — not eligible, not counted.
        }

        return DeviceResult(target: t, history: history, status: status)
    }

    private static func run(
        _ bridge: CLIBridge, _ bin: URL, _ args: [String]
    ) async -> (Int32, Data)? {
        try? await bridge.runAndCapture(
            executable: bin, arguments: args,
            environment: CLIBridge.environmentForJamfCLI(), onLine: { _ in }
        )
    }

    /// Per-run "stop this call type" flags, keyed by the exit code that
    /// triggered the stop, plus a one-shot log guard for launch failures. An
    /// actor so the four in-flight tasks agree on the decision without a lock.
    private actor StopGate {
        private var stopped: [CallType: Int32] = [:]
        private var launchFailureLogged: Set<CallType> = []

        func allows(_ type: CallType) -> Bool { stopped[type] == nil }

        func stops() -> [CallType: Int32] { stopped }

        func observe(
            _ exit: Int32, for type: CallType,
            onLine: @Sendable (CLIBridge.LogLine) -> Void
        ) {
            guard stopped[type] == nil else { return }
            let kind = type.kind
            switch exit {
            case CLIBridge.exitCodePermissionDenied:
                stopped[type] = exit
                onLine(.init(
                    timestamp: Date(), level: .warn,
                    text: "[warn] \(kind): exit 5 from a device — the API "
                        + "role needs Read Computers; skipping the rest of the run"
                ))
            case CLIBridge.exitCodeRefusedByPolicy:
                stopped[type] = exit
                onLine(.init(
                    timestamp: Date(), level: .warn,
                    text: "[warn] \(kind): refused by policy (exit 8) — this "
                        + "profile's API does not publish the command; skipping for the run"
                ))
            case CLIBridge.exitCodeRateLimited:
                stopped[type] = exit
                onLine(.init(
                    timestamp: Date(), level: .warn,
                    text: "[warn] \(kind): rate limited (exit 6) — stopping "
                        + "this call type for the run"
                ))
            case CLIBridge.exitCodeUnauthorized:
                // Only claim a call type that isn't already stopped for a
                // different reason — an exit 3 observed after an exit 5/8 on
                // the OTHER call type must not clobber that earlier record.
                if stopped[.history] == nil { stopped[.history] = exit }
                if stopped[.statusItems] == nil { stopped[.statusItems] = exit }
                onLine(.init(
                    timestamp: Date(), level: .warn,
                    text: "[warn] device scan: credentials rejected (exit 3) "
                        + "part-way through; stopping both call types"
                ))
            default: break
            }
        }

        /// Logs once per call type — a launch failure is a per-device event
        /// but repeating the same line for every failing device is noise.
        func noteLaunchFailure(
            _ type: CallType, onLine: @Sendable (CLIBridge.LogLine) -> Void
        ) {
            guard launchFailureLogged.insert(type).inserted else { return }
            let kind = type.kind
            onLine(.init(
                timestamp: Date(), level: .warn,
                text: "[warn] \(kind): jamf-cli failed to launch — counting the device as failed"
            ))
        }
    }

    // MARK: - Reduce + save

    private struct Tally<Row> {
        var rows: [Row] = []
        var attempted = 0
        var failed = 0
    }

    /// Folds one call type's raw per-device results into rows plus
    /// attempted/failed counts. `.notMade` counts toward neither — the call
    /// type was stopped, or the device was never eligible. `.launchFailed`
    /// counts as attempted-and-failed with no row. `.ran` counts as
    /// attempted; `row` returning nil counts it as failed (a non-JSON or
    /// otherwise-undecodable response).
    private static func tally<Row>(
        _ results: [DeviceResult],
        outcome: (DeviceResult) -> CallOutcome,
        row: (DeviceResult, Int32, Data) -> Row?
    ) -> Tally<Row> {
        var t = Tally<Row>()
        for r in results {
            switch outcome(r) {
            case .notMade:
                continue
            case .launchFailed:
                t.attempted += 1
                t.failed += 1
            case .ran(let exit, let data):
                t.attempted += 1
                if let built = row(r, exit, data) {
                    t.rows.append(built)
                } else {
                    t.failed += 1
                }
            }
        }
        return t
    }

    /// Writes the tally's rows, sorted by device id, when under the 25%
    /// failure budget; otherwise warns and records the kind failed without
    /// writing anything. `attempted == failed == 0` (nothing to reduce) is
    /// under budget, so it lands an empty snapshot — a landed, empty result,
    /// not a failure.
    private static func landOrReject<Row: Encodable & DeviceIdentified>(
        _ tally: Tally<Row>, kind: String, dataDir: URL, recordManifest: Bool,
        stateStore: StateFileStore?, collectStart: Date,
        onLine: @Sendable @escaping (CLIBridge.LogLine) -> Void, saved: inout Set<String>
    ) {
        if DeviceScanBuilders.exceedsFailureBudget(failed: tally.failed, total: tally.attempted) {
            onLine(.init(
                timestamp: Date(), level: .warn,
                text: "[warn] \(kind): \(tally.failed) of \(tally.attempted) "
                    + "devices failed — not written"
            ))
            stateStore?.record(.failed(exitCode: nil), report: kind, at: collectStart)
        } else {
            let rows = tally.rows.sorted { $0.deviceId < $1.deviceId }
            save(
                rows, kind: kind, failed: tally.failed, attempted: tally.attempted,
                dataDir: dataDir, recordManifest: recordManifest, stateStore: stateStore,
                collectStart: collectStart, onLine: onLine, saved: &saved
            )
        }
    }

    private static func reduceAndSave(
        results: [DeviceResult], stops: [CallType: Int32], dataDir: URL, recordManifest: Bool,
        stateStore: StateFileStore?, collectStart: Date,
        onLine: @Sendable @escaping (CLIBridge.LogLine) -> Void
    ) -> Set<String> {
        var saved: Set<String> = []
        let now = Date()

        // History → mdm-command-health (every device).
        if let stopExit = stops[.history] {
            onLine(.init(
                timestamp: Date(), level: .warn,
                text: "[warn] \(mdmCommandHealthKind): stopped after exit "
                    + "\(stopExit) — not written"
            ))
            stateStore?.record(
                .failed(exitCode: stopExit), report: mdmCommandHealthKind, at: collectStart
            )
        } else {
            let healthTally = tally(
                results, outcome: \.history
            ) { (r: DeviceResult, exit: Int32, data: Data) -> MDMCommandHealthRecord? in
                guard exit == 0 || exit == CLIBridge.exitCodePartialFailure,
                      let decoded = try? JSONDecoder().decode(
                          ComputerHistoryCommands.self, from: data
                      ) else { return nil }
                return DeviceScanBuilders.healthRecord(
                    deviceId: r.target.id, name: r.target.name, history: decoded, now: now
                )
            }
            landOrReject(
                healthTally, kind: mdmCommandHealthKind, dataDir: dataDir,
                recordManifest: recordManifest, stateStore: stateStore,
                collectStart: collectStart, onLine: onLine, saved: &saved
            )
        }

        // Status items → ddm-device-status (DDM-enabled devices only).
        if let stopExit = stops[.statusItems] {
            onLine(.init(
                timestamp: Date(), level: .warn,
                text: "[warn] \(ddmDeviceStatusKind): stopped after exit "
                    + "\(stopExit) — not written"
            ))
            stateStore?.record(
                .failed(exitCode: stopExit), report: ddmDeviceStatusKind, at: collectStart
            )
        } else {
            // Eligible devices; empty means the fleet has no DDM-enabled Mac with a managementId.
            let ddmTargets = results.filter {
                $0.target.ddmEnabled && $0.target.managementId != nil
            }
            if ddmTargets.isEmpty {
                // A fleet with zero DDM-enabled Macs is a real result, not an
                // absence — land an empty snapshot so the health strip sees it.
                save(
                    [DDMDeviceStatusRecord](), kind: ddmDeviceStatusKind, failed: 0, attempted: 0,
                    dataDir: dataDir, recordManifest: recordManifest, stateStore: stateStore,
                    collectStart: collectStart, onLine: onLine, saved: &saved
                )
            } else {
                let statusTally = tally(
                    ddmTargets, outcome: \.status
                ) { (r: DeviceResult, exit: Int32, data: Data) -> DDMDeviceStatusRecord? in
                    let mgmt = r.target.managementId ?? ""
                    if exit == CLIBridge.exitCodeNotFound {
                        return DeviceScanBuilders.ddmRecordNotReported(
                            deviceId: r.target.id, name: r.target.name, managementId: mgmt
                        )
                    }
                    guard exit == 0 || exit == CLIBridge.exitCodePartialFailure,
                          let payload = try? JSONDecoder().decode(
                              DDMStatusItemsPayload.self, from: data
                          ) else { return nil }
                    return DeviceScanBuilders.ddmRecord(
                        deviceId: r.target.id, name: r.target.name,
                        managementId: mgmt, payload: payload
                    )
                }
                landOrReject(
                    statusTally, kind: ddmDeviceStatusKind, dataDir: dataDir,
                    recordManifest: recordManifest, stateStore: stateStore,
                    collectStart: collectStart, onLine: onLine, saved: &saved
                )
            }
        }
        return saved
    }

    private static func save<T: Encodable>(
        _ rows: [T], kind: String, failed: Int, attempted: Int, dataDir: URL, recordManifest: Bool,
        stateStore: StateFileStore?, collectStart: Date,
        onLine: @Sendable @escaping (CLIBridge.LogLine) -> Void, saved: inout Set<String>
    ) {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(rows)
            try saveSnapshot(
                data: data, kind: kind, dataDir: dataDir,
                recordManifest: recordManifest, onLine: onLine
            )
            stateStore?.record(.landed, report: kind, at: collectStart)
            saved.insert(kind)
            onLine(.init(
                timestamp: Date(), level: .ok,
                text: "[ok] \(kind): \(rows.count) device(s)"
            ))
            if failed > 0 {
                onLine(.init(
                    timestamp: Date(), level: .warn,
                    text: "[partial] \(kind): \(failed) of \(attempted) devices did not respond"
                ))
            }
        } catch {
            stateStore?.record(.failed(exitCode: nil), report: kind, at: collectStart)
            onLine(.init(
                timestamp: Date(), level: .warn,
                text: "[warn] \(kind): could not write snapshot — \(error.localizedDescription)"
            ))
        }
    }
}
