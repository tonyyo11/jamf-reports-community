import Testing
import SwiftUI
@testable import JamfReports

/// Smoke test confirming PageScaffold compiles and instantiates without crashing.
///
/// SwiftUI views cannot be rendered in unit tests without a host; this test only
/// verifies that the view tree can be constructed — sufficient to catch API breaks.
@MainActor
struct PageScaffoldTests {

    @Test func scaffoldInstantiatesWithTextContent() {
        let view = PageScaffold {
            Text("Header")
        } content: {
            Text("Body content")
        }
        // If PageScaffold's initialiser or body property compiles and executes,
        // the view tree construction succeeds.
        _ = view
    }

    @Test func scaffoldInstantiatesWithEmptyViews() {
        let view = PageScaffold {
            EmptyView()
        } content: {
            EmptyView()
        }
        _ = view
    }

    @Test func metricsTokensUsedByScaffoldExist() {
        // Regression guard: PageScaffold reads these three metric constants.
        // If the constants are removed or renamed the test file won't compile.
        let h: CGFloat   = Theme.Metrics.pagePadH
        let top: CGFloat = Theme.Metrics.pagePadTop
        let bot: CGFloat = Theme.Metrics.pagePadBottom
        #expect(h > 0)
        #expect(top > 0)
        #expect(bot > 0)
    }
}
