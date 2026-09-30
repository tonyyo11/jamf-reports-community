import XCTest
@testable import JamfReports

// MARK: - WizardQ3Tests

/// Lane Q3 acceptance tests:
///   - SchoolTemplate registration and resolution
///   - ControlID parsing (canonical vs. non-canonical)
final class WizardQ3Tests: XCTestCase {

    // MARK: - #4 SchoolTemplate

    func testSchoolTemplateIdentifier() {
        XCTAssertEqual(SchoolTemplate().identifier, "school")
    }

    func testSchoolTemplateIsRegisteredInAllTemplates() {
        let identifiers = TemplateResolver.allTemplates.map(\.identifier)
        XCTAssertTrue(
            identifiers.contains("school"),
            "SchoolTemplate must be registered in TemplateResolver.allTemplates; got: \(identifiers)"
        )
    }

    func testTemplateResolverReturnsSchoolTemplate() {
        let resolved = TemplateResolver.resolve(identifier: "school")
        XCTAssertEqual(
            resolved.identifier,
            "school",
            "TemplateResolver.resolve(identifier: 'school') must return SchoolTemplate, " +
            "not the Executive fallback"
        )
    }

    func testSchoolTemplateDataTierIsSchool() {
        XCTAssertEqual(SchoolTemplate().recommendedSchedule, TemplateDataTier.school)
    }

    func testSchoolTemplateHasAudience() {
        XCTAssertFalse(
            SchoolTemplate().audience.isEmpty,
            "SchoolTemplate.audience must not be empty"
        )
    }

    func testSchoolTemplateIncludesAtLeastFourSheets() {
        XCTAssertGreaterThanOrEqual(
            SchoolTemplate().includedSheets.count, 4,
            "SchoolTemplate must include at least 4 sheets"
        )
    }

    func testSchoolTemplateIncludesAtLeastFourHTMLSections() {
        XCTAssertGreaterThanOrEqual(
            SchoolTemplate().htmlSections.count, 4,
            "SchoolTemplate must include at least 4 HTML sections"
        )
    }

    func testAllTemplatesHaveAudience() {
        for template in TemplateResolver.allTemplates {
            XCTAssertFalse(
                template.audience.isEmpty,
                "\(type(of: template)).audience must not be empty"
            )
        }
    }

    func testTemplateResolverFallsBackToExecutiveForUnknown() {
        let resolved = TemplateResolver.resolve(identifier: "does-not-exist")
        XCTAssertEqual(
            resolved.identifier,
            "executive",
            "Unknown identifier must fall back to ExecutiveTemplate"
        )
    }

    // MARK: - #9 ControlID parsing

    func testControlIDCanonicalSimple() {
        let id = ControlID(raw: "AC-3")
        XCTAssertTrue(id.isCanonical, "AC-3 must parse as canonical")
        XCTAssertEqual(id.raw, "AC-3")
    }

    func testControlIDCanonicalWithEnhancement() {
        let id = ControlID(raw: "AC-3(2)")
        XCTAssertTrue(id.isCanonical, "AC-3(2) must parse as canonical")
    }

    func testControlIDCanonicalMultipartIA5() {
        let id = ControlID(raw: "IA-5")
        XCTAssertTrue(id.isCanonical, "IA-5 must parse as canonical")
    }

    func testControlIDCanonicalWithSubpart() {
        let id = ControlID(raw: "SI-7.1")
        XCTAssertTrue(id.isCanonical, "SI-7.1 must parse as canonical")
    }

    func testControlIDNonCanonicalFreeText() {
        let id = ControlID(raw: "Free text exception")
        XCTAssertFalse(id.isCanonical, "Free text must parse as non-canonical")
        XCTAssertEqual(id.raw, "Free text exception", "Raw value must be stored verbatim")
    }

    func testControlIDNonCanonicalLowercaseLetters() {
        // Control IDs require uppercase prefix — lowercase is non-canonical.
        let id = ControlID(raw: "ac-3")
        XCTAssertFalse(id.isCanonical, "Lowercase ac-3 must be non-canonical")
    }

    func testControlIDCodableRoundtrip() throws {
        let original = ControlID(raw: "CM-6(1)")
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ControlID.self, from: data)
        XCTAssertEqual(decoded.raw, original.raw)
        XCTAssertEqual(decoded.isCanonical, original.isCanonical)
    }
}
