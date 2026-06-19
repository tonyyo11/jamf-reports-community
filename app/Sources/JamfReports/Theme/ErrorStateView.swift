import SwiftUI

/// True read/operation failure (corrupt file, permission denied, decode error) —
/// distinct from a legitimate "no data yet" empty state. Defaults a warning glyph
/// and an optional Retry action. Reuses `EmptyStateView`'s layout (one source of truth).
struct ErrorStateView: View {
    let title: String
    let message: String
    let commands: [String]
    let systemImage: String
    let retry: (@MainActor () -> Void)?

    init(title: String, message: String, commands: [String] = [],
         systemImage: String = "exclamationmark.triangle", retry: (@MainActor () -> Void)? = nil) {
        self.title = title
        self.message = message
        self.commands = commands
        self.systemImage = systemImage
        self.retry = retry
    }

    var body: some View {
        EmptyStateView(
            systemImage: systemImage,
            title: title,
            message: message,
            commands: commands,
            primaryAction: retry.map {
                EmptyStateAction(label: "Retry", icon: "arrow.clockwise", action: $0)
            }
        )
    }

    /// Test seam: fire the retry action without a rendered button.
    @MainActor func invokeRetryForTesting() { retry?() }
}
