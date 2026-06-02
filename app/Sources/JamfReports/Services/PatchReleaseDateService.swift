import Foundation

// MARK: - PatchReleaseDateService

/// Reads the merged `patch-release-dates` snapshot from the workspace's
/// jamf-cli data directory.
///
/// The merged snapshot is written by `ReportEngine.collect` after fetching
/// per-title patch definitions. Python's `JamfCLIBridge.collect_patch_release_dates`
/// writes to the same location, so both engines share the same on-disk artifact.
///
/// Shape: `[{"title_id": "2", "title": "Mozilla Firefox",
///           "latest_version": "151.0.2", "release_date": "2026-05-26T13:48:54Z"}]`
struct PatchReleaseDateService: Sendable {

    struct Row: Decodable, Sendable, Equatable {
        let titleId: String
        let title: String
        let latestVersion: String
        let releaseDate: String

        private enum CodingKeys: String, CodingKey {
            case titleId    = "title_id"
            case title
            case latestVersion = "latest_version"
            case releaseDate   = "release_date"
        }
    }

    /// Returns the newest merged patch-release-dates snapshot for `profile`.
    /// Returns an empty array when none exists — normal pre-collect state.
    static func load(profile: String) -> [Row] {
        guard let dir = try? WorkspacePaths.dataDir(for: profile) else { return [] }
        return load(dataDir: dir)
    }

    /// Returns the newest merged patch-release-dates snapshot from `dataDir`.
    /// Returns an empty array when none exists — normal pre-collect state.
    static func load(dataDir: URL) -> [Row] {
        let releasesDir = dataDir.appendingPathComponent("patch-release-dates", isDirectory: true)
        guard let url = FileManager.newestJSONFile(in: releasesDir) else { return [] }
        return load(from: url)
    }

    /// Test seam: load directly from a file URL.
    static func load(from url: URL) -> [Row] {
        guard FileManager.default.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url),
              let rows = try? JSONDecoder().decode([Row].self, from: data)
        else { return [] }
        return rows
    }

    /// Build a lookup dictionary: patch title id → releaseDate ISO string.
    static func releaseDateLookup(from rows: [Row]) -> [String: String] {
        Dictionary(uniqueKeysWithValues: rows.map { ($0.titleId, $0.releaseDate) })
    }

    // MARK: - Matching logic

    /// Return the best matching definition's (version, releaseDate) for one title.
    ///
    /// Priority (mirrors Python `_latest_definition_date`):
    /// 1. Exact match on `latestVersion`.
    /// 2. `absoluteOrderId == "0"` (newest-first default sort from jamf-cli).
    /// 3. First record.
    ///
    /// Returns `("", "")` when `definitions` is empty.
    static func latestDefinitionDate(
        definitions: [[String: Any]],
        latestVersion: String
    ) -> (version: String, releaseDate: String) {
        guard !definitions.isEmpty else { return ("", "") }
        let target = latestVersion.trimmingCharacters(in: .whitespacesAndNewlines)

        // 1. Exact version match.
        if !target.isEmpty {
            for def in definitions {
                let v = (def["version"] as? String ?? "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if v == target {
                    return (v, (def["releaseDate"] as? String ?? "")
                        .trimmingCharacters(in: .whitespacesAndNewlines))
                }
            }
        }

        // 2. absoluteOrderId == "0".
        for def in definitions {
            let orderId = (def["absoluteOrderId"] as? String ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if orderId == "0" {
                let v = (def["version"] as? String ?? "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                return (v, (def["releaseDate"] as? String ?? "")
                    .trimmingCharacters(in: .whitespacesAndNewlines))
            }
        }

        // 3. First record.
        let first = definitions[0]
        return (
            (first["version"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
            (first["releaseDate"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    // MARK: - Days behind helper

    /// Compute the number of days between a release date ISO string and `referenceDate`.
    /// Returns nil when `releaseDate` is empty or unparseable.
    static func daysBehind(releaseDate: String, referenceDate: Date = Date()) -> Int? {
        guard let date = SOFAFeedService.parseSOFADate(releaseDate) else { return nil }
        let diff = Calendar.current.dateComponents([.day], from: date, to: referenceDate)
        guard let days = diff.day else { return nil }
        return max(0, days)
    }
}
