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

        /// Accessibility-aware supporting text.
        static func tertiary(_ contrast: ColorSchemeContrast) -> Color {
            contrast == .increased ? Theme.Colors.fg2 : Theme.Colors.fgMuted
        }
        /// Accessibility-aware disabled state.
        static func disabled(_ contrast: ColorSchemeContrast) -> Color {
            contrast == .increased ? Theme.Colors.fgMuted : Theme.Colors.fgDisabled
        }
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

        /// Accessibility-aware higher-elevation chips and popovers.
        static func high(_ contrast: ColorSchemeContrast) -> Color {
            Color.white.opacity(contrast == .increased ? 0.14 : 0.08)
        }
        /// Accessibility-aware interactive element fill.
        static func interactive(_ contrast: ColorSchemeContrast) -> Color {
            Color.white.opacity(contrast == .increased ? 0.20 : 0.12)
        }
        /// Accessibility-aware text field / input background.
        static func input(_ contrast: ColorSchemeContrast) -> Color {
            Color.white.opacity(contrast == .increased ? 0.10 : 0.05)
        }
    }

    // MARK: Hairline

    /// Semantic separator colors.
    enum Hairline {
        /// Standard 0.5pt divider between sections.
        static let standard: Color = Theme.Colors.hairline
        /// Stronger 1pt divider used around cards.
        static let strong:   Color = Theme.Colors.hairlineStrong

        /// Accessibility-aware standard divider.
        static func standard(_ contrast: ColorSchemeContrast) -> Color {
            contrast == .increased ? Theme.Colors.hairlineStrong : Theme.Colors.hairline
        }
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

// MARK: - Severity semantic palette

extension Theme {
    enum Severity {
        case critical, high, medium, low

        /// In-app dark-mode color, matched to Pill tones below.
        var inApp: Color {
            switch self {
            case .critical: Theme.Colors.danger       // 0xFF453A
            case .high:     Theme.Colors.warn         // 0xFF9F0A
            case .medium:   Theme.Colors.goldBright   // 0xE8B614
            case .low:      Theme.Colors.teal         // 0x2A6B6B
            }
        }

        /// Light-canvas export color (saturated, not neon on #F8FAFC).
        var export: Color {
            switch self {
            case .critical: Color(hex: 0xDC2626)
            case .high:     Color(hex: 0xD97706)
            case .medium:   Color(hex: 0xCA8A04)
            case .low:      Color(hex: 0x0891B2)
            }
        }

        /// Map to existing Pill tone so chips match bars.
        var pillTone: Pill.Tone {
            switch self {
            case .critical: .danger
            case .high:     .warn
            case .medium:   .gold
            case .low:      .teal
            }
        }

        /// SF Symbol icon for color-blind-safe redundancy.
        var systemImage: String {
            switch self {
            case .critical: "exclamationmark.triangle.fill"
            case .high:     "exclamationmark.circle.fill"
            case .medium:   "info.circle.fill"
            case .low:      "circle.fill"
            }
        }
    }
}

// MARK: - Chart palette semantic tokens

extension Theme {
    enum ChartPalette {
        /// Ordered palette for OS version distributions. Read at small slice sizes
        /// in both dark in-app and light export canvases.
        static let osVersionInApp: [Color] = [
            Theme.Colors.goldBright,     // 0xE8B614
            Theme.Colors.teal,           // 0x2A6B6B - promote existing teal token
            Color(hex: 0x7DA3F9),        // soft blue
            Color(hex: 0xC58AF9),        // soft purple
            Color(hex: 0xF98AA3),        // soft pink
            Color(hex: 0xF9C58A),        // soft orange
            Color(hex: 0x8AF9C5),        // soft mint
            Color(hex: 0xA8A8AD)         // neutral gray
        ]

        static let osVersionExport: [Color] = [
            Color(hex: 0xCA8A04),
            Color(hex: 0x0891B2),
            Color(hex: 0x2563EB),
            Color(hex: 0x7C3AED),
            Color(hex: 0xDB2777),
            Color(hex: 0xEA580C),
            Color(hex: 0x059669),
            Color(hex: 0x6B7280)
        ]
    }
}
