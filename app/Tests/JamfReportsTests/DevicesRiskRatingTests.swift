import XCTest
@testable import JamfReports

/// One rating per Mac: the Devices Risk pill, the detail panel's badge, the Priority filter, the
/// CSV and the inventory sort all read `RiskScoringService`. The old "over 90 days since
/// check-in is Critical" rule is not a second rating.
final class DevicesRiskRatingTests: XCTestCase {

    /// Invented values, shaped like the `computers` snapshot's: every control on.
    private func healthyMac(daysSinceContact: Int?) -> DeviceInventoryRecord {
        var mac = DeviceInventoryRecord.empty(id: "serial:LAB1", source: "computers.json")
        mac.name = "Lab-Mac-01"
        mac.serial = "LAB1"
        mac.fileVault = "ENCRYPTED"
        mac.sip = "ENABLED"
        mac.firewall = "true"
        mac.gatekeeper = "APP_STORE_AND_IDENTIFIED_DEVELOPERS"
        mac.bootstrapToken = "ESCROWED"
        mac.daysSinceContact = daysSinceContact
        return mac
    }

    func testAMacStaleOverNinetyDaysWithNothingElseWrongIsLowNotCritical() {
        let mac = healthyMac(daysSinceContact: 120)
        XCTAssertEqual(mac.securityGapCount(policy: .default), 0)

        let risk = RiskScoringService.risk(for: mac, policy: .default)
        XCTAssertEqual(risk.triggered.map(\.factor), [.staleOffline])
        XCTAssertEqual(risk.score, 5)
        XCTAssertEqual(risk.level, .low)
        XCTAssertNotEqual(risk.level, .critical)
    }

    func testTheListPillAndThePanelBadgeNameTheSameBand() {
        for days in [1, 45, 120] {
            let risk = RiskScoringService.risk(
                for: healthyMac(daysSinceContact: days), policy: .default)
            let pill = DevicesView.riskPillText(risk.level)
            XCTAssertEqual(pill, risk.level.displayLabel)
            XCTAssertEqual(DevicesView.priorityRiskBadgeText(risk), "\(pill) · \(risk.score)")
        }
        var broken = healthyMac(daysSinceContact: 1)
        broken.fileVault = "UNENCRYPTED"
        let risk = RiskScoringService.risk(for: broken, policy: .default)
        XCTAssertEqual(risk.level, .high)
        XCTAssertEqual(DevicesView.riskPillText(risk.level), "High")
        XCTAssertEqual(DevicesView.priorityRiskBadgeText(risk), "High · 15")
    }

    func testEveryBandHasItsOwnTone() {
        let bands: [DeviceRisk.Level] = [.clean, .low, .medium, .high, .critical]
        let tones = bands.map { DevicesView.riskTone(for: $0) }
        XCTAssertEqual(tones, [.teal, .muted, .gold, .warn, .danger])
    }

    /// Patch failures and failed rules have their own columns and filters; with nothing else
    /// wrong they are no longer a Critical rating of their own.
    func testPatchFailuresAndFailedRulesAloneAreNotCritical() {
        var mac = healthyMac(daysSinceContact: 2)
        mac.failedRules = 40
        mac.patchFailures = (1...3).map {
            DevicePatchFailure(
                title: "App \($0)", status: "Failed", date: "2026-10-01", latestVersion: "1.0")
        }
        let risk = RiskScoringService.risk(for: mac, policy: .default)
        XCTAssertLessThan(risk.level, .critical)
        XCTAssertEqual(risk.triggered.map(\.factor), [.mscpMediumFailures])
    }

    func testTheCSVRiskColumnIsTheScoresBand() {
        let stale = healthyMac(daysSinceContact: 120)
        let row = DevicesView.exportCSV(
            devices: [stale], policy: .default,
            riskLevel: { RiskScoringService.risk(for: $0, policy: .default).level }
        ).components(separatedBy: "\n")[1]
        XCTAssertTrue(row.hasSuffix(",low"), row)
    }

    func testTheSecurityAgentFactorReachesTheRating() {
        let mac = healthyMac(daysSinceContact: 1)
        let down = RiskScoringService.SecurityAgentCheck(
            value: "Missing", connectedValue: "Installed")
        let risk = RiskScoringService.risk(for: mac, agentCheck: down, policy: .default)
        XCTAssertEqual(risk.triggered.map(\.factor), [.securityAgentDisconnected])
    }
}
