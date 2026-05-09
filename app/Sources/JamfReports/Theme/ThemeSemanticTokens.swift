import SwiftUI

// MARK: - Theme semantic layers
//
// These aliases map logical roles to the dark-mode palette defined in Theme.swift.
// Views should reference these rather than raw color values so light-mode and any
// future tint overrides only need to change this file.

extension Theme {

    // MARK: Text

    /// Semantic text colors keyed by visual emphasis.
    enum Text {
        /// Primary content — headings, selected labels.
        static let primary:   Color = Theme.Colors.fg
        /// Secondary content — body copy, field values.
        static let secondary: Color = Theme.Colors.fg2
        /// Supporting / de-emphasized text — labels, captions, placeholder.
        static let tertiary:  Color = Theme.Colors.fgMuted
        /// Disabled state.
        static let disabled:  Color = Theme.Colors.fgDisabled
    }

    // MARK: Surface

    /// Semantic surface fills keyed by elevation / function.
    enum Surface {
        /// Window background (lowest layer).
        static let base:        Color = Theme.Colors.winBG
        /// Slightly raised cards and panels.
        static let raised:      Color = Theme.Colors.winBG2
        /// Quiet / inset regions (sidebar trays, code blocks).
        static let quiet:       Color = Theme.Colors.winBG3
        /// Higher-elevation chips and popovers.
        static let high:        Color = Color.white.opacity(0.08)
        /// Interactive element fill (segment control, toggle track).
        static let interactive: Color = Color.white.opacity(0.12)
        /// Text field / input background.
        static let input:       Color = Color.white.opacity(0.05)
    }

    // MARK: Hairline

    /// Semantic separator colors.
    enum Hairline {
        /// Standard 0.5pt divider between sections.
        static let standard: Color = Theme.Colors.hairline
        /// Stronger 1pt divider used around cards.
        static let strong:   Color = Theme.Colors.hairlineStrong
    }

    // MARK: ButtonColors

    /// Foreground colors used on top of brand-colored button fills.
    enum ButtonColors {
        /// Foreground text on the gold (`.gold` style) button.
        static let goldFG: Color = Color(hex: 0x3B2A04)
        /// Foreground text on the danger (`.danger` style) button.
        static let dangerFG: Color = Color(hex: 0xFF453A)
    }
}

extension Theme.Text {
    /// Foreground used on top of an accent-colored fill (e.g. selected sidebar
    /// rows). Stays legible against gold or system-tint accents.
    static let onAccent: Color = Color.white
}

// MARK: - Theme.Fonts semantic additions

extension Theme.Fonts {

    /// Large display title — section headings inside modals and wizards.
    static let title: Font = .system(size: 15, weight: .semibold)

    /// Standard body text — list rows, descriptions.
    static let bodyText: Font = .system(size: 13)

    /// Small label — field labels, captions above controls.
    static let label: Font = .system(size: 12)

    /// Fine caption — helper text, inline timestamps.
    static let caption: Font = .system(size: 11)

    /// Eyebrow / kicker — uppercase tracked monospaced label above titles.
    static let kicker: Font = .system(.caption, design: .monospaced).weight(.semibold)

    /// Display numeral for KPI values.
    static let metric: Font = .system(size: 22, weight: .semibold, design: .serif)

    /// Default-size monospaced body. Tests reference this property form;
    /// production callers prefer the `mono(_:weight:)` function variant.
    static let mono: Font = .system(size: 13, weight: .regular, design: .monospaced)

    /// Caption-size monospaced. Used in inline timestamps, kicker badges.
    static let monoCaption: Font = .system(size: 11, weight: .regular, design: .monospaced)
}

// MARK: - Theme.Metrics semantic additions

extension Theme.Metrics {

    /// Corner radius for text fields and inline input elements.
    static let fieldRadius: CGFloat = 6

    /// Corner radius for profile/workspace chip surfaces.
    static let chipRadius: CGFloat = 8
}
