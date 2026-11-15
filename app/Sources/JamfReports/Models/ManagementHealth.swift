import Foundation

/// What the `computers` snapshot says about how each managed Mac is managed: one calculation
/// every surface reads. Each figure is "the Macs that match, of the Macs that reported the
/// field"; a finding no Mac can be judged on has no figure, never 0 of 0.
///
/// Unmanaged and binary-missing Macs are in no finding: Jamf reports nulls for them and they
/// are listed elsewhere.
struct ManagementHealth: Sendable {
    enum Kind: Sendable { case gap, warning, neutral }

    /// The matching Macs and how many reported the field.
    struct Figure: Sendable {
        let records: [DeviceInventoryRecord]
        let evaluated: Int
        var count: Int { records.count }
    }

    /// Stable identities; Jamf status strings are data and are never part of a title.
    enum Finding: String, CaseIterable, Sendable {
        case profileExpired
        /// The three expiring buckets are disjoint.
        case profileExpiringCheckingIn
        case profileExpiringStale
        case profileExpiringCheckInUnknown
        case binaryBehind
        case notUserApproved
        case notMDMCapable
        case notSupervised
        case notEnrolledViaADE
        case attested
        case attestationPending
        case attestationProblem
        case batteryNeedsService
        case batteryLowCapacity

        var kind: Kind {
            switch self {
            case .profileExpired, .notUserApproved, .notMDMCapable: .gap
            case .profileExpiringCheckingIn, .profileExpiringCheckInUnknown,
                 .attestationProblem: .warning
            // Already on the stale list, and it cannot renew until it checks in: a count here,
            // not a second place to chase the same Mac.
            case .profileExpiringStale: .neutral
            case .binaryBehind, .notSupervised, .notEnrolledViaADE, .attested,
                 .attestationPending, .batteryNeedsService, .batteryLowCapacity: .neutral
            }
        }

        var title: String {
            switch self {
            case .profileExpired: L("MDM profile expired")
            case .profileExpiringCheckingIn: L("MDM profile expiring, still checking in")
            case .profileExpiringStale: L("MDM profile expiring, also stale")
            case .profileExpiringCheckInUnknown: L("MDM profile expiring, check-in unknown")
            case .binaryBehind: L("Jamf binary behind the newest in this fleet")
            case .notUserApproved: L("MDM not user-approved")
            case .notMDMCapable: L("Not MDM capable")
            case .notSupervised: L("Not supervised")
            case .notEnrolledViaADE: L("Not enrolled through Automated Device Enrollment")
            case .attested: L("Attested")
            case .attestationPending: L("Attestation pending")
            case .attestationProblem: L("Attestation problem")
            case .batteryNeedsService: L("Battery needs service")
            case .batteryLowCapacity: L("Battery capacity under 80%")
            }
        }
    }

    /// Fields shown as a count per value, as Jamf gives the value.
    enum Breakdown: Sendable {
        case attestationProblem, batteryHealth, externalBootLevel, appleEnrollmentType
    }

    /// Fields shown as neutral on / off counts; never a gap.
    enum Toggle: Sendable, CaseIterable {
        case recoveryLock, activationLock, autoLoginDisabled, remoteDesktop, lockdownMode,
             awaitingConfiguration
    }

    struct OnOff: Sendable {
        let on: [DeviceInventoryRecord]
        let off: [DeviceInventoryRecord]
        var evaluated: Int { on.count + off.count }
    }

    static let defaultWarningDays = 90
    static let batteryCapacityFloor = 80.0
    /// Battery states that are not a service need.
    private static let batteryOK: Set<String> = ["NORMAL", "UNSUPPORTED", "UNKNOWN"]

    /// Findings with a figure; a finding no Mac was judged on is absent.
    let figures: [Finding: Figure]
    let toggles: [Toggle: OnOff]
    /// Managed Macs judged at all; a toggle's "not reported" is this less its evaluated count.
    let managedCount: Int
    /// The newest major.minor any managed Mac reports; nil below two distinct versions.
    let newestBinary: BinaryVersion?
    private let breakdowns: [Breakdown: [String: [DeviceInventoryRecord]]]
    private let attentionIDs: Set<String>

    /// False when no managed Mac reported any management field. A calculator that judged nothing
    /// says nothing: its surfaces are left out, never written as "no gaps".
    var judgedAnything: Bool { !figures.isEmpty || !toggles.isEmpty || !breakdowns.isEmpty }

    /// A gap or warning finding was judged on at least one Mac, so "none has one" is a fact.
    var judgedGapsOrWarnings: Bool { figures.keys.contains { $0.kind != .neutral } }

    /// Macs per value for `breakdown`, sorted by value.
    func values(_ breakdown: Breakdown) -> [(value: String, records: [DeviceInventoryRecord])] {
        (breakdowns[breakdown] ?? [:]).sorted { $0.key < $1.key }
            .map { (value: $0.key, records: $0.value) }
    }

    /// The Mac is in a gap or warning finding; neutral findings never count.
    func needsAttention(_ record: DeviceInventoryRecord) -> Bool {
        attentionIDs.contains(record.id)
    }

    init(
        records: [DeviceInventoryRecord], rule: StaleRule,
        warningDays: Int = ManagementHealth.defaultWarningDays, now: Date
    ) {
        let managed = records.filter {
            !$0.isBinaryMissing && !BinaryMissing.isUnmanaged($0.managedState)
        }
        managedCount = managed.count
        var figures: [Finding: Figure] = [:]
        var breakdowns: [Breakdown: [String: [DeviceInventoryRecord]]] = [:]
        Self.addProfile(managed, rule, warningDays, now, &figures)
        newestBinary = Self.addBinary(managed, &figures)
        Self.addFlags(managed, &figures)
        Self.addAttestation(managed, &figures, &breakdowns)
        Self.addBattery(managed, &figures, &breakdowns)
        func values(_ breakdown: Breakdown, _ field: (ManagementFacts) -> String?) {
            let reported = managed.filter { $0.management.flatMap(field) != nil }
            let grouped = Dictionary(grouping: reported) { $0.management.flatMap(field) ?? "" }
            if !grouped.isEmpty { breakdowns[breakdown] = grouped }
        }
        values(.externalBootLevel) { $0.externalBootLevel }
        values(.appleEnrollmentType) { $0.appleEnrollmentType }
        self.figures = figures
        self.breakdowns = breakdowns
        toggles = Self.toggles(managed)
        attentionIDs = Set(
            figures.filter { $0.key.kind != .neutral }.flatMap { $0.value.records.map(\.id) })
    }

    // MARK: - Findings

    private static func addProfile(
        _ managed: [DeviceInventoryRecord], _ rule: StaleRule, _ warningDays: Int,
        _ now: Date, _ figures: inout [Finding: Figure]
    ) {
        let known = managed.compactMap { record in
            record.management?.mdmProfileExpiration.map { (record, $0) }
        }
        guard !known.isEmpty else { return }
        let horizon = now.addingTimeInterval(Double(warningDays) * 86_400)
        let expired = known.filter { $0.1 < now }.map(\.0)
        let expiring = known.filter { $0.1 >= now && $0.1 <= horizon }.map(\.0)
        func figure(_ list: [DeviceInventoryRecord]) -> Figure {
            Figure(records: list, evaluated: known.count)
        }
        figures[.profileExpired] = figure(expired)
        // A Mac with no known date is its own bucket, before the stale test: with no date,
        // the rule would fall back to a source flag that says nothing about its check-in.
        let unknown = expiring.filter { rule.age(of: $0.staleInputs, now: now) == nil }
        let stale = expiring.filter {
            rule.age(of: $0.staleInputs, now: now) != nil && $0.isStale(rule, now: now)
        }
        let unknownIDs = Set(unknown.map(\.id)), staleIDs = Set(stale.map(\.id))
        figures[.profileExpiringCheckInUnknown] = figure(unknown)
        figures[.profileExpiringStale] = figure(stale)
        figures[.profileExpiringCheckingIn] = figure(
            expiring.filter { !unknownIDs.contains($0.id) && !staleIDs.contains($0.id) })
    }

    private static func addBinary(
        _ managed: [DeviceInventoryRecord], _ figures: inout [Finding: Figure]
    ) -> BinaryVersion? {
        let versions = managed.compactMap { record in
            record.management?.binaryVersion.map { (record, $0) }
        }
        guard Set(versions.map(\.1)).count >= 2, let newest = versions.map(\.1).max()
        else { return nil }
        figures[.binaryBehind] = Figure(
            records: versions.filter { $0.1 < newest }.map(\.0), evaluated: versions.count)
        return newest
    }

    private static func addFlags(
        _ managed: [DeviceInventoryRecord], _ figures: inout [Finding: Figure]
    ) {
        let flags: [(Finding, KeyPath<ManagementFacts, Bool?>)] = [
            (.notUserApproved, \.userApprovedMDM), (.notMDMCapable, \.mdmCapable),
            (.notSupervised, \.supervised), (.notEnrolledViaADE, \.enrolledViaADE),
        ]
        for (finding, path) in flags {
            let reported = managed.filter { $0.management?[keyPath: path] != nil }
            guard !reported.isEmpty else { continue }
            figures[finding] = Figure(
                records: reported.filter { $0.management?[keyPath: path] == false },
                evaluated: reported.count)
        }
    }

    private static func addAttestation(
        _ managed: [DeviceInventoryRecord], _ figures: inout [Finding: Figure],
        _ breakdowns: inout [Breakdown: [String: [DeviceInventoryRecord]]]
    ) {
        // Hardware that cannot attest is out of the denominator, not a failure.
        let judged = managed.filter {
            guard let status = $0.management?.attestationStatus else { return false }
            return status != "MDA_UNSUPPORTED_DUE_TO_HARDWARE"
        }
        guard !judged.isEmpty else { return }
        func status(_ record: DeviceInventoryRecord) -> String? {
            record.management?.attestationStatus
        }
        let others = judged.filter { status($0) != "SUCCESS" && status($0) != "PENDING" }
        figures[.attested] = Figure(
            records: judged.filter { status($0) == "SUCCESS" }, evaluated: judged.count)
        figures[.attestationPending] = Figure(
            records: judged.filter { status($0) == "PENDING" }, evaluated: judged.count)
        figures[.attestationProblem] = Figure(records: others, evaluated: judged.count)
        breakdowns[.attestationProblem] = Dictionary(grouping: others) { status($0) ?? "" }
    }

    private static func addBattery(
        _ managed: [DeviceInventoryRecord], _ figures: inout [Finding: Figure],
        _ breakdowns: inout [Breakdown: [String: [DeviceInventoryRecord]]]
    ) {
        let health = managed.filter { $0.management?.batteryHealth != nil }
        if !health.isEmpty {
            let service = health.filter { !batteryOK.contains($0.management?.batteryHealth ?? "") }
            figures[.batteryNeedsService] = Figure(records: service, evaluated: health.count)
            breakdowns[.batteryHealth] = Dictionary(grouping: service) {
                $0.management?.batteryHealth ?? ""
            }
        }
        let capacity = managed.filter { $0.management?.batteryCapacityPercent != nil }
        if !capacity.isEmpty {
            figures[.batteryLowCapacity] = Figure(
                records: capacity.filter {
                    ($0.management?.batteryCapacityPercent ?? .infinity) < batteryCapacityFloor
                },
                evaluated: capacity.count)
        }
    }

    private static func toggles(_ managed: [DeviceInventoryRecord]) -> [Toggle: OnOff] {
        let paths: [Toggle: KeyPath<ManagementFacts, Bool?>] = [
            .recoveryLock: \.recoveryLockEnabled, .activationLock: \.activationLockEnabled,
            .autoLoginDisabled: \.autoLoginDisabled, .remoteDesktop: \.remoteDesktopEnabled,
            .lockdownMode: \.lockdownModeEnabled, .awaitingConfiguration: \.awaitingConfiguration,
        ]
        var out: [Toggle: OnOff] = [:]
        for (toggle, path) in paths {
            let on = managed.filter { $0.management?[keyPath: path] == true }
            let off = managed.filter { $0.management?[keyPath: path] == false }
            if !on.isEmpty || !off.isEmpty { out[toggle] = OnOff(on: on, off: off) }
        }
        return out
    }
}
