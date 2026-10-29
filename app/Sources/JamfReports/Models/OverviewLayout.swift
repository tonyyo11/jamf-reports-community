import Foundation

/// A block the Overview shows beneath its header and banners.
///
/// Raw values are persisted in the saved layout: never rename one. A section
/// added in a later release joins a saved layout at the end, shown.
/// Declaration order is the standard layout, which matches the order the
/// Overview used before it could be customized.
enum OverviewSection: String, CaseIterable, Identifiable, Sendable {
    case aiInsight
    case managedDevices
    case scoreCards
    case osDistribution
    case mobileDevices
    case topFailingRules
    case securityAgents
    case recentActivity
    case workspaceStatus

    var id: String { rawValue }

    var title: String {
        switch self {
        case .managedDevices:  "Managed Devices"
        case .scoreCards:      "Score Cards"
        case .aiInsight:       "AI Fleet Insight"
        case .osDistribution:  "macOS Distribution"
        case .mobileDevices:   "Mobile Devices"
        case .topFailingRules: "Top Failing Rules"
        case .securityAgents:  "Security Agents"
        case .recentActivity:  "Recent Activity"
        case .workspaceStatus: "Workspace Status"
        }
    }

    /// One line for the customize sheet: what the section shows and where
    /// its numbers come from.
    var summary: String {
        switch self {
        case .managedDevices:
            "Computers and mobile devices in the latest daily summary."
        case .scoreCards:
            "The metric tiles you pick below, each with its trend."
        case .aiInsight:
            "A plain-language reading of the latest summary, generated on this Mac."
        case .osDistribution:
            "Macs per macOS version, and the share on a current release."
        case .mobileDevices:
            "Managed, supervised, passcode, current-OS, stale and jailbroken figures for "
                + "iPads and iPhones, from the latest daily summary."
        case .topFailingRules:
            "Compliance rules failing on the most Macs."
        case .securityAgents:
            "Coverage of each agent listed under security_agents in Config."
        case .recentActivity:
            "The Macs that checked in most recently."
        case .workspaceStatus:
            "jamf-cli version and how many daily summaries this workspace holds."
        }
    }

    var sfSymbol: String {
        switch self {
        case .managedDevices:  "desktopcomputer"
        case .scoreCards:      "square.grid.2x2"
        case .aiInsight:       "sparkles"
        case .osDistribution:  "chart.pie"
        case .mobileDevices:   "ipad.and.iphone"
        case .topFailingRules: "list.number"
        case .securityAgents:  "shield.lefthalf.filled"
        case .recentActivity:  "clock.arrow.circlepath"
        case .workspaceStatus: "externaldrive"
        }
    }

    /// Half-width sections share a row with a half-width neighbour.
    var isHalfWidth: Bool {
        self == .osDistribution || self == .mobileDevices || self == .topFailingRules
    }

    /// Whether this environment can have anything to show here. A section whose data cannot
    /// exist is left out, not drawn as an Unavailable notice: a figure that could exist after
    /// a collect or a setup step is `OverviewUnavailable`'s job instead.
    func availability(in composition: EnvironmentComposition) -> OverviewAvailability {
        switch self {
        case .osDistribution, .topFailingRules, .securityAgents, .recentActivity:
            return composition.allowsMacs ? .shown : .leftOut("No Macs in this environment.")
        case .mobileDevices:
            switch composition {
            case .mobileOnly, .mixed: return .shown
            case .macsOnly: return .leftOut("No mobile devices in the latest daily summary.")
            case .unknown: return .leftOut("No daily summary lists mobile devices yet.")
            }
        case .aiInsight, .managedDevices, .scoreCards, .workspaceStatus:
            return .shown
        }
    }
}

enum OverviewAvailability: Equatable, Sendable {
    case shown
    /// Not drawn on this Overview, and listed in Customize with this reason.
    case leftOut(String)

    var isShown: Bool { self == .shown }
    var reason: String? {
        if case .leftOut(let why) = self { return why }
        return nil
    }
}

/// Which Overview sections show, and in what order. App-wide rather than per
/// profile, like the score-card selection: the layout is how a person likes to
/// read the screen, and a section a profile cannot fill says so in its slot
/// instead of moving everything around on a profile switch.
struct OverviewLayout: Equatable, Sendable {
    /// Every section exactly once, in display order.
    private(set) var order: [OverviewSection]
    private(set) var hidden: Set<OverviewSection>

    init(order: [OverviewSection] = OverviewSection.allCases,
         hidden: Set<OverviewSection> = []) {
        self.order = Self.normalized(order)
        self.hidden = hidden
    }

    static let standard = OverviewLayout()

    var visible: [OverviewSection] { order.filter { !hidden.contains($0) } }

    func isVisible(_ section: OverviewSection) -> Bool { !hidden.contains(section) }

    mutating func setVisible(_ section: OverviewSection, _ isVisible: Bool) {
        if isVisible { hidden.remove(section) } else { hidden.insert(section) }
    }

    /// Trades places with `other`. The editor moves a section past the
    /// neighbour it lists rather than by one index, because a section it does
    /// not list (the AI card on a Mac that cannot run it) may sit between
    /// them, and a one-place move would then look like it did nothing.
    mutating func swap(_ section: OverviewSection, with other: OverviewSection) {
        guard let from = order.firstIndex(of: section),
              let to = order.firstIndex(of: other) else { return }
        order.swapAt(from, to)
    }

    /// The saved order with duplicates dropped and any section the save
    /// predates appended, so every section appears exactly once.
    static func normalized(_ order: [OverviewSection]) -> [OverviewSection] {
        var seen = Set<OverviewSection>()
        var result = order.filter { seen.insert($0).inserted }
        result += OverviewSection.allCases.filter { !seen.contains($0) }
        return result
    }

    /// Rows to render: two adjacent sections that are both `pairable` share a
    /// row; everything else takes a row to itself. The caller decides what is
    /// pairable — a half-width section with nothing to show renders as a thin
    /// full-width notice, and pairing one would leave half a row empty.
    static func rows(
        _ sections: [OverviewSection],
        pairable: (OverviewSection) -> Bool
    ) -> [[OverviewSection]] {
        var rows: [[OverviewSection]] = []
        var index = 0
        while index < sections.count {
            let section = sections[index]
            let next = index + 1 < sections.count ? sections[index + 1] : nil
            if let next, pairable(section), pairable(next) {
                rows.append([section, next])
                index += 2
            } else {
                rows.append([section])
                index += 1
            }
        }
        return rows
    }

    // MARK: Persistence

    private struct Stored: Codable {
        var order: [String]
        var hidden: [String]
    }

    /// JSON for UserDefaults.
    var serialized: String {
        let stored = Stored(order: order.map(\.rawValue),
                            hidden: hidden.map(\.rawValue).sorted())
        guard let data = try? JSONEncoder().encode(stored) else { return "" }
        return String(decoding: data, as: UTF8.self)
    }

    /// Lenient: an unknown raw value (a section a later release added, then a
    /// downgrade) is dropped rather than failing the whole layout, and an
    /// unreadable value falls back to the standard layout.
    static func parse(_ raw: String?) -> OverviewLayout {
        guard let raw, let data = raw.data(using: .utf8),
              let stored = try? JSONDecoder().decode(Stored.self, from: data) else {
            return .standard
        }
        return OverviewLayout(
            order: stored.order.compactMap(OverviewSection.init(rawValue:)),
            hidden: Set(stored.hidden.compactMap(OverviewSection.init(rawValue:)))
        )
    }
}

/// Why a section has nothing to show on the active profile.
struct OverviewUnavailable: Equatable, Sendable {
    let reason: String
    /// The screen that fixes it, when one does.
    var remedy: Tab? = nil
}

/// Which score cards the Overview draws from the person's saved selection.
enum OverviewScoreCards {
    /// What a mobile-only environment shows when none of the saved cards applies to it.
    static let mobileDefaults: [TrendSeries.Metric] = [
        .mobileOSCurrent, .mobilePasscode, .mobileSupervised, .mobileDataProtection,
    ]

    /// The saved cards that are offered, in their saved order. On a mobile-only environment
    /// where none of a non-empty selection is, the mobile defaults stand in (mobile spec 3.2).
    /// The selection itself is never rewritten here, so switching back to an environment
    /// with Macs restores it; an empty selection stays empty, as the person chose.
    static func shown(
        selected: [TrendSeries.Metric], composition: EnvironmentComposition,
        isOffered: (TrendSeries.Metric) -> Bool
    ) -> [TrendSeries.Metric] {
        let offered = selected.filter(isOffered)
        guard offered.isEmpty, !selected.isEmpty, composition == .mobileOnly else {
            return offered
        }
        return mobileDefaults.filter(isOffered)
    }

    /// True for the only card a mobile-only environment shows. Switching it off would leave the
    /// saved selection with nothing offered, and the mobile defaults would stand in again, so the
    /// switch is held on; the Score Cards section's own switch is how to remove them.
    static func isLastOnMobileOnly(
        _ metric: TrendSeries.Metric, shown: [TrendSeries.Metric],
        composition: EnvironmentComposition
    ) -> Bool {
        composition == .mobileOnly && shown == [metric]
    }

    /// The selection with the cards `shown` drew in its place made part of it, for the first
    /// edit made while the mobile defaults stand in; otherwise the selection unchanged.
    static func adopting(
        selected: [TrendSeries.Metric], composition: EnvironmentComposition,
        isOffered: (TrendSeries.Metric) -> Bool
    ) -> [TrendSeries.Metric] {
        guard !selected.contains(where: isOffered) else { return selected }
        return selected + shown(selected: selected, composition: composition, isOffered: isOffered)
    }
}

extension TrendSeries.Metric {
    /// What a profile has to collect before this score card has a value. Shown
    /// on a selected card that has none, and in the customize sheet.
    var dataRequirement: String {
        switch self {
        case .stability:
            "Needs patch status, jamf-cli's security report, or a compliance EA."
        case .activeDevices, .stale:
            "Needs the device-compliance report."
        case .compliance:
            "Needs jamf-cli's security report, or a compliance EA mapped in Config."
        case .fileVault, .securityScore, .sip, .firewall, .gatekeeper:
            "Needs jamf-cli's security report."
        case .osCurrent:
            "Needs the inventory summary and the SOFA feed."
        case .edrAgent, .agent:
            "Needs a security agent in Config and extension-attribute results."
        case .patch:
            "Needs the patch-status report."
        case .mscpBandTrend:
            "Needs a compliance baseline mapped in Config."
        case .managedDevices:
            "Needs a collected inventory."
        case .mobileManaged, .mobileOSCurrent, .mobilePasscode, .mobileSupervised,
             .mobileDataProtection, .mobileStale, .mobileJailbroken:
            "Needs the mobile device inventory."
        }
    }

    /// The security-policy control this card reports on; nil for any other card.
    var securityControl: SecurityControl? {
        switch self {
        case .fileVault: .fileVault
        case .sip: .sip
        case .firewall: .firewall
        case .gatekeeper: .gatekeeper
        default: nil
        }
    }

    /// False for a card whose control the policy does not count, for a Mac card where the
    /// environment has no Macs, and for a mobile card where it has no mobile devices: there
    /// is nothing to report on, so the Overview and its editor leave the card out. A stored
    /// selection naming it is kept, and shows again if the policy or the environment changes.
    /// The default composition is `.unknown`, which offers every Mac card and no mobile one.
    func isOffered(
        under policy: SecurityControlPolicy, in composition: EnvironmentComposition = .unknown
    ) -> Bool {
        if isMobile { return composition.allowsMobile }
        guard composition.allowsMacs else { return false }
        guard let control = securityControl else { return true }
        return policy.level(for: control) != .ignore
    }
}

extension Array where Element: Equatable {
    /// A copy with `element` moved `offset` places, clamped to the ends.
    /// Unchanged when `element` is absent.
    func moving(_ element: Element, by offset: Int) -> [Element] {
        guard let from = firstIndex(of: element) else { return self }
        let to = Swift.min(Swift.max(from + offset, 0), count - 1)
        guard to != from else { return self }
        var copy = self
        copy.remove(at: from)
        copy.insert(element, at: to)
        return copy
    }

    /// A copy with `element` moved to where `neighbour` sits. Steps over anything
    /// hidden between the two, which `moving(_:by:)` would swap with instead.
    func moving(_ element: Element, to neighbour: Element) -> [Element] {
        guard let from = firstIndex(of: element), let to = firstIndex(of: neighbour) else {
            return self
        }
        return moving(element, by: to - from)
    }
}
