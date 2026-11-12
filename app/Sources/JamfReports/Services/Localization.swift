import Foundation

/// POSIX formats an interpolated number as the code wrote it: no separator in a port, year or exit code.
private let argumentLocale = Locale(identifier: "en_US_POSIX")

/// UI text in the app's language. Only the GUI reads a real table: tests and headless runs read one
/// that does not exist, and `Localization.english` does the same for text bound for reports and logs.
func L(_ value: String.LocalizationValue) -> String {
    let text = String(localized: value, table: Localization.activeTable, locale: argumentLocale)
    #if DEBUG
    if Localization.isPseudo, !Localization.isEnglishOnly { return "\u{27E6}\(text)\u{27E7}" }
    #endif
    return text
}

/// English text in the catalog, for a value code also compares, logs or stores. Show it with `LShown`.
func LK(_ value: String.LocalizationValue) -> String {
    String(localized: value, table: Localization.englishTable, locale: argumentLocale)
}

/// The app's language for a fixed English string that reached the view as a value.
func LShown(_ english: String) -> String {
    Bundle.main.localizedString(forKey: english, value: english, table: Localization.activeTable)
}

/// Keys for text that reaches `LShown` as a value; the compiler extracts them from this list.
private let shownKeys = [
    LK("CRITICAL"), LK("WARNING"), LK("INFO"), LK("OK"), LK("High"), LK("Medium"), LK("Low"),
    LK("Single profile"), LK("All profiles"), LK("Daily"), LK("Weekly"), LK("Weekdays"),
    LK("Monthly"), LK("Last full month"), LK("Last full quarter"), LK("Custom dates"), LK("All"),
    LK("Managed"), LK("Unmanaged"), LK("Stale"), LK("Devices"), LK("Name"), LK("Platform API"),
    LK("Other sources"), LK("Up"), LK("Down"), LK("Flat"), LK("Stable"), LK("Supervised"),
    LK("Unsupervised"), LK("Unknown"), LK("CSV folder"),
    // Report templates: reports print these in English, so they stay English on the template.
    LK("Full Instance Report"),
    LK("Complete instance report with every available section — all sheets, all HTML sections, full detail."),
    LK("Jamf admins, MacAdmins, full-detail review"),
    LK("Executive"),
    LK("Summary for directors and CISOs: six figures with their change, what needs attention, and the fleet dashboard. No detail tables in the HTML report."),
    LK("Directors, VPs, CISOs"),
    LK("Operational"),
    LK("Daily NOC view for ops engineers: failures, patch queue, stale devices, check-in anomalies, and group hygiene."),
    LK("Mac ops engineers, NOC staff"),
    LK("Compliance"),
    LK("Auditor-grade deliverable: mSCP results, patch compliance bands, OS adoption, exception list, DDM status, and evidence appendix."),
    LK("Internal auditors, security teams, compliance officers"),
    LK("Asset Inventory"),
    LK("Asset view for asset managers: purchase-date cohorts and building/department breakdowns. The device inventory is in the workbook."),
    LK("Asset managers, finance teams, IT procurement"),
    LK("Security Posture"),
    LK("Security-engineer deep-dive: Protect alerts, mSCP findings, FileVault/SIP/Gatekeeper/Firewall health, agent coverage, and insights drift."),
    LK("Security engineers, CISO staff"),
    LK("School (Jamf School)"),
    LK("Inventory, classes, users, profiles, and device status for Jamf School-managed iPads and Macs."),
    LK("K-12 IT, lab managers, education sysadmin"),
    LK("Custom — choose sheets"),
    LK("User-selected sheets only — choose exactly which sections to include."),
    LK("Custom reporting requirements"),
]

extension Error {
    /// `localizedDescription` in English, for a log line, a stored file or a webhook card.
    var englishDescription: String { Localization.english { localizedDescription } }
}

enum Localization {
    static let englishTable = "EnglishSource"

    /// Set once by the GUI entry point, before any `L` call.
    nonisolated(unsafe) private static var appTable = englishTable

    /// True while building something that leaves the app (a report, a log line, a webhook card).
    @TaskLocal static var isEnglishOnly = false

    #if DEBUG
    /// Test seam: marks text that went through `L`, so a test can prove none reaches a report or log.
    @TaskLocal static var isPseudo = ProcessInfo.processInfo.environment["JRC_PSEUDO_L10N"] == "1"
    #endif

    static var activeTable: String { isEnglishOnly ? englishTable : appTable }

    static func useAppLanguage() {
        appTable = "Localizable"
    }

    /// Runs `body` with `L` returning its English source, whatever the app's language.
    static func english<T>(_ body: () throws -> T) rethrows -> T {
        try $isEnglishOnly.withValue(true, operation: body)
    }

    static func english<T>(
        isolation: isolated (any Actor)? = #isolation,
        _ body: () async throws -> T
    ) async rethrows -> T {
        try await $isEnglishOnly.withValue(true, operation: body, isolation: isolation)
    }
}
