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
    /// device names. Each group is read only when `landed` says this run landed its kind, so an
    /// older snapshot never stands in for a failed fetch; nil when neither group qualifies. The
    /// match goes through `ProtectProCorrelation.load`, the Protect screen's own calculator,
    /// against Jamf School devices only when `school` is set; it is left out of a Protect-only
    /// environment (`hasInventory` false) and against an inventory snapshot past
    /// `max_cache_age_hours`, the summary builder's own rule.
    static func protectSummaryFigures(
        dataDir: URL, workspace: WorkspaceID, landed: Set<String>, school: Bool = false,
        hasInventory: Bool = true, maxCacheAgeHours: Int = 168,
        onLine: @Sendable (CLIBridge.LogLine) -> Void = { _ in }
    ) -> ProtectSummaryFigures? {
        func readable(_ kind: String) -> Bool {
            landed.contains(kind)
                && FileManager.newestJSONFile(in: dataDir.appendingPathComponent(kind)) != nil
        }
        let snapshot = ProtectDashboardService.load(dataDir: dataDir)
        var figures = ProtectSummaryFigures()
        if readable("protect-computers"), !snapshot.unreadableKinds.contains("protect-computers") {
            let stale = hasInventory ? staleInventoryKind(
                dataDir: dataDir, kinds: [school ? "school-devices" : "computers"],
                maxCacheAgeHours: maxCacheAgeHours) : nil
            if let stale {
                logMatchLeftOut("Jamf Protect", kind: stale, hours: maxCacheAgeHours, onLine)
            }
            let matched = hasInventory && stale == nil
                ? ProtectProCorrelation.load(
                    protect: snapshot.computers, profile: workspace.name, demoMode: false,
                    school: school)?.matchedShare
                : nil
            figures.computers = .init(count: snapshot.computers.count, matched: matched)
        }
        if readable("protect-alerts"), !snapshot.unreadableKinds.contains("protect-alerts") {
            let open = snapshot.alerts.filter(\.isOpen)
            let bySeverity = Dictionary(
                grouping: open.compactMap { $0.severity?.lowercased() }, by: { $0 }
            ).mapValues(\.count)
            figures.alerts = .init(open: open.count, counts: bySeverity.isEmpty ? nil : bySeverity)
        }
        return figures.computers == nil && figures.alerts == nil ? nil : figures
    }

    /// The first of `kinds` whose newest snapshot exists and is past the age limit; nil when
    /// none is. An absent or unreadable one is left to the match's own loader, which returns
    /// nil for it.
    private static func staleInventoryKind(
        dataDir: URL, kinds: [String], maxCacheAgeHours: Int
    ) -> String? {
        for kind in kinds {
            do {
                _ = try loadLatestSnapshotData(
                    kind: kind, dataDir: dataDir, maxCacheAgeHours: maxCacheAgeHours)
            } catch is SnapshotCacheExpired {
                return kind
            } catch {}
        }
        return nil
    }

    /// One `[info]` line, never `[partial]`: a match left out for old inventory is not a failure.
    private static func logMatchLeftOut(
        _ product: String, kind: String, hours: Int,
        _ onLine: @Sendable (CLIBridge.LogLine) -> Void
    ) {
        onLine(.init(timestamp: Date(), level: .info, text:
            "[info] \(product) match left out: \(kind) is older than \(hours) hours"))
    }

    /// The Security Cloud figures (P12), read only when `landed` has `security-risk` and its
    /// newest snapshot reads; nil otherwise. The match uses `SecurityCloudCorrelation`, the one
    /// calculator, against the environment's inventory, and is left out when any inventory
    /// snapshot it would read (computers and mobile devices, or School's devices) is past
    /// `max_cache_age_hours`.
    static func securityCloudSummaryFigures(
        dataDir: URL, workspace: WorkspaceID, landed: Set<String>, school: Bool = false,
        hasInventory: Bool = true, maxCacheAgeHours: Int = 168,
        onLine: @Sendable (CLIBridge.LogLine) -> Void = { _ in }
    ) -> SecurityCloudSummaryFigures? {
        guard landed.contains(securityRiskKind),
              let rows = SecurityRiskRow.load(dataDir: dataDir) else { return nil }
        // The mobile rows come from whichever kind the reader picks (it can be the legacy one).
        let mobile = school ? nil : MobileFleetService.load(dataDir: dataDir)
        let kinds = school ? ["school-devices"]
            : ["computers"] + [mobile?.inventoryKind].compactMap { $0 }
        let stale = hasInventory ? staleInventoryKind(
            dataDir: dataDir, kinds: kinds, maxCacheAgeHours: maxCacheAgeHours) : nil
        if let stale {
            logMatchLeftOut("Security Cloud", kind: stale, hours: maxCacheAgeHours, onLine)
        }
        let correlation: SecurityCloudCorrelation? = if !hasInventory || stale != nil {
            nil
        } else if let mobile {
            SecurityCloudCorrelation.load(rows: rows, profile: workspace.name, mobile: mobile)
        } else {
            SecurityCloudCorrelation.load(rows: rows, schoolProfile: workspace.name)
        }
        return .init(
            count: rows.count, matched: correlation?.matchedShare,
            riskCounts: SecurityRiskRow.riskCounts(rows))
    }

    /// Adds `products` and the Protect figures to today's summary (P9-R1, R2, R4). Creates a
    /// summary only for a Protect-only environment; an MDM environment whose MDM wrote none
    /// gets nothing, so a failed MDM collect never reads as a Trends day.
    @discardableResult
    static func finalizeEnvironmentSummary(
        summariesDir: URL, dataDir: URL, environment: EnvironmentProfiles,
        workspace: WorkspaceID, landed: [EnvironmentProducts.Product: Set<String>],
        day: Date = Date(), announcesWrite: Bool = true, maxCacheAgeHours: Int = 168,
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
                dataDir: dataDir, workspace: workspace, landed: protectKinds,
                school: environment.isSchool, hasInventory: environment.mdm != nil,
                maxCacheAgeHours: maxCacheAgeHours, onLine: onLine)
        let securityFigures = securityCloudSummaryFigures(
            dataDir: dataDir, workspace: workspace, landed: landed[.securityCloud] ?? [],
            school: environment.isSchool, hasInventory: environment.mdm != nil,
            maxCacheAgeHours: maxCacheAgeHours, onLine: onLine)
        guard !slots.isEmpty || figures != nil else { return .keptExisting }
        summary = summary.withEnvironment(
            products: slots.isEmpty ? nil : slots, protect: figures, securityCloud: securityFigures)
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
