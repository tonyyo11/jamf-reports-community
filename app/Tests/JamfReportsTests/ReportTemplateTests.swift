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
    /// The SheetID equivalent lives in MSCPComplianceSheetsTests.testFullInstanceTemplateCoversAllSheetIDs.
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

    // MARK: - CustomTemplate

    func testCustomTemplateIdentifier() {
        XCTAssertEqual(CustomTemplate(includedSheets: [.cover]).identifier, "custom")
    }

    func testCustomTemplateSingleSheet() {
        let template = CustomTemplate(includedSheets: [.executiveSummary])
        XCTAssertEqual(template.includedSheets, [.executiveSummary])
    }

    func testCustomTemplateMultipleSheets() {
        let sheets: [SheetID] = [.executiveSummary, .securityPosture, .patchCompliance]
        let template = CustomTemplate(includedSheets: sheets)
        XCTAssertEqual(template.includedSheets, sheets)
    }

    func testCustomTemplatePreservesSheetOrder() {
        let sheets: [SheetID] = [.patchCompliance, .executiveSummary, .securityPosture]
        let template = CustomTemplate(includedSheets: sheets)
        XCTAssertEqual(template.includedSheets, sheets) // Order preserved
    }

    func testCustomTemplateEmptySheets() {
        let template = CustomTemplate(includedSheets: [])
        XCTAssertTrue(template.includedSheets.isEmpty)
    }

    func testCustomTemplateHtmlSectionsIncludesKpiTiles() {
        let template = CustomTemplate(includedSheets: [.executiveSummary])
        XCTAssertTrue(template.htmlSections.contains(.kpiTiles))
    }

    func testCustomTemplateHtmlSectionsIncludesOrgInfo() {
        let template = CustomTemplate(includedSheets: [.executiveSummary])
        XCTAssertTrue(template.htmlSections.contains(.orgInfo))
    }

    func testCustomTemplateEmptyHtmlSectionsWhenNoSheets() {
        let template = CustomTemplate(includedSheets: [])
        XCTAssertTrue(template.htmlSections.isEmpty)
    }

    // MARK: - CustomTemplate.htmlSections switch-arm coverage

    /// Parametric test: each switch arm in `CustomTemplate.htmlSections` maps its
    /// trigger sheet to its expected SectionID(s). Tests every non-`default` arm,
    /// guarding against transposed or missing SectionIDs in a custom HTML report.
    func testCustomTemplateHtmlSectionsSheetMappings() {
        // (triggerSheet, expectedSections) — based on the switch in CustomTemplate.htmlSections
        let cases: [(SheetID, [SectionID])] = [
            (.executiveSummary,   [.execSummary]),
            (.securityPosture,    [.securityTiles]),
            (.compliancePosture,  [.complianceBands]),
            (.patchCompliance,    [.patchBar, .patchQueue]),
            (.patchFailures,      [.patchBar, .patchQueue]),
            (.auditSummary,       [.auditEvidence]),
            (.inventorySummary,   [.assetMap]),
            (.hardwareModels,     [.assetMap]),
            (.osCurrency,         [.osAdoptionChart, .osCurrency]),
            (.policyHealth,       [.policyTable]),
            (.profileStatus,      [.profileTable]),
            (.mobileConfigProfiles, [.profileTable]),
            (.protectOverview,    [.protectAlerts, .insightsDrift]),
            (.protectAlerts,      [.protectAlerts, .insightsDrift]),
            (.protectComputers,   [.protectAlerts, .insightsDrift]),
            (.protectInsights,    [.protectAlerts, .insightsDrift]),
        ]

        for (sheet, expectedSections) in cases {
            let template = CustomTemplate(includedSheets: [sheet])
            let sections = template.htmlSections
            for expected in expectedSections {
                XCTAssertTrue(
                    sections.contains(expected),
                    "CustomTemplate([.\(sheet.rawValue)]).htmlSections missing .\(expected.rawValue)"
                )
            }
        }
    }

    /// A sheet with no specific HTML mapping (the `default` arm) should yield
    /// only the always-on sections: kpiTiles, fleetSummary, and orgInfo.
    func testCustomTemplateHtmlSectionsDefaultArmYieldsOnlyAlwaysOnSections() {
        // .cover has no HTML mapping (hits the default arm)
        let template = CustomTemplate(includedSheets: [.cover])
        let sections = Set(template.htmlSections)
        XCTAssertTrue(sections.contains(.kpiTiles))
        XCTAssertTrue(sections.contains(.fleetSummary))
        XCTAssertTrue(sections.contains(.orgInfo))
        // No other sections should be added for a default-arm sheet
        XCTAssertEqual(sections.count, 3,
            "Default-arm sheet should produce exactly 3 always-on sections, got \(sections.count): "
            + sections.map(\.rawValue).sorted().joined(separator: ", "))
    }

    // MARK: - TemplateResolver custom support

    func testResolveCustomWithSheets() {
        let sheets: [SheetID] = [.executiveSummary, .securityPosture]
        let template = TemplateResolver.resolveCustom(sheets: sheets)
        XCTAssertEqual(template.identifier, "custom")
        if let customTemplate = template as? CustomTemplate {
            XCTAssertEqual(customTemplate.includedSheets, sheets)
        } else {
            XCTFail("Expected CustomTemplate, got \(type(of: template))")
        }
    }

    func testResolveCustomWithEmptySheetsFallsBackToExecutive() {
        let template = TemplateResolver.resolveCustom(sheets: [])
        XCTAssertEqual(template.identifier, "executive")
        XCTAssertTrue(template is ExecutiveTemplate)
    }

    func testResolveCustomIdentifierFallsBackToExecutive() {
        let template = TemplateResolver.resolve(identifier: "custom")
        XCTAssertEqual(template.identifier, "executive")
        XCTAssertTrue(template is ExecutiveTemplate)
    }
}
