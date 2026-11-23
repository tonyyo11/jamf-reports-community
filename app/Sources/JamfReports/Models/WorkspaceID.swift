import Foundation

/// One workspace: the name its folder encodes under the workspaces root, by the `ProfileName`
/// rules. Folders, labels, pins, schedules, report groups and Run History key on it; the jamf-cli
/// profile a command passes as `-p` comes from `EnvironmentProfiles` and is a plain `String`, so
/// the two cannot be swapped. A workspace made before 2.12 has the ID of the profile it was made
/// for, so no folder, label or file name changes.
struct WorkspaceID: Hashable, Sendable, CustomStringConvertible {
    let name: String

    /// Nil for a name `ProfileService.isValid` refuses.
    init?(_ name: String) {
        guard ProfileService.isValid(name) else { return nil }
        self.name = name
    }

    /// For a caller that names a workspace as text: an invalid name throws
    /// `ReportEngineError.invalidProfile`, as the engine always has.
    init(validating name: String) throws {
        guard let id = WorkspaceID(name) else { throw ReportEngineError.invalidProfile(name) }
        self = id
    }

    var pathComponent: String { ProfileName.pathComponent(name) }
    var labelComponent: String { ProfileName.labelComponent(name) }
    var description: String { name }
}
