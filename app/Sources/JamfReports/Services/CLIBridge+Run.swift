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
        guard let bin = locate("jrc") else {
            onLine(.init(timestamp: Date(), level: .fail, text: "[error] jrc not found on PATH"))
            return -1
        }
        let args = buildRunArgs(profile: profile, mode: mode, csvPath: csvPath)
        return await run(executable: bin, arguments: args, onLine: onLine)
    }

    // MARK: - Private

    private func buildRunArgs(profile: String, mode: Schedule.RunMode, csvPath: URL?) -> [String] {
        switch mode {
        case .snapshotOnly:
            return ["collect", "--profile", profile]

        case .jamfCLIOnly:
            return ["generate", "--profile", profile]

        case .jamfCLIFull:
            var args = ["generate", "--profile", profile]
            if let csv = csvPath ?? newestCSV(in: profile) {
                args += ["--csv", csv.path]
            }
            return args

        case .csvAssisted:
            var args = ["generate", "--profile", profile]
            if let csv = csvPath ?? newestCSV(in: profile) {
                args += ["--csv", csv.path]
            }
            return args
        }
    }

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
