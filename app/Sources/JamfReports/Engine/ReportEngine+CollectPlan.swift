import Foundation
import Synchronization

/// What `collect` will do, decided once before its first jamf-cli command. The same data
/// writes the `[plan]` lines at the top of the run log and drives the loop, so the log says
/// what the run then does. The per-kind `[skip]` lines stay: they carry the detail
/// (last run, cadence) the plan groups away.
extension ReportEngine {

    /// Why `collect` leaves a matrix command alone this run.
    enum CollectSkipReason: Equatable, Sendable {
        case settingsSkipExpensive
        case platformOnly(authMethod: String)
        case environmentLevel
        case schoolNoPlatform
        case platformUnavailable(String)
        case collectSkip
        /// The fleet has none of this side's devices (`FleetState`).
        case noDevices(FleetSide)
        /// The installed jamf-cli is older than the source needs (`minimumJamfCLI`), or unknown.
        case needsJamfCLI(required: String, installed: String?)
        case tierNotSelected(CollectionTier)
        case notDue(lastRun: Date?, cadence: Cadence)
        /// Its last failures all timed out; left alone until `retryAfter` unless forced.
        case repeatedTimeouts(retryAfter: Date)
        /// The workspace's own profile is a Platform one, which does not serve them.
        case serverHealthNotOnGateway
        /// The API role lacks the privilege; checked again weekly (`StateFileStore.advisoryHold`).
        case notPermitted
        /// The server has the feature unset; checked again weekly.
        case notConfigured
        /// An admin-hygiene source: collected only when `jamf_cli.collect_opt_in` lists it.
        case notOptedIn

        /// What follows `[skip] <kind>: `; nil when one aggregate line already says it.
        var skipDetail: String? {
            switch self {
            case .settingsSkipExpensive:
                return nil
            case .platformOnly(let authMethod):
                return "requires a Platform API profile (auth-method is \(authMethod))"
            case .environmentLevel:
                return "needs a platform environment integration (this profile is tenant level)"
            case .schoolNoPlatform:
                return "the Jamf School profile has no Platform API fields "
                    + "(Data Sources › Add Platform API)"
            case .platformUnavailable(let reason):
                return reason
            case .collectSkip:
                return "listed in jamf_cli.collect_skip"
            case .noDevices(let side):
                return "\(Self.noDevicesText(side)) (overview); checked again weekly"
            case .needsJamfCLI(let required, let installed):
                return "needs jamf-cli \(required) or later (installed: \(installed ?? "unknown"))"
            case .tierNotSelected(let tier):
                return "tier \(tier.rawValue) not selected"
            case .notDue(let lastRun, let cadence):
                return "not due (last: \(collectLogDateLabel(lastRun)), cadence: \(cadence.label))"
            case .repeatedTimeouts(let retryAfter):
                return "timed out \(WorkspaceStore.repeatedTimeoutsBeforeBackoff) runs in a row; "
                    + "next automatic try after \(collectLogDateLabel(retryAfter)) "
                    + "(Collect now tries it sooner)"
            case .serverHealthNotOnGateway:
                return "not collected through a Platform API profile yet"
            case .notPermitted: return "not permitted for this login; checked again weekly"
            case .notConfigured:
                return "not set up on this Jamf Pro server; checked again weekly"
            case .notOptedIn: return "off until turned on (jamf_cli.collect_opt_in)"
            }
        }

        /// The label the `[plan]` block groups kinds under.
        var planLabel: String {
            switch self {
            case .settingsSkipExpensive: return "Settings: Skip expensive collections"
            case .platformOnly(let authMethod):
                return "requires a Platform API profile, auth-method is \(authMethod)"
            case .environmentLevel: return "needs a platform environment integration"
            case .schoolNoPlatform: return "the School profile has no Platform API fields"
            case .platformUnavailable(let reason): return reason
            case .collectSkip: return "jamf_cli.collect_skip"
            case .noDevices(let side): return Self.noDevicesText(side)
            case .needsJamfCLI(let required, _):
                return "needs jamf-cli \(required) or later"
            case .tierNotSelected(let tier): return "tier \(tier.rawValue) not selected"
            case .notDue: return "not due"
            case .repeatedTimeouts: return "timed out repeatedly, left to the next day's run"
            case .serverHealthNotOnGateway: return "Platform API profile"
            case .notPermitted: return "not permitted"
            case .notConfigured: return "not set up"
            case .notOptedIn: return "not turned on (jamf_cli.collect_opt_in)"
            }
        }

        static func noDevicesText(_ side: FleetSide) -> String {
            side == .mac ? "no computers in Jamf Pro" : "no mobile devices in Jamf Pro"
        }

        /// A cadence skip, the only kind that says the server answered recently.
        var isNotDue: Bool {
            if case .notDue = self { return true }
            return false
        }
    }

    /// One matrix command and what this run does with it: `skip` is nil for a command that runs.
    struct PlannedKind: Equatable, Sendable {
        let args: [String]
        let kind: String
        let skip: CollectSkipReason?
    }

    /// What the plan reads about the run and the profile, all known before any matrix command.
    struct CollectPlanInputs: Sendable {
        let tiers: Set<CollectionTier>
        let force: Bool
        let skipExpensive: Bool
        let nonPlatformAuth: String?
        let tenantLevel: Bool
        let collectSkip: Set<String>
        let installedVersion: String?
        let now: Date
        var platformUnavailable: String?
        /// Sides of the fleet with no devices (`FleetState.skipped`); forced runs follow it too.
        var skippedSides: Set<FleetSide> = []
        /// The workspace's own profile uses Platform auth, which serves no server-health command.
        var workspaceAuthIsPlatform = false
        /// The opt-in sources this Mac collects (`SharedConfigPin.collectOptIn`).
        var optInKinds: Set<String> = []
    }

    /// Decides every matrix command. The order is the loop's always was: Settings, then what
    /// this profile or jamf-cli cannot serve, then the tier set, then cadence, so a command
    /// is reported under the first reason that applies. `lastRun` answers a kind's last
    /// success (the state files), read once here. `timeoutHold` answers when a kind that keeps
    /// timing out may run again (`StateFileStore.timeoutHoldUntil`); a kind that never lands
    /// has no last success, so cadence alone would run it in every collect of its tier.
    static func planCollect(
        commands: [(args: [String], kind: String)],
        inputs: CollectPlanInputs,
        timeoutHold: (String) -> Date? = { _ in nil },
        advisoryHold: (String) -> CollectSkipReason? = { _ in nil },
        lastRun: (String) -> Date?
    ) -> [PlannedKind] {
        commands.map { command in
            PlannedKind(
                args: command.args, kind: command.kind,
                skip: skipReason(
                    for: command.kind, inputs: inputs, timeoutHold: timeoutHold,
                    advisoryHold: advisoryHold, lastRun: lastRun))
        }
    }

    private static func skipReason(
        for kind: String, inputs: CollectPlanInputs, timeoutHold: (String) -> Date?,
        advisoryHold: (String) -> CollectSkipReason?, lastRun: (String) -> Date?
    ) -> CollectSkipReason? {
        if inputs.skipExpensive, expensivePerDeviceKinds.contains(kind) {
            return .settingsSkipExpensive
        }
        return profileSkip(for: kind, inputs: inputs)
            ?? scheduleSkip(
                for: kind, inputs: inputs, timeoutHold: timeoutHold,
                advisoryHold: advisoryHold, lastRun: lastRun)
    }

    /// Why a scheduled run stops before its next source. Nothing failed: what is left stays
    /// due, the run is not Partial, and the background item comes back for it
    /// (`CollectHonestyWatcher` reads `stoppedEarlyMarker`).
    enum RunStop: Equatable, Sendable {
        /// The run has held the lock for `jamf_cli.run_budget_minutes`.
        case budgetUsed(minutes: Int)
        /// Someone asked for a refresh in the app (`ManualRefreshRequest`). `sameWorkspaceFull`:
        /// that refresh collects everything due in this run's workspace.
        case manualRefresh(sameWorkspaceFull: Bool)

        var reason: String {
            switch self {
            case .budgetUsed(let minutes): return "run budget used (\(minutes) minutes)"
            case .manualRefresh: return "stopped for a manual refresh"
            }
        }

        /// The one decision a scheduled run's `runStop` closure makes.
        static func evaluate(
            started: Date, budgetMinutes: Int, refresh: ManualRefreshRequest.Pending,
            profile: String, now: Date = Date()
        ) -> RunStop? {
            if refresh != .none {
                return .manualRefresh(sameWorkspaceFull: refresh.isFullRefresh(of: profile))
            }
            return now.timeIntervalSince(started) >= Double(budgetMinutes * 60)
                ? .budgetUsed(minutes: budgetMinutes) : nil
        }
    }

    /// Runs `body` as an automatic run that may stop between sources: once it has held the lock
    /// for `profile`'s `jamf_cli.run_budget_minutes`, or while someone waits to refresh in the
    /// app. The budget is per workspace: a schedule over several holds the lock for each.
    static func stoppingBetweenSources<T: Sendable>(
        profile: String, _ body: @Sendable () async throws -> T
    ) async rethrows -> T {
        let budget = ProfileService.workspaceURL(for: profile)
            .flatMap { try? ConfigLoader.load(from: $0.appendingPathComponent("config.yaml")) }?
            .jamfCli?.resolvedRunBudgetMinutes ?? JamfCLIConfig.defaultRunBudgetMinutes
        let started = Date()
        return try await $runStop.withValue({
            RunStop.evaluate(
                started: started, budgetMinutes: budget,
                refresh: ManualRefreshRequest.pending(), profile: profile)
        }, operation: body)
    }

    /// What a scheduled run planned, what it left and why it stopped, kept as values for the tick
    /// (`ReportEngine.runProgress`); the log lines say the same for people.
    final class RunProgress: Sendable {
        private struct State {
            var planned: [String] = []
            var left: [String] = []
            var stop: RunStop?
            var protectOnly = false
        }
        private let state = Mutex(State())

        init() {}

        var planned: [String] { state.withLock { $0.planned } }
        var left: [String] { state.withLock { $0.left } }
        var stop: RunStop? { state.withLock { $0.stop } }
        /// Set by the scheduled run: a confirmed Protect-only environment is never continued.
        var protectOnly: Bool {
            get { state.withLock { $0.protectOnly } }
            set { state.withLock { $0.protectOnly = newValue } }
        }

        func addPlanned(_ names: [String]) {
            state.withLock { s in s.planned += names.filter { !s.planned.contains($0) } }
        }

        /// Anything left was planned, the device scan included (its plan line is not a source list).
        /// One run can stop in several phases (Jamf Pro, then Protect, Security Cloud and the
        /// scan, each at its first source), so each phase's leftovers are added, not replaced.
        func recordStop(_ stop: RunStop, left: [String]) {
            state.withLock { s in
                s.stop = s.stop ?? stop
                s.left += left.filter { !s.left.contains($0) }
                s.planned += left.filter { !s.planned.contains($0) }
            }
        }
    }

    /// Starts every line that says a run stopped before its sources were done.
    static let stoppedEarlyMarker = "[info] stopped early: "

    /// True, after logging why and what is left, when `runStop` says to stop here.
    static func stopsRun(left: [String], onLine: @Sendable (CLIBridge.LogLine) -> Void) -> Bool {
        guard !left.isEmpty, let stop = runStop?() else { return false }
        runProgress?.recordStop(stop, left: left)
        let count = left.count == 1 ? "1 source" : "\(left.count) sources"
        onLine(.init(timestamp: Date(), level: .info, text: stoppedEarlyMarker
            + "\(stop.reason); \(count) left for the next run: \(left.joined(separator: ", "))"))
        return true
    }

    /// A source whose last attempt took longer than this many seconds runs after the others.
    static let slowSourceThreshold = 120

    /// The plan in the order the run takes it: sources whose last attempt took over
    /// `slowSourceThreshold` go last, shortest first, so one slow source does not hold up the
    /// rest of the day's data. Everything else, skipped sources included, keeps its place, and
    /// a workspace with no slow source runs in the matrix order.
    static func slowLast(_ plan: [PlannedKind], lastDuration: (String) -> Int?) -> [PlannedKind] {
        let slow = plan.enumerated().compactMap { index, item -> (Int, Int, PlannedKind)? in
            guard item.skip == nil, let seconds = lastDuration(item.kind),
                  seconds > slowSourceThreshold else { return nil }
            return (seconds, index, item)
        }
        guard !slow.isEmpty else { return plan }
        let slowKinds = Set(slow.map(\.2.kind))
        return plan.filter { !slowKinds.contains($0.kind) }
            + slow.sorted { ($0.0, $0.1) < ($1.0, $1.1) }.map(\.2)
    }

    /// `[plan] running last (slow on their last run): a 310s, b 722s`, or nil with none.
    static func slowLastLine(_ plan: [PlannedKind], lastDuration: (String) -> Int?) -> String? {
        let slow = plan.compactMap { item -> String? in
            guard item.skip == nil, let seconds = lastDuration(item.kind),
                  seconds > slowSourceThreshold else { return nil }
            return "\(item.kind) \(seconds)s"
        }
        return slow.isEmpty
            ? nil : "[plan] running last (slow on their last run): " + slow.joined(separator: ", ")
    }

    /// Kinds this profile's API, its scope or its jamf-cli cannot serve, or the operator
    /// turned off. Recorded nowhere: none of these is a failure.
    private static func profileSkip(
        for kind: String, inputs: CollectPlanInputs
    ) -> CollectSkipReason? {
        if let reason = inputs.platformUnavailable, platformOnlyKinds.contains(kind) {
            return .platformUnavailable(reason)
        }
        if let auth = inputs.nonPlatformAuth, platformOnlyKinds.contains(kind) {
            return .platformOnly(authMethod: auth)
        }
        if inputs.tenantLevel, environmentLevelKinds.contains(kind) { return .environmentLevel }
        if let side = skippedSide(of: kind, skipped: inputs.skippedSides) {
            return .noDevices(side)
        }
        if inputs.collectSkip.contains(kind) { return .collectSkip }
        if serverHealthKinds.contains(kind), inputs.workspaceAuthIsPlatform {
            return .serverHealthNotOnGateway
        }
        if let gate = jamfCLISkip(kind, installed: inputs.installedVersion) { return gate }
        if serverHealthOptInKinds.contains(kind), !inputs.optInKinds.contains(kind) {
            return .notOptedIn
        }
        return nil
    }

    /// The tier set, then cadence. An unmapped kind has no tier and is always allowed;
    /// `force` bypasses cadence so an ad-hoc refresh always refetches.
    private static func scheduleSkip(
        for kind: String, inputs: CollectPlanInputs, timeoutHold: (String) -> Date?,
        advisoryHold: (String) -> CollectSkipReason?, lastRun: (String) -> Date?
    ) -> CollectSkipReason? {
        if let tier = CollectionTier.tier(forReport: kind), !inputs.tiers.contains(tier) {
            return .tierNotSelected(tier)
        }
        guard !inputs.force else { return nil }
        if let until = timeoutHold(kind), inputs.now < until {
            return .repeatedTimeouts(retryAfter: until)
        }
        if let held = advisoryHold(kind) { return held }
        let cadence = CadenceResolver.cadence(forReport: kind)
        let last = lastRun(kind)
        // The daily summary takes these figures from the run that landed them, so each day's
        // first run collects them (`planAddOn`'s rule).
        if deploymentKinds.contains(kind), let last,
           !Calendar.current.isDate(last, inSameDayAs: inputs.now) {
            return nil
        }
        return CadenceResolver.isDue(lastRun: last, cadence: cadence, now: inputs.now)
            ? nil : .notDue(lastRun: last, cadence: cadence)
    }

    // MARK: - Sources collected after the matrix

    static let sofaKind = "sofa"
    static let patchReleaseDatesKind = "patch-release-dates"

    /// Fetches the SOFA feeds into `<dataDir>/sofa`; a test passes a stub so no collect
    /// reaches the network.
    typealias SOFARefresh = @Sendable (URL) async -> (SOFAFeedService.Snapshot, [String])
    static let defaultSOFARefresh: SOFARefresh = { dataDir in
        #if DEBUG
        // Same guard as the jamf-cli locator: a test that forgot to inject `refreshSOFA` must
        // not reach sofafeed.macadmins.io.
        if NSClassFromString("XCTestCase") != nil { return (.empty, []) }
        #endif
        return await SOFAFeedService.refresh(dataDir: dataDir)
    }

    /// The sources `finalizeCollect` fetches once the matrix is done. They have no cadence of
    /// their own: the tier set alone decides, so every collect that includes the Refresh
    /// tier fetches both, forced or not, unless `jamf_cli.collect_skip` lists one.
    static func sourcesAfterMatrix(
        tiers: Set<CollectionTier>, collectSkip: Set<String>, skippedSides: Set<FleetSide> = []
    ) -> [String] {
        selectedAfterMatrix(tiers: tiers).filter {
            !collectSkip.contains($0) && skippedSide(of: $0, skipped: skippedSides) == nil
        }
    }

    /// The after-matrix sources this run's tier set selects that `collect_skip` turns off.
    static func skippedAfterMatrix(
        tiers: Set<CollectionTier>, collectSkip: Set<String>, skippedSides: Set<FleetSide> = []
    ) -> [String] {
        selectedAfterMatrix(tiers: tiers).filter {
            collectSkip.contains($0) && skippedSide(of: $0, skipped: skippedSides) == nil
        }
    }

    /// The after-matrix sources this run's tier set selects that a fleet side leaves out.
    static func fleetSkippedAfterMatrix(
        tiers: Set<CollectionTier>, skippedSides: Set<FleetSide>
    ) -> [(kind: String, side: FleetSide)] {
        selectedAfterMatrix(tiers: tiers).compactMap { kind in
            skippedSide(of: kind, skipped: skippedSides).map { (kind, $0) }
        }
    }

    private static func selectedAfterMatrix(tiers: Set<CollectionTier>) -> [String] {
        [sofaKind, patchReleaseDatesKind].filter { kind in
            CollectionTier.tier(forReport: kind).map(tiers.contains) ?? false
        }
    }

    // MARK: - Log lines

    /// Writes the plan at the top of the run: Settings' per-device switch in the line it has
    /// always had, then the `[plan]` block.
    static func logCollectPlan(
        profile: String, plan: [PlannedKind], afterMatrix: [String],
        afterMatrixSkipped: [String] = [],
        afterMatrixFleetSkipped: [(kind: String, side: FleetSide)] = [],
        deviceScan: DeviceScanPlan,
        onLine: @Sendable (CLIBridge.LogLine) -> Void
    ) {
        let perDevice = plan.filter { $0.skip == .settingsSkipExpensive }.map(\.kind)
        if !perDevice.isEmpty {
            onLine(.init(
                timestamp: Date(), level: .info,
                text: "[info] skipping per-device commands (\(perDevice.joined(separator: ", "))) "
                    + "— Settings: Skip expensive collections"
            ))
        }
        let lines = collectPlanLines(
            profile: profile, plan: plan, afterMatrix: afterMatrix,
            afterMatrixSkipped: afterMatrixSkipped,
            afterMatrixFleetSkipped: afterMatrixFleetSkipped, deviceScan: deviceScan)
        for line in lines {
            onLine(.init(timestamp: Date(), level: .info, text: line))
        }
        // A skipped matrix kind gets its `[skip]` line from the loop; these have no loop.
        for kind in afterMatrixSkipped {
            onLine(.init(
                timestamp: Date(), level: .info,
                text: "[skip] \(kind): \(CollectSkipReason.collectSkip.skipDetail ?? "")"))
        }
        for (kind, side) in afterMatrixFleetSkipped {
            onLine(.init(
                timestamp: Date(), level: .info,
                text: "[skip] \(kind): \(CollectSkipReason.noDevices(side).skipDetail ?? "")"))
        }
    }

    /// Longest `[plan]` line; a longer list wraps onto an indented continuation line.
    private static let planLineLimit = 180

    /// The `[plan]` lines for a Jamf Pro collect: the sources that run (the matrix's, then
    /// `afterMatrix`), the ones left alone grouped by reason (`afterMatrixSkipped` being
    /// the after-matrix sources `collect_skip` turned off), and the device scan.
    static func collectPlanLines(
        profile: String, plan: [PlannedKind], afterMatrix: [String] = [],
        afterMatrixSkipped: [String] = [],
        afterMatrixFleetSkipped: [(kind: String, side: FleetSide)] = [],
        deviceScan: DeviceScanPlan
    ) -> [String] {
        var groups: [(label: String, kinds: [String])] = []
        func add(_ kind: String, under label: String) {
            if let index = groups.firstIndex(where: { $0.label == label }) {
                groups[index].kinds.append(kind)
            } else {
                groups.append((label, [kind]))
            }
        }
        for item in plan {
            if let skip = item.skip { add(item.kind, under: skip.planLabel) }
        }
        for kind in afterMatrixSkipped {
            add(kind, under: CollectSkipReason.collectSkip.planLabel)
        }
        for (kind, side) in afterMatrixFleetSkipped {
            add(kind, under: CollectSkipReason.noDevices(side).planLabel)
        }
        return collectPlanLines(
            profile: profile, running: plan.filter { $0.skip == nil }.map(\.kind) + afterMatrix,
            skipped: groups
        ) + ["[plan] \(deviceScan.planText)"]
    }

    /// The School matrix with this run's skips. School has no per-device scan, so its sources
    /// go with the refresh or inventory tier (a scan-only run collects nothing) at the refresh
    /// cadence; `force` (Collect now) ignores the cadence. `platformFieldsMissing` skips the
    /// blueprints kind, the one School source that needs the profile's Platform fields. A run
    /// with only the scan tier collects `school-devices`, the device scan's input, and only
    /// when `scanDue`; otherwise it stays a no-op. Any run with the scan tier ignores
    /// `school-devices`' cadence while the scan is due, so an unforced one (a split collect's
    /// continuation) still hands the scan the devices it needs.
    static func planSchoolCollect(
        profile: String, tiers: Set<CollectionTier>, force: Bool,
        collectSkip: Set<String> = [], now: Date = Date(),
        platformFieldsMissing: Bool = false, scanDue: Bool = false,
        timeoutHold: (String) -> Date? = { _ in nil }, lastRun: (String) -> Date?
    ) -> [PlannedKind] {
        let cadence = Cadence.seconds(CollectionTier.refresh.intervalSeconds)
        return schoolCommandMatrix(profile: profile).map { args, kind in
            let skip: CollectSkipReason?
            if collectSkip.contains(kind) {
                skip = .collectSkip
            } else if tiers.isDisjoint(with: [.refresh, .inventory]) {
                skip = scanDue && tiers.contains(.scan) && kind == SchoolFleetService.devicesKind
                    ? nil : .tierNotSelected(.inventory)
            } else if kind == schoolBlueprintsKind, platformFieldsMissing {
                skip = .schoolNoPlatform
            } else if !force, let until = timeoutHold(kind), now < until {
                skip = .repeatedTimeouts(retryAfter: until)
            } else if !force,
                      !(scanDue && tiers.contains(.scan) && kind == SchoolFleetService.devicesKind),
                      !CadenceResolver.isDue(lastRun: lastRun(kind), cadence: cadence, now: now) {
                skip = .notDue(lastRun: lastRun(kind), cadence: cadence)
            } else {
                skip = nil
            }
            return PlannedKind(args: args, kind: kind, skip: skip)
        }
    }

    /// The plan for a product collected after the MDM collect (Jamf Protect, Security Cloud).
    /// Unforced (`addOnCollectForced` false), a source waits out the refresh cadence and the
    /// timeout hold like a matrix source, so a run that came for one retried Jamf Pro source
    /// does not collect the whole product again.
    static func planAddOn(
        commands: [(args: [String], kind: String)], collectSkip: Set<String> = [],
        stateStore: StateFileStore?, now: Date = Date()
    ) -> [PlannedKind] {
        let cadence = Cadence.seconds(CollectionTier.refresh.intervalSeconds)
        return commands.map { args, kind in
            let skip: CollectSkipReason?
            let last = stateStore?.lastRun(report: kind)
            if collectSkip.contains(kind) {
                skip = .collectSkip
            } else if addOnCollectForced {
                skip = nil
            } else if let until = stateStore?.timeoutHoldUntil(report: kind, now: now),
                      now < until {
                skip = .repeatedTimeouts(retryAfter: until)
            } else if let last, Calendar.current.isDate(last, inSameDayAs: now),
                      !CadenceResolver.isDue(lastRun: last, cadence: cadence, now: now) {
                // Only within a local day: the daily summary takes these figures from the run
                // that landed them, so each day's first run must collect them.
                skip = .notDue(lastRun: last, cadence: cadence)
            } else {
                skip = nil
            }
            return PlannedKind(args: args, kind: kind, skip: skip)
        }
    }

    /// Logs a fixed plan and its `[skip]` lines; returns the commands that run.
    static func announcing(
        _ plan: [PlannedKind], profile: String, onLine: @Sendable (CLIBridge.LogLine) -> Void
    ) -> [(args: [String], kind: String)] {
        for line in collectPlanLines(profile: profile, fixedPlan: plan) {
            onLine(.init(timestamp: Date(), level: .info, text: line))
        }
        for item in plan {
            guard let detail = item.skip?.skipDetail else { continue }
            onLine(.init(timestamp: Date(), level: .info, text: "[skip] \(item.kind): \(detail)"))
        }
        return plan.filter { $0.skip == nil }.map { ($0.args, $0.kind) }
    }

    /// The `[plan]` lines for a fixed-list plan (Jamf School): what runs, then what is skipped
    /// under its reason. `afterMatrix` and `afterMatrixSkipped` are the sources fetched after
    /// the commands (`sofa`), listed like the Pro plan lists them.
    static func collectPlanLines(
        profile: String, fixedPlan plan: [PlannedKind], afterMatrix: [String] = [],
        afterMatrixSkipped: [String] = []
    ) -> [String] {
        var groups: [(label: String, kinds: [String])] = []
        for item in plan {
            guard let skip = item.skip else { continue }
            if let index = groups.firstIndex(where: { $0.label == skip.planLabel }) {
                groups[index].kinds.append(item.kind)
            } else {
                groups.append((skip.planLabel, [item.kind]))
            }
        }
        if !afterMatrixSkipped.isEmpty {
            groups.append((CollectSkipReason.collectSkip.planLabel, afterMatrixSkipped))
        }
        return collectPlanLines(
            profile: profile, running: plan.filter { $0.skip == nil }.map(\.kind) + afterMatrix,
            skipped: groups)
    }

    /// The `[plan]` lines for a collect with a fixed list (Jamf School, Protect): `running`
    /// kinds, and `skipped` kinds grouped under their reason.
    static func collectPlanLines(
        profile: String, running: [String], skipped: [(label: String, kinds: [String])] = []
    ) -> [String] {
        runProgress?.addPlanned(running)
        var lines = wrappedPlanLines(
            header: "[plan] profile \(profile) — collecting \(sourceCount(running.count))",
            items: running)
        for group in skipped {
            lines += wrappedPlanLines(
                header: "[plan] skipping \(sourceCount(group.kinds.count)) (\(group.label))",
                items: group.kinds)
        }
        return lines
    }

    private static func sourceCount(_ count: Int) -> String {
        count == 1 ? "1 source" : "\(count) sources"
    }

    /// `header: a, b, c`, wrapped before `planLineLimit` with `[plan]   ` continuation lines.
    private static func wrappedPlanLines(header: String, items: [String]) -> [String] {
        guard !items.isEmpty else { return [header] }
        var lines: [String] = []
        var current = header + ":"
        var itemsOnLine = 0
        for item in items {
            let candidate = current + (itemsOnLine == 0 ? " " : ", ") + item
            if itemsOnLine > 0, candidate.count > planLineLimit {
                lines.append(current + ",")
                current = "[plan]   " + item
                itemsOnLine = 1
            } else {
                current = candidate
                itemsOnLine += 1
            }
        }
        lines.append(current)
        return lines
    }
}

/// What the device scan phase does this run, decided with the matrix so the plan and the
/// phase read one answer.
enum DeviceScanPlan: Equatable, Sendable {
    /// The scan tier is not in this run's tier set.
    case tierNotSelected
    /// Settings: Skip expensive collections.
    case turnedOff
    /// `jamf_cli.collect_skip` turns off both scan kinds.
    case listedInCollectSkip
    /// The fleet has no computers (`FleetState`).
    case noComputers
    /// Every scan kind's cadence floor holds; `lastAttempt` is the newest attempt, if any.
    case notDue(lastAttempt: Date?)
    case due

    var planText: String {
        switch self {
        case .tierNotSelected:
            return "device scan: not selected (tier scan is not in this run)"
        case .turnedOff:
            return "device scan: turned off (Settings: Skip expensive collections)"
        case .listedInCollectSkip:
            return "device scan: turned off (jamf_cli.collect_skip)"
        case .noComputers:
            return "device scan: skipped (no computers in Jamf Pro)"
        case .notDue(let lastAttempt):
            return "device scan: not due (last attempt: \(collectLogDateLabel(lastAttempt)))"
        case .due:
            return "device scan: due"
        }
    }
}
