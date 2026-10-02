import Foundation

/// Fleet counts of the four controls under a workspace's `security_policy`: the one count
/// behind summary.json's P0/P1 and security score and the Security Posture screen. It starts
/// from jamf-cli's own summary counts; device rows only move hardware-encrypted Macs with
/// FileVault off when the hardware rule is in use.
struct SecurityFleetCounts: Sendable, Equatable {
    struct Control: Sendable, Equatable {
        let level: SecurityControlLevel
        let on: Int
        let fail: Int
        let warning: Int
    }

    let totalDevices: Int
    /// Only the controls the summary carries a count for.
    let controls: [SecurityControl: Control]
    /// FileVault-off Macs the hardware rule puts below FileVault's level (warning or not
    /// counted). Zero when the rule is off or its level is `fail`.
    let fileVaultOffHardwareEncrypted: Int

    static let empty = SecurityFleetCounts(
        totalDevices: 0, controls: [:], fileVaultOffHardwareEncrypted: 0)

    /// FileVault, SIP and Firewall failures. Nil without a FileVault count, as it always was.
    var p0: Int? {
        guard controls[.fileVault] != nil else { return nil }
        return [SecurityControl.fileVault, .sip, .firewall]
            .compactMap { controls[$0]?.fail }
            .reduce(0, +)
    }

    /// Gatekeeper failures; nil without a Gatekeeper count.
    var p1: Int? { controls[.gatekeeper]?.fail }

    /// The share of Macs not failing `control`, for reports that grade it red, amber or
    /// green. Warnings count as not failing. For FileVault the Macs the hardware rule does not
    /// count are out of the share, as in the score's. Nil without a count for the control,
    /// when it is not counted (`ignore`), or when no Mac is left to grade.
    func nonFailingPct(_ control: SecurityControl) -> Double? {
        guard let counts = controls[control], counts.level != .ignore else { return nil }
        let counted = totalDevices - (control == .fileVault ? fileVaultNotCountedByHardware : 0)
        guard counted > 0 else { return nil }
        return Double(counted - counts.fail) / Double(counted) * 100
    }

    /// A warning is not a gap, so it scores as compliant. An ignored control keeps its count,
    /// so `effectiveScoreWeights` can drop it without the score calling it missing. Macs the
    /// hardware rule does not count are left out of FileVault's share; when that is every
    /// Mac, FileVault has no share this run.
    func scoreInput() -> SecurityScoreCalculator.Input {
        let scored: [(SecurityControl, SecurityScore.Metric)] = [
            (.fileVault, .fileVault), (.sip, .sip), (.firewall, .firewall),
        ]
        var compliant: [SecurityScore.Metric: Int] = [:]
        var totals: [SecurityScore.Metric: Int] = [:]
        for (control, metric) in scored {
            guard let counts = controls[control] else { continue }
            if control == .fileVault, fileVaultNotCountedByHardware > 0 {
                let counted = totalDevices - fileVaultNotCountedByHardware
                guard counted > 0 else { continue }
                totals[metric] = counted
            }
            compliant[metric] = counts.on + counts.warning
        }
        return .init(totalDevices: totalDevices, compliantCounts: compliant, metricTotals: totals)
    }

    /// FileVault-off Macs in neither bucket: the ones the hardware rule dropped at `ignore`.
    private var fileVaultNotCountedByHardware: Int {
        guard let counts = controls[.fileVault], counts.level != .ignore else { return 0 }
        return max(totalDevices - counts.on, 0) - counts.fail - counts.warning
    }

    static func onCounts(_ summary: SecuritySummaryData) -> [SecurityControl: Int] {
        var counts: [SecurityControl: Int] = [:]
        counts[.fileVault] = summary.fileVaultEncrypted
        counts[.sip] = summary.sipEnabled
        counts[.firewall] = summary.firewallEnabled
        counts[.gatekeeper] = summary.gatekeeperEnabled
        return counts
    }

    static func build(
        totalDevices: Int, onCounts: [SecurityControl: Int], devices: [SecurityDevice],
        hardware: [String: Bool], policy: SecurityControlPolicy
    ) -> SecurityFleetCounts {
        var controls: [SecurityControl: Control] = [:]
        for (control, on) in onCounts {
            let level = policy.level(for: control)
            let off = max(totalDevices - on, 0)
            controls[control] = Control(
                level: level, on: on, fail: level == .fail ? off : 0,
                warning: level == .warning ? off : 0)
        }
        var lowered = 0
        if policy.usesHardwareRule, let hardwareLevel = policy.fileVaultOffHardwareEncrypted,
           let fileVault = controls[.fileVault] {
            let applies = devices.filter {
                policy.hardwareRuleApplies(
                    fileVaultReading: SecurityControlPolicy.reading($0.fileVault),
                    hardwareEncrypted: HardwareEncryption.lookup(
                        serial: $0.serial, name: $0.name, in: hardware))
            }.count
            // The summary counts the fleet; rows only say which of its off Macs move.
            let moved = min(max(totalDevices - fileVault.on, 0), applies)
            controls[.fileVault] = fileVault.moving(moved, to: hardwareLevel)
            lowered = hardwareLevel == .fail ? 0 : moved
        }
        return SecurityFleetCounts(
            totalDevices: totalDevices, controls: controls, fileVaultOffHardwareEncrypted: lowered)
    }

    /// Nil without a summary section.
    static func build(
        items: [SecurityReportItem], hardware: [String: Bool], policy: SecurityControlPolicy
    ) -> SecurityFleetCounts? {
        var summary: SecuritySummaryData?
        var devices: [SecurityDevice] = []
        for item in items {
            switch item {
            case .summary(let section): summary = section.data
            case .device(let device): devices.append(device)
            case .osVersion, .unknown: continue
            }
        }
        guard let summary else { return nil }
        return build(
            totalDevices: summary.totalDevices ?? 0, onCounts: onCounts(summary),
            devices: devices, hardware: hardware, policy: policy)
    }
}

private extension SecurityFleetCounts.Control {
    /// `count` Macs leave this control's own bucket for the bucket of `level`; at `ignore`
    /// they are in neither.
    func moving(_ count: Int, to level: SecurityControlLevel) -> Self {
        let fail = fail - (self.level == .fail ? count : 0) + (level == .fail ? count : 0)
        let warning = warning - (self.level == .warning ? count : 0)
            + (level == .warning ? count : 0)
        return Self(level: self.level, on: on, fail: fail, warning: warning)
    }
}
