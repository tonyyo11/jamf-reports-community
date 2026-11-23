import Foundation

/// Demo management facts and token, derived from the fleet's own positions and dated from
/// `referenceDate`, so the Management health card and the Computers filter agree with the 524
/// Macs and read no workspace.
extension DemoData {
    /// The facts of the fleet Mac at `index` (its position in `fleetMacs`): a fixed rule per
    /// field, so every figure is reproducible and a few Macs land in each finding.
    static func managementFacts(index: Int) -> ManagementFacts {
        var facts = ManagementFacts(item: [:])
        let day = 86_400.0
        let expiry: Double = index % 97 == 5 ? -Double(1 + index % 40)
            : index % 41 == 7 ? Double(5 + index % 80) : Double(120 + index % 300)
        facts.mdmProfileExpiration = referenceDate.addingTimeInterval(expiry * day)
        let version = index % 37 == 0 ? "11.31.1" : index % 11 == 0 ? "11.32.2" : "11.33.1"
        facts.jamfBinaryVersion = version
        facts.binaryVersion = BinaryVersion(version)
        facts.userApprovedMDM = index % 61 != 3
        facts.mdmCapable = index % 89 != 4
        facts.supervised = index % 13 != 0
        facts.enrolledViaADE = index % 9 != 0
        facts.attestationStatus = index % 17 == 1 ? "MDA_UNSUPPORTED_DUE_TO_HARDWARE"
            : index % 23 == 0 ? "PENDING"
            : index % 53 == 2 ? "DEVICE_PROPERTIES_MISMATCH" : "SUCCESS"
        facts.recoveryLockEnabled = index % 3 == 0
        facts.activationLockEnabled = index % 5 == 0
        facts.externalBootLevel = index % 4 == 0 ? "NOT_ALLOWED" : "ALLOW_ONLY_SIGNED"
        facts.batteryHealth = index % 29 == 0 ? "SERVICE_RECOMMENDED" : "NORMAL"
        facts.batteryCapacityPercent = Double(100 - index % 40)
        return facts
    }

    /// Two Automated Device Enrollment instances, dated from `referenceDate`: one inside the
    /// default 90-day warning window and one well outside it.
    static let enrollmentTokens: EnrollmentTokenSnapshot = {
        func day(_ offset: Int) -> String {
            let date = Calendar.current.date(byAdding: .day, value: offset, to: referenceDate)
                ?? referenceDate
            let parts = Calendar.current.dateComponents([.year, .month, .day], from: date)
            return String(
                format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
        }
        let rows: [[String: Any]] = [
            ["name": "Meridian Macs", "tokenExpirationDate": day(38)],
            ["name": "Meridian Clinics", "tokenExpirationDate": day(210)],
        ]
        return EnrollmentTokenSnapshot(
            tokens: rows.map {
                EnrollmentToken(row: $0, warningDays: ManagementHealth.defaultWarningDays,
                                now: referenceDate)
            },
            isDetected: true, readFailed: false)
    }()

    /// The Audit screen's card over the whole 524-Mac fleet.
    static let managementCard: ManagementCard? = ManagementCard.build(
        health: ManagementHealth(
            records: outreachRecords, rule: StaleRule(days: 30), now: referenceDate),
        tokens: enrollmentTokens)
}
