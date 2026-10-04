import Foundation

extension CLIBridge {

    /// Newest `.csv` in the profile workspace (`csv-inbox/` preferred; falls back to root).
    ///
    /// Used by `main.swift`'s `--scheduled-run` dispatch and `ConfigDoctorService`.
    /// `nonisolated` because the headless `scheduled-run` is detached and not main-actor-bound,
    /// and the implementation only touches `FileManager` + value types.
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
