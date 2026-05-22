import SwiftUI

// MARK: - Theme semantic layers
//
// These aliases map logical roles to the dark-mode palette defined in Theme.swift.
// Views should reference these rather than raw color values so light-mode and any
// future tint overrides only need to change this file.
//
// WCAG 2.2 contrast ratios (dark-mode; all computed against the standard dark surfaces):
//
//   Text on winBG (#1D1D1F):
//     fg  (#F2F2F7)    — 15.08:1  passes AA + AAA (7:1)
//     fg2 (#D8D8DD)    — 11.85:1  passes AA + AAA
//     fgMuted (#8E8E93) —  5.16:1  passes AA Normal (4.5:1); FAILS Large-text-only threshold
//     fgDisabled (#8A8A90) — 4.90:1  passes AA Normal; intended for non-essential chrome
//
//   Text on winBG2 (#232326):
//     fg  (#F2F2F7)    — 14.05:1  passes AA + AAA
//     fg2 (#D8D8DD)    — 11.04:1  passes AA + AAA
//     fgMuted (#8E8E93) —  4.81:1  passes AA Normal (marginally)
//
//   Text on winBG3 (#2A2A2E):
//     fg  (#F2F2F7)    — 12.81:1  passes AA + AAA
//     fg2 (#D8D8DD)    — 10.06:1  passes AA + AAA
//     fgMuted (#8E8E93) —  4.38:1  FAILS AA Normal for body-size text; use only at 18pt+ or bold 14pt+
//
//   Code surface text on codeBG (#0E0F12):
//     fg2 (#D8D8DD)    — 13.49:1  passes AA + AAA
//     fgMuted (#8E8E93) —  5.88:1  passes AA Normal
//     dangerSoft (#FFA39A) — 10.00:1  passes AA + AAA (verified 2026-05-20; see item #9)
//     warnSoft (#FFCE7A) — 13.11:1  passes AA + AAA
//
//   Status on winBG:
//     ok (#30D158)     —  8.32:1  passes AA + AAA
//     warn (#FF9F0A)   —  8.19:1  passes AA + AAA
//     danger (#FF453A) —  4.94:1  passes AA Normal
//     dangerSoft (#FFA39A) — 8.78:1  passes AA + AAA
//     goldBright (#E8B614) — 8.92:1  passes AA + AAA
//
// Increase Contrast notes:
//   Under .increased, Theme.Text.tertiary() promotes fgMuted → fg2 (+6.69pp).
//   This ensures all body-copy tertiary text passes AA Normal even on winBG3 contexts.
//   Under .increased, Theme.Text.disabled() promotes fgDisabled → fgMuted (+0.26pp).
//   disabled() lands at fgMuted (4.38:1 on winBG3) — it remains sub-AA-Normal even when
//   increased, by design: disabled controls are exempt from WCAG SC 1.4.3. The AA-pass
//   guarantee above applies to tertiary() only, not disabled().

extension Theme {

    // MARK: Text

    /// Semantic text colors keyed by visual emphasis.
    enum Text {
        /// Primary content — headings, selected labels.
        static let primary:   Color = Theme.Colors.fg
        /// Secondary content — body copy, field values.
        static let secondary: Color = Theme.Colors.fg2

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
        /// Hover / pointer-over tint for nav items and interactive rows.
        static func hover(_ contrast: ColorSchemeContrast) -> Color {
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
    /// Scales with Dynamic Type off the `.title3` text style (15pt base).
    static let title: Font = .system(.title3, weight: .semibold)

    /// Standard body text — list rows, descriptions. Scales off `.body` (13pt base).
    static let bodyText: Font = .body

    /// Small label — field labels, captions above controls. Scales off `.callout` (12pt base).
    static let label: Font = .callout

    /// Fine caption — helper text, inline timestamps. Scales off the `.caption`
    /// text style with Dynamic Type.
    static let caption: Font = .caption

    /// Eyebrow / kicker — uppercase tracked monospaced label above titles.
    static let kicker: Font = .system(.caption, design: .monospaced).weight(.semibold)

    /// Display numeral for KPI values. Scales off `.title` (22pt base).
    /// Scales aggressively — consumers must size their container with
    /// `.frame(minWidth:)`, never `.frame(width:)`, to avoid clipping at
    /// large Dynamic Type sizes (see PR #118).
    static let metric: Font = .system(.title, design: .serif, weight: .semibold)

    /// Default-size monospaced body. Tests reference this property form;
    /// production callers prefer the `mono(_:weight:)` function variant.
    static let mono: Font = .system(.body, design: .monospaced)

    /// Caption-size monospaced. Used in inline timestamps, kicker badges.
    static let monoCaption: Font = .system(.caption, design: .monospaced)
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
