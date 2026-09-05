import Foundation

/// Per-machine app state that is NOT workspace data: the schedule store, the
/// tick stamps and lock. Never inside a workspace — a workspace may be a synced
/// team folder, and schedules belong to one Mac.
enum AppSupport {
    static func directory(
        fileManager: FileManager = .default,
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        let dir = resolved(home: home)
        try? fileManager.createDirectory(
            at: dir, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        try? fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
        return dir
    }

    /// Where the store actually lives. A test root wins in DEBUG so a test can
    /// never write the developer's real store: the schedule records, the tick
    /// stamps and the lock all live here, and a test that took the lock would
    /// block a real ticker wake.
    private static func resolved(home: URL) -> URL {
        #if DEBUG
        let environment = ProcessInfo.processInfo.environment
        if let root = environment["JRC_TEST_WORKSPACES_ROOT"], !root.isEmpty {
            return URL(fileURLWithPath: root, isDirectory: true)
                .appendingPathComponent(".app-support", isDirectory: true)
        }
        #endif
        return home.appendingPathComponent(
            "Library/Application Support/JamfReports", isDirectory: true)
    }
}
