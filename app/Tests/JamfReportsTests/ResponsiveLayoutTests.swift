import Testing
@testable import JamfReports

/// Sanity tests for the responsive window sizing constants introduced in Task 4.
struct ResponsiveLayoutTests {

    /// The minimum supported width must be ≤960 pt to fit a 13" MacBook at native
    /// resolution and satisfy WCAG 1.4.10 Reflow at 200% Dynamic Type.
    @Test func minSupportedWidthIsAtMost960() {
        #expect(JamfReportsApp.minSupportedWidth <= 960)
    }

    /// Guard against accidentally regressing to the old 1200 pt minimum.
    @Test func minSupportedWidthIsNotLegacyValue() {
        #expect(JamfReportsApp.minSupportedWidth != 1200)
    }

    /// The constant must be a positive, usable width.
    @Test func minSupportedWidthIsPositive() {
        #expect(JamfReportsApp.minSupportedWidth > 0)
    }
}
