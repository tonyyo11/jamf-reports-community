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
}
