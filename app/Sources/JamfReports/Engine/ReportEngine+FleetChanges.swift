import Foundation

extension ReportEngine {
    /// The change parts of today's summary (wave B2), from what this routed run saved. Nil when
    /// it saved neither `computers` nor `compliance-rules`.
    static func fleetChanges(
        landed: LandedSources, dataDir: URL, config: ReportConfig
    ) -> FleetChangeSummary? {
        let summary = FleetChangeSummary(
            computers: landed.computerSnapshot.flatMap {
                computerChanges(landed: $0, dataDir: dataDir, rule: config.staleRule,
                                policy: config.resolvedSecurityPolicy)
            },
            benchmarks: landed.complianceRulesStamp.flatMap {
                benchmarkChanges(dataDir: dataDir, landedStamp: $0)
            })
        return summary.isEmpty ? nil : summary
    }

    /// The Mac counts between this run's snapshot and the newest earlier-day one. Nil with no
    /// baseline; a baseline over `readLimit` or that will not decode is recorded as unreadable,
    /// with no counts.
    static func computerChanges(
        landed: LandedSources.LandedComputers, dataDir: URL, rule: StaleRule,
        policy: SecurityControlPolicy, readLimit: Int = BoundedFile.inventoryLimit
    ) -> ComputerChanges? {
        guard let baseline = SnapshotFleetDrift.baseline(dataDir: dataDir, before: landed.date)
        else { return nil }
        var changes = ComputerChanges(
            currentStamp: landed.stamp,
            baselineStamp: PatchReleaseDateService.snapshotStamp(of: baseline.url),
            currentCount: landed.snapshot.rows.count,
            staleDays: rule.days, staleBasis: rule.basis.map(\.rawValue),
            fileVaultRule: policy.fileVaultFingerprint)
        let prior: ComputerSnapshot
        do {
            let data = try BoundedFile.read(
                baseline.url, limit: readLimit, followSymlinks: false, inside: dataDir)
            guard let decoded = ComputerDates.decodeComputerSnapshot(data) else {
                throw BoundedFile.Failure.notRegular
            }
            prior = decoded
        } catch {
            changes.baselineUnreadable = true
            changes.baselineUnreadableReason =
                (error as? BoundedFile.Failure) == .tooLarge ? .tooLarge : .undecodable
            return changes
        }
        let drift = SnapshotFleetDrift(
            current: landed.snapshot, currentAt: landed.date,
            prior: prior, priorAt: baseline.date, rule: rule, policy: policy)
        changes.priorCount = prior.rows.count
        changes.largeChangePercent = drift.largeChangePercent
        changes.joined = drift.joined.count
        changes.left = drift.left.count
        changes.osChanged = drift.osChanged.count
        if !drift.staleNotCompared {
            changes.becameStale = drift.becameStale.count
            changes.noLongerStale = drift.noLongerStale.count
        }
        changes.fileVaultOff = drift.fileVaultOff?.count
        changes.fileVaultStoppedReporting = drift.fileVaultStoppedReporting?.count
        changes.unidentified = drift.unidentified
        changes.ambiguous = drift.ambiguous
        return changes
    }

    /// Benchmark rules newly failing between this run's `compliance-rules` snapshot and the
    /// newest earlier-day one. Nil with no pair or a file that does not decode.
    static func benchmarkChanges(dataDir: URL, landedStamp: Date) -> BenchmarkChanges? {
        guard let pair = BenchmarkRuleDrift.pair(dataDir: dataDir, landedStamp: landedStamp),
              let drift = BenchmarkRuleDrift.load(current: pair.current, baseline: pair.baseline)
        else { return nil }
        return BenchmarkChanges(
            currentStamp: PatchReleaseDateService.snapshotStamp(of: pair.current),
            baselineStamp: PatchReleaseDateService.snapshotStamp(of: pair.baseline),
            newlyFailing: drift.newlyFailing.count, notCompared: drift.notCompared)
    }
}
