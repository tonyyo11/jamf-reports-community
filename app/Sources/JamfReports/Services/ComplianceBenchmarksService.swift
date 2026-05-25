import Foundation

/// Reads cached Platform API compliance snapshots from the workspace's
/// `compliance-rules/` and `compliance-devices/` directories and prepares
/// them for `ComplianceBenchmarksView`.
///
/// The Platform API is experimental (jamf-cli v1.14 beta), so this service
/// only reports on what is on disk — it never invokes jamf-cli. Whether the
/// snapshots exist at all is the upstream collect path's responsibility,
/// itself gated by ``experimental.platform_features_enabled`` and a
/// ``has_platform_auth`` probe on the Python side.
///
/// Decoded shapes track ``ComplianceRuleRow`` and ``ComplianceDeviceRow``
/// in ``JamfCLIDecoder.swift`` so a parser-level field rename is felt in
/// one place.
struct ComplianceBenchmarksService: Sendable {

    /// Everything the view needs to render. `.empty` when the workspace has
    /// no cached compliance data — the view falls back to its locked or
    /// empty state in that case.
    struct Snapshot: Sendable, Equatable, CacheSourceProviding {
        let rules: [Rule]
        let devices: [Device]
        let rulesSourceFile: URL?
        let devicesSourceFile: URL?
        let snapshotDate: Date?

        struct Rule: Sendable, Equatable, Identifiable {
            let rule: String
            let passed: Int
            let failed: Int?
            let unknown: Int
            let devices: Int
            let passRate: String
            var id: String { rule }
        }

        struct Device: Sendable, Equatable, Identifiable {
            let device: String
            let deviceId: String
            let rulesPassed: Int
            let rulesFailed: Int?
            let compliance: String
            var id: String { deviceId.isEmpty ? device : deviceId }
        }

        var totalRules: Int { rules.count }
        var totalDevices: Int { devices.count }

        /// Pass / Fail / Unknown across all rules. "Unknown" covers rules
        /// where the upstream returned no `failed` key — distinct from
        /// `failed == 0`, which means "evaluated and passing". Per-rule
        /// `unknown` counts (explicit unknown devices) are folded into the
        /// total unknown bucket regardless of branch.
        var ruleAggregate: (passed: Int, failed: Int, unknown: Int) {
            var passed = 0
            var failed = 0
            var unknown = 0
            for rule in rules {
                if let f = rule.failed {
                    passed += rule.passed
                    failed += f
                    unknown += rule.unknown
                } else {
                    unknown += rule.passed + rule.unknown
                }
            }
            return (passed, failed, unknown)
        }

        /// Devices grouped by whether they have known failures, are fully
        /// passing, or are in an unknown state. Drives the device-table
        /// counter cards.
        var deviceAggregate: (failing: Int, passing: Int, unknown: Int) {
            var failing = 0
            var passing = 0
            var unknown = 0
            for device in devices {
                if let f = device.rulesFailed {
                    if f > 0 { failing += 1 } else { passing += 1 }
                } else {
                    unknown += 1
                }
            }
            return (failing, passing, unknown)
        }

        var cacheSource: CacheSource {
            CacheSource.from(snapshotDate: snapshotDate, withinHours: 36)
        }

        static let empty = Snapshot(
            rules: [],
            devices: [],
            rulesSourceFile: nil,
            devicesSourceFile: nil,
            snapshotDate: nil
        )
    }

    /// Returns the newest compliance snapshot for `profile`. Returns
    /// `.empty` when no compliance data has been collected — that's the
    /// expected state pre-first-collect or on a tenant without Platform
    /// API access. The view renders its locked or empty state.
    static func load(profile: String) -> Snapshot {
        guard let dir = (try? WorkspacePaths.dataDir(for: profile)) else {
            return .empty
        }
        let rulesDir = dir.appendingPathComponent("compliance-rules", isDirectory: true)
        let devicesDir = dir.appendingPathComponent("compliance-devices", isDirectory: true)
        let rulesURL = newestJSON(in: rulesDir)
        let devicesURL = newestJSON(in: devicesDir)
        return load(rulesURL: rulesURL, devicesURL: devicesURL)
    }

    /// Test seam.
    static func load(rulesURL: URL?, devicesURL: URL?) -> Snapshot {
        let rules = rulesURL.flatMap(decodeRules) ?? []
        let devices = devicesURL.flatMap(decodeDevices) ?? []
        let dates = [rulesURL, devicesURL]
            .compactMap { $0 }
            .compactMap {
                (try? $0.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate
            }
        return Snapshot(
            rules: rules,
            devices: devices,
            rulesSourceFile: rulesURL,
            devicesSourceFile: devicesURL,
            snapshotDate: dates.max()
        )
    }

    // MARK: - Internals

    private static func decodeRules(at url: URL) -> [Snapshot.Rule]? {
        guard let data = try? Data(contentsOf: url),
              let items = try? JSONDecoder().decode([RawRule].self, from: data) else {
            return nil
        }
        return items.map { raw in
            Snapshot.Rule(
                rule: raw.rule ?? "",
                passed: raw.passed ?? 0,
                failed: raw.failed,
                unknown: raw.unknown ?? 0,
                devices: raw.devices ?? 0,
                passRate: raw.passRate ?? ""
            )
        }
    }

    private static func decodeDevices(at url: URL) -> [Snapshot.Device]? {
        guard let data = try? Data(contentsOf: url),
              let items = try? JSONDecoder().decode([RawDevice].self, from: data) else {
            return nil
        }
        return items.map { raw in
            Snapshot.Device(
                device: raw.device ?? "",
                deviceId: raw.deviceId ?? "",
                rulesPassed: raw.rulesPassed ?? 0,
                rulesFailed: raw.rulesFailed,
                compliance: raw.compliance ?? ""
            )
        }
    }

    private static func newestJSON(in dir: URL) -> URL? {
        let fm = FileManager.default
        guard fm.fileExists(atPath: dir.path) else { return nil }
        guard let files = try? fm.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return nil }
        return files
            .filter { $0.pathExtension == "json" }
            .max { lhs, rhs in
                let l = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate ?? .distantPast
                let r = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate ?? .distantPast
                return l < r
            }
    }

    private struct RawRule: Decodable {
        let rule: String?
        let passed: Int?
        let failed: Int?
        let unknown: Int?
        let devices: Int?
        let passRate: String?
    }

    private struct RawDevice: Decodable {
        let device: String?
        let deviceId: String?
        let rulesPassed: Int?
        let rulesFailed: Int?
        let compliance: String?
    }
}
