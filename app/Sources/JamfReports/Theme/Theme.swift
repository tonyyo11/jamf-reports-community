import SwiftUI

/// Patch Notes & Progress design tokens applied on top of macOS Tahoe HIG dark mode.
///
/// PN&P brand bleeds in subtly: gold accent only on CTAs, active states, and key
/// callouts; IBM Plex Mono for tracked uppercase labels and stdout/code; Source Serif
/// for page H1s and KPI numbers. Body remains San Francisco.
enum Theme {

    // MARK: Colors

    enum Colors {
        // Brand
        static let gold        = Color(hex: 0xC9970A)
        static let goldBright  = Color(hex: 0xE8B614)
        static let goldDim     = Color(hex: 0x8E6B06)
        static let teal        = Color(hex: 0x2A6B6B)
        static let tealBright  = Color(hex: 0x3A8A8A)

        // Tahoe dark surfaces
        static let winBG       = Color(hex: 0x1D1D1F)
        static let winBG2      = Color(hex: 0x232326)
        static let winBG3      = Color(hex: 0x2A2A2E)
        static let titlebar    = Color(hex: 0x28282C, opacity: 0.72)
        static let codeBG      = Color(hex: 0x0E0F12)

        // Text
        static let fg          = Color(hex: 0xF2F2F7)
        static let fg2         = Color(hex: 0xD8D8DD)
        static let fgMuted     = Color(hex: 0x8E8E93)
        static let fgDisabled  = Color(hex: 0x5A5A60)

        // Hairlines
        static let hairline       = Color.white.opacity(0.07)
        static let hairlineStrong = Color.white.opacity(0.12)

        // Status
        static let danger      = Color(hex: 0xFF453A)
        static let warn        = Color(hex: 0xFF9F0A)
        static let ok          = Color(hex: 0x30D158)
        static let info        = Color(hex: 0x0A84FF)
        static let purple      = Color(hex: 0xBF5AF2)
    }

    // MARK: Typography

    enum Fonts {
        /// IBM Plex Mono — tracked uppercase labels, stdout, code, profile ids.
        static func mono(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
            // Falls back to SF Mono if the bundled TTFs aren't registered yet.
            .custom("IBM Plex Mono", size: size).weight(weight)
        }

        /// Source Serif 4 / Playfair Display — page H1s + numeric KPIs.
        /// macOS bundles New York which is a perfectly good serif fallback.
        static func serif(_ size: CGFloat, weight: Font.Weight = .bold) -> Font {
            .system(size: size, weight: weight, design: .serif)
        }

        /// SF default body.
        static func body(_ size: CGFloat = 13, weight: Font.Weight = .regular) -> Font {
            .system(size: size, weight: weight)
        }
    }

    // MARK: Metrics

    enum Metrics {
        static let pagePadH: CGFloat = 28
        static let pagePadTop: CGFloat = 24
        static let pagePadBottom: CGFloat = 32
        static let cardRadius: CGFloat = 10
        static let largeCardRadius: CGFloat = 14
        static let buttonRadius: CGFloat = 6
        static let sidebarWidthExpanded: CGFloat = 232
        static let sidebarWidthCompact: CGFloat = 64
        static let titlebarHeight: CGFloat = 38
    }
}

// MARK: - Color hex helper

extension Color {
    init(hex: UInt32, opacity: Double = 1) {
        let r = Double((hex >> 16) & 0xFF) / 255
        let g = Double((hex >>  8) & 0xFF) / 255
        let b = Double( hex        & 0xFF) / 255
        self.init(.sRGB, red: r, green: g, blue: b, opacity: opacity)
    }
}

// MARK: - Font registration

/// Register bundled TTF fonts on app launch. SwiftUI's `.custom("IBM Plex Mono", …)`
/// resolves correctly only when the TTFs are registered with Core Text.
enum FontRegistry {
    static func registerBundledFonts() {
        let names = [
            "IBMPlexMono-Regular",
            "IBMPlexMono-Medium",
            "IBMPlexMono-SemiBold",
            "IBMPlexMono-Bold",
        ]
        for name in names {
            guard let url = Bundle.module.url(forResource: name, withExtension: "ttf") else { continue }
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        }
    }
}
