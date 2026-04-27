import Foundation

extension CLIBridge {

    /// Run `jrc` immediately for `profile` and `mode`, streaming each output line through `onLine`.
    ///
    /// Profile is validated with `ProfileService.isValid` before any subprocess is launched.
    /// For `jamfCLIFull` and `csvAssisted`, the newest CSV in the profile workspace is used when
    /// `csvPath` is nil; the search checks `csv-inbox/` first, then the workspace root.
    func runNow(
        profile: String,
        mode: Schedule.RunMode,
        csvPath: URL? = nil,
        onLine: @Sendable @escaping (LogLine) -> Void
    ) async -> Int32 {
        guard ProfileService.isValid(profile) else {
            onLine(.init(timestamp: Date(), level: .fail, text: "[error] invalid profile name: \(profile)"))
            return -1
        }
        guard resolveJRCCommand() != nil else {
            onLine(.init(timestamp: Date(), level: .fail, text: "[error] jrc or jamf-reports-community.py not found"))
            return -1
        }
        switch mode {
        case .snapshotOnly:
            return await collect(profile: profile, onLine: onLine)
        case .jamfCLIOnly:
            return await collectThenGenerate(profile: profile, csvPath: nil, onLine: onLine)
        case .jamfCLIFull, .csvAssisted:
            return await collectThenGenerate(
                profile: profile,
                csvPath: (csvPath ?? newestCSV(in: profile))?.path,
                onLine: onLine
            )
        }
    }

    // MARK: - Private

    /// Newest `.csv` in the profile workspace (`csv-inbox/` preferred; falls back to root).
    private func newestCSV(in profile: String) -> URL? {
        guard let workspace = ProfileService.workspaceURL(for: profile) else { return nil }
        let inbox  = workspace.appendingPathComponent("csv-inbox")
        let dir    = FileManager.default.fileExists(atPath: inbox.path) ? inbox : workspace
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
