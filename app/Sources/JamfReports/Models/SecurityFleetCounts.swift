import Foundation

/// Fleet counts of the four controls under a workspace's `security_policy`: the one count
/// behind summary.json's P0/P1 and security score and the Security Posture screen. It starts
/// from jamf-cli's own summary counts: the summary is the count of Macs with a control on,
/// and device rows only say which of the other Macs move. A Mac whose value reads as neither
/// on nor off (not collected, mid-transition) is not reported, not a failure; a Mac with
/// FileVault off moves to the hardware level when the hardware rule is in use.
struct SecurityFleetCounts: Sendable, Equatable {
    struct Control: Sendable, Equatable {
        let level: SecurityControlLevel
        let on: Int
        /// Macs measured off, at the control's level (the hardware rule moves some).
        let fail: Int
        let warning: Int
        /// Macs the summary does not count on whose device row reads neither on nor off. In
        /// neither bucket, and out of the share and the score. Informational at `ignore`.
        let notReported: Int

        init(level: SecurityControlLevel, on: Int, fail: Int, warning: Int, notReported: Int = 0) {
            self.level = level
            self.on = on
            self.fail = fail
            self.warning = warning
            self.notReported = notReported
        }
    }

    let totalDevices: Int
    /// Only the controls the summary carries a count for.
    let controls: [SecurityControl: Control]
    /// FileVault-off Macs the hardware rule puts below FileVault's level (warning or not
    /// counted). Zero when the rule is off or its level is `fail`.
    let fileVaultOffHardwareEncrypted: Int

    /// The workbook's row label for FileVault-off Macs the hardware rule counts apart or
    /// leaves out.
    static let hardwareEncryptedRowLabel = "FileVault off, hardware-encrypted"

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

    /// Values behind P0 that Jamf did not report: one per Mac and control, so a Mac missing two
    /// counts twice, as P0 adds up each control's gaps. Controls the policy ignores are left out.
    var p0NotReported: Int { notReported(in: [.fileVault, .sip, .firewall]) }

    /// Gatekeeper values Jamf did not report.
    var p1NotReported: Int { notReported(in: [.gatekeeper]) }

    private func notReported(in group: [SecurityControl]) -> Int {
        group.compactMap { controls[$0] }.filter { $0.level != .ignore }
            .reduce(0) { $0 + $1.notReported }
    }

    /// The share of Macs not failing `control`, for reports that grade it red, amber or
    /// green. Warnings count as not failing. Macs that did not report the control are out of
    /// the share, and for FileVault so are the Macs the hardware rule does not count, as in the
    /// score's. Nil without a count for the control, when it is not counted (`ignore`), or when
    /// no Mac is left to grade.
    func nonFailingPct(_ control: SecurityControl) -> Double? {
        guard let counts = controls[control], counts.level != .ignore else { return nil }
        let counted = totalDevices - counts.notReported
            - (control == .fileVault ? fileVaultNotCountedByHardware : 0)
        guard counted > 0 else { return nil }
        return Double(counted - counts.fail) / Double(counted) * 100
    }

    /// A control's share for the score: Macs on or at a warning (a warning is not a gap) over
    /// the Macs measured. Macs that did not report the control, and the Macs the hardware rule
    /// does not count for FileVault, are left out; when that is every Mac the control has no
    /// share this run. Nil when the report has no count for the control.
    func scoreMeasure(for control: SecurityControl) -> SecurityScoreMeasure? {
        guard let counts = controls[control] else { return nil }
        let left = counts.level == .ignore ? 0 : counts.notReported
        let counted = totalDevices - left
            - (control == .fileVault ? fileVaultNotCountedByHardware : 0)
        return SecurityScoreMeasure(passing: counts.on + counts.warning, evaluated: counted)
    }

    /// The summary's percentage for `control`: the on share of every Mac, as before, with the
    /// on count capped as `build` caps it; nil when no Mac reported the control. `reported` is
    /// the percentage jamf-cli's own figures give, kept when the cap changed nothing.
    func summaryPct(_ control: SecurityControl, reported: Double?, reportedOn: Int?) -> Double? {
        guard controls[control] != nil else { return reported }
        guard let on = onCount(control, reported: reportedOn) else { return nil }
        guard on != reportedOn, totalDevices > 0 else { return reported }
        return Double(on) / Double(totalDevices) * 100
    }

    /// The count of Macs with `control` on, for every screen and sheet that shows jamf-cli's
    /// summary counts: `reported` capped as `build` caps it, nil when no Mac reported it.
    func onCount(_ control: SecurityControl, reported: Int?) -> Int? {
        guard let counts = controls[control], totalDevices > 0 else { return reported }
        return counts.notReported < totalDevices ? counts.on : nil
    }

    /// FileVault-off Macs in no bucket and not unreported: the ones the hardware rule dropped
    /// at `ignore`.
    private var fileVaultNotCountedByHardware: Int {
        guard let counts = controls[.fileVault], counts.level != .ignore else { return 0 }
        return max(totalDevices - counts.on, 0) - counts.notReported - counts.fail
            - counts.warning
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
        // The one case rows override the summary: jamf-cli counts a Mac that never sent
        // inventory as Gatekeeper on. Neither such a Mac nor one whose row reads off can be on.
        let neverInventoried = devices.filter(\.isNeverInventoried).count
        for (control, reportedOn) in onCounts {
            let readOff = devices.filter { $0.reading(of: control, policy: policy) == false }.count
            let on = neverInventoried == 0
                ? reportedOn : min(reportedOn, max(totalDevices - neverInventoried - readOff, 0))
            let level = policy.level(for: control)
            let notOn = max(totalDevices - on, 0)
            let notReported = unreported(control, among: devices, notOn: notOn, policy: policy)
            let off = notOn - notReported
            controls[control] = Control(
                level: level, on: on, fail: level == .fail ? off : 0,
                warning: level == .warning ? off : 0, notReported: notReported)
        }
        var lowered = 0
        if policy.usesHardwareRule, let hardwareLevel = policy.fileVaultOffHardwareEncrypted,
           let fileVault = controls[.fileVault] {
            let applies = devices.filter {
                policy.hardwareRuleApplies(
                    fileVaultReading: $0.reading(of: .fileVault, policy: policy),
                    hardwareEncrypted: HardwareEncryption.lookup(
                        serial: $0.serial, name: $0.name, in: hardware))
            }.count
            // The summary counts the fleet; rows only say which of its measured-off Macs move.
            let measuredOff = max(totalDevices - fileVault.on, 0) - fileVault.notReported
            let moved = min(measuredOff, applies)
            controls[.fileVault] = fileVault.moving(moved, to: hardwareLevel)
            lowered = hardwareLevel == .fail ? 0 : moved
        }
        return SecurityFleetCounts(
            totalDevices: totalDevices, controls: controls, fileVaultOffHardwareEncrypted: lowered)
    }

    /// How many of the `notOn` Macs the summary does not count on read as neither on nor off in
    /// their device rows. Rows that read off take their share of `notOn` first, so a summary and
    /// rows that disagree can hide no Mac measured off. Zero without device rows.
    private static func unreported(
        _ control: SecurityControl, among devices: [SecurityDevice], notOn: Int,
        policy: SecurityControlPolicy
    ) -> Int {
        let readings = devices.map { $0.reading(of: control, policy: policy) }
        let measuredOff = min(readings.filter { $0 == false }.count, notOn)
        return min(readings.filter { $0 == nil }.count, notOn - measuredOff)
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
        return Self(level: self.level, on: on, fail: fail, warning: warning,
                    notReported: notReported)
    }
}

extension SecurityDevice {
    /// The row is a Mac with no inventory yet (`NeverInventoried`).
    var isNeverInventoried: Bool { NeverInventoried.isNeverInventoried(osVersion: osVersion) }

    /// A device row's value for `control` as on, off or not reported. The report's firewall is
    /// a boolean, so it reads as measured whenever the row carries it, except on a Mac that has
    /// never sent inventory, which reports nothing.
    func reading(of control: SecurityControl, policy: SecurityControlPolicy) -> Bool? {
        guard !isNeverInventoried else { return nil }
        return switch control {
        case .fileVault: policy.reading(fileVault, for: control)
        case .sip: policy.reading(sip, for: control)
        case .firewall: firewall
        case .gatekeeper: policy.reading(gatekeeper, for: control)
        }
    }
}
