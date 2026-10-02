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
/// of controls (FileVault / SIP / Firewall / Gatekeeper) the workspace's
/// `security_policy` counts as failing. The view should label this honestly.
struct CompliancePostureService: Sendable {

    struct Snapshot: Sendable, Equatable {
        let totalDevices: Int
        let bands: [ComplianceBand]
        let perOSMajor: [(osMajor: Int, bands: [ComplianceBand])]
        /// Per-control failure rate across the fleet, sorted highest-first.
        let controlGaps: [ControlGap]
        let sourceFile: URL?
        let snapshotDate: Date?
        /// Non-nil only when a snapshot file existed but could not be read/decoded —
        /// a true failure, distinct from `.empty` (no data collected yet).
        var loadError: String? = nil

        struct ControlGap: Sendable, Equatable, Identifiable {
            let control: String
            let failingDevices: Int
            let totalDevices: Int
            var warningDevices: Int = 0
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
                && lhs.loadError == rhs.loadError
        }

        static let empty = Snapshot(
            totalDevices: 0,
            bands: ComplianceBandingService.bands(failures: []),
            perOSMajor: [],
            controlGaps: [],
            sourceFile: nil,
            snapshotDate: nil
        )

        /// A true read/decode failure (file present but unreadable), distinct from `.empty`.
        static func failed(_ reason: String) -> Snapshot {
            var s = empty
            s.loadError = reason
            return s
        }
    }

    /// Load the newest security report and derive a compliance snapshot.
    /// Returns `.empty` when no data is available.
    static func load(profile: String) -> Snapshot {
        guard let dir = (try? WorkspacePaths.dataDir(for: profile)) else {
            return .empty
        }
        let securityDir = dir.appendingPathComponent("security", isDirectory: true)
        guard let newest = FileManager.newestJSONFile(in: securityDir) else { return .empty }
        let policy = SecurityPolicyConfigLoader.load(profile: profile)
        guard let snapshot = decode(at: newest, policy: policy) else {
            return .failed("Couldn't read the latest compliance snapshot — \(newest.lastPathComponent) may be corrupt.")
        }
        return snapshot
    }

    static func load(from url: URL, policy: SecurityControlPolicy) -> Snapshot? {
        decode(at: url, policy: policy)
    }

    // MARK: - Internals

    private static func decode(at url: URL, policy: SecurityControlPolicy) -> Snapshot? {
        guard let data = try? Data(contentsOf: url) else {
            AppLogger.platform.warning(
                "CompliancePostureService: could not read security file \(url.lastPathComponent, privacy: .public)"
            )
            return nil
        }
        guard let items = try? JSONDecoder().decode([SecurityReportItem].self, from: data) else {
            AppLogger.platform.warning(
                "CompliancePostureService: failed to decode security file \(url.lastPathComponent, privacy: .public)"
            )
            return nil
        }

        var devices: [SecurityDevice] = []
        for item in items {
            if case .device(let d) = item { devices.append(d) }
        }
        guard !devices.isEmpty else { return .empty }

        let gapCounts: [Int?] = devices.map {
            deviceGapCount($0, policy: policy, hardwareEncrypted: nil)
        }
        let bands = ComplianceBandingService.bands(failures: gapCounts)

        let osPairs: [(osMajor: Int, failures: Int?)] = zip(devices, gapCounts).compactMap {
            guard let raw = $0.osVersion,
                  let major = ComplianceBandingService.parseOSMajor(raw)
            else { return nil }
            return (major, $1)
        }
        let perOSMajor = ComplianceBandingService.bandsByOSMajor(osPairs)

        let mtime = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate
        return Snapshot(
            totalDevices: devices.count,
            bands: bands,
            perOSMajor: perOSMajor,
            controlGaps: controlGaps(devices, policy: policy),
            sourceFile: url,
            snapshotDate: mtime
        )
    }

    /// Controls at `fail` under `policy` for one device row. Nil when the row measured
    /// none of the evaluated controls: "NOT_COLLECTED"/"UNKNOWN" used to count as
    /// failing, which made the proxy report a measured 0% on partially collected tenants.
    static func deviceGapCount(
        _ device: SecurityDevice, policy: SecurityControlPolicy, hardwareEncrypted: Bool?
    ) -> Int? {
        policy.gapCount(
            fileVault: reading(.fileVault, of: device),
            sip: reading(.sip, of: device),
            firewall: reading(.firewall, of: device),
            gatekeeper: reading(.gatekeeper, of: device),
            hardwareEncrypted: hardwareEncrypted
        )
    }

    /// One row per evaluated control, most failing devices first.
    private static func controlGaps(
        _ devices: [SecurityDevice], policy: SecurityControlPolicy
    ) -> [Snapshot.ControlGap] {
        SecurityControl.allCases
            .filter { policy.level(for: $0) != .ignore }
            .map { control in
                let verdicts = devices.map {
                    policy.verdict(
                        for: control, reading: reading(control, of: $0), hardwareEncrypted: nil)
                }
                return Snapshot.ControlGap(
                    control: label(control),
                    failingDevices: verdicts.filter { $0 == .fail }.count,
                    totalDevices: devices.count,
                    warningDevices: verdicts.filter { $0 == .warning }.count
                )
            }
            .sorted { $0.failingDevices > $1.failingDevices }
    }

    private static func reading(_ control: SecurityControl, of device: SecurityDevice) -> Bool? {
        switch control {
        case .fileVault: SecurityControlPolicy.reading(device.fileVault)
        case .sip: SecurityControlPolicy.reading(device.sip)
        case .firewall: device.firewall
        case .gatekeeper: SecurityControlPolicy.reading(device.gatekeeper)
        }
    }

    private static func label(_ control: SecurityControl) -> String {
        switch control {
        case .fileVault: "FileVault"
        case .sip: "SIP"
        case .firewall: "Firewall"
        case .gatekeeper: "Gatekeeper"
        }
    }
}
