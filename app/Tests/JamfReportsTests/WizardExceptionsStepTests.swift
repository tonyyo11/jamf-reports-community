import XCTest
@testable import JamfReports

@MainActor
final class WizardExceptionsStepTests: XCTestCase {

    var wizardState: WizardState!

    override func setUp() async throws {
        try await super.setUp()
        wizardState = WizardState()
    }

    override func tearDown() async throws {
        wizardState = nil
        try await super.tearDown()
    }

    func testAcceptDraft_CreatesConfigException() {
        // Given: A draft exception
        let draft = CLISuggester.DraftException(
            draftId: "TEST-POLICY-001",
            description: "Test exception description",
            linkedFinding: "Authentication.Password Policy",
            proposedSignedOffBy: "John Doe",
            proposedSignedOffDate: "2026-05-07",
            severity: "high"
        )
        wizardState.exceptionDrafts = [draft]

        // When: Accepting the draft
        let exception = wizardState.acceptDraft(draft)

        // Then: Should create ConfigException with matching fields
        XCTAssertEqual(exception.id, "TEST-POLICY-001")
        XCTAssertEqual(exception.description, "Test exception description")
        XCTAssertEqual(exception.signedOffBy, "John Doe")
        XCTAssertEqual(exception.signedOffDate, "2026-05-07")
        XCTAssertEqual(exception.linkedFinding, "Authentication.Password Policy")
        XCTAssertNil(exception.expiresDate)
    }

    func testAcceptDraft_RemovesFromDraftsAndAddsToExceptions() {
        // Given: Draft exception in the state
        let draft = CLISuggester.DraftException(
            draftId: "TEST-001",
            description: "Test",
            linkedFinding: "Test.Finding",
            proposedSignedOffBy: "John Doe",
            proposedSignedOffDate: "2026-05-07",
            severity: "medium"
        )
        wizardState.exceptionDrafts = [draft]
        XCTAssertEqual(wizardState.exceptionDrafts.count, 1)
        XCTAssertEqual(wizardState.exceptions.count, 0)

        // When: Accepting the draft
        _ = wizardState.acceptDraft(draft)

        // Then: Should remove from drafts and add to exceptions
        XCTAssertEqual(wizardState.exceptionDrafts.count, 0)
        XCTAssertEqual(wizardState.exceptions.count, 1)
    }

    func testRejectDraft_RemovesFromDraftsWithoutAdding() {
        // Given: Draft exception in the state
        let draft = CLISuggester.DraftException(
            draftId: "TEST-002",
            description: "Test rejection",
            linkedFinding: nil,
            proposedSignedOffBy: "Jane Smith",
            proposedSignedOffDate: "2026-05-07",
            severity: "low"
        )
        wizardState.exceptionDrafts = [draft]
        XCTAssertEqual(wizardState.exceptionDrafts.count, 1)
        XCTAssertEqual(wizardState.exceptions.count, 0)

        // When: Rejecting the draft
        wizardState.rejectDraft(draft)

        // Then: Should remove from drafts without adding to exceptions
        XCTAssertEqual(wizardState.exceptionDrafts.count, 0)
        XCTAssertEqual(wizardState.exceptions.count, 0)
    }

    func testAddEmptyException_CreatesManualEntry() {
        // Given: Empty wizard state
        XCTAssertEqual(wizardState.exceptions.count, 0)

        // When: Adding empty exception
        wizardState.addEmptyException()

        // Then: Should create manual exception with default values
        XCTAssertEqual(wizardState.exceptions.count, 1)
        let exception = wizardState.exceptions.first!
        XCTAssertEqual(exception.id, "MANUAL-001")
        XCTAssertEqual(exception.description, "Manual exception entry")
        XCTAssertEqual(exception.signedOffBy, "")
        XCTAssertEqual(exception.signedOffDate, "")
        XCTAssertNil(exception.linkedFinding)
    }

    func testAddEmptyException_IncrementsCounter() {
        // Given: One existing exception
        wizardState.exceptions = [
            ConfigException(id: "EXISTING-001", description: "Existing",
                          signedOffBy: "Someone", signedOffDate: "2026-01-01")
        ]

        // When: Adding empty exception
        wizardState.addEmptyException()

        // Then: Should increment counter in ID
        XCTAssertEqual(wizardState.exceptions.count, 2)
        let newException = wizardState.exceptions.last!
        XCTAssertEqual(newException.id, "MANUAL-002")
    }

    func testMultipleDrafts_AcceptAndRejectMixed() {
        // Given: Multiple drafts
        let draft1 = CLISuggester.DraftException(
            draftId: "DRAFT-001",
            description: "First draft",
            linkedFinding: "Category.Rule1",
            proposedSignedOffBy: "John Doe",
            proposedSignedOffDate: "2026-05-07",
            severity: "high"
        )
        let draft2 = CLISuggester.DraftException(
            draftId: "DRAFT-002",
            description: "Second draft",
            linkedFinding: "Category.Rule2",
            proposedSignedOffBy: "Jane Smith",
            proposedSignedOffDate: "2026-05-07",
            severity: "medium"
        )
        wizardState.exceptionDrafts = [draft1, draft2]

        // When: Accept one, reject another
        _ = wizardState.acceptDraft(draft1)
        wizardState.rejectDraft(draft2)

        // Then: Should have one exception and no drafts
        XCTAssertEqual(wizardState.exceptions.count, 1)
        XCTAssertEqual(wizardState.exceptionDrafts.count, 0)
        XCTAssertEqual(wizardState.exceptions.first?.id, "DRAFT-001")
    }

    func testExceptionSummaryInWizard() {
        // Given: Accepted exceptions
        wizardState.exceptions = [
            ConfigException(id: "EX-001", description: "Exception 1",
                          signedOffBy: "John", signedOffDate: "2026-01-01"),
            ConfigException(id: "EX-002", description: "Exception 2",
                          signedOffBy: "Jane", signedOffDate: "2026-01-02")
        ]

        // When/Then: Count should be correct for summary
        XCTAssertEqual(wizardState.exceptions.count, 2)
        XCTAssertFalse(wizardState.exceptions.isEmpty)
    }

    func testSigningAuthorityInvariant() {
        // Given: Draft with specific signing authority
        let operatorName = "Security Officer"
        let draft = CLISuggester.DraftException(
            draftId: "SECURITY-001",
            description: "Security exception",
            linkedFinding: "Security.Firewall",
            proposedSignedOffBy: operatorName,
            proposedSignedOffDate: "2026-05-07",
            severity: "critical"
        )

        // When: Accepting the draft
        let exception = wizardState.acceptDraft(draft)

        // Then: Signing authority should match exactly with no manipulation
        XCTAssertEqual(exception.signedOffBy, operatorName)
        XCTAssertEqual(exception.signedOffBy, draft.proposedSignedOffBy)
    }
}