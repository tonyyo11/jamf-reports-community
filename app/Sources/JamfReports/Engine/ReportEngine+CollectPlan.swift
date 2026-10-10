import Foundation

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
        case collectSkip
        case dashboardUnsupported(installedVersion: String?)
        case tierNotSelected(CollectionTier)
        case notDue(lastRun: Date?, cadence: Cadence)

        /// What follows `[skip] <kind>: `; nil when one aggregate line already says it.
        var skipDetail: String? {
            switch self {
            case .settingsSkipExpensive:
                return nil
            case .platformOnly(let authMethod):
                return "requires a Platform API profile (auth-method is \(authMethod))"
            case .environmentLevel:
                return "needs a platform environment integration (this profile is tenant level)"
            case .collectSkip:
                return "listed in jamf_cli.collect_skip"
            case .dashboardUnsupported(let installed):
                return "needs jamf-cli \(JamfCLIInstaller.dashboardVersion) or later "
                    + "(installed: \(installed ?? "unknown"))"
            case .tierNotSelected(let tier):
                return "tier \(tier.rawValue) not selected"
            case .notDue(let lastRun, let cadence):
                return "not due (last: \(collectLogDateLabel(lastRun)), cadence: \(cadence.label))"
            }
        }

        /// The label the `[plan]` block groups kinds under.
        var planLabel: String {
            switch self {
            case .settingsSkipExpensive: return "Settings: Skip expensive collections"
            case .platformOnly(let authMethod):
                return "requires a Platform API profile, auth-method is \(authMethod)"
            case .environmentLevel: return "needs a platform environment integration"
            case .collectSkip: return "jamf_cli.collect_skip"
            case .dashboardUnsupported:
                return "needs jamf-cli \(JamfCLIInstaller.dashboardVersion) or later"
            case .tierNotSelected(let tier): return "tier \(tier.rawValue) not selected"
            case .notDue: return "not due"
            }
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
        let dashboardSupported: Bool
        let installedVersion: String?
        let now: Date
    }

    /// Decides every matrix command. The order is the loop's always was: Settings, then what
    /// this profile or jamf-cli cannot serve, then the tier set, then cadence, so a command
    /// is reported under the first reason that applies. `lastRun` answers a kind's last
    /// success (the state files), read once here.
    static func planCollect(
        commands: [(args: [String], kind: String)],
        inputs: CollectPlanInputs,
        lastRun: (String) -> Date?
    ) -> [PlannedKind] {
        commands.map { command in
            PlannedKind(
                args: command.args, kind: command.kind,
                skip: skipReason(for: command.kind, inputs: inputs, lastRun: lastRun))
        }
    }

    private static func skipReason(
        for kind: String, inputs: CollectPlanInputs, lastRun: (String) -> Date?
    ) -> CollectSkipReason? {
        if inputs.skipExpensive, expensivePerDeviceKinds.contains(kind) {
            return .settingsSkipExpensive
        }
        return profileSkip(for: kind, inputs: inputs)
            ?? scheduleSkip(for: kind, inputs: inputs, lastRun: lastRun)
    }

    /// Kinds this profile's API, its scope or its jamf-cli cannot serve, or the operator
    /// turned off. Recorded nowhere: none of these is a failure.
    private static func profileSkip(
        for kind: String, inputs: CollectPlanInputs
    ) -> CollectSkipReason? {
        if let auth = inputs.nonPlatformAuth, platformOnlyKinds.contains(kind) {
            return .platformOnly(authMethod: auth)
        }
        if inputs.tenantLevel, environmentLevelKinds.contains(kind) { return .environmentLevel }
        if inputs.collectSkip.contains(kind) { return .collectSkip }
        if kind == dashboardKind, !inputs.dashboardSupported {
            return .dashboardUnsupported(installedVersion: inputs.installedVersion)
        }
        return nil
    }

    /// The tier set, then cadence. An unmapped kind has no tier and is always allowed;
    /// `force` bypasses cadence so an ad-hoc refresh always refetches.
    private static func scheduleSkip(
        for kind: String, inputs: CollectPlanInputs, lastRun: (String) -> Date?
    ) -> CollectSkipReason? {
        if let tier = CollectionTier.tier(forReport: kind), !inputs.tiers.contains(tier) {
            return .tierNotSelected(tier)
        }
        guard !inputs.force else { return nil }
        let cadence = CadenceResolver.cadence(forReport: kind)
        let last = lastRun(kind)
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
        tiers: Set<CollectionTier>, collectSkip: Set<String>
    ) -> [String] {
        selectedAfterMatrix(tiers: tiers).filter { !collectSkip.contains($0) }
    }

    /// The after-matrix sources this run's tier set selects that `collect_skip` turns off.
    static func skippedAfterMatrix(
        tiers: Set<CollectionTier>, collectSkip: Set<String>
    ) -> [String] {
        selectedAfterMatrix(tiers: tiers).filter { collectSkip.contains($0) }
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
        afterMatrixSkipped: [String] = [], deviceScan: DeviceScanPlan,
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
            afterMatrixSkipped: afterMatrixSkipped, deviceScan: deviceScan)
        for line in lines {
            onLine(.init(timestamp: Date(), level: .info, text: line))
        }
        // A skipped matrix kind gets its `[skip]` line from the loop; these have no loop.
        for kind in afterMatrixSkipped {
            onLine(.init(
                timestamp: Date(), level: .info,
                text: "[skip] \(kind): \(CollectSkipReason.collectSkip.skipDetail ?? "")"))
        }
    }

    /// Longest `[plan]` line; a longer list wraps onto an indented continuation line.
    private static let planLineLimit = 180

    /// The `[plan]` lines for a Jamf Pro collect: the sources that run (the matrix's, then
    /// `afterMatrix`), the ones left alone grouped by reason (`afterMatrixSkipped` being
    /// the after-matrix sources `collect_skip` turned off), and the device scan.
    static func collectPlanLines(
        profile: String, plan: [PlannedKind], afterMatrix: [String] = [],
        afterMatrixSkipped: [String] = [], deviceScan: DeviceScanPlan
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
        return collectPlanLines(
            profile: profile, running: plan.filter { $0.skip == nil }.map(\.kind) + afterMatrix,
            skipped: groups
        ) + ["[plan] \(deviceScan.planText)"]
    }

    /// The `[plan]` lines for a collect with a fixed list (Jamf School, Protect): `running`
    /// kinds, and `skipped` kinds grouped under their reason.
    static func collectPlanLines(
        profile: String, running: [String], skipped: [(label: String, kinds: [String])] = []
    ) -> [String] {
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
    /// Every scan kind's cadence floor holds; `lastAttempt` is the newest attempt, if any.
    case notDue(lastAttempt: Date?)
    case due

    var planText: String {
        switch self {
        case .tierNotSelected:
            return "device scan: not selected (tier scan is not in this run)"
        case .turnedOff:
            return "device scan: turned off (Settings: Skip expensive collections)"
        case .notDue(let lastAttempt):
            return "device scan: not due (last attempt: \(collectLogDateLabel(lastAttempt)))"
        case .due:
            return "device scan: due"
        }
    }
}
