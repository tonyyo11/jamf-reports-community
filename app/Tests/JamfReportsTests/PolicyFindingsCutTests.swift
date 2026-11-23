import XCTest
@testable import JamfReports

final class PolicyFindingsCutTests: XCTestCase {
    private func finding(_ severity: String, _ id: Int) -> PolicyFinding {
        PolicyFinding(
            severity: severity, policy: "Policy \(id)", policyId: "\(id)", check: "check",
            detail: "")
    }

    func testCriticalFindingPastTheCutStillShows() {
        var findings = (0..<150).map { finding("info", $0) }
        findings.append(finding("critical", 150))
        let shown = PolicyProfileView.shownFindings(findings)
        XCTAssertEqual(shown.count, 100)
        XCTAssertEqual(shown.first?.policyId, "150")
    }

    func testSeverityOrderBeforeTheCut() {
        let findings = [finding("info", 0), finding("warning", 1), finding("critical", 2)]
        let shown = PolicyProfileView.shownFindings(findings, limit: 2)
        XCTAssertEqual(shown.map(\.policyId), ["2", "1"])
    }
}
