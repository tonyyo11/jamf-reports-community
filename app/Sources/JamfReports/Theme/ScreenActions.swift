import SwiftUI

extension WorkspaceStore {
    /// "Collect now" for an empty state that asks the person to collect, through the same
    /// tier refresh the banners use. Nil in demo mode, where nothing can be collected.
    func collectEmptyAction(tiers: Set<CollectionTier>) -> EmptyStateAction? {
        guard !demoMode else { return nil }
        return EmptyStateAction(label: L("Collect now"), icon: "arrow.down.circle") { [self] in
            Task {
                await runTierRefresh(tiers)
                NotificationCenter.default.post(name: .refreshActiveTab, object: nil)
            }
        }
    }
}

extension WorkspaceStore {
    /// "Collect now" for a Jamf School empty state: the first collect, which routes to School's
    /// own collect. Nil in demo mode.
    func firstCollectEmptyAction() -> EmptyStateAction? {
        guard !demoMode else { return nil }
        return EmptyStateAction(label: L("Collect now"), icon: "arrow.down.circle") { [self] in
            Task {
                await runFirstCollect()
                NotificationCenter.default.post(name: .refreshActiveTab, object: nil)
            }
        }
    }
}

/// A context-menu "Open in Jamf Pro" item: absent without a console URL, disabled in demo mode.
struct OpenInJamfProItem: View {
    @Environment(WorkspaceStore.self) private var workspace
    let url: URL?

    var body: some View {
        if let url {
            Button(L("Open in Jamf Pro")) { SystemActions.open(url) }
                .disabled(workspace.demoMode)
        }
    }
}
