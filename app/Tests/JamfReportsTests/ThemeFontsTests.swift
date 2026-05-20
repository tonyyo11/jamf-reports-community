import Testing
import SwiftUI
@testable import JamfReports

/// Compile-time and runtime smoke tests for the semantic font ramp added in Theme.Fonts.
///
/// A font token that "resolves without crashing" is sufficient — SwiftUI lazily resolves
/// fonts and there is no public API to inspect the internal representation at test time.
struct ThemeFontsTests {

    // MARK: Semantic token existence (compile-time checks)
    //
    // If any of these properties are removed or renamed, this test file fails to compile,
    // which is the intended signal.

    @Test func kickerTokenExists() {
        let font: Font = Theme.Fonts.kicker
        _ = font
    }

    @Test func metricTokenExists() {
        let font: Font = Theme.Fonts.metric
        _ = font
    }

    @Test func titleTokenExists() {
        let font: Font = Theme.Fonts.title
        _ = font
    }

    @Test func bodyTextTokenExists() {
        let font: Font = Theme.Fonts.bodyText
        _ = font
    }

    @Test func labelTokenExists() {
        let font: Font = Theme.Fonts.label
        _ = font
    }

    @Test func captionTokenExists() {
        let font: Font = Theme.Fonts.caption
        _ = font
    }

    @Test func monoTokenExists() {
        let font: Font = Theme.Fonts.mono
        _ = font
    }

    @Test func monoCaptionTokenExists() {
        let font: Font = Theme.Fonts.monoCaption
        _ = font
    }

    // MARK: Function-form helpers still resolve

    @Test func monoFunctionResolves() {
        let font = Theme.Fonts.mono(12, weight: .semibold)
        _ = font
    }

    @Test func serifFunctionResolves() {
        let font = Theme.Fonts.serif(26, weight: .bold)
        _ = font
    }

    @Test func bodyFunctionResolves() {
        let font = Theme.Fonts.body(13, weight: .regular)
        _ = font
    }
}
