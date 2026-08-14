import Foundation

extension CLIBridge {

    /// Run collect/generate immediately for `profile` and `mode`, streaming each output line through `onLine`.
    ///
    /// Profile is validated with `ProfileService.isValid` before any subprocess is launched.
    ///
    /// PR-21 mode contract (each branch is distinct, with no operational overlap):
    /// - `.snapshotOnly`: collect only — emits a Trends summary, produces no workbook.
    /// - `.jamfCLIOnly`: generate from cached data only — skips collect entirely, so a
    ///   re-render after editing config or templates is fast and offline.
    /// - `.jamfCLIFull`: collect + generate with no CSV input.
    /// - `.csvAssisted`: collect + generate with a required CSV from `csv-inbox/`. Hard-fails
    ///   when no CSV is found rather than silently degrading to a jamf-cli-only workbook —
    ///   the mode's whole purpose is "I have CSV data I want included."
    func runNow(
        profile: String,
        mode: Schedule.RunMode,
        csvPath: URL? = nil,
        onLine: @Sendable @escaping (LogLine) -> Void
    ) async throws -> Int32 {
        guard ProfileService.isValid(profile) else {
            onLine(.init(timestamp: Date(), level: .fail, text: "[error] invalid profile name: \(profile)"))
            throw CLIBridgeError.invalidProfile(profile)
        }
        switch mode {
        case .snapshotOnly:
            // GUI "Run now" is always ad-hoc — bypass the once-per-day guard.
            return try await collect(profile: profile, force: true, onLine: onLine)
        case .jamfCLIOnly:
            return try await generate(profile: profile, csvPath: nil, onLine: onLine)
        case .jamfCLIFull:
            return try await collectThenGenerate(profile: profile, csvPath: nil, onLine: onLine)
        case .csvAssisted:
            guard let csv = csvPath ?? Self.newestCSV(in: profile) else {
                onLine(.init(
                    timestamp: Date(), level: .fail,
                    text: "[error] csv-assisted requires a CSV in csv-inbox/ — none found. " +
                          "Drop a Jamf Pro export there, or pick the Refresh + Generate mode instead."
                ))
                throw CLIBridgeError.csvMissing(profile: profile)
            }
            return try await collectThenGenerate(profile: profile, csvPath: csv.path, onLine: onLine)
        case .backup:
            // Scheduled/manual configuration backup — no collect, no report.
            // Retention keeps the newest N scheduled backups; manual backups
            // from BackupsView (no "scheduled-" prefix) are never pruned.
            let exit = try await backup(
                profile: profile,
                label: "scheduled-\(BackupMaintenance.dateStamp())",
                onLine: onLine
            )
            // Exit 7 keeps its partial export on disk (see CLIBridge.backup), so
            // retention has to see it too — otherwise partial backups accumulate
            // unpruned forever. Mirrors main.swift's scheduled-run backup path.
            if Self.backupOutputIsPrunable(exit: exit) {
                BackupMaintenance.performPostSuccessHousekeeping(profile: profile, onLine: onLine)
            }
            return exit
        }
    }

    // MARK: - Internal helpers

    /// Newest `.csv` in the profile workspace (`csv-inbox/` preferred; falls back to root).
    ///
    /// Shared with `main.swift`'s `--scheduled-run` dispatch so the GUI "Run now" path and
    /// the LaunchAgent path pick the same file. `nonisolated` because both call sites need
    /// it (the headless `scheduled-run` is detached and not main-actor-bound), and the
    /// implementation only touches `FileManager` + value types.
    nonisolated static func newestCSV(in profile: String) -> URL? {
        guard let workspace = ProfileService.workspaceURL(for: profile) else { return nil }
        let inbox = workspace.appendingPathComponent("csv-inbox")
        let dir = FileManager.default.fileExists(atPath: inbox.path) ? inbox : workspace
        return (try? FileManager.default.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ))?
        .filter { $0.pathExtension.lowercased() == "csv" }
        .max {
            let a = (try? $0.resourceValues(forKeys: [.contentModificationDateKey])
                         .contentModificationDate) ?? .distantPast
            let b = (try? $1.resourceValues(forKeys: [.contentModificationDateKey])
                         .contentModificationDate) ?? .distantPast
            return a < b
        }
    }
}
