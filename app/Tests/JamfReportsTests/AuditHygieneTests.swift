import Foundation
import XCTest
@testable import JamfReports

final class AuditHygieneTests: XCTestCase {

    func testAuditFindingDecoding() throws {
        let json = """
        [
            {
                "name": "Audit failure halt",
                "affected": 52,
                "category": "Logging and Auditing",
                "recommendation": "Configure audit_failure_halt to 2 (suspend)",
                "severity": "CRITICAL"
            },
            {
                "name": "Audit record generation",
                "affected": 0,
                "category": "Logging and Auditing",
                "recommendation": "Ensure auditd is running",
                "severity": "OK"
            }
        ]
        """.data(using: .utf8)!

        let decoder = JSONDecoder()
        let findings = try decoder.decode([AuditFinding].self, from: json)

        XCTAssertEqual(findings.count, 2)
        XCTAssertEqual(findings[0].name, "Audit failure halt")
        XCTAssertEqual(findings[0].severity, "CRITICAL")
        XCTAssertEqual(findings[1].severity, "OK")
    }

    // MARK: - affectedDisplay

    /// CRITICAL/WARNING findings with affected==0 must display "—" because
    /// `pro audit` is an instance-config check with no per-device breakdown;
    /// "0 affected" next to CRITICAL would mislead operators into thinking
    /// no remediation is required.
    func testAffectedDisplayDashForNonOKZero() {
        let critical = AuditFinding(
            name: "FileVault Unencrypted",
            affected: 0,
            category: "Encryption",
            recommendation: "Enable FileVault",
            severity: "CRITICAL"
        )
        XCTAssertEqual(critical.affectedDisplay, "—")

        let warning = AuditFinding(
            name: "Outdated OS Version",
            affected: 0,
            category: "Update",
            recommendation: "Install latest OS",
            severity: "WARNING"
        )
        XCTAssertEqual(warning.affectedDisplay, "—")
    }

    /// OK findings with affected==0 must display "0" because the control
    /// passed; "—" here would hide a meaningful zero.
    func testAffectedDisplayZeroForOKFindings() {
        let ok = AuditFinding(
            name: "Audit record generation",
            affected: 0,
            category: "Logging",
            recommendation: "Ensure auditd is running",
            severity: "OK"
        )
        XCTAssertEqual(ok.affectedDisplay, "0")
    }

    /// Findings with a non-zero affected count always display the integer.
    func testAffectedDisplayNumericForNonZero() {
        let critical = AuditFinding(
            name: "Audit failure halt",
            affected: 52,
            category: "Logging",
            recommendation: "Configure audit_failure_halt",
            severity: "CRITICAL"
        )
        XCTAssertEqual(critical.affectedDisplay, "52")
    }

    func testUnusedGroupDecoding() throws {
        let json = """
        [
            {
                "id": "14",
                "name": "All Managed Clients",
                "memberCount": 850,
                "type": "computer_group",
                "reason": "Referenced by 12 policies"
            },
            {
                "id": "101",
                "name": "Unused Test Group",
                "memberCount": 0,
                "type": "smart_group",
                "reason": null
            }
        ]
        """.data(using: .utf8)!

        let decoder = JSONDecoder()
        let groups = try decoder.decode([UnusedGroup].self, from: json)

        XCTAssertEqual(groups.count, 2)
        XCTAssertEqual(groups[0].id, "14")
        XCTAssertEqual(groups[0].reason, "Referenced by 12 policies")
        XCTAssertEqual(groups[1].reasonLabel, "Not referenced by any policy or profile.")
    }

    // MARK: - Take-action routing (#184 follow-on)

    private func finding(_ name: String, category: String = "Security") -> AuditFinding {
        AuditFinding(name: name, affected: 1, category: category,
                     recommendation: "r", severity: "WARNING")
    }

    func testAuditActionDestinationRoutesKnownFindings() {
        XCTAssertEqual(auditActionDestination(for: finding("Unencrypted devices"))?.tab, .securityPosture)
        XCTAssertEqual(auditActionDestination(for: finding("Stale check-in (>14 days)", category: "Compliance"))?.tab, .outreach)
        XCTAssertEqual(auditActionDestination(for: finding("Policies with no scope", category: "Hygiene"))?.tab, .policyProfile)
        XCTAssertEqual(auditActionDestination(for: finding("Gatekeeper disabled"))?.tab, .securityPosture)
    }

    func testAuditActionDestinationCategoryFallback() {
        XCTAssertEqual(auditActionDestination(for: finding("Mystery finding", category: "Compliance"))?.tab, .compliancePosture)
        XCTAssertNil(auditActionDestination(for: finding("Mystery finding", category: "Inventory")),
                     "unknown name + category routes nowhere rather than somewhere wrong")
    }

    // MARK: - Name-based routes not previously covered

    func testAuditActionDestinationPatchNameRoutesToPatch() {
        XCTAssertEqual(auditActionDestination(for: finding("Patch compliance gap"))?.tab, .patch)
    }

    func testAuditActionDestinationUpdateNameRoutesToUpdates() {
        XCTAssertEqual(auditActionDestination(for: finding("Update plan failures"))?.tab, .updates)
    }

    func testAuditActionDestinationExtensionAttributeNameRoutesToEA() {
        XCTAssertEqual(
            auditActionDestination(for: finding("Extension attribute coverage low"))?.tab,
            .extensionAttributes
        )
    }

    func testAuditActionDestinationGroupNameRoutesToGroupInventory() {
        XCTAssertEqual(auditActionDestination(for: finding("Unused group detected"))?.tab, .groupInventory)
    }
}
