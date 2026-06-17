import SwiftUI

/// Group inventory dashboard for Classic API computer groups, mobile device groups,
/// and advanced mobile device searches. Surfaces group counts, type distribution,
/// and detailed inventories from `classic-computer-groups list`, `classic-mobile-device-groups list`,
/// and `advanced-mobile-device-searches list` snapshots.
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
                lastModified: snapshot.snapshotDate
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
                computerGroupsCard
                mobileGroupsCard
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
        snapshot = GroupInventoryService.load(profile: workspace.profile)
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
                message: "Run `jamf-cli pro classic-computer-groups list`, `classic-mobile-device-groups list`, and `advanced-mobile-device-searches list` to populate this dashboard."
            )
        }
    }

    private var computerGroupsCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                SectionHeader(
                    title: "Computer Groups",
                    trailing: snapshot.classicComputerGroupCount > 0
                        ? "\(snapshot.classicComputerSmartGroupCount) smart, \(snapshot.classicComputerStaticGroupCount) static"
                        : nil
                )

                if snapshot.classicComputerGroups.isEmpty {
                    Text("No computer groups found.")
                        .font(.footnote)
                        .foregroundStyle(Theme.Text.tertiary(contrast))
                        .padding(.bottom, 8)
                } else {
                    Table(snapshot.classicComputerGroups.enumerated().map { GroupRowWrapper(group: $0.element, index: $0.offset) }) {
                        TableColumn("Name") { wrapper in
                            Text(wrapper.group.name ?? "Untitled Group")
                                .font(.callout.weight(.medium))
                                .foregroundStyle(Theme.Colors.fg)
                        }
                        .width(min: 180, ideal: 250)

                        TableColumn("Type") { wrapper in
                            Pill(
                                text: wrapper.group.isSmart ? "Smart" : "Static",
                                tone: wrapper.group.isSmart ? .teal : .muted
                            )
                            .accessibilityLabel("\(wrapper.group.isSmart ? "Smart" : "Static") group")
                        }
                        .width(min: 80, ideal: 100)

                        TableColumn("ID") { wrapper in
                            if let id = wrapper.group.id {
                                Text(String(id))
                                    .font(Theme.Fonts.mono(11))
                                    .foregroundStyle(Theme.Text.tertiary(contrast))
                            } else {
                                Text("—")
                                    .foregroundStyle(Theme.Text.tertiary(contrast))
                            }
                        }
                        .width(min: 60, ideal: 80)
                    }
                    .font(.callout)
                }
            }
        }
    }

    private var mobileGroupsCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                SectionHeader(
                    title: "Mobile Device Groups",
                    trailing: snapshot.classicMobileGroupCount > 0
                        ? "\(snapshot.classicMobileSmartGroupCount) smart, \(snapshot.classicMobileStaticGroupCount) static"
                        : nil
                )

                if snapshot.classicMobileGroups.isEmpty {
                    Text("No mobile device groups found.")
                        .font(.footnote)
                        .foregroundStyle(Theme.Text.tertiary(contrast))
                        .padding(.bottom, 8)
                } else {
                    Table(snapshot.classicMobileGroups.enumerated().map { GroupRowWrapper(group: $0.element, index: $0.offset) }) {
                        TableColumn("Name") { wrapper in
                            Text(wrapper.group.name ?? "Untitled Group")
                                .font(.callout.weight(.medium))
                                .foregroundStyle(Theme.Colors.fg)
                        }
                        .width(min: 180, ideal: 250)

                        TableColumn("Type") { wrapper in
                            Pill(
                                text: wrapper.group.isSmart ? "Smart" : "Static",
                                tone: wrapper.group.isSmart ? .teal : .muted
                            )
                            .accessibilityLabel("\(wrapper.group.isSmart ? "Smart" : "Static") group")
                        }
                        .width(min: 80, ideal: 100)

                        TableColumn("ID") { wrapper in
                            if let id = wrapper.group.id {
                                Text(String(id))
                                    .font(Theme.Fonts.mono(11))
                                    .foregroundStyle(Theme.Text.tertiary(contrast))
                            } else {
                                Text("—")
                                    .foregroundStyle(Theme.Text.tertiary(contrast))
                            }
                        }
                        .width(min: 60, ideal: 80)
                    }
                    .font(.callout)
                }
            }
        }
    }

    private var advancedSearchesCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                SectionHeader(
                    title: "Advanced Mobile Searches",
                    trailingTag: snapshot.advancedSearchCount <= 30 ? nil : "\(min(30, snapshot.advancedSearchCount)) of \(snapshot.advancedSearchCount)"
                )

                Table(Array(snapshot.advancedMobileSearches.prefix(30).enumerated()).map { SearchRowWrapper(search: $0.element, index: $0.offset) }) {
                    TableColumn("Name") { wrapper in
                        Text(wrapper.search.name ?? "Untitled Search")
                            .font(.callout.weight(.medium))
                            .foregroundStyle(Theme.Colors.fg)
                    }
                    .width(min: 180, ideal: 220)

                    TableColumn("Criteria Count") { wrapper in
                        let count = wrapper.search.criteria?.count ?? 0
                        Text(String(count))
                            .font(.caption)
                            .foregroundStyle(Theme.Text.tertiary(contrast))
                    }
                    .width(min: 80, ideal: 100)

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
                .font(.callout)
            }
        }
    }
}

// MARK: - Table wrappers

/// Wrapper to make ClassicGroupRow identifiable for Table
private struct GroupRowWrapper: Identifiable {
    let group: ClassicGroupRow
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