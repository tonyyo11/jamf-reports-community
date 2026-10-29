import CoreGraphics
import Foundation

/// The one mapping from a charted thing to a colour, so a macOS version, a metric, a patch
/// title or a compliance band is the same colour on every screen and in every report.
///
/// A key's colour depends on the key alone, never on what else is charted:
/// - Metrics and bands have a fixed colour each. A metric never uses a status colour
///   (`Theme.Colors.ok`, `warn`, `danger`); a band is the one fixed colour on both schemes.
/// - A version's hue is its release (majors 11 to 15 and 26 to 28 never share one) and its
///   shade steps with the minor and patch number, so 26.6 and 26.7 are two shades of one hue.
///   "macOS 26.7" and "iOS 26.7" are one key on purpose: the numbers are one release train and
///   no chart draws both.
/// - A patch title or an agent hashes (FNV-1a) into a slot and shade. Two titles in one chart
///   can share a colour; the chart's labels, not its colours, name each one.
/// - `dark` is the in-app card and the HTML report's dark theme; `light` is the workbook's PNG
///   charts, the exported images and the HTML report's light theme.
enum ChartPalette {
    enum Scheme: Sendable { case dark, light }

    /// What a key names, so a version and a title with the same text do not share a hash.
    enum Kind: String, Sendable { case version, title }

    /// Three shades of one hue per scheme; shade 0 is the base that metrics use. Each shade is
    /// held to 4.5:1 on its scheme's surfaces by `ChartPaletteTests`: dark steps lighter
    /// (relative luminance 0.34, 0.46, 0.60), light steps darker (0.15, 0.09, 0.045).
    private struct Slot { let dark: [UInt32]; let light: [UInt32] }

    static let shadeCount = 3

    private static let slots: [Slot] = [
        Slot(dark: [0xC59616, 0xE2AC19, 0xEDC760], light: [0x88680F, 0x6A510C, 0x4B3A08]),  // gold
        Slot(dark: [0x25B09E, 0x2BC9B4, 0x66DECE], light: [0x1A7A6D, 0x146055, 0x0E443C]),  // teal
        Slot(dark: [0x67A0EE, 0x8DB8F2, 0xB0CEF6], light: [0x1867D7, 0x1351A9, 0x0E3B7A]),  // blue
        Slot(dark: [0xBA89E6, 0xCBA6EC, 0xDBC1F2], light: [0x9242D7, 0x7628BB, 0x551C86]),  // purple
        Slot(dark: [0xE779B9, 0xED9CCB, 0xF3BCDC], light: [0xC72383, 0x9E1C67, 0x71144A]),  // pink
        Slot(dark: [0xEF7F35, 0xF3A36D, 0xF7C19C], light: [0xB14F0E, 0x8B3E0B, 0x632C08]),  // orange
        Slot(dark: [0x2DB44F, 0x3DCF61, 0x81E099], light: [0x1F7D36, 0x18622B, 0x11451E]),  // green
        Slot(dark: [0x909FB2, 0xABB6C4, 0xC5CCD7], light: [0x5D6E85, 0x485568, 0x333C4A]),  // slate
        Slot(dark: [0x11ABD2, 0x22C4ED, 0x71DAF4], light: [0x0C7590, 0x095D71, 0x074150]),  // cyan
        Slot(dark: [0x9B95E8, 0xB3AEEE, 0xCAC7F3], light: [0x6459DC, 0x4639D5, 0x2E23A5]),  // indigo
        Slot(dark: [0xBB9773, 0xCCB094, 0xDCC9B5], light: [0x896542, 0x6B5034, 0x4C3825]),  // tan
        Slot(dark: [0x88A924, 0x9CC229, 0xB6D94B], light: [0x5E7419, 0x495C13, 0x34410E]),  // lime
    ]

    /// Hues no metric uses, so an agent series never shares a colour with a metric on a chart.
    // shortcut: 4 hues x 3 shades hashed alone, so two agents collide about 8% of the time;
    // upgrade if workspaces name many agents.
    private static let agentSlots: [Slot] = [
        Slot(dark: [0xE87E87, 0xEE9FA6, 0xF4BEC3], light: [0xD12533, 0xA41D28, 0x76151D]),  // crimson
        Slot(dark: [0xE272E6, 0xEA98ED, 0xF1BAF3], light: [0xB821BE, 0x921A96, 0x69136B]),  // magenta
        Slot(dark: [0x3BB27A, 0x5BC896, 0x91DAB8], light: [0x297A54, 0x205F42, 0x17442F]),  // seafoam
        Slot(dark: [0xA6A212, 0xBFBA15, 0xD7D018], light: [0x726F0D, 0x5A570A, 0x3F3D07]),  // mustard
    ]

    static var slotCount: Int { slots.count }
    static var agentSlotCount: Int { agentSlots.count }

    static func hex(slot: Int, shade: Int = 0, scheme: Scheme) -> UInt32 {
        pick(slots, slot: slot, shade: shade, scheme: scheme)
    }

    static func hex(agentSlot: Int, shade: Int = 0, scheme: Scheme) -> UInt32 {
        pick(agentSlots, slot: agentSlot, shade: shade, scheme: scheme)
    }

    private static func pick(_ table: [Slot], slot: Int, shade: Int, scheme: Scheme) -> UInt32 {
        let entry = table[((slot % table.count) + table.count) % table.count]
        let shades = scheme == .dark ? entry.dark : entry.light
        return shades[((shade % shades.count) + shades.count) % shades.count]
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

    /// Each metric's slot, in its base shade. A mobile metric shares its Mac counterpart's slot
    /// (the Mobile screens mirror the Computers ones), and no screen plots both in one chart.
    /// No default, so a new metric needs a decision here.
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
            let hash = fnv1a("agent:" + normalized(name))
            let count = UInt64(agentSlots.count)
            return hex(agentSlot: Int(hash % count), shade: Int(hash / count % 3), scheme: scheme)
        }
    }

    // MARK: Versions and titles

    static func hex(forVersion version: String, scheme: Scheme) -> UInt32 {
        let name = normalized(version, kind: .version)
        if isNeutral(name) { return neutralHex }
        let parts = name.split(separator: ".", omittingEmptySubsequences: false)
            .map { Int($0.prefix(while: \.isNumber)) }
        guard let first = parts.first, let major = first else {
            return hashed(.version, name, scheme: scheme)
        }
        // Apple jumped from 15 to 26 (iOS from 18), so later majors close up on the gap;
        // macOS 11 to 15 and 26 to 28 (iOS 15 to 18 and 26 to 27) never share a hue.
        let release = major >= 20 ? major - 6 : major
        // Snapshot text can hold any digits; the cap keeps the sum from overflowing. Under
        // minor + patch mod 3, 15.6 and 15.7.2 (and 26.6.2 and 26.7.1) share a shade.
        let steps = parts.dropFirst().prefix(2).reduce(0) { $0 + min($1 ?? 0, 1_000) }
        return hex(slot: release, shade: steps, scheme: scheme)
    }

    static func hex(forTitle title: String, scheme: Scheme) -> UInt32 {
        let name = normalized(title, kind: .title)
        return isNeutral(name) ? neutralHex : hashed(.title, name, scheme: scheme)
    }

    /// The colours of the keys one chart draws, in the order given: each key's own colour.
    static func hexes(for kind: Kind, keys: [String], scheme: Scheme) -> [UInt32] {
        keys.map { kind == .version ? hex(forVersion: $0, scheme: scheme)
                                    : hex(forTitle: $0, scheme: scheme) }
    }

    private static func hashed(_ kind: Kind, _ name: String, scheme: Scheme) -> UInt32 {
        let hash = fnv1a(kind.rawValue + ":" + name)
        let count = UInt64(slots.count)
        return hex(slot: Int(hash % count), shade: Int(hash / count % UInt64(shadeCount)),
                   scheme: scheme)
    }

    /// "Unknown", "Other" and "Other (3 versions)" name no entity.
    private static func isNeutral(_ name: String) -> Bool {
        name == "other" || name == "unknown" || name.hasPrefix("other (")
    }

    /// A version without its product word and trailing ".0" ("macOS 26.7.0" is "26.7"); any
    /// other text is trimmed and lowercased.
    private static func normalized(_ key: String, kind: Kind) -> String {
        let text = normalized(key)
        guard kind == .version, !isNeutral(text),
              let digit = text.firstIndex(where: \.isNumber) else { return text }
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
