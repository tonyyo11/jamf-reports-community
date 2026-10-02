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
        /// The policy the gaps were counted under; the posture insight words warnings by it.
        var policy: SecurityControlPolicy = .default

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
                && lhs.policy == rhs.policy
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
        let hardware = HardwareEncryption.index(dataDir: dir, for: policy)
        guard let snapshot = decode(at: newest, policy: policy, hardware: hardware) else {
            return .failed("Couldn't read the latest compliance snapshot — \(newest.lastPathComponent) may be corrupt.")
        }
        return snapshot
    }

    static func load(
        from url: URL, policy: SecurityControlPolicy, hardware: [String: Bool]
    ) -> Snapshot? {
        decode(at: url, policy: policy, hardware: hardware)
    }

    // MARK: - Internals

    private static func decode(
        at url: URL, policy: SecurityControlPolicy, hardware: [String: Bool]
    ) -> Snapshot? {
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

        let encrypted = devices.map {
            HardwareEncryption.lookup(serial: $0.serial, name: $0.name, in: hardware)
        }
        let gapCounts: [Int?] = zip(devices, encrypted).map {
            deviceGapCount($0, policy: policy, hardwareEncrypted: $1)
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
            controlGaps: controlGaps(devices, hardwareEncrypted: encrypted, policy: policy),
            sourceFile: url,
            snapshotDate: mtime,
            policy: policy
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

    /// One row per evaluated control, most failing devices first. `hardwareEncrypted` runs
    /// parallel to `devices`.
    private static func controlGaps(
        _ devices: [SecurityDevice], hardwareEncrypted: [Bool?], policy: SecurityControlPolicy
    ) -> [Snapshot.ControlGap] {
        SecurityControl.allCases
            .filter { policy.level(for: $0) != .ignore }
            .map { control in
                let verdicts = zip(devices, hardwareEncrypted).map {
                    policy.verdict(
                        for: control, reading: reading(control, of: $0),
                        hardwareEncrypted: $1)
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

    fileprivate static func label(_ control: SecurityControl) -> String {
        switch control {
        case .fileVault: "FileVault"
        case .sip: "SIP"
        case .firewall: "Firewall"
        case .gatekeeper: "Gatekeeper"
        }
    }
}

// MARK: - AI insight input

extension FleetInsightInput {
    /// The posture screen asking, with the snapshot it shows.
    enum PostureScreen {
        case security(SecurityPostureService.Snapshot)
        /// `showsBands` is false while mSCP baseline donuts take the control-gap bands' place.
        case compliance(CompliancePostureService.Snapshot, showsBands: Bool)
    }

    /// The Security Posture and Compliance Posture insight. Every count is one the asking
    /// screen shows, so the card cannot disagree with it: Security sends its fleet counts and
    /// P0/P1, Compliance its control-gap bars, bands and per-macOS-major rows. A control the
    /// policy ignores, or the report has no count for, sends nothing. Nil when nothing is left.
    static func posture(_ screen: PostureScreen) -> FleetInsightInput? {
        let macs: Int, rows: [PostureRow], policy: SecurityControlPolicy
        var more: [Fact] = [], notes = [postureGapNote], byMajor = false
        switch screen {
        case .security(let snapshot):
            (macs, policy) = (snapshot.totalDevices, snapshot.policy)
            rows = securityRows(snapshot.fleetCounts, policy: policy)
            more = actionItemFacts(snapshot.fleetCounts)
            if !more.isEmpty { notes.append(postureActionNote) }
        case .compliance(let snapshot, let showsBands):
            (macs, policy) = (snapshot.totalDevices, snapshot.policy)
            rows = complianceRows(snapshot.controlGaps)
            // The most Macs failing first: the on-device model leans on the first line it reads.
            let majors = snapshot.perOSMajor
                .compactMap { bandFact("macOS \($0.osMajor)", $0.bands) }
                .sorted { $0.failing > $1.failing }.map { $0.fact }
            let fleet = showsBands ? bandFact("All Macs", snapshot.bands)?.fact : nil
            more = [fleet].compactMap { $0 } + majors
            byMajor = !majors.isEmpty
            if !more.isEmpty { notes.append(postureBandNote) }
        }
        // Ordered as the Control Coverage Gaps bars are, most Macs failing first.
        let facts = rows.sorted { $0.failing > $1.failing }
            .flatMap { controlFacts($0, policy: policy) } + more
        guard !facts.isEmpty else { return nil }
        let total = Fact(label: "Macs in the security report", value: .count(macs), prior: nil,
                         polarity: .neutral)
        let subject = byMajor
            ? "which control and which macOS major account" : "which control accounts"
        return FleetInsightInput(
            title: "Posture insight",
            focus: subject + " for most of the gap, and what to do first.",
            facts: [total] + facts, notes: notes)
    }

    private static let postureGapNote = "Failing is a gap under this workspace's security policy. "
        + "A warning is a Mac with the control off that the policy does not count as a gap."
    private static let postureActionNote = "P0 and P1 add up each control's gaps, so a Mac "
        + "failing two of their controls counts twice."
    private static let postureBandNote = "Bands count the controls a Mac fails: Pass is none, "
        + "Low and above one or more, No Data none measured."

    /// One control as a posture screen shows it.
    private struct PostureRow {
        /// The share the screen shows: a Security KPI tile's Macs with the control on, or a
        /// Control Coverage Gaps bar's Macs failing.
        enum Share { case on(Double), failing(Double) }

        let control: SecurityControl
        let share: Share
        let failing: Int
        let warning: Int
        /// FileVault-off Macs the hardware rule leaves out at `ignore`; Security only.
        var notCounted = 0
    }

    /// The KPI tiles' share, Macs with the control on of every Mac in the report; the policy
    /// shows in the failing and warning counts. Ignored and absent controls send nothing.
    private static func securityRows(
        _ fleet: SecurityFleetCounts, policy: SecurityControlPolicy
    ) -> [PostureRow] {
        SecurityControl.allCases.compactMap { control in
            guard let counts = fleet.controls[control], counts.level != .ignore,
                  fleet.totalDevices > 0 else { return nil }
            let onPct = Double(counts.on) / Double(fleet.totalDevices) * 100
            let dropped = control == .fileVault && policy.fileVaultOffHardwareEncrypted == .ignore
            return PostureRow(control: control, share: .on(onPct), failing: counts.fail,
                              warning: counts.warning,
                              notCounted: dropped ? fleet.fileVaultOffHardwareEncrypted : 0)
        }
    }

    /// The Control Coverage Gaps bars, which already leave ignored controls out.
    private static func complianceRows(
        _ gaps: [CompliancePostureService.Snapshot.ControlGap]
    ) -> [PostureRow] {
        SecurityControl.allCases.compactMap { control in
            let label = CompliancePostureService.label(control)
            guard let gap = gaps.first(where: { $0.control == label }), gap.totalDevices > 0
            else { return nil }
            return PostureRow(control: control, share: .failing(gap.pct),
                              failing: gap.failingDevices, warning: gap.warningDevices)
        }
    }

    /// The screen's share and the Macs failing, then the Macs the policy counts apart.
    private static func controlFacts(_ row: PostureRow, policy: SecurityControlPolicy) -> [Fact] {
        let name = CompliancePostureService.label(row.control)
        // "SIP" alone reads as the VoIP protocol to the on-device model.
        let first = row.control == .sip ? "System Integrity Protection (SIP)" : name
        let share = switch row.share {
        case .on(let pct):
            Fact(label: "\(first) enabled", value: .percent(pct), prior: nil,
                 polarity: .higherIsBetter, complement: "off")
        case .failing(let pct):
            Fact(label: "\(first) failing", value: .percent(pct), prior: nil,
                 polarity: .lowerIsBetter, complement: "not failing")
        }
        var facts = [
            share,
            Fact(label: "Macs failing \(name)", value: .count(row.failing), prior: nil,
                 polarity: .lowerIsBetter),
        ]
        let hardware = "Macs with " + SecurityFleetCounts.hardwareEncryptedRowLabel
        if row.warning > 0 {
            // Only with FileVault at `fail` is every FileVault warning a hardware-encrypted Mac.
            let isHardware = row.control == .fileVault && policy.usesHardwareRule
                && policy.fileVaultOffHardwareEncrypted == .warning
            let off = isHardware ? hardware : "Macs with \(name) off"
            facts.append(Fact(label: off + " (a warning, not failing)", value: .count(row.warning),
                              prior: nil, polarity: .lowerIsBetter))
        }
        if row.notCounted > 0 {
            facts.append(Fact(label: hardware + ", not counted by this workspace's policy",
                              value: .count(row.notCounted), prior: nil, polarity: .neutral))
        }
        return facts
    }

    /// The Action Items tiles' P0 and P1, left out when every control they add up is ignored.
    private static func actionItemFacts(_ fleet: SecurityFleetCounts) -> [Fact] {
        func counted(_ controls: [SecurityControl]) -> Bool {
            controls.contains { fleet.controls[$0].map { $0.level != .ignore } ?? false }
        }
        var facts: [Fact] = []
        if let p0 = fleet.p0, counted([.fileVault, .sip, .firewall]) {
            facts.append(Fact(label: "P0 action items (FileVault, SIP and Firewall gaps)",
                              value: .count(p0), prior: nil, polarity: .lowerIsBetter))
        }
        if let p1 = fleet.p1, counted([.gatekeeper]) {
            facts.append(Fact(label: "P1 action items (Gatekeeper gaps)", value: .count(p1),
                              prior: nil, polarity: .lowerIsBetter))
        }
        return facts
    }

    /// One bands row: its Macs in a band below Pass, out of its Macs, then the bands holding
    /// Macs as the screen's legend reads them. Nil for a row with no Mac.
    private static func bandFact(
        _ label: String, _ bands: [ComplianceBand]
    ) -> (failing: Int, fact: Fact)? {
        let total = bands.reduce(0) { $0 + $1.count }
        guard total > 0 else { return nil }
        let clear = [ComplianceBandingService.Band.pass.label,
                     ComplianceBandingService.Band.noData.label]
        let failing = bands.filter { !clear.contains($0.label) }.reduce(0) { $0 + $1.count }
        let counts = bands.filter { $0.count > 0 }.map { "\($0.label) \($0.count)" }
        let text = "\(failing) of \(total) Macs fail at least one control ("
            + counts.joined(separator: ", ") + ")"
        return (failing, Fact(label: label, value: .text(text), prior: nil, polarity: .neutral))
    }
}
