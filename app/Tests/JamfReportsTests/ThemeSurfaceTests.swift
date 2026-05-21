import Testing
import SwiftUI
@testable import JamfReports

/// Smoke tests confirming that semantic surface and text role tokens resolve to
/// non-nil `Color` values at runtime.
///
/// SwiftUI `Color` is a value type, so "non-nil" here means the token can be
/// assigned to a typed variable without an optional unwrap.
struct ThemeSurfaceTests {

    // MARK: Surface roles

    @Test func baseTokenIsColor() {
        let c: Color = Theme.Surface.base
        _ = c
    }

    @Test func raisedTokenIsColor() {
        let c: Color = Theme.Surface.raised
        _ = c
    }

    @Test func inputTokenIsColor() {
        let c: Color = Theme.Surface.input
        _ = c
    }

    @Test func quietTokenIsColor() {
        let c: Color = Theme.Surface.quiet
        _ = c
    }

    @Test func interactiveTokenIsColor() {
        let c: Color = Theme.Surface.interactive
        _ = c
    }

    // MARK: Text roles

    @Test func textPrimaryIsColor() {
        let c: Color = Theme.Text.primary
        _ = c
    }

    @Test func textSecondaryIsColor() {
        let c: Color = Theme.Text.secondary
        _ = c
    }

    @Test func textTertiaryIsColor() {
        let c: Color = Theme.Text.tertiary(.standard)
        _ = c
    }

    @Test func textOnAccentIsColor() {
        let c: Color = Theme.Text.onAccent
        _ = c
    }

    // MARK: Button color tokens

    @Test func buttonGoldFGIsColor() {
        let c: Color = Theme.ButtonColors.goldFG
        _ = c
    }

    @Test func buttonDangerFGIsColor() {
        let c: Color = Theme.ButtonColors.dangerFG
        _ = c
    }
}
