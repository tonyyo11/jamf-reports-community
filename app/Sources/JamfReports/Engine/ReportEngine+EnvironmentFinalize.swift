import Foundation
import Synchronization

/// The kinds each product landed in one routed run, filled by the collects and read by
/// `CollectRouter` for `finalizeEnvironmentSummary`.
final class LandedSources: Sendable {
    private let kinds = Mutex<[EnvironmentProducts.Product: Set<String>]>([:])

    func record(_ product: EnvironmentProducts.Product, _ landed: some Collection<String>) {
        guard !landed.isEmpty else { return }
        kinds.withLock { $0[product, default: []].formUnion(landed) }
    }

    var all: [EnvironmentProducts.Product: Set<String>] { kinds.withLock { $0 } }

    private let unwritten = Mutex(false)
    /// The MDM step logged `summaryNotWrittenMarker` this run.
    var mdmSummaryUnwritten: Bool {
        get { unwritten.withLock { $0 } }
        set { unwritten.withLock { $0 = newValue } }
    }
}

extension ReportEngine {
    /// Bound by `CollectRouter` around a run; nil for a collect started on its own.
    @TaskLocal static var landedSources: LandedSources?

    /// The Protect figures a daily summary records (P9-R2) from the newest snapshots, never from
    /// device names; nil when neither a readable `protect-computers` nor `protect-alerts`
    /// snapshot exists. The match goes through `ProtectProCorrelation.load`, the Protect screen's
    /// own calculator, against Jamf School devices only when `school` is set.
    static func protectSummaryFigures(
        dataDir: URL, workspace: WorkspaceID, school: Bool = false
    ) -> ProtectSummaryFigures? {
        func readable(_ kind: String) -> Bool {
            FileManager.newestJSONFile(in: dataDir.appendingPathComponent(kind)) != nil
        }
        let snapshot = ProtectDashboardService.load(dataDir: dataDir)
        let hasComputers = readable("protect-computers")
            && !snapshot.unreadableKinds.contains("protect-computers")
        let hasAlerts = readable("protect-alerts")
            && !snapshot.unreadableKinds.contains("protect-alerts")
        guard hasComputers || hasAlerts else { return nil }
        var figures = ProtectSummaryFigures()
        if hasComputers {
            figures.computerCount = snapshot.computers.count
            figures.matchedPct = matchedPct(
                snapshot.computers, workspace: workspace, school: school)
        }
        if hasAlerts {
            // A missing status counts as open: only Resolved and AutoResolved are closed.
            let open = snapshot.alerts.filter {
                !["resolved", "autoresolved"].contains(($0.status ?? "").lowercased())
            }
            figures.openAlerts = open.count
            let bySeverity = Dictionary(
                grouping: open.compactMap { $0.severity?.lowercased() }, by: { $0 }
            ).mapValues(\.count)
            figures.alertCounts = bySeverity.isEmpty ? nil : bySeverity
        }
        return figures
    }

    private static func matchedPct(
        _ computers: [ProtectComputerRow], workspace: WorkspaceID, school: Bool
    ) -> Double? {
        guard let correlation = ProtectProCorrelation.load(
            protect: computers, profile: workspace.name, demoMode: false, school: school),
              correlation.inventorySize > 0 else { return nil }
        let denominator = correlation.protectCount - correlation.noIdentifier
        guard denominator > 0 else { return nil }
        return (Double(correlation.matched) / Double(denominator) * 1000).rounded() / 10
    }

    /// Adds `products` and the Protect figures to today's summary (P9-R1, R2, R4). Creates a
    /// summary only for a Protect-only environment; an MDM environment whose MDM wrote none
    /// gets nothing, so a failed MDM collect never reads as a Trends day.
    @discardableResult
    static func finalizeEnvironmentSummary(
        summariesDir: URL, dataDir: URL, environment: EnvironmentProfiles,
        workspace: WorkspaceID, landed: [EnvironmentProducts.Product: Set<String>],
        day: Date = Date(), announcesWrite: Bool = true,
        onLine: @Sendable @escaping (CLIBridge.LogLine) -> Void
    ) -> SummaryEmitOutcome {
        let date = SummaryJSONParser.dateFormatter.string(from: day)
        let file = summariesDir.appendingPathComponent("summary_\(date).json")
        let protectKinds = landed[.protect] ?? []
        var summary: DailySummary
        if let data = try? BoundedFile.read(
            file, limit: SummaryJSONParser.maxSummaryFileBytes, followSymlinks: false),
           let existing = try? SummaryJSONParser.decode(data) {
            summary = existing
        } else if environment.isProtectOnly, !protectKinds.isEmpty {
            do {
                try FileManager.default.createDirectory(
                    at: summariesDir, withIntermediateDirectories: true)
            } catch {
                let msg = "\(summaryNotWrittenMarker) the summaries directory could not be created"
                AppLogger.collect.warning("\(msg, privacy: .private)")
                onLine(.init(timestamp: Date(), level: .warn, text: msg))
                return .directoryUnavailable
            }
            summary = protectOnlySummary(
                date: date, collectionSources: [:],
                collectedByHost: collectingHostLabel(dataDir: dataDir))
        } else {
            return .nothingToSummarize
        }
        if environment.isProtectOnly, !protectKinds.isEmpty {
            summary.collectionSources = mergedSources(
                existing: summary.collectionSources,
                fresh: Dictionary(uniqueKeysWithValues: protectKinds.map { ($0, "live") }))
        }
        let slots = landed.filter { !$0.value.isEmpty }.map(\.key.slotName)
        let figures = protectKinds.isEmpty
            ? nil : protectSummaryFigures(
                dataDir: dataDir, workspace: workspace, school: environment.isSchool)
        guard !slots.isEmpty || figures != nil else { return .keptExisting }
        summary = summary.withEnvironment(products: slots.isEmpty ? nil : slots, protect: figures)
        // After a run whose MDM summary was not written, `writeSummaryFile`'s "will reflect this
        // run" line would contradict the [partial] line already logged: drop its [ok] line.
        let write: @Sendable (CLIBridge.LogLine) -> Void = {
            if announcesWrite || $0.level != .ok { onLine($0) }
        }
        guard writeSummaryFile(summary, to: file, onLine: write) else { return .writeFailed }
        onLine(.init(timestamp: Date(), level: .info, text:
            "[info] \(file.lastPathComponent) added environment fields: products "
                + (summary.products ?? []).joined(separator: ", ")))
        return .wrote
    }
}
