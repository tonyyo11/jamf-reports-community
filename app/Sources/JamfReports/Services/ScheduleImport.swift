import Foundation

/// One-time move of legacy plists into the schedule store. Pure `plan`, thin
/// `runIfNeeded`. Managed labels are never imported (the policy describes
/// them); the caller archives and removes those without asking.
enum ScheduleImport {
    static let defaultsKey = "schedulesImportedV1"

    struct Result: Sendable, Equatable {
        let imported: [ScheduleRecord]
        let managedLabels: [String]
        let unparseable: [String]
    }

    static func plan(installed: [Schedule], unparseable: [String]) -> Result {
        var imported: [ScheduleRecord] = []
        var managed: [String] = []
        for schedule in installed {
            guard let label = schedule.launchAgentLabel else { continue }
            if ManagedAutomation.owns(label) {
                managed.append(label)
                continue
            }
            if let record = ScheduleRecord(schedule: schedule) {
                imported.append(record)
            }
        }
        return Result(
            imported: imported.sorted { $0.label < $1.label },
            managedLabels: managed.sorted(),
            unparseable: unparseable
        )
    }

    /// Runs once per machine. Existing store records win over an imported
    /// plist with the same label — an operator's edit is never undone by a
    /// stale plist. Returns nil when the import already happened.
    @discardableResult
    static func runIfNeeded(
        store: ScheduleStore = ScheduleStore(),
        defaults: UserDefaults = .standard,
        key: String = defaultsKey,
        installed: () -> (schedules: [Schedule], unparseable: [String])
            = { LaunchAgentService.installedLegacy() }
    ) -> Result? {
        guard !defaults.bool(forKey: key) else { return nil }
        let found = installed()
        let result = plan(installed: found.schedules, unparseable: found.unparseable)
        let existing = Set(store.load().map(\.label))
        var failed = false
        for record in result.imported where !existing.contains(record.label) {
            do {
                try store.upsert(record)
            } catch {
                failed = true
                AppLogger.schedule.error(
                    """
                    import of \(record.label, privacy: .public) failed: \
                    \(error.localizedDescription, privacy: .public)
                    """
                )
            }
        }
        for name in result.unparseable {
            AppLogger.schedule.warning("import skipped unparseable plist \(name, privacy: .public)")
        }
        // A failed write leaves the flag unset so the next launch retries.
        if !failed { defaults.set(true, forKey: key) }
        return result
    }
}
