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
}
