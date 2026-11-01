import SwiftUI

/// Group inventory dashboard for Classic API computer groups, mobile device groups,
/// and advanced mobile device searches. Surfaces group counts, member counts, empty and
/// unused groups, and each search's criteria from snapshots the app already collects.
struct GroupsView: View {
    @Environment(WorkspaceStore.self) private var workspace
    @Environment(\.colorSchemeContrast) private var contrast
    @State private var snapshot: GroupInventoryService.Snapshot = .empty
    /// The `dataSource` `snapshot` was read for; the content waits for it to match.
    @State private var loadedSource: String?
    @State private var reloads = 0

    var body: some View {
        PageScaffold {
            PageHeader(
                kicker: L("Fleet"),
                title: L("Groups & Searches"),
                subtitle: subtitle,
                // The demo dataset is frozen on purpose; an age warning on it is noise.
                lastModified: workspace.demoMode ? nil : snapshot.snapshotDate
            )

            if loadedSource != dataSource {
                ScreenLoadingCard(what: "groups")
            } else {
                // Shared StaleDataBanner surfaces snapshot freshness above the main content.
                // Suppressed in demo mode (the demo dataset is intentionally static and
                // not user-perceivably "stale"). Renders nothing when source is .fresh.
                if !workspace.demoMode {
                    CollectNowBanner(source: snapshot.cacheSource, tiers: [.inventory])
                }

                if !snapshot.isDetected {
                    emptyState
                } else {
                    summaryTiles
                    GroupTableCard(
                        title: L("Computer Groups"), emptyText: L("No computer groups found."),
                        groups: snapshot.classicComputerGroups, platform: .computer,
                        snapshot: snapshot)
                    GroupTableCard(
                        title: L("Mobile Device Groups"), emptyText: L("No mobile device groups found."),
                        groups: snapshot.classicMobileGroups, platform: .mobile,
                        snapshot: snapshot)
                    if !snapshot.advancedMobileSearches.isEmpty {
                        advancedSearchesCard
                    }
                }
            }
        }
        .tint(Theme.Colors.goldBright)
        .task(id: "\(dataSource)|\(reloads)") { await load() }
        .onReceive(NotificationCenter.default.publisher(for: .refreshActiveTab)) { _ in
            reloads += 1
        }
    }

    private var subtitle: String? {
        let totalGroups = snapshot.classicComputerGroupCount + snapshot.classicMobileGroupCount
        let totalSearches = snapshot.advancedSearchCount

        if totalGroups > 0 && totalSearches > 0 {
            let groups = totalGroups == 1 ? L("\(totalGroups) group") : L("\(totalGroups) groups")
            let searches = totalSearches == 1 ? L("\(totalSearches) search") : L("\(totalSearches) searches")
            return L("\(groups) and \(searches).")
        } else if totalGroups > 0 {
            return (totalGroups == 1 ? L("\(totalGroups) group tracked across computer and mobile platforms.") : L("\(totalGroups) groups tracked across computer and mobile platforms."))
        } else if totalSearches > 0 {
            return (totalSearches == 1 ? L("\(totalSearches) advanced mobile search.") : L("\(totalSearches) advanced mobile searches."))
        } else {
            return nil
        }
    }

    // MARK: - Data loading

    /// Changes when the profile does, and when demo mode flips under the same profile name.
    private var dataSource: String { "\(workspace.demoMode)|\(workspace.profile)" }

    /// Decodes off the main thread; the task is cancelled when `dataSource` or `reloads` changes.
    private func load() async {
        let source = dataSource
        if loadedSource != source { loadedSource = nil; snapshot = .empty }
        // The demo profile's name could match a real workspace on this Mac;
        // demo mode never reads one.
        guard !workspace.demoMode else {
            snapshot = DemoData.groupInventory
            loadedSource = source
            return
        }
        let profile = workspace.profile
        guard let loaded = await ScreenLoad.paint(
            stillCurrent: { source == dataSource },
            read: { GroupInventoryService.load(profile: profile) }
        ) else { return }
        snapshot = loaded
        loadedSource = source
    }

    /// Maps Jamf's siteId to a display label, matching the Python sheet convention:
    /// `-1` and empty / nil both represent "All Sites" (no site restriction).
    private func siteLabel(_ siteId: String?) -> String {
        switch siteId {
        case nil, "", "-1": return L("All Sites")
        case let id?: return id
        }
    }

    // MARK: - Views

    private var emptyState: some View {
        Card(padding: 24) {
            EmptyStateView(
                systemImage: "rectangle.3.group",
                title: L("No group data detected"),
                message: L("Collect data for this screen with the Collect now banner when it shows, or run this command."),
                commands: [EmptyStateView.collectCommand(
                    profile: workspace.profile, kinds: [
                        "classic-computer-groups", "classic-mobile-device-groups",
                        "advanced-mobile-device-searches",
                    ])]
            )
        }
    }

    private var summaryTiles: some View {
        VStack(alignment: .leading, spacing: 12) {
            EqualHeightTileGrid(minTileWidth: 200) {
                StatTile(
                    label: L("Computer Groups"),
                    value: "\(snapshot.classicComputerGroupCount)",
                    sub: L("\(snapshot.classicComputerSmartGroupCount) smart, \(snapshot.classicComputerStaticGroupCount) static"),
                    fillsHeight: true)
                StatTile(
                    label: L("Mobile Device Groups"),
                    value: "\(snapshot.classicMobileGroupCount)",
                    sub: L("\(snapshot.classicMobileSmartGroupCount) smart, \(snapshot.classicMobileStaticGroupCount) static"),
                    fillsHeight: true)
                StatTile(
                    label: L("Empty Groups"),
                    value: snapshot.emptyGroupCount.map(String.init) ?? "—",
                    sub: snapshot.emptyGroupCount == nil
                        ? L("Member counts not collected yet") : L("No members"),
                    fillsHeight: true)
                StatTile(
                    label: L("Unused Groups"),
                    value: snapshot.unusedGroupCount.map(String.init) ?? "—",
                    sub: unusedCaption,
                    fillsHeight: true)
                StatTile(
                    label: L("Policies With No Scope"),
                    value: snapshot.unscopedPolicyCount.map(String.init) ?? "—",
                    sub: snapshot.unscopedPolicyCount == nil
                        ? L("Policy status not collected yet") : L("Target no computers"),
                    fillsHeight: true)
            }
            tileActions
        }
    }

    private var unusedCaption: String {
        guard let date = snapshot.analysisDate else {
            return L("Run Analyze Groups in Health Audit")
        }
        return L("Computer groups no policy or profile uses, from Health Audit, ")
            + date.formatted(date: .abbreviated, time: .omitted)
    }

    @ViewBuilder
    private var tileActions: some View {
        HStack(spacing: 8) {
            if snapshot.analysisDate == nil {
                PNPButton(title: L("Open Health Audit"), icon: "arrow.right", size: .sm) {
                    open(.audit)
                }
                .help("Analyze Groups on the Health Audit screen finds unused groups.")
            }
            if (snapshot.unscopedPolicyCount ?? 0) > 0 {
                PNPButton(title: L("Review policies with no scope"), icon: "arrow.right", size: .sm) {
                    open(.policyProfile)
                }
            }
        }
    }

    private func open(_ tab: Tab) {
        NotificationCenter.default.post(
            name: .navigateToTab, object: nil, userInfo: ["tab": tab.rawValue])
    }

    private var advancedSearchesCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                SectionHeader(
                    title: L("Advanced Mobile Searches"),
                    trailing: (snapshot.advancedSearchCount == 1 ? L("\(snapshot.advancedSearchCount) search") : L("\(snapshot.advancedSearchCount) searches"))
                )

                Table(snapshot.advancedMobileSearches.enumerated().map {
                    SearchRowWrapper(search: $0.element, index: $0.offset)
                }) {
                    TableColumn("Name") { wrapper in
                        Text(wrapper.search.name ?? L("Untitled Search"))
                            .font(.callout.weight(.medium))
                            .foregroundStyle(Theme.Colors.fg)
                    }
                    .width(min: 160, ideal: 200)

                    TableColumn("Criteria") { wrapper in
                        let text = wrapper.search.criteriaSummary
                        Text(text)
                            .font(.callout)
                            .foregroundStyle(Theme.Text.secondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .help(text)
                    }
                    .width(min: 260, ideal: 420)

                    TableColumn("Display Fields") { wrapper in
                        let count = wrapper.search.displayFields?.count ?? 0
                        Text(String(count))
                            .font(.caption)
                            .foregroundStyle(Theme.Text.tertiary(contrast))
                    }
                    .width(min: 80, ideal: 100)

                    TableColumn("Site") { wrapper in
                        Text(siteLabel(wrapper.search.siteId))
                            .font(Theme.Fonts.mono(11))
                            .foregroundStyle(Theme.Text.tertiary(contrast))
                    }
                    .width(min: 60, ideal: 80)
                }
                .pageTableHeight(rows: snapshot.advancedSearchCount)
                .font(.callout)
            }
        }
    }
}

// MARK: - Group table

/// One platform's group table, with member counts and Empty / Unused flags.
private struct GroupTableCard: View {
    @Environment(\.colorSchemeContrast) private var contrast
    let title: String
    let emptyText: String
    let groups: [ClassicGroupRow]
    let platform: GroupInventoryService.Platform
    let snapshot: GroupInventoryService.Snapshot

    private var rows: [GroupRowWrapper] {
        groups.enumerated().map { offset, group in
            GroupRowWrapper(
                group: group, detail: snapshot.detail(for: group, platform), index: offset)
        }
    }

    var body: some View {
        let visible = rows
        Card {
            VStack(alignment: .leading, spacing: 12) {
                SectionHeader(
                    title: title, trailing: groups.isEmpty ? nil : L("\(groups.count) total"))
                if groups.isEmpty {
                    Text(emptyText)
                        .font(.footnote)
                        .foregroundStyle(Theme.Text.tertiary(contrast))
                        .padding(.bottom, 8)
                } else {
                    table(visible)
                }
            }
        }
    }

    private func table(_ visible: [GroupRowWrapper]) -> some View {
        Table(visible) {
            TableColumn("Name") { wrapper in
                Text(wrapper.group.name ?? L("Untitled Group"))
                    .font(.callout.weight(.medium))
                    .foregroundStyle(Theme.Colors.fg)
            }
            .width(min: 160, ideal: 240)

            TableColumn("Type") { wrapper in
                Pill(
                    text: wrapper.group.isSmart ? L("Smart") : L("Static"),
                    tone: wrapper.group.isSmart ? .teal : .muted
                )
                .accessibilityLabel("\(wrapper.group.isSmart ? "Smart" : "Static") group")
            }
            .width(min: 70, ideal: 90)

            TableColumn("Status") { wrapper in
                HStack(spacing: 4) {
                    if wrapper.detail.isEmpty { Pill(text: L("Empty"), tone: .warn) }
                    if wrapper.detail.unused == true { Pill(text: L("Unused"), tone: .gold) }
                }
            }
            .width(min: 90, ideal: 130)

            TableColumn("Members") { wrapper in
                Text(wrapper.detail.memberCount.map(String.init) ?? "—")
                    .font(.callout)
                    .monospacedDigit()
                    .foregroundStyle(Theme.Text.secondary)
            }
            .width(min: 60, ideal: 70)

            TableColumn("Description") { wrapper in
                let text = wrapper.detail.description ?? ""
                Text(text.isEmpty ? "—" : text)
                    .font(.callout)
                    .foregroundStyle(Theme.Text.tertiary(contrast))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(text)
            }
            .width(min: 120, ideal: 240)

            TableColumn("ID") { wrapper in
                Text(wrapper.group.id.map(String.init) ?? "—")
                    .font(Theme.Fonts.mono(11))
                    .foregroundStyle(Theme.Text.tertiary(contrast))
            }
            .width(min: 50, ideal: 60)
        }
        .font(.callout)
        .pageTableHeight(rows: visible.count, rowHeight: PageTableMetrics.richRowHeight)
    }
}

// MARK: - Table wrappers

/// Wrapper to make ClassicGroupRow identifiable for Table
private struct GroupRowWrapper: Identifiable {
    let group: ClassicGroupRow
    let detail: GroupInventoryService.GroupDetail
    let index: Int

    var id: String {
        if let groupId = group.id {
            return "group_\(groupId)"
        } else {
            return "group_index_\(index)"
        }
    }
}

/// Wrapper to make AdvancedMobileSearchRow identifiable for Table
private struct SearchRowWrapper: Identifiable {
    let search: AdvancedMobileSearchRow
    let index: Int

    var id: String {
        if let searchId = search.id {
            return "search_\(searchId)"
        } else {
            return "search_index_\(index)"
        }
    }
}