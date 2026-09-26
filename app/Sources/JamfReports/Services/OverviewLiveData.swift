import Foundation

/// One row of the Overview's Recent Activity table. Optional fields render as
/// "—": a jamf-cli inventory carries no failed-rule count and often no
/// department, and a PASS pill or a check mark for them would misstate the Mac.
struct RecentDeviceRow: Identifiable, Sendable, Hashable {
    let id: String
    let name: String
    let serial: String
    var jamfID: String? = nil
    let os: String
    let user: String
    var department: String? = nil
    var fileVault: Bool? = nil
    var failedRules: Int? = nil
    let lastSeen: String
    var isStale: Bool = false

    var numericJamfID: String? {
        guard let trimmed = jamfID?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty,
              trimmed.allSatisfy({ $0 >= "0" && $0 <= "9" }) else {
            return nil
        }
        return trimmed
    }
}

extension RecentDeviceRow {
    init(demo row: DeviceRow) {
        self.init(
            id: row.serial, name: row.name, serial: row.serial, jamfID: row.jamfID,
            os: row.os, user: row.user, department: row.dept, fileVault: row.fileVault,
            failedRules: row.fails, lastSeen: row.lastSeen,
            isStale: row.lastSeen.contains("day")
        )
    }

    init(record: DeviceInventoryRecord, failedRules: Int?) {
        self.init(
            id: record.id, name: record.displayName, serial: record.serial,
            jamfID: record.jamfID, os: record.osVersion,
            user: record.email.isEmpty ? record.user : record.email,
            department: record.department.isEmpty ? nil : record.department,
            fileVault: record.fileVaultEnabled,
            failedRules: failedRules,
            lastSeen: Self.lastSeenLabel(record),
            isStale: record.stale
        )
    }

    /// The Devices screen's wording: "Today", "1 day", "12 days".
    static func lastSeenLabel(_ record: DeviceInventoryRecord) -> String {
        if let days = record.daysSinceContact {
            if days <= 0 { return "Today" }
            return days == 1 ? "1 day" : "\(days) days"
        }
        return record.lastContact.isEmpty ? "Unknown" : record.lastContact
    }
}

/// What the Overview's data-driven sections show on a live profile, read off
/// the main actor in one pass. A section with nothing to show carries the
/// reason in `unavailable` instead of rendering an empty or invented card.
struct OverviewLiveData: Sendable {
    var osDistribution: [OSDistribution] = []
    /// Share of Macs on the newest release of their own major version; nil
    /// when no SOFA feed is cached, so "current" cannot be judged.
    var osCurrentShare: Double?
    var osDeviceCount = 0
    var osVersionCount = 0

    var failingRules: [FailingRule] = []
    /// Distinct rules failing on at least one Mac.
    var failingRuleCount = 0
    /// The benchmark or baseline the rules belong to.
    var failingRulesLabel = ""

    var agents: [SecurityAgent] = []
    /// Configured agents no Mac reports a value for — usually a column name
    /// that does not match the extension attribute.
    var agentsWithoutValues: [String] = []

    var recentDevices: [RecentDeviceRow] = []

    var unavailable: [OverviewSection: OverviewUnavailable] = [:]

    static let empty = OverviewLiveData()

    /// Sections whose content this type carries.
    static let sections: Set<OverviewSection> = [
        .osDistribution, .topFailingRules, .securityAgents, .recentActivity,
    ]
}

/// Reads what `OverviewLiveData` holds from the workspace. Disk IO throughout:
/// call it from a detached task.
enum OverviewLiveDataLoader {
    static let recentLimit = 8
    static let osRowLimit = 6
    /// Rules kept for the drill-down; the card shows the first six.
    static let rulesKept = 50

    /// Only `sections` are read, so a hidden Recent Activity never pays for
    /// the device inventory. `fleetCount` is the latest summary's device
    /// count — the denominator agent cards print — or 0 when unknown.
    static func load(profile: String, sections: Set<OverviewSection>,
                     fleetCount: Int) -> OverviewLiveData {
        var data = OverviewLiveData()
        let wanted = sections.intersection(OverviewLiveData.sections)
        guard !wanted.isEmpty else { return data }
        guard let dataDir = try? WorkspacePaths.dataDir(for: profile) else {
            let why = OverviewUnavailable(reason: "This profile's workspace isn't set up yet.")
            for section in wanted { data.unavailable[section] = why }
            return data
        }
        let config = loadConfig(profile: profile)
        if wanted.contains(.osDistribution) {
            loadOSDistribution(into: &data, dataDir: dataDir)
        }
        let benchmarks = wanted.contains(.topFailingRules)
            ? ComplianceBenchmarksService.load(profile: profile)
            : ComplianceBenchmarksService.Snapshot.empty
        let baseline = config?.compliance?.resolvedBaselines.first
        let agents = (config?.securityAgents ?? []).filter {
            !$0.column.trimmingCharacters(in: .whitespaces).isEmpty
        }
        let needsEA = (wanted.contains(.topFailingRules) && benchmarks.rules.isEmpty
                       && baseline?.failuresListColumn != nil)
            || (wanted.contains(.securityAgents) && !agents.isEmpty)
            || (wanted.contains(.recentActivity) && baseline != nil)
        let eaRows = needsEA ? loadEARows(dataDir: dataDir) : nil
        if wanted.contains(.topFailingRules) {
            loadFailingRules(into: &data, benchmarks: benchmarks, baseline: baseline,
                             eaRows: eaRows)
        }
        if wanted.contains(.securityAgents) {
            loadAgents(into: &data, agents: agents, eaRows: eaRows, fleetCount: fleetCount)
        }
        if wanted.contains(.recentActivity) {
            loadRecentActivity(into: &data, profile: profile, baseline: baseline,
                               eaRows: eaRows)
        }
        return data
    }

    // MARK: Sections

    private static func loadOSDistribution(into data: inout OverviewLiveData, dataDir: URL) {
        guard let raw = try? ReportEngine.loadLatestSnapshotData(
                  kind: "inventory-summary", dataDir: dataDir),
              let rows = try? JSONDecoder().decode([InventorySummaryRow].self, from: raw),
              !rows.isEmpty else {
            data.unavailable[.osDistribution] = OverviewUnavailable(
                reason: "No inventory summary yet. Every collect writes one.",
                remedy: .sources)
            return
        }
        let counts = Dictionary(rows.map { ($0.osVersion, $0.count) }, uniquingKeysWith: +)
        let sofa = SOFAFeedService.load(dataDir: dataDir).rows.filter { $0.platform == "macOS" }
        let built = osDistribution(counts: counts,
                                   latestByMajor: SOFAFeedService.latestByMajor(sofa),
                                   limit: osRowLimit)
        data.osDistribution = built.rows
        data.osCurrentShare = built.currentShare
        data.osDeviceCount = built.total
        data.osVersionCount = built.versions
    }

    private static func loadFailingRules(
        into data: inout OverviewLiveData,
        benchmarks: ComplianceBenchmarksService.Snapshot,
        baseline: ComplianceBaselineConfig?,
        eaRows: [EAResultRow]?
    ) {
        if !benchmarks.rules.isEmpty {
            let built = failingRules(benchmarks: benchmarks)
            data.failingRules = Array(built.rules.prefix(rulesKept))
            data.failingRuleCount = built.rules.count
            data.failingRulesLabel = built.label
            return
        }
        guard let baseline, let listColumn = baseline.failuresListColumn else {
            data.unavailable[.topFailingRules] = OverviewUnavailable(
                reason: "Map your compliance failures-list extension attribute "
                    + "(compliance.failures_list_column) in Config, or collect Compliance "
                    + "Benchmarks with a Jamf Platform API profile.",
                remedy: .config)
            return
        }
        guard let eaRows else {
            data.unavailable[.topFailingRules] = OverviewUnavailable(
                reason: "No extension-attribute results yet. They are collected with the "
                    + "inventory.",
                remedy: .sources)
            return
        }
        let built = failingRules(rows: eaRows, listColumn: listColumn, baseline: baseline.name)
        guard built.reportingMacs > 0 else {
            data.unavailable[.topFailingRules] = OverviewUnavailable(
                reason: "No Mac reports \"\(listColumn)\" in the collected extension "
                    + "attributes. Check the column name in Config.",
                remedy: .config)
            return
        }
        data.failingRules = Array(built.rules.prefix(rulesKept))
        data.failingRuleCount = built.rules.count
        data.failingRulesLabel = baseline.name
    }

    private static func loadAgents(
        into data: inout OverviewLiveData,
        agents: [SecurityAgentConfig],
        eaRows: [EAResultRow]?,
        fleetCount: Int
    ) {
        guard !agents.isEmpty else {
            data.unavailable[.securityAgents] = OverviewUnavailable(
                reason: "List your security agents under Security Agents in Config.",
                remedy: .config)
            return
        }
        guard let eaRows else {
            data.unavailable[.securityAgents] = OverviewUnavailable(
                reason: "No extension-attribute results yet. They are collected with the "
                    + "inventory.",
                remedy: .sources)
            return
        }
        let coverage = SecurityAgentCoverage.compute(rows: eaRows, agents: agents)
        let reported = coverage.filter { $0.reporting > 0 }
        guard !reported.isEmpty else {
            data.unavailable[.securityAgents] = OverviewUnavailable(
                reason: "No Mac reports a value for any configured agent's column. Check "
                    + "each column matches its extension attribute's name in Config.",
                remedy: .config)
            return
        }
        // The card prints "installed / fleet", so the percentage uses the same
        // denominator; without a summary, the Macs ea-results knows about.
        let fleet = fleetCount > 0
            ? fleetCount : MSCPComplianceService.allDistinctDeviceIds(in: eaRows).count
        data.agents = reported.map {
            SecurityAgent(
                name: $0.name, installed: $0.installed,
                pct: SecurityAgentCoverage.percent(installed: $0.installed, fleet: fleet) ?? 0,
                column: $0.column, trend: .flat)
        }
        data.agentsWithoutValues = coverage.filter { $0.reporting == 0 }.map(\.name)
    }

    private static func loadRecentActivity(
        into data: inout OverviewLiveData,
        profile: String,
        baseline: ComplianceBaselineConfig?,
        eaRows: [EAResultRow]?
    ) {
        let inventory = DeviceInventoryService.load(profile: profile, demoMode: false)
        guard !inventory.devices.isEmpty else {
            data.unavailable[.recentActivity] = OverviewUnavailable(
                reason: "No computer inventory yet. A collect writes it.",
                remedy: .sources)
            return
        }
        let counts = baseline.flatMap { base in
            eaRows.map { failureCounts(rows: $0, countColumn: base.failuresCountColumn) }
        } ?? [:]
        data.recentDevices = recentDevices(inventory.devices, limit: recentLimit).map { record in
            RecentDeviceRow(record: record, failedRules: failedRules(
                for: record, eaCounts: counts, baselineConfigured: baseline != nil))
        }
    }

    // MARK: Pure builders (tested)

    /// Versions by device count, the rest rolled into "Other" past `limit`.
    /// `currentShare` is nil without a SOFA feed.
    static func osDistribution(
        counts: [String: Int], latestByMajor: [Int: String], limit: Int
    ) -> (rows: [OSDistribution], currentShare: Double?, total: Int, versions: Int) {
        let valid = counts.filter { $0.value > 0 && !$0.key.isEmpty }
        let total = valid.values.reduce(0, +)
        guard total > 0 else { return ([], nil, 0, 0) }
        let ranked = valid.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key > $1.key }
        let shown = ranked.count > limit ? Array(ranked.prefix(max(limit - 1, 1))) : ranked
        // Gold for versions on their major's latest release, greys for the rest —
        // the demo donut's scheme.
        var currentPalette: [UInt32] = [0xC9970A, 0xA87E08, 0x8A6906]
        var behindPalette: [UInt32] = [0x7D8794, 0x5A6068, 0x4A4F55, 0x3F4449]
        func pct(_ count: Int) -> Double { (Double(count) / Double(total) * 1000).rounded() / 10 }
        var rows: [OSDistribution] = shown.map { entry -> OSDistribution in
            let current = SOFAFeedService.isCurrent(entry.key, latestByMajor: latestByMajor) == true
            let color = current
                ? currentPalette.removeFirstOrLast() : behindPalette.removeFirstOrLast()
            return OSDistribution(version: "macOS \(entry.key)", count: entry.value,
                                  pct: pct(entry.value), colorHex: color, current: current)
        }
        let otherCount = total - shown.reduce(0) { $0 + $1.value }
        if otherCount > 0 {
            rows.append(OSDistribution(
                version: "Other (\(ranked.count - shown.count) versions)", count: otherCount,
                pct: pct(otherCount), colorHex: 0x33373B, current: false))
        }
        var share: Double?
        if !latestByMajor.isEmpty {
            let current = valid.filter {
                SOFAFeedService.isCurrent($0.key, latestByMajor: latestByMajor) == true
            }.values.reduce(0, +)
            share = pct(current)
        }
        return (rows, share, total, valid.count)
    }

    /// Failing rules from a Compliance Benchmarks snapshot. Aggregating across
    /// benchmarks would double-count Macs, so with several the first is used —
    /// the one the Compliance Benchmarks screen opens on.
    static func failingRules(
        benchmarks snapshot: ComplianceBenchmarksService.Snapshot
    ) -> (rules: [FailingRule], label: String) {
        let names = snapshot.benchmarks
        let scoped = names.count > 1 ? snapshot.filtered(to: names[0]) : snapshot
        let label = names.first ?? "Compliance Benchmark"
        let rules = scoped.rules.compactMap { rule -> FailingRule? in
            guard let failed = rule.failed, failed > 0 else { return nil }
            return FailingRule(ruleID: rule.rule, fails: failed, baseline: label)
        }
        return (ranked(rules), label)
    }

    /// Failing rules from the failures-list extension attribute: a pipe-separated
    /// list of rule IDs per Mac, each rule counted once per Mac.
    /// `reportingMacs` is how many Macs have a row for the column at all.
    static func failingRules(
        rows: [EAResultRow], listColumn: String, baseline: String
    ) -> (rules: [FailingRule], reportingMacs: Int) {
        var macsPerRule: [String: Set<String>] = [:]
        var reporting: Set<String> = []
        for row in rows {
            guard let eaName = row.eaName,
                  eaName.caseInsensitiveCompare(listColumn) == .orderedSame,
                  let id = MSCPComplianceService.primaryIdentifier(for: row)?.lowercased()
            else { continue }
            reporting.insert(id)
            for part in (row.value?.stringValue ?? "").split(separator: "|") {
                let rule = part.trimmingCharacters(in: .whitespacesAndNewlines)
                if !rule.isEmpty { macsPerRule[rule, default: []].insert(id) }
            }
        }
        let rules = macsPerRule.map {
            FailingRule(ruleID: $0.key, fails: $0.value.count, baseline: baseline)
        }
        return (ranked(rules), reporting.count)
    }

    private static func ranked(_ rules: [FailingRule]) -> [FailingRule] {
        rules.sorted { $0.fails != $1.fails ? $0.fails > $1.fails : $0.ruleID < $1.ruleID }
    }

    /// Per-Mac failure counts from the failures-count extension attribute,
    /// keyed by every identifier a row carries, lowercased.
    static func failureCounts(rows: [EAResultRow], countColumn: String) -> [String: Int] {
        var counts: [String: Int] = [:]
        for row in rows {
            guard let eaName = row.eaName,
                  eaName.caseInsensitiveCompare(countColumn) == .orderedSame,
                  let count = row.value?.intValue, count >= 0 else { continue }
            for key in [row.computerId, row.serial, row.device, row.computerName] {
                if let key, !key.isEmpty { counts[key.lowercased()] = count }
            }
        }
        return counts
    }

    /// The extension attribute is the jamf-cli source; a CSV's count is used
    /// only when compliance is configured, since without that column every
    /// CSV row reads 0 and would print as a pass.
    static func failedRules(
        for record: DeviceInventoryRecord, eaCounts: [String: Int], baselineConfigured: Bool
    ) -> Int? {
        let keys = [record.serial, record.jamfID ?? "", record.name]
            .map { $0.lowercased() }
            .filter { !$0.isEmpty }
        if let count = keys.lazy.compactMap({ eaCounts[$0] }).first { return count }
        let fromCSV = record.source.lowercased().contains(".csv")
        return baselineConfigured && fromCSV ? record.failedRules : nil
    }

    /// Most recent check-in first: fewest days since contact, then the newest
    /// timestamp within a day, then name.
    static func recentDevices(
        _ records: [DeviceInventoryRecord], limit: Int
    ) -> [DeviceInventoryRecord] {
        let iso = ISO8601DateFormatter()
        let isoFractional = ISO8601DateFormatter()
        isoFractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let dated: [(record: DeviceInventoryRecord, date: Date?)] = records.map {
            ($0, iso.date(from: $0.lastContact) ?? isoFractional.date(from: $0.lastContact))
        }
        let sorted = dated.sorted { a, b in
            switch (a.record.daysSinceContact, b.record.daysSinceContact) {
            case let (x?, y?) where x != y: return x < y
            case (.some, .none): return true
            case (.none, .some): return false
            default: break
            }
            switch (a.date, b.date) {
            case let (x?, y?) where x != y: return x > y
            case (.some, .none): return true
            case (.none, .some): return false
            default:
                return a.record.displayName.localizedStandardCompare(b.record.displayName)
                    == .orderedAscending
            }
        }
        return sorted.prefix(limit).map { $0.record }
    }

    // MARK: IO helpers

    private static func loadConfig(profile: String) -> ReportConfig? {
        guard let workspace = ProfileService.workspaceURL(for: profile) else { return nil }
        return try? ConfigLoader.load(from: workspace.appendingPathComponent("config.yaml"))
    }

    private static func loadEARows(dataDir: URL) -> [EAResultRow]? {
        guard let raw = try? ReportEngine.loadLatestSnapshotData(
            kind: "ea-results", dataDir: dataDir) else { return nil }
        return EAResultRow.decodeSnapshot(raw).rows
    }
}

private extension Array where Element == UInt32 {
    /// Next colour in the palette; the last one repeats once the rest are used.
    mutating func removeFirstOrLast() -> UInt32 {
        count > 1 ? removeFirst() : (first ?? 0x4A4F55)
    }
}
