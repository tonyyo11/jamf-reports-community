import Foundation

/// One-time move of legacy plists into the schedule store. Pure `plan`, thin
/// `runIfNeeded`. Managed labels are never imported (the policy describes
/// them); the caller archives and removes those without asking. A multi-profile plist scoped
/// to a list or a filter is refused: the store holds only "all profiles", and importing it
/// would run the schedule against every profile.
enum ScheduleImport {
    static let defaultsKey = "schedulesImportedV1"

    struct Refusal: Sendable, Equatable {
        let label: String
        let reason: String
    }

    struct Result: Sendable, Equatable {
        let imported: [ScheduleRecord]
        let managedLabels: [String]
        let unparseable: [String]
        let refused: [Refusal]
    }

    static func plan(installed: [Schedule], unparseable: [String]) -> Result {
        var imported: [ScheduleRecord] = []
        var managed: [String] = []
        var refused: [Refusal] = []
        for schedule in installed {
            guard let label = schedule.launchAgentLabel else { continue }
            if ManagedAutomation.owns(label) {
                managed.append(label)
                continue
            }
            if let reason = narrowScopeReason(schedule.multiTarget) {
                refused.append(Refusal(label: label, reason: reason))
                continue
            }
            if let record = ScheduleRecord(schedule: schedule) {
                imported.append(record)
            }
        }
        return Result(
            imported: imported.sorted { $0.label < $1.label },
            managedLabels: managed.sorted(),
            unparseable: unparseable,
            refused: refused.sorted { $0.label < $1.label }
        )
    }

    private static func narrowScopeReason(_ target: MultiTarget?) -> String? {
        switch target?.scope {
        case .list: "it is scoped to a list of profiles"
        case .filter: "it is scoped by a profile name filter"
        case .all, nil: nil
        }
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
        for refusal in result.refused {
            AppLogger.schedule.warning(
                """
                import refused \(refusal.label, privacy: .public): \
                \(refusal.reason, privacy: .public); the plist is left in place, \
                rebuild the schedule in the app
                """
            )
        }
        // A failed write leaves the flag unset so the next launch retries.
        if !failed { defaults.set(true, forKey: key) }
        return result
    }
}
