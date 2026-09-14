import Foundation

/// Owns the identity and desired-spec rules for the global "managed"
/// automation kinds derived from `AutomationPolicy` (v2.2.0 "set policy, not
/// cron jobs"). As of 2.8.0 the actual scheduling mechanism is the bundled
/// `SMAppService` ticker, not per-kind LaunchAgent plists — this enum now
/// only carries the pure identity/spec rules that mechanism still consumes.
///
/// `owns(_:)` is exact membership against the reserved managed label set,
/// never a prefix match, so a user's hand-built multi-schedule (`…multi
/// .<their-name>`) is never mistaken for a managed one.
enum ManagedAutomation {

    // MARK: - Reserved identity

    /// The four managed agent kinds. Raw values are slug-safe and become the
    /// `<prefix>.multi.<slug>` label suffix.
    enum ManagedKind: String, CaseIterable, Sendable {
        case freshness = "managed-freshness"
        case scan      = "managed-scan"
        case reports   = "managed-reports"
        case backup    = "managed-backup"
    }

    /// Exact reserved label set: `<prefix>.multi.<slug>` for every kind.
    static var reservedLabels: Set<String> {
        Set(ManagedKind.allCases.map(label(for:)))
    }

    static func label(for kind: ManagedKind) -> String {
        "\(LaunchAgentWriter.labelPrefix).multi.\(kind.rawValue)"
    }

    /// True only when `label` is exactly one of the reserved managed labels.
    /// Deliberately not a prefix test — a user agent whose name merely starts
    /// with `managed-` must never be mistaken for one of these.
    static func owns(_ label: String) -> Bool {
        reservedLabels.contains(label)
    }

    /// The profile a managed schedule carries as its base `--profile`: the
    /// first one the policy has not excluded. The run itself fans out over
    /// `--all-profiles`, so the base is only ever a valid-slug placeholder —
    /// but three call sites derived it separately and two of them ignored the
    /// exclusions, so an excluded first profile could end up naming the run.
    static func managedBaseProfile(
        profiles: [JamfCLIProfile], policy: AutomationPolicy
    ) -> String? {
        managedBaseProfile(names: profiles.map(\.name), policy: policy)
    }

    /// Name-list form, for the callers that only ever hold profile slugs.
    static func managedBaseProfile(names: [String], policy: AutomationPolicy) -> String? {
        names.first { !policy.excludedProfiles.contains($0) }
    }

    // MARK: - Desired specs (pure)

    /// The managed `Schedule`s the policy maps to. Empty when `isManaged` is
    /// false or when no base profile is available (nothing to manage).
    ///
    /// - Parameter baseProfile: A valid profile slug used as the multi
    ///   schedule's base `--profile`. The actual run fans out over
    ///   `--all-profiles`, so the base is vestigial but must be a valid slug.
    static func desiredSchedules(
        for policy: AutomationPolicy,
        baseProfile: String?
    ) -> [Schedule] {
        guard policy.isManaged,
              let baseProfile, ProfileService.isValid(baseProfile) else { return [] }

        var out: [Schedule] = []
        if policy.freshnessEnabled {
            out.append(makeSchedule(.freshness, policy: policy, baseProfile: baseProfile))
        }
        if policy.scanEnabled {
            out.append(makeSchedule(.scan, policy: policy, baseProfile: baseProfile))
        }
        if policy.reportsCadence != .off {
            out.append(makeSchedule(.reports, policy: policy, baseProfile: baseProfile))
        }
        if policy.backupsEnabled {
            out.append(makeSchedule(.backup, policy: policy, baseProfile: baseProfile))
        }
        return out
    }

    private static func makeSchedule(
        _ kind: ManagedKind,
        policy: AutomationPolicy,
        baseProfile: String
    ) -> Schedule {
        Schedule(
            name: kind.rawValue,
            profile: baseProfile,
            schedule: scheduleString(kind, policy: policy),
            cadence: cadenceWord(kind, policy: policy),
            mode: mode(kind),
            next: "—",
            last: "—",
            lastStatus: .ok,
            artifacts: [],
            enabled: true,
            launchAgentLabel: label(for: kind),
            multiTarget: MultiTarget(scope: .all, sequential: true),
            tiers: tiers(kind),
            excludedProfiles: policy.excludedProfiles
        )
    }

    /// Non-nil when the running bundle sits outside /Applications or
    /// ~/Applications. Automation runs whichever copy is running when the
    /// ticker fires, so a scratch or build-folder copy pins fleet automation
    /// to itself.
    static func bundleLocationWarning(
        executablePath: String? = Bundle.main.executableURL?.path,
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> String? {
        guard let executablePath else { return nil }
        let allowed = ["/Applications/", home.appendingPathComponent("Applications").path + "/"]
        if allowed.contains(where: executablePath.hasPrefix) { return nil }
        let bundle = executablePath.components(separatedBy: "/Contents/").first ?? executablePath
        return "JamfReports is running from \(bundle). Scheduled runs point at whichever copy "
            + "writes them, so move the app to /Applications before turning automation on."
    }

    // MARK: - Per-kind mapping

    private static func mode(_ kind: ManagedKind) -> Schedule.RunMode {
        switch kind {
        case .freshness: return .snapshotOnly          // collect + summary.json, no workbook
        case .scan:      return .snapshotOnly          // collect heavy scan only
        case .reports:   return .jamfCLIOnly           // generate from the already-fresh cache
        case .backup:    return .backup
        }
    }

    private static func tiers(_ kind: ManagedKind) -> Set<CollectionTier>? {
        switch kind {
        case .freshness: return [.refresh, .inventory]
        case .scan:      return [.scan]
        case .reports, .backup: return nil             // these modes never collect
        }
    }

    /// Minutes each kind is offset off the shared base run time, so the four
    /// agents don't fire simultaneously against on-prem Jamf Pro.
    private static func staggerMinutes(_ kind: ManagedKind) -> Int {
        switch kind {
        case .freshness: return 0
        case .scan:      return 10
        case .reports:   return 20
        case .backup:    return 30
        }
    }

    private static func cadenceWord(_ kind: ManagedKind, policy: AutomationPolicy) -> String {
        switch kind {
        case .freshness: return "daily"
        case .scan, .backup: return "weekly"
        case .reports:
            switch policy.reportsCadence {
            case .daily:   return "daily"
            case .monthly: return "monthly"
            case .weekly, .off: return "weekly"
            }
        }
    }

    /// Cadence string in the exact shape `LaunchAgentWriter.setupCadence`
    /// parses: "Daily HH:MM" / "<Day3> HH:MM" / "Day <n> HH:MM".
    private static func scheduleString(_ kind: ManagedKind, policy: AutomationPolicy) -> String {
        let time = staggeredTime(base: policy.runTime, offsetMinutes: staggerMinutes(kind))
        switch kind {
        case .freshness:
            return "Daily \(time)"
        case .scan:
            return "\(weekdayAbbrev(policy.scanWeekday)) \(time)"
        case .backup:
            return "\(weekdayAbbrev(policy.backupsWeekday)) \(time)"
        case .reports:
            switch policy.reportsCadence {
            case .daily:
                return "Daily \(time)"
            case .monthly:
                // Matches `LaunchAgentService.formatCalendar`'s "Day N HH:mm" reader
                // output (not the ordinal form) so the string this produces and the
                // string a round-trip through the reader produces agree. Clamped to
                // the 1...28 range `setupCadence` accepts — an out-of-range policy
                // value must keep resolving to a valid cadence rather than throwing
                // cadenceParseError.
                let day = min(max(1, policy.reportsDayOfMonth), 28)
                return "Day \(day) \(time)"
            case .weekly, .off:
                return "\(weekdayAbbrev(policy.reportsWeekday)) \(time)"
            }
        }
    }

    // MARK: - Pure formatting helpers

    /// Add `offsetMinutes` to "HH:mm", clamped within the same day (never wraps
    /// past 23:59 — staggers are small and a wrap would reorder the agents).
    static func staggeredTime(base: String, offsetMinutes: Int) -> String {
        let parts = base.split(separator: ":").compactMap { Int($0) }
        let h = parts.count > 0 ? parts[0] : 6
        let m = parts.count > 1 ? parts[1] : 0
        let total = min(23 * 60 + 59, max(0, h * 60 + m) + offsetMinutes)
        return String(format: "%02d:%02d", total / 60, total % 60)
    }

    private static func weekdayAbbrev(_ weekday: Int) -> String {
        let names = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
        return names[min(max(0, weekday), 6)]
    }
}
