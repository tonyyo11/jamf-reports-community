import XCTest
import SwiftUI
import AppKit
@testable import JamfReports

/// Tests that Theme.Surface, Theme.Text, and Theme.ButtonColors tokens correctly adapt
/// between light and dark macOS appearances. Ensures proper dynamism and WCAG contrast
/// compliance for accessibility.
@MainActor
class ThemeLightModeTests: XCTestCase {

    // MARK: - Dynamism Tests

    func testSurfaceTokensAreDynamic() {
        let lightAppearance = NSAppearance(named: .aqua)!
        let darkAppearance = NSAppearance(named: .darkAqua)!

        // Test each surface token resolves differently in light vs dark
        func testSurfaceDynamism(_ color: Color, name: String) {
            let lightRGBA = resolveColor(color, in: lightAppearance)
            let darkRGBA = resolveColor(color, in: darkAppearance)

            XCTAssertNotEqual(
                lightRGBA.r, darkRGBA.r,
                "\(name) should resolve to different colors in light vs dark mode"
            )
        }

        testSurfaceDynamism(Theme.Surface.base, name: "Surface.base")
        testSurfaceDynamism(Theme.Surface.raised, name: "Surface.raised")
        testSurfaceDynamism(Theme.Surface.input, name: "Surface.input")
        testSurfaceDynamism(Theme.Surface.quiet, name: "Surface.quiet")
        testSurfaceDynamism(Theme.Surface.interactive, name: "Surface.interactive")
    }

    func testTextTokensAreDynamic() {
        let lightAppearance = NSAppearance(named: .aqua)!
        let darkAppearance = NSAppearance(named: .darkAqua)!

        // Test each text token resolves differently in light vs dark
        func testTextDynamism(_ color: Color, name: String) {
            let lightRGBA = resolveColor(color, in: lightAppearance)
            let darkRGBA = resolveColor(color, in: darkAppearance)

            XCTAssertNotEqual(
                lightRGBA.r, darkRGBA.r,
                "\(name) should resolve to different colors in light vs dark mode"
            )
        }

        testTextDynamism(Theme.Text.primary, name: "Text.primary")
        testTextDynamism(Theme.Text.secondary, name: "Text.secondary")
        // tertiary is intentionally the same in both modes, so we skip it
    }

    // MARK: - Contrast Tests

    func testPrimaryTextOnBaseHasGoodContrast() {
        let lightAppearance = NSAppearance(named: .aqua)!
        let darkAppearance = NSAppearance(named: .darkAqua)!

        // Test light mode contrast
        let lightBase = resolveColor(Theme.Surface.base, in: lightAppearance)
        let lightText = resolveColor(Theme.Text.primary, in: lightAppearance)
        let lightRatio = contrastRatio(lightText, background: lightBase)

        XCTAssertGreaterThanOrEqual(
            lightRatio, 4.5,
            "Primary text on base surface should meet WCAG AA (4.5:1) in light mode, got \(lightRatio)"
        )

        // Test dark mode contrast
        let darkBase = resolveColor(Theme.Surface.base, in: darkAppearance)
        let darkText = resolveColor(Theme.Text.primary, in: darkAppearance)
        let darkRatio = contrastRatio(darkText, background: darkBase)

        XCTAssertGreaterThanOrEqual(
            darkRatio, 4.5,
            "Primary text on base surface should meet WCAG AA (4.5:1) in dark mode, got \(darkRatio)"
        )
    }

    func testPrimaryTextOnRaisedHasGoodContrast() {
        let lightAppearance = NSAppearance(named: .aqua)!
        let darkAppearance = NSAppearance(named: .darkAqua)!

        // Test light mode contrast
        let lightRaised = resolveColor(Theme.Surface.raised, in: lightAppearance)
        let lightText = resolveColor(Theme.Text.primary, in: lightAppearance)
        let lightRatio = contrastRatio(lightText, background: lightRaised)

        XCTAssertGreaterThanOrEqual(
            lightRatio, 4.5,
            "Primary text on raised surface should meet WCAG AA (4.5:1) in light mode, got \(lightRatio)"
        )

        // Test dark mode contrast
        let darkRaised = resolveColor(Theme.Surface.raised, in: darkAppearance)
        let darkText = resolveColor(Theme.Text.primary, in: darkAppearance)
        let darkRatio = contrastRatio(darkText, background: darkRaised)

        XCTAssertGreaterThanOrEqual(
            darkRatio, 4.5,
            "Primary text on raised surface should meet WCAG AA (4.5:1) in dark mode, got \(darkRatio)"
        )
    }

    // MARK: - High Contrast Support

    func testHighContrastModesResolve() {
        let hcLight = NSAppearance(named: .accessibilityHighContrastAqua)!
        let hcDark = NSAppearance(named: .accessibilityHighContrastDarkAqua)!

        // Ensure tokens can resolve in high contrast modes without crashing
        _ = resolveColor(Theme.Surface.base, in: hcLight)
        _ = resolveColor(Theme.Surface.base, in: hcDark)
        _ = resolveColor(Theme.Text.primary, in: hcLight)
        _ = resolveColor(Theme.Text.primary, in: hcDark)
        _ = resolveColor(Theme.ButtonColors.goldFG, in: hcLight)
        _ = resolveColor(Theme.ButtonColors.goldFG, in: hcDark)
    }

    // MARK: - Helper Functions

    /// Resolves a SwiftUI Color to RGBA components in the given NSAppearance.
    private func resolveColor(_ color: Color, in appearance: NSAppearance) -> (r: Double, g: Double, b: Double, a: Double) {
        let previousAppearance = NSAppearance.current
        NSAppearance.current = appearance
        defer { NSAppearance.current = previousAppearance }

        // Convert SwiftUI Color to NSColor to extract components
        let nsColor = NSColor(color)
        let rgbColor = nsColor.usingColorSpace(.deviceRGB)!

        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        rgbColor.getRed(&r, green: &g, blue: &b, alpha: &a)

        return (Double(r), Double(g), Double(b), Double(a))
    }

    /// Calculates the relative luminance of an RGBA color per WCAG guidelines.
    private func relativeLuminance(_ rgba: (r: Double, g: Double, b: Double, a: Double)) -> Double {
        func sRGBtoLin(_ val: Double) -> Double {
            return val <= 0.03928 ? val / 12.92 : pow((val + 0.055) / 1.055, 2.4)
        }

        let rLin = sRGBtoLin(rgba.r)
        let gLin = sRGBtoLin(rgba.g)
        let bLin = sRGBtoLin(rgba.b)

        return 0.2126 * rLin + 0.7152 * gLin + 0.0722 * bLin
    }

    /// Calculates the WCAG contrast ratio between foreground and background colors.
    private func contrastRatio(_ foreground: (r: Double, g: Double, b: Double, a: Double),
                              background: (r: Double, g: Double, b: Double, a: Double)) -> Double {
        let l1 = relativeLuminance(foreground)
        let l2 = relativeLuminance(background)

        let lighter = max(l1, l2)
        let darker = min(l1, l2)

        return (lighter + 0.05) / (darker + 0.05)
    }
}