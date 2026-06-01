import XCTest
@testable import JamfReports

// MARK: - ReportTemplateTests

/// Verifies that each concrete template satisfies the ReportTemplate protocol contracts:
/// - identifier is non-empty and stable
/// - displayName and description are non-empty
/// - includedSheets contains ≥ 4 entries
/// - htmlSections contains ≥ 4 entries
/// - pdfPagination and recommendedSchedule have meaningful raw values
final class ReportTemplateTests: XCTestCase {

    // MARK: - Fixture

    private var allTemplates: [any ReportTemplate] {
        [
            FullInstanceTemplate(),
            ExecutiveTemplate(),
            OperationalTemplate(),
            ComplianceTemplate(),
            AssetTemplate(),
            SecurityPostureTemplate(),
        ]
    }

    // MARK: - Protocol contract tests

    func testAllTemplatesHaveNonEmptyIdentifier() {
        for template in allTemplates {
            XCTAssertFalse(
                template.identifier.isEmpty,
                "\(type(of: template)) identifier must not be empty"
            )
        }
    }

    func testAllTemplatesHaveNonEmptyDisplayName() {
        for template in allTemplates {
            XCTAssertFalse(
                template.displayName.isEmpty,
                "\(type(of: template)) displayName must not be empty"
            )
        }
    }

    func testAllTemplatesHaveNonEmptyDescription() {
        for template in allTemplates {
            XCTAssertFalse(
                template.description.isEmpty,
                "\(type(of: template)) description must not be empty"
            )
        }
    }

    func testAllTemplatesHaveAtLeastFourSheets() {
        for template in allTemplates {
            XCTAssertGreaterThanOrEqual(
                template.includedSheets.count, 4,
                "\(type(of: template)) must include ≥ 4 sheets, got \(template.includedSheets.count)"
            )
        }
    }

    func testAllTemplatesHaveAtLeastFourHTMLSections() {
        for template in allTemplates {
            XCTAssertGreaterThanOrEqual(
                template.htmlSections.count, 4,
                "\(type(of: template)) must include ≥ 4 HTML sections, got \(template.htmlSections.count)"
            )
        }
    }

    func testIdentifiersAreUnique() {
        let ids = allTemplates.map(\.identifier)
        let unique = Set(ids)
        XCTAssertEqual(ids.count, unique.count, "Template identifiers must be unique")
    }

    func testIdentifiersAreLowercaseHyphenated() {
        for template in allTemplates {
            let id = template.identifier
            let allowed = CharacterSet.lowercaseLetters
                .union(.init(charactersIn: "-"))
                .union(.decimalDigits)
            XCTAssertTrue(
                id.unicodeScalars.allSatisfy { allowed.contains($0) },
                "Identifier '\(id)' must be lowercase with hyphens only"
            )
        }
    }

    func testIncludedSheetsContainNoduplicates() {
        for template in allTemplates {
            let ids = template.includedSheets.map(\.rawValue)
            let unique = Set(ids)
            XCTAssertEqual(
                ids.count, unique.count,
                "\(type(of: template)) includedSheets contains duplicate SheetIDs"
            )
        }
    }

    func testHTMLSectionsContainNoDuplicates() {
        for template in allTemplates {
            let ids = template.htmlSections.map(\.rawValue)
            let unique = Set(ids)
            XCTAssertEqual(
                ids.count, unique.count,
                "\(type(of: template)) htmlSections contains duplicate SectionIDs"
            )
        }
    }

    // MARK: - Executive template

    func testExecutiveTemplateIdentifier() {
        XCTAssertEqual(ExecutiveTemplate().identifier, "executive")
    }

    func testExecutiveTemplateIncludesCoverSheet() {
        XCTAssertTrue(ExecutiveTemplate().includedSheets.contains(.cover))
    }

    func testExecutiveTemplateIncludesSecurityPosture() {
        XCTAssertTrue(ExecutiveTemplate().includedSheets.contains(.securityPosture))
    }

    func testExecutiveTemplatePaginationIsStandard() {
        XCTAssertEqual(ExecutiveTemplate().pdfPagination, .standard)
    }

    func testExecutiveTemplateScheduleIsCore() {
        XCTAssertEqual(ExecutiveTemplate().recommendedSchedule, TemplateDataTier.core)
    }

    // MARK: - Operational template

    func testOperationalTemplateIdentifier() {
        XCTAssertEqual(OperationalTemplate().identifier, "operational")
    }

    func testOperationalTemplateIncludesCheckinHealth() {
        XCTAssertTrue(OperationalTemplate().includedSheets.contains(.checkinHealth))
    }

    func testOperationalTemplatePaginationIsCompact() {
        XCTAssertEqual(OperationalTemplate().pdfPagination, .compact)
    }

    func testOperationalTemplateHTMLIncludesPatchQueue() {
        XCTAssertTrue(OperationalTemplate().htmlSections.contains(.patchQueue))
    }

    // MARK: - Compliance template

    func testComplianceTemplateIdentifier() {
        XCTAssertEqual(ComplianceTemplate().identifier, "compliance")
    }

    func testComplianceTemplateIncludesAuditSummary() {
        XCTAssertTrue(ComplianceTemplate().includedSheets.contains(.auditSummary))
    }

    func testComplianceTemplatePaginationIsSectionPerPage() {
        XCTAssertEqual(ComplianceTemplate().pdfPagination, .sectionPerPage)
    }

    func testComplianceTemplateScheduleIsPlatform() {
        XCTAssertEqual(ComplianceTemplate().recommendedSchedule, .platform)
    }

    func testComplianceTemplateHTMLIncludesAuditEvidence() {
        XCTAssertTrue(ComplianceTemplate().htmlSections.contains(.auditEvidence))
    }

    // MARK: - Asset template

    func testAssetTemplateIdentifier() {
        XCTAssertEqual(AssetTemplate().identifier, "asset")
    }

    func testAssetTemplateIncludesInventorySummary() {
        XCTAssertTrue(AssetTemplate().includedSheets.contains(.inventorySummary))
    }

    func testAssetTemplateScheduleIsFull() {
        XCTAssertEqual(AssetTemplate().recommendedSchedule, .full)
    }

    func testAssetTemplateHTMLIncludesWarrantyTable() {
        XCTAssertTrue(AssetTemplate().htmlSections.contains(.warrantyTable))
    }

    func testAssetTemplateHTMLIncludesBuildingBreakdown() {
        XCTAssertTrue(AssetTemplate().htmlSections.contains(.buildingBreakdown))
    }

    // MARK: - Security Posture template

    func testSecurityPostureTemplateIdentifier() {
        XCTAssertEqual(SecurityPostureTemplate().identifier, "security-posture")
    }

    func testSecurityPostureTemplateIncludesProtectAlerts() {
        XCTAssertTrue(SecurityPostureTemplate().includedSheets.contains(.protectAlerts))
    }

    func testSecurityPostureTemplatePaginationIsSectionPerPage() {
        XCTAssertEqual(SecurityPostureTemplate().pdfPagination, .sectionPerPage)
    }

    func testSecurityPostureTemplateScheduleIsProtect() {
        XCTAssertEqual(SecurityPostureTemplate().recommendedSchedule, .protect)
    }

    func testSecurityPostureTemplateHTMLIncludesInsightsDrift() {
        XCTAssertTrue(SecurityPostureTemplate().htmlSections.contains(.insightsDrift))
    }

    // MARK: - SheetID coverage sanity

    func testAllSheetIDsHaveNonEmptyRawValue() {
        for id in SheetID.allCases {
            XCTAssertFalse(id.rawValue.isEmpty, "SheetID.\(id) must have a non-empty rawValue")
        }
    }

    func testAllSectionIDsHaveNonEmptyRawValue() {
        for id in SectionID.allCases {
            XCTAssertFalse(id.rawValue.isEmpty, "SectionID.\(id) must have a non-empty rawValue")
        }
    }

    // MARK: - FullInstanceTemplate

    func testFullInstanceTemplateIdentifier() {
        XCTAssertEqual(FullInstanceTemplate().identifier, "full-instance")
    }

    func testFullInstanceTemplateResolves() {
        let template = TemplateResolver.resolve(identifier: "full-instance")
        XCTAssertEqual(template.identifier, "full-instance")
        XCTAssertTrue(template is FullInstanceTemplate)
    }

    /// Every SectionID must appear in FullInstanceTemplate.htmlSections so new
    /// sections can never be silently omitted from the full report.
    func testFullInstanceTemplateHtmlSectionsCoversAllSectionIDs() {
        let templateSections = Set(FullInstanceTemplate().htmlSections)
        let allSections = Set(SectionID.allCases)
        let missing = allSections.subtracting(templateSections)
        XCTAssertTrue(
            missing.isEmpty,
            "FullInstanceTemplate.htmlSections is missing SectionIDs: " +
            "\(missing.map(\.rawValue).sorted().joined(separator: ", "))"
        )
    }

    func testFullInstanceTemplateScheduleIsFull() {
        XCTAssertEqual(FullInstanceTemplate().recommendedSchedule, .full)
    }

    func testFullInstanceTemplateIsFirstInResolver() {
        XCTAssertEqual(
            TemplateResolver.allTemplates.first?.identifier,
            "full-instance",
            "FullInstanceTemplate must be the first template in TemplateResolver.allTemplates"
        )
    }
}
