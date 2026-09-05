import Foundation

/// Per-machine app state that is NOT workspace data: the schedule store, the
/// tick stamps and lock. Never inside a workspace — a workspace may be a synced
/// team folder, and schedules belong to one Mac.
enum AppSupport {
    static func directory(
        fileManager: FileManager = .default,
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        let dir = home.appendingPathComponent(
            "Library/Application Support/JamfReports", isDirectory: true)
        try? fileManager.createDirectory(
            at: dir, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        try? fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
        return dir
    }
}
