import Foundation

/// Filesystem utilities shared across workspace-reading services.
extension FileManager {

    /// Returns the URL of the most recently modified `.json` file in `dir`,
    /// or nil if the directory doesn't exist, can't be read, or contains no
    /// JSON files. Skips hidden files.
    ///
    /// Epic #103: entries are canonicalized and must stay inside `dir`, so a
    /// symlink planted in a snapshot directory cannot point readers at a file
    /// outside the workspace.
    static func newestJSONFile(in dir: URL) -> URL? {
        let fm = FileManager.default
        guard fm.fileExists(atPath: dir.path) else { return nil }
        guard let files = try? fm.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return nil }
        let dirPrefix = dir.resolvingSymlinksInPath().standardizedFileURL.path + "/"
        return files
            .filter { $0.pathExtension == "json" }
            .compactMap { url -> URL? in
                let resolved = url.resolvingSymlinksInPath().standardizedFileURL
                return resolved.path.hasPrefix(dirPrefix) ? resolved : nil
            }
            .max { lhs, rhs in
                let l = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate ?? .distantPast
                let r = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate ?? .distantPast
                return l < r
            }
    }
}
