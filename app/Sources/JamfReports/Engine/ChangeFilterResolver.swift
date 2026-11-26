import Foundation

/// Rebuilds the Macs behind a "Since last collect" count from the two snapshots the summary
/// names, so the Computers list is the same set the count was taken from. Synchronous: the
/// caller runs it off the main actor. It reads files and logs nothing.
enum ChangeFilterResolver {
    /// Every kind of the filter's pair (the computer kinds, or the patch kinds) at once, so one
    /// pair of decodes serves each count of that pair.
    nonisolated static func resolveAll(
        _ filter: ChangeFilter, dataDir: URL, rule: StaleRule, policy: SecurityControlPolicy
    ) -> [ChangeKind: ChangeFilterResult] {
        let outcomes = filter.kind.isPatch
            ? patchOutcomes(filter, dataDir: dataDir)
            : computerOutcomes(filter, dataDir: dataDir, rule: rule, policy: policy)
        switch outcomes {
        case .failure(let failed): return uniform(filter, failed.outcome)
        case .success(let results):
            var out = results
            for kind in results.keys {
                out[kind]?.ruleChanged = ruleChanged(filter.with(kind: kind), rule: rule, policy: policy)
            }
            return out
        }
    }

    /// `outcome` for every kind of the filter's pair.
    nonisolated static func uniform(
        _ filter: ChangeFilter, _ outcome: ChangeFilterResult.Outcome
    ) -> [ChangeKind: ChangeFilterResult] {
        let kinds = ChangeKind.allCases.filter { $0.isPatch == filter.kind.isPatch }
        return Dictionary(uniqueKeysWithValues: kinds.map { ($0, ChangeFilterResult(outcome: outcome)) })
    }

    /// Only the rule a kind depends on, and only when the summary recorded it: a value the
    /// summary does not hold is unknown, not changed.
    nonisolated static func ruleChanged(
        _ filter: ChangeFilter, rule: StaleRule, policy: SecurityControlPolicy
    ) -> Bool {
        switch filter.kind {
        case .fileVaultOff, .fileVaultStoppedReporting:
            return filter.fileVaultRule.map { $0 != policy.fileVaultFingerprint } ?? false
        case .becameStale, .noLongerStale:
            let days = filter.staleDays.map { $0 != rule.days } ?? false
            let basis = filter.staleBasis.map { $0 != rule.basis.map(\.rawValue) } ?? false
            return days || basis
        default:
            return false
        }
    }

    private struct Failed: Error { let outcome: ChangeFilterResult.Outcome }

    private static func computerOutcomes(
        _ filter: ChangeFilter, dataDir: URL, rule: StaleRule, policy: SecurityControlPolicy
    ) -> Result<[ChangeKind: ChangeFilterResult], Failed> {
        do {
            let current = try snapshot(stamp: filter.currentStamp, dataDir: dataDir)
            let prior = try snapshot(stamp: filter.baselineStamp, dataDir: dataDir)
            let drift = SnapshotFleetDrift(
                current: current.snapshot, currentAt: current.date,
                prior: prior.snapshot, priorAt: prior.date, rule: rule, policy: policy)
            try checkCancelled()
            func keys(_ macs: [ComputerDates]) -> ChangeFilterResult {
                ChangeFilterResult(outcome: .macs(macs.map { MacKey(jamfID: $0.jamfID, serial: $0.serial) }))
            }
            return .success([
                .joined: keys(drift.joined),
                .left: ChangeFilterResult(outcome: .left(drift.left)),
                .osChanged: keys(drift.osChanged.map(\.current)),
                .becameStale: keys(drift.becameStale.map(\.current)),
                .noLongerStale: keys(drift.noLongerStale.map(\.current)),
                .fileVaultOff: keys((drift.fileVaultOff ?? []).map(\.current)),
                .fileVaultStoppedReporting:
                    keys((drift.fileVaultStoppedReporting ?? []).map(\.current)),
            ])
        } catch let failed as Failed {
            return .failure(failed)
        } catch {
            return .failure(Failed(outcome: .unreadable(.undecodable)))
        }
    }

    private static func patchOutcomes(
        _ filter: ChangeFilter, dataDir: URL
    ) -> Result<[ChangeKind: ChangeFilterResult], Failed> {
        do {
            guard let computersStamp = filter.computersStamp else { throw Failed(outcome: .fileGone) }
            let computers = try snapshot(stamp: computersStamp, dataDir: dataDir)
            let now = try patchRows(stamp: filter.currentStamp, dataDir: dataDir)
            let before = try patchRows(stamp: filter.baselineStamp, dataDir: dataDir)
            let drift = PatchFailureDrift(
                current: now, baseline: before,
                computers: ComputerDateIndex(computers.snapshot.rows))
            func result(_ rows: [PatchFailureRow]) -> ChangeFilterResult {
                let ids = rows.map { $0.deviceId.trimmingCharacters(in: .whitespacesAndNewlines) }
                var seen = Set<String>()
                let macs = ids.filter { seen.insert($0).inserted }.map { MacKey(jamfID: $0) }
                return ChangeFilterResult(outcome: .macs(macs), failures: rows.count)
            }
            return .success([
                .patchStarted: result(drift.startedFailing),
                .patchNoLongerListed: result(drift.noLongerListed),
            ])
        } catch let failed as Failed {
            return .failure(failed)
        } catch {
            return .failure(Failed(outcome: .unreadable(.undecodable)))
        }
    }

    private static func checkCancelled() throws {
        if Task.isCancelled { throw Failed(outcome: .cancelled) }
    }

    /// The snapshot of `kind` whose name carries exactly `stamp`, found by listing, so a
    /// sync-conflict copy or a name built from the stamp is never read.
    private static func file(kind: String, stamp: String, dataDir: URL) throws -> (url: URL, date: Date) {
        // A kind folder replaced by a link lists nothing; it is refused, not gone.
        let folder = dataDir.appendingPathComponent(kind, isDirectory: true)
        if (try? FileManager.default.attributesOfItem(atPath: folder.path)[.type]
            as? FileAttributeType) == .typeSymbolicLink {
            throw Failed(outcome: .unreadable(.undecodable))
        }
        guard let found = TrendStore.datedSnapshots(of: kind, in: dataDir)
            .last(where: { PatchReleaseDateService.snapshotStamp(of: $0.url) == stamp })
        else { throw Failed(outcome: .fileGone) }
        return found
    }

    private static func read(_ url: URL, limit: Int, dataDir: URL) throws -> Data {
        do {
            let data = try BoundedFile.read(url, limit: limit, followSymlinks: false, inside: dataDir)
            try checkCancelled()
            return data
        } catch let failure as BoundedFile.Failure {
            switch failure {
            case .unreadable(ENOENT): throw Failed(outcome: .fileGone)
            case .tooLarge: throw Failed(outcome: .unreadable(.tooLarge))
            default: throw Failed(outcome: .unreadable(.undecodable))
            }
        }
    }

    private static func snapshot(
        stamp: String, dataDir: URL
    ) throws -> (snapshot: ComputerSnapshot, date: Date) {
        try checkCancelled()
        let found = try file(kind: "computers", stamp: stamp, dataDir: dataDir)
        let data = try read(found.url, limit: BoundedFile.inventoryLimit, dataDir: dataDir)
        guard let decoded = ComputerDates.decodeComputerSnapshot(data) else {
            throw Failed(outcome: .unreadable(.undecodable))
        }
        try checkCancelled()
        return (decoded, found.date)
    }

    private static func patchRows(stamp: String, dataDir: URL) throws -> [PatchFailureRow] {
        try checkCancelled()
        let kind = PatchFailureDrift.kind
        let found = try file(kind: kind, stamp: stamp, dataDir: dataDir)
        let data = try read(found.url, limit: BoundedFile.limit(forKind: kind), dataDir: dataDir)
        guard let rows = try? JSONDecoder().decode([PatchFailureRow].self, from: data) else {
            throw Failed(outcome: .unreadable(.undecodable))
        }
        try checkCancelled()
        return rows
    }
}
