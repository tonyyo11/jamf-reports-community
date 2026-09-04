import Foundation

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

        init(id: String, name: String, managementId: String?, ddmEnabled: Bool) {
            self.id = id
            self.name = name
            self.managementId = managementId
            self.ddmEnabled = ddmEnabled
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

    /// Outcome of one call type across the fleet.
    private struct CallTypeTally: Sendable {
        var attempted = 0
        var failed = 0
        var stopped: String?      // reason the call type was abandoned for the run
    }

    private enum CallType: String, Sendable { case history, statusItems }

    private struct DeviceResult: Sendable {
        let target: DeviceScanTarget
        let history: (exit: Int32, data: Data)?      // nil = call type not made
        let status: (exit: Int32, data: Data)?
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
                    lastRun: stateStore?.lastRun(report: kind),
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
        onLine(.init(
            timestamp: Date(), level: .info,
            text: "[info] device scan: \(targets.count) Mac(s), "
                + "\(targets.filter(\.ddmEnabled).count) DDM-enabled"
        ))

        let results = await scanDevices(targets, profile: profile, bin: bin, onLine: onLine)
        return reduceAndSave(
            results: results, totalTargets: targets.count, dataDir: dataDir,
            recordManifest: recordManifest, stateStore: stateStore,
            collectStart: collectStart, onLine: onLine
        )
    }

    // MARK: - Fan-out

    /// Bounded task group: at most `deviceScanConcurrency` jamf-cli processes.
    /// Exit 5 or 8 on ANY device abandons that call type for the remaining
    /// devices (an actor-guarded flag read before each launch); exit 3 abandons
    /// both — a credential that died mid-scan will not come back for device 400.
    private static func scanDevices(
        _ targets: [DeviceScanTarget], profile: String, bin: URL,
        onLine: @Sendable @escaping (CLIBridge.LogLine) -> Void
    ) async -> [DeviceResult] {
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
        return results
    }

    private static func scanOne(
        _ t: DeviceScanTarget, profile: String, bin: URL, bridge: CLIBridge, gate: StopGate,
        onLine: @Sendable @escaping (CLIBridge.LogLine) -> Void
    ) async -> DeviceResult {
        var history: (Int32, Data)?
        var status: (Int32, Data)?
        if await gate.allows(.history) {
            history = await run(bridge, bin, [
                "-p", profile, "pro", "classic-computer-history", "get", t.id,
                "--subset", "commands", "--output", "json",
            ])
            if let h = history { await gate.observe(h.0, for: .history, onLine: onLine) }
        }
        if t.ddmEnabled, let mgmt = t.managementId, CLIBridge.isSafeDeviceIdentifier(mgmt),
           await gate.allows(.statusItems) {
            status = await run(bridge, bin, [
                "-p", profile, "pro", "ddm-status", "status-items", mgmt, "--output", "json",
            ])
            if let s = status { await gate.observe(s.0, for: .statusItems, onLine: onLine) }
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

    /// Per-run "stop this call type" flags. An actor so the four in-flight
    /// tasks agree on the decision without a lock.
    private actor StopGate {
        private var stopped: [CallType: String] = [:]

        func allows(_ type: CallType) -> Bool { stopped[type] == nil }

        func observe(
            _ exit: Int32, for type: CallType,
            onLine: @Sendable (CLIBridge.LogLine) -> Void
        ) {
            guard stopped[type] == nil else { return }
            let kind = type == .history
                ? ReportEngine.mdmCommandHealthKind
                : ReportEngine.ddmDeviceStatusKind
            switch exit {
            case CLIBridge.exitCodePermissionDenied:
                stopped[type] = "exit 5 — the API role needs Read Computers"
                onLine(.init(
                    timestamp: Date(), level: .warn,
                    text: "[warn] \(kind): exit 5 on the first device — the API "
                        + "role needs Read Computers; skipping the rest of the run"
                ))
            case CLIBridge.exitCodeRefusedByPolicy:
                stopped[type] = "exit 8 — refused by policy"
                onLine(.init(
                    timestamp: Date(), level: .warn,
                    text: "[warn] \(kind): refused by policy (exit 8) — this "
                        + "profile's API does not publish the command; skipping for the run"
                ))
            case CLIBridge.exitCodeUnauthorized:
                stopped[.history] = "exit 3 — credentials rejected mid-scan"
                stopped[.statusItems] = stopped[.history]
                onLine(.init(
                    timestamp: Date(), level: .warn,
                    text: "[warn] device scan: credentials rejected (exit 3) "
                        + "part-way through; stopping both call types"
                ))
            default: break
            }
        }
    }

    // MARK: - Reduce + save

    private static func reduceAndSave(
        results: [DeviceResult], totalTargets: Int, dataDir: URL, recordManifest: Bool,
        stateStore: StateFileStore?, collectStart: Date,
        onLine: @Sendable @escaping (CLIBridge.LogLine) -> Void
    ) -> Set<String> {
        var saved: Set<String> = []
        let now = Date()

        // History → mdm-command-health (every device).
        var health: [MDMCommandHealthRecord] = []
        var historyAttempted = 0, historyFailed = 0
        for r in results {
            guard let h = r.history else { continue }
            historyAttempted += 1
            if h.exit == 0 || h.exit == CLIBridge.exitCodePartialFailure,
               let decoded = try? JSONDecoder().decode(ComputerHistoryCommands.self, from: h.data) {
                health.append(DeviceScanBuilders.healthRecord(
                    deviceId: r.target.id, name: r.target.name, history: decoded, now: now
                ))
            } else {
                historyFailed += 1
            }
        }
        let historyAbandoned = historyAttempted < results.count && historyAttempted > 0
        if historyAttempted == 0 {
            // Stopped on the first device (exit 5/8/3) — the gate already logged why.
            stateStore?.record(
                .failed(exitCode: nil), report: mdmCommandHealthKind, at: collectStart
            )
        } else if historyAbandoned
            || DeviceScanBuilders.exceedsFailureBudget(
                failed: historyFailed, total: historyAttempted
            ) {
            onLine(.init(
                timestamp: Date(), level: .warn,
                text: "[warn] \(mdmCommandHealthKind): \(historyFailed) of \(historyAttempted) "
                    + "devices failed — not written"
            ))
            stateStore?.record(
                .failed(exitCode: nil), report: mdmCommandHealthKind, at: collectStart
            )
        } else {
            save(
                health, kind: mdmCommandHealthKind, failed: historyFailed,
                attempted: historyAttempted, dataDir: dataDir, recordManifest: recordManifest,
                stateStore: stateStore, collectStart: collectStart, onLine: onLine, saved: &saved
            )
        }

        // Status items → ddm-device-status (DDM-enabled devices only).
        let ddmTargets = results.filter { $0.target.ddmEnabled && $0.target.managementId != nil }
        if !ddmTargets.isEmpty {
            var rows: [DDMDeviceStatusRecord] = []
            var attempted = 0, failed = 0
            for r in ddmTargets {
                guard let s = r.status else { continue }
                attempted += 1
                let mgmt = r.target.managementId ?? ""
                if s.exit == CLIBridge.exitCodeNotFound {
                    rows.append(DeviceScanBuilders.ddmRecordNotReported(
                        deviceId: r.target.id, name: r.target.name, managementId: mgmt
                    ))
                } else if s.exit == 0 || s.exit == CLIBridge.exitCodePartialFailure,
                          let payload = try? JSONDecoder().decode(
                              DDMStatusItemsPayload.self, from: s.data
                          ) {
                    rows.append(DeviceScanBuilders.ddmRecord(
                        deviceId: r.target.id, name: r.target.name,
                        managementId: mgmt, payload: payload
                    ))
                } else {
                    failed += 1
                }
            }
            let abandoned = attempted < ddmTargets.count && attempted > 0
            if attempted == 0 {
                stateStore?.record(
                    .failed(exitCode: nil), report: ddmDeviceStatusKind, at: collectStart
                )
            } else if abandoned
                || DeviceScanBuilders.exceedsFailureBudget(failed: failed, total: attempted) {
                onLine(.init(
                    timestamp: Date(), level: .warn,
                    text: "[warn] \(ddmDeviceStatusKind): \(failed) of \(attempted) "
                        + "devices failed — not written"
                ))
                stateStore?.record(
                    .failed(exitCode: nil), report: ddmDeviceStatusKind, at: collectStart
                )
            } else {
                save(
                    rows, kind: ddmDeviceStatusKind, failed: failed, attempted: attempted,
                    dataDir: dataDir, recordManifest: recordManifest, stateStore: stateStore,
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
