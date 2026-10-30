import Foundation

/// One hand-built schedule as persisted. Managed schedules are never stored —
/// they are derived from `AutomationPolicy` on every tick.
struct ScheduleRecord: Codable, Sendable, Equatable {
    var label: String
    var name: String
    /// The owning workspace ID; "" when `allWorkspaces`. The JSON keys stay `profile`,
    /// `allProfiles` and `excludedProfiles`, so a file written before 2.12 decodes to the same
    /// values and an older build still reads one written now.
    var workspace: String
    var allWorkspaces: Bool
    var excludedWorkspaces: [String]
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
        self.allWorkspaces = schedule.isMulti
        self.workspace = schedule.isMulti ? "" : schedule.profile
        self.excludedWorkspaces = schedule.excludedProfiles ?? []
        self.mode = schedule.mode.rawValue
        self.tiers = schedule.tiers.map { $0.map(\.rawValue).sorted() }
        self.schedule = schedule.schedule
        self.enabled = schedule.enabled
    }

    enum CodingKeys: String, CodingKey {
        case label, name, mode, tiers, schedule, enabled
        case workspace = "profile"
        case allWorkspaces = "allProfiles"
        case excludedWorkspaces = "excludedProfiles"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        label = try c.decode(String.self, forKey: .label)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? label
        workspace = try c.decodeIfPresent(String.self, forKey: .workspace) ?? ""
        allWorkspaces = try c.decodeIfPresent(Bool.self, forKey: .allWorkspaces) ?? false
        excludedWorkspaces =
            try c.decodeIfPresent([String].self, forKey: .excludedWorkspaces) ?? []
        mode = try c.decodeIfPresent(String.self, forKey: .mode)
            ?? Schedule.RunMode.jamfCLIOnly.rawValue
        tiers = try c.decodeIfPresent([String].self, forKey: .tiers)
        schedule = try c.decodeIfPresent(String.self, forKey: .schedule) ?? "Daily 06:00"
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
    }

    func toSchedule() -> Schedule {
        let runMode = Schedule.RunMode(stored: mode) ?? .jamfCLIOnly
        let tierSet: Set<CollectionTier>? = tiers.map {
            Set($0.compactMap(CollectionTier.init(rawValue:)))
        }
        return Schedule(
            name: name,
            profile: workspace,
            schedule: schedule,
            cadence: "custom",
            mode: runMode,
            next: "—",
            last: "—",
            lastStatus: .ok,
            artifacts: [],
            enabled: enabled,
            launchAgentLabel: label,
            multiTarget: allWorkspaces ? MultiTarget(scope: .all, sequential: true) : nil,
            tiers: tierSet,
            excludedProfiles: allWorkspaces ? excludedWorkspaces : nil,
            retiredCSVAssisted: mode == Schedule.RunMode.retiredCSVAssistedRaw
        )
    }
}

/// JSON file of `ScheduleRecord`s. Missing or corrupt → empty (logged); writes
/// are atomic and 0o600. Every method re-reads the file, so two processes
/// (GUI + tick) never overwrite each other's edits with a stale copy.
struct ScheduleStore: Sendable {
    static var defaultURL: URL { AppSupport.directory().appendingPathComponent("schedules.json") }
    let url: URL

    init(url: URL = ScheduleStore.defaultURL) { self.url = url }

    func load() -> [ScheduleRecord] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        do {
            return try JSONDecoder().decode([ScheduleRecord].self, from: data)
        } catch {
            let aside = setAsideCorruptFile()
            AppLogger.schedule.error(
                """
                schedules.json could not be decoded: \
                \(error.localizedDescription, privacy: .private) — moved to \
                \(aside?.lastPathComponent ?? "(move failed)", privacy: .private)
                """
            )
            return []
        }
    }

    /// The next `upsert`/`remove` rewrites the whole file, so a corrupt one is
    /// moved to `schedules.json.broken-<stamp>` first rather than overwritten.
    private func setAsideCorruptFile() -> URL? {
        let stamp = ScheduledRunRecorder.timestamp(from: Date())
        let aside = url.appendingPathExtension("broken-\(stamp)")
        do {
            try FileManager.default.moveItem(at: url, to: aside)
            return aside
        } catch {
            return nil
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
