import SwiftUI

/// Stands in for a screen's content while its snapshot decodes off the main thread, so the
/// empty state never shows for data that is only late.
struct ScreenLoadingCard: View {
    let what: String
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        Card(padding: 24) {
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                    .accessibilityLabel("Loading \(what)")
                Text("Loading \(what)…")
                    .font(.footnote)
                    .foregroundStyle(Theme.Text.tertiary(contrast))
            }
        }
    }
}
