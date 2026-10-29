import SwiftUI

/// The Overview on a Jamf School workspace: today's device counts and School's own resource
/// counts from the newest snapshots (`SchoolFleetService`), and the Getting Started steps School
/// has. The history is on Trends (the School daily summary); the Jamf Pro Overview's cards
/// have nothing to read on School.
struct SchoolOverviewView: View {
    @Environment(WorkspaceStore.self) private var workspace
    @Environment(\.colorSchemeContrast) private var contrast
    @State private var snapshot: SchoolFleetService.Snapshot = .empty
    @State private var checklist: GettingStartedChecklist?
    /// The `dataSource` `snapshot` and `checklist` were read for; the content waits for it to
    /// match.
    @State private var loadedSource: String?
    @State private var reloads = 0

    private var staleDays: Int { Int(workspace.configState.staleDeviceDays) ?? 30 }

    var body: some View {
        PageScaffold {
            PageHeader(
                kicker: "Jamf School",
                title: "Overview",
                subtitle: workspace.profile,
                lastModified: snapshot.collectedAt
            )
            if loadedSource != dataSource {
                ScreenLoadingCard(what: "overview")
            } else {
                if let checklist, !checklist.isComplete {
                    GettingStartedCard(checklist: checklist, onAction: perform)
                }
                if snapshot.devicesDate != nil {
                    SchoolDeviceTiles(snapshot: snapshot, staleDays: staleDays)
                }
                if !snapshot.overview.isEmpty { resourcesCard }
                if !snapshot.isDetected { emptyState }
            }
        }
        .tint(Theme.Colors.goldBright)
        .task(id: "\(dataSource)|\(reloads)") { await load() }
        .onReceive(NotificationCenter.default.publisher(for: .refreshActiveTab)) { _ in
            reloads += 1
        }
    }

    private var emptyState: some View {
        Card(padding: 24) {
            EmptyStateView(
                systemImage: "graduationcap",
                title: "No Jamf School data yet",
                message: "Collect from Jamf School to see its devices, users and classes here."
            )
        }
    }

    /// One tile per line `jamf-cli school overview` prints, in its order.
    private var resourcesCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                SectionHeader(title: "In Jamf School")
                EqualHeightTileGrid(minTileWidth: 160) {
                    ForEach(snapshot.overview) { row in
                        StatTile(label: row.resource, value: row.value.isEmpty ? "—" : row.value,
                                 sub: row.section == row.resource ? nil : row.section,
                                 fillsHeight: true)
                    }
                }
            }
        }
    }

    // MARK: - Loading

    /// Changes when the profile does, and when demo mode flips under the same profile name.
    private var dataSource: String { "\(workspace.demoMode)|\(workspace.profile)" }

    /// Decodes off the main thread; the task is cancelled when `dataSource` or `reloads` changes.
    private func load() async {
        let source = dataSource
        if loadedSource != source { loadedSource = nil; snapshot = .empty; checklist = nil }
        let profile = workspace.profile
        guard !workspace.demoMode, ProfileService.isValid(profile) else {
            loadedSource = source
            return
        }
        let connected = !workspace.profiles.isEmpty
        guard let (loaded, scheduled, reported) = await ScreenLoad.paint(
            stillCurrent: { source == dataSource },
            read: {
                let loaded = SchoolFleetService.load(profile: profile)
                let hasAgent = ScheduleStore().load().map { $0.toSchedule() }
                    .contains { $0.profile == profile }
                let policy = AutomationPolicy.current()
                let scheduled = scheduleCovered(
                    hasAgent: hasAgent, policyIsManaged: policy.isManaged,
                    excluded: policy.excludedWorkspaces.contains(profile))
                let reported = !ReportLibrary().list(profile: profile).isEmpty
                return (loaded, scheduled, reported)
            }
        ) else { return }
        snapshot = loaded
        checklist = .buildSchool(
            connected: connected, collected: loaded.isDetected,
            scheduled: scheduled, reported: reported)
        loadedSource = source
    }

    private func perform(_ step: GettingStartedStep) {
        switch step.kind {
        case .collect:
            Task {
                await workspace.runFirstCollect()
                reloads += 1
            }
        default:
            NotificationCenter.default.post(
                name: .navigateToTab, object: nil,
                userInfo: ["tab": step.destinationTab])
        }
    }
}
