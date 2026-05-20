import XCTest
@testable import JamfReports

final class CLISuggesterExceptionsTests: XCTestCase {

    func testSuggestExceptions_WithMixedSeverityFindings() {
        // Given: 5 audit findings with mixed severity (2 categories)
        let findings = [
            createTestAuditFinding(name: "Password Policy", affected: 10, category: "Authentication",
                       recommendation: "Enable strong password requirements", severity: "high"),
            createTestAuditFinding(name: "Screen Lock", affected: 5, category: "Authentication",
                       recommendation: "Configure automatic screen lock", severity: "medium"),
            createTestAuditFinding(name: "Firewall Status", affected: 8, category: "Network",
                       recommendation: "Enable firewall on all devices", severity: "critical"),
            createTestAuditFinding(name: "Log Level", affected: 2, category: "Logging",
                       recommendation: "Set appropriate log levels", severity: "low"),
            createTestAuditFinding(name: "Banner Text", affected: 1, category: "Compliance",
                       recommendation: "Display legal banner", severity: "info")
        ]

        // When: Suggesting exceptions
        let drafts = CLISuggester.suggestExceptions(from: findings, operatorName: "John Doe")

        // Then: Should return 3 drafts (skipping the 2 low/info severity ones)
        XCTAssertEqual(drafts.count, 3)

        // Verify severity filtering
        let severities = Set(drafts.map { $0.severity })
        XCTAssertFalse(severities.contains("low"))
        XCTAssertFalse(severities.contains("info"))
        XCTAssertTrue(severities.contains("high") || severities.contains("medium") ||
                     severities.contains("critical") || severities.contains("warning"))
    }

    func testSuggestExceptions_IDCounterResetsPerCategory() {
        // Given: Findings in two categories
        let findings = [
            createTestAuditFinding(name: "Policy A", affected: 1, category: "Network",
                       recommendation: "Fix A", severity: "high"),
            createTestAuditFinding(name: "Policy B", affected: 1, category: "Network",
                       recommendation: "Fix B", severity: "medium"),
            createTestAuditFinding(name: "Config C", affected: 1, category: "Authentication",
                       recommendation: "Fix C", severity: "critical")
        ]

        // When: Suggesting exceptions
        let drafts = CLISuggester.suggestExceptions(from: findings, operatorName: "John Doe")

        // Then: Each category should have its own counter starting from 001
        XCTAssertEqual(drafts.count, 3)

        let networkDrafts = drafts.filter { $0.draftId.contains("NETWORK") }
        let authDrafts = drafts.filter { $0.draftId.contains("AUTHENTI") }

        XCTAssertEqual(networkDrafts.count, 2)
        XCTAssertEqual(authDrafts.count, 1)

        // Verify ID format includes counter
        XCTAssertTrue(networkDrafts.allSatisfy { $0.draftId.contains("-001") || $0.draftId.contains("-002") })
        XCTAssertTrue(authDrafts.allSatisfy { $0.draftId.contains("-001") })
    }

    func testSuggestExceptions_LongDescriptionTruncated() {
        // Given: Finding with very long recommendation
        let longRecommendation = String(repeating: "This is a very long recommendation that exceeds the character limit. ", count: 10)
        let findings = [
            createTestAuditFinding(name: "Long Policy", affected: 1, category: "Test",
                       recommendation: longRecommendation, severity: "high")
        ]

        // When: Suggesting exceptions
        let drafts = CLISuggester.suggestExceptions(from: findings, operatorName: "John Doe")

        // Then: Description should be truncated to 240 chars with ellipsis
        XCTAssertEqual(drafts.count, 1)
        let draft = drafts.first!
        XCTAssertTrue(draft.description.count <= 240)
        XCTAssertTrue(draft.description.hasSuffix("..."))
    }

    func testSuggestExceptions_ProposedSignedOffByMatchesParameter() {
        // Given: Findings and specific operator name
        let findings = [
            createTestAuditFinding(name: "Test Policy", affected: 1, category: "Test",
                       recommendation: "Fix this", severity: "high")
        ]
        let operatorName = "Jane Smith"

        // When: Suggesting exceptions
        let drafts = CLISuggester.suggestExceptions(from: findings, operatorName: operatorName)

        // Then: Proposed signed off by should match exactly
        XCTAssertEqual(drafts.count, 1)
        XCTAssertEqual(drafts.first?.proposedSignedOffBy, operatorName)
    }

    func testSuggestExceptions_EmptyFindingsReturnsEmptyDrafts() {
        // Given: No findings
        let findings: [AuditFinding] = []

        // When: Suggesting exceptions
        let drafts = CLISuggester.suggestExceptions(from: findings, operatorName: "John Doe")

        // Then: Should return empty array
        XCTAssertTrue(drafts.isEmpty)
    }

    func testSuggestExceptions_ProposedDateIsToday() {
        // Given: Findings
        let findings = [
            createTestAuditFinding(name: "Test Policy", affected: 1, category: "Test",
                       recommendation: "Fix this", severity: "high")
        ]

        // When: Suggesting exceptions
        let drafts = CLISuggester.suggestExceptions(from: findings, operatorName: "John Doe")

        // Then: Proposed date should be today in yyyy-MM-dd format
        XCTAssertEqual(drafts.count, 1)
        let today = Date()
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        let expectedDate = formatter.string(from: today)

        XCTAssertEqual(drafts.first?.proposedSignedOffDate, expectedDate)
    }

    func testSuggestExceptions_DeterministicOrdering() {
        // Given: Mixed findings to test ordering
        let findings = [
            createTestAuditFinding(name: "Z Policy", affected: 1, category: "B Category",
                       recommendation: "Fix Z", severity: "medium"),
            createTestAuditFinding(name: "A Policy", affected: 1, category: "A Category",
                       recommendation: "Fix A", severity: "critical"),
            createTestAuditFinding(name: "M Policy", affected: 1, category: "B Category",
                       recommendation: "Fix M", severity: "high")
        ]

        // When: Suggesting exceptions multiple times
        let drafts1 = CLISuggester.suggestExceptions(from: findings, operatorName: "John Doe")
        let drafts2 = CLISuggester.suggestExceptions(from: findings, operatorName: "John Doe")

        // Then: Results should be in same order both times
        // (severity desc, then category asc, then name asc)
        XCTAssertEqual(drafts1.count, drafts2.count)
        XCTAssertEqual(drafts1.map { $0.draftId }, drafts2.map { $0.draftId })

        // Verify order: critical first, then high, then medium
        // Within same severity: A Category before B Category
        XCTAssertEqual(drafts1[0].severity, "critical") // A Policy
        XCTAssertEqual(drafts1[1].severity, "high")     // M Policy
        XCTAssertEqual(drafts1[2].severity, "medium")   // Z Policy
    }
}

// MARK: - Test Helpers

/// Factory method for creating test AuditFinding instances
func createTestAuditFinding(name: String, affected: Int, category: String, recommendation: String, severity: String) -> AuditFinding {
    let jsonString = """
    {
        "name": "\(name)",
        "affected": \(affected),
        "category": "\(category)",
        "recommendation": "\(recommendation)",
        "severity": "\(severity)"
    }
    """
    let data = jsonString.data(using: .utf8)!
    return try! JSONDecoder().decode(AuditFinding.self, from: data)
}