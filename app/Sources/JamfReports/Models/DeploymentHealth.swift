import Foundation

/// The one judge of App Installers deployments and patch policies (wave C): every surface (the
/// Health Audit card, the workbook tab, the HTML report, the daily summary) reads it.
enum DeploymentHealth {

    enum Source: String, CaseIterable, Sendable {
        case appInstallers = "app-installers-deployments"
        case patchPolicy = "patch-policies"

        var kind: String { rawValue }

        /// The section name on every surface.
        var displayName: String {
            switch self {
            case .appInstallers: L("App Installers deployments")
            case .patchPolicy: L("Patch policies")
            }
        }
    }

    /// The organization's two levels, whole percentages (`thresholds.deployment_failure_*`).
    struct Levels: Equatable, Sendable {
        var warning: Int
        var critical: Int
        static let defaults = Levels(warning: 10, critical: 25)
    }

    /// A row needs this many Macs in scope to be judged, so 1 failed of 2 never reads critical.
    static let minimumInScope = 10

    struct Row: Equatable, Sendable {
        let source: Source
        let id: String
        let name: String?
        let enabled: Bool?
        let failed: Int?
        /// Macs the row itself serves; nil when a count it is built from is missing.
        let inScope: Int?
        // App Installers
        let assignedElsewhere: Int?
        let deployedVersion: String?
        let latestVersion: String?
        let updateBehavior: String?
        // Patch policies
        let completed: Int?
        let deferred: Int?
        let pending: Int?
        let targetVersion: String?
        let softwareTitle: String?

        /// "(no name)" for a row with none, through `ConfigSchema.displayText` (peer data).
        var displayName: String {
            name.map(ConfigSchema.displayText).flatMap { $0.isEmpty ? nil : $0 }
                ?? L("(no name)")
        }
    }

    enum Judgement: Equatable, Sendable {
        case notJudged, unmeasured, nothingInScope, belowMinimumScope
        case belowLevels, warning, critical

        var isAtLevel: Bool { self == .warning || self == .critical }
    }

    enum VersionState: Equatable, Sendable { case same, pinned, lagging, unknown }

    enum SourceState: Equatable, Sendable {
        case notCollected
        /// Exit 4 recorded and the kind never landed: not on this server.
        case notSetUp
        case unreadable
        /// `asOf` is set only when the snapshot is no longer current (failed since, or older
        /// than `max_cache_age_hours`). `leftOut` counts rows with no id.
        case rows([Row], asOf: Date?, leftOut: Int)

        var rows: [Row] {
            if case .rows(let rows, _, _) = self { return rows }
            return []
        }
    }

    struct Figures: Equatable, Sendable {
        var judged = 0
        var atWarning = 0
        var atCritical = 0
    }

    // MARK: - Judging

    /// The ordered rules: the first that applies decides; shares compare in integers, so exactly
    /// a level is at that level.
    static func judge(_ row: Row, levels: Levels) -> Judgement {
        guard row.enabled == true else { return .notJudged }
        guard let failed = row.failed, let inScope = row.inScope else { return .unmeasured }
        if inScope == 0 { return .nothingInScope }
        if inScope < minimumInScope { return .belowMinimumScope }
        if failed * 100 >= levels.critical * inScope { return .critical }
        if failed * 100 >= levels.warning * inScope { return .warning }
        return .belowLevels
    }

    /// The failed share as a fraction, for display only; nil with nothing in scope.
    static func share(_ row: Row) -> Double? {
        guard let failed = row.failed, let inScope = row.inScope, inScope > 0 else { return nil }
        return Double(failed) / Double(inScope)
    }

    /// The share as printed beside the level it is judged against, so rounding never puts it
    /// on the other side of that level ("24.6%", not "25%", at warning with critical 25).
    static func shareText(_ row: Row, levels: Levels, format: PercentFormat) -> String {
        guard let share = share(row) else { return "" }
        // A row at a level can only round up onto the next one (warning onto critical); a row
        // below the levels can only round up onto warning.
        let level = judge(row, levels: levels).isAtLevel ? levels.critical : levels.warning
        return format.text(share * 100, beside: Double(level))
    }

    /// The rows at a level, critical first, then by share descending (integer cross-multiplied),
    /// then name, then id: the one order every surface shows.
    static func atLevel(_ rows: [Row], levels: Levels) -> [(row: Row, judgement: Judgement)] {
        rows.map { ($0, judge($0, levels: levels)) }
            .filter { $0.1.isAtLevel }
            .sorted { lhs, rhs in
                if lhs.1 != rhs.1 { return lhs.1 == .critical }
                return ordered(lhs.0, rhs.0)
            }
    }

    /// Every row in the tab's order: enabled rows by level then share, disabled ones last.
    static func tabOrder(_ rows: [Row], levels: Levels) -> [Row] {
        func rank(_ judgement: Judgement) -> Int {
            switch judgement {
            case .critical: 0
            case .warning: 1
            case .belowLevels: 2
            case .belowMinimumScope: 3
            case .nothingInScope: 4
            case .unmeasured: 5
            case .notJudged: 6
            }
        }
        return rows.sorted { lhs, rhs in
            let (l, r) = (rank(judge(lhs, levels: levels)), rank(judge(rhs, levels: levels)))
            return l != r ? l < r : ordered(lhs, rhs)
        }
    }

    /// Rows with a share first, by share descending (failed × other scope, no division), then
    /// rows without one; then name, then id. A strict weak order, so the sort is stable.
    private static func ordered(_ lhs: Row, _ rhs: Row) -> Bool {
        let (lShare, rShare) = (share(lhs) != nil, share(rhs) != nil)
        if lShare != rShare { return lShare }
        if lShare {
            let left = (lhs.failed ?? 0) * (rhs.inScope ?? 0)
            let right = (rhs.failed ?? 0) * (lhs.inScope ?? 0)
            if left != right { return left > right }
        }
        let (ln, rn) = (lhs.displayName, rhs.displayName)
        return ln != rn ? ln.localizedStandardCompare(rn) == .orderedAscending : lhs.id < rhs.id
    }

    static func figures(_ rows: [Row], levels: Levels) -> Figures {
        rows.reduce(into: Figures()) { figures, row in
            switch judge(row, levels: levels) {
            case .critical: figures.judged += 1; figures.atCritical += 1
            case .warning: figures.judged += 1; figures.atWarning += 1
            case .belowLevels: figures.judged += 1
            default: break
            }
        }
    }

    /// Counts of the rows not judged, by reason, for the card's "not judged" line.
    static func notJudgedCounts(_ rows: [Row], levels: Levels) -> [Judgement: Int] {
        rows.reduce(into: [:]) { counts, row in
            let judgement = judge(row, levels: levels)
            switch judgement {
            case .notJudged, .unmeasured, .nothingInScope, .belowMinimumScope:
                counts[judgement, default: 0] += 1
            default: break
            }
        }
    }

    /// App Installers only: pinned when the admin chose the version (`MANUAL`), else lagging.
    static func versionState(_ row: Row) -> VersionState {
        let deployed = row.deployedVersion?.trimmingCharacters(in: .whitespaces) ?? ""
        let latest = row.latestVersion?.trimmingCharacters(in: .whitespaces) ?? ""
        guard !deployed.isEmpty, !latest.isEmpty else { return .unknown }
        if deployed == latest { return .same }
        return row.updateBehavior == "MANUAL" ? .pinned : .lagging
    }
}

extension DeploymentHealth.Judgement: Hashable {}

// MARK: - Loading

extension DeploymentHealth {

    /// Each source's state from its newest snapshot and its state files, read as wave A's
    /// `ServerHealth` reads its kinds: "not set up" wins over an older snapshot.
    static func load(
        dataDir: URL, now: Date = Date(), maxAgeHours: Int? = nil
    ) -> [Source: SourceState] {
        let store = StateFileStore(directory: dataDir.appendingPathComponent("state"))
        return Dictionary(uniqueKeysWithValues: Source.allCases.map { source in
            (source, state(of: source, dataDir: dataDir, store: store, now: now,
                           maxAgeHours: maxAgeHours))
        })
    }

    private static func state(
        of source: Source, dataDir: URL, store: StateFileStore, now: Date, maxAgeHours: Int?
    ) -> SourceState {
        let failed = store.failures(report: source.kind) != nil
        if failed, store.cause(for: source.kind)?.kind == .notConfiguredOnServer,
           store.isAdvisory(kind: source.kind) {
            return .notSetUp
        }
        let kindDir = dataDir.appendingPathComponent(source.kind, isDirectory: true)
        if FileManager.plantedNewestSnapshot(in: kindDir, fileExtension: "json") != nil {
            return .unreadable
        }
        guard let url = FileManager.newestJSONFile(in: kindDir) else { return .notCollected }
        guard let data = BoundedFile.readSnapshotLogged(url),
              let object = try? JSONSerialization.jsonObject(with: data),
              let list = object as? [Any] else { return .unreadable }
        var rows: [Row] = []
        var leftOut = 0
        for item in list {
            guard let dict = item as? [String: Any] else { return .unreadable }
            if let row = row(source, dict) { rows.append(row) } else { leftOut += 1 }
        }
        let stamp = CloudStorage.snapshotTimestamp(of: url)
        return .rows(rows, asOf: staleDate(failed: failed, stamp: stamp, now: now,
                                           maxAgeHours: maxAgeHours),
                     leftOut: leftOut)
    }

    /// The snapshot's date when it is no longer current: the kind failed since, or it is older
    /// than `max_cache_age_hours` (`ServerHealth.staleDate`'s rule).
    private static func staleDate(failed: Bool, stamp: Date?, now: Date, maxAgeHours: Int?)
        -> Date? {
        guard let stamp else { return nil }
        if failed { return stamp }
        guard let hours = maxAgeHours else { return nil }
        return now.timeIntervalSince(stamp) > Double(hours) * 3_600 ? stamp : nil
    }

    /// A reduced row, each field read on its own; nil for a row with no id.
    static func row(_ source: Source, _ dict: [String: Any]) -> Row? {
        func text(_ value: Any?) -> String? { value as? String }
        func count(_ value: Any?) -> Int? {
            // 0...`maxSummaryNumber`, the snapshot-count seam: in scope then stays under 4e9,
            // so `failed * 100` and the sort's cross-multiplication cannot overflow.
            let double = (value as? NSNumber).flatMap {
                CFGetTypeID($0) == CFBooleanGetTypeID() ? nil : $0.doubleValue
            }
            guard let double, double.isFinite, double == double.rounded(), double >= 0,
                  double <= Double(SummaryJSONParser.maxSummaryNumber) else { return nil }
            return Int(double)
        }
        func flag(_ value: Any?) -> Bool? {
            guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID()
            else { return nil }
            return number.boolValue
        }
        guard let id = text(dict["id"]), !id.isEmpty else { return nil }
        switch source {
        case .appInstallers:
            let statuses = dict["computerStatuses"] as? [String: Any] ?? [:]
            let app = dict["app"] as? [String: Any] ?? [:]
            let parts = ["installed", "available", "inProgress", "failed"].map {
                count(statuses[$0])
            }
            let inScope = parts.contains(where: { $0 == nil }) ? nil : parts.compactMap { $0 }
                .reduce(0, +)
            return Row(
                source: source, id: id, name: text(dict["name"]), enabled: flag(dict["enabled"]),
                failed: count(statuses["failed"]), inScope: inScope,
                assignedElsewhere: count(statuses["unqualified"]),
                deployedVersion: text(app["deployedVersion"]),
                latestVersion: text(app["latestVersion"]),
                updateBehavior: text(dict["updateBehavior"]),
                completed: nil, deferred: nil, pending: nil, targetVersion: nil,
                softwareTitle: nil)
        case .patchPolicy:
            let parts = ["completed", "deferred", "failed", "pending"].map { count(dict[$0]) }
            let inScope = parts.contains(where: { $0 == nil }) ? nil : parts.compactMap { $0 }
                .reduce(0, +)
            return Row(
                source: source, id: id, name: text(dict["policyName"]),
                enabled: flag(dict["policyEnabled"]), failed: count(dict["failed"]),
                inScope: inScope, assignedElsewhere: nil, deployedVersion: nil,
                latestVersion: nil, updateBehavior: nil,
                completed: count(dict["completed"]), deferred: count(dict["deferred"]),
                pending: count(dict["pending"]), targetVersion: text(dict["policyTargetVersion"]),
                softwareTitle: text(dict["softwareTitle"]))
        }
    }
}

// MARK: - Words shared by the card, the tab and the HTML report

extension DeploymentHealth {

    /// The line for a source with no rows to list; nil for `rows`.
    static func stateText(_ state: SourceState) -> String? {
        switch state {
        case .notCollected: L("Not collected yet")
        case .notSetUp: L("Not set up on this Jamf Pro server")
        case .unreadable: L("Could not be read")
        case .rows(let rows, _, _): rows.isEmpty ? L("None on this server") : nil
        }
    }

    static func judgementText(_ judgement: Judgement) -> String {
        switch judgement {
        case .critical: L("At critical")
        case .warning: L("At warning")
        case .belowLevels: L("Below the levels")
        case .belowMinimumScope: L("Under \(minimumInScope) Macs")
        case .nothingInScope: L("Nothing in scope")
        case .unmeasured: L("Unmeasured")
        case .notJudged: L("Not enabled")
        }
    }

    static func versionText(_ state: VersionState) -> String {
        switch state {
        case .same: L("Latest")
        case .pinned: L("Pinned")
        case .lagging: L("Lagging")
        case .unknown: ""
        }
    }
}
