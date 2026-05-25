import Foundation

/// Reads cached Platform API DDM and blueprint snapshots from the
/// workspace's `blueprint-status/` and `ddm-status/` directories and
/// prepares them for ``DDMBlueprintView``.
///
/// Same posture as ``ComplianceBenchmarksService``: the Platform API is
/// experimental (jamf-cli v1.14 beta), so this service only reports on
/// what is on disk — it never invokes jamf-cli. Whether the snapshots
/// exist at all is the upstream collect path's responsibility, itself
/// gated by ``experimental.platform_features_enabled`` and a
/// ``has_platform_auth`` probe on the Python side.
///
/// Decoded shapes track ``BlueprintStatusRow`` and ``DDMStatusRow`` in
/// ``JamfCLIDecoder.swift`` so a parser-level field rename is felt in
/// one place.
struct DDMBlueprintService: Sendable {

    /// Everything the view needs to render. `.empty` when the workspace
    /// has no cached blueprint or DDM data — the view falls back to its
    /// locked or empty state in that case.
    struct Snapshot: Sendable, Equatable, CacheSourceProviding {
        let blueprints: [Blueprint]
        let declarations: [Declaration]
        let blueprintsSourceFile: URL?
        let declarationsSourceFile: URL?
        let snapshotDate: Date?

        struct Blueprint: Sendable, Equatable, Identifiable {
            let name: String
            let state: String
            let scope: Int
            let steps: Int
            let succeeded: Int
            let failed: Int?
            let pending: Int?
            var id: String { name.isEmpty ? "(unnamed)-\(state)-\(scope)" : name }
        }

        struct Declaration: Sendable, Equatable, Identifiable {
            let source: String
            let type: String
            let declarations: Int
            let devices: Int
            let successful: Int
            let unsuccessful: Int
            var id: String { source.isEmpty ? "(no-source)-\(type)" : source }
        }

        var totalBlueprints: Int { blueprints.count }
        var totalDeclarationSources: Int { declarations.count }

        /// Adoption is the fraction of blueprints whose `state` is
        /// `DEPLOYED`. Anything else (`NOT_DEPLOYED`, `OUT_OF_DATE`, …)
        /// counts as not deployed. Returns 0 when there are no
        /// blueprints to avoid divide-by-zero.
        var adoptionRate: Double {
            guard !blueprints.isEmpty else { return 0 }
            let deployed = blueprints.filter {
                $0.state.uppercased() == "DEPLOYED"
            }.count
            return Double(deployed) / Double(blueprints.count)
        }

        /// Deployed / Not deployed / With failures / With pending — the
        /// four counter cards on the blueprint summary. "With failures"
        /// and "with pending" are independent of state so a deployed
        /// blueprint can also show up in those buckets.
        var blueprintAggregate: (deployed: Int, notDeployed: Int, failing: Int, pending: Int) {
            var deployed = 0
            var notDeployed = 0
            var failing = 0
            var pending = 0
            for blueprint in blueprints {
                if blueprint.state.uppercased() == "DEPLOYED" {
                    deployed += 1
                } else {
                    notDeployed += 1
                }
                if (blueprint.failed ?? 0) > 0 { failing += 1 }
                if (blueprint.pending ?? 0) > 0 { pending += 1 }
            }
            return (deployed, notDeployed, failing, pending)
        }

        /// Per-source declaration aggregate: how many sources have any
        /// unsuccessful declarations, and the running total of
        /// unsuccessful declarations across all sources.
        var declarationAggregate: (sourcesWithIssues: Int, unsuccessfulTotal: Int) {
            var sourcesWithIssues = 0
            var unsuccessfulTotal = 0
            for entry in declarations {
                if entry.unsuccessful > 0 { sourcesWithIssues += 1 }
                unsuccessfulTotal += entry.unsuccessful
            }
            return (sourcesWithIssues, unsuccessfulTotal)
        }

        var cacheSource: CacheSource {
            CacheSource.from(snapshotDate: snapshotDate, withinHours: 36)
        }

        static let empty = Snapshot(
            blueprints: [],
            declarations: [],
            blueprintsSourceFile: nil,
            declarationsSourceFile: nil,
            snapshotDate: nil
        )
    }

    /// Returns the newest DDM and blueprint snapshot for `profile`.
    /// Returns `.empty` when neither dataset has been collected — the
    /// expected state pre-first-collect or on a tenant without Platform
    /// API access. The view renders its locked or empty state.
    static func load(profile: String) -> Snapshot {
        guard let dir = (try? WorkspacePaths.dataDir(for: profile)) else {
            return .empty
        }
        let blueprintsDir = dir.appendingPathComponent("blueprint-status", isDirectory: true)
        let declarationsDir = dir.appendingPathComponent("ddm-status", isDirectory: true)
        let blueprintsURL = newestJSON(in: blueprintsDir)
        let declarationsURL = newestJSON(in: declarationsDir)
        return load(blueprintsURL: blueprintsURL, declarationsURL: declarationsURL)
    }

    /// Test seam.
    static func load(blueprintsURL: URL?, declarationsURL: URL?) -> Snapshot {
        let blueprints = blueprintsURL.flatMap(decodeBlueprints) ?? []
        let declarations = declarationsURL.flatMap(decodeDeclarations) ?? []
        let dates = [blueprintsURL, declarationsURL]
            .compactMap { $0 }
            .compactMap {
                (try? $0.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate
            }
        return Snapshot(
            blueprints: blueprints,
            declarations: declarations,
            blueprintsSourceFile: blueprintsURL,
            declarationsSourceFile: declarationsURL,
            snapshotDate: dates.max()
        )
    }

    // MARK: - Internals

    private static func decodeBlueprints(at url: URL) -> [Snapshot.Blueprint]? {
        guard let data = try? Data(contentsOf: url),
              let items = try? JSONDecoder().decode([RawBlueprint].self, from: data) else {
            return nil
        }
        return items.map { raw in
            Snapshot.Blueprint(
                name: raw.name ?? "",
                state: raw.state ?? "",
                scope: raw.scope ?? 0,
                steps: raw.steps ?? 0,
                succeeded: raw.succeeded ?? 0,
                failed: raw.failed,
                pending: raw.pending
            )
        }
    }

    private static func decodeDeclarations(at url: URL) -> [Snapshot.Declaration]? {
        guard let data = try? Data(contentsOf: url),
              let items = try? JSONDecoder().decode([RawDeclaration].self, from: data) else {
            return nil
        }
        return items.map { raw in
            Snapshot.Declaration(
                source: raw.source ?? "",
                type: raw.type ?? "",
                declarations: raw.declarations ?? 0,
                devices: raw.devices ?? 0,
                successful: raw.successful ?? 0,
                unsuccessful: raw.unsuccessful ?? 0
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

    private struct RawBlueprint: Decodable {
        let name: String?
        let state: String?
        let scope: Int?
        let steps: Int?
        let succeeded: Int?
        let failed: Int?
        let pending: Int?
    }

    private struct RawDeclaration: Decodable {
        let source: String?
        let type: String?
        let declarations: Int?
        let devices: Int?
        let successful: Int?
        let unsuccessful: Int?
    }
}
