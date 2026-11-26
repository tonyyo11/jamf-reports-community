import Foundation

extension ReportEngine {
    /// The change parts of today's summary (wave B2), from what this routed run saved. Nil when
    /// it saved neither `computers` nor `compliance-rules`. A part whose file is there but cannot
    /// be read is stored as unreadable, with no counts, and logged once.
    static func fleetChanges(
        landed: LandedSources, dataDir: URL, config: ReportConfig,
        onLine: (@Sendable (CLIBridge.LogLine) -> Void)? = nil
    ) -> FleetChangeSummary? {
        let computers = landed.computerFile.map { loadLanded($0, dataDir: dataDir) }
        let summary = FleetChangeSummary(
            computers: computers.flatMap { loaded in
                switch loaded {
                case .success(let snapshot):
                    return computerChanges(
                        landed: snapshot, dataDir: dataDir, rule: config.staleRule,
                        policy: config.resolvedSecurityPolicy)
                case .failure(let failure):
                    return ComputerChanges(
                        currentStamp: landed.computerFile?.stamp, baselineUnreadable: true,
                        baselineUnreadableReason: failure.reason)
                }
            },
            benchmarks: landed.complianceRulesStamp.flatMap {
                benchmarkChanges(dataDir: dataDir, landedStamp: $0)
            },
            patch: landed.patchFailuresStamp.flatMap {
                patchChanges(dataDir: dataDir, landedStamp: $0,
                             landed: try? computers?.get())
            })
        logUnreadable(summary, onLine: onLine)
        return summary.isEmpty ? nil : summary
    }

    /// The landed `computers` snapshot, read once here rather than on the collect's hot path.
    static func loadLanded(
        _ file: LandedSources.LandedFile, dataDir: URL
    ) -> Result<LandedSources.LandedComputers, SnapshotReadFailure> {
        SnapshotPair.read(file.url, limit: BoundedFile.inventoryLimit, dataDir: dataDir)
            .flatMap { data in
                ComputerDates.decodeComputerSnapshot(data).map {
                    .success(.init(stamp: file.stamp, date: file.date, snapshot: $0))
                } ?? .failure(SnapshotReadFailure(.undecodable))
            }
    }

    private static func logUnreadable(
        _ summary: FleetChangeSummary, onLine: (@Sendable (CLIBridge.LogLine) -> Void)?
    ) {
        let parts: [(String, ComputerChanges.UnreadableReason?)] = [
            ("Mac", summary.computers?.baselineUnreadable == true
                ? summary.computers?.baselineUnreadableReason ?? .undecodable : nil),
            ("benchmark rule", summary.benchmarks?.baselineUnreadable == true
                ? summary.benchmarks?.baselineUnreadableReason ?? .undecodable : nil),
            ("patch policy", summary.patch?.baselineUnreadable == true
                ? summary.patch?.baselineUnreadableReason ?? .undecodable : nil),
        ]
        for case let (name, reason?) in parts {
            onLine?(.init(timestamp: Date(), level: .warn,
                          text: "[warn] change counts: a \(name) snapshot could not be read ("
                              + "\(SnapshotReadFailure(reason).text)); not measured"))
        }
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
        let read = SnapshotPair.read(baseline.url, limit: readLimit, dataDir: dataDir)
            .flatMap { data in
                ComputerDates.decodeComputerSnapshot(data).map { .success($0) }
                    ?? .failure(SnapshotReadFailure(.undecodable))
            }
        let prior: ComputerSnapshot
        switch read {
        case .success(let snapshot): prior = snapshot
        case .failure(let failure):
            changes.baselineUnreadable = true
            changes.baselineUnreadableReason = failure.reason
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
    /// newest earlier-day one. Nil with no pair; a file that cannot be read is unreadable.
    static func benchmarkChanges(dataDir: URL, landedStamp: Date) -> BenchmarkChanges? {
        guard let pair = BenchmarkRuleDrift.pair(dataDir: dataDir, landedStamp: landedStamp)
        else { return nil }
        var changes = BenchmarkChanges(
            currentStamp: PatchReleaseDateService.snapshotStamp(of: pair.current),
            baselineStamp: PatchReleaseDateService.snapshotStamp(of: pair.baseline))
        switch BenchmarkRuleDrift.load(
            current: pair.current, baseline: pair.baseline, dataDir: dataDir) {
        case .success(let drift):
            changes.newlyFailing = drift.newlyFailing.count
            changes.notCompared = drift.notCompared
        case .failure(let failure):
            changes.baselineUnreadable = true
            changes.baselineUnreadableReason = failure.reason
        }
        return changes
    }

    /// Patch policy failures that started or dropped off since the newest earlier-day scan.
    /// Nil with no pair or no computers snapshot: a dropped pair cannot be counted without
    /// knowing whether its Mac is still enrolled. A scan or computers file that cannot be read
    /// is unreadable.
    static func patchChanges(
        dataDir: URL, landedStamp: Date, landed: LandedSources.LandedComputers?
    ) -> PatchChanges? {
        guard let pair = PatchFailureDrift.pair(dataDir: dataDir, landedStamp: landedStamp),
              let computers = patchComputerIndex(
                landed: landed, dataDir: dataDir, scanDate: landedStamp)
        else { return nil }
        var changes = PatchChanges(
            currentStamp: PatchReleaseDateService.snapshotStamp(of: pair.current),
            baselineStamp: PatchReleaseDateService.snapshotStamp(of: pair.baseline))
        let drift = computers.flatMap { index in
            PatchFailureDrift.load(
                current: pair.current, baseline: pair.baseline, dataDir: dataDir,
                computers: index.index
            ).map { ($0, index.stamp) }
        }
        switch drift {
        case .success(let (drift, stamp)):
            changes.startedFailing = drift.startedFailing.count
            changes.stoppedFailing = drift.noLongerListed.count
            changes.leftOut = drift.leftOut
            changes.notInComputers = drift.notInComputers
            changes.computersStamp = stamp
        case .failure(let failure):
            changes.baselineUnreadable = true
            changes.baselineUnreadableReason = failure.reason
        }
        return changes
    }

    /// The Macs a patch scan's dropped pairs are checked against: this run's landed
    /// `computers` snapshot, else the newest file stamped at or before the scan, with that
    /// snapshot's stamp. Nil with no file; a failure when the file cannot be read.
    static func patchComputerIndex(
        landed: LandedSources.LandedComputers?, dataDir: URL, scanDate: Date
    ) -> Result<(index: ComputerDateIndex, stamp: String?), SnapshotReadFailure>? {
        if let landed { return .success((ComputerDateIndex(landed.snapshot.rows), landed.stamp)) }
        guard let file = TrendStore.datedSnapshots(of: "computers", in: dataDir)
                .last(where: { $0.date <= scanDate })
        else { return nil }
        return SnapshotPair.read(file.url, limit: BoundedFile.inventoryLimit, dataDir: dataDir)
            .flatMap { data in
                ComputerDates.decodeComputerSnapshot(data).map {
                    .success((ComputerDateIndex($0.rows),
                              PatchReleaseDateService.snapshotStamp(of: file.url)))
                } ?? .failure(SnapshotReadFailure(.undecodable))
            }
    }
}
