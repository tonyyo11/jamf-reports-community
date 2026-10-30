import Foundation

extension ReportEngine {

    /// The day's summary for a Jamf School workspace, from its `school-devices` rows
    /// (`SchoolFleetService`; devices in School's trash are already left out). Macs and mobile
    /// devices are never counted together: Macs fill the Mac fields (`totalDevices`,
    /// `staleCount`, `osCurrentPct`), every other platform but "Unknown" is `mobileDeviceCount`
    /// and `mobile`, each nil when there is none of that type. Staleness is a check-in more than
    /// `staleDays` ago. `osCurrentPct` is the Pro definition (`osCurrentPercent`) against
    /// `sofaRows`' macOS feed and `mobile.osCurrent` against its iOS feed; no feed leaves them
    /// out. School rows carry no other Mac security figure. Nil when there are no devices.
    static func schoolSummary(
        from snapshot: SchoolFleetService.Snapshot, date: String, staleDays: Int, now: Date,
        sofaRows: [SOFAFeedService.OSFamilyRow] = [],
        collectionSources: [String: String]?, collectedByHost: String?
    ) -> DailySummary? {
        let macDevices = snapshot.devices.filter { $0.platform == "macOS" }
        let macs = macDevices.count
        let staleMacs = macDevices.filter { $0.isStale(atDays: staleDays, now: now) }.count
        let mobileDevices = snapshot.devices.filter { !["macOS", "Unknown"].contains($0.platform) }
        guard macs + mobileDevices.count > 0 else { return nil }
        let macVersions = macDevices.map { String($0.os.drop { !$0.isNumber }) }
        let osCurrent = osCurrentPercent(
            macOSRows: sofaRows.filter { $0.platform == SOFAFeedService.platformLabels["macos"] },
            osCounts: Dictionary(macVersions.map { ($0, 1) }, uniquingKeysWith: +),
            totalDevices: macs)
        return DailySummary(
            date: date, totalDevices: macs, fileVaultPct: nil, compliancePct: nil,
            staleCount: macs > 0 ? staleMacs : nil,
            osCurrentPct: osCurrent.map { ($0 * 10).rounded() / 10 },
            crowdstrikePct: nil, patchPct: nil,
            source: "jamf-cli", collectionSources: collectionSources,
            mobileDeviceCount: mobileDevices.isEmpty ? nil : mobileDevices.count,
            collectedByHost: collectedByHost,
            mobile: MobileSummary.build(
                mobileDevices.map { MobileSummary.device($0) },
                latestByMajor: SOFAFeedService.iOSLatestByMajor(sofaRows),
                staleDays: staleDays, now: now))
    }

    /// Writes `summary_<day>.json` for a School collect that landed `school-devices`, replacing
    /// a same-day file (its numbers are older). A run that did not land the devices source
    /// writes nothing and leaves the file as it is, so cached rows are never dated today.
    @discardableResult
    static func writeSchoolSummary(
        dataDir: URL, summariesDir: URL, landedKinds: Set<String>, staleDays: Int,
        day: Date = Date(), onLine: @Sendable @escaping (CLIBridge.LogLine) -> Void
    ) -> SummaryEmitOutcome {
        guard landedKinds.contains(SchoolFleetService.devicesKind) else {
            return .nothingToSummarize
        }
        let date = SummaryJSONParser.dateFormatter.string(from: day)
        guard let summary = schoolSummary(
            from: SchoolFleetService.load(dataDir: dataDir), date: date, staleDays: staleDays,
            now: day, sofaRows: SOFAFeedService.load(dataDir: dataDir).rows,
            collectionSources: [SchoolFleetService.devicesKind: "live"],
            collectedByHost: collectingHostLabel(dataDir: dataDir))
        else {
            let msg = "[warn] Jamf School returned 0 devices — summary not written"
            AppLogger.collect.warning("\(msg, privacy: .private)")
            onLine(.init(timestamp: Date(), level: .warn, text: msg))
            AttentionLog.raise(.schoolZeroDevices, "Jamf School returned 0 devices")
            return .nothingToSummarize
        }
        AttentionLog.clear(.schoolZeroDevices)
        do {
            try FileManager.default.createDirectory(
                at: summariesDir, withIntermediateDirectories: true)
        } catch {
            let msg = "\(summaryNotWrittenMarker) the summaries directory could not be created"
            AppLogger.collect.warning("\(msg, privacy: .private)")
            onLine(.init(timestamp: Date(), level: .warn, text: msg))
            return .directoryUnavailable
        }
        let file = summariesDir.appendingPathComponent("summary_\(date).json")
        return writeSummaryFile(summary, to: file, onLine: onLine) ? .wrote : .writeFailed
    }
}
