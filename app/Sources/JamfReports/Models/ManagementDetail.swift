import Foundation

/// The Computers detail panel's "Management" section: every field the Mac reported, and what
/// to do about a gap. A field Jamf did not report is left out, never shown as No or 0; Jamf's
/// status strings are shown as given.
enum ManagementDetail {
    /// A Jamf status string for the screen only: `ALLOW_BOOTING_FROM_EXTERNAL_MEDIA` reads
    /// "Allow booting from external media", `DISABLED` "Disabled". Only upper-case letters and
    /// underscores, four letters or more, are rewritten, so a serial, a version or an acronym
    /// such as MDM is kept as given. Workbook, HTML and CSV keep the raw value.
    static func displayValue(_ raw: String) -> String {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.filter(\.isLetter).count >= 4,
              text.allSatisfy({ ($0.isUppercase && $0.isASCII) || $0 == "_" })
        else { return text }
        let words = text.lowercased().replacingOccurrences(of: "_", with: " ")
        return words.prefix(1).uppercased() + words.dropFirst()
    }

    /// Jamf's `appleEnrollmentType` for the screen. The API sends it in lower case (`none`,
    /// `supervised`, `device`, `user`, `unknown`), which `displayValue` leaves as given.
    static func enrollmentTypeValue(_ raw: String) -> String {
        switch raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "none": L("None")
        case "supervised": L("Supervised")
        case "device": L("Device Enrollment")
        case "user": L("User Enrollment")
        case "unknown": L("Unknown")
        default: displayValue(raw)
        }
    }

    /// `displayValue` for a field of any kind (a jamf-cli Detail row, which can hold a name):
    /// only a value with an underscore or a known status word is rewritten, so a user, site or
    /// department written in capitals ("JSMITH", "FINANCE") stays as given.
    static func statusValue(_ raw: String) -> String {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.contains("_") || statusWords.contains(text) else { return text }
        return displayValue(text)
    }

    private static let statusWords: Set<String> = [
        "ENABLED", "DISABLED", "PENDING", "ACTIVE", "INACTIVE", "UNKNOWN", "NONE", "COMPLETE",
        "COMPLETED", "FAILED", "ERROR", "ENCRYPTED", "UNENCRYPTED", "ESCROWED", "SUPPORTED",
        "UNSUPPORTED", "ALLOWED", "DENIED", "TRUE", "FALSE",
    ]

    static func rows(
        _ facts: ManagementFacts, now: Date, calendar: Calendar = .current
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
        add(L("Enrollment type"), facts.appleEnrollmentType.map(enrollmentTypeValue))
        add(L("Awaiting setup"), yesNo(facts.awaitingConfiguration))
        add(L("Attestation"), facts.attestationStatus.map(displayValue))
        add(L("Last attested"), date(facts.lastSuccessfulAttestation))
        add(L("Recovery Lock"), yesNo(facts.recoveryLockEnabled))
        add(L("Activation Lock"), yesNo(facts.activationLockEnabled))
        add(L("External boot"), facts.externalBootLevel.map(displayValue))
        add(L("Auto-login off"), yesNo(facts.autoLoginDisabled))
        add(L("Remote Desktop"), yesNo(facts.remoteDesktopEnabled))
        add(L("Lockdown Mode"), yesNo(facts.lockdownModeEnabled))
        add(L("Battery health"), facts.batteryHealth.map(displayValue))
        add(L("Battery capacity"), facts.batteryCapacityPercent
            .flatMap { wholeInt($0) == nil ? nil : PercentFormat.whole.text($0) })
        add(L("Last iCloud backup"), date(facts.lastCloudBackupDate))
        return rows
    }

    /// One line per gap this Mac is in, plus the renewal note for a profile about to expire.
    static func remediation(
        _ facts: ManagementFacts, warningDays: Int, now: Date
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
