import SwiftUI
import Sparkle

/// Sparkle "Check for Updates…" menu item. Tracks SPUUpdater.canCheckForUpdates
/// so the menu item is greyed out while a check is already in flight.
///
/// Pattern is the canonical one from the Sparkle SwiftUI docs.
struct CheckForUpdatesView: View {
    @ObservedObject private var viewModel: CheckForUpdatesViewModel
    private let updater: SPUUpdater

    init(updater: SPUUpdater) {
        self.updater = updater
        self.viewModel = CheckForUpdatesViewModel(updater: updater)
    }

    var body: some View {
        Button("Check for Updates…", action: updater.checkForUpdates)
            .disabled(!viewModel.canCheckForUpdates)
    }
}

/// Bridges SPUUpdater's KVO-published `canCheckForUpdates` into Combine for
/// SwiftUI consumption. `@MainActor`-isolated because the underlying
/// `SPUUpdater.canCheckForUpdates` is itself main-actor-isolated under Swift 6
/// strict concurrency.
@MainActor
private final class CheckForUpdatesViewModel: ObservableObject {
    @Published var canCheckForUpdates = false

    init(updater: SPUUpdater) {
        updater.publisher(for: \.canCheckForUpdates)
            .assign(to: &$canCheckForUpdates)
    }
}
