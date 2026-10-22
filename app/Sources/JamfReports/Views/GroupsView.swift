import SwiftUI

/// Group inventory dashboard for Classic API computer groups, mobile device groups,
/// and advanced mobile device searches. Surfaces group counts, member counts, empty and
/// unused groups, and each search's criteria from snapshots the app already collects.
struct GroupsView: View {
    @Environment(WorkspaceStore.self) private var workspace
    @Environment(\.colorSchemeContrast) private var contrast
    @State private var snapshot: GroupInventoryService.Snapshot = .empty
    @State private var hasLoaded = false

    var body: some View {
        PageScaffold {
            PageHeader(
                kicker: "Fleet",
                title: "Groups & Searches",
                subtitle: subtitle,
                // The demo dataset is frozen on purpose; an age warning on it is noise.
                lastModified: workspace.demoMode ? nil : snapshot.snapshotDate
            )

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
                    title: "Computer Groups", emptyText: "No computer groups found.",
                    groups: snapshot.classicComputerGroups, platform: .computer,
                    snapshot: snapshot)
                GroupTableCard(
                    title: "Mobile Device Groups", emptyText: "No mobile device groups found.",
                    groups: snapshot.classicMobileGroups, platform: .mobile,
                    snapshot: snapshot)
                if !snapshot.advancedMobileSearches.isEmpty {
                    advancedSearchesCard
                }
            }
        }
        .tint(Theme.Colors.goldBright)
        .onAppear(perform: loadIfNeeded)
        .onChange(of: workspace.profile) { _, _ in reload() }
        .onReceive(NotificationCenter.default.publisher(for: .refreshActiveTab)) { _ in
            reload()
        }
    }

    private var subtitle: String? {
        let totalGroups = snapshot.classicComputerGroupCount + snapshot.classicMobileGroupCount
        let totalSearches = snapshot.advancedSearchCount

        if totalGroups > 0 && totalSearches > 0 {
            return "\(totalGroups) group\(totalGroups == 1 ? "" : "s") and \(totalSearches) search\(totalSearches == 1 ? "" : "es")."
        } else if totalGroups > 0 {
            return "\(totalGroups) group\(totalGroups == 1 ? "" : "s") tracked across computer and mobile platforms."
        } else if totalSearches > 0 {
            return "\(totalSearches) advanced mobile search\(totalSearches == 1 ? "" : "es")."
        } else {
            return nil
        }
    }

    // MARK: - Data loading

    private func loadIfNeeded() {
        guard !hasLoaded else { return }
        reload()
        hasLoaded = true
    }

    private func reload() {
        // The demo profile's name could match a real workspace on this Mac;
        // demo mode never reads one.
        snapshot = workspace.demoMode
            ? DemoData.groupInventory
            : GroupInventoryService.load(profile: workspace.profile)
    }

    /// Maps Jamf's siteId to a display label, matching the Python sheet convention:
    /// `-1` and empty / nil both represent "All Sites" (no site restriction).
    private func siteLabel(_ siteId: String?) -> String {
        switch siteId {
        case nil, "", "-1": return "All Sites"
        case let id?: return id
        }
    }

    // MARK: - Views

    private var emptyState: some View {
        Card(padding: 24) {
            EmptyStateView(
                systemImage: "rectangle.3.group",
                title: "No group data detected",
                message: "Collect data for this screen with the Collect now banner when it shows, "
                    + "or run this command.",
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
                    label: "Computer Groups",
                    value: "\(snapshot.classicComputerGroupCount)",
                    sub: "\(snapshot.classicComputerSmartGroupCount) smart, "
                        + "\(snapshot.classicComputerStaticGroupCount) static",
                    fillsHeight: true)
                StatTile(
                    label: "Mobile Device Groups",
                    value: "\(snapshot.classicMobileGroupCount)",
                    sub: "\(snapshot.classicMobileSmartGroupCount) smart, "
                        + "\(snapshot.classicMobileStaticGroupCount) static",
                    fillsHeight: true)
                StatTile(
                    label: "Empty Groups",
                    value: snapshot.emptyGroupCount.map(String.init) ?? "—",
                    sub: snapshot.emptyGroupCount == nil
                        ? "Member counts not collected yet" : "No members",
                    fillsHeight: true)
                StatTile(
                    label: "Unused Groups",
                    value: snapshot.unusedGroupCount.map(String.init) ?? "—",
                    sub: unusedCaption,
                    fillsHeight: true)
                StatTile(
                    label: "Policies With No Scope",
                    value: snapshot.unscopedPolicyCount.map(String.init) ?? "—",
                    sub: snapshot.unscopedPolicyCount == nil
                        ? "Policy status not collected yet" : "Target no computers",
                    fillsHeight: true)
            }
            tileActions
        }
    }

    private var unusedCaption: String {
        guard let date = snapshot.analysisDate else {
            return "Run Analyze Groups in Health Audit"
        }
        return "Computer groups no policy or profile uses, from Health Audit, "
            + date.formatted(date: .abbreviated, time: .omitted)
    }

    @ViewBuilder
    private var tileActions: some View {
        HStack(spacing: 8) {
            if snapshot.analysisDate == nil {
                PNPButton(title: "Open Health Audit", icon: "arrow.right", size: .sm) {
                    open(.audit)
                }
                .help("Analyze Groups on the Health Audit screen finds unused groups.")
            }
            if (snapshot.unscopedPolicyCount ?? 0) > 0 {
                PNPButton(title: "Review policies with no scope", icon: "arrow.right", size: .sm) {
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
                    title: "Advanced Mobile Searches",
                    trailing: "\(snapshot.advancedSearchCount) search\(snapshot.advancedSearchCount == 1 ? "" : "es")"
                )

                Table(snapshot.advancedMobileSearches.enumerated().map {
                    SearchRowWrapper(search: $0.element, index: $0.offset)
                }) {
                    TableColumn("Name") { wrapper in
                        Text(wrapper.search.name ?? "Untitled Search")
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
                    title: title, trailing: groups.isEmpty ? nil : "\(groups.count) total")
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
                Text(wrapper.group.name ?? "Untitled Group")
                    .font(.callout.weight(.medium))
                    .foregroundStyle(Theme.Colors.fg)
            }
            .width(min: 160, ideal: 240)

            TableColumn("Type") { wrapper in
                Pill(
                    text: wrapper.group.isSmart ? "Smart" : "Static",
                    tone: wrapper.group.isSmart ? .teal : .muted
                )
                .accessibilityLabel("\(wrapper.group.isSmart ? "Smart" : "Static") group")
            }
            .width(min: 70, ideal: 90)

            TableColumn("Status") { wrapper in
                HStack(spacing: 4) {
                    if wrapper.detail.isEmpty { Pill(text: "Empty", tone: .warn) }
                    if wrapper.detail.unused == true { Pill(text: "Unused", tone: .gold) }
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