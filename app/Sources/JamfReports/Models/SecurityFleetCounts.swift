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

    /// A warning is not a gap, so it scores as compliant. An ignored control keeps its count,
    /// so `effectiveScoreWeights` can drop it without the score calling it missing.
    func scoreInput() -> SecurityScoreCalculator.Input {
        let scored: [(SecurityControl, SecurityScore.Metric)] = [
            (.fileVault, .fileVault), (.sip, .sip), (.firewall, .firewall),
        ]
        var compliant: [SecurityScore.Metric: Int] = [:]
        for (control, metric) in scored {
            if let counts = controls[control] { compliant[metric] = counts.on + counts.warning }
        }
        return .init(totalDevices: totalDevices, compliantCounts: compliant)
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
