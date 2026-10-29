import Foundation

/// Reads the latest snapshots from three jamf-cli commands introduced in v1.18
/// and prepares typed summaries for the group inventory view slice:
///
/// - `advanced-mobile-device-searches list` — saved mobile searches with criteria counts
/// - `classic-computer-groups list`          — Classic API computer groups (smart + static)
/// - `classic-mobile-device-groups list`     — Classic API mobile device groups (smart + static)
///
/// Three more snapshots the app already holds enrich the Classic groups: `groups` (member
/// counts and descriptions), `group-tools-analyze` (groups no policy or profile references,
/// written only by the Health Audit's Analyze Groups) and `policy-status` (policies with no
/// scope). Returns `.empty` when no snapshots exist — that is normal pre-first-collect.
struct GroupInventoryService: Sendable {

    // MARK: - Snapshot

    enum Platform: Sendable { case computer, mobile }

    /// What the `groups` and `group-tools-analyze` snapshots add to one Classic group.
    /// Every field is nil when its source has no answer, so the view shows a dash, never 0.
    struct GroupDetail: Sendable, Equatable {
        var memberCount: Int?
        var description: String?
        /// True when the newest analysis found no policy or profile using the group; nil when
        /// never analysed (mobile groups are not analysed).
        var unused: Bool?

        var isEmpty: Bool { memberCount == 0 }
    }

    /// Summary of all group-inventory snapshot sources for one profile.
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
        /// Keyed by Classic id. Empty when no `groups` snapshot decoded.
        var computerDetails: [Int: GroupDetail] = [:]
        var mobileDetails: [Int: GroupDetail] = [:]
        /// When the newest Analyze Groups run was saved; nil when none decoded.
        var analysisDate: Date?
        /// Policies the newest policy-status snapshot flags `no_scope`; nil without one.
        var unscopedPolicyCount: Int?

        // MARK: - Computed aggregates

        var advancedSearchCount: Int { advancedMobileSearches.count }

        var classicComputerGroupCount: Int { classicComputerGroups.count }
        var classicComputerSmartGroupCount: Int { classicComputerGroups.filter(\.isSmart).count }
        var classicComputerStaticGroupCount: Int { classicComputerGroups.filter { !$0.isSmart }.count }

        var classicMobileGroupCount: Int { classicMobileGroups.count }
        var classicMobileSmartGroupCount: Int { classicMobileGroups.filter(\.isSmart).count }
        var classicMobileStaticGroupCount: Int { classicMobileGroups.filter { !$0.isSmart }.count }

        func detail(for group: ClassicGroupRow, _ platform: Platform) -> GroupDetail {
            guard let id = group.id else { return GroupDetail() }
            let table = platform == .computer ? computerDetails : mobileDetails
            return table[id] ?? GroupDetail()
        }

        /// Groups with a known member count of zero; nil when no `groups` snapshot decoded.
        var emptyGroupCount: Int? {
            let known = computerDetails.values.contains { $0.memberCount != nil }
                || mobileDetails.values.contains { $0.memberCount != nil }
            guard known else { return nil }
            return computerDetails.values.filter(\.isEmpty).count
                + mobileDetails.values.filter(\.isEmpty).count
        }

        /// Computer groups the newest analysis found unused; nil when never analysed.
        var unusedGroupCount: Int? {
            guard analysisDate != nil else { return nil }
            return computerDetails.values.filter { $0.unused == true }.count
        }

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
    }

    // MARK: - Load

    /// Returns the newest group-inventory snapshot for `profile`.
    /// Returns `.empty` when no snapshots exist.
    static func load(profile: String) -> Snapshot {
        guard let dir = (try? WorkspacePaths.dataDir(for: profile)) else {
            return .empty
        }
        return load(dataDir: dir)
    }

    /// `load(profile:)` over an explicit data directory, so tests need no workspace.
    static func load(dataDir dir: URL) -> Snapshot {
        func newest(_ kind: String) -> URL? {
            FileManager.newestJSONFile(in: dir.appendingPathComponent(kind, isDirectory: true))
        }

        return load(
            searchesURL: newest("advanced-mobile-device-searches"),
            computerGroupsURL: newest("classic-computer-groups"),
            mobileGroupsURL: newest("classic-mobile-device-groups"),
            groupsURL: newest("groups"),
            analysisURL: newest("group-tools-analyze"),
            policyStatusURL: newest("policy-status")
        )
    }

    /// Test seam: load directly from arbitrary file URLs.
    static func load(
        searchesURL: URL?,
        computerGroupsURL: URL?,
        mobileGroupsURL: URL?,
        groupsURL: URL? = nil,
        analysisURL: URL? = nil,
        policyStatusURL: URL? = nil
    ) -> Snapshot {
        var readSomething = false
        let searches = loadSearches(from: searchesURL, success: &readSomething)
        let computerGroups = loadClassicGroups(
            from: computerGroupsURL, kind: "classic-computer-groups", success: &readSomething)
        let mobileGroups = loadClassicGroups(
            from: mobileGroupsURL, kind: "classic-mobile-device-groups", success: &readSomething)

        guard readSomething else { return .empty }

        // The filename stamp, not mtime, which a sync provider restamps on download.
        let dated = [searchesURL, computerGroupsURL, mobileGroupsURL]
            .compactMap { $0 }
            .map { (url: $0, date: savedDate(of: $0)) }
        let newest = dated.max { $0.date < $1.date }

        let analysis = loadAnalysis(from: analysisURL)
        let membership = loadMembership(from: groupsURL)
        return Snapshot(
            advancedMobileSearches: searches,
            classicComputerGroups: computerGroups,
            classicMobileGroups: mobileGroups,
            decodedAnySource: readSomething,
            sourceFile: newest?.url,
            snapshotDate: newest?.date,
            computerDetails: details(
                for: computerGroups, membership.computer, unusedIDs: analysis),
            mobileDetails: details(for: mobileGroups, membership.mobile, unusedIDs: nil),
            analysisDate: analysis == nil ? nil : analysisURL.map(savedDate(of:)),
            unscopedPolicyCount: loadUnscopedPolicyCount(from: policyStatusURL)
        )
    }

    // MARK: - Joins

    /// Member counts and descriptions first, so a group the `groups` list lacks keeps nil.
    private static func details(
        for groups: [ClassicGroupRow], _ membership: [String: GroupsListRow],
        unusedIDs: Set<String>?
    ) -> [Int: GroupDetail] {
        var result: [Int: GroupDetail] = [:]
        for group in groups {
            guard let id = group.id else { continue }
            let row = membership[String(id)]
            let text = row?.description?.trimmingCharacters(in: .whitespacesAndNewlines)
            result[id] = GroupDetail(
                memberCount: row?.membershipCount,
                description: text?.isEmpty == false ? text : nil,
                unused: unusedIDs.map { $0.contains(String(id)) })
        }
        return result
    }

    private static func savedDate(of url: URL) -> Date {
        CloudStorage.snapshotTimestamp(of: url)
            ?? (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate
            ?? .distantPast
    }

    // MARK: - Private loaders

    private static func loadSearches(
        from url: URL?, success: inout Bool
    ) -> [AdvancedMobileSearchRow] {
        guard let url else { return [] }
        guard let data = BoundedFile.readLogged(url) else { return [] }
        if let envelope = try? JSONDecoder().decode(AdvancedMobileSearchEnvelope.self, from: data) {
            success = true
            return envelope.results
        }
        AppLogger.collect.warning(
            "GroupInventoryService: failed to decode advanced-mobile-device-searches at \(url.lastPathComponent, privacy: .public)"
        )
        return []
    }

    private static func loadClassicGroups(
        from url: URL?, kind: String, success: inout Bool
    ) -> [ClassicGroupRow] {
        guard let url else { return [] }
        guard let data = BoundedFile.readLogged(url) else { return [] }
        if let groups = try? JSONDecoder().decode([ClassicGroupRow].self, from: data) {
            success = true
            return groups
        }
        AppLogger.collect.warning(
            "GroupInventoryService: failed to decode \(kind, privacy: .public) at \(url.lastPathComponent, privacy: .public)"
        )
        return []
    }

    /// `groups` rows by Classic id, split by group type. A row with no id or an unknown type
    /// cannot be joined, since a computer and a mobile group can share an id.
    private static func loadMembership(
        from url: URL?
    ) -> (computer: [String: GroupsListRow], mobile: [String: GroupsListRow]) {
        guard let url, let rows = LenientElement<GroupsListRow>.rows(at: url, logging: .collect)
        else { return ([:], [:]) }
        var computer: [String: GroupsListRow] = [:]
        var mobile: [String: GroupsListRow] = [:]
        for row in rows {
            guard let id = row.jamfProID, let type = row.type?.uppercased() else { continue }
            if type == "COMPUTER" {
                computer[id] = row
            } else if type.hasPrefix("MOBILE") {
                mobile[id] = row
            }
        }
        return (computer, mobile)
    }

    private struct AnalyzedGroup: Decodable {
        let id: String?
        init(from decoder: Decoder) throws {
            id = try decoder.container(keyedBy: CodingKeys.self).lenientText(forKey: .id)
        }
        private enum CodingKeys: String, CodingKey { case id }
    }

    /// Ids in the newest Analyze Groups result, which lists the unused computer groups. Nil
    /// when there is no result or it is not a list: an unreadable file is not "nothing unused".
    private static func loadAnalysis(from url: URL?) -> Set<String>? {
        guard let url, let rows = LenientElement<AnalyzedGroup>.rows(at: url, logging: .collect)
        else { return nil }
        return Set(rows.compactMap(\.id))
    }

    private static func loadUnscopedPolicyCount(from url: URL?) -> Int? {
        guard let url,
              let policies = PolicyHealthService.load(policyURL: url, profileURL: nil)
        else { return nil }
        return policies.findings.filter { $0.check == "no_scope" }.count
    }
}

// MARK: - Search criteria text

extension AdvancedMobileSearchRow {
    static let noCriteriaText = "No criteria (matches every device)"

    /// The search as a sentence: `(Model like iPad OR Model like iPhone) AND Last Inventory
    /// Update more than x days ago 7`. A criterion's connector joins it to the one before.
    var criteriaSummary: String {
        let all = criteria ?? []
        guard !all.isEmpty else { return Self.noCriteriaText }
        let ordered = all.allSatisfy({ $0.priority != nil })
            ? all.enumerated().sorted {
                ($0.element.priority ?? 0, $0.offset) < ($1.element.priority ?? 0, $1.offset)
            }.map(\.element)
            : all
        var text = ""
        for (index, criterion) in ordered.enumerated() {
            if index > 0 {
                let joiner = criterion.andOr?.trimmingCharacters(in: .whitespaces).uppercased()
                text += " \(joiner.flatMap { $0.isEmpty ? nil : $0 } ?? "AND") "
            }
            text += criterion.sentence
        }
        return text
    }
}

private extension AdvancedMobileSearchCriterion {
    var sentence: String {
        let parts = [name, searchType, value]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let body = parts.isEmpty ? "Unnamed criterion" : parts.joined(separator: " ")
        return (openingParen == true ? "(" : "") + body + (closingParen == true ? ")" : "")
    }
}
