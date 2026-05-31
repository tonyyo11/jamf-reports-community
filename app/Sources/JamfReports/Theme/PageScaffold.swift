import SwiftUI

/// Standard scrollable page chrome.
///
/// Centralises the page-padding block that was copy-pasted into ~27 dashboard
/// views: a `ScrollView` wrapping a leading-aligned `VStack` padded with the
/// shared `Theme.Metrics.page*` constants. The header (`PageHeader`) scrolls
/// with the content, matching the long-standing behaviour of every dashboard.
///
/// Minimum supported content width is `PageScaffold.minSupportedWidth`; callers
/// must verify their content does not clip below it.
///
/// Usage:
/// ```swift
/// PageScaffold {
///     PageHeader(kicker: "Operations", title: "Patch Compliance")
///     if !workspace.demoMode { StaleDataBanner(source: snapshot.cacheSource) }
///     kpiGrid
///     patchTitlesCard
/// }
/// ```
@MainActor
struct PageScaffold<Content: View>: View {
    /// Narrowest content width the dashboards are expected to render at without
    /// clipping. Layout changes touching this component should be verified here.
    nonisolated static var minSupportedWidth: CGFloat { 640 }

    private let spacing: CGFloat
    private let content: Content

    /// - Parameters:
    ///   - spacing: Vertical spacing between stacked content blocks. Defaults to
    ///     20, the value every migrated dashboard used.
    ///   - content: The page body, including its `PageHeader`.
    init(spacing: CGFloat = 20, @ViewBuilder content: () -> Content) {
        self.spacing = spacing
        self.content = content()
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: spacing) {
                content
            }
            .padding(EdgeInsets(
                top: Theme.Metrics.pagePadTop,
                leading: Theme.Metrics.pagePadH,
                bottom: Theme.Metrics.pagePadBottom,
                trailing: Theme.Metrics.pagePadH
            ))
        }
    }
}
