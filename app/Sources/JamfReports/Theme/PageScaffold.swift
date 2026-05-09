import SwiftUI

/// Standard page chrome: a fixed header followed by a scrollable content region.
///
/// Centralises the six copy-pasted page-padding blocks that previously lived
/// in individual views. Lane C migrates call sites; this file just provides
/// the component.
///
/// Usage:
/// ```swift
/// PageScaffold {
///     PageHeader(kicker: "…", title: "…") { AnyView(EmptyView()) }
/// } content: {
///     Text("Body goes here")
/// }
/// ```
@MainActor
struct PageScaffold<Header: View, Content: View>: View {
    let header: Header
    let content: Content

    init(
        @ViewBuilder header: () -> Header,
        @ViewBuilder content: () -> Content
    ) {
        self.header = header()
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            ScrollView {
                content
                    .padding(.horizontal, Theme.Metrics.pagePadH)
                    .padding(.top, Theme.Metrics.pagePadTop)
                    .padding(.bottom, Theme.Metrics.pagePadBottom)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}
