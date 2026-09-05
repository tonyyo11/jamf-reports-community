import Foundation

/// One hand-built schedule as persisted. Managed schedules are never stored —
/// they are derived from `AutomationPolicy` on every tick.
struct ScheduleRecord: Codable, Sendable, Equatable {
    var label: String
    var name: String
    /// Owning profile slug; "" when `allProfiles`.
    var profile: String
    var allProfiles: Bool
    var excludedProfiles: [String]
    /// `Schedule.RunMode.rawValue`. Stored as a string so an unknown future
    /// mode decodes and is skipped rather than failing the whole file.
    var mode: String
    /// `CollectionTier.rawValue`s, sorted; nil = mode default.
    var tiers: [String]?
    /// Cadence string in the `LaunchAgentWriter.calendarIntervals(for:)` form.
    var schedule: String
    var enabled: Bool

    init?(schedule: Schedule) {
        guard let label = LaunchAgentWriter.label(for: schedule),
              !ManagedAutomation.owns(label) else { return nil }
        self.label = label
        self.name = schedule.name
        self.allProfiles = schedule.isMulti
        self.profile = schedule.isMulti ? "" : schedule.profile
        self.excludedProfiles = schedule.excludedProfiles ?? []
        self.mode = schedule.mode.rawValue
        self.tiers = schedule.tiers.map { $0.map(\.rawValue).sorted() }
        self.schedule = schedule.schedule
        self.enabled = schedule.enabled
    }

    enum CodingKeys: String, CodingKey {
        case label, name, profile, allProfiles, excludedProfiles, mode, tiers, schedule, enabled
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        label = try c.decode(String.self, forKey: .label)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? label
        profile = try c.decodeIfPresent(String.self, forKey: .profile) ?? ""
        allProfiles = try c.decodeIfPresent(Bool.self, forKey: .allProfiles) ?? false
        excludedProfiles = try c.decodeIfPresent([String].self, forKey: .excludedProfiles) ?? []
        mode = try c.decodeIfPresent(String.self, forKey: .mode) ?? Schedule.RunMode.jamfCLIOnly.rawValue
        tiers = try c.decodeIfPresent([String].self, forKey: .tiers)
        schedule = try c.decodeIfPresent(String.self, forKey: .schedule) ?? "Daily 06:00"
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
    }

    func toSchedule() -> Schedule {
        let runMode = Schedule.RunMode(rawValue: mode) ?? .jamfCLIOnly
        let tierSet: Set<CollectionTier>? = tiers.map {
            Set($0.compactMap(CollectionTier.init(rawValue:)))
        }
        return Schedule(
            name: name,
            profile: profile,
            schedule: schedule,
            cadence: "custom",
            mode: runMode,
            next: "—",
            last: "—",
            lastStatus: .ok,
            artifacts: [],
            enabled: enabled,
            launchAgentLabel: label,
            multiTarget: allProfiles ? MultiTarget(scope: .all, sequential: true) : nil,
            tiers: tierSet,
            excludedProfiles: allProfiles ? excludedProfiles : nil
        )
    }
}

/// JSON file of `ScheduleRecord`s. Missing or corrupt → empty (logged); writes
/// are atomic and 0o600. Every method re-reads the file, so two processes
/// (GUI + tick) never overwrite each other's edits with a stale copy.
struct ScheduleStore: Sendable {
    static let defaultURL = AppSupport.directory().appendingPathComponent("schedules.json")
    let url: URL

    init(url: URL = ScheduleStore.defaultURL) { self.url = url }

    func load() -> [ScheduleRecord] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        do {
            return try JSONDecoder().decode([ScheduleRecord].self, from: data)
        } catch {
            AppLogger.schedule.error(
                "schedules.json could not be decoded: \(error.localizedDescription, privacy: .public)")
            return []
        }
    }

    func save(_ records: [ScheduleRecord]) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(records)
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    func upsert(_ record: ScheduleRecord) throws {
        var records = load().filter { $0.label != record.label }
        records.append(record)
        try save(records.sorted { $0.label < $1.label })
    }

    func remove(label: String) throws {
        try save(load().filter { $0.label != label })
    }
}
