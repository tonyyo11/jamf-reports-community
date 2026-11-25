import Foundation

extension DemoData {
    /// The server's own credentials: the built-in CA expiring 40 days after `referenceDate`.
    static let serverHealth: ServerHealth = {
        let expires = Calendar.current.date(byAdding: .day, value: 40, to: referenceDate)
            ?? referenceDate
        let credential = CredentialExpiry(
            key: "ca", label: "Built-in CA", raw: Int(expires.timeIntervalSince1970),
            warningDays: ManagementHealth.defaultWarningDays, now: referenceDate)
        return ServerHealth(credentials: [
            .init(key: "ca", label: "Built-in CA", fact: .value(.credential(credential), stale: nil))
        ])
    }()
}
