import Foundation

/// Two independent debug-logging flags for our OSLog subsystem.
struct DebugLoggingState: Equatable {
    /// Persist debug/info entries in the local store (PII still rendered `<private>`).
    var persistVerbose: Bool
    /// `Enable-Private-Data` — show interpolated values in full. Default off; warned.
    var revealPrivate: Bool
    static let off = DebugLoggingState(persistVerbose: false, revealPrivate: false)
}

/// Reads/writes the per-user OSLog Subsystems config plist (no privilege escalation —
/// it lives under the user's `~/Library/Preferences`). Changes take effect at the NEXT
/// process launch, since OSLog reads this configuration at process start.
///
/// Schema (`/Library/Preferences/Logging/Subsystems/<subsystem>.plist`, also the shape of
/// the `com.apple.system.logging` MDM payload): a `DEFAULT-OPTIONS` dict with
/// `Enable-Level`/`Persist` level strings (`Off`/`Default`/`Info`/`Debug`) and an
/// `Enable-Private-Data` Bool. Confirmed against `man log` (`level`/`persist` hierarchy).
enum DebugLoggingService {
    static let subsystem = "com.github.tonyyo11.jamf-reports-community"

    static var defaultPlistURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Preferences/Logging/Subsystems/\(subsystem).plist")
    }

    static func current(at url: URL = defaultPlistURL) -> DebugLoggingState {
        guard let data = try? Data(contentsOf: url),
              let root = try? PropertyListSerialization.propertyList(from: data, format: nil),
              let dict = root as? [String: Any] else { return .off }
        let opts = (dict["DEFAULT-OPTIONS"] as? [String: Any]) ?? [:]
        let persist = (opts["Persist"] as? String).map {
            ["info", "debug"].contains($0.lowercased())
        } ?? false
        let reveal = (opts["Enable-Private-Data"] as? Bool) ?? false
        return DebugLoggingState(persistVerbose: persist, revealPrivate: reveal)
    }

    static func apply(_ state: DebugLoggingState, at url: URL = defaultPlistURL) throws {
        var opts: [String: Any] = [:]
        if state.persistVerbose {
            opts["Enable-Level"] = "Debug"
            opts["Persist"] = "Debug"
        }
        if state.revealPrivate { opts["Enable-Private-Data"] = true }
        let dict: [String: Any] = opts.isEmpty ? [:] : ["DEFAULT-OPTIONS": opts]
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try PropertyListSerialization.data(fromPropertyList: dict, format: .xml, options: 0)
        try data.write(to: url, options: .atomic)
    }
}
