import Foundation

extension ReportEngine {
    /// The server-health figures a Jamf Pro environment's daily summary records. Expiries come
    /// from the newest snapshot of the built-in CA and the ADE instances when it is within
    /// `maxCacheAgeHours` (an inventory-tier kind lands every 48 hours, so it is present every
    /// day); the notification count only when the kind landed this run. Nil when neither group
    /// measured anything, so an earlier value stands.
    static func serverHealthSummaryFigures(
        dataDir: URL, landed: Set<String>, maxCacheAgeHours: Int, now: Date = Date(),
        calendar: Calendar = .current
    ) -> ServerHealthSummaryFigures? {
        func asOf(_ kind: String) -> String? {
            guard let url = try? latestSnapshotURL(
                kind: kind, dataDir: dataDir, maxCacheAgeHours: maxCacheAgeHours, now: now)
            else { return nil }
            return SummaryJSONParser.dateFormatter.string(
                from: MSCPChartDataBuilder.dateFromSnapshotFilename(url))
        }
        let health = ServerHealth.load(
            dataDir: dataDir, warningDays: ManagementHealth.defaultWarningDays, now: now,
            calendar: calendar, optIn: landed.intersection([ServerHealth.lapsKind]))
        var expiries: [String: CredentialExpiryEntry] = [:]
        if let day = asOf(ServerHealth.caKind),
           case .value(.credential(let credential), _)?
               = health.credentials.first(where: { $0.key == "ca" })?.fact,
           let text = credential.expiresText {
            expiries["ca"] = .init(expires: text, asOf: day)
        }
        var adeMeasured = false
        if let day = asOf("device-enrollment-instances") {
            let tokens = EnrollmentTokenSnapshot.load(
                dataDir: dataDir, warningDays: ManagementHealth.defaultWarningDays, now: now,
                calendar: calendar).tokens
            adeMeasured = true
            for token in cappedTokens(tokens) {
                // The id comes from a snapshot a peer can write and becomes part of a key.
                guard let id = token.id, let expires = token.expiryDay, isSafeKeyPart(id)
                else { continue }
                expiries["ade:\(id)"] = .init(expires: expires, asOf: day)
            }
        }
        let count = landed.contains(ServerHealth.notificationsKind)
            ? health.notificationFigure?.value.total : nil
        // Only a kind that landed this run: an opted-out or failed source leaves the earlier value.
        let laps = landed.contains(ServerHealth.lapsKind) ? health.lapsPendingFigure : nil
        guard !expiries.isEmpty || adeMeasured || count != nil || laps != nil else { return nil }
        return .init(
            expiries: expiries.isEmpty && !adeMeasured ? nil : expiries,
            adeMeasured: adeMeasured, notificationCount: count, lapsPendingCount: laps)
    }

    static let maxADEInstances = 20

    /// The tokens the cap keeps: those not yet expired, soonest first, then the expired ones,
    /// most recently expired first (any past the ledger's retention window left out), so the
    /// cap never drops the token about to expire. A token with no readable day is not kept.
    static func cappedTokens(_ tokens: [EnrollmentToken]) -> [EnrollmentToken] {
        let dated = tokens.compactMap { token in token.daysLeft.map { (token, $0) } }
            .filter { $0.1 >= -MetricAlertLedger.credentialRetentionDays }
        let live = dated.filter { $0.1 >= 0 }.sorted { $0.1 < $1.1 }
        let expired = dated.filter { $0.1 < 0 }.sorted { $0.1 > $1.1 }
        return Array((live + expired).map(\.0).prefix(maxADEInstances))
    }

    static func isSafeKeyPart(_ id: String) -> Bool {
        (1...40).contains(id.count)
            && id.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }
    }
}
