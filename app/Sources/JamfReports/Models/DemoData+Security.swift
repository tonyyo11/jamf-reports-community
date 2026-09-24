import Foundation

/// Demo data for the posture, compliance, device-management and Protect screens.
/// Every value is derived from the shared demo facts in `DemoData.swift` and
/// `DemoData+Config.swift` (the 524-Mac fleet, its security controls, macOS
/// versions and compliance bands), so no demo screen contradicts another.
extension DemoData {

    // MARK: - macOS versions

    /// The version number in an `osDistribution` label: "macOS Sequoia 15.4" is
    /// "15.4" and "macOS 13.7.6 (Ventura)" is "13.7.6".
    static func osVersionNumber(_ label: String) -> String {
        let number = label.split(separator: " ").first { $0.first?.isNumber == true }
        return number.map(String.init) ?? label
    }

    // MARK: - Security Posture

    /// The Security Posture screen's `pro report security` snapshot: the four
    /// controls out of the 524-Mac fleet and the Overview's macOS distribution.
    static let securityPostureSnapshot = SecurityPostureService.Snapshot(
        totalDevices: securityControls.total,
        fileVaultEncrypted: securityControls.fileVault,
        sipEnabled: securityControls.sip,
        firewallEnabled: securityControls.firewall,
        gatekeeperEnabled: securityControls.gatekeeper,
        osVersions: osDistribution.map { entry in
            SecurityPostureService.Snapshot.OSVersion(
                osVersion: osVersionNumber(entry.version), count: entry.count, pct: entry.pct)
        },
        sourceFile: nil,
        snapshotDate: referenceDate
    )

    // MARK: - Compliance Posture

    /// The Compliance Posture screen's mSCP baselines. The configured benchmark is
    /// banded exactly as `complianceBands`, with 22 of the 524 Macs reporting no
    /// failure count; DISA STIG reports on every Mac.
    static let complianceBaselineResults: [MSCPComplianceService.BaselineResult] = [
        baselineResult(
            name: complianceBaseline, column: configState.failuresCountColumn,
            bandCounts: complianceBands.map(\.count)),
        baselineResult(
            name: "DISA STIG", column: "STIG Failures Count",
            bandCounts: [304, 96, 64, 32, 28]),
    ]

    /// A failure count inside each of the Pass, Low, Med-Low, Medium and High bands.
    private static let bandFailureCounts = [0, 5, 20, 40, 60]

    /// A baseline whose Pass through High bands hold `bandCounts` Macs; the rest of
    /// the fleet reports no failure count.
    private static func baselineResult(
        name: String, column: String, bandCounts: [Int]
    ) -> MSCPComplianceService.BaselineResult {
        var failures: [Int?] = []
        for (count, failureCount) in zip(bandCounts, bandFailureCounts) {
            failures += [Int?](repeating: failureCount, count: count)
        }
        let withData = failures.count
        failures += [Int?](repeating: nil, count: max(totalDevices - withData, 0))
        let passing = bandCounts.first ?? 0
        return MSCPComplianceService.BaselineResult(
            name: name,
            failuresCountColumn: column,
            bands: ComplianceBandingService.bands(failures: failures),
            noDataCount: failures.count - withData,
            totalDevices: failures.count,
            compliancePct: withData > 0 ? Double(passing) / Double(withData) * 100 : nil)
    }

    /// Macs on each macOS major version with none, one and two of FileVault, SIP,
    /// Firewall and Gatekeeper failing: 65 gaps in all, the complements of
    /// `securityControls` (firewall 42, Gatekeeper 12, FileVault 11, SIP 0).
    static let controlGapsByOSMajor: [(osMajor: Int, macsByGapCount: [Int])] = [
        (15, [360, 25, 0]), (14, [70, 12, 2]), (13, [24, 10, 4]), (12, [12, 4, 1]),
    ]

    /// The control-gap proxy the Compliance Posture screen bands by when no mSCP
    /// baseline is configured, and always uses for its per-OS breakdown.
    static let compliancePostureSnapshot: CompliancePostureService.Snapshot = {
        var pairs: [(osMajor: Int, failures: Int?)] = []
        for row in controlGapsByOSMajor {
            for (gaps, macs) in row.macsByGapCount.enumerated() {
                let pair: (osMajor: Int, failures: Int?) = (row.osMajor, gaps)
                pairs += Array(repeating: pair, count: macs)
            }
        }
        let controls = securityControls
        let failing: [(control: String, macs: Int)] = [
            ("FileVault", controls.total - controls.fileVault),
            ("SIP", controls.total - controls.sip),
            ("Firewall", controls.total - controls.firewall),
            ("Gatekeeper", controls.total - controls.gatekeeper),
        ]
        let gaps = failing
            .map { entry in
                CompliancePostureService.Snapshot.ControlGap(
                    control: entry.control, failingDevices: entry.macs,
                    totalDevices: controls.total)
            }
            .sorted { $0.failingDevices > $1.failingDevices }
        return CompliancePostureService.Snapshot(
            totalDevices: pairs.count,
            bands: ComplianceBandingService.bands(failures: pairs.map { $0.failures }),
            perOSMajor: ComplianceBandingService.bandsByOSMajor(pairs),
            controlGaps: gaps,
            sourceFile: nil,
            snapshotDate: referenceDate)
    }()
}
