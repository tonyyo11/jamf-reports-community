import Foundation

/// What the Audit screen's "Management health" card shows, built from `ManagementHealth` and
/// the enrollment token snapshot. Pure strings and tones, so the wording is testable and the
/// view only lays it out.
struct ManagementCard: Sendable, Equatable {
    enum Tone: Sendable, Equatable { case gap, warning, neutral }

    struct Row: Identifiable, Sendable, Equatable {
        let id: String
        let title: String
        let value: String
        let tone: Tone
        /// Jamf's own values, as given, one line.
        var breakdown: String?
        /// A gap or warning with Macs behind it opens Computers on the Management filter.
        var opensComputers = false
    }

    var gaps: [Row] = []
    var warnings: [Row] = []
    var counts: [Row] = []
    var settings: [Row] = []
    var tokens: [Row] = []
    /// Why there are no token rows: "not collected" and "could not be read" read apart.
    var tokenNote: String?

    /// Draws nothing when there is nothing to say about management.
    var isEmpty: Bool {
        gaps.isEmpty && warnings.isEmpty && counts.isEmpty && settings.isEmpty
            && tokens.isEmpty && tokenNote == nil
    }

    /// `health` is nil without a `computers` snapshot; a workspace with neither it nor a token
    /// snapshot gets no card.
    static func build(
        health: ManagementHealth?, tokens snapshot: EnrollmentTokenSnapshot
    ) -> ManagementCard? {
        var card = ManagementCard()
        if let health, health.judgedAnything { card.addHealth(health) }
        card.addTokens(snapshot, hasHealth: !card.isEmpty)
        return card.isEmpty ? nil : card
    }

    // MARK: - Findings

    private mutating func addHealth(_ health: ManagementHealth) {
        for finding in ManagementHealth.Finding.allCases {
            guard let figure = health.figures[finding] else { continue }
            let row = Self.row(finding, figure, health)
            switch finding.kind {
            case .gap: gaps.append(row)
            case .warning: warnings.append(row)
            case .neutral: counts.append(row)
            }
        }
        for breakdown in [ManagementHealth.Breakdown.externalBootLevel, .appleEnrollmentType] {
            if let row = Self.valuesRow(breakdown, health) { counts.append(row) }
        }
        for toggle in ManagementHealth.Toggle.allCases {
            guard let onOff = health.toggles[toggle] else { continue }
            let notReported = max(health.managedCount - onOff.evaluated, 0)
            settings.append(Row(
                id: "toggle.\(toggle)", title: toggle.title,
                value: L("on \(onOff.on.count) · off \(onOff.off.count) · not reported \(notReported)"),
                tone: .neutral))
        }
    }

    private static func row(
        _ finding: ManagementHealth.Finding, _ figure: ManagementHealth.Figure,
        _ health: ManagementHealth
    ) -> Row {
        var title = finding.title
        if finding == .binaryBehind, let newest = health.newestBinary {
            title = L("Jamf binary behind the newest binary in this fleet (\(newest.label))")
        }
        let marked = finding.kind != .neutral && figure.count > 0
        let tone: Tone = marked ? (finding.kind == .gap ? .gap : .warning) : .neutral
        var breakdown: String?
        switch finding {
        case .attestationProblem: breakdown = line(health.values(.attestationProblem))
        case .batteryNeedsService: breakdown = line(health.values(.batteryHealth))
        default: break
        }
        return Row(
            id: "finding.\(finding.rawValue)", title: title,
            value: L("\(figure.count) of \(figure.evaluated) Macs"), tone: tone,
            breakdown: breakdown, opensComputers: marked)
    }

    private static func valuesRow(
        _ breakdown: ManagementHealth.Breakdown, _ health: ManagementHealth
    ) -> Row? {
        let values = health.values(breakdown)
        guard !values.isEmpty else { return nil }
        let total = values.reduce(0) { $0 + $1.records.count }
        let title = breakdown == .externalBootLevel
            ? L("External boot level") : L("Enrollment type")
        return Row(
            id: "values.\(breakdown)", title: title,
            value: L("\(total) of \(health.managedCount) Macs"), tone: .neutral,
            breakdown: line(values))
    }

    /// "VALUE 3 · OTHER 1", the values as Jamf gives them.
    private static func line(_ values: [(value: String, records: [DeviceInventoryRecord])])
        -> String? {
        values.isEmpty ? nil
            : values.map { "\($0.value) \($0.records.count)" }.joined(separator: " · ")
    }

    // MARK: - Enrollment token

    private mutating func addTokens(_ snapshot: EnrollmentTokenSnapshot, hasHealth: Bool) {
        if snapshot.readFailed {
            tokenNote = L("Automated Device Enrollment token: could not be read")
        } else if !snapshot.isDetected {
            // Said only beside other management findings; alone it would be a card of nothing.
            if hasHealth { tokenNote = L("Automated Device Enrollment token: not collected") }
        } else {
            tokens = snapshot.tokens.enumerated().map { Self.tokenRow($1, position: $0) }
        }
    }

    static func tokenRow(_ token: EnrollmentToken, position: Int) -> Row {
        let title = token.name ?? L("Unnamed instance")
        let id = "token.\(position)"
        guard let days = token.daysLeft else {
            return Row(id: id, title: title, value: L("not reported"), tone: .neutral)
        }
        let tone: Tone = switch token.state {
        case .expired: .gap
        case .expiring: .warning
        case .ok, .notReported: .neutral
        }
        return Row(id: id, title: title, value: tokenWording(days: days), tone: tone)
    }

    static func tokenWording(days: Int) -> String {
        switch days {
        case ..<(-1): L("expired \(-days) days ago")
        case -1: L("expired 1 day ago")
        case 0: L("expires today")
        case 1: L("expires in 1 day")
        default: L("expires in \(days) days")
        }
    }

    /// The card for a workspace: the inventory's management health and the newest token
    /// snapshot. Runs off the main actor.
    nonisolated static func load(
        profile: String, inventory: DeviceInventorySnapshot, warningDays: Int, now: Date = Date()
    ) -> ManagementCard? {
        let health = inventory.devices.contains { $0.management != nil }
            ? ManagementHealth(
                records: inventory.devices,
                rule: StaleRule(days: inventory.staleDays, basis: inventory.staleBasis),
                warningDays: warningDays, now: now)
            : nil
        let tokens = (try? WorkspacePaths.dataDir(for: profile)).map {
            EnrollmentTokenSnapshot.load(dataDir: $0, warningDays: warningDays, now: now)
        } ?? .empty
        return build(health: health, tokens: tokens)
    }
}

extension ManagementHealth.Toggle {
    var title: String {
        switch self {
        case .recoveryLock: L("Recovery Lock")
        case .activationLock: L("Activation Lock")
        case .autoLoginDisabled: L("Automatic login disabled")
        case .remoteDesktop: L("Remote Desktop")
        case .lockdownMode: L("Lockdown Mode")
        case .awaitingConfiguration: L("Awaiting configuration")
        }
    }
}
