import XCTest
@testable import JamfReports

/// Demo screens must agree with the shared demo facts (`DemoData.swift`,
/// `DemoData+Config.swift`): the 524-Mac fleet, its security controls, macOS
/// versions and compliance bands. A demo number that contradicts another screen
/// reads as a bug in the product, not in the demo.
@MainActor
final class DemoDataSecurityTests: XCTestCase {

    // MARK: - Security Posture

    func testSecurityPostureCountsTheFleetsControls() {
        let snapshot = DemoData.securityPostureSnapshot
        let controls = DemoData.securityControls
        XCTAssertEqual(snapshot.totalDevices, DemoData.totalDevices)
        XCTAssertEqual(snapshot.fileVaultEncrypted, controls.fileVault)
        XCTAssertEqual(snapshot.sipEnabled, controls.sip)
        XCTAssertEqual(snapshot.firewallEnabled, controls.firewall)
        XCTAssertEqual(snapshot.gatekeeperEnabled, controls.gatekeeper)
        XCTAssertLessThanOrEqual(snapshot.snapshotDate ?? .distantFuture, DemoData.referenceDate)
    }

    func testSecurityPostureDonutIsTheOverviewDistribution() {
        let versions = DemoData.securityPostureSnapshot.osVersions
        XCTAssertEqual(versions.map(\.osVersion), ["15.4", "15.3.2", "14.7.4", "13.7.6", "12.7.6"])
        XCTAssertEqual(versions.map(\.count), DemoData.osDistribution.map(\.count))
        XCTAssertEqual(versions.reduce(0) { $0 + $1.count }, DemoData.totalDevices)
    }

    /// P0 is the FileVault, SIP and Firewall gaps, P1 the Gatekeeper gaps.
    func testSecurityPostureActionItems() {
        let controls = DemoData.securityControls
        let p0 = (controls.total - controls.fileVault) + (controls.total - controls.sip)
            + (controls.total - controls.firewall)
        XCTAssertEqual(p0, 53)
        XCTAssertEqual(controls.total - controls.gatekeeper, 12)
    }

    /// The ring's value with the default weights. The Overview's Security Score
    /// card ends on `DemoData.trends[.securityScore]`, which should match it.
    func testSecurityScoreRingWithDefaultWeights() {
        let score = SecurityScoreCalculator.score(
            input: SecurityScoreCalculator.input(from: DemoData.securityPostureSnapshot),
            weights: .defaultWeights)
        XCTAssertEqual(score.value, 96.6, accuracy: 0.001)
        XCTAssertEqual(score.grade, .aPlus)
        XCTAssertEqual(score.available, [.fileVault, .sip, .firewall])
    }
}
