import Foundation

/// What the workbook's Management Health tab and the HTML report print from
/// `ManagementHealth`: the one place report rows are chosen, so neither counts for itself.
enum ManagementReport {
    typealias Finding = ManagementHealth.Finding

    /// The health of the Macs in a raw `computers` snapshot; nil with no rows.
    static func health(
        computers: [[String: Any]], rule: StaleRule, warningDays: Int, now: Date
    ) -> ManagementHealth? {
        guard !computers.isEmpty else { return nil }
        let records = computers.map {
            DeviceInventoryService.recordFromComputer($0, source: "computers")
        }
        return ManagementHealth(records: records, rule: rule, warningDays: warningDays, now: now)
    }

    /// One Mac in one gap or warning finding.
    struct DetailRow {
        let record: DeviceInventoryRecord
        let finding: Finding
        /// What Jamf reported for it, as the value appears in the sheet.
        let value: String
        /// Days until the profile expires (negative once expired); nil for other findings.
        let days: Int?
    }

    /// Gap and warning findings only, gaps first, each in `Finding` order, Macs by name.
    static func detailRows(
        _ health: ManagementHealth, now: Date, calendar: Calendar = .current
    ) -> [DetailRow] {
        let findings = Finding.allCases.filter { $0.kind != .neutral }
            .sorted { ($0.kind == .gap ? 0 : 1) < ($1.kind == .gap ? 0 : 1) }
        let today = calendar.startOfDay(for: now)
        return findings.flatMap { finding -> [DetailRow] in
            let records = (health.figures[finding]?.records ?? []).sorted {
                ($0.name, $0.serial) < ($1.name, $1.serial)
            }
            return records.map { record in
                let expiry = record.management?.mdmProfileExpiration
                let days = expiry.flatMap {
                    calendar.dateComponents(
                        [.day], from: today, to: calendar.startOfDay(for: $0)).day
                }
                switch finding {
                case .profileExpired, .profileExpiringCheckingIn, .profileExpiringCheckInUnknown:
                    return DetailRow(
                        record: record, finding: finding,
                        value: expiry.map { CoreDashboard.dayText($0) } ?? "", days: days)
                case .attestationProblem:
                    return DetailRow(
                        record: record, finding: finding,
                        value: record.management?.attestationStatus ?? "", days: nil)
                default:
                    return DetailRow(record: record, finding: finding, value: "No", days: nil)
                }
            }
        }
    }

    /// The findings that put a Mac on the HTML report's intervention list, by record ID.
    /// A Mac that is stale and cannot renew is already on that list for being stale.
    static let interventionFindings: [Finding] = [
        .profileExpired, .profileExpiringCheckingIn, .notUserApproved, .notMDMCapable,
    ]

    static func interventionFindings(_ health: ManagementHealth?) -> [String: [Finding]] {
        guard let health else { return [:] }
        var byID: [String: [Finding]] = [:]
        for finding in interventionFindings {
            for record in health.figures[finding]?.records ?? [] {
                byID[record.id, default: []].append(finding)
            }
        }
        return byID
    }

    // MARK: - Titles

    static func title(_ toggle: ManagementHealth.Toggle) -> String {
        switch toggle {
        case .recoveryLock: L("Recovery Lock")
        case .activationLock: L("Activation Lock")
        case .autoLoginDisabled: L("Automatic login disabled")
        case .remoteDesktop: L("Remote Desktop")
        case .lockdownMode: L("Lockdown Mode")
        case .awaitingConfiguration: L("Awaiting configuration")
        }
    }

    static func title(_ breakdown: ManagementHealth.Breakdown) -> String {
        switch breakdown {
        case .attestationProblem: L("Attestation problem")
        case .batteryHealth: L("Battery health, needs service")
        case .externalBootLevel: L("External boot level")
        case .appleEnrollmentType: L("Enrollment type")
        }
    }

    static func kindText(_ kind: ManagementHealth.Kind) -> String {
        switch kind {
        case .gap: L("Gap")
        case .warning: L("Warning")
        case .neutral: L("Count")
        }
    }

    // MARK: - Enrollment token

    /// The token's expiry day, from today and the whole days left.
    static func expiryDay(
        _ token: EnrollmentToken, now: Date, calendar: Calendar = .current
    ) -> Date? {
        token.daysLeft.flatMap {
            calendar.date(byAdding: .day, value: $0, to: calendar.startOfDay(for: now))
        }
    }

    static func stateText(_ state: EnrollmentToken.State) -> String {
        switch state {
        case .expired: L("Expired")
        case .expiring: L("Expiring")
        case .ok: L("OK")
        case .notReported: L("Not reported")
        }
    }

    /// The enrollment-token line of the Needs attention list; nil while no instance is
    /// expired or expiring. Counts and days only: an instance name is an organization's.
    static func tokenSentence(_ snapshot: EnrollmentTokenSnapshot) -> String? {
        let expired = snapshot.tokens.filter { $0.state == .expired }.count
        let expiring = snapshot.tokens.filter { $0.state == .expiring }
        guard expired > 0 || !expiring.isEmpty else { return nil }
        func tokens(_ count: Int) -> String {
            let noun = "Automated Device Enrollment token"
            return count == 1 ? "1 \(noun)" : "\(count) \(noun)s"
        }
        var parts: [String] = []
        if expired > 0 {
            parts.append("\(tokens(expired)) \(expired == 1 ? "has" : "have") expired")
        }
        if !expiring.isEmpty {
            let soonest = expiring.compactMap(\.daysLeft).min()
                .map { $0 == 1 ? "1 day" : "\($0) days" } ?? "an unknown number of days"
            let subject = expired > 0 ? "\(expiring.count) more" : tokens(expiring.count)
            let verb = expiring.count == 1 ? "expires" : "expire"
            parts.append("\(subject) \(verb), the soonest in \(soonest)")
        }
        return parts.joined(separator: "; ") + "."
    }
}
