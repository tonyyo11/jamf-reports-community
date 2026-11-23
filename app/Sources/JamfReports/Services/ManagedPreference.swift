import Foundation

/// Preference keys a configuration profile can set. A forced value wins over any write, so a
/// managed key's control is shown locked with `note` and the app never writes the key.
enum ManagedPreference {
    static var note: String { L("Set by your organization's configuration profile") }

    static func isForced(_ key: String, defaults: UserDefaults = .standard) -> Bool {
        defaults.objectIsForced(forKey: key)
    }
}
