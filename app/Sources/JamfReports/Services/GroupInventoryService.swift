import Foundation

/// Reads the latest snapshots from three jamf-cli commands introduced in v1.18
/// and prepares typed summaries for the group inventory view slice:
///
/// - `advanced-mobile-device-searches list` — saved mobile searches with criteria counts
/// - `classic-computer-groups list`          — Classic API computer groups (smart + static)
/// - `classic-mobile-device-groups list`     — Classic API mobile device groups (smart + static)
///
/// The view consumer is still required (this PR wires the engine/service layer only).
/// Returns `.empty` when no snapshots exist — that is normal pre-first-collect.
struct GroupInventoryService: Sendable {

    // MARK: - Snapshot

    /// Summary of all three group-inventory snapshot sources for one profile.
    struct Snapshot: Sendable, Equatable {
        let advancedMobileSearches: [AdvancedMobileSearchRow]
        let classicComputerGroups: [ClassicGroupRow]
        let classicMobileGroups: [ClassicGroupRow]
        /// True when at least one source file decoded successfully, even to an empty array.
        /// Mirrors `ProtectDashboardService.Snapshot.isDetected` semantics: distinguishes
        /// "collect ran but found nothing" from "collect has never run."
        let decodedAnySource: Bool
        let sourceFile: URL?
        let snapshotDate: Date?

        // MARK: - Computed aggregates

        var advancedSearchCount: Int { advancedMobileSearches.count }

        var classicComputerGroupCount: Int { classicComputerGroups.count }
        var classicComputerSmartGroupCount: Int { classicComputerGroups.filter(\.isSmart).count }
        var classicComputerStaticGroupCount: Int { classicComputerGroups.filter { !$0.isSmart }.count }

        var classicMobileGroupCount: Int { classicMobileGroups.count }
        var classicMobileSmartGroupCount: Int { classicMobileGroups.filter(\.isSmart).count }
        var classicMobileStaticGroupCount: Int { classicMobileGroups.filter { !$0.isSmart }.count }

        /// Freshness signal for `StaleDataBanner` consumers.
        var cacheSource: CacheSource {
            CacheSource.from(snapshotDate: snapshotDate, withinHours: 36)
        }

        /// True when at least one source decoded successfully (even to an empty array).
        /// False only when no snapshots exist (collect has never run for this profile).
        var isDetected: Bool { decodedAnySource }

        static let empty = Snapshot(
            advancedMobileSearches: [],
            classicComputerGroups: [],
            classicMobileGroups: [],
            decodedAnySource: false,
            sourceFile: nil,
            snapshotDate: nil
        )

        static func == (lhs: Snapshot, rhs: Snapshot) -> Bool {
            lhs.advancedMobileSearches.count == rhs.advancedMobileSearches.count &&
            lhs.classicComputerGroups.count == rhs.classicComputerGroups.count &&
            lhs.classicMobileGroups.count == rhs.classicMobileGroups.count &&
            lhs.decodedAnySource == rhs.decodedAnySource &&
            lhs.sourceFile == rhs.sourceFile &&
            lhs.snapshotDate == rhs.snapshotDate
        }
    }

    // MARK: - Load

    /// Returns the newest group-inventory snapshot for `profile`.
    /// Returns `.empty` when no snapshots exist.
    static func load(profile: String) -> Snapshot {
        guard let dir = (try? WorkspacePaths.dataDir(for: profile)) else {
            return .empty
        }

        let searchesDir = dir.appendingPathComponent(
            "advanced-mobile-device-searches", isDirectory: true)
        let computerGroupsDir = dir.appendingPathComponent(
            "classic-computer-groups", isDirectory: true)
        let mobileGroupsDir = dir.appendingPathComponent(
            "classic-mobile-device-groups", isDirectory: true)

        let searchesURL = FileManager.newestJSONFile(in: searchesDir)
        let computerGroupsURL = FileManager.newestJSONFile(in: computerGroupsDir)
        let mobileGroupsURL = FileManager.newestJSONFile(in: mobileGroupsDir)

        return load(
            searchesURL: searchesURL,
            computerGroupsURL: computerGroupsURL,
            mobileGroupsURL: mobileGroupsURL
        )
    }

    /// Test seam: load directly from arbitrary file URLs.
    static func load(
        searchesURL: URL?,
        computerGroupsURL: URL?,
        mobileGroupsURL: URL?
    ) -> Snapshot {
        var readSomething = false
        let searches = loadSearches(from: searchesURL, success: &readSomething)
        let computerGroups = loadClassicGroups(
            from: computerGroupsURL, kind: "classic-computer-groups", success: &readSomething)
        let mobileGroups = loadClassicGroups(
            from: mobileGroupsURL, kind: "classic-mobile-device-groups", success: &readSomething)

        guard readSomething else { return .empty }

        let sourceFiles = [searchesURL, computerGroupsURL, mobileGroupsURL].compactMap { $0 }
        let sourceFile = sourceFiles.max { lhs, rhs in
            let l = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
            let r = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
            return l < r
        }
        let snapshotDate = sourceFile.flatMap { url in
            (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate
        }

        return Snapshot(
            advancedMobileSearches: searches,
            classicComputerGroups: computerGroups,
            classicMobileGroups: mobileGroups,
            decodedAnySource: readSomething,
            sourceFile: sourceFile,
            snapshotDate: snapshotDate
        )
    }

    // MARK: - Private loaders

    private static func loadSearches(
        from url: URL?, success: inout Bool
    ) -> [AdvancedMobileSearchRow] {
        guard let url, let data = try? Data(contentsOf: url) else { return [] }
        if let envelope = try? JSONDecoder().decode(AdvancedMobileSearchEnvelope.self, from: data) {
            success = true
            return envelope.results
        }
        AppLogger.engine.warning(
            "GroupInventoryService: failed to decode advanced-mobile-device-searches at \(url.lastPathComponent, privacy: .public)"
        )
        return []
    }

    private static func loadClassicGroups(
        from url: URL?, kind: String, success: inout Bool
    ) -> [ClassicGroupRow] {
        guard let url, let data = try? Data(contentsOf: url) else { return [] }
        if let groups = try? JSONDecoder().decode([ClassicGroupRow].self, from: data) {
            success = true
            return groups
        }
        AppLogger.engine.warning(
            "GroupInventoryService: failed to decode \(kind, privacy: .public) at \(url.lastPathComponent, privacy: .public)"
        )
        return []
    }
}
