import Foundation

/// Compliance-posture data source. Reads the same `pro security report`
/// snapshot as `SecurityPostureService` but derives **per-device** control-
/// gap counts instead of aggregate metrics, so the bucketed compliance
/// bands match the v3.5 STIG donut shape (Pass / Low / Med-Low / Medium /
/// High).
///
/// Pure mSCP failure counts (the v3.5 source) require a custom Extension
/// Attribute that's not part of the canonical `pro security report` output.
/// Until that EA is wired, we proxy "device failure count" with the number
/// of failing controls (0–4 across FileVault / SIP / Firewall / Gatekeeper).
/// The view should label this honestly.
struct CompliancePostureService: Sendable {

    struct Snapshot: Sendable, Equatable {
        let totalDevices: Int
        let bands: [ComplianceBand]
        let perOSMajor: [(osMajor: Int, bands: [ComplianceBand])]
        /// Per-control failure rate across the fleet, sorted highest-first.
        let controlGaps: [ControlGap]
        let sourceFile: URL?
        let snapshotDate: Date?

        struct ControlGap: Sendable, Equatable, Identifiable {
            let control: String
            let failingDevices: Int
            let totalDevices: Int
            var id: String { control }
            var pct: Double {
                totalDevices > 0
                    ? (Double(failingDevices) / Double(totalDevices)) * 100
                    : 0
            }
        }

        /// Freshness signal for `StaleDataBanner` consumers. Uses the same 36-hour
        /// threshold as TrendStore to align with the standard daily-schedule cadence.
        var cacheSource: CacheSource {
            CacheSource.from(snapshotDate: snapshotDate, withinHours: 36)
        }

        static func == (lhs: Snapshot, rhs: Snapshot) -> Bool {
            lhs.totalDevices == rhs.totalDevices
                && lhs.bands.map(\.label) == rhs.bands.map(\.label)
                && lhs.bands.map(\.count) == rhs.bands.map(\.count)
                && lhs.controlGaps == rhs.controlGaps
                && lhs.sourceFile == rhs.sourceFile
                && lhs.snapshotDate == rhs.snapshotDate
                && lhs.perOSMajor.map(\.osMajor) == rhs.perOSMajor.map(\.osMajor)
        }

        static let empty = Snapshot(
            totalDevices: 0,
            bands: ComplianceBandingService.bands(failures: []),
            perOSMajor: [],
            controlGaps: [],
            sourceFile: nil,
            snapshotDate: nil
        )
    }

    /// Load the newest security report and derive a compliance snapshot.
    /// Returns `.empty` when no data is available.
    static func load(profile: String) -> Snapshot {
        guard let dir = (try? WorkspacePaths.dataDir(for: profile)) else {
            return .empty
        }
        let securityDir = dir.appendingPathComponent("security", isDirectory: true)
        guard let newest = FileManager.newestJSONFile(in: securityDir) else { return .empty }
        return decode(at: newest) ?? .empty
    }

    static func load(from url: URL) -> Snapshot? {
        decode(at: url)
    }

    // MARK: - Internals

    private static func decode(at url: URL) -> Snapshot? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        guard let items = try? JSONDecoder()
            .decode([SecurityReportItem].self, from: data)
        else { return nil }

        var devices: [SecurityDevice] = []
        for item in items {
            if case .device(let d) = item { devices.append(d) }
        }
        guard !devices.isEmpty else { return .empty }

        let failureCounts: [Int?] = devices.map(deviceGapCount)
        let bands = ComplianceBandingService.bands(failures: failureCounts)

        let osPairs: [(osMajor: Int, failures: Int?)] = devices.compactMap { d in
            guard let raw = d.osVersion,
                  let major = ComplianceBandingService.parseOSMajor(raw)
            else { return nil }
            return (major, deviceGapCount(d))
        }
        let perOSMajor = ComplianceBandingService.bandsByOSMajor(osPairs)

        let total = devices.count
        let controlGaps: [Snapshot.ControlGap] = [
            ("FileVault", devices.filter { isFileVaultFailing($0) }.count),
            ("SIP", devices.filter { isSIPFailing($0) }.count),
            ("Firewall", devices.filter { isFirewallFailing($0) }.count),
            ("Gatekeeper", devices.filter { isGatekeeperFailing($0) }.count)
        ]
            .map { Snapshot.ControlGap(control: $0.0, failingDevices: $0.1, totalDevices: total) }
            .sorted { $0.failingDevices > $1.failingDevices }

        let mtime = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate
        return Snapshot(
            totalDevices: total,
            bands: bands,
            perOSMajor: perOSMajor,
            controlGaps: controlGaps,
            sourceFile: url,
            snapshotDate: mtime
        )
    }

    /// Derive failure count (0–4) from a device's per-control status fields.
    /// Returns nil only if the row has no status fields at all (treated as
    /// "No Data" by the banding service).
    static func deviceGapCount(_ device: SecurityDevice) -> Int? {
        let hasAny = device.fileVault != nil || device.sip != nil ||
                     device.firewall != nil || device.gatekeeper != nil
        guard hasAny else { return nil }
        var count = 0
        if isFileVaultFailing(device) { count += 1 }
        if isSIPFailing(device) { count += 1 }
        if isFirewallFailing(device) { count += 1 }
        if isGatekeeperFailing(device) { count += 1 }
        return count
    }

    static func isFileVaultFailing(_ d: SecurityDevice) -> Bool {
        guard let v = d.fileVault else { return false }
        return !v.uppercased().contains("ENCRYPTED") ||
               v.uppercased().contains("NOT_ENCRYPTED") ||
               v.uppercased() == "UNENCRYPTED"
    }

    static func isSIPFailing(_ d: SecurityDevice) -> Bool {
        guard let v = d.sip else { return false }
        return v.uppercased() != "ENABLED"
    }

    static func isFirewallFailing(_ d: SecurityDevice) -> Bool {
        guard let v = d.firewall else { return false }
        return !v
    }

    static func isGatekeeperFailing(_ d: SecurityDevice) -> Bool {
        guard let v = d.gatekeeper else { return false }
        let up = v.uppercased()
        // ENABLED, APP_STORE, APP_STORE_AND_IDENTIFIED_DEVELOPERS all count as
        // passing. DISABLED, UNKNOWN, or empty count as failing.
        return up.contains("DISABLED") || up.isEmpty || up == "UNKNOWN"
    }
}
