@testable import JamfReports

// Accessors only the contract tests read; the app reads `entry(for:)` and the `Entry` fields.
extension CommandCatalog {
    func exists(path: [String]) -> Bool { entry(for: path) != nil }
    /// True when `path` is the row's own name, not an alias of it.
    func isCanonical(path: [String]) -> Bool { byPath[path.joined(separator: " ")] != nil }
    func scopes(for path: [String]) -> [String]? { entry(for: path)?.scopes }
    func product(for path: [String]) -> String? { entry(for: path)?.product }
    func api(for path: [String]) -> String? { entry(for: path)?.api }
    func isDestructive(path: [String]) -> Bool? { entry(for: path)?.destructive }
    func isPreview(path: [String]) -> Bool { entry(for: path)?.preview ?? false }
}

extension WorkspaceMergeJournal.Pending {
    var isUnreadable: Bool {
        if case .unreadable = self { return true }
        return false
    }
}
