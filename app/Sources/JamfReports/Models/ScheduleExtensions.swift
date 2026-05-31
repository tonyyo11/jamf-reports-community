import Foundation

extension Schedule {
    /// Plain-language summary of this schedule's mode and cadence.
    var plainLanguageSummary: String {
        let cadenceSummary: String
        if schedule.contains("Daily") {
            cadenceSummary = "daily"
        } else if schedule.contains("Weekdays") {
            cadenceSummary = "every weekday"
        } else if schedule.lowercased().contains("sun") ||
                  schedule.lowercased().contains("mon") ||
                  schedule.lowercased().contains("tue") ||
                  schedule.lowercased().contains("wed") ||
                  schedule.lowercased().contains("thu") ||
                  schedule.lowercased().contains("fri") ||
                  schedule.lowercased().contains("sat") {
            // Check if it's multiple times per week
            if schedule.contains("×") || schedule.contains("x") {
                cadenceSummary = "multiple times per week"
            } else {
                cadenceSummary = "weekly"
            }
        } else if schedule.contains("×") || schedule.contains("x") {
            cadenceSummary = "multiple times per week"
        } else {
            cadenceSummary = schedule.lowercased()
        }

        let modeSummary: String
        switch mode {
        case .snapshotOnly:
            modeSummary = "collects snapshots only"
        case .jamfCLIOnly:
            modeSummary = "builds a workbook from cached data"
        case .jamfCLIFull:
            modeSummary = "collects snapshots and builds a workbook"
        case .csvAssisted:
            modeSummary = "collects snapshots and builds a workbook (CSV required)"
        }

        let timeMatch = schedule.range(of: #"\d{2}:\d{2}"#, options: .regularExpression)
        let timeComponent = timeMatch.map { " at " + String(schedule[$0]) } ?? ""

        // Capitalize only the first character of the cadence summary
        let capitalizedCadence = cadenceSummary.prefix(1).uppercased() + cadenceSummary.dropFirst()

        return "\(capitalizedCadence)\(timeComponent) — \(modeSummary)"
    }

    /// True if this schedule predates PR-20 and should show migration nudge.
    /// Pre-PR-20 plists lack the --mode flag and get defaulted to .jamfCLIOnly.
    /// Since PR-21 changed the meaning of .jamfCLIOnly (from collect+generate to generate-only),
    /// legacy plists need re-saving to migrate to explicit mode selection.
    var needsMigrationNudge: Bool {
        // If the schedule has an explicit launchAgentLabel, we can check the underlying plist
        // for presence of the --mode flag. However, for simplicity, we'll use a heuristic:
        // schedules with mode .jamfCLIOnly that were created before PR-20 would not have
        // explicitly chosen that mode, so they likely need migration.
        //
        // Since we can't easily distinguish between explicitly chosen .jamfCLIOnly and
        // defaulted .jamfCLIOnly from the Schedule model alone, we'll use the presence
        // of a launchAgentLabel as a proxy for "this was parsed from a plist" and
        // combine that with .jamfCLIOnly mode as the signal.
        return mode == .jamfCLIOnly && launchAgentLabel != nil
    }
}