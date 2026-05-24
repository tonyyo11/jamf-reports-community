import Foundation
import SwiftUI

/// Persists per-feature opt-ins for v2.1.0 experimental flags. Backed by
/// `UserDefaults` under the `experimentalFeatures` key — a comma-separated
/// list of raw values.
///
/// `@Observable` so SwiftUI views auto-refresh after a toggle. The
/// underlying `UserDefaults` write is the source of truth; the in-memory
/// `enabled` snapshot is rebuilt from disk after each mutation so multiple
/// instances pointing at the same suite agree.
@MainActor
@Observable
final class ExperimentalFeatureService {

    /// Per-feature identifiers. Raw values are stable (used as
    /// `UserDefaults` storage tokens) — do not rename without a migration.
    /// Raw values must not contain commas — the storage format is comma-delimited.
    enum Feature: String, CaseIterable, Sendable {
        case platformAPI = "platform-api"
        case protect = "protect-deep-dive"

        var displayName: String {
            switch self {
            case .platformAPI: return "Platform API"
            case .protect:     return "Jamf Protect deep dive"
            }
        }

        var description: String {
            switch self {
            case .platformAPI:
                return "Compliance benchmarks and DDM blueprint dashboards. "
                    + "Built on jamf-cli's Platform API integration."
            case .protect:
                return "Per-device alert timeline and kill-chain stage breakdown "
                    + "for tenants with Jamf Protect configured in jamf-cli."
            }
        }

        /// Community discussion category — surfaced as a "Learn more" link
        /// alongside the toggle. Categories may not exist yet; the URL points
        /// at the path admins should land on once they do.
        var discussionURL: URL? {
            switch self {
            case .platformAPI:
                return URL(
                    string: "https://github.com/tonyyo11/jamf-reports-community/discussions/categories/platform-api"
                )
            case .protect:
                return URL(
                    string: "https://github.com/tonyyo11/jamf-reports-community/discussions/categories/jamf-protect"
                )
            }
        }
    }

    /// Storage key under the supplied `UserDefaults` suite. Single string for
    /// the whole set rather than one key per feature, so adding a new feature
    /// doesn't require a migration pass over existing prefs.
    static let storageKey = "experimentalFeatures"

    private let defaults: UserDefaults
    private(set) var enabled: Set<Feature> = []

    /// Default initializer reads from the standard `UserDefaults` suite. The
    /// optional parameter exists for tests, which inject an isolated suite to
    /// avoid leaking writes into the user's real preferences.
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.enabled = Self.load(from: defaults)
    }

    func isEnabled(_ feature: Feature) -> Bool {
        enabled.contains(feature)
    }

    func setEnabled(_ feature: Feature, _ on: Bool) {
        var next = enabled
        if on { next.insert(feature) } else { next.remove(feature) }
        guard next != enabled else { return }
        Self.save(next, to: defaults)
        enabled = next
    }

    // MARK: - Storage

    private static func load(from defaults: UserDefaults) -> Set<Feature> {
        let raw = defaults.string(forKey: storageKey) ?? ""
        guard !raw.isEmpty else { return [] }
        let tokens = raw.split(separator: ",").map { String($0) }
        var result: Set<Feature> = []
        for token in tokens {
            if let feature = Feature(rawValue: token) {
                result.insert(feature)
            }
        }
        return result
    }

    private static func save(_ features: Set<Feature>, to defaults: UserDefaults) {
        // Sort by raw value so the serialized form is stable — easier to
        // inspect via `defaults read` and easier to diff in test assertions.
        let tokens = features.map(\.rawValue).sorted()
        let joined = tokens.joined(separator: ",")
        if joined.isEmpty {
            defaults.removeObject(forKey: storageKey)
        } else {
            defaults.set(joined, forKey: storageKey)
        }
    }
}
