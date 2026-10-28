import CoreGraphics
import Foundation

/// The one mapping from a charted thing to a colour, so a macOS version, a metric, a patch
/// title or a compliance band is the same colour on every screen and in every report.
///
/// - Metrics and bands have a fixed colour each. A metric never uses a status colour
///   (`Theme.Colors.ok`, `warn`, `danger`); a band is the one fixed colour on both schemes.
/// - Versions and titles are not a closed set, so a key's colour comes from a hash of the key
///   (`slotIndexes`), which is stable across runs and unaffected by which other keys exist,
///   except that two keys charted together never share a slot while a free one remains.
/// - `dark` is the in-app card and the HTML report's dark theme; `light` is the workbook's PNG
///   charts, the exported images and the HTML report's light theme.
enum ChartPalette {
    enum Scheme: Sendable { case dark, light }

    /// What a key names, so a version and a title with the same text do not share a hash.
    enum Kind: String, Sendable { case version, title }

    private struct Slot { let dark: UInt32; let light: UInt32 }

    // Each pair has its relative luminance targeted at 0.34 (dark) and 0.15 (light), which
    // keeps 4.5:1 against every surface in `ChartPaletteTests.darkSurfaces` / `lightSurfaces`.
    private static let slots: [Slot] = [
        Slot(dark: 0xC59616, light: 0x88680F),  // gold
        Slot(dark: 0x25B09E, light: 0x1A7A6D),  // teal
        Slot(dark: 0x67A0EE, light: 0x1867D7),  // blue
        Slot(dark: 0xBA89E6, light: 0x9242D7),  // purple
        Slot(dark: 0xE779B9, light: 0xC72383),  // pink
        Slot(dark: 0xEF7F35, light: 0xB14F0E),  // orange
        Slot(dark: 0x2DB44F, light: 0x1F7D36),  // green
        Slot(dark: 0x909FB2, light: 0x5D6E85),  // slate
        Slot(dark: 0x11ABD2, light: 0x0C7590),  // cyan
        Slot(dark: 0x9B95E8, light: 0x6459DC),  // indigo
        Slot(dark: 0xBB9773, light: 0x896542),  // tan
        Slot(dark: 0x88A924, light: 0x5E7419),  // lime
    ]

    static var slotCount: Int { slots.count }

    static func hex(slot: Int, scheme: Scheme) -> UInt32 {
        let entry = slots[((slot % slots.count) + slots.count) % slots.count]
        return scheme == .dark ? entry.dark : entry.light
    }

    // MARK: Bands

    /// One colour per band, the same on both schemes: luminance 0.235 holds 3:1 against the
    /// lightest dark surface and the darkest light one. Pass is green and High is red; the
    /// workbook donut, the Compliance screen and the Trends band chart all read these.
    static func hex(forBand band: ComplianceBandingService.Band) -> UInt32 {
        switch band {
        case .pass:   return 0x26984C
        case .low:    return 0x2A85EE
        case .medLow: return 0xA4810D
        case .medium: return 0xCF6911
        case .high:   return 0xEA5041
        case .noData: return neutralHex
        }
    }

    /// "Other", "Unknown" and No Data: a grey that is no entity's colour.
    static let neutralHex: UInt32 = 0x85858C

    // MARK: Metrics

    /// Each metric's slot. A mobile metric shares its Mac counterpart's slot (the Mobile
    /// screens mirror the Computers ones), and no screen plots both in one chart. No default,
    /// so a new metric needs a decision here.
    static func hex(forMetric metric: TrendSeries.Metric, scheme: Scheme) -> UInt32 {
        switch metric {
        case .stability:                          return hex(slot: 0, scheme: scheme)
        case .compliance, .mscpBandTrend:         return hex(slot: 1, scheme: scheme)
        case .osCurrent, .mobileOSCurrent:        return hex(slot: 2, scheme: scheme)
        case .patch:                              return hex(slot: 3, scheme: scheme)
        case .securityScore, .mobileJailbroken:   return hex(slot: 4, scheme: scheme)
        case .stale, .mobileStale:                return hex(slot: 5, scheme: scheme)
        case .fileVault, .mobilePasscode:         return hex(slot: 6, scheme: scheme)
        case .managedDevices, .mobileManaged:     return hex(slot: 7, scheme: scheme)
        case .edrAgent:                           return hex(slot: 8, scheme: scheme)
        case .sip, .mobileDataProtection:         return hex(slot: 9, scheme: scheme)
        case .gatekeeper:                         return hex(slot: 10, scheme: scheme)
        case .firewall, .mobileSupervised:        return hex(slot: 11, scheme: scheme)
        case .activeDevices:                      return neutralHex
        case .agent(let name):
            // shortcut: agents hash alone, so two agents can share a slot; upgrade if a
            // workspace names more than a handful.
            let slot = Int(fnv1a("agent:" + normalized(name)) % UInt64(slots.count))
            return hex(slot: slot, scheme: scheme)
        }
    }

    // MARK: Versions and titles

    static func hex(forVersion version: String, scheme: Scheme) -> UInt32 {
        hexes(for: .version, keys: [version], scheme: scheme)[0]
    }

    static func hex(forTitle title: String, scheme: Scheme) -> UInt32 {
        hexes(for: .title, keys: [title], scheme: scheme)[0]
    }

    /// The colours of the keys one chart draws, in the order given. "Other (3 versions)" and
    /// the like are `neutralHex`. Keys that read as one entity ("26.7", "macOS 26.7.0") get
    /// one colour.
    static func hexes(for kind: Kind, keys: [String], scheme: Scheme) -> [UInt32] {
        let names = keys.map { normalized($0, kind: kind) }
        let assigned = slotIndexes(kind: kind, names: names)
        return names.map { name in
            assigned[name].map { hex(slot: $0, scheme: scheme) } ?? neutralHex
        }
    }

    /// Each distinct key's slot: its hash, or the next free slot when another key in this set
    /// already holds it. Keys are placed in sorted order so one set always resolves the same
    /// way. Past `slots.count` keys the slots repeat. An "Other" key has no entry.
    private static func slotIndexes(kind: Kind, names: [String]) -> [String: Int] {
        var result: [String: Int] = [:]
        var taken = Set<Int>()
        for name in Set(names).sorted() {
            guard !name.hasPrefix("other") else { continue }
            var slot = Int(fnv1a(kind.rawValue + ":" + name) % UInt64(slots.count))
            if taken.count < slots.count {
                while taken.contains(slot) { slot = (slot + 1) % slots.count }
            }
            taken.insert(slot)
            result[name] = slot
        }
        return result
    }

    /// A version without its product word and trailing ".0" ("macOS 26.7.0" is "26.7"); any
    /// other text is trimmed and lowercased.
    private static func normalized(_ key: String, kind: Kind) -> String {
        let text = normalized(key)
        // "Other (3 versions)" has digits to strip but names no version.
        guard kind == .version, !text.hasPrefix("other"), let digit = text.firstIndex(where: \.isNumber) else { return text }
        return OSVersionName.normalized(String(text[digit...]))
    }

    private static func normalized(_ key: String) -> String {
        key.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// `hashValue` is seeded per process; a colour must not change between runs.
    private static func fnv1a(_ text: String) -> UInt64 {
        text.utf8.reduce(14_695_981_039_346_656_037) { ($0 ^ UInt64($1)) &* 1_099_511_628_211 }
    }

    // MARK: CoreGraphics

    static func cgColor(hex: UInt32) -> CGColor {
        CGColor(red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }

    /// A metric's colour on the workbook's white PNG canvas.
    static func cgColor(forMetric metric: TrendSeries.Metric, scheme: Scheme = .light) -> CGColor {
        cgColor(hex: hex(forMetric: metric, scheme: scheme))
    }

    /// Band colours for the mSCP/STIG donut and band trend. Order: Pass, Low, Med-Low, Medium,
    /// High (no No-Data: a stacked trend has no area for it).
    static let complianceBandColors: [CGColor] =
        [ComplianceBandingService.Band.pass, .low, .medLow, .medium, .high]
            .map { cgColor(hex: hex(forBand: $0)) }

    static let noDataColor: CGColor = cgColor(hex: neutralHex)

    /// The five band colours plus No-Data grey, for the donut.
    static var complianceBandColorsWithNoData: [CGColor] { complianceBandColors + [noDataColor] }
}
