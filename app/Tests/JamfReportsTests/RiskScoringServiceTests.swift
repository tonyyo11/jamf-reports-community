import Foundation
import XCTest
@testable import JamfReports

final class RiskScoringServiceTests: XCTestCase {

    func testSafeInputScoresClean() {
        let risk = RiskScoringService.score(input: .safe)
        XCTAssertEqual(risk.score, 0)
        XCTAssertEqual(risk.level, .clean)
        XCTAssertTrue(risk.triggered.isEmpty)
    }

    func testNoFileVaultIsHighRiskAlone() {
        // FileVault alone is 15 pts in v3.5 defaults — exactly the High band.
        var input = RiskScoringService.Input.safe
        input.fileVaultEncrypted = false
        let risk = RiskScoringService.score(input: input)

        XCTAssertEqual(risk.score, 15)
        XCTAssertEqual(risk.level, .high)
        XCTAssertEqual(risk.triggered.first?.factor, .noFileVault)
    }

    func testCriticalDeviceStacksMultipleFactors() {
        // FV off (15) + SIP off (8) + Firewall off (6) = 29 → Critical
        var input = RiskScoringService.Input.safe
        input.fileVaultEncrypted = false
        input.sipEnabled = false
        input.firewallEnabled = false
        let risk = RiskScoringService.score(input: input)

        XCTAssertEqual(risk.score, 29)
        XCTAssertEqual(risk.level, .critical)
        XCTAssertEqual(risk.triggered.map(\.factor),
                       [.noFileVault, .sipDisabled, .firewallDisabled])
    }

    func testMscpHighFailuresAreCapped() {
        // Default cap is 21 points = 3 High failures × 7. A device with 10
        // Highs should still only be charged 21 points, not 70.
        var input = RiskScoringService.Input.safe
        input.mscpHighFailures = 10
        let risk = RiskScoringService.score(input: input)

        XCTAssertEqual(risk.score, 21)
        XCTAssertEqual(risk.level, .critical)
        XCTAssertEqual(risk.triggered.first?.detail, "10 High failures")
    }

    func testNoBaselineOnlyPenalizesActiveDevices() {
        var inactive = RiskScoringService.Input.safe
        inactive.hasBaseline = false
        inactive.daysSinceCheckIn = 60  // > 30 → stale, not active

        let inactiveRisk = RiskScoringService.score(input: inactive)
        XCTAssertFalse(inactiveRisk.triggered.contains { $0.factor == .noBaseline },
                       "Stale device should not be penalized for missing baseline")

        var active = RiskScoringService.Input.safe
        active.hasBaseline = false
        let activeRisk = RiskScoringService.score(input: active)
        XCTAssertTrue(activeRisk.triggered.contains { $0.factor == .noBaseline })
    }

    func testSecurityAgentConnectivityIsOnlyScoredWhenAgentDeployed() {
        // nil = no agent configured / no EA data → do not penalize
        var noAgent = RiskScoringService.Input.safe
        noAgent.securityAgentConnected = nil
        XCTAssertEqual(RiskScoringService.score(input: noAgent).score, 0)

        // false = agent configured but disconnected → penalize
        var disconnected = RiskScoringService.Input.safe
        disconnected.securityAgentConnected = false
        XCTAssertEqual(RiskScoringService.score(input: disconnected).score, 5)
        XCTAssertTrue(
            RiskScoringService.score(input: disconnected).triggered
                .contains { $0.factor == .securityAgentDisconnected }
        )

        // true = agent connected → no penalty
        var connected = RiskScoringService.Input.safe
        connected.securityAgentConnected = true
        XCTAssertEqual(RiskScoringService.score(input: connected).score, 0)
    }

    // MARK: - Security-agent check (config-driven, replaces hardcoded Nessus)

    func testSecurityAgentCheckMatchesConnectedValueCaseInsensitively() {
        // connected_value is a case-insensitive substring match (config contract).
        let connected = RiskScoringService.SecurityAgentCheck(
            value: "Agent CONNECTED to cloud.tenable.com", connectedValue: "connected"
        )
        XCTAssertEqual(connected.isConnected, true)

        let disconnected = RiskScoringService.SecurityAgentCheck(
            value: "Unlinked", connectedValue: "connected"
        )
        XCTAssertEqual(disconnected.isConnected, false)
    }

    func testSecurityAgentCheckHasNoSignalForEmptyValues() {
        XCTAssertNil(RiskScoringService.SecurityAgentCheck(
            value: "", connectedValue: "connected"
        ).isConnected, "empty EA value = no data, not a finding")
        XCTAssertNil(RiskScoringService.SecurityAgentCheck(
            value: "Connected", connectedValue: ""
        ).isConnected, "empty connected_value = unconfigured, not a finding")
    }

    func testAdapterFeedsAgentCheckIntoScore() {
        let record = DeviceInventoryRecord(
            id: "JSS-200", jamfID: "200", name: "Mac-200", serial: "DEF456",
            osVersion: "15.4", model: "MacBookPro18,1", user: "bob",
            email: "bob@example.org", department: "Eng", building: "HQ",
            site: "main", ipAddress: "10.0.0.2", assetTag: "AT-002",
            managedState: "Managed", lastContact: "2026-05-10T12:00:00Z",
            lastInventory: "2026-05-10T12:00:00Z", daysSinceContact: 2,
            stale: false, fileVault: "Encrypted", sip: "Enabled",
            firewall: "Enabled", gatekeeper: "Enabled",
            bootstrapToken: "Escrowed", diskUsage: "62%", failedRules: 0,
            patchFailures: [], source: "jamf-cli"
        )
        let disconnectedInput = RiskScoringService.Input.from(
            record: record,
            agentCheck: .init(value: "Service not running", connectedValue: "Connected")
        )
        XCTAssertEqual(disconnectedInput.securityAgentConnected, false)

        let noCheckInput = RiskScoringService.Input.from(record: record)
        XCTAssertNil(noCheckInput.securityAgentConnected)
    }

    func testAgentFactorLabelsAreConfigDrivenNotHardcoded() {
        let factor = DeviceRisk.Factor.securityAgentDisconnected
        XCTAssertEqual(factor.displayLabel, "Security Agent Disconnected")
        XCTAssertFalse(factor.displayLabel.localizedCaseInsensitiveContains("nessus"))
        XCTAssertFalse(factor.remediation.localizedCaseInsensitiveContains("nessus"))
        XCTAssertEqual(
            factor.displayLabel(agentName: "Nessus Agent"), "Nessus Agent Disconnected"
        )
        XCTAssertEqual(
            factor.remediation(agentName: "CrowdStrike Falcon"),
            "Re-link CrowdStrike Falcon via its deployment policy."
        )
        // Other factors ignore the agent name.
        XCTAssertEqual(
            DeviceRisk.Factor.noFileVault.displayLabel(agentName: "Anything"),
            "No FileVault Encryption"
        )
    }

    func testSecureBootMediumAndNoneScoreDifferently() {
        var medium = RiskScoringService.Input.safe
        medium.secureBootLevel = .medium
        var none = RiskScoringService.Input.safe
        none.secureBootLevel = .none

        XCTAssertEqual(RiskScoringService.score(input: medium).score, 5)
        XCTAssertEqual(RiskScoringService.score(input: none).score, 12)
    }

    func testBootDriveThresholdRespectsConfigurableCutoff() {
        var input = RiskScoringService.Input.safe
        input.bootDrivePctUsed = 94
        XCTAssertEqual(RiskScoringService.score(input: input).score, 0,
                       "94% should be below default 95% threshold")

        input.bootDrivePctUsed = 96
        let risk = RiskScoringService.score(input: input)
        XCTAssertEqual(risk.score, 8)
        XCTAssertEqual(risk.triggered.first?.detail, "96% used")
    }

    func testInputFromInventoryRecordInterpretsStringStatuses() {
        let record = DeviceInventoryRecord(
            id: "JSS-100",
            jamfID: "100",
            name: "Mac-100",
            serial: "ABC123",
            osVersion: "15.4",
            model: "MacBookPro18,1",
            user: "alice",
            email: "alice@example.org",
            department: "Eng",
            building: "HQ",
            site: "main",
            ipAddress: "10.0.0.1",
            assetTag: "AT-001",
            managedState: "Managed",
            lastContact: "2026-05-10T12:00:00Z",
            lastInventory: "2026-05-10T12:00:00Z",
            daysSinceContact: 2,
            stale: false,
            fileVault: "Encrypted",
            sip: "Enabled",
            firewall: "Disabled",   // <- only failing one
            gatekeeper: "Enabled",
            bootstrapToken: "Escrowed",
            diskUsage: "62%",
            failedRules: 0,
            patchFailures: [],
            source: "jamf-cli"
        )

        let input = RiskScoringService.Input.from(record: record)

        XCTAssertTrue(input.fileVaultEncrypted)
        XCTAssertTrue(input.sipEnabled)
        XCTAssertFalse(input.firewallEnabled)
        XCTAssertTrue(input.gatekeeperEnabled)
        XCTAssertTrue(input.bootstrapEscrowed)
        XCTAssertEqual(input.bootDrivePctUsed ?? -1, 62, accuracy: 0.01)
        XCTAssertEqual(RiskScoringService.score(input: input).score, 6)
    }

    func testBandThresholdsCoverAllLevels() {
        XCTAssertEqual(DeviceRisk.Level.from(score: 0), .clean)
        XCTAssertEqual(DeviceRisk.Level.from(score: 1), .low)
        XCTAssertEqual(DeviceRisk.Level.from(score: 9), .low)
        XCTAssertEqual(DeviceRisk.Level.from(score: 10), .medium)
        XCTAssertEqual(DeviceRisk.Level.from(score: 14), .medium)
        XCTAssertEqual(DeviceRisk.Level.from(score: 15), .high)
        XCTAssertEqual(DeviceRisk.Level.from(score: 19), .high)
        XCTAssertEqual(DeviceRisk.Level.from(score: 20), .critical)
        XCTAssertEqual(DeviceRisk.Level.from(score: 100), .critical)
    }

    // MARK: - Status-string polarity

    private func statusRecord(
        fileVault: String, sip: String, firewall: String, gatekeeper: String
    ) -> DeviceInventoryRecord {
        DeviceInventoryRecord(
            id: "JSS-900", jamfID: "900", name: "Mac-900", serial: "POLARITY9",
            osVersion: "15.4", model: "MacBookPro18,1", user: "carol",
            email: "carol@example.org", department: "Eng", building: "HQ",
            site: "main", ipAddress: "10.0.0.9", assetTag: "AT-009",
            managedState: "Managed", lastContact: "2026-05-10T12:00:00Z",
            lastInventory: "2026-05-10T12:00:00Z", daysSinceContact: 1,
            stale: false, fileVault: fileVault, sip: sip,
            firewall: firewall, gatekeeper: gatekeeper,
            bootstrapToken: "Escrowed", diskUsage: "10%", failedRules: 0,
            patchFailures: [], source: "jamf-cli"
        )
    }

    /// "not enabled" contains "enabled" and "not encrypted" contains
    /// "encrypted", so testing positive substrings before negative ones scored
    /// every disabled control as passing — an unprotected Mac scored Clean and
    /// dropped out of the Priority filter. These are Jamf's own word-form
    /// export values.
    func testJamfWordFormNegativesScoreAsFailing() {
        let input = RiskScoringService.Input.from(record: statusRecord(
            fileVault: "Not Encrypted", sip: "Not Enabled",
            firewall: "Not Enabled", gatekeeper: "Off"
        ))
        XCTAssertFalse(input.fileVaultEncrypted, "\"Not Encrypted\" is not encrypted")
        XCTAssertFalse(input.sipEnabled, "\"Not Enabled\" is not enabled")
        XCTAssertFalse(input.firewallEnabled, "\"Not Enabled\" is not enabled")
        XCTAssertFalse(input.gatekeeperEnabled, "\"Off\" is not enabled")

        let risk = RiskScoringService.score(input: input)
        XCTAssertGreaterThan(risk.score, 0)
        XCTAssertNotEqual(risk.level, .clean, "an unprotected Mac must never score Clean")
    }

    /// Underscore forms reach us from the API path rather than the CSV export;
    /// normalization must fold them onto the same values.
    func testUnderscoreFormNegativesScoreAsFailing() {
        let input = RiskScoringService.Input.from(record: statusRecord(
            fileVault: "NOT_ENCRYPTED", sip: "NOT_ENABLED",
            firewall: "DISABLED", gatekeeper: "NOT_ENABLED"
        ))
        XCTAssertFalse(input.fileVaultEncrypted)
        XCTAssertFalse(input.sipEnabled)
        XCTAssertFalse(input.firewallEnabled)
        XCTAssertFalse(input.gatekeeperEnabled)
    }

    func testAffirmativeStatusesStillPass() {
        let input = RiskScoringService.Input.from(record: statusRecord(
            fileVault: "Encrypted", sip: "Enabled",
            firewall: "Enabled", gatekeeper: "Yes"
        ))
        XCTAssertTrue(input.fileVaultEncrypted)
        XCTAssertTrue(input.sipEnabled)
        XCTAssertTrue(input.firewallEnabled)
        XCTAssertTrue(input.gatekeeperEnabled)
    }

    /// An absent value is not a failing value — a control we never measured
    /// must not be scored as disabled.
    func testEmptyStatusIsNotScoredAsFailing() {
        let input = RiskScoringService.Input.from(record: statusRecord(
            fileVault: "", sip: "", firewall: "", gatekeeper: ""
        ))
        XCTAssertTrue(input.fileVaultEncrypted)
        XCTAssertTrue(input.sipEnabled)
    }
}
