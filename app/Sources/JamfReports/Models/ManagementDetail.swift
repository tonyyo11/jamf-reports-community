import Foundation

/// The Computers detail panel's "Management" section: every field the Mac reported, and what
/// to do about a gap. A field Jamf did not report is left out, never shown as No or 0; Jamf's
/// status strings are shown as given.
enum ManagementDetail {
    static func rows(
        _ facts: ManagementFacts, now: Date = Date(), calendar: Calendar = .current
    ) -> [(String, String)] {
        var rows: [(String, String)] = []
        func add(_ label: String, _ value: String?) {
            if let value { rows.append((label, value)) }
        }
        func yesNo(_ value: Bool?) -> String? { value.map { $0 ? L("Yes") : L("No") } }
        func date(_ value: Date?) -> String? {
            value?.formatted(date: .abbreviated, time: .omitted)
        }
        add(L("MDM profile"), facts.mdmProfileExpiration.map {
            "\(date($0) ?? "") · \(expiryWording($0, now: now, calendar: calendar))"
        })
        add(L("Jamf binary"), facts.jamfBinaryVersion)
        add(L("MDM approved"), yesNo(facts.userApprovedMDM))
        add(L("MDM capable"), yesNo(facts.mdmCapable))
        add(L("Supervised"), yesNo(facts.supervised))
        add(L("Enrolled via ADE"), yesNo(facts.enrolledViaADE))
        add(L("Enrollment type"), facts.appleEnrollmentType)
        add(L("Awaiting setup"), yesNo(facts.awaitingConfiguration))
        add(L("Attestation"), facts.attestationStatus)
        add(L("Last attested"), date(facts.lastSuccessfulAttestation))
        add(L("Recovery Lock"), yesNo(facts.recoveryLockEnabled))
        add(L("Activation Lock"), yesNo(facts.activationLockEnabled))
        add(L("External boot"), facts.externalBootLevel)
        add(L("Auto-login off"), yesNo(facts.autoLoginDisabled))
        add(L("Remote Desktop"), yesNo(facts.remoteDesktopEnabled))
        add(L("Lockdown Mode"), yesNo(facts.lockdownModeEnabled))
        add(L("Battery health"), facts.batteryHealth)
        add(L("Battery capacity"), facts.batteryCapacityPercent.map { "\(Int($0.rounded()))%" })
        add(L("Last iCloud backup"), date(facts.lastCloudBackupDate))
        return rows
    }

    /// One line per gap this Mac is in, plus the renewal note for a profile about to expire.
    static func remediation(
        _ facts: ManagementFacts, warningDays: Int, now: Date = Date()
    ) -> [String] {
        var lines: [String] = []
        if let expiry = facts.mdmProfileExpiration {
            if expiry < now {
                lines.append(L("The MDM profile has expired. Re-enroll the Mac."))
            } else if expiry <= now.addingTimeInterval(Double(warningDays) * 86_400) {
                lines.append(L("The MDM profile renews when the Mac checks in."))
            }
        }
        if facts.userApprovedMDM == false {
            lines.append(L("MDM is not user-approved. Approve the MDM profile in System Settings › Privacy & Security › Profiles."))
        }
        if facts.mdmCapable == false {
            lines.append(L("The Mac is not MDM capable. Re-enroll the Mac."))
        }
        return lines
    }

    private static func expiryWording(_ expiry: Date, now: Date, calendar: Calendar) -> String {
        let days = calendar.dateComponents(
            [.day], from: calendar.startOfDay(for: now), to: calendar.startOfDay(for: expiry)
        ).day ?? 0
        return ManagementCard.tokenWording(days: days)
    }
}
