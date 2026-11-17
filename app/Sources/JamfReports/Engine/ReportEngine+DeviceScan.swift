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

    /// Seconds one per-device jamf-cli call gets. `pro classic-computer-history` and
    /// `status-items` make a few requests, and one request may wait 120 s; past this the call
    /// is stopped and counts as a failed device, like exit 1.
    static let deviceCallTimeout: TimeInterval = 180

    /// Consecutive timed-out calls of one call type after which the scan stops that call type
    /// for the run: a server that never answers would otherwise cost the limit on every device.
    static let deviceTimeoutStopThreshold = 3

    /// The per-call limit and the timeout stop rule; tests inject smaller ones.
    struct DeviceCallLimits: Sendable {
        var timeout: TimeInterval = ReportEngine.deviceCallTimeout
        var stopAfterTimeouts: Int = ReportEngine.deviceTimeoutStopThreshold
    }
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
        /// `general.site.id`; nil for no site ("-1", blank or absent).
        let siteId: String?

        private enum Keys: String, CodingKey { case id, general }
        private enum General: String, CodingKey {
            case name, managementId, declarativeDeviceManagementEnabled, site
        }
        private enum Site: String, CodingKey { case id }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: Keys.self)
            // Both ids are trimmed once, here: `isSafeDeviceIdentifier` trims before it
            // checks, so the value it passes has to be the value argv and the rows get.
            let rawId = try c.decodeIfPresent(AnyCodable.self, forKey: .id)?.stringValue ?? ""
            id = rawId.trimmingCharacters(in: .whitespacesAndNewlines)
            let g = try? c.nestedContainer(keyedBy: General.self, forKey: .general)
            name = (try? g?.decodeIfPresent(String.self, forKey: .name)) ?? ""
            managementId = (try? g?.decodeIfPresent(String.self, forKey: .managementId))?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            // Two if-let steps: try? flattens decodeIfPresent's result to a single optional.
            var ddm = false
            if let container = g,
               let raw = try? container.decodeIfPresent(
                   AnyCodable.self, forKey: .declarativeDeviceManagementEnabled
               ) {
                ddm = raw.boolValue ?? false
            }
            ddmEnabled = ddm
            let site = (try? g?.nestedContainer(keyedBy: Site.self, forKey: .site))
                .flatMap { try? $0.decodeIfPresent(AnyCodable.self, forKey: .id) }?
                .stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            siteId = (site == nil || site == "" || site == "-1") ? nil : site
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

        /// What exit 5 needs when jamf-cli's hint names nothing: the Jamf Pro API role
        /// privilege, or the Jamf Account permission of a Platform API integration.
        var permissionFallback: String {
            switch self {
            case .history:
                return "Read Computers (API role) or Inventory > Device history (Jamf Account)"
            case .statusItems:
                return "Read Computers (API role) or Inventory > Devices (Jamf Account)"
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

    /// Whether the phase runs: the tier set, Settings, then the cadence floor, which `force`
    /// bypasses. Decided with the matrix, so the `[plan]` block and the phase share it. While a
    /// round is open, any unforced run takes one pass a local day, whatever its tiers.
    static func planDeviceScan(
        tiers: Set<CollectionTier>, skipExpensive: Bool, force: Bool,
        collectSkip: Set<String> = [], stateStore: StateFileStore?, now: Date
    ) -> DeviceScanPlan {
        let round = continuedRound(
            DeviceScanPasses.round(in: stateStore, now: now), collectSkip: collectSkip)
        guard tiers.contains(.scan) || (round != nil && !force) else { return .tierNotSelected }
        guard !skipExpensive else { return .turnedOff }
        let scanKinds = [ddmDeviceStatusKind, mdmCommandHealthKind].filter {
            !collectSkip.contains($0)
        }
        guard !scanKinds.isEmpty else { return .listedInCollectSkip }
        guard !force else { return .due }
        if let round {
            return Calendar.current.isDate(round.lastPass, inSameDayAs: now)
                ? .notDue(lastAttempt: round.lastPass) : .due
        }
        let attempts = scanKinds.map { kind in
            (kind: kind, last: lastAttemptDate(for: kind, stateStore: stateStore))
        }
        let due = attempts.contains {
            CadenceResolver.isDue(
                lastRun: $0.last, cadence: CadenceResolver.cadence(forReport: $0.kind), now: now)
        }
        return due ? .due : .notDue(lastAttempt: attempts.compactMap(\.last).max())
    }

    /// The scan kinds `collectSkip` turns off, as a round records them.
    static func scanKindsTurnedOff(_ collectSkip: Set<String>) -> [String] {
        [ddmDeviceStatusKind, mdmCommandHealthKind].filter(collectSkip.contains).sorted()
    }

    /// `round` when it was started with the same scan kinds turned off; otherwise a fresh round
    /// starts, so a pass never carries a round across a switch change.
    static func continuedRound(
        _ round: DeviceScanRound?, collectSkip: Set<String>
    ) -> DeviceScanRound? {
        guard let round, (round.turnedOff ?? []) == scanKindsTurnedOff(collectSkip) else {
            return nil
        }
        return round
    }

    /// Returns the kinds it wrote. Never throws: the matrix's verdicts have
    /// already run, and a scan problem must not turn a good run red. An unforced pass stops
    /// starting Macs after `scanBudget` seconds or when `runStop` asks; a forced one scans all.
    /// `scanStop` (tests) replaces that decision; it gets how many Macs the pass has started.
    static func runDeviceScanPhase(
        profile: String, bin: URL, dataDir: URL, plan: DeviceScanPlan,
        recordManifest: Bool,
        collectSkip: Set<String> = [],
        stateStore: StateFileStore?, collectStart: Date,
        authConfirmationProbe: @escaping AuthConfirmationProbe,
        limits: DeviceCallLimits = DeviceCallLimits(),
        force: Bool = true,
        scanBudget: TimeInterval = TimeInterval(JamfCLIConfig.defaultScanBudgetMinutes * 60),
        scanStop: (@Sendable (Int) -> Bool)? = nil,
        onLine: @Sendable @escaping (CLIBridge.LogLine) -> Void
    ) async -> Set<String> {
        guard plan == .due else {
            if case .notDue = plan {
                onLine(.init(timestamp: Date(), level: .info, text: "[skip] device scan: not due"))
            }
            return []
        }
        // A call type turned off in this workspace makes no call and records nothing.
        let off = Set([CallType.history, .statusItems].filter { collectSkip.contains($0.kind) })
        guard let targets = loadScanTargets(dataDir: dataDir, onLine: onLine),
              let earlier = loadEarlier(
                  dataDir: dataDir, wholeFleet: force, off: off, onLine: onLine)
        else { return [] }
        onLine(.init(
            timestamp: Date(), level: .info,
            text: "[info] device scan: \(targets.count) Mac(s), "
                + "\(targets.filter(\.ddmEnabled).count) DDM-enabled"
        ))
        let targetIDs = Set(targets.map(\.id))
        var round = force ? nil : continuedRound(
            DeviceScanPasses.round(in: stateStore, now: collectStart), collectSkip: collectSkip)
        var doneBefore = Set(round?.attempted ?? []).intersection(targetIDs)
        // A round that already covers every current target has nothing left: start afresh.
        if doneBefore == targetIDs { round = nil; doneBefore = [] }
        let pending = DeviceScanPasses.passOrder(
            targets.filter { !doneBefore.contains($0.id) },
            health: earlier.health, ddm: earlier.ddm)
        let passStart = Date()
        let stopRun = runStop
        let shouldStop: (@Sendable (Int) -> Bool)? = scanStop ?? (force ? nil : { @Sendable _ in
            passShouldStop(passStart: passStart, now: Date(), budget: scanBudget,
                           runStop: stopRun)
        })
        let (results, stops, stopCause) = await scanDevices(
            pending, profile: profile, bin: bin, off: off,
            probe: authConfirmationProbe, limits: limits, shouldStop: shouldStop, onLine: onLine
        )
        let attempted = Set(results.map(\.target.id))
        guard !attempted.isEmpty else {
            // Nothing new: no write, no landing, and the round stays as it was.
            onLine(.init(timestamp: Date(), level: .info, text:
                "[info] device scan: scanned 0 of \(targets.count) Macs this pass; "
                    + "\(pending.count) left for the next pass"))
            return []
        }
        let left = pending.count - attempted.count
        let pass = PassInput(
            results: results, stops: stops, off: off, stopCause: stopCause, targets: targets,
            earlier: earlier, prior: round,
            roundEnds: left <= 0 || !stops.isEmpty)
        let (written, tallies) = reduceAndSave(
            pass, dataDir: dataDir, recordManifest: recordManifest, stateStore: stateStore,
            collectStart: collectStart, onLine: onLine)
        if pass.roundEnds {
            stateStore?.clearDeviceScanRound()
        } else {
            let next = DeviceScanRound(
                started: round?.started ?? collectStart, lastPass: collectStart,
                attempted: doneBefore.union(attempted).sorted(), remaining: left,
                history: (round?.history ?? DeviceScanTally()) + (tallies[.history] ?? .init()),
                statusItems: (round?.statusItems ?? DeviceScanTally())
                    + (tallies[.statusItems] ?? .init()),
                turnedOff: scanKindsTurnedOff(collectSkip))
            do { try stateStore?.recordDeviceScanRound(next) } catch {
                onLine(.init(timestamp: Date(), level: .warn, text:
                    "[warn] device scan: round not recorded — \(error.englishDescription)"))
            }
            onLine(.init(timestamp: Date(), level: .info, text:
                "[info] device scan: scanned \(attempted.count) of \(targets.count) Macs "
                    + "this pass; \(left) left for the next pass"))
        }
        return written
    }

    /// The budget is spent or someone is waiting to refresh in the app.
    static func passShouldStop(
        passStart: Date, now: Date, budget: TimeInterval, runStop: (@Sendable () -> RunStop?)?
    ) -> Bool {
        now.timeIntervalSince(passStart) >= budget || runStop?() != nil
    }

    /// The scan targets from the newest `computers` snapshot, logging why there are none.
    private static func loadScanTargets(
        dataDir: URL, onLine: @Sendable (CLIBridge.LogLine) -> Void
    ) -> [DeviceScanTarget]? {
        guard let data = try? loadLatestSnapshotData(kind: "computers", dataDir: dataDir),
              let found = DeviceScanPasses.scanTargets(from: data),
              found.unsafe + found.targets.count > 0 else {
            onLine(.init(timestamp: Date(), level: .info,
                         text: "[skip] device scan: no computers snapshot"))
            return nil
        }
        for _ in 0..<found.unsafe {
            onLine(.init(timestamp: Date(), level: .warn,
                         text: "[warn] device scan: skipping a device with an unsafe id"))
        }
        guard !found.targets.isEmpty else {
            onLine(.init(timestamp: Date(), level: .warn,
                         text: "[warn] device scan: no reachable devices — nothing attempted"))
            return nil
        }
        return found.targets
    }

    /// The two kinds' newest earlier rows; nil, after one line per kind, when a snapshot is
    /// there but cannot be read, so this pass's rows never replace a whole-fleet file. A forced
    /// scan takes the whole fleet, so what it writes is whole and may replace an unreadable
    /// file; otherwise one bad file would block the scan until someone removed it.
    private static func loadEarlier(
        dataDir: URL, wholeFleet: Bool, off: Set<CallType> = [],
        onLine: @Sendable (CLIBridge.LogLine) -> Void
    ) -> Earlier? {
        // A kind turned off is never read: its file, readable or not, cannot hold up the other.
        let health = off.contains(.history) ? [] : DeviceScanPasses.earlierRows(
            kind: mdmCommandHealthKind, dataDir: dataDir, as: MDMCommandHealthRecord.self)
        let ddm = off.contains(.statusItems) ? [] : DeviceScanPasses.earlierRows(
            kind: ddmDeviceStatusKind, dataDir: dataDir, as: DDMDeviceStatusRecord.self)
        for (kind, rows) in [(mdmCommandHealthKind, health == nil),
                             (ddmDeviceStatusKind, ddm == nil)] where rows {
            onLine(.init(timestamp: Date(), level: .warn,
                         text: "[warn] device scan: \(kind) snapshot could not be read; "
                            + (wholeFleet ? "this full scan replaces it" : "pass skipped")))
        }
        if wholeFleet { return Earlier(health: health ?? [], ddm: ddm ?? []) }
        guard let health, let ddm else { return nil }
        return Earlier(health: health, ddm: ddm)
    }

    /// The newest earlier row of each Mac, per kind, each with a scan time when one is known.
    private struct Earlier {
        let health: [MDMCommandHealthRecord]
        let ddm: [DDMDeviceStatusRecord]
    }

    /// One pass's results and what the round knew before it.
    private struct PassInput {
        let results: [DeviceResult]
        let stops: [CallType: Int32]
        var off: Set<CallType> = []
        let stopCause: FailureCause?
        let targets: [DeviceScanTarget]
        let earlier: Earlier
        let prior: DeviceScanRound?
        /// Every target attempted, or a call type stopped.
        let roundEnds: Bool
    }

    /// A failed attempt still counts as an attempt for cadence purposes —
    /// otherwise a chronically-failing kind never advances its `.last` state
    /// and self-remediation's hourly retry turns it into an hourly full
    /// fan-out instead of waiting for the scan tier's normal weekly cadence.
    /// `force: true` (manual Collect now) bypasses this via the `!force`
    /// guard above.
    private static func lastAttemptDate(for kind: String, stateStore: StateFileStore?) -> Date? {
        // A credentials failure is not an attempt: once they are fixed, scan on the next
        // pass rather than a week later. Every other failure keeps holding the floor.
        let authFailure =
            stateStore?.lastFailureExitCode(for: kind) == CLIBridge.exitCodeUnauthorized
        let failure = authFailure ? nil : stateStore?.failures(report: kind)?.last
        return [stateStore?.lastRun(report: kind), failure].compactMap { $0 }.max()
    }

    // MARK: - Fan-out

    /// Bounded task group: at most `deviceScanConcurrency` jamf-cli processes.
    /// Exit 5 or 8 on ANY device abandons that call type for the remaining
    /// devices (an actor-guarded flag read before each launch); exit 3 abandons
    /// both — a credential that died mid-scan will not come back for device 400. Timed-out
    /// calls stop their call type after `limits.stopAfterTimeouts` in a row (exit -2).
    private static func scanDevices(
        _ targets: [DeviceScanTarget], profile: String, bin: URL, off: Set<CallType> = [],
        probe: @escaping AuthConfirmationProbe, limits: DeviceCallLimits,
        shouldStop: (@Sendable (Int) -> Bool)?,
        onLine: @Sendable @escaping (CLIBridge.LogLine) -> Void
    ) async -> (results: [DeviceResult], stops: [CallType: Int32], stopCause: FailureCause?) {
        let bridge = CLIBridge()
        let gate = StopGate(probe: probe, profile: profile, bin: bin, limits: limits, off: off)
        var results: [DeviceResult] = []
        results.reserveCapacity(targets.count)
        var done = 0

        await withTaskGroup(of: DeviceResult.self) { group in
            var inFlight = 0
            var started = 0
            for target in targets {
                if inFlight >= deviceScanConcurrency, let r = await group.next() {
                    inFlight -= 1
                    results.append(r)
                    done += 1
                    // After a stop the remaining devices return without calling
                    // jamf-cli, so a running count would read as scanning continuing.
                    if done % progressEvery == 0, await gate.stillScanning() {
                        onLine(.init(
                            timestamp: Date(), level: .info,
                            text: "[info] device scan: \(done) of \(targets.count)"
                        ))
                    }
                }
                // Calls in flight finish; the pass only stops starting Macs.
                if shouldStop?(started) == true { break }
                started += 1
                inFlight += 1
                group.addTask {
                    await scanOne(
                        target, profile: profile, bin: bin, bridge: bridge,
                        gate: gate, limits: limits, onLine: onLine
                    )
                }
            }
            for await r in group { results.append(r) }
        }
        return (results, await gate.stops(), await gate.stopCause())
    }

    static func historyArguments(profile: String, id: String) -> [String] {
        ["-p", profile, "pro", "classic-computer-history", "get", id,
         "--subset", "commands", "--output", "json"]
    }

    static func statusItemsArguments(profile: String, managementId: String) -> [String] {
        ["-p", profile, "pro", "declarative-device-management", "status-items", managementId,
         "--output", "json"]
    }

    private static func scanOne(
        _ t: DeviceScanTarget, profile: String, bin: URL, bridge: CLIBridge, gate: StopGate,
        limits: DeviceCallLimits,
        onLine: @Sendable @escaping (CLIBridge.LogLine) -> Void
    ) async -> DeviceResult {
        var history: CallOutcome = .notMade
        var status: CallOutcome = .notMade

        if await gate.allows(.history) {
            history = await call(
                .history, historyArguments(profile: profile, id: t.id),
                bridge: bridge, bin: bin, gate: gate, timeout: limits.timeout, onLine: onLine)
        }

        if t.ddmEnabled {
            if let mgmt = t.managementId, CLIBridge.isSafeDeviceIdentifier(mgmt) {
                if await gate.allows(.statusItems) {
                    status = await call(
                        .statusItems,
                        statusItemsArguments(profile: profile, managementId: mgmt),
                        bridge: bridge, bin: bin, gate: gate, timeout: limits.timeout,
                        onLine: onLine
                    )
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

    /// Runs one device call. On exit 3 the gate forces a fresh token; if that works, the
    /// call is retried once in a new jamf-cli process, which reads the new token.
    private static func call(
        _ type: CallType, _ args: [String], bridge: CLIBridge, bin: URL, gate: StopGate,
        timeout: TimeInterval,
        onLine: @Sendable @escaping (CLIBridge.LogLine) -> Void
    ) async -> CallOutcome {
        guard var result = await run(bridge, bin, args, timeout: timeout) else {
            await gate.noteLaunchFailure(type, onLine: onLine)
            return .launchFailed
        }
        if result.exit == CLIBridge.exitCodeUnauthorized,
           await gate.credentialsConfirmed(onLine: onLine) {
            guard let retry = await run(bridge, bin, args, timeout: timeout) else {
                await gate.noteLaunchFailure(type, onLine: onLine)
                return .launchFailed
            }
            result = retry
        }
        let exit = FailureCause.exitCountingServerTimeout(result.exit, stdout: result.data)
        await gate.observe(
            exit, stdout: result.data, keychainLocked: result.keychainLocked,
            for: type, onLine: onLine)
        return .ran(exit: exit, data: result.data)
    }

    static func run(
        _ bridge: CLIBridge, _ bin: URL, _ args: [String], timeout: TimeInterval
    ) async -> (exit: Int32, data: Data, keychainLocked: Bool)? {
        // stderr is read only for the locked-keychain line; a device call prints nothing else
        // the scan acts on.
        let watcher = StderrSignalWatcher()
        guard let (exit, data) = try? await bridge.runAndCapture(
            executable: bin, arguments: args,
            environment: CLIBridge.environmentForJamfCLI(),
            timeout: timeout, onLine: watcher.forwarding(to: { _ in })
        ) else { return nil }
        return (exit, data, watcher.sawKeychainLocked)
    }

    /// Per-run "stop this call type" flags, keyed by the exit code that
    /// triggered the stop, plus a one-shot log guard for launch failures. An
    /// actor so the four in-flight tasks agree on the decision without a lock.
    private actor StopGate {
        private let probe: AuthConfirmationProbe
        private let profile: String
        private let bin: URL
        private var stopped: [CallType: Int32] = [:]
        private var launchFailureLogged: Set<CallType> = []
        private var tokenCheck: Task<Bool, Never>?
        private var tokenCheckLogged = false
        private let limits: DeviceCallLimits
        private var timeoutStreak: [CallType: Int] = [:]
        private var keychainStop: FailureCause?
        private let off: Set<CallType>

        init(
            probe: @escaping AuthConfirmationProbe, profile: String, bin: URL,
            limits: DeviceCallLimits, off: Set<CallType> = []
        ) {
            self.probe = probe
            self.profile = profile
            self.bin = bin
            self.limits = limits
            self.off = off
        }

        func allows(_ type: CallType) -> Bool { stopped[type] == nil && !off.contains(type) }

        /// False once both call types are stopped — no device will call jamf-cli again.
        func stillScanning() -> Bool { allows(.history) || allows(.statusItems) }

        func stops() -> [CallType: Int32] { stopped }

        /// Set when a locked login keychain stopped the scan, so the failure is recorded with it.
        func stopCause() -> FailureCause? { keychainStop }

        /// One forced token exchange shared by every device that hit exit 3 at the same
        /// moment; true means jamf-cli could still get a token.
        // ponytail: no per-run cap. A retry that exits 3 again stops the scan, so each
        // burst costs at most one extra token plus one extra call per device.
        func credentialsConfirmed(onLine: @Sendable (CLIBridge.LogLine) -> Void) async -> Bool {
            let check: Task<Bool, Never>
            if let tokenCheck {
                check = tokenCheck
            } else {
                check = Task { [probe, profile, bin] in await probe(profile, bin) == .alive }
                tokenCheck = check
            }
            let valid = await check.value
            if tokenCheck == check { tokenCheck = nil }
            if !tokenCheckLogged {
                tokenCheckLogged = true
                onLine(.init(
                    timestamp: Date(), level: .warn,
                    text: valid
                        ? "[warn] device scan: a device call was rejected (exit 3) but jamf-cli "
                            + "got a fresh token — retrying"
                        : "[warn] device scan: exit 3, and jamf-cli could not get a fresh token"
                ))
            }
            return valid
        }

        func observe(
            _ exit: Int32, stdout: Data, keychainLocked: Bool = false, for type: CallType,
            onLine: @Sendable (CLIBridge.LogLine) -> Void
        ) {
            guard stopped[type] == nil else { return }
            let kind = type.kind
            // A locked keychain fails every device the same way (exit 1), so both call types stop.
            if exit != 0, keychainLocked
                || FailureCause.classify(exitCode: exit, stdout: stdout).kind == .keychainLocked {
                for t in [CallType.history, .statusItems] where stopped[t] == nil {
                    stopped[t] = exit
                }
                keychainStop = FailureCause(
                    kind: .keychainLocked, names: [], hint: FailureCause.keychainLockedHint,
                    exitCode: exit)
                onLine(.init(
                    timestamp: Date(), level: .warn,
                    text: "[warn] device scan: the login keychain is locked — "
                        + FailureCause.keychainLockedHint + "; stopping both call types"
                ))
                return
            }
            noteTimeouts(exit, for: type, onLine: onLine)
            guard stopped[type] == nil else { return }
            switch exit {
            case CLIBridge.exitCodePermissionDenied:
                stopped[type] = exit
                // jamf-cli's hint names the grant in the terms of the API that answered.
                let cause = FailureCause.classify(exitCode: exit, stdout: stdout)
                let reason = cause.kind == .missingPermission && cause.names.isEmpty
                    ? "needs " + type.permissionFallback
                    : cause.label
                onLine(.init(
                    timestamp: Date(), level: .warn,
                    text: "[warn] \(kind): exit 5 from a device — \(reason); "
                        + "skipping the rest of the run"
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

        /// Counts consecutive timed-out calls of a call type; any other result resets the count.
        /// The last of `limits.stopAfterTimeouts` stops the call type with the timeout's code.
        private func noteTimeouts(
            _ exit: Int32, for type: CallType, onLine: @Sendable (CLIBridge.LogLine) -> Void
        ) {
            guard exit == CLIBridge.exitCodeTimedOut else {
                timeoutStreak[type] = 0
                return
            }
            let streak = (timeoutStreak[type] ?? 0) + 1
            timeoutStreak[type] = streak
            guard streak >= limits.stopAfterTimeouts else { return }
            stopped[type] = exit
            onLine(.init(
                timestamp: Date(), level: .warn,
                text: "[warn] stopped \(type.kind): \(streak) calls in a row timed out after "
                    + "\(Int(limits.timeout)) s"
            ))
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

    /// Ends a kind's pass. At the round's end a call type with more than a quarter of the
    /// round's attempts failed records the kind failed and writes nothing; otherwise this pass's
    /// rows, merged with every other target's earlier row, are written, and landed at the end.
    /// Returns whether it wrote.
    private static func finishKind<Row: DeviceScanRow>(
        _ tally: Tally<Row>, kind: String, earlier: [Row], carry: Set<String>,
        before: DeviceScanTally?, roundEnds: Bool, dataDir: URL, recordManifest: Bool,
        stateStore: StateFileStore?, collectStart: Date,
        onLine: @Sendable @escaping (CLIBridge.LogLine) -> Void
    ) -> Bool {
        let round = (before ?? DeviceScanTally())
            + DeviceScanTally(attempted: tally.attempted, failed: tally.failed)
        if roundEnds,
           DeviceScanBuilders.exceedsFailureBudget(failed: round.failed, total: round.attempted) {
            onLine(.init(
                timestamp: Date(), level: .warn,
                text: "[partial] \(kind): \(round.failed) of \(round.attempted) "
                    + "devices failed \(deviceScanNotWrittenMarkerSuffix)"
            ))
            stateStore?.record(.failed(exitCode: nil), report: kind, at: collectStart)
            return false
        }
        let now = Date()
        let scanned = tally.rows.map { row -> Row in
            var row = row
            row.scannedAt = ISO8601Time.string(now)
            return row
        }
        let rows = DeviceScanPasses.merged(
            scanned: scanned, earlier: earlier, carry: carry, now: now)
        guard save(rows, kind: kind, dataDir: dataDir, recordManifest: recordManifest,
                   stateStore: stateStore, collectStart: collectStart, onLine: onLine)
        else { return false }
        guard roundEnds else { return true }
        stateStore?.record(.landed, report: kind, at: collectStart)
        onLine(.init(timestamp: Date(), level: .ok, text: "[ok] \(kind): \(rows.count) device(s)"))
        if round.failed > 0 {
            // Shared suffix: the honesty watcher must not queue a retry for a landed kind.
            onLine(.init(
                timestamp: Date(), level: .warn,
                text: "[partial] \(kind): \(round.failed) of \(round.attempted) "
                    + deviceScanGapsMarkerSuffix
            ))
        }
        return true
    }

    /// Why a call type stopped, as the `[partial]` line says it.
    private static func stoppedText(_ stopExit: Int32) -> String {
        stopExit == CLIBridge.exitCodeTimedOut
            ? "stopped after repeated timeouts" : "stopped after exit \(stopExit)"
    }

    /// Records a stopped call type's kind failed, as before passes.
    private static func recordStopped(
        _ kind: String, stopExit: Int32, cause: FailureCause?, stateStore: StateFileStore?,
        collectStart: Date, onLine: @Sendable (CLIBridge.LogLine) -> Void
    ) {
        onLine(.init(
            timestamp: Date(), level: .warn,
            text: "[partial] \(kind): \(stoppedText(stopExit)) " + deviceScanNotWrittenMarkerSuffix
        ))
        stateStore?.record(
            .failed(exitCode: stopExit), report: kind, at: collectStart, cause: cause)
    }

    /// Returns the kinds written and this pass's attempts and failures per call type.
    private static func reduceAndSave(
        _ pass: PassInput, dataDir: URL, recordManifest: Bool,
        stateStore: StateFileStore?, collectStart: Date,
        onLine: @Sendable @escaping (CLIBridge.LogLine) -> Void
    ) -> (written: Set<String>, tallies: [CallType: DeviceScanTally]) {
        var written: Set<String> = []
        var tallies: [CallType: DeviceScanTally] = [:]
        let now = Date()

        // History → mdm-command-health (every device).
        if pass.off.contains(.history) {
            // Turned off in this workspace: nothing written, nothing recorded.
        } else if let stopExit = pass.stops[.history] {
            recordStopped(mdmCommandHealthKind, stopExit: stopExit, cause: pass.stopCause,
                          stateStore: stateStore, collectStart: collectStart, onLine: onLine)
        } else {
            let t = tally(
                pass.results, outcome: \.history
            ) { (r: DeviceResult, exit: Int32, data: Data) -> MDMCommandHealthRecord? in
                guard exit == 0 || exit == CLIBridge.exitCodePartialFailure,
                      let decoded = try? JSONDecoder().decode(
                          ComputerHistoryCommands.self, from: data
                      ) else { return nil }
                return DeviceScanBuilders.healthRecord(
                    deviceId: r.target.id, name: r.target.name, history: decoded, now: now
                )
            }
            tallies[.history] = DeviceScanTally(attempted: t.attempted, failed: t.failed)
            if finishKind(
                t, kind: mdmCommandHealthKind, earlier: pass.earlier.health,
                carry: Set(pass.targets.map(\.id)), before: pass.prior?.history,
                roundEnds: pass.roundEnds, dataDir: dataDir, recordManifest: recordManifest,
                stateStore: stateStore, collectStart: collectStart, onLine: onLine
            ) { written.insert(mdmCommandHealthKind) }
        }

        // Status items → ddm-device-status (DDM-enabled devices only). With none in the fleet
        // it writes an empty snapshot, a real result the health strip must see.
        if pass.off.contains(.statusItems) { return (written, tallies) }
        if let stopExit = pass.stops[.statusItems] {
            recordStopped(ddmDeviceStatusKind, stopExit: stopExit, cause: pass.stopCause,
                          stateStore: stateStore, collectStart: collectStart, onLine: onLine)
            return (written, tallies)
        }
        let t = tally(
            pass.results.filter { DeviceScanPasses.isDDMEligible($0.target) }, outcome: \.status
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
        tallies[.statusItems] = DeviceScanTally(attempted: t.attempted, failed: t.failed)
        // Eligible across the whole fleet, not this pass, so a pass that reached no DDM Mac
        // keeps the fleet's rows.
        if finishKind(
            t, kind: ddmDeviceStatusKind, earlier: pass.earlier.ddm,
            carry: Set(pass.targets.filter(DeviceScanPasses.isDDMEligible).map(\.id)),
            before: pass.prior?.statusItems, roundEnds: pass.roundEnds, dataDir: dataDir,
            recordManifest: recordManifest, stateStore: stateStore,
            collectStart: collectStart, onLine: onLine
        ) { written.insert(ddmDeviceStatusKind) }
        return (written, tallies)
    }

    /// Writes the snapshot; false, after recording the failure, when it cannot.
    private static func save<T: Encodable>(
        _ rows: [T], kind: String, dataDir: URL, recordManifest: Bool,
        stateStore: StateFileStore?, collectStart: Date,
        onLine: @Sendable @escaping (CLIBridge.LogLine) -> Void
    ) -> Bool {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            try saveSnapshot(
                data: try encoder.encode(rows), kind: kind, dataDir: dataDir,
                recordManifest: recordManifest, onLine: onLine
            )
            return true
        } catch {
            stateStore?.record(.failed(exitCode: nil), report: kind, at: collectStart)
            onLine(.init(
                timestamp: Date(), level: .warn,
                text: "[warn] \(kind): could not write snapshot — \(error.englishDescription)"
            ))
            return false
        }
    }
}
